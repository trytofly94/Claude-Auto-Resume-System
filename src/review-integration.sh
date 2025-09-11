#!/usr/bin/env bash

# Claude Auto-Resume - Review Integration Module
# Integrates PR review functionality with the existing task queue workflow system
# Handles review command execution within the monitoring infrastructure

set -euo pipefail

# ===============================================================================
# CONFIGURATION & IMPORTS
# ===============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load existing infrastructure
if [[ -f "$SCRIPT_DIR/utils/logging.sh" ]]; then
    source "$SCRIPT_DIR/utils/logging.sh"
else
    log_info() { echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S'): $*"; }
    log_warn() { echo "[WARN] $(date '+%Y-%m-%d %H:%M:%S'): $*" >&2; }
    log_error() { echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S'): $*" >&2; }
fi

# ===============================================================================
# WORKFLOW INTEGRATION FUNCTIONS
# ===============================================================================

execute_review_workflow() {
    local pr_identifier="$1"
    shift
    local additional_args=("$@")
    
    log_info "Executing review workflow for: $pr_identifier"
    
    # Validate review script exists
    if [[ ! -x "$SCRIPT_DIR/pr-review.sh" ]]; then
        log_error "PR review script not found or not executable: $SCRIPT_DIR/pr-review.sh"
        return 1
    fi
    
    # Execute review with proper error handling
    local scratchpad_path=""
    local review_exit_code=0
    
    if scratchpad_path=$("$SCRIPT_DIR/pr-review.sh" "$pr_identifier" "${additional_args[@]}" 2>&1); then
        log_info "Review completed successfully"
        log_info "Scratchpad created: $scratchpad_path"
        
        # Extract just the path from any multi-line output
        scratchpad_path=$(echo "$scratchpad_path" | grep "scratchpads/active" | tail -n1 | tr -d '[:space:]')
        
        # Verify scratchpad was created
        if [[ -f "$scratchpad_path" ]]; then
            log_info "Review scratchpad verified: $(basename "$scratchpad_path")"
            echo "REVIEW_SUCCESS:$scratchpad_path"
        else
            log_warn "Review completed but scratchpad not found: $scratchpad_path"
            echo "REVIEW_PARTIAL_SUCCESS:$scratchpad_path"
        fi
    else
        review_exit_code=$?
        log_error "Review failed with exit code: $review_exit_code"
        log_error "Output: $scratchpad_path"
        echo "REVIEW_FAILED:exit_code_$review_exit_code"
        return $review_exit_code
    fi
}

handle_workflow_review_command() {
    local workflow_command="$1"
    
    log_info "Processing workflow review command: $workflow_command"
    
    # Parse review command (e.g., "/review PR-106", "/review issue-94")
    if [[ "$workflow_command" =~ ^/review[[:space:]]+(.+)$ ]]; then
        local review_target="${BASH_REMATCH[1]}"
        
        # Execute review in workflow context
        execute_review_workflow "$review_target" --quick
    else
        log_error "Invalid review command format: $workflow_command"
        echo "REVIEW_FAILED:invalid_command_format"
        return 1
    fi
}

# ===============================================================================
# TASK QUEUE INTEGRATION
# ===============================================================================

add_review_to_queue() {
    local pr_identifier="$1"
    local priority="${2:-normal}"
    
    log_info "Adding review task to queue: $pr_identifier"
    
    if [[ -x "$SCRIPT_DIR/task-queue.sh" ]]; then
        local review_command="./src/review-integration.sh execute_review '$pr_identifier'"
        local description="Review PR/Issue: $pr_identifier"
        
        "$SCRIPT_DIR/task-queue.sh" add-custom "$description" \
            --command "$review_command" \
            --priority "$priority" \
            --timeout 1800 \
            --completion-marker "REVIEW_SUCCESS"
        
        log_info "Review task added to queue successfully"
    else
        log_error "Task queue not available for review integration"
        return 1
    fi
}

# ===============================================================================
# COMMAND LINE INTERFACE
# ===============================================================================

show_integration_usage() {
    cat << EOF
Usage: $0 COMMAND [OPTIONS]

COMMANDS:
    execute_review PR_ID [OPTIONS]    Execute review workflow for PR/Issue
    handle_workflow CMD               Handle workflow review command  
    add_to_queue PR_ID [PRIORITY]     Add review to task queue
    
INTEGRATION EXAMPLES:
    # Direct execution
    $0 execute_review PR-106
    
    # Workflow integration (called by task queue)
    $0 handle_workflow "/review PR-106"
    
    # Queue integration  
    $0 add_to_queue issue-94 high

WORKFLOW INTEGRATION:
    This module integrates PR reviews with the existing monitoring
    and task queue infrastructure for automated agent workflows.
EOF
}

main() {
    local command="${1:-}"
    
    case "$command" in
        execute_review)
            if [[ $# -lt 2 ]]; then
                log_error "execute_review requires PR identifier"
                show_integration_usage
                exit 1
            fi
            execute_review_workflow "${@:2}"
            ;;
        handle_workflow)
            if [[ $# -ne 2 ]]; then
                log_error "handle_workflow requires workflow command"
                show_integration_usage
                exit 1
            fi
            handle_workflow_review_command "$2"
            ;;
        add_to_queue)
            if [[ $# -lt 2 ]]; then
                log_error "add_to_queue requires PR identifier"
                show_integration_usage
                exit 1
            fi
            add_review_to_queue "$2" "${3:-normal}"
            ;;
        --help|help|"")
            show_integration_usage
            ;;
        *)
            log_error "Unknown command: $command"
            show_integration_usage
            exit 1
            ;;
    esac
}

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi