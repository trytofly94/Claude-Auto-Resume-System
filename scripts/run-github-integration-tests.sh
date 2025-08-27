#!/usr/bin/env bash

# GitHub Integration Test Runner
# Specialized test runner for GitHub Integration Module testing
# Includes comprehensive test execution, coverage reporting, and performance metrics

set -euo pipefail

# ===============================================================================
# SCRIPT CONFIGURATION
# ===============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TESTS_DIR="$PROJECT_ROOT/tests"

# Test configuration
TEST_RUNNER_NAME="GitHub Integration Test Runner"
TEST_RUNNER_VERSION="1.0.0"
LOG_FILE="$PROJECT_ROOT/logs/github-integration-tests.log"
RESULTS_FILE="$PROJECT_ROOT/test-results-github.json"

# Test categories
GITHUB_UNIT_TESTS="$TESTS_DIR/unit/test-github-integration.bats $TESTS_DIR/unit/test-github-comments.bats $TESTS_DIR/unit/test-github-task-integration.bats"
GITHUB_INTEGRATION_TESTS="$TESTS_DIR/integration/test-github-task-queue-integration.bats"

# Performance thresholds
MAX_TEST_DURATION="300"          # 5 minutes maximum per test suite
MAX_MEMORY_USAGE="500"           # 500MB maximum memory usage
MIN_SUCCESS_RATE="95"            # 95% minimum test success rate

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly WHITE='\033[1;37m'
readonly NC='\033[0m' # No Color

# ===============================================================================
# UTILITY FUNCTIONS
# ===============================================================================

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
    
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    
    case "$level" in
        "ERROR")
            echo -e "${RED}[ERROR]${NC} $message" >&2
            ;;
        "WARN")
            echo -e "${YELLOW}[WARN]${NC} $message" >&2
            ;;
        "INFO")
            echo -e "${BLUE}[INFO]${NC} $message"
            ;;
        "SUCCESS")
            echo -e "${GREEN}[SUCCESS]${NC} $message"
            ;;
        "DEBUG")
            if [[ "${DEBUG_MODE:-false}" == "true" ]]; then
                echo -e "${PURPLE}[DEBUG]${NC} $message"
            fi
            ;;
        *)
            echo "$message"
            ;;
    esac
}

print_header() {
    local title="$1"
    local width=80
    local padding=$(((width - ${#title} - 2) / 2))
    
    echo
    echo -e "${CYAN}$(printf '═%.0s' $(seq 1 $width))${NC}"
    echo -e "${CYAN}$(printf '%-*s' $padding '')${WHITE}$title${CYAN}$(printf '%-*s' $padding '')${NC}"
    echo -e "${CYAN}$(printf '═%.0s' $(seq 1 $width))${NC}"
    echo
}

print_section() {
    local title="$1"
    echo
    echo -e "${YELLOW}▶ $title${NC}"
    echo -e "${YELLOW}$(printf '─%.0s' $(seq 1 $((${#title} + 2))))${NC}"
}

check_dependencies() {
    local missing_deps=()
    
    # Check for bats
    if ! command -v bats >/dev/null 2>&1; then
        missing_deps+=("bats")
    fi
    
    # Check for jq
    if ! command -v jq >/dev/null 2>&1; then
        missing_deps+=("jq")
    fi
    
    # Check for Python 3
    if ! command -v python3 >/dev/null 2>&1; then
        missing_deps+=("python3")
    fi
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log "ERROR" "Missing required dependencies: ${missing_deps[*]}"
        log "INFO" "Please install missing dependencies and try again"
        return 1
    fi
    
    return 0
}

setup_test_environment() {
    # Create logs directory if it doesn't exist
    mkdir -p "$(dirname "$LOG_FILE")"
    
    # Initialize log file
    echo "=== GitHub Integration Test Session Started at $(date -u -Iseconds) ===" > "$LOG_FILE"
    
    # Set test environment variables
    export TEST_MODE="true"
    export DEBUG_MODE="${DEBUG_MODE:-false}"
    export GITHUB_INTEGRATION_TEST_MODE="true"
    export LOG_LEVEL="INFO"
    
    # Disable real GitHub API calls
    export OFFLINE_MODE="true"
    export GITHUB_MOCK_MODE="true"
    
    log "INFO" "Test environment initialized"
}

# ===============================================================================
# TEST EXECUTION FUNCTIONS
# ===============================================================================

run_test_suite() {
    local suite_name="$1"
    local test_files="$2"
    local start_time=$(date +%s)
    local temp_results=$(mktemp)
    
    print_section "Running $suite_name"
    
    # Run tests with XML output for CI/CD compatibility
    local bats_cmd="bats --formatter tap"
    if [[ "${XML_OUTPUT:-false}" == "true" ]]; then
        bats_cmd="bats --formatter junit"
    fi
    
    # Execute tests with timeout
    local test_result=0
    if timeout "$MAX_TEST_DURATION" $bats_cmd $test_files > "$temp_results" 2>&1; then
        test_result=0
        log "SUCCESS" "$suite_name completed successfully"
    else
        test_result=$?
        if [[ $test_result -eq 124 ]]; then
            log "ERROR" "$suite_name timed out after ${MAX_TEST_DURATION}s"
        else
            log "ERROR" "$suite_name failed with exit code $test_result"
        fi
    fi
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    # Parse test results
    local total_tests=0
    local passed_tests=0
    local failed_tests=0
    local skipped_tests=0
    
    if [[ -f "$temp_results" ]]; then
        # Count TAP results
        total_tests=$(grep -c "^ok\|^not ok" "$temp_results" || echo 0)
        passed_tests=$(grep -c "^ok" "$temp_results" || echo 0)
        failed_tests=$(grep -c "^not ok" "$temp_results" || echo 0)
        skipped_tests=$(grep -c "# SKIP" "$temp_results" || echo 0)
        
        # Display results
        cat "$temp_results"
        
        # Log summary
        log "INFO" "$suite_name Results: $passed_tests passed, $failed_tests failed, $skipped_tests skipped (${duration}s)"
    fi
    
    # Store results for JSON report
    local success_rate=0
    if [[ $total_tests -gt 0 ]]; then
        success_rate=$(( (passed_tests * 100) / total_tests ))
    fi
    
    cat >> "$RESULTS_FILE.tmp" << EOF
    {
      "suite": "$suite_name",
      "start_time": $start_time,
      "end_time": $end_time,
      "duration": $duration,
      "total_tests": $total_tests,
      "passed_tests": $passed_tests,
      "failed_tests": $failed_tests,
      "skipped_tests": $skipped_tests,
      "success_rate": $success_rate,
      "exit_code": $test_result
    },
EOF
    
    # Cleanup
    rm -f "$temp_results"
    
    return $test_result
}

run_unit_tests() {
    local overall_result=0
    
    print_header "GitHub Integration Unit Tests"
    
    # Run main GitHub integration tests
    if ! run_test_suite "GitHub Core Integration" "$TESTS_DIR/unit/test-github-integration.bats"; then
        overall_result=1
    fi
    
    # Run comment management tests
    if ! run_test_suite "GitHub Comments Management" "$TESTS_DIR/unit/test-github-comments.bats"; then
        overall_result=1
    fi
    
    # Run task integration tests
    if ! run_test_suite "GitHub Task Integration" "$TESTS_DIR/unit/test-github-task-integration.bats"; then
        overall_result=1
    fi
    
    return $overall_result
}

run_integration_tests() {
    local overall_result=0
    
    print_header "GitHub Integration Tests"
    
    # Run comprehensive integration tests
    if ! run_test_suite "GitHub-TaskQueue Integration" "$GITHUB_INTEGRATION_TESTS"; then
        overall_result=1
    fi
    
    return $overall_result
}

run_performance_tests() {
    print_section "Performance Testing"
    
    local start_time=$(date +%s)
    local start_memory=$(ps -o rss= -p $$ || echo 0)
    
    # Run performance-focused tests
    log "INFO" "Running performance benchmarks..."
    
    # Test GitHub API mock performance
    local api_start=$(date +%s%3N)  # milliseconds
    python3 -c "
import json
import time
# Simulate API call overhead
for i in range(100):
    data = {'test': f'iteration_{i}'}
    json.dumps(data)
    time.sleep(0.001)  # 1ms per operation
" 2>/dev/null || true
    
    local api_end=$(date +%s%3N)
    local api_duration=$((api_end - api_start))
    
    log "INFO" "API mock simulation: ${api_duration}ms for 100 operations"
    
    # Check memory usage
    local current_memory=$(ps -o rss= -p $$ || echo 0)
    local memory_diff=$((current_memory - start_memory))
    
    if [[ $memory_diff -gt $MAX_MEMORY_USAGE ]]; then
        log "WARN" "Memory usage increased by ${memory_diff}KB (threshold: ${MAX_MEMORY_USAGE}KB)"
    else
        log "SUCCESS" "Memory usage within acceptable limits: ${memory_diff}KB"
    fi
    
    local end_time=$(date +%s)
    local total_duration=$((end_time - start_time))
    
    log "INFO" "Performance testing completed in ${total_duration}s"
    
    # Add performance results to JSON
    cat >> "$RESULTS_FILE.tmp" << EOF
    {
      "suite": "Performance Tests",
      "start_time": $start_time,
      "end_time": $end_time,
      "duration": $total_duration,
      "api_mock_performance_ms": $api_duration,
      "memory_usage_kb": $memory_diff,
      "memory_within_limits": $([ $memory_diff -le $MAX_MEMORY_USAGE ] && echo "true" || echo "false")
    },
EOF
    
    return 0
}

generate_test_report() {
    print_section "Generating Test Report"
    
    # Create JSON report
    local timestamp=$(date -u -Iseconds)
    local session_end=$(date +%s)
    local session_start=$(grep "started at" "$LOG_FILE" | head -1 | grep -o '[0-9]\{10\}' || echo $session_end)
    local total_session_duration=$((session_end - session_start))
    
    cat > "$RESULTS_FILE" << EOF
{
  "test_session": {
    "runner": "$TEST_RUNNER_NAME",
    "version": "$TEST_RUNNER_VERSION",
    "timestamp": "$timestamp",
    "duration": $total_session_duration,
    "environment": {
      "test_mode": "${TEST_MODE:-false}",
      "debug_mode": "${DEBUG_MODE:-false}",
      "offline_mode": "${OFFLINE_MODE:-false}",
      "github_mock_mode": "${GITHUB_MOCK_MODE:-false}"
    }
  },
  "results": [
$(cat "$RESULTS_FILE.tmp" | sed '$ s/,$//')
  ]
}
EOF
    
    # Calculate overall statistics
    local total_tests=0
    local total_passed=0
    local total_failed=0
    local total_skipped=0
    
    if [[ -f "$RESULTS_FILE" ]]; then
        total_tests=$(jq '[.results[] | .total_tests // 0] | add' "$RESULTS_FILE" 2>/dev/null || echo 0)
        total_passed=$(jq '[.results[] | .passed_tests // 0] | add' "$RESULTS_FILE" 2>/dev/null || echo 0)
        total_failed=$(jq '[.results[] | .failed_tests // 0] | add' "$RESULTS_FILE" 2>/dev/null || echo 0)
        total_skipped=$(jq '[.results[] | .skipped_tests // 0] | add' "$RESULTS_FILE" 2>/dev/null || echo 0)
    fi
    
    local overall_success_rate=0
    if [[ $total_tests -gt 0 ]]; then
        overall_success_rate=$(( (total_passed * 100) / total_tests ))
    fi
    
    # Display summary
    print_header "GitHub Integration Test Summary"
    
    echo -e "📊 ${WHITE}Test Statistics:${NC}"
    echo -e "   Total Tests:    ${CYAN}$total_tests${NC}"
    echo -e "   Passed:         ${GREEN}$total_passed${NC}"
    echo -e "   Failed:         ${RED}$total_failed${NC}"
    echo -e "   Skipped:        ${YELLOW}$total_skipped${NC}"
    echo -e "   Success Rate:   ${GREEN}$overall_success_rate%${NC}"
    echo -e "   Duration:       ${BLUE}${total_session_duration}s${NC}"
    echo
    
    echo -e "📁 ${WHITE}Output Files:${NC}"
    echo -e "   Log File:       $LOG_FILE"
    echo -e "   Results:        $RESULTS_FILE"
    echo
    
    # Quality assessment
    if [[ $overall_success_rate -ge $MIN_SUCCESS_RATE ]] && [[ $total_failed -eq 0 ]]; then
        log "SUCCESS" "GitHub Integration Module: A+ Rating (${overall_success_rate}% success rate)"
        echo -e "🏆 ${GREEN}Quality Rating: A+ (Excellent)${NC}"
        return 0
    elif [[ $overall_success_rate -ge 90 ]]; then
        log "SUCCESS" "GitHub Integration Module: A Rating (${overall_success_rate}% success rate)"
        echo -e "🥇 ${GREEN}Quality Rating: A (Very Good)${NC}"
        return 0
    elif [[ $overall_success_rate -ge 80 ]]; then
        log "WARN" "GitHub Integration Module: B Rating (${overall_success_rate}% success rate)"
        echo -e "🥈 ${YELLOW}Quality Rating: B (Good)${NC}"
        return 1
    else
        log "ERROR" "GitHub Integration Module: C Rating (${overall_success_rate}% success rate)"
        echo -e "🥉 ${RED}Quality Rating: C (Needs Improvement)${NC}"
        return 1
    fi
    
    # Cleanup
    rm -f "$RESULTS_FILE.tmp"
}

# ===============================================================================
# MAIN EXECUTION LOGIC
# ===============================================================================

show_help() {
    cat << EOF
$TEST_RUNNER_NAME v$TEST_RUNNER_VERSION

USAGE:
    $0 [OPTIONS] [TEST_TYPE]

OPTIONS:
    -h, --help              Show this help message
    -v, --verbose           Enable verbose output
    -d, --debug             Enable debug mode
    -q, --quiet             Minimize output
    --xml                   Generate XML output for CI/CD
    --performance           Include performance benchmarks
    --no-cleanup            Skip cleanup after tests

TEST_TYPES:
    unit                    Run only unit tests (default)
    integration             Run only integration tests
    all                     Run all tests
    performance             Run performance tests only

EXAMPLES:
    $0                      # Run unit tests
    $0 all                  # Run all tests
    $0 --debug integration  # Run integration tests with debug output
    $0 --xml --performance  # Run with XML output and performance tests

ENVIRONMENT VARIABLES:
    DEBUG_MODE              Enable debug logging (true/false)
    OFFLINE_MODE            Run in offline mode (true/false)
    MAX_TEST_DURATION       Maximum test duration in seconds (default: 300)
    MIN_SUCCESS_RATE        Minimum success rate for A rating (default: 95)

EOF
}

main() {
    local test_type="unit"
    local include_performance="false"
    local verbose="false"
    local quiet="false"
    local no_cleanup="false"
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--verbose)
                export DEBUG_MODE="true"
                verbose="true"
                shift
                ;;
            -d|--debug)
                export DEBUG_MODE="true"
                shift
                ;;
            -q|--quiet)
                quiet="true"
                shift
                ;;
            --xml)
                export XML_OUTPUT="true"
                shift
                ;;
            --performance)
                include_performance="true"
                shift
                ;;
            --no-cleanup)
                no_cleanup="true"
                shift
                ;;
            unit|integration|all|performance)
                test_type="$1"
                shift
                ;;
            *)
                log "ERROR" "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    # Adjust logging based on verbosity
    if [[ "$quiet" == "true" ]]; then
        exec 1>/dev/null
    fi
    
    # Initialize
    print_header "GitHub Integration Module Test Suite"
    
    if ! check_dependencies; then
        exit 1
    fi
    
    setup_test_environment
    
    # Initialize results file
    echo "" > "$RESULTS_FILE.tmp"
    
    local overall_result=0
    
    # Execute tests based on type
    case "$test_type" in
        "unit")
            if ! run_unit_tests; then
                overall_result=1
            fi
            ;;
        "integration")
            if ! run_integration_tests; then
                overall_result=1
            fi
            ;;
        "all")
            if ! run_unit_tests; then
                overall_result=1
            fi
            if ! run_integration_tests; then
                overall_result=1
            fi
            ;;
        "performance")
            include_performance="true"
            ;;
        *)
            log "ERROR" "Invalid test type: $test_type"
            exit 1
            ;;
    esac
    
    # Run performance tests if requested
    if [[ "$include_performance" == "true" ]]; then
        if ! run_performance_tests; then
            overall_result=1
        fi
    fi
    
    # Generate final report
    if ! generate_test_report; then
        overall_result=1
    fi
    
    # Cleanup
    if [[ "$no_cleanup" != "true" ]]; then
        rm -f "$RESULTS_FILE.tmp" 2>/dev/null || true
        log "INFO" "Cleanup completed"
    fi
    
    # Final status
    if [[ $overall_result -eq 0 ]]; then
        log "SUCCESS" "All GitHub Integration tests passed successfully!"
    else
        log "ERROR" "Some GitHub Integration tests failed. Check the results above."
    fi
    
    exit $overall_result
}

# Execute main function with all arguments
main "$@"