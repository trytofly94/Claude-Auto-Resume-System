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
# TASK_QUEUE_ENABLED will be loaded from config file - don't set a default here
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
# Use fallback syntax for better compatibility
if ! declare -p TASK_STATES >/dev/null 2>&1; then
    if ! declare -gA TASK_STATES 2>/dev/null; then
        # Fallback for older bash versions
        declare -A TASK_STATES
    fi
fi
if ! declare -p TASK_METADATA >/dev/null 2>&1; then
    if ! declare -gA TASK_METADATA 2>/dev/null; then
        declare -A TASK_METADATA
    fi
fi
if ! declare -p TASK_RETRY_COUNTS >/dev/null 2>&1; then
    if ! declare -gA TASK_RETRY_COUNTS 2>/dev/null; then
        declare -A TASK_RETRY_COUNTS
    fi
fi
if ! declare -p TASK_TIMESTAMPS >/dev/null 2>&1; then
    if ! declare -gA TASK_TIMESTAMPS 2>/dev/null; then
        declare -A TASK_TIMESTAMPS
    fi
fi
if ! declare -p TASK_PRIORITIES >/dev/null 2>&1; then
    if ! declare -gA TASK_PRIORITIES 2>/dev/null; then
        declare -A TASK_PRIORITIES
    fi
fi

# Task-Status-Konstanten
# Protect against re-sourcing - only declare readonly if not already set
if [[ -z "${TASK_STATE_PENDING:-}" ]]; then
    readonly TASK_STATE_PENDING="pending"
    readonly TASK_STATE_IN_PROGRESS="in_progress"
    readonly TASK_STATE_COMPLETED="completed"
    readonly TASK_STATE_FAILED="failed"
    readonly TASK_STATE_TIMEOUT="timeout"
fi

# Task-Typ-Konstanten
if [[ -z "${TASK_TYPE_GITHUB_ISSUE:-}" ]]; then
    readonly TASK_TYPE_GITHUB_ISSUE="github_issue"
    readonly TASK_TYPE_GITHUB_PR="github_pr"
    readonly TASK_TYPE_CUSTOM="custom"
fi

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
    
    # Using atomic directory-based locking (cross-platform reliable)
    # No flock dependency required
    
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
    local timestamp
    local random
    timestamp=$(date +%s)
    random=$(( RANDOM % 9999 ))
    
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
# ENHANCED ATOMIC LOCKING SYSTEM - Phase 1 Implementation
# ===============================================================================

# Comprehensive stale lock detection and cleanup
# ===============================================================================
# ENHANCED STALE LOCK DETECTION AND CLEANUP (Directory-Based System)
# ===============================================================================

# Enhanced stale lock cleanup with better timeout handling and graceful termination
cleanup_stale_lock() {
    local lock_dir="$1"
    
    # No lock directory = nothing to clean
    [[ -d "$lock_dir" ]] || return 0
    
    local pid_file="$lock_dir/pid"
    
    # No PID file = invalid lock, clean it up
    if [[ ! -f "$pid_file" ]]; then
        log_debug "Lock has no PID file - cleaning up"
        rm -rf "$lock_dir" 2>/dev/null
        return 0
    fi
    
    local lock_pid
    lock_pid=$(cat "$pid_file" 2>/dev/null || echo "")
    
    # Empty PID = invalid lock, clean it up  
    if [[ -z "$lock_pid" ]]; then
        log_debug "Lock has empty PID - cleaning up"
        rm -rf "$lock_dir" 2>/dev/null
        return 0
    fi
    
    # Check if process is still running
    if ! kill -0 "$lock_pid" 2>/dev/null; then
        log_debug "Lock process $lock_pid is dead - cleaning up"
        rm -rf "$lock_dir" 2>/dev/null
        return 0
    else
        log_debug "Lock process $lock_pid is alive - not cleaning up"
        return 1
    fi
}

# Enhanced aggressive stale lock cleanup with multi-criteria validation
cleanup_stale_lock_aggressive() {
    local lock_dir="$1"
    local force_cleanup="${2:-false}"
    
    [[ -d "$lock_dir" ]] || return 0
    
    local pid_file="$lock_dir/pid"
    local timestamp_file="$lock_dir/timestamp"
    local hostname_file="$lock_dir/hostname"
    
    # Pass 1: Standard validation
    local lock_pid
    lock_pid=$(cat "$pid_file" 2>/dev/null || echo "")
    local lock_timestamp
    lock_timestamp=$(cat "$timestamp_file" 2>/dev/null || echo "")
    local lock_hostname
    lock_hostname=$(cat "$hostname_file" 2>/dev/null || echo "")
    local should_cleanup=false
    local cleanup_reason=""
    
    # Criteria 1: Dead process check
    if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
        log_info "Stale lock detected: Process $lock_pid is dead"
        should_cleanup=true
        cleanup_reason="dead_process"
    fi
    
    # Criteria 2: Age-based cleanup (locks older than 10 minutes)
    if [[ -n "$lock_timestamp" ]]; then
        local current_time
        current_time=$(date +%s)
        local lock_time
        lock_time=$(date -d "$lock_timestamp" +%s 2>/dev/null || echo 0)
        local age
        age=$((current_time - lock_time))
        
        if [[ $age -gt 600 ]]; then  # 10 minutes
            log_info "Stale lock detected: Lock age ${age}s exceeds timeout"
            should_cleanup=true
            cleanup_reason="age_timeout"
        fi
    fi
    
    # Criteria 3: Different hostname (network filesystem safety)
    if [[ -n "$lock_hostname" && "$lock_hostname" != "$HOSTNAME" ]]; then
        log_debug "Cross-host lock detected: $lock_hostname vs $HOSTNAME"
        # Only cleanup if process is confirmed dead or very old
        if [[ "$should_cleanup" == "true" ]]; then
            cleanup_reason="${cleanup_reason}_cross_host"
        fi
    fi
    
    # Criteria 4: Force cleanup (emergency override)
    if [[ "$force_cleanup" == "true" ]]; then
        log_warn "Force cleanup requested for lock in $lock_dir"
        should_cleanup=true
        cleanup_reason="force_cleanup"
    fi
    
    # Execute cleanup with verification
    if [[ "$should_cleanup" == "true" ]]; then
        log_info "Removing stale lock: $lock_dir (reason: $cleanup_reason)"
        
        # Attempt removal with verification
        if rm -rf "$lock_dir" 2>/dev/null; then
            log_info "Successfully removed stale lock: $lock_dir"
            return 0
        else
            log_error "Failed to remove stale lock directory: $lock_dir"
            return 1
        fi
    else
        log_debug "Lock appears valid - not cleaning up: $lock_dir"
        return 1
    fi
}

# Clean up all stale locks in queue directory
cleanup_all_stale_locks() {
    local queue_dir="$PROJECT_ROOT/$TASK_QUEUE_DIR"
    local cleaned_count=0
    local total_count=0
    
    log_info "Scanning for stale locks in: $queue_dir"
    
    # Find all lock directories
    while IFS= read -r -d '' lock_dir; do
        ((total_count++))
        if cleanup_stale_lock "$lock_dir"; then
            ((cleaned_count++))
            log_debug "Cleaned stale lock: $(basename "$lock_dir")"
        fi
    done < <(find "$queue_dir" -name "*.lock.d" -type d -print0 2>/dev/null || true)
    
    if [[ $total_count -gt 0 ]]; then
        log_info "Stale lock cleanup: $cleaned_count/$total_count locks cleaned"
    else
        log_debug "No lock directories found for cleanup"
    fi
    
    return 0
}

# Validate lock directory integrity
validate_lock_integrity() {
    local lock_dir="$1"
    local pid_file="$lock_dir/pid"
    local timestamp_file="$lock_dir/timestamp"
    local hostname_file="$lock_dir/hostname"
    
    # Check if lock directory exists
    if [[ ! -d "$lock_dir" ]]; then
        log_debug "Lock directory does not exist: $lock_dir"
        return 1
    fi
    
    # Check if required files exist
    if [[ ! -f "$pid_file" ]]; then
        log_debug "Missing PID file: $pid_file"
        return 1
    fi
    
    # Validate PID file content
    local lock_pid
    lock_pid=$(cat "$pid_file" 2>/dev/null || echo "")
    if [[ ! "$lock_pid" =~ ^[0-9]+$ ]]; then
        log_debug "Invalid PID in lock file: $lock_pid"
        return 1
    fi
    
    # Check timestamp file if it exists
    if [[ -f "$timestamp_file" ]]; then
        local timestamp
        timestamp=$(cat "$timestamp_file" 2>/dev/null || echo "")
        if [[ -z "$timestamp" ]]; then
            log_debug "Empty timestamp file: $timestamp_file"
            return 1
        fi
    fi
    
    return 0
}

# Get detailed lock information for directory-based locks
get_lock_info() {
    local lock_dir="$1"
    local pid_file="$lock_dir/pid"
    local timestamp_file="$lock_dir/timestamp"
    local hostname_file="$lock_dir/hostname"
    local operation_file="$lock_dir/operation"
    local user_file="$lock_dir/user"
    
    if [[ ! -d "$lock_dir" ]]; then
        echo "No lock found"
        return 1
    fi
    
    local lock_pid
    local lock_timestamp
    local lock_hostname
    local lock_operation
    local lock_user
    lock_pid=$(cat "$pid_file" 2>/dev/null || echo "unknown")
    lock_timestamp=$(cat "$timestamp_file" 2>/dev/null || echo "unknown")
    lock_hostname=$(cat "$hostname_file" 2>/dev/null || echo "unknown")
    lock_operation=$(cat "$operation_file" 2>/dev/null || echo "unknown")
    lock_user=$(cat "$user_file" 2>/dev/null || echo "unknown")
    
    local age="unknown"
    if [[ "$lock_timestamp" != "unknown" ]]; then
        local current_time
        current_time=$(date +%s)
        local lock_time
        lock_time=$(date -d "$lock_timestamp" +%s 2>/dev/null || echo 0)
        if [[ $lock_time -gt 0 ]]; then
            age=$((current_time - lock_time))
        fi
    fi
    
    local status="unknown"
    if [[ "$lock_pid" != "unknown" ]]; then
        if kill -0 "$lock_pid" 2>/dev/null; then
            status="active"
        else
            status="stale"
        fi
    fi
    
    cat <<EOF
Lock Information:
  Directory: $(basename "$lock_dir")
  PID: $lock_pid
  Status: $status
  Operation: $lock_operation
  Age: ${age}s
  Hostname: $lock_hostname
  User: $lock_user
  Timestamp: $lock_timestamp
EOF
}

# Atomic directory-based lock acquisition
acquire_queue_lock_atomic() {
    local lock_dir="$PROJECT_ROOT/$TASK_QUEUE_DIR/.queue.lock.d"
    local attempts=0
    
    # Clean up any stale locks first
    cleanup_stale_lock "$lock_dir"
    
    # Multiple attempts with proper retry logic for atomic operations
    local max_attempts=10
    
    while [[ $attempts -lt $max_attempts ]]; do
        if mkdir "$lock_dir" 2>/dev/null; then
            # Successfully acquired lock - write metadata
            echo $$ > "$lock_dir/pid" 2>/dev/null || {
                rm -rf "$lock_dir" 2>/dev/null
                log_error "Failed to write PID to lock directory"
                return 1
            }
            
            date -Iseconds > "$lock_dir/timestamp" 2>/dev/null || {
                rm -rf "$lock_dir" 2>/dev/null
                log_error "Failed to write timestamp to lock directory"
                return 1
            }
            
            echo "$HOSTNAME" > "$lock_dir/hostname" 2>/dev/null || {
                rm -rf "$lock_dir" 2>/dev/null
                log_error "Failed to write hostname to lock directory"
                return 1
            }
            
            # Write additional metadata for enhanced cleanup
            echo "$USER" > "$lock_dir/user" 2>/dev/null || true
            echo "${1:-unknown}" > "$lock_dir/operation" 2>/dev/null || true
            echo "${CLI_MODE:-false}" > "$lock_dir/cli_mode" 2>/dev/null || true
            
            log_debug "Acquired atomic queue lock (pid: $$, attempt: $attempts, operation: ${1:-unknown})"
            return 0
        fi
        
        # Stale lock cleanup before retry
        if cleanup_stale_lock "$lock_dir"; then
            log_debug "Successfully cleaned up stale lock, retrying immediately"
            # Don't increment attempts counter for immediate retry after cleanup
            continue
        else
            log_debug "Stale lock cleanup failed or lock is still valid"
        fi
        
        # Exponential backoff with jitter
        local base_delay=0.1
        local delay=$(echo "$base_delay * (1.5 ^ $attempts)" | bc -l 2>/dev/null || echo "1")
        local jitter=$(echo "scale=3; $RANDOM / 32767 * 0.1" | bc -l 2>/dev/null || echo "0")
        local wait_time=$(echo "$delay + $jitter" | bc -l 2>/dev/null || echo "1")
        
        # Cap wait time at 2 seconds for CLI operations
        if [[ "${CLI_MODE:-false}" == "true" ]]; then
            wait_time=$(echo "if ($wait_time > 1.0) 1.0 else $wait_time" | bc -l 2>/dev/null || echo "1")
        fi
        
        log_debug "Lock attempt $((attempts + 1))/$max_attempts failed, waiting ${wait_time}s"
        sleep "$wait_time" 2>/dev/null || sleep 1
        
        ((attempts++))
    done
    
    # Final cleanup attempt before giving up
    cleanup_stale_lock "$lock_dir"
    
    log_error "Failed to acquire atomic queue lock after $max_attempts attempts"
    return 1
}

# Release atomic directory-based lock
release_queue_lock_atomic() {
    local lock_dir="$PROJECT_ROOT/$TASK_QUEUE_DIR/.queue.lock.d"
    
    if [[ -d "$lock_dir" ]]; then
        local lock_pid=$(cat "$lock_dir/pid" 2>/dev/null || echo "")
        
        if [[ "$lock_pid" == "$$" ]]; then
            rm -rf "$lock_dir" 2>/dev/null && {
                log_debug "Released atomic queue lock (pid: $$)"
                return 0
            } || {
                log_warn "Failed to remove atomic lock directory"
                return 1
            }
        else
            log_warn "Attempted to release lock not owned by this process (lock pid: $lock_pid, current pid: $$)"
            return 1
        fi
    else
        log_debug "No atomic lock directory to release"
        return 0
    fi
}

# Enhanced lock acquisition with aggressive recovery
acquire_queue_lock_with_aggressive_recovery() {
    local lock_dir="$PROJECT_ROOT/$TASK_QUEUE_DIR/.queue.lock.d"
    local operation="${1:-unknown}"
    local max_attempts=15  # Increased from 10
    local attempts=0
    
    log_debug "Starting aggressive lock acquisition for: $operation"
    
    while [[ $attempts -lt $max_attempts ]]; do
        # Phase 1: Standard acquisition attempt
        if mkdir "$lock_dir" 2>/dev/null; then
            # Success - write metadata
            echo $$ > "$lock_dir/pid" 2>/dev/null || {
                rm -rf "$lock_dir" 2>/dev/null
                log_error "Failed to write PID to lock directory"
                ((attempts++))
                continue
            }
            
            date -Iseconds > "$lock_dir/timestamp" 2>/dev/null || {
                rm -rf "$lock_dir" 2>/dev/null
                log_error "Failed to write timestamp to lock directory" 
                ((attempts++))
                continue
            }
            
            echo "$HOSTNAME" > "$lock_dir/hostname" 2>/dev/null || {
                rm -rf "$lock_dir" 2>/dev/null
                log_error "Failed to write hostname to lock directory"
                ((attempts++))
                continue
            }
            
            echo "$USER" > "$lock_dir/user" 2>/dev/null || true
            echo "$operation" > "$lock_dir/operation" 2>/dev/null || true
            echo "${CLI_MODE:-false}" > "$lock_dir/cli_mode" 2>/dev/null || true
            
            log_info "Acquired queue lock (pid: $$, attempt: $attempts, operation: $operation)"
            return 0
        fi
        
        # Phase 2: Standard stale lock cleanup
        if cleanup_stale_lock_aggressive "$lock_dir" false; then
            log_debug "Standard cleanup successful, retrying immediately"
            continue  # Retry immediately after successful cleanup
        fi
        
        # Phase 3: Escalated cleanup after multiple failures
        if [[ $attempts -ge 5 ]]; then
            log_warn "Multiple lock acquisition failures, attempting aggressive cleanup"
            if cleanup_stale_lock_aggressive "$lock_dir" false; then
                log_info "Aggressive cleanup successful, retrying"
                continue
            fi
        fi
        
        # Phase 4: Emergency force cleanup (last resort)
        if [[ $attempts -ge 12 ]]; then
            log_error "Emergency force cleanup - persistent lock blocking operations"
            if cleanup_stale_lock_aggressive "$lock_dir" true; then
                log_warn "Force cleanup successful - lock was likely stale"
                continue
            else
                log_error "Force cleanup failed - lock directory may have permission issues"
            fi
        fi
        
        # Exponential backoff with jitter
        local wait_time=$(echo "scale=2; 0.1 * (1.5 ^ $attempts) + ($RANDOM % 1000) / 10000" | bc -l 2>/dev/null || echo "1")
        wait_time=$(echo "if ($wait_time > 5.0) 5.0 else $wait_time" | bc -l 2>/dev/null || echo "2")
        
        log_debug "Lock attempt $((attempts + 1))/$max_attempts failed, waiting ${wait_time}s"
        sleep "$wait_time" 2>/dev/null || sleep 1
        
        ((attempts++))
    done
    
    # Final attempt with full diagnostic information
    log_error "Failed to acquire queue lock after $max_attempts aggressive attempts"
    show_lock_diagnostic_info "$lock_dir"
    return 1
}

# Show detailed lock diagnostic information
show_lock_diagnostic_info() {
    local lock_dir="$1"
    
    echo "=== LOCK DIAGNOSTIC INFORMATION ==="
    echo "Lock directory: $lock_dir"
    echo "Directory exists: $([[ -d "$lock_dir" ]] && echo "YES" || echo "NO")"
    
    if [[ -d "$lock_dir" ]]; then
        echo "Lock details:"
        get_lock_info "$lock_dir" | sed 's/^/  /'
        echo
        echo "Directory contents:"
        ls -la "$lock_dir" 2>/dev/null | sed 's/^/  /' || echo "  (Cannot list contents)"
        echo
        echo "Directory permissions:"
        ls -ld "$lock_dir" 2>/dev/null | sed 's/^/  /' || echo "  (Cannot check permissions)"
    fi
    
    echo "System information:"
    echo "  Current user: $USER"
    echo "  Current PID: $$"
    echo "  Hostname: $HOSTNAME"
    echo "  System load: $(uptime | awk -F'load average:' '{print $2}' | awk -F',' '{print $1}' | tr -d ' ')"
    echo "  Available disk space:"
    df -h "$PROJECT_ROOT" 2>/dev/null | tail -n 1 | sed 's/^/    /' || echo "    (Cannot check disk space)"
    echo "================================="
}

# Get lock information in a readable format
get_lock_info() {
    local lock_dir="$1"
    
    if [[ ! -d "$lock_dir" ]]; then
        echo "No lock directory found"
        return 1
    fi
    
    local lock_pid=$(cat "$lock_dir/pid" 2>/dev/null || echo "unknown")
    local lock_timestamp=$(cat "$lock_dir/timestamp" 2>/dev/null || echo "unknown")
    local lock_hostname=$(cat "$lock_dir/hostname" 2>/dev/null || echo "unknown")
    local lock_user=$(cat "$lock_dir/user" 2>/dev/null || echo "unknown")
    local lock_operation=$(cat "$lock_dir/operation" 2>/dev/null || echo "unknown")
    
    echo "PID: $lock_pid"
    if [[ "$lock_pid" != "unknown" ]]; then
        if kill -0 "$lock_pid" 2>/dev/null; then
            echo "Process Status: ✅ Running"
        else
            echo "Process Status: ❌ Dead (STALE LOCK)"
        fi
    fi
    echo "Timestamp: $lock_timestamp"
    echo "Hostname: $lock_hostname"
    echo "User: $lock_user"
    echo "Operation: $lock_operation"
    
    # Calculate lock age if we have a timestamp
    if [[ "$lock_timestamp" != "unknown" ]]; then
        local current_time
        current_time=$(date +%s)
        local lock_time
        lock_time=$(date -d "$lock_timestamp" +%s 2>/dev/null || echo 0)
        if [[ $lock_time -gt 0 ]]; then
            local age
        age=$((current_time - lock_time))
            echo "Lock Age: ${age} seconds"
            if [[ $age -gt 600 ]]; then
                echo "Age Status: ⚠️  Old lock (>10 minutes)"
            else
                echo "Age Status: ✅ Fresh lock"
            fi
        fi
    fi
}

# Emergency unlock command for manual intervention
force_unlock_queue_cmd() {
    local lock_dir="$PROJECT_ROOT/$TASK_QUEUE_DIR/.queue.lock.d"
    
    echo "🚨 EMERGENCY QUEUE UNLOCK"
    echo "Current lock status:"
    
    if [[ -d "$lock_dir" ]]; then
        get_lock_info "$lock_dir"
        echo
        echo "⚠️  WARNING: Force unlock will remove the lock regardless of validity"
        echo "   Only proceed if you're certain no other processes are using the queue"
        echo
        
        if [[ "${CLI_MODE:-false}" != "true" ]]; then
            read -p "Proceed with force unlock? (yes/NO): " confirm
            if [[ "$confirm" != "yes" ]]; then
                echo "Force unlock cancelled"
                return 1
            fi
        fi
        
        if cleanup_stale_lock_aggressive "$lock_dir" true; then
            echo "✅ Queue unlocked successfully"
            echo "📋 Testing queue functionality..."
            
            # Test queue operations
            if ./src/task-queue.sh status >/dev/null 2>&1; then
                echo "✅ Queue is now functional"
                return 0
            else
                echo "⚠️  Queue unlock succeeded but functionality test failed"
                return 1
            fi
        else
            echo "❌ Force unlock failed - check directory permissions"
            return 1
        fi
    else
        echo "No active locks found"
        return 0
    fi
}

# Handle lock acquisition failure with user-friendly error reporting
handle_lock_acquisition_failure() {
    local operation="$1"
    local attempts="$2"
    local lock_dir="$PROJECT_ROOT/$TASK_QUEUE_DIR/.queue.lock.d"
    
    echo "❌ QUEUE LOCK ACQUISITION FAILED"
    echo "   Operation: $operation"
    echo "   Attempts: $attempts"
    echo
    
    # Analyze failure reason
    if [[ -d "$lock_dir" ]]; then
        local lock_pid=$(cat "$lock_dir/pid" 2>/dev/null || echo "unknown")
        local lock_timestamp=$(cat "$lock_dir/timestamp" 2>/dev/null || echo "unknown")
        
        echo "🔒 ACTIVE LOCK DETECTED"
        echo "   Process ID: $lock_pid"
        echo "   Created: $lock_timestamp"
        
        if [[ "$lock_pid" != "unknown" ]]; then
            if kill -0 "$lock_pid" 2>/dev/null; then
                echo "   Status: ✅ Process is running"
                echo
                echo "📋 RECOMMENDED ACTIONS:"
                echo "   1. Wait for the running operation to complete"
                echo "   2. Check if process $lock_pid is stuck: ps -p $lock_pid -o pid,etime,comm"
                echo "   3. If stuck, terminate process: kill $lock_pid"
                echo "   4. If terminated, retry your operation immediately"
            else
                echo "   Status: ❌ Process is dead (STALE LOCK DETECTED)"
                echo
                echo "🚨 STALE LOCK RECOVERY:"
                echo "   The lock is held by a dead process. This should be cleaned up automatically."
                echo
                echo "📋 RECOMMENDED ACTIONS:"
                echo "   1. Retry your operation (stale locks are cleaned up automatically)"  
                echo "   2. If problem persists, run: ./src/task-queue.sh lock cleanup"
                echo "   3. For emergency unlock: ./src/task-queue.sh lock force-unlock"
            fi
        else
            echo "   Status: ❓ Invalid lock (no PID)"
            echo
            echo "📋 RECOMMENDED ACTIONS:"
            echo "   1. Run: ./src/task-queue.sh lock cleanup"
            echo "   2. Retry your operation"
        fi
    else
        echo "🚨 UNKNOWN LOCK FAILURE"
        echo "   No active lock detected, but acquisition failed"
        echo
        echo "📋 POSSIBLE CAUSES:"
        echo "   1. Permission issues with queue directory"
        echo "   2. Disk space exhaustion" 
        echo "   3. File system errors"
        echo "   4. High system load causing timeouts"
        echo
        echo "📋 RECOMMENDED ACTIONS:"
        echo "   1. Check disk space: df -h $PROJECT_ROOT"
        echo "   2. Check permissions: ls -ld $PROJECT_ROOT/$TASK_QUEUE_DIR"
        echo "   3. Check system load: uptime"
        echo "   4. Retry operation with higher timeout"
    fi
    
    echo
    echo "🔧 SUPPORT COMMANDS:"
    echo "   ./src/task-queue.sh lock status      - Show lock status"
    echo "   ./src/task-queue.sh lock health      - System health check"
    echo "   ./src/task-queue.sh lock cleanup     - Clean stale locks"
    echo "   ./src/task-queue.sh lock force-unlock - Emergency unlock"
}

# ===============================================================================
# FILE-LOCKING FÜR ATOMIC OPERATIONS - Updated to use Enhanced System
# ===============================================================================

# Acquire queue lock für sichere Operationen - always use atomic directory-based locking
acquire_queue_lock() {
    # Use enhanced aggressive recovery for better stale lock handling
    local result
    acquire_queue_lock_with_aggressive_recovery "$@"
    result=$?
    if [[ $result -ne 0 ]]; then
        log_debug "acquire_queue_lock_with_aggressive_recovery returned $result"
        # Provide user-friendly error reporting for CLI mode
        if [[ "${CLI_MODE:-false}" == "true" ]]; then
            handle_lock_acquisition_failure "${1:-unknown}" "15"
        fi
    else
        log_debug "acquire_queue_lock_with_aggressive_recovery succeeded"
    fi
    return $result
}

# Release queue lock - always use atomic directory-based locking
release_queue_lock() {
    # Always use atomic directory-based locking for better cross-platform reliability
    release_queue_lock_atomic "$@"
}

# Enhanced lock wrapper with monitoring and nested lock prevention
with_queue_lock_enhanced() {
    local operation="$1"
    shift
    local start_time=$(date +%s.%N 2>/dev/null || date +%s)
    local result=0
    
    # Check if we already hold a lock (prevent nested locking)
    if [[ "${QUEUE_LOCK_HELD:-false}" == "true" ]]; then
        log_debug "Lock already held - executing $operation directly"
        "$operation" "$@"
        return $?
    fi
    
    log_debug "Starting enhanced lock operation: $operation"
    
    export QUEUE_LOCK_HELD=true
    
    if acquire_queue_lock; then
        # Execute operation with monitoring
        local exec_start_time=$(date +%s.%N 2>/dev/null || date +%s)
        "$operation" "$@"
        result=$?
        local exec_end_time=$(date +%s.%N 2>/dev/null || date +%s)
        
        # Log performance metrics if bc is available
        if command -v bc >/dev/null 2>&1; then
            local exec_duration=$(echo "$exec_end_time - $exec_start_time" | bc 2>/dev/null || echo "N/A")
            log_debug "Operation $operation completed in ${exec_duration}s (exit code: $result)"
        else
            log_debug "Operation $operation completed (exit code: $result)"
        fi
        
        # Always release lock
        release_queue_lock
        
        if command -v bc >/dev/null 2>&1; then
            local total_duration=$(echo "$(date +%s.%N 2>/dev/null || date +%s) - $start_time" | bc 2>/dev/null || echo "N/A")
            log_debug "Total lock duration: ${total_duration}s"
        fi
        
        export QUEUE_LOCK_HELD=false
        return $result
    else
        log_error "Cannot execute operation without enhanced lock: $operation"
        export QUEUE_LOCK_HELD=false
        return 1
    fi
}

# Legacy wrapper - now redirects to enhanced version for better compatibility
with_queue_lock() {
    with_queue_lock_enhanced "$@"
}

# ===============================================================================
# SMART OPERATION ROUTING (Lock-Free Read Operations)
# ===============================================================================

# Check if an operation is read-only (doesn't modify state)
is_read_only_operation() {
    local op="$1"
    case "$op" in
        "list"|"status"|"enhanced-status"|"filter"|"find"|"export"|"config"|"stats"|"statistics"|"next"|"monitor")
            return 0  # Read-only operations
            ;;
        "show_queue_status"|"show_enhanced_status"|"list_queue_tasks"|"get_queue_statistics"|"get_next_task"|"advanced_list_tasks"|"export_queue_data"|"monitor_queue_cmd"|"show_current_config")
            return 0  # Internal read-only functions
            ;;
        *)
            return 1  # State-changing operations
            ;;
    esac
}

# Direct JSON operations for read-only commands (no locking required)
direct_json_operation() {
    local operation="$1"
    shift
    
    log_debug "Direct JSON operation: $operation"
    
    # Ensure directories exist
    ensure_queue_directories || return 1
    
    # Initialize arrays if needed (but don't force full init)
    if ! declare -p TASK_STATES >/dev/null 2>&1; then
        declare -gA TASK_STATES
        declare -gA TASK_METADATA  
        declare -gA TASK_RETRY_COUNTS
        declare -gA TASK_TIMESTAMPS
        declare -gA TASK_PRIORITIES
        log_debug "Initialized arrays for direct JSON operation"
    fi
    
    # Load state directly without locking
    load_queue_state || {
        log_error "Failed to load queue state for read operation"
        return 1
    }
    
    # Execute the read-only operation
    "$operation" "$@"
}

# Direct JSON-based task listing (optimized for read operations)
direct_json_list_tasks() {
    local filter="${1:-all}"
    local sort_order="${2:-priority}"
    local queue_file="$PROJECT_ROOT/$TASK_QUEUE_DIR/task-queue.json"
    
    if [[ ! -f "$queue_file" ]]; then
        echo "No tasks in queue"
        return 0
    fi
    
    # Use jq for efficient JSON filtering and sorting
    case "$filter" in
        "pending")
            jq -r '.tasks[] | select(.status == "pending") | [.id, .type, .priority, .title // .description // "No description"] | @tsv' "$queue_file" | sort -k3 -n
            ;;
        "active")
            jq -r '.tasks[] | select(.status == "active") | [.id, .type, .priority, .title // .description // "No description"] | @tsv' "$queue_file" | sort -k3 -n
            ;;
        "completed")
            jq -r '.tasks[] | select(.status == "completed") | [.id, .type, .priority, .title // .description // "No description"] | @tsv' "$queue_file" | sort -k3 -n
            ;;
        "failed")
            jq -r '.tasks[] | select(.status == "failed") | [.id, .type, .priority, .title // .description // "No description"] | @tsv' "$queue_file" | sort -k3 -n
            ;;
        *)
            jq -r '.tasks[] | [.id, .type, .status, .priority, .title // .description // "No description"] | @tsv' "$queue_file" | sort -k4 -n
            ;;
    esac
}

# Direct JSON status retrieval
direct_json_get_status() {
    local queue_file="$PROJECT_ROOT/$TASK_QUEUE_DIR/task-queue.json"
    
    if [[ ! -f "$queue_file" ]]; then
        echo '{"status": "empty", "total_tasks": 0, "pending": 0, "active": 0, "completed": 0, "failed": 0}'
        return 0
    fi
    
    # Use jq for efficient status calculation
    jq '{
        status: (if .tasks | length > 0 then "active" else "empty" end),
        total_tasks: (.tasks | length),
        pending: (.tasks | map(select(.status == "pending")) | length),
        active: (.tasks | map(select(.status == "active")) | length),  
        completed: (.tasks | map(select(.status == "completed")) | length),
        failed: (.tasks | map(select(.status == "failed")) | length),
        last_updated: .metadata.last_updated
    }' "$queue_file"
}

# Smart operation wrapper - routes operations based on read-only vs state-changing
smart_operation_wrapper() {
    local operation="$1"
    shift
    
    if is_read_only_operation "$operation"; then
        # Direct JSON access for read-only operations
        log_debug "Using lock-free path for read-only operation: $operation"
        direct_json_operation "$operation" "$@"
    else
        # Use robust locking for state-changing operations
        log_debug "Using locked path for state-changing operation: $operation"
        robust_lock_wrapper "$operation" "$@"
    fi
}

# ===============================================================================
# ROBUST LOCK ACQUISITION (Exponential Backoff & Operation-Specific Timeouts)
# ===============================================================================

# Get operation-specific timeout
get_operation_timeout() {
    local operation="$1"
    case "$operation" in
        "add_task_cmd"|"remove_task_cmd")         echo "10" ;;   # Quick operations  
        "batch_add"|"batch_remove"|"batch_operation_cmd") echo "30" ;; # Batch operations need more time
        "import_queue_data"|"clear_queue_cmd")    echo "60" ;;   # Heavy operations
        "interactive"|"start_interactive_mode")   echo "5" ;;    # Interactive needs fast response
        *)                                        echo "15" ;;   # Default timeout
    esac
}

# Acquire lock with exponential backoff retry logic
acquire_lock_with_backoff() {
    local operation="$1"
    local max_attempts=10
    local base_delay=0.1
    local max_delay=5.0
    local attempt=1
    local start_time=$(date +%s.%3N)
    
    # Get operation-specific timeout
    local operation_timeout
    operation_timeout=$(get_operation_timeout "$operation")
    
    # Override max_attempts based on timeout
    max_attempts=$(( operation_timeout > 10 ? operation_timeout / 2 : 5 ))
    
    log_debug "Attempting to acquire lock for $operation (timeout: ${operation_timeout}s, max_attempts: $max_attempts)"
    
    while [[ $attempt -le $max_attempts ]]; do
        export LOCK_BACKOFF_MODE=true
        if acquire_queue_lock; then
            export LOCK_BACKOFF_MODE=false
            local end_time=$(date +%s.%3N)
            local wait_time=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "0")
            log_debug "Lock acquired for $operation (attempt $attempt, wait: ${wait_time}s)"
            return 0
        fi
        export LOCK_BACKOFF_MODE=false
        
        # Calculate exponential backoff with jitter
        local delay
        if command -v bc >/dev/null 2>&1; then
            delay=$(echo "$base_delay * (2 ^ ($attempt - 1))" | bc -l 2>/dev/null)
            if (( $(echo "$delay > $max_delay" | bc -l 2>/dev/null) )); then
                delay=$max_delay
            fi
            
            # Add random jitter (±25%)
            local jitter_factor=$(echo "$RANDOM" | awk '{print $1/32767.0 * 0.5 + 0.75}')
            delay=$(echo "$delay * $jitter_factor" | bc -l 2>/dev/null)
        else
            # Fallback without bc: simple doubling with cap
            delay=$(( attempt < 5 ? attempt : 5 ))
        fi
        
        log_debug "Lock acquisition failed for $operation (attempt $attempt/$max_attempts), retrying in ${delay}s"
        
        # Use sleep with decimal if supported, fallback to integer
        if sleep "$delay" 2>/dev/null; then
            : # decimal sleep worked
        else
            sleep "${delay%.*}" # fallback to integer part
        fi
        
        ((attempt++))
    done
    
    local end_time=$(date +%s.%3N) 
    local total_wait=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "$operation_timeout")
    log_error "Failed to acquire lock for $operation after $max_attempts attempts (${total_wait}s)"
    export LOCK_BACKOFF_MODE=false
    return 1
}

# Note: The old duplicate acquire_queue_lock_atomic function has been removed
# The main atomic implementation is defined earlier at line 237

# Enhanced robust lock wrapper
robust_lock_wrapper() {
    local operation="$1"
    shift
    local result=0
    local start_time=$(date +%s.%3N)
    
    log_debug "Starting robust locked operation: $operation"
    
    if acquire_lock_with_backoff "$operation"; then
        local acquire_time=$(date +%s.%3N)
        local wait_time=$(echo "$acquire_time - $start_time" | bc -l 2>/dev/null || echo "0")
        
        # Execute operation with lock held
        "$operation" "$@"
        result=$?
        
        # Always release lock
        release_queue_lock
        
        local end_time=$(date +%s.%3N)
        local hold_time=$(echo "$end_time - $acquire_time" | bc -l 2>/dev/null || echo "0")
        
        log_debug "Completed robust locked operation: $operation (wait: ${wait_time}s, hold: ${hold_time}s, exit: $result)"
        return $result
    else
        local fail_time=$(date +%s.%3N)
        local wait_time=$(echo "$fail_time - $start_time" | bc -l 2>/dev/null || echo "0")
        
        log_error "Cannot execute operation without lock: $operation (waited: ${wait_time}s)"
        return 1
    fi
}

# ===============================================================================
# FINE-GRAINED LOCKING SYSTEM (Multiple Lock Types)
# ===============================================================================

# Define lock types for different operations
declare -A LOCK_TYPES=(
    ["read"]="queue/.read.lock.d"           # Read-only operations (may not be needed)
    ["write"]="queue/.write.lock.d"         # Single task modifications  
    ["batch"]="queue/.batch.lock.d"         # Batch operations
    ["config"]="queue/.config.lock.d"       # Configuration changes
    ["maintenance"]="queue/.maintenance.lock.d" # Cleanup/maintenance operations
)

# Get appropriate lock type for an operation
get_operation_lock_type() {
    local operation="$1"
    case "$operation" in
        "add_task_cmd"|"remove_task_cmd"|"update_status"|"update_priority"|"github_issue_cmd")   
            echo "write" ;;
        "batch_add"|"batch_remove"|"batch_operation_cmd"|"import_queue_data")                
            echo "batch" ;;
        "clear_queue_cmd"|"cleanup_cmd")                                  
            echo "maintenance" ;;
        "config_set"|"config_reset"|"show_current_config")                        
            echo "config" ;;
        *)                                                  
            echo "write" ;;  # Default to write lock
    esac
}

# Acquire typed lock for specific operation
acquire_typed_lock() {
    local operation="$1"
    local lock_type
    lock_type=$(get_operation_lock_type "$operation")
    local lock_dir="$PROJECT_ROOT/$TASK_QUEUE_DIR/${LOCK_TYPES[$lock_type]}"
    
    log_debug "Acquiring $lock_type lock for operation: $operation"
    
    # Ensure lock directory parent exists
    mkdir -p "$(dirname "$lock_dir")" 2>/dev/null || {
        log_error "Failed to create lock directory parent: $(dirname "$lock_dir")"
        return 1
    }
    
    # Use similar logic to acquire_queue_lock_atomic but with typed locks
    local attempts=0
    local max_attempts=$([[ "${CLI_MODE:-false}" == "true" ]] && echo 5 || echo "$QUEUE_LOCK_TIMEOUT")
    
    while [[ $attempts -lt $max_attempts ]]; do
        if mkdir "$lock_dir" 2>/dev/null; then
            # Successfully acquired typed lock - write metadata
            echo $$ > "$lock_dir/pid" 2>/dev/null || {
                rm -rf "$lock_dir" 2>/dev/null
                log_error "Failed to write PID to typed lock directory"
                return 1
            }
            
            date -Iseconds > "$lock_dir/timestamp" 2>/dev/null || {
                rm -rf "$lock_dir" 2>/dev/null
                log_error "Failed to write timestamp to typed lock directory"
                return 1
            }
            
            echo "$HOSTNAME" > "$lock_dir/hostname" 2>/dev/null || {
                rm -rf "$lock_dir" 2>/dev/null
                log_error "Failed to write hostname to typed lock directory"
                return 1
            }
            
            # Write additional metadata
            echo "$USER" > "$lock_dir/user" 2>/dev/null || true
            echo "$operation" > "$lock_dir/operation" 2>/dev/null || true
            echo "$lock_type" > "$lock_dir/lock_type" 2>/dev/null || true
            echo "${CLI_MODE:-false}" > "$lock_dir/cli_mode" 2>/dev/null || true
            
            log_debug "Acquired $lock_type lock (pid: $$, attempt: $attempts, operation: $operation)"
            return 0
        fi
        
        # Stale lock cleanup before retry
        cleanup_stale_lock "$lock_dir"
        
        # Exponential backoff with jitter (same as atomic lock)
        local base_delay=0.1
        local delay=$(echo "$base_delay * (1.5 ^ $attempts)" | bc -l 2>/dev/null || echo "1")
        local jitter=$(echo "scale=3; $RANDOM / 32767 * 0.1" | bc -l 2>/dev/null || echo "0")
        local wait_time=$(echo "$delay + $jitter" | bc -l 2>/dev/null || echo "1")
        
        # Cap wait time for CLI operations
        if [[ "${CLI_MODE:-false}" == "true" ]]; then
            wait_time=$(echo "if ($wait_time > 1.0) 1.0 else $wait_time" | bc -l 2>/dev/null || echo "1")
        fi
        
        log_debug "$lock_type lock attempt $((attempts + 1))/$max_attempts failed, waiting ${wait_time}s"
        sleep "$wait_time" 2>/dev/null || sleep 1
        
        ((attempts++))
    done
    
    log_error "Failed to acquire $lock_type lock after $max_attempts attempts: $operation"
    return 1
}

# Release typed lock
release_typed_lock() {
    local operation="$1"
    local lock_type
    lock_type=$(get_operation_lock_type "$operation")
    local lock_dir="$PROJECT_ROOT/$TASK_QUEUE_DIR/${LOCK_TYPES[$lock_type]}"
    
    if [[ -d "$lock_dir" ]]; then
        local lock_pid=$(cat "$lock_dir/pid" 2>/dev/null || echo "")
        
        if [[ "$lock_pid" == "$$" ]]; then
            rm -rf "$lock_dir" 2>/dev/null && {
                log_debug "Released $lock_type lock (pid: $$, operation: $operation)"
                return 0
            } || {
                log_warn "Failed to remove $lock_type lock directory"
                return 1
            }
        else
            log_warn "Attempted to release $lock_type lock not owned by this process (lock pid: $lock_pid, current pid: $$)"
            return 1
        fi
    else
        log_debug "No $lock_type lock directory to release"
        return 0
    fi
}

# Fine-grained lock wrapper for operations
with_typed_lock() {
    local operation="$1"
    shift
    local result=0
    local start_time=$(date +%s.%3N 2>/dev/null || date +%s)
    
    log_debug "Starting typed locked operation: $operation"
    
    if acquire_typed_lock "$operation"; then
        local acquire_time=$(date +%s.%3N 2>/dev/null || date +%s)
        local wait_time=$(echo "$acquire_time - $start_time" | bc -l 2>/dev/null || echo "0")
        
        # Execute operation with typed lock held
        "$operation" "$@"
        result=$?
        
        # Always release typed lock
        release_typed_lock "$operation"
        
        local end_time=$(date +%s.%3N 2>/dev/null || date +%s)
        local hold_time=$(echo "$end_time - $acquire_time" | bc -l 2>/dev/null || echo "0")
        
        log_debug "Completed typed locked operation: $operation (wait: ${wait_time}s, hold: ${hold_time}s, exit: $result)"
        return $result
    else
        local fail_time=$(date +%s.%3N 2>/dev/null || date +%s)
        local wait_time=$(echo "$fail_time - $start_time" | bc -l 2>/dev/null || echo "0")
        
        log_error "Cannot execute operation without typed lock: $operation (waited: ${wait_time}s)"
        return 1
    fi
}

# Check for lock conflicts (different lock types that might conflict)
check_lock_conflicts() {
    local requested_type="$1"
    local conflicting_types=()
    
    case "$requested_type" in
        "maintenance")
            # Maintenance conflicts with everything
            conflicting_types=("write" "batch" "config" "read")
            ;;
        "batch")
            # Batch operations conflict with write and maintenance
            conflicting_types=("write" "maintenance")
            ;;
        "write")
            # Write operations conflict with batch and maintenance
            conflicting_types=("batch" "maintenance")
            ;;
        "config")
            # Config changes conflict with maintenance
            conflicting_types=("maintenance")
            ;;
        *)
            # Default: no conflicts (read operations)
            conflicting_types=()
            ;;
    esac
    
    # Check if any conflicting locks exist
    for conflict_type in "${conflicting_types[@]}"; do
        local conflict_dir="$PROJECT_ROOT/$TASK_QUEUE_DIR/${LOCK_TYPES[$conflict_type]}"
        if [[ -d "$conflict_dir" ]]; then
            # Validate that the conflicting lock is still active
            if validate_lock_integrity "$conflict_dir"; then
                local conflict_pid=$(cat "$conflict_dir/pid" 2>/dev/null || echo "")
                if [[ -n "$conflict_pid" ]] && kill -0 "$conflict_pid" 2>/dev/null; then
                    log_debug "Lock conflict detected: $requested_type conflicts with active $conflict_type lock (PID: $conflict_pid)"
                    return 1  # Conflict exists
                fi
            fi
        fi
    done
    
    return 0  # No conflicts
}

# Show all active typed locks
show_typed_locks() {
    local queue_dir="$PROJECT_ROOT/$TASK_QUEUE_DIR/queue"
    local found_locks=false
    
    echo "=== Active Typed Locks ==="
    
    for lock_type in "${!LOCK_TYPES[@]}"; do
        local lock_dir="$queue_dir/${LOCK_TYPES[$lock_type]#queue/}"
        if [[ -d "$lock_dir" ]]; then
            found_locks=true
            echo "[$lock_type]"
            get_lock_info "$lock_dir" | sed 's/^/  /'
            echo
        fi
    done
    
    if [[ "$found_locks" == "false" ]]; then
        echo "No active typed locks found"
    fi
}

# Clean up all typed locks
cleanup_all_typed_locks() {
    local queue_dir="$PROJECT_ROOT/$TASK_QUEUE_DIR/queue"
    local cleaned_count=0
    local total_count=0
    
    log_info "Scanning for stale typed locks in: $queue_dir"
    
    for lock_type in "${!LOCK_TYPES[@]}"; do
        local lock_dir="$queue_dir/${LOCK_TYPES[$lock_type]#queue/}"
        if [[ -d "$lock_dir" ]]; then
            ((total_count++))
            if cleanup_stale_lock "$lock_dir"; then
                ((cleaned_count++))
                log_debug "Cleaned stale $lock_type lock"
            fi
        fi
    done
    
    if [[ $total_count -gt 0 ]]; then
        log_info "Stale typed lock cleanup: $cleaned_count/$total_count locks cleaned"
    else
        log_debug "No typed lock directories found for cleanup"
    fi
    
    return 0
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
    
    # Create backup of existing file (skip in performance mode)
    if [[ -f "$queue_file" && "${SKIP_BACKUP_CREATION:-false}" != "true" ]]; then
        if cp "$queue_file" "$backup_file"; then
            log_debug "Created backup: $backup_file"
        else
            log_error "Failed to create backup before save"
            return 1
        fi
    fi
    
    # Write to temp file first
    if generate_queue_json > "$temp_file"; then
        # Validate JSON before replacing original (skip in performance mode)
        if [[ "${DISABLE_JSON_VALIDATION:-false}" == "true" ]] || jq empty "$temp_file" 2>/dev/null; then
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
    
    # Ensure arrays are initialized BEFORE any checks - caller should have loaded queue state
    log_debug "About to check if TASK_STATES is declared"
    if ! declare -p TASK_STATES >/dev/null 2>&1; then
        log_debug "TASK_STATES not declared, initializing arrays"
        declare -gA TASK_STATES
        declare -gA TASK_METADATA
        declare -gA TASK_RETRY_COUNTS
        declare -gA TASK_TIMESTAMPS
        declare -gA TASK_PRIORITIES
        log_debug "Initialized arrays in add_task_to_queue"
    else
        log_debug "TASK_STATES already declared"
    fi
    log_debug "Arrays are available"
    
    # Load BATS state if in test environment
    if [[ "${BATS_TEST_NAME:-}" != "" ]] && command -v load_bats_state >/dev/null 2>&1; then
        load_bats_state
        log_debug "Loaded BATS state before checks"
    fi
    
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
        # BATS environment - use BATS compatibility system for duplicate detection
        if command -v bats_safe_array_operation >/dev/null 2>&1; then
            # Check in memory array (should be loaded from BATS state)
            if [[ -n "${TASK_STATES[$task_id]:-}" ]]; then
                task_exists=true
            fi
        else
            # Fallback to simple file tracking
            local bats_state_file="${TEST_PROJECT_DIR:-/tmp}/queue/bats_task_states.txt"
            if [[ -f "$bats_state_file" ]] && grep -q "^$task_id$" "$bats_state_file" 2>/dev/null; then
                task_exists=true
            fi
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
        # BATS environment - use BATS compatibility system for size counting
        if command -v bats_safe_array_operation >/dev/null 2>&1; then
            # Count from memory array (should be loaded from BATS state)
            current_size=0
            if declare -p TASK_STATES >/dev/null 2>&1; then
                # Use eval to safely access array length
                current_size=$(eval "echo \${#TASK_STATES[@]}" 2>/dev/null) || current_size=0
            fi
        else
            # Fallback to simple file tracking
            local bats_state_file="${TEST_PROJECT_DIR:-/tmp}/queue/bats_task_states.txt"
            if [[ -f "$bats_state_file" ]]; then
                current_size=$(wc -l < "$bats_state_file" 2>/dev/null || echo "0")
            fi
        fi
    else
        # Normal environment - use array
        current_size=0
        if declare -p TASK_STATES >/dev/null 2>&1; then
            # Use eval to safely access array length
            current_size=$(eval "echo \${#TASK_STATES[@]}" 2>/dev/null) || current_size=0
        fi
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
    
    # In BATS test environment - use enhanced BATS compatibility tracking
    if [[ "${BATS_TEST_NAME:-}" != "" ]]; then
        # Use BATS compatibility system for persistent state tracking
        if command -v save_bats_state >/dev/null 2>&1; then
            save_bats_state
            log_debug "Saved task state via BATS compatibility system: $task_id"
        else
            # Fallback to simple file tracking
            local bats_state_file="${TEST_PROJECT_DIR:-/tmp}/queue/bats_task_states.txt"
            mkdir -p "$(dirname "$bats_state_file")"
            echo "$task_id" >> "$bats_state_file"
            log_debug "Added task to BATS file-based tracking: $task_id"
        fi
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
    
    # Save queue state to persist the new task (skip in performance mode)
    if [[ "${TASK_QUEUE_PERFORMANCE_MODE:-false}" != "true" ]]; then
        save_queue_state || {
            log_warn "Failed to save queue state after adding task $task_id"
        }
    fi
    
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
    
    # In BATS test environment - update BATS compatibility tracking  
    if [[ "${BATS_TEST_NAME:-}" != "" ]]; then
        if command -v save_bats_state >/dev/null 2>&1; then
            save_bats_state
            log_debug "Updated BATS state after task removal: $task_id"
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
        echo "No tasks found"
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
    # Check if TASK_STATES has elements for listing (safe array access)
    if declare -p TASK_STATES >/dev/null 2>&1; then
        # Safe way to check array size for potentially uninitialized associative array
        if [[ "${TASK_STATES[*]:-}" ]]; then
            task_count=${#TASK_STATES[@]}
        fi
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
    
    # Load BATS state in test environment to ensure we have current data
    if [[ "${BATS_TEST_NAME:-}" != "" ]] && command -v load_bats_state >/dev/null 2>&1; then
        load_bats_state
    fi
    
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
        # Strip timezone info - handle both Z and +offset formats
        local created_clean=$(echo "$created" | sed 's/[Z+].*$//')
        created_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$created_clean" "+%s" 2>/dev/null || echo "0")
        
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
    
    # Get script directory for proper path resolution
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    # Use proper path resolution like hybrid-monitor.sh
    if [[ ! -f "$config_file" ]]; then
        config_file="$script_dir/../$config_file"
    fi
    
    log_info "Initializing task queue system"
    log_debug "Using config file: $config_file"
    
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
            
            # Remove surrounding quotes and trim whitespace
            value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^"\(.*\)"$/\1/;s/^\047\(.*\)\047$/\1/')
            
            case "$key" in
                TASK_QUEUE_ENABLED|TASK_QUEUE_DIR|TASK_DEFAULT_TIMEOUT|TASK_MAX_RETRIES|TASK_RETRY_DELAY|TASK_COMPLETION_PATTERN|TASK_QUEUE_MAX_SIZE|TASK_AUTO_CLEANUP_DAYS|TASK_BACKUP_RETENTION_DAYS|QUEUE_LOCK_TIMEOUT)
                    # Always set from config - config file should take precedence over defaults
                    eval "$key='$value'"
                    log_debug "Config loaded: $key='$value'"
                    ;;
            esac
        done < <(grep -E '^[^#]*=' "$config_file" || true)
        
        log_debug "Task queue configured from: $config_file"
    fi
    
    # Check if task queue is enabled
    if [[ "${TASK_QUEUE_ENABLED:-}" != "true" ]]; then
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
    if declare -p TASK_STATES >/dev/null 2>&1; then
        # Safe way to get array size for potentially uninitialized associative array
        if [[ "${TASK_STATES[*]:-}" ]]; then
            task_count=${#TASK_STATES[@]}
        fi
    fi
    log_info "Queue state: $task_count tasks loaded"
    
    return 0
}

# Read-only initialization without locking for CLI operations
init_task_queue_readonly() {
    local config_file="${1:-config/default.conf}"
    
    log_debug "Initializing task queue system (readonly mode)"
    
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
        
        log_debug "Task queue configured from: $config_file (readonly)"
    fi
    
    # Check if task queue is enabled
    if [[ "${TASK_QUEUE_ENABLED:-}" != "true" ]]; then
        log_debug "Task queue is disabled in configuration"
        return 1
    fi
    
    # Ensure directories exist
    ensure_queue_directories || {
        log_error "Failed to create queue directories"
        return 1
    }
    
    # Initialize arrays from JSON without acquiring locks
    if [[ -f "$PROJECT_ROOT/$TASK_QUEUE_DIR/task-queue.json" ]]; then
        load_queue_state_readonly
        return $?
    else
        # Initialize empty arrays
        declare -gA TASK_METADATA=()
        declare -gA TASK_STATES=()
        declare -ga TASK_QUEUE=()
        declare -gA TASK_RETRY_COUNTS=()
        declare -gA TASK_TIMESTAMPS=()
        declare -gA TASK_PRIORITIES=()
        log_debug "Initialized empty task arrays (readonly)"
        return 0
    fi
}

# Load queue state from JSON file without locking (read-only)
load_queue_state_readonly() {
    local queue_file="$PROJECT_ROOT/$TASK_QUEUE_DIR/task-queue.json"
    
    if [[ ! -f "$queue_file" ]]; then
        log_debug "No existing queue file found: $queue_file (readonly)"
        return 0
    fi
    
    log_debug "Loading queue state from: $queue_file (readonly)"
    
    # Validate JSON first
    if ! jq empty "$queue_file" 2>/dev/null; then
        log_error "Queue file contains invalid JSON: $queue_file"
        return 1
    fi
    
    # Initialize empty arrays
    declare -gA TASK_STATES=()
    declare -gA TASK_METADATA=()
    declare -ga TASK_QUEUE=()
    declare -gA TASK_RETRY_COUNTS=()
    declare -gA TASK_TIMESTAMPS=()
    declare -gA TASK_PRIORITIES=()
    
    # Load tasks from JSON
    while IFS=$'\t' read -r task_id status priority created metadata retry_count; do
        [[ -z "$task_id" ]] && continue
        
        TASK_STATES["$task_id"]="$status"
        TASK_PRIORITIES["$task_id"]="$priority"
        TASK_TIMESTAMPS["$task_id"]="$created"
        TASK_RETRY_COUNTS["$task_id"]="${retry_count:-0}"
        TASK_METADATA["$task_id"]="$metadata"
        TASK_QUEUE+=("$task_id")
        
    done < <(jq -r '.tasks[]? | [.id, .status, .priority, .created, (.metadata | tostring), (.retry_count // 0)] | @tsv' "$queue_file" 2>/dev/null)
    
    local task_count=${#TASK_STATES[@]}
    log_debug "Loaded $task_count tasks from queue (readonly)"
    
    return 0
}

# Task-Queue-Status anzeigen
show_queue_status() {
    if [[ "${TASK_QUEUE_ENABLED:-}" != "true" ]]; then
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

# Enhanced CLI operation wrapper with deadlock prevention
cli_operation_wrapper() {
    local operation="$1"
    shift
    
    # Check if we already hold a lock (prevent nested locking)
    if [[ "${QUEUE_LOCK_HELD:-false}" == "true" ]]; then
        log_debug "Lock already held - executing $operation directly"
        "$operation" "$@"
        return $?
    fi
    
    export CLI_MODE=true
    export QUEUE_LOCK_HELD=false
    
    # Initialize without locking (use read-only methods)
    init_task_queue_readonly || {
        log_error "Failed to initialize task queue for CLI operation"
        export CLI_MODE=false
        return 1
    }
    
    log_debug "CLI Operation: $operation with args: $*"
    
    # Execute with smart operation routing (lock-free for reads, robust locking for writes)
    local result
    smart_operation_wrapper "$operation" "$@"
    result=$?
    
    export CLI_MODE=false
    export QUEUE_LOCK_HELD=false
    return $result
}

# CLI Command Implementations (mit verbesserter Fehlerbehandlung)
# Wrapper that loads queue state before adding task
add_task_with_state_load() {
    # Load queue state first
    load_queue_state || {
        log_debug "Failed to load queue state, initializing empty state"
        declare -gA TASK_STATES
        declare -gA TASK_METADATA
        declare -gA TASK_RETRY_COUNTS
        declare -gA TASK_TIMESTAMPS
        declare -gA TASK_PRIORITIES
    }
    
    # Now add the task
    add_task_to_queue "$@"
}

add_task_cmd() {
    if [[ $# -ge 2 ]]; then
        local task_id
        # Note: This function is called within a locked context by cli_operation_wrapper
        # so we don't need with_queue_lock here
        task_id=$(add_task_with_state_load "$1" "$2" "${3:-}" "${@:4}")
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
    
    if [[ "${TASK_QUEUE_ENABLED:-}" != "true" ]]; then
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
# ADVANCED FILTERING AND QUERY SYSTEM
# ===============================================================================

# Advanced list command with filtering capabilities
advanced_list_tasks() {
    local filter_status=""
    local filter_priority=""
    local filter_type=""
    local filter_date_after=""
    local filter_date_before=""
    local filter_text=""
    local sort_by="priority"
    local output_format="text"
    local limit=""
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --status=*) filter_status="${1#*=}" ;;
            --priority=*) filter_priority="${1#*=}" ;;
            --type=*) filter_type="${1#*=}" ;;
            --created-after=*) filter_date_after="${1#*=}" ;;
            --created-before=*) filter_date_before="${1#*=}" ;;
            --search=*) filter_text="${1#*=}" ;;
            --sort=*) sort_by="${1#*=}" ;;
            --format=*) output_format="${1#*=}" ;;
            --limit=*) limit="${1#*=}" ;;
            --json) output_format="json" ;;
            --help)
                show_filter_help
                return 0
                ;;
            *) echo "Unknown filter option: $1" >&2; return 1 ;;
        esac
        shift
    done
    
    # Collect all task IDs that match filters
    local matching_tasks=()
    local task_id
    
    if ! declare -p TASK_STATES >/dev/null 2>&1; then
        if [[ "$output_format" == "json" ]]; then
            echo '{"tasks": [], "count": 0}'
        else
            echo "No tasks found"
        fi
        return 0
    fi
    
    for task_id in "${!TASK_STATES[@]}"; do
        # Apply filters
        if ! task_matches_filters "$task_id" "$filter_status" "$filter_priority" "$filter_type" "$filter_date_after" "$filter_date_before" "$filter_text"; then
            continue
        fi
        
        matching_tasks+=("$task_id")
    done
    
    # Sort tasks
    case "$sort_by" in
        "priority") sort_tasks_by_priority matching_tasks ;;
        "created") sort_tasks_by_date matching_tasks ;;
        "status") sort_tasks_by_status matching_tasks ;;
        *) log_warn "Unknown sort option: $sort_by, using priority" ;;
    esac
    
    # Apply limit
    if [[ -n "$limit" && "$limit" -gt 0 ]]; then
        local temp_array=()
        local i
        for ((i=0; i<limit && i<${#matching_tasks[@]}; i++)); do
            temp_array+=("${matching_tasks[$i]}")
        done
        matching_tasks=("${temp_array[@]}")
    fi
    
    # Output results
    if [[ "$output_format" == "json" ]]; then
        output_filtered_tasks_json matching_tasks
    else
        output_filtered_tasks_text matching_tasks
    fi
}

# Check if task matches all specified filters
task_matches_filters() {
    local task_id="$1"
    local filter_status="$2"
    local filter_priority="$3"
    local filter_type="$4"
    local filter_date_after="$5"
    local filter_date_before="$6"
    local filter_text="$7"
    
    # Status filter
    if [[ -n "$filter_status" ]]; then
        local current_status="${TASK_STATES[$task_id]:-}"
        if [[ "$filter_status" == *","* ]]; then
            # Multiple statuses
            local status_list="${filter_status//,/|}"
            if ! [[ "$current_status" =~ ^($status_list)$ ]]; then
                return 1
            fi
        else
            # Single status
            if [[ "$current_status" != "$filter_status" ]]; then
                return 1
            fi
        fi
    fi
    
    # Priority filter
    if [[ -n "$filter_priority" ]]; then
        local current_priority="${TASK_PRIORITIES[$task_id]:-5}"
        if [[ "$filter_priority" == *"-"* ]]; then
            # Range: "1-3"
            local min_priority="${filter_priority%-*}"
            local max_priority="${filter_priority#*-}"
            if [[ "$current_priority" -lt "$min_priority" ]] || [[ "$current_priority" -gt "$max_priority" ]]; then
                return 1
            fi
        else
            # Exact match
            if [[ "$current_priority" != "$filter_priority" ]]; then
                return 1
            fi
        fi
    fi
    
    # Type filter
    if [[ -n "$filter_type" ]]; then
        local current_metadata="${TASK_METADATA[$task_id]:-}"
        if ! echo "$current_metadata" | grep -q "\"type\":\"$filter_type\""; then
            return 1
        fi
    fi
    
    # Date filters (basic implementation - could be enhanced)
    if [[ -n "$filter_date_after" ]]; then
        local task_timestamp="${TASK_TIMESTAMPS[$task_id]:-0}"
        local filter_timestamp
        filter_timestamp=$(date -d "$filter_date_after" +%s 2>/dev/null) || filter_timestamp=0
        if [[ "$task_timestamp" -le "$filter_timestamp" ]]; then
            return 1
        fi
    fi
    
    if [[ -n "$filter_date_before" ]]; then
        local task_timestamp="${TASK_TIMESTAMPS[$task_id]:-0}"
        local filter_timestamp
        filter_timestamp=$(date -d "$filter_date_before" +%s 2>/dev/null) || filter_timestamp=999999999999
        if [[ "$task_timestamp" -ge "$filter_timestamp" ]]; then
            return 1
        fi
    fi
    
    # Text search filter
    if [[ -n "$filter_text" ]]; then
        local current_metadata="${TASK_METADATA[$task_id]:-}"
        if ! echo "$current_metadata" | grep -qi "$filter_text"; then
            return 1
        fi
    fi
    
    return 0
}

# Sort tasks by priority
sort_tasks_by_priority() {
    local -n task_array=$1
    local temp_file="/tmp/task_sort_$$"
    
    # Create sortable list
    local task_id
    for task_id in "${task_array[@]}"; do
        local priority="${TASK_PRIORITIES[$task_id]:-5}"
        printf "%02d %s\n" "$priority" "$task_id" >> "$temp_file"
    done
    
    # Sort and extract task IDs
    task_array=()
    while read -r priority task_id; do
        task_array+=("$task_id")
    done < <(sort -n "$temp_file")
    
    rm -f "$temp_file"
}

# Sort tasks by creation date
sort_tasks_by_date() {
    local -n task_array=$1
    local temp_file="/tmp/task_sort_$$"
    
    # Create sortable list
    local task_id
    for task_id in "${task_array[@]}"; do
        local timestamp="${TASK_TIMESTAMPS[$task_id]:-0}"
        printf "%s %s\n" "$timestamp" "$task_id" >> "$temp_file"
    done
    
    # Sort and extract task IDs (newest first)
    task_array=()
    while read -r timestamp task_id; do
        task_array+=("$task_id")
    done < <(sort -rn "$temp_file")
    
    rm -f "$temp_file"
}

# Sort tasks by status
sort_tasks_by_status() {
    local -n task_array=$1
    local temp_file="/tmp/task_sort_$$"
    
    # Create sortable list with status priority
    local task_id
    for task_id in "${task_array[@]}"; do
        local status="${TASK_STATES[$task_id]:-pending}"
        local sort_priority
        case "$status" in
            "$TASK_STATE_IN_PROGRESS") sort_priority="1" ;;
            "$TASK_STATE_PENDING") sort_priority="2" ;;
            "$TASK_STATE_FAILED"|"$TASK_STATE_TIMEOUT") sort_priority="3" ;;
            "$TASK_STATE_COMPLETED") sort_priority="4" ;;
            *) sort_priority="5" ;;
        esac
        printf "%s %s\n" "$sort_priority" "$task_id" >> "$temp_file"
    done
    
    # Sort and extract task IDs
    task_array=()
    while read -r sort_priority task_id; do
        task_array+=("$task_id")
    done < <(sort -n "$temp_file")
    
    rm -f "$temp_file"
}

# Output filtered tasks in JSON format
output_filtered_tasks_json() {
    local -n task_array=$1
    local task_count=${#task_array[@]}
    
    echo "{"
    echo "  \"count\": $task_count,"
    echo "  \"tasks\": ["
    
    local i
    for ((i=0; i<${#task_array[@]}; i++)); do
        local task_id="${task_array[$i]}"
        local status="${TASK_STATES[$task_id]:-unknown}"
        local priority="${TASK_PRIORITIES[$task_id]:-5}"
        local metadata="${TASK_METADATA[$task_id]:-{}}"
        local timestamp="${TASK_TIMESTAMPS[$task_id]:-0}"
        
        echo "    {"
        echo "      \"id\": \"$task_id\","
        echo "      \"status\": \"$status\","
        echo "      \"priority\": $priority,"
        echo "      \"timestamp\": $timestamp,"
        echo "      \"metadata\": $metadata"
        if [[ $i -lt $((${#task_array[@]} - 1)) ]]; then
            echo "    },"
        else
            echo "    }"
        fi
    done
    
    echo "  ]"
    echo "}"
}

# Output filtered tasks in text format
output_filtered_tasks_text() {
    local -n task_array=$1
    local task_count=${#task_array[@]}
    
    if [[ $task_count -eq 0 ]]; then
        echo "No tasks match the specified filters"
        return 0
    fi
    
    echo "=== Filtered Tasks ($task_count found) ==="
    echo ""
    
    local task_id
    for task_id in "${task_array[@]}"; do
        display_task_details "$task_id"
        echo ""
    done
}

# Display detailed task information
display_task_details() {
    local task_id="$1"
    local status="${TASK_STATES[$task_id]:-unknown}"
    local priority="${TASK_PRIORITIES[$task_id]:-5}"
    local metadata="${TASK_METADATA[$task_id]:-{}}"
    local timestamp="${TASK_TIMESTAMPS[$task_id]:-0}"
    
    # Color coding
    local status_color=""
    local reset_color=""
    if [[ -t 1 ]]; then
        case "$status" in
            "$TASK_STATE_PENDING") status_color='\033[0;33m' ;;
            "$TASK_STATE_IN_PROGRESS") status_color='\033[0;34m' ;;
            "$TASK_STATE_COMPLETED") status_color='\033[0;32m' ;;
            "$TASK_STATE_FAILED"|"$TASK_STATE_TIMEOUT") status_color='\033[0;31m' ;;
        esac
        reset_color='\033[0m'
    fi
    
    # Format timestamp
    local formatted_date=""
    if [[ "$timestamp" != "0" ]] && command -v date >/dev/null 2>&1; then
        formatted_date=$(date -d "@$timestamp" "+%Y-%m-%d %H:%M" 2>/dev/null) || formatted_date="$timestamp"
    else
        formatted_date="$timestamp"
    fi
    
    # Extract description from metadata
    local description=""
    if echo "$metadata" | jq -e '.description' >/dev/null 2>&1; then
        description=$(echo "$metadata" | jq -r '.description' 2>/dev/null) || description=""
    fi
    
    printf "ID: %s\n" "$task_id"
    printf "Status: ${status_color}%s${reset_color}\n" "$status"
    printf "Priority: %s\n" "$priority"
    printf "Created: %s\n" "$formatted_date"
    if [[ -n "$description" ]]; then
        printf "Description: %s\n" "$description"
    fi
}

# Show filter help
show_filter_help() {
    cat <<EOF
=== Advanced Task Filtering ===

Usage: filter [OPTIONS]

Filter Options:
  --status=STATUS          Filter by status (pending,in_progress,completed,failed,timeout)
                           Multiple: --status=pending,in_progress
  --priority=PRIORITY      Filter by priority (1-10) or range (1-3)
  --type=TYPE             Filter by task type (github_issue,custom,github_pr)
  --created-after=DATE    Filter tasks created after date (YYYY-MM-DD)
  --created-before=DATE   Filter tasks created before date (YYYY-MM-DD)
  --search=TEXT           Search in task descriptions and metadata

Sort Options:
  --sort=FIELD            Sort by: priority, created, status

Output Options:
  --format=FORMAT         Output format: text, json
  --json                  JSON output (shorthand)
  --limit=N               Limit results to N tasks

Examples:
  filter --status=pending --priority=1-3
  filter --type=github_issue --created-after=2025-08-01
  filter --search="bug fix" --sort=created --limit=5
  filter --status=pending,in_progress --json
EOF
}

# ===============================================================================
# EXPORT/IMPORT SYSTEM
# ===============================================================================

# Export queue data to file or stdout
export_queue_data() {
    local export_format="${1:-json}"
    local output_file="${2:-}"
    local filter_args=("${@:3}")
    
    case "$export_format" in
        "json")
            export_queue_json "$output_file" "${filter_args[@]}"
            ;;
        "csv")
            export_queue_csv "$output_file" "${filter_args[@]}"
            ;;
        *)
            echo "Error: Unsupported export format: $export_format" >&2
            echo "Supported formats: json, csv" >&2
            return 1
            ;;
    esac
}

# Export queue as JSON
export_queue_json() {
    local output_file="${1:-}"
    local filter_args=("${@:2}")
    
    # Generate export data
    local export_data
    export_data=$(generate_export_json "${filter_args[@]}")
    
    # Output to file or stdout
    if [[ -n "$output_file" ]]; then
        echo "$export_data" > "$output_file" || {
            echo "Error: Failed to write to $output_file" >&2
            return 1
        }
        echo "Queue exported to: $output_file"
    else
        echo "$export_data"
    fi
}

# Export queue as CSV
export_queue_csv() {
    local output_file="${1:-}"
    local filter_args=("${@:2}")
    
    # Generate CSV header
    local csv_data="ID,Status,Priority,Type,Created,Description"
    
    # Get filtered tasks if filters are specified
    local task_list=()
    if [[ ${#filter_args[@]} -gt 0 ]]; then
        # Apply filters (reuse filtering system)
        # This is a simplified version - in a full implementation,
        # we'd integrate with the filtering system properly
        local task_id
        for task_id in "${!TASK_STATES[@]}"; do
            task_list+=("$task_id")
        done
    else
        # All tasks
        local task_id
        for task_id in "${!TASK_STATES[@]}"; do
            task_list+=("$task_id")
        done
    fi
    
    # Generate CSV rows
    local task_id
    for task_id in "${task_list[@]}"; do
        local status="${TASK_STATES[$task_id]:-unknown}"
        local priority="${TASK_PRIORITIES[$task_id]:-5}"
        local metadata="${TASK_METADATA[$task_id]:-{}}"
        local timestamp="${TASK_TIMESTAMPS[$task_id]:-0}"
        
        # Extract type and description from metadata
        local task_type=""
        local description=""
        if echo "$metadata" | jq -e '.' >/dev/null 2>&1; then
            task_type=$(echo "$metadata" | jq -r '.type // "custom"' 2>/dev/null) || task_type="custom"
            description=$(echo "$metadata" | jq -r '.description // ""' 2>/dev/null) || description=""
        fi
        
        # Format timestamp
        local formatted_date=""
        if [[ "$timestamp" != "0" ]] && command -v date >/dev/null 2>&1; then
            formatted_date=$(date -d "@$timestamp" "+%Y-%m-%d %H:%M:%S" 2>/dev/null) || formatted_date="$timestamp"
        else
            formatted_date="$timestamp"
        fi
        
        # Escape CSV fields
        description="${description//\"/\"\"}"
        if [[ "$description" == *,* ]] || [[ "$description" == *\"* ]]; then
            description="\"$description\""
        fi
        
        csv_data+=$'\n'"$task_id,$status,$priority,$task_type,$formatted_date,$description"
    done
    
    # Output to file or stdout
    if [[ -n "$output_file" ]]; then
        echo "$csv_data" > "$output_file" || {
            echo "Error: Failed to write to $output_file" >&2
            return 1
        }
        echo "Queue exported to CSV: $output_file"
    else
        echo "$csv_data"
    fi
}

# Generate comprehensive JSON export
generate_export_json() {
    local filter_args=("$@")
    
    # Get export metadata
    local export_timestamp=$(date -Iseconds)
    local total_tasks=0
    local task_count_by_status='{}'
    
    if declare -p TASK_STATES >/dev/null 2>&1; then
        total_tasks=${#TASK_STATES[@]}
        
        # Count tasks by status
        local pending=0 active=0 completed=0 failed=0
        local task_id
        for task_id in "${!TASK_STATES[@]}"; do
            case "${TASK_STATES[$task_id]}" in
                "$TASK_STATE_PENDING") ((pending++)) ;;
                "$TASK_STATE_IN_PROGRESS") ((active++)) ;;
                "$TASK_STATE_COMPLETED") ((completed++)) ;;
                "$TASK_STATE_FAILED"|"$TASK_STATE_TIMEOUT") ((failed++)) ;;
            esac
        done
        
        task_count_by_status=$(cat <<EOF
{
  "pending": $pending,
  "in_progress": $active,
  "completed": $completed,
  "failed": $failed
}
EOF
        )
    fi
    
    # Generate export JSON
    cat <<EOF
{
  "export_metadata": {
    "version": "1.0",
    "timestamp": "$export_timestamp",
    "total_tasks": $total_tasks,
    "task_counts": $task_count_by_status,
    "source_system": "claude-auto-resume-task-queue"
  },
  "configuration": {
    "TASK_QUEUE_ENABLED": "$TASK_QUEUE_ENABLED",
    "TASK_DEFAULT_TIMEOUT": $TASK_DEFAULT_TIMEOUT,
    "TASK_MAX_RETRIES": $TASK_MAX_RETRIES,
    "TASK_QUEUE_MAX_SIZE": $TASK_QUEUE_MAX_SIZE
  },
  "tasks": [
$(generate_tasks_json_array)
  ]
}
EOF
}

# Generate JSON array for all tasks
generate_tasks_json_array() {
    local task_list=()
    local task_id
    
    # Collect all task IDs
    if declare -p TASK_STATES >/dev/null 2>&1; then
        for task_id in "${!TASK_STATES[@]}"; do
            task_list+=("$task_id")
        done
    fi
    
    # Generate JSON for each task
    local i
    for ((i=0; i<${#task_list[@]}; i++)); do
        task_id="${task_list[$i]}"
        local status="${TASK_STATES[$task_id]:-unknown}"
        local priority="${TASK_PRIORITIES[$task_id]:-5}"
        local metadata="${TASK_METADATA[$task_id]:-{}}"
        local timestamp="${TASK_TIMESTAMPS[$task_id]:-0}"
        local retry_count="${TASK_RETRY_COUNTS[$task_id]:-0}"
        
        echo "    {"
        echo "      \"id\": \"$task_id\","
        echo "      \"status\": \"$status\","
        echo "      \"priority\": $priority,"
        echo "      \"timestamp\": $timestamp,"
        echo "      \"retry_count\": $retry_count,"
        echo "      \"metadata\": $metadata"
        if [[ $i -lt $((${#task_list[@]} - 1)) ]]; then
            echo "    },"
        else
            echo "    }"
        fi
    done
}

# Import queue data from file
import_queue_data() {
    local import_file="$1"
    local import_mode="${2:-merge}" # merge, replace, validate
    
    if [[ ! -f "$import_file" ]]; then
        echo "Error: Import file not found: $import_file" >&2
        return 1
    fi
    
    # Validate JSON first
    if ! jq empty "$import_file" 2>/dev/null; then
        echo "Error: Import file contains invalid JSON: $import_file" >&2
        return 1
    fi
    
    case "$import_mode" in
        "validate")
            validate_import_file "$import_file"
            ;;
        "replace")
            import_with_replace "$import_file"
            ;;
        "merge")
            import_with_merge "$import_file"
            ;;
        *)
            echo "Error: Invalid import mode: $import_mode" >&2
            echo "Supported modes: validate, merge, replace" >&2
            return 1
            ;;
    esac
}

# Validate import file structure
validate_import_file() {
    local import_file="$1"
    
    echo "Validating import file: $import_file"
    
    # Check required structure
    local required_fields=("export_metadata" "tasks")
    local field
    for field in "${required_fields[@]}"; do
        if ! jq -e ".$field" "$import_file" >/dev/null 2>&1; then
            echo "✗ Missing required field: $field"
            return 1
        fi
    done
    
    # Validate tasks array
    local task_count
    task_count=$(jq -r '.tasks | length' "$import_file" 2>/dev/null) || task_count=0
    echo "✓ Found $task_count tasks in import file"
    
    # Check task structure
    if [[ $task_count -gt 0 ]]; then
        local first_task_valid
        first_task_valid=$(jq -e '.tasks[0] | has("id") and has("status") and has("priority")' "$import_file" 2>/dev/null)
        if [[ "$first_task_valid" == "true" ]]; then
            echo "✓ Task structure appears valid"
        else
            echo "✗ Invalid task structure detected"
            return 1
        fi
    fi
    
    # Check export metadata
    local export_version
    export_version=$(jq -r '.export_metadata.version' "$import_file" 2>/dev/null)
    echo "✓ Export version: $export_version"
    
    local export_timestamp
    export_timestamp=$(jq -r '.export_metadata.timestamp' "$import_file" 2>/dev/null)
    echo "✓ Export timestamp: $export_timestamp"
    
    echo "Import file validation completed successfully"
    return 0
}

# Import with merge mode (add new, update existing)
import_with_merge() {
    local import_file="$1"
    
    echo "Importing queue data (merge mode) from: $import_file"
    
    # Validate first
    if ! validate_import_file "$import_file"; then
        echo "Import aborted due to validation errors"
        return 1
    fi
    
    # Create backup before import
    local backup_file="$PROJECT_ROOT/$TASK_QUEUE_DIR/backups/pre-import-$(date +%Y%m%d-%H%M%S).json"
    if ! with_queue_lock save_queue_state; then
        echo "Warning: Could not create backup before import"
    else
        cp "$PROJECT_ROOT/$TASK_QUEUE_DIR/task-queue.json" "$backup_file" 2>/dev/null || true
        echo "Backup created: $backup_file"
    fi
    
    # Import tasks
    local imported_count=0
    local updated_count=0
    local error_count=0
    
    # Process each task from import file
    while read -r task_json; do
        local task_id priority status metadata timestamp retry_count
        
        task_id=$(echo "$task_json" | jq -r '.id' 2>/dev/null) || continue
        priority=$(echo "$task_json" | jq -r '.priority // 5' 2>/dev/null) || priority=5
        status=$(echo "$task_json" | jq -r '.status' 2>/dev/null) || status="pending"
        metadata=$(echo "$task_json" | jq -c '.metadata // {}' 2>/dev/null) || metadata="{}"
        timestamp=$(echo "$task_json" | jq -r '.timestamp // 0' 2>/dev/null) || timestamp=0
        retry_count=$(echo "$task_json" | jq -r '.retry_count // 0' 2>/dev/null) || retry_count=0
        
        # Check if task exists
        if [[ -n "${TASK_STATES[$task_id]:-}" ]]; then
            # Update existing task
            TASK_STATES[$task_id]="$status"
            TASK_PRIORITIES[$task_id]="$priority"
            TASK_METADATA[$task_id]="$metadata"
            TASK_TIMESTAMPS[$task_id]="$timestamp"
            TASK_RETRY_COUNTS[$task_id]="$retry_count"
            ((updated_count++))
            echo "Updated task: $task_id"
        else
            # Add new task
            TASK_STATES[$task_id]="$status"
            TASK_PRIORITIES[$task_id]="$priority"
            TASK_METADATA[$task_id]="$metadata"
            TASK_TIMESTAMPS[$task_id]="$timestamp"
            TASK_RETRY_COUNTS[$task_id]="$retry_count"
            ((imported_count++))
            echo "Imported task: $task_id"
        fi
    done < <(jq -c '.tasks[]' "$import_file" 2>/dev/null)
    
    # Save updated state
    if with_queue_lock save_queue_state; then
        echo ""
        echo "=== Import Summary ==="
        echo "New tasks imported: $imported_count"
        echo "Existing tasks updated: $updated_count"
        echo "Errors: $error_count"
        echo "Import completed successfully"
    else
        echo "Error: Failed to save queue state after import"
        return 1
    fi
}

# Import with replace mode (clear existing, import new)
import_with_replace() {
    local import_file="$1"
    
    echo "Importing queue data (replace mode) from: $import_file"
    echo "WARNING: This will replace ALL existing tasks!"
    
    # Validate first
    if ! validate_import_file "$import_file"; then
        echo "Import aborted due to validation errors"
        return 1
    fi
    
    # Create backup before replace
    local backup_file="$PROJECT_ROOT/$TASK_QUEUE_DIR/backups/pre-replace-$(date +%Y%m%d-%H%M%S).json"
    if with_queue_lock save_queue_state; then
        cp "$PROJECT_ROOT/$TASK_QUEUE_DIR/task-queue.json" "$backup_file" 2>/dev/null || true
        echo "Backup created: $backup_file"
    fi
    
    # Clear existing tasks
    if with_queue_lock clear_task_queue; then
        echo "Existing queue cleared"
    else
        echo "Error: Failed to clear existing queue"
        return 1
    fi
    
    # Import new tasks (reuse merge logic)
    import_with_merge "$import_file"
}

# ===============================================================================
# REAL-TIME MONITORING MODE
# ===============================================================================

# Real-time monitoring mode mit auto-refresh
start_monitor_mode() {
    local refresh_interval="${1:-5}"  # seconds
    local monitor_format="${2:-compact}"
    local show_help="${3:-true}"
    
    # Validate refresh interval
    if ! [[ "$refresh_interval" =~ ^[0-9]+$ ]] || [[ "$refresh_interval" -lt 1 ]]; then
        echo "Error: Invalid refresh interval. Must be a positive integer." >&2
        return 1
    fi
    
    if [[ "$show_help" == "true" ]]; then
        echo "=== Task Queue Real-time Monitor ==="
        echo "Refresh interval: ${refresh_interval}s"
        echo "Press 'q' and Enter to quit, 'r' and Enter to refresh now"
        echo ""
    fi
    
    # Set up signal handling for clean exit
    trap 'echo "Monitor stopped"; exit 0' INT TERM
    
    local last_update=$(date +%s)
    local cycle_count=0
    
    while true; do
        # Check for user input (non-blocking)
        local user_input=""
        if read -t 0.1 -r user_input 2>/dev/null; then
            case "$user_input" in
                "q"|"quit"|"exit") 
                    echo "Monitor stopped"
                    break 
                    ;;
                "r"|"refresh")
                    # Force immediate refresh
                    ;;
                "h"|"help")
                    show_monitor_help
                    continue
                    ;;
            esac
        fi
        
        # Clear screen for full display mode
        if [[ "$monitor_format" != "compact" ]]; then
            clear
        fi
        
        # Load fresh state
        load_queue_state >/dev/null 2>&1
        
        # Show timestamp
        local current_time=$(date '+%Y-%m-%d %H:%M:%S')
        if [[ "$monitor_format" == "compact" ]]; then
            printf "\r[%s] " "$current_time"
            show_enhanced_status "true" "compact"
        else
            echo "=== Task Queue Monitor - $current_time ==="
            echo "Update #$((++cycle_count)) (every ${refresh_interval}s)"
            echo ""
            show_enhanced_status "true" "text"
            
            # Show recent activity if available
            if [[ $(get_task_count) -gt 0 ]]; then
                echo ""
                echo "=== Recent Tasks (Last 3) ==="
                list_queue_tasks "all" "created" "3" 2>/dev/null || echo "No recent tasks available"
            fi
            
            echo ""
            echo "Commands: q=quit, r=refresh, h=help"
        fi
        
        # Wait for next refresh
        local elapsed=$(($(date +%s) - last_update))
        if [[ $elapsed -lt $refresh_interval ]]; then
            sleep $((refresh_interval - elapsed))
        fi
        last_update=$(date +%s)
    done
    
    # Clean up
    trap - INT TERM
}

# Get total task count helper
get_task_count() {
    if declare -p TASK_STATES >/dev/null 2>&1; then
        echo "${#TASK_STATES[@]}"
    else
        echo "0"
    fi
}

# Show monitor help
show_monitor_help() {
    cat <<EOF

=== Monitor Mode Help ===

Commands (type and press Enter):
  q, quit, exit    Stop monitoring and exit
  r, refresh       Force immediate refresh
  h, help          Show this help

Monitor shows:
- Real-time queue statistics with color coding
- Health status (healthy/warning/critical)
- Recent task activity
- Last update timestamp

The display updates automatically every ${refresh_interval:-5} seconds.
EOF
}

# Wrapper command for monitor mode
monitor_queue_cmd() {
    local refresh_interval="${1:-5}"
    local format="${2:-compact}"
    
    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --interval=*) refresh_interval="${1#*=}" ;;
            --format=*) format="${1#*=}" ;;
            --compact) format="compact" ;;
            --full) format="full" ;;
            --help) 
                echo "Usage: monitor [--interval=N] [--format=compact|full]"
                echo "  --interval=N    Refresh interval in seconds (default: 5)"
                echo "  --format=FORMAT Output format: compact (single line) or full (detailed)"
                return 0
                ;;
            *) 
                # Assume it's the refresh interval if it's a number
                if [[ "$1" =~ ^[0-9]+$ ]]; then
                    refresh_interval="$1"
                else
                    echo "Unknown monitor option: $1" >&2
                    return 1
                fi
                ;;
        esac
        shift
    done
    
    start_monitor_mode "$refresh_interval" "$format" "true"
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
# LOCK MANAGEMENT CLI COMMANDS
# ===============================================================================

# Show current lock status
show_lock_status_cmd() {
    echo "=== Task Queue Lock Status ==="
    
    # Show main queue lock
    local main_lock_dir="$PROJECT_ROOT/$TASK_QUEUE_DIR/.queue.lock.d"
    if [[ -d "$main_lock_dir" ]]; then
        echo "Main Queue Lock:"
        get_lock_info "$main_lock_dir" | sed 's/^/  /'
    else
        echo "Main Queue Lock: Not held"
    fi
    echo
    
    # Show typed locks
    show_typed_locks
    
    # Show any legacy file locks
    local legacy_lock_file="$PROJECT_ROOT/$TASK_QUEUE_DIR/.queue.lock"
    if [[ -f "$legacy_lock_file" ]]; then
        echo "Legacy file lock detected: $legacy_lock_file"
    fi
}

# Clean up stale locks
cleanup_locks_cmd() {
    echo "Cleaning up stale locks..."
    
    # Clean up main queue locks
    cleanup_all_stale_locks
    
    # Clean up typed locks 
    cleanup_all_typed_locks
    
    echo "Lock cleanup completed"
}

# Check lock system health
lock_health_check_cmd() {
    local health_score=100
    local issues=()
    
    # Check for stale main locks
    local main_lock_dir="$PROJECT_ROOT/$TASK_QUEUE_DIR/.queue.lock.d"
    if [[ -d "$main_lock_dir" ]]; then
        if ! validate_lock_integrity "$main_lock_dir"; then
            ((health_score -= 20))
            issues+=("Invalid main lock detected")
        fi
    fi
    
    # Check for stale typed locks
    for lock_type in "${!LOCK_TYPES[@]}"; do
        local lock_dir="$PROJECT_ROOT/$TASK_QUEUE_DIR/${LOCK_TYPES[$lock_type]}"
        if [[ -d "$lock_dir" ]]; then
            if ! validate_lock_integrity "$lock_dir"; then
                ((health_score -= 10))
                issues+=("Invalid $lock_type lock detected")
            fi
        fi
    done
    
    # Check system load impact
    if command -v uptime >/dev/null 2>&1; then
        local load_avg=$(uptime | awk '{print $(NF-2)}' | sed 's/,//')
        if (( $(echo "$load_avg > 2.0" | bc -l 2>/dev/null || echo "0") )); then
            ((health_score -= 15))
            issues+=("High system load may affect lock performance: $load_avg")
        fi
    fi
    
    echo "Lock system health: $health_score/100"
    
    if [[ ${#issues[@]} -gt 0 ]]; then
        echo "Issues detected:"
        for issue in "${issues[@]}"; do
            echo "  - $issue"
        done
        echo
        echo "Recommendations:"
        if [[ $health_score -lt 60 ]]; then
            echo "  - Run 'lock cleanup' to remove stale locks"
            echo "  - Consider restarting if issues persist"
        fi
        echo "  - Monitor system load: $(uptime)"
    else
        echo "No issues detected"
    fi
}

# ===============================================================================
# MAIN ENTRY POINT (für Testing und CLI)
# ===============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Load configuration first
    init_task_queue_readonly >/dev/null 2>&1 || true
    
    # Handle command line arguments with improved wrapper
    case "${1:-status}" in
        "status")
            # Read-only operation - skip heavy locking
            if [[ "${TASK_QUEUE_ENABLED:-}" != "true" ]]; then
                echo "Task Queue: DISABLED"
            else
                load_queue_state >/dev/null 2>&1 && show_queue_status || echo "Task Queue: ENABLED (no tasks loaded)"
            fi
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
            # Read-only operation - skip heavy locking
            if [[ "${TASK_QUEUE_ENABLED:-}" != "true" ]]; then
                if [[ "$format" == "json" ]]; then
                    echo '{"status": "disabled", "message": "Task Queue is disabled"}'
                else
                    echo "Task Queue: DISABLED"
                fi
            else
                load_queue_state >/dev/null 2>&1 && show_enhanced_status "$colors" "$format" || {
                    if [[ "$format" == "json" ]]; then
                        echo '{"status": "enabled", "message": "Queue enabled but no data loaded", "total_tasks": 0}'
                    else
                        echo "Task Queue: ENABLED (no tasks loaded)"
                    fi
                }
            fi
            ;;
        "list")
            # Read-only operation with minimal locking
            if [[ "${TASK_QUEUE_ENABLED:-}" != "true" ]]; then
                echo "Task Queue: DISABLED"
            else
                # Direct JSON read for list command to avoid locking issues
                QUEUE_FILE="$PROJECT_ROOT/$TASK_QUEUE_DIR/task-queue.json"
                if [[ -f "$QUEUE_FILE" ]] && jq empty "$QUEUE_FILE" 2>/dev/null; then
                    TASK_COUNT=$(jq -r '.total_tasks // 0' "$QUEUE_FILE" 2>/dev/null)
                    if [[ "$TASK_COUNT" == "0" ]]; then
                        echo "No tasks in queue"
                    else
                        echo "=== Task Queue (Direct Read) ==="
                        echo "Total tasks: $TASK_COUNT"
                        # Show task summary
                        jq -r '.tasks[]? | "[\(.id)] \(.metadata.type // "unknown") (priority: \(.priority)) - \(.status)"' "$QUEUE_FILE" 2>/dev/null || echo "Tasks exist but format parsing failed"
                    fi
                else
                    echo "No tasks to display (queue file not found or invalid)"
                fi
            fi
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
            # Read-only operation
            if [[ "${TASK_QUEUE_ENABLED:-}" != "true" ]]; then
                echo "Task Queue: DISABLED"
            else
                load_queue_state >/dev/null 2>&1 && get_queue_statistics || echo "No statistics available"
            fi
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
        "filter"|"find")
            shift
            init_task_queue && advanced_list_tasks "$@"
            ;;
        "export")
            shift
            init_task_queue && export_queue_data "$@"
            ;;
        "import")
            shift
            cli_operation_wrapper import_queue_data "$@"
            ;;
        "monitor")
            shift
            init_task_queue && monitor_queue_cmd "$@"
            ;;
        "lock")
            # Lock management commands
            case "${2:-status}" in
                "status")
                    show_lock_status_cmd
                    ;;
                "cleanup")
                    echo "Cleaning up stale locks with enhanced detection..."
                    cleanup_all_stale_locks
                    cleanup_all_typed_locks
                    echo "✅ Stale lock cleanup completed"
                    ;;
                "health")
                    lock_health_check_cmd
                    ;;
                "force-unlock"|"unlock")
                    force_unlock_queue_cmd
                    ;;
                "diagnostic"|"diag")
                    show_lock_diagnostic_info "$PROJECT_ROOT/$TASK_QUEUE_DIR/.queue.lock.d"
                    ;;
                "typed")
                    show_typed_locks
                    ;;
                "cleanup-typed")
                    cleanup_all_typed_locks
                    ;;
                *)
                    echo "Usage: $0 lock [status|cleanup|health|force-unlock|diagnostic|typed|cleanup-typed]"
                    echo "  status       - Show current lock status with detailed information"
                    echo "  cleanup      - Clean up stale locks (enhanced detection)"  
                    echo "  health       - Check lock system health"
                    echo "  force-unlock - Emergency unlock (removes any locks)"
                    echo "  diagnostic   - Show detailed diagnostic information"
                    echo "  typed        - Show typed locks"
                    echo "  cleanup-typed - Clean up all typed locks"
                    exit 1
                    ;;
            esac
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
  monitor [interval]                  Real-time monitoring with auto-refresh (default: 5s)
  next                                Get next task for processing
  stats                               Show detailed queue statistics
  cleanup                             Clean up old tasks and backups
  config                              Show current configuration
  
Batch Operations:
  batch add <stdin|file> [path] [type] [priority]
                                      Add multiple tasks from stdin or file
  batch remove <stdin|file> [path]   Remove multiple tasks by ID

Advanced Features:
  filter, find [OPTIONS]             Advanced task filtering and search
  export <format> [file] [filters]   Export queue data (json, csv)
  import <file> [mode]               Import queue data (validate, merge, replace)
  
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
  
  # Real-time monitoring
  $0 monitor 10          # Monitor with 10s refresh interval
  $0 monitor --format=full --interval=3
  
  # Batch operations
  echo -e "41\n42\n43" | $0 batch add stdin github_issue 2
  $0 batch add file tasks.txt custom 3
  
  # Advanced filtering
  $0 filter --status=pending --priority=1-3 --sort=created
  $0 find --type=github_issue --search="bug fix" --json
  
  # Export/Import
  $0 export json queue_backup.json
  $0 export csv queue_report.csv
  $0 import queue_backup.json merge
  
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