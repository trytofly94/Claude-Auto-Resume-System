#!/usr/bin/env bash

# Claude Auto-Resume - Task Queue Test Runner
# Comprehensive test runner for Task Queue Core Module
# Runs unit tests, integration tests, and performance benchmarks

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test configuration
VERBOSE=false
STOP_ON_FAILURE=false
TEST_TYPE="all"
PERFORMANCE_TESTS=false
OUTPUT_JUNIT=false

# Usage information
usage() {
    cat << EOF
Usage: $0 [OPTIONS] [TEST_TYPE]

Run Task Queue Core Module tests

TEST_TYPE:
    unit            Run unit tests only
    integration     Run integration tests only  
    all             Run all tests (default)
    performance     Run performance benchmarks

OPTIONS:
    -v, --verbose       Enable verbose output
    -s, --stop          Stop on first failure
    -p, --performance   Include performance tests
    -j, --junit         Generate JUnit XML output
    -h, --help          Show this help

Examples:
    $0                  # Run all tests
    $0 unit            # Run only unit tests
    $0 -v -s integration  # Run integration tests with verbose output, stop on failure
    $0 --performance   # Run performance benchmarks
EOF
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -s|--stop)
                STOP_ON_FAILURE=true
                shift
                ;;
            -p|--performance)
                PERFORMANCE_TESTS=true
                shift
                ;;
            -j|--junit)
                OUTPUT_JUNIT=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            unit|integration|all|performance)
                TEST_TYPE="$1"
                shift
                ;;
            *)
                echo "Unknown argument: $1" >&2
                usage
                exit 1
                ;;
        esac
    done
}

# Print colored output
print_status() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# Check if bats is available
check_bats() {
    if ! command -v bats >/dev/null 2>&1; then
        print_status "$RED" "ERROR: bats (Bash Automated Testing System) is not installed"
        print_status "$YELLOW" "Please install bats:"
        print_status "$YELLOW" "  macOS: brew install bats-core"
        print_status "$YELLOW" "  Linux: apt-get install bats (or equivalent)"
        print_status "$YELLOW" "  Manual: https://github.com/bats-core/bats-core#installation"
        exit 1
    fi
}

# Check if jq is available (required for task queue)
check_jq() {
    if ! command -v jq >/dev/null 2>&1; then
        print_status "$RED" "ERROR: jq is not installed (required for Task Queue JSON processing)"
        print_status "$YELLOW" "Please install jq:"
        print_status "$YELLOW" "  macOS: brew install jq"
        print_status "$YELLOW" "  Linux: apt-get install jq"
        exit 1
    fi
}

# Set up test environment
setup_test_env() {
    print_status "$BLUE" "Setting up test environment..."
    
    # Ensure test directories exist
    mkdir -p "$PROJECT_ROOT/tests/unit"
    mkdir -p "$PROJECT_ROOT/tests/integration"
    mkdir -p "$PROJECT_ROOT/tests/fixtures"
    
    # Set test-specific environment variables
    export TEST_MODE=true
    export DEBUG_MODE=false
    export LOG_LEVEL=ERROR  # Reduce noise during tests
    
    # Enable task queue for testing
    export TASK_QUEUE_ENABLED=true
    export TASK_QUEUE_DIR="queue"
    export TASK_DEFAULT_TIMEOUT=30  # Shorter for tests
    export QUEUE_LOCK_TIMEOUT=5     # Shorter for tests
    
    print_status "$GREEN" "Test environment ready"
}

# Run unit tests
run_unit_tests() {
    print_status "$BLUE" "Running Task Queue Unit Tests..."
    
    local test_file="$PROJECT_ROOT/tests/unit/test-task-queue.bats"
    if [[ ! -f "$test_file" ]]; then
        print_status "$RED" "ERROR: Unit test file not found: $test_file"
        return 1
    fi
    
    local bats_args=()
    [[ "$VERBOSE" == "true" ]] && bats_args+=("--verbose-run")
    [[ "$OUTPUT_JUNIT" == "true" ]] && bats_args+=("--formatter" "junit" "--output" "$PROJECT_ROOT/test-results")
    
    if bats "${bats_args[@]}" "$test_file"; then
        print_status "$GREEN" "✓ Unit tests passed"
        return 0
    else
        print_status "$RED" "✗ Unit tests failed"
        return 1
    fi
}

# Run integration tests
run_integration_tests() {
    print_status "$BLUE" "Running Task Queue Integration Tests..."
    
    local test_file="$PROJECT_ROOT/tests/integration/test-task-queue-integration.bats"
    if [[ ! -f "$test_file" ]]; then
        print_status "$RED" "ERROR: Integration test file not found: $test_file"
        return 1
    fi
    
    local bats_args=()
    [[ "$VERBOSE" == "true" ]] && bats_args+=("--verbose-run")
    [[ "$OUTPUT_JUNIT" == "true" ]] && bats_args+=("--formatter" "junit" "--output" "$PROJECT_ROOT/test-results")
    
    if bats "${bats_args[@]}" "$test_file"; then
        print_status "$GREEN" "✓ Integration tests passed"
        return 0
    else
        print_status "$RED" "✗ Integration tests failed"
        return 1
    fi
}

# Run performance benchmarks
run_performance_tests() {
    print_status "$BLUE" "Running Task Queue Performance Tests..."
    
    local temp_dir
    temp_dir=$(mktemp -d)
    cd "$temp_dir"
    
    # Set up test environment
    export TASK_QUEUE_ENABLED=true
    export TASK_QUEUE_DIR="queue"
    
    # Source the task queue module
    source "$PROJECT_ROOT/src/task-queue.sh"
    
    # Initialize
    if ! init_task_queue; then
        print_status "$RED" "ERROR: Failed to initialize task queue for performance tests"
        return 1
    fi
    
    print_status "$YELLOW" "Performance Test 1: Task Creation Speed"
    local start_time=$(date +%s.%N)
    
    for i in {1..100}; do
        add_task_to_queue "$TASK_TYPE_CUSTOM" $((i % 10 + 1)) "" "description" "Perf test $i" > /dev/null
    done
    
    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "N/A")
    print_status "$GREEN" "Created 100 tasks in ${duration}s"
    
    print_status "$YELLOW" "Performance Test 2: Queue Operations Speed"
    start_time=$(date +%s.%N)
    
    # Test various operations
    list_queue_tasks > /dev/null
    get_queue_statistics > /dev/null
    get_next_task "$TASK_STATE_PENDING" > /dev/null
    
    end_time=$(date +%s.%N)
    duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "N/A")
    print_status "$GREEN" "Queue operations completed in ${duration}s"
    
    print_status "$YELLOW" "Performance Test 3: JSON Persistence Speed"
    start_time=$(date +%s.%N)
    
    save_queue_state
    load_queue_state > /dev/null
    
    end_time=$(date +%s.%N)
    duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "N/A")
    print_status "$GREEN" "JSON save/load completed in ${duration}s"
    
    # Memory usage test
    print_status "$YELLOW" "Performance Test 4: Memory Usage"
    local task_count=${#TASK_STATES[@]}
    local json_size
    json_size=$(stat -f%z "queue/task-queue.json" 2>/dev/null || stat -c%s "queue/task-queue.json" 2>/dev/null || echo "0")
    
    print_status "$GREEN" "Tasks in memory: $task_count"
    print_status "$GREEN" "JSON file size: ${json_size} bytes"
    
    # Cleanup
    cd "$PROJECT_ROOT"
    rm -rf "$temp_dir"
    
    print_status "$GREEN" "✓ Performance tests completed"
    return 0
}

# Run built-in task queue tests
run_builtin_tests() {
    print_status "$BLUE" "Running Task Queue Built-in Tests..."
    
    # Use the built-in test command of the task queue module
    if "$PROJECT_ROOT/src/task-queue.sh" test; then
        print_status "$GREEN" "✓ Built-in tests passed"
        return 0
    else
        print_status "$RED" "✗ Built-in tests failed"
        return 1
    fi
}

# Generate test report
generate_report() {
    local total_tests="$1"
    local passed_tests="$2"
    local failed_tests="$3"
    local skipped_tests="$4"
    
    print_status "$BLUE" "================================================="
    print_status "$BLUE" "Task Queue Test Results Summary"
    print_status "$BLUE" "================================================="
    
    print_status "$NC" "Total Tests:   $total_tests"
    [[ $passed_tests -gt 0 ]] && print_status "$GREEN" "Passed:        $passed_tests"
    [[ $failed_tests -gt 0 ]] && print_status "$RED" "Failed:        $failed_tests"
    [[ $skipped_tests -gt 0 ]] && print_status "$YELLOW" "Skipped:       $skipped_tests"
    
    local success_rate
    if [[ $total_tests -gt 0 ]]; then
        success_rate=$((passed_tests * 100 / total_tests))
        print_status "$NC" "Success Rate:  ${success_rate}%"
    fi
    
    print_status "$BLUE" "================================================="
    
    if [[ $failed_tests -eq 0 ]]; then
        print_status "$GREEN" "🎉 All tests passed!"
        return 0
    else
        print_status "$RED" "❌ Some tests failed!"
        return 1
    fi
}

# Main execution function
main() {
    local exit_code=0
    local tests_run=0
    local tests_passed=0
    local tests_failed=0
    local tests_skipped=0
    
    print_status "$BLUE" "Task Queue Core Module Test Runner"
    print_status "$BLUE" "=================================="
    
    # Check dependencies
    check_bats
    check_jq
    
    # Set up test environment
    setup_test_env
    
    # Prepare output directory for JUnit
    if [[ "$OUTPUT_JUNIT" == "true" ]]; then
        mkdir -p "$PROJECT_ROOT/test-results"
    fi
    
    # Run specified tests
    case "$TEST_TYPE" in
        "unit")
            if run_unit_tests; then
                ((tests_passed++))
            else
                ((tests_failed++))
                exit_code=1
                [[ "$STOP_ON_FAILURE" == "true" ]] && exit $exit_code
            fi
            ((tests_run++))
            ;;
        "integration")
            if run_integration_tests; then
                ((tests_passed++))
            else
                ((tests_failed++))
                exit_code=1
                [[ "$STOP_ON_FAILURE" == "true" ]] && exit $exit_code
            fi
            ((tests_run++))
            ;;
        "performance")
            if run_performance_tests; then
                ((tests_passed++))
            else
                ((tests_failed++))
                exit_code=1
            fi
            ((tests_run++))
            ;;
        "all")
            # Run unit tests
            if run_unit_tests; then
                ((tests_passed++))
            else
                ((tests_failed++))
                exit_code=1
                [[ "$STOP_ON_FAILURE" == "true" ]] && exit $exit_code
            fi
            ((tests_run++))
            
            # Run integration tests
            if run_integration_tests; then
                ((tests_passed++))
            else
                ((tests_failed++))
                exit_code=1
                [[ "$STOP_ON_FAILURE" == "true" ]] && exit $exit_code
            fi
            ((tests_run++))
            
            # Run built-in tests
            if run_builtin_tests; then
                ((tests_passed++))
            else
                ((tests_failed++))
                exit_code=1
                [[ "$STOP_ON_FAILURE" == "true" ]] && exit $exit_code
            fi
            ((tests_run++))
            
            # Run performance tests if requested
            if [[ "$PERFORMANCE_TESTS" == "true" ]]; then
                if run_performance_tests; then
                    ((tests_passed++))
                else
                    ((tests_failed++))
                    exit_code=1
                fi
                ((tests_run++))
            fi
            ;;
    esac
    
    # Generate report
    generate_report "$tests_run" "$tests_passed" "$tests_failed" "$tests_skipped"
    
    exit $exit_code
}

# Parse arguments and run
parse_args "$@"
main