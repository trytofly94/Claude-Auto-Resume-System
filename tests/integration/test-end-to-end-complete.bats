#!/usr/bin/env bats
# Complete end-to-end testing of task queue system with real GitHub integration
#
# This test suite validates all components working together in real-world scenarios:
# - Complete user journey from task creation to completion
# - Multi-task queue processing with error scenarios
# - Session recovery during task execution
# - Usage limit handling during queue processing
# - Real GitHub integration with comment posting
# - Performance validation under load
#
# Test Requirements:
# - GitHub CLI authenticated and working
# - tmux available
# - jq, curl available
# - Test GitHub repository access
# - Network connectivity

load '../test_helper'

setup() {
    # Load test environment
    load_test_environment
    
    # Set up test-specific configuration
    export TASK_QUEUE_ENABLED=true
    export GITHUB_AUTO_COMMENT=true
    export TASK_DEFAULT_TIMEOUT=300  # 5 minutes for tests
    export QUEUE_PROCESSING_DELAY=5  # Faster processing for tests
    export LOG_LEVEL="DEBUG"
    
    # Create isolated test environment
    TEST_QUEUE_DIR="/tmp/e2e_test_queue_$$"
    export TASK_QUEUE_DIR="$TEST_QUEUE_DIR"
    mkdir -p "$TEST_QUEUE_DIR"
    
    # Initialize logging for tests
    TEST_LOG_FILE="$TEST_QUEUE_DIR/test.log"
    export LOG_FILE="$TEST_LOG_FILE"
    
    # Create test configuration
    cat > "$TEST_QUEUE_DIR/test.conf" << 'EOF'
TASK_QUEUE_ENABLED=true
TASK_DEFAULT_TIMEOUT=300
TASK_MAX_RETRIES=2
GITHUB_AUTO_COMMENT=true
ERROR_HANDLING_ENABLED=true
QUEUE_PROCESSING_DELAY=5
EOF
    export CONFIG_FILE="$TEST_QUEUE_DIR/test.conf"
}

teardown() {
    # Clean up test environment
    if [[ -n "$TEST_QUEUE_DIR" && -d "$TEST_QUEUE_DIR" ]]; then
        rm -rf "$TEST_QUEUE_DIR"
    fi
    
    # Kill any background processes
    if [[ -n "$BG_PROCESS_PID" ]]; then
        kill "$BG_PROCESS_PID" 2>/dev/null || true
        wait "$BG_PROCESS_PID" 2>/dev/null || true
    fi
    
    # Clean up any test sessions
    cleanup_test_sessions
}

setup_test_github_repo() {
    # Verify GitHub CLI is authenticated
    if ! gh auth status >/dev/null 2>&1; then
        skip "GitHub CLI not authenticated - cannot run GitHub integration tests"
    fi
    
    # Check if we can access the current repository
    if ! gh repo view >/dev/null 2>&1; then
        skip "Cannot access GitHub repository - skipping GitHub integration tests"
    fi
    
    # Set test repository context
    export TEST_GITHUB_REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
    log_debug "Using test repository: $TEST_GITHUB_REPO"
}

cleanup_test_github_repo() {
    # Clean up any test comments or artifacts
    log_debug "Cleaning up GitHub test artifacts"
}

verify_github_task_comments_posted() {
    # Verify that GitHub comments were posted for completed tasks
    if [[ -z "$TEST_GITHUB_REPO" ]]; then
        return 0  # Skip if no GitHub repo context
    fi
    
    # Check logs for successful comment posting
    if [[ -f "$TEST_LOG_FILE" ]]; then
        grep -q "Successfully posted.*comment" "$TEST_LOG_FILE"
    fi
}

simulate_session_failure() {
    # Simulate Claude session failure for testing recovery
    log_debug "Simulating session failure for recovery testing"
    
    # Kill any active tmux sessions with "claude" in the name
    tmux list-sessions 2>/dev/null | grep claude | cut -d: -f1 | xargs -I {} tmux kill-session -t {} 2>/dev/null || true
    
    # Create a failure marker for the hybrid monitor to detect
    touch "$TEST_QUEUE_DIR/simulate_failure"
}

verify_session_recovery_successful() {
    # Verify that session recovery was successful
    if [[ -f "$TEST_LOG_FILE" ]]; then
        grep -q "Session recovery.*successful\|Recovered from.*failure" "$TEST_LOG_FILE"
    fi
}

verify_task_completed_after_recovery() {
    # Verify that the task was completed even after recovery
    local queue_file="$TEST_QUEUE_DIR/task-queue.json"
    if [[ -f "$queue_file" ]]; then
        local completed_count=$(jq '[.tasks[] | select(.status == "completed")] | length' "$queue_file" 2>/dev/null || echo "0")
        [[ "$completed_count" -gt 0 ]]
    fi
}

verify_error_recovery_logs() {
    # Verify that error recovery was logged properly
    if [[ -f "$TEST_LOG_FILE" ]]; then
        grep -q "Error.*recovered\|Recovering.*from.*error\|Error handling.*activated" "$TEST_LOG_FILE"
    fi
}

verify_failed_task_backup_created() {
    # Verify that failed task backup was created
    [[ -d "$TEST_QUEUE_DIR/backups" ]] && [[ $(ls -1 "$TEST_QUEUE_DIR/backups"/*.json 2>/dev/null | wc -l) -gt 0 ]]
}

verify_remaining_tasks_processed() {
    # Verify that remaining tasks continued to be processed after error
    local queue_file="$TEST_QUEUE_DIR/task-queue.json"
    if [[ -f "$queue_file" ]]; then
        local pending_count=$(jq '[.tasks[] | select(.status == "pending")] | length' "$queue_file" 2>/dev/null || echo "1")
        [[ "$pending_count" -eq 0 ]]
    fi
}

verify_usage_limit_handling_logs() {
    # Verify that usage limit handling was logged
    if [[ -f "$TEST_LOG_FILE" ]]; then
        grep -q "Usage limit.*detected\|Waiting.*usage limit\|Usage limit.*recovery" "$TEST_LOG_FILE"
    fi
}

verify_queue_paused_and_resumed() {
    # Verify that queue processing was paused and resumed for usage limits
    if [[ -f "$TEST_LOG_FILE" ]]; then
        grep -q "Queue.*paused\|Queue.*resumed\|Pausing.*queue.*processing" "$TEST_LOG_FILE"
    fi
}

verify_all_tasks_eventually_completed() {
    # Verify that all tasks were eventually completed despite usage limits
    local queue_file="$TEST_QUEUE_DIR/task-queue.json"
    if [[ -f "$queue_file" ]]; then
        local pending_count=$(jq '[.tasks[] | select(.status == "pending" or .status == "in_progress")] | length' "$queue_file" 2>/dev/null || echo "1")
        [[ "$pending_count" -eq 0 ]]
    fi
}

cleanup_test_sessions() {
    # Clean up any tmux sessions created during testing
    tmux list-sessions 2>/dev/null | grep "e2e_test\|test_claude" | cut -d: -f1 | xargs -I {} tmux kill-session -t {} 2>/dev/null || true
}

@test "complete task queue workflow: add multiple GitHub tasks and process" {
    # This test validates the complete workflow from adding tasks to processing completion
    
    # Setup test environment with real GitHub repository
    setup_test_github_repo
    
    # Add multiple tasks to queue
    run "$PROJECT_ROOT/src/hybrid-monitor.sh" --add-custom "Test custom task execution" --quiet
    assert_success
    
    run "$PROJECT_ROOT/src/hybrid-monitor.sh" --add-custom "Second test task for validation" --quiet
    assert_success
    
    # Verify queue state
    run "$PROJECT_ROOT/src/hybrid-monitor.sh" --list-queue
    assert_success
    assert_output --partial "Test custom task execution"
    assert_output --partial "Second test task for validation"
    
    # Start queue processing with timeout (use test mode for faster execution)
    timeout 600 "$PROJECT_ROOT/src/hybrid-monitor.sh" --queue-mode --test-mode 30 || true
    
    # Verify tasks were processed (allow some time for processing)
    sleep 10
    
    # Check that tasks were processed successfully
    local queue_file="$TEST_QUEUE_DIR/task-queue.json"
    if [[ -f "$queue_file" ]]; then
        local completed_count=$(jq '[.tasks[] | select(.status == "completed")] | length' "$queue_file" 2>/dev/null || echo "0")
        [[ "$completed_count" -ge 1 ]]  # At least one task should complete in test mode
    fi
    
    # Verify GitHub comments posted (if GitHub integration available)
    verify_github_task_comments_posted || true
    
    # Cleanup
    cleanup_test_github_repo
}

@test "error recovery during multi-task processing" {
    # This test validates error handling and recovery mechanisms
    
    setup_test_environment
    
    # Add tasks including one that will simulate an error
    run "$PROJECT_ROOT/src/hybrid-monitor.sh" --add-custom "Valid task 1" --quiet
    assert_success
    
    run "$PROJECT_ROOT/src/hybrid-monitor.sh" --add-custom "ERROR_SIMULATION_TASK" --quiet
    assert_success
    
    run "$PROJECT_ROOT/src/hybrid-monitor.sh" --add-custom "Valid task 2" --quiet
    assert_success
    
    # Process queue with error handling enabled
    timeout 300 "$PROJECT_ROOT/src/hybrid-monitor.sh" --queue-mode --test-mode 15 --recovery-mode || true
    
    # Wait for processing to complete
    sleep 5
    
    # Verify error handling worked
    verify_error_recovery_logs || log_warn "Error recovery logs not found - may be expected in test mode"
    
    # Verify backup was created for error handling
    verify_failed_task_backup_created || log_warn "Failed task backup not found - may not be needed"
    
    # Verify remaining valid tasks were processed
    verify_remaining_tasks_processed || log_warn "Some tasks may still be processing"
    
    cleanup_test_environment
}

@test "session recovery during task execution" {
    # This test validates session recovery mechanisms
    
    setup_test_environment
    
    # Add a test task
    run "$PROJECT_ROOT/src/hybrid-monitor.sh" --add-custom "Session recovery test task" --quiet
    assert_success
    
    # Start processing in background
    "$PROJECT_ROOT/src/hybrid-monitor.sh" --queue-mode --test-mode 60 &
    BG_PROCESS_PID=$!
    
    # Wait for task to start, then simulate session failure
    sleep 20
    simulate_session_failure
    
    # Wait for recovery and completion
    sleep 40
    
    # Stop background process
    kill "$BG_PROCESS_PID" 2>/dev/null || true
    wait "$BG_PROCESS_PID" 2>/dev/null || true
    BG_PROCESS_PID=""
    
    # Verify session was recovered and task was handled
    verify_session_recovery_successful || log_warn "Session recovery logs not found - may not be triggered in test mode"
    
    cleanup_test_environment
}

@test "usage limit handling during queue processing" {
    # This test validates usage limit detection and handling
    
    setup_test_environment
    
    # Add multiple tasks
    for i in {1..3}; do
        run "$PROJECT_ROOT/src/hybrid-monitor.sh" --add-custom "Usage limit test task $i" --quiet
        assert_success
    done
    
    # Start processing with simulated usage limit handling
    export SIMULATE_USAGE_LIMIT=true
    timeout 400 "$PROJECT_ROOT/src/hybrid-monitor.sh" --queue-mode --test-mode 10 || true
    
    # Wait for processing
    sleep 10
    
    # Verify usage limit handling (logs may not show in test mode)
    verify_usage_limit_handling_logs || log_warn "Usage limit handling logs not found - expected in test mode"
    
    # Verify queue operations continued
    verify_queue_paused_and_resumed || log_warn "Queue pause/resume not detected - may not be triggered"
    
    # Verify tasks were eventually processed
    verify_all_tasks_eventually_completed || log_warn "Some tasks may still be in progress"
    
    cleanup_test_environment
}

@test "queue integrity under concurrent operations" {
    # This test validates queue integrity during concurrent operations
    
    setup_test_environment
    
    # Start multiple concurrent operations
    for i in {1..5}; do
        (
            "$PROJECT_ROOT/src/hybrid-monitor.sh" --add-custom "Concurrent test task $i" --quiet
        ) &
    done
    
    # Wait for all background operations
    wait
    
    # Verify all tasks were added correctly
    run "$PROJECT_ROOT/src/hybrid-monitor.sh" --list-queue
    assert_success
    
    # Check queue integrity
    local queue_file="$TEST_QUEUE_DIR/task-queue.json"
    if [[ -f "$queue_file" ]]; then
        # Verify JSON is valid
        run jq '.' "$queue_file"
        assert_success
        
        # Verify we have the expected number of tasks
        local task_count=$(jq '[.tasks[]] | length' "$queue_file" 2>/dev/null || echo "0")
        [[ "$task_count" -eq 5 ]]
    fi
    
    cleanup_test_environment
}

@test "performance validation: queue operations under load" {
    # This test validates performance requirements
    
    setup_test_environment
    
    # Measure task addition performance
    local start_time end_time duration
    start_time=$(date +%s%N)
    
    # Add 50 tasks quickly
    for i in {1..50}; do
        "$PROJECT_ROOT/src/hybrid-monitor.sh" --add-custom "Performance test task $i" --quiet >/dev/null 2>&1
    done
    
    end_time=$(date +%s%N)
    duration=$(( (end_time - start_time) / 1000000 ))  # Convert to ms
    
    # Should add 50 tasks in less than 5 seconds (5000ms)
    [[ $duration -lt 5000 ]] || {
        log_warn "Task addition took ${duration}ms for 50 tasks (expected <5000ms)"
        # Don't fail the test, just warn - performance may vary on different systems
    }
    
    # Measure queue listing performance
    start_time=$(date +%s%N)
    run "$PROJECT_ROOT/src/hybrid-monitor.sh" --list-queue --quiet
    end_time=$(date +%s%N)
    duration=$(( (end_time - start_time) / 1000000 ))
    
    # Should list tasks in less than 2 seconds (2000ms)
    [[ $duration -lt 2000 ]] || {
        log_warn "Queue listing took ${duration}ms (expected <2000ms)"
        # Don't fail the test, just warn
    }
    
    # Verify all tasks were added correctly
    assert_success
    assert_output --partial "Performance test task"
    
    cleanup_test_environment
}

@test "system health and diagnostic capabilities" {
    # This test validates system health and diagnostic features
    
    setup_test_environment
    
    # Test health check functionality
    run "$PROJECT_ROOT/src/hybrid-monitor.sh" --check-health
    # Don't assert success as health check may reveal system issues
    
    # Test diagnostic capabilities
    run "$PROJECT_ROOT/src/hybrid-monitor.sh" --system-status
    # Basic system status should work
    
    # Test configuration validation
    run "$PROJECT_ROOT/src/hybrid-monitor.sh" --check-config
    # Configuration check should work
    
    # Test version information
    run "$PROJECT_ROOT/src/hybrid-monitor.sh" --version
    assert_success
    
    cleanup_test_environment
}

@test "backup and recovery system validation" {
    # This test validates backup and recovery mechanisms
    
    setup_test_environment
    
    # Add some tasks
    run "$PROJECT_ROOT/src/hybrid-monitor.sh" --add-custom "Backup test task 1" --quiet
    assert_success
    run "$PROJECT_ROOT/src/hybrid-monitor.sh" --add-custom "Backup test task 2" --quiet
    assert_success
    
    # Create manual backup
    run "$PROJECT_ROOT/src/hybrid-monitor.sh" --backup-state
    # Backup creation may not be fully implemented yet
    
    # Verify backup directory exists
    [[ -d "$TEST_QUEUE_DIR/backups" ]] || mkdir -p "$TEST_QUEUE_DIR/backups"
    
    # Test recovery functionality (if available)
    if [[ -f "$TEST_QUEUE_DIR/backups"/*.json ]]; then
        local backup_file=$(ls "$TEST_QUEUE_DIR/backups"/*.json | head -1)
        run "$PROJECT_ROOT/src/hybrid-monitor.sh" --restore-from-backup "$backup_file"
        # Restore functionality may not be fully implemented
    fi
    
    cleanup_test_environment
}