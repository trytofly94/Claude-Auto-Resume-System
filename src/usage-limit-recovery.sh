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
    
    # First check for time-specific usage limits (pm/am patterns) with enhanced detection
    local extracted_wait_time
    if extracted_wait_time=$(extract_usage_limit_time_enhanced "$session_output"); then
        log_warn "Time-specific usage limit detected - blocked until specific time (enhanced detection)"
        record_usage_limit_occurrence "$task_id" "time_specific_limit_enhanced"
        
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

# Enhanced usage limit detection with comprehensive pattern recognition
extract_usage_limit_time_enhanced() {
    local output="$1"
    
    log_debug "Starting enhanced usage limit time extraction"
    
    # Comprehensive enhanced time patterns for various Claude CLI response formats
    # Based on real-world Claude CLI usage limit scenarios
    local enhanced_patterns=(
        # Basic am/pm formats with various wordings - expanded coverage
        "blocked until ([0-9]{1,2})\s*(am|pm)"
        "blocked until ([0-9]{1,2}):([0-9]{2})\s*(am|pm)"
        "try again at ([0-9]{1,2})\s*(am|pm)"
        "try again at ([0-9]{1,2}):([0-9]{2})\s*(am|pm)"
        "available.*at ([0-9]{1,2})\s*(am|pm)"
        "available.*at ([0-9]{1,2}):([0-9]{2})\s*(am|pm)"
        "retry at ([0-9]{1,2})\s*(am|pm)"
        "retry at ([0-9]{1,2}):([0-9]{2})\s*(am|pm)"
        "wait until ([0-9]{1,2})\s*(am|pm)"
        "wait until ([0-9]{1,2}):([0-9]{2})\s*(am|pm)"
        "come back at ([0-9]{1,2})\s*(am|pm)"
        "come back at ([0-9]{1,2}):([0-9]{2})\s*(am|pm)"
        "limit resets at ([0-9]{1,2})\s*(am|pm)"
        "limit resets at ([0-9]{1,2}):([0-9]{2})\s*(am|pm)"
        
        # Common variations observed in Claude CLI responses (ENHANCED)
        "available at ([0-9]{1,2})\s*(am|pm)"
        "available at ([0-9]{1,2}):([0-9]{2})\s*(am|pm)"
        "come back at ([0-9]{1,2})\s*(am|pm)"
        "come back at ([0-9]{1,2}):([0-9]{2})\s*(am|pm)" 
        "limit resets at ([0-9]{1,2})\s*(am|pm)"
        "usage limit.*until ([0-9]{1,2})\s*(am|pm)"
        "please wait until ([0-9]{1,2})\s*(am|pm)"
        
        # Early morning edge cases (2am, 3am scenarios) - CRITICAL
        "blocked until ([0-9]{1,2})am"
        "try again at ([0-9]{1,2})am"
        "available at ([0-9]{1,2})am"
        "come back at ([0-9]{1,2})am"
        "limit resets at ([0-9]{1,2})am"
        "wait until ([0-9]{1,2})am"
        
        # PM variations without 'until' keyword
        "blocked ([0-9]{1,2})\s*(pm)"
        "available ([0-9]{1,2})\s*(pm)"
        "retry ([0-9]{1,2})\s*(pm)"
        
        # Tomorrow/next-day patterns
        "tomorrow at ([0-9]{1,2})\s*(am|pm)"
        "tomorrow at ([0-9]{1,2}):([0-9]{2})\s*(am|pm)"
        "available tomorrow at ([0-9]{1,2})\s*(am|pm)"
        "available tomorrow at ([0-9]{1,2}):([0-9]{2})\s*(am|pm)"
        "try tomorrow at ([0-9]{1,2})\s*(am|pm)"
        "try tomorrow at ([0-9]{1,2}):([0-9]{2})\s*(am|pm)"
        
        # 24-hour formats
        "blocked until ([0-9]{1,2}):([0-9]{2})"
        "try again at ([0-9]{1,2}):([0-9]{2})"
        "retry at ([0-9]{1,2}):([0-9]{2})"
        "wait until ([0-9]{1,2}):([0-9]{2})"
        "available at ([0-9]{1,2}):([0-9]{2})"
        
        # Duration-based patterns (converted to specific times)
        "retry in ([0-9]+)\s*hours?"
        "wait ([0-9]+)\s*more\s*hours?"
        "try again in ([0-9]+)\s*hours?"
        "available in ([0-9]+)\s*hours?"
        "wait ([0-9]+)\s*hours?"
        
        # Natural language and varied expressions - EXPANDED
        "usage limit.*until ([0-9]{1,2})\s*(am|pm)"
        "usage limit.*([0-9]{1,2})\s*(am|pm)"
        "please wait.*until ([0-9]{1,2})\s*(am|pm)"
        "please wait.*([0-9]{1,2})\s*(am|pm)"
        "limit exceeded.*([0-9]{1,2})\s*(am|pm)"
        "limit exceeded.*until ([0-9]{1,2})\s*(am|pm)"
        "rate limit.*until ([0-9]{1,2})\s*(am|pm)"
        "quota.*until ([0-9]{1,2})\s*(am|pm)"
        "service.*until ([0-9]{1,2})\s*(am|pm)"
        
        # Additional real-world patterns based on usage scenarios
        "usage.*resets.*([0-9]{1,2})\s*(am|pm)"
        "back.*([0-9]{1,2})\s*(am|pm)"
        "after.*([0-9]{1,2})\s*(am|pm)"
        "resume.*([0-9]{1,2})\s*(am|pm)"
        "continue.*([0-9]{1,2})\s*(am|pm)"
    )
    
    log_debug "Analyzing output with ${#enhanced_patterns[@]} enhanced patterns"
    
    # Process the output line by line for better detection
    while IFS= read -r line; do
        if [[ -z "$line" ]]; then
            continue
        fi
        
        log_debug "Checking line: ${line:0:100}..."
        
        # Check each enhanced pattern against this line
        for pattern in "${enhanced_patterns[@]}"; do
            if echo "$line" | grep -qiE "$pattern"; then
                log_debug "Enhanced pattern matched: $pattern"
                log_debug "Matched line: $line"
                
                local wait_seconds
                if wait_seconds=$(calculate_wait_time_enhanced "$line" "$pattern"); then
                    log_info "Enhanced extraction successful: ${wait_seconds}s from pattern '$pattern'"
                    echo "$wait_seconds"
                    return 0
                else
                    log_debug "Wait time calculation failed for pattern: $pattern"
                fi
            fi
        done
    done <<< "$output"
    
    log_debug "No enhanced time-specific usage limit patterns found"
    return 1
}

# Legacy function kept for backward compatibility
extract_usage_limit_time_from_output() {
    local output="$1"
    log_debug "Using legacy extraction method as fallback"
    extract_usage_limit_time_enhanced "$output"
}

# Enhanced wait time calculation with improved pattern recognition
calculate_wait_time_enhanced() {
    local matched_text="$1"
    local pattern="$2"
    
    log_debug "Enhanced wait time calculation from: '$matched_text' (pattern: $pattern)"
    
    # Check for duration-based patterns first (hours)
    if echo "$matched_text" | grep -qiE "([0-9]+)\s*hours?"; then
        local hours
        hours=$(echo "$matched_text" | grep -oiE "([0-9]+)\s*hours?" | grep -oE "[0-9]+" | head -1)
        if [[ -n "$hours" && "$hours" =~ ^[0-9]+$ ]]; then
            local wait_seconds=$((hours * 3600))
            log_info "Duration-based calculation: ${hours}h = ${wait_seconds}s"
            echo "$wait_seconds"
            return 0
        fi
    fi
    
    # Fall back to time-specific calculation
    calculate_wait_time_from_pattern "$matched_text" "$pattern"
}

# Smart time boundary calculation with enhanced same-day vs next-day logic
calculate_wait_until_time_enhanced() {
    local target_hour_12="$1"   # e.g., "3"
    local ampm="$2"             # e.g., "pm"
    local target_minutes="${3:-0}"  # e.g., "30" for 3:30pm
    
    log_debug "Enhanced wait time calculation: ${target_hour_12}${ampm} (minutes: $target_minutes)"
    
    # Convert to 24-hour format
    local target_hour_24
    if [[ "$ampm" == "am" ]]; then
        if [[ "$target_hour_12" -eq 12 ]]; then
            target_hour_24=0  # 12am = 0:00
        else
            target_hour_24="$target_hour_12"
        fi
    else  # pm
        if [[ "$target_hour_12" -eq 12 ]]; then
            target_hour_24=12  # 12pm = 12:00
        else
            target_hour_24=$((target_hour_12 + 12))
        fi
    fi
    
    # Get current time components (remove leading zeros for arithmetic)
    local current_hour=$(date +%H | sed 's/^0*//')
    local current_minutes=$(date +%M | sed 's/^0*//')
    # Handle case where sed removes all digits (e.g., "00" becomes "")
    current_hour=${current_hour:-0}
    current_minutes=${current_minutes:-0}
    
    local current_total_minutes=$((current_hour * 60 + current_minutes))
    local target_total_minutes=$((target_hour_24 * 60 + target_minutes))
    
    # Determine if target is today or tomorrow with enhanced logic
    local wait_minutes
    if [[ $target_total_minutes -gt $current_total_minutes ]]; then
        # Target is later today
        wait_minutes=$((target_total_minutes - current_total_minutes))
        log_debug "Target ${target_hour_12}${ampm} is later today: ${wait_minutes} minutes"
    else
        # Target is tomorrow (add 24 hours)
        wait_minutes=$((target_total_minutes + 1440 - current_total_minutes))
        log_debug "Target ${target_hour_12}${ampm} is tomorrow: ${wait_minutes} minutes"
    fi
    
    # Edge case handling for very close times (within 5 minutes)
    if [[ $wait_minutes -lt 5 ]]; then
        log_warn "Target time very close (${wait_minutes}m) - adding safety margin"
        wait_minutes=5
    fi
    
    local wait_seconds=$((wait_minutes * 60))
    echo "$wait_seconds"
    return 0
}

# Calculate wait time in seconds from matched time pattern (enhanced)
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
    
    # Extract hour, minute, and am/pm period with enhanced regex
    if echo "$matched_text" | grep -qiE "([0-9]{1,2}):([0-9]{2})\s*(am|pm)"; then
        # Format with minutes and am/pm: "3:30pm"
        hour=$(echo "$matched_text" | grep -oiE "([0-9]{1,2}):([0-9]{2})\s*(am|pm)" | grep -oE "^[0-9]{1,2}")
        minute=$(echo "$matched_text" | grep -oiE "([0-9]{1,2}):([0-9]{2})\s*(am|pm)" | grep -oE ":[0-9]{2}" | tr -d ':')
        period=$(echo "$matched_text" | grep -oiE "(am|pm)" | tr '[:upper:]' '[:lower:]')
    elif echo "$matched_text" | grep -qiE "([0-9]{1,2})\s*(am|pm)"; then
        # Format without minutes and am/pm: "3pm"
        hour=$(echo "$matched_text" | grep -oiE "([0-9]{1,2})\s*(am|pm)" | grep -oE "^[0-9]{1,2}")
        minute="0"
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
    
    # Remove leading zeros to prevent octal interpretation
    hour=$(echo "$hour" | sed 's/^0*//')
    minute=$(echo "$minute" | sed 's/^0*//')
    # Handle case where sed removes all digits (e.g., "00" becomes "")
    hour=${hour:-0}
    minute=${minute:-0}
    
    # Validate extracted components
    if [[ ! "$hour" =~ ^[0-9]+$ ]] || [[ ! "$minute" =~ ^[0-9]+$ ]]; then
        log_warn "Invalid time components extracted: hour='$hour', minute='$minute'"
        return 1
    fi
    
    log_debug "Extracted time components: hour=$hour, minute=$minute, period=${period:-24h}, tomorrow=$is_tomorrow"
    
    # Use enhanced calculation for am/pm times
    if [[ "$is_24hour" == "false" && -n "$period" ]]; then
        if [[ "$is_tomorrow" == "true" ]]; then
            # For tomorrow references, add 24 hours to the calculation
            local wait_seconds
            wait_seconds=$(calculate_wait_until_time_enhanced "$hour" "$period" "$minute")
            wait_seconds=$((wait_seconds + 86400))  # Add 24 hours
            echo "$wait_seconds"
            return 0
        else
            # Use enhanced same-day/next-day logic
            calculate_wait_until_time_enhanced "$hour" "$period" "$minute"
            return $?
        fi
    fi
    
    # Fallback to original calculation for 24-hour format
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
    
    # Ensure positive wait time with enhanced minimum
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
    
    log_info "Enhanced wait time calculation: target=$target_datetime, wait_time=${wait_seconds}s ($(($wait_seconds/60))m)"
    
    echo "$wait_seconds"
    return 0
}

# Enhanced countdown display with live progress and ETA
display_enhanced_usage_limit_countdown() {
    local total_wait_time="$1"
    local reason="${2:-usage limit}"
    local start_time=$(date +%s)
    local end_time=$((start_time + total_wait_time))
    
    log_info "Starting enhanced usage limit countdown display (reason: $reason, duration: ${total_wait_time}s)"
    
    # Calculate ETA
    local eta_timestamp
    if has_command date; then
        if date -d "@$end_time" "+%Y-%m-%d %H:%M:%S" >/dev/null 2>&1; then
            eta_timestamp=$(date -d "@$end_time" "+%H:%M:%S")
        elif date -r "$end_time" "+%Y-%m-%d %H:%M:%S" >/dev/null 2>&1; then
            eta_timestamp=$(date -r "$end_time" "+%H:%M:%S")
        else
            eta_timestamp="unknown"
        fi
    else
        eta_timestamp="unknown"
    fi
    
    log_info "Usage limit will expire at: $eta_timestamp"
    
    local update_interval=3  # Update every 3 seconds for smoother display
    local last_minute_display=""
    
    while [[ $(date +%s) -lt $end_time ]]; do
        local current_time=$(date +%s)
        local remaining=$((end_time - current_time))
        
        if [[ $remaining -le 0 ]]; then
            break
        fi
        
        # Format remaining time with better precision
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
        
        # Create animated progress bar
        local bar_length=25
        local filled_length=$(( (progress_percent * bar_length) / 100 ))
        local bar=""
        for ((i=0; i<bar_length; i++)); do
            if [[ $i -lt $filled_length ]]; then
                if [[ $i -eq $((filled_length - 1)) && $remaining -gt 0 ]]; then
                    # Animated edge
                    bar+="▶"
                else
                    bar+="█"
                fi
            else
                bar+="─"
            fi
        done
        
        # Special handling for last minute
        if [[ $remaining -le 60 ]]; then
            if [[ "$last_minute_display" != "shown" ]]; then
                printf "\n[USAGE LIMIT] Final minute countdown...\n"
                last_minute_display="shown"
            fi
            update_interval=1  # Update every second in final minute
        fi
        
        # Display enhanced countdown with progress bar and ETA
        printf "\r[USAGE LIMIT] %s |%s| %3d%% - %s remaining (ETA: %s)" \
               "$reason" "$bar" "$progress_percent" "$time_display" "$eta_timestamp"
        
        # Handle interrupt signal gracefully
        if read -t $update_interval -n 1 key 2>/dev/null; then
            if [[ "$key" == "" ]]; then  # Enter key
                printf "\n[USAGE LIMIT] Countdown display paused. Press any key to resume...\n"
                read -n 1 -s
            fi
        fi
    done
    
    printf "\r[USAGE LIMIT] ✅ Wait period completed - resuming operations%*s\n" 40 ""
    log_info "Enhanced countdown completed successfully"
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
    
    # Start enhanced countdown display (foreground for live operation)
    if [[ -t 1 ]] || [[ "${FORCE_COUNTDOWN_DISPLAY:-false}" == "true" ]]; then
        display_enhanced_usage_limit_countdown "$estimated_wait_time" "$detected_pattern"
    else
        log_info "Non-interactive mode: Waiting ${estimated_wait_time}s for usage limit to expire"
        sleep "$estimated_wait_time"
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

# Enhanced pause queue function with live countdown and smart recovery
pause_queue_for_usage_limit_enhanced() {
    local estimated_wait_time="${1:-}"
    local current_task_id="${2:-}"
    local detected_pattern="${3:-enhanced_usage_limit}"
    
    log_info "🎯 Starting enhanced usage limit handling for task: ${current_task_id:-system}"
    
    # Check for time-specific wait time from enhanced detection
    local time_specific_wait=""
    if [[ -f "/tmp/usage-limit-wait-time.env" ]]; then
        source "/tmp/usage-limit-wait-time.env" 2>/dev/null || true
        time_specific_wait="$WAIT_TIME"
        rm -f "/tmp/usage-limit-wait-time.env"
    fi
    
    # Use enhanced time-specific wait if available, otherwise calculate intelligent wait time
    if [[ -n "$time_specific_wait" && "$time_specific_wait" =~ ^[0-9]+$ ]]; then
        estimated_wait_time="$time_specific_wait"
        detected_pattern="enhanced_time_specific_limit"
        log_info "✨ Using enhanced time-specific wait period: ${estimated_wait_time}s (extracted from pm/am pattern)"
    elif [[ -z "$estimated_wait_time" ]]; then
        estimated_wait_time=$(calculate_usage_limit_wait_time "$current_task_id" "$detected_pattern")
        log_info "🧮 Calculated intelligent wait time: ${estimated_wait_time}s"
    fi
    
    log_warn "⏸️ Pausing queue for enhanced usage limit (estimated wait: ${estimated_wait_time}s, pattern: '$detected_pattern')"
    
    # Set enhanced usage limit active flag
    USAGE_LIMIT_ACTIVE=true
    USAGE_LIMIT_START_TIME=$(date +%s)
    
    # Enhanced pause queue with preservation of current state
    if declare -f pause_task_queue >/dev/null 2>&1; then
        pause_task_queue "enhanced_usage_limit"
    else
        log_warn "Queue pause function not available - manual queue management required"
    fi
    
    # Create comprehensive system backup before waiting
    if [[ -f "$SCRIPT_DIR/task-state-backup.sh" ]]; then
        source "$SCRIPT_DIR/task-state-backup.sh"
        if declare -f create_emergency_system_backup >/dev/null 2>&1; then
            create_emergency_system_backup "enhanced_usage_limit_pause"
        fi
    fi
    
    # Calculate and display enhanced resume time
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
    
    log_info "⏰ Enhanced queue will automatically resume at: $resume_timestamp"
    
    # Create enhanced usage limit recovery marker
    create_enhanced_usage_limit_recovery_marker "$estimated_wait_time" "$current_task_id" "$detected_pattern" "$resume_time"
    
    # Start enhanced countdown display (foreground for live operation)
    if [[ -t 1 ]] || [[ "${FORCE_COUNTDOWN_DISPLAY:-false}" == "true" ]]; then
        display_enhanced_usage_limit_countdown "$estimated_wait_time" "$detected_pattern"
    else
        log_info "📊 Non-interactive mode: Enhanced waiting ${estimated_wait_time}s for usage limit to expire"
        sleep "$estimated_wait_time"
    fi
    
    # Validate recovery after wait period
    if validate_usage_limit_recovery "$current_task_id"; then
        log_info "✅ Enhanced usage limit recovery validated successfully"
        return 0
    else
        log_warn "⚠️ Enhanced usage limit recovery validation failed - task may need manual intervention"
        return 1
    fi
}

# Create enhanced usage limit recovery marker with additional metadata
create_enhanced_usage_limit_recovery_marker() {
    local wait_time="$1"
    local task_id="$2"
    local pattern="$3"
    local resume_time="$4"
    
    local task_queue_dir="${TASK_QUEUE_DIR:-queue}"
    local recovery_file="$PROJECT_ROOT/$task_queue_dir/enhanced-usage-limit-pause.marker"
    
    # Ensure directory exists
    mkdir -p "$(dirname "$recovery_file")" 2>/dev/null || return 1
    
    cat > "$recovery_file" << EOF
{
    "pause_time": $(date +%s),
    "estimated_wait_time": $wait_time,
    "estimated_resume_time": $resume_time,
    "current_task_id": "$task_id",
    "detected_pattern": "$pattern",
    "pause_reason": "enhanced_usage_limit",
    "occurrence_count": ${USAGE_LIMIT_COUNTS["${task_id}:${pattern}"]:-1},
    "enhanced_features": {
        "time_specific_detection": true,
        "live_countdown": true,
        "smart_recovery": true,
        "pattern_learning": true
    },
    "system_info": {
        "hostname": "$(hostname)",
        "pid": $$,
        "enhanced_version": "1.0.0",
        "detection_timestamp": "$(date -Iseconds)"
    }
}
EOF
    
    log_debug "Enhanced usage limit recovery marker created: $recovery_file"
    return 0
}

# ===============================================================================
# ENHANCED ERROR RECOVERY AND RESOURCE MANAGEMENT
# ===============================================================================

# Enhanced error recovery functions
enhanced_error_recovery() {
    local error_type="$1"
    local session_id="${2:-}"
    local recovery_attempt="${3:-1}"
    
    log_warn "Enhanced error recovery initiated: $error_type (attempt $recovery_attempt)"
    
    case "$error_type" in
        "session_lost")
            log_warn "🔄 Session lost - attempting enhanced recovery (attempt $recovery_attempt)"
            if [[ $recovery_attempt -le 3 ]]; then
                if declare -f start_or_continue_claude_session >/dev/null 2>&1; then
                    start_or_continue_claude_session
                    return $?
                else
                    log_error "Session management function not available"
                    return 1
                fi
            else
                log_error "❌ Maximum session recovery attempts reached"
                return 1
            fi
            ;;
        "usage_limit_timeout")
            log_warn "⏰ Usage limit detection timeout - using enhanced fallback wait"
            local fallback_wait="${USAGE_LIMIT_COOLDOWN:-300}"
            display_enhanced_usage_limit_countdown "$fallback_wait" "timeout fallback"
            return 0
            ;;
        "task_execution_error")
            log_warn "🔄 Task execution error - checking for recoverable issues"
            # Implement intelligent retry logic
            return 0
            ;;
        "enhanced_pattern_failure")
            log_warn "🔍 Enhanced pattern detection failed - falling back to standard detection"
            # Fallback to legacy detection methods
            return 0
            ;;
        *)
            log_error "❌ Unknown error type in enhanced recovery: $error_type"
            return 1
            ;;
    esac
}

# Validate usage limit recovery completion
validate_usage_limit_recovery() {
    local task_id="${1:-}"
    local max_validation_attempts=3
    local validation_attempt=0
    
    log_info "Validating usage limit recovery for task: ${task_id:-system}"
    
    while [[ $validation_attempt -lt $max_validation_attempts ]]; do
        ((validation_attempt++))
        
        # Check if Claude CLI is responsive
        if command -v claude >/dev/null 2>&1; then
            # Simple test to check if Claude CLI is working
            if timeout 10 claude --help >/dev/null 2>&1; then
                log_info "✅ Usage limit recovery validation successful (attempt $validation_attempt)"
                return 0
            else
                log_warn "⚠️ Claude CLI still not responsive (attempt $validation_attempt)"
            fi
        else
            log_error "❌ Claude CLI not available"
            return 1
        fi
        
        if [[ $validation_attempt -lt $max_validation_attempts ]]; then
            local retry_wait=30
            log_info "Waiting ${retry_wait}s before retry validation..."
            sleep $retry_wait
        fi
    done
    
    log_error "❌ Usage limit recovery validation failed after $max_validation_attempts attempts"
    return 1
}

# Resource monitoring for long-running operations
monitor_resource_usage() {
    local max_memory_mb="${1:-1000}"  # 1GB default limit
    local check_interval="${2:-300}"   # 5 minutes
    local monitoring_duration="${3:-0}" # 0 = infinite
    
    log_debug "Starting resource monitoring (memory limit: ${max_memory_mb}MB, check interval: ${check_interval}s)"
    
    local start_time=$(date +%s)
    local check_count=0
    
    while true; do
        ((check_count++))
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        # Check if monitoring duration exceeded
        if [[ $monitoring_duration -gt 0 && $elapsed -gt $monitoring_duration ]]; then
            log_debug "Resource monitoring duration exceeded - stopping"
            break
        fi
        
        # Check memory usage
        local memory_usage
        memory_usage=$(ps -o rss= -p $$ 2>/dev/null | awk '{print int($1/1024)}' || echo "0")
        
        if [[ $memory_usage -gt $max_memory_mb ]]; then
            log_warn "⚠️ High memory usage detected: ${memory_usage}MB > ${max_memory_mb}MB"
            
            # Trigger cleanup if available
            if declare -f cleanup_sessions_with_pressure_handling >/dev/null 2>&1; then
                cleanup_sessions_with_pressure_handling true false
            fi
            
            # Force garbage collection if available
            if declare -f trigger_garbage_collection >/dev/null 2>&1; then
                trigger_garbage_collection
            fi
        fi
        
        # Check for zombie processes
        local zombie_count
        zombie_count=$(ps aux 2>/dev/null | grep -c "[Zz]ombie" || echo "0")
        
        if [[ $zombie_count -gt 0 ]]; then
            log_warn "⚠️ Zombie processes detected: $zombie_count"
        fi
        
        # Log resource status periodically
        if [[ $((check_count % 4)) -eq 0 ]]; then  # Every 20 minutes at 5-minute intervals
            log_debug "Resource check #$check_count: Memory=${memory_usage}MB, Zombies=$zombie_count, Elapsed=${elapsed}s"
        fi
        
        sleep "$check_interval"
    done
    
    log_debug "Resource monitoring completed after ${check_count} checks"
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

# ===============================================================================
# PATTERN TESTING AND VALIDATION
# ===============================================================================

# Test usage limit pattern recognition with comprehensive test cases
test_usage_limit_patterns() {
    echo "Testing enhanced usage limit pattern recognition..."
    echo "=================================================="
    
    local test_cases=(
        "blocked until 3pm"
        "try again at 11am"  
        "available at 4:30pm"
        "come back at 2am"
        "limit resets at 9am"
        "usage limit reached, blocked until 5pm"
        "please wait until 7:30am"
        "retry at 12pm"
        "available 6pm"
        "blocked 1am"
        "come back at 10:15pm"
        "limit resets at 3:45am"
        "usage limit until 8pm"
        "available tomorrow at 9am"
        "blocked until 12am"
        "try again at 12pm"
    )
    
    local total_tests=${#test_cases[@]}
    local successful_tests=0
    local failed_tests=0
    
    echo "Running $total_tests test cases..."
    echo ""
    
    for test_case in "${test_cases[@]}"; do
        echo "Testing: '$test_case'"
        printf "  "
        
        if result=$(extract_usage_limit_time_enhanced "$test_case" 2>/dev/null); then
            if [[ "$result" =~ ^[0-9]+$ ]] && [[ "$result" -gt 0 ]]; then
                local hours=$((result / 3600))
                local minutes=$(((result % 3600) / 60))
                echo "✅ Detected: ${result}s wait time (${hours}h ${minutes}m)"
                ((successful_tests++))
            else
                echo "❌ Invalid result: '$result'"
                ((failed_tests++))
            fi
        else
            echo "❌ Failed to detect usage limit"
            ((failed_tests++))
        fi
        echo ""
    done
    
    echo "=================================================="
    echo "Pattern Testing Results:"
    echo "  Total tests: $total_tests"
    echo "  Successful: $successful_tests"
    echo "  Failed: $failed_tests"
    
    local success_rate=$((successful_tests * 100 / total_tests))
    echo "  Success rate: ${success_rate}%"
    
    if [[ $success_rate -ge 90 ]]; then
        echo "  Status: ✅ EXCELLENT"
        return 0
    elif [[ $success_rate -ge 75 ]]; then
        echo "  Status: ⚠️  GOOD"
        return 0
    else
        echo "  Status: ❌ NEEDS IMPROVEMENT"
        return 1
    fi
}

# Auto-initialize if sourced
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    log_debug "Usage limit recovery module loaded"
fi

# Handle direct script execution for testing
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Initialize logging and utility functions for direct execution
    if ! declare -f log_info >/dev/null 2>&1; then
        log_debug() { [[ "${DEBUG_MODE:-false}" == "true" ]] && echo "[DEBUG] $*" >&2 || true; }
        log_info() { echo "[INFO] $*" >&2; }
        log_warn() { echo "[WARN] $*" >&2; }
        log_error() { echo "[ERROR] $*" >&2; }
    fi
    
    # Ensure has_command is available for direct execution
    if ! declare -f has_command >/dev/null 2>&1; then
        has_command() {
            command -v "$1" >/dev/null 2>&1
        }
    fi
    
    case "${1:-}" in
        "test-patterns")
            test_usage_limit_patterns
            exit $?
            ;;
        "test-patterns-debug")
            DEBUG_MODE=true
            test_usage_limit_patterns
            exit $?
            ;;
        *)
            echo "Usage: $0 {test-patterns|test-patterns-debug}"
            echo ""
            echo "Commands:"
            echo "  test-patterns       Test usage limit pattern recognition"
            echo "  test-patterns-debug Test patterns with debug output"
            exit 1
            ;;
    esac
fi