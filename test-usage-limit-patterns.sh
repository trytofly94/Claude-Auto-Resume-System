#!/usr/bin/env bash

# Test Enhanced Usage Limit Detection
# Tests the comprehensive pattern matching implemented in usage-limit-recovery.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"

# Load the usage limit recovery module
source "$SCRIPT_DIR/src/usage-limit-recovery.sh"

# Test cases for enhanced pattern detection
declare -A TEST_CASES=(
    # Basic pm/am formats
    ["blocked_3pm"]="You're blocked until 3pm. Please try again later."
    ["blocked_330pm"]="You're blocked until 3:30pm. Please try again later."
    ["try_again_5am"]="Please try again at 5am."
    ["try_again_1130am"]="Please try again at 11:30am."
    ["available_9pm"]="Service will be available at 9pm."
    ["available_630pm"]="Service will be available at 6:30pm."
    
    # Tomorrow patterns
    ["tomorrow_2pm"]="Please try tomorrow at 2pm."
    ["tomorrow_845am"]="Available tomorrow at 8:45am."
    ["tomorrow_12pm"]="Try tomorrow at 12pm."
    
    # 24-hour formats
    ["24h_1500"]="System available at 15:00."
    ["24h_0830"]="Service resumes at 08:30."
    ["24h_2145"]="Retry at 21:45."
    
    # Duration-based patterns
    ["duration_2h"]="Please retry in 2 hours."
    ["duration_3h"]="Wait 3 more hours before trying again."
    ["duration_1h"]="Available in 1 hour."
    
    # Natural language patterns
    ["usage_limit_8pm"]="Usage limit exceeded. Try again at 8pm."
    ["rate_limit_noon"]="Rate limit reached. Available at 12pm."
    ["quota_exceeded_10am"]="Daily quota exceeded until 10am tomorrow."
    
    # Edge cases
    ["mixed_case"]="BLOCKED UNTIL 4PM. Please try again."
    ["extra_spaces"]="  Try again at   7:30pm   tomorrow  ."
    ["punctuation"]="Sorry! You're blocked until 9:15am, please wait."
)

echo "🧪 Testing Enhanced Usage Limit Detection Patterns"
echo "=================================================="
echo ""

# Test results tracking
declare -i passed_tests=0
declare -i failed_tests=0
declare -i total_tests=${#TEST_CASES[@]}

# Run tests
for test_name in "${!TEST_CASES[@]}"; do
    echo "Testing: $test_name"
    echo "Input: ${TEST_CASES[$test_name]}"
    
    # Test the enhanced extraction function
    if wait_time=$(extract_usage_limit_time_enhanced "${TEST_CASES[$test_name]}"); then
        if [[ -n "$wait_time" && "$wait_time" =~ ^[0-9]+$ ]]; then
            # Calculate human-readable time
            local hours=$((wait_time / 3600))
            local minutes=$(((wait_time % 3600) / 60))
            echo "✅ Pattern detected - Wait time: ${wait_time}s (${hours}h ${minutes}m)"
            ((passed_tests++))
        else
            echo "❌ Invalid wait time returned: '$wait_time'"
            ((failed_tests++))
        fi
    else
        echo "❌ Pattern not detected"
        ((failed_tests++))
    fi
    echo ""
done

# Test edge cases that should NOT match
echo "Testing negative cases (should not match):"
echo "----------------------------------------"

declare -A NEGATIVE_CASES=(
    ["no_time"]="Usage limit exceeded. Please try again later."
    ["invalid_time"]="Blocked until 25pm."
    ["no_period"]="Try again at 3."
    ["random_text"]="This is just random text with no time patterns."
)

for test_name in "${!NEGATIVE_CASES[@]}"; do
    echo "Testing: $test_name"
    echo "Input: ${NEGATIVE_CASES[$test_name]}"
    
    if wait_time=$(extract_usage_limit_time_enhanced "${NEGATIVE_CASES[$test_name]}"); then
        echo "❌ Should not have matched but returned: '$wait_time'"
        ((failed_tests++))
    else
        echo "✅ Correctly rejected pattern"
        ((passed_tests++))
    fi
    echo ""
    ((total_tests++))
done

# Final results
echo "=========================================="
echo "Test Results Summary:"
echo "  Passed: $passed_tests"
echo "  Failed: $failed_tests"
echo "  Total:  $total_tests"
echo "  Success Rate: $(( (passed_tests * 100) / total_tests ))%"
echo "=========================================="

if [[ $failed_tests -eq 0 ]]; then
    echo "🎉 All tests passed! Enhanced pattern detection is working correctly."
    exit 0
else
    echo "⚠️ Some tests failed. Please review the pattern matching logic."
    exit 1
fi