#!/usr/bin/env bash

# Claude Auto-Resume - Usage Limit Recovery System
# Enhanced Usage Limit Detection and Queue Management
# Version: 1.0.0-alpha
# Created: 2025-08-27

set -euo pipefail

# ===============================================================================
# GLOBALE VARIABLEN UND KONSTANTEN
# ===============================================================================

# Standard-Konfiguration (wird von config/default.conf überschrieben)
USAGE_LIMIT_COOLDOWN="${USAGE_LIMIT_COOLDOWN:-300}"         # 5 minutes default
BACKOFF_FACTOR="${BACKOFF_FACTOR:-1.5}"                     # Exponential backoff multiplier
MAX_WAIT_TIME="${MAX_WAIT_TIME:-1800}"                       # 30 minutes max
USAGE_LIMIT_THRESHOLD="${USAGE_LIMIT_THRESHOLD:-3}"          # Consecutive limits before extended backoff

# Usage limit tracking
declare -A USAGE_LIMIT_HISTORY
declare -A USAGE_LIMIT_COUNTS
USAGE_LIMIT_ACTIVE=false
USAGE_LIMIT_START_TIME=0

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
# USAGE LIMIT DETECTION
# ===============================================================================

# Enhanced usage limit detection with precise time parsing
detect_usage_limit_in_queue() {
    local session_output="$1"
    local task_id="${2:-}"
    
    if [[ -z "$session_output" ]]; then
        return 1  # No output to check
    fi
    
    log_debug "Checking for usage limit patterns in session output"
    
    # Enhanced usage limit patterns with case-insensitive matching
    local limit_patterns=(
        "usage limit"
        "rate limit"
        "too many requests"
        "please try again later"
        "request limit exceeded"
        "quota exceeded"
        "temporarily unavailable"
        "service temporarily overloaded"
        "daily usage limit"
        "hourly rate limit"
        "api quota exceeded"
    )
    
    # Specific time-based patterns for precise detection
    local time_based_patterns=(
        "blocked until [0-9]{1,2}:[0-9]{2} *[ap]m"
        "try again at [0-9]{1,2}:[0-9]{2} *[ap]m"
        "available again at [0-9]{1,2}:[0-9]{2} *[ap]m"
        "wait until [0-9]{1,2}:[0-9]{2} *[ap]m"
        "retry at [0-9]{1,2}:[0-9]{2} *[ap]m"
        "blocked until [0-9]{1,2}:[0-9]{2}"
        "available at [0-9]{1,2}:[0-9]{2}"
    )
    
    local limit_detected=false
    local detected_pattern=""
    local extracted_time=""
    local wait_seconds=0
    
    # Check for time-based patterns first (higher priority)
    for pattern in "${time_based_patterns[@]}"; do
        if echo "$session_output" | grep -qiE "$pattern"; then
            limit_detected=true
            detected_pattern="time_based:$pattern"
            
            # Extract the time from the output
            extracted_time=$(echo "$session_output" | grep -ioE "([0-9]{1,2}:[0-9]{2} *[ap]m|[0-9]{1,2}:[0-9]{2})" | head -1 | tr -d ' ')
            
            # Calculate precise wait time
            if [[ -n "$extracted_time" ]]; then
                wait_seconds=$(calculate_precise_wait_time "$extracted_time")
                log_info "Detected time-based usage limit: available at $extracted_time (wait: ${wait_seconds}s)"
            fi
            break
        fi
    done
    
    # If no time-based pattern, check generic patterns
    if [[ "$limit_detected" == "false" ]]; then
        for pattern in "${limit_patterns[@]}"; do
            if echo "$session_output" | grep -qi "$pattern"; then
                limit_detected=true
                detected_pattern="generic:$pattern"
                break
            fi
        done
    fi
    
    if [[ "$limit_detected" == "true" ]]; then
        log_warn "Usage limit detected during queue processing (pattern: '$detected_pattern')"
        
        # Record usage limit occurrence with enhanced data
        record_usage_limit_occurrence "$task_id" "$detected_pattern" "$extracted_time" "$wait_seconds"
        
        # Create usage limit checkpoint if task is active
        if [[ -n "$task_id" ]]; then
            create_usage_limit_checkpoint "$task_id" "$extracted_time" "$wait_seconds"
        fi
        
        # Store extracted wait time for use by calling functions
        export DETECTED_USAGE_LIMIT_WAIT_SECONDS="$wait_seconds"
        export DETECTED_USAGE_LIMIT_TIME="$extracted_time"
        
        return 0  # Usage limit detected
    fi
    
    return 1  # No usage limit detected
}

# Calculate precise wait time from extracted time string
calculate_precise_wait_time() {
    local time_string="$1"
    
    if [[ -z "$time_string" ]]; then
        log_debug "No time string provided, returning default cooldown"
        echo "$USAGE_LIMIT_COOLDOWN"
        return
    fi
    
    log_debug "Calculating precise wait time for: '$time_string'"
    
    # Current time
    local current_epoch=$(date +%s)
    local current_hour=$(date +%H)
    local current_minute=$(date +%M)
    local current_seconds=$((current_hour * 3600 + current_minute * 60))
    
    # Parse the time string
    local target_hour target_minute target_seconds target_epoch
    
    # Handle 12-hour format (with AM/PM)
    if [[ "$time_string" =~ ^([0-9]{1,2}):([0-9]{2})[ap]m$ ]]; then
        target_hour=${BASH_REMATCH[1]}
        target_minute=${BASH_REMATCH[2]}
        
        # Convert to 24-hour format
        if [[ "$time_string" =~ pm$ ]] && [[ $target_hour -ne 12 ]]; then
            target_hour=$((target_hour + 12))
        elif [[ "$time_string" =~ am$ ]] && [[ $target_hour -eq 12 ]]; then
            target_hour=0
        fi
        
    # Handle 24-hour format
    elif [[ "$time_string" =~ ^([0-9]{1,2}):([0-9]{2})$ ]]; then
        target_hour=${BASH_REMATCH[1]}
        target_minute=${BASH_REMATCH[2]}
        
    else
        log_warn "Unable to parse time format '$time_string', using default cooldown"
        echo "$USAGE_LIMIT_COOLDOWN"
        return
    fi
    
    # Convert to seconds since midnight
    target_seconds=$((target_hour * 3600 + target_minute * 60))
    
    # Calculate wait time
    local wait_seconds
    if [[ $target_seconds -gt $current_seconds ]]; then
        # Target time is later today
        wait_seconds=$((target_seconds - current_seconds))
    else
        # Target time is tomorrow
        wait_seconds=$((86400 - current_seconds + target_seconds))
    fi
    
    # Add small buffer (30 seconds) to avoid exact timing issues
    wait_seconds=$((wait_seconds + 30))
    
    # Ensure minimum and maximum bounds
    if [[ $wait_seconds -lt 60 ]]; then
        wait_seconds=60  # Minimum 1 minute
    elif [[ $wait_seconds -gt $MAX_WAIT_TIME ]]; then
        wait_seconds=$MAX_WAIT_TIME
    fi
    
    log_debug "Calculated wait time: ${wait_seconds}s (target: $target_hour:$(printf "%02d" $target_minute), current: $current_hour:$(printf "%02d" $current_minute))"
    echo "$wait_seconds"
}

# Record usage limit occurrence for tracking
record_usage_limit_occurrence() {
    local task_id="${1:-system}"
    local pattern="${2:-unknown}"
    local extracted_time="${3:-}"
    local wait_seconds="${4:-0}"
    local timestamp=$(date +%s)
    
    # Enhanced tracking with time information
    local history_entry="$task_id:$pattern"
    if [[ -n "$extracted_time" ]]; then
        history_entry="$history_entry:$extracted_time:$wait_seconds"
    fi
    
    # Track usage limit history
    USAGE_LIMIT_HISTORY["$timestamp"]="$history_entry"
    
    # Increment counter for this task/pattern combination
    local key="${task_id}:${pattern}"
    USAGE_LIMIT_COUNTS["$key"]=$((${USAGE_LIMIT_COUNTS["$key"]:-0} + 1))
    
    if [[ -n "$extracted_time" ]]; then
        log_debug "Usage limit occurrence recorded: $key (count: ${USAGE_LIMIT_COUNTS["$key"]}, available at: $extracted_time, wait: ${wait_seconds}s)"
    else
        log_debug "Usage limit occurrence recorded: $key (count: ${USAGE_LIMIT_COUNTS["$key"]})"
    fi
}

# Create usage limit checkpoint
create_usage_limit_checkpoint() {
    local task_id="$1"
    local extracted_time="${2:-}"
    local wait_seconds="${3:-0}"
    
    log_debug "Creating usage limit checkpoint for task $task_id (available at: $extracted_time, wait: ${wait_seconds}s)"
    
    # Create checkpoint using backup system if available
    if [[ -f "$SCRIPT_DIR/task-state-backup.sh" ]]; then
        source "$SCRIPT_DIR/task-state-backup.sh"
        if declare -f create_task_checkpoint >/dev/null 2>&1; then
            create_task_checkpoint "$task_id" "usage_limit" "$extracted_time" "$wait_seconds"
            return $?
        fi
    fi
    
    # Fallback: create simple checkpoint
    local task_queue_dir="${TASK_QUEUE_DIR:-queue}"
    local checkpoint_dir="$PROJECT_ROOT/$task_queue_dir/usage-limit-checkpoints"
    mkdir -p "$checkpoint_dir" 2>/dev/null || true
    
    if [[ -d "$checkpoint_dir" ]]; then
        local checkpoint_file="$checkpoint_dir/usage-limit-${task_id}-$(date +%s).json"
        
        # Calculate resume time
        local resume_time=$(($(date +%s) + wait_seconds))
        
        cat > "$checkpoint_file" << EOF
{
    "task_id": "$task_id",
    "checkpoint_time": "$(date -Iseconds)",
    "checkpoint_reason": "usage_limit",
    "usage_limit_info": {
        "detection_time": $(date +%s),
        "extracted_time": "$extracted_time",
        "wait_seconds": $wait_seconds,
        "estimated_resume_time": $resume_time,
        "resume_time_iso": "$(date -d "@$resume_time" -Iseconds 2>/dev/null || date -r "$resume_time" -Iseconds 2>/dev/null || echo "unknown")",
        "occurrence_count": ${USAGE_LIMIT_COUNTS["$task_id:usage_limit"]:-1}
    }
}
EOF
        log_debug "Usage limit checkpoint created: $(basename "$checkpoint_file")"
    fi
    
    return 0
}

# ===============================================================================
# USAGE LIMIT RESPONSE AND QUEUE MANAGEMENT
# ===============================================================================

# Pause queue for usage limit with intelligent wait calculation
pause_queue_for_usage_limit() {
    local estimated_wait_time="${1:-}"
    local current_task_id="${2:-}"
    local detected_pattern="${3:-usage_limit}"
    local extracted_time="${4:-}"
    
    # Use precise wait time from detection if available, otherwise calculate
    if [[ -z "$estimated_wait_time" ]] && [[ -n "${DETECTED_USAGE_LIMIT_WAIT_SECONDS:-}" ]]; then
        estimated_wait_time="$DETECTED_USAGE_LIMIT_WAIT_SECONDS"
        log_info "Using precise wait time from detection: ${estimated_wait_time}s"
    elif [[ -z "$estimated_wait_time" ]]; then
        estimated_wait_time=$(calculate_usage_limit_wait_time "$current_task_id" "$detected_pattern")
        log_info "Calculated fallback wait time: ${estimated_wait_time}s"
    fi
    
    log_warn "Pausing queue for usage limit (estimated wait: ${estimated_wait_time}s, pattern: '$detected_pattern')"
    
    # Set usage limit active flag
    USAGE_LIMIT_ACTIVE=true
    USAGE_LIMIT_START_TIME=$(date +%s)
    
    # Pause queue with preservation of current state
    if declare -f pause_task_queue >/dev/null 2>&1; then
        pause_task_queue "usage_limit"
    else
        log_warn "Queue pause function not available - manual queue management required"
    fi
    
    # Create comprehensive system backup before waiting
    if [[ -f "$SCRIPT_DIR/task-state-backup.sh" ]]; then
        source "$SCRIPT_DIR/task-state-backup.sh"
        if declare -f create_emergency_system_backup >/dev/null 2>&1; then
            create_emergency_system_backup "usage_limit_pause"
        fi
    fi
    
    # Calculate and display resume time
    local resume_time=$(($(date +%s) + estimated_wait_time))
    local resume_timestamp
    
    if has_command date; then
        if date -d "@$resume_time" "+%Y-%m-%d %H:%M:%S" >/dev/null 2>&1; then
            resume_timestamp=$(date -d "@$resume_time" "+%Y-%m-%d %H:%M:%S")
        elif date -r "$resume_time" "+%Y-%m-%d %H:%M:%S" >/dev/null 2>&1; then
            resume_timestamp=$(date -r "$resume_time" "+%Y-%m-%d %H:%M:%S")
        else
            resume_timestamp="unknown"
        fi
    else
        resume_timestamp="unknown"
    fi
    
    log_info "Queue will automatically resume at: $resume_timestamp"
    
    # Create usage limit recovery marker
    create_usage_limit_recovery_marker "$estimated_wait_time" "$current_task_id" "$detected_pattern" "$resume_time"
    
    # Start countdown display in background if terminal is available
    if [[ -t 1 ]]; then
        display_usage_limit_countdown "$estimated_wait_time" &
        local countdown_pid=$!
        echo "$countdown_pid" > "/tmp/usage-limit-countdown.pid" 2>/dev/null || true
    fi
    
    return 0
}

# Calculate intelligent wait time based on usage limit history
calculate_usage_limit_wait_time() {
    local task_id="${1:-system}"
    local pattern="${2:-usage_limit}"
    
    # Get occurrence count for this pattern
    local occurrence_count=${USAGE_LIMIT_COUNTS["${task_id}:${pattern}"]:-1}
    
    # Base wait time
    local wait_time=$USAGE_LIMIT_COOLDOWN
    
    # Apply exponential backoff if multiple occurrences
    if [[ $occurrence_count -gt 1 ]]; then
        # Calculate backoff multiplier
        local backoff_multiplier
        if has_command bc; then
            backoff_multiplier=$(echo "scale=2; $BACKOFF_FACTOR^($occurrence_count-1)" | bc 2>/dev/null || echo "1")
        else
            # Fallback without bc
            backoff_multiplier=1
            for ((i=1; i<occurrence_count; i++)); do
                backoff_multiplier=$(( (backoff_multiplier * 15) / 10 ))  # Approximate 1.5x
            done
        fi
        
        # Apply backoff
        if [[ "$backoff_multiplier" =~ ^[0-9.]+$ ]]; then
            wait_time=$(( (wait_time * ${backoff_multiplier%.*}) ))
        fi
    fi
    
    # Cap at maximum wait time
    if [[ $wait_time -gt $MAX_WAIT_TIME ]]; then
        wait_time=$MAX_WAIT_TIME
    fi
    
    # Ensure minimum wait time
    if [[ $wait_time -lt 60 ]]; then
        wait_time=60  # Minimum 1 minute
    fi
    
    log_debug "Calculated usage limit wait time: ${wait_time}s (occurrences: $occurrence_count, backoff applied: $([[ $occurrence_count -gt 1 ]] && echo "yes" || echo "no"))"
    
    echo "$wait_time"
}

# Create usage limit recovery marker
create_usage_limit_recovery_marker() {
    local wait_time="$1"
    local task_id="$2"
    local pattern="$3"
    local resume_time="$4"
    
    local task_queue_dir="${TASK_QUEUE_DIR:-queue}"
    local recovery_file="$PROJECT_ROOT/$task_queue_dir/usage-limit-pause.marker"
    
    # Ensure directory exists
    mkdir -p "$(dirname "$recovery_file")" 2>/dev/null || return 1
    
    cat > "$recovery_file" << EOF
{
    "pause_time": $(date +%s),
    "estimated_wait_time": $wait_time,
    "estimated_resume_time": $resume_time,
    "current_task_id": "$task_id",
    "detected_pattern": "$pattern",
    "pause_reason": "usage_limit",
    "occurrence_count": ${USAGE_LIMIT_COUNTS["${task_id}:${pattern}"]:-1},
    "system_info": {
        "hostname": "$(hostname)",
        "pid": $$
    }
}
EOF
    
    log_debug "Usage limit recovery marker created: $recovery_file"
    return 0
}

# Display usage limit countdown
display_usage_limit_countdown() {
    local total_wait_time="$1"
    local start_time=$(date +%s)
    local end_time=$((start_time + total_wait_time))
    
    log_info "Starting usage limit countdown display"
    
    while [[ $(date +%s) -lt $end_time ]]; do
        local current_time=$(date +%s)
        local remaining=$((end_time - current_time))
        
        if [[ $remaining -le 0 ]]; then
            break
        fi
        
        # Format remaining time
        local hours=$((remaining / 3600))
        local minutes=$(( (remaining % 3600) / 60 ))
        local seconds=$((remaining % 60))
        
        local time_display=""
        if [[ $hours -gt 0 ]]; then
            time_display="${hours}h ${minutes}m ${seconds}s"
        elif [[ $minutes -gt 0 ]]; then
            time_display="${minutes}m ${seconds}s"
        else
            time_display="${seconds}s"
        fi
        
        # Display countdown (overwrite previous line)
        printf "\r[USAGE LIMIT] Resuming in: %s" "$time_display"
        
        sleep 10  # Update every 10 seconds
    done
    
    printf "\r[USAGE LIMIT] Wait period completed - resuming operations\n"
}

# ===============================================================================
# QUEUE RESUME OPERATIONS
# ===============================================================================

# Resume queue after usage limit
resume_queue_after_limit() {
    local task_queue_dir="${TASK_QUEUE_DIR:-queue}"
    local recovery_file="$PROJECT_ROOT/$task_queue_dir/usage-limit-pause.marker"
    
    if [[ ! -f "$recovery_file" ]]; then
        log_warn "No usage limit recovery marker found - queue may not have been paused for usage limit"
        return 1
    fi
    
    log_info "Resuming queue after usage limit"
    
    # Stop countdown display if running
    local countdown_pid_file="/tmp/usage-limit-countdown.pid"
    if [[ -f "$countdown_pid_file" ]]; then
        local countdown_pid
        countdown_pid=$(cat "$countdown_pid_file" 2>/dev/null || true)
        if [[ -n "$countdown_pid" ]] && kill -0 "$countdown_pid" 2>/dev/null; then
            kill -TERM "$countdown_pid" 2>/dev/null || true
        fi
        rm -f "$countdown_pid_file"
    fi
    
    # Resume queue processing
    if declare -f resume_task_queue >/dev/null 2>&1; then
        resume_task_queue "usage_limit_recovery"
    else
        log_warn "Queue resume function not available - manual queue management required"
    fi
    
    # Clean up recovery marker
    rm -f "$recovery_file"
    
    # Reset usage limit state
    USAGE_LIMIT_ACTIVE=false
    USAGE_LIMIT_START_TIME=0
    
    log_info "Queue successfully resumed after usage limit"
    return 0
}

# Check if usage limit wait period is complete
is_usage_limit_wait_complete() {
    local task_queue_dir="${TASK_QUEUE_DIR:-queue}"
    local recovery_file="$PROJECT_ROOT/$task_queue_dir/usage-limit-pause.marker"
    
    if [[ ! -f "$recovery_file" ]]; then
        return 0  # No active usage limit
    fi
    
    if ! has_command jq; then
        # Fallback: assume wait is complete after some time
        local pause_time
        pause_time=$(grep '"pause_time"' "$recovery_file" 2>/dev/null | grep -o '[0-9]*' | head -1 || echo "0")
        local current_time=$(date +%s)
        local elapsed=$((current_time - pause_time))
        
        [[ $elapsed -gt $USAGE_LIMIT_COOLDOWN ]]
        return $?
    fi
    
    # Extract resume time from recovery file
    local resume_time
    resume_time=$(jq -r '.estimated_resume_time // 0' "$recovery_file" 2>/dev/null || echo "0")
    
    local current_time=$(date +%s)
    
    # Check if current time is past resume time
    [[ $current_time -gt $resume_time ]]
}

# Auto-resume queue if wait period is complete
auto_resume_queue_if_ready() {
    if is_usage_limit_wait_complete; then
        log_info "Usage limit wait period complete - auto-resuming queue"
        resume_queue_after_limit
        return $?
    fi
    
    return 1  # Wait period not complete
}

# ===============================================================================
# USAGE LIMIT STATISTICS AND MONITORING
# ===============================================================================

# Get usage limit statistics
get_usage_limit_statistics() {
    local total_occurrences=0
    local unique_patterns=0
    local current_status="inactive"
    
    # Count total occurrences
    for count in "${USAGE_LIMIT_COUNTS[@]}"; do
        total_occurrences=$((total_occurrences + count))
    done
    
    # Count unique patterns
    unique_patterns=${#USAGE_LIMIT_COUNTS[@]}
    
    # Determine current status
    if [[ "$USAGE_LIMIT_ACTIVE" == "true" ]]; then
        current_status="active"
    fi
    
    # Calculate time since last occurrence
    local last_occurrence=0
    for timestamp in "${!USAGE_LIMIT_HISTORY[@]}"; do
        if [[ $timestamp -gt $last_occurrence ]]; then
            last_occurrence=$timestamp
        fi
    done
    
    local time_since_last=0
    if [[ $last_occurrence -gt 0 ]]; then
        time_since_last=$(($(date +%s) - last_occurrence))
    fi
    
    cat << EOF
{
    "current_status": "$current_status",
    "total_occurrences": $total_occurrences,
    "unique_patterns": $unique_patterns,
    "last_occurrence": $last_occurrence,
    "time_since_last": $time_since_last,
    "usage_limit_active": $USAGE_LIMIT_ACTIVE,
    "usage_limit_start_time": $USAGE_LIMIT_START_TIME,
    "configuration": {
        "cooldown": $USAGE_LIMIT_COOLDOWN,
        "backoff_factor": $BACKOFF_FACTOR,
        "max_wait_time": $MAX_WAIT_TIME,
        "threshold": $USAGE_LIMIT_THRESHOLD
    }
}
EOF
}

# Get recent usage limit history
get_recent_usage_limit_history() {
    local hours_back="${1:-24}"  # Default last 24 hours
    local cutoff_time=$(($(date +%s) - (hours_back * 3600)))
    
    echo "["
    local first=true
    
    for timestamp in $(printf '%s\n' "${!USAGE_LIMIT_HISTORY[@]}" | sort -n); do
        if [[ $timestamp -gt $cutoff_time ]]; then
            if [[ "$first" != "true" ]]; then
                echo ","
            fi
            first=false
            
            local info="${USAGE_LIMIT_HISTORY[$timestamp]}"
            local task_id="${info%:*}"
            local pattern="${info#*:}"
            
            echo -n "    {"
            echo -n "\"timestamp\": $timestamp, "
            echo -n "\"task_id\": \"$task_id\", "
            echo -n "\"pattern\": \"$pattern\", "
            echo -n "\"datetime\": \"$(date -d "@$timestamp" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || date -r "$timestamp" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "unknown")\""
            echo -n "}"
        fi
    done
    
    echo ""
    echo "]"
}

# ===============================================================================
# CLEANUP AND MAINTENANCE
# ===============================================================================

# Clean up usage limit tracking data
cleanup_usage_limit_tracking() {
    local retention_hours="${1:-168}"  # Default 1 week
    local cutoff_time=$(($(date +%s) - (retention_hours * 3600)))
    
    log_debug "Cleaning up usage limit tracking data older than $retention_hours hours"
    
    # Clean up old history entries
    local cleanup_count=0
    for timestamp in "${!USAGE_LIMIT_HISTORY[@]}"; do
        if [[ $timestamp -lt $cutoff_time ]]; then
            unset "USAGE_LIMIT_HISTORY[$timestamp]"
            ((cleanup_count++))
        fi
    done
    
    if [[ $cleanup_count -gt 0 ]]; then
        log_debug "Cleaned up $cleanup_count old usage limit history entries"
    fi
    
    # Clean up temporary files
    rm -f "/tmp/usage-limit-countdown.pid" 2>/dev/null || true
    
    return 0
}

# Reset usage limit statistics
reset_usage_limit_statistics() {
    log_info "Resetting usage limit statistics"
    
    USAGE_LIMIT_HISTORY=()
    USAGE_LIMIT_COUNTS=()
    USAGE_LIMIT_ACTIVE=false
    USAGE_LIMIT_START_TIME=0
    
    # Clean up marker files
    local task_queue_dir="${TASK_QUEUE_DIR:-queue}"
    rm -f "$PROJECT_ROOT/$task_queue_dir/usage-limit-pause.marker" 2>/dev/null || true
    
    log_info "Usage limit statistics reset completed"
}

# ===============================================================================
# MODULE INITIALIZATION AND SIGNAL HANDLING
# ===============================================================================

# Handle script termination signals
usage_limit_signal_handler() {
    local signal="$1"
    log_info "Usage limit recovery system received signal $signal - cleaning up"
    
    # Stop countdown display if running
    local countdown_pid_file="/tmp/usage-limit-countdown.pid"
    if [[ -f "$countdown_pid_file" ]]; then
        local countdown_pid
        countdown_pid=$(cat "$countdown_pid_file" 2>/dev/null || true)
        if [[ -n "$countdown_pid" ]] && kill -0 "$countdown_pid" 2>/dev/null; then
            kill -TERM "$countdown_pid" 2>/dev/null || true
        fi
        rm -f "$countdown_pid_file"
    fi
    
    cleanup_usage_limit_tracking
    exit 0
}

# Set up signal handlers
trap 'usage_limit_signal_handler TERM' TERM
trap 'usage_limit_signal_handler INT' INT
trap 'usage_limit_signal_handler EXIT' EXIT

# ===============================================================================
# MODULE INITIALIZATION
# ===============================================================================

# Auto-initialize if sourced
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    log_debug "Usage limit recovery module loaded"
fi