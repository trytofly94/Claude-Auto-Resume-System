#!/usr/bin/env bats

# Unit tests for Issue-Merge Workflow Command Execution Functions
# Tests the core command execution functionality including:
# - execute_dev_command() - Development command execution
# - execute_clear_command() - Context clearing command execution  
# - execute_review_command() - Review command execution
# - execute_merge_command() - Merge command execution
# - All command execution functions with mocked claunch integration

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
    
    # Mock claunch integration functions
    setup_mock_claunch_integration
    
    # Source the workflow module
    source "$BATS_TEST_DIRNAME/../../src/queue/workflow.sh"
    
    # Initialize logging
    if command -v log_info >/dev/null 2>&1; then
        export LOG_LEVEL="ERROR"  # Reduce log noise in tests
    fi
}

teardown() {
    default_teardown
}

# Mock claunch integration functions for testing
setup_mock_claunch_integration() {
    # Mock session status checking
    check_session_status() {
        [[ "${MOCK_SESSION_ACTIVE:-true}" == "true" ]]
    }
    
    # Mock session starting
    start_or_resume_session() {
        local project_dir="$1"
        local create_new="${2:-false}"
        
        if [[ "${MOCK_SESSION_START_SUCCESS:-true}" == "true" ]]; then
            log_debug "Mock: Started session for $project_dir"
            export MOCK_SESSION_ACTIVE="true"
            return 0
        else
            log_error "Mock: Failed to start session for $project_dir"
            return 1
        fi
    }
    
    # Mock command sending
    send_command_to_session() {
        local command="$1"
        
        if [[ "${MOCK_COMMAND_SEND_SUCCESS:-true}" == "true" ]]; then
            log_debug "Mock: Sent command to session: $command"
            
            # Store sent command for verification
            echo "$command" >> "$TEST_TEMP_DIR/sent_commands.log"
            return 0
        else
            log_error "Mock: Failed to send command: $command"
            return 1
        fi
    }
    
    # Mock completion monitoring
    monitor_command_completion() {
        local command="$1"
        local phase="$2"
        local context="${3:-}"
        
        if [[ "${MOCK_COMPLETION_SUCCESS:-true}" == "true" ]]; then
            log_debug "Mock: Command completed successfully: $command"
            
            # Store completion event for verification
            echo "${phase}:${command}:success" >> "$TEST_TEMP_DIR/completion_events.log"
            return 0
        else
            log_error "Mock: Command failed or timed out: $command"
            echo "${phase}:${command}:failed" >> "$TEST_TEMP_DIR/completion_events.log"
            return 1
        fi
    }
    
    # Export all mocked functions
    export -f check_session_status
    export -f start_or_resume_session
    export -f send_command_to_session
    export -f monitor_command_completion
}

# Test: execute_dev_command function
@test "execute_dev_command sends correct command with active session" {
    # Setup active session
    export MOCK_SESSION_ACTIVE="true"
    export MOCK_COMMAND_SEND_SUCCESS="true"
    export MOCK_COMPLETION_SUCCESS="true"
    
    run execute_dev_command "/dev 123" "123"
    
    [ "$status" -eq 0 ]
    
    # Verify command was sent
    assert_file_exists "$TEST_TEMP_DIR/sent_commands.log"
    local sent_command=$(cat "$TEST_TEMP_DIR/sent_commands.log")
    [ "$sent_command" = "/dev 123" ]
    
    # Verify completion monitoring was called
    assert_file_exists "$TEST_TEMP_DIR/completion_events.log"
    local completion_event=$(cat "$TEST_TEMP_DIR/completion_events.log")
    [ "$completion_event" = "develop:/dev 123:success" ]
}

@test "execute_dev_command starts session when none active" {
    # Setup inactive session
    export MOCK_SESSION_ACTIVE="false"
    export MOCK_SESSION_START_SUCCESS="true"
    export MOCK_COMMAND_SEND_SUCCESS="true"
    export MOCK_COMPLETION_SUCCESS="true"
    
    run execute_dev_command "/dev 456" "456"
    
    [ "$status" -eq 0 ]
    assert_output_contains "Attempting to start new session"
    
    # Session should be marked as active after starting
    [ "$MOCK_SESSION_ACTIVE" = "true" ]
}

@test "execute_dev_command fails when session cannot be started" {
    # Setup session start failure
    export MOCK_SESSION_ACTIVE="false"
    export MOCK_SESSION_START_SUCCESS="false"
    
    run execute_dev_command "/dev 789" "789"
    
    [ "$status" -eq 1 ]
    assert_output_contains "Failed to start Claude session"
}

@test "execute_dev_command fails when command cannot be sent" {
    # Setup command send failure
    export MOCK_SESSION_ACTIVE="true"
    export MOCK_COMMAND_SEND_SUCCESS="false"
    
    run execute_dev_command "/dev 101" "101"
    
    [ "$status" -eq 1 ]
    assert_output_contains "Failed to send command to session"
}

@test "execute_dev_command fails when command times out" {
    # Setup completion timeout
    export MOCK_SESSION_ACTIVE="true"
    export MOCK_COMMAND_SEND_SUCCESS="true"
    export MOCK_COMPLETION_SUCCESS="false"
    
    run execute_dev_command "/dev 202" "202"
    
    [ "$status" -eq 1 ]
    assert_output_contains "Dev command failed or timed out"
}

# Test: execute_clear_command function
@test "execute_clear_command executes quickly with active session" {
    # Setup active session
    export MOCK_SESSION_ACTIVE="true"
    export MOCK_COMMAND_SEND_SUCCESS="true"
    
    run execute_clear_command "/clear"
    
    [ "$status" -eq 0 ]
    assert_output_contains "Clear command sent successfully"
    assert_output_contains "Clear command completed successfully"
    
    # Verify command was sent
    local sent_command=$(cat "$TEST_TEMP_DIR/sent_commands.log")
    [ "$sent_command" = "/clear" ]
}

@test "execute_clear_command fails with inactive session" {
    # Setup inactive session
    export MOCK_SESSION_ACTIVE="false"
    
    run execute_clear_command "/clear"
    
    [ "$status" -eq 1 ]
    assert_output_contains "No active Claude session for clear command"
}

@test "execute_clear_command handles command send failure" {
    # Setup command send failure
    export MOCK_SESSION_ACTIVE="true"
    export MOCK_COMMAND_SEND_SUCCESS="false"
    
    run execute_clear_command "/clear"
    
    [ "$status" -eq 1 ]
    assert_output_contains "Failed to send clear command"
}

# Test: execute_review_command function
@test "execute_review_command sends review command with PR reference" {
    # Setup successful execution
    export MOCK_SESSION_ACTIVE="true"
    export MOCK_COMMAND_SEND_SUCCESS="true"
    export MOCK_COMPLETION_SUCCESS="true"
    
    run execute_review_command "/review PR-123" "PR-123"
    
    [ "$status" -eq 0 ]
    assert_output_contains "Review command sent successfully"
    
    # Verify correct command and completion monitoring
    local sent_command=$(cat "$TEST_TEMP_DIR/sent_commands.log")
    [ "$sent_command" = "/review PR-123" ]
    
    local completion_event=$(cat "$TEST_TEMP_DIR/completion_events.log")
    [ "$completion_event" = "review:/review PR-123:success" ]
}

@test "execute_review_command fails with inactive session" {
    # Setup inactive session
    export MOCK_SESSION_ACTIVE="false"
    
    run execute_review_command "/review PR-456" "PR-456"
    
    [ "$status" -eq 1 ]
    assert_output_contains "No active Claude session for review command"
}

@test "execute_review_command handles completion failure" {
    # Setup completion failure
    export MOCK_SESSION_ACTIVE="true"
    export MOCK_COMMAND_SEND_SUCCESS="true"
    export MOCK_COMPLETION_SUCCESS="false"
    
    run execute_review_command "/review PR-789" "PR-789"
    
    [ "$status" -eq 1 ]
    assert_output_contains "Review command failed or timed out"
}

# Test: execute_merge_command function
@test "execute_merge_command executes merge with issue context" {
    # Setup successful execution
    export MOCK_SESSION_ACTIVE="true"
    export MOCK_COMMAND_SEND_SUCCESS="true"
    export MOCK_COMPLETION_SUCCESS="true"
    
    run execute_merge_command "/dev merge-pr 123 --focus-main" "123"
    
    [ "$status" -eq 0 ]
    assert_output_contains "Merge command sent successfully"
    
    # Verify command execution and completion
    local sent_command=$(cat "$TEST_TEMP_DIR/sent_commands.log")
    [ "$sent_command" = "/dev merge-pr 123 --focus-main" ]
    
    local completion_event=$(cat "$TEST_TEMP_DIR/completion_events.log")
    [ "$completion_event" = "merge:/dev merge-pr 123 --focus-main:success" ]
}

@test "execute_merge_command fails with inactive session" {
    # Setup inactive session
    export MOCK_SESSION_ACTIVE="false"
    
    run execute_merge_command "/dev merge-pr 456 --focus-main" "456"
    
    [ "$status" -eq 1 ]
    assert_output_contains "No active Claude session for merge command"
}

@test "execute_merge_command handles send failure" {
    # Setup command send failure
    export MOCK_SESSION_ACTIVE="true"
    export MOCK_COMMAND_SEND_SUCCESS="false"
    
    run execute_merge_command "/dev merge-pr 789 --focus-main" "789"
    
    [ "$status" -eq 1 ]
    assert_output_contains "Failed to send merge command"
}

# Test: execute_generic_command function
@test "execute_generic_command handles arbitrary commands" {
    # Setup successful execution
    export MOCK_SESSION_ACTIVE="true"
    export MOCK_COMMAND_SEND_SUCCESS="true"
    export MOCK_COMPLETION_SUCCESS="true"
    
    run execute_generic_command "/custom test command"
    
    [ "$status" -eq 0 ]
    assert_output_contains "Generic command sent successfully"
    
    # Verify command execution
    local sent_command=$(cat "$TEST_TEMP_DIR/sent_commands.log")
    [ "$sent_command" = "/custom test command" ]
    
    local completion_event=$(cat "$TEST_TEMP_DIR/completion_events.log")
    [ "$completion_event" = "generic:/custom test command:success" ]
}

@test "execute_generic_command validates session availability" {
    # Setup inactive session
    export MOCK_SESSION_ACTIVE="false"
    
    run execute_generic_command "/some command"
    
    [ "$status" -eq 1 ]
    assert_output_contains "No active Claude session for generic command"
}

# Test: Command parameter extraction and context handling
@test "execute_workflow_step routes commands to correct handlers" {
    # Test development phase routing
    export MOCK_SESSION_ACTIVE="true"
    export MOCK_COMMAND_SEND_SUCCESS="true"
    export MOCK_COMPLETION_SUCCESS="true"
    
    run execute_workflow_step "/dev 123" "develop" "123"
    
    [ "$status" -eq 0 ]
    
    # Verify development command was processed
    local completion_event=$(cat "$TEST_TEMP_DIR/completion_events.log")
    [ "$completion_event" = "develop:/dev 123:success" ]
}

@test "execute_workflow_step handles unknown phases gracefully" {
    # Test unknown phase fallback to generic
    export MOCK_SESSION_ACTIVE="true"
    export MOCK_COMMAND_SEND_SUCCESS="true"
    export MOCK_COMPLETION_SUCCESS="true"
    
    run execute_workflow_step "/unknown command" "unknown_phase" "context"
    
    [ "$status" -eq 0 ]
    assert_output_contains "Unknown workflow step phase: unknown_phase"
    
    # Should fall back to generic execution
    local completion_event=$(cat "$TEST_TEMP_DIR/completion_events.log")
    [ "$completion_event" = "generic:/unknown command:success" ]
}

# Test: Session management integration
@test "command execution respects session lifecycle" {
    # Test sequence: inactive -> start -> execute -> verify active
    export MOCK_SESSION_ACTIVE="false"
    export MOCK_SESSION_START_SUCCESS="true"
    export MOCK_COMMAND_SEND_SUCCESS="true"
    export MOCK_COMPLETION_SUCCESS="true"
    
    # First command should start session
    run execute_dev_command "/dev 111" "111"
    [ "$status" -eq 0 ]
    
    # Session should now be active
    [ "$MOCK_SESSION_ACTIVE" = "true" ]
    
    # Second command should use existing session
    run execute_clear_command "/clear"
    [ "$status" -eq 0 ]
    
    # Verify both commands were sent
    local sent_commands=$(cat "$TEST_TEMP_DIR/sent_commands.log")
    [[ "$sent_commands" =~ "/dev 111" ]]
    [[ "$sent_commands" =~ "/clear" ]]
}

# Test: Error handling and logging
@test "command execution provides detailed error logging" {
    # Setup failure scenario
    export MOCK_SESSION_ACTIVE="false"
    export MOCK_SESSION_START_SUCCESS="false"
    
    run execute_dev_command "/dev 999" "999"
    
    [ "$status" -eq 1 ]
    
    # Verify comprehensive error logging
    assert_output_contains "No active Claude session for dev command"
    assert_output_contains "Attempting to start new session"
    assert_output_contains "Failed to start Claude session"
}

# Test: Command timeout and completion monitoring
@test "command execution integrates with completion monitoring" {
    # Verify completion monitoring is called with correct parameters
    export MOCK_SESSION_ACTIVE="true"
    export MOCK_COMMAND_SEND_SUCCESS="true"
    export MOCK_COMPLETION_SUCCESS="true"
    
    run execute_review_command "/review PR-555" "PR-555"
    
    [ "$status" -eq 0 ]
    
    # Check completion event log for correct phase and context
    local completion_event=$(cat "$TEST_TEMP_DIR/completion_events.log")
    [ "$completion_event" = "review:/review PR-555:success" ]
}

# Test: Resource cleanup and state management
@test "command execution maintains clean state between calls" {
    # Setup successful execution environment
    export MOCK_SESSION_ACTIVE="true"
    export MOCK_COMMAND_SEND_SUCCESS="true"
    export MOCK_COMPLETION_SUCCESS="true"
    
    # Execute multiple commands
    run execute_dev_command "/dev 1" "1"
    [ "$status" -eq 0 ]
    
    run execute_clear_command "/clear"
    [ "$status" -eq 0 ]
    
    run execute_review_command "/review PR-1" "PR-1"
    [ "$status" -eq 0 ]
    
    run execute_merge_command "/dev merge-pr 1 --focus-main" "1"
    [ "$status" -eq 0 ]
    
    # Verify all commands were recorded correctly
    local sent_commands=$(wc -l < "$TEST_TEMP_DIR/sent_commands.log")
    [ "$sent_commands" -eq 4 ]
    
    local completion_events=$(wc -l < "$TEST_TEMP_DIR/completion_events.log")  
    [ "$completion_events" -eq 4 ]
}