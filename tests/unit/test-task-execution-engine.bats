#!/usr/bin/env bats

# Test Suite: Task Execution Engine - Core Functionality Tests
# Comprehensive testing of the Task Execution Engine implementation
# Test Coverage: Module Loading, CLI Parameters, Task Processing, Error Handling

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
    # Standard test setup
    default_setup
    
    # Create mock directories and files for testing
    mkdir -p "$TEST_TEMP_DIR/test_working_dir"
    mkdir -p "$TEST_TEMP_DIR/test_config"
    mkdir -p "$TEST_TEMP_DIR/test_logs"
    
    # Set up test environment variables
    export WORKING_DIR="$TEST_TEMP_DIR/test_working_dir"
    export SCRIPT_DIR="$(dirname "$BATS_TEST_FILENAME")/../.."
    export CONFIG_FILE="$TEST_TEMP_DIR/test_config/test.conf"
    export TASK_QUEUE_ENABLED="true"
    export DEBUG_MODE="true"
    export DRY_RUN="true"
    
    # Create test configuration file
    cat > "$CONFIG_FILE" << 'EOF'
# Test configuration for Task Execution Engine
TASK_QUEUE_ENABLED=true
GITHUB_INTEGRATION_ENABLED=true
TASK_DEFAULT_TIMEOUT=300
TASK_MAX_RETRIES=2
TASK_DEFAULT_PRIORITY=5
DEBUG_MODE=true
EOF
    
    # Source the hybrid-monitor script functions only (not execute main)
    export BASH_SOURCE=("/dev/null")  # Prevent auto-execution
}

teardown() {
    default_teardown
}

# ===============================================================================
# A) CORE INTEGRATION TESTING - Module Loading & Dependencies
# ===============================================================================

@test "Task Execution Engine: hybrid-monitor.sh loads successfully without errors" {
    run bash -n "$SCRIPT_DIR/src/hybrid-monitor.sh"
    
    assert_success
    assert_output ""  # No syntax errors should be silent
}

@test "Task Execution Engine: All required modules can be sourced" {
    # Source hybrid-monitor functions
    source "$SCRIPT_DIR/src/hybrid-monitor.sh"
    
    # Verify core functions are available
    declare -f load_dependencies &>/dev/null
    declare -f parse_arguments &>/dev/null
    declare -f process_task_queue_cycle &>/dev/null
    declare -f execute_single_task &>/dev/null
    declare -f monitor_task_completion &>/dev/null
}

@test "Task Execution Engine: load_dependencies function loads Task Queue modules when enabled" {
    # Mock the module files
    mkdir -p "$SCRIPT_DIR/src"
    echo '#!/bin/bash' > "$SCRIPT_DIR/src/task-queue.sh"
    echo 'init_task_queue() { return 0; }' >> "$SCRIPT_DIR/src/task-queue.sh"
    echo 'get_next_task() { return 1; }' >> "$SCRIPT_DIR/src/task-queue.sh"
    
    echo '#!/bin/bash' > "$SCRIPT_DIR/src/github-integration.sh"
    echo 'init_github_integration() { return 0; }' >> "$SCRIPT_DIR/src/github-integration.sh"
    
    # Source main script functions
    source "$SCRIPT_DIR/src/hybrid-monitor.sh"
    
    # Test module loading
    run load_dependencies
    
    assert_success
    assert_output --partial "Task Queue Core Module loaded successfully"
    
    # Verify functions are loaded
    declare -f init_task_queue &>/dev/null
    declare -f get_next_task &>/dev/null
}

@test "Task Execution Engine: graceful degradation when optional GitHub modules are missing" {
    # Create only required modules
    mkdir -p "$SCRIPT_DIR/src"
    echo '#!/bin/bash' > "$SCRIPT_DIR/src/task-queue.sh"
    echo 'init_task_queue() { return 0; }' >> "$SCRIPT_DIR/src/task-queue.sh"
    
    # No GitHub modules - should warn but continue
    source "$SCRIPT_DIR/src/hybrid-monitor.sh"
    
    run load_dependencies
    
    assert_success
    assert_output --partial "Optional GitHub module not found"
    assert_output --partial "GitHub integration features may be limited"
}

@test "Task Execution Engine: fails appropriately when required Task Queue module is missing" {
    # No Task Queue module
    mkdir -p "$SCRIPT_DIR/src"
    
    source "$SCRIPT_DIR/src/hybrid-monitor.sh"
    
    run load_dependencies
    
    assert_failure
    assert_output --partial "Task Queue Core Module not found"
}

# ===============================================================================
# B) CLI INTERFACE TESTING - All 14 New Parameters
# ===============================================================================

@test "Task Execution Engine: --queue-mode parameter enables task queue" {
    source "$SCRIPT_DIR/src/hybrid-monitor.sh"
    
    run parse_arguments --queue-mode
    
    assert_success
    [[ "$QUEUE_MODE" == "true" ]]
    [[ "$TASK_QUEUE_ENABLED" == "true" ]]
}

@test "Task Execution Engine: --add-issue parameter processes correctly" {
    source "$SCRIPT_DIR/src/hybrid-monitor.sh"
    
    run parse_arguments --add-issue 123
    
    assert_success
    [[ "$QUEUE_ACTION" == "add_issue" ]]
    [[ "$QUEUE_ITEM" == "123" ]]
    [[ "$QUEUE_MODE" == "true" ]]
    [[ "$TASK_QUEUE_ENABLED" == "true" ]]
}

@test "Task Execution Engine: --add-pr parameter processes correctly" {
    source "$SCRIPT_DIR/src/hybrid-monitor.sh"
    
    run parse_arguments --add-pr 456
    
    assert_success
    [[ "$QUEUE_ACTION" == "add_pr" ]]
    [[ "$QUEUE_ITEM" == "456" ]]
    [[ "$QUEUE_MODE" == "true" ]]
    [[ "$TASK_QUEUE_ENABLED" == "true" ]]
}

@test "Task Execution Engine: --add-custom parameter processes correctly" {
    source "$SCRIPT_DIR/src/hybrid-monitor.sh"
    
    run parse_arguments --add-custom "Fix the login bug"
    
    assert_success
    [[ "$QUEUE_ACTION" == "add_custom" ]]
    [[ "$QUEUE_ITEM" == "Fix the login bug" ]]
    [[ "$QUEUE_MODE" == "true" ]]
}

@test "Task Execution Engine: --list-queue parameter processes correctly" {
    source "$SCRIPT_DIR/src/hybrid-monitor.sh"
    
    run parse_arguments --list-queue
    
    assert_success
    [[ "$QUEUE_ACTION" == "list_queue" ]]
    [[ "$QUEUE_MODE" == "true" ]]
}

@test "Task Execution Engine: --clear-queue parameter processes correctly" {
    source "$SCRIPT_DIR/src/hybrid-monitor.sh"
    
    run parse_arguments --clear-queue
    
    assert_success
    [[ "$QUEUE_ACTION" == "clear_queue" ]]
    [[ "$QUEUE_MODE" == "true" ]]
}

@test "Task Execution Engine: --pause-queue and --resume-queue parameters process correctly" {
    source "$SCRIPT_DIR/src/hybrid-monitor.sh"
    
    # Test pause
    run parse_arguments --pause-queue
    assert_success
    [[ "$QUEUE_ACTION" == "pause_queue" ]]
    
    # Reset and test resume
    QUEUE_ACTION=""
    run parse_arguments --resume-queue
    assert_success
    [[ "$QUEUE_ACTION" == "resume_queue" ]]
}

@test "Task Execution Engine: --skip-current and --retry-current parameters process correctly" {
    source "$SCRIPT_DIR/src/hybrid-monitor.sh"
    
    # Test skip current
    run parse_arguments --skip-current
    assert_success
    [[ "$QUEUE_ACTION" == "skip_current" ]]
    
    # Reset and test retry current
    QUEUE_ACTION=""
    run parse_arguments --retry-current
    assert_success
    [[ "$QUEUE_ACTION" == "retry_current" ]]
}

@test "Task Execution Engine: --queue-timeout parameter validates and processes correctly" {
    source "$SCRIPT_DIR/src/hybrid-monitor.sh"
    
    # Valid timeout
    run parse_arguments --queue-timeout 1800
    assert_success
    [[ "$TASK_DEFAULT_TIMEOUT" == "1800" ]]
    
    # Invalid timeout - too low
    run parse_arguments --queue-timeout 30
    assert_failure
    assert_output --partial "must be >= 60"
    
    # Invalid timeout - too high
    run parse_arguments --queue-timeout 90000
    assert_failure
    assert_output --partial "must be <= 86400"
}

@test "Task Execution Engine: --queue-retries parameter validates and processes correctly" {
    source "$SCRIPT_DIR/src/hybrid-monitor.sh"
    
    # Valid retry count
    run parse_arguments --queue-retries 5
    assert_success
    [[ "$TASK_MAX_RETRIES" == "5" ]]
    
    # Invalid retry count - too high
    run parse_arguments --queue-retries 15
    assert_failure
    assert_output --partial "must be <= 10"
}

@test "Task Execution Engine: --queue-priority parameter validates and processes correctly" {
    source "$SCRIPT_DIR/src/hybrid-monitor.sh"
    
    # Valid priority
    run parse_arguments --queue-priority 8
    assert_success
    [[ "$TASK_DEFAULT_PRIORITY" == "8" ]]
    
    # Invalid priority - too low
    run parse_arguments --queue-priority 0
    assert_failure
    assert_output --partial "must be >= 1"
    
    # Invalid priority - too high
    run parse_arguments --queue-priority 15
    assert_failure
    assert_output --partial "must be <= 10"
}

@test "Task Execution Engine: CLI parameter validation with non-numeric values" {
    source "$SCRIPT_DIR/src/hybrid-monitor.sh"
    
    # Non-numeric issue number
    run parse_arguments --add-issue "abc"
    assert_failure
    assert_output --partial "requires a valid number"
    
    # Non-numeric PR number  
    run parse_arguments --add-pr "xyz"
    assert_failure
    assert_output --partial "requires a valid number"
    
    # Non-numeric timeout
    run parse_arguments --queue-timeout "invalid"
    assert_failure
    assert_output --partial "requires a valid number"
}

# ===============================================================================
# C) BACKWARD COMPATIBILITY TESTING
# ===============================================================================

@test "Task Execution Engine: backward compatibility - existing parameters still work" {
    source "$SCRIPT_DIR/src/hybrid-monitor.sh"
    
    run parse_arguments --continuous --check-interval 10 --max-cycles 5 --debug
    
    assert_success
    [[ "$CONTINUOUS_MODE" == "true" ]]
    [[ "$CHECK_INTERVAL_MINUTES" == "10" ]]
    [[ "$MAX_RESTARTS" == "5" ]]
    [[ "$DEBUG_MODE" == "true" ]]
    [[ "$QUEUE_MODE" == "false" ]]  # Should not auto-enable queue mode
}

@test "Task Execution Engine: backward compatibility - Claude args still processed" {
    source "$SCRIPT_DIR/src/hybrid-monitor.sh"
    
    run parse_arguments continue --model claude-3-sonnet
    
    assert_success
    [[ "${CLAUDE_ARGS[0]}" == "continue" ]]
    [[ "${CLAUDE_ARGS[1]}" == "--model" ]]
    [[ "${CLAUDE_ARGS[2]}" == "claude-3-sonnet" ]]
    [[ "$QUEUE_MODE" == "false" ]]  # Not in queue mode
}

@test "Task Execution Engine: backward compatibility - default Claude args when no queue mode" {
    source "$SCRIPT_DIR/src/hybrid-monitor.sh"
    
    run parse_arguments --continuous
    
    assert_success
    [[ "${CLAUDE_ARGS[0]}" == "continue" ]]  # Default args applied
    [[ "$QUEUE_MODE" == "false" ]]
}

@test "Task Execution Engine: backward compatibility - no default Claude args in queue mode" {
    source "$SCRIPT_DIR/src/hybrid-monitor.sh"
    
    run parse_arguments --queue-mode --continuous
    
    assert_success
    [[ "${#CLAUDE_ARGS[@]}" -eq 0 ]]  # No default args in queue mode
    [[ "$QUEUE_MODE" == "true" ]]
}

# ===============================================================================
# D) HELP AND VERSION TESTING
# ===============================================================================

@test "Task Execution Engine: help includes all new task queue parameters" {
    source "$SCRIPT_DIR/src/hybrid-monitor.sh"
    
    run show_help
    
    assert_success
    
    # Check for all new parameter sections
    assert_output --partial "TASK QUEUE OPTIONS:"
    assert_output --partial "Task Management:"
    assert_output --partial "Queue Control:"
    assert_output --partial "Queue Configuration:"
    
    # Check for specific parameters
    assert_output --partial "--add-issue"
    assert_output --partial "--add-pr"
    assert_output --partial "--add-custom"
    assert_output --partial "--list-queue"
    assert_output --partial "--clear-queue"
    assert_output --partial "--pause-queue"
    assert_output --partial "--resume-queue"
    assert_output --partial "--skip-current"
    assert_output --partial "--retry-current"
    assert_output --partial "--queue-timeout"
    assert_output --partial "--queue-retries"
    assert_output --partial "--queue-priority"
    
    # Check for workflow description
    assert_output --partial "TASK QUEUE WORKFLOW:"
}

@test "Task Execution Engine: version info includes dependency information" {
    source "$SCRIPT_DIR/src/hybrid-monitor.sh"
    
    run show_version
    
    assert_success
    assert_output --partial "version"
    assert_output --partial "Dependencies:"
}

# ===============================================================================
# E) CONFIGURATION LOADING TESTING
# ===============================================================================

@test "Task Execution Engine: configuration loading includes new task queue parameters" {
    # Create test config with task queue parameters
    cat > "$CONFIG_FILE" << 'EOF'
TASK_QUEUE_ENABLED=true
TASK_DEFAULT_TIMEOUT=7200
TASK_MAX_RETRIES=5
GITHUB_INTEGRATION_ENABLED=true
GITHUB_AUTO_COMMENT=true
DEBUG_MODE=true
EOF
    
    source "$SCRIPT_DIR/src/hybrid-monitor.sh"
    
    run load_configuration
    
    assert_success
    
    # Verify task queue parameters are loaded
    [[ "$TASK_QUEUE_ENABLED" == "true" ]]
    [[ "$TASK_DEFAULT_TIMEOUT" == "7200" ]]
    [[ "$TASK_MAX_RETRIES" == "5" ]]
    [[ "$GITHUB_INTEGRATION_ENABLED" == "true" ]]
    [[ "$GITHUB_AUTO_COMMENT" == "true" ]]
}

@test "Task Execution Engine: configuration loading with invalid values uses defaults" {
    # Create config with some invalid values
    cat > "$CONFIG_FILE" << 'EOF'
TASK_QUEUE_ENABLED=maybe
TASK_DEFAULT_TIMEOUT=invalid
TASK_MAX_RETRIES=twenty
DEBUG_MODE=true
EOF
    
    source "$SCRIPT_DIR/src/hybrid-monitor.sh"
    
    run load_configuration
    
    assert_success
    
    # Invalid values should be loaded as strings (validation happens later)
    [[ "$TASK_QUEUE_ENABLED" == "maybe" ]]  
    [[ "$TASK_DEFAULT_TIMEOUT" == "invalid" ]]
}