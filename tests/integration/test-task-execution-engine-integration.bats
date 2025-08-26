#!/usr/bin/env bats

# Integration Test Suite: Task Execution Engine - Complete Workflow Testing
# Tests the full task processing workflow including session management, 
# completion detection, and GitHub integration

load '../test_helper'

# Define assertion functions locally
assert_success() { [[ "$status" -eq 0 ]] || { echo "Expected success but got exit code $status"; return 1; }; }
assert_failure() { [[ "$status" -ne 0 ]] || { echo "Expected failure but got exit code $status"; return 1; }; }
assert_output() { 
    if [[ "$1" == "--partial" ]]; then
        [[ "$output" =~ $2 ]] || { echo "Expected output to contain '$2', got: $output"; return 1; }
    else
        [[ "$output" == "$1" ]] || { echo "Expected output '$1', got: $output"; return 1; }
    fi
}
refute_output() {
    if [[ "$1" == "--partial" ]]; then
        [[ ! "$output" =~ $2 ]] || { echo "Expected output to not contain '$2', got: $output"; return 1; }
    else
        [[ "$output" != "$1" ]] || { echo "Expected output to not be '$1'"; return 1; }
    fi
}

# Setup for all tests in this file
setup() {
    default_setup
    
    # Create comprehensive test environment
    mkdir -p "$TEST_TEMP_DIR/test_working_dir"
    mkdir -p "$TEST_TEMP_DIR/test_config"
    mkdir -p "$TEST_TEMP_DIR/test_logs"
    mkdir -p "$TEST_TEMP_DIR/mock_sessions"
    
    export WORKING_DIR="$TEST_TEMP_DIR/test_working_dir"
    export SCRIPT_DIR="$(dirname "$BATS_TEST_FILENAME")/../.."
    export CONFIG_FILE="$TEST_TEMP_DIR/test_config/test.conf"
    export TASK_QUEUE_ENABLED="true"
    export GITHUB_INTEGRATION_ENABLED="true"
    export DEBUG_MODE="true"
    export DRY_RUN="false"  # Allow some real operations for integration testing
    
    # Create comprehensive test configuration
    cat > "$CONFIG_FILE" << 'EOF'
TASK_QUEUE_ENABLED=true
GITHUB_INTEGRATION_ENABLED=true
TASK_DEFAULT_TIMEOUT=60
TASK_MAX_RETRIES=2
TASK_DEFAULT_PRIORITY=5
TASK_COMPLETION_PATTERN=###TASK_COMPLETE###
QUEUE_PROCESSING_DELAY=5
QUEUE_SESSION_CLEAR_BETWEEN_TASKS=true
DEBUG_MODE=true
USE_CLAUNCH=false
EOF
    
    # Setup mock functions for integration testing
    setup_integration_mocks
}

teardown() {
    default_teardown
}

# Setup mock functions that simulate real system behavior
setup_integration_mocks() {
    # Mock task queue functions with realistic behavior
    cat > "$TEST_TEMP_DIR/mock_task_queue.bash" << 'EOF'
#!/bin/bash

# Mock task queue with JSON task storage
MOCK_TASK_QUEUE_FILE="$TEST_TEMP_DIR/mock_task_queue.json"
MOCK_TASK_COUNTER_FILE="$TEST_TEMP_DIR/mock_task_counter"

init_task_queue() {
    echo '{"tasks": [], "next_id": 1}' > "$MOCK_TASK_QUEUE_FILE"
    echo "0" > "$MOCK_TASK_COUNTER_FILE"
    return 0
}

get_next_task() {
    if [[ ! -f "$MOCK_TASK_QUEUE_FILE" ]]; then
        return 1
    fi
    
    local next_task_id
    next_task_id=$(jq -r '.tasks[] | select(.status == "pending") | .id' "$MOCK_TASK_QUEUE_FILE" 2>/dev/null | head -1)
    
    if [[ -n "$next_task_id" && "$next_task_id" != "null" ]]; then
        echo "$next_task_id"
        return 0
    fi
    
    return 1
}

get_task_details() {
    local task_id="$1"
    if [[ ! -f "$MOCK_TASK_QUEUE_FILE" ]]; then
        return 1
    fi
    
    jq -r ".tasks[] | select(.id == \"$task_id\")" "$MOCK_TASK_QUEUE_FILE" 2>/dev/null
}

update_task_status() {
    local task_id="$1"
    local new_status="$2"
    
    if [[ ! -f "$MOCK_TASK_QUEUE_FILE" ]]; then
        return 1
    fi
    
    jq "(.tasks[] | select(.id == \"$task_id\") | .status) = \"$new_status\"" "$MOCK_TASK_QUEUE_FILE" > "$MOCK_TASK_QUEUE_FILE.tmp" && mv "$MOCK_TASK_QUEUE_FILE.tmp" "$MOCK_TASK_QUEUE_FILE"
}

add_test_task() {
    local task_type="$1"
    local command="$2"
    local description="$3"
    
    if [[ ! -f "$MOCK_TASK_QUEUE_FILE" ]]; then
        init_task_queue
    fi
    
    local task_id="test_task_$(date +%s)_$$"
    
    jq --arg id "$task_id" --arg type "$task_type" --arg cmd "$command" --arg desc "$description" \
       '.tasks += [{
         "id": $id,
         "type": $type,
         "command": $cmd,
         "description": $desc,
         "status": "pending",
         "timeout": 60,
         "created_at": now
       }]' "$MOCK_TASK_QUEUE_FILE" > "$MOCK_TASK_QUEUE_FILE.tmp" && mv "$MOCK_TASK_QUEUE_FILE.tmp" "$MOCK_TASK_QUEUE_FILE"
    
    echo "$task_id"
}

# Mock GitHub integration functions
post_task_start_notification() {
    echo "Mock: Posted start notification for task $1"
    return 0
}

post_task_completion_notification() {
    echo "Mock: Posted completion notification for task $1 with result $2"
    return 0
}

# Mock session management functions
send_command_to_session() {
    local command="$1"
    echo "Mock: Sending command to session: $command" >&2
    
    # Simulate command execution
    sleep 1
    
    # Store command for verification
    echo "$command" >> "$TEST_TEMP_DIR/mock_session_commands.log"
    
    return 0
}

capture_recent_session_output() {
    local session_id="$1"
    
    # Simulate session output based on commands sent
    if [[ -f "$TEST_TEMP_DIR/mock_session_commands.log" ]]; then
        echo "Mock session output for session $session_id"
        echo "Processing task..."
        
        # Simulate task completion after some commands
        local command_count
        command_count=$(wc -l < "$TEST_TEMP_DIR/mock_session_commands.log" 2>/dev/null || echo "0")
        
        if [[ $command_count -ge 2 ]]; then
            echo "Task completed successfully!"
            echo "###TASK_COMPLETE###"
        fi
    else
        echo "Mock session output - no commands yet"
    fi
}

initialize_session_for_tasks() {
    local session_id="$1"
    echo "Mock: Initialized session $session_id for task processing" >&2
    
    # Create session command log
    touch "$TEST_TEMP_DIR/mock_session_commands.log"
    
    return 0
}

verify_session_responsiveness() {
    local session_id="$1"
    echo "Mock: Verified session $session_id responsiveness" >&2
    return 0
}

is_queue_paused() {
    [[ -f "$TEST_TEMP_DIR/mock_queue_paused" ]]
}

EOF

    # Source the mock functions
    source "$TEST_TEMP_DIR/mock_task_queue.bash"
    
    # Also create session-specific mocks
    export MAIN_SESSION_ID="mock_session_123"
}

# ===============================================================================
# TASK PROCESSING WORKFLOW INTEGRATION TESTS
# ===============================================================================

@test "Integration: process_task_queue_cycle handles empty queue gracefully" {
    # Source main script with mocks
    source "$SCRIPT_DIR/src/hybrid-monitor.sh"
    
    # Initialize empty queue
    init_task_queue
    
    run process_task_queue_cycle
    
    assert_success
    
    # Should return gracefully when no tasks available
}

@test "Integration: process_task_queue_cycle executes single task successfully" {
    source "$SCRIPT_DIR/src/hybrid-monitor.sh"
    
    # Initialize queue and add test task
    init_task_queue
    local task_id
    task_id=$(add_test_task "custom" "/dev test task" "Integration test task")
    
    # Mock successful execution
    export MAIN_SESSION_ID="mock_session_123"
    
    run process_task_queue_cycle
    
    assert_success
    assert_output --partial "Processing task from queue: $task_id"
    assert_output --partial "completed successfully"
}

@test "Integration: execute_single_task lifecycle - pending to in_progress to completed" {
    source "$SCRIPT_DIR/src/hybrid-monitor.sh"
    
    # Setup task
    init_task_queue
    local task_id
    task_id=$(add_test_task "custom" "/dev complete this task please" "Test task lifecycle")
    
    # Mock session
    export MAIN_SESSION_ID="mock_session_123"
    
    # Execute task
    run execute_single_task "$task_id"
    
    assert_success
    assert_output --partial "Executing task: $task_id"
    assert_output --partial "Task execution completed successfully"
    
    # Verify task status progression
    local final_status
    final_status=$(jq -r ".tasks[] | select(.id == \"$task_id\") | .status" "$MOCK_TASK_QUEUE_FILE")
    [[ "$final_status" == "completed" ]]
}

@test "Integration: execute_single_task handles missing task gracefully" {
    source "$SCRIPT_DIR/src/hybrid-monitor.sh"
    
    init_task_queue
    
    run execute_single_task "nonexistent_task_123"
    
    assert_failure
    assert_output --partial "Failed to retrieve task details"
}

@test "Integration: execute_single_task handles invalid task data" {
    source "$SCRIPT_DIR/src/hybrid-monitor.sh"
    
    # Create a task with invalid/empty command
    init_task_queue
    local task_id
    task_id=$(add_test_task "custom" "" "Task with empty command")
    
    run execute_single_task "$task_id"
    
    assert_failure
    assert_output --partial "Task command is empty"
}

# ===============================================================================
# TASK EXECUTION WITH MONITORING TESTS
# ===============================================================================

@test "Integration: execute_task_with_monitoring sends commands and monitors completion" {
    source "$SCRIPT_DIR/src/hybrid-monitor.sh"
    
    export MAIN_SESSION_ID="mock_session_123"
    
    # Clear any previous command logs
    rm -f "$TEST_TEMP_DIR/mock_session_commands.log"
    
    run execute_task_with_monitoring "test_task_123" "/dev implement feature X" 60
    
    assert_success
    assert_output --partial "Starting task execution with 60s timeout"
    assert_output --partial "Command sent successfully"
    assert_output --partial "Task completed successfully within timeout"
    
    # Verify command was sent to session
    [[ -f "$TEST_TEMP_DIR/mock_session_commands.log" ]]
    grep -q "/dev implement feature X" "$TEST_TEMP_DIR/mock_session_commands.log"
}

@test "Integration: execute_task_with_monitoring handles session clearing" {
    source "$SCRIPT_DIR/src/hybrid-monitor.sh"
    
    export MAIN_SESSION_ID="mock_session_123" 
    export QUEUE_SESSION_CLEAR_BETWEEN_TASKS="true"
    
    rm -f "$TEST_TEMP_DIR/mock_session_commands.log"
    
    run execute_task_with_monitoring "test_task_456" "/dev fix bug Y" 60
    
    assert_success
    assert_output --partial "Clearing session before task execution"
    
    # Verify clear command was sent first
    [[ -f "$TEST_TEMP_DIR/mock_session_commands.log" ]]
    local first_command
    first_command=$(head -1 "$TEST_TEMP_DIR/mock_session_commands.log")
    [[ "$first_command" == "/clear" ]]
}

@test "Integration: execute_task_with_monitoring fails without active session" {
    source "$SCRIPT_DIR/src/hybrid-monitor.sh"
    
    export MAIN_SESSION_ID=""  # No active session
    
    run execute_task_with_monitoring "test_task_789" "/dev do something" 60
    
    assert_failure
    assert_output --partial "No active Claude session available"
}

# ===============================================================================
# COMPLETION DETECTION SYSTEM TESTS
# ===============================================================================

@test "Integration: monitor_task_completion detects completion pattern" {
    source "$SCRIPT_DIR/src/hybrid-monitor.sh"
    
    export MAIN_SESSION_ID="mock_session_123"
    export TASK_COMPLETION_PATTERN="###TASK_COMPLETE###"
    
    # Pre-populate session commands to trigger completion pattern
    echo "/dev test task" > "$TEST_TEMP_DIR/mock_session_commands.log"
    echo "/dev continue" >> "$TEST_TEMP_DIR/mock_session_commands.log"
    
    run timeout 30 monitor_task_completion "$MAIN_SESSION_ID" 60 "test_task_completion"
    
    assert_success
    assert_output --partial "Completion pattern detected"
}

@test "Integration: monitor_task_completion handles timeout correctly" {
    source "$SCRIPT_DIR/src/hybrid-monitor.sh"
    
    export MAIN_SESSION_ID="mock_session_123"
    
    # Clear command log so no completion pattern is triggered
    rm -f "$TEST_TEMP_DIR/mock_session_commands.log"
    
    # Use very short timeout for test
    run timeout 15 monitor_task_completion "$MAIN_SESSION_ID" 5 "test_task_timeout"
    
    assert_failure
    assert_output --partial "Task timeout reached"
}

@test "Integration: monitor_task_completion shows progress updates" {
    source "$SCRIPT_DIR/src/hybrid-monitor.sh"
    
    export MAIN_SESSION_ID="mock_session_123"
    
    # Mock progress updates by running with short timeout
    run timeout 10 monitor_task_completion "$MAIN_SESSION_ID" 30 "test_task_progress"
    
    # May timeout, but should show monitoring messages
    assert_output --partial "Task execution started"
    assert_output --partial "monitoring for completion pattern"
}

# ===============================================================================
# SESSION INITIALIZATION TESTS
# ===============================================================================

@test "Integration: initialize_session_for_tasks sends initialization commands" {
    source "$SCRIPT_DIR/src/hybrid-monitor.sh"
    
    rm -f "$TEST_TEMP_DIR/mock_session_commands.log"
    
    run initialize_session_for_tasks "mock_session_123"
    
    assert_success
    assert_output --partial "Initializing session mock_session_123 for task processing"
    assert_output --partial "Sending task processing initialization"
    assert_output --partial "initialization completed"
    
    # Verify initialization commands were sent
    [[ -f "$TEST_TEMP_DIR/mock_session_commands.log" ]]
    local command_count
    command_count=$(wc -l < "$TEST_TEMP_DIR/mock_session_commands.log")
    [[ $command_count -ge 3 ]]  # Should send multiple initialization commands
}

@test "Integration: initialize_session_for_tasks handles missing send function gracefully" {
    source "$SCRIPT_DIR/src/hybrid-monitor.sh"
    
    # Undefine the send function to test graceful degradation
    unset -f send_command_to_session
    
    run initialize_session_for_tasks "mock_session_123"
    
    assert_success
    assert_output --partial "send_command_to_session function not available"
    assert_output --partial "skipping session initialization"
}

# ===============================================================================
# ERROR HANDLING AND RECOVERY INTEGRATION TESTS
# ===============================================================================

@test "Integration: handle_task_failure implements retry logic with exponential backoff" {
    source "$SCRIPT_DIR/src/hybrid-monitor.sh"
    
    init_task_queue
    local task_id
    task_id=$(add_test_task "custom" "/dev failing task" "Task that will fail")
    
    # Mock retry count functions
    get_task_retry_count() { echo "1"; }
    increment_task_retry_count() { return 0; }
    
    run handle_task_failure "$task_id" "execution_timeout"
    
    assert_success
    assert_output --partial "Scheduling retry 2/2 for task $task_id"
    assert_output --partial "exponential backoff"
}

@test "Integration: handle_task_failure marks task as permanently failed after max retries" {
    source "$SCRIPT_DIR/src/hybrid-monitor.sh"
    
    init_task_queue
    local task_id
    task_id=$(add_test_task "custom" "/dev permanently failing task" "Task that fails permanently")
    
    # Mock that we've reached max retries
    get_task_retry_count() { echo "3"; }  # Over the limit of 2
    
    run handle_task_failure "$task_id" "execution_failure"
    
    assert_success
    assert_output --partial "permanently failed after 2 retry attempts"
    assert_output --partial "marked as permanently failed"
}

@test "Integration: recover_from_task_processing_error handles different error types" {
    source "$SCRIPT_DIR/src/hybrid-monitor.sh"
    
    # Mock session recovery functions
    perform_session_recovery() { return 0; }
    
    # Test session unresponsive recovery
    run recover_from_task_processing_error "session_unresponsive" "mock_session_123"
    
    assert_success
    assert_output --partial "Attempting recovery from task processing error"
    assert_output --partial "Session recovery successful"
}

# ===============================================================================
# QUEUE PAUSE/RESUME INTEGRATION TESTS
# ===============================================================================

@test "Integration: process_task_queue_cycle respects queue pause state" {
    source "$SCRIPT_DIR/src/hybrid-monitor.sh"
    
    init_task_queue
    add_test_task "custom" "/dev test task" "Should not execute when paused"
    
    # Create pause state
    touch "$TEST_TEMP_DIR/mock_queue_paused"
    
    run process_task_queue_cycle
    
    assert_success
    assert_output --partial "Task queue processing is paused - skipping cycle"
}

@test "Integration: queue auto-pause on permanent failure" {
    source "$SCRIPT_DIR/src/hybrid-monitor.sh"
    
    init_task_queue
    local task_id
    task_id=$(add_test_task "custom" "/dev failing task" "Task for auto-pause test")
    
    export QUEUE_AUTO_PAUSE_ON_ERROR="true"
    
    # Mock functions for auto-pause test
    get_task_retry_count() { echo "3"; }  # Exceeded retry limit
    pause_task_queue() { 
        touch "$TEST_TEMP_DIR/mock_queue_paused"
        echo "Mock: Queue paused with reason: $1"
        return 0
    }
    
    run handle_task_failure "$task_id" "permanent_failure"
    
    assert_success
    assert_output --partial "Auto-pausing task queue due to permanent task failure"
    [[ -f "$TEST_TEMP_DIR/mock_queue_paused" ]]  # Verify pause state was created
}

# ===============================================================================
# GITHUB INTEGRATION WORKFLOW TESTS
# ===============================================================================

@test "Integration: GitHub task execution includes notification lifecycle" {
    source "$SCRIPT_DIR/src/hybrid-monitor.sh"
    
    init_task_queue
    local task_id
    task_id=$(add_test_task "github_issue" "/dev Fix issue #123" "GitHub issue task")
    
    export MAIN_SESSION_ID="mock_session_123"
    
    # Enable output capture to verify notifications
    run execute_single_task "$task_id"
    
    assert_success
    
    # Should include GitHub notifications in output 
    assert_output --partial "Mock: Posted start notification for task $task_id"
    assert_output --partial "Mock: Posted completion notification for task $task_id with result success"
}

@test "Integration: GitHub task failure includes failure notification" {
    source "$SCRIPT_DIR/src/hybrid-monitor.sh"
    
    init_task_queue
    local task_id  
    task_id=$(add_test_task "github_pr" "" "Empty GitHub PR task - should fail")  # Empty command will fail
    
    export MAIN_SESSION_ID="mock_session_123"
    
    run execute_single_task "$task_id"
    
    assert_failure
    assert_output --partial "Mock: Posted completion notification for task $task_id with result failure"
}

# ===============================================================================
# CONFIGURATION INTEGRATION TESTS  
# ===============================================================================

@test "Integration: task queue configuration affects processing behavior" {
    # Create config with specific settings
    cat > "$CONFIG_FILE" << 'EOF'
TASK_QUEUE_ENABLED=true
TASK_COMPLETION_PATTERN=##CUSTOM_COMPLETE##
QUEUE_PROCESSING_DELAY=2
QUEUE_SESSION_CLEAR_BETWEEN_TASKS=false
EOF
    
    source "$SCRIPT_DIR/src/hybrid-monitor.sh"
    load_configuration
    
    # Verify configuration is loaded and affects behavior
    [[ "$TASK_COMPLETION_PATTERN" == "##CUSTOM_COMPLETE##" ]]
    [[ "$QUEUE_PROCESSING_DELAY" == "2" ]]
    [[ "$QUEUE_SESSION_CLEAR_BETWEEN_TASKS" == "false" ]]
}

@test "Integration: end-to-end task processing with custom configuration" {
    # Setup custom configuration
    cat > "$CONFIG_FILE" << 'EOF'
TASK_QUEUE_ENABLED=true
TASK_DEFAULT_TIMEOUT=30
QUEUE_SESSION_CLEAR_BETWEEN_TASKS=false
TASK_COMPLETION_PATTERN=###CUSTOM_DONE###
DEBUG_MODE=true
EOF
    
    source "$SCRIPT_DIR/src/hybrid-monitor.sh"
    load_configuration
    
    init_task_queue
    local task_id
    task_id=$(add_test_task "custom" "/dev quick task" "End-to-end test task")
    
    export MAIN_SESSION_ID="mock_session_integration"
    
    # Mock output to include custom completion pattern
    capture_recent_session_output() {
        echo "Processing task with custom config..."
        echo "###CUSTOM_DONE###"
    }
    
    run execute_single_task "$task_id"
    
    assert_success
    
    # Verify custom timeout is used
    assert_output --partial "with 30s timeout"
    
    # Verify no session clearing (disabled in config)
    refute_output --partial "Clearing session before task execution"
}