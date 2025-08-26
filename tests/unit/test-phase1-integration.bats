#!/usr/bin/env bats

# Test Phase 1: Integration Test for Task Queue CLI Interface
# Tests the actual hybrid-monitor.sh script with task queue integration

load '../test_helper'

setup() {
    # Set up minimal test environment
    export TEST_MODE=true
    export LOG_LEVEL=ERROR
    export SRC_DIR="$BATS_TEST_DIRNAME/../../src"
    export LOG_FILE="$(mktemp)"
    
    # Create mock task queue script
    MOCK_TASK_QUEUE_SCRIPT="$(mktemp)"
    cat > "$MOCK_TASK_QUEUE_SCRIPT" << 'EOF'
#!/bin/bash
echo "Mock task-queue called with: $*" >&2
case "$1" in
    "add") echo "Added task"; exit 0 ;;
    "list") echo "Mock task list"; exit 0 ;;
    "status") echo "Queue Status: active"; exit 0 ;;
    "pause"|"resume"|"clear") echo "Operation: $1"; exit 0 ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "$MOCK_TASK_QUEUE_SCRIPT"
    export TASK_QUEUE_SCRIPT="$MOCK_TASK_QUEUE_SCRIPT"
    export TASK_QUEUE_AVAILABLE=true
    
    # Ensure hybrid-monitor.sh is executable
    chmod +x "$SRC_DIR/hybrid-monitor.sh"
}

teardown() {
    [[ -f "$MOCK_TASK_QUEUE_SCRIPT" ]] && rm -f "$MOCK_TASK_QUEUE_SCRIPT"
    [[ -f "$LOG_FILE" ]] && rm -f "$LOG_FILE"
}

@test "hybrid-monitor.sh help shows task queue options" {
    run "$SRC_DIR/hybrid-monitor.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"TASK QUEUE OPTIONS"* ]]
    [[ "$output" == *"--queue-mode"* ]]
    [[ "$output" == *"--add-issue"* ]]
}

@test "hybrid-monitor.sh accepts --add-issue parameter" {
    run timeout 10s "$SRC_DIR/hybrid-monitor.sh" --add-issue 123
    [ "$status" -eq 0 ]
}

@test "hybrid-monitor.sh accepts --add-custom parameter" {
    run timeout 10s "$SRC_DIR/hybrid-monitor.sh" --add-custom "Test task"
    [ "$status" -eq 0 ]
}

@test "hybrid-monitor.sh rejects invalid issue number" {
    run timeout 10s "$SRC_DIR/hybrid-monitor.sh" --add-issue abc
    [ "$status" -ne 0 ]
    [[ "$output" == *"Error"* ]]
}

@test "hybrid-monitor.sh handles missing task queue gracefully" {
    export TASK_QUEUE_AVAILABLE=false
    
    run timeout 10s "$SRC_DIR/hybrid-monitor.sh" --add-issue 123
    [ "$status" -ne 0 ]
    [[ "$output" == *"Task Queue module not available"* ]]
}

@test "hybrid-monitor.sh configuration loading works" {
    # Test that script can load configuration without errors
    run "$SRC_DIR/hybrid-monitor.sh" --help
    [ "$status" -eq 0 ]
}

@test "hybrid-monitor.sh backward compatibility preserved" {
    # Test that existing functionality still works
    run timeout 5s "$SRC_DIR/hybrid-monitor.sh" --test-mode 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"TEST MODE"* ]]
}

@test "hybrid-monitor.sh handles --queue-mode flag" {
    run timeout 3s "$SRC_DIR/hybrid-monitor.sh" --queue-mode
    # Should timeout in queue mode (expected behavior)
    [ "$status" -eq 124 ]
}

@test "hybrid-monitor.sh processes multiple queue operations" {
    run timeout 10s "$SRC_DIR/hybrid-monitor.sh" --add-issue 123 --add-custom "Test"
    [ "$status" -eq 0 ]
}

@test "hybrid-monitor.sh exits after queue operations when not in continuous mode" {
    run timeout 10s "$SRC_DIR/hybrid-monitor.sh" --add-issue 999
    [ "$status" -eq 0 ]
}