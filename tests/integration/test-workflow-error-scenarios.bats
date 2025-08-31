#!/usr/bin/env bats

# Integration tests for Issue-Merge Workflow Error Scenarios
# Tests comprehensive error handling across the entire workflow system including:
# - Network errors and session failures
# - Usage limit errors and recovery
# - Command syntax and execution errors
# - Recovery mechanisms and retry logic
# - Data persistence during failures
# - User intervention scenarios

load ../test_helper

# Source the workflow module and dependencies
setup() {
    default_setup
    
    # Create test project directory
    export TEST_PROJECT_DIR="$TEST_TEMP_DIR/claude-auto-resume-error-test"
    mkdir -p "$TEST_PROJECT_DIR"
    cd "$TEST_PROJECT_DIR"
    
    # Create complete test environment
    create_error_test_environment
    
    # Set up error testing configuration
    export USE_CLAUNCH="true"
    export CLAUNCH_MODE="tmux"
    export TMUX_SESSION_NAME="claude-error-test"
    export PROJECT_ROOT="$TEST_PROJECT_DIR"
    export SCRIPT_DIR="$BATS_TEST_DIRNAME/../../src"
    
    # Initialize task queue for error testing
    export TASK_QUEUE_ENABLED="true"
    export TASK_QUEUE_DIR="queue"
    export TASK_DEFAULT_TIMEOUT=10  # Shorter timeout for error tests
    export TASK_MAX_RETRIES=3
    
    # Setup comprehensive error simulation mocks
    setup_error_simulation_mocks
    
    # Source modules
    source "$BATS_TEST_DIRNAME/../../src/task-queue.sh"
    source "$BATS_TEST_DIRNAME/../../src/queue/workflow.sh"
    
    # Initialize error test environment
    initialize_error_test_environment
    
    # Set up logging for error tracking
    export LOG_LEVEL="DEBUG"
    mkdir -p "$TEST_TEMP_DIR/error_logs"
}

teardown() {
    default_teardown
}

# Create error testing environment
create_error_test_environment() {
    # Create complete project structure
    mkdir -p {src,tests,config,queue,logs}
    mkdir -p queue/{task-states,backups}
    
    # Create test files
    cat > README.md << 'EOF'
# Error Scenario Test Project
Testing comprehensive error handling in workflow system.
EOF
    
    # Initialize git
    mkdir -p .git/hooks
    echo "ref: refs/heads/main" > .git/HEAD
}

# Setup error simulation mocks
setup_error_simulation_mocks() {
    # Error injection state
    export ERROR_INJECTION_MODE="none"
    export ERROR_INJECT_COUNT=0
    export ERROR_MAX_INJECT=1
    
    # Mock tmux with error injection capabilities
    tmux() {
        case "$1" in
            "has-session")
                if [[ "$ERROR_INJECTION_MODE" == "session_not_found" ]]; then
                    return 1
                else
                    return 0
                fi
                ;;
            "send-keys")
                if [[ "$ERROR_INJECTION_MODE" == "send_keys_failure" ]]; then
                    ((ERROR_INJECT_COUNT++))
                    if [[ $ERROR_INJECT_COUNT -le ${ERROR_MAX_INJECT:-1} ]]; then
                        echo "Error: failed to send keys to session" >&2
                        return 1
                    fi
                fi
                echo "[TMUX] Sent: $3" >> "$TEST_TEMP_DIR/command_log.txt"
                return 0
                ;;
            "capture-pane")
                if [[ "$3" == "-p" ]]; then
                    case "$ERROR_INJECTION_MODE" in
                        "network_error")
                            echo "Error: Connection refused"
                            ;;
                        "usage_limit")
                            echo "Error: Rate limit exceeded. Please wait 5 minutes."
                            ;;
                        "auth_error")
                            echo "Error: Authentication failed - invalid token"
                            ;;
                        "syntax_error")
                            echo "Error: Command not found: /invalid-command"
                            ;;
                        "session_timeout")
                            echo "Error: Session has expired"
                            ;;
                        *)
                            echo "claude>"
                            ;;
                    esac
                fi
                ;;
            *)
                return 0
                ;;
        esac
    }
    export -f tmux
    
    # Mock claunch functions with error injection
    check_session_status() {
        if [[ "$ERROR_INJECTION_MODE" == "no_session" ]]; then
            return 1
        fi
        return 0
    }
    
    start_or_resume_session() {
        local project_dir="$1"
        local create_new="${2:-false}"
        
        if [[ "$ERROR_INJECTION_MODE" == "session_start_failure" ]]; then
            ((ERROR_INJECT_COUNT++))
            if [[ $ERROR_INJECT_COUNT -le ${ERROR_MAX_INJECT:-1} ]]; then
                echo "Failed to start Claude session: connection timeout" >&2
                return 1
            fi
        fi
        
        echo "Session started for $project_dir"
        return 0
    }
    
    send_command_to_session() {
        local command="$1"
        
        if [[ "$ERROR_INJECTION_MODE" == "command_send_failure" ]]; then
            ((ERROR_INJECT_COUNT++))
            if [[ $ERROR_INJECT_COUNT -le ${ERROR_MAX_INJECT:-1} ]]; then
                echo "Failed to send command: network error" >&2
                return 1
            fi
        fi
        
        echo "Command sent: $command"
        return 0
    }
    
    monitor_command_completion() {
        local command="$1"
        local phase="$2"
        local context="${3:-}"
        local timeout="${4:-300}"
        
        case "$ERROR_INJECTION_MODE" in
            "command_timeout")
                ((ERROR_INJECT_COUNT++))
                if [[ $ERROR_INJECT_COUNT -le ${ERROR_MAX_INJECT:-1} ]]; then
                    echo "Command timeout after ${timeout}s: $command" >&2
                    return 1
                fi
                ;;
            "completion_failure")
                ((ERROR_INJECT_COUNT++))
                if [[ $ERROR_INJECT_COUNT -le ${ERROR_MAX_INJECT:-1} ]]; then
                    echo "Command failed: $command" >&2
                    return 1
                fi
                ;;
        esac
        
        # Simulate brief completion time
        sleep 0.1
        return 0
    }
    
    # Export error simulation functions
    export -f check_session_status
    export -f start_or_resume_session
    export -f send_command_to_session
    export -f monitor_command_completion
    
    # Mock sleep to avoid long delays in error tests
    sleep() {
        local duration="$1"
        echo "[SLEEP] Simulated sleep: ${duration}s" >> "$TEST_TEMP_DIR/error_logs/sleep.log"
        if [[ "${MOCK_SKIP_SLEEP:-true}" == "true" ]]; then
            return 0  # Skip actual sleep for faster tests
        else
            command sleep "$duration"
        fi
    }
    export -f sleep
    export MOCK_SKIP_SLEEP="true"
}

# Initialize error test environment
initialize_error_test_environment() {
    # Initialize task queue arrays
    declare -gA TASK_STATES
    declare -gA TASK_METADATA
    declare -gA TASK_RETRY_COUNTS
    declare -gA TASK_TIMESTAMPS
    declare -gA TASK_PRIORITIES
    
    # Create queue structure
    ensure_queue_directories
    
    # Create initial queue file
    echo '{"version": "1.0", "tasks": [], "metadata": {"total_tasks": 0}}' > "$TEST_PROJECT_DIR/queue/task-queue.json"
}

# Helper to create workflow for error testing
create_test_workflow() {
    local issue_id="${1:-999}"
    local config="{\"issue_id\": \"$issue_id\"}"
    create_workflow_task "issue-merge" "$config"
}

# Test: Network error handling
@test "workflow handles network connection errors with retry" {
    export ERROR_INJECTION_MODE="network_error"
    export ERROR_MAX_INJECT=2  # Fail first 2 attempts
    
    local workflow_id=$(create_test_workflow "network-test")
    
    run execute_workflow_task "$workflow_id"
    
    [ "$status" -eq 0 ]  # Should succeed after retries
    assert_output_contains "Attempting recovery for network_error"
    assert_output_contains "Workflow execution completed successfully"
}

@test "workflow fails after max network error retries" {
    export ERROR_INJECTION_MODE="network_error"
    export ERROR_MAX_INJECT=10  # Exceed max retries
    
    local workflow_id=$(create_test_workflow "network-fail")
    
    run execute_workflow_task "$workflow_id"
    
    [ "$status" -eq 1 ]
    assert_output_contains "Maximum workflow retry attempts exceeded"
    
    # Verify workflow status is failed
    local final_status=$(get_task "$workflow_id" "json" | jq -r '.status')
    [ "$final_status" = "failed" ]
}

@test "workflow handles intermittent network connectivity" {
    # Create workflow
    local workflow_id=$(create_test_workflow "intermittent")
    
    # Simulate intermittent failures
    local failure_count=0
    monitor_command_completion() {
        local command="$1"
        ((failure_count++))
        
        # Fail every other attempt
        if [[ $((failure_count % 2)) -eq 1 ]]; then
            return 1
        else
            return 0
        fi
    }
    export -f monitor_command_completion
    
    run execute_workflow_task "$workflow_id"
    
    [ "$status" -eq 0 ]
    assert_output_contains "Workflow execution completed successfully"
}

# Test: Session management errors
@test "workflow handles session not found errors" {
    export ERROR_INJECTION_MODE="session_not_found"
    export ERROR_MAX_INJECT=1
    
    local workflow_id=$(create_test_workflow "session-not-found")
    
    run execute_workflow_task "$workflow_id"
    
    [ "$status" -eq 1 ]
    assert_output_contains "tmux session not found"
}

@test "workflow recovers from session startup failures" {
    export ERROR_INJECTION_MODE="session_start_failure"
    export ERROR_MAX_INJECT=1
    
    local workflow_id=$(create_test_workflow "session-startup")
    
    run execute_workflow_task "$workflow_id"
    
    [ "$status" -eq 0 ]
    assert_output_contains "Session started for"
    assert_output_contains "Workflow execution completed successfully"
}

@test "workflow handles session timeout and recovery" {
    export ERROR_INJECTION_MODE="session_timeout"
    export ERROR_MAX_INJECT=1
    
    local workflow_id=$(create_test_workflow "session-timeout")
    
    run execute_workflow_task "$workflow_id"
    
    [ "$status" -eq 0 ]  # Should recover after session restart
    assert_output_contains "Attempting recovery for session_error"
}

# Test: Usage limit error handling
@test "workflow handles usage limit with cooldown period" {
    export ERROR_INJECTION_MODE="usage_limit"
    export ERROR_MAX_INJECT=1
    
    local workflow_id=$(create_test_workflow "usage-limit")
    
    run execute_workflow_task "$workflow_id"
    
    [ "$status" -eq 0 ]
    assert_output_contains "Usage limit encountered"
    assert_output_contains "Simulated sleep: 300s"  # Cooldown period
    assert_output_contains "Workflow execution completed successfully"
}

@test "usage limit errors don't count against retry limit" {
    export ERROR_INJECTION_MODE="usage_limit"
    export ERROR_MAX_INJECT=5  # Multiple usage limit hits
    
    local workflow_id=$(create_test_workflow "usage-limit-multi")
    
    # Should eventually succeed despite multiple usage limit errors
    run execute_workflow_task "$workflow_id"
    
    [ "$status" -eq 0 ]
    assert_output_contains "Usage limit encountered"
    assert_output_contains "Workflow execution completed successfully"
}

# Test: Authentication and authorization errors
@test "workflow fails immediately on authentication errors" {
    export ERROR_INJECTION_MODE="auth_error"
    
    local workflow_id=$(create_test_workflow "auth-error")
    
    run execute_workflow_task "$workflow_id"
    
    [ "$status" -eq 1 ]
    assert_output_contains "Non-recoverable error type: auth_error"
    
    # Should not have attempted retries
    local error_count=$(get_task "$workflow_id" "json" | jq '.error_history | length')
    [ "$error_count" -eq 1 ]
}

@test "authentication errors are properly classified" {
    local error_messages=(
        "Authentication failed"
        "Unauthorized access"
        "Permission denied"
        "Invalid credentials"
    )
    
    for error_msg in "${error_messages[@]}"; do
        run classify_workflow_error "$error_msg" "/dev 123" "develop"
        [ "$status" -eq 0 ]
        [ "$output" = "auth_error" ]
    done
}

# Test: Command syntax and execution errors
@test "workflow fails on command syntax errors without retry" {
    export ERROR_INJECTION_MODE="syntax_error"
    
    local workflow_id=$(create_test_workflow "syntax-error")
    
    run execute_workflow_task "$workflow_id"
    
    [ "$status" -eq 1 ]
    assert_output_contains "Non-recoverable error type: syntax_error"
}

@test "syntax error classification works correctly" {
    local syntax_errors=(
        "Command not found: /invalid-cmd"
        "Invalid command syntax"
        "Syntax error in command"
        "Unknown command"
    )
    
    for error_msg in "${syntax_errors[@]}"; do
        run classify_workflow_error "$error_msg" "/invalid-cmd" "develop"
        [ "$status" -eq 0 ]
        [ "$output" = "syntax_error" ]
    done
}

# Test: Command timeout scenarios
@test "workflow handles command timeout with retry" {
    export ERROR_INJECTION_MODE="command_timeout"
    export ERROR_MAX_INJECT=2
    
    local workflow_id=$(create_test_workflow "cmd-timeout")
    
    run execute_workflow_task "$workflow_id"
    
    [ "$status" -eq 0 ]
    assert_output_contains "Attempting recovery for generic_error"
    assert_output_contains "Workflow execution completed successfully"
}

@test "command timeout uses appropriate backoff strategy" {
    export ERROR_INJECTION_MODE="command_timeout"
    export ERROR_MAX_INJECT=3
    
    local workflow_id=$(create_test_workflow "timeout-backoff")
    
    run execute_workflow_task "$workflow_id"
    
    [ "$status" -eq 0 ]
    
    # Verify exponential backoff was used
    assert_file_exists "$TEST_TEMP_DIR/error_logs/sleep.log"
    local sleep_log=$(cat "$TEST_TEMP_DIR/error_logs/sleep.log")
    [[ "$sleep_log" =~ "5s" ]]   # First retry
    [[ "$sleep_log" =~ "10s" ]]  # Second retry
}

# Test: Data corruption and persistence errors
@test "workflow handles queue data corruption gracefully" {
    local workflow_id=$(create_test_workflow "corruption-test")
    
    # Corrupt queue data mid-execution
    echo "invalid json" > "$TEST_PROJECT_DIR/queue/task-queue.json"
    
    run execute_workflow_task "$workflow_id"
    
    # Should handle gracefully without crashing
    if [ "$status" -eq 0 ]; then
        assert_output_contains "Workflow execution completed"
    else
        assert_output_contains "invalid JSON" || assert_output_contains "corrupted"
    fi
}

@test "workflow creates backup before risky operations" {
    local workflow_id=$(create_test_workflow "backup-test")
    
    # Execute workflow (should create automatic backup)
    execute_workflow_task "$workflow_id"
    
    # Verify checkpoint/backup was created
    local workflow_data=$(get_task "$workflow_id" "json")
    local checkpoint_count=$(echo "$workflow_data" | jq '.checkpoints | length')
    [ "$checkpoint_count" -gt 0 ]
}

@test "workflow recovers from disk space errors" {
    # Mock filesystem full error
    local original_echo_func=$(declare -f echo)
    echo() {
        if [[ "$*" =~ "queue/task-queue.json" ]]; then
            echo "bash: echo: write error: No space left on device" >&2
            return 1
        else
            $original_echo_func "$@"
        fi
    }
    export -f echo
    
    local workflow_id=$(create_test_workflow "disk-space")
    
    run execute_workflow_task "$workflow_id"
    
    # Should handle disk space error gracefully
    [ "$status" -ne 139 ]  # No segfault
}

# Test: Step-specific error scenarios
@test "workflow handles development step failures correctly" {
    # Create workflow that fails on develop step
    local workflow_id=$(create_test_workflow "dev-fail")
    
    execute_workflow_step() {
        local command="$1"
        local phase="$2"
        
        if [[ "$phase" == "develop" ]]; then
            return 1  # Fail develop step
        else
            return 0
        fi
    }
    export -f execute_workflow_step
    
    run execute_workflow_task "$workflow_id"
    
    [ "$status" -eq 1 ]
    
    # Verify only develop step failed, others weren't attempted
    local workflow_data=$(get_task "$workflow_id" "json")
    local develop_status=$(echo "$workflow_data" | jq -r '.steps[0].status')
    local clear_status=$(echo "$workflow_data" | jq -r '.steps[1].status')
    
    [ "$develop_status" = "failed" ]
    [ "$clear_status" = "pending" ]
}

@test "workflow handles review step specific errors" {
    local workflow_id=$(create_test_workflow "review-fail")
    
    execute_workflow_step() {
        local command="$1"
        local phase="$2"
        
        if [[ "$phase" == "review" ]]; then
            return 1  # Fail review step
        else
            return 0
        fi
    }
    export -f execute_workflow_step
    
    run execute_workflow_task "$workflow_id"
    
    [ "$status" -eq 1 ]
    
    # Verify develop and clear completed, review failed
    local workflow_data=$(get_task "$workflow_id" "json")
    local develop_status=$(echo "$workflow_data" | jq -r '.steps[0].status')
    local clear_status=$(echo "$workflow_data" | jq -r '.steps[1].status')
    local review_status=$(echo "$workflow_data" | jq -r '.steps[2].status')
    local merge_status=$(echo "$workflow_data" | jq -r '.steps[3].status')
    
    [ "$develop_status" = "completed" ]
    [ "$clear_status" = "completed" ]
    [ "$review_status" = "failed" ]
    [ "$merge_status" = "pending" ]
}

# Test: Recovery and resumption scenarios
@test "workflow can be resumed after failure" {
    # Create workflow that fails initially
    local workflow_id=$(create_test_workflow "resume-after-fail")
    
    export ERROR_INJECTION_MODE="command_timeout"
    export ERROR_MAX_INJECT=10  # Force failure
    
    # Initial execution should fail
    execute_workflow_task "$workflow_id"
    
    # Reset error injection
    export ERROR_INJECTION_MODE="none"
    export ERROR_INJECT_COUNT=0
    
    # Resume should succeed
    run resume_workflow "$workflow_id"
    
    [ "$status" -eq 0 ]
    assert_output_contains "Resuming workflow"
}

@test "workflow resume preserves error history" {
    local workflow_id=$(create_test_workflow "error-history")
    
    # Inject error and fail workflow
    export ERROR_INJECTION_MODE="network_error"
    export ERROR_MAX_INJECT=10
    
    execute_workflow_task "$workflow_id"
    
    # Verify error history is preserved
    local workflow_data=$(get_task "$workflow_id" "json")
    local error_count=$(echo "$workflow_data" | jq '.error_history | length')
    [ "$error_count" -gt 0 ]
    
    local last_error_type=$(echo "$workflow_data" | jq -r '.last_error.type')
    [ "$last_error_type" = "network_error" ]
}

@test "workflow can resume from specific step after failure" {
    local workflow_id=$(create_test_workflow "resume-from-step")
    
    # Fail on review step
    execute_workflow_step() {
        local phase="$2"
        if [[ "$phase" == "review" ]]; then
            return 1
        else
            return 0
        fi
    }
    export -f execute_workflow_step
    
    # Execute and fail
    execute_workflow_task "$workflow_id"
    
    # Reset and resume from review step
    execute_workflow_step() { return 0; }
    export -f execute_workflow_step
    
    run resume_workflow_from_step "$workflow_id" 2
    
    [ "$status" -eq 0 ]
    assert_output_contains "Resuming workflow from step 2"
}

# Test: Resource exhaustion scenarios
@test "workflow handles memory exhaustion gracefully" {
    # Create workflow with large data
    local workflow_id=$(create_test_workflow "memory-test")
    
    # Mock memory exhaustion in jq operations
    jq() {
        if [[ "$*" =~ "large_data" ]]; then
            echo "jq: error: out of memory" >&2
            return 1
        else
            command jq "$@"
        fi
    }
    export -f jq
    
    run execute_workflow_task "$workflow_id"
    
    # Should not crash completely
    [ "$status" -ne 139 ]  # No segfault
}

@test "workflow handles CPU timeout scenarios" {
    local workflow_id=$(create_test_workflow "cpu-timeout")
    
    # Mock CPU-intensive operation timeout
    local timeout_occurred=false
    monitor_command_completion() {
        local timeout="$4"
        
        if [[ "${timeout_occurred}" == "false" ]]; then
            timeout_occurred=true
            return 124  # timeout exit code
        else
            return 0
        fi
    }
    export -f monitor_command_completion
    
    run execute_workflow_task "$workflow_id"
    
    [ "$status" -eq 0 ]  # Should recover after timeout
}

# Test: User intervention scenarios
@test "workflow handles manual cancellation gracefully" {
    local workflow_id=$(create_test_workflow "manual-cancel")
    
    # Execute workflow
    execute_workflow_task "$workflow_id" &
    local workflow_pid=$!
    
    # Brief pause then cancel
    sleep 0.1
    cancel_workflow "$workflow_id"
    
    wait "$workflow_pid" || true  # Don't fail if process already ended
    
    # Verify cancellation was recorded
    local workflow_data=$(get_task "$workflow_id" "json")
    local status=$(echo "$workflow_data" | jq -r '.status')
    local cancellation_reason=$(echo "$workflow_data" | jq -r '.cancellation_reason')
    
    [ "$status" = "failed" ]
    [ "$cancellation_reason" = "user_cancelled" ]
}

@test "workflow handles pause/resume during execution" {
    local workflow_id=$(create_test_workflow "pause-resume")
    
    # Start workflow execution in background
    execute_workflow_task "$workflow_id" &
    local workflow_pid=$!
    
    # Brief pause then pause workflow
    sleep 0.1
    pause_workflow "$workflow_id"
    
    # Kill background process
    kill "$workflow_pid" 2>/dev/null || true
    wait "$workflow_pid" 2>/dev/null || true
    
    # Resume workflow
    run resume_workflow "$workflow_id"
    
    [ "$status" -eq 0 ]
    assert_output_contains "Resuming workflow from status: paused"
}

# Test: Error logging and reporting
@test "workflow errors are comprehensively logged" {
    export LOG_LEVEL="DEBUG"
    export ERROR_INJECTION_MODE="network_error"
    export ERROR_MAX_INJECT=2
    
    local workflow_id=$(create_test_workflow "error-logging")
    
    run execute_workflow_task "$workflow_id"
    
    [ "$status" -eq 0 ]
    
    # Verify comprehensive error logging
    assert_output_contains "Workflow step failed"
    assert_output_contains "Error classified as: network_error"
    assert_output_contains "Attempting recovery"
}

@test "error history preserves debugging information" {
    export ERROR_INJECTION_MODE="generic_error"
    export ERROR_MAX_INJECT=3
    
    local workflow_id=$(create_test_workflow "debug-info")
    
    execute_workflow_task "$workflow_id"
    
    # Verify error history contains debugging info
    local workflow_data=$(get_task "$workflow_id" "json")
    local error_history=$(echo "$workflow_data" | jq '.error_history[0]')
    
    local has_error_type=$(echo "$error_history" | jq 'has("error_type")')
    local has_timestamp=$(echo "$error_history" | jq 'has("timestamp")')
    local has_step_index=$(echo "$error_history" | jq 'has("step_index")')
    
    [ "$has_error_type" = "true" ]
    [ "$has_timestamp" = "true" ]
    [ "$has_step_index" = "true" ]
}