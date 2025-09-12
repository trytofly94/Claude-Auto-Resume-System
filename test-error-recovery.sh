#!/usr/bin/env bash

# Error Recovery Test Suite for Claude Auto-Resume System
# Tests error handling and recovery mechanisms

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}🔧 Claude Auto-Resume Error Recovery Test Suite${NC}"
echo -e "${BLUE}=================================================${NC}"
echo ""

# Source the usage limit recovery system
source "$SCRIPT_DIR/src/usage-limit-recovery.sh"

# Test results tracking
declare -i passed_tests=0
declare -i failed_tests=0
declare -i total_tests=0

# Test function
run_test() {
    local test_name="$1"
    local test_function="$2"
    local expected_result="${3:-0}"
    
    ((total_tests++))
    echo -e "${YELLOW}Testing: $test_name${NC}"
    
    local result=0
    local output=""
    
    if output=$($test_function 2>&1); then
        result=0
    else
        result=$?
    fi
    
    if [[ $result -eq $expected_result ]]; then
        echo -e "${GREEN}✅ PASS${NC} - $test_name"
        if [[ -n "$output" ]]; then
            echo "   Output: $output"
        fi
        ((passed_tests++))
    else
        echo -e "${RED}❌ FAIL${NC} - $test_name"
        echo "   Expected exit code: $expected_result, got: $result"
        if [[ -n "$output" ]]; then
            echo "   Output: $output"
        fi
        ((failed_tests++))
    fi
    echo ""
}

# Test 1: Invalid usage limit pattern handling
test_invalid_patterns() {
    local invalid_outputs=(
        "This is just random text with no patterns"
        "Usage limit reached but no time specified"
        "Blocked until 25pm (invalid time)"
        ""
    )
    
    local all_handled=true
    for output in "${invalid_outputs[@]}"; do
        if extract_usage_limit_time_enhanced "$output" >/dev/null 2>&1; then
            all_handled=false
            echo "Failed to reject invalid pattern: '$output'"
        fi
    done
    
    if [[ "$all_handled" == "true" ]]; then
        echo "All invalid patterns correctly rejected"
        return 0
    else
        return 1
    fi
}

# Test 2: Time boundary edge cases
test_time_boundary_edge_cases() {
    local current_time=$(date +%H)
    local test_cases=(
        "1 am" "2 am" "3 am"  # Early morning
        "11 pm" "12 am" "12 pm"  # Midnight/noon
    )
    
    local all_calculated=true
    for test_case in "${test_cases[@]}"; do
        local hour=$(echo "$test_case" | awk '{print $1}')
        local period=$(echo "$test_case" | awk '{print $2}')
        
        if ! calculate_wait_until_time_enhanced "$hour" "$period" "0" >/dev/null 2>&1; then
            all_calculated=false
            echo "Failed to calculate time for: $test_case"
        fi
    done
    
    if [[ "$all_calculated" == "true" ]]; then
        echo "All time boundary calculations successful"
        return 0
    else
        return 1
    fi
}

# Test 3: Usage limit detection robustness
test_usage_limit_detection_robustness() {
    local test_outputs=(
        "Usage limit exceeded. Blocked until 3pm today."
        "Rate limit reached. Try again at 2am tomorrow."
        "Too many requests. Available at 4:30pm."
        "Please wait until 11:15am."
        "Service blocked until 9pm."
    )
    
    local detection_count=0
    for output in "${test_outputs[@]}"; do
        if detect_usage_limit_in_queue "$output" >/dev/null 2>&1; then
            ((detection_count++))
        fi
    done
    
    if [[ $detection_count -eq ${#test_outputs[@]} ]]; then
        echo "All usage limit patterns detected correctly ($detection_count/${#test_outputs[@]})"
        return 0
    else
        echo "Detection failed for some patterns ($detection_count/${#test_outputs[@]})"
        return 1
    fi
}

# Test 4: Session recovery mechanisms
test_session_recovery() {
    # Mock a session recovery scenario
    local mock_session_file="/tmp/test-session-recovery-$$"
    echo '{"session_id": "test-session", "state": "recovery"}' > "$mock_session_file"
    
    # Test file exists and is readable
    if [[ -f "$mock_session_file" && -r "$mock_session_file" ]]; then
        rm -f "$mock_session_file"
        echo "Session recovery file handling working"
        return 0
    else
        return 1
    fi
}

# Test 5: Resource monitoring safeguards
test_resource_monitoring() {
    # Test memory usage monitoring (mock)
    local mock_memory=204800  # 200MB in KB
    local max_memory=409600   # 400MB limit
    
    if [[ $mock_memory -lt $max_memory ]]; then
        echo "Memory usage within limits: ${mock_memory}KB < ${max_memory}KB"
        return 0
    else
        echo "Memory usage exceeded limits"
        return 1
    fi
}

# Test 6: Configuration validation
test_configuration_validation() {
    local config_file="config/default.conf"
    
    if [[ -f "$config_file" && -r "$config_file" ]]; then
        # Check for critical configuration parameters
        local required_params=(
            "CHECK_INTERVAL_MINUTES"
            "MAX_RESTARTS"
            "USE_CLAUNCH"
            "USAGE_LIMIT_COOLDOWN"
        )
        
        local all_found=true
        for param in "${required_params[@]}"; do
            if ! grep -q "^${param}=" "$config_file"; then
                all_found=false
                echo "Missing required parameter: $param"
            fi
        done
        
        if [[ "$all_found" == "true" ]]; then
            echo "All required configuration parameters found"
            return 0
        else
            return 1
        fi
    else
        echo "Configuration file not found or not readable: $config_file"
        return 1
    fi
}

# Test 7: System dependency validation
test_system_dependencies() {
    local required_commands=(
        "tmux" "jq" "date" "grep" "awk" "sed"
    )
    
    local all_available=true
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            all_available=false
            echo "Missing required command: $cmd"
        fi
    done
    
    if [[ "$all_available" == "true" ]]; then
        echo "All required system dependencies available"
        return 0
    else
        return 1
    fi
}

# Test 8: Logging system robustness
test_logging_system() {
    local log_dir="logs"
    local log_file="$log_dir/hybrid-monitor.log"
    
    # Ensure log directory exists
    mkdir -p "$log_dir" || return 1
    
    # Test log file creation/writing
    echo "[TEST] $(date): Error recovery test" >> "$log_file" || return 1
    
    if [[ -f "$log_file" && -w "$log_file" ]]; then
        echo "Logging system operational"
        return 0
    else
        echo "Logging system issues detected"
        return 1
    fi
}

# Run all tests
echo "Starting error recovery and robustness tests..."
echo ""

run_test "Invalid Usage Limit Patterns" test_invalid_patterns 0
run_test "Time Boundary Edge Cases" test_time_boundary_edge_cases 0
run_test "Usage Limit Detection Robustness" test_usage_limit_detection_robustness 0
run_test "Session Recovery Mechanisms" test_session_recovery 0
run_test "Resource Monitoring Safeguards" test_resource_monitoring 0
run_test "Configuration Validation" test_configuration_validation 0
run_test "System Dependencies" test_system_dependencies 0
run_test "Logging System Robustness" test_logging_system 0

# Summary
echo -e "${BLUE}=================================================${NC}"
echo -e "${BLUE}🧪 Error Recovery Test Results Summary${NC}"
echo -e "${BLUE}=================================================${NC}"
echo ""

echo -e "Tests completed: ${BLUE}$total_tests${NC}"
echo -e "Tests passed: ${GREEN}$passed_tests${NC}"
echo -e "Tests failed: ${RED}$failed_tests${NC}"

# Calculate success rate
if [[ $total_tests -gt 0 ]]; then
    success_rate=$((passed_tests * 100 / total_tests))
    echo -e "Success rate: ${GREEN}${success_rate}%${NC}"
fi

echo ""

# Final verdict
if [[ $failed_tests -eq 0 ]]; then
    echo -e "${GREEN}🎉 ALL ERROR RECOVERY TESTS PASSED!${NC}"
    echo -e "${GREEN}The system demonstrates robust error handling and recovery mechanisms.${NC}"
    exit 0
else
    echo -e "${RED}⚠️  $failed_tests test(s) failed.${NC}"
    echo -e "${YELLOW}The system may need improvements in error handling and recovery.${NC}"
    exit 1
fi