#!/usr/bin/env bats

# Test Phase 1: CLI Parameter Parsing for Task Queue Integration
# Tests comprehensive CLI parameter parsing for --queue-mode, --add-issue, --add-pr, --add-custom, etc.

load '../test_helper'

setup() {
    # Create test environment
    export TEST_MODE=true
    export LOG_LEVEL=ERROR  # Reduce noise in tests
    
    # Set up paths
    export SRC_DIR="$BATS_TEST_DIRNAME/../../src"
    export LOG_FILE="$(mktemp)"
    
    # Mock dependencies
    MOCK_TASK_QUEUE_SCRIPT="$(mktemp)"
    cat > "$MOCK_TASK_QUEUE_SCRIPT" << 'EOF'
#!/bin/bash
# Mock task-queue.sh for testing
echo "Mock task-queue.sh called with args: $*" >&2
case "$1" in
    "add") exit 0 ;;
    "list") 
        if [[ "$*" == *"--status=pending --count-only"* ]]; then
            echo "2"
        elif [[ "$*" == *"--status=pending --format=id-only --limit=1"* ]]; then
            echo "task-123"
        else
            echo "Mock task list"
        fi
        ;;
    "status") echo "Queue Status: active" ;;
    "pause"|"resume"|"clear") exit 0 ;;
    *) echo "Unknown command: $1" >&2; exit 1 ;;
esac
EOF
    chmod +x "$MOCK_TASK_QUEUE_SCRIPT"
    export TASK_QUEUE_SCRIPT="$MOCK_TASK_QUEUE_SCRIPT"
    export TASK_QUEUE_AVAILABLE=true
}

teardown() {
    [[ -f "$MOCK_TASK_QUEUE_SCRIPT" ]] && rm -f "$MOCK_TASK_QUEUE_SCRIPT"
}

@test "CLI parameter parsing: --queue-mode sets QUEUE_MODE=true" {
    # Test that --queue-mode parameter is correctly parsed
    run timeout 5s "$SRC_DIR/hybrid-monitor.sh" --queue-mode --help
    [ "$status" -eq 0 ]
    
    # Check that queue mode is mentioned in help when --queue-mode is used
    [[ "$output" == *"TASK QUEUE OPTIONS"* ]]
}

@test "CLI parameter parsing: --add-issue accepts numeric issue number" {
    # Test --add-issue with valid number
    run timeout 10s "$SRC_DIR/hybrid-monitor.sh" --add-issue 123
    assert_success
    
    # Check that the operation was logged
    run grep -i "adding github issue.*123" "$LOG_FILE"
    assert_success
}

@test "CLI parameter parsing: --add-issue rejects non-numeric input" {
    # Test --add-issue with invalid input
    run timeout 5s "$SRC_DIR/hybrid-monitor.sh" --add-issue abc
    assert_failure
    
    # Should show error message for invalid issue number
    assert_output --partial "Error: Invalid issue number"
}

@test "CLI parameter parsing: --add-pr accepts numeric PR number" {
    # Test --add-pr with valid number
    run timeout 10s "$SRC_DIR/hybrid-monitor.sh" --add-pr 456
    assert_success
    
    # Check that the operation was logged
    run grep -i "adding github pr.*456" "$LOG_FILE"
    assert_success
}

@test "CLI parameter parsing: --add-pr rejects non-numeric input" {
    # Test --add-pr with invalid input
    run timeout 5s "$SRC_DIR/hybrid-monitor.sh" --add-pr xyz
    assert_failure
    
    # Should show error message for invalid PR number
    assert_output --partial "Error: Invalid PR number"
}

@test "CLI parameter parsing: --add-custom accepts quoted strings" {
    # Test --add-custom with quoted task description
    run timeout 10s "$SRC_DIR/hybrid-monitor.sh" --add-custom "Implement user authentication feature"
    assert_success
    
    # Check that the operation was logged
    run grep -i "adding custom task" "$LOG_FILE"
    assert_success
}

@test "CLI parameter parsing: --add-custom requires argument" {
    # Test --add-custom without argument
    run timeout 5s "$SRC_DIR/hybrid-monitor.sh" --add-custom
    assert_failure
    
    # Should show error message for missing argument
    assert_output --partial "Error: --add-custom requires a task description"
}

@test "CLI parameter parsing: --list-queue flag parsing" {
    # Test --list-queue flag
    run timeout 10s "$SRC_DIR/hybrid-monitor.sh" --list-queue
    assert_success
    
    # Should call task queue list command
    assert_output --partial "Mock task list"
}

@test "CLI parameter parsing: --pause-queue flag parsing" {
    # Test --pause-queue flag
    run timeout 10s "$SRC_DIR/hybrid-monitor.sh" --pause-queue
    assert_success
    
    # Check that pause operation was logged
    run grep -i "pausing task queue" "$LOG_FILE"
    assert_success
}

@test "CLI parameter parsing: --resume-queue flag parsing" {
    # Test --resume-queue flag
    run timeout 10s "$SRC_DIR/hybrid-monitor.sh" --resume-queue
    assert_success
    
    # Check that resume operation was logged
    run grep -i "resuming task queue" "$LOG_FILE"
    assert_success
}

@test "CLI parameter parsing: --clear-queue flag parsing" {
    # Test --clear-queue flag
    run timeout 10s "$SRC_DIR/hybrid-monitor.sh" --clear-queue
    assert_success
    
    # Check that clear operation was logged
    run grep -i "clearing task queue" "$LOG_FILE"
    assert_success
}

@test "CLI parameter parsing: multiple queue parameters together" {
    # Test combining --add-issue with --queue-mode
    run timeout 10s "$SRC_DIR/hybrid-monitor.sh" --queue-mode --add-issue 789
    assert_success
    
    # Should process the add operation
    run grep -i "adding github issue.*789" "$LOG_FILE"
    assert_success
}

@test "CLI parameter parsing: queue parameters with --continuous" {
    # Test queue parameters with continuous mode
    # Using timeout to prevent infinite loop in continuous mode
    run timeout 3s "$SRC_DIR/hybrid-monitor.sh" --add-custom "Test task" --continuous
    
    # Should timeout (expected) but start successfully
    assert_equal "$status" 124  # timeout exit code
    
    # Check that task was added before continuous mode started
    run grep -i "adding custom task" "$LOG_FILE"
    assert_success
}

@test "CLI parameter parsing: help shows task queue options" {
    # Test that help includes task queue options
    run "$SRC_DIR/hybrid-monitor.sh" --help
    assert_success
    
    # Should include all task queue CLI options
    assert_output --partial "TASK QUEUE OPTIONS:"
    assert_output --partial "--queue-mode"
    assert_output --partial "--add-issue"
    assert_output --partial "--add-pr" 
    assert_output --partial "--add-custom"
    assert_output --partial "--list-queue"
    assert_output --partial "--pause-queue"
    assert_output --partial "--resume-queue"
    assert_output --partial "--clear-queue"
}

@test "CLI parameter parsing: parameter validation with missing task queue" {
    # Test behavior when task queue is not available
    export TASK_QUEUE_AVAILABLE=false
    
    run timeout 10s "$SRC_DIR/hybrid-monitor.sh" --add-issue 123
    assert_failure
    
    # Should show appropriate error message
    assert_output --partial "Task Queue module not available"
}

@test "CLI parameter parsing: parameter combination validation" {
    # Test invalid parameter combinations
    run timeout 5s "$SRC_DIR/hybrid-monitor.sh" --add-issue 123 --add-pr 456
    assert_success  # Both should be processed
    
    # Check that both operations were attempted
    run grep -i "adding github issue.*123" "$LOG_FILE"
    assert_success
    run grep -i "adding github pr.*456" "$LOG_FILE"
    assert_success
}

@test "CLI parameter parsing: exit behavior after queue operations" {
    # Test that script exits after queue operations when not in continuous mode
    run timeout 10s "$SRC_DIR/hybrid-monitor.sh" --add-issue 999
    assert_success
    
    # Should log completion and exit
    run grep -i "queue operations completed" "$LOG_FILE"
    assert_success
}

@test "CLI parameter parsing: queue-mode prevents early exit" {
    # Test that --queue-mode prevents early exit after operations
    run timeout 3s "$SRC_DIR/hybrid-monitor.sh" --queue-mode --add-issue 888
    
    # Should timeout (expected behavior in queue mode)
    assert_equal "$status" 124  # timeout exit code
    
    # Should not show "queue operations completed"
    run grep -i "queue operations completed" "$LOG_FILE"
    assert_failure
}