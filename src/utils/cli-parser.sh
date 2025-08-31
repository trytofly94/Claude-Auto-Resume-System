#!/usr/bin/env bash

# Claude Auto-Resume - CLI Parser Module
# Command-line argument parsing for context clearing features (Issue #93)
# Version: 1.0.0

set -euo pipefail

# ===============================================================================
# CLI PARSING FUNCTIONS
# ===============================================================================

# Parse context clearing flags from command line arguments
# Returns: JSON object with clear_context preference or null if not specified
parse_context_flags() {
    local args=("$@")
    local clear_context=null
    local remaining_args=()
    
    for arg in "${args[@]}"; do
        case "$arg" in
            --clear-context)
                clear_context=true
                ;;
            --no-clear-context)
                clear_context=false
                ;;
            *)
                remaining_args+=("$arg")
                ;;
        esac
    done
    
    # Output results in JSON format for easy parsing
    local result='{"clear_context": '${clear_context}', "remaining_args": []}'
    
    # Add remaining args to JSON
    for remaining_arg in "${remaining_args[@]}"; do
        result=$(echo "$result" | jq --arg arg "$remaining_arg" '.remaining_args += [$arg]')
    done
    
    echo "$result"
}

# Enhanced task creation with context clearing support
create_task_with_context_options() {
    local task_type="$1"
    local description="$2"
    shift 2
    local additional_args=("$@")
    
    # Parse CLI flags
    local parse_result
    parse_result=$(parse_context_flags "${additional_args[@]}")
    local clear_context=$(echo "$parse_result" | jq -r '.clear_context')
    
    # Generate basic task JSON
    local task_id
    task_id=$(generate_task_id "$task_type")
    
    local task_json='{
        "id": "'$task_id'",
        "type": "'$task_type'",
        "description": "'$description'",
        "status": "pending",
        "created_at": "'$(date -Iseconds)'",
        "priority": "normal"
    }'
    
    # Add clear_context field if explicitly set
    if [[ "$clear_context" != "null" ]]; then
        task_json=$(echo "$task_json" | jq --argjson clear "$clear_context" '.clear_context = $clear')
    fi
    
    echo "$task_json"
}

# Show help for context clearing options
show_context_clearing_help() {
    cat << 'EOF'

Context Clearing Options (Issue #93):
  --clear-context       Force context clearing after this task completes
  --no-clear-context    Preserve context after this task completes (useful for related tasks)

Examples:
  # Single task with fresh context (default behavior)
  ./src/task-queue.sh add-custom "Fix login bug"
  
  # Related tasks preserving context flow
  ./src/task-queue.sh add-custom "Design user model" --no-clear-context
  ./src/task-queue.sh add-custom "Implement user model" --no-clear-context  
  ./src/task-queue.sh add-custom "Test user model" --clear-context
  
  # Explicitly clear context (override global config if disabled)
  ./src/task-queue.sh add-custom "Add feature X" --clear-context

Configuration:
  Set QUEUE_SESSION_CLEAR_BETWEEN_TASKS=false in config/default.conf to disable
  automatic context clearing globally while still allowing per-task overrides.

EOF
}

# ===============================================================================
# ENHANCED COMMAND FUNCTIONS
# ===============================================================================

# Enhanced add-custom command with context clearing support
cmd_add_custom_with_context() {
    local description="${1:-}"
    shift || true
    local additional_args=("$@")
    
    if [[ -z "$description" ]]; then
        echo "Usage: $0 add-custom \"<description>\" [--clear-context|--no-clear-context]"
        echo ""
        show_context_clearing_help
        return 1
    fi
    
    local task_json
    task_json=$(create_task_with_context_options "custom" "$description" "${additional_args[@]}")
    
    if add_task "$task_json"; then
        local task_id=$(echo "$task_json" | jq -r '.id')
        local clear_context=$(echo "$task_json" | jq -r '.clear_context // null')
        
        echo "Custom task added: $task_id"
        echo "Description: $description"
        if [[ "$clear_context" == "null" ]]; then
            echo "Context clearing: default (${QUEUE_SESSION_CLEAR_BETWEEN_TASKS:-true})"
        else
            echo "Context clearing: $clear_context"
        fi
        
        save_queue_state false
        return 0
    else
        echo "Failed to add custom task" >&2
        return 1
    fi
}

# Enhanced GitHub issue command with context clearing support
cmd_add_github_issue_with_context() {
    local issue_number="${1:-}"
    shift || true
    local additional_args=("$@")
    
    if [[ -z "$issue_number" ]]; then
        echo "Usage: $0 add-issue <issue_number> [--clear-context|--no-clear-context]"
        echo ""
        show_context_clearing_help
        return 1
    fi
    
    # Validate issue number
    if ! [[ "$issue_number" =~ ^[0-9]+$ ]]; then
        echo "Error: Issue number must be a positive integer" >&2
        return 1
    fi
    
    local description="GitHub Issue #${issue_number}"
    local task_json
    task_json=$(create_task_with_context_options "github_issue" "$description" "${additional_args[@]}")
    
    # Add issue-specific fields
    task_json=$(echo "$task_json" | jq --argjson issue "$issue_number" '.issue_number = $issue')
    
    if add_task "$task_json"; then
        local task_id=$(echo "$task_json" | jq -r '.id')
        local clear_context=$(echo "$task_json" | jq -r '.clear_context // null')
        
        echo "GitHub issue task added: $task_id"
        echo "Issue: #$issue_number"
        if [[ "$clear_context" == "null" ]]; then
            echo "Context clearing: default (${QUEUE_SESSION_CLEAR_BETWEEN_TASKS:-true})"
        else
            echo "Context clearing: $clear_context"
        fi
        
        save_queue_state false
        return 0
    else
        echo "Failed to add GitHub issue task" >&2
        return 1
    fi
}

# Check if this script is being run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Load core functions if run directly
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$SCRIPT_DIR/../queue/core.sh" 2>/dev/null || true
    
    case "${1:-help}" in
        test-parse)
            shift
            parse_context_flags "$@"
            ;;
        test-create)
            shift
            create_task_with_context_options "custom" "Test task" "$@"
            ;;
        help|*)
            show_context_clearing_help
            ;;
    esac
fi