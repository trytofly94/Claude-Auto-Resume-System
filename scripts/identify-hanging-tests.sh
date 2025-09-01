#!/usr/bin/env bash

# Script to identify hanging tests that are causing timeouts
# Phase 1 of Issue #84 comprehensive test suite reliability fixes

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== Identifying Hanging Tests ==="
echo "Project: $PROJECT_ROOT"
echo "Date: $(date)"
echo

# Test timeout for individual files (shorter to identify hanging tests)
TEST_TIMEOUT=30
RESULTS_FILE="$PROJECT_ROOT/hanging-test-results.txt"

# Clear previous results
> "$RESULTS_FILE"

echo "Testing individual test files with ${TEST_TIMEOUT}s timeout..."
echo

# Function to test individual files
test_individual_file() {
    local test_file="$1"
    local basename_file=$(basename "$test_file")
    
    echo "Testing: $basename_file"
    local start_time=$(date +%s)
    
    local status=0
    local output=""
    
    if output=$(timeout "$TEST_TIMEOUT" bats "$test_file" --tap 2>&1); then
        status=0
        local result="PASS"
    else
        status=$?
        if [[ $status -eq 124 ]]; then
            result="TIMEOUT"
        else
            result="FAIL"
        fi
    fi
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    echo "  Status: $result (${duration}s)"
    
    # Log detailed results
    cat >> "$RESULTS_FILE" << EOF
FILE: $basename_file
STATUS: $result ($status)
DURATION: ${duration}s
OUTPUT: $output

---

EOF
    
    return $status
}

# Test all unit tests first
echo "=== Unit Tests ==="
unit_tests_passed=0
unit_tests_failed=0
unit_tests_timeout=0

if [[ -d "$PROJECT_ROOT/tests/unit" ]]; then
    for test_file in "$PROJECT_ROOT/tests/unit"/*.bats; do
        if [[ -f "$test_file" ]]; then
            if test_individual_file "$test_file"; then
                ((unit_tests_passed++))
            else
                case $? in
                    124) ((unit_tests_timeout++)) ;;
                    *) ((unit_tests_failed++)) ;;
                esac
            fi
        fi
    done
else
    echo "Unit tests directory not found"
fi

echo
echo "Unit Tests Summary:"
echo "  Passed: $unit_tests_passed"
echo "  Failed: $unit_tests_failed"
echo "  Timeout: $unit_tests_timeout"
echo

# Test some integration tests (limited due to time)
echo "=== Integration Tests (Sample) ==="
integration_tests_passed=0
integration_tests_failed=0
integration_tests_timeout=0

if [[ -d "$PROJECT_ROOT/tests/integration" ]]; then
    # Test only first 3 integration tests to avoid long runtime
    test_files=()
    mapfile -t test_files < <(find "$PROJECT_ROOT/tests/integration" -name "*.bats" | head -3)
    for test_file in "${test_files[@]}"; do
        if [[ -f "$test_file" ]]; then
            if test_individual_file "$test_file"; then
                ((integration_tests_passed++))
            else
                case $? in
                    124) ((integration_tests_timeout++)) ;;
                    *) ((integration_tests_failed++)) ;;
                esac
            fi
        fi
    done
else
    echo "Integration tests directory not found"
fi

echo
echo "Integration Tests Summary (sample):"
echo "  Passed: $integration_tests_passed"
echo "  Failed: $integration_tests_failed"
echo "  Timeout: $integration_tests_timeout"
echo

# Overall summary
total_passed=$((unit_tests_passed + integration_tests_passed))
total_failed=$((unit_tests_failed + integration_tests_failed))
total_timeout=$((unit_tests_timeout + integration_tests_timeout))
total_tests=$((total_passed + total_failed + total_timeout))

echo "=== OVERALL SUMMARY ==="
echo "Total Tests: $total_tests"
echo "Passed: $total_passed"
echo "Failed: $total_failed"
echo "Timeout: $total_timeout"
echo

if [[ $total_timeout -gt 0 ]]; then
    echo "⚠️  HANGING TESTS DETECTED: $total_timeout tests timed out"
    echo "These tests are likely causing the full test suite timeouts"
    echo
    echo "Detailed results saved to: $RESULTS_FILE"
    echo
    echo "Next steps:"
    echo "1. Review timeout tests in detail"
    echo "2. Fix or optimize hanging operations"
    echo "3. Add per-test timeout mechanisms"
else
    echo "✅ No hanging tests detected in sample"
fi

echo
echo "Analysis complete: $(date)"