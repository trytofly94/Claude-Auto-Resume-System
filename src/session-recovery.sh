#!/usr/bin/env bash

# Claude Auto-Resume - Session Recovery System
# Advanced Session Health Monitoring and Recovery
# Version: 1.0.0-alpha
# Created: 2025-08-27

set -euo pipefail

# ===============================================================================
# GLOBALE VARIABLEN UND KONSTANTEN
# ===============================================================================

# Standard-Konfiguration (wird von config/default.conf überschrieben)
SESSION_HEALTH_CHECK_INTERVAL="${SESSION_HEALTH_CHECK_INTERVAL:-60}"  # 1 minute during task execution
SESSION_RECOVERY_TIMEOUT="${SESSION_RECOVERY_TIMEOUT:-300}"           # 5 minutes
SESSION_RECOVERY_MAX_ATTEMPTS="${SESSION_RECOVERY_MAX_ATTEMPTS:-3}"
RECOVERY_AUTO_ATTEMPT="${RECOVERY_AUTO_ATTEMPT:-true}"
RECOVERY_MAX_ATTEMPTS="${RECOVERY_MAX_ATTEMPTS:-3}"
RECOVERY_FALLBACK_MODE="${RECOVERY_FALLBACK_MODE:-true}"

# Recovery state tracking
declare -A SESSION_RECOVERY_STATE
declare -A SESSION_RECOVERY_ATTEMPTS
declare -A SESSION_HEALTH_MONITORS

# ===============================================================================
# HILFSFUNKTIONEN UND DEPENDENCIES
# ===============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Lade Utility-Module
if [[ -f "$SCRIPT_DIR/utils/logging.sh" ]]; then
    source "$SCRIPT_DIR/utils/logging.sh"
else
    log_debug() { echo "[DEBUG] $*" >&2; }
    log_info() { echo "[INFO] $*" >&2; }
    log_warn() { echo "[WARN] $*" >&2; }
    log_error() { echo "[ERROR] $*" >&2; }
fi

# Load session manager module
if [[ -f "$SCRIPT_DIR/session-manager.sh" ]]; then
    source "$SCRIPT_DIR/session-manager.sh"
fi

# Load claunch integration
if [[ -f "$SCRIPT_DIR/claunch-integration.sh" ]]; then
    source "$SCRIPT_DIR/claunch-integration.sh"
fi

# Utility function to check if command exists
has_command() {
    command -v "$1" >/dev/null 2>&1
}

# ===============================================================================
# CORE SESSION HEALTH MONITORING
# ===============================================================================

# Monitor session health during task execution
monitor_session_health_during_task() {
    local session_id="$1"
    local task_id="$2"
    
    if [[ -z "$session_id" || -z "$task_id" ]]; then
        log_error "Invalid parameters for session health monitoring"
        return 1
    fi
    
    log_info "Starting session health monitoring for session $session_id (task: $task_id)"
    
    # Start health monitor in background
    session_health_monitor_loop "$session_id" "$task_id" &
    local monitor_pid=$!
    
    # Track monitor PID
    SESSION_HEALTH_MONITORS["$task_id"]="$monitor_pid"
    
    log_debug "Session health monitor started (PID: $monitor_pid)"
    return 0
}

# Main session health monitoring loop
session_health_monitor_loop() {
    local session_id="$1"
    local task_id="$2"
    
    while is_task_active "$task_id"; do
        if ! verify_session_responsiveness "$session_id"; then
            log_warn "Session $session_id unresponsive during task $task_id"
            
            # Create session failure backup
            create_session_failure_backup "$task_id" "$session_id"
            
            # Attempt session recovery
            if recover_session_with_task_context "$session_id" "$task_id"; then
                log_info "Session recovery successful for task $task_id"
            else
                log_error "Session recovery failed for task $task_id"
                handle_session_recovery_failure "$task_id" "$session_id"
                return 1
            fi
        fi
        
        # Check session health every interval
        sleep "$SESSION_HEALTH_CHECK_INTERVAL"
    done
    
    log_debug "Task $task_id completed - stopping session health monitoring"
    return 0
}

# Verify session responsiveness
verify_session_responsiveness() {
    local session_id="$1"
    local test_command="echo 'health_check_$(date +%s)'"
    local response_timeout=30
    
    log_debug "Verifying responsiveness of session $session_id"
    
    # Send test command and monitor for response
    if send_command_to_session "$session_id" "$test_command"; then
        local start_time=$(date +%s)
        
        # Wait for response with timeout
        while [[ $(($(date +%s) - start_time)) -lt $response_timeout ]]; do
            if session_has_recent_output "$session_id"; then
                log_debug "Session $session_id is responsive"
                return 0  # Session responsive
            fi
            sleep 2
        done
        
        log_warn "Session $session_id did not respond within ${response_timeout}s"
    else
        log_warn "Failed to send test command to session $session_id"
    fi
    
    return 1  # Session unresponsive
}

# Send command to session
send_command_to_session() {
    local session_id="$1"
    local command="$2"
    
    # Use claunch integration if available
    if declare -f send_command_with_claunch >/dev/null 2>&1; then
        send_command_with_claunch "$command" "$session_id"
    elif declare -f send_tmux_command >/dev/null 2>&1; then
        send_tmux_command "$command" "$session_id"
    else
        # Fallback to basic tmux command
        if has_command tmux; then
            tmux send-keys -t "$session_id" "$command" C-m 2>/dev/null
        else
            log_error "No method available to send command to session $session_id"
            return 1
        fi
    fi
}

# Check if session has recent output
session_has_recent_output() {
    local session_id="$1"
    local output_timeout=10  # Check for output within last 10 seconds
    
    # Try to capture recent session output
    local recent_output=""
    
    if has_command tmux; then
        # Capture last few lines of tmux session
        recent_output=$(tmux capture-pane -t "$session_id" -p 2>/dev/null | tail -5 || true)
    fi
    
    # Check if output contains our health check pattern or recent activity
    if [[ -n "$recent_output" ]]; then
        local current_time=$(date +%s)
        local health_check_pattern="health_check_"
        
        # Look for health check response or recent activity
        if echo "$recent_output" | grep -q "$health_check_pattern"; then
            return 0
        fi
        
        # Check for any recent activity (non-empty output)
        if [[ $(echo "$recent_output" | wc -c) -gt 10 ]]; then
            return 0
        fi
    fi
    
    return 1
}

# ===============================================================================
# SESSION RECOVERY MECHANISMS
# ===============================================================================

# Recover session with task context preservation
recover_session_with_task_context() {
    local session_id="$1"
    local task_id="$2"
    
    local attempt_key="${session_id}_${task_id}"
    local current_attempts=${SESSION_RECOVERY_ATTEMPTS[$attempt_key]:-0}
    
    if [[ $current_attempts -ge $SESSION_RECOVERY_MAX_ATTEMPTS ]]; then
        log_error "Maximum recovery attempts ($SESSION_RECOVERY_MAX_ATTEMPTS) reached for session $session_id"
        return 1
    fi
    
    ((current_attempts++))
    SESSION_RECOVERY_ATTEMPTS[$attempt_key]=$current_attempts
    
    log_info "Attempting session recovery for $session_id (attempt $current_attempts/$SESSION_RECOVERY_MAX_ATTEMPTS, task: $task_id)"
    
    # Preserve task state before recovery
    preserve_task_state_during_recovery "$task_id"
    
    # Try graceful session restart first
    if restart_claude_session "$session_id"; then
        # Restore task context in new session
        if restore_task_context_after_recovery "$task_id"; then
            # Validate session is ready
            if validate_session_after_recovery "$session_id"; then
                log_info "Session recovery completed successfully for $session_id"
                SESSION_RECOVERY_ATTEMPTS[$attempt_key]=0  # Reset counter on success
                return 0
            fi
        fi
    fi
    
    # Fallback to emergency session creation
    log_warn "Graceful recovery failed for $session_id, attempting emergency session creation"
    if create_emergency_session_for_task "$task_id"; then
        SESSION_RECOVERY_ATTEMPTS[$attempt_key]=0  # Reset counter on success
        return 0
    fi
    
    log_error "All recovery attempts failed for session $session_id (task: $task_id)"
    return 1
}

# Preserve task state during recovery
preserve_task_state_during_recovery() {
    local task_id="$1"
    
    log_debug "Preserving task state during recovery for task $task_id"
    
    # Create recovery checkpoint if backup system is available
    if [[ -f "$SCRIPT_DIR/task-state-backup.sh" ]]; then
        source "$SCRIPT_DIR/task-state-backup.sh"
        if declare -f create_task_checkpoint >/dev/null 2>&1; then
            create_task_checkpoint "$task_id" "session_recovery"
        fi
    fi
    
    # Store current task progress if available
    local task_progress_file="/tmp/task-recovery-${task_id}.json"
    cat > "$task_progress_file" << EOF
{
    "task_id": "$task_id",
    "recovery_time": "$(date -Iseconds)",
    "recovery_reason": "session_unresponsive",
    "recovery_attempt": ${SESSION_RECOVERY_ATTEMPTS["${MAIN_SESSION_ID:-unknown}_${task_id}"]:-1}
}
EOF
    
    log_debug "Task state preserved for recovery: $task_progress_file"
    return 0
}

# Restart Claude session
restart_claude_session() {
    local session_id="$1"
    
    log_info "Restarting Claude session: $session_id"
    
    # Kill existing session if it exists
    if has_command tmux && tmux has-session -t "$session_id" 2>/dev/null; then
        log_debug "Terminating existing tmux session: $session_id"
        tmux kill-session -t "$session_id" 2>/dev/null || true
    fi
    
    # Start new session using session manager if available
    if declare -f create_new_session >/dev/null 2>&1; then
        create_new_session "$session_id"
    elif declare -f start_claude_session_with_claunch >/dev/null 2>&1; then
        start_claude_session_with_claunch "$session_id"
    else
        # Fallback to basic tmux session creation
        create_basic_tmux_session "$session_id"
    fi
}

# Create basic tmux session as fallback
create_basic_tmux_session() {
    local session_id="$1"
    
    if ! has_command tmux; then
        log_error "tmux not available - cannot create fallback session"
        return 1
    fi
    
    log_debug "Creating basic tmux session: $session_id"
    
    # Create new tmux session
    if tmux new-session -d -s "$session_id" 2>/dev/null; then
        # Wait a moment for session to initialize
        sleep 2
        
        # Try to start Claude CLI in the session
        if has_command claude; then
            tmux send-keys -t "$session_id" "claude" C-m
            sleep 3  # Allow Claude to initialize
        fi
        
        return 0
    else
        log_error "Failed to create basic tmux session: $session_id"
        return 1
    fi
}

# Restore task context after recovery
restore_task_context_after_recovery() {
    local task_id="$1"
    
    log_debug "Restoring task context after recovery for task $task_id"
    
    # Check for recovery state file
    local task_progress_file="/tmp/task-recovery-${task_id}.json"
    if [[ ! -f "$task_progress_file" ]]; then
        log_warn "No recovery state found for task $task_id"
        return 0  # Continue anyway
    fi
    
    # Restore from backup if available
    if [[ -f "$SCRIPT_DIR/task-state-backup.sh" ]]; then
        source "$SCRIPT_DIR/task-state-backup.sh"
        if declare -f restore_from_checkpoint >/dev/null 2>&1; then
            restore_from_checkpoint "$task_id"
        fi
    fi
    
    # Clean up temporary recovery file
    rm -f "$task_progress_file"
    
    log_debug "Task context restoration completed for task $task_id"
    return 0
}

# Validate session after recovery
validate_session_after_recovery() {
    local session_id="$1"
    local validation_timeout=60
    local start_time=$(date +%s)
    
    log_debug "Validating session $session_id after recovery"
    
    # Wait for session to be ready
    while [[ $(($(date +%s) - start_time)) -lt $validation_timeout ]]; do
        if verify_session_responsiveness "$session_id"; then
            log_info "Session $session_id validated successfully after recovery"
            return 0
        fi
        sleep 5
    done
    
    log_error "Session $session_id validation failed after recovery (timeout: ${validation_timeout}s)"
    return 1
}

# Create emergency session for task
create_emergency_session_for_task() {
    local task_id="$1"
    local emergency_session_id="emergency-${task_id}-$(date +%s)"
    
    log_warn "Creating emergency session for task $task_id: $emergency_session_id"
    
    # Create emergency session
    if create_basic_tmux_session "$emergency_session_id"; then
        # Update task with new session ID if possible
        if [[ -f "$SCRIPT_DIR/task-queue.sh" ]]; then
            source "$SCRIPT_DIR/task-queue.sh"
            if declare -f update_task_session >/dev/null 2>&1; then
                update_task_session "$task_id" "$emergency_session_id"
            fi
        fi
        
        # Update global session ID if this was the main session
        if [[ "${MAIN_SESSION_ID:-}" == *"$task_id"* ]]; then
            export MAIN_SESSION_ID="$emergency_session_id"
        fi
        
        log_info "Emergency session created successfully: $emergency_session_id"
        return 0
    else
        log_error "Failed to create emergency session for task $task_id"
        return 1
    fi
}

# ===============================================================================
# FAILURE HANDLING
# ===============================================================================

# Create session failure backup
create_session_failure_backup() {
    local task_id="$1"
    local session_id="$2"
    local timestamp=$(date +%Y%m%d-%H%M%S)
    
    # Determine backup location
    local backup_dir="${PROJECT_ROOT}/queue/backups"
    mkdir -p "$backup_dir" 2>/dev/null || backup_dir="/tmp"
    
    local backup_file="$backup_dir/session-failure-${task_id}-${timestamp}.json"
    
    log_debug "Creating session failure backup: $backup_file"
    
    # Gather session state information
    local session_state="unknown"
    if declare -f get_session_state >/dev/null 2>&1; then
        session_state=$(get_session_state "$session_id" 2>/dev/null || echo "unknown")
    fi
    
    # Create comprehensive failure backup
    cat > "$backup_file" << EOF
{
    "backup_time": "$(date -Iseconds)",
    "backup_reason": "session_failure",
    "task_id": "$task_id",
    "session_id": "$session_id",
    "session_state": "$session_state",
    "recovery_attempts": ${SESSION_RECOVERY_ATTEMPTS["${session_id}_${task_id}"]:-0},
    "system_info": {
        "hostname": "$(hostname)",
        "pid": $$,
        "current_cycle": "${CURRENT_CYCLE:-0}"
    },
    "failure_details": {
        "detection_time": $(date +%s),
        "health_check_interval": $SESSION_HEALTH_CHECK_INTERVAL
    }
}
EOF
    
    log_info "Session failure backup created: $backup_file"
    return 0
}

# Handle session recovery failure
handle_session_recovery_failure() {
    local task_id="$1"
    local session_id="$2"
    
    log_error "Handling session recovery failure for task $task_id (session: $session_id)"
    
    # Mark task as failed if task queue is available
    if [[ -f "$SCRIPT_DIR/task-queue.sh" ]]; then
        source "$SCRIPT_DIR/task-queue.sh"
        if declare -f update_task_status >/dev/null 2>&1; then
            update_task_status "$task_id" "failed" "session_recovery_failure"
        fi
    fi
    
    # Trigger error classification and recovery if available
    if [[ -f "$SCRIPT_DIR/error-classification.sh" ]]; then
        source "$SCRIPT_DIR/error-classification.sh"
        if declare -f execute_recovery_strategy >/dev/null 2>&1; then
            execute_recovery_strategy "manual_recovery" "$task_id" "session_failure"
        fi
    fi
    
    # Stop health monitoring for this task
    stop_session_health_monitoring "$task_id"
    
    return 1
}

# ===============================================================================
# MONITORING CONTROL
# ===============================================================================

# Stop session health monitoring for a task
stop_session_health_monitoring() {
    local task_id="$1"
    
    local monitor_pid="${SESSION_HEALTH_MONITORS[$task_id]:-}"
    
    if [[ -n "$monitor_pid" ]]; then
        if kill -0 "$monitor_pid" 2>/dev/null; then
            kill -TERM "$monitor_pid" 2>/dev/null || true
            log_debug "Session health monitor stopped for task $task_id (PID: $monitor_pid)"
        fi
        unset SESSION_HEALTH_MONITORS["$task_id"]
    fi
    
    return 0
}

# Stop all session health monitors
stop_all_session_monitors() {
    log_info "Stopping all session health monitors"
    
    for task_id in "${!SESSION_HEALTH_MONITORS[@]}"; do
        stop_session_health_monitoring "$task_id"
    done
    
    # Clear recovery state
    SESSION_RECOVERY_ATTEMPTS=()
    SESSION_RECOVERY_STATE=()
    
    log_debug "All session health monitors stopped"
}

# Check if task is still active (implementation depends on task queue system)
is_task_active() {
    local task_id="$1"
    
    # Source task-queue functions if available
    if [[ -f "$SCRIPT_DIR/task-queue.sh" ]]; then
        source "$SCRIPT_DIR/task-queue.sh"
        
        if declare -f get_task_status >/dev/null 2>&1; then
            local status
            status=$(get_task_status "$task_id" 2>/dev/null || echo "unknown")
            [[ "$status" == "in_progress" || "$status" == "pending" ]]
        else
            # Fallback: assume active if called
            true
        fi
    else
        # Ultimate fallback: assume active
        true
    fi
}

# ===============================================================================
# SIGNAL HANDLING AND CLEANUP
# ===============================================================================

# Handle script termination signals
session_recovery_signal_handler() {
    local signal="$1"
    log_info "Session recovery system received signal $signal - cleaning up"
    stop_all_session_monitors
    exit 0
}

# Set up signal handlers
trap 'session_recovery_signal_handler TERM' TERM
trap 'session_recovery_signal_handler INT' INT
trap 'session_recovery_signal_handler EXIT' EXIT

# ===============================================================================
# MODULE INITIALIZATION
# ===============================================================================

# Auto-initialize if sourced
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    log_debug "Session recovery module loaded"
fi