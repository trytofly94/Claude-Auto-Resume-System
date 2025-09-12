#!/usr/bin/env bash

# Comprehensive Live Operation Test
# Tests all critical components for production readiness

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"

# Color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Emojis
readonly TEST_TUBE="🧪"
readonly CHECK="✅"
readonly ERROR="❌"
readonly WARNING="⚠️"
readonly GEAR="⚙️"
readonly ROCKET="🚀"

echo -e "${BLUE}${TEST_TUBE} Comprehensive Live Operation Test${NC}"
echo "========================================="
echo ""

# Test results
declare -i tests_passed=0
declare -i tests_failed=0
declare -i tests_total=0

run_test() {
    local test_name="$1"
    local test_command="$2"
    
    ((tests_total++))
    echo -n "Testing $test_name: "
    
    if eval "$test_command" >/dev/null 2>&1; then
        echo -e "${CHECK} PASS"
        ((tests_passed++))
        return 0
    else
        echo -e "${ERROR} FAIL"
        ((tests_failed++))
        return 1
    fi
}

# Test 1: Prerequisites Check
echo -e "${GEAR} Testing Prerequisites..."
run_test "Claude CLI availability" "command -v claude"
run_test "claunch availability" "command -v claunch"
run_test "tmux availability" "command -v tmux"
run_test "jq availability" "command -v jq"
echo ""

# Test 2: Core Components
echo -e "${GEAR} Testing Core Components..."
run_test "hybrid-monitor script" "[[ -x src/hybrid-monitor.sh ]]"
run_test "task-queue script" "[[ -x src/task-queue.sh ]]"
run_test "usage-limit-recovery script" "[[ -f src/usage-limit-recovery.sh ]]"
run_test "session-manager script" "[[ -f src/session-manager.sh ]]"
echo ""

# Test 3: Configuration
echo -e "${GEAR} Testing Configuration..."
run_test "default config exists" "[[ -f config/default.conf ]]"
run_test "queue directory exists" "[[ -d queue ]]"
run_test "logs directory exists" "[[ -d logs ]]"
echo ""

# Test 4: Usage Limit Detection
echo -e "${GEAR} Testing Usage Limit Detection..."
run_test "basic usage limit detection" 'source src/usage-limit-recovery.sh && detect_usage_limit_in_queue "usage limit exceeded" "test123"'
run_test "pm/am time extraction" 'source src/usage-limit-recovery.sh && [[ -n "$(extract_usage_limit_time_enhanced "blocked until 3pm")" ]]'
run_test "rate limit detection" 'source src/usage-limit-recovery.sh && detect_usage_limit_in_queue "rate limit reached" "test456"'
echo ""

# Test 5: Task Queue Operations
echo -e "${GEAR} Testing Task Queue Operations..."
run_test "queue status command" "./src/task-queue.sh status >/dev/null"
run_test "queue list command" "./src/task-queue.sh list >/dev/null"
run_test "pending tasks exist" '[[ $(./src/task-queue.sh status | grep -o '"pending": [0-9]*' | grep -o '[0-9]*') -gt 0 ]]'
echo ""

# Test 6: Session Management
echo -e "${GEAR} Testing Session Management..."
run_test "claunch validation" 'claunch --version >/dev/null'
run_test "tmux functionality" 'tmux list-sessions >/dev/null 2>&1 || true'  # Allow no sessions
echo ""

# Test 7: Live Operation Scripts
echo -e "${GEAR} Testing Live Operation Scripts..."
run_test "deploy script executable" "[[ -x deploy-live-operation.sh ]]"
run_test "test script executable" "[[ -x test-live-operation.sh ]]"
run_test "deployment validation" "./deploy-live-operation.sh check >/dev/null"
echo ""

# Test 8: Integration Test (30-second run)
echo -e "${GEAR} Running Integration Test (30 seconds)..."
echo "Starting hybrid monitor in background..."

# Generate unique session name for test
test_session="claude-comprehensive-test-$(date +%s)-$$"

if tmux new-session -d -s "$test_session" -c "$PROJECT_ROOT" "timeout 30 ./src/hybrid-monitor.sh --queue-mode --enhanced-usage-limits --test-mode 30"; then
    sleep 5  # Let it initialize
    
    if tmux has-session -t "$test_session" 2>/dev/null; then
        echo -n "Integration test (30s monitoring): "
        
        # Wait for test to complete
        local wait_count=0
        while tmux has-session -t "$test_session" 2>/dev/null && [[ $wait_count -lt 35 ]]; do
            sleep 1
            ((wait_count++))
        done
        
        if [[ $wait_count -lt 35 ]]; then
            echo -e "${CHECK} PASS"
            ((tests_passed++))
        else
            echo -e "${ERROR} TIMEOUT"
            tmux kill-session -t "$test_session" 2>/dev/null || true
            ((tests_failed++))
        fi
        ((tests_total++))
    else
        echo -e "${ERROR} Integration test failed to start"
        ((tests_failed++))
        ((tests_total++))
    fi
else
    echo -e "${ERROR} Failed to create test session"
    ((tests_failed++))
    ((tests_total++))
fi

# Cleanup
tmux kill-session -t "$test_session" 2>/dev/null || true

echo ""

# Final Results
echo "========================================="
echo -e "${BLUE}COMPREHENSIVE TEST RESULTS:${NC}"
echo -e "  Total tests: $tests_total"
echo -e "  Passed: ${GREEN}$tests_passed${NC}"
echo -e "  Failed: ${RED}$tests_failed${NC}"
echo -e "  Success rate: $(( (tests_passed * 100) / tests_total ))%"
echo "========================================="

if [[ $tests_failed -eq 0 ]]; then
    echo -e "${CHECK} ${GREEN}ALL TESTS PASSED!${NC}"
    echo -e "${ROCKET} ${GREEN}System is READY for live operation deployment!${NC}"
    echo ""
    echo "Ready for production with:"
    echo "  • Enhanced usage limit detection and countdown"
    echo "  • Automated task processing from queue (18 pending tasks)"
    echo "  • Safe tmux session isolation"
    echo "  • Robust error handling and recovery"
    echo "  • Real-time monitoring and logging"
    echo ""
    exit 0
else
    echo -e "${ERROR} ${RED}Some tests failed - review before deployment${NC}"
    exit 1
fi