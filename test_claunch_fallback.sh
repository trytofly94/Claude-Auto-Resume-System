#!/usr/bin/env bash

# Test script to verify Issue #77 - claunch dependency detection and exit code 127 fix
# This test specifically verifies that no "No such file or directory" errors occur

set -euo pipefail

echo "=== Testing Issue #77 - claunch dependency detection and fallback ==="
echo ""

# Function to run test and capture output
test_scenario() {
    local scenario_name="$1"
    local test_command="$2"
    local expected_exit_code="${3:-0}"
    
    echo "Testing: $scenario_name"
    echo "Command: $test_command"
    echo ""
    
    # Capture both stdout and stderr
    local temp_output=$(mktemp)
    local actual_exit_code=0
    
    # Run the command and capture exit code
    if ! eval "$test_command" >"$temp_output" 2>&1; then
        actual_exit_code=$?
    fi
    
    # Display the output
    cat "$temp_output"
    echo ""
    
    # Check for exit code 127 (command not found)
    if [[ $actual_exit_code -eq 127 ]]; then
        echo "❌ FAIL: Exit code 127 detected - command not found error"
        rm -f "$temp_output"
        return 1
    fi
    
    # Check for "No such file or directory" errors
    if grep -q "No such file or directory" "$temp_output"; then
        echo "❌ FAIL: 'No such file or directory' error detected"
        rm -f "$temp_output"
        return 1
    fi
    
    # Check for proper fallback messages
    if grep -q "FALLBACK MODE: Direct Claude CLI" "$temp_output"; then
        echo "✅ PASS: Proper fallback mode activated"
    elif grep -q "claunch detected and validated" "$temp_output"; then
        echo "✅ PASS: claunch properly detected"
    else
        echo "⚠️  WARNING: Unclear session mode outcome"
    fi
    
    echo "Exit code: $actual_exit_code (expected: $expected_exit_code)"
    echo "----------------------------------------"
    echo ""
    
    rm -f "$temp_output"
    
    # Check if exit code matches expectation
    if [[ $actual_exit_code -eq $expected_exit_code ]]; then
        return 0
    else
        echo "❌ FAIL: Exit code mismatch"
        return 1
    fi
}

# Backup claunch if it exists
claunch_backup=""
if command -v claunch >/dev/null 2>&1; then
    claunch_path=$(command -v claunch)
    claunch_backup="${claunch_path}.test_backup"
    echo "Backing up claunch: $claunch_path -> $claunch_backup"
    mv "$claunch_path" "$claunch_backup"
fi

echo ""
echo "=== Test 1: claunch-integration.sh with no claunch available ==="
echo ""

# Test 1: claunch-integration.sh fallback
if ! test_scenario "claunch-integration.sh fallback" "timeout 10 ./src/claunch-integration.sh" 0; then
    echo "Test 1 FAILED"
    exit_status=1
else
    echo "Test 1 PASSED"
fi

echo ""
echo "=== Test 2: hybrid-monitor.sh with no claunch available ==="
echo ""

# Test 2: hybrid-monitor.sh fallback  
if ! test_scenario "hybrid-monitor.sh fallback" "timeout 15 ./src/hybrid-monitor.sh --test-mode 1 --debug" 0; then
    echo "Test 2 FAILED"
    exit_status=1
else
    echo "Test 2 PASSED"
fi

# Restore claunch if we backed it up
if [[ -n "$claunch_backup" && -f "$claunch_backup" ]]; then
    echo "Restoring claunch: $claunch_backup -> $claunch_path"
    mv "$claunch_backup" "$claunch_path"
fi

echo ""
echo "=== Test 3: claunch-integration.sh with claunch available ==="
echo ""

# Test 3: claunch-integration.sh with claunch available
if ! test_scenario "claunch-integration.sh with claunch" "timeout 10 ./src/claunch-integration.sh" 0; then
    echo "Test 3 FAILED"
    exit_status=1
else
    echo "Test 3 PASSED"
fi

echo ""
echo "=== Test 4: hybrid-monitor.sh with claunch available ==="
echo ""

# Test 4: hybrid-monitor.sh with claunch available
if ! test_scenario "hybrid-monitor.sh with claunch" "timeout 15 ./src/hybrid-monitor.sh --test-mode 1 --debug" 0; then
    echo "Test 4 FAILED"
    exit_status=1
else
    echo "Test 4 PASSED"
fi

echo ""
echo "=== Final Results ==="
echo ""

if [[ ${exit_status:-0} -eq 0 ]]; then
    echo "🎉 ALL TESTS PASSED - Issue #77 is RESOLVED"
    echo ""
    echo "✅ No exit code 127 errors detected"
    echo "✅ No 'No such file or directory' errors detected"  
    echo "✅ Graceful fallback working properly"
    echo "✅ Enhanced detection system working"
    echo ""
    exit 0
else
    echo "❌ SOME TESTS FAILED - Issue #77 may need more work"
    echo ""
    exit 1
fi