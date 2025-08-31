#!/usr/bin/env bash

# Claude Auto-Resume - Task Queue Workflow Module  
# Issue-Merge workflow automation and other workflow types
# Version: 2.0.0-refactored

set -euo pipefail

# ===============================================================================
# WORKFLOW CONSTANTS
# ===============================================================================

# Workflow types (only declare if not already set)
if [[ -z "${WORKFLOW_TYPE_ISSUE_MERGE:-}" ]]; then
    readonly WORKFLOW_TYPE_ISSUE_MERGE="issue-merge"
    readonly WORKFLOW_TYPE_CUSTOM="custom"
fi

# Workflow statuses (only declare if not already set)
if [[ -z "${WORKFLOW_STATUS_PENDING:-}" ]]; then
    readonly WORKFLOW_STATUS_PENDING="pending"
    readonly WORKFLOW_STATUS_IN_PROGRESS="in_progress"
    readonly WORKFLOW_STATUS_COMPLETED="completed"
    readonly WORKFLOW_STATUS_FAILED="failed"
    readonly WORKFLOW_STATUS_PAUSED="paused"
fi

# Issue-merge workflow steps (only declare if not already set)
if [[ -z "${STEP_DEVELOP:-}" ]]; then
    readonly STEP_DEVELOP="develop"
    readonly STEP_CLEAR="clear"
    readonly STEP_REVIEW="review"
    readonly STEP_MERGE="merge"
fi

# ===============================================================================
# WORKFLOW CORE FUNCTIONS
# ===============================================================================

# Create a new workflow task
create_workflow_task() {
    local workflow_type="$1"
    local workflow_config="$2"  # JSON configuration
    
    log_info "[WORKFLOW] Creating new workflow of type: $workflow_type"
    log_debug "[WORKFLOW] Workflow config: $workflow_config"
    
    local workflow_id
    workflow_id=$(generate_task_id "workflow")
    
    log_debug "[WORKFLOW] Generated workflow ID: $workflow_id"
    
    local workflow_data
    workflow_data=$(jq -n \
        --arg id "$workflow_id" \
        --arg type "workflow" \
        --arg workflow_type "$workflow_type" \
        --arg status "$WORKFLOW_STATUS_PENDING" \
        --arg created_at "$(date -Iseconds)" \
        --argjson config "$workflow_config" \
        '{
            id: $id,
            type: $type,
            workflow_type: $workflow_type,
            status: $status,
            created_at: $created_at,
            updated_at: $created_at,
            config: $config,
            current_step: 0,
            steps: [],
            results: {},
            error_history: [],
            checkpoints: []
        }')
    
    # Initialize workflow-specific steps
    case "$workflow_type" in
        "$WORKFLOW_TYPE_ISSUE_MERGE")
            log_debug "[WORKFLOW] Initializing issue-merge workflow steps"
            workflow_data=$(initialize_issue_merge_workflow "$workflow_data" "$workflow_config")
            ;;
        "$WORKFLOW_TYPE_CUSTOM")
            log_debug "[WORKFLOW] Initializing custom workflow steps"
            workflow_data=$(initialize_custom_workflow "$workflow_data" "$workflow_config")
            ;;
        *)
            log_error "[WORKFLOW] Unknown workflow type: $workflow_type"
            return 1
            ;;
    esac
    
    # Add to queue
    if add_task "$workflow_data"; then
        local total_steps
        total_steps=$(echo "$workflow_data" | jq '.steps | length')
        log_info "[WORKFLOW] Created workflow task successfully: $workflow_id ($workflow_type) with $total_steps steps"
        
        # Log workflow details for debugging
        log_debug "[WORKFLOW] Workflow details:"
        echo "$workflow_data" | jq '.steps[] | {phase: .phase, command: .command}' | while read -r step; do
            log_debug "[WORKFLOW]   Step: $step"
        done
        
        echo "$workflow_id"
        return 0
    else
        log_error "[WORKFLOW] Failed to create workflow task: $workflow_id"
        log_error "[WORKFLOW] Failed workflow data was: $(echo "$workflow_data" | jq -c .)"
        return 1
    fi
}

# Execute a workflow task
execute_workflow_task() {
    local workflow_id="$1"
    
    log_info "[WORKFLOW] Starting execution of workflow: $workflow_id"
    
    if ! task_exists "$workflow_id"; then
        log_error "[WORKFLOW] Workflow task not found: $workflow_id"
        return 1
    fi
    
    local workflow_data
    workflow_data=$(get_task "$workflow_id" "json")
    
    local workflow_type
    workflow_type=$(echo "$workflow_data" | jq -r '.workflow_type')
    
    local current_step
    current_step=$(echo "$workflow_data" | jq -r '.current_step')
    
    local total_steps
    total_steps=$(echo "$workflow_data" | jq '.steps | length')
    
    log_info "[WORKFLOW] Executing $workflow_type workflow (steps: $current_step/$total_steps)"
    
    # Create automatic checkpoint before execution
    create_workflow_checkpoint "$workflow_id" "pre_execution"
    
    # Update status to in_progress
    update_task_status "$workflow_id" "$WORKFLOW_STATUS_IN_PROGRESS"
    
    # Log system environment for debugging
    log_debug "[WORKFLOW] System environment:"
    log_debug "[WORKFLOW]   USE_CLAUNCH: ${USE_CLAUNCH:-not_set}"
    log_debug "[WORKFLOW]   CLAUNCH_MODE: ${CLAUNCH_MODE:-not_set}"
    log_debug "[WORKFLOW]   TMUX_SESSION_NAME: ${TMUX_SESSION_NAME:-not_set}"
    
    local execution_result
    case "$workflow_type" in
        "$WORKFLOW_TYPE_ISSUE_MERGE")
            log_info "[WORKFLOW] Starting issue-merge workflow execution with recovery"
            execute_issue_merge_workflow_with_recovery "$workflow_id"
            execution_result=$?
            ;;
        "$WORKFLOW_TYPE_CUSTOM")
            log_info "[WORKFLOW] Starting custom workflow execution"
            execute_custom_workflow "$workflow_id"
            execution_result=$?
            ;;
        *)
            log_error "[WORKFLOW] Cannot execute unknown workflow type: $workflow_type"
            update_task_status "$workflow_id" "$WORKFLOW_STATUS_FAILED"
            return 1
            ;;
    esac
    
    # Log final result
    if [[ $execution_result -eq 0 ]]; then
        log_info "[WORKFLOW] Workflow execution completed successfully: $workflow_id"
    else
        log_error "[WORKFLOW] Workflow execution failed: $workflow_id (exit code: $execution_result)"
    fi
    
    return $execution_result
}

# ===============================================================================
# ISSUE-MERGE WORKFLOW IMPLEMENTATION
# ===============================================================================

# Initialize issue-merge workflow with steps
initialize_issue_merge_workflow() {
    local workflow_data="$1"
    local config="$2"
    
    local issue_id
    issue_id=$(echo "$config" | jq -r '.issue_id')
    
    if [[ -z "$issue_id" ]] || [[ "$issue_id" == "null" ]]; then
        log_error "Issue ID is required for issue-merge workflow"
        return 1
    fi
    
    # Define workflow steps using jq to build JSON properly
    local steps
    steps=$(jq -n \
        --arg issue_id "$issue_id" \
        '[
            {
                "phase": "develop",
                "status": "pending", 
                "command": ("/dev " + $issue_id),
                "description": ("Develop feature for issue " + $issue_id)
            },
            {
                "phase": "clear",
                "status": "pending",
                "command": "/clear",
                "description": "Clear context for clean review"
            },
            {
                "phase": "review", 
                "status": "pending",
                "command": ("/review PR-" + $issue_id),
                "description": ("Review PR for issue " + $issue_id)
            },
            {
                "phase": "merge",
                "status": "pending",
                "command": ("/dev merge-pr " + $issue_id + " --focus-main"),
                "description": "Merge PR with main functionality focus"
            }
        ]')
    
    echo "$workflow_data" | jq \
        --argjson steps "$steps" \
        --arg issue_id "$issue_id" \
        '.steps = $steps | .config.issue_id = $issue_id'
}

# Execute issue-merge workflow
execute_issue_merge_workflow() {
    local workflow_id="$1"
    
    log_info "Starting issue-merge workflow execution: $workflow_id"
    
    local workflow_data
    workflow_data=$(get_task "$workflow_id" "json")
    
    local current_step
    current_step=$(echo "$workflow_data" | jq -r '.current_step')
    
    local steps
    steps=$(echo "$workflow_data" | jq -r '.steps')
    
    local total_steps
    total_steps=$(echo "$steps" | jq length)
    
    # Execute steps sequentially
    for ((step_index=current_step; step_index<total_steps; step_index++)); do
        local step_data
        step_data=$(echo "$steps" | jq ".[$step_index]")
        
        local phase
        phase=$(echo "$step_data" | jq -r '.phase')
        
        local command
        command=$(echo "$step_data" | jq -r '.command')
        
        local description
        description=$(echo "$step_data" | jq -r '.description')
        
        log_info "Executing workflow step $((step_index + 1))/$total_steps: $phase"
        log_info "Description: $description"
        log_info "Command: $command"
        
        # Update current step and step status
        workflow_data=$(echo "$workflow_data" | jq \
            --arg step_index "$step_index" \
            --arg status "in_progress" \
            '.current_step = ($step_index | tonumber) | .steps[' "$step_index" '].status = $status')
        
        update_workflow_data "$workflow_id" "$workflow_data"
        
        # Execute the step with context
        local issue_id
        issue_id=$(echo "$workflow_data" | jq -r '.config.issue_id // ""')
        
        local step_result
        if execute_workflow_step "$command" "$phase" "$issue_id"; then
            step_result="success"
            
            # Mark step as completed
            workflow_data=$(echo "$workflow_data" | jq \
                --arg completed_at "$(date -Iseconds)" \
                '.steps['"$step_index"'].status = "completed" | .steps['"$step_index"'].completed_at = $completed_at')
            
            log_info "Workflow step completed: $phase"
        else
            step_result="failed"
            
            # Mark step as failed
            workflow_data=$(echo "$workflow_data" | jq \
                --arg failed_at "$(date -Iseconds)" \
                '.steps['"$step_index"'].status = "failed" | .steps['"$step_index"'].failed_at = $failed_at')
            
            log_error "Workflow step failed: $phase"
            
            # Update workflow status and exit
            update_task_status "$workflow_id" "$WORKFLOW_STATUS_FAILED"
            update_workflow_data "$workflow_id" "$workflow_data"
            return 1
        fi
        
        # Store step result
        workflow_data=$(echo "$workflow_data" | jq \
            --arg step_index "$step_index" \
            --arg result "$step_result" \
            '.results["step_' "$step_index" '"] = $result')
        
        # Update workflow data
        update_workflow_data "$workflow_id" "$workflow_data"
        
        # Wait between steps (if configured)
        local step_delay
        step_delay=$(echo "$step_data" | jq -r '.delay // "5"')
        
        if [[ $step_delay -gt 0 ]] && [[ $((step_index + 1)) -lt $total_steps ]]; then
            log_info "Waiting ${step_delay}s before next step..."
            sleep "$step_delay"
        fi
    done
    
    # Mark workflow as completed
    workflow_data=$(echo "$workflow_data" | jq \
        --arg completed_at "$(date -Iseconds)" \
        '.completed_at = $completed_at')
    update_task_status "$workflow_id" "$WORKFLOW_STATUS_COMPLETED"
    update_workflow_data "$workflow_id" "$workflow_data"
    
    log_info "Issue-merge workflow completed successfully: $workflow_id"
    return 0
}

# Execute individual workflow step
execute_workflow_step() {
    local command="$1"
    local phase="$2"
    local context="${3:-}"  # Additional context like issue_id, pr_ref
    
    log_debug "Executing workflow step: $command (phase: $phase)"
    
    # Extract relevant identifiers from command
    local identifier=""
    case "$phase" in
        "$STEP_DEVELOP")
            identifier=$(echo "$command" | sed 's|^/dev ||' | sed 's| .*||')
            ;;
        "$STEP_REVIEW")
            identifier=$(echo "$command" | sed 's|^/review ||')
            ;;
        "$STEP_MERGE")
            identifier=$(echo "$command" | sed 's|^.*/dev merge-pr ||' | sed 's| .*||')
            ;;
    esac
    
    # Use context if provided, otherwise use extracted identifier
    local execution_context="${context:-$identifier}"
    
    # Execute real commands with Claude CLI integration
    case "$phase" in
        "$STEP_DEVELOP")
            execute_dev_command "$command" "$execution_context"
            ;;
        "$STEP_CLEAR")
            execute_clear_command "$command"
            ;;
        "$STEP_REVIEW")
            execute_review_command "$command" "$execution_context"
            ;;
        "$STEP_MERGE")
            execute_merge_command "$command" "$execution_context"
            ;;
        *)
            log_warn "Unknown workflow step phase: $phase, executing as generic command"
            execute_generic_command "$command"
            ;;
    esac
}

# ===============================================================================
# REAL COMMAND EXECUTION IMPLEMENTATION
# ===============================================================================

# Source claunch integration for command execution
if [[ -f "${SCRIPT_DIR:-src}/claunch-integration.sh" ]]; then
    # shellcheck source=../claunch-integration.sh
    source "${SCRIPT_DIR:-src}/claunch-integration.sh"
elif [[ -f "${BASH_SOURCE[0]%/*}/../claunch-integration.sh" ]]; then
    # shellcheck source=../claunch-integration.sh
    source "${BASH_SOURCE[0]%/*}/../claunch-integration.sh"
else
    log_error "claunch-integration.sh not found - workflow execution will fail"
fi

# Execute /dev command with real Claude CLI integration
execute_dev_command() {
    local command="$1"
    local issue_id="$2"
    
    log_info "Executing dev command: $command"
    
    # Ensure session exists and is active
    if ! check_session_status; then
        log_error "No active Claude session for dev command"
        log_info "Attempting to start new session"
        if ! start_or_resume_session "$(pwd)" false; then
            log_error "Failed to start Claude session"
            return 1
        fi
        # Give session time to start
        sleep 3
    fi
    
    # Send command and monitor for completion
    log_debug "Sending command to session: $command"
    if send_command_to_session "$command"; then
        log_info "Command sent successfully, monitoring for completion"
        if monitor_command_completion "$command" "develop" "$issue_id"; then
            log_info "Dev command completed successfully"
            return 0
        else
            log_error "Dev command failed or timed out"
            return 1
        fi
    else
        log_error "Failed to send command to session: $command"
        return 1
    fi
}

# Execute /clear command with real Claude CLI integration
execute_clear_command() {
    local command="$1"
    
    log_info "Executing clear command: $command"
    
    # Ensure session exists and is active
    if ! check_session_status; then
        log_error "No active Claude session for clear command"
        return 1
    fi
    
    # Send command - clear is usually immediate
    log_debug "Sending clear command to session: $command"
    if send_command_to_session "$command"; then
        log_info "Clear command sent successfully"
        # Clear command is typically immediate, so short monitoring
        sleep 2
        log_info "Clear command completed successfully"
        return 0
    else
        log_error "Failed to send clear command: $command"
        return 1
    fi
}

# Execute /review command with real Claude CLI integration  
execute_review_command() {
    local command="$1"
    local pr_ref="$2"
    
    log_info "Executing review command: $command"
    
    # Ensure session exists and is active
    if ! check_session_status; then
        log_error "No active Claude session for review command"
        return 1
    fi
    
    # Send command and monitor for completion
    log_debug "Sending review command to session: $command"
    if send_command_to_session "$command"; then
        log_info "Review command sent successfully, monitoring for completion"
        if monitor_command_completion "$command" "review" "$pr_ref"; then
            log_info "Review command completed successfully"
            return 0
        else
            log_error "Review command failed or timed out"
            return 1
        fi
    else
        log_error "Failed to send review command: $command"
        return 1
    fi
}

# Execute merge command with real Claude CLI integration
execute_merge_command() {
    local command="$1"
    local issue_id="$2"
    
    log_info "Executing merge command: $command"
    
    # Ensure session exists and is active
    if ! check_session_status; then
        log_error "No active Claude session for merge command"
        return 1
    fi
    
    # Send command and monitor for completion
    log_debug "Sending merge command to session: $command"
    if send_command_to_session "$command"; then
        log_info "Merge command sent successfully, monitoring for completion"
        if monitor_command_completion "$command" "merge" "$issue_id"; then
            log_info "Merge command completed successfully"
            return 0
        else
            log_error "Merge command failed or timed out"
            return 1
        fi
    else
        log_error "Failed to send merge command: $command"
        return 1
    fi
}

# Execute generic command with real Claude CLI integration
execute_generic_command() {
    local command="$1"
    
    log_info "Executing generic command: $command"
    
    # Ensure session exists and is active
    if ! check_session_status; then
        log_error "No active Claude session for generic command"
        return 1
    fi
    
    # Send command and monitor for completion
    log_debug "Sending generic command to session: $command"
    if send_command_to_session "$command"; then
        log_info "Generic command sent successfully, monitoring for completion"
        if monitor_command_completion "$command" "generic" ""; then
            log_info "Generic command completed successfully"
            return 0
        else
            log_error "Generic command failed or timed out"
            return 1
        fi
    else
        log_error "Failed to send generic command: $command"
        return 1
    fi
}

# ===============================================================================
# COMMAND COMPLETION DETECTION
# ===============================================================================

# Monitor command completion using multiple detection strategies
monitor_command_completion() {
    local command="$1"
    local phase="$2"
    local context="${3:-}"
    local timeout="${4:-300}"  # 5 minutes default timeout
    
    log_debug "Monitoring command completion: $command (phase: $phase, timeout: ${timeout}s)"
    
    local start_time=$(date +%s)
    local check_interval=5
    local pattern_checks=0
    local max_pattern_checks=12  # 1 minute of pattern checking
    
    # Phase-specific timeout adjustments
    case "$phase" in
        "develop")
            timeout=600  # 10 minutes for development work
            ;;
        "clear") 
            timeout=30   # 30 seconds for context clearing
            ;;
        "review")
            timeout=480  # 8 minutes for review work
            ;;
        "merge")
            timeout=300  # 5 minutes for merge operations
            ;;
        "generic")
            timeout=180  # 3 minutes for generic commands
            ;;
    esac
    
    log_debug "Using timeout: ${timeout}s for phase: $phase"
    
    while true; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        # Check for timeout first
        if (( elapsed > timeout )); then
            log_error "Command timeout after ${elapsed}s (limit: ${timeout}s): $command"
            return 1
        fi
        
        # Check for completion patterns
        if check_command_completion_pattern "$command" "$phase" "$context"; then
            log_info "Command completion detected after ${elapsed}s: $command"
            return 0
        fi
        
        # Increment pattern check counter
        ((pattern_checks++))
        
        # Log progress every minute
        if (( elapsed % 60 == 0 && elapsed > 0 )); then
            log_info "Command still running: ${elapsed}s elapsed (${command})"
        fi
        
        # Wait before next check
        sleep $check_interval
    done
}

# Check for command completion patterns based on tmux session output
check_command_completion_pattern() {
    local command="$1"
    local phase="$2" 
    local context="${3:-}"
    
    log_debug "Checking completion patterns for: $command"
    
    # Only works in tmux mode with active session
    if [[ "$USE_CLAUNCH" != "true" ]] || [[ "$CLAUNCH_MODE" != "tmux" ]]; then
        log_debug "Pattern detection not available in current mode, using timeout-based detection"
        return 0  # Fall back to timeout-based detection
    fi
    
    if ! tmux has-session -t "$TMUX_SESSION_NAME" 2>/dev/null; then
        log_warn "tmux session not found: $TMUX_SESSION_NAME"
        return 1
    fi
    
    # Capture recent tmux session output
    local session_output
    session_output=$(tmux capture-pane -t "$TMUX_SESSION_NAME" -p 2>/dev/null || echo "")
    
    if [[ -z "$session_output" ]]; then
        log_debug "No session output captured"
        return 0
    fi
    
    # Phase-specific completion patterns
    case "$phase" in
        "develop")
            check_develop_completion_patterns "$session_output" "$context"
            ;;
        "clear")
            check_clear_completion_patterns "$session_output"
            ;;
        "review") 
            check_review_completion_patterns "$session_output" "$context"
            ;;
        "merge")
            check_merge_completion_patterns "$session_output" "$context"
            ;;
        "generic")
            check_generic_completion_patterns "$session_output"
            ;;
        *)
            log_debug "No specific patterns for phase: $phase"
            return 0
            ;;
    esac
}

# Check development phase completion patterns
check_develop_completion_patterns() {
    local output="$1"
    local issue_id="$2"
    
    # Look for PR creation success patterns
    if echo "$output" | grep -q -i "pull request.*created\|pr.*created\|created pull request"; then
        log_debug "Found PR creation pattern in output"
        return 0
    fi
    
    # Look for branch creation and commit patterns
    if echo "$output" | grep -q -i "committed.*changes\|created.*branch\|pushed.*to"; then
        log_debug "Found development completion pattern in output"
        return 0
    fi
    
    # Look for issue-specific completion
    if [[ -n "$issue_id" ]] && echo "$output" | grep -q -i "issue.*$issue_id.*complete\|$issue_id.*implemented"; then
        log_debug "Found issue-specific completion pattern in output"
        return 0
    fi
    
    # Look for general completion indicators
    if echo "$output" | grep -q -i "implementation.*complete\|feature.*complete\|development.*finished"; then
        log_debug "Found general completion pattern in output"
        return 0
    fi
    
    # Look for Claude prompt readiness (fallback)
    if echo "$output" | tail -5 | grep -q -E "claude>|>|❯|$"; then
        log_debug "Found prompt readiness in output"
        return 0
    fi
    
    return 1
}

# Check clear phase completion patterns  
check_clear_completion_patterns() {
    local output="$1"
    
    # Clear is usually immediate, look for context cleared messages
    if echo "$output" | grep -q -i "context.*cleared\|clear.*complete\|conversation.*reset"; then
        log_debug "Found clear completion pattern in output"
        return 0
    fi
    
    # Look for prompt readiness (clear is fast)
    if echo "$output" | tail -3 | grep -q -E "claude>|>|❯|$"; then
        log_debug "Found prompt readiness after clear in output"
        return 0
    fi
    
    return 1
}

# Check review phase completion patterns
check_review_completion_patterns() {
    local output="$1"
    local pr_ref="$2"
    
    # Look for review completion patterns
    if echo "$output" | grep -q -i "review.*complete\|analysis.*complete\|review.*finished"; then
        log_debug "Found review completion pattern in output"
        return 0
    fi
    
    # Look for PR-specific review completion
    if [[ -n "$pr_ref" ]] && echo "$output" | grep -q -i "$pr_ref.*review\|reviewed.*$pr_ref"; then
        log_debug "Found PR-specific review completion pattern in output"
        return 0
    fi
    
    # Look for summary or recommendations (indicates review completion)
    if echo "$output" | grep -q -i "summary\|recommendation\|conclusion\|overall"; then
        log_debug "Found review summary pattern in output"
        return 0
    fi
    
    return 1
}

# Check merge phase completion patterns
check_merge_completion_patterns() {
    local output="$1"
    local issue_id="$2"
    
    # Look for merge success patterns
    if echo "$output" | grep -q -i "merge.*successful\|merged.*successfully\|merge.*complete"; then
        log_debug "Found merge completion pattern in output"
        return 0
    fi
    
    # Look for main branch update patterns
    if echo "$output" | grep -q -i "main.*updated\|merged.*into.*main\|main.*branch"; then
        log_debug "Found main branch update pattern in output"
        return 0
    fi
    
    # Look for issue closure patterns
    if [[ -n "$issue_id" ]] && echo "$output" | grep -q -i "issue.*$issue_id.*closed\|closed.*$issue_id"; then
        log_debug "Found issue closure pattern in output"
        return 0
    fi
    
    return 1
}

# Check generic completion patterns
check_generic_completion_patterns() {
    local output="$1"
    
    # Look for general completion indicators
    if echo "$output" | grep -q -i "complete\|finished\|done\|success"; then
        log_debug "Found generic completion pattern in output"
        return 0
    fi
    
    # Look for prompt readiness
    if echo "$output" | tail -3 | grep -q -E "claude>|>|❯|$"; then
        log_debug "Found prompt readiness in output"
        return 0
    fi
    
    return 1
}

# ===============================================================================
# ERROR HANDLING AND RECOVERY
# ===============================================================================

# Classify error type for appropriate recovery strategy
classify_workflow_error() {
    local error_output="$1"
    local command="$2"
    local phase="$3"
    
    # Network/connection errors (recoverable)
    if echo "$error_output" | grep -q -i "connection.*refused\|network.*error\|timeout\|connection.*reset"; then
        echo "network_error"
        return 0
    fi
    
    # Session not found errors (recoverable)
    if echo "$error_output" | grep -q -i "session.*not.*found\|no.*active.*session"; then
        echo "session_error"
        return 0
    fi
    
    # Authentication errors (non-recoverable)
    if echo "$error_output" | grep -q -i "authentication.*failed\|unauthorized\|permission.*denied"; then
        echo "auth_error"
        return 0
    fi
    
    # Command syntax errors (non-recoverable)
    if echo "$error_output" | grep -q -i "command.*not.*found\|invalid.*command\|syntax.*error"; then
        echo "syntax_error"
        return 0
    fi
    
    # Usage limit errors (recoverable with wait)
    if echo "$error_output" | grep -q -i "rate.*limit\|usage.*limit\|quota.*exceeded"; then
        echo "usage_limit_error"
        return 0
    fi
    
    # Generic error (recoverable)
    echo "generic_error"
    return 0
}

# Handle workflow step error with appropriate recovery
handle_workflow_step_error() {
    local workflow_id="$1"
    local step_index="$2"
    local command="$3"
    local phase="$4"
    local error_output="${5:-}"
    
    log_error "Workflow step failed: $command (phase: $phase)"
    
    # Classify error type
    local error_type
    error_type=$(classify_workflow_error "$error_output" "$command" "$phase")
    
    log_info "Error classified as: $error_type"
    
    # Get current workflow data
    local workflow_data
    workflow_data=$(get_task "$workflow_id" "json")
    
    # Get retry count for this step
    local step_retry_count
    step_retry_count=$(echo "$workflow_data" | jq -r ".steps[$step_index].retry_count // 0")
    local max_retries=3
    
    # Update error history
    workflow_data=$(echo "$workflow_data" | jq \
        --arg error_type "$error_type" \
        --arg error_output "$error_output" \
        --arg timestamp "$(date -Iseconds)" \
        --arg step_index "$step_index" \
        '.error_history += [{
            step_index: ($step_index | tonumber),
            error_type: $error_type,
            error_output: $error_output,
            timestamp: $timestamp,
            retry_count: '"$step_retry_count"'
        }] | .last_error = {
            type: $error_type,
            step_index: ($step_index | tonumber),
            timestamp: $timestamp
        }')
    
    # Decide recovery strategy based on error type
    case "$error_type" in
        "network_error"|"session_error"|"generic_error")
            if (( step_retry_count < max_retries )); then
                log_info "Attempting recovery for $error_type (retry $((step_retry_count + 1))/$max_retries)"
                
                # Increment retry count
                workflow_data=$(echo "$workflow_data" | jq \
                    --arg step_index "$step_index" \
                    '.steps['"$step_index"'].retry_count = ((.steps['"$step_index"'].retry_count // 0) + 1)')
                
                # Add backoff delay
                local backoff_delay=$((5 * (step_retry_count + 1)))
                log_info "Waiting ${backoff_delay}s before retry..."
                sleep "$backoff_delay"
                
                # Update workflow data and return recoverable status
                update_workflow_data "$workflow_id" "$workflow_data"
                return 2  # Recoverable error
            else
                log_error "Max retries exceeded for $error_type"
                update_workflow_data "$workflow_id" "$workflow_data"
                return 1  # Non-recoverable after max retries
            fi
            ;;
        "usage_limit_error")
            log_info "Usage limit encountered, implementing cooldown period"
            local cooldown_delay=300  # 5 minutes
            log_info "Waiting ${cooldown_delay}s for usage limit cooldown..."
            sleep "$cooldown_delay"
            
            # Don't count usage limits against retry count
            update_workflow_data "$workflow_id" "$workflow_data"
            return 2  # Recoverable after cooldown
            ;;
        "auth_error"|"syntax_error")
            log_error "Non-recoverable error type: $error_type"
            update_workflow_data "$workflow_id" "$workflow_data"
            return 1  # Non-recoverable
            ;;
        *)
            log_warn "Unknown error type: $error_type, treating as recoverable"
            update_workflow_data "$workflow_id" "$workflow_data"
            return 2  # Assume recoverable for unknown errors
            ;;
    esac
}

# Enhanced workflow execution with error handling
execute_issue_merge_workflow_with_recovery() {
    local workflow_id="$1"
    
    log_info "Starting issue-merge workflow with recovery: $workflow_id"
    
    local workflow_data
    workflow_data=$(get_task "$workflow_id" "json")
    
    local current_step
    current_step=$(echo "$workflow_data" | jq -r '.current_step')
    
    local steps
    steps=$(echo "$workflow_data" | jq -r '.steps')
    
    local total_steps
    total_steps=$(echo "$steps" | jq length)
    
    local max_workflow_retries=5
    local workflow_retry_count=0
    
    # Execute steps sequentially with recovery
    for ((step_index=current_step; step_index<total_steps; step_index++)); do
        local step_retry_attempts=0
        local step_completed=false
        
        while [[ "$step_completed" == "false" ]] && (( workflow_retry_count < max_workflow_retries )); do
            # Get current step data (refresh in case of retries)
            workflow_data=$(get_task "$workflow_id" "json")
            local step_data
            step_data=$(echo "$workflow_data" | jq ".steps[$step_index]")
            
            local phase
            phase=$(echo "$step_data" | jq -r '.phase')
            
            local command
            command=$(echo "$step_data" | jq -r '.command')
            
            local description
            description=$(echo "$step_data" | jq -r '.description')
            
            log_info "Executing workflow step $((step_index + 1))/$total_steps: $phase (attempt $((step_retry_attempts + 1)))"
            log_info "Description: $description"
            log_info "Command: $command"
            
            # Update current step and step status
            workflow_data=$(echo "$workflow_data" | jq \
                --arg step_index "$step_index" \
                --arg status "in_progress" \
                --arg started_at "$(date -Iseconds)" \
                '.current_step = ($step_index | tonumber) | 
                 .steps['"$step_index"'].status = $status |
                 .steps['"$step_index"'].started_at = $started_at')
            
            update_workflow_data "$workflow_id" "$workflow_data"
            
            # Execute the step with context
            local issue_id
            issue_id=$(echo "$workflow_data" | jq -r '.config.issue_id // ""')
            
            local step_result
            if execute_workflow_step "$command" "$phase" "$issue_id" 2>&1; then
                # Success - mark step as completed
                workflow_data=$(echo "$workflow_data" | jq \
                    --arg completed_at "$(date -Iseconds)" \
                    '.steps['"$step_index"'].status = "completed" | 
                     .steps['"$step_index"'].completed_at = $completed_at')
                
                # Store step result
                workflow_data=$(echo "$workflow_data" | jq \
                    --arg step_index "$step_index" \
                    '.results["step_'"$step_index"'"] = "success"')
                
                update_workflow_data "$workflow_id" "$workflow_data"
                
                log_info "Workflow step completed successfully: $phase"
                step_completed=true
            else
                # Error - attempt recovery
                local error_output="$?"
                log_error "Workflow step failed: $phase"
                
                local recovery_result
                recovery_result=$(handle_workflow_step_error "$workflow_id" "$step_index" "$command" "$phase" "$error_output")
                
                case "$recovery_result" in
                    2)  # Recoverable error
                        log_info "Error is recoverable, retrying step"
                        ((step_retry_attempts++))
                        ((workflow_retry_count++))
                        ;;
                    1|*) # Non-recoverable error
                        log_error "Non-recoverable error in workflow step: $phase"
                        
                        # Mark step as failed
                        workflow_data=$(echo "$workflow_data" | jq \
                            --arg failed_at "$(date -Iseconds)" \
                            '.steps['"$step_index"'].status = "failed" | 
                             .steps['"$step_index"'].failed_at = $failed_at')
                        
                        # Update workflow status and exit
                        update_task_status "$workflow_id" "$WORKFLOW_STATUS_FAILED"
                        update_workflow_data "$workflow_id" "$workflow_data"
                        return 1
                        ;;
                esac
            fi
        done
        
        # Check if we exceeded max workflow retries
        if (( workflow_retry_count >= max_workflow_retries )); then
            log_error "Maximum workflow retry attempts exceeded"
            update_task_status "$workflow_id" "$WORKFLOW_STATUS_FAILED"
            return 1
        fi
        
        # Wait between steps (if configured and not the last step)
        if [[ $((step_index + 1)) -lt $total_steps ]]; then
            local step_delay
            step_delay=$(echo "$step_data" | jq -r '.delay // "5"')
            
            if [[ $step_delay -gt 0 ]]; then
                log_info "Waiting ${step_delay}s before next step..."
                sleep "$step_delay"
            fi
        fi
    done
    
    # Mark workflow as completed
    workflow_data=$(echo "$workflow_data" | jq \
        --arg completed_at "$(date -Iseconds)" \
        '.completed_at = $completed_at')
    update_task_status "$workflow_id" "$WORKFLOW_STATUS_COMPLETED"
    update_workflow_data "$workflow_id" "$workflow_data"
    
    log_info "Issue-merge workflow completed successfully with recovery: $workflow_id"
    return 0
}

# ===============================================================================
# CUSTOM WORKFLOW IMPLEMENTATION
# ===============================================================================

# Initialize custom workflow
initialize_custom_workflow() {
    local workflow_data="$1"
    local config="$2"
    
    local custom_steps
    custom_steps=$(echo "$config" | jq -r '.steps // []')
    
    if [[ "$(echo "$custom_steps" | jq length)" -eq 0 ]]; then
        log_error "Custom workflow requires steps configuration"
        return 1
    fi
    
    echo "$workflow_data" | jq \
        --argjson steps "$custom_steps" \
        '.steps = $steps'
}

# Execute custom workflow
execute_custom_workflow() {
    local workflow_id="$1"
    
    log_info "Executing custom workflow: $workflow_id"
    
    # Custom workflows can be implemented similarly to issue-merge
    # For now, we'll use the same execution pattern
    execute_issue_merge_workflow "$workflow_id"
}

# ===============================================================================
# WORKFLOW MANAGEMENT FUNCTIONS
# ===============================================================================

# Update workflow data in the queue
update_workflow_data() {
    local workflow_id="$1"
    local updated_data="$2"
    
    # Update the metadata in global state
    TASK_METADATA["$workflow_id"]="$updated_data"
    
    # Save to persistent storage
    save_queue_state false  # Save without backup for workflow updates
}

# Get workflow status and progress
get_workflow_status() {
    local workflow_id="$1"
    
    if ! task_exists "$workflow_id"; then
        echo '{"error": "Workflow not found"}'
        return 1
    fi
    
    local workflow_data
    workflow_data=$(get_task "$workflow_id" "json")
    
    local current_step
    current_step=$(echo "$workflow_data" | jq -r '.current_step')
    
    local total_steps
    total_steps=$(echo "$workflow_data" | jq '.steps | length')
    
    local status
    status=$(echo "$workflow_data" | jq -r '.status')
    
    local workflow_type
    workflow_type=$(echo "$workflow_data" | jq -r '.workflow_type')
    
    jq -n \
        --arg workflow_id "$workflow_id" \
        --arg workflow_type "$workflow_type" \
        --arg status "$status" \
        --argjson current_step "$current_step" \
        --argjson total_steps "$total_steps" \
        --argjson progress "$(echo "scale=2; $current_step * 100 / $total_steps" | bc -l 2>/dev/null || echo "0")" \
        '{
            workflow_id: $workflow_id,
            workflow_type: $workflow_type,
            status: $status,
            current_step: $current_step,
            total_steps: $total_steps,
            progress_percent: $progress
        }'
}

# Get detailed workflow status with timing and error information
get_workflow_detailed_status() {
    local workflow_id="$1"
    
    if ! task_exists "$workflow_id"; then
        echo '{"error": "Workflow not found"}'
        return 1
    fi
    
    local workflow_data
    workflow_data=$(get_task "$workflow_id" "json")
    
    local current_step
    current_step=$(echo "$workflow_data" | jq -r '.current_step')
    
    local total_steps
    total_steps=$(echo "$workflow_data" | jq '.steps | length')
    
    local status
    status=$(echo "$workflow_data" | jq -r '.status')
    
    local workflow_type
    workflow_type=$(echo "$workflow_data" | jq -r '.workflow_type')
    
    local created_at
    created_at=$(echo "$workflow_data" | jq -r '.created_at')
    
    local updated_at
    updated_at=$(echo "$workflow_data" | jq -r '.updated_at // .created_at')
    
    local current_time
    current_time=$(date -Iseconds)
    
    # Calculate progress percentage
    local progress=0
    if [[ $total_steps -gt 0 ]]; then
        progress=$(echo "scale=2; $current_step * 100 / $total_steps" | bc -l 2>/dev/null || echo "0")
    fi
    
    # Get current step details if workflow is in progress
    local current_step_info="null"
    if [[ $current_step -lt $total_steps ]] && [[ $current_step -ge 0 ]]; then
        current_step_info=$(echo "$workflow_data" | jq ".steps[$current_step]")
    fi
    
    # Get error information
    local error_count
    error_count=$(echo "$workflow_data" | jq '.error_history | length // 0')
    
    local last_error
    last_error=$(echo "$workflow_data" | jq '.last_error // null')
    
    # Calculate elapsed time
    local start_epoch
    start_epoch=$(date -d "$created_at" +%s 2>/dev/null || echo "0")
    local current_epoch
    current_epoch=$(date +%s)
    local elapsed_seconds=$((current_epoch - start_epoch))
    
    # Estimate completion time for in-progress workflows
    local estimated_completion="null"
    if [[ "$status" == "in_progress" ]] && [[ $current_step -gt 0 ]]; then
        local avg_time_per_step=$((elapsed_seconds / current_step))
        local remaining_steps=$((total_steps - current_step))
        local estimated_remaining_time=$((avg_time_per_step * remaining_steps))
        local completion_epoch=$((current_epoch + estimated_remaining_time))
        estimated_completion=$(date -d "@$completion_epoch" -Iseconds 2>/dev/null || echo "null")
    fi
    
    jq -n \
        --arg workflow_id "$workflow_id" \
        --arg workflow_type "$workflow_type" \
        --arg status "$status" \
        --argjson current_step "$current_step" \
        --argjson total_steps "$total_steps" \
        --argjson progress_percent "$progress" \
        --arg created_at "$created_at" \
        --arg updated_at "$updated_at" \
        --arg current_time "$current_time" \
        --argjson elapsed_seconds "$elapsed_seconds" \
        --argjson current_step_info "$current_step_info" \
        --argjson error_count "$error_count" \
        --argjson last_error "$last_error" \
        --arg estimated_completion "$estimated_completion" \
        '{
            workflow_id: $workflow_id,
            workflow_type: $workflow_type,
            status: $status,
            progress: {
                current_step: $current_step,
                total_steps: $total_steps,
                percentage: $progress_percent,
                current_step_info: $current_step_info
            },
            timing: {
                created_at: $created_at,
                updated_at: $updated_at,
                current_time: $current_time,
                elapsed_seconds: $elapsed_seconds,
                elapsed_human: (($elapsed_seconds | tostring) + "s"),
                estimated_completion: $estimated_completion
            },
            errors: {
                count: $error_count,
                last_error: $last_error
            },
            session_health: (if ($status == "in_progress") then "monitoring" else "idle" end)
        }'
}

# Pause workflow execution
pause_workflow() {
    local workflow_id="$1"
    
    if ! task_exists "$workflow_id"; then
        log_error "Workflow not found: $workflow_id"
        return 1
    fi
    
    update_task_status "$workflow_id" "$WORKFLOW_STATUS_PAUSED"
    log_info "Paused workflow: $workflow_id"
}

# Resume workflow execution
resume_workflow() {
    local workflow_id="$1"
    
    if ! task_exists "$workflow_id"; then
        log_error "Workflow not found: $workflow_id"
        return 1
    fi
    
    local current_status
    current_status="${TASK_STATES[$workflow_id]}"
    
    # Allow resuming from paused or failed states
    if [[ "$current_status" != "$WORKFLOW_STATUS_PAUSED" ]] && [[ "$current_status" != "$WORKFLOW_STATUS_FAILED" ]]; then
        log_error "Workflow cannot be resumed from status: $current_status (must be paused or failed)"
        return 1
    fi
    
    log_info "Resuming workflow from status: $current_status"
    
    # Reset workflow to pending status for resumption
    update_task_status "$workflow_id" "$WORKFLOW_STATUS_PENDING"
    
    # Update workflow data to indicate resumption
    local workflow_data
    workflow_data=$(get_task "$workflow_id" "json")
    
    workflow_data=$(echo "$workflow_data" | jq \
        --arg resumed_at "$(date -Iseconds)" \
        '.resumed_at = $resumed_at | .resumed_count = ((.resumed_count // 0) + 1)')
    
    update_workflow_data "$workflow_id" "$workflow_data"
    
    # Resume execution
    execute_workflow_task "$workflow_id"
}

# Resume workflow from specific step (for manual intervention)
resume_workflow_from_step() {
    local workflow_id="$1"
    local resume_step="${2:-0}"
    
    if ! task_exists "$workflow_id"; then
        log_error "Workflow not found: $workflow_id"
        return 1
    fi
    
    local workflow_data
    workflow_data=$(get_task "$workflow_id" "json")
    
    local total_steps
    total_steps=$(echo "$workflow_data" | jq '.steps | length')
    
    if [[ $resume_step -ge $total_steps ]] || [[ $resume_step -lt 0 ]]; then
        log_error "Invalid resume step: $resume_step (must be between 0 and $((total_steps - 1)))"
        return 1
    fi
    
    log_info "Resuming workflow from step $resume_step"
    
    # Update workflow data to resume from specified step
    workflow_data=$(echo "$workflow_data" | jq \
        --arg resume_step "$resume_step" \
        --arg resumed_at "$(date -Iseconds)" \
        '.current_step = ($resume_step | tonumber) |
         .resumed_at = $resumed_at |
         .resumed_count = ((.resumed_count // 0) + 1) |
         .manual_resume = true')
    
    # Mark steps before resume point as completed
    for ((i=0; i<resume_step; i++)); do
        workflow_data=$(echo "$workflow_data" | jq \
            --arg step_index "$i" \
            '.steps['"$i"'].status = "completed"')
    done
    
    # Mark steps from resume point onwards as pending
    for ((i=resume_step; i<total_steps; i++)); do
        workflow_data=$(echo "$workflow_data" | jq \
            --arg step_index "$i" \
            '.steps['"$i"'].status = "pending"')
    done
    
    # Update workflow status and data
    update_task_status "$workflow_id" "$WORKFLOW_STATUS_PENDING"
    update_workflow_data "$workflow_id" "$workflow_data"
    
    # Resume execution
    execute_workflow_task "$workflow_id"
}

# Create workflow checkpoint (save current state)
create_workflow_checkpoint() {
    local workflow_id="$1"
    local checkpoint_reason="${2:-manual_checkpoint}"
    
    if ! task_exists "$workflow_id"; then
        log_error "Workflow not found: $workflow_id"
        return 1
    fi
    
    local workflow_data
    workflow_data=$(get_task "$workflow_id" "json")
    
    # Create checkpoint data
    local checkpoint
    checkpoint=$(jq -n \
        --argjson workflow_data "$workflow_data" \
        --arg checkpoint_id "$(generate_task_id "checkpoint")" \
        --arg created_at "$(date -Iseconds)" \
        --arg reason "$checkpoint_reason" \
        '{
            checkpoint_id: $checkpoint_id,
            workflow_id: $workflow_data.id,
            created_at: $created_at,
            reason: $reason,
            workflow_state: $workflow_data,
            system_info: {
                claunch_mode: env.CLAUNCH_MODE // "unknown",
                session_name: env.TMUX_SESSION_NAME // "unknown"
            }
        }')
    
    # Add checkpoint to workflow history
    workflow_data=$(echo "$workflow_data" | jq \
        --argjson checkpoint "$checkpoint" \
        '.checkpoints += [$checkpoint] | .last_checkpoint = $checkpoint')
    
    update_workflow_data "$workflow_id" "$workflow_data"
    
    local checkpoint_id
    checkpoint_id=$(echo "$checkpoint" | jq -r '.checkpoint_id')
    
    log_info "Created workflow checkpoint: $checkpoint_id (reason: $checkpoint_reason)"
    echo "$checkpoint_id"
}

# Cancel workflow execution
cancel_workflow() {
    local workflow_id="$1"
    
    if ! task_exists "$workflow_id"; then
        log_error "Workflow not found: $workflow_id"
        return 1
    fi
    
    update_task_status "$workflow_id" "$WORKFLOW_STATUS_FAILED"
    
    # Update workflow data with cancellation info
    local workflow_data
    workflow_data=$(get_task "$workflow_id" "json")
    
    workflow_data=$(echo "$workflow_data" | jq \
        --arg cancelled_at "$(date -Iseconds)" \
        '.cancelled_at = $cancelled_at | .cancellation_reason = "user_cancelled"')
    
    update_workflow_data "$workflow_id" "$workflow_data"
    
    log_info "Cancelled workflow: $workflow_id"
}

# List all workflow tasks
list_workflows() {
    local status_filter="${1:-all}"
    
    local workflow_tasks="[]"
    
    for task_id in "${!TASK_METADATA[@]}"; do
        local task_data="${TASK_METADATA[$task_id]}"
        local task_type
        task_type=$(echo "$task_data" | jq -r '.type')
        
        if [[ "$task_type" == "workflow" ]]; then
            local task_status="${TASK_STATES[$task_id]}"
            
            if [[ "$status_filter" == "all" ]] || [[ "$task_status" == "$status_filter" ]]; then
                workflow_tasks=$(echo "$workflow_tasks" | jq --argjson task "$task_data" '. += [$task]')
            fi
        fi
    done
    
    echo "$workflow_tasks"
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