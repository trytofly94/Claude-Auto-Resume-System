#!/usr/bin/env bash

# Claude Auto-Resume - Task Queue Interactive CLI Module
# User-friendly interactive interface for task queue management
# Version: 2.0.0-refactored

set -euo pipefail

# ===============================================================================
# INTERACTIVE CLI CONSTANTS
# ===============================================================================

INTERACTIVE_PROMPT="queue> "
INTERACTIVE_HISTORY_FILE="${HOME}/.claude-auto-resume-history"
INTERACTIVE_MAX_HISTORY=1000

# ===============================================================================
# LOGGING FUNCTIONS
# ===============================================================================

# Load logging functions if available, or define fallback functions
# NOTE: This must be defined early as many functions depend on logging
if [[ -f "${SCRIPT_DIR:-}/utils/logging.sh" ]]; then
    source "${SCRIPT_DIR}/utils/logging.sh"
else
    log_debug() { echo "[DEBUG] $*" >&2; }
    log_info() { echo "[INFO] $*" >&2; }
    log_warn() { echo "[WARN] $*" >&2; }
    log_error() { echo "[ERROR] $*" >&2; }
fi

# ===============================================================================
# INTERACTIVE SESSION MANAGEMENT
# ===============================================================================

# Initialize interactive mode
init_interactive_mode() {
    log_info "Starting interactive task queue management"
    
    # Load command history if available
    if [[ -f "$INTERACTIVE_HISTORY_FILE" ]] && command -v history >/dev/null 2>&1; then
        history -r "$INTERACTIVE_HISTORY_FILE" 2>/dev/null || true
    fi
    
    # Set up signal handlers for clean exit
    trap 'cleanup_interactive_session' EXIT INT TERM
    
    show_interactive_welcome
}

# Show welcome message and help
show_interactive_welcome() {
    echo "==============================================================================="
    echo "Claude Auto-Resume - Task Queue Interactive Management"
    echo "Version: 2.0.0-refactored"
    echo "==============================================================================="
    echo
    echo "Available commands:"
    echo "  add <task_data>     - Add new task (JSON format)"
    echo "  remove <task_id>    - Remove task by ID"  
    echo "  list [status]       - List tasks (optional status filter)"
    echo "  status              - Show queue status summary"
    echo "  stats               - Show detailed statistics"
    echo "  monitor             - Start real-time monitoring"
    echo "  locks               - Show current locks"
    echo "  cleanup             - Run maintenance cleanup"
    echo "  save                - Save queue state"
    echo "  load                - Load queue state"
    echo "  backup              - Create backup"
    echo "  help                - Show this help"
    echo "  exit, quit          - Exit interactive mode"
    echo
}

# Main interactive loop
run_interactive_mode() {
    init_interactive_mode
    
    local continue_running=true
    
    while [[ "$continue_running" == true ]]; do
        # Display prompt and read user input
        echo -n "$INTERACTIVE_PROMPT"
        
        local user_input
        if ! read -r user_input; then
            echo  # New line for clean exit
            break
        fi
        
        # Skip empty input
        if [[ -z "${user_input// }" ]]; then
            continue
        fi
        
        # Add to history
        if command -v history >/dev/null 2>&1; then
            history -s "$user_input"
        fi
        
        # Parse and execute command
        local exit_code=0
        execute_interactive_command "$user_input" || exit_code=$?
        
        # Check for exit commands
        local cmd="${user_input%% *}"
        if [[ "$cmd" == "exit" ]] || [[ "$cmd" == "quit" ]]; then
            continue_running=false
        fi
        
        echo  # Add spacing between commands
    done
    
    cleanup_interactive_session
    log_info "Interactive session ended"
}

# Execute interactive command
execute_interactive_command() {
    local input="$1"
    local cmd args
    
    # Parse command and arguments
    read -r cmd args <<< "$input"
    
    case "$cmd" in
        "add")
            handle_add_command "$args"
            ;;
        "remove"|"rm")
            handle_remove_command "$args"
            ;;
        "list"|"ls")
            handle_list_command "$args"
            ;;
        "status")
            handle_status_command
            ;;
        "stats")
            handle_stats_command
            ;;
        "monitor")
            handle_monitor_command "$args"
            ;;
        "locks")
            handle_locks_command
            ;;
        "cleanup")
            handle_cleanup_command
            ;;
        "save")
            handle_save_command
            ;;
        "load")
            handle_load_command
            ;;
        "backup")
            handle_backup_command "$args"
            ;;
        "help"|"?")
            show_interactive_help
            ;;
        "exit"|"quit")
            echo "Goodbye!"
            ;;
        "")
            # Empty command, do nothing
            ;;
        *)
            echo "Unknown command: $cmd"
            echo "Type 'help' for available commands"
            return 1
            ;;
    esac
}

# ===============================================================================
# COMMAND HANDLERS
# ===============================================================================

# Handle add task command
handle_add_command() {
    local task_data="$1"
    
    if [[ -z "$task_data" ]]; then
        echo "Usage: add <task_data_json>"
        echo "Example: add '{\"id\":\"task-123\",\"type\":\"custom\",\"status\":\"pending\",\"created_at\":\"$(date -Iseconds)\"}'"
        return 1
    fi
    
    # Validate JSON
    if ! echo "$task_data" | jq empty >/dev/null 2>&1; then
        echo "Error: Invalid JSON format"
        return 1
    fi
    
    if add_task "$task_data"; then
        echo "Task added successfully"
        save_queue_state false  # Save without backup for interactive add
    else
        echo "Failed to add task"
        return 1
    fi
}

# Handle remove task command
handle_remove_command() {
    local task_id="$1"
    
    if [[ -z "$task_id" ]]; then
        echo "Usage: remove <task_id>"
        return 1
    fi
    
    if remove_task "$task_id"; then
        echo "Task removed: $task_id"
        save_queue_state false  # Save without backup for interactive remove
    else
        echo "Failed to remove task: $task_id"
        return 1
    fi
}

# Handle list tasks command
handle_list_command() {
    local status_filter="${1:-all}"
    
    local tasks_json
    tasks_json=$(list_tasks "$status_filter" "json")
    
    local task_count
    task_count=$(echo "$tasks_json" | jq length)
    
    if [[ "$task_count" -eq 0 ]]; then
        echo "No tasks found"
        if [[ "$status_filter" != "all" ]]; then
            echo "(filter: status=$status_filter)"
        fi
        return 0
    fi
    
    echo "Found $task_count task(s):"
    if [[ "$status_filter" != "all" ]]; then
        echo "(filter: status=$status_filter)"
    fi
    echo
    
    # Display tasks in a table format
    printf "%-20s %-15s %-12s %-20s\n" "ID" "TYPE" "STATUS" "CREATED"
    printf "%-20s %-15s %-12s %-20s\n" "----" "----" "------" "-------"
    
    echo "$tasks_json" | jq -r '.[] | [.id, .type, .status, .created_at] | @tsv' | \
    while IFS=$'\t' read -r id type status created; do
        printf "%-20s %-15s %-12s %-20s\n" "$id" "$type" "$status" "$created"
    done
}

# Handle status command
handle_status_command() {
    local stats_json
    stats_json=$(get_queue_stats)
    
    echo "Queue Status Summary:"
    echo "===================="
    
    local total pending in_progress completed failed timeout
    total=$(echo "$stats_json" | jq -r '.total')
    pending=$(echo "$stats_json" | jq -r '.pending')
    in_progress=$(echo "$stats_json" | jq -r '.in_progress')  
    completed=$(echo "$stats_json" | jq -r '.completed')
    failed=$(echo "$stats_json" | jq -r '.failed')
    timeout=$(echo "$stats_json" | jq -r '.timeout')
    
    printf "Total Tasks:      %s\n" "$total"
    printf "Pending:          %s\n" "$pending"
    printf "In Progress:      %s\n" "$in_progress"
    printf "Completed:        %s\n" "$completed"
    printf "Failed:           %s\n" "$failed"
    printf "Timeout:          %s\n" "$timeout"
    
    # Show queue file info
    local file_stats
    file_stats=$(get_queue_file_stats)
    
    if echo "$file_stats" | jq -e '.exists' >/dev/null 2>&1; then
        echo
        echo "Queue File Info:"
        echo "==============="
        printf "File:             %s\n" "$(echo "$file_stats" | jq -r '.file')"
        printf "Size:             %s bytes\n" "$(echo "$file_stats" | jq -r '.size_bytes')"
        printf "Last Modified:    %s\n" "$(date -d @$(echo "$file_stats" | jq -r '.last_modified') 2>/dev/null || echo 'unknown')"
    fi
}

# Handle stats command  
handle_stats_command() {
    handle_status_command
    
    echo
    echo "Detailed Statistics:"
    echo "==================="
    
    # Task type breakdown
    local type_stats='{}'
    for task_id in "${!TASK_METADATA[@]}"; do
        local task_type
        task_type=$(echo "${TASK_METADATA[$task_id]}" | jq -r '.type')
        type_stats=$(echo "$type_stats" | jq --arg type "$task_type" '.[$type] = (.[$type] // 0) + 1')
    done
    
    echo "Tasks by Type:"
    echo "$type_stats" | jq -r 'to_entries[] | "  \(.key): \(.value)"'
    
    # Priority breakdown
    local priority_stats='{}'
    for task_id in "${!TASK_PRIORITIES[@]}"; do
        local priority="${TASK_PRIORITIES[$task_id]}"
        priority_stats=$(echo "$priority_stats" | jq --arg priority "$priority" '.[$priority] = (.[$priority] // 0) + 1')
    done
    
    echo
    echo "Tasks by Priority:"
    echo "$priority_stats" | jq -r 'to_entries[] | "  \(.key): \(.value)"'
}

# Handle monitor command
handle_monitor_command() {
    local duration="${1:-30}"
    
    if ! [[ "$duration" =~ ^[0-9]+$ ]]; then
        echo "Error: Monitor duration must be a number (seconds)"
        echo "Usage: monitor [duration_in_seconds]"
        return 1
    fi
    
    echo "Starting real-time monitoring for $duration seconds..."
    echo "Press Ctrl+C to stop early"
    echo
    
    start_realtime_monitoring "$duration"
}

# Handle locks command
handle_locks_command() {
    echo "Current Lock Status:"
    echo "==================="
    list_all_locks
}

# Handle cleanup command
handle_cleanup_command() {
    echo "Running maintenance cleanup..."
    
    local cleaned=0
    
    # Clean stale locks
    cleanup_all_stale_locks && ((cleaned++))
    
    # Clean old backups
    cleanup_old_backups && ((cleaned++))
    
    # Validate queue integrity
    validate_queue_integrity && ((cleaned++))
    
    echo "Cleanup completed ($cleaned operations)"
}

# Handle save command
handle_save_command() {
    echo "Saving queue state..."
    
    if save_queue_state true; then
        echo "Queue state saved successfully"
    else
        echo "Failed to save queue state"
        return 1
    fi
}

# Handle load command  
handle_load_command() {
    echo "Loading queue state..."
    
    if load_queue_state; then
        echo "Queue state loaded successfully"
        handle_status_command  # Show updated status
    else
        echo "Failed to load queue state"
        return 1
    fi
}

# Handle backup command
handle_backup_command() {
    local suffix="${1:-$(date +%Y%m%d-%H%M%S)}"
    
    echo "Creating backup with suffix: $suffix"
    
    if create_backup "$suffix"; then
        echo "Backup created successfully"
    else
        echo "Failed to create backup"
        return 1
    fi
}

# Show interactive help
show_interactive_help() {
    show_interactive_welcome
}

# ===============================================================================
# REAL-TIME MONITORING
# ===============================================================================

# Start real-time monitoring
start_realtime_monitoring() {
    local duration="${1:-30}"
    local end_time=$(($(date +%s) + duration))
    
    # Set up monitoring display
    local monitor_count=0
    
    while [[ $(date +%s) -lt $end_time ]]; do
        ((monitor_count++))
        
        # Clear screen and show header
        clear
        echo "==============================================================================="
        echo "Real-Time Task Queue Monitoring (Update #$monitor_count)"
        echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Remaining: $((end_time - $(date +%s))) seconds"
        echo "==============================================================================="
        echo
        
        # Show current status
        handle_status_command
        
        echo
        echo "Recent Activity:"
        echo "==============="
        
        # Show recent tasks (last 5)
        local recent_tasks
        recent_tasks=$(list_tasks "all" "json" | jq '.[-5:]')
        
        if [[ "$(echo "$recent_tasks" | jq length)" -gt 0 ]]; then
            printf "%-20s %-12s %-20s\n" "ID" "STATUS" "UPDATED"
            printf "%-20s %-12s %-20s\n" "----" "------" "-------"
            
            echo "$recent_tasks" | jq -r '.[] | [.id, .status, (.updated_at // .created_at)] | @tsv' | \
            while IFS=$'\t' read -r id status updated; do
                printf "%-20s %-12s %-20s\n" "$id" "$status" "$updated"
            done
        else
            echo "No recent activity"
        fi
        
        # Wait before next update
        sleep 2
    done
    
    echo
    echo "Monitoring completed"
}

# ===============================================================================
# CLEANUP AND UTILITIES
# ===============================================================================

# Cleanup interactive session
cleanup_interactive_session() {
    # Save command history if available
    if command -v history >/dev/null 2>&1; then
        history -w "$INTERACTIVE_HISTORY_FILE" 2>/dev/null || true
        
        # Trim history file to max size
        if [[ -f "$INTERACTIVE_HISTORY_FILE" ]]; then
            tail -n "$INTERACTIVE_MAX_HISTORY" "$INTERACTIVE_HISTORY_FILE" > "${INTERACTIVE_HISTORY_FILE}.tmp" 2>/dev/null && \
            mv "${INTERACTIVE_HISTORY_FILE}.tmp" "$INTERACTIVE_HISTORY_FILE" 2>/dev/null || \
            rm -f "${INTERACTIVE_HISTORY_FILE}.tmp" 2>/dev/null
        fi
    fi
}

# ===============================================================================
# UTILITY FUNCTIONS
# ===============================================================================

# Load required modules
load_required_modules() {
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    # Load core modules
    for module in core persistence locking; do
        local module_file="$script_dir/${module}.sh"
        if [[ -f "$module_file" ]]; then
            source "$module_file"
        else
            log_error "Required module not found: $module_file"
            return 1
        fi
    done
}

# NOTE: Logging functions moved to top of file to resolve dependency issues

# ===============================================================================
# MODULE INITIALIZATION
# ===============================================================================

# Load required modules when this script is sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Script is being executed directly
    load_required_modules || {
        echo "Failed to load required modules" >&2
        exit 1
    }
    
    # Start interactive mode
    run_interactive_mode
else
    # Script is being sourced
    load_required_modules || {
        log_error "Failed to load required modules for interactive mode"
        return 1
    }
fi