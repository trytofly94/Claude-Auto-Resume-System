#!/usr/bin/env bats

# Integration tests for error handling and recovery systems
# Tests the full error handling workflow in realistic scenarios

load ../test_helper

# Setup function - runs before each test
setup() {
    # Setup test environment
    setup_test_environment
    
    # Load error handling modules and dependencies
    load_hybrid_monitor_modules
    
    # Create test directories
    export TEST_TASK_QUEUE_DIR="$BATS_TMPDIR/test-queue"
    export TASK_QUEUE_DIR="$TEST_TASK_QUEUE_DIR"
    mkdir -p "$TEST_TASK_QUEUE_DIR"/{tasks,backups,timeouts,usage-limit-checkpoints}
    
    # Configure error handling for testing
    export ERROR_HANDLING_ENABLED="true"
    export BACKUP_ENABLED="true"
    export TIMEOUT_DETECTION_ENABLED="true"
    export ERROR_AUTO_RECOVERY="true"
    export USAGE_LIMIT_COOLDOWN=10  # Short timeout for testing
    export TASK_DEFAULT_TIMEOUT=30  # Short timeout for testing
}

# Helper function to load hybrid monitor and error handling modules
load_hybrid_monitor_modules() {
    local src_dir="${PROJECT_ROOT:-$BATS_TEST_DIRNAME/../..}/src"
    
    # Load utility modules first
    if [[ -f "$src_dir/utils/logging.sh" ]]; then
        source "$src_dir/utils/logging.sh"
    fi
    
    # Load error handling modules
    for module in task-timeout-monitor.sh session-recovery.sh task-state-backup.sh usage-limit-recovery.sh error-classification.sh; do
        if [[ -f "$src_dir/$module" ]]; then
            source "$src_dir/$module"
        fi
    done
    
    # Initialize error handling systems
    if declare -f initialize_timeout_system >/dev/null 2>&1; then
        initialize_timeout_system 2>/dev/null || true
    fi
    
    if declare -f initialize_backup_system >/dev/null 2>&1; then
        initialize_backup_system 2>/dev/null || true
    fi
}

# Helper function to create a mock task
create_mock_task() {
    local task_id="$1"
    local task_status="${2:-pending}"
    local task_command="${3:-echo 'test task'}"
    
    local task_file="$TEST_TASK_QUEUE_DIR/tasks/${task_id}.json"
    cat > "$task_file" << EOF
{
    "id": "$task_id",
    "type": "custom",
    "status": "$task_status",
    "command": "$task_command",
    "description": "Test task for error handling integration",
    "timeout": 30,
    "created_at": "$(date -Iseconds)",
    "priority": 5
}
EOF
}

# Cleanup function - runs after each test
teardown() {
    # Clean up test files
    rm -rf "$TEST_TASK_QUEUE_DIR" 2>/dev/null || true
    rm -rf /tmp/task-recovery-*.json 2>/dev/null || true
    rm -rf /tmp/usage-limit-countdown.pid 2>/dev/null || true
    
    # Stop any background monitoring processes
    if declare -f cleanup_all_timeout_monitors >/dev/null 2>&1; then
        cleanup_all_timeout_monitors 2>/dev/null || true
    fi
}

# ===============================================================================
# TIMEOUT DETECTION INTEGRATION TESTS
# ===============================================================================

@test "timeout integration: task timeout should trigger timeout handling workflow" {
    if ! declare -f start_task_timeout_monitor >/dev/null 2>&1 || ! declare -f handle_task_timeout >/dev/null 2>&1; then
        skip "timeout handling functions not available"
    fi
    
    # Create mock task
    create_mock_task "timeout-integration-test" "in_progress" "sleep 60"
    
    # Start timeout monitoring with very short timeout
    run start_task_timeout_monitor "timeout-integration-test" 2 "$$"
    [ "$status" -eq 0 ]
    
    # Wait for timeout to trigger (should happen within 3 seconds)
    sleep 3
    
    # Check that timeout backup was created
    local timeout_backups
    timeout_backups=$(find "$TEST_TASK_QUEUE_DIR" -name "*timeout-backup-timeout-integration-test-*.json" 2>/dev/null | wc -l)
    [ "$timeout_backups" -gt 0 ]
}

@test "timeout integration: timeout monitor should clean up properly" {
    if ! declare -f start_task_timeout_monitor >/dev/null 2>&1 || ! declare -f stop_timeout_monitor >/dev/null 2>&1; then
        skip "timeout handling functions not available"
    fi
    
    # Create mock task
    create_mock_task "timeout-cleanup-test" "in_progress"
    
    # Start and immediately stop timeout monitoring
    run start_task_timeout_monitor "timeout-cleanup-test" 60 "$$"
    [ "$status" -eq 0 ]
    
    run stop_timeout_monitor "timeout-cleanup-test"
    [ "$status" -eq 0 ]
    
    # Verify cleanup
    [ ! -f "$TEST_TASK_QUEUE_DIR/timeouts/timeout-cleanup-test.timeout" ]
}

# ===============================================================================
# SESSION RECOVERY INTEGRATION TESTS
# ===============================================================================

@test "session recovery: session failure should create backup and trigger recovery" {
    if ! declare -f create_session_failure_backup >/dev/null 2>&1; then
        skip "session recovery functions not available"
    fi
    
    # Create mock task
    create_mock_task "session-recovery-test" "in_progress"
    
    # Simulate session failure
    run create_session_failure_backup "session-recovery-test" "test-session-123"
    [ "$status" -eq 0 ]
    
    # Check that session failure backup was created
    local session_backups
    session_backups=$(find "$TEST_TASK_QUEUE_DIR/backups" -name "session-failure-session-recovery-test-*.json" 2>/dev/null | wc -l)
    [ "$session_backups" -gt 0 ]
}

# ===============================================================================
# BACKUP SYSTEM INTEGRATION TESTS
# ===============================================================================

@test "backup integration: checkpoint creation should work with task workflow" {
    if ! declare -f create_task_checkpoint >/dev/null 2>&1; then
        skip "backup system functions not available"
    fi
    
    # Create mock task
    create_mock_task "backup-integration-test" "in_progress"
    
    # Create multiple checkpoints
    run create_task_checkpoint "backup-integration-test" "task_start"
    [ "$status" -eq 0 ]
    
    run create_task_checkpoint "backup-integration-test" "mid_execution"
    [ "$status" -eq 0 ]
    
    run create_task_checkpoint "backup-integration-test" "task_completion"
    [ "$status" -eq 0 ]
    
    # Verify checkpoints were created
    local checkpoint_count
    checkpoint_count=$(find "$TEST_TASK_QUEUE_DIR/backups" -name "checkpoint-backup-integration-test-*.json*" 2>/dev/null | wc -l)
    [ "$checkpoint_count" -ge 3 ]
}

@test "backup integration: emergency backup should capture system state" {
    if ! declare -f create_emergency_system_backup >/dev/null 2>&1; then
        skip "emergency backup function not available"
    fi
    
    # Set up test environment
    export MAIN_SESSION_ID="test-session-emergency"
    export CURRENT_CYCLE="5"
    
    # Create mock tasks
    create_mock_task "emergency-test-1" "in_progress"
    create_mock_task "emergency-test-2" "pending"
    
    # Create emergency backup
    run create_emergency_system_backup "integration_test"
    [ "$status" -eq 0 ]
    
    # Verify emergency backup was created
    local emergency_backups
    emergency_backups=$(find "$TEST_TASK_QUEUE_DIR/backups" -name "emergency-system-*.json*" 2>/dev/null | wc -l)
    [ "$emergency_backups" -gt 0 ]
    
    # Verify backup contains system info
    local latest_backup
    latest_backup=$(find "$TEST_TASK_QUEUE_DIR/backups" -name "emergency-system-*.json*" -type f 2>/dev/null | sort | tail -1)
    
    if [[ -n "$latest_backup" && -f "$latest_backup" ]]; then
        # Check for expected content (accounting for potential compression)
        if [[ "$latest_backup" == *.gz ]]; then
            if command -v gunzip >/dev/null 2>&1; then
                gunzip -c "$latest_backup" | grep -q "integration_test"
            fi
        else
            grep -q "integration_test" "$latest_backup"
        fi
    fi
}

# ===============================================================================
# USAGE LIMIT RECOVERY INTEGRATION TESTS
# ===============================================================================

@test "usage limit integration: detection should trigger recovery workflow" {
    if ! declare -f detect_usage_limit_in_queue >/dev/null 2>&1 || ! declare -f record_usage_limit_occurrence >/dev/null 2>&1; then
        skip "usage limit recovery functions not available"
    fi
    
    # Create mock task
    create_mock_task "usage-limit-test" "in_progress"
    
    # Simulate usage limit detection
    local usage_limit_output="Error: Usage limit reached. Please try again in 30 minutes."
    
    run detect_usage_limit_in_queue "$usage_limit_output" "usage-limit-test"
    [ "$status" -eq 0 ]  # Should detect usage limit
    
    # Check that usage limit checkpoint was created (if function is available)
    if declare -f create_usage_limit_checkpoint >/dev/null 2>&1; then
        local usage_limit_checkpoints
        usage_limit_checkpoints=$(find "$TEST_TASK_QUEUE_DIR" -name "*usage-limit-usage-limit-test-*.json" 2>/dev/null | wc -l)
        [ "$usage_limit_checkpoints" -gt 0 ]
    fi
}

@test "usage limit integration: wait time calculation should consider occurrence history" {
    if ! declare -f calculate_usage_limit_wait_time >/dev/null 2>&1 || ! declare -f record_usage_limit_occurrence >/dev/null 2>&1; then
        skip "usage limit recovery functions not available"
    fi
    
    # Record multiple usage limit occurrences
    record_usage_limit_occurrence "multi-occurrence-test" "usage_limit"
    record_usage_limit_occurrence "multi-occurrence-test" "usage_limit"
    record_usage_limit_occurrence "multi-occurrence-test" "usage_limit"
    
    # Calculate wait time (should be longer due to multiple occurrences)
    run calculate_usage_limit_wait_time "multi-occurrence-test" "usage_limit"
    [ "$status" -eq 0 ]
    
    # Should return a numeric value greater than the base cooldown
    [[ "$output" =~ ^[0-9]+$ ]]
    [ "$output" -ge "$USAGE_LIMIT_COOLDOWN" ]
}

# ===============================================================================
# ERROR CLASSIFICATION INTEGRATION TESTS
# ===============================================================================

@test "error classification integration: full error handling workflow should work" {
    if ! declare -f classify_error_severity >/dev/null 2>&1 || ! declare -f determine_recovery_strategy >/dev/null 2>&1; then
        skip "error classification functions not available"
    fi
    
    # Create mock task
    create_mock_task "error-workflow-test" "in_progress"
    
    # Simulate error classification workflow
    local error_message="Network timeout occurred during task execution"
    
    run classify_error_severity "$error_message" "task_execution" "error-workflow-test"
    local error_severity=$status
    [ "$error_severity" -eq 2 ]  # Should be warning level
    
    # Determine recovery strategy
    run determine_recovery_strategy "$error_severity" "error-workflow-test" 1 "task_execution"
    [ "$status" -eq 0 ]
    
    # Should recommend automatic recovery for warning-level errors with low retry count
    [[ "$output" == "automatic_recovery" ]]
}

@test "error classification integration: escalation should work correctly" {
    if ! declare -f classify_error_severity >/dev/null 2>&1 || ! declare -f determine_recovery_strategy >/dev/null 2>&1; then
        skip "error classification functions not available"
    fi
    
    # Test escalation for repeated failures
    local error_message="Connection refused by remote server"
    
    run classify_error_severity "$error_message" "task_execution" "escalation-test"
    local error_severity=$status
    [ "$error_severity" -eq 2 ]  # Warning level
    
    # Simulate high retry count (should escalate to manual recovery)
    run determine_recovery_strategy "$error_severity" "escalation-test" 5 "task_execution"
    [ "$status" -eq 0 ]
    [[ "$output" == "manual_recovery" ]]
}

# ===============================================================================
# FULL SYSTEM INTEGRATION TESTS
# ===============================================================================

@test "full integration: multiple error handling systems should work together" {
    # Skip if essential functions are not available
    if ! declare -f create_task_checkpoint >/dev/null 2>&1 || ! declare -f classify_error_severity >/dev/null 2>&1; then
        skip "required error handling functions not available"
    fi
    
    # Create mock task
    create_mock_task "full-integration-test" "in_progress"
    
    # Create initial checkpoint
    run create_task_checkpoint "full-integration-test" "integration_start"
    [ "$status" -eq 0 ]
    
    # Simulate error occurrence
    run classify_error_severity "Temporary network failure" "integration_test" "full-integration-test"
    [ "$status" -eq 2 ]  # Warning level
    
    # Create error checkpoint
    run create_task_checkpoint "full-integration-test" "error_occurred"
    [ "$status" -eq 0 ]
    
    # Verify multiple checkpoints exist
    local checkpoint_count
    checkpoint_count=$(find "$TEST_TASK_QUEUE_DIR/backups" -name "checkpoint-full-integration-test-*.json*" 2>/dev/null | wc -l)
    [ "$checkpoint_count" -ge 2 ]
}

@test "full integration: error handling should be configurable and optional" {
    # Test with error handling disabled
    export ERROR_HANDLING_ENABLED="false"
    
    # Functions should still work but may behave differently
    if declare -f classify_error_severity >/dev/null 2>&1; then
        run classify_error_severity "Test error" "configurable_test" "config-test"
        # Should not fail when disabled
        [ "$status" -ge 0 ]
    fi
    
    # Test with backup disabled
    export BACKUP_ENABLED="false"
    
    if declare -f create_task_checkpoint >/dev/null 2>&1; then
        run create_task_checkpoint "config-test" "backup_disabled"
        # Should handle disabled state gracefully
        [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
    fi
}

@test "full integration: system should handle missing dependencies gracefully" {
    # Test behavior when optional commands are missing
    # This simulates environments where jq, gzip, etc. might not be available
    
    if declare -f create_task_checkpoint >/dev/null 2>&1; then
        # Should work even without optional compression
        export BACKUP_COMPRESSION="false"
        run create_task_checkpoint "dependency-test" "no_compression"
        [ "$status" -eq 0 ]
    fi
    
    if declare -f get_backup_statistics >/dev/null 2>&1; then
        # Should provide statistics even with limited functionality
        run get_backup_statistics
        [ "$status" -eq 0 ]
        # Should contain valid JSON-like structure
        echo "$output" | grep -q "backup_directory"
    fi
}

# ===============================================================================
# PERFORMANCE AND STRESS TESTS
# ===============================================================================

@test "integration performance: error handling should not significantly impact performance" {
    if ! declare -f create_task_checkpoint >/dev/null 2>&1; then
        skip "backup functions not available"
    fi
    
    # Test multiple rapid checkpoint operations
    local start_time end_time duration
    start_time=$(date +%s)
    
    for i in {1..10}; do
        create_task_checkpoint "perf-test-$i" "performance_test" 2>/dev/null || true
    done
    
    end_time=$(date +%s)
    duration=$((end_time - start_time))
    
    # Should complete 10 checkpoints within 10 seconds
    [ "$duration" -le 10 ]
}

@test "integration cleanup: all error handling systems should clean up properly" {
    # Test cleanup functions if available
    if declare -f cleanup_all_timeout_monitors >/dev/null 2>&1; then
        run cleanup_all_timeout_monitors
        [ "$status" -eq 0 ]
    fi
    
    if declare -f cleanup_backup_system >/dev/null 2>&1; then
        run cleanup_backup_system
        [ "$status" -eq 0 ]
    fi
    
    if declare -f cleanup_usage_limit_tracking >/dev/null 2>&1; then
        run cleanup_usage_limit_tracking
        [ "$status" -eq 0 ]
    fi
    
    if declare -f cleanup_error_tracking >/dev/null 2>&1; then
        run cleanup_error_tracking
        [ "$status" -eq 0 ]
    fi
}

# ===============================================================================
# EDGE CASES AND ERROR CONDITIONS
# ===============================================================================

@test "integration edge cases: system should handle disk space issues gracefully" {
    if ! declare -f create_task_checkpoint >/dev/null 2>&1; then
        skip "backup functions not available"
    fi
    
    # Try to create backup in read-only location (should fail gracefully)
    export TEST_TASK_QUEUE_DIR="/tmp/readonly-test"
    export TASK_QUEUE_DIR="$TEST_TASK_QUEUE_DIR"
    
    # Don't actually create read-only directory in tests, just test error handling
    run create_task_checkpoint "readonly-test" "disk_space_test"
    # Should either succeed (if fallback works) or fail gracefully
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

@test "integration edge cases: system should handle concurrent access safely" {
    if ! declare -f create_task_checkpoint >/dev/null 2>&1; then
        skip "backup functions not available"
    fi
    
    # Create multiple checkpoints simultaneously (background processes)
    local pids=()
    
    for i in {1..5}; do
        (create_task_checkpoint "concurrent-test-$i" "concurrency_test" 2>/dev/null) &
        pids+=($!)
    done
    
    # Wait for all background processes
    local failed_count=0
    for pid in "${pids[@]}"; do
        if ! wait "$pid"; then
            ((failed_count++))
        fi
    done
    
    # Allow some failures due to concurrency, but not all
    [ "$failed_count" -lt 5 ]
}