#!/usr/bin/env bash

# Claude Auto-Resume - Task Queue Locking Module  
# Simplified, focused locking with NO duplicates
# Version: 2.0.0-refactored

set -euo pipefail

# ===============================================================================
# LOCKING CONSTANTS
# ===============================================================================

QUEUE_LOCK_TIMEOUT="${QUEUE_LOCK_TIMEOUT:-30}"
QUEUE_LOCK_DIR="${TASK_QUEUE_DIR:-queue}/locks"
LOCK_RETRY_INTERVAL=1
MAX_LOCK_AGE=300  # 5 minutes

# ===============================================================================
# CORE LOCKING FUNCTIONS (NO DUPLICATES)
# ===============================================================================

# Initialize lock directory
ensure_lock_directory() {
    if [[ ! -d "$QUEUE_LOCK_DIR" ]]; then
        mkdir -p "$QUEUE_LOCK_DIR" 2>/dev/null || {
            log_error "Failed to create lock directory: $QUEUE_LOCK_DIR"
            return 1
        }
    fi
}

# Get lock file path for a resource
get_lock_file() {
    local resource="${1:-queue}"
    echo "$QUEUE_LOCK_DIR/${resource}.lock"
}

# Check if lock is stale (older than MAX_LOCK_AGE)
is_lock_stale() {
    local lock_file="$1"
    
    if [[ ! -f "$lock_file" ]]; then
        return 1  # No lock file, not stale
    fi
    
    local lock_age
    if command -v stat >/dev/null 2>&1; then
        # Try GNU stat first, then BSD stat
        if lock_age=$(stat -c %Y "$lock_file" 2>/dev/null); then
            : # GNU stat worked
        elif lock_age=$(stat -f %m "$lock_file" 2>/dev/null); then
            : # BSD stat worked  
        else
            log_warn "Cannot determine lock age for $lock_file"
            return 1
        fi
    else
        log_warn "stat command not available, cannot check lock age"
        return 1
    fi
    
    local current_time=$(date +%s)
    local age_seconds=$((current_time - lock_age))
    
    [[ $age_seconds -gt $MAX_LOCK_AGE ]]
}

# Clean up a single stale lock
cleanup_stale_lock() {
    local lock_file="$1"
    
    if is_lock_stale "$lock_file"; then
        log_info "Cleaning up stale lock: $lock_file"
        rm -f "$lock_file" 2>/dev/null || {
            log_warn "Failed to remove stale lock: $lock_file"
            return 1
        }
        return 0
    fi
    
    return 1  # Lock not stale
}

# Clean up all stale locks in the lock directory
cleanup_all_stale_locks() {
    ensure_lock_directory || return 1
    
    local cleaned=0
    
    for lock_file in "$QUEUE_LOCK_DIR"/*.lock; do
        if [[ -f "$lock_file" ]] && cleanup_stale_lock "$lock_file"; then
            ((cleaned++))
        fi
    done
    
    if [[ $cleaned -gt 0 ]]; then
        log_info "Cleaned up $cleaned stale locks"
    fi
    
    return 0
}

# Acquire lock atomically  
acquire_lock() {
    local resource="${1:-queue}"
    local timeout="${2:-$QUEUE_LOCK_TIMEOUT}"
    
    ensure_lock_directory || return 1
    
    local lock_file
    lock_file=$(get_lock_file "$resource")
    
    local end_time=$(($(date +%s) + timeout))
    local attempts=0
    
    while [[ $(date +%s) -lt $end_time ]]; do
        ((attempts++))
        
        # Try to create lock atomically
        if (
            set -C  # Enable noclobber
            echo "$$" > "$lock_file" 2>/dev/null
        ); then
            log_debug "Acquired lock for $resource (attempt $attempts)"
            return 0
        fi
        
        # Check if existing lock is stale
        if cleanup_stale_lock "$lock_file"; then
            log_info "Cleaned stale lock for $resource, retrying..."
            continue  # Try again immediately
        fi
        
        # Wait before retry
        sleep "$LOCK_RETRY_INTERVAL"
    done
    
    log_error "Failed to acquire lock for $resource after $attempts attempts (timeout: ${timeout}s)"
    return 1
}

# Release lock
release_lock() {
    local resource="${1:-queue}"
    
    local lock_file
    lock_file=$(get_lock_file "$resource")
    
    if [[ ! -f "$lock_file" ]]; then
        log_warn "Lock file does not exist: $lock_file"
        return 1
    fi
    
    # Verify we own this lock
    local lock_pid
    lock_pid=$(cat "$lock_file" 2>/dev/null || echo "")
    
    if [[ "$lock_pid" != "$$" ]]; then
        log_warn "Lock for $resource is owned by PID $lock_pid, not $$"
        return 1
    fi
    
    if rm "$lock_file" 2>/dev/null; then
        log_debug "Released lock for $resource"
        return 0
    else
        log_error "Failed to release lock for $resource"
        return 1
    fi
}

# Execute function with lock (dynamic pattern)
with_lock() {
    local resource="$1"
    local timeout="${2:-$QUEUE_LOCK_TIMEOUT}"
    shift 2
    local cmd=("$@")
    
    if acquire_lock "$resource" "$timeout"; then
        local exit_code=0
        
        # Execute command and capture exit code
        "${cmd[@]}" || exit_code=$?
        
        # Always try to release lock
        release_lock "$resource" || log_warn "Failed to release lock for $resource"
        
        return $exit_code
    else
        log_error "Could not acquire lock for $resource, skipping execution"
        return 1  
    fi
}

# Force cleanup of specific lock (emergency use)
force_cleanup_lock() {
    local resource="${1:-queue}"
    
    local lock_file
    lock_file=$(get_lock_file "$resource")
    
    if [[ -f "$lock_file" ]]; then
        log_warn "Force cleaning lock for $resource"
        rm -f "$lock_file" 2>/dev/null || {
            log_error "Failed to force cleanup lock: $lock_file"
            return 1
        }
        log_info "Force cleaned lock for $resource"
        return 0
    fi
    
    log_info "No lock to clean for $resource"
    return 0
}

# Get lock information
get_lock_info() {
    local resource="${1:-queue}"
    
    local lock_file
    lock_file=$(get_lock_file "$resource")
    
    if [[ ! -f "$lock_file" ]]; then
        echo "No lock exists for $resource"
        return 1
    fi
    
    local lock_pid
    lock_pid=$(cat "$lock_file" 2>/dev/null || echo "unknown")
    
    local lock_age="unknown"
    if command -v stat >/dev/null 2>&1; then
        if lock_age=$(stat -c %Y "$lock_file" 2>/dev/null); then
            lock_age=$(($(date +%s) - lock_age))
        elif lock_age=$(stat -f %m "$lock_file" 2>/dev/null); then
            lock_age=$(($(date +%s) - lock_age))
        fi
    fi
    
    echo "Lock for $resource: PID=$lock_pid, Age=${lock_age}s, File=$lock_file"
    
    # Check if stale
    if is_lock_stale "$lock_file"; then
        echo "  Status: STALE (older than ${MAX_LOCK_AGE}s)"
    else
        echo "  Status: ACTIVE"
    fi
    
    return 0
}

# List all current locks
list_all_locks() {
    ensure_lock_directory || return 1
    
    local found=0
    
    for lock_file in "$QUEUE_LOCK_DIR"/*.lock; do
        if [[ -f "$lock_file" ]]; then
            local resource
            resource=$(basename "$lock_file" .lock)
            get_lock_info "$resource"
            ((found++))
        fi
    done
    
    if [[ $found -eq 0 ]]; then
        echo "No active locks found"
    fi
    
    return 0
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