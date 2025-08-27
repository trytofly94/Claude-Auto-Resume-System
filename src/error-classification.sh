#!/usr/bin/env bash

# Claude Auto-Resume - Error Classification and Recovery Strategy Engine
# Intelligent Error Analysis and Recovery Decision System
# Version: 1.0.0-alpha
# Created: 2025-08-27

set -euo pipefail

# ===============================================================================
# GLOBALE VARIABLEN UND KONSTANTEN
# ===============================================================================

# Standard-Konfiguration (wird von config/default.conf überschrieben)
ERROR_HANDLING_ENABLED="${ERROR_HANDLING_ENABLED:-true}"
ERROR_AUTO_RECOVERY="${ERROR_AUTO_RECOVERY:-true}"
ERROR_MAX_RETRIES="${ERROR_MAX_RETRIES:-3}"
ERROR_RETRY_DELAY="${ERROR_RETRY_DELAY:-300}"                # 5 minutes
ERROR_ESCALATION_THRESHOLD="${ERROR_ESCALATION_THRESHOLD:-5}"

# Error severity levels
readonly ERROR_SEVERITY_CRITICAL=3
readonly ERROR_SEVERITY_WARNING=2
readonly ERROR_SEVERITY_INFO=1
readonly ERROR_SEVERITY_UNKNOWN=0

# Recovery strategy types
readonly RECOVERY_STRATEGY_EMERGENCY="emergency_shutdown"
readonly RECOVERY_STRATEGY_AUTO="automatic_recovery"
readonly RECOVERY_STRATEGY_MANUAL="manual_recovery"
readonly RECOVERY_STRATEGY_RETRY="simple_retry"
readonly RECOVERY_STRATEGY_SAFE="safe_recovery"
readonly RECOVERY_STRATEGY_TIMEOUT="timeout_recovery"

# Error tracking
declare -A ERROR_HISTORY
declare -A ERROR_COUNTS
declare -A RECOVERY_ATTEMPTS

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

# Utility function to check if command exists
has_command() {
    command -v "$1" >/dev/null 2>&1
}

# ===============================================================================
# ERROR CLASSIFICATION ENGINE
# ===============================================================================

# Classify error severity based on error message and context
classify_error_severity() {
    local error_message="$1"
    local error_context="${2:-general}"
    local task_id="${3:-}"
    
    if [[ -z "$error_message" ]]; then
        log_debug "Empty error message - returning unknown severity"
        return $ERROR_SEVERITY_UNKNOWN
    fi
    
    log_debug "Classifying error severity for context '$error_context': '$error_message'"
    
    # Critical errors requiring immediate intervention
    local critical_patterns=(
        "segmentation fault"
        "segfault"
        "core dumped"
        "out of memory"
        "no space left on device"
        "disk full"
        "permission denied"
        "access denied"
        "authentication failed"
        "auth.*fail"
        "unauthorized"
        "fatal error"
        "panic"
        "emergency"
        "corruption"
        "corrupted"
        "kernel panic"
        "system halt"
    )
    
    # Warning level errors that can be retried
    local warning_patterns=(
        "network timeout"
        "connection timeout"
        "connection refused"
        "connection reset"
        "timeout"
        "temporary failure"
        "temporary unavailable"
        "usage limit"
        "rate limit"
        "limit exceeded"
        "service unavailable"
        "bad gateway"
        "gateway timeout"
        "network.*error"
        "dns.*error"
        "resolve.*error"
        "host.*unreachable"
        "no route to host"
        "connection.*lost"
        "disconnected"
        "interrupted"
    )
    
    # Info level errors that are recoverable
    local info_patterns=(
        "command not found"
        "file not found"
        "directory not found"
        "no such file"
        "syntax error"
        "invalid.*argument"
        "invalid.*option"
        "parse.*error"
        "format.*error"
        "validation.*error"
        "config.*error"
        "missing.*parameter"
        "unexpected.*token"
        "malformed"
    )
    
    # Check error severity in order of severity (critical first)
    for pattern in "${critical_patterns[@]}"; do
        if echo "$error_message" | grep -qi "$pattern"; then
            log_error "CRITICAL error detected: pattern '$pattern' matched"
            record_error_occurrence "$error_message" $ERROR_SEVERITY_CRITICAL "$error_context" "$task_id"
            return $ERROR_SEVERITY_CRITICAL
        fi
    done
    
    for pattern in "${warning_patterns[@]}"; do
        if echo "$error_message" | grep -qi "$pattern"; then
            log_warn "WARNING level error detected: pattern '$pattern' matched"
            record_error_occurrence "$error_message" $ERROR_SEVERITY_WARNING "$error_context" "$task_id"
            return $ERROR_SEVERITY_WARNING
        fi
    done
    
    for pattern in "${info_patterns[@]}"; do
        if echo "$error_message" | grep -qi "$pattern"; then
            log_info "INFO level error detected: pattern '$pattern' matched"
            record_error_occurrence "$error_message" $ERROR_SEVERITY_INFO "$error_context" "$task_id"
            return $ERROR_SEVERITY_INFO
        fi
    done
    
    # Unknown error pattern
    log_debug "Unknown error pattern detected: '$error_message'"
    record_error_occurrence "$error_message" $ERROR_SEVERITY_UNKNOWN "$error_context" "$task_id"
    return $ERROR_SEVERITY_UNKNOWN
}

# Record error occurrence for tracking and analysis
record_error_occurrence() {
    local error_message="$1"
    local severity="$2"
    local context="$3"
    local task_id="$4"
    local timestamp=$(date +%s)
    
    # Create error fingerprint for tracking
    local error_fingerprint
    error_fingerprint=$(echo "$error_message" | head -c 100 | tr -d '\n' | sed 's/[^a-zA-Z0-9]/_/g')
    
    # Record in history
    local history_key="${timestamp}_${error_fingerprint}"
    ERROR_HISTORY["$history_key"]="$severity:$context:$task_id:$error_message"
    
    # Update counts
    local count_key="${severity}_${error_fingerprint}"
    ERROR_COUNTS["$count_key"]=$((${ERROR_COUNTS["$count_key"]:-0} + 1))
    
    log_debug "Error occurrence recorded: severity=$severity, context=$context, count=${ERROR_COUNTS["$count_key"]}"
}

# ===============================================================================
# RECOVERY STRATEGY DETERMINATION
# ===============================================================================

# Determine appropriate recovery strategy based on error severity and history
determine_recovery_strategy() {
    local error_severity="$1"
    local task_id="$2"
    local retry_count="${3:-0}"
    local error_context="${4:-general}"
    
    log_debug "Determining recovery strategy: severity=$error_severity, retries=$retry_count, context=$error_context"
    
    # Check if recovery is enabled
    if [[ "$ERROR_HANDLING_ENABLED" != "true" ]]; then
        log_warn "Error handling disabled - using safe recovery"
        echo "$RECOVERY_STRATEGY_SAFE"
        return 0
    fi
    
    # Determine strategy based on severity and retry count
    case "$error_severity" in
        $ERROR_SEVERITY_CRITICAL)
            log_error "Critical error detected - initiating emergency protocols"
            echo "$RECOVERY_STRATEGY_EMERGENCY"
            ;;
        $ERROR_SEVERITY_WARNING)
            if [[ $retry_count -lt $ERROR_MAX_RETRIES ]]; then
                if [[ "$ERROR_AUTO_RECOVERY" == "true" ]]; then
                    log_warn "Warning level error - attempting automatic recovery"
                    echo "$RECOVERY_STRATEGY_AUTO"
                else
                    log_warn "Automatic recovery disabled - escalating to manual recovery"
                    echo "$RECOVERY_STRATEGY_MANUAL"
                fi
            else
                log_warn "Max retries exceeded ($ERROR_MAX_RETRIES) - escalating to manual recovery"
                echo "$RECOVERY_STRATEGY_MANUAL"
            fi
            ;;
        $ERROR_SEVERITY_INFO)
            if [[ $retry_count -lt $ERROR_MAX_RETRIES ]]; then
                log_info "Info level error - attempting simple retry"
                echo "$RECOVERY_STRATEGY_RETRY"
            else
                log_info "Max retries exceeded - using safe recovery"
                echo "$RECOVERY_STRATEGY_SAFE"
            fi
            ;;
        *)
            log_warn "Unknown error severity ($error_severity) - using safe recovery strategy"
            echo "$RECOVERY_STRATEGY_SAFE"
            ;;
    esac
}

# ===============================================================================
# RECOVERY STRATEGY EXECUTION
# ===============================================================================

# Execute the determined recovery strategy
execute_recovery_strategy() {
    local strategy="$1"
    local task_id="$2"
    local error_context="${3:-general}"
    local error_message="${4:-}"
    
    if [[ "$ERROR_HANDLING_ENABLED" != "true" ]]; then
        log_warn "Error handling disabled - skipping recovery strategy execution"
        return 1
    fi
    
    log_info "Executing recovery strategy: $strategy for task $task_id (context: $error_context)"
    
    # Track recovery attempt
    local attempt_key="${task_id}_${strategy}"
    RECOVERY_ATTEMPTS["$attempt_key"]=$((${RECOVERY_ATTEMPTS["$attempt_key"]:-0} + 1))
    
    case "$strategy" in
        "$RECOVERY_STRATEGY_EMERGENCY")
            emergency_queue_shutdown "$error_context" "$error_message"
            ;;
        "$RECOVERY_STRATEGY_AUTO")
            attempt_automatic_recovery "$task_id" "$error_context"
            ;;
        "$RECOVERY_STRATEGY_MANUAL")
            escalate_to_manual_recovery "$task_id" "$error_context" "$error_message"
            ;;
        "$RECOVERY_STRATEGY_RETRY")
            schedule_simple_retry "$task_id" "$error_context"
            ;;
        "$RECOVERY_STRATEGY_SAFE")
            fallback_to_safe_mode "$task_id" "$error_context"
            ;;
        "$RECOVERY_STRATEGY_TIMEOUT")
            handle_timeout_recovery "$task_id" "$error_context"
            ;;
        *)
            log_error "Unknown recovery strategy: $strategy"
            fallback_to_safe_mode "$task_id" "$error_context"
            return 1
            ;;
    esac
}

# ===============================================================================
# RECOVERY STRATEGY IMPLEMENTATIONS
# ===============================================================================

# Emergency queue shutdown for critical errors
emergency_queue_shutdown() {
    local error_context="$1"
    local error_message="$2"
    
    log_error "EMERGENCY: Initiating emergency queue shutdown due to critical error"
    log_error "Error context: $error_context"
    log_error "Error message: $error_message"
    
    # Create emergency backup
    if [[ -f "$SCRIPT_DIR/task-state-backup.sh" ]]; then
        source "$SCRIPT_DIR/task-state-backup.sh"
        if declare -f create_emergency_system_backup >/dev/null 2>&1; then
            local backup_file
            backup_file=$(create_emergency_system_backup "critical_error")
            log_error "Emergency backup created: $backup_file"
        fi
    fi
    
    # Stop all task processing
    if declare -f pause_task_queue >/dev/null 2>&1; then
        pause_task_queue "critical_error"
    fi
    
    # Stop all monitoring
    if declare -f stop_all_monitoring >/dev/null 2>&1; then
        stop_all_monitoring
    fi
    
    # Notify user if possible
    echo "CRITICAL ERROR DETECTED - SYSTEM SHUTDOWN INITIATED" >&2
    echo "Error: $error_message" >&2
    echo "Emergency backup created if backup system was available" >&2
    
    # Exit with error
    exit 1
}

# Attempt automatic recovery
attempt_automatic_recovery() {
    local task_id="$1"
    local error_context="$2"
    
    log_info "Attempting automatic recovery for task $task_id"
    
    # Create recovery checkpoint
    if [[ -f "$SCRIPT_DIR/task-state-backup.sh" ]]; then
        source "$SCRIPT_DIR/task-state-backup.sh"
        if declare -f create_task_checkpoint >/dev/null 2>&1; then
            create_task_checkpoint "$task_id" "auto_recovery"
        fi
    fi
    
    # Try to restart task with clean session
    if [[ -f "$SCRIPT_DIR/session-recovery.sh" ]]; then
        source "$SCRIPT_DIR/session-recovery.sh"
        if declare -f recover_session_with_task_context >/dev/null 2>&1; then
            if recover_session_with_task_context "${MAIN_SESSION_ID:-}" "$task_id"; then
                log_info "Automatic recovery successful for task $task_id"
                return 0
            fi
        fi
    fi
    
    # Fallback: reschedule task
    schedule_task_retry "$task_id" "auto_recovery"
    return $?
}

# Escalate to manual recovery
escalate_to_manual_recovery() {
    local task_id="$1"
    local error_context="$2"
    local error_message="$3"
    
    log_warn "Escalating task $task_id to manual recovery"
    
    # Create detailed recovery report
    local recovery_report_file
    recovery_report_file=$(create_manual_recovery_report "$task_id" "$error_context" "$error_message")
    
    # Mark task as requiring manual intervention
    if [[ -f "$SCRIPT_DIR/task-queue.sh" ]]; then
        source "$SCRIPT_DIR/task-queue.sh"
        if declare -f update_task_status >/dev/null 2>&1; then
            update_task_status "$task_id" "failed" "manual_recovery_required"
        fi
    fi
    
    log_warn "Manual recovery required for task $task_id"
    log_warn "Recovery report created: $recovery_report_file"
    
    return 1  # Indicates manual intervention needed
}

# Schedule simple retry
schedule_simple_retry() {
    local task_id="$1"
    local error_context="$2"
    
    log_info "Scheduling simple retry for task $task_id"
    
    # Add retry delay if configured
    if [[ $ERROR_RETRY_DELAY -gt 0 ]]; then
        log_info "Waiting ${ERROR_RETRY_DELAY}s before retry"
        sleep "$ERROR_RETRY_DELAY"
    fi
    
    # Attempt to reschedule task
    if [[ -f "$SCRIPT_DIR/task-queue.sh" ]]; then
        source "$SCRIPT_DIR/task-queue.sh"
        if declare -f schedule_task_retry >/dev/null 2>&1; then
            schedule_task_retry "$task_id" "$error_context"
            return $?
        fi
    fi
    
    # Fallback: mark for retry
    log_info "Task $task_id scheduled for retry (fallback method)"
    return 0
}

# Fallback to safe mode
fallback_to_safe_mode() {
    local task_id="$1"
    local error_context="$2"
    
    log_warn "Falling back to safe mode for task $task_id"
    
    # Create safety checkpoint
    if [[ -f "$SCRIPT_DIR/task-state-backup.sh" ]]; then
        source "$SCRIPT_DIR/task-state-backup.sh"
        if declare -f create_task_checkpoint >/dev/null 2>&1; then
            create_task_checkpoint "$task_id" "safe_mode_fallback"
        fi
    fi
    
    # Pause processing for this task
    if [[ -f "$SCRIPT_DIR/task-queue.sh" ]]; then
        source "$SCRIPT_DIR/task-queue.sh"
        if declare -f pause_task >/dev/null 2>&1; then
            pause_task "$task_id" "safe_mode"
        elif declare -f update_task_status >/dev/null 2>&1; then
            update_task_status "$task_id" "failed" "safe_mode_fallback"
        fi
    fi
    
    log_warn "Task $task_id moved to safe mode - manual review recommended"
    return 0
}

# Handle timeout recovery
handle_timeout_recovery() {
    local task_id="$1"
    local error_context="$2"
    
    log_info "Handling timeout recovery for task $task_id"
    
    # Create timeout recovery checkpoint
    if [[ -f "$SCRIPT_DIR/task-state-backup.sh" ]]; then
        source "$SCRIPT_DIR/task-state-backup.sh"
        if declare -f create_task_checkpoint >/dev/null 2>&1; then
            create_task_checkpoint "$task_id" "timeout_recovery"
        fi
    fi
    
    # Try to restart with extended timeout
    local extended_timeout=$((${TASK_DEFAULT_TIMEOUT:-3600} * 2))  # Double the timeout
    
    if [[ -f "$SCRIPT_DIR/task-queue.sh" ]]; then
        source "$SCRIPT_DIR/task-queue.sh"
        if declare -f reschedule_task_with_timeout >/dev/null 2>&1; then
            reschedule_task_with_timeout "$task_id" "$extended_timeout"
            return $?
        fi
    fi
    
    # Fallback: regular retry
    schedule_simple_retry "$task_id" "timeout_recovery"
    return $?
}

# ===============================================================================
# RECOVERY REPORTING AND TRACKING
# ===============================================================================

# Create manual recovery report
create_manual_recovery_report() {
    local task_id="$1"
    local error_context="$2"
    local error_message="$3"
    
    local report_dir="$PROJECT_ROOT/logs/recovery-reports"
    mkdir -p "$report_dir" 2>/dev/null || report_dir="/tmp"
    
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local report_file="$report_dir/manual-recovery-${task_id}-${timestamp}.json"
    
    # Gather system state information
    local system_info
    system_info=$(cat << EOF
{
    "hostname": "$(hostname)",
    "timestamp": "$(date -Iseconds)",
    "pid": $$,
    "current_cycle": "${CURRENT_CYCLE:-0}",
    "session_id": "${MAIN_SESSION_ID:-unknown}"
}
EOF
)
    
    # Create comprehensive recovery report
    cat > "$report_file" << EOF
{
    "report_type": "manual_recovery",
    "task_id": "$task_id",
    "error_context": "$error_context",
    "error_message": "$error_message",
    "report_time": "$(date -Iseconds)",
    "system_info": $system_info,
    "recovery_attempts": ${RECOVERY_ATTEMPTS["${task_id}_automatic_recovery"]:-0},
    "error_history": $(get_task_error_history "$task_id"),
    "recommended_actions": [
        "Review task configuration and requirements",
        "Check system resources and dependencies",
        "Examine error logs for additional context",
        "Consider manual task execution with debugging",
        "Validate session and environment state"
    ]
}
EOF
    
    log_info "Manual recovery report created: $report_file"
    echo "$report_file"
}

# Get error history for specific task
get_task_error_history() {
    local task_id="$1"
    local history_json="[]"
    
    if ! has_command jq; then
        echo "$history_json"
        return 0
    fi
    
    # Collect error history entries for this task
    local entries=()
    for key in "${!ERROR_HISTORY[@]}"; do
        local value="${ERROR_HISTORY[$key]}"
        if echo "$value" | grep -q ":$task_id:"; then
            local timestamp="${key%%_*}"
            local severity="${value%%:*}"
            local rest="${value#*:}"
            local context="${rest%%:*}"
            local message="${rest#*:*:}"
            
            entries+=("{\"timestamp\": $timestamp, \"severity\": $severity, \"context\": \"$context\", \"message\": \"$(echo "$message" | sed 's/"/\\"/g')\"}")
        fi
    done
    
    # Format as JSON array
    if [[ ${#entries[@]} -gt 0 ]]; then
        history_json="[$(IFS=','; echo "${entries[*]}")]"
    fi
    
    echo "$history_json"
}

# ===============================================================================
# ERROR STATISTICS AND MONITORING
# ===============================================================================

# Get error classification statistics
get_error_statistics() {
    local critical_count=0
    local warning_count=0
    local info_count=0
    local unknown_count=0
    local total_count=0
    
    # Count errors by severity
    for key in "${!ERROR_COUNTS[@]}"; do
        local count="${ERROR_COUNTS[$key]}"
        total_count=$((total_count + count))
        
        case "${key%%_*}" in
            $ERROR_SEVERITY_CRITICAL)
                critical_count=$((critical_count + count))
                ;;
            $ERROR_SEVERITY_WARNING)
                warning_count=$((warning_count + count))
                ;;
            $ERROR_SEVERITY_INFO)
                info_count=$((info_count + count))
                ;;
            *)
                unknown_count=$((unknown_count + count))
                ;;
        esac
    done
    
    # Count recovery attempts
    local total_recovery_attempts=0
    for count in "${RECOVERY_ATTEMPTS[@]}"; do
        total_recovery_attempts=$((total_recovery_attempts + count))
    done
    
    cat << EOF
{
    "error_counts": {
        "critical": $critical_count,
        "warning": $warning_count,
        "info": $info_count,
        "unknown": $unknown_count,
        "total": $total_count
    },
    "recovery_attempts": $total_recovery_attempts,
    "configuration": {
        "handling_enabled": $ERROR_HANDLING_ENABLED,
        "auto_recovery": $ERROR_AUTO_RECOVERY,
        "max_retries": $ERROR_MAX_RETRIES,
        "retry_delay": $ERROR_RETRY_DELAY,
        "escalation_threshold": $ERROR_ESCALATION_THRESHOLD
    }
}
EOF
}

# ===============================================================================
# CLEANUP AND MAINTENANCE
# ===============================================================================

# Clean up old error tracking data
cleanup_error_tracking() {
    local retention_hours="${1:-168}"  # Default 1 week
    local cutoff_time=$(($(date +%s) - (retention_hours * 3600)))
    
    log_debug "Cleaning up error tracking data older than $retention_hours hours"
    
    # Clean up old history entries
    local cleanup_count=0
    for key in "${!ERROR_HISTORY[@]}"; do
        local timestamp="${key%%_*}"
        if [[ $timestamp -lt $cutoff_time ]]; then
            unset ERROR_HISTORY["$key"]
            ((cleanup_count++))
        fi
    done
    
    if [[ $cleanup_count -gt 0 ]]; then
        log_debug "Cleaned up $cleanup_count old error history entries"
    fi
    
    return 0
}

# Reset error classification statistics
reset_error_statistics() {
    log_info "Resetting error classification statistics"
    
    ERROR_HISTORY=()
    ERROR_COUNTS=()
    RECOVERY_ATTEMPTS=()
    
    log_info "Error statistics reset completed"
}

# ===============================================================================
# HELPER FUNCTIONS
# ===============================================================================

# Schedule task retry (fallback implementation)
schedule_task_retry() {
    local task_id="$1"
    local reason="$2"
    
    log_info "Scheduling retry for task $task_id (reason: $reason)"
    
    # This is a fallback - the actual implementation should be in task-queue.sh
    if [[ -f "$SCRIPT_DIR/task-queue.sh" ]]; then
        source "$SCRIPT_DIR/task-queue.sh"
        if declare -f retry_task >/dev/null 2>&1; then
            retry_task "$task_id"
            return $?
        fi
    fi
    
    log_warn "Task retry function not available - manual intervention may be required"
    return 1
}

# ===============================================================================
# MODULE INITIALIZATION
# ===============================================================================

# Auto-initialize if sourced
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    log_debug "Error classification and recovery strategy engine loaded"
fi