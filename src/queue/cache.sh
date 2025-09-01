#!/usr/bin/env bash

# Claude Auto-Resume - Task Queue Cache Module
# High-performance caching system for queue operations
# Version: 2.1.0-efficiency-optimization (Issue #116)

set -euo pipefail

# ===============================================================================
# CACHE CONSTANTS AND GLOBALS
# ===============================================================================

# Cache configuration (only declare if not already set)
if [[ -z "${CACHE_VERSION:-}" ]]; then
    readonly CACHE_VERSION="2.1.0"
fi
if [[ -z "${CACHE_MAX_AGE_SECONDS:-}" ]]; then
    readonly CACHE_MAX_AGE_SECONDS=300  # 5 minutes max cache age
fi
if [[ -z "${CACHE_MAX_ENTRIES:-}" ]]; then
    readonly CACHE_MAX_ENTRIES=1000     # Prevent memory exhaustion
fi

# Cache directory (dynamic to support different environments)
CACHE_DIR="${HOME}/.claude-queue-cache"

# Cache data structures (declare as global if not already declared)
if ! declare -p QUEUE_CACHE_DATA &>/dev/null; then
    declare -gA QUEUE_CACHE_DATA=()
fi
if ! declare -p TASK_INDEX &>/dev/null; then
    declare -gA TASK_INDEX=()
fi
if ! declare -p TASK_STATUS_COUNTS &>/dev/null; then
    declare -gA TASK_STATUS_COUNTS=()
fi

# Cache state tracking
declare -g QUEUE_CACHE_TIMESTAMP=0
declare -g QUEUE_CACHE_VALID=false
declare -g CACHE_STATS_JSON=""
declare -g LAST_QUEUE_MTIME=0
declare -g CACHE_HIT_COUNT=0
declare -g CACHE_MISS_COUNT=0

# ===============================================================================
# CACHE INITIALIZATION AND MANAGEMENT
# ===============================================================================

# Initialize cache system
init_cache_system() {
    log_debug "[CACHE] Initializing cache system v$CACHE_VERSION"
    
    # Create cache directory if needed
    if [[ ! -d "$CACHE_DIR" ]]; then
        mkdir -p "$CACHE_DIR" || {
            log_warn "[CACHE] Failed to create cache directory, using memory-only cache"
            return 0
        }
        log_debug "[CACHE] Created cache directory: $CACHE_DIR"
    fi
    
    # Initialize cache state
    QUEUE_CACHE_VALID=false
    QUEUE_CACHE_TIMESTAMP=0
    CACHE_HIT_COUNT=0
    CACHE_MISS_COUNT=0
    
    log_info "[CACHE] Cache system initialized successfully"
    return 0
}

# Check if cache is valid for given queue file
is_cache_valid() {
    local queue_file="$1"
    
    # Check if cache is marked as valid
    if [[ "$QUEUE_CACHE_VALID" != "true" ]]; then
        log_debug "[CACHE] Cache marked as invalid"
        return 1
    fi
    
    # Check if queue file exists
    if [[ ! -f "$queue_file" ]]; then
        log_debug "[CACHE] Queue file does not exist: $queue_file"
        return 1
    fi
    
    # Check file modification time
    local current_mtime
    current_mtime=$(stat -f %m "$queue_file" 2>/dev/null || echo 0)
    
    if [[ $current_mtime -gt $LAST_QUEUE_MTIME ]]; then
        log_debug "[CACHE] Queue file modified (mtime: $current_mtime > $LAST_QUEUE_MTIME)"
        return 1
    fi
    
    # Check cache age
    local current_time
    current_time=$(date +%s)
    local cache_age=$((current_time - QUEUE_CACHE_TIMESTAMP))
    
    if [[ $cache_age -gt $CACHE_MAX_AGE_SECONDS ]]; then
        log_debug "[CACHE] Cache expired (age: ${cache_age}s > ${CACHE_MAX_AGE_SECONDS}s)"
        return 1
    fi
    
    log_debug "[CACHE] Cache is valid"
    return 0
}

# Invalidate cache
invalidate_cache() {
    local reason="${1:-manual}"
    
    log_debug "[CACHE] Invalidating cache: $reason"
    
    # Clear cache data structures
    QUEUE_CACHE_DATA=()
    TASK_INDEX=()
    TASK_STATUS_COUNTS=()
    CACHE_STATS_JSON=""
    
    # Reset cache state
    QUEUE_CACHE_VALID=false
    QUEUE_CACHE_TIMESTAMP=0
    LAST_QUEUE_MTIME=0
    
    log_debug "[CACHE] Cache invalidated: $reason"
}

# ===============================================================================
# CACHE BUILDING AND REFRESH
# ===============================================================================

# Build cache from queue file using single-pass optimization
build_cache() {
    local queue_file="$1"
    
    log_debug "[CACHE] Building cache from: $queue_file"
    
    if [[ ! -f "$queue_file" ]]; then
        log_error "[CACHE] Queue file not found: $queue_file"
        return 1
    fi
    
    # Clear existing cache
    invalidate_cache "rebuild"
    
    # Single-pass JSON parsing to extract all needed data
    local cache_data
    cache_data=$(jq -r '
        .tasks | 
        to_entries | 
        map({
            index: .key,
            id: .value.id,
            status: .value.status,
            priority: (.value.priority // "normal"),
            created_at: .value.created_at,
            type: .value.type
        }) |
        {
            tasks: .,
            stats: (
                group_by(.status) | 
                map({
                    status: .[0].status,
                    count: length
                }) |
                reduce .[] as $item ({}; .[$item.status] = $item.count) |
                . + {total: (. | add // 0)}
            ),
            total_count: length
        }
    ' "$queue_file" 2>/dev/null) || {
        log_error "[CACHE] Failed to parse queue file: $queue_file"
        return 1
    }
    
    # Extract tasks into index structures
    local task_data
    task_data=$(echo "$cache_data" | jq -r '.tasks[]? | "\(.id)|\(.index)|\(.status)"')
    
    # Reset status counters
    TASK_STATUS_COUNTS=()
    
    # Build index and status counts
    while IFS='|' read -r task_id index status; do
        if [[ -n "$task_id" && -n "$index" && -n "$status" ]]; then
            TASK_INDEX["$task_id"]="$index"
            TASK_STATUS_COUNTS["$status"]=$((${TASK_STATUS_COUNTS["$status"]:-0} + 1))
        fi
    done <<< "$task_data"
    
    # Cache pre-computed stats JSON
    CACHE_STATS_JSON=$(echo "$cache_data" | jq -c '.stats')
    
    # Update cache metadata
    LAST_QUEUE_MTIME=$(stat -f %m "$queue_file" 2>/dev/null || echo 0)
    QUEUE_CACHE_TIMESTAMP=$(date +%s)
    QUEUE_CACHE_VALID=true
    
    local task_count=${#TASK_INDEX[@]}
    log_info "[CACHE] Cache built successfully: $task_count tasks indexed"
    
    return 0
}

# Refresh cache if needed
refresh_cache_if_needed() {
    local queue_file="$1"
    
    if is_cache_valid "$queue_file"; then
        log_debug "[CACHE] Using cached data"
        ((CACHE_HIT_COUNT++))
        return 0
    fi
    
    log_debug "[CACHE] Cache miss, rebuilding"
    ((CACHE_MISS_COUNT++))
    
    build_cache "$queue_file"
}

# ===============================================================================
# CACHED OPERATIONS
# ===============================================================================

# Get task by ID using cache
get_task_by_id_cached() {
    local queue_file="$1"
    local task_id="$2"
    
    # Ensure cache is fresh
    refresh_cache_if_needed "$queue_file" || return 1
    
    # Check if task exists in cache
    if [[ -z "${TASK_INDEX[$task_id]:-}" ]]; then
        log_debug "[CACHE] Task not found in cache: $task_id"
        return 1
    fi
    
    local task_index="${TASK_INDEX[$task_id]}"
    
    # Extract task from file using index
    jq -r ".tasks[$task_index]" "$queue_file" 2>/dev/null || {
        log_warn "[CACHE] Failed to extract task $task_id at index $task_index"
        return 1
    }
}

# Check if task exists using cache
task_exists_cached() {
    local queue_file="$1"
    local task_id="$2"
    
    # Ensure cache is fresh
    refresh_cache_if_needed "$queue_file" || return 1
    
    [[ -n "${TASK_INDEX[$task_id]:-}" ]]
}

# Get queue stats using cached data
get_queue_stats_cached() {
    local queue_file="$1"
    
    # Ensure cache is fresh
    refresh_cache_if_needed "$queue_file" || return 1
    
    # Return pre-computed stats JSON
    echo "$CACHE_STATS_JSON"
}

# Get tasks by status using cache
get_tasks_by_status_cached() {
    local queue_file="$1"
    local status_filter="$2"
    
    # Ensure cache is fresh
    refresh_cache_if_needed "$queue_file" || return 1
    
    if [[ "$status_filter" == "all" ]]; then
        jq '.tasks' "$queue_file"
    else
        # Use optimized single jq call with status filter
        jq --arg status "$status_filter" '[.tasks[] | select(.status == $status)]' "$queue_file"
    fi
}

# Get pending task count using cache
get_pending_count_cached() {
    local queue_file="$1"
    
    # Ensure cache is fresh
    refresh_cache_if_needed "$queue_file" || return 1
    
    echo "${TASK_STATUS_COUNTS[pending]:-0}"
}

# ===============================================================================
# BATCH OPERATIONS
# ===============================================================================

# Process multiple tasks efficiently
process_tasks_batch() {
    local queue_file="$1"
    local operation="$2"
    shift 2
    local task_ids=("$@")
    
    # Ensure cache is fresh
    refresh_cache_if_needed "$queue_file" || return 1
    
    if [[ ${#task_ids[@]} -eq 0 ]]; then
        log_debug "[CACHE] No task IDs provided for batch operation"
        return 0
    fi
    
    # Build jq filter for multiple task selection
    local filter_parts=()
    for task_id in "${task_ids[@]}"; do
        if [[ -n "${TASK_INDEX[$task_id]:-}" ]]; then
            filter_parts+=("\"$task_id\"")
        fi
    done
    
    if [[ ${#filter_parts[@]} -eq 0 ]]; then
        log_debug "[CACHE] No valid task IDs found in cache"
        return 1
    fi
    
    local filter=".tasks[] | select(.id | IN(${filter_parts[*]// /;}))"
    
    case "$operation" in
        "get")
            jq -c "$filter" "$queue_file"
            ;;
        "ids")
            jq -r "$filter | .id" "$queue_file"
            ;;
        "count")
            jq "$filter" "$queue_file" | jq -s 'length'
            ;;
        *)
            log_error "[CACHE] Unknown batch operation: $operation"
            return 1
            ;;
    esac
}

# ===============================================================================
# CACHE STATISTICS AND MONITORING
# ===============================================================================

# Get cache performance statistics
get_cache_stats() {
    local total_requests=$((CACHE_HIT_COUNT + CACHE_MISS_COUNT))
    local hit_rate=0
    
    if [[ $total_requests -gt 0 ]]; then
        hit_rate=$(( (CACHE_HIT_COUNT * 100) / total_requests ))
    fi
    
    jq -n \
        --arg version "$CACHE_VERSION" \
        --arg valid "$QUEUE_CACHE_VALID" \
        --arg timestamp "$QUEUE_CACHE_TIMESTAMP" \
        --arg mtime "$LAST_QUEUE_MTIME" \
        --argjson hits "$CACHE_HIT_COUNT" \
        --argjson misses "$CACHE_MISS_COUNT" \
        --argjson hit_rate "$hit_rate" \
        --argjson task_count "${#TASK_INDEX[@]}" \
        '{
            version: $version,
            valid: ($valid == "true"),
            timestamp: ($timestamp | tonumber),
            last_queue_mtime: ($mtime | tonumber),
            hits: $hits,
            misses: $misses,
            hit_rate_percent: $hit_rate,
            cached_tasks: $task_count
        }'
}

# Reset cache statistics
reset_cache_stats() {
    CACHE_HIT_COUNT=0
    CACHE_MISS_COUNT=0
    log_info "[CACHE] Cache statistics reset"
}

# ===============================================================================
# UTILITY FUNCTIONS
# ===============================================================================

# Load logging functions if available
if [[ -f "${SCRIPT_DIR:-}/utils/logging.sh" ]]; then
    source "${SCRIPT_DIR}/utils/logging.sh"
elif [[ -f "${CLAUDE_SRC_DIR:-}/utils/logging.sh" ]]; then
    source "${CLAUDE_SRC_DIR}/utils/logging.sh"
else
    # Fallback logging functions
    log_debug() { [[ "${DEBUG:-}" == "true" ]] && echo "[DEBUG] $*" >&2; }
    log_info() { echo "[INFO] $*" >&2; }
    log_warn() { echo "[WARN] $*" >&2; }
    log_error() { echo "[ERROR] $*" >&2; }
fi

# Initialize cache system on module load
init_cache_system