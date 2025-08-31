#!/usr/bin/env bash

# Claude Auto-Resume - Task Queue Persistence Module
# Focused JSON save/load operations with backup management
# Version: 2.0.0-refactored

set -euo pipefail

# ===============================================================================
# PERSISTENCE CONSTANTS
# ===============================================================================

TASK_QUEUE_DIR="${TASK_QUEUE_DIR:-queue}"
TASK_QUEUE_FILE="$TASK_QUEUE_DIR/task-queue.json"
TASK_BACKUP_DIR="$TASK_QUEUE_DIR/backups"
TASK_BACKUP_RETENTION_DAYS="${TASK_BACKUP_RETENTION_DAYS:-30}"

# ===============================================================================
# DIRECTORY MANAGEMENT
# ===============================================================================

# Ensure queue directories exist
ensure_queue_directories() {
    local dirs=("$TASK_QUEUE_DIR" "$TASK_BACKUP_DIR")
    
    for dir in "${dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir" 2>/dev/null || {
                log_error "Failed to create directory: $dir"
                return 1
            }
            log_debug "Created directory: $dir"
        fi
    done
    
    return 0
}

# ===============================================================================
# CORE PERSISTENCE FUNCTIONS
# ===============================================================================

# Save queue state to JSON using current global state
save_queue_state() {
    local backup_before="${1:-true}"
    
    ensure_queue_directories || return 1
    
    # Create backup before save if requested
    if [[ "$backup_before" == "true" ]] && [[ -f "$TASK_QUEUE_FILE" ]]; then
        create_backup "before-save" || log_warn "Backup creation failed"
    fi
    
    # Build JSON from global state arrays
    local queue_json='{
        "version": "2.0.0",
        "timestamp": "'$(date -Iseconds)'",  
        "tasks": []
    }'
    
    # Add all tasks from global state
    log_debug "save_queue_state: Starting with ${#TASK_METADATA[@]} tasks in TASK_METADATA"
    for task_id in "${!TASK_METADATA[@]}"; do
        log_debug "save_queue_state: Processing task_id: $task_id"
        local task_data="${TASK_METADATA[$task_id]}"
        
        # Ensure task has current status and retry count
        task_data=$(echo "$task_data" | jq \
            --arg status "${TASK_STATES[$task_id]}" \
            --arg retries "${TASK_RETRY_COUNTS[$task_id]:-0}" \
            --arg priority "${TASK_PRIORITIES[$task_id]:-normal}" \
            '.status = $status | .retry_count = ($retries | tonumber) | .priority = $priority')
        
        queue_json=$(echo "$queue_json" | jq --argjson task "$task_data" '.tasks += [$task]')
        log_debug "save_queue_state: Added task $task_id to queue_json"
    done
    
    # Write atomically using temporary file
    local temp_file="${TASK_QUEUE_FILE}.tmp.$$"
    
    if echo "$queue_json" | jq '.' > "$temp_file" 2>/dev/null; then
        if mv "$temp_file" "$TASK_QUEUE_FILE"; then
            log_info "Queue state saved: $(echo "$queue_json" | jq '.tasks | length') tasks"
            return 0
        else
            log_error "Failed to move temporary file to $TASK_QUEUE_FILE"
            rm -f "$temp_file"
            return 1
        fi
    else
        log_error "Failed to write queue state to temporary file"
        rm -f "$temp_file"
        return 1
    fi
}

# Load queue state from JSON into global state arrays
load_queue_state() {
    if [[ ! -f "$TASK_QUEUE_FILE" ]]; then
        log_info "No existing queue file, starting with empty queue"
        initialize_empty_queue
        return 0
    fi
    
    # Validate JSON structure
    if ! jq empty "$TASK_QUEUE_FILE" 2>/dev/null; then
        log_error "Invalid JSON in queue file: $TASK_QUEUE_FILE"
        return 1
    fi
    
    # Clear global state arrays
    TASK_STATES=()
    TASK_METADATA=()
    TASK_RETRY_COUNTS=()
    TASK_TIMESTAMPS=()
    TASK_PRIORITIES=()
    
    # Load tasks from JSON
    local task_count=0
    
    while IFS= read -r task_json; do
        if [[ -n "$task_json" ]] && [[ "$task_json" != "null" ]]; then
            local task_id
            task_id=$(echo "$task_json" | jq -r '.id')
            
            if [[ -n "$task_id" ]] && [[ "$task_id" != "null" ]]; then
                # Load into global state arrays
                TASK_STATES["$task_id"]=$(echo "$task_json" | jq -r '.status')
                TASK_METADATA["$task_id"]="$task_json"
                TASK_RETRY_COUNTS["$task_id"]=$(echo "$task_json" | jq -r '.retry_count // "0"')
                TASK_TIMESTAMPS["$task_id"]=$(echo "$task_json" | jq -r '.created_at // empty' | xargs -I {} date -d {} +%s 2>/dev/null || date +%s)
                TASK_PRIORITIES["$task_id"]=$(echo "$task_json" | jq -r '.priority // "normal"')
                
                ((task_count++))
            fi
        fi
    done < <(jq -c '.tasks[]?' "$TASK_QUEUE_FILE" 2>/dev/null || echo)
    
    log_info "Loaded queue state: $task_count tasks"
    return 0
}

# Initialize empty queue structure
initialize_empty_queue() {
    ensure_queue_directories || return 1
    
    local empty_queue='{
        "version": "2.0.0",
        "timestamp": "'$(date -Iseconds)'",
        "tasks": []
    }'
    
    echo "$empty_queue" | jq '.' > "$TASK_QUEUE_FILE" || {
        log_error "Failed to initialize empty queue"
        return 1
    }
    
    log_info "Initialized empty queue"
    return 0
}

# ===============================================================================
# BACKUP MANAGEMENT  
# ===============================================================================

# Create backup of current queue file
create_backup() {
    local suffix="${1:-$(date +%Y%m%d-%H%M%S)}"
    
    if [[ ! -f "$TASK_QUEUE_FILE" ]]; then
        log_debug "No queue file to backup"
        return 0
    fi
    
    ensure_queue_directories || return 1
    
    local backup_file="$TASK_BACKUP_DIR/backup-${suffix}.json"
    
    if cp "$TASK_QUEUE_FILE" "$backup_file" 2>/dev/null; then
        log_debug "Created backup: $backup_file"
        return 0
    else
        log_error "Failed to create backup: $backup_file"
        return 1
    fi
}

# Restore from backup
restore_from_backup() {
    local backup_file="$1"
    
    if [[ ! -f "$backup_file" ]]; then
        log_error "Backup file not found: $backup_file"
        return 1
    fi
    
    # Validate backup JSON
    if ! jq empty "$backup_file" 2>/dev/null; then
        log_error "Invalid JSON in backup file: $backup_file"
        return 1
    fi
    
    # Create backup of current state before restore
    create_backup "before-restore-$(date +%Y%m%d-%H%M%S)" || log_warn "Failed to backup current state"
    
    # Restore backup
    if cp "$backup_file" "$TASK_QUEUE_FILE" 2>/dev/null; then
        log_info "Restored from backup: $backup_file"
        # Reload state after restore
        load_queue_state
        return 0
    else
        log_error "Failed to restore from backup: $backup_file"
        return 1
    fi
}

# List available backups
list_backups() {
    local format="${1:-simple}"
    
    if [[ ! -d "$TASK_BACKUP_DIR" ]]; then
        echo "No backup directory found"
        return 1
    fi
    
    local backups=()
    while IFS= read -r -d '' backup; do
        backups+=("$backup")
    done < <(find "$TASK_BACKUP_DIR" -name "backup-*.json" -print0 | sort -z)
    
    if [[ ${#backups[@]} -eq 0 ]]; then
        echo "No backups found"
        return 1
    fi
    
    case "$format" in
        "simple")
            printf '%s\n' "${backups[@]}"
            ;;
        "detailed")
            for backup in "${backups[@]}"; do
                local size
                size=$(du -h "$backup" 2>/dev/null | cut -f1 || echo "unknown")
                local modified
                modified=$(stat -c %y "$backup" 2>/dev/null || stat -f %Sm "$backup" 2>/dev/null || echo "unknown")
                echo "$backup (${size}, modified: $modified)"
            done
            ;;
        "json")
            local backup_list="[]"
            for backup in "${backups[@]}"; do
                local backup_info='{
                    "file": "'$backup'",
                    "size": "'$(du -b "$backup" 2>/dev/null | cut -f1 || echo 0)'",
                    "modified": "'$(stat -c %Y "$backup" 2>/dev/null || stat -f %m "$backup" 2>/dev/null || echo 0)'"
                }'
                backup_list=$(echo "$backup_list" | jq --argjson info "$backup_info" '. += [$info]')
            done
            echo "$backup_list"
            ;;
    esac
}

# Clean up old backups based on retention policy
cleanup_old_backups() {
    local retention_days="${1:-$TASK_BACKUP_RETENTION_DAYS}"
    
    if [[ ! -d "$TASK_BACKUP_DIR" ]]; then
        log_debug "No backup directory to clean"
        return 0
    fi
    
    local deleted_count=0
    local cutoff_date=$(date -d "${retention_days} days ago" +%s 2>/dev/null || date -v-"${retention_days}d" +%s 2>/dev/null || {
        log_warn "Could not calculate cutoff date for backup cleanup"
        return 1
    })
    
    while IFS= read -r -d '' backup_file; do
        local file_date
        if command -v stat >/dev/null 2>&1; then
            if file_date=$(stat -c %Y "$backup_file" 2>/dev/null); then
                : # GNU stat worked
            elif file_date=$(stat -f %m "$backup_file" 2>/dev/null); then  
                : # BSD stat worked
            else
                log_warn "Cannot determine age of backup: $backup_file"
                continue
            fi
        else
            log_warn "stat command not available, skipping backup cleanup"
            return 1
        fi
        
        if [[ $file_date -lt $cutoff_date ]]; then
            if rm "$backup_file" 2>/dev/null; then
                log_debug "Deleted old backup: $backup_file"
                ((deleted_count++))
            else
                log_warn "Failed to delete backup: $backup_file"
            fi
        fi
    done < <(find "$TASK_BACKUP_DIR" -name "backup-*.json" -print0)
    
    if [[ $deleted_count -gt 0 ]]; then
        log_info "Cleaned up $deleted_count old backups (older than $retention_days days)"
    fi
    
    return 0
}

# ===============================================================================
# UTILITY FUNCTIONS
# ===============================================================================

# Validate queue file integrity
validate_queue_file() {
    local file="${1:-$TASK_QUEUE_FILE}"
    
    if [[ ! -f "$file" ]]; then
        log_error "Queue file not found: $file"
        return 1
    fi
    
    # Check JSON validity
    if ! jq empty "$file" 2>/dev/null; then
        log_error "Invalid JSON in queue file: $file"
        return 1
    fi
    
    # Check required structure
    local required_fields=("version" "timestamp" "tasks")
    for field in "${required_fields[@]}"; do
        if ! jq -e ".$field" "$file" >/dev/null 2>&1; then
            log_error "Missing required field '$field' in queue file: $file"
            return 1
        fi
    done
    
    log_info "Queue file validation passed: $file"
    return 0
}

# Get queue file statistics
get_queue_file_stats() {
    if [[ ! -f "$TASK_QUEUE_FILE" ]]; then
        echo '{"exists": false}'
        return 1
    fi
    
    local file_size
    file_size=$(du -b "$TASK_QUEUE_FILE" 2>/dev/null | cut -f1 || echo 0)
    
    local task_count
    task_count=$(jq '.tasks | length' "$TASK_QUEUE_FILE" 2>/dev/null || echo 0)
    
    local last_modified
    last_modified=$(stat -c %Y "$TASK_QUEUE_FILE" 2>/dev/null || stat -f %m "$TASK_QUEUE_FILE" 2>/dev/null || echo 0)
    
    jq -n \
        --arg size "$file_size" \
        --arg tasks "$task_count" \
        --arg modified "$last_modified" \
        --arg file "$TASK_QUEUE_FILE" \
        '{
            "exists": true,
            "file": $file,
            "size_bytes": ($size | tonumber),
            "task_count": ($tasks | tonumber), 
            "last_modified": ($modified | tonumber)
        }'
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