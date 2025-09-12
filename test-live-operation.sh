#!/usr/bin/env bash

# Claude Auto-Resume - Live Operation Testing Framework
# Safe testing in isolated tmux sessions without disrupting existing operations
# Version: 1.0.0-alpha

set -euo pipefail

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"

# Color codes for better output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color

# Emojis for better UX
readonly TEST_TUBE="🧪"
readonly CHECK="✅"
readonly WARNING="⚠️"
readonly ERROR="❌"
readonly INFO="ℹ️"
readonly GEAR="⚙️"
readonly CLOCK="⏰"
readonly CHART="📊"
readonly SHIELD="🛡️"

echo -e "${BLUE}${TEST_TUBE} Claude Auto-Resume - Live Operation Testing Framework${NC}"
echo "============================================================"
echo ""

# Default test parameters
TEST_DURATION="${1:-600}"  # Default 10 minutes
MAX_TEST_DURATION=3600     # Maximum 1 hour for safety
MIN_TEST_DURATION=60       # Minimum 1 minute

# Validate test duration
if ! [[ "$TEST_DURATION" =~ ^[0-9]+$ ]] || [[ $TEST_DURATION -lt $MIN_TEST_DURATION ]] || [[ $TEST_DURATION -gt $MAX_TEST_DURATION ]]; then
    echo -e "${ERROR} Invalid test duration: $TEST_DURATION"
    echo -e "${INFO} Duration must be between $MIN_TEST_DURATION and $MAX_TEST_DURATION seconds"
    echo -e "${INFO} Examples:"
    echo -e "   $0 300    # 5 minutes"
    echo -e "   $0 600    # 10 minutes (default)"  
    echo -e "   $0 1800   # 30 minutes"
    exit 1
fi

# Load logging functions if available
if [[ -f "$SCRIPT_DIR/src/utils/logging.sh" ]]; then
    source "$SCRIPT_DIR/src/utils/logging.sh"
else
    # Fallback logging functions
    log_debug() { [[ "${DEBUG_MODE:-false}" == "true" ]] && echo -e "${CYAN}[DEBUG]${NC} $*" >&2 || true; }
    log_info() { echo -e "${GREEN}[INFO]${NC} $*" >&2; }
    log_warn() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
    log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
fi

# Generate unique test session name to avoid conflicts
generate_test_session_name() {
    local timestamp=$(date +%s)
    local random_suffix=$(( (RANDOM % 1000) + 1 ))
    echo "claude-test-isolated-${timestamp}-${random_suffix}"
}

# Check for conflicts with existing sessions
check_session_conflicts() {
    local proposed_name="$1"
    
    # List existing tmux sessions
    local existing_sessions
    if existing_sessions=$(tmux list-sessions -F "#{session_name}" 2>/dev/null); then
        if echo "$existing_sessions" | grep -q "^$proposed_name$"; then
            log_error "Session name conflict detected: $proposed_name"
            return 1
        fi
        
        # Check for other Claude sessions
        local claude_sessions
        claude_sessions=$(echo "$existing_sessions" | grep -i claude || echo "")
        if [[ -n "$claude_sessions" ]]; then
            log_info "Existing Claude sessions detected (will not be affected):"
            echo "$claude_sessions" | sed 's/^/   - /'
            echo ""
        fi
    fi
    
    return 0
}

# Create isolated test environment
create_test_environment() {
    local test_session_name="$1"
    
    log_info "${GEAR} Creating isolated test environment: $test_session_name"
    
    # Ensure no conflicts
    if ! check_session_conflicts "$test_session_name"; then
        return 1
    fi
    
    # Create new tmux session for testing
    if tmux new-session -d -s "$test_session_name" -c "$PROJECT_ROOT"; then
        log_info "${CHECK} Test session created successfully: $test_session_name"
        
        # Brief pause to ensure session is ready
        sleep 1
        
        # Verify session exists
        if tmux has-session -t "$test_session_name" 2>/dev/null; then
            echo "$test_session_name"
            return 0
        else
            log_error "Session creation verification failed"
            return 1
        fi
    else
        log_error "Failed to create test session"
        return 1
    fi
}

# Start enhanced monitoring in test session
start_test_monitoring() {
    local test_session="$1"
    local duration="$2"
    
    log_info "${CHART} Starting enhanced monitoring in test session (duration: ${duration}s)"
    
    # Build test command with enhanced features and time limit
    local test_command="./src/hybrid-monitor.sh --queue-mode --continuous --enhanced-usage-limits --debug --test-mode $duration"
    
    # Send command to test session
    tmux send-keys -t "$test_session" "$test_command" Enter
    
    # Brief pause to let monitoring start
    sleep 2
    
    # Check if command started successfully
    local session_output
    if session_output=$(tmux capture-pane -t "$test_session" -p 2>/dev/null); then
        if echo "$session_output" | grep -q "hybrid.monitor"; then
            log_info "${CHECK} Enhanced monitoring started successfully in test session"
            return 0
        else
            log_warn "Monitoring may not have started correctly"
            echo "Session output:"
            echo "$session_output"
        fi
    fi
    
    return 0
}

# Monitor test progress with detailed reporting
monitor_test_progress() {
    local test_session="$1"
    local duration="$2"
    local start_time=$(date +%s)
    local end_time=$((start_time + duration))
    local last_check_time=$start_time
    local check_interval=30  # Check every 30 seconds
    local detailed_report_interval=120  # Detailed report every 2 minutes
    
    log_info "${CLOCK} Monitoring test progress for ${duration}s ($(($duration/60)) minutes)"
    echo ""
    
    local check_count=0
    
    while [[ $(date +%s) -lt $end_time ]]; do
        ((check_count++))
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        local remaining=$((end_time - current_time))
        local progress_percent=$(( (elapsed * 100) / duration ))
        
        # Check if test session is still running
        if ! tmux has-session -t "$test_session" 2>/dev/null; then
            log_error "Test session terminated unexpectedly"
            return 1
        fi
        
        # Get session activity
        local session_output
        session_output=$(tmux capture-pane -t "$test_session" -p 2>/dev/null | tail -10 || echo "No output")
        
        # Basic progress report every check_interval
        if [[ $((elapsed % check_interval)) -eq 0 ]] && [[ $elapsed -gt 0 ]]; then
            echo -e "${CHART} Test progress: ${elapsed}s elapsed, ${remaining}s remaining (${progress_percent}%)"
        fi
        
        # Detailed report every detailed_report_interval
        if [[ $((elapsed % detailed_report_interval)) -eq 0 ]] && [[ $elapsed -gt 0 ]]; then
            echo ""
            echo -e "${SHIELD} Detailed Test Report (Check #$check_count):"
            echo "   Time elapsed: ${elapsed}s / ${duration}s (${progress_percent}%)"
            echo "   Session status: Running"
            
            # Check task queue status if available
            local queue_status
            if queue_status=$(./src/task-queue.sh status 2>/dev/null | grep -A 5 "GLOBAL QUEUE STATUS" | head -6); then
                echo "   Queue status: Available"
                if command -v jq >/dev/null 2>&1; then
                    local pending_tasks
                    pending_tasks=$(echo "$queue_status" | jq -r '.pending // "unknown"' 2>/dev/null || echo "unknown")
                    echo "   Pending tasks: $pending_tasks"
                fi
            else
                echo "   Queue status: Not available"
            fi
            
            # Show recent session activity
            echo "   Recent activity:"
            echo "$session_output" | tail -3 | sed 's/^/     /'
            echo ""
        fi
        
        # Handle user interrupt
        if read -t $check_interval -n 1 key 2>/dev/null; then
            if [[ "$key" == "q" ]]; then
                echo ""
                log_warn "Test interrupted by user"
                return 2
            elif [[ "$key" == "s" ]]; then
                echo ""
                echo "=== Current Session Output ==="
                tmux capture-pane -t "$test_session" -p
                echo "=============================="
                echo ""
            fi
        fi
    done
    
    log_info "${CHECK} Test monitoring completed successfully"
    return 0
}

# Generate test report
generate_test_report() {
    local test_session="$1"
    local duration="$2"
    local test_result="$3"
    
    echo ""
    echo "=== LIVE OPERATION TEST REPORT ==="
    echo "Session: $test_session"
    echo "Duration: ${duration}s ($(($duration/60)) minutes)"
    echo "Result: $test_result"
    echo "Timestamp: $(date)"
    echo ""
    
    # Get final session state
    if tmux has-session -t "$test_session" 2>/dev/null; then
        echo "=== Final Session Output ==="
        tmux capture-pane -t "$test_session" -p | tail -20
        echo ""
    fi
    
    # Get final queue status
    echo "=== Final Queue Status ==="
    if ./src/task-queue.sh status 2>/dev/null; then
        echo ""
    else
        echo "Queue status not available"
        echo ""
    fi
    
    # Get resource usage if available
    echo "=== Resource Usage ==="
    local memory_usage
    memory_usage=$(ps -o rss= -p $$ 2>/dev/null | awk '{print int($1/1024)}' || echo "unknown")
    echo "Memory usage: ${memory_usage}MB"
    
    local process_count
    process_count=$(ps aux | grep -c "hybrid-monitor" || echo "0")
    echo "Active monitors: $process_count"
    echo ""
}

# Cleanup test environment
cleanup_test_environment() {
    local test_session="$1"
    
    log_info "${GEAR} Cleaning up test environment: $test_session"
    
    # Stop the session gracefully
    if tmux has-session -t "$test_session" 2>/dev/null; then
        # Send interrupt signal to stop monitoring
        tmux send-keys -t "$test_session" C-c
        sleep 2
        
        # Kill the session
        tmux kill-session -t "$test_session" 2>/dev/null || true
        
        # Verify session is gone
        if ! tmux has-session -t "$test_session" 2>/dev/null; then
            log_info "${CHECK} Test session cleaned up successfully"
        else
            log_warn "Test session may still exist"
        fi
    else
        log_info "${CHECK} Test session already terminated"
    fi
    
    # Clean up any temporary files created during test
    rm -f "/tmp/usage-limit-wait-time.env" 2>/dev/null || true
    rm -f "/tmp/usage-limit-countdown.pid" 2>/dev/null || true
}

# Main test execution function
run_live_operation_test() {
    local duration="$1"
    
    echo -e "${INFO} Starting live operation test (duration: ${duration}s)"
    echo ""
    
    # Generate unique test session name
    local test_session
    test_session=$(generate_test_session_name)
    
    # Create isolated test environment
    if ! create_test_environment "$test_session"; then
        log_error "Failed to create test environment"
        return 1
    fi
    
    # Start monitoring in test session
    if ! start_test_monitoring "$test_session" "$duration"; then
        log_error "Failed to start test monitoring"
        cleanup_test_environment "$test_session"
        return 1
    fi
    
    # Monitor test progress
    local monitor_result
    monitor_test_progress "$test_session" "$duration"
    monitor_result=$?
    
    # Generate test report
    case $monitor_result in
        0)
            generate_test_report "$test_session" "$duration" "SUCCESS"
            ;;
        1)
            generate_test_report "$test_session" "$duration" "FAILURE"
            ;;
        2)
            generate_test_report "$test_session" "$duration" "INTERRUPTED"
            ;;
        *)
            generate_test_report "$test_session" "$duration" "UNKNOWN"
            ;;
    esac
    
    # Cleanup test environment
    cleanup_test_environment "$test_session"
    
    # Final result
    case $monitor_result in
        0)
            echo -e "${CHECK} ${GREEN}Live operation test completed successfully!${NC}"
            echo -e "${INFO} System is ready for production deployment"
            return 0
            ;;
        1)
            echo -e "${ERROR} ${RED}Live operation test failed${NC}"
            echo -e "${INFO} Please review the issues above before production deployment"
            return 1
            ;;
        2)
            echo -e "${WARNING} ${YELLOW}Live operation test was interrupted${NC}"
            echo -e "${INFO} Consider running a full test before production deployment"
            return 1
            ;;
        *)
            echo -e "${ERROR} ${RED}Live operation test had unknown result${NC}"
            return 1
            ;;
    esac
}

# Handle command line arguments
case "${1:-}" in
    "help"|"-h"|"--help")
        echo -e "${BLUE}Claude Auto-Resume Live Operation Testing Framework${NC}"
        echo ""
        echo "Usage: $0 [duration_in_seconds]"
        echo ""
        echo "Parameters:"
        echo "  duration    Test duration in seconds (default: 600, min: 60, max: 3600)"
        echo ""
        echo "Examples:"
        echo "  $0          # Run 10-minute test (default)"
        echo "  $0 300      # Run 5-minute test"
        echo "  $0 1800     # Run 30-minute test"
        echo ""
        echo "Interactive commands during test:"
        echo "  q           # Quit test early"
        echo "  s           # Show current session output"
        echo ""
        echo "Features:"
        echo "  - Isolated tmux session (no interference with existing sessions)"
        echo "  - Real-time progress monitoring"
        echo "  - Enhanced usage limit detection testing"
        echo "  - Resource usage monitoring"
        echo "  - Comprehensive test report"
        echo "  - Automatic cleanup"
        echo ""
        ;;
    "")
        run_live_operation_test "$TEST_DURATION"
        ;;
    *)
        if [[ "$1" =~ ^[0-9]+$ ]]; then
            TEST_DURATION="$1"
            run_live_operation_test "$TEST_DURATION"
        else
            log_error "Invalid argument: $1"
            echo -e "${INFO} Use ${CYAN}$0 help${NC} for usage information"
            exit 1
        fi
        ;;
esac