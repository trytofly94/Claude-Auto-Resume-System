#!/usr/bin/env bash
# Performance monitoring and optimization for Claude Auto-Resume
#
# This module provides:
# - Memory usage monitoring and optimization
# - Performance metrics collection
# - Resource cleanup and optimization
# - Queue performance optimization
# - System resource monitoring
# - Performance-based configuration adjustments
#
# Performance Targets:
# - Memory Usage: < 100MB for 1000 queued tasks
# - Queue Operations: < 1 second per operation
# - Processing Overhead: < 10 seconds per task
# - System Resource Usage: Optimized for long-running processes

set -euo pipefail

# ===============================================================================
# PERFORMANCE MONITORING CONFIGURATION
# ===============================================================================

# Performance monitoring settings
PERFORMANCE_MONITORING="${PERFORMANCE_MONITORING:-false}"
MEMORY_LIMIT_MB="${MEMORY_LIMIT_MB:-100}"
CPU_LIMIT_PERCENT="${CPU_LIMIT_PERCENT:-80}"
DISK_USAGE_LIMIT_PERCENT="${DISK_USAGE_LIMIT_PERCENT:-90}"

# Optimization settings
LARGE_QUEUE_OPTIMIZATION="${LARGE_QUEUE_OPTIMIZATION:-false}"
AUTO_CLEANUP="${AUTO_CLEANUP:-false}"
CLEANUP_INTERVAL="${CLEANUP_INTERVAL:-300}"  # 5 minutes
PERFORMANCE_LOG_INTERVAL="${PERFORMANCE_LOG_INTERVAL:-60}"  # 1 minute

# Memory optimization settings
CONSERVATIVE_MODE="${CONSERVATIVE_MODE:-false}"
MEMORY_CHECK_INTERVAL="${MEMORY_CHECK_INTERVAL:-30}"  # 30 seconds
MEMORY_CLEANUP_THRESHOLD="${MEMORY_CLEANUP_THRESHOLD:-80}"  # 80% of limit

# Performance thresholds
QUEUE_SIZE_OPTIMIZATION_THRESHOLD="${QUEUE_SIZE_OPTIMIZATION_THRESHOLD:-100}"
LOG_SIZE_LIMIT_MB="${LOG_SIZE_LIMIT_MB:-50}"
BACKUP_RETENTION_HOURS="${BACKUP_RETENTION_HOURS:-168}"  # 1 week

# ===============================================================================
# INITIALIZATION AND SETUP
# ===============================================================================

# Get project root directory
if [[ -n "${PROJECT_ROOT:-}" ]]; then
    SCRIPT_DIR="$PROJECT_ROOT/src"
else
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

# Load logging utilities
if [[ -f "$SCRIPT_DIR/utils/logging.sh" ]]; then
    source "$SCRIPT_DIR/utils/logging.sh"
else
    # Fallback logging functions
    log_debug() { [[ "${DEBUG_MODE:-false}" == "true" ]] && echo "[DEBUG] $*" >&2; }
    log_info() { echo "[INFO] $*" >&2; }
    log_warn() { echo "[WARN] $*" >&2; }
    log_error() { echo "[ERROR] $*" >&2; }
fi

# Load centralized configuration loader (Issue #114)
if [[ -f "$SCRIPT_DIR/utils/config-loader.sh" ]]; then
    source "$SCRIPT_DIR/utils/config-loader.sh"
    # Load configuration using centralized loader
    load_system_config || log_warn "Failed to load centralized configuration, using defaults"
    
    # Get configuration values using centralized getter
    PERFORMANCE_MONITORING="$(get_config "PERFORMANCE_MONITORING" "${PERFORMANCE_MONITORING:-false}")"
    MEMORY_LIMIT_MB="$(get_config "MEMORY_LIMIT_MB" "${MEMORY_LIMIT_MB:-100}")"
    CPU_LIMIT_PERCENT="$(get_config "CPU_LIMIT_PERCENT" "${CPU_LIMIT_PERCENT:-80}")"
    DISK_USAGE_LIMIT_PERCENT="$(get_config "DISK_USAGE_LIMIT_PERCENT" "${DISK_USAGE_LIMIT_PERCENT:-90}")"
    LARGE_QUEUE_OPTIMIZATION="$(get_config "LARGE_QUEUE_OPTIMIZATION" "${LARGE_QUEUE_OPTIMIZATION:-false}")"
    AUTO_CLEANUP="$(get_config "AUTO_CLEANUP" "${AUTO_CLEANUP:-false}")"
    CLEANUP_INTERVAL="$(get_config "CLEANUP_INTERVAL" "${CLEANUP_INTERVAL:-300}")"
    PERFORMANCE_LOG_INTERVAL="$(get_config "PERFORMANCE_LOG_INTERVAL" "${PERFORMANCE_LOG_INTERVAL:-60}")"
    CONSERVATIVE_MODE="$(get_config "CONSERVATIVE_MODE" "${CONSERVATIVE_MODE:-false}")"
    MEMORY_CHECK_INTERVAL="$(get_config "MEMORY_CHECK_INTERVAL" "${MEMORY_CHECK_INTERVAL:-30}")"
    MEMORY_CLEANUP_THRESHOLD="$(get_config "MEMORY_CLEANUP_THRESHOLD" "${MEMORY_CLEANUP_THRESHOLD:-80}")"
    QUEUE_SIZE_OPTIMIZATION_THRESHOLD="$(get_config "QUEUE_SIZE_OPTIMIZATION_THRESHOLD" "${QUEUE_SIZE_OPTIMIZATION_THRESHOLD:-100}")"
    LOG_SIZE_LIMIT_MB="$(get_config "LOG_SIZE_LIMIT_MB" "${LOG_SIZE_LIMIT_MB:-50}")"
    BACKUP_RETENTION_HOURS="$(get_config "BACKUP_RETENTION_HOURS" "${BACKUP_RETENTION_HOURS:-168}")"
else
    # Fallback: Load configuration directly if centralized loader not available
    if [[ -f "$PROJECT_ROOT/config/default.conf" ]]; then
        source "$PROJECT_ROOT/config/default.conf" 2>/dev/null || true
    fi
    log_warn "Centralized config loader not available, using fallback method"
fi

# Performance log file
PERFORMANCE_LOG="${PERFORMANCE_LOG:-$PROJECT_ROOT/logs/performance.log}"

# ===============================================================================
# MEMORY MONITORING FUNCTIONS
# ===============================================================================

# Monitor memory usage of current process
monitor_memory_usage() {
    local pid="${1:-$$}"
    
    if has_command_cached ps 2>/dev/null || command -v ps >/dev/null; then
        # Get memory usage in MB (works on both macOS and Linux)
        local memory_kb
        memory_kb=$(ps -o rss= -p "$pid" 2>/dev/null | awk '{print $1}' || echo "0")
        echo "scale=2; $memory_kb / 1024" | bc -l 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

# Monitor system memory usage
monitor_system_memory() {
    if has_command_cached free 2>/dev/null || command -v free >/dev/null; then
        # Linux system
        free -m | awk 'NR==2{printf "%.1f", $3*100/($3+$4)}'
    elif [[ "$(uname)" == "Darwin" ]]; then
        # macOS system
        local vm_stat
        vm_stat=$(vm_stat 2>/dev/null) || echo ""
        if [[ -n "$vm_stat" ]]; then
            local free_blocks wired_blocks active_blocks inactive_blocks speculative_blocks
            free_blocks=$(echo "$vm_stat" | awk '/Pages free:/ {print $3}' | sed 's/\.//')
            wired_blocks=$(echo "$vm_stat" | awk '/Pages wired down:/ {print $4}' | sed 's/\.//')
            active_blocks=$(echo "$vm_stat" | awk '/Pages active:/ {print $3}' | sed 's/\.//')
            inactive_blocks=$(echo "$vm_stat" | awk '/Pages inactive:/ {print $3}' | sed 's/\.//')
            speculative_blocks=$(echo "$vm_stat" | awk '/Pages speculative:/ {print $3}' | sed 's/\.//')
            
            # Calculate usage percentage (approximation)
            local total_blocks used_blocks
            total_blocks=$((free_blocks + wired_blocks + active_blocks + inactive_blocks + speculative_blocks))
            used_blocks=$((wired_blocks + active_blocks))
            if [[ $total_blocks -gt 0 ]]; then
                echo "scale=1; $used_blocks * 100 / $total_blocks" | bc -l 2>/dev/null || echo "0"
            else
                echo "0"
            fi
        else
            echo "0"
        fi
    else
        echo "0"
    fi
}

# Check if system resources are under pressure
check_system_resources() {
    local memory_limit_mb="${MEMORY_LIMIT_MB:-100}"
    local cpu_limit="${CPU_LIMIT_PERCENT:-80}"
    
    # Check process memory usage
    local current_memory
    current_memory=$(monitor_memory_usage)
    
    if (( $(echo "$current_memory > $memory_limit_mb" | bc -l 2>/dev/null || echo 0) )); then
        log_warn "Memory usage ($current_memory MB) exceeds limit ($memory_limit_mb MB)"
        
        # Trigger cleanup
        cleanup_memory_usage
        
        # If still over limit, enable conservative mode
        current_memory=$(monitor_memory_usage)
        if (( $(echo "$current_memory > $memory_limit_mb" | bc -l 2>/dev/null || echo 0) )); then
            log_warn "Enabling conservative mode due to memory pressure"
            export CONSERVATIVE_MODE="true"
        fi
        
        return 1
    fi
    
    # Check system memory usage
    local system_memory
    system_memory=$(monitor_system_memory)
    
    if (( $(echo "$system_memory > 90" | bc -l 2>/dev/null || echo 0) )); then
        log_warn "System memory usage is high: ${system_memory}%"
        export CONSERVATIVE_MODE="true"
        return 1
    fi
    
    return 0
}

# ===============================================================================
# PERFORMANCE OPTIMIZATION FUNCTIONS
# ===============================================================================

# Clean up memory usage
cleanup_memory_usage() {
    log_debug "Cleaning up memory usage"
    
    # Clean up old log entries
    cleanup_log_files
    
    # Clean up old backup files
    cleanup_old_backups
    
    # Optimize queue file if large
    optimize_queue_file
    
    # Clear any temporary files
    cleanup_temporary_files
}

# Clean up log files to prevent excessive memory usage
cleanup_log_files() {
    local log_limit_mb="${LOG_SIZE_LIMIT_MB:-50}"
    
    local log_files=(
        "$PROJECT_ROOT/logs/hybrid-monitor.log"
        "$PROJECT_ROOT/logs/task-queue.log"
        "$PROJECT_ROOT/logs/github-integration.log"
        "$PERFORMANCE_LOG"
    )
    
    for log_file in "${log_files[@]}"; do
        if [[ -f "$log_file" ]]; then
            local log_size_mb
            log_size_mb=$(du -m "$log_file" 2>/dev/null | cut -f1 || echo "0")
            
            if [[ $log_size_mb -gt $log_limit_mb ]]; then
                log_debug "Trimming large log file: $log_file (${log_size_mb}MB)"
                
                # Keep last half of the file
                local line_count
                line_count=$(wc -l < "$log_file" 2>/dev/null || echo "0")
                local keep_lines=$((line_count / 2))
                
                if [[ $keep_lines -gt 0 ]]; then
                    tail -n "$keep_lines" "$log_file" > "${log_file}.tmp"
                    mv "${log_file}.tmp" "$log_file"
                    log_debug "Trimmed log file to $keep_lines lines"
                fi
            fi
        fi
    done
}

# Clean up old backup files
cleanup_old_backups() {
    local backup_dirs=(
        "$PROJECT_ROOT/queue/backups"
        "$PROJECT_ROOT/logs/backups"
    )
    
    local retention_hours="${BACKUP_RETENTION_HOURS:-168}"  # 1 week
    
    for backup_dir in "${backup_dirs[@]}"; do
        if [[ -d "$backup_dir" ]]; then
            log_debug "Cleaning up old backups in: $backup_dir"
            
            # Find and remove files older than retention period
            find "$backup_dir" -type f -name "*.json" -mtime +$((retention_hours / 24)) -delete 2>/dev/null || true
            find "$backup_dir" -type f -name "*.log" -mtime +$((retention_hours / 24)) -delete 2>/dev/null || true
        fi
    done
}

# Optimize queue file for large queues
optimize_queue_file() {
    local queue_files=(
        "$PROJECT_ROOT/queue/task-queue.json"
        "${TASK_QUEUE_DIR:-$PROJECT_ROOT/queue}/task-queue.json"
    )
    
    for queue_file in "${queue_files[@]}"; do
        if [[ -f "$queue_file" ]]; then
            local completed_count
            completed_count=$(jq '[.tasks[] | select(.status == "completed")] | length' "$queue_file" 2>/dev/null || echo "0")
            
            if [[ $completed_count -gt 100 ]]; then
                log_info "Archiving $completed_count completed tasks from queue"
                archive_completed_tasks "$queue_file"
            fi
        fi
    done
}

# Archive completed tasks to reduce queue file size
archive_completed_tasks() {
    local queue_file="$1"
    
    if [[ ! -f "$queue_file" ]]; then
        return 0
    fi
    
    local archive_dir="$(dirname "$queue_file")/archives"
    mkdir -p "$archive_dir"
    
    local archive_file="$archive_dir/completed-$(date +%Y%m%d-%H%M%S).json"
    
    # Extract completed tasks
    if jq '[.tasks[] | select(.status == "completed")]' "$queue_file" > "$archive_file" 2>/dev/null; then
        # Remove from main queue
        if jq '.tasks |= [.[] | select(.status != "completed")]' "$queue_file" > "${queue_file}.tmp" 2>/dev/null; then
            mv "${queue_file}.tmp" "$queue_file"
            log_info "Completed tasks archived to: $archive_file"
        else
            log_error "Failed to update queue file after archiving"
            rm -f "${queue_file}.tmp"
        fi
    else
        log_error "Failed to extract completed tasks for archiving"
    fi
}

# Clean up temporary files
cleanup_temporary_files() {
    local temp_patterns=(
        "/tmp/task_queue_*"
        "/tmp/github_cache_*"
        "/tmp/performance_*"
        "/tmp/claude_auto_resume_*"
    )
    
    for pattern in "${temp_patterns[@]}"; do
        # Only remove files older than 1 hour to avoid interfering with active operations
        find "$(dirname "$pattern")" -name "$(basename "$pattern")" -type f -mtime +0.04 -delete 2>/dev/null || true
    done
}

# ===============================================================================
# QUEUE OPTIMIZATION FUNCTIONS
# ===============================================================================

# Get queue size efficiently without loading entire queue
get_queue_size_fast() {
    local queue_file="${1:-$PROJECT_ROOT/queue/task-queue.json}"
    
    if [[ -f "$queue_file" ]]; then
        jq -r '.tasks | length' "$queue_file" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

# Optimize for large queues
optimize_for_large_queues() {
    local queue_size
    queue_size=$(get_queue_size_fast)
    
    local threshold="${QUEUE_SIZE_OPTIMIZATION_THRESHOLD:-100}"
    
    if [[ $queue_size -gt $threshold ]]; then
        log_info "Large queue detected ($queue_size tasks), applying optimizations"
        
        # Enable batch processing mode
        export BATCH_PROCESSING="true"
        export QUEUE_CHUNK_SIZE="${QUEUE_CHUNK_SIZE:-10}"
        
        # Reduce logging verbosity to improve performance
        if [[ "${LOG_LEVEL:-INFO}" == "DEBUG" ]]; then
            export LOG_LEVEL="INFO"
            log_info "Reduced logging verbosity for performance"
        fi
        
        # Increase processing delays to reduce resource usage
        local current_delay="${QUEUE_PROCESSING_DELAY:-30}"
        export QUEUE_PROCESSING_DELAY=$((current_delay * 2))
        
        # Enable periodic cleanup
        export AUTO_CLEANUP="true"
        export CLEANUP_INTERVAL="${CLEANUP_INTERVAL:-300}"
        
        # Enable conservative mode for very large queues
        if [[ $queue_size -gt 500 ]]; then
            log_info "Very large queue detected, enabling conservative mode"
            export CONSERVATIVE_MODE="true"
            export MEMORY_LIMIT_MB=$((MEMORY_LIMIT_MB / 2))
        fi
    fi
}

# Batch queue operations for better performance
batch_queue_operations() {
    local operations=("$@")
    
    if [[ ${#operations[@]} -eq 0 ]]; then
        return 0
    fi
    
    local queue_file="${TASK_QUEUE_FILE:-$PROJECT_ROOT/queue/task-queue.json}"
    local temp_queue="/tmp/queue_batch_$$.json"
    
    # Copy current queue to temp file
    if [[ -f "$queue_file" ]]; then
        cp "$queue_file" "$temp_queue" || {
            log_error "Failed to create temporary queue file"
            return 1
        }
    else
        echo '{"tasks": []}' > "$temp_queue"
    fi
    
    # Apply operations in batch
    for operation in "${operations[@]}"; do
        case "$operation" in
            "cleanup_completed")
                jq 'del(.tasks[] | select(.status == "completed" and (.created_at | fromdateiso8601) < (now - 86400)))' "$temp_queue" > "${temp_queue}.new"
                mv "${temp_queue}.new" "$temp_queue"
                ;;
            "update_priorities")
                jq '.tasks |= sort_by(.priority, .created_at)' "$temp_queue" > "${temp_queue}.new"
                mv "${temp_queue}.new" "$temp_queue"
                ;;
            "compact_queue")
                jq '.tasks |= [.[] | del(.logs[]?)]' "$temp_queue" > "${temp_queue}.new"
                mv "${temp_queue}.new" "$temp_queue"
                ;;
        esac
    done
    
    # Apply all changes at once
    if mv "$temp_queue" "$queue_file"; then
        log_debug "Batch operations completed successfully"
        return 0
    else
        log_error "Failed to apply batch operations"
        rm -f "$temp_queue"
        return 1
    fi
}

# ===============================================================================
# PERFORMANCE METRICS AND MONITORING
# ===============================================================================

# Collect performance metrics
collect_performance_metrics() {
    if [[ "${PERFORMANCE_MONITORING:-false}" != "true" ]]; then
        return 0
    fi
    
    local metrics_file="${PERFORMANCE_LOG:-$PROJECT_ROOT/logs/performance.log}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Collect system metrics
    local memory_usage system_memory queue_size disk_usage
    memory_usage=$(monitor_memory_usage)
    system_memory=$(monitor_system_memory)
    queue_size=$(get_queue_size_fast)
    
    # Disk usage (if available)
    if has_command_cached df 2>/dev/null || command -v df >/dev/null; then
        disk_usage=$(df "$PROJECT_ROOT" 2>/dev/null | awk 'NR==2 {print $5}' | sed 's/%//' || echo "0")
    else
        disk_usage="0"
    fi
    
    # Log metrics in JSON format for easy parsing
    local metrics_json
    metrics_json=$(jq -n \
        --arg timestamp "$timestamp" \
        --arg memory_usage "$memory_usage" \
        --arg system_memory "$system_memory" \
        --arg queue_size "$queue_size" \
        --arg disk_usage "$disk_usage" \
        '{
            timestamp: $timestamp,
            memory_usage_mb: $memory_usage,
            system_memory_percent: $system_memory,
            queue_size: $queue_size,
            disk_usage_percent: $disk_usage
        }')
    
    # Append to performance log
    echo "$metrics_json" >> "$metrics_file"
    
    # Rotate performance log if it gets too large
    local log_size
    log_size=$(wc -l < "$metrics_file" 2>/dev/null || echo "0")
    if [[ $log_size -gt 1000 ]]; then
        tail -n 500 "$metrics_file" > "${metrics_file}.tmp"
        mv "${metrics_file}.tmp" "$metrics_file"
    fi
}

# Generate performance report
generate_performance_report() {
    local metrics_file="${PERFORMANCE_LOG:-$PROJECT_ROOT/logs/performance.log}"
    local report_file="${1:-/tmp/performance_report_$$.txt}"
    
    if [[ ! -f "$metrics_file" ]]; then
        echo "No performance metrics available" > "$report_file"
        return 0
    fi
    
    {
        echo "=== Claude Auto-Resume Performance Report ==="
        echo "Generated: $(date)"
        echo ""
        
        # Get last 24 hours of data
        local last_24h
        last_24h=$(date -d "24 hours ago" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -v-24H '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "")
        
        if [[ -n "$last_24h" ]]; then
            local recent_metrics
            recent_metrics=$(grep "$last_24h" "$metrics_file" 2>/dev/null | tail -100 || tail -100 "$metrics_file")
        else
            recent_metrics=$(tail -100 "$metrics_file")
        fi
        
        if [[ -n "$recent_metrics" ]]; then
            echo "Performance Statistics (last 100 measurements):"
            echo ""
            
            # Calculate averages and peaks
            local avg_memory peak_memory avg_queue_size peak_queue_size
            avg_memory=$(echo "$recent_metrics" | jq -r '.memory_usage_mb' | awk '{sum+=$1} END {printf "%.1f", sum/NR}' 2>/dev/null || echo "N/A")
            peak_memory=$(echo "$recent_metrics" | jq -r '.memory_usage_mb' | sort -n | tail -1 2>/dev/null || echo "N/A")
            avg_queue_size=$(echo "$recent_metrics" | jq -r '.queue_size' | awk '{sum+=$1} END {printf "%.0f", sum/NR}' 2>/dev/null || echo "N/A")
            peak_queue_size=$(echo "$recent_metrics" | jq -r '.queue_size' | sort -n | tail -1 2>/dev/null || echo "N/A")
            
            echo "Memory Usage:"
            echo "  Average: ${avg_memory} MB"
            echo "  Peak: ${peak_memory} MB"
            echo ""
            
            echo "Queue Size:"
            echo "  Average: ${avg_queue_size} tasks"
            echo "  Peak: ${peak_queue_size} tasks"
            echo ""
            
            # Performance recommendations
            echo "Recommendations:"
            if (( $(echo "$peak_memory > 80" | bc -l 2>/dev/null || echo 0) )); then
                echo "  - Consider enabling conservative mode (high memory usage detected)"
            fi
            
            if [[ "$peak_queue_size" -gt 100 ]]; then
                echo "  - Enable large queue optimization for better performance"
            fi
            
            if [[ "${AUTO_CLEANUP:-false}" == "false" ]]; then
                echo "  - Enable automatic cleanup to prevent resource accumulation"
            fi
        else
            echo "No recent performance data available"
        fi
        
    } > "$report_file"
    
    echo "Performance report generated: $report_file"
}

# ===============================================================================
# OPTIMIZATION MODES AND STRATEGIES
# ===============================================================================

# Enable conservative mode for resource-constrained environments
enable_conservative_mode() {
    log_info "Enabling conservative mode for resource optimization"
    
    export CONSERVATIVE_MODE="true"
    export QUEUE_PROCESSING_DELAY=$((${QUEUE_PROCESSING_DELAY:-30} * 2))
    export LOG_LEVEL="${LOG_LEVEL:-WARN}"
    export AUTO_CLEANUP="true"
    export CLEANUP_INTERVAL="180"  # More frequent cleanup
    export MEMORY_LIMIT_MB=$((${MEMORY_LIMIT_MB:-100} * 3 / 4))  # 25% reduction
    
    log_info "Conservative mode enabled with reduced resource usage"
}

# Enable high performance mode for powerful systems
enable_high_performance_mode() {
    log_info "Enabling high performance mode for optimal throughput"
    
    export CONSERVATIVE_MODE="false"
    export QUEUE_PROCESSING_DELAY=$((${QUEUE_PROCESSING_DELAY:-30} / 2))
    export BATCH_PROCESSING="true"
    export PARALLEL_OPERATIONS="true"
    export MEMORY_LIMIT_MB=$((${MEMORY_LIMIT_MB:-100} * 2))  # Double limit
    
    log_info "High performance mode enabled"
}

# Auto-adjust performance settings based on system conditions
auto_adjust_performance() {
    local system_memory queue_size current_memory
    system_memory=$(monitor_system_memory)
    queue_size=$(get_queue_size_fast)
    current_memory=$(monitor_memory_usage)
    
    # Adjust based on system memory pressure
    if (( $(echo "$system_memory > 85" | bc -l 2>/dev/null || echo 0) )); then
        if [[ "${CONSERVATIVE_MODE:-false}" == "false" ]]; then
            log_info "High system memory usage detected, enabling conservative mode"
            enable_conservative_mode
        fi
    elif (( $(echo "$system_memory < 50" | bc -l 2>/dev/null || echo 0) )); then
        if [[ "${CONSERVATIVE_MODE:-false}" == "true" ]] && [[ "$queue_size" -lt 50 ]]; then
            log_info "System resources available, disabling conservative mode"
            export CONSERVATIVE_MODE="false"
        fi
    fi
    
    # Adjust based on queue size
    if [[ $queue_size -gt 200 ]]; then
        optimize_for_large_queues
    fi
    
    # Adjust based on process memory usage
    if (( $(echo "$current_memory > $((MEMORY_LIMIT_MB * 8 / 10))" | bc -l 2>/dev/null || echo 0) )); then
        cleanup_memory_usage
    fi
}

# ===============================================================================
# MAIN PERFORMANCE MONITORING LOOP
# ===============================================================================

# Start performance monitoring
start_performance_monitoring() {
    if [[ "${PERFORMANCE_MONITORING:-false}" != "true" ]]; then
        log_debug "Performance monitoring is disabled"
        return 0
    fi
    
    local monitoring_interval="${PERFORMANCE_LOG_INTERVAL:-60}"
    log_info "Starting performance monitoring (interval: ${monitoring_interval}s)"
    
    # Background monitoring loop
    (
        while true; do
            collect_performance_metrics
            auto_adjust_performance
            
            # Check if we should continue monitoring
            if [[ "${PERFORMANCE_MONITORING:-false}" != "true" ]]; then
                break
            fi
            
            sleep "$monitoring_interval"
        done
    ) &
    
    local monitor_pid=$!
    log_debug "Performance monitoring started with PID: $monitor_pid"
    
    # Store PID for cleanup
    echo "$monitor_pid" > "/tmp/performance_monitor_$$.pid"
    
    return 0
}

# Stop performance monitoring
stop_performance_monitoring() {
    local pid_file="/tmp/performance_monitor_$$.pid"
    
    if [[ -f "$pid_file" ]]; then
        local monitor_pid
        monitor_pid=$(cat "$pid_file")
        
        if kill -0 "$monitor_pid" 2>/dev/null; then
            log_info "Stopping performance monitoring (PID: $monitor_pid)"
            kill "$monitor_pid" 2>/dev/null || true
        fi
        
        rm -f "$pid_file"
    fi
    
    export PERFORMANCE_MONITORING="false"
}

# ===============================================================================
# CLI INTERFACE AND MAIN FUNCTION
# ===============================================================================

# Display help information
display_performance_help() {
    cat << 'EOF'
Claude Auto-Resume Performance Monitor
=====================================

USAGE:
    performance-monitor.sh [OPTIONS] [COMMAND]

COMMANDS:
    start                   Start performance monitoring
    stop                    Stop performance monitoring
    status                  Show current performance status
    report                  Generate performance report
    cleanup                 Perform manual cleanup
    optimize                Optimize system for current conditions

OPTIONS:
    --memory-limit MB       Set memory limit (default: 100MB)
    --conservative          Enable conservative mode
    --high-performance      Enable high performance mode
    --auto-cleanup          Enable automatic cleanup
    --help                  Show this help message

EXAMPLES:
    # Start monitoring with custom memory limit
    performance-monitor.sh --memory-limit 200 start
    
    # Generate performance report
    performance-monitor.sh report
    
    # Manual cleanup and optimization
    performance-monitor.sh cleanup optimize

EOF
}

# Main performance monitor function
performance_monitor_main() {
    local command="${1:-status}"
    
    case "$command" in
        "start")
            export PERFORMANCE_MONITORING="true"
            start_performance_monitoring
            ;;
        "stop")
            stop_performance_monitoring
            ;;
        "status")
            local memory_usage system_memory queue_size
            memory_usage=$(monitor_memory_usage)
            system_memory=$(monitor_system_memory)
            queue_size=$(get_queue_size_fast)
            
            echo "=== Performance Status ==="
            echo "Memory Usage: ${memory_usage} MB"
            echo "System Memory: ${system_memory}%"
            echo "Queue Size: ${queue_size} tasks"
            echo "Conservative Mode: ${CONSERVATIVE_MODE:-false}"
            echo "Performance Monitoring: ${PERFORMANCE_MONITORING:-false}"
            ;;
        "report")
            generate_performance_report "${2:-}"
            ;;
        "cleanup")
            cleanup_memory_usage
            echo "Manual cleanup completed"
            ;;
        "optimize")
            auto_adjust_performance
            echo "Performance optimization applied"
            ;;
        "help"|"--help"|"-h")
            display_performance_help
            ;;
        *)
            log_error "Unknown command: $command"
            display_performance_help
            return 1
            ;;
    esac
}

# Process command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --memory-limit)
            export MEMORY_LIMIT_MB="$2"
            shift 2
            ;;
        --conservative)
            enable_conservative_mode
            shift
            ;;
        --high-performance)
            enable_high_performance_mode
            shift
            ;;
        --auto-cleanup)
            export AUTO_CLEANUP="true"
            shift
            ;;
        --help|-h)
            display_performance_help
            exit 0
            ;;
        -*)
            log_error "Unknown option: $1"
            display_performance_help
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    performance_monitor_main "$@"
fi