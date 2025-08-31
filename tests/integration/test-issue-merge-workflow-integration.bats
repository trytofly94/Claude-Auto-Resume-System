#!/usr/bin/env bats

# Integration tests for Issue-Merge Workflow End-to-End Execution
# Tests the complete issue-merge workflow functionality including:
# - Full workflow creation and execution
# - Real Claude session integration (mocked)
# - Step-by-step progression and monitoring
# - Error handling and recovery in realistic scenarios
# - Session lifecycle management

load ../test_helper

# Source the workflow module and dependencies
setup() {
    default_setup
    
    # Create test project directory with realistic structure
    export TEST_PROJECT_DIR="$TEST_TEMP_DIR/claude-auto-resume-integration"
    mkdir -p "$TEST_PROJECT_DIR"
    cd "$TEST_PROJECT_DIR"
    
    # Create realistic project structure
    create_realistic_project_structure
    
    # Set up integration test configuration
    export USE_CLAUNCH="true"
    export CLAUNCH_MODE="tmux"
    export TMUX_SESSION_NAME="claude-integration-test"
    export PROJECT_ROOT="$TEST_PROJECT_DIR"
    export SCRIPT_DIR="$BATS_TEST_DIRNAME/../../src"
    
    # Initialize task queue for workflow storage
    export TASK_QUEUE_ENABLED="true"
    export TASK_QUEUE_DIR="queue"
    export TASK_DEFAULT_TIMEOUT=30
    export TASK_MAX_RETRIES=3
    
    # Mock realistic Claude and tmux integration
    setup_realistic_workflow_mocks
    
    # Source the modules in correct order
    source "$BATS_TEST_DIRNAME/../../src/task-queue.sh"
    source "$BATS_TEST_DIRNAME/../../src/queue/workflow.sh"
    
    # Initialize task queue for workflow tests
    initialize_test_task_queue
    
    # Initialize logging
    export LOG_LEVEL="INFO"  # More verbose for integration tests
}

teardown() {
    default_teardown
}

# Create realistic project structure
create_realistic_project_structure() {
    # Create directories
    mkdir -p src tests docs config queue
    mkdir -p queue/task-states queue/backups
    
    # Create realistic files
    cat > README.md << 'EOF'
# Claude Auto-Resume System
Integration test project structure
EOF
    
    cat > package.json << 'EOF'
{
  "name": "claude-auto-resume-test",
  "version": "1.0.0",
  "description": "Test project for integration testing"
}
EOF
    
    cat > src/main.js << 'EOF'
console.log("Test application");
EOF
    
    # Initialize git repo
    mkdir -p .git/hooks
    echo "ref: refs/heads/main" > .git/HEAD
}

# Setup realistic workflow mocks for integration testing
setup_realistic_workflow_mocks() {
    # Mock tmux with realistic session behavior
    local tmux_capture_count=0
    local session_output_progression=(
        "Starting Claude CLI session..."
        "claude> Processing /dev command..."
        "Analyzing issue requirements..."
        "Creating feature branch..."
        "Implementing solution..."
        "Running tests..."
        "Pull request created successfully: PR #123"
        "claude>"
    )
    
    tmux() {
        case "$1" in
            "has-session")
                [[ "${MOCK_TMUX_SESSION_EXISTS:-true}" == "true" ]]
                ;;
            "send-keys")
                # Simulate command being sent
                local command="$3"
                echo "[TMUX] Sent command: $command" >> "$TEST_TEMP_DIR/session.log"
                return 0
                ;;
            "capture-pane")
                if [[ "$3" == "-p" ]]; then
                    # Return progressive output based on how many times we've been called
                    ((tmux_capture_count++))
                    local output_index=$((tmux_capture_count % ${#session_output_progression[@]}))
                    echo "${session_output_progression[$output_index]}"
                fi
                ;;
            *)
                echo "Mock tmux: $*"
                return 0
                ;;
        esac
    }
    export -f tmux
    
    # Mock claunch integration functions with realistic behavior
    check_session_status() {
        [[ "${MOCK_SESSION_ACTIVE:-true}" == "true" ]]
    }
    
    start_or_resume_session() {
        local project_dir="$1"
        local create_new="${2:-false}"
        
        if [[ "${MOCK_SESSION_START_SUCCESS:-true}" == "true" ]]; then
            echo "[SESSION] Started session for project: $project_dir"
            export MOCK_SESSION_ACTIVE="true"
            return 0
        else
            echo "[SESSION] Failed to start session"
            return 1
        fi
    }
    
    send_command_to_session() {
        local command="$1"
        
        echo "[SESSION] Sending command: $command" >> "$TEST_TEMP_DIR/session.log"
        
        if [[ "${MOCK_COMMAND_SEND_SUCCESS:-true}" == "true" ]]; then
            # Simulate command acknowledgment
            sleep 0.1  # Brief pause to simulate network delay
            return 0
        else
            return 1
        fi
    }
    
    # Export mocked functions
    export -f check_session_status
    export -f start_or_resume_session
    export -f send_command_to_session
    
    # Initialize mock state
    export MOCK_TMUX_SESSION_EXISTS="true"
    export MOCK_SESSION_ACTIVE="true"
    export MOCK_SESSION_START_SUCCESS="true" 
    export MOCK_COMMAND_SEND_SUCCESS="true"
}

# Initialize task queue for testing
initialize_test_task_queue() {
    # Create queue directories
    mkdir -p "$TEST_PROJECT_DIR/queue/task-states"
    mkdir -p "$TEST_PROJECT_DIR/queue/backups"
    
    # Initialize global arrays
    declare -gA TASK_STATES
    declare -gA TASK_METADATA
    declare -gA TASK_RETRY_COUNTS
    declare -gA TASK_TIMESTAMPS
    declare -gA TASK_PRIORITIES
    
    # Create empty queue file
    echo '{"version": "1.0", "tasks": [], "metadata": {}}' > "$TEST_PROJECT_DIR/queue/task-queue.json"
}

# Test: Full issue-merge workflow creation
@test "create_workflow_task creates complete issue-merge workflow" {
    local issue_id="123"
    local config="{\"issue_id\": \"$issue_id\"}"
    
    run create_workflow_task "issue-merge" "$config"
    
    [ "$status" -eq 0 ]
    
    local workflow_id="$output"
    [[ "$workflow_id" =~ ^workflow-.*$ ]]
    
    # Verify workflow was stored correctly
    run get_task "$workflow_id" "json"
    [ "$status" -eq 0 ]
    
    local workflow_type=$(echo "$output" | jq -r '.workflow_type')
    local steps_count=$(echo "$output" | jq '.steps | length')
    local issue_id_config=$(echo "$output" | jq -r '.config.issue_id')
    
    [ "$workflow_type" = "issue-merge" ]
    [ "$steps_count" -eq 4 ]
    [ "$issue_id_config" = "123" ]
}

@test "issue-merge workflow has correct step configuration" {
    local config='{"issue_id": "456"}'
    local workflow_id=$(create_workflow_task "issue-merge" "$config")
    
    local workflow_data=$(get_task "$workflow_id" "json")
    local steps=$(echo "$workflow_data" | jq '.steps')
    
    # Verify develop step
    local develop_phase=$(echo "$steps" | jq -r '.[0].phase')
    local develop_command=$(echo "$steps" | jq -r '.[0].command')
    [ "$develop_phase" = "develop" ]
    [ "$develop_command" = "/dev 456" ]
    
    # Verify clear step
    local clear_phase=$(echo "$steps" | jq -r '.[1].phase')
    local clear_command=$(echo "$steps" | jq -r '.[1].command')
    [ "$clear_phase" = "clear" ]
    [ "$clear_command" = "/clear" ]
    
    # Verify review step
    local review_phase=$(echo "$steps" | jq -r '.[2].phase')
    local review_command=$(echo "$steps" | jq -r '.[2].command')
    [ "$review_phase" = "review" ]
    [ "$review_command" = "/review PR-456" ]
    
    # Verify merge step
    local merge_phase=$(echo "$steps" | jq -r '.[3].phase')
    local merge_command=$(echo "$steps" | jq -r '.[3].command')
    [ "$merge_phase" = "merge" ]
    [ "$merge_command" = "/dev merge-pr 456 --focus-main" ]
}

# Test: Full workflow execution with mocked sessions
@test "execute_workflow_task completes full issue-merge workflow successfully" {
    # Create workflow
    local config='{"issue_id": "789"}'
    local workflow_id=$(create_workflow_task "issue-merge" "$config")
    
    # Mock completion monitoring to succeed quickly
    monitor_command_completion() {
        local command="$1"
        local phase="$2"
        local context="${3:-}"
        
        echo "[MONITOR] Command completed: $command (phase: $phase)"
        sleep 0.1  # Brief simulation delay
        return 0
    }
    export -f monitor_command_completion
    
    run execute_workflow_task "$workflow_id"
    
    [ "$status" -eq 0 ]
    assert_output_contains "Workflow execution completed successfully"
    
    # Verify all steps were executed
    assert_file_exists "$TEST_TEMP_DIR/session.log"
    local session_log=$(cat "$TEST_TEMP_DIR/session.log")
    
    [[ "$session_log" =~ "/dev 789" ]]
    [[ "$session_log" =~ "/clear" ]]
    [[ "$session_log" =~ "/review PR-789" ]]
    [[ "$session_log" =~ "/dev merge-pr 789" ]]
}

@test "workflow execution handles session startup correctly" {
    # Start with inactive session
    export MOCK_SESSION_ACTIVE="false"
    export MOCK_SESSION_START_SUCCESS="true"
    
    local config='{"issue_id": "111"}'
    local workflow_id=$(create_workflow_task "issue-merge" "$config")
    
    # Mock completion monitoring
    monitor_command_completion() { return 0; }
    export -f monitor_command_completion
    
    run execute_workflow_task "$workflow_id"
    
    [ "$status" -eq 0 ]
    assert_output_contains "Started session for project"
}

@test "workflow execution fails gracefully when session cannot start" {
    # Setup session start failure
    export MOCK_SESSION_ACTIVE="false"
    export MOCK_SESSION_START_SUCCESS="false"
    
    local config='{"issue_id": "222"}'
    local workflow_id=$(create_workflow_task "issue-merge" "$config")
    
    run execute_workflow_task "$workflow_id"
    
    [ "$status" -eq 1 ]
    assert_output_contains "Failed to start Claude session"
}

# Test: Step-by-step workflow progression
@test "workflow executes steps in correct sequence with delays" {
    local config='{"issue_id": "333"}'
    local workflow_id=$(create_workflow_task "issue-merge" "$config")
    
    # Track execution order
    local execution_log="$TEST_TEMP_DIR/execution_order.log"
    
    monitor_command_completion() {
        local command="$1"
        local phase="$2"
        echo "$phase:$command" >> "$execution_log"
        sleep 0.1
        return 0
    }
    export -f monitor_command_completion
    
    run execute_workflow_task "$workflow_id"
    
    [ "$status" -eq 0 ]
    
    # Verify execution order
    assert_file_exists "$execution_log"
    local execution_order=$(cat "$execution_log")
    
    # Check that steps executed in correct order
    local line1=$(sed -n '1p' "$execution_log")
    local line2=$(sed -n '2p' "$execution_log") 
    local line3=$(sed -n '3p' "$execution_log")
    local line4=$(sed -n '4p' "$execution_log")
    
    [[ "$line1" =~ "develop:" ]]
    [[ "$line2" =~ "clear:" ]]
    [[ "$line3" =~ "review:" ]]
    [[ "$line4" =~ "merge:" ]]
}

@test "workflow stops on step failure and marks status correctly" {
    local config='{"issue_id": "444"}'
    local workflow_id=$(create_workflow_task "issue-merge" "$config")
    
    # Mock failure on review step
    local step_count=0
    monitor_command_completion() {
        ((step_count++))
        if [[ $step_count -eq 3 ]]; then
            return 1  # Fail review step
        else
            return 0  # Succeed other steps
        fi
    }
    export -f monitor_command_completion
    
    run execute_workflow_task "$workflow_id"
    
    [ "$status" -eq 1 ]
    
    # Verify workflow status is failed
    local workflow_data=$(get_task "$workflow_id" "json")
    local status=$(echo "$workflow_data" | jq -r '.status')
    [ "$status" = "failed" ]
}

# Test: Error handling and recovery integration
@test "workflow retries failed steps with exponential backoff" {
    local config='{"issue_id": "555"}'
    local workflow_id=$(create_workflow_task "issue-merge" "$config")
    
    # Mock sleep to track backoff delays
    local sleep_calls=()
    sleep() {
        sleep_calls+=("$1")
        echo "Mock sleep: $1 seconds"
    }
    export -f sleep
    
    # Mock step failure then success
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
    
    run execute_workflow_task "$workflow_id"
    
    [ "$status" -eq 0 ]
    assert_output_contains "Workflow execution completed successfully"
    
    # Verify backoff delay was used
    [[ "${#sleep_calls[@]}" -gt 0 ]]
}

@test "workflow creates automatic checkpoint before execution" {
    local config='{"issue_id": "666"}'
    local workflow_id=$(create_workflow_task "issue-merge" "$config")
    
    # Mock completion monitoring
    monitor_command_completion() { return 0; }
    export -f monitor_command_completion
    
    run execute_workflow_task "$workflow_id"
    
    [ "$status" -eq 0 ]
    assert_output_contains "Created checkpoint"
    
    # Verify checkpoint was created
    local workflow_data=$(get_task "$workflow_id" "json")
    local checkpoint_count=$(echo "$workflow_data" | jq '.checkpoints | length')
    [ "$checkpoint_count" -gt 0 ]
}

# Test: Session management integration
@test "workflow manages tmux session lifecycle correctly" {
    local config='{"issue_id": "777"}'
    local workflow_id=$(create_workflow_task "issue-merge" "$config")
    
    # Track session management calls
    local session_log="$TEST_TEMP_DIR/session_management.log"
    
    check_session_status() {
        echo "check_session_status called" >> "$session_log"
        return 0
    }
    
    send_command_to_session() {
        echo "send_command_to_session: $1" >> "$session_log"
        return 0
    }
    
    monitor_command_completion() {
        echo "monitor_command_completion: $1" >> "$session_log"
        return 0
    }
    
    export -f check_session_status
    export -f send_command_to_session
    export -f monitor_command_completion
    
    run execute_workflow_task "$workflow_id"
    
    [ "$status" -eq 0 ]
    
    # Verify session management calls
    assert_file_exists "$session_log"
    local session_calls=$(cat "$session_log")
    
    [[ "$session_calls" =~ "check_session_status called" ]]
    [[ "$session_calls" =~ "send_command_to_session: /dev 777" ]]
    [[ "$session_calls" =~ "monitor_command_completion: /dev 777" ]]
}

# Test: Realistic completion detection
@test "workflow completion detection works with realistic tmux output" {
    # Set up realistic tmux output progression
    local capture_call_count=0
    local realistic_outputs=(
        "claude> Processing your request..."
        "Analyzing issue requirements for #888..."
        "Creating feature branch: feature/issue-888"
        "Implementing solution..."
        "Running automated tests..."
        "All tests passed ✓"
        "Creating pull request..."
        "Pull request #888 created successfully!"
        "claude>"
    )
    
    tmux() {
        case "$1" in
            "has-session") return 0 ;;
            "capture-pane")
                if [[ "$3" == "-p" ]]; then
                    ((capture_call_count++))
                    local output_index=$((capture_call_count % ${#realistic_outputs[@]}))
                    echo "${realistic_outputs[$output_index]}"
                fi
                ;;
            *) return 0 ;;
        esac
    }
    export -f tmux
    
    local config='{"issue_id": "888"}'
    local workflow_id=$(create_workflow_task "issue-merge" "$config")
    
    run execute_workflow_task "$workflow_id"
    
    [ "$status" -eq 0 ]
    assert_output_contains "Workflow execution completed successfully"
}

# Test: Performance and timing
@test "workflow execution completes within reasonable timeframe" {
    local config='{"issue_id": "999"}'
    local workflow_id=$(create_workflow_task "issue-merge" "$config")
    
    # Mock fast completion
    monitor_command_completion() {
        sleep 0.1  # 100ms simulation
        return 0
    }
    export -f monitor_command_completion
    
    local start_time=$(date +%s)
    
    run execute_workflow_task "$workflow_id"
    
    local end_time=$(date +%s)
    local execution_time=$((end_time - start_time))
    
    [ "$status" -eq 0 ]
    # Should complete within 10 seconds with mocked delays
    [ "$execution_time" -lt 10 ]
}

# Test: Resource cleanup and state consistency
@test "workflow maintains consistent state throughout execution" {
    local config='{"issue_id": "101"}'
    local workflow_id=$(create_workflow_task "issue-merge" "$config")
    
    # Mock completion monitoring
    monitor_command_completion() { return 0; }
    export -f monitor_command_completion
    
    # Execute workflow
    execute_workflow_task "$workflow_id"
    
    # Verify final state consistency
    local final_data=$(get_task "$workflow_id" "json")
    local status=$(echo "$final_data" | jq -r '.status')
    local current_step=$(echo "$final_data" | jq -r '.current_step')
    local total_steps=$(echo "$final_data" | jq '.steps | length')
    local completed_steps=$(echo "$final_data" | jq '[.steps[] | select(.status == "completed")] | length')
    
    [ "$status" = "completed" ]
    [ "$current_step" -eq "$total_steps" ]
    [ "$completed_steps" -eq "$total_steps" ]
}

@test "workflow cleans up resources on completion" {
    local config='{"issue_id": "102"}'
    local workflow_id=$(create_workflow_task "issue-merge" "$config")
    
    # Mock completion monitoring
    monitor_command_completion() { return 0; }
    export -f monitor_command_completion
    
    run execute_workflow_task "$workflow_id"
    
    [ "$status" -eq 0 ]
    
    # Verify no temporary files left behind (session log should be the only file)
    local temp_files=$(find "$TEST_TEMP_DIR" -name "*.tmp" | wc -l)
    [ "$temp_files" -eq 0 ]
}

# Test: Multi-workflow concurrent execution (simulation)
@test "multiple workflows can be created and tracked independently" {
    # Create multiple workflows
    local workflow1=$(create_workflow_task "issue-merge" '{"issue_id": "201"}')
    local workflow2=$(create_workflow_task "issue-merge" '{"issue_id": "202"}')
    local workflow3=$(create_workflow_task "issue-merge" '{"issue_id": "203"}')
    
    # Verify all workflows exist and have unique IDs
    [ -n "$workflow1" ]
    [ -n "$workflow2" ]
    [ -n "$workflow3" ]
    [ "$workflow1" != "$workflow2" ]
    [ "$workflow2" != "$workflow3" ]
    
    # Verify all workflows have correct configuration
    local config1=$(get_task "$workflow1" "json" | jq -r '.config.issue_id')
    local config2=$(get_task "$workflow2" "json" | jq -r '.config.issue_id')
    local config3=$(get_task "$workflow3" "json" | jq -r '.config.issue_id')
    
    [ "$config1" = "201" ]
    [ "$config2" = "202" ]
    [ "$config3" = "203" ]
}

# Test: Integration with project structure
@test "workflow execution respects project directory structure" {
    local config='{"issue_id": "301"}'
    local workflow_id=$(create_workflow_task "issue-merge" "$config")
    
    # Verify PROJECT_ROOT is used correctly
    run execute_workflow_task "$workflow_id"
    
    # Should start session with correct project directory
    assert_output_contains "$TEST_PROJECT_DIR"
}

# Test: Logging integration
@test "workflow execution provides comprehensive logging" {
    export LOG_LEVEL="DEBUG"
    
    local config='{"issue_id": "401"}'
    local workflow_id=$(create_workflow_task "issue-merge" "$config")
    
    monitor_command_completion() { return 0; }
    export -f monitor_command_completion
    
    run execute_workflow_task "$workflow_id"
    
    [ "$status" -eq 0 ]
    
    # Verify comprehensive logging output
    assert_output_contains "Starting issue-merge workflow execution"
    assert_output_contains "Executing workflow step"
    assert_output_contains "Workflow execution completed successfully"
}