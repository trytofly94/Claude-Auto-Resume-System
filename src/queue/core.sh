#!/usr/bin/env bash

# Claude Auto-Resume - Task Queue Core Module
# Focused, lean core queue operations with reusable dynamic functions
# Version: 2.0.0-refactored

set -euo pipefail

# ===============================================================================
# CORE CONSTANTS AND GLOBALS
# ===============================================================================

# Task-Status-Konstanten (only declare if not already set)
if [[ -z "${TASK_STATE_PENDING:-}" ]]; then
    readonly TASK_STATE_PENDING="pending"
    readonly TASK_STATE_IN_PROGRESS="in_progress" 
    readonly TASK_STATE_COMPLETED="completed"
    readonly TASK_STATE_FAILED="failed"
    readonly TASK_STATE_TIMEOUT="timeout"
fi

# Task-Typ-Konstanten (only declare if not already set)
if [[ -z "${TASK_TYPE_GITHUB_ISSUE:-}" ]]; then
    readonly TASK_TYPE_GITHUB_ISSUE="github_issue"
    readonly TASK_TYPE_GITHUB_PR="github_pr"
    readonly TASK_TYPE_CUSTOM="custom"
    readonly TASK_TYPE_WORKFLOW="workflow"
fi

# Global state tracking (single source of truth)
# Only declare if not already declared to preserve existing state
if ! declare -p TASK_STATES &>/dev/null; then
    declare -gA TASK_STATES=()
fi
if ! declare -p TASK_METADATA &>/dev/null; then
    declare -gA TASK_METADATA=()
fi
if ! declare -p TASK_RETRY_COUNTS &>/dev/null; then
    declare -gA TASK_RETRY_COUNTS=()
fi
if ! declare -p TASK_TIMESTAMPS &>/dev/null; then
    declare -gA TASK_TIMESTAMPS=()
fi
if ! declare -p TASK_PRIORITIES &>/dev/null; then
    declare -gA TASK_PRIORITIES=()
fi

# ===============================================================================
# DYNAMIC REUSABLE FUNCTIONS
# ===============================================================================

# Dynamic function executor - reuse pattern across all modules
execute_with_context() {
    local operation="$1"
    local context="$2"
    shift 2
    local args=("$@")
    
    case "$operation" in
        "validate")
            validate_context "$context" "${args[@]}"
            ;;
        "transform")
            transform_data "$context" "${args[@]}"
            ;;
        "execute")
            execute_operation "$context" "${args[@]}"
            ;;
        *)
            log_error "Unknown operation: $operation"
            return 1
            ;;
    esac
}

# Generic validation function - reused across all operations
validate_context() {
    local context="$1"
    shift
    local args=("$@")
    
    case "$context" in
        "task_id")
            validate_task_id "${args[0]}"
            ;;
        "task_data")
            validate_task_structure "${args[0]}"
            ;;
        "queue_state")
            validate_queue_integrity
            ;;
        *)
            return 0
            ;;
    esac
}

# Generic data transformer - reused for different data formats
transform_data() {
    local format="$1"
    local data="$2"
    
    case "$format" in
        "json_to_internal")
            echo "$data" | jq -r '.'
            ;;
        "internal_to_json") 
            echo "$data" | jq -c '.'
            ;;
        "timestamp")
            date -d "$data" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S'
            ;;
        *)
            echo "$data"
            ;;
    esac
}

# ===============================================================================
# CORE QUEUE OPERATIONS
# ===============================================================================

# Generate unique task ID using dynamic approach
generate_task_id() {
    local prefix="${1:-task}"
    local timestamp=$(date +%s)
    local random=$(( RANDOM % 10000 ))
    echo "${prefix}-${timestamp}-${random}"
}

# Validate task ID format using dynamic validation
validate_task_id() {
    local task_id="$1"
    
    if [[ -z "$task_id" ]]; then
        log_error "Task ID cannot be empty"
        return 1
    fi
    
    if [[ ! "$task_id" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "Invalid task ID format: $task_id"
        return 1
    fi
    
    return 0
}

# Validate task data structure using dynamic validation
validate_task_structure() {
    local task_json="$1"
    
    local required_fields=("id" "type" "status" "created_at")
    
    for field in "${required_fields[@]}"; do
        if ! echo "$task_json" | jq -e ".$field" >/dev/null 2>&1; then
            log_error "Missing required field: $field"
            return 1
        fi
    done
    
    return 0
}

# Add task to queue using dynamic execution pattern
add_task() {
    local task_data="$1"
    local task_id
    
    log_debug "add_task called with data: $(echo "$task_data" | head -c 100)..."
    
    # Dynamic validation
    execute_with_context "validate" "task_data" "$task_data" || return 1
    
    task_id=$(echo "$task_data" | jq -r '.id')
    log_debug "Extracted task_id: $task_id"
    
    # Check if task already exists
    if task_exists "$task_id"; then
        log_warn "Task $task_id already exists, updating instead"
        update_task "$task_id" "$task_data"
        return $?
    fi
    
    # Add to global state
    TASK_STATES["$task_id"]=$(echo "$task_data" | jq -r '.status')
    TASK_METADATA["$task_id"]="$task_data"
    TASK_RETRY_COUNTS["$task_id"]="0"
    TASK_TIMESTAMPS["$task_id"]=$(date +%s)
    TASK_PRIORITIES["$task_id"]=$(echo "$task_data" | jq -r '.priority // "normal"')
    
    log_info "Added task: $task_id"
    log_debug "Global state now has ${#TASK_STATES[@]} tasks in TASK_STATES and ${#TASK_METADATA[@]} in TASK_METADATA"
    return 0
}

# Remove task using dynamic pattern
remove_task() {
    local task_id="$1"
    
    execute_with_context "validate" "task_id" "$task_id" || return 1
    
    if ! task_exists "$task_id"; then
        log_warn "Task $task_id does not exist"
        return 1
    fi
    
    # Remove from all global state arrays
    unset TASK_STATES["$task_id"]
    unset TASK_METADATA["$task_id"] 
    unset TASK_RETRY_COUNTS["$task_id"]
    unset TASK_TIMESTAMPS["$task_id"]
    unset TASK_PRIORITIES["$task_id"]
    
    log_info "Removed task: $task_id"
    return 0
}

# Update task status using dynamic approach
update_task_status() {
    local task_id="$1"
    local new_status="$2"
    
    execute_with_context "validate" "task_id" "$task_id" || return 1
    
    if ! task_exists "$task_id"; then
        log_error "Task $task_id does not exist"
        return 1
    fi
    
    # Update status in metadata and state
    local current_data="${TASK_METADATA[$task_id]}"
    local updated_data=$(echo "$current_data" | jq --arg status "$new_status" '.status = $status | .updated_at = now')
    
    TASK_STATES["$task_id"]="$new_status"
    TASK_METADATA["$task_id"]="$updated_data"
    
    log_info "Updated task $task_id status: $new_status"
    return 0
}

# Get next pending task using dynamic approach
get_next_task() {
    local filter_type="${1:-all}"
    
    for task_id in "${!TASK_STATES[@]}"; do
        local status="${TASK_STATES[$task_id]}"
        
        if [[ "$status" == "$TASK_STATE_PENDING" ]]; then
            case "$filter_type" in
                "high_priority")
                    if [[ "${TASK_PRIORITIES[$task_id]}" == "high" ]]; then
                        echo "$task_id"
                        return 0
                    fi
                    ;;
                "all"|*)
                    echo "$task_id"
                    return 0
                    ;;
            esac
        fi
    done
    
    return 1
}

# Check if task exists
task_exists() {
    local task_id="$1"
    [[ -n "${TASK_STATES[$task_id]:-}" ]]
}

# Get task data using dynamic transformation
get_task() {
    local task_id="$1"
    local format="${2:-json}"
    
    if ! task_exists "$task_id"; then
        return 1
    fi
    
    local task_data="${TASK_METADATA[$task_id]}"
    transform_data "internal_to_$format" "$task_data"
}

# List tasks with optional filtering
list_tasks() {
    local status_filter="${1:-all}"
    local format="${2:-json}"
    
    local tasks_json="[]"
    
    for task_id in "${!TASK_STATES[@]}"; do
        local status="${TASK_STATES[$task_id]}"
        
        if [[ "$status_filter" == "all" ]] || [[ "$status" == "$status_filter" ]]; then
            local task_data="${TASK_METADATA[$task_id]}"
            tasks_json=$(echo "$tasks_json" | jq --argjson task "$task_data" '. += [$task]')
        fi
    done
    
    case "$format" in
        "json")
            echo "$tasks_json"
            ;;
        "count")
            echo "$tasks_json" | jq length
            ;;
        "ids")
            echo "$tasks_json" | jq -r '.[].id'
            ;;
    esac
}

# Get queue statistics using dynamic aggregation
get_queue_stats() {
    local stats_json='{
        "total": 0,
        "pending": 0,
        "in_progress": 0,
        "completed": 0,
        "failed": 0,
        "timeout": 0
    }'
    
    for status in "${TASK_STATES[@]}"; do
        stats_json=$(echo "$stats_json" | jq --arg status "$status" '.total += 1 | .[$status] += 1')
    done
    
    echo "$stats_json"
}

# Validate queue integrity using dynamic validation
validate_queue_integrity() {
    local errors=()
    
    # Check for orphaned entries
    for task_id in "${!TASK_STATES[@]}"; do
        if [[ -z "${TASK_METADATA[$task_id]:-}" ]]; then
            errors+=("Task $task_id has state but no metadata")
        fi
    done
    
    for task_id in "${!TASK_METADATA[@]}"; do
        if [[ -z "${TASK_STATES[$task_id]:-}" ]]; then
            errors+=("Task $task_id has metadata but no state")
        fi
    done
    
    if [[ ${#errors[@]} -gt 0 ]]; then
        log_error "Queue integrity issues found:"
        printf '%s\n' "${errors[@]}"
        return 1
    fi
    
    log_info "Queue integrity validated successfully"
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