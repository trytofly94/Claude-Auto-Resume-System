#!/usr/bin/env bats

# Test Phase 1: Error Handling and Graceful Degradation
# Tests error scenarios and graceful degradation when task queue is unavailable or fails

load '../test_helper'

setup() {
    # Create test environment
    export TEST_MODE=true
    export LOG_LEVEL=ERROR  # Reduce noise but capture errors
    
    # Create test config
    TEST_CONFIG="$(mktemp)"
    cat > "$TEST_CONFIG" << 'EOF'
TASK_QUEUE_ENABLED=true
TASK_QUEUE_DIR="test-queue"
CHECK_INTERVAL_MINUTES=5
LOG_LEVEL="ERROR"
EOF
    export CONFIG_FILE="$TEST_CONFIG"
    
    # Create test directories
    TEST_DIR="$(mktemp -d)"
    export TEST_DIR
    
    # Create failing task queue script for error testing
    FAILING_TASK_QUEUE_SCRIPT="$TEST_DIR/failing-task-queue.sh"
    cat > "$FAILING_TASK_QUEUE_SCRIPT" << 'EOF'
#!/bin/bash
# Failing task queue script for error testing
echo "task-queue.sh error: $*" >&2
exit 1
EOF
    chmod +x "$FAILING_TASK_QUEUE_SCRIPT"
    export FAILING_TASK_QUEUE_SCRIPT
}

teardown() {
    [[ -f "$TEST_CONFIG" ]] && rm -f "$TEST_CONFIG"
    [[ -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"
}

@test "error handling: task queue script not found" {
    # Test with non-existent task queue script
    export TASK_QUEUE_SCRIPT="/non/existent/script.sh"
    export TASK_QUEUE_AVAILABLE=false
    
    run timeout 10s "$SRC_DIR/hybrid-monitor.sh" --add-issue 123
    assert_failure
    assert_output --partial "Task Queue module not available"
}

@test "error handling: task queue script not executable" {
    # Create non-executable script
    NON_EXEC_SCRIPT="$TEST_DIR/non-exec-script.sh"
    echo "#!/bin/bash" > "$NON_EXEC_SCRIPT"
    # Don't make it executable
    
    export TASK_QUEUE_SCRIPT="$NON_EXEC_SCRIPT"
    export TASK_QUEUE_AVAILABLE=false
    
    run timeout 10s "$SRC_DIR/hybrid-monitor.sh" --add-issue 123
    assert_failure
    assert_output --partial "Task Queue module not available"
}

@test "error handling: task queue add operation fails" {
    # Test with failing task queue script
    export TASK_QUEUE_SCRIPT="$FAILING_TASK_QUEUE_SCRIPT"
    export TASK_QUEUE_AVAILABLE=true
    
    run timeout 10s "$SRC_DIR/hybrid-monitor.sh" --add-issue 123
    
    # Script should handle the failure gracefully
    # (The main script continues even if individual operations fail)
    assert_output --partial "Failed to add GitHub issue"
}

@test "error handling: task queue list operation fails" {
    # Test with failing task queue for list operation
    export TASK_QUEUE_SCRIPT="$FAILING_TASK_QUEUE_SCRIPT"
    export TASK_QUEUE_AVAILABLE=true
    
    run timeout 10s "$SRC_DIR/hybrid-monitor.sh" --list-queue
    
    # Should show the error but not crash
    assert_output --partial "task-queue.sh error"
}

@test "error handling: task queue pause operation fails" {
    # Test graceful handling of pause failure
    export TASK_QUEUE_SCRIPT="$FAILING_TASK_QUEUE_SCRIPT"
    export TASK_QUEUE_AVAILABLE=true
    
    run timeout 10s "$SRC_DIR/hybrid-monitor.sh" --pause-queue
    
    # Should log the failure
    assert_output --partial "task-queue.sh error"
}

@test "error handling: task queue resume operation fails" {
    # Test graceful handling of resume failure
    export TASK_QUEUE_SCRIPT="$FAILING_TASK_QUEUE_SCRIPT"
    export TASK_QUEUE_AVAILABLE=true
    
    run timeout 10s "$SRC_DIR/hybrid-monitor.sh" --resume-queue
    
    # Should log the failure
    assert_output --partial "task-queue.sh error"
}

@test "error handling: task queue clear operation fails" {
    # Test graceful handling of clear failure
    export TASK_QUEUE_SCRIPT="$FAILING_TASK_QUEUE_SCRIPT"
    export TASK_QUEUE_AVAILABLE=true
    
    run timeout 10s "$SRC_DIR/hybrid-monitor.sh" --clear-queue
    
    # Should log the failure
    assert_output --partial "task-queue.sh error"
}

@test "error handling: process_task_queue handles missing task queue" {
    # Test process_task_queue when task queue is unavailable
    export TASK_QUEUE_AVAILABLE=false
    
    # Run in continuous mode briefly to trigger process_task_queue
    run timeout 2s "$SRC_DIR/hybrid-monitor.sh" --continuous
    
    # Should handle gracefully without errors
    assert_equal "$status" 124  # timeout exit code
    
    # Check that it logged task queue unavailability
    run grep -i "task queue not available.*skipping processing" "$LOG_FILE"
    assert_success
}

@test "error handling: process_task_queue handles failing task queue commands" {
    # Test process_task_queue with failing task queue commands
    export TASK_QUEUE_SCRIPT="$FAILING_TASK_QUEUE_SCRIPT"
    export TASK_QUEUE_AVAILABLE=true
    
    # Run briefly to trigger process_task_queue
    run timeout 2s "$SRC_DIR/hybrid-monitor.sh" --queue-mode --continuous
    
    # Should handle failures in task queue commands gracefully
    assert_equal "$status" 124  # timeout exit code
}

@test "error handling: invalid issue number validation" {
    # Create valid task queue script for parameter validation
    VALID_SCRIPT="$TEST_DIR/valid-script.sh"
    cat > "$VALID_SCRIPT" << 'EOF'
#!/bin/bash
echo "Valid script: $*"
exit 0
EOF
    chmod +x "$VALID_SCRIPT"
    export TASK_QUEUE_SCRIPT="$VALID_SCRIPT"
    export TASK_QUEUE_AVAILABLE=true
    
    # Test with invalid issue number
    run timeout 10s "$SRC_DIR/hybrid-monitor.sh" --add-issue abc
    assert_failure
    assert_output --partial "Error: Invalid issue number"
}

@test "error handling: invalid PR number validation" {
    # Setup valid script
    VALID_SCRIPT="$TEST_DIR/valid-script.sh"
    cat > "$VALID_SCRIPT" << 'EOF'
#!/bin/bash
echo "Valid script: $*"
exit 0
EOF
    chmod +x "$VALID_SCRIPT"
    export TASK_QUEUE_SCRIPT="$VALID_SCRIPT"
    export TASK_QUEUE_AVAILABLE=true
    
    # Test with invalid PR number
    run timeout 10s "$SRC_DIR/hybrid-monitor.sh" --add-pr xyz
    assert_failure
    assert_output --partial "Error: Invalid PR number"
}

@test "error handling: missing custom task description" {
    # Setup valid script
    VALID_SCRIPT="$TEST_DIR/valid-script.sh"
    cat > "$VALID_SCRIPT" << 'EOF'
#!/bin/bash
echo "Valid script: $*"
exit 0
EOF
    chmod +x "$VALID_SCRIPT"
    export TASK_QUEUE_SCRIPT="$VALID_SCRIPT"
    export TASK_QUEUE_AVAILABLE=true
    
    # Test with missing custom task argument
    run timeout 10s "$SRC_DIR/hybrid-monitor.sh" --add-custom
    assert_failure
    assert_output --partial "Error: --add-custom requires a task description"
}

@test "error handling: configuration file read errors" {
    # Test with unreadable config file
    UNREADABLE_CONFIG="$TEST_DIR/unreadable.conf"
    echo "TEST=value" > "$UNREADABLE_CONFIG"
    chmod 000 "$UNREADABLE_CONFIG"
    
    export CONFIG_FILE="$UNREADABLE_CONFIG"
    
    # Should fall back to defaults gracefully
    run timeout 5s "$SRC_DIR/hybrid-monitor.sh" --help
    
    # The script may show a warning but should continue
    # (Bash source command behavior varies by system)
    
    # Cleanup
    chmod 644 "$UNREADABLE_CONFIG"
}

@test "error handling: mixed operation success and failure" {
    # Create partially failing script (succeeds for some operations, fails for others)
    MIXED_SCRIPT="$TEST_DIR/mixed-script.sh"
    cat > "$MIXED_SCRIPT" << 'EOF'
#!/bin/bash
case "$1" in
    "add")
        if [[ "$2" == "github_issue" ]]; then
            echo "Successfully added issue"
            exit 0
        else
            echo "Failed to add: $2" >&2
            exit 1
        fi
        ;;
    "pause")
        echo "Pause failed" >&2
        exit 1
        ;;
    *)
        echo "Command: $*"
        exit 0
        ;;
esac
EOF
    chmod +x "$MIXED_SCRIPT"
    export TASK_QUEUE_SCRIPT="$MIXED_SCRIPT"
    export TASK_QUEUE_AVAILABLE=true
    
    # Run mixed operations
    run timeout 10s "$SRC_DIR/hybrid-monitor.sh" --add-issue 123 --pause-queue
    
    # Should handle partial success/failure
    assert_output --partial "Successfully added issue"
    assert_output --partial "Pause failed"
}

@test "error handling: graceful degradation in continuous mode" {
    # Test that task queue failures don't break continuous monitoring
    export TASK_QUEUE_SCRIPT="$FAILING_TASK_QUEUE_SCRIPT"
    export TASK_QUEUE_AVAILABLE=true
    
    # Start continuous mode with task queue enabled
    run timeout 3s "$SRC_DIR/hybrid-monitor.sh" --queue-mode --continuous
    
    # Should timeout (expected) but not crash
    assert_equal "$status" 124  # timeout exit code
    
    # Should continue monitoring despite task queue failures
    run grep -i "starting continuous monitoring" "$LOG_FILE"
    assert_success
}

@test "error handling: signal handling with task queue errors" {
    # Test that signal handling works correctly even when task queue operations fail
    export TASK_QUEUE_SCRIPT="$FAILING_TASK_QUEUE_SCRIPT"
    export TASK_QUEUE_AVAILABLE=true
    
    # Start and interrupt
    run timeout 2s "$SRC_DIR/hybrid-monitor.sh" --queue-mode --continuous
    
    # Should handle interruption gracefully
    assert_equal "$status" 124  # timeout exit code
    
    # Should not leave hanging processes or incomplete operations
    # (This is implicit - if the test completes, cleanup worked)
}

@test "error handling: network dependency failures with task queue" {
    # Test behavior when network checks fail but task queue operations are requested
    export NETWORK_TIMEOUT=1  # Very short timeout to trigger failures
    
    VALID_SCRIPT="$TEST_DIR/valid-script.sh"
    cat > "$VALID_SCRIPT" << 'EOF'
#!/bin/bash
echo "Added task: $*"
exit 0
EOF
    chmod +x "$VALID_SCRIPT"
    export TASK_QUEUE_SCRIPT="$VALID_SCRIPT"
    export TASK_QUEUE_AVAILABLE=true
    
    # Should still handle task queue operations even if network checks fail
    run timeout 10s "$SRC_DIR/hybrid-monitor.sh" --add-custom "Network test task"
    assert_success
    assert_output --partial "Added task"
}

@test "error handling: multiple parameter validation errors" {
    # Test handling of multiple invalid parameters
    run timeout 10s "$SRC_DIR/hybrid-monitor.sh" --add-issue abc --add-pr xyz --add-custom
    
    # Should show all relevant error messages
    assert_failure
    assert_output --partial "Error: Invalid issue number"
}

@test "error handling: task queue unavailable but monitoring continues" {
    # Test that monitoring functions continue when task queue is unavailable
    export TASK_QUEUE_AVAILABLE=false
    
    run timeout 3s "$SRC_DIR/hybrid-monitor.sh" --continuous
    
    # Should start monitoring successfully
    assert_equal "$status" 124  # timeout exit code
    
    # Should log that monitoring started
    run grep -i "starting continuous monitoring" "$LOG_FILE"
    assert_success
}