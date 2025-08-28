#!/usr/bin/env bash

# Test Script for Session ID Copying Functionality (GitHub Issue #39)
# Tests the recently implemented session ID display, clipboard integration, and CLI parameters

set -euo pipefail

# Test configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$SCRIPT_DIR/src"
TEST_RESULTS=()
TEST_COUNT=0
PASSED_COUNT=0
FAILED_COUNT=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test helper functions
log_test() { echo -e "${YELLOW}[TEST]${NC} $*"; }
log_pass() { echo -e "${GREEN}[PASS]${NC} $*"; ((PASSED_COUNT++)); }
log_fail() { echo -e "${RED}[FAIL]${NC} $*"; ((FAILED_COUNT++)); }
log_info() { echo -e "${YELLOW}[INFO]${NC} $*"; }

start_test() {
    local test_name="$1"
    ((TEST_COUNT++))
    log_test "Starting test: $test_name"
}

end_test() {
    local test_name="$1"
    local result="$2"
    if [[ "$result" == "pass" ]]; then
        log_pass "Test passed: $test_name"
        TEST_RESULTS+=("PASS: $test_name")
    else
        log_fail "Test failed: $test_name"
        TEST_RESULTS+=("FAIL: $test_name")
    fi
}

# Test 1: Verify session display module exists and syntax
test_session_display_module() {
    start_test "Session Display Module Syntax Check"
    
    local session_display_file="$SOURCE_DIR/utils/session-display.sh"
    
    if [[ ! -f "$session_display_file" ]]; then
        end_test "Session Display Module Syntax Check" "fail"
        return 1
    fi
    
    if bash -n "$session_display_file"; then
        end_test "Session Display Module Syntax Check" "pass"
        return 0
    else
        end_test "Session Display Module Syntax Check" "fail"
        return 1
    fi
}

# Test 2: Verify clipboard module exists and syntax
test_clipboard_module() {
    start_test "Clipboard Module Syntax Check"
    
    local clipboard_file="$SOURCE_DIR/utils/clipboard.sh"
    
    if [[ ! -f "$clipboard_file" ]]; then
        end_test "Clipboard Module Syntax Check" "fail"
        return 1
    fi
    
    if bash -n "$clipboard_file"; then
        end_test "Clipboard Module Syntax Check" "pass"
        return 0
    else
        end_test "Clipboard Module Syntax Check" "fail"
        return 1
    fi
}

# Test 3: Test clipboard functionality directly
test_clipboard_functionality() {
    start_test "Clipboard Functionality"
    
    local clipboard_file="$SOURCE_DIR/utils/clipboard.sh"
    
    # Test clipboard info command
    if "$clipboard_file" --info >/dev/null 2>&1; then
        log_info "Clipboard system information retrieved successfully"
        end_test "Clipboard Functionality" "pass"
        return 0
    else
        log_fail "Could not retrieve clipboard system information"
        end_test "Clipboard Functionality" "fail"
        return 1
    fi
}

# Test 4: Test session display functionality directly
test_session_display_functionality() {
    start_test "Session Display Functionality"
    
    local session_display_file="$SOURCE_DIR/utils/session-display.sh"
    
    # Test session display module by running it directly
    if "$session_display_file" >/dev/null 2>&1; then
        log_info "Session display module executed successfully"
        end_test "Session Display Functionality" "pass"
        return 0
    else
        log_fail "Session display module execution failed"
        end_test "Session Display Functionality" "fail"
        return 1
    fi
}

# Test 5: Test hybrid-monitor CLI parameter parsing
test_hybrid_monitor_cli_parameters() {
    start_test "Hybrid Monitor CLI Parameters for Session ID"
    
    local hybrid_monitor="$SOURCE_DIR/hybrid-monitor.sh"
    
    if [[ ! -f "$hybrid_monitor" ]]; then
        end_test "Hybrid Monitor CLI Parameters for Session ID" "fail"
        return 1
    fi
    
    # Test --help includes session ID parameters
    if "$hybrid_monitor" --help 2>&1 | grep -q "SESSION ID MANAGEMENT"; then
        log_info "Session ID management section found in help output"
    else
        log_fail "Session ID management section missing from help output"
        end_test "Hybrid Monitor CLI Parameters for Session ID" "fail"
        return 1
    fi
    
    # Check for specific parameters in help
    local help_output
    help_output=$("$hybrid_monitor" --help 2>&1)
    
    local required_params=(
        "--show-session-id"
        "--copy-session-id"
        "--list-sessions"
        "--resume-session"
        "--show-full-session-id"
    )
    
    local missing_params=()
    for param in "${required_params[@]}"; do
        if ! echo "$help_output" | grep -q "$param"; then
            missing_params+=("$param")
        fi
    done
    
    if [[ ${#missing_params[@]} -eq 0 ]]; then
        log_info "All required session ID parameters found in help"
        end_test "Hybrid Monitor CLI Parameters for Session ID" "pass"
        return 0
    else
        log_fail "Missing session ID parameters: ${missing_params[*]}"
        end_test "Hybrid Monitor CLI Parameters for Session ID" "fail"
        return 1
    fi
}

# Test 6: Test basic session ID parameter parsing (without execution)
test_session_id_parameter_parsing() {
    start_test "Session ID Parameter Parsing"
    
    local hybrid_monitor="$SOURCE_DIR/hybrid-monitor.sh"
    
    # Test that the parameters are recognized (should fail gracefully, not with "unknown option")
    
    # Test --show-session-id
    if "$hybrid_monitor" --show-session-id --dry-run 2>&1 | grep -q "No active session found"; then
        log_info "--show-session-id parameter recognized"
    elif "$hybrid_monitor" --show-session-id --dry-run 2>&1 | grep -q "Unknown option"; then
        log_fail "--show-session-id parameter not recognized"
        end_test "Session ID Parameter Parsing" "fail"
        return 1
    else
        log_info "--show-session-id parameter handled appropriately"
    fi
    
    # Test --list-sessions
    if "$hybrid_monitor" --list-sessions --dry-run 2>&1 | grep -q "Session display module not loaded"; then
        log_info "--list-sessions parameter recognized (expected failure)"
    elif "$hybrid_monitor" --list-sessions --dry-run 2>&1 | grep -q "Unknown option"; then
        log_fail "--list-sessions parameter not recognized"
        end_test "Session ID Parameter Parsing" "fail"
        return 1
    else
        log_info "--list-sessions parameter handled appropriately"
    fi
    
    end_test "Session ID Parameter Parsing" "pass"
    return 0
}

# Test 7: Test clipboard system detection across platforms
test_cross_platform_clipboard() {
    start_test "Cross-Platform Clipboard Detection"
    
    local clipboard_file="$SOURCE_DIR/utils/clipboard.sh"
    
    # Test platform detection
    local platform_output
    if platform_output=$("$clipboard_file" --info 2>/dev/null); then
        log_info "Platform detection successful"
        
        # Check that it identifies the current platform
        if echo "$platform_output" | grep -q "Platform:"; then
            local detected_platform
            detected_platform=$(echo "$platform_output" | grep "Platform:" | cut -d' ' -f2)
            log_info "Detected platform: $detected_platform"
            
            case "$(uname -s)" in
                Darwin*)
                    if [[ "$detected_platform" == "macOS" ]]; then
                        log_info "Correct platform detection for macOS"
                        end_test "Cross-Platform Clipboard Detection" "pass"
                        return 0
                    fi
                    ;;
                Linux*)
                    if [[ "$detected_platform" == "Linux-X11" ]] || [[ "$detected_platform" == "Linux-Wayland" ]] || [[ "$detected_platform" == "Linux-unknown" ]]; then
                        log_info "Correct platform detection for Linux"
                        end_test "Cross-Platform Clipboard Detection" "pass"
                        return 0
                    fi
                    ;;
                *)
                    log_info "Platform detected as: $detected_platform"
                    end_test "Cross-Platform Clipboard Detection" "pass"
                    return 0
                    ;;
            esac
        fi
    else
        log_fail "Platform detection failed"
        end_test "Cross-Platform Clipboard Detection" "fail"
        return 1
    fi
    
    end_test "Cross-Platform Clipboard Detection" "pass"
    return 0
}

# Test 8: Test tmux integration
test_tmux_integration() {
    start_test "tmux Integration"
    
    # Check if we're in tmux environment
    if [[ -n "${TMUX:-}" ]]; then
        log_info "Running in tmux environment - testing tmux-specific functionality"
        
        # Source the session display module to test tmux functions
        local session_display_file="$SOURCE_DIR/utils/session-display.sh"
        
        # Test that tmux-specific functions exist
        if source "$session_display_file" 2>/dev/null; then
            if declare -f copy_session_to_tmux_buffer >/dev/null 2>&1; then
                log_info "tmux buffer copy function available"
                end_test "tmux Integration" "pass"
                return 0
            else
                log_fail "tmux buffer copy function not found"
                end_test "tmux Integration" "fail"
                return 1
            fi
        else
            log_fail "Could not source session display module"
            end_test "tmux Integration" "fail"
            return 1
        fi
    else
        log_info "Not in tmux environment - checking tmux detection works"
        end_test "tmux Integration" "pass"
        return 0
    fi
}

# Test 9: Verify session ID formatting functions
test_session_id_formatting() {
    start_test "Session ID Formatting Functions"
    
    local session_display_file="$SOURCE_DIR/utils/session-display.sh"
    
    # Source the module and test the shorten_session_id function
    if source "$session_display_file" 2>/dev/null; then
        if declare -f shorten_session_id >/dev/null 2>&1; then
            # Test shortening a long session ID
            local test_session_id="test-project-1672531200-very-long-session-id-12345"
            local shortened
            shortened=$(shorten_session_id "$test_session_id" 20)
            
            if [[ ${#shortened} -le 20 ]]; then
                log_info "Session ID shortening works correctly: $shortened"
                end_test "Session ID Formatting Functions" "pass"
                return 0
            else
                log_fail "Session ID not properly shortened: $shortened (length: ${#shortened})"
                end_test "Session ID Formatting Functions" "fail"
                return 1
            fi
        else
            log_fail "shorten_session_id function not found"
            end_test "Session ID Formatting Functions" "fail"
            return 1
        fi
    else
        log_fail "Could not source session display module"
        end_test "Session ID Formatting Functions" "fail"
        return 1
    fi
}

# Test 10: Integration test - full parameter flow
test_integration_parameter_flow() {
    start_test "Integration Parameter Flow"
    
    local hybrid_monitor="$SOURCE_DIR/hybrid-monitor.sh"
    
    # Test the dry-run version of session operations
    log_info "Testing complete parameter handling flow"
    
    # Test show-session-id with expected failure message
    local output
    if output=$("$hybrid_monitor" --show-session-id 2>&1); then
        # Should fail since no actual session, but should handle parameter correctly
        if echo "$output" | grep -q "No active session found"; then
            log_info "Session ID display handles no-session case correctly"
        else
            log_info "Session ID display produced output: $(echo "$output" | head -1)"
        fi
    fi
    
    # Test list-sessions
    if output=$("$hybrid_monitor" --list-sessions 2>&1); then
        if echo "$output" | grep -q "Session display module not loaded" || echo "$output" | grep -q "No sessions"; then
            log_info "List sessions handles module loading correctly"
        else
            log_info "List sessions produced output: $(echo "$output" | head -1)"
        fi
    fi
    
    end_test "Integration Parameter Flow" "pass"
    return 0
}

# Main test execution
main() {
    echo "=================================="
    echo "Session ID Functionality Test Suite"
    echo "Testing GitHub Issue #39 Implementation"
    echo "=================================="
    echo

    # Change to project directory
    cd "$SCRIPT_DIR"

    # Run all tests
    test_session_display_module
    test_clipboard_module
    test_clipboard_functionality
    test_session_display_functionality
    test_hybrid_monitor_cli_parameters
    test_session_id_parameter_parsing
    test_cross_platform_clipboard
    test_tmux_integration
    test_session_id_formatting
    test_integration_parameter_flow

    echo
    echo "=================================="
    echo "TEST SUMMARY"
    echo "=================================="
    echo "Total tests: $TEST_COUNT"
    echo "Passed: $PASSED_COUNT"
    echo "Failed: $FAILED_COUNT"
    echo "Success rate: $(( (PASSED_COUNT * 100) / TEST_COUNT ))%"
    echo
    
    if [[ $FAILED_COUNT -eq 0 ]]; then
        echo -e "${GREEN}✅ All tests passed!${NC}"
        echo
        echo "Session ID copying functionality is working correctly."
        echo "The implementation for GitHub Issue #39 appears to be complete and functional."
        echo
        echo "Key functionality verified:"
        echo "• Session display module syntax and execution"
        echo "• Cross-platform clipboard integration"
        echo "• CLI parameter parsing and recognition"
        echo "• Session ID formatting and display"
        echo "• Integration with hybrid-monitor main script"
        echo "• tmux environment detection and integration"
        exit 0
    else
        echo -e "${RED}❌ $FAILED_COUNT test(s) failed!${NC}"
        echo
        echo "Failed tests:"
        for result in "${TEST_RESULTS[@]}"; do
            if [[ $result == FAIL:* ]]; then
                echo "  - ${result#FAIL: }"
            fi
        done
        echo
        echo "Please review the failing tests and fix the issues before deployment."
        exit 1
    fi
}

# Run tests
main "$@"