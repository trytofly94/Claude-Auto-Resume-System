#!/usr/bin/env bash

# Claude Auto-Resume - Task Queue Cleanup Module
# Maintenance and cleanup operations for task queue
# Version: 2.0.0-refactored

set -euo pipefail

# ===============================================================================
# CLEANUP CONSTANTS
# ===============================================================================

TASK_AUTO_CLEANUP_DAYS="${TASK_AUTO_CLEANUP_DAYS:-7}"
TASK_BACKUP_RETENTION_DAYS="${TASK_BACKUP_RETENTION_DAYS:-30}"
CLEANUP_LOG_RETENTION_DAYS="${CLEANUP_LOG_RETENTION_DAYS:-14}"
MAX_QUEUE_SIZE="${TASK_QUEUE_MAX_SIZE:-0}"  # 0 = unlimited

# ===============================================================================
# CORE CLEANUP FUNCTIONS
# ===============================================================================

# Run complete cleanup routine
run_full_cleanup() {
    local cleanup_report='{
        "started_at": "'$(date -Iseconds)'",
        "operations": []
    }'
    
    log_info "Starting full cleanup routine"
    
    # 1. Clean completed tasks
    local completed_cleaned
    completed_cleaned=$(cleanup_completed_tasks "$TASK_AUTO_CLEANUP_DAYS")
    cleanup_report=$(echo "$cleanup_report" | jq \
        --argjson count "$completed_cleaned" \
        '.operations += [{"type": "completed_tasks", "cleaned": $count}]')
    
    # 2. Clean failed tasks (older than double the retention)
    local failed_cleaned
    failed_cleaned=$(cleanup_failed_tasks "$((TASK_AUTO_CLEANUP_DAYS * 2))")
    cleanup_report=$(echo "$cleanup_report" | jq \
        --argjson count "$failed_cleaned" \
        '.operations += [{"type": "failed_tasks", "cleaned": $count}]')
    
    # 3. Clean old backups
    local backups_cleaned
    backups_cleaned=$(cleanup_old_backups_with_count "$TASK_BACKUP_RETENTION_DAYS")
    cleanup_report=$(echo "$cleanup_report" | jq \
        --argjson count "$backups_cleaned" \
        '.operations += [{"type": "old_backups", "cleaned": $count}]')
    
    # 4. Clean stale locks
    local locks_cleaned
    locks_cleaned=$(cleanup_stale_locks_with_count)
    cleanup_report=$(echo "$cleanup_report" | jq \
        --argjson count "$locks_cleaned" \
        '.operations += [{"type": "stale_locks", "cleaned": $count}]')
    
    # 5. Clean temporary files
    local temp_cleaned
    temp_cleaned=$(cleanup_temp_files)
    cleanup_report=$(echo "$cleanup_report" | jq \
        --argjson count "$temp_cleaned" \
        '.operations += [{"type": "temp_files", "cleaned": $count}]')
    
    # 6. Validate and repair queue integrity
    local integrity_fixed
    integrity_fixed=$(validate_and_repair_queue)
    cleanup_report=$(echo "$cleanup_report" | jq \
        --argjson fixed "$integrity_fixed" \
        '.operations += [{"type": "integrity_repair", "fixed": $fixed}]')
    
    # 7. Enforce queue size limits
    local size_limited
    size_limited=$(enforce_queue_size_limits)
    cleanup_report=$(echo "$cleanup_report" | jq \
        --argjson removed "$size_limited" \
        '.operations += [{"type": "size_enforcement", "removed": $removed}]')
    
    # Finalize report
    cleanup_report=$(echo "$cleanup_report" | jq \
        --arg completed_at "$(date -Iseconds)" \
        '.completed_at = $completed_at')
    
    local total_cleaned
    total_cleaned=$(echo "$cleanup_report" | jq '[.operations[].cleaned // .operations[].fixed // .operations[].removed] | add')
    
    log_info "Full cleanup completed: $total_cleaned items processed"
    
    # Save cleanup report
    save_cleanup_report "$cleanup_report"
    
    echo "$cleanup_report"
    return 0
}

# ===============================================================================
# SPECIFIC CLEANUP OPERATIONS
# ===============================================================================

# Clean completed tasks older than specified days
cleanup_completed_tasks() {
    local retention_days="${1:-$TASK_AUTO_CLEANUP_DAYS}"
    local cleaned_count=0
    
    local cutoff_timestamp
    cutoff_timestamp=$(date -d "${retention_days} days ago" +%s 2>/dev/null || \
                      date -v-"${retention_days}d" +%s 2>/dev/null || {
        log_error "Cannot calculate cutoff date for cleanup"
        echo "0"
        return 1
    })
    
    log_debug "Cleaning completed tasks older than $retention_days days (cutoff: $cutoff_timestamp)"
    
    local tasks_to_remove=()
    
    for task_id in "${!TASK_STATES[@]}"; do
        local status="${TASK_STATES[$task_id]}"
        
        if [[ "$status" == "$TASK_STATE_COMPLETED" ]]; then
            local task_timestamp="${TASK_TIMESTAMPS[$task_id]}"
            
            if [[ "$task_timestamp" -lt "$cutoff_timestamp" ]]; then
                tasks_to_remove+=("$task_id")
            fi
        fi
    done
    
    # Remove old completed tasks
    for task_id in "${tasks_to_remove[@]}"; do
        if remove_task "$task_id"; then
            ((cleaned_count++))
            log_debug "Cleaned completed task: $task_id"
        fi
    done
    
    if [[ $cleaned_count -gt 0 ]]; then
        log_info "Cleaned $cleaned_count completed tasks older than $retention_days days"
        save_queue_state false  # Save without backup after cleanup
    fi
    
    echo "$cleaned_count"
}

# Clean failed tasks older than specified days
cleanup_failed_tasks() {
    local retention_days="${1:-$((TASK_AUTO_CLEANUP_DAYS * 2))}"
    local cleaned_count=0
    
    local cutoff_timestamp
    cutoff_timestamp=$(date -d "${retention_days} days ago" +%s 2>/dev/null || \
                      date -v-"${retention_days}d" +%s 2>/dev/null || {
        log_error "Cannot calculate cutoff date for failed task cleanup"
        echo "0"
        return 1
    })
    
    log_debug "Cleaning failed tasks older than $retention_days days"
    
    local tasks_to_remove=()
    
    for task_id in "${!TASK_STATES[@]}"; do
        local status="${TASK_STATES[$task_id]}"
        
        if [[ "$status" == "$TASK_STATE_FAILED" ]] || [[ "$status" == "$TASK_STATE_TIMEOUT" ]]; then
            local task_timestamp="${TASK_TIMESTAMPS[$task_id]}"
            
            if [[ "$task_timestamp" -lt "$cutoff_timestamp" ]]; then
                tasks_to_remove+=("$task_id")
            fi
        fi
    done
    
    # Remove old failed tasks
    for task_id in "${tasks_to_remove[@]}"; do
        if remove_task "$task_id"; then
            ((cleaned_count++))
            log_debug "Cleaned failed task: $task_id"
        fi
    done
    
    if [[ $cleaned_count -gt 0 ]]; then
        log_info "Cleaned $cleaned_count failed tasks older than $retention_days days"
        save_queue_state false
    fi
    
    echo "$cleaned_count"
}

# Clean old backups with count return
cleanup_old_backups_with_count() {
    local retention_days="${1:-$TASK_BACKUP_RETENTION_DAYS}"
    
    if [[ ! -d "$TASK_BACKUP_DIR" ]]; then
        echo "0"
        return 0
    fi
    
    local cleaned_count=0
    local cutoff_timestamp
    cutoff_timestamp=$(date -d "${retention_days} days ago" +%s 2>/dev/null || \
                      date -v-"${retention_days}d" +%s 2>/dev/null || {
        log_error "Cannot calculate cutoff date for backup cleanup"
        echo "0"
        return 1
    })
    
    while IFS= read -r -d '' backup_file; do
        local file_timestamp
        if command -v stat >/dev/null 2>&1; then
            if file_timestamp=$(stat -c %Y "$backup_file" 2>/dev/null); then
                : # GNU stat worked
            elif file_timestamp=$(stat -f %m "$backup_file" 2>/dev/null); then
                : # BSD stat worked
            else
                log_warn "Cannot determine age of backup: $backup_file"
                continue
            fi
        else
            continue
        fi
        
        if [[ $file_timestamp -lt $cutoff_timestamp ]]; then
            if rm "$backup_file" 2>/dev/null; then
                ((cleaned_count++))
                log_debug "Cleaned old backup: $backup_file"
            fi
        fi
    done < <(find "$TASK_BACKUP_DIR" -name "backup-*.json*" -print0 2>/dev/null || true)
    
    if [[ $cleaned_count -gt 0 ]]; then
        log_info "Cleaned $cleaned_count old backup files older than $retention_days days"
    fi
    
    echo "$cleaned_count"
}

# Clean stale locks with count return
cleanup_stale_locks_with_count() {
    local cleaned_count=0
    
    if [[ ! -d "$QUEUE_LOCK_DIR" ]]; then
        echo "0"
        return 0
    fi
    
    for lock_file in "$QUEUE_LOCK_DIR"/*.lock; do
        if [[ -f "$lock_file" ]] && is_lock_stale "$lock_file"; then
            if rm -f "$lock_file" 2>/dev/null; then
                ((cleaned_count++))
                log_debug "Cleaned stale lock: $lock_file"
            fi
        fi
    done
    
    if [[ $cleaned_count -gt 0 ]]; then
        log_info "Cleaned $cleaned_count stale lock files"
    fi
    
    echo "$cleaned_count"
}

# Clean temporary files
cleanup_temp_files() {
    local cleaned_count=0
    local temp_patterns=(
        "${TASK_QUEUE_DIR:-queue}/tmp/*"
        "${TASK_QUEUE_DIR:-queue}/*.tmp*"
        "${TASK_QUEUE_DIR:-queue}/*.lock.tmp*"
    )
    
    for pattern in "${temp_patterns[@]}"; do
        for temp_file in $pattern; do
            if [[ -f "$temp_file" ]]; then
                # Only remove files older than 1 hour
                local file_age
                if command -v stat >/dev/null 2>&1; then
                    if file_age=$(stat -c %Y "$temp_file" 2>/dev/null); then
                        : # GNU stat worked
                    elif file_age=$(stat -f %m "$temp_file" 2>/dev/null); then
                        : # BSD stat worked
                    else
                        continue
                    fi
                else
                    continue
                fi
                
                local current_time=$(date +%s)
                local age_hours=$(( (current_time - file_age) / 3600 ))
                
                if [[ $age_hours -gt 1 ]]; then
                    if rm -f "$temp_file" 2>/dev/null; then
                        ((cleaned_count++))
                        log_debug "Cleaned temp file: $temp_file"
                    fi
                fi
            fi
        done
    done
    
    if [[ $cleaned_count -gt 0 ]]; then
        log_info "Cleaned $cleaned_count temporary files"
    fi
    
    echo "$cleaned_count"
}

# Validate and repair queue integrity
validate_and_repair_queue() {
    local fixed_count=0
    
    # Check for orphaned entries and fix them
    local orphaned_states=()
    local orphaned_metadata=()
    
    # Find orphaned state entries
    for task_id in "${!TASK_STATES[@]}"; do
        if [[ -z "${TASK_METADATA[$task_id]:-}" ]]; then
            orphaned_states+=("$task_id")
        fi
    done
    
    # Find orphaned metadata entries
    for task_id in "${!TASK_METADATA[@]}"; do
        if [[ -z "${TASK_STATES[$task_id]:-}" ]]; then
            orphaned_metadata+=("$task_id")
        fi
    done
    
    # Fix orphaned state entries (remove them)
    for task_id in "${orphaned_states[@]}"; do
        unset TASK_STATES["$task_id"]
        unset TASK_RETRY_COUNTS["$task_id"] 2>/dev/null || true
        unset TASK_TIMESTAMPS["$task_id"] 2>/dev/null || true
        unset TASK_PRIORITIES["$task_id"] 2>/dev/null || true
        ((fixed_count++))
        log_debug "Fixed orphaned state entry: $task_id"
    done
    
    # Fix orphaned metadata entries (remove them)
    for task_id in "${orphaned_metadata[@]}"; do
        unset TASK_METADATA["$task_id"]
        ((fixed_count++))
        log_debug "Fixed orphaned metadata entry: $task_id"
    done
    
    # Validate JSON structure of metadata
    for task_id in "${!TASK_METADATA[@]}"; do
        local task_data="${TASK_METADATA[$task_id]}"
        
        if ! echo "$task_data" | jq empty >/dev/null 2>&1; then
            log_warn "Removing task with invalid JSON metadata: $task_id"
            remove_task "$task_id"
            ((fixed_count++))
        fi
    done
    
    if [[ $fixed_count -gt 0 ]]; then
        log_info "Fixed $fixed_count queue integrity issues"
        save_queue_state false
    fi
    
    echo "$fixed_count"
}

# Enforce queue size limits
enforce_queue_size_limits() {
    local removed_count=0
    
    if [[ "$MAX_QUEUE_SIZE" -eq 0 ]]; then
        echo "0"  # No size limit
        return 0
    fi
    
    local current_size=${#TASK_STATES[@]}
    
    if [[ $current_size -le $MAX_QUEUE_SIZE ]]; then
        echo "0"  # Within limit
        return 0
    fi
    
    local excess_count=$((current_size - MAX_QUEUE_SIZE))
    
    log_info "Queue size ($current_size) exceeds limit ($MAX_QUEUE_SIZE), removing $excess_count oldest completed tasks"
    
    # Get oldest completed tasks
    local oldest_completed=()
    
    for task_id in "${!TASK_STATES[@]}"; do
        local status="${TASK_STATES[$task_id]}"
        
        if [[ "$status" == "$TASK_STATE_COMPLETED" ]]; then
            oldest_completed+=("$task_id:${TASK_TIMESTAMPS[$task_id]}")
        fi
    done
    
    # Sort by timestamp and remove oldest
    if [[ ${#oldest_completed[@]} -gt 0 ]]; then
        local sorted_tasks
        readarray -t sorted_tasks < <(printf '%s\n' "${oldest_completed[@]}" | sort -t: -k2 -n)
        
        for ((i=0; i<excess_count && i<${#sorted_tasks[@]}; i++)); do
            local task_entry="${sorted_tasks[$i]}"
            local task_id="${task_entry%%:*}"
            
            if remove_task "$task_id"; then
                ((removed_count++))
                log_debug "Removed oldest completed task for size limit: $task_id"
            fi
            
            # Check if we've reached the limit
            if [[ ${#TASK_STATES[@]} -le $MAX_QUEUE_SIZE ]]; then
                break
            fi
        done
    fi
    
    # If still over limit, remove oldest failed tasks
    if [[ ${#TASK_STATES[@]} -gt $MAX_QUEUE_SIZE ]]; then
        local remaining_excess=$((${#TASK_STATES[@]} - MAX_QUEUE_SIZE))
        local oldest_failed=()
        
        for task_id in "${!TASK_STATES[@]}"; do
            local status="${TASK_STATES[$task_id]}"
            
            if [[ "$status" == "$TASK_STATE_FAILED" ]] || [[ "$status" == "$TASK_STATE_TIMEOUT" ]]; then
                oldest_failed+=("$task_id:${TASK_TIMESTAMPS[$task_id]}")
            fi
        done
        
        if [[ ${#oldest_failed[@]} -gt 0 ]]; then
            readarray -t sorted_failed < <(printf '%s\n' "${oldest_failed[@]}" | sort -t: -k2 -n)
            
            for ((i=0; i<remaining_excess && i<${#sorted_failed[@]}; i++)); do
                local task_entry="${sorted_failed[$i]}"
                local task_id="${task_entry%%:*}"
                
                if remove_task "$task_id"; then
                    ((removed_count++))
                    log_debug "Removed oldest failed task for size limit: $task_id"
                fi
                
                if [[ ${#TASK_STATES[@]} -le $MAX_QUEUE_SIZE ]]; then
                    break
                fi
            done
        fi
    fi
    
    if [[ $removed_count -gt 0 ]]; then
        log_info "Removed $removed_count tasks to enforce queue size limit"
        save_queue_state false
    fi
    
    echo "$removed_count"
}

# ===============================================================================
# CLEANUP SCHEDULING AND AUTOMATION
# ===============================================================================

# Run automatic cleanup based on configuration
run_auto_cleanup() {
    local force="${1:-false}"
    local cleanup_marker="${TASK_QUEUE_DIR:-queue}/.last_cleanup"
    
    # Check if cleanup is needed
    local should_cleanup=false
    
    if [[ "$force" == "true" ]]; then
        should_cleanup=true
    elif [[ ! -f "$cleanup_marker" ]]; then
        should_cleanup=true
    else
        local last_cleanup
        last_cleanup=$(cat "$cleanup_marker" 2>/dev/null || echo "0")
        
        local current_time=$(date +%s)
        local cleanup_interval=$((24 * 3600))  # 24 hours
        
        if [[ $((current_time - last_cleanup)) -gt $cleanup_interval ]]; then
            should_cleanup=true
        fi
    fi
    
    if [[ "$should_cleanup" == "true" ]]; then
        log_info "Running automatic cleanup"
        
        local cleanup_result
        cleanup_result=$(run_full_cleanup)
        
        # Update cleanup marker
        date +%s > "$cleanup_marker"
        
        echo "$cleanup_result"
    else
        log_debug "Automatic cleanup not needed yet"
        echo '{"skipped": true, "reason": "not_needed"}'
    fi
}

# ===============================================================================
# CLEANUP REPORTING
# ===============================================================================

# Save cleanup report to file
save_cleanup_report() {
    local cleanup_report="$1"
    
    ensure_queue_directories
    
    local reports_dir="${TASK_QUEUE_DIR:-queue}/reports"
    mkdir -p "$reports_dir" 2>/dev/null || true
    
    local report_file="$reports_dir/cleanup-$(date +%Y%m%d-%H%M%S).json"
    
    echo "$cleanup_report" > "$report_file" 2>/dev/null && \
    log_debug "Saved cleanup report: $report_file"
}

# Get cleanup history
get_cleanup_history() {
    local limit="${1:-10}"
    local reports_dir="${TASK_QUEUE_DIR:-queue}/reports"
    
    if [[ ! -d "$reports_dir" ]]; then
        echo "[]"
        return 0
    fi
    
    local history="[]"
    local report_count=0
    
    for report_file in "$reports_dir"/cleanup-*.json; do
        if [[ -f "$report_file" ]] && [[ $report_count -lt $limit ]]; then
            local report_data
            report_data=$(cat "$report_file" 2>/dev/null || echo '{}')
            
            if [[ "$report_data" != '{}' ]]; then
                history=$(echo "$history" | jq --argjson report "$report_data" '. += [$report]')
                ((report_count++))
            fi
        fi
    done
    
    # Sort by started_at timestamp (newest first)
    echo "$history" | jq 'sort_by(.started_at) | reverse'
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