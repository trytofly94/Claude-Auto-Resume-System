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

# Enhanced usage limit detection for queue processing with time-specific handling
detect_usage_limit_in_queue() {
    local session_output="$1"
    local task_id="${2:-}"
    
    if [[ -z "$session_output" ]]; then
        return 1  # No output to check
    fi
    
    log_debug "Checking for usage limit patterns in session output"
    
    # First check for time-specific usage limits (pm/am patterns)
    local extracted_wait_time
    if extracted_wait_time=$(extract_usage_limit_time_from_output "$session_output"); then
        log_warn "Time-specific usage limit detected - blocked until specific time"
        record_usage_limit_occurrence "$task_id" "time_specific_limit"
        
        if [[ -n "$task_id" ]]; then
            create_usage_limit_checkpoint "$task_id"
        fi
        
        # Store the extracted wait time for use in pause calculation
        echo "WAIT_TIME=$extracted_wait_time" > "/tmp/usage-limit-wait-time.env"
        return 0
    fi
    
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
        "blocked until"
        "try again at"
        "available.*at"
        "retry at"
        "wait until"
    )
    
    local limit_detected=false
    local detected_pattern=""
    
    # Check for usage limit patterns
    for pattern in "${limit_patterns[@]}"; do
        if echo "$session_output" | grep -qi "$pattern"; then
            limit_detected=true
            detected_pattern="$pattern"
            break
        fi
    done
    
    if [[ "$limit_detected" == "true" ]]; then
        log_warn "Usage limit detected during queue processing (pattern: '$detected_pattern')"
        
        # Record usage limit occurrence
        record_usage_limit_occurrence "$task_id" "$detected_pattern"
        
        # Create usage limit checkpoint if task is active
        if [[ -n "$task_id" ]]; then
            create_usage_limit_checkpoint "$task_id"
        fi
        
        return 0  # Usage limit detected
    fi
    
    return 1  # No usage limit detected
}

# Record usage limit occurrence for tracking
record_usage_limit_occurrence() {
    local task_id="${1:-system}"
    local pattern="${2:-unknown}"
    local timestamp=$(date +%s)
    
    # Track usage limit history
    USAGE_LIMIT_HISTORY["$timestamp"]="$task_id:$pattern"
    
    # Increment counter for this task/pattern combination
    local key="${task_id}:${pattern}"
    USAGE_LIMIT_COUNTS["$key"]=$((${USAGE_LIMIT_COUNTS["$key"]:-0} + 1))
    
    log_debug "Usage limit occurrence recorded: $key (count: ${USAGE_LIMIT_COUNTS["$key"]})"
}

# Create usage limit checkpoint
create_usage_limit_checkpoint() {
    local task_id="$1"
    
    log_debug "Creating usage limit checkpoint for task $task_id"
    
    # Create checkpoint using backup system if available
    if [[ -f "$SCRIPT_DIR/task-state-backup.sh" ]]; then
        source "$SCRIPT_DIR/task-state-backup.sh"
        if declare -f create_task_checkpoint >/dev/null 2>&1; then
            create_task_checkpoint "$task_id" "usage_limit"
            return $?
        fi
    fi
    
    # Fallback: create simple checkpoint
    local task_queue_dir="${TASK_QUEUE_DIR:-queue}"
    local checkpoint_dir="$PROJECT_ROOT/$task_queue_dir/usage-limit-checkpoints"
    mkdir -p "$checkpoint_dir" 2>/dev/null || true
    
    if [[ -d "$checkpoint_dir" ]]; then
        local checkpoint_file="$checkpoint_dir/usage-limit-${task_id}-$(date +%s).json"
        cat > "$checkpoint_file" << EOF
{
    "task_id": "$task_id",
    "checkpoint_time": "$(date -Iseconds)",
    "checkpoint_reason": "usage_limit",
    "usage_limit_info": {
        "detection_time": $(date +%s),
        "occurrence_count": ${USAGE_LIMIT_COUNTS["$task_id:usage_limit"]:-1}
    }
}
EOF
        log_debug "Usage limit checkpoint created: $(basename "$checkpoint_file")"
    fi
    
    return 0
}

# ===============================================================================
# ENHANCED TIME-BASED USAGE LIMIT DETECTION
# ===============================================================================

# Extract specific wait time from usage limit messages
extract_usage_limit_time_from_output() {
    local output="$1"
    
    # Comprehensive time patterns for various formats
    local time_patterns=(
        # Standard am/pm formats
        "blocked until ([0-9]{1,2})(am|pm)"                      # "blocked until 3pm"
        "blocked until ([0-9]{1,2}):([0-9]{2})(am|pm)"           # "blocked until 3:30pm"
        "try again at ([0-9]{1,2})(am|pm)"                       # "try again at 9am"
        "try again at ([0-9]{1,2}):([0-9]{2})(am|pm)"            # "try again at 9:30am"
        "available.*at ([0-9]{1,2})(am|pm)"                      # "available tomorrow at 2pm"
        "available.*at ([0-9]{1,2}):([0-9]{2})(am|pm)"           # "available tomorrow at 2:30pm"
        "retry at ([0-9]{1,2})(am|pm)"                           # "retry at 4pm"
        "retry at ([0-9]{1,2}):([0-9]{2})(am|pm)"                # "retry at 4:30pm"
        "wait until ([0-9]{1,2})(am|pm)"                         # "wait until 5pm"
        "wait until ([0-9]{1,2}):([0-9]{2})(am|pm)"              # "wait until 5:30pm"
        "tomorrow at ([0-9]{1,2})(am|pm)"                        # "tomorrow at 8am"
        "tomorrow at ([0-9]{1,2}):([0-9]{2})(am|pm)"             # "tomorrow at 8:30am"
        
        # 24-hour formats
        "blocked until ([0-9]{1,2}):([0-9]{2})"                   # "blocked until 15:30"
        "try again at ([0-9]{1,2}):([0-9]{2})"                    # "try again at 21:00"
        "retry at ([0-9]{1,2}):([0-9]{2})"                        # "retry at 14:45"
        "wait until ([0-9]{1,2}):([0-9]{2})"                      # "wait until 20:15"
        
        # Natural language patterns
        "usage limit.*([0-9]{1,2})(am|pm)"                       # "usage limit exceeded, try 3pm"
        "please wait.*([0-9]{1,2})(am|pm)"                       # "please wait until 6pm"
        "limit exceeded.*([0-9]{1,2})(am|pm)"                    # "limit exceeded, retry at 7am"
    )
    
    log_debug "Analyzing output for time-specific usage limit patterns"
    
    # Check each pattern for matches
    for pattern in "${time_patterns[@]}"; do
        if echo "$output" | grep -qiE "$pattern"; then
            log_debug "Matched time pattern: $pattern"
            
            # Extract the time components
            local matched_line
            matched_line=$(echo "$output" | grep -iE "$pattern" | head -1)
            
            local wait_seconds
            if wait_seconds=$(calculate_wait_time_from_pattern "$matched_line" "$pattern"); then
                log_info "Successfully extracted wait time: ${wait_seconds}s from pattern match"
                echo "$wait_seconds"
                return 0
            else
                log_warn "Failed to calculate wait time from matched pattern: $pattern"
            fi
        fi
    done
    
    log_debug "No time-specific usage limit patterns found in output"
    return 1
}

# Calculate wait time in seconds from matched time pattern
calculate_wait_time_from_pattern() {
    local matched_text="$1"
    local pattern="$2"
    
    log_debug "Calculating wait time from: '$matched_text' (pattern: $pattern)"
    
    # Extract time components using various regex approaches
    local hour minute period is_24hour=false is_tomorrow=false
    
    # Check if it's a tomorrow reference
    if echo "$matched_text" | grep -qi "tomorrow"; then
        is_tomorrow=true
        log_debug "Tomorrow reference detected"
    fi
    
    # Extract hour, minute, and am/pm period
    if echo "$matched_text" | grep -qiE "([0-9]{1,2}):([0-9]{2})(am|pm)"; then
        # Format with minutes and am/pm: "3:30pm"
        hour=$(echo "$matched_text" | grep -oiE "([0-9]{1,2}):([0-9]{2})(am|pm)" | grep -oE "^[0-9]{1,2}")
        minute=$(echo "$matched_text" | grep -oiE "([0-9]{1,2}):([0-9]{2})(am|pm)" | grep -oE ":[0-9]{2}" | tr -d ':')
        period=$(echo "$matched_text" | grep -oiE "(am|pm)" | tr '[:upper:]' '[:lower:]')
    elif echo "$matched_text" | grep -qiE "([0-9]{1,2})(am|pm)"; then
        # Format without minutes and am/pm: "3pm"
        hour=$(echo "$matched_text" | grep -oiE "([0-9]{1,2})(am|pm)" | grep -oE "^[0-9]{1,2}")
        minute="00"
        period=$(echo "$matched_text" | grep -oiE "(am|pm)" | tr '[:upper:]' '[:lower:]')
    elif echo "$matched_text" | grep -qE "([0-9]{1,2}):([0-9]{2})" && ! echo "$matched_text" | grep -qiE "(am|pm)"; then
        # 24-hour format: "15:30"
        hour=$(echo "$matched_text" | grep -oE "([0-9]{1,2}):([0-9]{2})" | cut -d: -f1)
        minute=$(echo "$matched_text" | grep -oE "([0-9]{1,2}):([0-9]{2})" | cut -d: -f2)
        is_24hour=true
    else
        log_warn "Could not extract time components from: '$matched_text'"
        return 1
    fi
    
    # Validate extracted components
    if [[ ! "$hour" =~ ^[0-9]+$ ]] || [[ ! "$minute" =~ ^[0-9]+$ ]]; then
        log_warn "Invalid time components extracted: hour='$hour', minute='$minute'"
        return 1
    fi
    
    log_debug "Extracted time components: hour=$hour, minute=$minute, period=${period:-24h}, tomorrow=$is_tomorrow"
    
    # Convert to 24-hour format if needed
    local target_hour="$hour"
    if [[ "$is_24hour" == "false" ]]; then
        if [[ "$period" == "pm" && "$hour" != "12" ]]; then
            target_hour=$((hour + 12))
        elif [[ "$period" == "am" && "$hour" == "12" ]]; then
            target_hour="0"
        fi
    fi
    
    # Validate final hour
    if [[ $target_hour -gt 23 || $target_hour -lt 0 ]]; then
        log_warn "Invalid target hour: $target_hour"
        return 1
    fi
    
    # Calculate target timestamp
    local current_time=$(date +%s)
    local current_date
    local target_date
    
    if [[ "$is_tomorrow" == "true" ]]; then
        # Tomorrow at specified time
        target_date=$(date -d "tomorrow" +%Y-%m-%d 2>/dev/null || date -v+1d +%Y-%m-%d 2>/dev/null)
    else
        # Today at specified time (but check if it's already past)
        target_date=$(date +%Y-%m-%d)
        
        # Create target timestamp for today
        local today_target_time
        if has_command date && date -d "$target_date $target_hour:$minute:00" "+%s" >/dev/null 2>&1; then
            today_target_time=$(date -d "$target_date $target_hour:$minute:00" +%s)
        elif date -j -f "%Y-%m-%d %H:%M:%S" "$target_date $target_hour:$minute:00" "+%s" >/dev/null 2>&1; then
            today_target_time=$(date -j -f "%Y-%m-%d %H:%M:%S" "$target_date $target_hour:$minute:00" "+%s")
        else
            log_warn "Could not create target timestamp for today"
            return 1
        fi
        
        # If the time has already passed today, assume tomorrow
        if [[ $today_target_time -le $current_time ]]; then
            log_debug "Target time has passed today, assuming tomorrow"
            target_date=$(date -d "tomorrow" +%Y-%m-%d 2>/dev/null || date -v+1d +%Y-%m-%d 2>/dev/null)
            is_tomorrow=true
        fi
    fi
    
    # Create final target timestamp
    local target_timestamp
    if has_command date && date -d "$target_date $target_hour:$minute:00" "+%s" >/dev/null 2>&1; then
        target_timestamp=$(date -d "$target_date $target_hour:$minute:00" +%s)
    elif date -j -f "%Y-%m-%d %H:%M:%S" "$target_date $target_hour:$minute:00" "+%s" >/dev/null 2>&1; then
        target_timestamp=$(date -j -f "%Y-%m-%d %H:%M:%S" "$target_date $target_hour:$minute:00" "+%s")
    else
        log_error "Could not create final target timestamp"
        return 1
    fi
    
    # Calculate wait time in seconds
    local wait_seconds=$((target_timestamp - current_time))
    
    # Ensure positive wait time
    if [[ $wait_seconds -le 0 ]]; then
        log_warn "Calculated wait time is negative or zero: ${wait_seconds}s - using minimum wait"
        wait_seconds=300  # 5 minutes minimum
    fi
    
    # Log the calculation details
    local target_datetime
    if has_command date; then
        if date -d "@$target_timestamp" "+%Y-%m-%d %H:%M:%S" >/dev/null 2>&1; then
            target_datetime=$(date -d "@$target_timestamp" "+%Y-%m-%d %H:%M:%S")
        elif date -r "$target_timestamp" "+%Y-%m-%d %H:%M:%S" >/dev/null 2>&1; then
            target_datetime=$(date -r "$target_timestamp" "+%Y-%m-%d %H:%M:%S")
        else
            target_datetime="unknown"
        fi
    else
        target_datetime="unknown"
    fi
    
    log_info "Wait time calculation: target=$target_datetime, wait_time=${wait_seconds}s ($(($wait_seconds/60))m)"
    
    echo "$wait_seconds"
    return 0
}

# Enhanced countdown display with better progress indicators
display_enhanced_usage_limit_countdown() {
    local total_wait_time="$1"
    local reason="${2:-usage limit}"
    local start_time=$(date +%s)
    local end_time=$((start_time + total_wait_time))
    
    log_info "Starting enhanced usage limit countdown display (reason: $reason)"
    
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
        
        # Calculate progress percentage
        local elapsed=$((current_time - start_time))
        local progress_percent=$(( (elapsed * 100) / total_wait_time ))
        
        # Create progress bar
        local bar_length=20
        local filled_length=$(( (progress_percent * bar_length) / 100 ))
        local bar=""
        for ((i=0; i<bar_length; i++)); do
            if [[ $i -lt $filled_length ]]; then
                bar+="▓"
            else
                bar+="░"
            fi
        done
        
        # Display enhanced countdown with progress bar
        printf "\r[USAGE LIMIT] %s [%s] %d%% - Resuming in: %s" "$reason" "$bar" "$progress_percent" "$time_display"
        
        sleep 5  # Update every 5 seconds for better responsiveness
    done
    
    printf "\r[USAGE LIMIT] Wait period completed - resuming operations%*s\n" 50 ""
}

# ===============================================================================
# USAGE LIMIT RESPONSE AND QUEUE MANAGEMENT
# ===============================================================================

# Pause queue for usage limit with intelligent wait calculation
pause_queue_for_usage_limit() {
    local estimated_wait_time="${1:-}"
    local current_task_id="${2:-}"
    local detected_pattern="${3:-usage_limit}"
    
    # Check for time-specific wait time from detection
    local time_specific_wait=""
    if [[ -f "/tmp/usage-limit-wait-time.env" ]]; then
        source "/tmp/usage-limit-wait-time.env" 2>/dev/null || true
        time_specific_wait="$WAIT_TIME"
        rm -f "/tmp/usage-limit-wait-time.env"
    fi
    
    # Use time-specific wait if available, otherwise calculate intelligent wait time
    if [[ -n "$time_specific_wait" && "$time_specific_wait" =~ ^[0-9]+$ ]]; then
        estimated_wait_time="$time_specific_wait"
        detected_pattern="time_specific_limit"
        log_info "Using time-specific wait period: ${estimated_wait_time}s (extracted from pm/am pattern)"
    elif [[ -z "$estimated_wait_time" ]]; then
        estimated_wait_time=$(calculate_usage_limit_wait_time "$current_task_id" "$detected_pattern")
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
    
    # Start enhanced countdown display in background if terminal is available
    if [[ -t 1 ]]; then
        display_enhanced_usage_limit_countdown "$estimated_wait_time" "$detected_pattern" &
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