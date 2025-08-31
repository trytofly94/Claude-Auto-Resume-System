#!/usr/bin/env bats

# Integration tests for Issue-Merge Workflow Task Queue Integration
# Tests the complete integration between workflow system and task queue including:
# - create-issue-merge CLI command
# - Workflow status reporting and monitoring
# - Resume command functionality
# - Task queue persistence and recovery
# - CLI interface and user interaction

load ../test_helper

# Source the workflow module and dependencies
setup() {
    default_setup
    
    # Create test project directory with complete structure
    export TEST_PROJECT_DIR="$TEST_TEMP_DIR/claude-auto-resume-integration"
    mkdir -p "$TEST_PROJECT_DIR"
    cd "$TEST_PROJECT_DIR"
    
    # Create project structure for integration tests
    create_complete_project_structure
    
    # Set up comprehensive test configuration
    export USE_CLAUNCH="true"
    export CLAUNCH_MODE="tmux"
    export TMUX_SESSION_NAME="claude-queue-integration-test"
    export PROJECT_ROOT="$TEST_PROJECT_DIR"
    export SCRIPT_DIR="$BATS_TEST_DIRNAME/../../src"
    
    # Initialize task queue system
    export TASK_QUEUE_ENABLED="true"
    export TASK_QUEUE_DIR="queue"
    export TASK_DEFAULT_TIMEOUT=30
    export TASK_MAX_RETRIES=3
    export TASK_QUEUE_MAX_SIZE=0
    export QUEUE_LOCK_TIMEOUT=5
    
    # Mock comprehensive integration environment
    setup_comprehensive_integration_mocks
    
    # Source modules in proper order
    source "$BATS_TEST_DIRNAME/../../src/task-queue.sh"
    source "$BATS_TEST_DIRNAME/../../src/queue/workflow.sh"
    
    # Initialize complete test environment
    initialize_integration_environment
    
    # Set appropriate logging level
    export LOG_LEVEL="INFO"
}

teardown() {
    default_teardown
}

# Create complete project structure for integration tests
create_complete_project_structure() {
    # Create all necessary directories
    mkdir -p {src,tests,docs,config,queue,logs}
    mkdir -p queue/{task-states,backups}
    
    # Create project files
    cat > README.md << 'EOF'
# Claude Auto-Resume Integration Test Project
This is a complete test project for integration testing.
EOF
    
    cat > CLAUDE.md << 'EOF'
# Project Configuration
Issue-merge workflow integration test configuration.
EOF
    
    cat > package.json << 'EOF'
{
  "name": "claude-auto-resume-integration-test",
  "version": "1.0.0",
  "description": "Integration test project"
}
EOF
    
    # Create configuration files
    cat > config/default.conf << 'EOF'
USE_CLAUNCH=true
CLAUNCH_MODE=tmux
CHECK_INTERVAL_MINUTES=5
MAX_RESTARTS=50
EOF
    
    # Initialize git repository
    mkdir -p .git/{hooks,refs/heads}
    echo "ref: refs/heads/main" > .git/HEAD
    echo "Test repository for integration testing" > .git/description
}

# Setup comprehensive integration mocks
setup_comprehensive_integration_mocks() {
    # Mock tmux with comprehensive session management
    local session_state="inactive"
    local command_history=()
    
    tmux() {
        case "$1" in
            "has-session")
                if [[ "$session_state" == "active" ]]; then
                    return 0
                else
                    return 1
                fi
                ;;
            "new-session")
                session_state="active"
                echo "[TMUX] Session started: $*"
                return 0
                ;;
            "send-keys")
                local session="$2"
                local command="$3"
                command_history+=("$command")
                echo "[TMUX] Sent to $session: $command" >> "$TEST_TEMP_DIR/command_history.log"
                return 0
                ;;
            "capture-pane")
                if [[ "$3" == "-p" ]]; then
                    # Return realistic workflow output based on command history
                    local last_command="${command_history[-1]:-}"
                    case "$last_command" in
                        "/dev"*)
                            echo "Pull request created successfully!"
                            ;;
                        "/clear")
                            echo "Context cleared"
                            ;;
                        "/review"*)
                            echo "Review completed - changes look good!"
                            ;;
                        "/dev merge-pr"*)
                            echo "Merge completed successfully - main branch updated"
                            ;;
                        *)
                            echo "claude>"
                            ;;
                    esac
                fi
                ;;
            "list-sessions")
                if [[ "$session_state" == "active" ]]; then
                    echo "claude-queue-integration-test: 1 windows (created)"
                else
                    echo "no server running"
                fi
                ;;
            *)
                return 0
                ;;
        esac
    }
    export -f tmux
    
    # Mock claunch integration with state management
    check_session_status() {
        [[ "${MOCK_SESSION_ACTIVE:-false}" == "true" ]]
    }
    
    start_or_resume_session() {
        local project_dir="$1"
        local create_new="${2:-false}"
        
        if [[ "${MOCK_SESSION_START_SUCCESS:-true}" == "true" ]]; then
            export MOCK_SESSION_ACTIVE="true"
            session_state="active"
            echo "[SESSION] Started for project: $project_dir"
            return 0
        else
            return 1
        fi
    }
    
    send_command_to_session() {
        local command="$1"
        
        if [[ "${MOCK_COMMAND_SEND_SUCCESS:-true}" == "true" ]]; then
            command_history+=("$command")
            echo "[SESSION] Command sent: $command"
            return 0
        else
            return 1
        fi
    }
    
    monitor_command_completion() {
        local command="$1"
        local phase="$2" 
        local context="${3:-}"
        local timeout="${4:-300}"
        
        if [[ "${MOCK_COMPLETION_SUCCESS:-true}" == "true" ]]; then
            # Simulate realistic completion time
            sleep 0.1
            echo "[MONITOR] Command completed: $command"
            return 0
        else
            return 1
        fi
    }
    
    # Export all integration mocks
    export -f check_session_status
    export -f start_or_resume_session
    export -f send_command_to_session
    export -f monitor_command_completion
    
    # Initialize mock state
    export MOCK_SESSION_ACTIVE="false"
    export MOCK_SESSION_START_SUCCESS="true"
    export MOCK_COMMAND_SEND_SUCCESS="true"
    export MOCK_COMPLETION_SUCCESS="true"
}

# Initialize complete integration test environment
initialize_integration_environment() {
    # Initialize task queue system
    declare -gA TASK_STATES
    declare -gA TASK_METADATA
    declare -gA TASK_RETRY_COUNTS
    declare -gA TASK_TIMESTAMPS
    declare -gA TASK_PRIORITIES
    
    # Create queue structure
    ensure_queue_directories
    
    # Create initial queue state file
    local initial_queue='{
        "version": "1.0",
        "created_at": "'$(date -Iseconds)'",
        "tasks": [],
        "metadata": {
            "total_tasks": 0,
            "last_updated": "'$(date -Iseconds)'"
        }
    }'
    echo "$initial_queue" > "$TEST_PROJECT_DIR/queue/task-queue.json"
}

# Test: create-issue-merge CLI command
@test "create-issue-merge command creates workflow successfully" {
    run bash -c "source '$BATS_TEST_DIRNAME/../../src/task-queue.sh' && cmd_create_issue_merge_workflow 123"
    
    [ "$status" -eq 0 ]
    assert_output_contains "Created issue-merge workflow"
    
    # Verify workflow was created and persisted
    local queue_file="$TEST_PROJECT_DIR/queue/task-queue.json"
    assert_file_exists "$queue_file"
    
    local task_count=$(jq '.tasks | length' "$queue_file")
    [ "$task_count" -gt 0 ]
    
    # Verify workflow configuration
    local workflow_data=$(jq '.tasks[0]' "$queue_file")
    local workflow_type=$(echo "$workflow_data" | jq -r '.workflow_type')
    local issue_id=$(echo "$workflow_data" | jq -r '.config.issue_id')
    
    [ "$workflow_type" = "issue-merge" ]
    [ "$issue_id" = "123" ]
}

@test "create-issue-merge command validates issue ID parameter" {
    # Test missing issue ID
    run bash -c "source '$BATS_TEST_DIRNAME/../../src/task-queue.sh' && cmd_create_issue_merge_workflow"
    
    [ "$status" -eq 1 ]
    assert_output_contains "Usage:"
    assert_output_contains "create-issue-merge <issue_id>"
}

@test "create-issue-merge command integrates with task queue persistence" {
    # Create multiple workflows to test persistence
    bash -c "source '$BATS_TEST_DIRNAME/../../src/task-queue.sh' && cmd_create_issue_merge_workflow 111"
    bash -c "source '$BATS_TEST_DIRNAME/../../src/task-queue.sh' && cmd_create_issue_merge_workflow 222"
    
    # Verify both workflows persisted
    local queue_file="$TEST_PROJECT_DIR/queue/task-queue.json"
    local task_count=$(jq '.tasks | length' "$queue_file")
    [ "$task_count" -eq 2 ]
    
    # Verify distinct workflow IDs
    local workflow1_id=$(jq -r '.tasks[0].id' "$queue_file")
    local workflow2_id=$(jq -r '.tasks[1].id' "$queue_file")
    [ "$workflow1_id" != "$workflow2_id" ]
}

# Test: Workflow status reporting integration
@test "workflow command reports status correctly" {
    # Create and execute workflow
    local workflow_output=$(bash -c "source '$BATS_TEST_DIRNAME/../../src/task-queue.sh' && cmd_create_issue_merge_workflow 333")
    local workflow_id=$(echo "$workflow_output" | grep -o 'workflow-[^[:space:]]*')
    
    # Test status reporting
    run bash -c "source '$BATS_TEST_DIRNAME/../../src/task-queue.sh' && cmd_workflow_status '$workflow_id'"
    
    [ "$status" -eq 0 ]
    assert_output_contains "Workflow Status"
    assert_output_contains "workflow_id.*$workflow_id"
    assert_output_contains "workflow_type.*issue-merge"
    assert_output_contains "status.*pending"
}

@test "workflow detailed status provides comprehensive information" {
    # Create workflow
    local workflow_output=$(bash -c "source '$BATS_TEST_DIRNAME/../../src/task-queue.sh' && cmd_create_issue_merge_workflow 444")
    local workflow_id=$(echo "$workflow_output" | grep -o 'workflow-[^[:space:]]*')
    
    # Test detailed status
    run bash -c "source '$BATS_TEST_DIRNAME/../../src/task-queue.sh' && cmd_workflow_detailed_status '$workflow_id'"
    
    [ "$status" -eq 0 ]
    assert_output_contains "Detailed Workflow Status"
    assert_output_contains "Progress:"
    assert_output_contains "Timing:"
    assert_output_contains "Errors:"
    assert_output_contains "Session Health:"
}

@test "workflow list command shows all workflows" {
    # Create multiple workflows
    bash -c "source '$BATS_TEST_DIRNAME/../../src/task-queue.sh' && cmd_create_issue_merge_workflow 555"
    bash -c "source '$BATS_TEST_DIRNAME/../../src/task-queue.sh' && cmd_create_issue_merge_workflow 666"
    
    # Test list command
    run bash -c "source '$BATS_TEST_DIRNAME/../../src/task-queue.sh' && cmd_workflow_list"
    
    [ "$status" -eq 0 ]
    assert_output_contains "Workflow List"
    assert_output_contains "issue-555"
    assert_output_contains "issue-666"
}

@test "workflow list filters by status correctly" {
    # Create workflow and mark as completed
    local workflow_output=$(bash -c "source '$BATS_TEST_DIRNAME/../../src/task-queue.sh' && cmd_create_issue_merge_workflow 777")
    local workflow_id=$(echo "$workflow_output" | grep -o 'workflow-[^[:space:]]*')
    
    # Update status to completed (simulate execution)
    bash -c "source '$BATS_TEST_DIRNAME/../../src/task-queue.sh' && update_task_status '$workflow_id' 'completed'"
    
    # Test filtered list
    run bash -c "source '$BATS_TEST_DIRNAME/../../src/task-queue.sh' && cmd_workflow_list completed"
    
    [ "$status" -eq 0 ]
    assert_output_contains "$workflow_id"
}

# Test: Resume command functionality
@test "workflow resume command restarts paused workflow" {
    # Create and pause workflow
    local workflow_output=$(bash -c "source '$BATS_TEST_DIRNAME/../../src/task-queue.sh' && cmd_create_issue_merge_workflow 888")
    local workflow_id=$(echo "$workflow_output" | grep -o 'workflow-[^[:space:]]*')
    
    # Pause workflow
    bash -c "source '$BATS_TEST_DIRNAME/../../src/task-queue.sh' && pause_workflow '$workflow_id'"
    
    # Test resume command
    run bash -c "source '$BATS_TEST_DIRNAME/../../src/task-queue.sh' && cmd_workflow_resume '$workflow_id'"
    
    [ "$status" -eq 0 ]
    assert_output_contains "Resuming workflow"
}

@test "workflow resume from step functionality works correctly" {
    # Create workflow
    local workflow_output=$(bash -c "source '$BATS_TEST_DIRNAME/../../src/task-queue.sh' && cmd_create_issue_merge_workflow 999")
    local workflow_id=$(echo "$workflow_output" | grep -o 'workflow-[^[:space:]]*')
    
    # Test resume from specific step
    run bash -c "source '$BATS_TEST_DIRNAME/../../src/task-queue.sh' && cmd_workflow_resume_from_step '$workflow_id' 2"
    
    [ "$status" -eq 0 ]
    assert_output_contains "Resuming workflow from step 2"
}

@test "resume command validates workflow existence" {
    run bash -c "source '$BATS_TEST_DIRNAME/../../src/task-queue.sh' && cmd_workflow_resume 'nonexistent-workflow'"
    
    [ "$status" -eq 1 ]
    assert_output_contains "Workflow not found"
}

# Test: Workflow execution integration
@test "workflow execute command runs complete issue-merge workflow" {
    # Create workflow
    local workflow_output=$(bash -c "source '$BATS_TEST_DIRNAME/../../src/task-queue.sh' && cmd_create_issue_merge_workflow 101")
    local workflow_id=$(echo "$workflow_output" | grep -o 'workflow-[^[:space:]]*')
    
    # Execute workflow
    run bash -c "source '$BATS_TEST_DIRNAME/../../src/task-queue.sh' && cmd_workflow_execute '$workflow_id'"
    
    [ "$status" -eq 0 ]
    assert_output_contains "Executing workflow"
    assert_output_contains "Workflow execution completed successfully"
}

@test "workflow execution updates status throughout process" {
    # Create workflow  
    local workflow_output=$(bash -c "source '$BATS_TEST_DIRNAME/../../src/task-queue.sh' && cmd_create_issue_merge_workflow 102")
    local workflow_id=$(echo "$workflow_output" | grep -o 'workflow-[^[:space:]]*')
    
    # Execute workflow
    bash -c "source '$BATS_TEST_DIRNAME/../../src/task-queue.sh' && cmd_workflow_execute '$workflow_id'"
    
    # Check final status
    run bash -c "source '$BATS_TEST_DIRNAME/../../src/task-queue.sh' && get_task '$workflow_id' json | jq -r '.status'"
    
    [ "$status" -eq 0 ]
    [ "$output" = "completed" ]
}

@test "workflow execution persists progress and results" {
    # Create workflow
    local workflow_output=$(bash -c "source '$BATS_TEST_DIRNAME/../../src/task-queue.sh' && cmd_create_issue_merge_workflow 103")
    local workflow_id=$(echo "$workflow_output" | grep -o 'workflow-[^[:space:]]*')
    
    # Execute workflow
    bash -c "source '$BATS_TEST_DIRNAME/../../src/task-queue.sh' && cmd_workflow_execute '$workflow_id'"
    
    # Verify results were persisted
    local workflow_data=$(bash -c "source '$BATS_TEST_DIRNAME/../../src/task-queue.sh' && get_task '$workflow_id' json")
    local results_count=$(echo "$workflow_data" | jq '.results | length')
    local completed_steps=$(echo "$workflow_data" | jq '[.steps[] | select(.status == "completed")] | length')
    
    [ "$results_count" -gt 0 ]
    [ "$completed_steps" -eq 4 ]
}

# Test: CLI interface and user experience
@test "task-queue CLI shows workflow commands in help" {
    run bash -c "source '$BATS_TEST_DIRNAME/../../src/task-queue.sh' && show_usage"
    
    [ "$status" -eq 0 ]
    assert_output_contains "create-issue-merge"
    assert_output_contains "workflow execute"
    assert_output_contains "workflow status"
    assert_output_contains "workflow resume"
}

@test "workflow commands provide helpful error messages" {
    # Test missing workflow ID
    run bash -c "source '$BATS_TEST_DIRNAME/../../src/task-queue.sh' && cmd_workflow_status"
    
    [ "$status" -eq 1 ]
    assert_output_contains "Usage:"
    
    # Test invalid workflow ID  
    run bash -c "source '$BATS_TEST_DIRNAME/../../src/task-queue.sh' && cmd_workflow_status 'invalid-id'"
    
    [ "$status" -eq 1 ]
    assert_output_contains "Workflow not found"
}

@test "workflow commands support verbose output" {
    # Create workflow
    local workflow_output=$(bash -c "source '$BATS_TEST_DIRNAME/../../src/task-queue.sh' && cmd_create_issue_merge_workflow 201")
    local workflow_id=$(echo "$workflow_output" | grep -o 'workflow-[^[:space:]]*')
    
    # Test verbose status
    run bash -c "LOG_LEVEL=DEBUG source '$BATS_TEST_DIRNAME/../../src/task-queue.sh' && cmd_workflow_status '$workflow_id'"
    
    [ "$status" -eq 0 ]
    # More comprehensive output expected with debug logging
}

# Test: Queue integration and persistence
@test "workflow creation updates queue metadata correctly" {
    local initial_metadata=$(jq '.metadata' "$TEST_PROJECT_DIR/queue/task-queue.json")
    
    # Create workflow
    bash -c "source '$BATS_TEST_DIRNAME/../../src/task-queue.sh' && cmd_create_issue_merge_workflow 301"
    
    # Verify metadata updated
    local updated_metadata=$(jq '.metadata' "$TEST_PROJECT_DIR/queue/task-queue.json")
    local total_tasks=$(echo "$updated_metadata" | jq '.total_tasks')
    
    [ "$total_tasks" -gt 0 ]
}

@test "workflow system handles queue backup creation" {
    # Create multiple workflows to trigger backup
    bash -c "source '$BATS_TEST_DIRNAME/../../src/task-queue.sh' && cmd_create_issue_merge_workflow 401"
    bash -c "source '$BATS_TEST_DIRNAME/../../src/task-queue.sh' && cmd_create_issue_merge_workflow 402"
    
    # Execute backup operation
    run bash -c "source '$BATS_TEST_DIRNAME/../../src/task-queue.sh' && backup_queue_state 'integration-test'"
    
    [ "$status" -eq 0 ]
    assert_output_contains "Queue backup created"
    
    # Verify backup file exists
    local backup_files=("$TEST_PROJECT_DIR/queue/backups"/backup-integration-test-*.json)
    [ -f "${backup_files[0]}" ]
}

@test "workflow system recovers from queue corruption gracefully" {
    # Create valid workflow first
    bash -c "source '$BATS_TEST_DIRNAME/../../src/task-queue.sh' && cmd_create_issue_merge_workflow 501"
    
    # Corrupt queue file
    echo "invalid json" > "$TEST_PROJECT_DIR/queue/task-queue.json"
    
    # Attempt to create new workflow (should handle corruption gracefully)
    run bash -c "source '$BATS_TEST_DIRNAME/../../src/task-queue.sh' && cmd_create_issue_merge_workflow 502"
    
    # Should either succeed with recovery or fail gracefully
    if [ "$status" -eq 0 ]; then
        assert_output_contains "Created issue-merge workflow"
    else
        assert_output_contains "queue" # Some mention of queue issue
    fi
}

# Test: Performance and scalability
@test "workflow system handles multiple concurrent operations" {
    # Simulate concurrent workflow creation
    local pids=()
    
    for i in {1..5}; do
        bash -c "source '$BATS_TEST_DIRNAME/../../src/task-queue.sh' && cmd_create_issue_merge_workflow $((600 + i))" &
        pids+=($!)
    done
    
    # Wait for all background processes
    for pid in "${pids[@]}"; do
        wait "$pid"
    done
    
    # Verify all workflows were created
    local task_count=$(jq '.tasks | length' "$TEST_PROJECT_DIR/queue/task-queue.json")
    [ "$task_count" -eq 5 ]
}

@test "workflow system maintains performance with large queue" {
    # Create many workflows quickly
    for i in {1..20}; do
        bash -c "source '$BATS_TEST_DIRNAME/../../src/task-queue.sh' && cmd_create_issue_merge_workflow $((700 + i))" >/dev/null 2>&1
    done
    
    # Test that operations still work efficiently
    local start_time=$(date +%s)
    run bash -c "source '$BATS_TEST_DIRNAME/../../src/task-queue.sh' && cmd_workflow_list"
    local end_time=$(date +%s)
    
    [ "$status" -eq 0 ]
    # Should complete within reasonable time (5 seconds)
    local duration=$((end_time - start_time))
    [ "$duration" -lt 5 ]
}

# Test: Integration with monitoring and health checks
@test "workflow monitoring integration provides system health status" {
    # Create and execute workflow
    local workflow_output=$(bash -c "source '$BATS_TEST_DIRNAME/../../src/task-queue.sh' && cmd_create_issue_merge_workflow 801")
    local workflow_id=$(echo "$workflow_output" | grep -o 'workflow-[^[:space:]]*')
    
    # Test health check
    run bash -c "source '$BATS_TEST_DIRNAME/../../src/task-queue.sh' && cmd_check_health"
    
    [ "$status" -eq 0 ]
    assert_output_contains "System Health Check"
}

@test "workflow system integrates with monitoring commands" {
    # Create active workflow
    local workflow_output=$(bash -c "source '$BATS_TEST_DIRNAME/../../src/task-queue.sh' && cmd_create_issue_merge_workflow 802")
    local workflow_id=$(echo "$workflow_output" | grep -o 'workflow-[^[:space:]]*')
    
    # Test monitoring integration
    run bash -c "source '$BATS_TEST_DIRNAME/../../src/task-queue.sh' && cmd_start_monitoring 5 1"
    
    [ "$status" -eq 0 ]
    assert_output_contains "Starting queue monitoring"
}