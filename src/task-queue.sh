#!/usr/bin/env bash

# Claude Auto-Resume - Task Queue Core Module
# Task-Queue-Management-System für das Claude Auto-Resume System
# Version: 1.0.0-alpha
# Letzte Aktualisierung: 2025-08-24

set -euo pipefail

# ===============================================================================
# GLOBALE VARIABLEN UND KONSTANTEN
# ===============================================================================

# Standard-Konfiguration (wird von config/default.conf überschrieben)
TASK_QUEUE_ENABLED="${TASK_QUEUE_ENABLED:-false}"
TASK_QUEUE_DIR="${TASK_QUEUE_DIR:-queue}"
TASK_DEFAULT_TIMEOUT="${TASK_DEFAULT_TIMEOUT:-3600}"
TASK_MAX_RETRIES="${TASK_MAX_RETRIES:-3}"
TASK_RETRY_DELAY="${TASK_RETRY_DELAY:-300}"
TASK_COMPLETION_PATTERN="${TASK_COMPLETION_PATTERN:-###TASK_COMPLETE###}"
TASK_QUEUE_MAX_SIZE="${TASK_QUEUE_MAX_SIZE:-0}"
TASK_AUTO_CLEANUP_DAYS="${TASK_AUTO_CLEANUP_DAYS:-7}"
TASK_BACKUP_RETENTION_DAYS="${TASK_BACKUP_RETENTION_DAYS:-30}"
QUEUE_LOCK_TIMEOUT="${QUEUE_LOCK_TIMEOUT:-30}"

# Task-State-Tracking (global associative arrays)
# Initialize arrays at script load time to ensure availability in all contexts
if ! declare -p TASK_STATES >/dev/null 2>&1; then
    declare -gA TASK_STATES
fi
if ! declare -p TASK_METADATA >/dev/null 2>&1; then
    declare -gA TASK_METADATA
fi
if ! declare -p TASK_RETRY_COUNTS >/dev/null 2>&1; then
    declare -gA TASK_RETRY_COUNTS
fi
if ! declare -p TASK_TIMESTAMPS >/dev/null 2>&1; then
    declare -gA TASK_TIMESTAMPS
fi
if ! declare -p TASK_PRIORITIES >/dev/null 2>&1; then
    declare -gA TASK_PRIORITIES
fi

# Task-Status-Konstanten
readonly TASK_STATE_PENDING="pending"
readonly TASK_STATE_IN_PROGRESS="in_progress"
readonly TASK_STATE_COMPLETED="completed"
readonly TASK_STATE_FAILED="failed"
readonly TASK_STATE_TIMEOUT="timeout"

# Task-Typ-Konstanten
readonly TASK_TYPE_GITHUB_ISSUE="github_issue"
readonly TASK_TYPE_GITHUB_PR="github_pr"
readonly TASK_TYPE_CUSTOM="custom"

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

# Prüfe ob Kommando verfügbar ist
has_command() {
    command -v "$1" >/dev/null 2>&1
}

# Prüfe Dependencies
check_dependencies() {
    local missing_deps=()
    
    if ! has_command jq; then
        missing_deps+=("jq")
    fi
    
    # flock is optional - we'll use alternative locking on systems without it
    if ! has_command flock; then
        log_warn "flock not available - using alternative file locking (may be less reliable)"
    fi
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing_deps[*]}"
        log_error "Please install missing dependencies: sudo apt-get install ${missing_deps[*]} (Ubuntu/Debian) or brew install ${missing_deps[*]} (macOS)"
        return 1
    fi
    
    return 0
}

# ===============================================================================
# VERZEICHNIS-MANAGEMENT
# ===============================================================================

# Stelle sicher, dass Queue-Verzeichnisse existieren
ensure_queue_directories() {
    local base_dir="$PROJECT_ROOT/$TASK_QUEUE_DIR"
    
    for dir in "$base_dir" "$base_dir/task-states" "$base_dir/backups"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir" || {
                log_error "Cannot create queue directory: $dir"
                return 1
            }
            log_debug "Created queue directory: $dir"
        fi
    done
    
    return 0
}

# ===============================================================================
# TASK-ID-GENERATION UND VALIDATION
# ===============================================================================

# Generiere eindeutige Task-ID
generate_task_id() {
    local prefix="${1:-task}"
    local timestamp=$(date +%s)
    local random=$(( RANDOM % 9999 ))
    
    printf "%s-%s-%04d" "$prefix" "$timestamp" "$random"
}

# Validiere Task-ID-Format
validate_task_id() {
    local task_id="$1"
    
    if [[ -z "$task_id" ]]; then
        log_error "Task ID cannot be empty"
        return 1
    fi
    
    if [[ ! "$task_id" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "Task ID contains invalid characters: $task_id"
        return 1
    fi
    
    if [[ ${#task_id} -gt 100 ]]; then
        log_error "Task ID too long (max 100 chars): $task_id"
        return 1
    fi
    
    return 0
}

# Validiere Task-Daten
validate_task_data() {
    local task_type="$1"
    local priority="$2"
    local timeout="${3:-$TASK_DEFAULT_TIMEOUT}"
    
    # Validiere Task-Typ
    case "$task_type" in
        "$TASK_TYPE_GITHUB_ISSUE"|"$TASK_TYPE_GITHUB_PR"|"$TASK_TYPE_CUSTOM")
            ;;
        *)
            log_error "Invalid task type: $task_type"
            return 1
            ;;
    esac
    
    # Validiere Priority (1-10, 1 = höchste)
    if ! [[ "$priority" =~ ^[0-9]+$ ]] || [[ $priority -lt 1 ]] || [[ $priority -gt 10 ]]; then
        log_error "Priority must be between 1 and 10: $priority"
        return 1
    fi
    
    # Validiere Timeout
    if ! [[ "$timeout" =~ ^[0-9]+$ ]] || [[ $timeout -lt 1 ]]; then
        log_error "Timeout must be a positive number: $timeout"
        return 1
    fi
    
    return 0
}

# ===============================================================================
# FILE-LOCKING FÜR ATOMIC OPERATIONS
# ===============================================================================

# Acquire queue lock für sichere Operationen
acquire_queue_lock() {
    local lock_file="$PROJECT_ROOT/$TASK_QUEUE_DIR/.queue.lock"
    local lock_fd=200
    local attempts=0
    local max_attempts=$((QUEUE_LOCK_TIMEOUT))
    
    ensure_queue_directories || return 1
    
    if has_command flock; then
        # Use flock if available (Linux)
        exec 200>"$lock_file"
        
        if flock -x -w "$QUEUE_LOCK_TIMEOUT" 200; then
            log_debug "Acquired queue lock (flock, fd: $lock_fd, timeout: ${QUEUE_LOCK_TIMEOUT}s)"
            return 0
        else
            log_error "Failed to acquire queue lock within ${QUEUE_LOCK_TIMEOUT}s"
            return 1
        fi
    else
        # Alternative locking for macOS/systems without flock
        local pid_file="$lock_file.pid"
        
        while [[ $attempts -lt $max_attempts ]]; do
            # Check if lock file exists and is valid
            if [[ -f "$pid_file" ]]; then
                local lock_pid
                lock_pid=$(cat "$pid_file" 2>/dev/null || echo "")
                
                # Check if process is still running
                if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
                    log_debug "Queue lock held by process $lock_pid (attempt $((attempts + 1))/$max_attempts)"
                    sleep 1
                    ((attempts++))
                    continue
                else
                    log_debug "Removing stale lock file (pid: $lock_pid)"
                    rm -f "$pid_file" "$lock_file" 2>/dev/null || true
                fi
            fi
            
            # Try to acquire lock
            if (set -C; echo $$ > "$pid_file") 2>/dev/null; then
                # Create main lock file
                touch "$lock_file"
                log_debug "Acquired queue lock (alternative method, pid: $$)"
                return 0
            else
                log_debug "Failed to acquire lock, retrying... (attempt $((attempts + 1))/$max_attempts)"
                sleep 1
                ((attempts++))
            fi
        done
        
        log_error "Failed to acquire queue lock within ${max_attempts}s (alternative method)"
        return 1
    fi
}

# Release queue lock
release_queue_lock() {
    local lock_file="$PROJECT_ROOT/$TASK_QUEUE_DIR/.queue.lock"
    local lock_fd=200
    
    if has_command flock; then
        # Release flock
        flock -u 200 2>/dev/null || {
            log_warn "Failed to release queue lock (may have been released already)"
        }
        
        # Close file descriptor
        exec 200>&- 2>/dev/null || true
        
        log_debug "Released queue lock (flock, fd: $lock_fd)"
    else
        # Release alternative lock
        local pid_file="$lock_file.pid"
        
        if [[ -f "$pid_file" ]]; then
            local lock_pid
            lock_pid=$(cat "$pid_file" 2>/dev/null || echo "")
            
            if [[ "$lock_pid" == "$$" ]]; then
                rm -f "$pid_file" "$lock_file" 2>/dev/null || {
                    log_warn "Failed to remove lock files"
                }
                log_debug "Released queue lock (alternative method, pid: $$)"
            else
                log_warn "Lock file belongs to different process: $lock_pid (current: $$)"
            fi
        else
            log_debug "No lock file to release"
        fi
    fi
}

# Wrapper für sichere Queue-Operationen
with_queue_lock() {
    local operation="$1"
    shift
    local result=0
    
    log_debug "Starting locked operation: $operation"
    
    if acquire_queue_lock; then
        # Execute operation with lock held
        "$operation" "$@"
        result=$?
        
        # Always release lock
        release_queue_lock
        
        log_debug "Completed locked operation: $operation (exit code: $result)"
        return $result
    else
        log_error "Cannot execute operation without lock: $operation"
        return 1
    fi
}

# ===============================================================================
# JSON-PERSISTENZ-LAYER
# ===============================================================================

# Generiere JSON für Queue-State
generate_queue_json() {
    local current_time=$(date -Iseconds)
    local total_tasks=0
    local pending_tasks=0
    local active_tasks=0
    local completed_tasks=0
    local failed_tasks=0
    local timeout_tasks=0
    
    # Zähle Tasks nach Status
    for task_id in "${!TASK_STATES[@]}"; do
        ((total_tasks++))
        case "${TASK_STATES[$task_id]}" in
            "$TASK_STATE_PENDING") ((pending_tasks++)) ;;
            "$TASK_STATE_IN_PROGRESS") ((active_tasks++)) ;;
            "$TASK_STATE_COMPLETED") ((completed_tasks++)) ;;
            "$TASK_STATE_FAILED") ((failed_tasks++)) ;;
            "$TASK_STATE_TIMEOUT") ((timeout_tasks++)) ;;
        esac
    done
    
    # Generiere JSON-Header
    cat <<EOF
{
  "version": "1.0",
  "created": "$current_time",
  "last_updated": "$current_time",
  "total_tasks": $total_tasks,
  "pending_tasks": $pending_tasks,
  "active_tasks": $active_tasks,
  "completed_tasks": $completed_tasks,
  "failed_tasks": $failed_tasks,
  "timeout_tasks": $timeout_tasks,
  "tasks": [
EOF

    # Generiere Task-Einträge
    local first=true
    for task_id in "${!TASK_STATES[@]}"; do
        [[ "$first" == true ]] && first=false || echo ","
        
        local task_type="${TASK_METADATA[${task_id}_type]:-$TASK_TYPE_CUSTOM}"
        local priority="${TASK_PRIORITIES[$task_id]:-5}"
        local status="${TASK_STATES[$task_id]}"
        local created_at="${TASK_TIMESTAMPS[${task_id}_created]:-$current_time}"
        local updated_at="${TASK_TIMESTAMPS[${task_id}_${status}]:-$created_at}"
        local timeout="${TASK_METADATA[${task_id}_timeout]:-$TASK_DEFAULT_TIMEOUT}"
        local retry_count="${TASK_RETRY_COUNTS[$task_id]:-0}"
        local max_retries="${TASK_METADATA[${task_id}_max_retries]:-$TASK_MAX_RETRIES}"
        
        cat <<EOF
    {
      "id": "$task_id",
      "type": "$task_type",
      "priority": $priority,
      "status": "$status",
      "created_at": "$created_at",
      "updated_at": "$updated_at",
      "timeout": $timeout,
      "retry_count": $retry_count,
      "max_retries": $max_retries
EOF

        # GitHub-spezifische Felder
        if [[ "$task_type" == "$TASK_TYPE_GITHUB_ISSUE" ]]; then
            local github_number="${TASK_METADATA[${task_id}_github_number]:-}"
            local title="${TASK_METADATA[${task_id}_title]:-}"
            local labels="${TASK_METADATA[${task_id}_labels]:-}"
            local command="${TASK_METADATA[${task_id}_command]:-}"
            
            cat <<EOF
,
      "github_number": $github_number,
      "title": $(echo "$title" | jq -R .),
      "labels": $(echo "$labels" | jq -R . | jq 'split(",")')
EOF
            [[ -n "$command" ]] && cat <<EOF
,
      "command": $(echo "$command" | jq -R .)
EOF
        elif [[ "$task_type" == "$TASK_TYPE_CUSTOM" ]]; then
            local description="${TASK_METADATA[${task_id}_description]:-}"
            local command="${TASK_METADATA[${task_id}_command]:-}"
            
            [[ -n "$description" ]] && cat <<EOF
,
      "description": $(echo "$description" | jq -R .)
EOF
            [[ -n "$command" ]] && cat <<EOF
,
      "command": $(echo "$command" | jq -R .)
EOF
        fi
        
        echo -n "    }"
    done
    
    cat <<EOF

  ]
}
EOF
}

# Atomare JSON-File-Writing
save_queue_state() {
    local queue_file="$PROJECT_ROOT/$TASK_QUEUE_DIR/task-queue.json"
    local temp_file="$queue_file.tmp.$$"
    local backup_file="$PROJECT_ROOT/$TASK_QUEUE_DIR/backups/backup-$(date +%Y%m%d-%H%M%S).json"
    
    ensure_queue_directories || return 1
    
    log_debug "Saving queue state to: $queue_file"
    
    # Create backup of existing file
    if [[ -f "$queue_file" ]]; then
        if cp "$queue_file" "$backup_file"; then
            log_debug "Created backup: $backup_file"
        else
            log_error "Failed to create backup before save"
            return 1
        fi
    fi
    
    # Write to temp file first
    if generate_queue_json > "$temp_file"; then
        # Validate JSON before replacing original
        if jq empty "$temp_file" 2>/dev/null; then
            if mv "$temp_file" "$queue_file"; then
                log_debug "Queue state saved successfully"
                return 0
            else
                log_error "Failed to move temp file to queue file"
                rm -f "$temp_file" 2>/dev/null || true
                return 1
            fi
        else
            log_error "Generated JSON is invalid, aborting save"
            rm -f "$temp_file" 2>/dev/null || true
            return 1
        fi
    else
        log_error "Failed to generate JSON for queue state"
        rm -f "$temp_file" 2>/dev/null || true
        return 1
    fi
}

# Lade Queue-State von JSON-File
load_queue_state() {
    local queue_file="$PROJECT_ROOT/$TASK_QUEUE_DIR/task-queue.json"
    
    if [[ ! -f "$queue_file" ]]; then
        log_debug "No existing queue file found: $queue_file"
        return 0
    fi
    
    log_debug "Loading queue state from: $queue_file"
    
    # Validate JSON first
    if ! jq empty "$queue_file" 2>/dev/null; then
        log_error "Queue file contains invalid JSON: $queue_file"
        return 1
    fi
    
    # Clear existing data only if loading from an existing file
    # Don't clear if this is the first initialization
    local clear_data=true
    if [[ ! -f "$queue_file" ]]; then
        clear_data=false
        log_debug "No existing queue file - keeping any in-memory data"
    fi
    
    if [[ "$clear_data" == "true" ]]; then
        declare -gA TASK_STATES
        declare -gA TASK_METADATA
        declare -gA TASK_RETRY_COUNTS
        declare -gA TASK_TIMESTAMPS
        declare -gA TASK_PRIORITIES
        log_debug "Cleared existing task data to load from file"
    fi
    
    # Parse and load tasks
    local task_count
    task_count=$(jq '.tasks | length' "$queue_file")
    
    if [[ "$task_count" -gt 0 ]]; then
        log_info "Loading $task_count tasks from queue file"
        
        for ((i = 0; i < task_count; i++)); do
            local task_data
            task_data=$(jq -r ".tasks[$i]" "$queue_file")
            
            local task_id=$(echo "$task_data" | jq -r '.id')
            local task_type=$(echo "$task_data" | jq -r '.type')
            local priority=$(echo "$task_data" | jq -r '.priority')
            local status=$(echo "$task_data" | jq -r '.status')
            local created_at=$(echo "$task_data" | jq -r '.created_at')
            local updated_at=$(echo "$task_data" | jq -r '.updated_at')
            local timeout=$(echo "$task_data" | jq -r '.timeout')
            local retry_count=$(echo "$task_data" | jq -r '.retry_count')
            local max_retries=$(echo "$task_data" | jq -r '.max_retries')
            
            # Lade Task-Daten in Memory-Strukturen
            TASK_STATES["$task_id"]="$status"
            TASK_PRIORITIES["$task_id"]="$priority"
            TASK_RETRY_COUNTS["$task_id"]="$retry_count"
            TASK_TIMESTAMPS["${task_id}_created"]="$created_at"
            TASK_TIMESTAMPS["${task_id}_${status}"]="$updated_at"
            TASK_METADATA["${task_id}_type"]="$task_type"
            TASK_METADATA["${task_id}_timeout"]="$timeout"
            TASK_METADATA["${task_id}_max_retries"]="$max_retries"
            
            # GitHub-spezifische Metadaten
            if [[ "$task_type" == "$TASK_TYPE_GITHUB_ISSUE" ]]; then
                local github_number=$(echo "$task_data" | jq -r '.github_number // ""')
                local title=$(echo "$task_data" | jq -r '.title // ""')
                local labels=$(echo "$task_data" | jq -r '.labels // [] | join(",")')
                local command=$(echo "$task_data" | jq -r '.command // ""')
                
                [[ -n "$github_number" && "$github_number" != "null" ]] && TASK_METADATA["${task_id}_github_number"]="$github_number"
                [[ -n "$title" && "$title" != "null" ]] && TASK_METADATA["${task_id}_title"]="$title"
                [[ -n "$labels" && "$labels" != "null" ]] && TASK_METADATA["${task_id}_labels"]="$labels"
                [[ -n "$command" && "$command" != "null" ]] && TASK_METADATA["${task_id}_command"]="$command"
            elif [[ "$task_type" == "$TASK_TYPE_CUSTOM" ]]; then
                local description=$(echo "$task_data" | jq -r '.description // ""')
                local command=$(echo "$task_data" | jq -r '.command // ""')
                
                [[ -n "$description" && "$description" != "null" ]] && TASK_METADATA["${task_id}_description"]="$description"
                [[ -n "$command" && "$command" != "null" ]] && TASK_METADATA["${task_id}_command"]="$command"
            fi
            
            log_debug "Loaded task: $task_id ($task_type, priority=$priority, status=$status)"
        done
        
        log_info "Successfully loaded $task_count tasks from queue"
    else
        log_debug "Queue file is empty"
    fi
    
    return 0
}

# Backup-Management
backup_queue_state() {
    local reason="${1:-manual}"
    local queue_file="$PROJECT_ROOT/$TASK_QUEUE_DIR/task-queue.json"
    local backup_file="$PROJECT_ROOT/$TASK_QUEUE_DIR/backups/backup-${reason}-$(date +%Y%m%d-%H%M%S).json"
    
    ensure_queue_directories || return 1
    
    if [[ -f "$queue_file" ]]; then
        if cp "$queue_file" "$backup_file"; then
            log_info "Queue backup created: $backup_file"
            return 0
        else
            log_error "Failed to create queue backup"
            return 1
        fi
    else
        log_warn "No queue file to backup"
        return 1
    fi
}

# Queue-Recovery von Backup
recover_queue_state() {
    local backup_file="$1"
    local queue_file="$PROJECT_ROOT/$TASK_QUEUE_DIR/task-queue.json"
    
    if [[ ! -f "$backup_file" ]]; then
        log_error "Backup file not found: $backup_file"
        return 1
    fi
    
    log_info "Recovering queue state from backup: $backup_file"
    
    # Validate backup JSON first
    if ! jq empty "$backup_file" 2>/dev/null; then
        log_error "Backup contains invalid JSON: $backup_file"
        return 1
    fi
    
    # Create backup of current state if exists
    if [[ -f "$queue_file" ]]; then
        backup_queue_state "pre-recovery" || {
            log_warn "Failed to backup current state before recovery"
        }
    fi
    
    # Copy backup to main file
    if cp "$backup_file" "$queue_file"; then
        log_info "Queue state recovered from backup"
        
        # Reload from recovered file
        load_queue_state
        return $?
    else
        log_error "Failed to recover from backup"
        return 1
    fi
}

# ===============================================================================
# KERN-QUEUE-OPERATIONS
# ===============================================================================

# Task zur Queue hinzufügen
add_task_to_queue() {
    local task_type="$1"
    local priority="$2"
    local task_id="${3:-}"
    
    # Handle variable arguments safely
    local metadata=()
    if [[ $# -gt 3 ]]; then
        shift 3
        metadata=("$@")
    fi
    
    log_info "Adding task to queue (type: $task_type, priority: $priority)"
    
    # Validate input
    validate_task_data "$task_type" "$priority" || return 1
    log_debug "Passed validate_task_data"
    
    # Ensure arrays are initialized before accessing them
    if ! declare -p TASK_STATES >/dev/null 2>&1; then
        declare -gA TASK_STATES
        declare -gA TASK_METADATA
        declare -gA TASK_RETRY_COUNTS
        declare -gA TASK_TIMESTAMPS
        declare -gA TASK_PRIORITIES
        log_debug "Initialized arrays in add_task_to_queue"
    fi
    log_debug "Arrays are available"
    
    # Generate ID if not provided
    if [[ -z "$task_id" ]]; then
        task_id=$(generate_task_id)
        log_debug "Generated task ID: $task_id"
    else
        validate_task_id "$task_id" || return 1
        log_debug "Validated provided task ID: $task_id"
    fi
    
    # Check if task already exists
    local task_exists=false
    if [[ "${BATS_TEST_NAME:-}" != "" ]]; then
        # BATS environment - use file-based tracking for duplicate detection
        local bats_state_file="${TEST_PROJECT_DIR:-/tmp}/queue/bats_task_states.txt"
        if [[ -f "$bats_state_file" ]] && grep -q "^$task_id$" "$bats_state_file" 2>/dev/null; then
            task_exists=true
        fi
    else
        # Normal environment - use array
        if [[ -n "${TASK_STATES[$task_id]:-}" ]]; then
            task_exists=true
        fi
    fi
    
    if [[ "$task_exists" == "true" ]]; then
        log_error "Task already exists in queue: $task_id"
        return 1
    fi
    log_debug "Task ID is unique"
    
    # Check queue size limit
    local current_size=0
    if [[ "${BATS_TEST_NAME:-}" != "" ]]; then
        # BATS environment - count from file
        local bats_state_file="${TEST_PROJECT_DIR:-/tmp}/queue/bats_task_states.txt"
        if [[ -f "$bats_state_file" ]]; then
            current_size=$(wc -l < "$bats_state_file" 2>/dev/null || echo "0")
        fi
    else
        # Normal environment - use array
        current_size=${#TASK_STATES[@]}
    fi
    
    if [[ ${TASK_QUEUE_MAX_SIZE:-0} -gt 0 ]] && [[ $current_size -ge $TASK_QUEUE_MAX_SIZE ]]; then
        log_error "Queue is full (max size: $TASK_QUEUE_MAX_SIZE)"
        return 1
    fi
    log_debug "Queue size check: $current_size/${TASK_QUEUE_MAX_SIZE:-unlimited}"
    
    local current_time=$(date -Iseconds)
    
    # Initialize task data in memory arrays
    TASK_STATES["$task_id"]="$TASK_STATE_PENDING"
    TASK_PRIORITIES["$task_id"]="$priority"
    TASK_RETRY_COUNTS["$task_id"]=0
    TASK_TIMESTAMPS["${task_id}_created"]="$current_time"
    TASK_TIMESTAMPS["${task_id}_$TASK_STATE_PENDING"]="$current_time"
    TASK_METADATA["${task_id}_type"]="$task_type"
    TASK_METADATA["${task_id}_timeout"]="$TASK_DEFAULT_TIMEOUT"
    TASK_METADATA["${task_id}_max_retries"]="$TASK_MAX_RETRIES"
    
    # In BATS test environment - also use file-based tracking for persistence validation
    if [[ "${BATS_TEST_NAME:-}" != "" ]]; then
        local bats_state_file="${TEST_PROJECT_DIR:-/tmp}/queue/bats_task_states.txt"
        mkdir -p "$(dirname "$bats_state_file")"
        echo "$task_id" >> "$bats_state_file"
        log_debug "Added task to BATS file-based tracking: $task_id"
    fi
    
    # Process metadata arguments
    local i=0
    while [[ $i -lt ${#metadata[@]} ]]; do
        local key="${metadata[$i]}"
        local value="${metadata[$((i + 1))]:-}"
        
        if [[ -n "$key" && -n "$value" ]]; then
            TASK_METADATA["${task_id}_${key}"]="$value"
            log_debug "Set metadata: $task_id.$key = $value"
        fi
        
        ((i += 2))
    done
    
    log_info "Task added to queue: $task_id ($task_type, priority=$priority)"
    echo "$task_id"  # Return task ID for caller
    return 0
}

# Task aus Queue entfernen
remove_task_from_queue() {
    local task_id="$1"
    local cleanup="${2:-true}"
    
    validate_task_id "$task_id" || return 1
    
    # Ensure arrays are initialized before accessing them
    if ! declare -p TASK_STATES >/dev/null 2>&1; then
        declare -gA TASK_STATES
        declare -gA TASK_METADATA
        declare -gA TASK_RETRY_COUNTS
        declare -gA TASK_TIMESTAMPS
        declare -gA TASK_PRIORITIES
        log_debug "Initialized arrays in remove_task_from_queue"
    fi
    
    if [[ -z "${TASK_STATES[$task_id]:-}" ]]; then
        log_error "Task not found in queue: $task_id"
        return 1
    fi
    
    log_info "Removing task from queue: $task_id"
    
    # Remove from all data structures
    unset "TASK_STATES[$task_id]"
    unset "TASK_PRIORITIES[$task_id]"
    unset "TASK_RETRY_COUNTS[$task_id]"
    
    # Remove all timestamps
    for key in "${!TASK_TIMESTAMPS[@]}"; do
        if [[ "$key" =~ ^${task_id}_ ]]; then
            unset "TASK_TIMESTAMPS[$key]"
        fi
    done
    
    # Remove all metadata
    for key in "${!TASK_METADATA[@]}"; do
        if [[ "$key" =~ ^${task_id}_ ]]; then
            unset "TASK_METADATA[$key]"
        fi
    done
    
    # Cleanup task state file if requested
    if [[ "$cleanup" == "true" ]]; then
        local task_state_file="$PROJECT_ROOT/$TASK_QUEUE_DIR/task-states/${task_id}.json"
        if [[ -f "$task_state_file" ]]; then
            rm -f "$task_state_file" || {
                log_warn "Failed to remove task state file: $task_state_file"
            }
        fi
    fi
    
    log_info "Task removed from queue: $task_id"
    return 0
}

# Nächsten Task aus Queue holen (priority-basiert)
get_next_task() {
    local filter_status="${1:-$TASK_STATE_PENDING}"
    
    log_debug "Getting next task with status: $filter_status"
    
    # Ensure arrays are initialized before accessing them
    if ! declare -p TASK_STATES >/dev/null 2>&1; then
        declare -gA TASK_STATES
        declare -gA TASK_METADATA
        declare -gA TASK_RETRY_COUNTS
        declare -gA TASK_TIMESTAMPS
        declare -gA TASK_PRIORITIES
        log_debug "Initialized arrays in get_next_task"
    fi
    
    local best_task_id=""
    local best_priority=11  # Höher als Maximum (10)
    
    # Finde Task mit höchster Priority (niedrigste Zahl)
    for task_id in "${!TASK_STATES[@]}"; do
        local status="${TASK_STATES[$task_id]}"
        local priority="${TASK_PRIORITIES[$task_id]:-5}"
        
        if [[ "$status" == "$filter_status" ]]; then
            if [[ $priority -lt $best_priority ]]; then
                best_priority=$priority
                best_task_id="$task_id"
            elif [[ $priority -eq $best_priority && -n "$best_task_id" ]]; then
                # Bei gleicher Priority: FIFO (älterer Task)
                local current_created="${TASK_TIMESTAMPS[${task_id}_created]:-}"
                local best_created="${TASK_TIMESTAMPS[${best_task_id}_created]:-}"
                
                if [[ "$current_created" < "$best_created" ]]; then
                    best_task_id="$task_id"
                fi
            fi
        fi
    done
    
    if [[ -n "$best_task_id" ]]; then
        log_debug "Next task: $best_task_id (priority: $best_priority)"
        echo "$best_task_id"
        return 0
    else
        log_debug "No tasks found with status: $filter_status"
        return 1
    fi
}

# Task-Status aktualisieren
update_task_status() {
    local task_id="$1"
    local new_status="$2"
    local details="${3:-}"
    
    validate_task_id "$task_id" || return 1
    
    if [[ -z "${TASK_STATES[$task_id]:-}" ]]; then
        log_error "Task not found: $task_id"
        return 1
    fi
    
    local old_status="${TASK_STATES[$task_id]}"
    
    # Validate state transition
    case "$old_status" in
        "$TASK_STATE_PENDING")
            if [[ "$new_status" != "$TASK_STATE_IN_PROGRESS" && "$new_status" != "$TASK_STATE_FAILED" ]]; then
                log_error "Invalid state transition: $old_status -> $new_status for task $task_id"
                return 1
            fi
            ;;
        "$TASK_STATE_IN_PROGRESS")
            if [[ "$new_status" != "$TASK_STATE_COMPLETED" && "$new_status" != "$TASK_STATE_FAILED" && "$new_status" != "$TASK_STATE_TIMEOUT" ]]; then
                log_error "Invalid state transition: $old_status -> $new_status for task $task_id"
                return 1
            fi
            ;;
        "$TASK_STATE_COMPLETED")
            log_error "Cannot transition from completed state: $task_id"
            return 1
            ;;
        "$TASK_STATE_FAILED"|"$TASK_STATE_TIMEOUT")
            if [[ "$new_status" != "$TASK_STATE_PENDING" ]]; then
                log_error "Invalid state transition: $old_status -> $new_status for task $task_id"
                return 1
            fi
            ;;
    esac
    
    if [[ "$old_status" != "$new_status" ]]; then
        log_info "Task $task_id state change: $old_status -> $new_status"
        [[ -n "$details" ]] && log_debug "State change details: $details"
        
        TASK_STATES["$task_id"]="$new_status"
        TASK_TIMESTAMPS["${task_id}_${new_status}"]=$(date -Iseconds)
        
        return 0
    else
        log_debug "Task $task_id already in state: $new_status"
        return 0
    fi
}

# Task-Priority aktualisieren
update_task_priority() {
    local task_id="$1"
    local new_priority="$2"
    
    validate_task_id "$task_id" || return 1
    
    if [[ -z "${TASK_STATES[$task_id]:-}" ]]; then
        log_error "Task not found: $task_id"
        return 1
    fi
    
    if ! [[ "$new_priority" =~ ^[0-9]+$ ]] || [[ $new_priority -lt 1 ]] || [[ $new_priority -gt 10 ]]; then
        log_error "Priority must be between 1 and 10: $new_priority"
        return 1
    fi
    
    local old_priority="${TASK_PRIORITIES[$task_id]}"
    
    if [[ "$old_priority" != "$new_priority" ]]; then
        log_info "Task $task_id priority change: $old_priority -> $new_priority"
        TASK_PRIORITIES["$task_id"]="$new_priority"
        return 0
    else
        log_debug "Task $task_id already has priority: $new_priority"
        return 0
    fi
}

# Queue-Tasks auflisten
list_queue_tasks() {
    local status_filter="${1:-all}"
    local sort_by="${2:-priority}"
    
    log_debug "Listing tasks (filter: $status_filter, sort: $sort_by)"
    
    local task_count=0
    # Check if TASK_STATES has elements for listing
    if declare -p TASK_STATES >/dev/null 2>&1 && [[ ${#TASK_STATES[@]} -gt 0 ]] 2>/dev/null; then
        task_count=${#TASK_STATES[@]}
    fi
    
    if [[ $task_count -eq 0 ]]; then
        echo "No tasks in queue"
        return 0
    fi
    
    echo "=== Task Queue ==="
    printf "%-20s %-15s %-12s %-3s %-8s %-10s %s\n" \
           "TASK_ID" "TYPE" "STATUS" "PRI" "RETRIES" "CREATED" "TITLE/DESC"
    echo "$(printf '%.0s-' {1..100})"
    
    # Sammle und sortiere Tasks
    local task_list=()
    for task_id in "${!TASK_STATES[@]}"; do
        local status="${TASK_STATES[$task_id]}"
        
        # Apply status filter
        if [[ "$status_filter" != "all" && "$status" != "$status_filter" ]]; then
            continue
        fi
        
        task_list+=("$task_id")
    done
    
    # Sort tasks
    if [[ "$sort_by" == "priority" ]]; then
        # Sort by priority, then by creation time
        mapfile -t task_list < <(
            for task_id in "${task_list[@]}"; do
                local priority="${TASK_PRIORITIES[$task_id]:-5}"
                local created="${TASK_TIMESTAMPS[${task_id}_created]:-}"
                printf "%02d %s %s\n" "$priority" "$created" "$task_id"
            done | sort -k1,1n -k2,2 | cut -d' ' -f3
        )
    elif [[ "$sort_by" == "created" ]]; then
        # Sort by creation time
        mapfile -t task_list < <(
            for task_id in "${task_list[@]}"; do
                local created="${TASK_TIMESTAMPS[${task_id}_created]:-}"
                printf "%s %s\n" "$created" "$task_id"
            done | sort -k1,1 | cut -d' ' -f2
        )
    fi
    
    # Display tasks
    for task_id in "${task_list[@]}"; do
        local task_type="${TASK_METADATA[${task_id}_type]:-}"
        local status="${TASK_STATES[$task_id]}"
        local priority="${TASK_PRIORITIES[$task_id]:-5}"
        local retry_count="${TASK_RETRY_COUNTS[$task_id]:-0}"
        local max_retries="${TASK_METADATA[${task_id}_max_retries]:-$TASK_MAX_RETRIES}"
        local created="${TASK_TIMESTAMPS[${task_id}_created]:-}"
        local created_short=$(echo "$created" | cut -d'T' -f1)
        
        # Get title or description
        local display_text=""
        if [[ "$task_type" == "$TASK_TYPE_GITHUB_ISSUE" ]]; then
            display_text="${TASK_METADATA[${task_id}_title]:-}"
            local github_number="${TASK_METADATA[${task_id}_github_number]:-}"
            [[ -n "$github_number" ]] && display_text="#$github_number: $display_text"
        elif [[ "$task_type" == "$TASK_TYPE_CUSTOM" ]]; then
            display_text="${TASK_METADATA[${task_id}_description]:-}"
        fi
        
        # Truncate long text
        if [[ ${#display_text} -gt 30 ]]; then
            display_text="${display_text:0:27}..."
        fi
        
        printf "%-20s %-15s %-12s %-3s %-8s %-10s %s\n" \
               "$task_id" "$task_type" "$status" "$priority" \
               "$retry_count/$max_retries" "$created_short" "$display_text"
    done
    
    # Show summary
    local total=${#task_list[@]}
    local pending=0 active=0 completed=0 failed=0 timeout=0
    
    for task_id in "${task_list[@]}"; do
        case "${TASK_STATES[$task_id]}" in
            "$TASK_STATE_PENDING") ((pending++)) ;;
            "$TASK_STATE_IN_PROGRESS") ((active++)) ;;
            "$TASK_STATE_COMPLETED") ((completed++)) ;;
            "$TASK_STATE_FAILED") ((failed++)) ;;
            "$TASK_STATE_TIMEOUT") ((timeout++)) ;;
        esac
    done
    
    echo ""
    echo "Summary: $total total | $pending pending | $active active | $completed completed | $failed failed | $timeout timeout"
}

# Gesamte Queue leeren
clear_task_queue() {
    local create_backup="${1:-true}"
    
    log_warn "Clearing entire task queue (backup: $create_backup)"
    
    local current_size=0
    if declare -p TASK_STATES >/dev/null 2>&1 && [[ ${#TASK_STATES[@]} -gt 0 ]] 2>/dev/null; then
        current_size=${#TASK_STATES[@]}
    fi
    
    if [[ $current_size -eq 0 ]]; then
        log_info "Queue is already empty"
        return 0
    fi
    
    # Create backup before clearing
    if [[ "$create_backup" == "true" ]]; then
        backup_queue_state "before-clear" || {
            log_error "Failed to create backup before clearing queue"
            return 1
        }
    fi
    
    local task_count=$current_size
    
    # Clear all data structures
    declare -gA TASK_STATES
    declare -gA TASK_METADATA
    declare -gA TASK_RETRY_COUNTS
    declare -gA TASK_TIMESTAMPS
    declare -gA TASK_PRIORITIES
    
    # Remove task state files
    local task_states_dir="$PROJECT_ROOT/$TASK_QUEUE_DIR/task-states"
    if [[ -d "$task_states_dir" ]]; then
        rm -f "$task_states_dir"/*.json 2>/dev/null || {
            log_warn "Failed to remove some task state files"
        }
    fi
    
    log_info "Queue cleared: removed $task_count tasks"
    return 0
}

# ===============================================================================
# RETRY-LOGIC UND ERROR-TRACKING
# ===============================================================================

# Retry-Counter erhöhen
increment_retry_count() {
    local task_id="$1"
    
    validate_task_id "$task_id" || return 1
    
    if [[ -z "${TASK_STATES[$task_id]:-}" ]]; then
        log_error "Task not found: $task_id"
        return 1
    fi
    
    local current_count="${TASK_RETRY_COUNTS[$task_id]:-0}"
    local max_retries="${TASK_METADATA[${task_id}_max_retries]:-$TASK_MAX_RETRIES}"
    
    TASK_RETRY_COUNTS["$task_id"]=$((current_count + 1))
    
    log_info "Task $task_id retry count incremented: $((current_count + 1))/$max_retries"
    
    if [[ $((current_count + 1)) -ge $max_retries ]]; then
        log_warn "Task $task_id has reached maximum retry count"
        return 1
    fi
    
    return 0
}

# Task-Error protokollieren
record_task_error() {
    local task_id="$1"
    local error_message="$2"
    local error_code="${3:-1}"
    
    validate_task_id "$task_id" || return 1
    
    local current_time=$(date -Iseconds)
    local retry_count="${TASK_RETRY_COUNTS[$task_id]:-0}"
    
    # Store error details in metadata
    TASK_METADATA["${task_id}_last_error"]="$error_message"
    TASK_METADATA["${task_id}_last_error_code"]="$error_code"
    TASK_METADATA["${task_id}_last_error_time"]="$current_time"
    
    log_error "Task $task_id error (retry $retry_count): $error_message (code: $error_code)"
    
    # Update task status to failed
    update_task_status "$task_id" "$TASK_STATE_FAILED" "error: $error_message"
}

# Prüfe Retry-Berechtigung
check_retry_eligibility() {
    local task_id="$1"
    
    validate_task_id "$task_id" || return 1
    
    if [[ -z "${TASK_STATES[$task_id]:-}" ]]; then
        log_error "Task not found: $task_id"
        return 1
    fi
    
    local status="${TASK_STATES[$task_id]}"
    local retry_count="${TASK_RETRY_COUNTS[$task_id]:-0}"
    local max_retries="${TASK_METADATA[${task_id}_max_retries]:-$TASK_MAX_RETRIES}"
    
    # Only failed or timeout tasks can be retried
    if [[ "$status" != "$TASK_STATE_FAILED" && "$status" != "$TASK_STATE_TIMEOUT" ]]; then
        log_debug "Task $task_id is not eligible for retry (status: $status)"
        return 1
    fi
    
    # Check retry limit
    if [[ $retry_count -ge $max_retries ]]; then
        log_debug "Task $task_id has exceeded retry limit ($retry_count >= $max_retries)"
        return 1
    fi
    
    log_debug "Task $task_id is eligible for retry ($retry_count < $max_retries)"
    return 0
}

# ===============================================================================
# GITHUB-SPEZIFISCHE FUNKTIONEN
# ===============================================================================

# GitHub Issue Task erstellen
create_github_issue_task() {
    local github_number="$1"
    local priority="${2:-5}"
    local title="${3:-}"
    local labels="${4:-}"
    
    if ! [[ "$github_number" =~ ^[0-9]+$ ]]; then
        log_error "GitHub issue number must be numeric: $github_number"
        return 1
    fi
    
    local task_id="issue-${github_number}"
    local command="/dev $github_number"
    
    if [[ -z "$title" ]]; then
        title="GitHub Issue #$github_number"
    fi
    
    log_info "Creating GitHub issue task: #$github_number"
    
    add_task_to_queue "$TASK_TYPE_GITHUB_ISSUE" "$priority" "$task_id" \
        "github_number" "$github_number" \
        "title" "$title" \
        "labels" "$labels" \
        "command" "$command"
}

# GitHub PR Task erstellen  
create_github_pr_task() {
    local github_number="$1"
    local priority="${2:-5}"
    local title="${3:-}"
    
    if ! [[ "$github_number" =~ ^[0-9]+$ ]]; then
        log_error "GitHub PR number must be numeric: $github_number"
        return 1
    fi
    
    local task_id="pr-${github_number}"
    local command="/dev $github_number"
    
    if [[ -z "$title" ]]; then
        title="GitHub PR #$github_number"
    fi
    
    log_info "Creating GitHub PR task: #$github_number"
    
    add_task_to_queue "$TASK_TYPE_GITHUB_PR" "$priority" "$task_id" \
        "github_number" "$github_number" \
        "title" "$title" \
        "command" "$command"
}

# Validiere GitHub Task
validate_github_task() {
    local task_id="$1"
    
    validate_task_id "$task_id" || return 1
    
    local task_type="${TASK_METADATA[${task_id}_type]:-}"
    
    if [[ "$task_type" != "$TASK_TYPE_GITHUB_ISSUE" && "$task_type" != "$TASK_TYPE_GITHUB_PR" ]]; then
        log_error "Task is not a GitHub task: $task_id (type: $task_type)"
        return 1
    fi
    
    local github_number="${TASK_METADATA[${task_id}_github_number]:-}"
    if [[ -z "$github_number" ]]; then
        log_error "GitHub task missing issue/PR number: $task_id"
        return 1
    fi
    
    if ! [[ "$github_number" =~ ^[0-9]+$ ]]; then
        log_error "Invalid GitHub number format: $github_number"
        return 1
    fi
    
    return 0
}

# ===============================================================================
# QUEUE-STATISTICS UND MONITORING
# ===============================================================================

# Hole Task-Duration
get_task_duration() {
    local task_id="$1"
    
    validate_task_id "$task_id" || return 1
    
    local created="${TASK_TIMESTAMPS[${task_id}_created]:-}"
    local completed="${TASK_TIMESTAMPS[${task_id}_completed]:-}"
    local failed="${TASK_TIMESTAMPS[${task_id}_failed]:-}"
    local timeout="${TASK_TIMESTAMPS[${task_id}_timeout]:-}"
    
    if [[ -z "$created" ]]; then
        log_error "Task creation time not found: $task_id"
        return 1
    fi
    
    local end_time=""
    if [[ -n "$completed" ]]; then
        end_time="$completed"
    elif [[ -n "$failed" ]]; then
        end_time="$failed"
    elif [[ -n "$timeout" ]]; then
        end_time="$timeout"
    else
        # Task still in progress - use current time
        end_time=$(date -Iseconds)
    fi
    
    # Calculate duration (basic implementation - could be improved)
    local created_epoch
    local end_epoch
    created_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$(echo "$created" | cut -d'+' -f1)" "+%s" 2>/dev/null || echo "0")
    end_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$(echo "$end_time" | cut -d'+' -f1)" "+%s" 2>/dev/null || echo "0")
    
    if [[ $created_epoch -gt 0 && $end_epoch -gt 0 ]]; then
        local duration=$((end_epoch - created_epoch))
        echo "$duration"
        return 0
    else
        log_error "Failed to calculate duration for task: $task_id"
        return 1
    fi
}

# Hole Queue-Statistiken
get_queue_statistics() {
    local total_tasks=0
    # Check if TASK_STATES has elements
    if declare -p TASK_STATES >/dev/null 2>&1 && [[ ${#TASK_STATES[@]} -gt 0 ]] 2>/dev/null; then
        total_tasks=${#TASK_STATES[@]}
    fi
    local pending_tasks=0
    local active_tasks=0
    local completed_tasks=0
    local failed_tasks=0
    local timeout_tasks=0
    # total_duration is calculated but not used in final output
    # local total_duration=0
    local completed_duration=0
    
    for task_id in "${!TASK_STATES[@]}"; do
        local status="${TASK_STATES[$task_id]}"
        
        case "$status" in
            "$TASK_STATE_PENDING") ((pending_tasks++)) ;;
            "$TASK_STATE_IN_PROGRESS") ((active_tasks++)) ;;
            "$TASK_STATE_COMPLETED") 
                ((completed_tasks++))
                local duration
                if duration=$(get_task_duration "$task_id"); then
                    ((completed_duration += duration))
                fi
                ;;
            "$TASK_STATE_FAILED") ((failed_tasks++)) ;;
            "$TASK_STATE_TIMEOUT") ((timeout_tasks++)) ;;
        esac
    done
    
    local avg_completion_time=0
    if [[ $completed_tasks -gt 0 ]]; then
        avg_completion_time=$((completed_duration / completed_tasks))
    fi
    
    cat <<EOF
=== Queue Statistics ===
Total Tasks: $total_tasks
Pending: $pending_tasks
Active: $active_tasks
Completed: $completed_tasks
Failed: $failed_tasks
Timeout: $timeout_tasks

Completion Rate: $(( completed_tasks * 100 / (total_tasks > 0 ? total_tasks : 1) ))%
Average Completion Time: ${avg_completion_time}s
EOF
}

# ===============================================================================
# CLEANUP UND MAINTENANCE
# ===============================================================================

# Bereinige alte Tasks
cleanup_old_tasks() {
    local max_age_days="${1:-$TASK_AUTO_CLEANUP_DAYS}"
    
    if [[ $max_age_days -le 0 ]]; then
        log_debug "Task auto-cleanup disabled (max_age_days: $max_age_days)"
        return 0
    fi
    
    log_info "Cleaning up tasks older than $max_age_days days"
    
    local current_time
    current_time=$(date +%s)
    local max_age_seconds=$((max_age_days * 24 * 3600))
    local cleaned_count=0
    
    # Collect tasks to clean
    local tasks_to_clean=()
    for task_id in "${!TASK_STATES[@]}"; do
        local status="${TASK_STATES[$task_id]}"
        
        # Only clean completed, failed, or timeout tasks
        if [[ "$status" != "$TASK_STATE_COMPLETED" && "$status" != "$TASK_STATE_FAILED" && "$status" != "$TASK_STATE_TIMEOUT" ]]; then
            continue
        fi
        
        local created="${TASK_TIMESTAMPS[${task_id}_created]:-}"
        if [[ -z "$created" ]]; then
            continue
        fi
        
        # Calculate age (basic implementation)
        local created_epoch
        created_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$(echo "$created" | cut -d'+' -f1)" "+%s" 2>/dev/null || echo "0")
        if [[ $created_epoch -gt 0 ]]; then
            local age=$((current_time - created_epoch))
            if [[ $age -gt $max_age_seconds ]]; then
                tasks_to_clean+=("$task_id")
            fi
        fi
    done
    
    # Clean up old tasks
    for task_id in "${tasks_to_clean[@]}"; do
        local status="${TASK_STATES[$task_id]}"
        log_debug "Cleaning up old task: $task_id (status: $status, age: >$max_age_days days)"
        
        if remove_task_from_queue "$task_id" "true"; then
            ((cleaned_count++))
        fi
    done
    
    if [[ $cleaned_count -gt 0 ]]; then
        log_info "Cleaned up $cleaned_count old tasks"
    else
        log_debug "No old tasks to clean up"
    fi
    
    return 0
}

# Bereinige alte Backups
cleanup_old_backups() {
    local max_age_days="${1:-$TASK_BACKUP_RETENTION_DAYS}"
    local backups_dir="$PROJECT_ROOT/$TASK_QUEUE_DIR/backups"
    
    if [[ $max_age_days -le 0 ]]; then
        log_debug "Backup cleanup disabled (max_age_days: $max_age_days)"
        return 0
    fi
    
    if [[ ! -d "$backups_dir" ]]; then
        log_debug "No backups directory to clean: $backups_dir"
        return 0
    fi
    
    log_info "Cleaning up backup files older than $max_age_days days"
    
    local cleaned_count=0
    if command -v find >/dev/null 2>&1; then
        # Use find command if available
        local old_backups
        mapfile -t old_backups < <(find "$backups_dir" -name "backup-*.json" -type f -mtime +$max_age_days 2>/dev/null)
        
        for backup_file in "${old_backups[@]}"; do
            if rm -f "$backup_file"; then
                ((cleaned_count++))
                log_debug "Removed old backup: $(basename "$backup_file")"
            fi
        done
    else
        log_warn "find command not available - skipping backup cleanup"
    fi
    
    if [[ $cleaned_count -gt 0 ]]; then
        log_info "Cleaned up $cleaned_count old backup files"
    else
        log_debug "No old backup files to clean up"
    fi
    
    return 0
}

# ===============================================================================
# ÖFFENTLICHE API-FUNKTIONEN
# ===============================================================================

# Initialisiere Task-Queue-System
init_task_queue() {
    local config_file="${1:-config/default.conf}"
    
    log_info "Initializing task queue system"
    
    # Check dependencies first
    check_dependencies || {
        log_error "Missing dependencies - cannot initialize task queue"
        return 1
    }
    
    # Load configuration (but preserve environment variables)
    if [[ -f "$config_file" ]]; then
        while IFS='=' read -r key value; do
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$key" ]] && continue
            
            value=$(echo "$value" | sed 's/^["'\'']\|["'\'']$//g')
            
            case "$key" in
                TASK_QUEUE_ENABLED|TASK_QUEUE_DIR|TASK_DEFAULT_TIMEOUT|TASK_MAX_RETRIES|TASK_RETRY_DELAY|TASK_COMPLETION_PATTERN|TASK_QUEUE_MAX_SIZE|TASK_AUTO_CLEANUP_DAYS|TASK_BACKUP_RETENTION_DAYS|QUEUE_LOCK_TIMEOUT)
                    # Only set from config if not already set in environment
                    if [[ -z "${!key:-}" ]]; then
                        eval "$key='$value'"
                    fi
                    ;;
            esac
        done < <(grep -E '^[^#]*=' "$config_file" || true)
        
        log_debug "Task queue configured from: $config_file"
    fi
    
    # Check if task queue is enabled
    if [[ "$TASK_QUEUE_ENABLED" != "true" ]]; then
        log_warn "Task queue is disabled in configuration"
        return 1
    fi
    
    # Ensure directories exist
    ensure_queue_directories || {
        log_error "Failed to create queue directories"
        return 1
    }
    
    # Initialize arrays if not already done
    # Use a safer check for array initialization
    if ! declare -p TASK_STATES >/dev/null 2>&1; then
        declare -gA TASK_STATES
        declare -gA TASK_METADATA
        declare -gA TASK_RETRY_COUNTS
        declare -gA TASK_TIMESTAMPS
        declare -gA TASK_PRIORITIES
        log_debug "Initialized global task arrays"
    fi
    
    # Load existing queue state
    load_queue_state || {
        log_error "Failed to load existing queue state"
        return 1
    }
    
    log_info "Task queue system initialized successfully"
    local task_count=0
    if declare -p TASK_STATES >/dev/null 2>&1 && [[ ${#TASK_STATES[@]} -gt 0 ]] 2>/dev/null; then
        task_count=${#TASK_STATES[@]}
    fi
    log_info "Queue state: $task_count tasks loaded"
    
    return 0
}

# Task-Queue-Status anzeigen
show_queue_status() {
    if [[ "$TASK_QUEUE_ENABLED" != "true" ]]; then
        echo "Task Queue: DISABLED"
        return 0
    fi
    
    echo "=== Task Queue Status ==="
    echo "Queue Directory: $PROJECT_ROOT/$TASK_QUEUE_DIR"
    echo "Max Queue Size: $([ $TASK_QUEUE_MAX_SIZE -eq 0 ] && echo "unlimited" || echo $TASK_QUEUE_MAX_SIZE)"
    echo "Default Timeout: ${TASK_DEFAULT_TIMEOUT}s"
    echo "Max Retries: $TASK_MAX_RETRIES"
    echo "Auto Cleanup: $([ $TASK_AUTO_CLEANUP_DAYS -gt 0 ] && echo "${TASK_AUTO_CLEANUP_DAYS} days" || echo "disabled")"
    echo ""
    
    get_queue_statistics
    echo ""
    
    list_queue_tasks "all" "priority"
}

# ===============================================================================
# CLI OPERATION WRAPPER (für Array-Persistenz)
# ===============================================================================

# Wrapper für alle CLI-Operationen mit automatischer JSON-Synchronisation
cli_operation_wrapper() {
    local operation="$1"
    shift
    
    # Initialize und State aus JSON laden
    init_task_queue || {
        log_error "Failed to initialize task queue for CLI operation"
        return 1
    }
    
    log_debug "CLI Operation: $operation with args: $*"
    
    # Operation ausführen
    "$operation" "$@"
    local result=$?
    
    # State automatisch nach JSON speichern für state-changing operations
    local state_changing_ops=("add_task_cmd" "remove_task_cmd" "clear_queue_cmd" "github_issue_cmd" "cleanup_cmd")
    local op_name
    for op_name in "${state_changing_ops[@]}"; do
        if [[ "$operation" == "$op_name" ]]; then
            if [[ $result -eq 0 ]]; then
                with_queue_lock save_queue_state || {
                    log_error "Failed to save queue state after $operation"
                    return 1
                }
                log_debug "Queue state saved after $operation"
            fi
            break
        fi
    done
    
    return $result
}

# CLI Command Implementations (mit verbesserter Fehlerbehandlung)
add_task_cmd() {
    if [[ $# -ge 2 ]]; then
        local task_id
        task_id=$(with_queue_lock add_task_to_queue "$1" "$2" "${3:-}" "${@:4}")
        if [[ $? -eq 0 && -n "$task_id" ]]; then
            echo "Task added: $task_id"
            return 0
        else
            echo "Failed to add task" >&2
            return 1
        fi
    else
        echo "Usage: add <type> <priority> [task_id] [metadata...]" >&2
        return 1
    fi
}

remove_task_cmd() {
    if [[ $# -ge 1 ]]; then
        if with_queue_lock remove_task_from_queue "$1"; then
            echo "Task removed: $1"
            return 0
        else
            echo "Failed to remove task: $1" >&2
            return 1
        fi
    else
        echo "Usage: remove <task_id>" >&2
        return 1
    fi
}

clear_queue_cmd() {
    if with_queue_lock clear_task_queue; then
        echo "Queue cleared"
        return 0
    else
        echo "Failed to clear queue" >&2
        return 1
    fi
}

github_issue_cmd() {
    if [[ $# -ge 1 ]]; then
        local task_id
        task_id=$(with_queue_lock create_github_issue_task "$1" "${2:-5}" "${3:-}" "${4:-}")
        if [[ $? -eq 0 && -n "$task_id" ]]; then
            echo "GitHub issue task added: $task_id"
            return 0
        else
            echo "Failed to add GitHub issue task" >&2
            return 1
        fi
    else
        echo "Usage: github-issue <number> [priority] [title] [labels]" >&2
        return 1
    fi
}

cleanup_cmd() {
    with_queue_lock cleanup_old_tasks
    with_queue_lock cleanup_old_backups
    echo "Cleanup completed"
    return 0
}

# Status-only operations (no state changes, load-only)
status_cmd() {
    show_queue_status
}

list_tasks_cmd() {
    list_queue_tasks "${1:-all}" "${2:-priority}"
}

stats_cmd() {
    get_queue_statistics
}

# ===============================================================================
# ENHANCED STATUS DASHBOARD
# ===============================================================================

# Erweiterte Status-Anzeige mit Farben und detaillierteren Informationen
show_enhanced_status() {
    local use_colors="${1:-true}"
    local output_format="${2:-text}" # text, json, compact
    
    if [[ "$TASK_QUEUE_ENABLED" != "true" ]]; then
        if [[ "$output_format" == "json" ]]; then
            echo '{"status": "disabled", "message": "Task Queue is disabled"}'
        else
            echo "Task Queue: DISABLED"
        fi
        return 0
    fi
    
    # Color definitions
    local RED='' GREEN='' YELLOW='' BLUE='' CYAN='' RESET=''
    if [[ "$use_colors" == "true" ]] && [[ -t 1 ]]; then
        RED='\033[0;31m'
        GREEN='\033[0;32m'
        YELLOW='\033[0;33m'
        BLUE='\033[0;34m'
        CYAN='\033[0;36m'
        RESET='\033[0m'
    fi
    
    # Gather statistics
    local total_tasks=0 pending_tasks=0 active_tasks=0 completed_tasks=0 failed_tasks=0
    local task_id
    
    if declare -p TASK_STATES >/dev/null 2>&1; then
        for task_id in "${!TASK_STATES[@]}"; do
            case "${TASK_STATES[$task_id]}" in
                "$TASK_STATE_PENDING") ((pending_tasks++)) ;;
                "$TASK_STATE_IN_PROGRESS") ((active_tasks++)) ;;
                "$TASK_STATE_COMPLETED") ((completed_tasks++)) ;;
                "$TASK_STATE_FAILED"|"$TASK_STATE_TIMEOUT") ((failed_tasks++)) ;;
            esac
            ((total_tasks++))
        done
    fi
    
    if [[ "$output_format" == "json" ]]; then
        cat <<EOF
{
  "status": "enabled",
  "queue_directory": "$PROJECT_ROOT/$TASK_QUEUE_DIR",
  "configuration": {
    "max_queue_size": $([ $TASK_QUEUE_MAX_SIZE -eq 0 ] && echo "null" || echo $TASK_QUEUE_MAX_SIZE),
    "default_timeout": $TASK_DEFAULT_TIMEOUT,
    "max_retries": $TASK_MAX_RETRIES,
    "auto_cleanup_days": $([ $TASK_AUTO_CLEANUP_DAYS -gt 0 ] && echo $TASK_AUTO_CLEANUP_DAYS || echo "null")
  },
  "statistics": {
    "total_tasks": $total_tasks,
    "pending_tasks": $pending_tasks,
    "active_tasks": $active_tasks,
    "completed_tasks": $completed_tasks,
    "failed_tasks": $failed_tasks
  },
  "health_status": "$(get_queue_health_status)"
}
EOF
        return 0
    fi
    
    if [[ "$output_format" == "compact" ]]; then
        printf "Queue: %d total (%s%d pending%s, %s%d active%s, %s%d completed%s, %s%d failed%s)\n" \
            $total_tasks \
            "$YELLOW" $pending_tasks "$RESET" \
            "$BLUE" $active_tasks "$RESET" \
            "$GREEN" $completed_tasks "$RESET" \
            "$RED" $failed_tasks "$RESET"
        return 0
    fi
    
    # Default detailed text output
    echo -e "${CYAN}=== Enhanced Task Queue Status ===${RESET}"
    echo "Queue Directory: $PROJECT_ROOT/$TASK_QUEUE_DIR"
    echo "Max Queue Size: $([ $TASK_QUEUE_MAX_SIZE -eq 0 ] && echo "unlimited" || echo $TASK_QUEUE_MAX_SIZE)"
    echo "Default Timeout: ${TASK_DEFAULT_TIMEOUT}s"
    echo "Max Retries: $TASK_MAX_RETRIES"
    echo "Auto Cleanup: $([ $TASK_AUTO_CLEANUP_DAYS -gt 0 ] && echo "${TASK_AUTO_CLEANUP_DAYS} days" || echo "disabled")"
    echo ""
    
    echo -e "${CYAN}=== Task Statistics ===${RESET}"
    printf "Total Tasks:     %d\n" $total_tasks
    printf "${YELLOW}Pending:         %d${RESET}\n" $pending_tasks
    printf "${BLUE}Active:          %d${RESET}\n" $active_tasks
    printf "${GREEN}Completed:       %d${RESET}\n" $completed_tasks
    printf "${RED}Failed/Timeout:  %d${RESET}\n" $failed_tasks
    echo ""
    
    # Health status
    local health_status
    health_status=$(get_queue_health_status)
    case "$health_status" in
        "healthy")
            echo -e "Health Status: ${GREEN}HEALTHY${RESET}"
            ;;
        "warning")
            echo -e "Health Status: ${YELLOW}WARNING${RESET}"
            ;;
        "critical")
            echo -e "Health Status: ${RED}CRITICAL${RESET}"
            ;;
        *)
            echo -e "Health Status: ${YELLOW}UNKNOWN${RESET}"
            ;;
    esac
    echo ""
    
    # Recent activity (last 5 tasks)
    if [[ $total_tasks -gt 0 ]]; then
        echo -e "${CYAN}=== Recent Tasks (Last 5) ===${RESET}"
        list_queue_tasks "all" "created" "5"
    fi
}

# Bestimme Queue Health Status
get_queue_health_status() {
    local total_tasks=0 failed_tasks=0 active_tasks=0
    local task_id
    
    if declare -p TASK_STATES >/dev/null 2>&1; then
        for task_id in "${!TASK_STATES[@]}"; do
            case "${TASK_STATES[$task_id]}" in
                "$TASK_STATE_FAILED"|"$TASK_STATE_TIMEOUT") ((failed_tasks++)) ;;
                "$TASK_STATE_IN_PROGRESS") ((active_tasks++)) ;;
            esac
            ((total_tasks++))
        done
    fi
    
    # Health logic
    if [[ $total_tasks -eq 0 ]]; then
        echo "healthy"
    elif [[ $failed_tasks -gt 0 ]] && [[ $((failed_tasks * 100 / total_tasks)) -gt 20 ]]; then
        echo "critical"
    elif [[ $active_tasks -gt 5 ]] || [[ $failed_tasks -gt 0 ]]; then
        echo "warning"
    else
        echo "healthy"
    fi
}

# ===============================================================================
# INTERACTIVE MODE
# ===============================================================================

# Interactive Mode mit Real-time Queue Management
start_interactive_mode() {
    echo "=== Task Queue Interactive Mode ==="
    echo "Type 'help' for commands, 'quit' to exit"
    echo ""
    
    # Set up readline if available
    if command -v read >/dev/null 2>&1; then
        local readline_available=true
    else
        local readline_available=false
    fi
    
    while true; do
        # Load current state for fresh status
        load_queue_state >/dev/null 2>&1 || true
        
        # Show current status in prompt
        local pending_count=0 active_count=0 total_count=0
        if declare -p TASK_STATES >/dev/null 2>&1; then
            local task_id
            for task_id in "${!TASK_STATES[@]}"; do
                case "${TASK_STATES[$task_id]}" in
                    "$TASK_STATE_PENDING") ((pending_count++)) ;;
                    "$TASK_STATE_IN_PROGRESS") ((active_count++)) ;;
                esac
                ((total_count++))
            done
        fi
        
        # Color-coded prompt
        if [[ -t 1 ]]; then
            printf "\n\033[0;36m[%d total, \033[0;33m%d pending\033[0;36m, \033[0;34m%d active\033[0;36m]\033[0m > " \
                "$total_count" "$pending_count" "$active_count"
        else
            printf "\n[%d total, %d pending, %d active] > " "$total_count" "$pending_count" "$active_count"
        fi
        
        # Read command
        local command args
        if [[ "$readline_available" == "true" ]]; then
            read -r -e command args
        else
            read -r command args
        fi
        
        # Skip empty commands
        [[ -z "$command" ]] && continue
        
        # Process command
        case "$command" in
            "help"|"h"|"?")
                show_interactive_help
                ;;
            "status"|"s")
                show_enhanced_status "true" "compact"
                ;;
            "list"|"l")
                list_queue_tasks ${args:-all} priority
                ;;
            "add"|"a")
                if [[ -n "$args" ]]; then
                    # Parse args for add command
                    local add_args=($args)
                    if [[ ${#add_args[@]} -ge 2 ]]; then
                        cli_operation_wrapper add_task_cmd "${add_args[@]}"
                    else
                        echo "Usage: add <type> <priority> [task_id] [metadata...]"
                    fi
                else
                    echo "Usage: add <type> <priority> [task_id] [metadata...]"
                fi
                ;;
            "remove"|"rm"|"r")
                if [[ -n "$args" ]]; then
                    cli_operation_wrapper remove_task_cmd $args
                else
                    echo "Usage: remove <task_id>"
                fi
                ;;
            "clear")
                echo "Are you sure you want to clear all tasks? (y/N)"
                read -r confirmation
                if [[ "$confirmation" =~ ^[Yy]$ ]]; then
                    cli_operation_wrapper clear_queue_cmd
                else
                    echo "Clear cancelled"
                fi
                ;;
            "github"|"gh"|"g")
                if [[ -n "$args" ]]; then
                    local gh_args=($args)
                    cli_operation_wrapper github_issue_cmd "${gh_args[@]}"
                else
                    echo "Usage: github <issue_number> [priority] [title] [labels]"
                fi
                ;;
            "stats"|"statistics")
                get_queue_statistics
                ;;
            "refresh"|"reload")
                echo "Reloading queue state..."
                load_queue_state && echo "Queue reloaded successfully" || echo "Failed to reload queue"
                ;;
            "cleanup")
                echo "Running cleanup..."
                cli_operation_wrapper cleanup_cmd
                ;;
            "quit"|"q"|"exit")
                echo "Exiting interactive mode..."
                break
                ;;
            "next"|"n")
                get_next_task
                ;;
            "config"|"cfg")
                show_current_config
                ;;
            *)
                echo "Unknown command: '$command'. Type 'help' for available commands."
                ;;
        esac
    done
}

# Hilfe für Interactive Mode
show_interactive_help() {
    cat <<EOF
=== Interactive Mode Commands ===

Queue Management:
  list, l [status] [sort]     List tasks (status: all|pending|active|completed|failed)
  add, a <type> <priority>    Add new task to queue
  remove, rm, r <task_id>     Remove task from queue
  clear                       Clear all tasks (with confirmation)
  
GitHub Integration:
  github, gh, g <number>      Add GitHub issue task
  
Queue Operations:
  status, s                   Show compact queue status
  stats, statistics           Show detailed queue statistics
  next, n                     Get next task for processing
  cleanup                     Clean up old tasks and backups
  
System:
  config, cfg                 Show current configuration
  refresh, reload             Reload queue state from disk
  help, h, ?                  Show this help
  quit, q, exit               Exit interactive mode

Examples:
  add custom 1 "" description "Fix login bug" command "fix-login.sh"
  github 123 2
  remove task-1234567890-0001
  list pending priority

Tips:
- Tab completion supported where available
- Command history with arrow keys
- Status shown in prompt: [total, pending, active]
EOF
}

# ===============================================================================
# BATCH OPERATIONS
# ===============================================================================

# Batch-Operation für mehrere Tasks
batch_operation_cmd() {
    local operation="${1:-add}"
    local source_type="${2:-stdin}"
    local source_path="${3:-}"
    
    case "$operation" in
        "add")
            batch_add_tasks "$source_type" "$source_path" "${@:4}"
            ;;
        "remove")
            batch_remove_tasks "$source_type" "$source_path"
            ;;
        *)
            echo "Usage: batch <add|remove> <stdin|file> [path] [additional_args...]" >&2
            return 1
            ;;
    esac
}

# Batch Task Addition
batch_add_tasks() {
    local source_type="$1"
    local source_path="$2"
    local task_type="${3:-custom}"
    local default_priority="${4:-5}"
    
    local input_source
    local temp_file=""
    local line_count=0
    local success_count=0
    local error_count=0
    
    # Determine input source
    case "$source_type" in
        "stdin")
            if [[ -t 0 ]]; then
                echo "Reading from stdin (press Ctrl+D when done):"
            fi
            input_source="/dev/stdin"
            ;;
        "file")
            if [[ -z "$source_path" ]] || [[ ! -f "$source_path" ]]; then
                echo "Error: File path required and must exist for file source" >&2
                return 1
            fi
            input_source="$source_path"
            ;;
        *)
            echo "Error: Invalid source type. Use 'stdin' or 'file'" >&2
            return 1
            ;;
    esac
    
    echo "Starting batch task addition..."
    echo "Task Type: $task_type, Default Priority: $default_priority"
    echo ""
    
    # Process each line
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        
        ((line_count++))
        
        # Parse line - support different formats
        local parsed_task_type="$task_type"
        local parsed_priority="$default_priority"
        local parsed_description=""
        local task_id=""
        
        if [[ "$line" =~ ^[0-9]+$ ]]; then
            # GitHub issue number only
            parsed_task_type="$TASK_TYPE_GITHUB_ISSUE"
            parsed_description="Issue #$line"
            task_id=$(with_queue_lock create_github_issue_task "$line" "$parsed_priority" "" "")
        elif [[ "$line" =~ ^[0-9]+,(.+)$ ]]; then
            # GitHub issue with description: "123,Fix login bug"
            local issue_num="${line%%,*}"
            parsed_description="${line#*,}"
            parsed_task_type="$TASK_TYPE_GITHUB_ISSUE"
            task_id=$(with_queue_lock create_github_issue_task "$issue_num" "$parsed_priority" "$parsed_description" "")
        elif [[ "$line" =~ ^([^,]+),([0-9]+),(.+)$ ]]; then
            # Full format: "type,priority,description"
            parsed_task_type="${BASH_REMATCH[1]}"
            parsed_priority="${BASH_REMATCH[2]}"
            parsed_description="${BASH_REMATCH[3]}"
            task_id=$(with_queue_lock add_task_to_queue "$parsed_task_type" "$parsed_priority" "" "description" "$parsed_description")
        else
            # Simple description only
            parsed_description="$line"
            task_id=$(with_queue_lock add_task_to_queue "$parsed_task_type" "$parsed_priority" "" "description" "$parsed_description")
        fi
        
        if [[ $? -eq 0 && -n "$task_id" ]]; then
            ((success_count++))
            echo "✓ Added task $success_count/$line_count: $task_id ($parsed_description)"
        else
            ((error_count++))
            echo "✗ Failed to add task $line_count: $line" >&2
        fi
        
        # Progress indicator for large batches
        if [[ $((line_count % 10)) -eq 0 ]]; then
            echo "   Processed $line_count lines..."
        fi
    done < "$input_source"
    
    # Save state after batch operation
    if [[ $success_count -gt 0 ]]; then
        with_queue_lock save_queue_state
    fi
    
    # Summary
    echo ""
    echo "=== Batch Operation Complete ==="
    echo "Lines processed: $line_count"
    echo "Tasks added successfully: $success_count"
    echo "Errors: $error_count"
    
    if [[ $error_count -gt 0 ]]; then
        return 1
    fi
    
    return 0
}

# Batch Task Removal
batch_remove_tasks() {
    local source_type="$1"
    local source_path="$2"
    
    local input_source
    local line_count=0
    local success_count=0
    local error_count=0
    
    # Determine input source
    case "$source_type" in
        "stdin")
            if [[ -t 0 ]]; then
                echo "Reading task IDs from stdin (press Ctrl+D when done):"
            fi
            input_source="/dev/stdin"
            ;;
        "file")
            if [[ -z "$source_path" ]] || [[ ! -f "$source_path" ]]; then
                echo "Error: File path required and must exist for file source" >&2
                return 1
            fi
            input_source="$source_path"
            ;;
        *)
            echo "Error: Invalid source type. Use 'stdin' or 'file'" >&2
            return 1
            ;;
    esac
    
    echo "Starting batch task removal..."
    echo ""
    
    # Process each line
    while IFS= read -r task_id || [[ -n "$task_id" ]]; do
        # Skip empty lines and comments
        [[ -z "$task_id" || "$task_id" =~ ^[[:space:]]*# ]] && continue
        
        # Clean whitespace
        task_id=$(echo "$task_id" | tr -d ' \t\r\n')
        
        ((line_count++))
        
        if with_queue_lock remove_task_from_queue "$task_id"; then
            ((success_count++))
            echo "✓ Removed task $success_count/$line_count: $task_id"
        else
            ((error_count++))
            echo "✗ Failed to remove task $line_count: $task_id" >&2
        fi
    done < "$input_source"
    
    # Save state after batch operation
    if [[ $success_count -gt 0 ]]; then
        with_queue_lock save_queue_state
    fi
    
    # Summary
    echo ""
    echo "=== Batch Operation Complete ==="
    echo "Task IDs processed: $line_count"
    echo "Tasks removed successfully: $success_count"
    echo "Errors: $error_count"
    
    if [[ $error_count -gt 0 ]]; then
        return 1
    fi
    
    return 0
}

# ===============================================================================
# CONFIGURATION MANAGEMENT CLI
# ===============================================================================

# Zeige aktuelle Konfiguration
show_current_config() {
    echo "=== Current Task Queue Configuration ==="
    cat <<EOF
Core Settings:
  TASK_QUEUE_ENABLED         = $TASK_QUEUE_ENABLED
  TASK_QUEUE_DIR             = $TASK_QUEUE_DIR
  TASK_QUEUE_MAX_SIZE        = $TASK_QUEUE_MAX_SIZE $([ $TASK_QUEUE_MAX_SIZE -eq 0 ] && echo "(unlimited)")
  
Task Settings:
  TASK_DEFAULT_TIMEOUT       = $TASK_DEFAULT_TIMEOUT seconds
  TASK_MAX_RETRIES           = $TASK_MAX_RETRIES
  TASK_RETRY_DELAY           = $TASK_RETRY_DELAY seconds
  TASK_COMPLETION_PATTERN    = $TASK_COMPLETION_PATTERN
  
Cleanup Settings:
  TASK_AUTO_CLEANUP_DAYS     = $TASK_AUTO_CLEANUP_DAYS $([ $TASK_AUTO_CLEANUP_DAYS -eq 0 ] && echo "(disabled)" || echo "days")
  TASK_BACKUP_RETENTION_DAYS = $TASK_BACKUP_RETENTION_DAYS days
  
System Settings:
  QUEUE_LOCK_TIMEOUT         = $QUEUE_LOCK_TIMEOUT seconds
  
Paths:
  PROJECT_ROOT               = $PROJECT_ROOT
  SCRIPT_DIR                 = $SCRIPT_DIR
  Queue Directory            = $PROJECT_ROOT/$TASK_QUEUE_DIR
EOF
}

# ===============================================================================
# MAIN ENTRY POINT (für Testing und CLI)
# ===============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Handle command line arguments with improved wrapper
    case "${1:-status}" in
        "status")
            cli_operation_wrapper status_cmd
            ;;
        "enhanced-status"|"estatus")
            # Enhanced status with color support and optional JSON output
            colors="true"
            format="text"
            shift
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --no-color|--no-colors) colors="false" ;;
                    --json) format="json" ;;
                    --compact) format="compact" ;;
                    *) break ;;
                esac
                shift
            done
            init_task_queue && show_enhanced_status "$colors" "$format"
            ;;
        "list")
            cli_operation_wrapper list_tasks_cmd "${2:-all}" "${3:-priority}"
            ;;
        "add")
            shift
            cli_operation_wrapper add_task_cmd "$@"
            ;;
        "remove")
            shift
            cli_operation_wrapper remove_task_cmd "$@"
            ;;
        "clear")
            cli_operation_wrapper clear_queue_cmd
            ;;
        "stats")
            cli_operation_wrapper stats_cmd
            ;;
        "cleanup")
            cli_operation_wrapper cleanup_cmd
            ;;
        "github-issue")
            shift
            cli_operation_wrapper github_issue_cmd "$@"
            ;;
        "interactive"|"i")
            # Interactive mode
            init_task_queue && start_interactive_mode
            ;;
        "config")
            if [[ $# -eq 1 ]]; then
                init_task_queue && show_current_config
            else
                echo "Configuration management not yet implemented"
                exit 1
            fi
            ;;
        "next")
            init_task_queue && get_next_task
            ;;
        "batch")
            shift
            cli_operation_wrapper batch_operation_cmd "$@"
            ;;
        "test")
            echo "Running basic tests..."
            
            # Test add task
            echo "Testing task creation..."
            task_id=$(with_queue_lock add_task_to_queue "$TASK_TYPE_CUSTOM" 5 "" "description" "Test task" "command" "echo hello")
            if [[ $? -eq 0 ]]; then
                echo "✓ Task created: $task_id"
            else
                echo "✗ Failed to create task"
                exit 1
            fi
            
            # Test list
            echo "Testing task listing..."
            list_queue_tasks
            
            # Test status update
            echo "Testing status update..."
            if with_queue_lock update_task_status "$task_id" "$TASK_STATE_IN_PROGRESS"; then
                echo "✓ Status updated"
            else
                echo "✗ Failed to update status"
            fi
            
            # Test save/load
            echo "Testing save/load..."
            if with_queue_lock save_queue_state; then
                echo "✓ Queue saved"
            else
                echo "✗ Failed to save queue"
            fi
            
            # Test cleanup
            echo "Testing task removal..."
            if with_queue_lock remove_task_from_queue "$task_id"; then
                echo "✓ Task removed"
            else
                echo "✗ Failed to remove task"
            fi
            
            with_queue_lock save_queue_state
            echo "Basic tests completed"
            ;;
        *)
            cat <<EOF
Usage: $0 <command> [arguments]

Core Commands:
  status                              Show basic queue status
  enhanced-status, estatus            Show enhanced status with colors (--json, --compact, --no-color)
  list [status] [sort]                List tasks (status: all|pending|active|completed|failed|timeout)
  add <type> <priority> [id] [meta]   Add single task to queue
  remove <task_id>                    Remove task from queue
  clear                               Clear entire queue
  
Queue Management:
  interactive, i                      Start interactive mode for real-time management
  next                                Get next task for processing
  stats                               Show detailed queue statistics
  cleanup                             Clean up old tasks and backups
  config                              Show current configuration
  
Batch Operations:
  batch add <stdin|file> [path] [type] [priority]
                                      Add multiple tasks from stdin or file
  batch remove <stdin|file> [path]   Remove multiple tasks by ID
  
GitHub Integration:
  github-issue <number> [priority]    Add GitHub issue task
  
Development:
  test                                Run basic functionality tests

Examples:
  # Basic usage
  $0 status
  $0 enhanced-status --json
  $0 list pending priority
  $0 add custom 1 "" description "Fix bug" command "/dev fix-bug"
  
  # Interactive mode
  $0 interactive
  
  # Batch operations
  echo -e "41\n42\n43" | $0 batch add stdin github_issue 2
  $0 batch add file tasks.txt custom 3
  
  # GitHub integration
  $0 github-issue 123 1
  
Enhanced Features:
  - Color-coded status displays
  - Interactive mode with real-time updates
  - Batch operations for bulk task management
  - JSON output support for scripting
  - Comprehensive help system
EOF
            ;;
    esac
fi