#!/usr/bin/env bats

# Unit tests for Issue-Merge Workflow Status Tracking and Checkpoint Functions
# Tests the workflow state management functionality including:
# - get_workflow_detailed_status() - Detailed progress and timing information
# - create_workflow_checkpoint() - State persistence and recovery points
# - resume_workflow_from_step() - Workflow resumption capabilities
# - Progress calculation and ETA estimation

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
    task_exists() {
        local task_id="$1"
        [[ -n "${MOCK_WORKFLOW_DATA[$task_id]:-}" ]]
    }
    
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
    
    generate_task_id() {
        local prefix="${1:-task}"
        echo "${prefix}-$(date +%s)-$$"
    }
    
    # Mock workflow execution functions
    execute_workflow_task() {
        local workflow_id="$1"
        echo "Mock: Executing workflow task $workflow_id"
        return 0
    }
    
    # Export mocked functions
    export -f task_exists
    export -f get_task
    export -f update_workflow_data
    export -f update_task_status
    export -f generate_task_id
    export -f execute_workflow_task
    
    # Declare mock data storage
    declare -gA MOCK_WORKFLOW_DATA
}

# Setup test workflow data
setup_test_workflow_data() {
    # Create workflows in different states for testing
    
    # Pending workflow
    local pending_workflow='{
        "id": "workflow-pending",
        "type": "workflow",
        "workflow_type": "issue-merge",
        "status": "pending",
        "created_at": "2025-08-31T10:00:00Z",
        "updated_at": "2025-08-31T10:00:00Z",
        "current_step": 0,
        "config": { "issue_id": "123" },
        "steps": [
            {"phase": "develop", "status": "pending", "command": "/dev 123"},
            {"phase": "clear", "status": "pending", "command": "/clear"},
            {"phase": "review", "status": "pending", "command": "/review PR-123"},
            {"phase": "merge", "status": "pending", "command": "/dev merge-pr 123"}
        ],
        "results": {},
        "error_history": [],
        "checkpoints": []
    }'
    
    # In-progress workflow
    local in_progress_workflow='{
        "id": "workflow-in-progress",
        "type": "workflow", 
        "workflow_type": "issue-merge",
        "status": "in_progress",
        "created_at": "2025-08-31T10:00:00Z",
        "updated_at": "2025-08-31T10:05:00Z",
        "current_step": 2,
        "config": { "issue_id": "456" },
        "steps": [
            {"phase": "develop", "status": "completed", "command": "/dev 456", "completed_at": "2025-08-31T10:02:00Z"},
            {"phase": "clear", "status": "completed", "command": "/clear", "completed_at": "2025-08-31T10:03:00Z"}, 
            {"phase": "review", "status": "in_progress", "command": "/review PR-456", "started_at": "2025-08-31T10:04:00Z"},
            {"phase": "merge", "status": "pending", "command": "/dev merge-pr 456"}
        ],
        "results": {"step_0": "success", "step_1": "success"},
        "error_history": [],
        "checkpoints": []
    }'
    
    # Completed workflow
    local completed_workflow='{
        "id": "workflow-completed",
        "type": "workflow",
        "workflow_type": "issue-merge", 
        "status": "completed",
        "created_at": "2025-08-31T09:00:00Z",
        "updated_at": "2025-08-31T09:15:00Z",
        "completed_at": "2025-08-31T09:15:00Z",
        "current_step": 4,
        "config": { "issue_id": "789" },
        "steps": [
            {"phase": "develop", "status": "completed", "command": "/dev 789", "completed_at": "2025-08-31T09:05:00Z"},
            {"phase": "clear", "status": "completed", "command": "/clear", "completed_at": "2025-08-31T09:07:00Z"},
            {"phase": "review", "status": "completed", "command": "/review PR-789", "completed_at": "2025-08-31T09:12:00Z"},
            {"phase": "merge", "status": "completed", "command": "/dev merge-pr 789", "completed_at": "2025-08-31T09:15:00Z"}
        ],
        "results": {"step_0": "success", "step_1": "success", "step_2": "success", "step_3": "success"},
        "error_history": [],
        "checkpoints": []
    }'
    
    # Failed workflow with errors
    local failed_workflow='{
        "id": "workflow-failed",
        "type": "workflow",
        "workflow_type": "issue-merge",
        "status": "failed", 
        "created_at": "2025-08-31T11:00:00Z",
        "updated_at": "2025-08-31T11:08:00Z",
        "current_step": 1,
        "config": { "issue_id": "999" },
        "steps": [
            {"phase": "develop", "status": "completed", "command": "/dev 999", "completed_at": "2025-08-31T11:05:00Z"},
            {"phase": "clear", "status": "failed", "command": "/clear", "failed_at": "2025-08-31T11:08:00Z"},
            {"phase": "review", "status": "pending", "command": "/review PR-999"},
            {"phase": "merge", "status": "pending", "command": "/dev merge-pr 999"}
        ],
        "results": {"step_0": "success"},
        "error_history": [
            {
                "step_index": 1,
                "error_type": "session_error",
                "error_output": "No active session",
                "timestamp": "2025-08-31T11:08:00Z",
                "retry_count": 3
            }
        ],
        "last_error": {
            "type": "session_error",
            "step_index": 1,
            "timestamp": "2025-08-31T11:08:00Z"
        }
    }'
    
    MOCK_WORKFLOW_DATA["workflow-pending"]="$pending_workflow"
    MOCK_WORKFLOW_DATA["workflow-in-progress"]="$in_progress_workflow"
    MOCK_WORKFLOW_DATA["workflow-completed"]="$completed_workflow"
    MOCK_WORKFLOW_DATA["workflow-failed"]="$failed_workflow"
}

# Test: get_workflow_status basic functionality
@test "get_workflow_status returns basic workflow information" {
    run get_workflow_status "workflow-pending"
    
    [ "$status" -eq 0 ]
    
    local workflow_id=$(echo "$output" | jq -r '.workflow_id')
    local workflow_type=$(echo "$output" | jq -r '.workflow_type')
    local status=$(echo "$output" | jq -r '.status')
    local current_step=$(echo "$output" | jq -r '.current_step')
    local total_steps=$(echo "$output" | jq -r '.total_steps')
    
    [ "$workflow_id" = "workflow-pending" ]
    [ "$workflow_type" = "issue-merge" ]
    [ "$status" = "pending" ]
    [ "$current_step" = "0" ]
    [ "$total_steps" = "4" ]
}

@test "get_workflow_status calculates progress percentage correctly" {
    run get_workflow_status "workflow-in-progress"
    
    [ "$status" -eq 0 ]
    
    local progress=$(echo "$output" | jq -r '.progress_percent')
    # 2 steps out of 4 = 50%
    [ "$progress" = "50.00" ]
}

@test "get_workflow_status handles completed workflows" {
    run get_workflow_status "workflow-completed"
    
    [ "$status" -eq 0 ]
    
    local status=$(echo "$output" | jq -r '.status')
    local current_step=$(echo "$output" | jq -r '.current_step')
    local progress=$(echo "$output" | jq -r '.progress_percent')
    
    [ "$status" = "completed" ]
    [ "$current_step" = "4" ]
    [ "$progress" = "100.00" ]
}

@test "get_workflow_status handles non-existent workflows" {
    run get_workflow_status "workflow-nonexistent"
    
    [ "$status" -eq 1 ]
    
    local error_message=$(echo "$output" | jq -r '.error')
    [ "$error_message" = "Workflow not found" ]
}

# Test: get_workflow_detailed_status comprehensive functionality
@test "get_workflow_detailed_status provides comprehensive workflow information" {
    run get_workflow_detailed_status "workflow-in-progress"
    
    [ "$status" -eq 0 ]
    
    # Verify all required sections are present
    local has_progress=$(echo "$output" | jq 'has("progress")')
    local has_timing=$(echo "$output" | jq 'has("timing")')
    local has_errors=$(echo "$output" | jq 'has("errors")')
    local has_session_health=$(echo "$output" | jq 'has("session_health")')
    
    [ "$has_progress" = "true" ]
    [ "$has_timing" = "true" ]
    [ "$has_errors" = "true" ]
    [ "$has_session_health" = "true" ]
}

@test "get_workflow_detailed_status includes current step information" {
    run get_workflow_detailed_status "workflow-in-progress"
    
    [ "$status" -eq 0 ]
    
    local current_step_info=$(echo "$output" | jq '.progress.current_step_info')
    local current_phase=$(echo "$current_step_info" | jq -r '.phase')
    local current_status=$(echo "$current_step_info" | jq -r '.status')
    
    [ "$current_phase" = "review" ]
    [ "$current_status" = "in_progress" ]
}

@test "get_workflow_detailed_status calculates elapsed time correctly" {
    # Mock date command to provide consistent time
    date() {
        case "$*" in
            "-Iseconds") echo "2025-08-31T10:10:00Z" ;;
            "-d"*"+%s") echo "1693478400" ;;  # Mock timestamp
            "+%s") echo "1693478400" ;;       # Mock current timestamp
            *) command date "$@" ;;
        esac
    }
    export -f date
    
    run get_workflow_detailed_status "workflow-in-progress"
    
    [ "$status" -eq 0 ]
    
    local elapsed_seconds=$(echo "$output" | jq '.timing.elapsed_seconds')
    [ "$elapsed_seconds" -ge 0 ]
}

@test "get_workflow_detailed_status estimates completion time for in-progress workflows" {
    # Mock date and bc for time calculations
    date() {
        case "$*" in
            "-Iseconds") echo "2025-08-31T10:10:00Z" ;;
            "-d"*) 
                if [[ "$*" =~ "2025-08-31T10:00:00Z" ]]; then
                    echo "1693477800"
                elif [[ "$*" =~ "@" ]]; then
                    echo "2025-08-31T10:20:00Z"
                fi
                ;;
            "+%s") echo "1693478400" ;;  # 10 minutes after start
            *) command date "$@" ;;
        esac
    }
    export -f date
    
    # Mock bc for math
    bc() {
        case "$*" in
            *) echo "50.00" ;;
        esac
    }
    export -f bc
    
    run get_workflow_detailed_status "workflow-in-progress"
    
    [ "$status" -eq 0 ]
    
    local estimated_completion=$(echo "$output" | jq '.timing.estimated_completion')
    [ "$estimated_completion" != "null" ]
}

@test "get_workflow_detailed_status reports error information correctly" {
    run get_workflow_detailed_status "workflow-failed"
    
    [ "$status" -eq 0 ]
    
    local error_count=$(echo "$output" | jq '.errors.count')
    local last_error_type=$(echo "$output" | jq -r '.errors.last_error.type')
    
    [ "$error_count" -eq 1 ]
    [ "$last_error_type" = "session_error" ]
}

@test "get_workflow_detailed_status handles workflows with no errors" {
    run get_workflow_detailed_status "workflow-pending"
    
    [ "$status" -eq 0 ]
    
    local error_count=$(echo "$output" | jq '.errors.count')
    local last_error=$(echo "$output" | jq '.errors.last_error')
    
    [ "$error_count" -eq 0 ]
    [ "$last_error" = "null" ]
}

@test "get_workflow_detailed_status sets appropriate session health status" {
    # In-progress workflow should show "monitoring"
    run get_workflow_detailed_status "workflow-in-progress"
    [ "$status" -eq 0 ]
    local session_health=$(echo "$output" | jq -r '.session_health')
    [ "$session_health" = "monitoring" ]
    
    # Completed workflow should show "idle"
    run get_workflow_detailed_status "workflow-completed"
    [ "$status" -eq 0 ]
    session_health=$(echo "$output" | jq -r '.session_health')
    [ "$session_health" = "idle" ]
}

# Test: create_workflow_checkpoint functionality
@test "create_workflow_checkpoint creates checkpoint with current state" {
    # Mock generate_task_id for consistent checkpoint ID
    generate_task_id() {
        echo "checkpoint-test-123"
    }
    export -f generate_task_id
    
    run create_workflow_checkpoint "workflow-pending" "manual_test"
    
    [ "$status" -eq 0 ]
    [ "$output" = "checkpoint-test-123" ]
    
    # Verify checkpoint was added to workflow data
    local updated_data="${MOCK_WORKFLOW_DATA["workflow-pending"]}"
    local checkpoint_count=$(echo "$updated_data" | jq '.checkpoints | length')
    local last_checkpoint_reason=$(echo "$updated_data" | jq -r '.last_checkpoint.reason')
    
    [ "$checkpoint_count" -eq 1 ]
    [ "$last_checkpoint_reason" = "manual_test" ]
}

@test "create_workflow_checkpoint includes system information" {
    # Mock environment variables
    export CLAUNCH_MODE="tmux"
    export TMUX_SESSION_NAME="test-session"
    
    generate_task_id() {
        echo "checkpoint-system-info"
    }
    export -f generate_task_id
    
    run create_workflow_checkpoint "workflow-pending" "system_info_test"
    
    [ "$status" -eq 0 ]
    
    # Verify system information is captured
    local updated_data="${MOCK_WORKFLOW_DATA["workflow-pending"]}"
    local checkpoint_data=$(echo "$updated_data" | jq '.checkpoints[0]')
    local system_claunch_mode=$(echo "$checkpoint_data" | jq -r '.system_info.claunch_mode')
    local system_session_name=$(echo "$checkpoint_data" | jq -r '.system_info.session_name')
    
    [ "$system_claunch_mode" = "tmux" ]
    [ "$system_session_name" = "test-session" ]
}

@test "create_workflow_checkpoint handles non-existent workflows" {
    run create_workflow_checkpoint "workflow-nonexistent" "test"
    
    [ "$status" -eq 1 ]
    assert_output_contains "Workflow not found"
}

@test "create_workflow_checkpoint preserves existing checkpoints" {
    # Create first checkpoint
    generate_task_id() {
        echo "checkpoint-first"
    }
    export -f generate_task_id
    
    create_workflow_checkpoint "workflow-pending" "first_checkpoint"
    
    # Create second checkpoint
    generate_task_id() {
        echo "checkpoint-second" 
    }
    export -f generate_task_id
    
    create_workflow_checkpoint "workflow-pending" "second_checkpoint"
    
    # Verify both checkpoints exist
    local updated_data="${MOCK_WORKFLOW_DATA["workflow-pending"]}"
    local checkpoint_count=$(echo "$updated_data" | jq '.checkpoints | length')
    
    [ "$checkpoint_count" -eq 2 ]
}

# Test: pause_workflow functionality
@test "pause_workflow changes workflow status to paused" {
    run pause_workflow "workflow-pending"
    
    [ "$status" -eq 0 ]
    assert_output_contains "Paused workflow: workflow-pending"
    
    # Verify status was updated
    local updated_data="${MOCK_WORKFLOW_DATA["workflow-pending"]}"
    local status=$(echo "$updated_data" | jq -r '.status')
    [ "$status" = "paused" ]
}

@test "pause_workflow handles non-existent workflows" {
    run pause_workflow "workflow-nonexistent"
    
    [ "$status" -eq 1 ]
    assert_output_contains "Workflow not found"
}

# Test: resume_workflow functionality
@test "resume_workflow resumes from paused state" {
    # First pause the workflow
    pause_workflow "workflow-pending"
    
    run resume_workflow "workflow-pending"
    
    [ "$status" -eq 0 ]
    assert_output_contains "Resuming workflow from status: paused"
    
    # Verify workflow was executed
    assert_output_contains "Mock: Executing workflow task workflow-pending"
}

@test "resume_workflow resumes from failed state" {
    run resume_workflow "workflow-failed"
    
    [ "$status" -eq 0 ]
    assert_output_contains "Resuming workflow from status: failed"
}

@test "resume_workflow rejects invalid state transitions" {
    run resume_workflow "workflow-completed"
    
    [ "$status" -eq 1 ]
    assert_output_contains "Workflow cannot be resumed from status: completed"
}

@test "resume_workflow updates resumption metadata" {
    pause_workflow "workflow-pending"
    
    run resume_workflow "workflow-pending"
    
    [ "$status" -eq 0 ]
    
    # Verify resumption metadata was added
    local updated_data="${MOCK_WORKFLOW_DATA["workflow-pending"]}"
    local has_resumed_at=$(echo "$updated_data" | jq 'has("resumed_at")')
    local resumed_count=$(echo "$updated_data" | jq '.resumed_count')
    
    [ "$has_resumed_at" = "true" ]
    [ "$resumed_count" -eq 1 ]
}

# Test: resume_workflow_from_step functionality
@test "resume_workflow_from_step resumes from specified step" {
    run resume_workflow_from_step "workflow-failed" 2
    
    [ "$status" -eq 0 ]
    assert_output_contains "Resuming workflow from step 2"
    
    # Verify current step was updated
    local updated_data="${MOCK_WORKFLOW_DATA["workflow-failed"]}"
    local current_step=$(echo "$updated_data" | jq '.current_step')
    [ "$current_step" -eq 2 ]
}

@test "resume_workflow_from_step marks previous steps as completed" {
    run resume_workflow_from_step "workflow-failed" 2
    
    [ "$status" -eq 0 ]
    
    # Verify steps 0 and 1 are marked completed
    local updated_data="${MOCK_WORKFLOW_DATA["workflow-failed"]}"
    local step0_status=$(echo "$updated_data" | jq -r '.steps[0].status')
    local step1_status=$(echo "$updated_data" | jq -r '.steps[1].status')
    local step2_status=$(echo "$updated_data" | jq -r '.steps[2].status')
    
    [ "$step0_status" = "completed" ]
    [ "$step1_status" = "completed" ]
    [ "$step2_status" = "pending" ]
}

@test "resume_workflow_from_step validates step range" {
    run resume_workflow_from_step "workflow-pending" 10
    
    [ "$status" -eq 1 ]
    assert_output_contains "Invalid resume step: 10"
    
    run resume_workflow_from_step "workflow-pending" -1
    
    [ "$status" -eq 1 ]
    assert_output_contains "Invalid resume step: -1"
}

@test "resume_workflow_from_step sets manual resume flag" {
    run resume_workflow_from_step "workflow-failed" 1
    
    [ "$status" -eq 0 ]
    
    # Verify manual resume flag was set
    local updated_data="${MOCK_WORKFLOW_DATA["workflow-failed"]}"
    local manual_resume=$(echo "$updated_data" | jq '.manual_resume')
    [ "$manual_resume" = "true" ]
}

# Test: cancel_workflow functionality
@test "cancel_workflow sets status to failed with cancellation metadata" {
    run cancel_workflow "workflow-in-progress"
    
    [ "$status" -eq 0 ]
    assert_output_contains "Cancelled workflow: workflow-in-progress"
    
    # Verify cancellation was recorded
    local updated_data="${MOCK_WORKFLOW_DATA["workflow-in-progress"]}"
    local status=$(echo "$updated_data" | jq -r '.status')
    local cancellation_reason=$(echo "$updated_data" | jq -r '.cancellation_reason')
    local has_cancelled_at=$(echo "$updated_data" | jq 'has("cancelled_at")')
    
    [ "$status" = "failed" ]
    [ "$cancellation_reason" = "user_cancelled" ]
    [ "$has_cancelled_at" = "true" ]
}

@test "cancel_workflow handles non-existent workflows" {
    run cancel_workflow "workflow-nonexistent"
    
    [ "$status" -eq 1 ]
    assert_output_contains "Workflow not found"
}

# Test: list_workflows functionality
@test "list_workflows returns all workflows by default" {
    run list_workflows
    
    [ "$status" -eq 0 ]
    
    local workflow_count=$(echo "$output" | jq length)
    [ "$workflow_count" -eq 4 ]
}

@test "list_workflows filters by status" {
    run list_workflows "completed"
    
    [ "$status" -eq 0 ]
    
    local workflow_count=$(echo "$output" | jq length)
    local first_status=$(echo "$output" | jq -r '.[0].status')
    
    [ "$workflow_count" -eq 1 ]
    [ "$first_status" = "completed" ]
}

@test "list_workflows returns empty array when no matches" {
    run list_workflows "nonexistent_status"
    
    [ "$status" -eq 0 ]
    
    local workflow_count=$(echo "$output" | jq length)
    [ "$workflow_count" -eq 0 ]
}

# Test: Edge cases and error handling
@test "status functions handle corrupted workflow data gracefully" {
    # Create corrupted workflow data
    MOCK_WORKFLOW_DATA["workflow-corrupted"]='{"invalid": json}'
    
    run get_workflow_detailed_status "workflow-corrupted"
    
    [ "$status" -eq 1 ]
    # Should handle gracefully without crashing
}

@test "checkpoint creation handles missing workflow gracefully" {
    run create_workflow_checkpoint "missing-workflow" "test"
    
    [ "$status" -eq 1 ]
    assert_output_contains "Workflow not found"
}

@test "progress calculation handles edge cases" {
    # Create workflow with 0 steps (edge case)
    local zero_step_workflow='{
        "id": "workflow-zero-steps",
        "type": "workflow",
        "workflow_type": "custom", 
        "status": "pending",
        "current_step": 0,
        "steps": []
    }'
    
    MOCK_WORKFLOW_DATA["workflow-zero-steps"]="$zero_step_workflow"
    
    run get_workflow_detailed_status "workflow-zero-steps"
    
    [ "$status" -eq 0 ]
    
    local progress=$(echo "$output" | jq '.progress.percentage')
    [ "$progress" = "0" ]
}

# Test: Performance and resource efficiency
@test "status tracking handles large workflow data efficiently" {
    # Create workflow with many steps and history
    local large_workflow='{
        "id": "workflow-large",
        "type": "workflow",
        "workflow_type": "issue-merge",
        "status": "in_progress", 
        "current_step": 50,
        "steps": []
    }'
    
    # Add many steps
    local steps_array="["
    for i in {1..100}; do
        steps_array+="{\"phase\": \"step$i\", \"status\": \"pending\", \"command\": \"/cmd$i\"}"
        if [[ $i -lt 100 ]]; then
            steps_array+=","
        fi
    done
    steps_array+="]"
    
    large_workflow=$(echo "$large_workflow" | jq --argjson steps "$steps_array" '.steps = $steps')
    MOCK_WORKFLOW_DATA["workflow-large"]="$large_workflow"
    
    run get_workflow_detailed_status "workflow-large"
    
    [ "$status" -eq 0 ]
    
    local total_steps=$(echo "$output" | jq '.progress.total_steps')
    [ "$total_steps" -eq 100 ]
}

@test "checkpoint creation preserves workflow state integrity" {
    local original_data="${MOCK_WORKFLOW_DATA["workflow-in-progress"]}"
    
    generate_task_id() { echo "checkpoint-integrity-test"; }
    export -f generate_task_id
    
    create_workflow_checkpoint "workflow-in-progress" "integrity_test"
    
    local updated_data="${MOCK_WORKFLOW_DATA["workflow-in-progress"]}"
    local checkpoint_data=$(echo "$updated_data" | jq '.checkpoints[0].workflow_state')
    
    # Verify checkpoint contains complete workflow state
    local checkpoint_status=$(echo "$checkpoint_data" | jq -r '.status')
    local checkpoint_current_step=$(echo "$checkpoint_data" | jq '.current_step')
    local checkpoint_steps_count=$(echo "$checkpoint_data" | jq '.steps | length')
    
    [ "$checkpoint_status" = "in_progress" ]
    [ "$checkpoint_current_step" -eq 2 ]
    [ "$checkpoint_steps_count" -eq 4 ]
}