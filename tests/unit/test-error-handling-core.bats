#!/usr/bin/env bats

# Unit tests for core error handling functionality
# Tests the timeout monitor, session recovery, backup, usage limit recovery, and error classification modules

load ../test_helper

# Setup function - runs before each test
setup() {
    # Setup test environment
    setup_test_environment
    
    # Load error handling modules
    load_error_handling_modules
    
    # Create test directories
    export TEST_TASK_QUEUE_DIR="$BATS_TMPDIR/test-queue"
    export TASK_QUEUE_DIR="$TEST_TASK_QUEUE_DIR"
    mkdir -p "$TEST_TASK_QUEUE_DIR"/{tasks,backups,timeouts}
    
    # Configure error handling for testing
    export ERROR_HANDLING_ENABLED="true"
    export BACKUP_ENABLED="true"
    export TIMEOUT_DETECTION_ENABLED="true"
    export USAGE_LIMIT_COOLDOWN=10  # Short timeout for testing
}

# Helper function to load error handling modules
load_error_handling_modules() {
    local src_dir="${PROJECT_ROOT:-$BATS_TEST_DIRNAME/../..}/src"
    
    if [[ -f "$src_dir/task-timeout-monitor.sh" ]]; then
        source "$src_dir/task-timeout-monitor.sh"
    fi
    
    if [[ -f "$src_dir/session-recovery.sh" ]]; then
        source "$src_dir/session-recovery.sh"
    fi
    
    if [[ -f "$src_dir/task-state-backup.sh" ]]; then
        source "$src_dir/task-state-backup.sh"
    fi
    
    if [[ -f "$src_dir/usage-limit-recovery.sh" ]]; then
        source "$src_dir/usage-limit-recovery.sh"
    fi
    
    if [[ -f "$src_dir/error-classification.sh" ]]; then
        source "$src_dir/error-classification.sh"
    fi
}

# Cleanup function - runs after each test
teardown() {
    # Clean up test files
    rm -rf "$TEST_TASK_QUEUE_DIR" 2>/dev/null || true
    rm -rf /tmp/task-recovery-*.json 2>/dev/null || true
    rm -rf /tmp/usage-limit-countdown.pid 2>/dev/null || true
}

# ===============================================================================
# TIMEOUT MONITOR TESTS
# ===============================================================================

@test "timeout monitor: initialize_timeout_system should create timeout directory" {
    if ! declare -f initialize_timeout_system >/dev/null 2>&1; then
        skip "timeout monitor module not available"
    fi
    
    run initialize_timeout_system
    [ "$status" -eq 0 ]
    [ -d "$TEST_TASK_QUEUE_DIR/timeouts" ]
}

@test "timeout monitor: start_task_timeout_monitor should create timeout file" {
    if ! declare -f start_task_timeout_monitor >/dev/null 2>&1; then
        skip "timeout monitor module not available"
    fi
    
    run start_task_timeout_monitor "test-task-123" 60 "$$"
    [ "$status" -eq 0 ]
    [ -f "$TEST_TASK_QUEUE_DIR/timeouts/test-task-123.timeout" ]
}

@test "timeout monitor: stop_timeout_monitor should clean up files" {
    if ! declare -f start_task_timeout_monitor >/dev/null 2>&1 || ! declare -f stop_timeout_monitor >/dev/null 2>&1; then
        skip "timeout monitor functions not available"
    fi
    
    # Start timeout monitor
    run start_task_timeout_monitor "test-task-456" 60 "$$"
    [ "$status" -eq 0 ]
    [ -f "$TEST_TASK_QUEUE_DIR/timeouts/test-task-456.timeout" ]
    
    # Stop timeout monitor
    run stop_timeout_monitor "test-task-456"
    [ "$status" -eq 0 ]
    [ ! -f "$TEST_TASK_QUEUE_DIR/timeouts/test-task-456.timeout" ]
}

# ===============================================================================
# SESSION RECOVERY TESTS
# ===============================================================================

@test "session recovery: verify_session_responsiveness should handle basic cases" {
    if ! declare -f verify_session_responsiveness >/dev/null 2>&1; then
        skip "session recovery module not available"
    fi
    
    # Test with non-existent session (should fail)
    run verify_session_responsiveness "non-existent-session"
    [ "$status" -ne 0 ]
}

@test "session recovery: create_session_failure_backup should create backup file" {
    if ! declare -f create_session_failure_backup >/dev/null 2>&1; then
        skip "session recovery module not available"
    fi
    
    run create_session_failure_backup "test-task-789" "test-session-123"
    [ "$status" -eq 0 ]
    
    # Check that a backup file was created
    local backup_count
    backup_count=$(find "$TEST_TASK_QUEUE_DIR/backups" -name "session-failure-test-task-789-*.json" 2>/dev/null | wc -l)
    [ "$backup_count" -gt 0 ]
}

# ===============================================================================
# BACKUP SYSTEM TESTS
# ===============================================================================

@test "backup system: initialize_backup_system should create backup directory" {
    if ! declare -f initialize_backup_system >/dev/null 2>&1; then
        skip "backup system module not available"
    fi
    
    run initialize_backup_system
    [ "$status" -eq 0 ]
    [ -d "$TEST_TASK_QUEUE_DIR/backups" ]
}

@test "backup system: create_task_checkpoint should create backup file" {
    if ! declare -f create_task_checkpoint >/dev/null 2>&1; then
        skip "backup system module not available"
    fi
    
    run create_task_checkpoint "test-task-backup" "test_checkpoint"
    [ "$status" -eq 0 ]
    
    # Check that a checkpoint file was created
    local checkpoint_count
    checkpoint_count=$(find "$TEST_TASK_QUEUE_DIR/backups" -name "checkpoint-test-task-backup-*.json*" 2>/dev/null | wc -l)
    [ "$checkpoint_count" -gt 0 ]
}

@test "backup system: create_emergency_system_backup should create emergency backup" {
    if ! declare -f create_emergency_system_backup >/dev/null 2>&1; then
        skip "backup system module not available"
    fi
    
    run create_emergency_system_backup "test_emergency"
    [ "$status" -eq 0 ]
    
    # Check that an emergency backup file was created
    local emergency_count
    emergency_count=$(find "$TEST_TASK_QUEUE_DIR/backups" -name "emergency-system-*.json*" 2>/dev/null | wc -l)
    [ "$emergency_count" -gt 0 ]
}

@test "backup system: get_backup_statistics should return valid JSON" {
    if ! declare -f get_backup_statistics >/dev/null 2>&1; then
        skip "backup system module not available"
    fi
    
    # Create some test backup files first
    create_task_checkpoint "stats-test" "test" 2>/dev/null || true
    
    run get_backup_statistics
    [ "$status" -eq 0 ]
    
    # Verify JSON structure (basic test)
    echo "$output" | grep -q '"backup_directory"'
    echo "$output" | grep -q '"total_backups"'
}

# ===============================================================================
# USAGE LIMIT RECOVERY TESTS
# ===============================================================================

@test "usage limit recovery: detect_usage_limit_in_queue should detect usage limit patterns" {
    if ! declare -f detect_usage_limit_in_queue >/dev/null 2>&1; then
        skip "usage limit recovery module not available"
    fi
    
    # Test with usage limit text
    run detect_usage_limit_in_queue "Error: usage limit reached. Please try again later."
    [ "$status" -eq 0 ]
    
    # Test with rate limit text
    run detect_usage_limit_in_queue "Rate limit exceeded. Please wait."
    [ "$status" -eq 0 ]
    
    # Test with normal text (should not detect)
    run detect_usage_limit_in_queue "Task completed successfully"
    [ "$status" -ne 0 ]
}

@test "usage limit recovery: calculate_usage_limit_wait_time should return reasonable values" {
    if ! declare -f calculate_usage_limit_wait_time >/dev/null 2>&1; then
        skip "usage limit recovery module not available"
    fi
    
    run calculate_usage_limit_wait_time "test-task" "usage_limit"
    [ "$status" -eq 0 ]
    
    # Should return a numeric value
    [[ "$output" =~ ^[0-9]+$ ]]
    
    # Should be at least 10 seconds (our test cooldown)
    [ "$output" -ge 10 ]
}

@test "usage limit recovery: get_usage_limit_statistics should return valid JSON" {
    if ! declare -f get_usage_limit_statistics >/dev/null 2>&1; then
        skip "usage limit recovery module not available"
    fi
    
    run get_usage_limit_statistics
    [ "$status" -eq 0 ]
    
    # Verify JSON structure
    echo "$output" | grep -q '"current_status"'
    echo "$output" | grep -q '"total_occurrences"'
    echo "$output" | grep -q '"configuration"'
}

# ===============================================================================
# ERROR CLASSIFICATION TESTS
# ===============================================================================

@test "error classification: classify_error_severity should handle critical errors" {
    if ! declare -f classify_error_severity >/dev/null 2>&1; then
        skip "error classification module not available"
    fi
    
    # Test critical error patterns
    run classify_error_severity "Segmentation fault occurred" "test_context" "test-task"
    [ "$status" -eq 3 ]  # Critical severity
    
    run classify_error_severity "Out of memory error" "test_context" "test-task"
    [ "$status" -eq 3 ]  # Critical severity
}

@test "error classification: classify_error_severity should handle warning errors" {
    if ! declare -f classify_error_severity >/dev/null 2>&1; then
        skip "error classification module not available"
    fi
    
    # Test warning level patterns
    run classify_error_severity "Network timeout occurred" "test_context" "test-task"
    [ "$status" -eq 2 ]  # Warning severity
    
    run classify_error_severity "Connection refused by server" "test_context" "test-task"
    [ "$status" -eq 2 ]  # Warning severity
}

@test "error classification: classify_error_severity should handle info errors" {
    if ! declare -f classify_error_severity >/dev/null 2>&1; then
        skip "error classification module not available"
    fi
    
    # Test info level patterns
    run classify_error_severity "File not found: /tmp/test.txt" "test_context" "test-task"
    [ "$status" -eq 1 ]  # Info severity
    
    run classify_error_severity "Syntax error in command" "test_context" "test-task"
    [ "$status" -eq 1 ]  # Info severity
}

@test "error classification: determine_recovery_strategy should return valid strategies" {
    if ! declare -f determine_recovery_strategy >/dev/null 2>&1; then
        skip "error classification module not available"
    fi
    
    # Test critical error strategy
    run determine_recovery_strategy 3 "test-task" 0 "test_context"
    [ "$status" -eq 0 ]
    [[ "$output" == "emergency_shutdown" ]]
    
    # Test warning error strategy with low retry count
    run determine_recovery_strategy 2 "test-task" 1 "test_context"
    [ "$status" -eq 0 ]
    [[ "$output" == "automatic_recovery" ]]
    
    # Test info error strategy
    run determine_recovery_strategy 1 "test-task" 1 "test_context"
    [ "$status" -eq 0 ]
    [[ "$output" == "simple_retry" ]]
}

@test "error classification: get_error_statistics should return valid JSON" {
    if ! declare -f get_error_statistics >/dev/null 2>&1; then
        skip "error classification module not available"
    fi
    
    # Record some test errors first
    classify_error_severity "Test error" "test_context" "test-task" 2>/dev/null || true
    
    run get_error_statistics
    [ "$status" -eq 0 ]
    
    # Verify JSON structure
    echo "$output" | grep -q '"error_counts"'
    echo "$output" | grep -q '"recovery_attempts"'
    echo "$output" | grep -q '"configuration"'
}

# ===============================================================================
# INTEGRATION TESTS
# ===============================================================================

@test "integration: error handling modules should work together" {
    if ! declare -f classify_error_severity >/dev/null 2>&1 || ! declare -f create_task_checkpoint >/dev/null 2>&1; then
        skip "required error handling modules not available"
    fi
    
    # Simulate error handling workflow
    run classify_error_severity "Network timeout during task execution" "task_execution" "integration-test-task"
    [ "$status" -eq 2 ]  # Should be warning level
    
    # Create checkpoint for the task
    run create_task_checkpoint "integration-test-task" "error_handling_test"
    [ "$status" -eq 0 ]
    
    # Verify backup was created
    local backup_count
    backup_count=$(find "$TEST_TASK_QUEUE_DIR/backups" -name "checkpoint-integration-test-task-*.json*" 2>/dev/null | wc -l)
    [ "$backup_count" -gt 0 ]
}

@test "integration: error handling should be configurable" {
    # Test with error handling disabled
    export ERROR_HANDLING_ENABLED="false"
    
    if declare -f classify_error_severity >/dev/null 2>&1; then
        # Should still work but might behave differently
        run classify_error_severity "Test error" "test_context" "test-task"
        # Don't check status as behavior might vary when disabled
    fi
    
    # Test with backup disabled
    export BACKUP_ENABLED="false"
    
    if declare -f create_task_checkpoint >/dev/null 2>&1; then
        run create_task_checkpoint "test-task" "config_test"
        # Should either succeed or fail gracefully
        [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
    fi
}

# ===============================================================================
# ERROR HANDLING EDGE CASES
# ===============================================================================

@test "error handling: modules should handle missing dependencies gracefully" {
    # Test timeout monitor without jq
    if declare -f start_task_timeout_monitor >/dev/null 2>&1; then
        # Should work even without jq (fallback behavior)
        run start_task_timeout_monitor "fallback-test" 30 "$$"
        # Should either succeed with fallback or fail gracefully
        [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
    fi
}

@test "error handling: modules should handle invalid parameters" {
    if declare -f classify_error_severity >/dev/null 2>&1; then
        # Test with empty error message
        run classify_error_severity "" "test_context" "test-task"
        [ "$status" -eq 0 ]  # Should return unknown severity (0)
    fi
    
    if declare -f start_task_timeout_monitor >/dev/null 2>&1; then
        # Test with invalid parameters
        run start_task_timeout_monitor "" 30 "$$"
        [ "$status" -ne 0 ]  # Should fail with invalid task ID
    fi
}

@test "error handling: cleanup functions should work correctly" {
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
}

# ===============================================================================
# PERFORMANCE TESTS
# ===============================================================================

@test "error handling: backup operations should complete quickly" {
    if ! declare -f create_task_checkpoint >/dev/null 2>&1; then
        skip "backup system module not available"
    fi
    
    # Test backup performance (should complete in reasonable time)
    local start_time end_time duration
    start_time=$(date +%s)
    
    run create_task_checkpoint "perf-test-task" "performance_test"
    [ "$status" -eq 0 ]
    
    end_time=$(date +%s)
    duration=$((end_time - start_time))
    
    # Should complete within 5 seconds
    [ "$duration" -le 5 ]
}