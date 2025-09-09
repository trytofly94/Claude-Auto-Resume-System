#!/usr/bin/env bash

# Claude Auto-Resume - Local Queue Operations Module
# Extensions for local queue task operations  
# Version: 2.0.0-local-queue
# Issue: #91

set -euo pipefail

# ===============================================================================
# LOCAL QUEUE TASK OPERATIONS
# ===============================================================================

# Add task to local queue
add_local_task() {
    local task_data="$1"
    local queue_file
    
    if ! is_local_queue_active; then
        log_error "No active local queue, cannot add task"
        return 1
    fi
    
    queue_file=$(get_local_queue_file) || return 1
    
    # Validate task structure
    if ! validate_task_structure "$task_data"; then
        log_error "Invalid task structure for local queue"
        return 1
    fi
    
    local task_id=$(echo "$task_data" | jq -r '.id')
    log_debug "Adding task to local queue: $task_id"
    
    # Check if task already exists
    if local_task_exists "$task_id"; then
        log_warn "Task $task_id already exists in local queue, updating instead"
        update_local_task "$task_id" "$task_data"
        return $?
    fi
    
    # Create backup before modification
    create_local_backup "before-add-$task_id" || log_warn "Failed to create backup"
    
    # Add task to queue file using atomic operation
    local temp_file="${queue_file}.tmp.$$"
    
    if jq --argjson task "$task_data" --arg timestamp "$(date -Iseconds)" '.tasks += [$task] | .last_modified = $timestamp' "$queue_file" > "$temp_file"; then
        if mv "$temp_file" "$queue_file"; then
            log_info "Task added to local queue: $task_id"
            return 0
        else
            log_error "Failed to update local queue file"
            rm -f "$temp_file"
            return 1
        fi
    else
        log_error "Failed to add task to local queue"
        rm -f "$temp_file"
        return 1
    fi
}

# Remove task from local queue
remove_local_task() {
    local task_id="$1"
    local queue_file
    
    if ! is_local_queue_active; then
        log_error "No active local queue, cannot remove task"
        return 1
    fi
    
    queue_file=$(get_local_queue_file) || return 1
    
    # Use cached task existence check if available
    if declare -f task_exists_cached >/dev/null 2>&1; then
        if ! task_exists_cached "$queue_file" "$task_id"; then
            log_error "Task $task_id not found in local queue"
            return 1
        fi
    else
        if ! local_task_exists "$task_id"; then
            log_error "Task $task_id not found in local queue"
            return 1
        fi
    fi
    
    log_debug "Removing task from local queue: $task_id"
    
    # Create backup before modification
    create_local_backup "before-remove-$task_id" || log_warn "Failed to create backup"
    
    # Remove task from queue file using atomic operation
    local temp_file="${queue_file}.tmp.$$"
    
    if jq --arg id "$task_id" --arg timestamp "$(date -Iseconds)" '.tasks = [.tasks[] | select(.id != $id)] | .last_modified = $timestamp' "$queue_file" > "$temp_file"; then
        if mv "$temp_file" "$queue_file"; then
            log_info "Task removed from local queue: $task_id"
            return 0
        else
            log_error "Failed to update local queue file"
            rm -f "$temp_file"
            return 1
        fi
    else
        log_error "Failed to remove task from local queue"
        rm -f "$temp_file"
        return 1
    fi
}

# Update task in local queue
update_local_task() {
    local task_id="$1"
    local task_data="$2"
    local queue_file
    
    if ! is_local_queue_active; then
        log_error "No active local queue, cannot update task"
        return 1
    fi
    
    queue_file=$(get_local_queue_file) || return 1
    
    # Use cached task existence check if available
    if declare -f task_exists_cached >/dev/null 2>&1; then
        if ! task_exists_cached "$queue_file" "$task_id"; then
            log_error "Task $task_id not found in local queue"
            return 1
        fi
    else
        if ! local_task_exists "$task_id"; then
            log_error "Task $task_id not found in local queue"
            return 1
        fi
    fi
    
    log_debug "Updating task in local queue: $task_id"
    
    # Create backup before modification
    create_local_backup "before-update-$task_id" || log_warn "Failed to create backup"
    
    # Update task in queue file using atomic operation
    local temp_file="${queue_file}.tmp.$$"
    
    if jq --arg id "$task_id" --argjson task "$task_data" --arg timestamp "$(date -Iseconds)" '
        .tasks = [.tasks[] | if .id == $id then $task else . end] | 
        .last_modified = $timestamp
    ' "$queue_file" > "$temp_file"; then
        if mv "$temp_file" "$queue_file"; then
            log_info "Task updated in local queue: $task_id"
            return 0
        else
            log_error "Failed to update local queue file"
            rm -f "$temp_file"
            return 1
        fi
    else
        log_error "Failed to update task in local queue"
        rm -f "$temp_file"
        return 1
    fi
}

# Get task from local queue
get_local_task() {
    local task_id="$1"
    local queue_file
    
    if ! is_local_queue_active; then
        log_error "No active local queue"
        return 1
    fi
    
    queue_file=$(get_local_queue_file) || return 1
    
    jq --arg id "$task_id" '.tasks[] | select(.id == $id)' "$queue_file" 2>/dev/null || {
        log_error "Task $task_id not found in local queue"
        return 1
    }
}

# List tasks from local queue
list_local_tasks() {
    local status_filter="${1:-all}"
    local format="${2:-json}"
    local queue_file
    
    if ! is_local_queue_active; then
        log_error "No active local queue"
        return 1
    fi
    
    queue_file=$(get_local_queue_file) || return 1
    
    local jq_filter
    if [[ "$status_filter" == "all" ]]; then
        jq_filter='.tasks'
    else
        jq_filter=".tasks[] | select(.status == \"$status_filter\")"
    fi
    
    case "$format" in
        "json")
            jq "$jq_filter" "$queue_file"
            ;;
        "table")
            local header="ID\tTYPE\tSTATUS\tDESCRIPTION\tCREATED"
            echo -e "$header"
            jq -r "$jq_filter | [.id, .type, .status, .description, .created_at] | @tsv" "$queue_file"
            ;;
        "summary")
            local pending=$(jq '[.tasks[] | select(.status == "pending")] | length' "$queue_file")
            local in_progress=$(jq '[.tasks[] | select(.status == "in_progress")] | length' "$queue_file")
            local completed=$(jq '[.tasks[] | select(.status == "completed")] | length' "$queue_file")
            local failed=$(jq '[.tasks[] | select(.status == "failed")] | length' "$queue_file")
            
            echo "Local Queue Summary ($LOCAL_PROJECT_NAME):"
            echo "  Pending: $pending"
            echo "  In Progress: $in_progress"
            echo "  Completed: $completed"
            echo "  Failed: $failed"
            ;;
        *)
            jq "$jq_filter" "$queue_file"
            ;;
    esac
}

# ===============================================================================
# LOCAL QUEUE BACKUP OPERATIONS
# ===============================================================================

# Create backup of local queue
create_local_backup() {
    local suffix="${1:-$(date +%Y%m%d-%H%M%S)}"
    local backup_dir
    local queue_file
    
    if ! is_local_queue_active; then
        log_error "No active local queue, cannot create backup"
        return 1
    fi
    
    backup_dir=$(get_local_backup_dir) || return 1
    queue_file=$(get_local_queue_file) || return 1
    
    local backup_file="$backup_dir/queue-$suffix.json"
    
    if cp "$queue_file" "$backup_file"; then
        log_debug "Local queue backup created: $backup_file"
        return 0
    else
        log_error "Failed to create local queue backup"
        return 1
    fi
}

# Restore local queue from backup
restore_local_backup() {
    local backup_name="$1"
    local backup_dir
    local queue_file
    
    if ! is_local_queue_active; then
        log_error "No active local queue, cannot restore backup"
        return 1
    fi
    
    backup_dir=$(get_local_backup_dir) || return 1
    queue_file=$(get_local_queue_file) || return 1
    
    local backup_file="$backup_dir/$backup_name"
    
    if [[ ! -f "$backup_file" ]]; then
        log_error "Backup file not found: $backup_file"
        return 1
    fi
    
    # Validate backup file before restore
    if ! jq empty "$backup_file" 2>/dev/null; then
        log_error "Backup file is corrupted: $backup_file"
        return 1
    fi
    
    # Create backup of current state before restore
    create_local_backup "before-restore" || log_warn "Failed to create backup before restore"
    
    if cp "$backup_file" "$queue_file"; then
        log_info "Local queue restored from backup: $backup_name"
        return 0
    else
        log_error "Failed to restore local queue from backup"
        return 1
    fi
}

# List available local backups
list_local_backups() {
    local format="${1:-simple}"
    local backup_dir
    
    if ! is_local_queue_active; then
        log_error "No active local queue"
        return 1
    fi
    
    backup_dir=$(get_local_backup_dir) || return 1
    
    case "$format" in
        "detailed")
            echo "Local Queue Backups ($LOCAL_PROJECT_NAME):"
            find "$backup_dir" -name "queue-*.json" -type f -exec ls -lh {} \; | sort -k9
            ;;
        "json")
            find "$backup_dir" -name "queue-*.json" -type f -printf '{"file":"%f","size":"%s","modified":"%T@"}\n' | jq -s .
            ;;
        *)
            find "$backup_dir" -name "queue-*.json" -type f -printf "%f\n" | sort
            ;;
    esac
}

# Cleanup old local backups
cleanup_local_backups() {
    local retention_days="${1:-30}"
    local backup_dir
    
    if ! is_local_queue_active; then
        log_error "No active local queue"
        return 1
    fi
    
    backup_dir=$(get_local_backup_dir) || return 1
    
    local count=0
    while IFS= read -r -d '' file; do
        rm "$file"
        ((count++))
        log_debug "Removed old backup: $(basename "$file")"
    done < <(find "$backup_dir" -name "queue-*.json" -type f -mtime "+$retention_days" -print0)
    
    if [[ $count -gt 0 ]]; then
        log_info "Cleaned up $count old local backups (older than $retention_days days)"
    else
        log_debug "No old local backups to clean up"
    fi
    
    echo $count
}

# ===============================================================================
# CONTEXT SWITCHING OPERATIONS
# ===============================================================================

# Switch to local context if available, fallback to global
auto_switch_context() {
    if detect_local_queue; then
        log_debug "Automatically switched to local queue context: $LOCAL_QUEUE_PATH"
        return 0
    else
        force_global_context
        log_debug "No local queue found, using global context"
        return 1
    fi
}

# Ensure context is appropriate for operation
ensure_context() {
    local required_context="${1:-any}"  # local, global, any
    
    case "$required_context" in
        "local")
            if ! is_local_queue_active; then
                log_error "Local queue context required but not active"
                return 1
            fi
            ;;
        "global")
            if is_local_queue_active; then
                log_error "Global queue context required but local queue is active"
                return 1
            fi
            ;;
        "any")
            # No specific requirement
            return 0
            ;;
        *)
            log_error "Unknown context requirement: $required_context"
            return 1
            ;;
    esac
    
    return 0
}

# ===============================================================================
# LOGGING FUNCTIONS (fallback if not loaded)
# ===============================================================================

# Fallback logging functions if main logging module not loaded
if ! declare -f log_debug >/dev/null 2>&1; then
    log_debug() { echo "[LOCAL-OPS] [DEBUG] $*" >&2; }
    log_info() { echo "[LOCAL-OPS] [INFO] $*" >&2; }
    log_warn() { echo "[LOCAL-OPS] [WARN] $*" >&2; }
    log_error() { echo "[LOCAL-OPS] [ERROR] $*" >&2; }
fi

log_debug "Local queue operations module loaded"