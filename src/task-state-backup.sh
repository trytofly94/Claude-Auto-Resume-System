#!/usr/bin/env bash

# Claude Auto-Resume - Task State Backup System
# Local Backup and State Preservation System
# Version: 1.0.0-alpha
# Created: 2025-08-27

set -euo pipefail

# ===============================================================================
# GLOBALE VARIABLEN UND KONSTANTEN
# ===============================================================================

# Standard-Konfiguration (wird von config/default.conf überschrieben)
BACKUP_ENABLED="${BACKUP_ENABLED:-true}"
BACKUP_RETENTION_HOURS="${BACKUP_RETENTION_HOURS:-168}"    # 1 week
BACKUP_CHECKPOINT_FREQUENCY="${BACKUP_CHECKPOINT_FREQUENCY:-1800}"  # 30 minutes
BACKUP_COMPRESSION="${BACKUP_COMPRESSION:-false}"

# Backup directories and tracking
BACKUP_DIR=""
CHECKPOINT_TRACKING=()

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
# BACKUP SYSTEM INITIALIZATION
# ===============================================================================

# Initialize backup system
initialize_backup_system() {
    if [[ "$BACKUP_ENABLED" != "true" ]]; then
        log_debug "Backup system disabled - skipping initialization"
        return 0
    fi
    
    local task_queue_dir="${TASK_QUEUE_DIR:-queue}"
    
    # Create absolute path for backup directory
    if [[ "$task_queue_dir" = /* ]]; then
        BACKUP_DIR="$task_queue_dir/backups"
    else
        BACKUP_DIR="$PROJECT_ROOT/$task_queue_dir/backups"
    fi
    
    # Create backup directory if it doesn't exist
    if ! mkdir -p "$BACKUP_DIR"; then
        log_error "Failed to create backup directory: $BACKUP_DIR"
        return 1
    fi
    
    # Clean up old backups
    cleanup_old_backups
    
    log_info "Backup system initialized: $BACKUP_DIR"
    return 0
}

# Clean up old backup files
cleanup_old_backups() {
    if [[ ! -d "$BACKUP_DIR" ]]; then
        return 0
    fi
    
    local retention_hours="${1:-$BACKUP_RETENTION_HOURS}"
    local cleanup_count=0
    
    log_debug "Cleaning up backups older than $retention_hours hours"
    
    # Remove backup files older than retention period
    while IFS= read -r -d '' backup_file; do
        if [[ -f "$backup_file" ]]; then
            # Check if file is older than retention period
            if [[ $(find "$backup_file" -mtime "+$((retention_hours / 24))" 2>/dev/null | wc -l) -gt 0 ]]; then
                rm -f "$backup_file" 2>/dev/null || true
                ((cleanup_count++))
                log_debug "Removed old backup: $(basename "$backup_file")"
            fi
        fi
    done < <(find "$BACKUP_DIR" -name "*.json" -print0 2>/dev/null || true)
    
    if [[ $cleanup_count -gt 0 ]]; then
        log_info "Cleaned up $cleanup_count old backup files"
    fi
}

# ===============================================================================
# CORE BACKUP FUNCTIONS
# ===============================================================================

# Create task checkpoint
create_task_checkpoint() {
    local task_id="$1"
    local checkpoint_reason="${2:-periodic}"
    
    if [[ "$BACKUP_ENABLED" != "true" ]]; then
        log_debug "Backup disabled - skipping checkpoint creation for task $task_id"
        return 0
    fi
    
    if [[ -z "$task_id" ]]; then
        log_error "Invalid task ID for checkpoint creation"
        return 1
    fi
    
    if [[ ! -d "$BACKUP_DIR" ]]; then
        initialize_backup_system
    fi
    
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_file="$BACKUP_DIR/checkpoint-${task_id}-${timestamp}.json"
    
    log_debug "Creating task checkpoint for $task_id: $checkpoint_reason"
    
    # Gather comprehensive task state
    local task_data
    task_data=$(get_comprehensive_task_state "$task_id")
    
    if [[ -z "$task_data" || "$task_data" == "null" ]]; then
        log_warn "No task data available for checkpoint: $task_id"
        task_data="{\"error\": \"no_task_data\"}"
    fi
    
    # Create backup with metadata
    cat > "$backup_file" << EOF
{
    "task_id": "$task_id",
    "checkpoint_time": "$(date -Iseconds)",
    "checkpoint_reason": "$checkpoint_reason",
    "backup_version": "1.0",
    "system_state": {
        "session_id": "${MAIN_SESSION_ID:-unknown}",
        "queue_status": "$(get_queue_status)",
        "current_cycle": "${CURRENT_CYCLE:-0}",
        "hostname": "$(hostname)",
        "backup_pid": $$
    },
    "task_state": $task_data
}
EOF
    
    # Compress if enabled
    if [[ "$BACKUP_COMPRESSION" == "true" ]] && has_command gzip; then
        gzip "$backup_file"
        backup_file="${backup_file}.gz"
        log_debug "Backup compressed: $(basename "$backup_file")"
    fi
    
    log_debug "Task checkpoint created: $(basename "$backup_file")"
    
    # Track checkpoint for periodic cleanup
    CHECKPOINT_TRACKING+=("$backup_file")
    
    # Cleanup old checkpoints for this task
    cleanup_old_checkpoints "$task_id"
    
    echo "$backup_file"  # Return backup file path
    return 0
}

# Get comprehensive task state
get_comprehensive_task_state() {
    local task_id="$1"
    local task_data="{}"
    
    # Try to get task details from task queue system
    if [[ -f "$SCRIPT_DIR/task-queue.sh" ]]; then
        source "$SCRIPT_DIR/task-queue.sh"
        
        if declare -f get_task_details >/dev/null 2>&1; then
            task_data=$(get_task_details "$task_id" 2>/dev/null || echo "{}")
        elif declare -f get_task_info >/dev/null 2>&1; then
            task_data=$(get_task_info "$task_id" 2>/dev/null || echo "{}")
        fi
    fi
    
    # If no detailed data available, create basic task state
    if [[ "$task_data" == "{}" ]]; then
        local status="unknown"
        local start_time="unknown"
        local retry_count=0
        
        # Try to get basic info if functions are available
        if declare -f get_task_status >/dev/null 2>&1; then
            status=$(get_task_status "$task_id" 2>/dev/null || echo "unknown")
        fi
        
        task_data=$(cat << EOF
{
    "task_id": "$task_id",
    "status": "$status",
    "start_time": "$start_time",
    "retry_count": $retry_count,
    "checkpoint_data": {
        "created_at": "$(date -Iseconds)",
        "source": "basic_fallback"
    }
}
EOF
)
    fi
    
    echo "$task_data"
}

# Get current queue status
get_queue_status() {
    local status="unknown"
    
    # Try to get queue status from task queue system
    if [[ -f "$SCRIPT_DIR/task-queue.sh" ]]; then
        source "$SCRIPT_DIR/task-queue.sh"
        
        if declare -f get_queue_stats >/dev/null 2>&1; then
            status=$(get_queue_stats 2>/dev/null | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")
        fi
    fi
    
    echo "$status"
}

# Restore from checkpoint
restore_from_checkpoint() {
    local task_id="$1"
    local backup_file="${2:-$(find_latest_checkpoint "$task_id")}"
    
    if [[ -z "$backup_file" || ! -f "$backup_file" ]]; then
        log_error "No checkpoint found for task $task_id"
        return 1
    fi
    
    log_info "Restoring task $task_id from checkpoint: $(basename "$backup_file")"
    
    # Handle compressed files
    local temp_file=""
    if [[ "$backup_file" == *.gz ]]; then
        if has_command gunzip; then
            temp_file=$(mktemp)
            gunzip -c "$backup_file" > "$temp_file"
            backup_file="$temp_file"
        else
            log_error "Cannot decompress backup file - gunzip not available"
            return 1
        fi
    fi
    
    # Extract and validate backup data
    if ! has_command jq; then
        log_error "jq not available - cannot restore from JSON backup"
        [[ -n "$temp_file" ]] && rm -f "$temp_file"
        return 1
    fi
    
    # Validate backup file structure
    if ! jq -e '.task_state' "$backup_file" >/dev/null 2>&1; then
        log_error "Invalid backup file structure: $(basename "$backup_file")"
        [[ -n "$temp_file" ]] && rm -f "$temp_file"
        return 1
    fi
    
    # Extract task state
    local task_state
    task_state=$(jq -r '.task_state' "$backup_file")
    
    # Restore task state
    if restore_task_state "$task_id" "$task_state"; then
        log_info "Task $task_id restored successfully from checkpoint"
        [[ -n "$temp_file" ]] && rm -f "$temp_file"
        return 0
    else
        log_error "Failed to restore task $task_id from checkpoint"
        [[ -n "$temp_file" ]] && rm -f "$temp_file"
        return 1
    fi
}

# Restore task state
restore_task_state() {
    local task_id="$1"
    local task_state="$2"
    
    log_debug "Restoring state for task $task_id"
    
    # Try to restore using task queue system if available
    if [[ -f "$SCRIPT_DIR/task-queue.sh" ]]; then
        source "$SCRIPT_DIR/task-queue.sh"
        
        if declare -f restore_task_from_state >/dev/null 2>&1; then
            restore_task_from_state "$task_id" "$task_state"
            return $?
        fi
    fi
    
    # Fallback: basic restoration logic
    log_debug "Using fallback restoration for task $task_id"
    
    # Extract basic info from task state
    if has_command jq; then
        local status
        status=$(echo "$task_state" | jq -r '.status // "pending"')
        
        # Update task status if possible
        if declare -f update_task_status >/dev/null 2>&1; then
            update_task_status "$task_id" "$status"
        fi
    fi
    
    log_info "Basic task state restoration completed for task $task_id"
    return 0
}

# Find latest checkpoint for task
find_latest_checkpoint() {
    local task_id="$1"
    
    if [[ ! -d "$BACKUP_DIR" ]]; then
        return 1
    fi
    
    # Find the most recent checkpoint file for this task
    local latest_file=""
    latest_file=$(find "$BACKUP_DIR" -name "checkpoint-${task_id}-*.json*" -type f 2>/dev/null | sort | tail -1)
    
    if [[ -n "$latest_file" && -f "$latest_file" ]]; then
        echo "$latest_file"
        return 0
    fi
    
    return 1
}

# Clean up old checkpoints for specific task
cleanup_old_checkpoints() {
    local task_id="$1"
    local max_checkpoints=5  # Keep last 5 checkpoints per task
    
    if [[ ! -d "$BACKUP_DIR" ]]; then
        return 0
    fi
    
    # Find all checkpoints for this task and remove old ones
    local checkpoint_files=()
    while IFS= read -r -d '' file; do
        checkpoint_files+=("$file")
    done < <(find "$BACKUP_DIR" -name "checkpoint-${task_id}-*.json*" -type f -print0 2>/dev/null | sort -z)
    
    # Keep only the most recent checkpoints
    if [[ ${#checkpoint_files[@]} -gt $max_checkpoints ]]; then
        local files_to_remove=$((${#checkpoint_files[@]} - max_checkpoints))
        for ((i=0; i<files_to_remove; i++)); do
            rm -f "${checkpoint_files[$i]}" 2>/dev/null || true
            log_debug "Removed old checkpoint: $(basename "${checkpoint_files[$i]}")"
        done
    fi
}

# ===============================================================================
# EMERGENCY BACKUP FUNCTIONS
# ===============================================================================

# Create emergency system backup
create_emergency_system_backup() {
    local reason="${1:-manual}"
    
    if [[ "$BACKUP_ENABLED" != "true" ]]; then
        log_debug "Backup disabled - skipping emergency system backup"
        return 0
    fi
    
    if [[ ! -d "$BACKUP_DIR" ]]; then
        initialize_backup_system
    fi
    
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local emergency_backup="$BACKUP_DIR/emergency-system-${timestamp}.json"
    
    log_warn "Creating emergency system backup: $reason"
    
    # Comprehensive system state backup
    cat > "$emergency_backup" << EOF
{
    "backup_time": "$(date -Iseconds)",
    "backup_reason": "$reason",
    "backup_type": "emergency_system",
    "backup_version": "1.0",
    "system_info": {
        "hostname": "$(hostname)",
        "pid": $$,
        "session_id": "${MAIN_SESSION_ID:-unknown}",
        "current_cycle": "${CURRENT_CYCLE:-0}",
        "script_path": "${BASH_SOURCE[1]:-unknown}"
    },
    "queue_state": $(get_complete_queue_state),
    "active_tasks": $(get_all_active_tasks),
    "configuration": $(export_current_configuration)
}
EOF
    
    # Compress if enabled
    if [[ "$BACKUP_COMPRESSION" == "true" ]] && has_command gzip; then
        gzip "$emergency_backup"
        emergency_backup="${emergency_backup}.gz"
    fi
    
    log_info "Emergency backup created: $(basename "$emergency_backup")"
    echo "$emergency_backup"
    return 0
}

# Get complete queue state
get_complete_queue_state() {
    local queue_state="{}"
    
    if [[ -f "$SCRIPT_DIR/task-queue.sh" ]]; then
        source "$SCRIPT_DIR/task-queue.sh"
        
        if declare -f export_queue_state >/dev/null 2>&1; then
            queue_state=$(export_queue_state 2>/dev/null || echo "{}")
        elif declare -f get_queue_stats >/dev/null 2>&1; then
            queue_state=$(get_queue_stats 2>/dev/null || echo "{}")
        fi
    fi
    
    echo "$queue_state"
}

# Get all active tasks
get_all_active_tasks() {
    local active_tasks="[]"
    
    if [[ -f "$SCRIPT_DIR/task-queue.sh" ]]; then
        source "$SCRIPT_DIR/task-queue.sh"
        
        if declare -f get_active_tasks >/dev/null 2>&1; then
            active_tasks=$(get_active_tasks 2>/dev/null | jq -c '.' 2>/dev/null || echo "[]")
        fi
    fi
    
    echo "$active_tasks"
}

# Export current configuration
export_current_configuration() {
    local config="{}"
    
    # Basic configuration export
    config=$(cat << EOF
{
    "backup_enabled": "$BACKUP_ENABLED",
    "backup_retention_hours": $BACKUP_RETENTION_HOURS,
    "backup_checkpoint_frequency": $BACKUP_CHECKPOINT_FREQUENCY,
    "task_queue_enabled": "${TASK_QUEUE_ENABLED:-false}",
    "max_restarts": "${MAX_RESTARTS:-50}",
    "check_interval_minutes": "${CHECK_INTERVAL_MINUTES:-5}"
}
EOF
)
    
    echo "$config"
}

# ===============================================================================
# PERIODIC BACKUP MANAGEMENT
# ===============================================================================

# Check if periodic checkpoint is needed
should_create_checkpoint() {
    local last_checkpoint_time="${1:-0}"
    local current_time=$(date +%s)
    local time_since_last=$((current_time - last_checkpoint_time))
    
    [[ $time_since_last -ge $BACKUP_CHECKPOINT_FREQUENCY ]]
}

# Create periodic checkpoint if needed
create_periodic_checkpoint_if_needed() {
    local task_id="$1"
    local last_checkpoint_time="${2:-0}"
    
    if should_create_checkpoint "$last_checkpoint_time"; then
        create_task_checkpoint "$task_id" "periodic"
        return $?
    fi
    
    return 0
}

# ===============================================================================
# BACKUP STATISTICS AND MONITORING
# ===============================================================================

# Get backup statistics
get_backup_statistics() {
    if [[ ! -d "$BACKUP_DIR" ]]; then
        echo '{"error": "backup_dir_not_found"}'
        return 1
    fi
    
    local total_backups=0
    local checkpoint_backups=0
    local emergency_backups=0
    local compressed_backups=0
    local total_size=0
    
    # Count different types of backups
    while IFS= read -r -d '' backup_file; do
        if [[ -f "$backup_file" ]]; then
            ((total_backups++))
            
            local filename
            filename=$(basename "$backup_file")
            
            case "$filename" in
                checkpoint-*)
                    ((checkpoint_backups++))
                    ;;
                emergency-*)
                    ((emergency_backups++))
                    ;;
            esac
            
            if [[ "$filename" == *.gz ]]; then
                ((compressed_backups++))
            fi
            
            # Calculate size
            if has_command stat; then
                local file_size
                file_size=$(stat -f%z "$backup_file" 2>/dev/null || stat -c%s "$backup_file" 2>/dev/null || echo 0)
                total_size=$((total_size + file_size))
            fi
        fi
    done < <(find "$BACKUP_DIR" -name "*.json*" -print0 2>/dev/null)
    
    # Format size for display
    local size_display="unknown"
    if has_command numfmt; then
        size_display=$(numfmt --to=iec-i --suffix=B "$total_size" 2>/dev/null || echo "${total_size} bytes")
    else
        size_display="${total_size} bytes"
    fi
    
    cat << EOF
{
    "backup_directory": "$BACKUP_DIR",
    "total_backups": $total_backups,
    "checkpoint_backups": $checkpoint_backups,
    "emergency_backups": $emergency_backups,
    "compressed_backups": $compressed_backups,
    "total_size": $total_size,
    "size_display": "$size_display",
    "retention_hours": $BACKUP_RETENTION_HOURS,
    "compression_enabled": $BACKUP_COMPRESSION
}
EOF
}

# ===============================================================================
# CLEANUP AND MAINTENANCE
# ===============================================================================

# Clean up all backup tracking
cleanup_backup_system() {
    log_debug "Cleaning up backup system"
    
    CHECKPOINT_TRACKING=()
    
    # Optionally clean up temporary files
    local temp_files=(/tmp/task-recovery-*.json)
    for temp_file in "${temp_files[@]}"; do
        if [[ -f "$temp_file" ]]; then
            rm -f "$temp_file" 2>/dev/null || true
        fi
    done
    
    log_debug "Backup system cleanup completed"
}

# ===============================================================================
# MODULE INITIALIZATION
# ===============================================================================

# Auto-initialize if sourced
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    log_debug "Task state backup module loaded"
    # Initialize backup system when module is sourced
    initialize_backup_system
fi