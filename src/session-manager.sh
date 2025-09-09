#!/usr/bin/env bash

# Claude Auto-Resume - Session Manager
# Session-Lifecycle-Management für das Claude Auto-Resume System
# Version: 1.0.0-alpha
# Letzte Aktualisierung: 2025-08-05

set -euo pipefail

# ===============================================================================
# GLOBALE VARIABLEN UND KONSTANTEN
# ===============================================================================

# Standard-Konfiguration (wird von config/default.conf überschrieben)
MAX_RESTARTS="${MAX_RESTARTS:-50}"
SESSION_RESTART_DELAY="${SESSION_RESTART_DELAY:-10}"
HEALTH_CHECK_ENABLED="${HEALTH_CHECK_ENABLED:-true}"
HEALTH_CHECK_INTERVAL="${HEALTH_CHECK_INTERVAL:-60}"
HEALTH_CHECK_TIMEOUT="${HEALTH_CHECK_TIMEOUT:-30}"
AUTO_RECOVERY_ENABLED="${AUTO_RECOVERY_ENABLED:-true}"
RECOVERY_DELAY="${RECOVERY_DELAY:-30}"
MAX_RECOVERY_ATTEMPTS="${MAX_RECOVERY_ATTEMPTS:-3}"

# Session-State-Tracking with Optimization Guards (Issue #115)
# Arrays will be initialized via init_session_arrays_once() when needed
# This prevents issues with sourcing contexts and scope problems
SESSION_ARRAYS_INITIALIZED="false"

# Module loading guards to prevent redundant sourcing (Issue #111)
SESSION_MANAGER_LOADED="${SESSION_MANAGER_LOADED:-false}"

# Per-Project Session Management (Issue #89)
# Additional associative arrays for project-aware session tracking
PROJECT_SESSIONS_INITIALIZED=false

# Maximum tracked sessions to prevent memory bloat (Issue #115)
MAX_TRACKED_SESSIONS="${MAX_TRACKED_SESSIONS:-100}"

# Project ID Cache for efficient lookups (Issue #115) 
declare -gA PROJECT_ID_CACHE 2>/dev/null || true
declare -gA PROJECT_CONTEXT_CACHE 2>/dev/null || true

# Additional performance optimization constants (Issue #115)
# Use safe conditional assignment to prevent readonly variable conflicts
if [[ -z "${DEFAULT_SESSION_CLEANUP_AGE:-}" ]]; then
    DEFAULT_SESSION_CLEANUP_AGE="1800"    # 30 minutes for stopped sessions
    export DEFAULT_SESSION_CLEANUP_AGE
fi

if [[ -z "${DEFAULT_ERROR_SESSION_CLEANUP_AGE:-}" ]]; then
    DEFAULT_ERROR_SESSION_CLEANUP_AGE="900"   # 15 minutes for error sessions
    export DEFAULT_ERROR_SESSION_CLEANUP_AGE
fi

if [[ -z "${BATCH_OPERATION_THRESHOLD:-}" ]]; then
    BATCH_OPERATION_THRESHOLD="10"     # Use batch operations when >=10 sessions
    export BATCH_OPERATION_THRESHOLD
fi

# Project context cache to avoid repeated computation (moved to global for consistency)
# declare -A PROJECT_CONTEXT_CACHE  # Moved to optimization section above

# Session-Status-Konstanten
# Protect against re-sourcing - only declare readonly if not already set
if [[ -z "${SESSION_STATE_UNKNOWN:-}" ]]; then
    readonly SESSION_STATE_UNKNOWN="unknown"
    readonly SESSION_STATE_STARTING="starting"
    readonly SESSION_STATE_RUNNING="running"
    readonly SESSION_STATE_USAGE_LIMITED="usage_limited"
    readonly SESSION_STATE_ERROR="error"
    readonly SESSION_STATE_STOPPED="stopped"
    readonly SESSION_STATE_RECOVERING="recovering"
fi

# ===============================================================================
# HILFSFUNKTIONEN UND DEPENDENCIES
# ===============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Lade Utility-Module
if [[ -f "$SCRIPT_DIR/utils/logging.sh" ]]; then
    source "$SCRIPT_DIR/utils/logging.sh"
else
    log_debug() { echo "[DEBUG] $*" >&2; }
    log_info() { echo "[INFO] $*" >&2; }
    log_warn() { echo "[WARN] $*" >&2; }
    log_error() { echo "[ERROR] $*" >&2; }
fi

if [[ -f "$SCRIPT_DIR/utils/network.sh" ]]; then
    source "$SCRIPT_DIR/utils/network.sh"
fi

if [[ -f "$SCRIPT_DIR/claunch-integration.sh" ]]; then
    source "$SCRIPT_DIR/claunch-integration.sh"
fi

# Prüfe ob Kommando verfügbar ist
has_command() {
    command -v "$1" >/dev/null 2>&1
}

# ===============================================================================
# PROJECT DETECTION AND UNIQUE NAMING (Issue #89)
# ===============================================================================

# Generate unique project identifier from working directory
# Uses sanitized directory components plus collision-resistant hash
generate_project_identifier() {
    local project_path="${1:-$(pwd)}"
    
    log_debug "Generating project identifier for: $project_path"
    
    # Validate that the project path exists
    if [[ ! -d "$project_path" && ! -f "$project_path" ]]; then
        log_warn "Project path does not exist: $project_path"
        # Continue anyway but warn - path might be created later
    fi
    
    # Resolve symlinks and get canonical path
    local resolved_path
    if resolved_path=$(realpath "$project_path" 2>/dev/null); then
        log_debug "Resolved path: $resolved_path"
    else
        # Fallback for systems without realpath
        resolved_path="$project_path"
        log_warn "realpath not available, using original path: $project_path"
    fi
    
    # Sanitize path components for session naming
    # Remove leading slash, replace remaining slashes with hyphens
    # Remove special characters, normalize multiple hyphens
    local sanitized
    sanitized=$(echo "$resolved_path" | sed 's|^/||; s|/|-|g; s/[^a-zA-Z0-9-]//g; s/--*/-/g')
    
    # Handle edge cases: empty sanitized name
    if [[ -z "$sanitized" ]]; then
        sanitized="root"
    fi
    
    # Truncate if too long (keep reasonable session name length)
    if [[ ${#sanitized} -gt 30 ]]; then
        sanitized="${sanitized:0:30}"
    fi
    
    # Generate collision-resistant hash from full resolved path
    local path_hash
    if command -v shasum >/dev/null 2>&1; then
        path_hash=$(echo "$resolved_path" | shasum -a 256 | cut -c1-6)
    elif command -v sha256sum >/dev/null 2>&1; then
        path_hash=$(echo "$resolved_path" | sha256sum | cut -c1-6)
    elif command -v md5sum >/dev/null 2>&1; then
        path_hash=$(echo "$resolved_path" | md5sum | cut -c1-6)
    else
        # Final fallback: use cksum (less ideal but universally available)
        path_hash=$(echo "$resolved_path" | cksum | cut -d' ' -f1 | cut -c1-6)
    fi
    
    # Combine sanitized name with hash for uniqueness
    local project_id="${sanitized}-${path_hash}"
    
    log_debug "Generated project identifier: $project_id"
    echo "$project_id"
}

# Efficient project context with caching (Issue #115)
get_project_id_cached() {
    local working_dir="${1:-$(pwd)}"
    local cache_key
    cache_key="cache_${working_dir//[\/]/_}"  # Safe cache key
    
    # Ensure cache is initialized
    if ! declare -p PROJECT_ID_CACHE >/dev/null 2>&1; then
        declare -gA PROJECT_ID_CACHE 2>/dev/null || true
    fi
    
    # Check cache first - most efficient path
    if [[ -n "${PROJECT_ID_CACHE[$cache_key]:-}" ]]; then
        echo "${PROJECT_ID_CACHE[$cache_key]}"
        return 0
    fi
    
    # Generate project ID and cache it
    local project_id
    project_id=$(generate_project_identifier "$working_dir")
    PROJECT_ID_CACHE["$cache_key"]="$project_id"
    
    log_debug "Cached project ID: $working_dir -> $project_id"
    echo "$project_id"
}

# Enhanced project context with efficient caching
get_current_project_context() {
    local working_dir="${1:-$(pwd)}"
    local MAX_CACHE_SIZE=100  # Maximum cache entries to prevent memory bloat
    
    # Ensure cache is initialized (safety guard)
    if ! declare -p PROJECT_CONTEXT_CACHE >/dev/null 2>&1; then
        declare -gA PROJECT_CONTEXT_CACHE 2>/dev/null || true
        log_debug "Initialized PROJECT_CONTEXT_CACHE in get_current_project_context"
    fi
    
    # Check cache first
    if [[ -n "${PROJECT_CONTEXT_CACHE[$working_dir]:-}" ]]; then
        log_debug "Using cached project context for: $working_dir"
        echo "${PROJECT_CONTEXT_CACHE[$working_dir]}"
        return 0
    fi
    
    # Check cache size and evict oldest entries if needed
    local cache_size=0
    set +u  # Temporarily disable nounset for array access
    if declare -p PROJECT_CONTEXT_CACHE >/dev/null 2>&1; then
        cache_size=${#PROJECT_CONTEXT_CACHE[@]}
    fi
    set -u  # Re-enable nounset
    
    if [[ $cache_size -ge $MAX_CACHE_SIZE ]]; then
        log_debug "Cache size limit reached ($cache_size >= $MAX_CACHE_SIZE), evicting oldest entries"
        # Clear half of the cache (simple eviction strategy)
        local count=0
        set +u  # Temporarily disable nounset for array iteration
        for key in "${!PROJECT_CONTEXT_CACHE[@]}"; do
            unset PROJECT_CONTEXT_CACHE["$key"]
            ((count++))
            if [[ $count -ge $((MAX_CACHE_SIZE / 2)) ]]; then
                break
            fi
        done
        set -u  # Re-enable nounset
        log_debug "Evicted $count cache entries"
    fi
    
    # Generate new project context
    local project_id
    project_id=$(generate_project_identifier "$working_dir")
    
    # Cache the result
    PROJECT_CONTEXT_CACHE["$working_dir"]="$project_id"
    
    log_debug "Cached project context: $working_dir -> $project_id (cache size: $((cache_size + 1)))"
    echo "$project_id"
}

# Generate project-aware session ID
generate_session_id() {
    local project_name="$1"
    local project_id="${2:-$(get_current_project_context)}"
    local timestamp=$(date +%s)
    
    # Create session ID that includes project context
    local session_id="sess-${project_id}-${timestamp}-$$"
    
    log_debug "Generated project-aware session ID: $session_id"
    echo "$session_id"
}

# Get session file path for project-specific session storage
get_session_file_path() {
    local project_id="${1:-$(get_current_project_context)}"
    
    # Project-specific session file pattern
    echo "$HOME/.claude_session_${project_id}"
}

# ===============================================================================
# ARRAY INITIALIZATION AND VALIDATION
# ===============================================================================

# Optimized array initialization with guards (Issue #115)
init_session_arrays_once() {
    # Double-check pattern to prevent race conditions
    if [[ "${SESSION_ARRAYS_INITIALIZED:-false}" == "true" ]]; then
        log_debug "Session arrays already initialized, skipping"
        return 0
    fi
    
    # Additional safety check for sourcing contexts
    if [[ "${SESSION_MANAGER_LOADED:-false}" == "true" ]] && [[ "${SESSION_ARRAYS_INITIALIZED:-false}" == "true" ]]; then
        log_debug "Session manager already fully loaded, skipping array initialization"
        return 0
    fi
    
    log_debug "Initializing session management arrays (optimization: once-only)"
    
    # Use more efficient declare syntax with error handling
    declare -gA SESSIONS 2>/dev/null || true
    declare -gA SESSION_STATES 2>/dev/null || true
    declare -gA SESSION_RESTART_COUNTS 2>/dev/null || true
    declare -gA SESSION_RECOVERY_COUNTS 2>/dev/null || true
    declare -gA SESSION_LAST_SEEN 2>/dev/null || true
    
    # Per-Project Session Management Arrays (Issue #89) - structured storage
    declare -gA PROJECT_SESSIONS 2>/dev/null || true
    declare -gA SESSION_PROJECTS 2>/dev/null || true
    declare -gA PROJECT_CONTEXTS 2>/dev/null || true
    
    # Structured session data arrays (Issue #115) - eliminates string parsing
    declare -gA SESSION_PROJECT_NAMES 2>/dev/null || true
    declare -gA SESSION_WORKING_DIRS 2>/dev/null || true
    declare -gA SESSION_PROJECT_IDS 2>/dev/null || true
    
    # Cache arrays for performance (Issue #115)
    declare -gA PROJECT_CONTEXT_CACHE 2>/dev/null || true
    declare -gA PROJECT_ID_CACHE 2>/dev/null || true
    
    # Verify critical array initialization  
    if ! declare -p SESSIONS >/dev/null 2>&1; then
        log_error "CRITICAL: Failed to declare SESSIONS array"
        return 1
    fi
    
    # Mark as initialized to prevent re-initialization
    SESSION_ARRAYS_INITIALIZED="true"
    SESSION_MANAGER_LOADED="true"
    export SESSION_ARRAYS_INITIALIZED SESSION_MANAGER_LOADED
    
    log_debug "Session arrays initialized once (optimization guard active)"
    log_info "Session arrays initialized successfully (optimization guards active)"
    return 0
}

# Backward compatibility wrapper
init_session_arrays() {
    init_session_arrays_once
}

# Comprehensive array validation function (Issue #115 - enhanced)
validate_session_arrays() {
    local errors=0
    
    # Check each required array including per-project and structured arrays
    local required_arrays=(
        "SESSIONS" "SESSION_STATES" "SESSION_RESTART_COUNTS" "SESSION_RECOVERY_COUNTS" 
        "SESSION_LAST_SEEN" "PROJECT_SESSIONS" "SESSION_PROJECTS" "PROJECT_CONTEXTS"
        "SESSION_PROJECT_NAMES" "SESSION_WORKING_DIRS" "SESSION_PROJECT_IDS"
        "PROJECT_CONTEXT_CACHE" "PROJECT_ID_CACHE"
    )
    
    for array_name in "${required_arrays[@]}"; do
        if ! declare -p "$array_name" >/dev/null 2>&1; then
            log_error "Array $array_name is not declared"
            ((errors++))
        else
            log_debug "Array $array_name is properly declared"
        fi
    done
    
    if [[ $errors -gt 0 ]]; then
        log_error "Found $errors array declaration errors"
        return 1
    fi
    
    log_debug "All session arrays are properly validated (including optimized arrays)"
    return 0
}

# Safe array access wrapper (Issue #115 - enhanced)
safe_array_get() {
    local array_name="$1"
    local key="$2"
    local default_value="${3:-}"
    
    # Ensure array exists
    if ! declare -p "$array_name" >/dev/null 2>&1; then
        echo "$default_value"
        return 1
    fi
    
    # Access array value safely
    local -n array_ref="$array_name"
    echo "${array_ref[$key]:-$default_value}"
}

# Batch array operations for efficiency (Issue #115)
batch_update_session_timestamps() {
    local current_time=$(date +%s)
    local -a session_ids=("$@")
    
    # Early return if no sessions to update
    if [[ ${#session_ids[@]} -eq 0 ]]; then
        return 0
    fi
    
    # Update multiple session timestamps at once - more efficient loop
    for session_id in "${session_ids[@]}"; do
        [[ -n "$session_id" ]] && SESSION_LAST_SEEN["$session_id"]="$current_time"
    done
    
    log_debug "Updated timestamps for ${#session_ids[@]} sessions"
}

# Efficient session data extraction (Issue #115)
# This replaces inefficient string parsing with direct array access
get_session_data_efficient() {
    local session_id="$1"
    local -n result_ref="$2"  # nameref for efficient return
    
    # Initialize result array
    result_ref=()  
    
    # Try structured data first (most efficient)
    if [[ -n "${SESSION_PROJECT_NAMES[$session_id]:-}" ]]; then
        result_ref[0]="${SESSION_PROJECT_NAMES[$session_id]}"
        result_ref[1]="${SESSION_WORKING_DIRS[$session_id]:-}"
        result_ref[2]="${SESSION_PROJECT_IDS[$session_id]:-}"
        return 0
    fi
    
    # Fallback to parsing (backward compatibility)
    local session_data="${SESSIONS[$session_id]:-}"
    if [[ -n "$session_data" ]]; then
        if [[ "$session_data" == *":"*":"* ]]; then
            # New format: project_name:working_dir:project_id
            result_ref[0]="${session_data%%:*}"
            local temp="${session_data#*:}"
            result_ref[1]="${temp%%:*}"
            result_ref[2]="${session_data##*:}"
        else
            # Legacy format: project_name:working_dir
            result_ref[0]="${session_data%%:*}"
            result_ref[1]="${session_data#*:}"
            result_ref[2]="$(get_current_project_context "${result_ref[1]}")"
        fi
        return 0
    fi
    
    return 1
}

# Batch session state operations (Issue #115)
batch_update_session_states() {
    local new_state="$1"
    shift
    local -a session_ids=("$@")
    local current_time=$(date +%s)
    local updated_count=0
    
    # Batch update states for multiple sessions
    for session_id in "${session_ids[@]}"; do
        if [[ -n "$session_id" ]] && [[ -n "${SESSIONS[$session_id]:-}" ]]; then
            local old_state="${SESSION_STATES[$session_id]:-$SESSION_STATE_UNKNOWN}"
            if [[ "$old_state" != "$new_state" ]]; then
                SESSION_STATES["$session_id"]="$new_state"
                SESSION_LAST_SEEN["$session_id"]="$current_time"
                ((updated_count++))
            fi
        fi
    done
    
    if [[ $updated_count -gt 0 ]]; then
        log_debug "Batch updated $updated_count sessions to state: $new_state"
    fi
    
    return 0
}

# Memory-efficient session count
get_session_count() {
    echo "${#SESSIONS[@]}"
}

# Get session count by state (efficient) - optimized with early termination
get_session_count_by_state() {
    local target_state="$1"
    local max_count="${2:-0}"  # Optional: stop counting at this limit
    local count=0
    
    # Early return if no sessions exist
    if [[ ${#SESSION_STATES[@]} -eq 0 ]]; then
        echo 0
        return 0
    fi
    
    for session_id in "${!SESSION_STATES[@]}"; do
        if [[ "${SESSION_STATES[$session_id]}" == "$target_state" ]]; then
            ((count++))
            # Early termination optimization
            if [[ $max_count -gt 0 ]] && [[ $count -ge $max_count ]]; then
                break
            fi
        fi
    done
    
    echo "$count"
}

# Efficient multi-state session counting (Issue #115)
get_session_counts_by_states() {
    local -a states=("$@")
    local -A counts
    
    # Initialize counts
    for state in "${states[@]}"; do
        counts["$state"]=0
    done
    
    # Single pass through all sessions
    for session_id in "${!SESSION_STATES[@]}"; do
        local current_state="${SESSION_STATES[$session_id]}"
        for state in "${states[@]}"; do
            if [[ "$current_state" == "$state" ]]; then
                ((counts["$state"]++))
                break  # Session can only be in one state
            fi
        done
    done
    
    # Output results
    for state in "${states[@]}"; do
        echo "$state:${counts[$state]}"
    done
}

# Ensure arrays are initialized before access (Issue #115 - optimized)
ensure_arrays_initialized() {
    if [[ "${SESSION_ARRAYS_INITIALIZED}" != "true" ]]; then
        log_debug "Arrays not initialized, calling init_session_arrays_once"
        init_session_arrays_once || return 1
    fi
    return 0
}

# ===============================================================================
# SESSION-STATE-MANAGEMENT
# ===============================================================================

# Optimized session registration with structured data (Issue #115)
register_session_efficient() {
    local session_id="$1" project_name="$2" working_dir="$3" project_id="$4"
    
    log_info "Registering new session: $session_id (project: $project_id)"
    
    # Ensure arrays are initialized
    ensure_arrays_initialized || {
        log_error "Failed to initialize session arrays"
        return 1
    }
    
    # Validate parameters
    if [[ -z "$session_id" ]] || [[ -z "$project_name" ]] || [[ -z "$working_dir" ]] || [[ -z "$project_id" ]]; then
        log_error "Invalid parameters for session registration"
        return 1
    fi
    
    # Check session limits before adding (Issue #115)
    local session_count=0
    set +u  # Temporarily disable nounset for array access
    if declare -p SESSIONS >/dev/null 2>&1; then
        session_count=${#SESSIONS[@]}
    fi
    set -u  # Re-enable nounset
    
    if [[ $session_count -ge $MAX_TRACKED_SESSIONS ]]; then
        log_warn "Maximum tracked sessions reached ($MAX_TRACKED_SESSIONS), performing cleanup"
        cleanup_sessions_efficient
    fi
    
    # Direct assignment to structured arrays - no string parsing needed (Issue #115)
    SESSION_PROJECT_NAMES["$session_id"]="$project_name"
    SESSION_WORKING_DIRS["$session_id"]="$working_dir"
    SESSION_PROJECT_IDS["$session_id"]="$project_id"
    
    # Core session arrays
    SESSIONS["$session_id"]="$project_name:$working_dir:$project_id"  # Backward compatibility
    SESSION_STATES["$session_id"]="$SESSION_STATE_STARTING"
    SESSION_RESTART_COUNTS["$session_id"]=0
    SESSION_RECOVERY_COUNTS["$session_id"]=0
    SESSION_LAST_SEEN["$session_id"]=$(date +%s)
    
    # Per-Project tracking
    PROJECT_SESSIONS["$project_id"]="$session_id"
    SESSION_PROJECTS["$session_id"]="$project_id"
    PROJECT_CONTEXTS["$project_id"]="$working_dir"
    
    log_debug "Session registered efficiently: $session_id -> structured data"
    log_debug "Project mapping: $project_id -> $session_id"
    return 0
}

# Backward compatibility wrapper
register_session() {
    local session_id="$1"
    local project_name="$2"
    local working_dir="$3"
    local project_id="${4:-$(get_current_project_context "$working_dir")}"
    
    register_session_efficient "$session_id" "$project_name" "$working_dir" "$project_id"
}

# Aktualisiere Session-Status
update_session_state() {
    local session_id="$1"
    local new_state="$2"
    local details="${3:-}"
    
    # Ensure arrays are initialized
    ensure_arrays_initialized || return 1
    
    local old_state="${SESSION_STATES[$session_id]:-$SESSION_STATE_UNKNOWN}"
    
    if [[ "$old_state" != "$new_state" ]]; then
        log_info "Session $session_id state change: $old_state -> $new_state"
        [[ -n "$details" ]] && log_debug "State change details: $details"
        
        SESSION_STATES["$session_id"]="$new_state"
        SESSION_LAST_SEEN["$session_id"]=$(date +%s)
        
        # Log Session-Event
        if declare -f log_session_event >/dev/null 2>&1; then
            log_session_event "$session_id" "state_change" "$old_state -> $new_state"
        fi
    fi
}

# Optimized session info retrieval (Issue #115)
get_session_info_efficient() {
    local session_id="$1"
    
    # Ensure arrays are initialized
    ensure_arrays_initialized || return 1
    
    # Check session exists
    if [[ -z "${SESSIONS[$session_id]:-}" ]]; then
        return 1
    fi
    
    # Use efficient data extraction helper
    local -a session_data_array
    if ! get_session_data_efficient "$session_id" session_data_array; then
        log_error "Failed to extract session data for: $session_id"
        return 1
    fi
    
    local project_name="${session_data_array[0]:-}"
    local working_dir="${session_data_array[1]:-}"
    local project_id="${session_data_array[2]:-}"
    
    local state="${SESSION_STATES[$session_id]:-$SESSION_STATE_UNKNOWN}"
    local restart_count="${SESSION_RESTART_COUNTS[$session_id]:-0}"
    local recovery_count="${SESSION_RECOVERY_COUNTS[$session_id]:-0}"
    local last_seen="${SESSION_LAST_SEEN[$session_id]:-0}"
    
    echo "SESSION_ID=$session_id"
    echo "PROJECT_NAME=$project_name"
    echo "PROJECT_ID=$project_id"
    echo "WORKING_DIR=$working_dir"
    echo "STATE=$state"
    echo "RESTART_COUNT=$restart_count"
    echo "RECOVERY_COUNT=$recovery_count"
    echo "LAST_SEEN=$last_seen"
}

# Backward compatibility wrapper  
get_session_info() {
    get_session_info_efficient "$1"
}

# ===============================================================================
# PER-PROJECT SESSION MANAGEMENT FUNCTIONS (Issue #89)
# ===============================================================================

# Batch session operations - get active sessions (Issue #115)
get_active_sessions() {
    local -a active_sessions
    local current_time=$(date +%s)
    
    # Single iteration to collect active sessions
    for session_id in "${!SESSIONS[@]}"; do
        local last_seen="${SESSION_LAST_SEEN[$session_id]:-0}"
        local state="${SESSION_STATES[$session_id]:-$SESSION_STATE_UNKNOWN}"
        
        # Consider session active if seen recently and not in error/stopped state
        if [[ $((current_time - last_seen)) -lt 3600 ]] && 
           [[ "$state" != "$SESSION_STATE_STOPPED" ]] && 
           [[ "$state" != "$SESSION_STATE_ERROR" ]]; then
            active_sessions+=("$session_id")
        fi
    done
    
    printf '%s\n' "${active_sessions[@]}"
}

# Optimized project sessions listing (Issue #115)
list_project_sessions() {
    local target_project_id="${1:-$(get_current_project_context)}"
    
    echo "=== Sessions for Project: $target_project_id ==="
    
    # Ensure arrays are initialized
    ensure_arrays_initialized || return 1
    
    local found_sessions=0
    local current_time=$(date +%s)
    
    # Batch collect project sessions for efficiency
    for session_id in "${!SESSIONS[@]}"; do
        # Use efficient data extraction - no string parsing!
        local -a session_data_array
        if ! get_session_data_efficient "$session_id" session_data_array; then
            continue  # Skip invalid sessions
        fi
        
        local project_name="${session_data_array[0]:-}"
        local working_dir="${session_data_array[1]:-}"
        local session_project_id="${session_data_array[2]:-}"
        
        if [[ "$session_project_id" == "$target_project_id" ]]; then
            
            local state="${SESSION_STATES[$session_id]:-$SESSION_STATE_UNKNOWN}"
            local restart_count="${SESSION_RESTART_COUNTS[$session_id]:-0}"
            local last_seen="${SESSION_LAST_SEEN[$session_id]:-0}"
            local age=$((current_time - last_seen))
            
            printf "  %-20s %-15s %-10s %3d restarts %3ds ago\n" \
                   "$session_id" "$project_name" "$state" "$restart_count" "$age"
            ((found_sessions++))
        fi
    done
    
    if [[ $found_sessions -eq 0 ]]; then
        echo "  No active sessions for this project"
    fi
    
    echo ""
}

# List all sessions grouped by project
list_sessions_by_project() {
    echo "=== All Active Sessions (Grouped by Project) ==="
    
    # Ensure arrays are initialized
    ensure_arrays_initialized || return 1
    
    # Use safer array length check
    local session_count=0
    set +u
    if declare -p SESSIONS >/dev/null 2>&1; then
        session_count=${#SESSIONS[@]}
    fi
    set -u
    
    if [[ $session_count -eq 0 ]]; then
        echo "No sessions registered"
        return 0
    fi
    
    # Collect unique project IDs using efficient data extraction
    local -A projects_found
    for session_id in "${!SESSIONS[@]}"; do
        local -a session_data_array
        if get_session_data_efficient "$session_id" session_data_array; then
            local session_project_id="${session_data_array[2]:-}"
            if [[ -n "$session_project_id" ]]; then
                projects_found["$session_project_id"]=1
            fi
        fi
    done
    
    # List sessions for each project
    for project_id in "${!projects_found[@]}"; do
        local project_dir="${PROJECT_CONTEXTS[$project_id]:-unknown}"
        echo ""
        echo "Project: $project_id ($project_dir)"
        echo "$(printf '%.${#project_id}s' "$(printf '%*s' "${#project_id}" | tr ' ' '-')")"
        
        list_project_sessions "$project_id"
    done
}

# Find session by project
find_session_by_project() {
    local target_project_id="${1:-$(get_current_project_context)}"
    
    ensure_arrays_initialized || return 1
    
    # Check direct project mapping first
    if [[ -n "${PROJECT_SESSIONS[$target_project_id]:-}" ]]; then
        echo "${PROJECT_SESSIONS[$target_project_id]}"
        return 0
    fi
    
    # Search through all sessions using efficient data extraction
    for session_id in "${!SESSIONS[@]}"; do
        local -a session_data_array
        if get_session_data_efficient "$session_id" session_data_array; then
            local session_project_id="${session_data_array[2]:-}"
            if [[ "$session_project_id" == "$target_project_id" ]]; then
                echo "$session_id"
                return 0
            fi
        fi
    done
    
    return 1
}

# Stop session for specific project
stop_project_session() {
    local target_project_id="${1:-$(get_current_project_context)}"
    
    log_info "Stopping session for project: $target_project_id"
    
    local session_id
    if session_id=$(find_session_by_project "$target_project_id"); then
        stop_managed_session "$session_id"
    else
        log_warn "No active session found for project: $target_project_id"
        return 1
    fi
}

# Liste alle Sessions (Enhanced Legacy Function)
list_sessions() {
    echo "=== Active Sessions (Legacy View) ==="
    
    # Ensure SESSIONS array is initialized globally
    if ! declare -p SESSIONS >/dev/null 2>&1; then
        declare -gA SESSIONS
        declare -gA SESSION_STATES  
        declare -gA SESSION_RESTART_COUNTS
        declare -gA SESSION_RECOVERY_COUNTS
        declare -gA SESSION_LAST_SEEN
    fi
    
    # Use safer array length check to avoid nounset errors
    local session_count=0
    set +u  # Temporarily disable nounset for array access
    if declare -p SESSIONS >/dev/null 2>&1; then
        session_count=${#SESSIONS[@]}
    fi
    set -u  # Re-enable nounset
    
    if [[ $session_count -eq 0 ]]; then
        echo "No sessions registered"
        echo ""
        echo "Use 'list_sessions_by_project' for enhanced per-project view"
        return 0
    fi
    
    for session_id in "${!SESSIONS[@]}"; do
        # Use efficient data extraction instead of parsing
        local -a session_data_array
        if ! get_session_data_efficient "$session_id" session_data_array; then
            continue  # Skip invalid sessions
        fi
        
        local project_name="${session_data_array[0]:-unknown}"
        local project_id="${session_data_array[2]:-legacy}"
        
        local state="${SESSION_STATES[$session_id]:-$SESSION_STATE_UNKNOWN}"
        local restart_count="${SESSION_RESTART_COUNTS[$session_id]:-0}"
        local last_seen="${SESSION_LAST_SEEN[$session_id]:-0}"
        local age=$(($(date +%s) - last_seen))
        
        printf "%-20s %-15s %-12s %-10s %3d restarts %3ds ago\n" \
               "$session_id" "$project_name" "$project_id" "$state" "$restart_count" "$age"
    done
    
    echo ""
    echo "Tip: Use 'list_sessions_by_project' for better project organization"
}

# Efficient session cleanup (Issue #115)
cleanup_sessions_efficient() {
    local max_sessions=${MAX_TRACKED_SESSIONS:-100}
    local session_count=${#SESSIONS[@]}
    local force_cleanup="${1:-false}"  # Force cleanup even if under limit
    
    # Early return if arrays not initialized
    if [[ "${SESSION_ARRAYS_INITIALIZED:-false}" != "true" ]]; then
        log_debug "Session arrays not initialized, skipping cleanup"
        return 0
    fi
    
    # Check if cleanup is needed
    if [[ $session_count -le $max_sessions ]] && [[ "$force_cleanup" != "true" ]]; then
        log_debug "Session count within limits ($session_count <= $max_sessions), no cleanup needed"
        return 0
    fi
    
    log_debug "Performing session cleanup (count: $session_count, limit: $max_sessions, forced: $force_cleanup)"
    
    # Collect removal candidates in single pass
    local -a sessions_to_remove
    local current_time=$(date +%s)
    
    for session_id in "${!SESSIONS[@]}"; do
        local state="${SESSION_STATES[$session_id]:-$SESSION_STATE_UNKNOWN}"
        local last_seen="${SESSION_LAST_SEEN[$session_id]:-0}"
        local age=$((current_time - last_seen))
        
        # Remove old inactive sessions
        if [[ "$state" == "$SESSION_STATE_STOPPED" ]] && [[ $age -gt 1800 ]]; then
            sessions_to_remove+=("$session_id")
        elif [[ "$state" == "$SESSION_STATE_ERROR" ]] && [[ $age -gt 900 ]]; then
            sessions_to_remove+=("$session_id")
        fi
    done
    
    # Batch removal - efficient cleanup
    local removed_count=0
    for session_id in "${sessions_to_remove[@]}"; do
        # Remove from all arrays in batch
        unset "SESSIONS[$session_id]" "SESSION_STATES[$session_id]"
        unset "SESSION_RESTART_COUNTS[$session_id]" "SESSION_RECOVERY_COUNTS[$session_id]"
        unset "SESSION_LAST_SEEN[$session_id]"
        
        # Remove from structured arrays
        unset "SESSION_PROJECT_NAMES[$session_id]" "SESSION_WORKING_DIRS[$session_id]"
        unset "SESSION_PROJECT_IDS[$session_id]"
        
        # Clean up project mappings
        local project_id="${SESSION_PROJECTS[$session_id]:-}"
        if [[ -n "$project_id" ]]; then
            unset "SESSION_PROJECTS[$session_id]" "PROJECT_SESSIONS[$project_id]"
        fi
        
        ((removed_count++))
    done
    
    # Additional cleanup: remove orphaned cache entries
    cleanup_orphaned_cache_entries
    
    # Compact arrays if significant cleanup occurred
    if [[ $removed_count -gt 10 ]] || [[ $removed_count -gt $((session_count / 4)) ]]; then
        log_debug "Significant cleanup performed, compacting arrays"
        compact_session_arrays
    fi
    
    log_info "Cleaned up $removed_count old sessions (efficient batch operation)"
    return 0
}

# Remove orphaned cache entries (Issue #115)
cleanup_orphaned_cache_entries() {
    local cleaned_cache_entries=0
    
    # Clean project context cache for non-existent sessions
    local -a cache_keys_to_remove
    for cache_key in "${!PROJECT_CONTEXT_CACHE[@]}"; do
        local found_session=false
        for session_id in "${!SESSIONS[@]}"; do
            local working_dir="${SESSION_WORKING_DIRS[$session_id]:-}"
            if [[ "$working_dir" == "$cache_key" ]]; then
                found_session=true
                break
            fi
        done
        
        if [[ "$found_session" == "false" ]]; then
            cache_keys_to_remove+=("$cache_key")
        fi
    done
    
    # Remove orphaned cache entries
    for cache_key in "${cache_keys_to_remove[@]}"; do
        unset "PROJECT_CONTEXT_CACHE[$cache_key]"
        ((cleaned_cache_entries++))
    done
    
    # Clean project ID cache similarly
    cache_keys_to_remove=()
    for cache_key in "${!PROJECT_ID_CACHE[@]}"; do
        local found_session=false
        for session_id in "${!SESSIONS[@]}"; do
            local working_dir="${SESSION_WORKING_DIRS[$session_id]:-}"
            local normalized_key="cache_${working_dir//[\/]/_}"
            if [[ "$normalized_key" == "$cache_key" ]]; then
                found_session=true
                break
            fi
        done
        
        if [[ "$found_session" == "false" ]]; then
            cache_keys_to_remove+=("$cache_key")
        fi
    done
    
    for cache_key in "${cache_keys_to_remove[@]}"; do
        unset "PROJECT_ID_CACHE[$cache_key]"
        ((cleaned_cache_entries++))
    done
    
    if [[ $cleaned_cache_entries -gt 0 ]]; then
        log_debug "Cleaned up $cleaned_cache_entries orphaned cache entries"
    fi
}

# Compact session arrays by removing gaps (Issue #115)
compact_session_arrays() {
    # This is mostly a no-op for associative arrays in Bash,
    # but we can check for consistency and log memory usage
    local total_arrays=8  # Number of main session arrays
    local total_entries=0
    
    # Count total entries across all arrays
    total_entries=$((${#SESSIONS[@]} + ${#SESSION_STATES[@]} + ${#SESSION_RESTART_COUNTS[@]} + 
                    ${#SESSION_RECOVERY_COUNTS[@]} + ${#SESSION_LAST_SEEN[@]} + 
                    ${#PROJECT_SESSIONS[@]} + ${#SESSION_PROJECTS[@]} + ${#PROJECT_CONTEXTS[@]}))
    
    local avg_entries=$((total_entries / total_arrays))
    log_debug "Array compaction complete - average entries per array: $avg_entries"
    
    # Verify array consistency
    local inconsistencies=0
    for session_id in "${!SESSIONS[@]}"; do
        if [[ -z "${SESSION_STATES[$session_id]:-}" ]]; then
            log_warn "Inconsistency found: session $session_id missing state"
            ((inconsistencies++))
        fi
    done
    
    if [[ $inconsistencies -gt 0 ]]; then
        log_warn "Found $inconsistencies array inconsistencies during compaction"
    fi
}

# Advanced cleanup with memory pressure handling (Issue #115)
cleanup_sessions_with_pressure_handling() {
    local memory_pressure="${1:-false}"
    local aggressive_mode="${2:-false}"
    
    log_debug "Running cleanup with memory pressure handling (pressure: $memory_pressure, aggressive: $aggressive_mode)"
    
    # Under memory pressure, be more aggressive
    local cleanup_age_stopped=1800   # 30 minutes
    local cleanup_age_error=900      # 15 minutes
    local max_sessions=${MAX_TRACKED_SESSIONS:-100}
    
    if [[ "$memory_pressure" == "true" ]]; then
        cleanup_age_stopped=900   # 15 minutes
        cleanup_age_error=300     # 5 minutes
        max_sessions=$((max_sessions / 2))  # Reduce limit by half
        log_debug "Memory pressure mode: reduced cleanup ages and session limit"
    fi
    
    if [[ "$aggressive_mode" == "true" ]]; then
        cleanup_age_stopped=300   # 5 minutes
        cleanup_age_error=60      # 1 minute
        max_sessions=$((max_sessions / 4))  # Reduce limit by 75%
        log_debug "Aggressive cleanup mode: very short cleanup ages"
    fi
    
    # Temporarily override the limit
    local original_limit=${MAX_TRACKED_SESSIONS:-100}
    MAX_TRACKED_SESSIONS=$max_sessions
    
    # Run efficient cleanup
    cleanup_sessions_efficient true
    
    # Restore original limit
    MAX_TRACKED_SESSIONS=$original_limit
    
    # Additional aggressive cleanup if needed
    if [[ "$aggressive_mode" == "true" ]]; then
        # Remove sessions that haven't been seen recently, regardless of state
        local current_time=$(date +%s)
        local -a sessions_to_remove
        
        for session_id in "${!SESSIONS[@]}"; do
            local last_seen="${SESSION_LAST_SEEN[$session_id]:-0}"
            local age=$((current_time - last_seen))
            
            if [[ $age -gt 600 ]]; then  # 10 minutes for any session
                sessions_to_remove+=("$session_id")
            fi
        done
        
        # Remove sessions found in aggressive cleanup
        local aggressive_removed=0
        for session_id in "${sessions_to_remove[@]}"; do
            remove_session_completely "$session_id"
            ((aggressive_removed++))
        done
        
        if [[ $aggressive_removed -gt 0 ]]; then
            log_info "Aggressive cleanup removed $aggressive_removed additional sessions"
        fi
    fi
}

# Complete session removal helper (Issue #115)
remove_session_completely() {
    local session_id="$1"
    
    # Remove from all arrays efficiently
    unset "SESSIONS[$session_id]" "SESSION_STATES[$session_id]" 
    unset "SESSION_RESTART_COUNTS[$session_id]" "SESSION_RECOVERY_COUNTS[$session_id]"
    unset "SESSION_LAST_SEEN[$session_id]"
    
    # Remove structured data
    unset "SESSION_PROJECT_NAMES[$session_id]" "SESSION_WORKING_DIRS[$session_id]"
    unset "SESSION_PROJECT_IDS[$session_id]"
    
    # Clean project mappings
    local project_id="${SESSION_PROJECTS[$session_id]:-}"
    if [[ -n "$project_id" ]]; then
        unset "SESSION_PROJECTS[$session_id]" "PROJECT_SESSIONS[$project_id]"
    fi
}

# Backward compatibility wrapper
cleanup_sessions() {
    local max_age="${1:-3600}"  # 1 Stunde Standard
    
    log_debug "Cleaning up sessions older than ${max_age}s (legacy mode)"
    
    local current_time=$(date +%s)
    local cleaned_count=0
    
    for session_id in "${!SESSIONS[@]}"; do
        local last_seen="${SESSION_LAST_SEEN[$session_id]:-0}"
        local age=$((current_time - last_seen))
        
        if [[ $age -gt $max_age ]]; then
            local state="${SESSION_STATES[$session_id]:-$SESSION_STATE_UNKNOWN}"
            
            if [[ "$state" == "$SESSION_STATE_STOPPED" ]] || [[ "$state" == "$SESSION_STATE_ERROR" ]]; then
                log_info "Cleaning up old session: $session_id (age: ${age}s, state: $state)"
                
                unset "SESSIONS[$session_id]"
                unset "SESSION_STATES[$session_id]"
                unset "SESSION_RESTART_COUNTS[$session_id]"
                unset "SESSION_RECOVERY_COUNTS[$session_id]"
                unset "SESSION_LAST_SEEN[$session_id]"
                
                # Clean up structured arrays if they exist
                unset "SESSION_PROJECT_NAMES[$session_id]" 2>/dev/null || true
                unset "SESSION_WORKING_DIRS[$session_id]" 2>/dev/null || true
                unset "SESSION_PROJECT_IDS[$session_id]" 2>/dev/null || true
                
                ((cleaned_count++))
            fi
        fi
    done
    
    if [[ $cleaned_count -gt 0 ]]; then
        log_info "Cleaned up $cleaned_count old sessions"
    fi
}

# ===============================================================================
# HEALTH-CHECK-FUNKTIONEN
# ===============================================================================

# Führe Health-Check für Session durch
perform_health_check() {
    local session_id="$1"
    
    log_debug "Performing health check for session: $session_id"
    
    if [[ -z "${SESSIONS[$session_id]:-}" ]]; then
        log_error "Session not found: $session_id"
        return 1
    fi
    
    local project_and_dir="${SESSIONS[$session_id]}"
    local project_name="${project_and_dir%%:*}"
    
    # Methode 1: tmux-Session-Check
    if [[ "$CLAUNCH_MODE" == "tmux" ]]; then
        local tmux_session_name="${TMUX_SESSION_PREFIX}-${project_name}"
        
        if tmux has-session -t "$tmux_session_name" 2>/dev/null; then
            # Prüfe ob Session aktiv ist (nicht suspended)
            local session_info
            session_info=$(tmux display-message -t "$tmux_session_name" -p "#{session_attached}")
            
            if [[ "$session_info" -gt 0 ]]; then
                update_session_state "$session_id" "$SESSION_STATE_RUNNING" "tmux session active"
                return 0
            else
                update_session_state "$session_id" "$SESSION_STATE_RUNNING" "tmux session detached but alive"
                return 0
            fi
        else
            update_session_state "$session_id" "$SESSION_STATE_STOPPED" "tmux session not found"
            return 1
        fi
    fi
    
    # Methode 2: Session-Datei-Check (Project-aware - Issue #89)
    local session_data="${SESSIONS[$session_id]}"
    local project_id
    
    # Extract project ID from session data
    if [[ "$session_data" == *":"*":"* ]]; then
        project_id="${session_data##*:}"
    else
        local working_dir="${session_data#*:}"
        project_id="$(get_current_project_context "$working_dir")"
    fi
    
    local session_file
    session_file="$(get_session_file_path "$project_id")"
    
    if [[ -f "$session_file" ]]; then
        local stored_session_id
        stored_session_id=$(cat "$session_file" 2>/dev/null || echo "")
        
        if [[ -n "$stored_session_id" ]]; then
            update_session_state "$session_id" "$SESSION_STATE_RUNNING" "project session file exists"
            return 0
        fi
    fi
    
    update_session_state "$session_id" "$SESSION_STATE_STOPPED" "no active session found"
    return 1
}

# Erkenne Usage-Limit-Status
detect_usage_limit() {
    local session_id="$1"
    
    log_debug "Checking for usage limits in session: $session_id"
    
    if [[ -z "${SESSIONS[$session_id]:-}" ]]; then
        return 1
    fi
    
    local project_and_dir="${SESSIONS[$session_id]}"
    local project_name="${project_and_dir%%:*}"
    
    # Prüfe tmux-Session-Output auf Usage-Limit-Meldungen
    if [[ "$CLAUNCH_MODE" == "tmux" ]]; then
        local tmux_session_name="${TMUX_SESSION_PREFIX}-${project_name}"
        
        if tmux has-session -t "$tmux_session_name" 2>/dev/null; then
            local session_output
            session_output=$(tmux capture-pane -t "$tmux_session_name" -p 2>/dev/null || echo "")
            
            if echo "$session_output" | grep -q "Claude AI usage limit reached\|usage limit reached"; then
                log_info "Usage limit detected in session: $session_id"
                update_session_state "$session_id" "$SESSION_STATE_USAGE_LIMITED" "usage limit detected in output"
                return 0
            fi
        fi
    fi
    
    # Alternative: Teste Claude CLI direkt
    local test_output
    if test_output=$(timeout "$HEALTH_CHECK_TIMEOUT" claude -p 'check' 2>&1); then
        if echo "$test_output" | grep -q "Claude AI usage limit reached\|usage limit reached"; then
            log_info "Usage limit detected via direct CLI test"
            update_session_state "$session_id" "$SESSION_STATE_USAGE_LIMITED" "usage limit detected via CLI"
            return 0
        fi
    fi
    
    return 1
}

# ===============================================================================
# RECOVERY-FUNKTIONEN
# ===============================================================================

# Führe Session-Recovery durch
perform_session_recovery() {
    local session_id="$1"
    local recovery_type="${2:-auto}"
    
    log_info "Starting session recovery: $session_id (type: $recovery_type)"
    
    if [[ -z "${SESSIONS[$session_id]:-}" ]]; then
        log_error "Cannot recover unknown session: $session_id"
        return 1
    fi
    
    # Prüfe Recovery-Limits
    local recovery_count="${SESSION_RECOVERY_COUNTS[$session_id]:-0}"
    if [[ $recovery_count -ge $MAX_RECOVERY_ATTEMPTS ]]; then
        log_error "Maximum recovery attempts reached for session: $session_id"
        update_session_state "$session_id" "$SESSION_STATE_ERROR" "max recovery attempts reached"
        return 1
    fi
    
    update_session_state "$session_id" "$SESSION_STATE_RECOVERING" "recovery attempt $((recovery_count + 1))"
    SESSION_RECOVERY_COUNTS["$session_id"]=$((recovery_count + 1))
    
    local project_and_dir="${SESSIONS[$session_id]}"
    local project_name="${project_and_dir%%:*}"
    local working_dir="${project_and_dir#*:}"
    
    # Recovery-Strategie basierend auf aktuellem Zustand
    local current_state="${SESSION_STATES[$session_id]:-$SESSION_STATE_UNKNOWN}"
    
    case "$current_state" in
        "$SESSION_STATE_USAGE_LIMITED")
            recover_from_usage_limit "$session_id"
            ;;
        "$SESSION_STATE_STOPPED")
            recover_stopped_session "$session_id" "$working_dir"
            ;;
        "$SESSION_STATE_ERROR")
            recover_error_session "$session_id" "$working_dir"
            ;;
        *)
            log_warn "No specific recovery strategy for state: $current_state"
            generic_session_recovery "$session_id" "$working_dir"
            ;;
    esac
}

# Recovery von Usage-Limit
recover_from_usage_limit() {
    local session_id="$1"
    
    log_info "Recovering from usage limit: $session_id"
    
    local project_and_dir="${SESSIONS[$session_id]}"
    local project_name="${project_and_dir%%:*}"
    
    # Sende Recovery-Kommando an Session
    if [[ "$CLAUNCH_MODE" == "tmux" ]]; then
        local tmux_session_name="${TMUX_SESSION_PREFIX}-${project_name}"
        
        if tmux has-session -t "$tmux_session_name" 2>/dev/null; then
            log_info "Sending recovery command to session: $session_id"
            tmux send-keys -t "$tmux_session_name" "/dev bitte mach weiter" Enter
            
            # Warte auf Recovery
            sleep "$RECOVERY_DELAY"
            
            # Prüfe ob Recovery erfolgreich war
            if ! detect_usage_limit "$session_id"; then
                log_info "Usage limit recovery successful: $session_id"
                update_session_state "$session_id" "$SESSION_STATE_RUNNING" "recovered from usage limit"
                SESSION_RECOVERY_COUNTS["$session_id"]=0  # Reset bei erfolgreichem Recovery
                return 0
            else
                log_warn "Usage limit recovery failed: $session_id"
                return 1
            fi
        fi
    fi
    
    log_error "Cannot send recovery command - no active tmux session"
    return 1
}

# ===============================================================================
# CONTEXT CLEARING FUNCTIONS (Issue #93)
# ===============================================================================

# Send context clear command to a session
# This function sends the /clear command to Claude via tmux send-keys
send_context_clear_command() {
    local session_name="$1"
    local wait_seconds="${2:-${QUEUE_CONTEXT_CLEAR_WAIT:-2}}"
    
    if [[ -z "$session_name" ]]; then
        log_error "send_context_clear_command: session_name parameter required"
        return 1
    fi
    
    log_info "Clearing context for session: $session_name"
    
    # Check if this is a tmux session or session ID  
    if [[ "$CLAUNCH_MODE" == "tmux" ]]; then
        local tmux_session_name
        
        # If it looks like a session ID, convert to tmux session name
        if [[ "$session_name" =~ ^sess- ]]; then
            # Extract project name from session data
            local project_and_dir="${SESSIONS[$session_name]:-}"
            if [[ -n "$project_and_dir" ]]; then
                local project_name="${project_and_dir%%:*}"
                tmux_session_name="${TMUX_SESSION_PREFIX}-${project_name}"
            else
                log_error "Cannot find project name for session ID: $session_name"
                return 1
            fi
        else
            # Assume it's already a tmux session name
            tmux_session_name="$session_name"
        fi
        
        if tmux has-session -t "$tmux_session_name" 2>/dev/null; then
            log_debug "Sending /clear command to tmux session: $tmux_session_name"
            
            # Send the /clear command
            if tmux send-keys -t "$tmux_session_name" '/clear' C-m 2>/dev/null; then
                log_debug "Context clear command sent, waiting ${wait_seconds}s for completion"
                sleep "$wait_seconds"
                log_info "Context cleared for session: $session_name"
                return 0
            else
                log_error "Failed to send context clear command to session: $tmux_session_name"
                return 1
            fi
        else
            log_warn "tmux session not found, cannot clear context: $tmux_session_name"
            return 1
        fi
    else
        log_warn "Context clearing only supported in tmux mode, current mode: ${CLAUNCH_MODE:-direct}"
        return 1
    fi
}

# Check if context clearing is supported for the current session
is_context_clearing_supported() {
    local session_id="$1"
    
    # Context clearing requires tmux mode
    if [[ "$CLAUNCH_MODE" != "tmux" ]]; then
        return 1
    fi
    
    # Session must exist and be active
    if [[ -z "${SESSIONS[$session_id]:-}" ]]; then
        return 1
    fi
    
    # Extract tmux session name and check if it exists
    local project_and_dir="${SESSIONS[$session_id]}"
    local project_name="${project_and_dir%%:*}"
    local tmux_session_name="${TMUX_SESSION_PREFIX}-${project_name}"
    
    tmux has-session -t "$tmux_session_name" 2>/dev/null
}

# Recovery gestoppter Session
recover_stopped_session() {
    local session_id="$1"
    local working_dir="$2"
    
    log_info "Recovering stopped session: $session_id"
    
    # Prüfe Restart-Limits
    local restart_count="${SESSION_RESTART_COUNTS[$session_id]:-0}"
    if [[ $restart_count -ge $MAX_RESTARTS ]]; then
        log_error "Maximum restarts reached for session: $session_id"
        update_session_state "$session_id" "$SESSION_STATE_ERROR" "max restarts reached"
        return 1
    fi
    
    SESSION_RESTART_COUNTS["$session_id"]=$((restart_count + 1))
    
    # Warte vor Neustart
    if [[ $SESSION_RESTART_DELAY -gt 0 ]]; then
        log_debug "Waiting ${SESSION_RESTART_DELAY}s before session restart"
        sleep "$SESSION_RESTART_DELAY"
    fi
    
    # Starte Session neu
    if declare -f start_claunch_session >/dev/null 2>&1; then
        cd "$working_dir"
        if start_claunch_session "$working_dir" "continue"; then
            log_info "Session restart successful: $session_id"
            update_session_state "$session_id" "$SESSION_STATE_RUNNING" "restarted successfully"
            SESSION_RECOVERY_COUNTS["$session_id"]=0
            return 0
        else
            log_error "Session restart failed: $session_id"
            update_session_state "$session_id" "$SESSION_STATE_ERROR" "restart failed"
            return 1
        fi
    else
        log_error "claunch integration not available for restart"
        return 1
    fi
}

# Recovery bei Fehlern
recover_error_session() {
    local session_id="$1"
    local working_dir="$2"
    
    log_info "Recovering error session: $session_id"
    
    # Bereinige potentiell korrupte Session-Dateien
    local project_and_dir="${SESSIONS[$session_id]}"
    local project_name="${project_and_dir%%:*}"
    local session_file="$HOME/.claude_session_${project_name}"
    
    if [[ -f "$session_file" ]]; then
        log_debug "Removing potentially corrupt session file: $session_file"
        rm -f "$session_file"
    fi
    
    # Versuche Clean-Restart
    recover_stopped_session "$session_id" "$working_dir"
}

# Generische Recovery
generic_session_recovery() {
    local session_id="$1"
    local working_dir="$2"
    
    log_info "Performing generic recovery: $session_id"
    
    # Erst Health-Check versuchen
    if perform_health_check "$session_id"; then
        log_info "Session is actually healthy: $session_id"
        return 0
    fi
    
    # Dann Standard-Recovery
    recover_stopped_session "$session_id" "$working_dir"
}

# ===============================================================================
# MONITORING-LOOP
# ===============================================================================

# Optimized session monitoring with batch operations (Issue #115)
monitor_sessions() {
    local check_interval="${1:-$HEALTH_CHECK_INTERVAL}"
    
    log_info "Starting optimized session monitoring (interval: ${check_interval}s)"
    
    while true; do
        log_debug "Performing batch session health checks"
        
        # Get active sessions in batch for efficiency
        local -a active_sessions_list
        mapfile -t active_sessions_list < <(get_active_sessions)
        
        log_debug "Checking ${#active_sessions_list[@]} active sessions"
        
        # Health-Check für aktive Sessions
        for session_id in "${active_sessions_list[@]}"; do
            [[ -z "$session_id" ]] && continue
            
            local current_state="${SESSION_STATES[$session_id]:-$SESSION_STATE_UNKNOWN}"
            
            # Überspringe Sessions, die bereits in Recovery sind
            if [[ "$current_state" == "$SESSION_STATE_RECOVERING" ]]; then
                continue
            fi
            
            # Führe Health-Check durch
            if ! perform_health_check "$session_id"; then
                log_warn "Health check failed for session: $session_id"
                
                # Auto-Recovery falls aktiviert
                if [[ "$AUTO_RECOVERY_ENABLED" == "true" ]]; then
                    log_info "Starting automatic recovery for session: $session_id"
                    perform_session_recovery "$session_id" "auto"
                fi
            else
                # Prüfe auf Usage-Limits
                if detect_usage_limit "$session_id"; then
                    if [[ "$AUTO_RECOVERY_ENABLED" == "true" ]]; then
                        log_info "Starting automatic usage limit recovery: $session_id"
                        perform_session_recovery "$session_id" "usage_limit"
                    fi
                fi
            fi
        done
        
        # Efficient session cleanup
        cleanup_sessions_efficient
        
        # Warte bis zum nächsten Check
        sleep "$check_interval"
    done
}

# ===============================================================================
# ÖFFENTLICHE API-FUNKTIONEN
# ===============================================================================

# Initialisiere Session-Manager (Issue #115 - optimized)
init_session_manager() {
    local config_file="${1:-config/default.conf}"
    
    log_info "Initializing optimized session manager"
    
    # CRITICAL: Initialize arrays once with guards
    if ! init_session_arrays_once; then
        log_error "Failed to initialize session arrays"
        return 1
    fi
    
    # Validate array initialization  
    if ! validate_session_arrays; then
        log_error "Session array validation failed"
        return 1
    fi
    
    # Load configuration using centralized loader (Issue #114)
    # If centralized config loader is available, use it
    if declare -f load_system_config >/dev/null 2>&1; then
        # Config should already be loaded by main process, but ensure it's loaded
        if [[ -z "${SYSTEM_CONFIG_LOADED:-}" ]]; then
            load_system_config "$config_file" || log_warn "Failed to load centralized config"
        fi
        
        # Get session manager specific config values using centralized functions
        MAX_RESTARTS=$(get_config "MAX_RESTARTS" "50")
        SESSION_RESTART_DELAY=$(get_config "SESSION_RESTART_DELAY" "5")
        HEALTH_CHECK_ENABLED=$(get_config "HEALTH_CHECK_ENABLED" "true")
        HEALTH_CHECK_INTERVAL=$(get_config "HEALTH_CHECK_INTERVAL" "30")
        HEALTH_CHECK_TIMEOUT=$(get_config "HEALTH_CHECK_TIMEOUT" "10")
        AUTO_RECOVERY_ENABLED=$(get_config "AUTO_RECOVERY_ENABLED" "true")
        RECOVERY_DELAY=$(get_config "RECOVERY_DELAY" "10")
        MAX_RECOVERY_ATTEMPTS=$(get_config "MAX_RECOVERY_ATTEMPTS" "3")
        
        log_debug "Session manager configured using centralized loader"
    else
        # Fallback to direct file reading for backward compatibility
        if [[ -f "$config_file" ]]; then
            while IFS='=' read -r key value; do
                [[ "$key" =~ ^[[:space:]]*# ]] && continue
                [[ -z "$key" ]] && continue
                
                # Remove quotes from beginning and end
                value=${value#\"} 
                value=${value%\"}
                value=${value#\'} 
                value=${value%\'}
                
                case "$key" in
                    MAX_RESTARTS|SESSION_RESTART_DELAY|HEALTH_CHECK_ENABLED|HEALTH_CHECK_INTERVAL|HEALTH_CHECK_TIMEOUT|AUTO_RECOVERY_ENABLED|RECOVERY_DELAY|MAX_RECOVERY_ATTEMPTS)
                        eval "$key='$value'"
                        ;;
                esac
            done < <(grep -E '^[^#]*=' "$config_file" || true)
            
            log_debug "Session manager configured from: $config_file (fallback method)"
        fi
    fi
    
    # Initialisiere claunch-Integration falls verfügbar
    if declare -f init_claunch_integration >/dev/null 2>&1; then
        init_claunch_integration "$config_file"
    fi
    
    log_info "Session manager initialized successfully"
}

# Starte verwaltete Session (Enhanced for Per-Project - Issue #89)
start_managed_session() {
    local project_name="$1"
    local working_dir="$2"
    local use_new_terminal="${3:-false}"
    shift 3
    local claude_args=("$@")
    
    # Generate project context
    local project_id
    project_id=$(get_current_project_context "$working_dir")
    
    log_info "Starting managed session for project: $project_name (ID: $project_id)"
    
    # Check if session already exists for this project
    local existing_session_id
    if existing_session_id=$(find_session_by_project "$project_id"); then
        log_info "Found existing session for project $project_id: $existing_session_id"
        
        local current_state="${SESSION_STATES[$existing_session_id]:-$SESSION_STATE_UNKNOWN}"
        if [[ "$current_state" == "$SESSION_STATE_RUNNING" ]]; then
            log_info "Session already running, returning existing session ID: $existing_session_id"
            echo "$existing_session_id"
            return 0
        else
            log_info "Existing session not running (state: $current_state), starting new session"
        fi
    fi
    
    # Generiere neue Session-ID mit project context
    local session_id
    session_id=$(generate_session_id "$project_name" "$project_id")
    
    # Registriere Session mit project context
    register_session "$session_id" "$project_name" "$working_dir" "$project_id"
    
    # Starte Session über claunch-Integration
    if declare -f start_or_resume_session >/dev/null 2>&1; then
        if start_or_resume_session "$working_dir" "$use_new_terminal" "${claude_args[@]}"; then
            update_session_state "$session_id" "$SESSION_STATE_RUNNING" "project session started successfully"
            
            # Store session ID in project-specific file
            local session_file
            session_file="$(get_session_file_path "$project_id")"
            echo "$session_id" > "$session_file"
            
            log_info "Project session started and registered: $session_id -> $session_file"
            echo "$session_id"  # Return session ID für Tracking
            return 0
        else
            update_session_state "$session_id" "$SESSION_STATE_ERROR" "failed to start project session"
            return 1
        fi
    else
        log_error "claunch integration not available for project session"
        update_session_state "$session_id" "$SESSION_STATE_ERROR" "claunch integration unavailable"
        return 1
    fi
}

# Stoppe verwaltete Session (Enhanced for Per-Project - Issue #89)
stop_managed_session() {
    local session_id="$1"
    
    log_info "Stopping managed project session: $session_id"
    
    if [[ -z "${SESSIONS[$session_id]:-}" ]]; then
        log_error "Session not found: $session_id"
        return 1
    fi
    
    # Extract project information using efficient data extraction
    local -a session_data_array
    if ! get_session_data_efficient "$session_id" session_data_array; then
        log_error "Failed to extract session data for: $session_id"
        return 1
    fi
    
    local project_name="${session_data_array[0]:-}"
    local working_dir="${session_data_array[1]:-}"
    local project_id="${session_data_array[2]:-}"
    
    log_debug "Stopping session for project: $project_name (ID: $project_id)"
    
    # Stoppe tmux-Session falls vorhanden
    if [[ "$CLAUNCH_MODE" == "tmux" ]]; then
        local tmux_session_name="${TMUX_SESSION_PREFIX}-${project_id}"
        
        if tmux has-session -t "$tmux_session_name" 2>/dev/null; then
            tmux kill-session -t "$tmux_session_name"
            log_info "Project tmux session terminated: $tmux_session_name"
        else
            log_debug "No tmux session found to terminate: $tmux_session_name"
        fi
    fi
    
    # Clean up project-specific session files
    local session_file
    session_file="$(get_session_file_path "$project_id")"
    
    if [[ -f "$session_file" ]]; then
        rm -f "$session_file"
        log_debug "Removed project session file: $session_file"
    fi
    
    # Clean up metadata file if it exists
    local metadata_file="${session_file}.metadata"
    if [[ -f "$metadata_file" ]]; then
        rm -f "$metadata_file"
        log_debug "Removed project session metadata: $metadata_file"
    fi
    
    # Update session state and clean up from tracking arrays
    update_session_state "$session_id" "$SESSION_STATE_STOPPED" "stopped by user"
    
    # Clean up project mappings
    if [[ -n "${PROJECT_SESSIONS[$project_id]:-}" ]]; then
        unset "PROJECT_SESSIONS[$project_id]"
    fi
    
    if [[ -n "${SESSION_PROJECTS[$session_id]:-}" ]]; then
        unset "SESSION_PROJECTS[$session_id]"
    fi
    
    log_info "Project session stopped and cleaned up: $session_id (project: $project_id)"
    return 0
}

# ===============================================================================
# ENHANCED SESSION DETECTION FUNCTIONS (für Setup Wizard)
# ===============================================================================

# Übergreifende Claude Session Detection für Setup Wizard
# 
# Diese Funktion implementiert eine mehrstufige Erkennungsstrategie für bestehende Claude-Sessions:
# 1. tmux-Sessions: Sucht nach aktiven tmux-Sessions mit Claude-bezogenen Namen
# 2. Session-Dateien: Prüft persistierte Session-IDs in bekannten Dateipfaden
# 3. Prozess-Baum: Analysiert laufende Prozesse auf Claude-Instanzen
# 4. Socket-Verbindungen: Heuristische Netzwerk-Analyse (experimentell)
#
# Die Methoden werden sequenziell ausgeführt und die erste erfolgreiche Detection
# bestimmt das Ergebnis. Dies ermöglicht robuste Erkennung auch bei partiellen
# System-Zuständen (z.B. tmux läuft aber Session-Datei fehlt).
#
# Rückgabe: 0 wenn Session gefunden, 1 wenn keine Session erkannt
detect_existing_claude_session() {
    log_debug "Starting comprehensive Claude session detection"
    
    # Definiere Detection-Methoden in Prioritätsreihenfolge
    # (von spezifischsten zu allgemeinsten)
    local detection_methods=(
        "check_tmux_sessions"        # Spezifisch: aktive tmux-Sessions
        "check_session_files"        # Spezifisch: persistierte Session-IDs
        "check_process_tree"         # Allgemein: laufende Claude-Prozesse
        "check_socket_connections"   # Heuristisch: Netzwerk-Verbindungen
    )
    
    for method in "${detection_methods[@]}"; do
        log_debug "Trying detection method: $method"
        
        if "$method"; then
            log_info "Claude session detected via $method"
            return 0
        fi
    done
    
    log_info "No existing Claude session detected"
    return 1
}

# Prüfe tmux-Sessions auf Claude-bezogene Sessions
#
# Implementiert eine zweistufige tmux-Session-Erkennung:
# 1. Exakte Übereinstimmung: Sucht nach dem erwarteten Session-Namen für das aktuelle Projekt
# 2. Pattern-Matching: Sucht nach Sessions mit Claude-relevanten Namensmustern
# 3. Content-Validation: Analysiert Session-Inhalte auf Claude-spezifische Ausgaben
#
# Die Funktion verwendet tmux's session formatting (#{session_name}) für zuverlässige
# Namensextraktion und grep mit erweiterten Regex für flexible Pattern-Erkennung.
check_tmux_sessions() {
    local project_name=$(basename "$(pwd)")
    local session_pattern="${TMUX_SESSION_PREFIX:-claude-auto-resume}-${project_name}"
    
    # Stufe 1: Exakte Übereinstimmung mit erwartetem Session-Namen
    # Dies ist der optimale Fall - die Session wurde von unserem System erstellt
    if tmux has-session -t "$session_pattern" 2>/dev/null; then
        DETECTED_SESSION_NAME="$session_pattern"
        log_info "Found exact tmux session match: $session_pattern"
        return 0
    fi
    
    # Stufe 2: Pattern-basierte Suche nach Claude-relevanten Session-Namen
    # Regex erklärt: "claude" (case-insensitive), "auto-resume", oder "sess-" (Session-ID Präfix)
    local matching_sessions
    matching_sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -E "claude|auto-resume|sess-" || true)
    
    if [[ -n "$matching_sessions" ]]; then
        log_info "Found potential Claude tmux sessions: $matching_sessions"
        DETECTED_SESSION_NAME=$(echo "$matching_sessions" | head -1)
        
        # Stufe 3: Content-Validation - verifiziere Claude-Aktivität in gefundenen Sessions
        # Verwende tmux capture-pane um den aktuellen Session-Inhalt zu analysieren
        # Dies verhindert False-Positives von unrelated Sessions mit ähnlichen Namen
        for session in $matching_sessions; do
            local session_output
            session_output=$(tmux capture-pane -t "$session" -p 2>/dev/null || echo "")
            
            # Suche nach Claude-spezifischen Ausgabeindikatoren:
            # - "claude"/"Claude": Kommandozeilen-Tool oder Begrüßung
            # - "session"/"sess-": Session-ID-Referenzen in Claude-Ausgaben
            if echo "$session_output" | grep -q "claude\|Claude\|session\|sess-"; then
                DETECTED_SESSION_NAME="$session"
                log_info "Confirmed Claude activity in session: $session"
                return 0
            fi
        done
    fi
    
    return 1
}

# Prüfe Session-Dateien auf persistierte Session-IDs
#
# Durchsucht bekannte Dateipfade nach gespeicherten Claude Session-IDs.
# Diese Dateien werden vom System erstellt um Session-Persistenz über
# Terminal-Neustarts hinweg zu ermöglichen.
# 
# Priorität der Dateipfade (wichtigste zuerst):
# 1. Projektspezifische Session-Datei im Home-Verzeichnis
# 2. Legacy Auto-Resume Session-Datei (Backwards-Kompatibilität) 
# 3. Lokale Session-Datei im Projektverzeichnis
# 4. Globale Session-Datei (fallback für nicht-projekt-spezifische Usage)
check_session_files() {
    local project_name=$(basename "$(pwd)")
    local session_files=(
        "$HOME/.claude_session_${project_name}"     # Projekt-spezifisch
        "$HOME/.claude_auto_resume_${project_name}" # Legacy-Format
        "$(pwd)/.claude_session"                    # Lokal im Projekt
        "$HOME/.claude_session"
    )
    
    for file in "${session_files[@]}"; do
        if [[ -f "$file" && -s "$file" ]]; then
            local session_id
            session_id=$(cat "$file" 2>/dev/null | head -1 | tr -d '\n\r' | sed 's/[[:space:]]*$//')
            
            if [[ -n "$session_id" ]]; then
                log_info "Found session file: $file with ID: $session_id"
                
                # Validiere Session ID Format
                if [[ "$session_id" =~ ^sess- ]] && [[ ${#session_id} -ge 10 ]]; then
                    DETECTED_SESSION_ID="$session_id"
                    
                    # Prüfe ob Session noch aktiv ist (optional)
                    if validate_session_id_active "$session_id"; then
                        log_info "Confirmed active session from file: $session_id"
                        return 0
                    else
                        log_warn "Session file found but session may be inactive: $session_id"
                        return 0  # Trotzdem als gefunden markieren
                    fi
                else
                    log_warn "Invalid session ID format in file $file: $session_id"
                fi
            fi
        fi
    done
    
    return 1
}

# Prüfe Prozess-Baum auf Claude-Instanzen
check_process_tree() {
    log_debug "Checking process tree for Claude instances"
    
    # Finde Claude-Prozesse
    local claude_processes
    claude_processes=$(pgrep -f "claude" 2>/dev/null || true)
    
    if [[ -n "$claude_processes" ]]; then
        log_info "Found running Claude processes: $claude_processes"
        
        # Prüfe ob Claude-Prozesse in tmux laufen
        for pid in $claude_processes; do
            # Prüfe ob der Prozess in einer tmux-Session läuft
            if tmux list-panes -a -F '#{pane_pid} #{session_name}' 2>/dev/null | grep -q "^$pid "; then
                local session_name
                session_name=$(tmux list-panes -a -F '#{pane_pid} #{session_name}' 2>/dev/null | grep "^$pid " | head -1 | cut -d' ' -f2)
                log_info "Found Claude process $pid running in tmux session: $session_name"
                DETECTED_SESSION_NAME="$session_name"
                return 0
            fi
        done
        
        # Auch wenn nicht in tmux, könnte es eine direkte Claude-Instanz sein
        log_info "Found Claude processes but not in tmux sessions"
        return 0
    fi
    
    return 1
}

# Prüfe Socket-Verbindungen (erweiterte Detection)
check_socket_connections() {
    log_debug "Checking socket connections for Claude activity"
    
    # Prüfe auf offene Netzwerkverbindungen zu Claude-Servern
    # Dies ist eine heuristische Methode, die nach typischen Claude-Verbindungen sucht
    if has_command "netstat"; then
        local claude_connections
        claude_connections=$(netstat -an 2>/dev/null | grep -E "anthropic|claude|443" | grep ESTABLISHED || true)
        
        if [[ -n "$claude_connections" ]]; then
            log_debug "Found potential Claude network connections"
            return 0
        fi
    elif has_command "lsof"; then
        local claude_network
        claude_network=$(lsof -i -n 2>/dev/null | grep -E "claude|anthropic" || true)
        
        if [[ -n "$claude_network" ]]; then
            log_debug "Found Claude network activity via lsof"
            return 0
        fi
    fi
    
    return 1
}

# Validiere ob eine Session-ID noch aktiv ist
validate_session_id_active() {
    local session_id="$1"
    
    # Basis-Validierung der Session-ID-Format
    if [[ ! "$session_id" =~ ^sess- ]] || [[ ${#session_id} -lt 10 ]]; then
        log_debug "Invalid session ID format: $session_id"
        return 1
    fi
    
    # Prüfe ob tmux-Sessions mit dieser Session-ID in Verbindung stehen
    local tmux_sessions
    tmux_sessions=$(tmux list-sessions 2>/dev/null || true)
    
    if [[ -n "$tmux_sessions" ]]; then
        # Durchsuche Session-Outputs nach der Session-ID
        while IFS= read -r session_line; do
            if [[ -n "$session_line" ]]; then
                local session_name
                session_name=$(echo "$session_line" | cut -d':' -f1)
                
                local session_output
                session_output=$(tmux capture-pane -t "$session_name" -p 2>/dev/null || echo "")
                
                if echo "$session_output" | grep -q "$session_id"; then
                    log_debug "Session ID $session_id found in tmux session: $session_name"
                    return 0
                fi
            fi
        done <<< "$tmux_sessions"
    fi
    
    # Session-ID nicht in aktiven Sessions gefunden
    return 1
}

# Erweiterte Session-Information sammeln
get_session_info() {
    local session_identifier="$1"
    
    echo "Session Information:"
    echo "=================="
    
    # Falls es eine tmux-Session ist
    if tmux has-session -t "$session_identifier" 2>/dev/null; then
        echo "Type: tmux session"
        echo "Name: $session_identifier"
        echo "Created: $(tmux list-sessions -F '#{session_created} #{session_name}' | grep "$session_identifier" | cut -d' ' -f1)"
        echo "Windows: $(tmux list-windows -t "$session_identifier" | wc -l)"
        echo ""
        echo "Recent output:"
        tmux capture-pane -t "$session_identifier" -p | tail -5
    # Falls es eine Session-ID ist
    elif [[ "$session_identifier" =~ ^sess- ]]; then
        echo "Type: Claude session ID"
        echo "Session ID: $session_identifier"
        echo "Format: $(if [[ ${#session_identifier} -ge 20 ]]; then echo "Valid"; else echo "Short/Invalid"; fi)"
        
        # Suche zugehörige tmux-Session
        local found_session=""
        local tmux_sessions
        tmux_sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)
        
        if [[ -n "$tmux_sessions" ]]; then
            while IFS= read -r session_name; do
                if [[ -n "$session_name" ]]; then
                    local session_output
                    session_output=$(tmux capture-pane -t "$session_name" -p 2>/dev/null || echo "")
                    
                    if echo "$session_output" | grep -q "$session_identifier"; then
                        found_session="$session_name"
                        break
                    fi
                fi
            done <<< "$tmux_sessions"
        fi
        
        if [[ -n "$found_session" ]]; then
            echo "Associated tmux session: $found_session"
        else
            echo "Associated tmux session: Not found"
        fi
    else
        echo "Type: Unknown"
        echo "Identifier: $session_identifier"
    fi
}

# ===============================================================================
# MAIN ENTRY POINT (für Testing)
# ===============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "=== Session Manager Test ==="
    
    init_session_manager
    
    echo "Configuration:"
    echo "  MAX_RESTARTS: $MAX_RESTARTS"
    echo "  HEALTH_CHECK_ENABLED: $HEALTH_CHECK_ENABLED"
    echo "  AUTO_RECOVERY_ENABLED: $AUTO_RECOVERY_ENABLED"
    echo ""
    
    list_sessions
    
    if [[ "${1:-}" == "--monitor" ]]; then
        echo "Starting session monitoring..."
        monitor_sessions
    fi
fi