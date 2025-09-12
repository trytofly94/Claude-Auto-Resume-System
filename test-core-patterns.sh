#!/usr/bin/env bash

# Test Core Usage Limit Patterns for Live Operation
# Focus on the most common Claude CLI responses for production readiness

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load the usage limit recovery module
source "$SCRIPT_DIR/src/usage-limit-recovery.sh"

echo "🧪 Testing Core Usage Limit Patterns for Live Operation"
echo "======================================================"
echo ""

# Core test cases that matter for live operation
declare -A CORE_TESTS=(
    ["basic_pm"]="You're blocked until 3pm"
    ["basic_am"]="Try again at 9am"
    ["with_minutes"]="Available at 2:30pm"  
    ["usage_limit"]="Usage limit exceeded"
    ["rate_limit"]="Rate limit reached"
    ["too_many_requests"]="Too many requests"
    ["retry_later"]="Please try again later"
)

echo "Testing basic usage limit detection (detect_usage_limit_in_queue):"
echo "----------------------------------------------------------------"

passed=0
total=0

for test_name in "${!CORE_TESTS[@]}"; do
    ((total++))
    echo -n "Testing '$test_name': "
    
    if detect_usage_limit_in_queue "${CORE_TESTS[$test_name]}" "test-task-$total"; then
        echo "✅ DETECTED"
        ((passed++))
    else
        echo "❌ NOT DETECTED"
    fi
done

echo ""
echo "Results: $passed/$total tests passed"
echo ""

# Test time extraction for pm/am patterns
echo "Testing time-specific extraction:"
echo "--------------------------------"

time_tests=(
    "blocked until 3pm"
    "try again at 9am"  
    "available at 2:30pm"
    "retry at 11:45am"
)

time_passed=0
time_total=${#time_tests[@]}

for test_input in "${time_tests[@]}"; do
    echo -n "Testing '$test_input': "
    
    if wait_time=$(extract_usage_limit_time_enhanced "$test_input"); then
        if [[ -n "$wait_time" && "$wait_time" =~ ^[0-9]+$ ]]; then
            hours=$((wait_time / 3600))
            minutes=$(((wait_time % 3600) / 60))
            echo "✅ ${wait_time}s (${hours}h ${minutes}m)"
            ((time_passed++))
        else
            echo "❌ Invalid time: '$wait_time'"
        fi
    else
        echo "❌ No time extracted"
    fi
done

echo ""
echo "Time extraction results: $time_passed/$time_total tests passed"
echo ""

# Test countdown functionality
echo "Testing enhanced countdown display (5 second test):"
echo "--------------------------------------------------"

echo "Starting 5-second countdown test..."
display_enhanced_usage_limit_countdown 5 "test_pattern" &
countdown_pid=$!

# Wait for countdown to complete
sleep 6

# Check if countdown completed
if ! kill -0 $countdown_pid 2>/dev/null; then
    echo "✅ Countdown completed successfully"
    countdown_passed=1
else
    echo "❌ Countdown still running"
    kill $countdown_pid 2>/dev/null || true
    countdown_passed=0
fi

echo ""

# Overall results
total_all=$((total + time_total + 1))
passed_all=$((passed + time_passed + countdown_passed))

echo "=========================================="
echo "CORE LIVE OPERATION TEST RESULTS:"
echo "  Basic Detection: $passed/$total"
echo "  Time Extraction: $time_passed/$time_total"  
echo "  Countdown Test:  $countdown_passed/1"
echo "  Overall:         $passed_all/$total_all"
echo "  Success Rate:    $(( (passed_all * 100) / total_all ))%"
echo "=========================================="

if [[ $passed_all -eq $total_all ]]; then
    echo "🎉 All core functionality tests passed!"
    echo "✅ System is ready for live operation testing"
    exit 0
else
    echo "⚠️ Some core functionality failed"
    echo "❌ Review issues before live deployment"
    exit 1
fi