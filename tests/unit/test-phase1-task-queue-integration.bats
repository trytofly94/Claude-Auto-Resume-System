#!/usr/bin/env bats

# Test Phase 1: Task Queue Integration Functionality
# Tests handle_task_queue_operations and process_task_queue functions

load '../test_helper'

setup() {
    # Create test environment
    export TEST_MODE=true
    export LOG_LEVEL=ERROR  # Reduce noise in tests
    
    # Create mock task queue script with various response scenarios
    MOCK_TASK_QUEUE_SCRIPT="$(mktemp)"
    cat > "$MOCK_TASK_QUEUE_SCRIPT" << 'EOF'
#!/bin/bash
# Advanced mock task-queue.sh for integration testing

# Log all calls for verification
echo "task-queue.sh: $*" >> "${TASK_QUEUE_LOG:-/dev/null}"

case "$1" in
    "add")
        case "$2" in
            "github_issue")
                if [[ "$3" =~ ^[0-9]+$ ]]; then
                    echo "Added GitHub issue #$3"
                    exit 0
                else
                    echo "Error: Invalid issue number" >&2
                    exit 1
                fi
                ;;
            "github_pr")
                if [[ "$3" =~ ^[0-9]+$ ]]; then
                    echo "Added GitHub PR #$3"
                    exit 0
                else
                    echo "Error: Invalid PR number" >&2
                    exit 1
                fi
                ;;
            "custom")
                if [[ -n "$4" ]]; then
                    echo "Added custom task: $4"
                    exit 0
                else
                    echo "Error: Missing task description" >&2
                    exit 1
                fi
                ;;
            *)
                echo "Error: Unknown task type: $2" >&2
                exit 1
                ;;
        esac
        ;;
    "list")
        if [[ "$*" == *"--status=pending --count-only"* ]]; then
            echo "${MOCK_PENDING_COUNT:-2}"
        elif [[ "$*" == *"--status=pending --format=id-only --limit=1"* ]]; then
            echo "${MOCK_NEXT_TASK_ID:-task-123}"
        else
            echo "task-123: GitHub Issue #456 [pending]"
            echo "task-124: Custom task example [pending]"
        fi
        ;;
    "status")
        echo "Queue Status: ${MOCK_QUEUE_STATUS:-active}"
        echo "Total Tasks: 3"
        echo "Pending: 2"
        echo "In Progress: 1"
        ;;
    "pause")
        if [[ "$MOCK_PAUSE_FAIL" == "true" ]]; then
            exit 1
        else
            echo "Queue paused: $2"
            exit 0
        fi
        ;;
    "resume")
        if [[ "$MOCK_RESUME_FAIL" == "true" ]]; then
            exit 1
        else
            echo "Queue resumed"
            exit 0
        fi
        ;;
    "clear")
        if [[ "$MOCK_CLEAR_FAIL" == "true" ]]; then
            exit 1
        else
            echo "Queue cleared: $2"
            exit 0
        fi
        ;;
    *)
        echo "Unknown command: $1" >&2
        exit 1
        ;;
esac
EOF
    chmod +x "$MOCK_TASK_QUEUE_SCRIPT"
    
    # Set up environment
    export TASK_QUEUE_SCRIPT="$MOCK_TASK_QUEUE_SCRIPT"
    export TASK_QUEUE_AVAILABLE=true
    
    # Create log file for tracking task queue calls
    TASK_QUEUE_LOG="$(mktemp)"
    export TASK_QUEUE_LOG
}

teardown() {
    [[ -f "$MOCK_TASK_QUEUE_SCRIPT" ]] && rm -f "$MOCK_TASK_QUEUE_SCRIPT"
    [[ -f "$TASK_QUEUE_LOG" ]] && rm -f "$TASK_QUEUE_LOG"
}

# Helper function to source hybrid-monitor.sh functions without execution
load_hybrid_monitor_functions() {
    # We need to extract functions without running the script
    # This is a bit tricky - we'll modify the script temporarily to skip main execution
    TEMP_HYBRID_SCRIPT="$(mktemp)"
    
    # Copy script but skip main execution part
    sed '/^# MAIN SCRIPT EXECUTION/,$d' "$SRC_DIR/hybrid-monitor.sh" > "$TEMP_HYBRID_SCRIPT"
    
    # Add minimal initialization
    cat >> "$TEMP_HYBRID_SCRIPT" << 'EOF'
# Minimal init for testing
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-config/default.conf}"

# Source required utilities
source "$SCRIPT_DIR/utils/logging.sh" 2>/dev/null || true
source "$SCRIPT_DIR/utils/network.sh" 2>/dev/null || true
EOF
    
    source "$TEMP_HYBRID_SCRIPT"
    rm -f "$TEMP_HYBRID_SCRIPT"
}

@test "handle_task_queue_operations: successful GitHub issue addition" {
    load_hybrid_monitor_functions
    
    # Set up parameters
    ADD_ISSUE="123"
    ADD_PR=""
    ADD_CUSTOM=""
    LIST_QUEUE=false
    PAUSE_QUEUE=false
    RESUME_QUEUE=false
    CLEAR_QUEUE=false
    
    run handle_task_queue_operations
    assert_success
    
    # Verify task queue was called correctly
    run grep "task-queue.sh: add github_issue 123" "$TASK_QUEUE_LOG"
    assert_success
}

@test "handle_task_queue_operations: successful GitHub PR addition" {
    load_hybrid_monitor_functions
    
    # Set up parameters
    ADD_ISSUE=""
    ADD_PR="456"
    ADD_CUSTOM=""
    LIST_QUEUE=false
    PAUSE_QUEUE=false
    RESUME_QUEUE=false
    CLEAR_QUEUE=false
    
    run handle_task_queue_operations
    assert_success
    
    # Verify task queue was called correctly
    run grep "task-queue.sh: add github_pr 456" "$TASK_QUEUE_LOG"
    assert_success
}

@test "handle_task_queue_operations: successful custom task addition" {
    load_hybrid_monitor_functions
    
    # Set up parameters
    ADD_ISSUE=""
    ADD_PR=""
    ADD_CUSTOM="Implement user authentication"
    LIST_QUEUE=false
    PAUSE_QUEUE=false
    RESUME_QUEUE=false
    CLEAR_QUEUE=false
    
    run handle_task_queue_operations
    assert_success
    
    # Verify task queue was called with custom task
    run grep "task-queue.sh: add custom.*Implement user authentication" "$TASK_QUEUE_LOG"
    assert_success
}

@test "handle_task_queue_operations: list queue operation" {
    load_hybrid_monitor_functions
    
    # Set up parameters
    ADD_ISSUE=""
    ADD_PR=""
    ADD_CUSTOM=""
    LIST_QUEUE=true
    PAUSE_QUEUE=false
    RESUME_QUEUE=false
    CLEAR_QUEUE=false
    
    run handle_task_queue_operations
    assert_success
    assert_output --partial "task-123: GitHub Issue #456"
    
    # Verify task queue list was called
    run grep "task-queue.sh: list" "$TASK_QUEUE_LOG"
    assert_success
}

@test "handle_task_queue_operations: pause queue operation" {
    load_hybrid_monitor_functions
    
    # Set up parameters
    ADD_ISSUE=""
    ADD_PR=""
    ADD_CUSTOM=""
    LIST_QUEUE=false
    PAUSE_QUEUE=true
    RESUME_QUEUE=false
    CLEAR_QUEUE=false
    
    run handle_task_queue_operations
    assert_success
    
    # Verify pause was called with manual reason
    run grep "task-queue.sh: pause Manual pause via CLI" "$TASK_QUEUE_LOG"
    assert_success
}

@test "handle_task_queue_operations: resume queue operation" {
    load_hybrid_monitor_functions
    
    # Set up parameters
    ADD_ISSUE=""
    ADD_PR=""
    ADD_CUSTOM=""
    LIST_QUEUE=false
    PAUSE_QUEUE=false
    RESUME_QUEUE=true
    CLEAR_QUEUE=false
    
    run handle_task_queue_operations
    assert_success
    
    # Verify resume was called
    run grep "task-queue.sh: resume" "$TASK_QUEUE_LOG"
    assert_success
}

@test "handle_task_queue_operations: clear queue operation" {
    load_hybrid_monitor_functions
    
    # Set up parameters
    ADD_ISSUE=""
    ADD_PR=""
    ADD_CUSTOM=""
    LIST_QUEUE=false
    PAUSE_QUEUE=false
    RESUME_QUEUE=false
    CLEAR_QUEUE=true
    
    run handle_task_queue_operations
    assert_success
    
    # Verify clear was called with manual reason
    run grep "task-queue.sh: clear Manual clear via CLI" "$TASK_QUEUE_LOG"
    assert_success
}

@test "handle_task_queue_operations: multiple operations" {
    load_hybrid_monitor_functions
    
    # Set up parameters for multiple operations
    ADD_ISSUE="999"
    ADD_PR="888"
    ADD_CUSTOM="Test task"
    LIST_QUEUE=false
    PAUSE_QUEUE=false
    RESUME_QUEUE=false
    CLEAR_QUEUE=false
    
    run handle_task_queue_operations
    assert_success
    
    # Verify all operations were called
    run grep "task-queue.sh: add github_issue 999" "$TASK_QUEUE_LOG"
    assert_success
    run grep "task-queue.sh: add github_pr 888" "$TASK_QUEUE_LOG"
    assert_success
    run grep "task-queue.sh: add custom.*Test task" "$TASK_QUEUE_LOG"
    assert_success
}

@test "handle_task_queue_operations: error when task queue unavailable" {
    load_hybrid_monitor_functions
    
    # Disable task queue
    export TASK_QUEUE_AVAILABLE=false
    
    ADD_ISSUE="123"
    ADD_PR=""
    ADD_CUSTOM=""
    LIST_QUEUE=false
    PAUSE_QUEUE=false
    RESUME_QUEUE=false
    CLEAR_QUEUE=false
    
    run handle_task_queue_operations
    assert_failure
    assert_output --partial "Task Queue module not available"
}

@test "handle_task_queue_operations: handles task queue script failures" {
    load_hybrid_monitor_functions
    
    # Set up to trigger failure in pause operation
    export MOCK_PAUSE_FAIL=true
    
    ADD_ISSUE=""
    ADD_PR=""
    ADD_CUSTOM=""
    LIST_QUEUE=false
    PAUSE_QUEUE=true
    RESUME_QUEUE=false
    CLEAR_QUEUE=false
    
    run handle_task_queue_operations
    # Should still return success (error is logged but doesn't fail operation)
    assert_success
}

@test "process_task_queue: detects pending tasks" {
    load_hybrid_monitor_functions
    
    # Set up mock to return pending tasks
    export MOCK_PENDING_COUNT=3
    export MOCK_NEXT_TASK_ID="task-456"
    
    run process_task_queue
    assert_success
    
    # Should detect and log pending task
    run grep "Found pending task for processing: task-456" "$LOG_FILE"
    assert_success
}

@test "process_task_queue: handles no pending tasks" {
    load_hybrid_monitor_functions
    
    # Set up mock to return no pending tasks
    export MOCK_PENDING_COUNT=0
    
    run process_task_queue
    assert_success
    
    # Should log that no tasks are pending
    run grep "No pending tasks in queue" "$LOG_FILE"
    assert_success
}

@test "process_task_queue: skips when task queue unavailable" {
    load_hybrid_monitor_functions
    
    # Disable task queue
    export TASK_QUEUE_AVAILABLE=false
    
    run process_task_queue
    assert_success
    
    # Should log that task queue is not available
    run grep "Task queue not available - skipping processing" "$LOG_FILE"
    assert_success
}

@test "process_task_queue: skips when queue is paused" {
    load_hybrid_monitor_functions
    
    # Set up mock to return paused status
    export MOCK_QUEUE_STATUS=paused
    
    run process_task_queue
    assert_success
    
    # Should log that queue is paused
    run grep "Task queue is paused - skipping processing" "$LOG_FILE"
    assert_success
}

@test "process_task_queue: Phase 2 placeholder functionality" {
    load_hybrid_monitor_functions
    
    # Set up mock to return a task
    export MOCK_PENDING_COUNT=1
    export MOCK_NEXT_TASK_ID="task-phase2-test"
    
    run process_task_queue
    assert_success
    
    # Should log Phase 2 placeholder message
    run grep "Task processing will be implemented in Phase 2: task-phase2-test" "$LOG_FILE"
    assert_success
}

@test "process_task_queue: handles missing task ID gracefully" {
    load_hybrid_monitor_functions
    
    # Set up mock to return pending count but no task ID
    export MOCK_PENDING_COUNT=1
    export MOCK_NEXT_TASK_ID=""
    
    run process_task_queue
    assert_success
    
    # Should log that no executable tasks are available
    run grep "No executable tasks available" "$LOG_FILE"
    assert_success
}

@test "process_task_queue: calls correct task queue commands" {
    load_hybrid_monitor_functions
    
    export MOCK_PENDING_COUNT=2
    export MOCK_NEXT_TASK_ID="task-verify-calls"
    
    run process_task_queue
    assert_success
    
    # Verify correct sequence of calls
    run grep "task-queue.sh: list --status=pending --count-only" "$TASK_QUEUE_LOG"
    assert_success
    run grep "task-queue.sh: status" "$TASK_QUEUE_LOG"
    assert_success
    run grep "task-queue.sh: list --status=pending --format=id-only --limit=1" "$TASK_QUEUE_LOG"
    assert_success
}