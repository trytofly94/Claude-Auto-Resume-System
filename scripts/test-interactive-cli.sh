#!/usr/bin/env bash

# Claude Auto-Resume - Interactive CLI Testing Script
# Comprehensive testing for interactive mode functionality
# Version: 1.0.0

set -euo pipefail

# ===============================================================================
# CONFIGURATION AND SETUP
# ===============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TASK_QUEUE_SCRIPT="$PROJECT_ROOT/src/task-queue.sh"
TEST_RESULTS_DIR="$PROJECT_ROOT/tests/interactive-results"
TEST_LOG="$TEST_RESULTS_DIR/test-log-$(date +%Y%m%d-%H%M%S).log"

# Test configuration
TEST_TIMEOUT=60
MONITOR_DURATION=10

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test results
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TOTAL=0

# ===============================================================================
# LOGGING AND UTILITIES
# ===============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$TEST_LOG"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" | tee -a "$TEST_LOG"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" | tee -a "$TEST_LOG"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*" | tee -a "$TEST_LOG"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" | tee -a "$TEST_LOG"
}

# Test assertion functions
assert_success() {
    local test_name="$1"
    local exit_code="$2"
    ((TESTS_TOTAL++))
    
    if [[ $exit_code -eq 0 ]]; then
        ((TESTS_PASSED++))
        log_success "✓ $test_name"
        return 0
    else
        ((TESTS_FAILED++))
        log_error "✗ $test_name (exit code: $exit_code)"
        return 1
    fi
}

assert_contains() {
    local test_name="$1"
    local output="$2"
    local expected="$3"
    ((TESTS_TOTAL++))
    
    if [[ "$output" =~ $expected ]]; then
        ((TESTS_PASSED++))
        log_success "✓ $test_name"
        return 0
    else
        ((TESTS_FAILED++))
        log_error "✗ $test_name - Expected '$expected' not found in output"
        return 1
    fi
}

# ===============================================================================
# SETUP AND TEARDOWN
# ===============================================================================

setup_test_environment() {
    log_info "Setting up test environment"
    
    # Create test results directory
    mkdir -p "$TEST_RESULTS_DIR"
    
    # Verify task queue script exists
    if [[ ! -f "$TASK_QUEUE_SCRIPT" ]]; then
        log_error "Task queue script not found: $TASK_QUEUE_SCRIPT"
        exit 1
    fi
    
    # Initialize task queue system
    log_info "Initializing task queue system"
    "$TASK_QUEUE_SCRIPT" status >/dev/null || {
        log_error "Failed to initialize task queue system"
        exit 1
    }
    
    log_success "Test environment setup complete"
}

cleanup_test_environment() {
    log_info "Cleaning up test environment"
    
    # Clean up any test tasks we created
    local test_task_ids=("test-interactive-1" "test-interactive-2" "test-interactive-3")
    
    for task_id in "${test_task_ids[@]}"; do
        "$TASK_QUEUE_SCRIPT" remove "$task_id" >/dev/null 2>&1 || true
    done
    
    # Remove test history file
    rm -f ~/.claude-auto-resume-history-test
    
    log_success "Test environment cleanup complete"
}

# ===============================================================================
# INTERACTIVE COMMAND TESTING
# ===============================================================================

# Test individual interactive commands by simulating user input
test_interactive_commands() {
    log_info "Testing interactive commands"
    
    # Test help command
    test_interactive_help
    
    # Test add command
    test_interactive_add
    
    # Test list command
    test_interactive_list
    
    # Test status command
    test_interactive_status
    
    # Test stats command
    test_interactive_stats
    
    # Test remove command
    test_interactive_remove
    
    # Test save/load commands
    test_interactive_save_load
    
    # Test backup command
    test_interactive_backup
    
    # Test cleanup command
    test_interactive_cleanup
}

test_interactive_help() {
    log_info "Testing help command"
    
    local output
    output=$(echo "help" | timeout "$TEST_TIMEOUT" "$TASK_QUEUE_SCRIPT" interactive 2>&1) || true
    
    assert_contains "Help shows available commands" "$output" "Available commands"
    assert_contains "Help shows add command" "$output" "add <task_data>"
    assert_contains "Help shows remove command" "$output" "remove <task_id>"
    assert_contains "Help shows exit command" "$output" "exit, quit"
}

test_interactive_add() {
    log_info "Testing add command"
    
    local test_task='{"id":"test-interactive-1","type":"test","status":"pending","created_at":"'$(date -Iseconds)'"}'
    local command="add $test_task"$'\nexit'
    
    local output
    output=$(echo -e "$command" | timeout "$TEST_TIMEOUT" "$TASK_QUEUE_SCRIPT" interactive 2>&1) || true
    
    assert_contains "Add command successful" "$output" "Task added successfully"
    
    # Verify task was actually added
    local task_exists
    task_exists=$("$TASK_QUEUE_SCRIPT" list pending | jq -r '.[] | select(.id=="test-interactive-1") | .id') || true
    
    if [[ "$task_exists" == "test-interactive-1" ]]; then
        ((TESTS_PASSED++))
        log_success "✓ Task actually added to queue"
    else
        ((TESTS_FAILED++))
        log_error "✗ Task not found in queue after add"
    fi
    ((TESTS_TOTAL++))
}

test_interactive_list() {
    log_info "Testing list command"
    
    local command="list"$'\nexit'
    
    local output
    output=$(echo -e "$command" | timeout "$TEST_TIMEOUT" "$TASK_QUEUE_SCRIPT" interactive 2>&1) || true
    
    assert_contains "List shows table headers" "$output" "ID.*TYPE.*STATUS.*CREATED"
    assert_contains "List shows test task" "$output" "test-interactive-1"
}

test_interactive_status() {
    log_info "Testing status command"
    
    local command="status"$'\nexit'
    
    local output
    output=$(echo -e "$command" | timeout "$TEST_TIMEOUT" "$TASK_QUEUE_SCRIPT" interactive 2>&1) || true
    
    assert_contains "Status shows queue summary" "$output" "Queue Status Summary"
    assert_contains "Status shows total tasks" "$output" "Total Tasks:"
    assert_contains "Status shows pending tasks" "$output" "Pending:"
}

test_interactive_stats() {
    log_info "Testing stats command"
    
    local command="stats"$'\nexit'
    
    local output
    output=$(echo -e "$command" | timeout "$TEST_TIMEOUT" "$TASK_QUEUE_SCRIPT" interactive 2>&1) || true
    
    assert_contains "Stats shows detailed information" "$output" "Detailed Statistics"
    assert_contains "Stats shows task types" "$output" "Tasks by Type"
}

test_interactive_remove() {
    log_info "Testing remove command"
    
    local command="remove test-interactive-1"$'\nexit'
    
    local output
    output=$(echo -e "$command" | timeout "$TEST_TIMEOUT" "$TASK_QUEUE_SCRIPT" interactive 2>&1) || true
    
    assert_contains "Remove command successful" "$output" "Task removed: test-interactive-1"
    
    # Verify task was actually removed
    local task_exists
    task_exists=$("$TASK_QUEUE_SCRIPT" list all | jq -r '.[] | select(.id=="test-interactive-1") | .id') || true
    
    if [[ -z "$task_exists" ]]; then
        ((TESTS_PASSED++))
        log_success "✓ Task actually removed from queue"
    else
        ((TESTS_FAILED++))
        log_error "✗ Task still exists in queue after remove"
    fi
    ((TESTS_TOTAL++))
}

test_interactive_save_load() {
    log_info "Testing save/load commands"
    
    # Test save command
    local save_command="save"$'\nexit'
    local output
    output=$(echo -e "$save_command" | timeout "$TEST_TIMEOUT" "$TASK_QUEUE_SCRIPT" interactive 2>&1) || true
    
    assert_contains "Save command successful" "$output" "Queue state saved successfully"
    
    # Test load command
    local load_command="load"$'\nexit'
    output=$(echo -e "$load_command" | timeout "$TEST_TIMEOUT" "$TASK_QUEUE_SCRIPT" interactive 2>&1) || true
    
    assert_contains "Load command successful" "$output" "Queue state loaded successfully"
}

test_interactive_backup() {
    log_info "Testing backup command"
    
    local command="backup test-backup"$'\nexit'
    
    local output
    output=$(echo -e "$command" | timeout "$TEST_TIMEOUT" "$TASK_QUEUE_SCRIPT" interactive 2>&1) || true
    
    assert_contains "Backup command successful" "$output" "Backup created successfully"
}

test_interactive_cleanup() {
    log_info "Testing cleanup command"
    
    local command="cleanup"$'\nexit'
    
    local output
    output=$(echo -e "$command" | timeout "$TEST_TIMEOUT" "$TASK_QUEUE_SCRIPT" interactive 2>&1) || true
    
    assert_contains "Cleanup command runs" "$output" "Running maintenance cleanup"
    assert_contains "Cleanup completes" "$output" "Cleanup completed"
}

# ===============================================================================
# MONITORING AND ADVANCED FEATURES TESTING
# ===============================================================================

test_interactive_monitoring() {
    log_info "Testing real-time monitoring"
    
    # Create a test task first
    local test_task='{"id":"test-interactive-monitor","type":"test","status":"pending","created_at":"'$(date -Iseconds)'"}'
    "$TASK_QUEUE_SCRIPT" add "$test_task" >/dev/null
    
    # Test monitor command with short duration
    local command="monitor $MONITOR_DURATION"$'\nexit'
    
    local output
    output=$(echo -e "$command" | timeout $((TEST_TIMEOUT + MONITOR_DURATION)) "$TASK_QUEUE_SCRIPT" interactive 2>&1) || true
    
    assert_contains "Monitor starts successfully" "$output" "Starting real-time monitoring"
    assert_contains "Monitor shows task data" "$output" "Real-Time Task Queue Monitoring"
    assert_contains "Monitor completes" "$output" "Monitoring completed"
    
    # Clean up test task
    "$TASK_QUEUE_SCRIPT" remove "test-interactive-monitor" >/dev/null 2>&1 || true
}

test_interactive_locks() {
    log_info "Testing locks command"
    
    local command="locks"$'\nexit'
    
    local output
    output=$(echo -e "$command" | timeout "$TEST_TIMEOUT" "$TASK_QUEUE_SCRIPT" interactive 2>&1) || true
    
    assert_contains "Locks command shows status" "$output" "Current Lock Status"
}

# ===============================================================================
# ERROR HANDLING AND EDGE CASES
# ===============================================================================

test_interactive_error_handling() {
    log_info "Testing error handling"
    
    # Test invalid command
    test_invalid_command
    
    # Test invalid JSON for add
    test_invalid_json_add
    
    # Test missing arguments
    test_missing_arguments
}

test_invalid_command() {
    log_info "Testing invalid command handling"
    
    local command="invalidcommand"$'\nexit'
    
    local output
    output=$(echo -e "$command" | timeout "$TEST_TIMEOUT" "$TASK_QUEUE_SCRIPT" interactive 2>&1) || true
    
    assert_contains "Invalid command shows error" "$output" "Unknown command"
    assert_contains "Invalid command shows help hint" "$output" "Type 'help'"
}

test_invalid_json_add() {
    log_info "Testing invalid JSON handling in add command"
    
    local command="add {invalid-json}"$'\nexit'
    
    local output
    output=$(echo -e "$command" | timeout "$TEST_TIMEOUT" "$TASK_QUEUE_SCRIPT" interactive 2>&1) || true
    
    assert_contains "Invalid JSON shows error" "$output" "Invalid JSON format"
}

test_missing_arguments() {
    log_info "Testing missing arguments handling"
    
    # Test add without arguments
    local command="add"$'\nexit'
    
    local output
    output=$(echo -e "$command" | timeout "$TEST_TIMEOUT" "$TASK_QUEUE_SCRIPT" interactive 2>&1) || true
    
    assert_contains "Missing add argument shows usage" "$output" "Usage: add <task_data_json>"
    
    # Test remove without arguments
    command="remove"$'\nexit'
    output=$(echo -e "$command" | timeout "$TEST_TIMEOUT" "$TASK_QUEUE_SCRIPT" interactive 2>&1) || true
    
    assert_contains "Missing remove argument shows usage" "$output" "Usage: remove <task_id>"
}

# ===============================================================================
# SESSION AND HISTORY TESTING
# ===============================================================================

test_command_history() {
    log_info "Testing command history functionality"
    
    # Set custom history file for testing
    export INTERACTIVE_HISTORY_FILE=~/.claude-auto-resume-history-test
    
    # Create a series of commands to test history
    local commands="help"$'\n'"status"$'\n'"list"$'\n'"exit"
    
    local output
    output=$(echo -e "$commands" | timeout "$TEST_TIMEOUT" "$TASK_QUEUE_SCRIPT" interactive 2>&1) || true
    
    # Check if history file was created (basic test)
    if [[ -f "$INTERACTIVE_HISTORY_FILE" ]]; then
        ((TESTS_PASSED++))
        log_success "✓ History file created"
    else
        ((TESTS_FAILED++))
        log_error "✗ History file not created"
    fi
    ((TESTS_TOTAL++))
}

test_graceful_exit() {
    log_info "Testing graceful exit"
    
    # Test exit command
    local command="exit"
    
    local output
    output=$(echo -e "$command" | timeout "$TEST_TIMEOUT" "$TASK_QUEUE_SCRIPT" interactive 2>&1) || true
    
    assert_contains "Exit shows goodbye message" "$output" "Goodbye!"
    
    # Test quit command
    command="quit"
    output=$(echo -e "$command" | timeout "$TEST_TIMEOUT" "$TASK_QUEUE_SCRIPT" interactive 2>&1) || true
    
    assert_contains "Quit shows goodbye message" "$output" "Goodbye!"
}

# ===============================================================================
# INTEGRATION TESTING
# ===============================================================================

test_module_integration() {
    log_info "Testing integration with core modules"
    
    # Test that interactive mode integrates properly with core modules
    local command="status"$'\nexit'
    
    local output
    output=$(echo -e "$command" | timeout "$TEST_TIMEOUT" "$TASK_QUEUE_SCRIPT" interactive 2>&1) || true
    
    # Should not show any module loading errors
    if ! echo "$output" | grep -q "Failed to load"; then
        ((TESTS_PASSED++))
        log_success "✓ No module loading errors in interactive mode"
    else
        ((TESTS_FAILED++))
        log_error "✗ Module loading errors detected"
    fi
    ((TESTS_TOTAL++))
}

# ===============================================================================
# PERFORMANCE AND RESOURCE TESTING
# ===============================================================================

test_performance() {
    log_info "Testing performance and resource usage"
    
    # Test interactive mode startup time
    local start_time=$(date +%s%N)
    
    local command="exit"
    echo -e "$command" | timeout "$TEST_TIMEOUT" "$TASK_QUEUE_SCRIPT" interactive >/dev/null 2>&1 || true
    
    local end_time=$(date +%s%N)
    local startup_time=$(((end_time - start_time) / 1000000)) # Convert to milliseconds
    
    if [[ $startup_time -lt 5000 ]]; then # Less than 5 seconds
        ((TESTS_PASSED++))
        log_success "✓ Interactive mode startup time acceptable ($startup_time ms)"
    else
        ((TESTS_FAILED++))
        log_error "✗ Interactive mode startup time too slow ($startup_time ms)"
    fi
    ((TESTS_TOTAL++))
}

# ===============================================================================
# COMPREHENSIVE TEST RUNNER
# ===============================================================================

run_comprehensive_tests() {
    log_info "Starting comprehensive interactive CLI testing"
    
    # Setup
    setup_test_environment
    
    # Core functionality tests
    test_interactive_commands
    
    # Advanced features tests
    test_interactive_monitoring
    test_interactive_locks
    
    # Error handling tests
    test_interactive_error_handling
    
    # Session and history tests
    test_command_history
    test_graceful_exit
    
    # Integration tests
    test_module_integration
    
    # Performance tests
    test_performance
    
    # Cleanup
    cleanup_test_environment
}

# ===============================================================================
# REPORT GENERATION
# ===============================================================================

generate_test_report() {
    log_info "Generating test report"
    
    local report_file="$TEST_RESULTS_DIR/interactive-cli-test-report-$(date +%Y%m%d-%H%M%S).md"
    
    cat > "$report_file" << EOF
# Interactive CLI Testing Report

**Date**: $(date '+%Y-%m-%d %H:%M:%S')
**Duration**: Testing completed in approximately $(($(date +%s) - START_TIME)) seconds

## Summary

- **Total Tests**: $TESTS_TOTAL
- **Passed**: $TESTS_PASSED
- **Failed**: $TESTS_FAILED
- **Success Rate**: $(( (TESTS_PASSED * 100) / TESTS_TOTAL ))%

## Test Categories

### Core Commands
- help, add, remove, list, status, stats commands

### Advanced Features  
- Real-time monitoring
- Lock management
- Backup operations

### Error Handling
- Invalid commands
- Invalid JSON
- Missing arguments

### Session Management
- Command history
- Graceful exit

### Integration
- Core module integration
- Performance validation

## Detailed Results

See full test log: \`$TEST_LOG\`

EOF

    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "\n✅ **All tests passed!** Interactive CLI mode is functioning correctly." >> "$report_file"
    else
        echo -e "\n❌ **Some tests failed.** Check the test log for details." >> "$report_file"
    fi
    
    log_info "Test report saved to: $report_file"
    echo
    cat "$report_file"
}

# ===============================================================================
# MAIN EXECUTION
# ===============================================================================

main() {
    echo "==============================================================================="
    echo "Claude Auto-Resume - Interactive CLI Testing Script"
    echo "==============================================================================="
    echo
    
    # Record start time
    START_TIME=$(date +%s)
    
    # Run comprehensive tests
    run_comprehensive_tests
    
    echo
    echo "==============================================================================="
    echo "TEST SUMMARY"
    echo "==============================================================================="
    
    if [[ $TESTS_FAILED -eq 0 ]]; then
        log_success "All $TESTS_TOTAL tests passed! ✅"
        echo
        log_info "Interactive CLI mode is functioning correctly and ready for production use."
    else
        log_error "$TESTS_FAILED out of $TESTS_TOTAL tests failed ❌"
        echo
        log_warning "Please review the failed tests and fix any issues before production use."
    fi
    
    # Generate report
    generate_test_report
    
    # Return appropriate exit code
    return $([[ $TESTS_FAILED -eq 0 ]] && echo 0 || echo 1)
}

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi