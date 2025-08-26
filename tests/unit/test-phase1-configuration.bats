#!/usr/bin/env bats

# Test Phase 1: Configuration Loading and Validation
# Tests configuration loading for new task queue parameters and validation

load '../test_helper'

setup() {
    # Create test environment
    export TEST_MODE=true
    export LOG_LEVEL=ERROR  # Reduce noise in tests
    
    # Create test config file with task queue parameters
    TEST_CONFIG_FILE="$(mktemp)"
    cat > "$TEST_CONFIG_FILE" << 'EOF'
# Test configuration for Phase 1 testing
CHECK_INTERVAL_MINUTES=3
MAX_RESTARTS=25
USE_CLAUNCH=true
CLAUNCH_MODE="tmux"

# Task Queue Configuration
TASK_QUEUE_ENABLED=true
TASK_QUEUE_DIR="test-queue"
TASK_DEFAULT_TIMEOUT=1800
TASK_MAX_RETRIES=2
TASK_RETRY_DELAY=120
TASK_COMPLETION_PATTERN="###TEST_COMPLETE###"
TASK_QUEUE_MAX_SIZE=100
TASK_AUTO_CLEANUP_DAYS=3
TASK_BACKUP_RETENTION_DAYS=14
QUEUE_LOCK_TIMEOUT=15

# Task Queue Processing Configuration (for hybrid-monitor.sh)
QUEUE_PROCESSING_DELAY=60
QUEUE_MAX_CONCURRENT=2
QUEUE_AUTO_PAUSE_ON_ERROR=false

# Standard monitoring config
LOG_LEVEL="DEBUG"
PREFERRED_TERMINAL="auto"
DEBUG_MODE=false
EOF

    export CONFIG_FILE="$TEST_CONFIG_FILE"
    
    # Create test task queue directory
    TEST_TASK_QUEUE_DIR="$(mktemp -d)"
    export TEST_TASK_QUEUE_DIR
    
    # Create mock task-queue.sh script
    MOCK_TASK_QUEUE_SCRIPT="$TEST_TASK_QUEUE_DIR/task-queue.sh"
    cat > "$MOCK_TASK_QUEUE_SCRIPT" << 'EOF'
#!/bin/bash
echo "Mock task-queue.sh: $*"
exit 0
EOF
    chmod +x "$MOCK_TASK_QUEUE_SCRIPT"
    export TASK_QUEUE_SCRIPT="$MOCK_TASK_QUEUE_SCRIPT"
}

teardown() {
    [[ -f "$TEST_CONFIG_FILE" ]] && rm -f "$TEST_CONFIG_FILE"
    [[ -d "$TEST_TASK_QUEUE_DIR" ]] && rm -rf "$TEST_TASK_QUEUE_DIR"
}

# Helper function to load configuration (extracted from hybrid-monitor.sh)
load_test_configuration() {
    # Source the configuration file
    if [[ -r "$CONFIG_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
        return 0
    else
        return 1
    fi
}

@test "configuration loading: loads task queue enabled flag" {
    run load_test_configuration
    assert_success
    
    # Verify task queue is enabled
    [[ "$TASK_QUEUE_ENABLED" == "true" ]]
}

@test "configuration loading: loads task queue directory" {
    load_test_configuration
    
    # Verify task queue directory is set correctly
    [[ "$TASK_QUEUE_DIR" == "test-queue" ]]
}

@test "configuration loading: loads task processing parameters" {
    load_test_configuration
    
    # Verify all task processing parameters
    [[ "$TASK_DEFAULT_TIMEOUT" -eq 1800 ]]
    [[ "$TASK_MAX_RETRIES" -eq 2 ]]
    [[ "$TASK_RETRY_DELAY" -eq 120 ]]
    [[ "$TASK_COMPLETION_PATTERN" == "###TEST_COMPLETE###" ]]
    [[ "$TASK_QUEUE_MAX_SIZE" -eq 100 ]]
    [[ "$TASK_AUTO_CLEANUP_DAYS" -eq 3 ]]
    [[ "$TASK_BACKUP_RETENTION_DAYS" -eq 14 ]]
    [[ "$QUEUE_LOCK_TIMEOUT" -eq 15 ]]
}

@test "configuration loading: loads queue processing configuration" {
    load_test_configuration
    
    # Verify hybrid-monitor specific queue processing parameters
    [[ "$QUEUE_PROCESSING_DELAY" -eq 60 ]]
    [[ "$QUEUE_MAX_CONCURRENT" -eq 2 ]]
    [[ "$QUEUE_AUTO_PAUSE_ON_ERROR" == "false" ]]
}

@test "configuration loading: maintains backward compatibility" {
    load_test_configuration
    
    # Verify existing parameters are still loaded correctly
    [[ "$CHECK_INTERVAL_MINUTES" -eq 3 ]]
    [[ "$MAX_RESTARTS" -eq 25 ]]
    [[ "$USE_CLAUNCH" == "true" ]]
    [[ "$CLAUNCH_MODE" == "tmux" ]]
    [[ "$LOG_LEVEL" == "DEBUG" ]]
    [[ "$PREFERRED_TERMINAL" == "auto" ]]
    [[ "$DEBUG_MODE" == "false" ]]
}

@test "configuration loading: handles missing config file gracefully" {
    # Test with non-existent config file
    export CONFIG_FILE="/non/existent/file.conf"
    
    run load_test_configuration
    assert_failure
}

@test "configuration loading: default values for missing parameters" {
    # Create minimal config file without task queue parameters
    MINIMAL_CONFIG="$(mktemp)"
    cat > "$MINIMAL_CONFIG" << 'EOF'
CHECK_INTERVAL_MINUTES=5
USE_CLAUNCH=true
EOF
    export CONFIG_FILE="$MINIMAL_CONFIG"
    
    load_test_configuration
    
    # Verify defaults are used (bash variables remain unset/empty)
    [[ -z "${TASK_QUEUE_ENABLED:-}" ]]
    [[ -z "${TASK_DEFAULT_TIMEOUT:-}" ]]
    
    rm -f "$MINIMAL_CONFIG"
}

@test "configuration validation: task queue script availability check" {
    # Test with hybrid-monitor script directly to check TASK_QUEUE_AVAILABLE setting
    export TASK_QUEUE_SCRIPT="$MOCK_TASK_QUEUE_SCRIPT"
    
    # Run hybrid-monitor with --help to trigger initialization without full execution
    run timeout 10s "$SRC_DIR/hybrid-monitor.sh" --help
    assert_success
    
    # The script should complete successfully with task queue available
    assert_output --partial "TASK QUEUE OPTIONS"
}

@test "configuration validation: task queue script unavailability handling" {
    # Test with non-existent task queue script
    export TASK_QUEUE_SCRIPT="/non/existent/script.sh"
    
    # Run hybrid-monitor with task queue operation - should fail gracefully
    run timeout 10s "$SRC_DIR/hybrid-monitor.sh" --add-issue 123
    assert_failure
    assert_output --partial "Task Queue module not available"
}

@test "configuration validation: task queue enabled but script missing" {
    # Create config with task queue enabled but missing script
    INCOMPLETE_CONFIG="$(mktemp)"
    cat > "$INCOMPLETE_CONFIG" << 'EOF'
TASK_QUEUE_ENABLED=true
TASK_QUEUE_DIR="missing-dir"
EOF
    export CONFIG_FILE="$INCOMPLETE_CONFIG"
    
    # Remove the task queue script
    rm -f "$MOCK_TASK_QUEUE_SCRIPT"
    export TASK_QUEUE_SCRIPT="/non/existent/script.sh"
    
    # Should handle gracefully
    run timeout 10s "$SRC_DIR/hybrid-monitor.sh" --add-custom "test"
    assert_failure
    assert_output --partial "Task Queue module not available"
    
    rm -f "$INCOMPLETE_CONFIG"
}

@test "configuration validation: numeric parameter validation" {
    # Create config with invalid numeric values
    INVALID_CONFIG="$(mktemp)"
    cat > "$INVALID_CONFIG" << 'EOF'
CHECK_INTERVAL_MINUTES=abc
TASK_DEFAULT_TIMEOUT=xyz
QUEUE_MAX_CONCURRENT=not-a-number
EOF
    export CONFIG_FILE="$INVALID_CONFIG"
    
    load_test_configuration
    
    # Variables should contain the invalid values (bash doesn't validate on assignment)
    [[ "$CHECK_INTERVAL_MINUTES" == "abc" ]]
    [[ "$TASK_DEFAULT_TIMEOUT" == "xyz" ]]
    [[ "$QUEUE_MAX_CONCURRENT" == "not-a-number" ]]
    
    rm -f "$INVALID_CONFIG"
}

@test "configuration validation: boolean parameter handling" {
    # Create config with various boolean formats
    BOOL_CONFIG="$(mktemp)"
    cat > "$BOOL_CONFIG" << 'EOF'
TASK_QUEUE_ENABLED=true
USE_CLAUNCH=TRUE
DEBUG_MODE=1
QUEUE_AUTO_PAUSE_ON_ERROR=false
NEW_TERMINAL_DEFAULT=FALSE
AUTO_RECOVERY_ENABLED=0
EOF
    export CONFIG_FILE="$BOOL_CONFIG"
    
    load_test_configuration
    
    # All should be loaded as strings (bash doesn't have native booleans)
    [[ "$TASK_QUEUE_ENABLED" == "true" ]]
    [[ "$USE_CLAUNCH" == "TRUE" ]]
    [[ "$DEBUG_MODE" == "1" ]]
    [[ "$QUEUE_AUTO_PAUSE_ON_ERROR" == "false" ]]
    [[ "$NEW_TERMINAL_DEFAULT" == "FALSE" ]]
    [[ "$AUTO_RECOVERY_ENABLED" == "0" ]]
    
    rm -f "$BOOL_CONFIG"
}

@test "configuration validation: environment variable override" {
    # Set environment variables that should override config values
    export CHECK_INTERVAL_MINUTES=999
    export TASK_DEFAULT_TIMEOUT=7777
    export QUEUE_PROCESSING_DELAY=123
    
    load_test_configuration
    
    # Environment variables should override config file values
    [[ "$CHECK_INTERVAL_MINUTES" -eq 999 ]]
    [[ "$TASK_DEFAULT_TIMEOUT" -eq 7777 ]]
    [[ "$QUEUE_PROCESSING_DELAY" -eq 123 ]]
}

@test "configuration integration: task queue processing enabled conditions" {
    load_test_configuration
    
    # Test condition 1: TASK_QUEUE_ENABLED=true in config
    if [[ "${TASK_QUEUE_ENABLED:-false}" == "true" ]]; then
        CONDITION_1_MET=true
    else
        CONDITION_1_MET=false
    fi
    
    [[ "$CONDITION_1_MET" == "true" ]]
    
    # Test condition 2: QUEUE_MODE=true (CLI parameter)
    QUEUE_MODE=true
    if [[ "${TASK_QUEUE_ENABLED:-false}" == "true" || "${QUEUE_MODE:-false}" == "true" ]]; then
        CONDITION_2_MET=true
    else
        CONDITION_2_MET=false
    fi
    
    [[ "$CONDITION_2_MET" == "true" ]]
}

@test "configuration integration: task queue disabled by config" {
    # Create config with task queue disabled
    DISABLED_CONFIG="$(mktemp)"
    cat > "$DISABLED_CONFIG" << 'EOF'
TASK_QUEUE_ENABLED=false
CHECK_INTERVAL_MINUTES=5
EOF
    export CONFIG_FILE="$DISABLED_CONFIG"
    
    load_test_configuration
    
    # Task queue should be disabled
    [[ "$TASK_QUEUE_ENABLED" == "false" ]]
    
    # But CLI parameter should still enable it
    QUEUE_MODE=true
    if [[ "${TASK_QUEUE_ENABLED:-false}" == "true" || "${QUEUE_MODE:-false}" == "true" ]]; then
        OVERRIDE_WORKS=true
    else
        OVERRIDE_WORKS=false
    fi
    
    [[ "$OVERRIDE_WORKS" == "true" ]]
    
    rm -f "$DISABLED_CONFIG"
}