#!/usr/bin/env bash

# Claude Auto-Resume - Task Timeout Monitor
# Timeout Detection and Management System
# Version: 1.0.0-alpha
# Created: 2025-08-27

set -euo pipefail

# ===============================================================================
# GLOBALE VARIABLEN UND KONSTANTEN
# ===============================================================================

# Standard-Konfiguration (wird von config/default.conf überschrieben)
TIMEOUT_DETECTION_ENABLED="${TIMEOUT_DETECTION_ENABLED:-true}"
TIMEOUT_WARNING_THRESHOLD="${TIMEOUT_WARNING_THRESHOLD:-300}"  # 5 minutes before timeout
TIMEOUT_AUTO_ESCALATION="${TIMEOUT_AUTO_ESCALATION:-true}"
TIMEOUT_EMERGENCY_TERMINATION="${TIMEOUT_EMERGENCY_TERMINATION:-true}"

# Timeout Tracking Directories
TIMEOUT_DIR=""
TIMEOUT_MONITOR_PIDS=()

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

# ===============================================================================
# TIMEOUT TRACKING INITIALIZATION
# ===============================================================================

# Initialize timeout tracking system
initialize_timeout_system() {
    local task_queue_dir="${TASK_QUEUE_DIR:-queue}"
    
    if [[ "$TIMEOUT_DETECTION_ENABLED" != "true" ]]; then
        log_debug "Timeout detection disabled - skipping initialization"
        return 0
    fi
    
    # Create absolute path for timeout directory
    if [[ "$task_queue_dir" = /* ]]; then
        TIMEOUT_DIR="$task_queue_dir/timeouts"
    else
        TIMEOUT_DIR="$PROJECT_ROOT/$task_queue_dir/timeouts"
    fi
    
    # Create timeout directory if it doesn't exist
    if ! mkdir -p "$TIMEOUT_DIR"; then
        log_error "Failed to create timeout directory: $TIMEOUT_DIR"
        return 1
    fi
    
    # Clean up any stale timeout files
    cleanup_stale_timeouts
    
    log_info "Timeout monitoring system initialized: $TIMEOUT_DIR"
    return 0
}

# Clean up stale timeout files from previous runs
cleanup_stale_timeouts() {
    if [[ ! -d "$TIMEOUT_DIR" ]]; then
        return 0
    fi
    
    local cleanup_count=0
    
    # Remove timeout files older than 24 hours
    while IFS= read -r -d '' timeout_file; do
        if [[ -f "$timeout_file" && $(find "$timeout_file" -mtime +1 2>/dev/null | wc -l) -gt 0 ]]; then
            rm -f "$timeout_file" "${timeout_file}.monitor_pid" 2>/dev/null || true
            ((cleanup_count++))
        fi
    done < <(find "$TIMEOUT_DIR" -name "*.timeout" -print0 2>/dev/null || true)
    
    if [[ $cleanup_count -gt 0 ]]; then
        log_debug "Cleaned up $cleanup_count stale timeout files"
    fi
}

# ===============================================================================
# CORE TIMEOUT MONITORING FUNCTIONS
# ===============================================================================

# Start timeout monitor for a task
start_task_timeout_monitor() {
    local task_id="$1"
    local timeout_seconds="$2"
    local task_pid="${3:-}"
    
    if [[ "$TIMEOUT_DETECTION_ENABLED" != "true" ]]; then
        log_debug "Timeout monitoring disabled for task $task_id"
        return 0
    fi
    
    if [[ -z "$task_id" || -z "$timeout_seconds" ]]; then
        log_error "Invalid parameters for timeout monitor: task_id='$task_id' timeout='$timeout_seconds'"
        return 1
    fi
    
    if [[ ! -d "$TIMEOUT_DIR" ]]; then
        initialize_timeout_system
    fi
    
    local timeout_file="$TIMEOUT_DIR/${task_id}.timeout"
    local current_time=$(date +%s)
    
    log_info "Starting timeout monitor for task $task_id (${timeout_seconds}s timeout)"
    
    # Create timeout tracking file
    cat > "$timeout_file" << EOF
{
    "task_id": "$task_id",
    "start_time": $current_time,
    "timeout_seconds": $timeout_seconds,
    "task_pid": "$task_pid",
    "warnings_sent": 0,
    "monitor_pid": null,
    "status": "active"
}
EOF
    
    # Start timeout monitor in background
    monitor_task_timeout "$task_id" "$timeout_seconds" &
    local monitor_pid=$!
    
    # Update timeout file with monitor PID
    if has_command jq; then
        local temp_file
        temp_file=$(mktemp)
        jq --argjson pid "$monitor_pid" '.monitor_pid = $pid' "$timeout_file" > "$temp_file" && mv "$temp_file" "$timeout_file"
    else
        # Fallback without jq
        echo "$monitor_pid" > "${timeout_file}.monitor_pid"
    fi
    
    # Track monitor PID for cleanup
    TIMEOUT_MONITOR_PIDS+=("$monitor_pid")
    
    log_debug "Timeout monitor started for task $task_id (PID: $monitor_pid)"
    return 0
}

# Main timeout monitoring loop
monitor_task_timeout() {
    local task_id="$1"
    local timeout_seconds="$2"
    local warning_threshold=$((timeout_seconds - TIMEOUT_WARNING_THRESHOLD))
    
    # Ensure warning threshold is reasonable
    if [[ $warning_threshold -le 0 ]]; then
        warning_threshold=$((timeout_seconds / 2))  # Warn at 50% if too short
    fi
    
    local start_time=$(date +%s)
    local warning_sent=false
    
    log_debug "Monitoring task $task_id timeout (warning at ${warning_threshold}s, timeout at ${timeout_seconds}s)"
    
    while true; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        # Check if task is still active
        if ! is_task_active "$task_id"; then
            log_debug "Task $task_id no longer active - stopping timeout monitor"
            cleanup_timeout_monitor "$task_id"
            return 0
        fi
        
        # Send warning before timeout
        if [[ $elapsed -ge $warning_threshold ]] && [[ "$warning_sent" == "false" ]]; then
            send_timeout_warning "$task_id" "$elapsed" "$timeout_seconds"
            warning_sent=true
        fi
        
        # Handle timeout
        if [[ $elapsed -ge $timeout_seconds ]]; then
            log_warn "TIMEOUT: Task $task_id exceeded timeout limit (${elapsed}s >= ${timeout_seconds}s)"
            handle_task_timeout "$task_id" "$elapsed"
            return 1
        fi
        
        # Check every 30 seconds for efficiency
        sleep 30
    done
}

# Check if task is still active
is_task_active() {
    local task_id="$1"
    
    # Source task-queue functions if available
    if [[ -f "$SCRIPT_DIR/task-queue.sh" ]]; then
        source "$SCRIPT_DIR/task-queue.sh"
        
        # Check if get_task_status function is available
        if declare -f get_task_status >/dev/null 2>&1; then
            local status
            status=$(get_task_status "$task_id" 2>/dev/null || echo "unknown")
            [[ "$status" == "in_progress" || "$status" == "pending" ]]
        else
            # Fallback: check if task file exists and is recent
            local task_queue_dir="${TASK_QUEUE_DIR:-queue}"
            local task_file="$PROJECT_ROOT/$task_queue_dir/tasks/${task_id}.json"
            [[ -f "$task_file" && $(find "$task_file" -mmin -5 2>/dev/null | wc -l) -gt 0 ]]
        fi
    else
        # Ultimate fallback: assume active if timeout file exists
        local timeout_file="$TIMEOUT_DIR/${task_id}.timeout"
        [[ -f "$timeout_file" ]]
    fi
}

# Send timeout warning
send_timeout_warning() {
    local task_id="$1"
    local elapsed="$2"
    local timeout_seconds="$3"
    local remaining=$((timeout_seconds - elapsed))
    
    log_warn "TIMEOUT WARNING: Task $task_id will timeout in ${remaining}s (elapsed: ${elapsed}s)"
    
    # Update timeout file with warning information
    local timeout_file="$TIMEOUT_DIR/${task_id}.timeout"
    if [[ -f "$timeout_file" ]] && has_command jq; then
        local temp_file
        temp_file=$(mktemp)
        jq '.warnings_sent += 1 | .last_warning = now' "$timeout_file" > "$temp_file" && mv "$temp_file" "$timeout_file"
    fi
    
    # TODO: Could integrate with notification system here
    # notify_timeout_warning "$task_id" "$remaining"
}

# Handle task timeout
handle_task_timeout() {
    local task_id="$1"
    local elapsed_time="$2"
    
    log_warn "TIMEOUT: Task $task_id timed out after ${elapsed_time}s"
    
    # Create timeout backup before termination
    create_timeout_backup "$task_id"
    
    # Update task status to timeout if task-queue functions are available
    if [[ -f "$SCRIPT_DIR/task-queue.sh" ]]; then
        source "$SCRIPT_DIR/task-queue.sh"
        if declare -f update_task_status >/dev/null 2>&1; then
            update_task_status "$task_id" "timeout" 2>/dev/null || log_warn "Failed to update task status to timeout"
        fi
    fi
    
    # Terminate task if possible
    terminate_task_safely "$task_id"
    
    # Trigger timeout recovery workflow if enabled
    if [[ "$TIMEOUT_AUTO_ESCALATION" == "true" ]]; then
        trigger_timeout_recovery "$task_id"
    fi
    
    # Cleanup timeout monitor
    cleanup_timeout_monitor "$task_id"
}

# Create timeout backup
create_timeout_backup() {
    local task_id="$1"
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_file="$TIMEOUT_DIR/timeout-backup-${task_id}-${timestamp}.json"
    
    log_debug "Creating timeout backup for task $task_id"
    
    # Gather task information if available
    local task_info="{}"
    if [[ -f "$SCRIPT_DIR/task-queue.sh" ]]; then
        source "$SCRIPT_DIR/task-queue.sh"
        if declare -f get_task_details >/dev/null 2>&1; then
            task_info=$(get_task_details "$task_id" 2>/dev/null || echo "{}")
        fi
    fi
    
    # Create comprehensive backup
    cat > "$backup_file" << EOF
{
    "backup_time": "$(date -Iseconds)",
    "backup_reason": "timeout",
    "task_id": "$task_id",
    "timeout_info": {
        "elapsed_time": $(date +%s),
        "start_time": $(date +%s),
        "timeout_threshold": "unknown"
    },
    "task_details": $task_info,
    "system_state": {
        "hostname": "$(hostname)",
        "pid": $$,
        "current_cycle": "${CURRENT_CYCLE:-0}"
    }
}
EOF
    
    log_info "Timeout backup created: $backup_file"
    return 0
}

# Safely terminate task
terminate_task_safely() {
    local task_id="$1"
    
    log_debug "Attempting safe termination of task $task_id"
    
    # Try to find task PID from timeout file
    local timeout_file="$TIMEOUT_DIR/${task_id}.timeout"
    local task_pid=""
    
    if [[ -f "$timeout_file" ]] && has_command jq; then
        task_pid=$(jq -r '.task_pid // empty' "$timeout_file" 2>/dev/null || true)
    fi
    
    # If we have a PID, try to terminate gracefully
    if [[ -n "$task_pid" && "$task_pid" != "null" ]]; then
        if kill -0 "$task_pid" 2>/dev/null; then
            log_info "Sending TERM signal to task $task_id (PID: $task_pid)"
            kill -TERM "$task_pid" 2>/dev/null || true
            
            # Wait a bit for graceful termination
            sleep 5
            
            # Force kill if still running
            if kill -0 "$task_pid" 2>/dev/null; then
                log_warn "Task $task_id still running - sending KILL signal"
                kill -KILL "$task_pid" 2>/dev/null || true
            fi
        fi
    else
        log_debug "No valid PID found for task $task_id - cannot terminate directly"
    fi
    
    return 0
}

# Trigger timeout recovery workflow
trigger_timeout_recovery() {
    local task_id="$1"
    
    log_info "Triggering timeout recovery for task $task_id"
    
    # Source error classification module if available
    if [[ -f "$SCRIPT_DIR/error-classification.sh" ]]; then
        source "$SCRIPT_DIR/error-classification.sh"
        if declare -f execute_recovery_strategy >/dev/null 2>&1; then
            execute_recovery_strategy "timeout_recovery" "$task_id" "timeout"
            return $?
        fi
    fi
    
    # Fallback recovery logic
    log_warn "Advanced recovery system not available - using basic timeout recovery"
    
    # Basic timeout recovery: mark task for retry if retries available
    if [[ -f "$SCRIPT_DIR/task-queue.sh" ]]; then
        source "$SCRIPT_DIR/task-queue.sh"
        if declare -f schedule_task_retry >/dev/null 2>&1; then
            schedule_task_retry "$task_id" "timeout"
        fi
    fi
    
    return 0
}

# Stop timeout monitor for a task
stop_timeout_monitor() {
    local task_id="$1"
    
    if [[ "$TIMEOUT_DETECTION_ENABLED" != "true" ]]; then
        return 0
    fi
    
    log_debug "Stopping timeout monitor for task $task_id"
    
    local timeout_file="$TIMEOUT_DIR/${task_id}.timeout"
    local monitor_pid=""
    
    # Get monitor PID
    if [[ -f "$timeout_file" ]] && has_command jq; then
        monitor_pid=$(jq -r '.monitor_pid // empty' "$timeout_file" 2>/dev/null || true)
    elif [[ -f "${timeout_file}.monitor_pid" ]]; then
        monitor_pid=$(cat "${timeout_file}.monitor_pid" 2>/dev/null || true)
    fi
    
    # Kill monitor process if running
    if [[ -n "$monitor_pid" && "$monitor_pid" != "null" ]]; then
        if kill -0 "$monitor_pid" 2>/dev/null; then
            kill -TERM "$monitor_pid" 2>/dev/null || true
            log_debug "Timeout monitor stopped for task $task_id (PID: $monitor_pid)"
        fi
    fi
    
    # Clean up files
    cleanup_timeout_monitor "$task_id"
    return 0
}

# Clean up timeout monitor files
cleanup_timeout_monitor() {
    local task_id="$1"
    
    local timeout_file="$TIMEOUT_DIR/${task_id}.timeout"
    
    # Remove timeout tracking files
    rm -f "$timeout_file" "${timeout_file}.monitor_pid" 2>/dev/null || true
    
    log_debug "Timeout monitor files cleaned up for task $task_id"
}

# Utility function to check if command exists
has_command() {
    command -v "$1" >/dev/null 2>&1
}

# ===============================================================================
# SYSTEM CLEANUP AND SHUTDOWN
# ===============================================================================

# Clean up all timeout monitors
cleanup_all_timeout_monitors() {
    if [[ "$TIMEOUT_DETECTION_ENABLED" != "true" || -z "$TIMEOUT_DIR" ]]; then
        return 0
    fi
    
    log_info "Cleaning up all timeout monitors"
    
    # Kill all monitor processes
    for pid in "${TIMEOUT_MONITOR_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill -TERM "$pid" 2>/dev/null || true
        fi
    done
    
    # Clean up timeout files
    if [[ -d "$TIMEOUT_DIR" ]]; then
        find "$TIMEOUT_DIR" -name "*.timeout" -delete 2>/dev/null || true
        find "$TIMEOUT_DIR" -name "*.monitor_pid" -delete 2>/dev/null || true
    fi
    
    TIMEOUT_MONITOR_PIDS=()
    log_debug "All timeout monitors cleaned up"
}

# Handle script termination signals
timeout_monitor_signal_handler() {
    local signal="$1"
    log_info "Timeout monitor received signal $signal - cleaning up"
    cleanup_all_timeout_monitors
    exit 0
}

# Set up signal handlers
trap 'timeout_monitor_signal_handler TERM' TERM
trap 'timeout_monitor_signal_handler INT' INT
trap 'timeout_monitor_signal_handler EXIT' EXIT

# ===============================================================================
# MODULE INITIALIZATION
# ===============================================================================

# Auto-initialize if sourced
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    log_debug "Task timeout monitor module loaded"
    # Initialize timeout system when module is sourced
    initialize_timeout_system
fi