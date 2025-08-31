#!/usr/bin/env bash

# Claude Auto-Resume - Task Queue Monitoring Module
# Real-time monitoring and health checking for task queue
# Version: 2.0.0-refactored

set -euo pipefail

# ===============================================================================
# MONITORING CONSTANTS
# ===============================================================================

MONITOR_UPDATE_INTERVAL="${MONITOR_UPDATE_INTERVAL:-5}"
MONITOR_LOG_FILE="${TASK_QUEUE_DIR:-queue}/logs/monitor.log"
MONITOR_HEALTH_THRESHOLD_FAILED="${MONITOR_HEALTH_THRESHOLD_FAILED:-10}"
MONITOR_HEALTH_THRESHOLD_TIMEOUT="${MONITOR_HEALTH_THRESHOLD_TIMEOUT:-5}"

# Health status constants
readonly HEALTH_GOOD="good"
readonly HEALTH_WARNING="warning"
readonly HEALTH_CRITICAL="critical"

# ===============================================================================
# MONITORING CORE FUNCTIONS
# ===============================================================================

# Start continuous monitoring daemon
start_monitoring_daemon() {
    local duration="${1:-0}"  # 0 = infinite
    local update_interval="${2:-$MONITOR_UPDATE_INTERVAL}"
    local debug_mode="${3:-false}"
    
    log_info "Starting monitoring daemon (duration: ${duration}s, interval: ${update_interval}s)"
    
    if [[ "$debug_mode" == "true" ]]; then
        log_info "DEBUG: Starting monitoring daemon with debug mode enabled"
        log_info "DEBUG: Duration: ${duration}s, Interval: ${update_interval}s"
    fi
    
    # Ensure monitor log directory exists
    ensure_monitor_log_directory
    
    local start_time=$(date +%s)
    local end_time=$((start_time + duration))
    local update_count=0
    
    # Set up signal handlers for clean shutdown
    trap 'stop_monitoring_daemon' EXIT INT TERM
    
    while true; do
        ((update_count++))
        local current_time=$(date +%s)
        
        # Check if we should stop (duration-based)
        if [[ $duration -gt 0 ]] && [[ $current_time -ge $end_time ]]; then
            log_info "Monitoring duration expired, stopping daemon"
            break
        fi
        
        # Perform monitoring update
        if [[ "$debug_mode" == "true" ]]; then
            log_info "DEBUG: Starting update #$update_count"
        fi
        
        perform_monitoring_update "$update_count" "$debug_mode"
        
        # Sleep until next update
        sleep "$update_interval"
    done
    
    stop_monitoring_daemon
}

# Perform single monitoring update
perform_monitoring_update() {
    local update_number="$1"
    local debug_mode="${2:-false}"
    
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Collect monitoring data
    local queue_stats
    queue_stats=$(get_queue_stats)
    
    local health_status
    health_status=$(get_queue_health_status)
    
    local system_metrics
    system_metrics=$(get_system_metrics)
    
    # Create monitoring snapshot
    local monitoring_data
    monitoring_data=$(jq -n \
        --arg timestamp "$timestamp" \
        --arg update_number "$update_number" \
        --argjson queue_stats "$queue_stats" \
        --argjson health_status "$health_status" \
        --argjson system_metrics "$system_metrics" \
        '{
            timestamp: $timestamp,
            update_number: ($update_number | tonumber),
            queue_stats: $queue_stats,
            health_status: $health_status,
            system_metrics: $system_metrics
        }')
    
    # Log monitoring data
    log_monitoring_data "$monitoring_data"
    
    # Check for alerts
    check_monitoring_alerts "$monitoring_data"
    
    # Display monitoring update (if running in foreground)
    if [[ "$debug_mode" == "true" ]]; then
        log_info "DEBUG: About to check terminal and display update"
    fi
    
    # Use safe terminal detection with fallback
    if terminal_is_interactive_safe; then
        display_monitoring_update_safe "$monitoring_data" "$debug_mode"
    elif [[ "$debug_mode" == "true" ]]; then
        log_info "DEBUG: Terminal not interactive, skipping display"
    fi
}

# Stop monitoring daemon
stop_monitoring_daemon() {
    log_info "Stopping monitoring daemon"
    
    # Cleanup any monitoring-specific resources
    cleanup_monitoring_resources
}

# ===============================================================================
# HEALTH STATUS MONITORING
# ===============================================================================

# Get overall queue health status
get_queue_health_status() {
    local stats
    stats=$(get_queue_stats)
    
    local failed_count
    failed_count=$(echo "$stats" | jq -r '.failed')
    
    local timeout_count
    timeout_count=$(echo "$stats" | jq -r '.timeout')
    
    local total_count
    total_count=$(echo "$stats" | jq -r '.total')
    
    # Determine health status
    local health_level="$HEALTH_GOOD"
    local health_message="Queue operating normally"
    local health_issues=()
    
    if [[ $failed_count -ge $MONITOR_HEALTH_THRESHOLD_FAILED ]]; then
        health_level="$HEALTH_CRITICAL"
        health_issues+=("High number of failed tasks: $failed_count")
    elif [[ $failed_count -gt 0 ]]; then
        health_level="$HEALTH_WARNING"
        health_issues+=("Some failed tasks detected: $failed_count")
    fi
    
    if [[ $timeout_count -ge $MONITOR_HEALTH_THRESHOLD_TIMEOUT ]]; then
        health_level="$HEALTH_CRITICAL"
        health_issues+=("High number of timeout tasks: $timeout_count")
    elif [[ $timeout_count -gt 0 ]]; then
        health_level="$HEALTH_WARNING"
        health_issues+=("Some timeout tasks detected: $timeout_count")
    fi
    
    # Check queue file health
    if ! validate_queue_file >/dev/null 2>&1; then
        health_level="$HEALTH_CRITICAL"
        health_issues+=("Queue file validation failed")
    fi
    
    # Check lock health
    local stale_locks
    stale_locks=$(check_stale_locks_count)
    
    if [[ $stale_locks -gt 0 ]]; then
        health_level="$HEALTH_WARNING"
        health_issues+=("Stale locks detected: $stale_locks")
    fi
    
    # Set health message based on issues
    if [[ ${#health_issues[@]} -gt 0 ]]; then
        health_message=$(IFS='; '; echo "${health_issues[*]}")
    fi
    
    # Return health status as JSON
    jq -n \
        --arg level "$health_level" \
        --arg message "$health_message" \
        --argjson failed "$failed_count" \
        --argjson timeout "$timeout_count" \
        --argjson total "$total_count" \
        --argjson stale_locks "$stale_locks" \
        '{
            level: $level,
            message: $message,
            metrics: {
                failed_tasks: $failed,
                timeout_tasks: $timeout,
                total_tasks: $total,
                stale_locks: $stale_locks
            }
        }'
}

# Check for stale locks
check_stale_locks_count() {
    ensure_lock_directory >/dev/null 2>&1
    
    local stale_count=0
    
    for lock_file in "$QUEUE_LOCK_DIR"/*.lock; do
        if [[ -f "$lock_file" ]] && is_lock_stale "$lock_file"; then
            ((stale_count++))
        fi
    done
    
    echo "$stale_count"
}

# ===============================================================================
# SYSTEM METRICS
# ===============================================================================

# Get system metrics relevant to queue monitoring
get_system_metrics() {
    local disk_usage
    disk_usage=$(get_disk_usage_percent "${TASK_QUEUE_DIR:-queue}")
    
    local memory_usage
    memory_usage=$(get_memory_usage_percent)
    
    local cpu_load
    cpu_load=$(get_cpu_load_average)
    
    local process_count
    process_count=$(get_queue_process_count)
    
    jq -n \
        --argjson disk_usage "$disk_usage" \
        --argjson memory_usage "$memory_usage" \
        --arg cpu_load "$cpu_load" \
        --argjson process_count "$process_count" \
        '{
            disk_usage_percent: $disk_usage,
            memory_usage_percent: $memory_usage, 
            cpu_load_average: $cpu_load,
            queue_process_count: $process_count
        }'
}

# Get disk usage percentage for queue directory
get_disk_usage_percent() {
    local directory="$1"
    
    if [[ ! -d "$directory" ]]; then
        echo "0"
        return
    fi
    
    local usage_percent
    if command -v df >/dev/null 2>&1; then
        usage_percent=$(df "$directory" 2>/dev/null | awk 'NR==2 {gsub(/%/, "", $5); print $5}' || echo "0")
    else
        usage_percent="0"
    fi
    
    echo "${usage_percent:-0}"
}

# Get memory usage percentage
get_memory_usage_percent() {
    local memory_percent="0"
    
    if command -v free >/dev/null 2>&1; then
        # Linux
        memory_percent=$(free | awk 'NR==2{printf "%.0f", $3*100/$2}' 2>/dev/null || echo "0")
    elif command -v vm_stat >/dev/null 2>&1; then
        # macOS
        local page_size=4096
        local free_pages
        free_pages=$(vm_stat | grep "Pages free" | awk '{print $3}' | sed 's/\.//' || echo "0")
        local inactive_pages
        inactive_pages=$(vm_stat | grep "Pages inactive" | awk '{print $3}' | sed 's/\.//' || echo "0")
        local wired_pages
        wired_pages=$(vm_stat | grep "Pages wired" | awk '{print $4}' | sed 's/\.//' || echo "0")
        local active_pages
        active_pages=$(vm_stat | grep "Pages active" | awk '{print $3}' | sed 's/\.//' || echo "0")
        
        local total_pages=$((free_pages + inactive_pages + wired_pages + active_pages))
        local used_pages=$((wired_pages + active_pages))
        
        if [[ $total_pages -gt 0 ]]; then
            memory_percent=$((used_pages * 100 / total_pages))
        fi
    fi
    
    echo "${memory_percent:-0}"
}

# Get CPU load average
get_cpu_load_average() {
    local load_avg="0.00"
    
    if command -v uptime >/dev/null 2>&1; then
        load_avg=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | sed 's/,//' || echo "0.00")
    fi
    
    echo "${load_avg:-0.00}"
}

# Get number of queue-related processes
get_queue_process_count() {
    local process_count=0
    
    if command -v ps >/dev/null 2>&1; then
        # Count processes related to queue operations
        process_count=$(ps aux | grep -c "[c]laude-auto-resume\|[t]ask-queue\|[h]ybrid-monitor" 2>/dev/null || echo "0")
    fi
    
    echo "$process_count"
}

# ===============================================================================
# SAFE TERMINAL DETECTION AND DISPLAY
# ===============================================================================

# Safe terminal detection that won't hang
terminal_is_interactive_safe() {
    # Use timeout to prevent hanging on terminal detection
    if timeout 2s bash -c '[[ -t 1 ]]' 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Safe display function with error handling and fallbacks
display_monitoring_update_safe() {
    local monitoring_data="$1"
    local debug_mode="${2:-false}"
    
    if [[ "$debug_mode" == "true" ]]; then
        log_info "DEBUG: Attempting safe display update"
    fi
    
    # Try full display with error handling
    if ! display_monitoring_update_with_fallback "$monitoring_data" "$debug_mode" 2>/dev/null; then
        # Fall back to simple display if complex display fails
        if [[ "$debug_mode" == "true" ]]; then
            log_info "DEBUG: Full display failed, trying simple display"
        fi
        
        display_monitoring_update_simple "$monitoring_data" "$debug_mode"
    fi
}

# Display with fallback - tries complex display but handles errors
display_monitoring_update_with_fallback() {
    local monitoring_data="$1"
    local debug_mode="${2:-false}"
    
    # Use timeout to prevent hanging on terminal operations
    if timeout 5s bash -c "
        # Clear screen only if we can do it safely
        if command -v tput >/dev/null 2>&1; then
            tput clear 2>/dev/null || printf '\n\n=== Monitoring Update ===\n'
        else
            printf '\033[2J\033[H' 2>/dev/null || printf '\n\n=== Monitoring Update ===\n'
        fi
    " 2>/dev/null; then
        # Terminal clearing worked, proceed with full display
        display_monitoring_update_content "$monitoring_data"
        return 0
    else
        # Terminal clearing failed or timed out
        if [[ "$debug_mode" == "true" ]]; then
            log_info "DEBUG: Terminal clearing failed or timed out"
        fi
        return 1
    fi
}

# Simple display that works in all environments
display_monitoring_update_simple() {
    local monitoring_data="$1"
    local debug_mode="${2:-false}"
    
    local timestamp
    timestamp=$(echo "$monitoring_data" | jq -r '.timestamp')
    
    local update_number
    update_number=$(echo "$monitoring_data" | jq -r '.update_number')
    
    local health_level
    health_level=$(echo "$monitoring_data" | jq -r '.health_status.level')
    
    local queue_stats
    queue_stats=$(echo "$monitoring_data" | jq -r '.queue_stats')
    
    # Simple text-based display
    echo ""
    echo "=== Task Queue Monitoring Update #$update_number ==="
    echo "Time: $timestamp"
    echo "Health: $health_level"
    echo "Queue - Total: $(echo "$queue_stats" | jq -r '.total'), Pending: $(echo "$queue_stats" | jq -r '.pending'), Completed: $(echo "$queue_stats" | jq -r '.completed'), Failed: $(echo "$queue_stats" | jq -r '.failed')"
    
    if [[ "$health_level" != "$HEALTH_GOOD" ]]; then
        local health_message
        health_message=$(echo "$monitoring_data" | jq -r '.health_status.message')
        echo "Issues: $health_message"
    fi
    
    echo "Press Ctrl+C to stop monitoring"
}

# Display monitoring update content (used by fallback display)
display_monitoring_update_content() {
    local monitoring_data="$1"
    
    local timestamp
    timestamp=$(echo "$monitoring_data" | jq -r '.timestamp')
    
    local update_number
    update_number=$(echo "$monitoring_data" | jq -r '.update_number')
    
    local health_level
    health_level=$(echo "$monitoring_data" | jq -r '.health_status.level')
    
    local queue_stats
    queue_stats=$(echo "$monitoring_data" | jq -r '.queue_stats')
    
    echo "==============================================================================="
    echo "Task Queue Real-Time Monitoring - Update #$update_number"
    echo "Time: $timestamp"
    echo "Health: $(colorize_health_status "$health_level")"
    echo "==============================================================================="
    echo
    
    # Display queue statistics
    printf "Queue Statistics:\n"
    printf "  Total:        %s\n" "$(echo "$queue_stats" | jq -r '.total')"
    printf "  Pending:      %s\n" "$(echo "$queue_stats" | jq -r '.pending')"
    printf "  In Progress:  %s\n" "$(echo "$queue_stats" | jq -r '.in_progress')"
    printf "  Completed:    %s\n" "$(echo "$queue_stats" | jq -r '.completed')"
    printf "  Failed:       %s\n" "$(echo "$queue_stats" | jq -r '.failed')"
    printf "  Timeout:      %s\n" "$(echo "$queue_stats" | jq -r '.timeout')"
    echo
    
    # Display system metrics
    printf "System Metrics:\n"
    printf "  Disk Usage:   %s%%\n" "$(echo "$monitoring_data" | jq -r '.system_metrics.disk_usage_percent')"
    printf "  Memory Usage: %s%%\n" "$(echo "$monitoring_data" | jq -r '.system_metrics.memory_usage_percent')"
    printf "  CPU Load:     %s\n" "$(echo "$monitoring_data" | jq -r '.system_metrics.cpu_load_average')"
    printf "  Processes:    %s\n" "$(echo "$monitoring_data" | jq -r '.system_metrics.queue_process_count')"
    echo
    
    # Display health message if not good
    if [[ "$health_level" != "$HEALTH_GOOD" ]]; then
        local health_message
        health_message=$(echo "$monitoring_data" | jq -r '.health_status.message')
        echo "Health Issues:"
        echo "  $health_message"
        echo
    fi
    
    echo "Press Ctrl+C to stop monitoring"
}

# MONITORING DISPLAY AND LOGGING
# ===============================================================================

# Display monitoring update to terminal
display_monitoring_update() {
    local monitoring_data="$1"
    
    local timestamp
    timestamp=$(echo "$monitoring_data" | jq -r '.timestamp')
    
    local update_number
    update_number=$(echo "$monitoring_data" | jq -r '.update_number')
    
    local health_level
    health_level=$(echo "$monitoring_data" | jq -r '.health_status.level')
    
    local queue_stats
    queue_stats=$(echo "$monitoring_data" | jq -r '.queue_stats')
    
    # Clear screen and display header
    printf "\033[2J\033[H"  # Clear screen and move cursor to top-left
    
    echo "==============================================================================="
    echo "Task Queue Real-Time Monitoring - Update #$update_number"
    echo "Time: $timestamp"
    echo "Health: $(colorize_health_status "$health_level")"
    echo "==============================================================================="
    echo
    
    # Display queue statistics
    printf "Queue Statistics:\n"
    printf "  Total:        %s\n" "$(echo "$queue_stats" | jq -r '.total')"
    printf "  Pending:      %s\n" "$(echo "$queue_stats" | jq -r '.pending')"
    printf "  In Progress:  %s\n" "$(echo "$queue_stats" | jq -r '.in_progress')"
    printf "  Completed:    %s\n" "$(echo "$queue_stats" | jq -r '.completed')"
    printf "  Failed:       %s\n" "$(echo "$queue_stats" | jq -r '.failed')"
    printf "  Timeout:      %s\n" "$(echo "$queue_stats" | jq -r '.timeout')"
    echo
    
    # Display system metrics
    printf "System Metrics:\n"
    printf "  Disk Usage:   %s%%\n" "$(echo "$monitoring_data" | jq -r '.system_metrics.disk_usage_percent')"
    printf "  Memory Usage: %s%%\n" "$(echo "$monitoring_data" | jq -r '.system_metrics.memory_usage_percent')"
    printf "  CPU Load:     %s\n" "$(echo "$monitoring_data" | jq -r '.system_metrics.cpu_load_average')"
    printf "  Processes:    %s\n" "$(echo "$monitoring_data" | jq -r '.system_metrics.queue_process_count')"
    echo
    
    # Display health message if not good
    if [[ "$health_level" != "$HEALTH_GOOD" ]]; then
        local health_message
        health_message=$(echo "$monitoring_data" | jq -r '.health_status.message')
        echo "Health Issues:"
        echo "  $health_message"
        echo
    fi
    
    echo "Press Ctrl+C to stop monitoring"
}

# Colorize health status for terminal display
colorize_health_status() {
    local health_level="$1"
    
    case "$health_level" in
        "$HEALTH_GOOD")
            echo -e "\033[32m${health_level}\033[0m"  # Green
            ;;
        "$HEALTH_WARNING")
            echo -e "\033[33m${health_level}\033[0m"  # Yellow
            ;;
        "$HEALTH_CRITICAL")
            echo -e "\033[31m${health_level}\033[0m"  # Red
            ;;
        *)
            echo "$health_level"
            ;;
    esac
}

# Log monitoring data to file
log_monitoring_data() {
    local monitoring_data="$1"
    
    ensure_monitor_log_directory
    
    # Append to log file with timestamp
    echo "$monitoring_data" >> "$MONITOR_LOG_FILE" 2>/dev/null || {
        log_warn "Failed to write monitoring data to log file: $MONITOR_LOG_FILE"
    }
    
    # Rotate log file if it gets too large (>10MB)
    if [[ -f "$MONITOR_LOG_FILE" ]]; then
        local file_size
        file_size=$(du -b "$MONITOR_LOG_FILE" 2>/dev/null | cut -f1 || echo "0")
        
        if [[ $file_size -gt 10485760 ]]; then  # 10MB
            rotate_monitor_log
        fi
    fi
}

# Rotate monitor log file
rotate_monitor_log() {
    if [[ -f "$MONITOR_LOG_FILE" ]]; then
        local rotated_file="${MONITOR_LOG_FILE}.$(date +%Y%m%d-%H%M%S)"
        
        if mv "$MONITOR_LOG_FILE" "$rotated_file" 2>/dev/null; then
            log_info "Rotated monitor log: $rotated_file"
            
            # Compress rotated log
            if command -v gzip >/dev/null 2>&1; then
                gzip "$rotated_file" 2>/dev/null && \
                log_info "Compressed rotated log: ${rotated_file}.gz"
            fi
        else
            log_warn "Failed to rotate monitor log file"
        fi
    fi
}

# ===============================================================================
# MONITORING ALERTS
# ===============================================================================

# Check for monitoring alerts and take action
check_monitoring_alerts() {
    local monitoring_data="$1"
    
    local health_level
    health_level=$(echo "$monitoring_data" | jq -r '.health_status.level')
    
    case "$health_level" in
        "$HEALTH_CRITICAL")
            handle_critical_alert "$monitoring_data"
            ;;
        "$HEALTH_WARNING")
            handle_warning_alert "$monitoring_data"
            ;;
        "$HEALTH_GOOD")
            # No action needed for good health
            ;;
    esac
}

# Handle critical health alert
handle_critical_alert() {
    local monitoring_data="$1"
    
    local health_message
    health_message=$(echo "$monitoring_data" | jq -r '.health_status.message')
    
    log_error "CRITICAL ALERT: $health_message"
    
    # Auto-cleanup actions for critical alerts
    local cleaned=0
    
    # Clean stale locks
    if cleanup_all_stale_locks >/dev/null 2>&1; then
        ((cleaned++))
        log_info "Auto-cleaned stale locks due to critical alert"
    fi
    
    # Validate and potentially repair queue integrity  
    if ! validate_queue_integrity >/dev/null 2>&1; then
        log_warn "Queue integrity issues detected during critical alert"
    fi
    
    # Create emergency backup
    if create_backup "critical-alert-$(date +%Y%m%d-%H%M%S)" >/dev/null 2>&1; then
        log_info "Created emergency backup due to critical alert"
    fi
}

# Handle warning health alert
handle_warning_alert() {
    local monitoring_data="$1"
    
    local health_message
    health_message=$(echo "$monitoring_data" | jq -r '.health_status.message')
    
    log_warn "WARNING ALERT: $health_message"
    
    # Optional cleanup actions for warnings
    cleanup_all_stale_locks >/dev/null 2>&1 && \
    log_info "Cleaned stale locks due to warning alert"
}

# ===============================================================================
# UTILITIES AND SETUP
# ===============================================================================

# Ensure monitor log directory exists
ensure_monitor_log_directory() {
    local log_dir
    log_dir=$(dirname "$MONITOR_LOG_FILE")
    
    if [[ ! -d "$log_dir" ]]; then
        mkdir -p "$log_dir" 2>/dev/null || {
            log_error "Failed to create monitor log directory: $log_dir"
            return 1
        }
        log_debug "Created monitor log directory: $log_dir"
    fi
}

# Cleanup monitoring resources
cleanup_monitoring_resources() {
    # Clean up any temporary monitoring files
    local temp_pattern="${TASK_QUEUE_DIR:-queue}/tmp/monitor-*"
    find "${TASK_QUEUE_DIR:-queue}/tmp" -name "monitor-*" -type f -delete 2>/dev/null || true
    
    log_debug "Cleaned up monitoring resources"
}

# Get monitoring history from log file
get_monitoring_history() {
    local limit="${1:-10}"
    
    if [[ ! -f "$MONITOR_LOG_FILE" ]]; then
        echo "[]"
        return 0
    fi
    
    # Get last N monitoring entries
    tail -n "$limit" "$MONITOR_LOG_FILE" 2>/dev/null | jq -s '.' || echo "[]"
}

# ===============================================================================
# UTILITY FUNCTIONS
# ===============================================================================

# Load logging functions if available
if [[ -f "${SCRIPT_DIR:-}/utils/logging.sh" ]]; then
    source "${SCRIPT_DIR}/utils/logging.sh"
else
    log_debug() { echo "[DEBUG] $*" >&2; }
    log_info() { echo "[INFO] $*" >&2; }
    log_warn() { echo "[WARN] $*" >&2; }
    log_error() { echo "[ERROR] $*" >&2; }
fi