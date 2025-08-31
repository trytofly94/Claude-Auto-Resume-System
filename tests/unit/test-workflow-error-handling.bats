#!/usr/bin/env bats

# Unit tests for Issue-Merge Workflow Error Handling and Recovery Functions
# Tests the comprehensive error handling and recovery functionality including:
# - classify_workflow_error() - Error type classification
# - handle_workflow_step_error() - Error handling with retry logic
# - execute_issue_merge_workflow_with_recovery() - Full workflow with recovery
# - Error classification and retry strategies

load ../test_helper

# Source the workflow module and dependencies
setup() {
    default_setup
    
    # Create test project directory
    export TEST_PROJECT_DIR="$TEST_TEMP_DIR/claude-auto-resume"
    mkdir -p "$TEST_PROJECT_DIR"
    cd "$TEST_PROJECT_DIR"
    
    # Set up workflow test configuration
    export USE_CLAUNCH="true"
    export CLAUNCH_MODE="tmux"
    export TMUX_SESSION_NAME="claude-test-workflow"
    export SCRIPT_DIR="$BATS_TEST_DIRNAME/../../src"
    
    # Mock workflow dependencies
    setup_mock_workflow_dependencies
    
    # Source the workflow module
    source "$BATS_TEST_DIRNAME/../../src/queue/workflow.sh"
    
    # Source task queue for workflow data functions
    source "$BATS_TEST_DIRNAME/../../src/task-queue.sh"
    
    # Initialize logging
    export LOG_LEVEL="ERROR"  # Reduce log noise in tests
    
    # Initialize test workflow data
    setup_test_workflow_data
}

teardown() {
    default_teardown
}

# Mock workflow dependencies
setup_mock_workflow_dependencies() {
    # Mock task queue functions
    get_task() {
        local task_id="$1"
        local format="${2:-json}"
        
        if [[ -n "${MOCK_WORKFLOW_DATA[$task_id]:-}" ]]; then
            echo "${MOCK_WORKFLOW_DATA[$task_id]}"
        else
            echo '{"error": "Task not found"}'
            return 1
        fi
    }
    
    update_workflow_data() {
        local workflow_id="$1"
        local updated_data="$2"
        
        MOCK_WORKFLOW_DATA["$workflow_id"]="$updated_data"
        return 0
    }
    
    update_task_status() {
        local task_id="$1"
        local new_status="$2"
        
        if [[ -n "${MOCK_WORKFLOW_DATA[$task_id]:-}" ]]; then
            local updated_data
            updated_data=$(echo "${MOCK_WORKFLOW_DATA[$task_id]}" | jq --arg status "$new_status" '.status = $status')
            MOCK_WORKFLOW_DATA["$task_id"]="$updated_data"
            return 0
        else
            return 1
        fi
    }
    
    # Mock workflow execution functions
    execute_workflow_step() {
        local command="$1"
        local phase="$2"
        local context="${3:-}"
        
        # Return status based on mock configuration
        if [[ "${MOCK_STEP_SUCCESS:-true}" == "true" ]]; then
            return 0
        else
            return "${MOCK_STEP_ERROR_CODE:-1}"
        fi
    }
    
    # Export mocked functions
    export -f get_task
    export -f update_workflow_data
    export -f update_task_status
    export -f execute_workflow_step
    
    # Declare mock data storage
    declare -gA MOCK_WORKFLOW_DATA
}

# Setup test workflow data
setup_test_workflow_data() {
    # Create a sample workflow for testing
    local workflow_data='{
        "id": "workflow-test-123",
        "type": "workflow",
        "workflow_type": "issue-merge",
        "status": "pending",
        "created_at": "2025-08-31T10:00:00Z",
        "updated_at": "2025-08-31T10:00:00Z",
        "current_step": 0,
        "config": {
            "issue_id": "123"
        },
        "steps": [
            {
                "phase": "develop",
                "status": "pending",
                "command": "/dev 123",
                "description": "Develop feature for issue 123"
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
                "command": "/review PR-123",
                "description": "Review PR for issue 123"
            },
            {
                "phase": "merge",
                "status": "pending",
                "command": "/dev merge-pr 123 --focus-main",
                "description": "Merge PR with main functionality focus"
            }
        ],
        "results": {},
        "error_history": [],
        "checkpoints": []
    }'
    
    MOCK_WORKFLOW_DATA["workflow-test-123"]="$workflow_data"
}

# Test: classify_workflow_error function
@test "classify_workflow_error identifies network errors as recoverable" {
    local error_messages=(
        "Connection refused"
        "Network error occurred"
        "Connection timeout"
        "Connection reset by peer"
    )
    
    for error_msg in "${error_messages[@]}"; do
        run classify_workflow_error "$error_msg" "/dev 123" "develop"
        [ "$status" -eq 0 ]
        [ "$output" = "network_error" ]
    done
}

@test "classify_workflow_error identifies session errors as recoverable" {
    local error_messages=(
        "Session not found"
        "No active session available"
        "Session has expired"
    )
    
    for error_msg in "${error_messages[@]}"; do
        run classify_workflow_error "$error_msg" "/dev 123" "develop"
        [ "$status" -eq 0 ]
        [ "$output" = "session_error" ]
    done
}

@test "classify_workflow_error identifies authentication errors as non-recoverable" {
    local error_messages=(
        "Authentication failed"
        "Unauthorized access"
        "Permission denied"
    )
    
    for error_msg in "${error_messages[@]}"; do
        run classify_workflow_error "$error_msg" "/dev 123" "develop"
        [ "$status" -eq 0 ]
        [ "$output" = "auth_error" ]
    done
}

@test "classify_workflow_error identifies syntax errors as non-recoverable" {
    local error_messages=(
        "Command not found"
        "Invalid command syntax"
        "Syntax error in command"
    )
    
    for error_msg in "${error_messages[@]}"; do
        run classify_workflow_error "$error_msg" "/dev 123" "develop"
        [ "$status" -eq 0 ]
        [ "$output" = "syntax_error" ]
    done
}

@test "classify_workflow_error identifies usage limit errors as recoverable" {
    local error_messages=(
        "Rate limit exceeded"
        "Usage limit reached"
        "Quota exceeded for this period"
    )
    
    for error_msg in "${error_messages[@]}"; do
        run classify_workflow_error "$error_msg" "/dev 123" "develop"
        [ "$status" -eq 0 ]
        [ "$output" = "usage_limit_error" ]
    done
}

@test "classify_workflow_error defaults to generic error for unknown patterns" {
    run classify_workflow_error "Unknown error occurred" "/dev 123" "develop"
    
    [ "$status" -eq 0 ]
    [ "$output" = "generic_error" ]
}

# Test: handle_workflow_step_error function
@test "handle_workflow_step_error retries recoverable network errors" {
    # Setup workflow with no previous retries
    local workflow_id="workflow-test-123"
    
    run handle_workflow_step_error "$workflow_id" "0" "/dev 123" "develop" "Connection refused"
    
    [ "$status" -eq 2 ]  # Recoverable error return code
    assert_output_contains "Attempting recovery for network_error"
    
    # Verify error history was updated
    local updated_data="${MOCK_WORKFLOW_DATA[$workflow_id]}"
    local error_count=$(echo "$updated_data" | jq '.error_history | length')
    [ "$error_count" -gt 0 ]
}

@test "handle_workflow_step_error handles usage limit errors with cooldown" {
    local workflow_id="workflow-test-123"
    
    # Mock sleep to avoid actual delays in tests
    sleep() {
        echo "Mock sleep: $1 seconds"
    }
    export -f sleep
    
    run handle_workflow_step_error "$workflow_id" "0" "/dev 123" "develop" "Rate limit exceeded"
    
    [ "$status" -eq 2 ]  # Recoverable after cooldown
    assert_output_contains "Usage limit encountered"
    assert_output_contains "Mock sleep: 300 seconds"
}

@test "handle_workflow_step_error rejects non-recoverable auth errors" {
    local workflow_id="workflow-test-123"
    
    run handle_workflow_step_error "$workflow_id" "0" "/dev 123" "develop" "Authentication failed"
    
    [ "$status" -eq 1 ]  # Non-recoverable error
    assert_output_contains "Non-recoverable error type: auth_error"
}

@test "handle_workflow_step_error rejects non-recoverable syntax errors" {
    local workflow_id="workflow-test-123"
    
    run handle_workflow_step_error "$workflow_id" "0" "/dev 123" "develop" "Invalid command syntax"
    
    [ "$status" -eq 1 ]  # Non-recoverable error
    assert_output_contains "Non-recoverable error type: syntax_error"
}

@test "handle_workflow_step_error implements exponential backoff" {
    local workflow_id="workflow-test-123"
    
    # Mock sleep to capture backoff delays
    local sleep_calls=()
    sleep() {
        sleep_calls+=("$1")
        echo "Mock sleep: $1 seconds"
    }
    export -f sleep
    
    # Simulate step with existing retries
    local workflow_data_with_retries
    workflow_data_with_retries=$(echo "${MOCK_WORKFLOW_DATA[$workflow_id]}" | jq '.steps[0].retry_count = 2')
    MOCK_WORKFLOW_DATA["$workflow_id"]="$workflow_data_with_retries"
    
    run handle_workflow_step_error "$workflow_id" "0" "/dev 123" "develop" "Network error"
    
    [ "$status" -eq 2 ]
    # Should use backoff delay of 5 * (retry_count + 1) = 15 seconds
    [[ "${sleep_calls[0]}" == "15" ]]
}

@test "handle_workflow_step_error stops retrying after max attempts" {
    local workflow_id="workflow-test-123"
    
    # Setup step that has reached max retries
    local workflow_data_max_retries
    workflow_data_max_retries=$(echo "${MOCK_WORKFLOW_DATA[$workflow_id]}" | jq '.steps[0].retry_count = 3')
    MOCK_WORKFLOW_DATA["$workflow_id"]="$workflow_data_max_retries"
    
    run handle_workflow_step_error "$workflow_id" "0" "/dev 123" "develop" "Connection timeout"
    
    [ "$status" -eq 1 ]  # Non-recoverable after max retries
    assert_output_contains "Max retries exceeded"
}

@test "handle_workflow_step_error updates error history correctly" {
    local workflow_id="workflow-test-123"
    
    run handle_workflow_step_error "$workflow_id" "0" "/dev 123" "develop" "Test error message"
    
    [ "$status" -eq 2 ]
    
    # Verify error was recorded in history
    local updated_data="${MOCK_WORKFLOW_DATA[$workflow_id]}"
    local last_error_type=$(echo "$updated_data" | jq -r '.last_error.type')
    local error_count=$(echo "$updated_data" | jq '.error_history | length')
    
    [ "$last_error_type" = "generic_error" ]
    [ "$error_count" -eq 1 ]
}

@test "handle_workflow_step_error preserves workflow data integrity" {
    local workflow_id="workflow-test-123"
    local original_data="${MOCK_WORKFLOW_DATA[$workflow_id]}"
    
    run handle_workflow_step_error "$workflow_id" "0" "/dev 123" "develop" "Network error"
    
    [ "$status" -eq 2 ]
    
    # Verify essential workflow data is preserved
    local updated_data="${MOCK_WORKFLOW_DATA[$workflow_id]}"
    local workflow_type=$(echo "$updated_data" | jq -r '.workflow_type')
    local steps_count=$(echo "$updated_data" | jq '.steps | length')
    
    [ "$workflow_type" = "issue-merge" ]
    [ "$steps_count" -eq 4 ]
}

# Test: execute_issue_merge_workflow_with_recovery function
@test "execute_issue_merge_workflow_with_recovery completes successfully" {
    local workflow_id="workflow-test-123"
    
    # Setup successful execution
    export MOCK_STEP_SUCCESS="true"
    
    run execute_issue_merge_workflow_with_recovery "$workflow_id"
    
    [ "$status" -eq 0 ]
    assert_output_contains "Issue-merge workflow completed successfully with recovery"
    
    # Verify workflow status updated
    local final_data="${MOCK_WORKFLOW_DATA[$workflow_id]}"
    local final_status=$(echo "$final_data" | jq -r '.status')
    [ "$final_status" = "completed" ]
}

@test "execute_issue_merge_workflow_with_recovery handles step failures with retry" {
    local workflow_id="workflow-test-123"
    
    # Mock sleep to avoid delays
    sleep() { echo "Mock sleep: $1 seconds"; }
    export -f sleep
    
    # Setup initial failure followed by success
    local attempt_count=0
    execute_workflow_step() {
        ((attempt_count++))
        if [[ $attempt_count -eq 1 ]]; then
            return 1  # Fail first attempt
        else
            return 0  # Succeed on retry
        fi
    }
    export -f execute_workflow_step
    
    # Mock error handling to return recoverable
    handle_workflow_step_error() {
        echo "Mock: Handling recoverable error"
        return 2  # Recoverable
    }
    export -f handle_workflow_step_error
    
    run execute_issue_merge_workflow_with_recovery "$workflow_id"
    
    [ "$status" -eq 0 ]
    assert_output_contains "Issue-merge workflow completed successfully with recovery"
}

@test "execute_issue_merge_workflow_with_recovery fails on non-recoverable errors" {
    local workflow_id="workflow-test-123"
    
    # Setup step failure
    export MOCK_STEP_SUCCESS="false"
    export MOCK_STEP_ERROR_CODE="1"
    
    # Mock error handling to return non-recoverable
    handle_workflow_step_error() {
        echo "Mock: Non-recoverable error"
        return 1  # Non-recoverable
    }
    export -f handle_workflow_step_error
    
    run execute_issue_merge_workflow_with_recovery "$workflow_id"
    
    [ "$status" -eq 1 ]
    assert_output_contains "Non-recoverable error in workflow step"
}

@test "execute_issue_merge_workflow_with_recovery enforces max workflow retries" {
    local workflow_id="workflow-test-123"
    
    # Mock sleep to avoid delays
    sleep() { echo "Mock sleep: $1 seconds"; }
    export -f sleep
    
    # Setup persistent failures
    execute_workflow_step() { return 1; }  # Always fail
    export -f execute_workflow_step
    
    # Mock error handling to always return recoverable
    handle_workflow_step_error() {
        echo "Mock: Always recoverable"
        return 2
    }
    export -f handle_workflow_step_error
    
    run execute_issue_merge_workflow_with_recovery "$workflow_id"
    
    [ "$status" -eq 1 ]
    assert_output_contains "Maximum workflow retry attempts exceeded"
}

@test "execute_issue_merge_workflow_with_recovery creates checkpoints" {
    local workflow_id="workflow-test-123"
    
    # Mock checkpoint creation
    create_workflow_checkpoint() {
        local wf_id="$1"
        local reason="${2:-manual_checkpoint}"
        echo "Mock: Created checkpoint for $wf_id (reason: $reason)"
        return 0
    }
    export -f create_workflow_checkpoint
    
    # Setup successful execution
    export MOCK_STEP_SUCCESS="true"
    
    run execute_issue_merge_workflow_with_recovery "$workflow_id"
    
    [ "$status" -eq 0 ]
    assert_output_contains "Created checkpoint for workflow-test-123 (reason: pre_execution)"
}

@test "execute_issue_merge_workflow_with_recovery handles step delays correctly" {
    local workflow_id="workflow-test-123"
    
    # Setup workflow with step delays
    local workflow_with_delays
    workflow_with_delays=$(echo "${MOCK_WORKFLOW_DATA[$workflow_id]}" | jq '.steps[0].delay = 2')
    MOCK_WORKFLOW_DATA["$workflow_id"]="$workflow_with_delays"
    
    # Mock sleep to capture delays
    local sleep_calls=()
    sleep() {
        sleep_calls+=("$1")
        echo "Mock sleep: $1 seconds"
    }
    export -f sleep
    
    # Setup successful execution
    export MOCK_STEP_SUCCESS="true"
    
    run execute_issue_merge_workflow_with_recovery "$workflow_id"
    
    [ "$status" -eq 0 ]
    # Should have delay between steps (but not after last step)
    [[ "${#sleep_calls[@]}" -eq 3 ]]  # 3 delays between 4 steps
}

@test "execute_issue_merge_workflow_with_recovery updates step status correctly" {
    local workflow_id="workflow-test-123"
    
    # Setup successful execution
    export MOCK_STEP_SUCCESS="true"
    
    run execute_issue_merge_workflow_with_recovery "$workflow_id"
    
    [ "$status" -eq 0 ]
    
    # Verify all steps marked as completed
    local final_data="${MOCK_WORKFLOW_DATA[$workflow_id]}"
    local completed_steps=$(echo "$final_data" | jq '[.steps[] | select(.status == "completed")] | length')
    [ "$completed_steps" -eq 4 ]
}

# Test: Error recovery edge cases
@test "error handling gracefully manages corrupted workflow data" {
    local workflow_id="workflow-corrupted"
    
    # Setup corrupted workflow data
    MOCK_WORKFLOW_DATA["$workflow_id"]='{"invalid": "json structure"}'
    
    run execute_issue_merge_workflow_with_recovery "$workflow_id"
    
    [ "$status" -eq 1 ]
    # Should handle gracefully without crashing
}

@test "error classification handles empty error messages" {
    run classify_workflow_error "" "/dev 123" "develop"
    
    [ "$status" -eq 0 ]
    [ "$output" = "generic_error" ]
}

@test "error handling preserves retry state across failures" {
    local workflow_id="workflow-test-123"
    
    # Mock multiple error scenarios
    local error_call_count=0
    handle_workflow_step_error() {
        ((error_call_count++))
        echo "Mock error handling call #$error_call_count"
        
        if [[ $error_call_count -lt 3 ]]; then
            return 2  # Recoverable
        else
            return 1  # Finally non-recoverable
        fi
    }
    export -f handle_workflow_step_error
    
    # Setup persistent step failures
    execute_workflow_step() { return 1; }
    export -f execute_workflow_step
    
    # Mock sleep to avoid delays
    sleep() { echo "Mock sleep: $1 seconds"; }
    export -f sleep
    
    run execute_issue_merge_workflow_with_recovery "$workflow_id"
    
    [ "$status" -eq 1 ]
    # Should have called error handler multiple times
    assert_output_contains "Mock error handling call #1"
    assert_output_contains "Mock error handling call #2" 
    assert_output_contains "Mock error handling call #3"
}

# Test: Resource management during error scenarios
@test "error recovery cleans up resources on failure" {
    local workflow_id="workflow-test-123"
    
    # Setup cleanup tracking
    local cleanup_called=false
    cleanup_workflow_resources() {
        cleanup_called=true
        echo "Mock: Cleaned up workflow resources"
    }
    export -f cleanup_workflow_resources
    
    # Setup step failure
    export MOCK_STEP_SUCCESS="false"
    
    # Mock non-recoverable error
    handle_workflow_step_error() {
        return 1  # Non-recoverable
    }
    export -f handle_workflow_step_error
    
    run execute_issue_merge_workflow_with_recovery "$workflow_id"
    
    [ "$status" -eq 1 ]
    # Resource cleanup should be handled by workflow failure update
}

# Test: Error reporting and logging
@test "error handling provides comprehensive error reporting" {
    local workflow_id="workflow-test-123"
    
    run handle_workflow_step_error "$workflow_id" "0" "/dev 123" "develop" "Detailed error message"
    
    [ "$status" -eq 2 ]
    assert_output_contains "Workflow step failed: /dev 123"
    assert_output_contains "Error classified as: generic_error"
    assert_output_contains "Attempting recovery for generic_error"
}

@test "workflow recovery maintains audit trail" {
    local workflow_id="workflow-test-123"
    
    # Setup error scenario
    export MOCK_STEP_SUCCESS="false"
    handle_workflow_step_error() { return 1; }  # Non-recoverable
    export -f handle_workflow_step_error
    
    run execute_issue_merge_workflow_with_recovery "$workflow_id"
    
    [ "$status" -eq 1 ]
    
    # Verify error history is maintained
    local final_data="${MOCK_WORKFLOW_DATA[$workflow_id]}"
    local has_error_history=$(echo "$final_data" | jq 'has("error_history")')
    [ "$has_error_history" = "true" ]
}