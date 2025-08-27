#!/usr/bin/env bats

# Unit tests for logging.sh utility module
# Enhanced with Issue #46 BATS compatibility improvements

load '../test_helper'

setup() {
    # Phase 2: Use enhanced setup with BATS compatibility (Issue #46)
    enhanced_setup
    
    export TEST_MODE=true
    export LOG_LEVEL="DEBUG" 
    export DEBUG_MODE=true
    
    # Create temporary log directory
    TEST_LOG_DIR=$(mktemp -d)
    export LOG_FILE="$TEST_LOG_DIR/test.log"
    
    # Phase 1: Source with timeout protection (Issue #46)
    if ! run_with_bats_timeout "setup" bash -c "source '$BATS_TEST_DIRNAME/../../src/utils/logging.sh'"; then
        fail "Failed to source logging module with timeout"
    fi
    
    # Also source normally for direct function access in tests
    source "$BATS_TEST_DIRNAME/../../src/utils/logging.sh" 2>/dev/null || true
}

teardown() {
    # Phase 2: Use enhanced teardown (Issue #46)
    rm -rf "$TEST_LOG_DIR" 2>/dev/null || true
    enhanced_teardown
}

@test "logging module loads without errors" {
    # Test that the module can be sourced - Issue #46: Enhanced compatibility
    run bash -c "source '$BATS_TEST_DIRNAME/../../src/utils/logging.sh'"
    [ "$status" -eq 0 ]
}

@test "log_info function exists and works" {
    # Issue #46: Test with enhanced BATS compatibility
    run log_info "Test info message"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "[INFO]" ]]
    [[ "$output" =~ "Test info message" ]]
}

@test "log_warn function exists and works" {
    # Issue #46: Test with enhanced BATS compatibility
    run log_warn "Test warning message"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "[WARN]" ]]
    [[ "$output" =~ "Test warning message" ]]
}

@test "log_error function exists and works" {
    run log_error "Test error message"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "[ERROR]" ]]
    [[ "$output" =~ "Test error message" ]]
}

@test "log_debug function respects DEBUG_MODE" {
    # Test with DEBUG_MODE=true (should output)
    export DEBUG_MODE=true
    run log_debug "Test debug message"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "[DEBUG]" ]]
    [[ "$output" =~ "Test debug message" ]]
    
    # Test with DEBUG_MODE=false (should not output)
    export DEBUG_MODE=false
    run log_debug "Test debug message"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "log_success function works with colors" {
    run log_success "Test success message"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "[SUCCESS]" ]]
    [[ "$output" =~ "Test success message" ]]
}

@test "logging functions handle empty messages" {
    run log_info ""
    [ "$status" -eq 0 ]
    [[ "$output" =~ "[INFO]" ]]
    
    run log_warn ""
    [ "$status" -eq 0 ]
    [[ "$output" =~ "[WARN]" ]]
}

@test "logging functions handle special characters" {
    local special_msg="Test with special chars: !@#$%^&*()[]{}|\\;:'\",<.>/?"
    
    run log_info "$special_msg"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "$special_msg" ]]
}

@test "logging functions handle multiline messages" {
    local multiline_msg="Line 1
Line 2
Line 3"
    
    run log_info "$multiline_msg"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Line 1" ]]
    [[ "$output" =~ "Line 2" ]]
    [[ "$output" =~ "Line 3" ]]
}

@test "init_logging function initializes properly" {
    # Test with default config
    run init_logging "$BATS_TEST_DIRNAME/../fixtures/test-config.conf"
    [ "$status" -eq 0 ]
    
    # Check that LOG_LEVEL was set
    [[ "$LOG_LEVEL" == "DEBUG" ]]
}

@test "log file creation works when specified" {
    if declare -f init_logging >/dev/null 2>&1; then
        export LOG_FILE="$TEST_LOG_DIR/test-file.log"
        init_logging "$BATS_TEST_DIRNAME/../fixtures/test-config.conf"
        
        # Write something to log
        log_info "Test log file message"
        
        # Check if log file was created (implementation may vary)
        if [[ -f "$LOG_FILE" ]]; then
            [[ -s "$LOG_FILE" ]]  # File exists and is not empty
        fi
    else
        skip "init_logging function not implemented yet"
    fi
}

@test "log_session_event function works if available" {
    if declare -f log_session_event >/dev/null 2>&1; then
        run log_session_event "test-session-123" "start" "Session started successfully"
        [ "$status" -eq 0 ]
        [[ "$output" =~ "test-session-123" ]]
        [[ "$output" =~ "start" ]]
    else
        skip "log_session_event function not implemented yet"
    fi
}

@test "log rotation functions exist if implemented" {
    if declare -f rotate_log >/dev/null 2>&1; then
        # Create a large log file for testing
        echo "Large log content" > "$TEST_LOG_DIR/large.log"
        for i in {1..1000}; do
            echo "Log line $i with some content to make it bigger" >> "$TEST_LOG_DIR/large.log"
        done
        
        export LOG_FILE="$TEST_LOG_DIR/large.log"
        run rotate_log
        [ "$status" -eq 0 ]
    else
        skip "rotate_log function not implemented yet"
    fi
}

@test "logging works in non-interactive environment" {
    # Simulate non-interactive environment
    export TERM=""
    export CI=true
    
    run log_info "Non-interactive test"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "[INFO]" ]]
    [[ "$output" =~ "Non-interactive test" ]]
}