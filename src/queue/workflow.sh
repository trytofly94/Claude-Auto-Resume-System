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
    
    # Start resource monitoring if enabled
    if [[ "$ENABLE_RESOURCE_MONITORING" == "true" ]]; then
        check_system_resources "$workflow_id"
    fi
    
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
# CONFIGURABLE COMPLETION PATTERNS
# ===============================================================================

# Configurable completion patterns for better reliability
# Users can override these by setting environment variables
readonly DEVELOP_COMPLETION_PATTERNS="${DEVELOP_COMPLETION_PATTERNS:-"pull request.*created|pr.*created|created pull request|committed.*changes|created.*branch|pushed.*to|issue.*complete|implemented|development.*finished"}"
readonly CLEAR_COMPLETION_PATTERNS="${CLEAR_COMPLETION_PATTERNS:-"context.*cleared|clear.*complete|conversation.*reset|claude>|>|❯"}"
readonly REVIEW_COMPLETION_PATTERNS="${REVIEW_COMPLETION_PATTERNS:-"review.*complete|analysis.*complete|review.*finished|summary|recommendation|conclusion|overall"}"
readonly MERGE_COMPLETION_PATTERNS="${MERGE_COMPLETION_PATTERNS:-"merge.*successful|merged.*successfully|merge.*complete|main.*updated|merged.*into.*main|main.*branch|issue.*closed"}"
readonly GENERIC_COMPLETION_PATTERNS="${GENERIC_COMPLETION_PATTERNS:-"complete|finished|done|success|claude>|>|❯"}"

# Configurable timeouts for each phase (in seconds)
readonly DEVELOP_TIMEOUT="${DEVELOP_TIMEOUT:-600}"    # 10 minutes for development
readonly CLEAR_TIMEOUT="${CLEAR_TIMEOUT:-30}"         # 30 seconds for clearing
readonly REVIEW_TIMEOUT="${REVIEW_TIMEOUT:-480}"      # 8 minutes for review
readonly MERGE_TIMEOUT="${MERGE_TIMEOUT:-300}"        # 5 minutes for merge
readonly GENERIC_TIMEOUT="${GENERIC_TIMEOUT:-180}"    # 3 minutes for generic commands

# Resource monitoring configuration
readonly RESOURCE_CHECK_INTERVAL="${RESOURCE_CHECK_INTERVAL:-60}"    # Check every 60 seconds
readonly MAX_CPU_PERCENT="${MAX_CPU_PERCENT:-80}"                    # Maximum CPU usage threshold
readonly MAX_MEMORY_MB="${MAX_MEMORY_MB:-512}"                       # Maximum memory usage in MB
readonly ENABLE_RESOURCE_MONITORING="${ENABLE_RESOURCE_MONITORING:-true}"  # Enable resource monitoring

# Backoff and jitter configuration
readonly BACKOFF_BASE_DELAY="${BACKOFF_BASE_DELAY:-5}"               # Base delay in seconds
readonly BACKOFF_MAX_DELAY="${BACKOFF_MAX_DELAY:-300}"               # Maximum backoff delay (5 minutes)
readonly BACKOFF_JITTER_RANGE="${BACKOFF_JITTER_RANGE:-3}"           # +/- jitter range in seconds

# Resource monitoring functions
check_system_resources() {
    local workflow_id="${1:-system}"
    
    # Skip if monitoring is disabled
    if [[ "$ENABLE_RESOURCE_MONITORING" != "true" ]]; then
        return 0
    fi
    
    local cpu_usage=0
    local memory_usage=0
    local warnings=()
    
    # Get CPU usage (cross-platform)
    if command -v top >/dev/null 2>&1; then
        if [[ "$(uname)" == "Darwin" ]]; then
            # macOS
            cpu_usage=$(top -l1 -n0 | grep "CPU usage" | awk '{print $3}' | sed 's/%//' 2>/dev/null || echo "0")
        else
            # Linux
            cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | sed 's/%us,//' 2>/dev/null || echo "0")
        fi
    fi
    
    # Get memory usage of current process and its children
    if command -v ps >/dev/null 2>&1; then
        local pid=$$
        memory_usage=$(ps -o pid,ppid,rss,vsz,comm -e | grep -E "($$|tmux|claude)" | awk '{sum+=$3} END {print sum/1024}' 2>/dev/null || echo "0")
    fi
    
    # Check CPU threshold
    if (( $(echo "$cpu_usage > $MAX_CPU_PERCENT" | bc -l 2>/dev/null || echo "0") )); then
        warnings+=("CPU usage high: ${cpu_usage}% (threshold: ${MAX_CPU_PERCENT}%)")
    fi
    
    # Check memory threshold
    if (( $(echo "$memory_usage > $MAX_MEMORY_MB" | bc -l 2>/dev/null || echo "0") )); then
        warnings+=("Memory usage high: ${memory_usage}MB (threshold: ${MAX_MEMORY_MB}MB)")
    fi
    
    # Log warnings if any
    if [[ ${#warnings[@]} -gt 0 ]]; then
        for warning in "${warnings[@]}"; do
            log_warn "[$workflow_id] RESOURCE WARNING: $warning"
        done
        log_info "[$workflow_id] HINT: Consider reducing concurrent workflows or increasing resource limits"
    fi
    
    # Return warning status
    if [[ ${#warnings[@]} -gt 0 ]]; then
        return 1  # Warnings present
    else
        return 0  # All good
    fi
}

# Monitor resources during workflow execution
monitor_workflow_resources() {
    local workflow_id="$1"
    local monitoring_duration="${2:-300}"  # 5 minutes default
    
    if [[ "$ENABLE_RESOURCE_MONITORING" != "true" ]]; then
        log_debug "[$workflow_id] Resource monitoring disabled"
        return 0
    fi
    
    log_debug "[$workflow_id] Starting resource monitoring for ${monitoring_duration}s"
    
    local start_time=$(date +%s)
    local last_check=0
    
    while true; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        # Exit if monitoring duration exceeded
        if (( elapsed > monitoring_duration )); then
            break
        fi
        
        # Check resources at intervals with jitter
        local check_interval_with_jitter
        check_interval_with_jitter=$((RESOURCE_CHECK_INTERVAL + (RANDOM % 20) - 10))  # +/- 10 seconds jitter
        
        if (( current_time - last_check >= check_interval_with_jitter )); then
            if ! check_system_resources "$workflow_id"; then
                log_info "[$workflow_id] Resource usage is elevated, monitoring more closely"
            fi
            last_check=$current_time
        fi
        
        # Sleep for a short interval with minor jitter
        local sleep_interval
        sleep_interval=$((10 + (RANDOM % 6) - 3))  # 7-13 seconds with jitter
        sleep "$sleep_interval"
    done
    
    log_debug "[$workflow_id] Resource monitoring completed"
}

# Get current resource usage statistics
get_resource_stats() {
    local workflow_id="${1:-system}"
    
    local cpu_usage=0
    local memory_usage=0
    local load_average="unknown"
    local disk_usage="unknown"
    
    # CPU usage
    if command -v top >/dev/null 2>&1; then
        if [[ "$(uname)" == "Darwin" ]]; then
            cpu_usage=$(top -l1 -n0 | grep "CPU usage" | awk '{print $3}' | sed 's/%//' 2>/dev/null || echo "0")
        else
            cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | sed 's/%us,//' 2>/dev/null || echo "0")
        fi
    fi
    
    # Memory usage
    if command -v ps >/dev/null 2>&1; then
        memory_usage=$(ps -o pid,ppid,rss,vsz,comm -e | grep -E "($$|tmux|claude)" | awk '{sum+=$3} END {print sum/1024}' 2>/dev/null || echo "0")
    fi
    
    # Load average
    if command -v uptime >/dev/null 2>&1; then
        load_average=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | sed 's/,//' 2>/dev/null || echo "unknown")
    fi
    
    # Disk usage (current directory)
    if command -v df >/dev/null 2>&1; then
        disk_usage=$(df -h . | tail -1 | awk '{print $5}' 2>/dev/null || echo "unknown")
    fi
    
    # Return JSON formatted stats
    jq -n \
        --arg cpu_percent "$cpu_usage" \
        --arg memory_mb "$memory_usage" \
        --arg load_avg "$load_average" \
        --arg disk_percent "$disk_usage" \
        --arg timestamp "$(date -Iseconds)" \
        '{
            cpu_usage_percent: $cpu_percent,
            memory_usage_mb: $memory_mb,
            load_average: $load_avg,
            disk_usage_percent: $disk_percent,
            timestamp: $timestamp,
            thresholds: {
                max_cpu_percent: env.MAX_CPU_PERCENT // "80",
                max_memory_mb: env.MAX_MEMORY_MB // "512"
            }
        }'
}

# ===============================================================================
# COMMAND COMPLETION DETECTION
# ===============================================================================

# Load smart completion modules if available
if [[ -f "$SCRIPT_DIR/../completion-prompts.sh" ]]; then
    source "$SCRIPT_DIR/../completion-prompts.sh"
fi
if [[ -f "$SCRIPT_DIR/../completion-fallback.sh" ]]; then
    source "$SCRIPT_DIR/../completion-fallback.sh"
fi

# Monitor smart task completion with markers and patterns
monitor_smart_completion() {
    local task_id="$1"
    local command="$2"
    local phase="${3:-custom}"
    local timeout="${4:-300}"
    
    log_debug "Monitoring smart completion for task $task_id: $command"
    
    # Check if smart completion is enabled
    if [[ "${SMART_COMPLETION_ENABLED:-true}" != "true" ]]; then
        log_debug "Smart completion disabled, falling back to standard monitoring"
        return $(monitor_command_completion "$command" "$phase" "$task_id" "$timeout")
    fi
    
    # Get completion marker and patterns for this task
    local completion_marker="${TASK_COMPLETION_MARKERS[$task_id]:-}"
    local completion_patterns="${TASK_COMPLETION_PATTERNS[$task_id]:-}"
    
    # If no smart patterns available, fall back to standard detection
    if [[ -z "$completion_marker" && -z "$completion_patterns" ]]; then
        log_debug "No smart completion patterns for task $task_id, using standard detection"
        return $(monitor_command_completion "$command" "$phase" "$task_id" "$timeout")
    fi
    
    # Combine patterns if both marker and custom patterns exist
    if [[ -n "$completion_marker" ]]; then
        local marker_patterns
        marker_patterns=$(get_default_completion_patterns "$phase" "$completion_marker")
        if [[ -n "$completion_patterns" ]]; then
            completion_patterns="${marker_patterns}|${completion_patterns}"
        else
            completion_patterns="$marker_patterns"
        fi
    fi
    
    log_debug "Using smart completion patterns: $completion_patterns"
    
    local start_time=$(date +%s)
    local check_interval=5
    local confidence_threshold="${COMPLETION_CONFIDENCE_THRESHOLD:-0.8}"
    
    # Calculate smart timeout if available
    if command -v calculate_task_timeout >/dev/null 2>&1; then
        local task_description
        task_description=$(echo "${TASK_METADATA[$task_id]:-{}}" | jq -r '.description // ""')
        timeout=$(calculate_task_timeout "$phase" "$task_description" "$timeout")
        log_debug "Smart timeout calculated: ${timeout}s"
    fi
    
    while true; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        # Check for timeout with smart fallback handling
        if (( elapsed > timeout )); then
            log_warn "Smart completion timeout after ${elapsed}s for task $task_id"
            
            # Try fallback completion if available
            if command -v handle_timeout_completion >/dev/null 2>&1; then
                if handle_timeout_completion "$task_id" "$elapsed" "$timeout"; then
                    log_info "Fallback completion confirmed for task $task_id"
                    return 0
                elif [[ $? -eq 2 ]]; then
                    # Retry requested, extend timeout briefly
                    timeout=$((timeout + 30))
                    log_info "Extending timeout by 30s for task $task_id retry"
                    continue
                fi
            fi
            
            log_error "Task timeout with no fallback success: $task_id"
            return 1
        fi
        
        # Capture session output for pattern matching
        local session_output=""
        if [[ "$USE_CLAUNCH" == "true" && "$CLAUNCH_MODE" == "tmux" ]]; then
            if tmux has-session -t "$TMUX_SESSION_NAME" 2>/dev/null; then
                session_output=$(tmux capture-pane -t "$TMUX_SESSION_NAME" -p 2>/dev/null || echo "")
            fi
        fi
        
        # Test completion patterns with confidence scoring
        if [[ -n "$session_output" && -n "$completion_patterns" ]]; then
            if test_completion_match "$session_output" "$completion_patterns" "$confidence_threshold"; then
                log_info "Smart completion detected for task $task_id after ${elapsed}s"
                
                # Extract and validate completion marker if present
                local detected_marker
                if detected_marker=$(extract_completion_marker "$session_output"); then
                    if [[ "$detected_marker" == "$completion_marker" ]]; then
                        log_info "Completion marker validated: $detected_marker"
                    else
                        log_warn "Completion marker mismatch: expected $completion_marker, got $detected_marker"
                    fi
                fi
                
                return 0
            fi
        fi
        
        # Log progress periodically
        if (( elapsed % 60 == 0 && elapsed > 0 )); then
            log_info "Smart monitoring in progress for task $task_id: ${elapsed}s elapsed"
            
            # Show context analysis if available
            if [[ -n "$session_output" ]] && command -v analyze_completion_context >/dev/null 2>&1; then
                analyze_completion_context "$task_id" "$session_output" "$elapsed"
            fi
        fi
        
        sleep $check_interval
    done
}

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
    
    # Phase-specific timeout adjustments using configurable values
    case "$phase" in
        "develop")
            timeout="$DEVELOP_TIMEOUT"
            ;;
        "clear") 
            timeout="$CLEAR_TIMEOUT"
            ;;
        "review")
            timeout="$REVIEW_TIMEOUT"
            ;;
        "merge")
            timeout="$MERGE_TIMEOUT"
            ;;
        "generic")
            timeout="$GENERIC_TIMEOUT"
            ;;
    esac
    
    log_debug "Using timeout: ${timeout}s for phase: $phase"
    
    while true; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        # Check for timeout first
        if (( elapsed > timeout )); then
            log_error "Command timeout after ${elapsed}s (limit: ${timeout}s): $command"
            log_info "HINT: Consider increasing ${phase^^}_TIMEOUT environment variable for longer operations"
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
    
    log_debug "Checking development patterns: $DEVELOP_COMPLETION_PATTERNS"
    
    # Use configurable patterns for primary detection
    if echo "$output" | grep -q -i -E "$DEVELOP_COMPLETION_PATTERNS"; then
        log_debug "Found development completion pattern in output"
        return 0
    fi
    
    # Look for issue-specific completion
    if [[ -n "$issue_id" ]] && echo "$output" | grep -q -i "issue.*$issue_id.*complete\|$issue_id.*implemented"; then
        log_debug "Found issue-specific completion pattern in output"
        return 0
    fi
    
    return 1
}

# Check clear phase completion patterns  
check_clear_completion_patterns() {
    local output="$1"
    
    log_debug "Checking clear patterns: $CLEAR_COMPLETION_PATTERNS"
    
    # Use configurable patterns for detection
    if echo "$output" | grep -q -i -E "$CLEAR_COMPLETION_PATTERNS"; then
        log_debug "Found clear completion pattern in output"
        return 0
    fi
    
    return 1
}

# Check review phase completion patterns
check_review_completion_patterns() {
    local output="$1"
    local pr_ref="$2"
    
    log_debug "Checking review patterns: $REVIEW_COMPLETION_PATTERNS"
    
    # Use configurable patterns for primary detection
    if echo "$output" | grep -q -i -E "$REVIEW_COMPLETION_PATTERNS"; then
        log_debug "Found review completion pattern in output"
        return 0
    fi
    
    # Look for PR-specific review completion
    if [[ -n "$pr_ref" ]] && echo "$output" | grep -q -i "$pr_ref.*review\|reviewed.*$pr_ref"; then
        log_debug "Found PR-specific review completion pattern in output"
        return 0
    fi
    
    return 1
}

# Check merge phase completion patterns
check_merge_completion_patterns() {
    local output="$1"
    local issue_id="$2"
    
    log_debug "Checking merge patterns: $MERGE_COMPLETION_PATTERNS"
    
    # Use configurable patterns for primary detection
    if echo "$output" | grep -q -i -E "$MERGE_COMPLETION_PATTERNS"; then
        log_debug "Found merge completion pattern in output"
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
    
    log_debug "Checking generic patterns: $GENERIC_COMPLETION_PATTERNS"
    
    # Use configurable patterns for detection
    if echo "$output" | grep -q -i -E "$GENERIC_COMPLETION_PATTERNS"; then
        log_debug "Found generic completion pattern in output"
        return 0
    fi
    
    return 1
}

# ===============================================================================
# ERROR HANDLING AND RECOVERY
# ===============================================================================

# Enhanced error logging with context and troubleshooting hints
log_workflow_error() {
    local workflow_id="$1"
    local phase="$2"
    local error_type="$3"
    local error_output="$4"
    local command="${5:-}"
    
    # Base error message with context
    log_error "[$workflow_id] Phase '$phase' failed: $error_type"
    
    # Add command context if available
    if [[ -n "$command" ]]; then
        log_error "[$workflow_id] Failed command: $command"
    fi
    
    # Add error output snippet if available
    if [[ -n "$error_output" ]] && [[ ${#error_output} -gt 0 ]]; then
        local error_snippet
        error_snippet=$(echo "$error_output" | head -3 | tail -1 | cut -c1-100)
        if [[ -n "$error_snippet" ]]; then
            log_error "[$workflow_id] Error details: $error_snippet"
        fi
    fi
    
    # Add troubleshooting hints based on error type
    case "$error_type" in
        "network_error")
            log_info "[$workflow_id] HINT: Check internet connection and try again"
            log_info "[$workflow_id] HINT: Network errors usually resolve automatically after retry"
            ;;
        "session_error")
            log_info "[$workflow_id] HINT: Try restarting Claude session with 'claunch start'"
            log_info "[$workflow_id] HINT: Check if tmux session exists: 'tmux list-sessions'"
            ;;
        "auth_error")
            log_info "[$workflow_id] HINT: Check Claude CLI authentication: 'claude auth status'"
            log_info "[$workflow_id] HINT: Re-authenticate if needed: 'claude auth login'"
            ;;
        "syntax_error")
            log_info "[$workflow_id] HINT: Check command syntax in workflow configuration"
            log_info "[$workflow_id] HINT: Verify all required parameters are present"
            ;;
        "usage_limit_error")
            log_info "[$workflow_id] HINT: Usage limit reached, workflow will auto-resume after cooldown"
            log_info "[$workflow_id] HINT: Check current usage: 'claude usage'"
            ;;
        "timeout_error")
            log_info "[$workflow_id] HINT: Command exceeded timeout (${DEVELOP_TIMEOUT:-600}s for $phase)"
            log_info "[$workflow_id] HINT: Consider increasing timeout with ${phase^^}_TIMEOUT environment variable"
            ;;
        *)
            log_info "[$workflow_id] HINT: Generic error - check Claude CLI logs for details"
            log_info "[$workflow_id] HINT: Try running the command manually to diagnose the issue"
            ;;
    esac
}

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
    
    # Timeout errors (recoverable)
    if echo "$error_output" | grep -q -i "timeout\|timed.*out"; then
        echo "timeout_error"
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
    
    # Classify error type
    local error_type
    error_type=$(classify_workflow_error "$error_output" "$command" "$phase")
    
    # Log enhanced error with context and troubleshooting hints
    log_workflow_error "$workflow_id" "$phase" "$error_type" "$error_output" "$command"
    
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
        "network_error"|"session_error"|"generic_error"|"timeout_error")
            if (( step_retry_count < max_retries )); then
                log_info "[$workflow_id] Attempting recovery for $error_type (retry $((step_retry_count + 1))/$max_retries)"
                
                # Increment retry count
                workflow_data=$(echo "$workflow_data" | jq \
                    --arg step_index "$step_index" \
                    '.steps['"$step_index"'].retry_count = ((.steps['"$step_index"'].retry_count // 0) + 1)')
                
                # Calculate backoff delay with jitter to prevent thundering herd
                local backoff_delay
                
                if [[ "$error_type" == "timeout_error" ]]; then
                    # Longer delay for timeout errors (exponential backoff with factor 3)
                    backoff_delay=$((BACKOFF_BASE_DELAY * (step_retry_count + 1) * 3))
                else
                    # Standard exponential backoff
                    backoff_delay=$((BACKOFF_BASE_DELAY * (step_retry_count + 1)))
                fi
                
                # Cap at maximum delay
                if [[ $backoff_delay -gt $BACKOFF_MAX_DELAY ]]; then
                    backoff_delay=$BACKOFF_MAX_DELAY
                fi
                
                # Add jitter: random value between -BACKOFF_JITTER_RANGE and +BACKOFF_JITTER_RANGE
                local jitter
                jitter=$(( (RANDOM % (2 * BACKOFF_JITTER_RANGE + 1)) - BACKOFF_JITTER_RANGE ))
                backoff_delay=$((backoff_delay + jitter))
                
                # Ensure minimum delay of 1 second
                if [[ $backoff_delay -lt 1 ]]; then
                    backoff_delay=1
                fi
                
                log_info "[$workflow_id] Waiting ${backoff_delay}s before retry..."
                sleep "$backoff_delay"
                
                # Update workflow data and return recoverable status
                update_workflow_data "$workflow_id" "$workflow_data"
                return 2  # Recoverable error
            else
                log_error "[$workflow_id] Max retries exceeded for $error_type"
                update_workflow_data "$workflow_id" "$workflow_data"
                return 1  # Non-recoverable after max retries
            fi
            ;;
        "usage_limit_error")
            log_info "[$workflow_id] Usage limit encountered, implementing cooldown period"
            local cooldown_delay=300  # 5 minutes
            log_info "[$workflow_id] Waiting ${cooldown_delay}s for usage limit cooldown..."
            sleep "$cooldown_delay"
            
            # Don't count usage limits against retry count
            update_workflow_data "$workflow_id" "$workflow_data"
            return 2  # Recoverable after cooldown
            ;;
        "auth_error"|"syntax_error")
            log_error "[$workflow_id] Non-recoverable error type: $error_type"
            update_workflow_data "$workflow_id" "$workflow_data"
            return 1  # Non-recoverable
            ;;
        *)
            log_warn "[$workflow_id] Unknown error type: $error_type, treating as recoverable"
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
    
    local detailed_status
    detailed_status=$(jq -n \
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
            session_health: (if ($status == "in_progress") then "monitoring" else "idle" end),
            system_resources: null
        }')
    
    # Add resource statistics if monitoring is enabled
    if [[ "$ENABLE_RESOURCE_MONITORING" == "true" ]]; then
        local resource_stats
        resource_stats=$(get_resource_stats "$workflow_id")
        echo "$detailed_status" | jq --argjson resources "$resource_stats" '.system_resources = $resources'
    else
        echo "$detailed_status"
    fi
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