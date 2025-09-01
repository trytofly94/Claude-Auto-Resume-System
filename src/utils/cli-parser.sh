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

# Parse completion marker flags from command line arguments  
# Returns: JSON object with completion marker and patterns
parse_completion_flags() {
    local args=("$@")
    local completion_marker=null
    local completion_patterns=null
    local custom_timeout=null
    local remaining_args=()
    
    local i=0
    while (( i < ${#args[@]} )); do
        case "${args[i]}" in
            --completion-marker)
                if (( i + 1 < ${#args[@]} )); then
                    completion_marker="${args[i+1]}"
                    ((i++))
                else
                    echo "Error: --completion-marker requires a value" >&2
                    return 1
                fi
                ;;
            --completion-pattern)
                if (( i + 1 < ${#args[@]} )); then
                    if [[ "$completion_patterns" == "null" ]]; then
                        completion_patterns="[\"${args[i+1]}\"]"
                    else
                        completion_patterns=$(echo "$completion_patterns" | jq '. + ["'"${args[i+1]}"'"]')
                    fi
                    ((i++))
                else
                    echo "Error: --completion-pattern requires a value" >&2
                    return 1
                fi
                ;;
            --completion-timeout)
                if (( i + 1 < ${#args[@]} )); then
                    if [[ "${args[i+1]}" =~ ^[0-9]+$ ]]; then
                        custom_timeout="${args[i+1]}"
                        ((i++))
                    else
                        echo "Error: --completion-timeout requires a numeric value" >&2
                        return 1
                    fi
                else
                    echo "Error: --completion-timeout requires a value" >&2
                    return 1
                fi
                ;;
            *)
                remaining_args+=("${args[i]}")
                ;;
        esac
        ((i++))
    done
    
    # Build result JSON safely
    local result='{"completion_marker": null, "completion_patterns": null, "custom_timeout": null, "remaining_args": []}'
    
    if [[ "$completion_marker" != "null" ]]; then
        result=$(echo "$result" | jq --arg marker "$completion_marker" '.completion_marker = $marker')
    fi
    
    if [[ "$completion_patterns" != "null" ]]; then
        result=$(echo "$result" | jq --argjson patterns "$completion_patterns" '.completion_patterns = $patterns')
    fi
    
    if [[ "$custom_timeout" != "null" ]]; then
        result=$(echo "$result" | jq --argjson timeout "$custom_timeout" '.custom_timeout = $timeout')
    fi
    
    # Add remaining args to JSON
    for remaining_arg in "${remaining_args[@]}"; do
        result=$(echo "$result" | jq --arg arg "$remaining_arg" '.remaining_args += [$arg]')
    done
    
    echo "$result"
}

# Enhanced flag parser that handles both context and completion flags
parse_enhanced_flags() {
    local args=("$@")
    
    # Parse completion flags first
    local completion_result
    completion_result=$(parse_completion_flags "${args[@]}")
    local remaining_after_completion
    
    # Get remaining args from completion parsing as array
    local remaining_args=()
    while IFS= read -r arg; do
        [[ -n "$arg" ]] && remaining_args+=("$arg")
    done < <(echo "$completion_result" | jq -r '.remaining_args[]')
    
    # Parse context flags from remaining args
    local context_result
    if (( ${#remaining_args[@]} > 0 )); then
        context_result=$(parse_context_flags "${remaining_args[@]}")
    else
        context_result=$(parse_context_flags)
    fi
    
    # Combine results
    local combined_result
    combined_result=$(echo "$completion_result" | jq --argjson context "$context_result" '
        .clear_context = $context.clear_context |
        .final_remaining_args = $context.remaining_args
    ')
    
    echo "$combined_result"
}

# Enhanced task creation with context clearing support
create_task_with_context_options() {
    local task_type="$1"
    local description="$2"
    shift 2
    local additional_args=("$@")
    
    # Parse CLI flags (enhanced to support completion markers)
    local parse_result
    parse_result=$(parse_enhanced_flags "${additional_args[@]}")
    local clear_context=$(echo "$parse_result" | jq -r '.clear_context')
    local completion_marker=$(echo "$parse_result" | jq -r '.completion_marker')
    local completion_patterns=$(echo "$parse_result" | jq -r '.completion_patterns')
    local custom_timeout=$(echo "$parse_result" | jq -r '.custom_timeout')
    
    # Generate completion marker if not provided but smart completion is enabled
    if [[ "$completion_marker" == "null" && "${SMART_COMPLETION_ENABLED:-true}" == "true" ]]; then
        # Load completion prompts module if available
        if command -v generate_completion_marker >/dev/null 2>&1; then
            completion_marker="\"$(generate_completion_marker "$description" "$task_type")\""
        fi
    fi
    
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
    
    # Add completion marker if available
    if [[ "$completion_marker" != "null" ]]; then
        task_json=$(echo "$task_json" | jq --arg marker "$completion_marker" '.completion_marker = $marker')
    fi
    
    # Add completion patterns if available
    if [[ "$completion_patterns" != "null" ]]; then
        task_json=$(echo "$task_json" | jq --argjson patterns "$completion_patterns" '.completion_patterns = $patterns')
    fi
    
    # Add custom timeout if specified
    if [[ "$custom_timeout" != "null" ]]; then
        task_json=$(echo "$task_json" | jq --argjson timeout "$custom_timeout" '.custom_timeout = $timeout')
    fi
    
    echo "$task_json"
}

# Show help for context clearing options
show_context_clearing_help() {
    cat << 'EOF'

Context Clearing Options (Issue #93):
  --clear-context       Force context clearing after this task completes
  --no-clear-context    Preserve context after this task completes (useful for related tasks)

Smart Completion Detection Options (Issue #90):
  --completion-marker <marker>      Custom completion marker for this task
  --completion-pattern <pattern>    Custom completion pattern (can be used multiple times)
  --completion-timeout <seconds>    Custom timeout for this task

Examples:
  # Single task with fresh context (default behavior)
  ./src/task-queue.sh add-custom "Fix login bug"
  
  # Related tasks preserving context flow
  ./src/task-queue.sh add-custom "Design user model" --no-clear-context
  ./src/task-queue.sh add-custom "Implement user model" --no-clear-context  
  ./src/task-queue.sh add-custom "Test user model" --clear-context
  
  # Smart completion with custom markers
  ./src/task-queue.sh add-custom "Deploy to prod" --completion-marker "DEPLOY_COMPLETE"
  ./src/task-queue.sh add-custom "Review code" --completion-pattern "Code review finished" --completion-timeout 600
  
  # Explicitly clear context (override global config if disabled)
  ./src/task-queue.sh add-custom "Add feature X" --clear-context

Configuration:
  Set QUEUE_SESSION_CLEAR_BETWEEN_TASKS=false in config/default.conf to disable
  automatic context clearing globally while still allowing per-task overrides.
  Set SMART_COMPLETION_ENABLED=false to disable automatic completion marker generation.

EOF
}

# Generate unique task ID
generate_task_id() {
    local prefix="${1:-task}"
    local timestamp
    local random
    timestamp=$(date +%s)
    random=$(( RANDOM % 9999 ))
    
    printf "%s-%s-%04d" "$prefix" "$timestamp" "$random"
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
        echo "Usage: $0 add-custom \"<description>\" [OPTIONS]"
        echo ""
        show_context_clearing_help
        return 1
    fi
    
    local task_json
    task_json=$(create_task_with_context_options "custom" "$description" "${additional_args[@]}")
    
    if add_task "$task_json"; then
        local task_id=$(echo "$task_json" | jq -r '.id')
        local clear_context=$(echo "$task_json" | jq -r '.clear_context // null')
        local completion_marker=$(echo "$task_json" | jq -r '.completion_marker // null')
        local completion_patterns=$(echo "$task_json" | jq -r '.completion_patterns // null')
        local custom_timeout=$(echo "$task_json" | jq -r '.custom_timeout // null')
        
        echo "Custom task added: $task_id"
        echo "Description: $description"
        if [[ "$clear_context" == "null" ]]; then
            echo "Context clearing: default (${QUEUE_SESSION_CLEAR_BETWEEN_TASKS:-true})"
        else
            echo "Context clearing: $clear_context"
        fi
        
        # Show smart completion info if enabled
        if [[ "${SMART_COMPLETION_ENABLED:-true}" == "true" ]]; then
            if [[ "$completion_marker" != "null" ]]; then
                echo "Completion marker: $completion_marker"
            fi
            if [[ "$completion_patterns" != "null" ]]; then
                echo "Custom patterns: $(echo "$completion_patterns" | jq -r '. | length') pattern(s)"
            fi
            if [[ "$custom_timeout" != "null" ]]; then
                echo "Custom timeout: ${custom_timeout}s"
            fi
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