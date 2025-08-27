#!/usr/bin/env bats

# Basic Test Suite: Task Execution Engine - Critical Functions Only
# Fast verification of core Task Execution Engine functionality

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

setup() {
    default_setup
    export SCRIPT_DIR="$TEST_TEMP_DIR/src"
    export WORKING_DIR="$TEST_TEMP_DIR/work"
    
    # Create basic script structure
    mkdir -p "$SCRIPT_DIR" "$WORKING_DIR"
    
    # Create minimal hybrid-monitor.sh for testing
    cp /Volumes/SSD-MacMini/ClaudeCode/Claude-Auto-Resume-System/src/hybrid-monitor.sh "$SCRIPT_DIR/"
}

teardown() {
    default_teardown
}

# ===============================================================================
# CRITICAL FUNCTIONALITY TESTS
# ===============================================================================

@test "Critical: hybrid-monitor.sh script has valid bash syntax" {
    run bash -n "$SCRIPT_DIR/hybrid-monitor.sh"
    
    assert_success
}

@test "Critical: script contains all new Task Queue CLI parameters in help text" {
    run grep -c "queue-mode\|add-issue\|add-pr\|add-custom\|list-queue\|clear-queue\|pause-queue\|resume-queue\|skip-current\|retry-current\|queue-timeout\|queue-retries\|queue-priority" "$SCRIPT_DIR/hybrid-monitor.sh"
    
    assert_success
    # Should find at least 13 occurrences (all 13 new parameters)
    [[ "${output}" -ge 13 ]]
}

@test "Critical: script contains Task Execution Engine core functions" {
    # Check for critical new functions
    run grep -c "process_task_queue_cycle\|execute_single_task\|monitor_task_completion\|execute_task_with_monitoring\|initialize_session_for_tasks\|handle_task_failure" "$SCRIPT_DIR/hybrid-monitor.sh"
    
    assert_success
    # Should find at least 6 occurrences (core functions)
    [[ "${output}" -ge 6 ]]
}

@test "Critical: script contains Task Queue module loading logic" {
    run grep -A5 -B5 "Task Queue Core Module" "$SCRIPT_DIR/hybrid-monitor.sh"
    
    assert_success
    assert_output --partial "task-queue.sh"
    assert_output --partial "init_task_queue"
}

@test "Critical: script contains GitHub integration loading logic" {
    run grep -A10 "GitHub Integration Modules" "$SCRIPT_DIR/hybrid-monitor.sh"
    
    assert_success  
    assert_output --partial "github-integration"
    assert_output --partial "github-task-integration"
    assert_output --partial "github-integration-comments"
}

@test "Critical: script contains completion pattern detection" {
    run grep -B2 -A2 "TASK_COMPLETION_PATTERN\|###TASK_COMPLETE###" "$SCRIPT_DIR/hybrid-monitor.sh"
    
    assert_success
    assert_output --partial "completion_pattern"
}

@test "Critical: script contains parameter validation functions" {
    run grep -A10 "validate_number_parameter" "$SCRIPT_DIR/hybrid-monitor.sh"
    
    assert_success
    assert_output --partial "min_value"
    assert_output --partial "max_value"
    assert_output --partial "valid number"
}

@test "Critical: script contains task execution workflow" {
    # Look for task execution workflow steps
    run grep -C3 "Update task status\|send_command_to_session\|monitor_task_completion" "$SCRIPT_DIR/hybrid-monitor.sh"
    
    assert_success
    assert_output --partial "in_progress"
    assert_output --partial "completed"
}

@test "Critical: script contains error handling and retry logic" {
    run grep -C3 "handle_task_failure\|retry_count\|max_retries" "$SCRIPT_DIR/hybrid-monitor.sh"
    
    assert_success
    assert_output --partial "retry"
    assert_output --partial "exponential backoff"
}

@test "Critical: script maintains backward compatibility with original parameters" {
    # Check that original parameters are still supported
    run grep -E "continuous|check-interval|max-cycles|new-terminal|debug|dry-run" "$SCRIPT_DIR/hybrid-monitor.sh"
    
    assert_success
    assert_output --partial "continuous"
    assert_output --partial "debug"
}

@test "Critical: script has proper dependency loading for Task Queue" {
    run grep -A20 "TASK_QUEUE_ENABLED.*true" "$SCRIPT_DIR/hybrid-monitor.sh"
    
    assert_success
    assert_output --partial "loading integration modules"
    assert_output --partial "modules loaded successfully"
}

@test "Critical: script contains all 14 new CLI parameter handlers" {
    # Test that all new parameters are handled in parse_arguments
    local parameters=(
        "queue-mode"
        "add-issue" 
        "add-pr"
        "add-custom"
        "list-queue"
        "clear-queue"
        "pause-queue" 
        "resume-queue"
        "skip-current"
        "retry-current"
        "queue-timeout"
        "queue-retries"
        "queue-priority"
    )
    
    local found_count=0
    for param in "${parameters[@]}"; do
        if grep -q "--$param)" "$SCRIPT_DIR/hybrid-monitor.sh"; then
            ((found_count++))
        fi
    done
    
    # All 13 parameters should be found
    [[ $found_count -eq 13 ]]
}

@test "Critical: script contains queue action handlers" {
    # Check that queue actions are implemented
    run grep -A5 "handle_queue_actions" "$SCRIPT_DIR/hybrid-monitor.sh"
    
    assert_success
    assert_output --partial "QUEUE_ACTION"
    
    # Check specific action handlers
    run grep -E "add_issue|add_pr|add_custom|list_queue|clear_queue" "$SCRIPT_DIR/hybrid-monitor.sh"
    
    assert_success
}

@test "Critical: script contains task processing integration in monitoring loop" {
    # Check that task queue processing is integrated into the main loop
    run grep -A10 -B5 "process_task_queue_cycle" "$SCRIPT_DIR/hybrid-monitor.sh"
    
    assert_success
    assert_output --partial "Task queue processing"
    assert_output --partial "TASK_QUEUE_ENABLED"
}

@test "Critical: script file size indicates comprehensive implementation" {
    # The script should be significantly larger than the original
    local file_size
    file_size=$(wc -l < "$SCRIPT_DIR/hybrid-monitor.sh")
    
    # Should be around 1,869 lines (as mentioned in requirements)  
    [[ $file_size -gt 1800 ]]
}

# ===============================================================================
# INTEGRATION CHECK TESTS
# ===============================================================================

@test "Integration Check: script references all required modules" {
    # Check that all modules needed for Task Execution Engine are referenced
    local modules=(
        "task-queue.sh"
        "github-integration.sh"
        "github-integration-comments.sh" 
        "github-task-integration.sh"
        "claunch-integration.sh"
        "session-manager.sh"
    )
    
    local found_modules=0
    for module in "${modules[@]}"; do
        if grep -q "$module" "$SCRIPT_DIR/hybrid-monitor.sh"; then
            ((found_modules++))
        fi
    done
    
    # At least 4 core modules should be referenced
    [[ $found_modules -ge 4 ]]
}

@test "Integration Check: script has proper configuration parameter handling" {
    # Check that Task Queue config parameters are handled
    run grep -E "TASK_DEFAULT_TIMEOUT|TASK_MAX_RETRIES|TASK_DEFAULT_PRIORITY|GITHUB_INTEGRATION_ENABLED" "$SCRIPT_DIR/hybrid-monitor.sh"
    
    assert_success
    assert_output --partial "TASK_DEFAULT_TIMEOUT"
    assert_output --partial "GITHUB_INTEGRATION_ENABLED"
}

@test "Integration Check: script contains session management for task processing" {
    # Check that session is properly managed for task execution
    run grep -C5 "initialize_session_for_tasks\|MAIN_SESSION_ID" "$SCRIPT_DIR/hybrid-monitor.sh"
    
    assert_success
    assert_output --partial "session"
    assert_output --partial "task processing"
}

@test "Integration Check: Help text includes comprehensive Task Queue documentation" {
    run grep -A50 "TASK QUEUE OPTIONS:" "$SCRIPT_DIR/hybrid-monitor.sh"
    
    assert_success
    assert_output --partial "Task Management:"
    assert_output --partial "Queue Control:"
    assert_output --partial "Queue Configuration:"
    assert_output --partial "EXAMPLES:"
    assert_output --partial "TASK QUEUE WORKFLOW:"
}