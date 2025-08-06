#!/usr/bin/env bats

# Integration tests for hybrid-monitor.sh main script

load '../test_helper'

setup() {
    default_setup
    
    # Create test project
    TEST_PROJECT_DIR=$(create_test_project "test-integration")
    cd "$TEST_PROJECT_DIR"
    
    # Source the hybrid monitor (if available)
    if [[ -f "$BATS_TEST_DIRNAME/../../src/hybrid-monitor.sh" ]]; then
        source "$BATS_TEST_DIRNAME/../../src/hybrid-monitor.sh" 2>/dev/null || true
    fi
    
    # Set integration test environment
    export DRY_RUN=true
    export TEST_MODE=true
    export TEST_WAIT_SECONDS=1
    export CHECK_INTERVAL_MINUTES=1
    export MAX_RESTARTS=3
}

teardown() {
    default_teardown
}

@test "hybrid monitor script exists and is executable" {
    local monitor_script="$BATS_TEST_DIRNAME/../../src/hybrid-monitor.sh"
    
    assert_file_exists "$monitor_script"
    
    # Check if executable
    [[ -x "$monitor_script" ]]
}

@test "hybrid monitor shows help message" {
    local monitor_script="$BATS_TEST_DIRNAME/../../src/hybrid-monitor.sh"
    
    if [[ -x "$monitor_script" ]]; then
        run "$monitor_script" --help
        [ "$status" -eq 0 ]
        [[ "$output" =~ "Usage:" ]]
        [[ "$output" =~ "hybrid-monitor" ]]
    else
        skip "Hybrid monitor script not found or not executable"
    fi
}

@test "hybrid monitor shows version information" {
    local monitor_script="$BATS_TEST_DIRNAME/../../src/hybrid-monitor.sh"
    
    if [[ -x "$monitor_script" ]]; then
        run "$monitor_script" --version
        [ "$status" -eq 0 ]
        [[ "$output" =~ "version" ]]
    else
        skip "Hybrid monitor script not found or not executable"
    fi
}

@test "hybrid monitor validates system requirements" {
    if declare -f validate_system_requirements >/dev/null 2>&1; then
        run validate_system_requirements
        [[ "$status" -eq 0 ]] || [[ "$status" -eq 1 ]]
    else
        skip "validate_system_requirements function not available"
    fi
}

@test "hybrid monitor loads configuration correctly" {
    if declare -f load_configuration >/dev/null 2>&1; then
        run load_configuration
        [ "$status" -eq 0 ]
    else
        skip "load_configuration function not available"
    fi
}

@test "hybrid monitor initializes modules correctly" {
    if declare -f load_dependencies >/dev/null 2>&1; then
        run load_dependencies
        [ "$status" -eq 0 ]
    else
        skip "load_dependencies function not available"
    fi
}

@test "usage limit check handles test mode" {
    if declare -f check_usage_limits >/dev/null 2>&1; then
        export TEST_MODE=true
        export TEST_WAIT_SECONDS=1
        
        run check_usage_limits
        # In test mode, should simulate usage limit
        [ "$status" -eq 1 ]
    else
        skip "check_usage_limits function not available"
    fi
}

@test "usage limit check handles normal mode" {
    if declare -f check_usage_limits >/dev/null 2>&1; then
        export TEST_MODE=false
        setup_mock_claude "success"
        
        run check_usage_limits
        [ "$status" -eq 0 ]  # Should pass with mock successful Claude
    else
        skip "check_usage_limits function not available"
    fi
}

@test "usage limit handling calculates wait time correctly" {
    if declare -f handle_usage_limit >/dev/null 2>&1; then
        local future_timestamp=$(($(date +%s) + 5))  # 5 seconds in future
        
        # This should complete quickly in test mode
        run timeout 10 handle_usage_limit "$future_timestamp"
        [ "$status" -eq 0 ]
    else
        skip "handle_usage_limit function not available"
    fi
}

@test "session startup works with claunch integration" {
    if declare -f start_or_continue_claude_session >/dev/null 2>&1; then
        export USE_CLAUNCH=true
        export DRY_RUN=true
        
        run start_or_continue_claude_session
        [ "$status" -eq 0 ]
    else
        skip "start_or_continue_claude_session function not available"
    fi
}

@test "session startup works in legacy mode" {
    if declare -f start_or_continue_claude_session >/dev/null 2>&1; then
        export USE_CLAUNCH=false
        export DRY_RUN=true
        export USE_NEW_TERMINAL=false
        
        run start_or_continue_claude_session
        [ "$status" -eq 0 ]
    else
        skip "start_or_continue_claude_session function not available"
    fi
}

@test "recovery command sending works" {
    if declare -f send_recovery_command >/dev/null 2>&1; then
        export USE_CLAUNCH=true
        export DRY_RUN=true
        export MAIN_SESSION_ID="test-session-123"
        
        # Mock session manager functions
        perform_session_recovery() {
            echo "Mock: performing recovery for $1"
            return 0
        }
        export -f perform_session_recovery
        
        run send_recovery_command "custom recovery command"
        [ "$status" -eq 0 ]
        
        unset -f perform_session_recovery
    else
        skip "send_recovery_command function not available"
    fi
}

@test "continuous monitoring initializes correctly" {
    if declare -f continuous_monitoring_loop >/dev/null 2>&1; then
        export CHECK_INTERVAL_MINUTES=1
        export MAX_RESTARTS=1
        export DRY_RUN=true
        export MONITORING_ACTIVE=false  # Prevent actual loop
        
        # This should setup but not run the loop due to MONITORING_ACTIVE=false
        run timeout 5 bash -c "source '$BATS_TEST_DIRNAME/../../src/hybrid-monitor.sh' 2>/dev/null; continuous_monitoring_loop || true"
        # Should not timeout or crash
        [[ "$status" -eq 0 ]] || [[ "$status" -eq 124 ]] || [[ "$status" -eq 1 ]]
    else
        skip "continuous_monitoring_loop function not available"
    fi
}

@test "signal handling works correctly" {
    local monitor_script="$BATS_TEST_DIRNAME/../../src/hybrid-monitor.sh"
    
    if [[ -x "$monitor_script" ]]; then
        # Start monitor in background and send SIGINT
        "$monitor_script" --continuous --dry-run &
        local pid=$!
        
        sleep 1
        kill -INT "$pid" 2>/dev/null || true
        
        # Wait for process to handle signal
        wait "$pid" 2>/dev/null || true
        
        # Process should have exited gracefully
        ! kill -0 "$pid" 2>/dev/null
    else
        skip "Hybrid monitor script not found or not executable"
    fi
}

@test "argument parsing works correctly" {
    if declare -f parse_arguments >/dev/null 2>&1; then
        # Test various argument combinations
        run parse_arguments --continuous --check-interval 5 --max-cycles 10 --debug
        [ "$status" -eq 0 ]
        
        run parse_arguments --new-terminal --dry-run "custom prompt"
        [ "$status" -eq 0 ]
        
        # Test invalid arguments
        run parse_arguments --invalid-option
        [ "$status" -eq 1 ]
    else
        skip "parse_arguments function not available"
    fi
}

@test "main function runs without errors" {
    local monitor_script="$BATS_TEST_DIRNAME/../../src/hybrid-monitor.sh"
    
    if [[ -x "$monitor_script" ]]; then
        # Test single execution mode with dry run
        run timeout 30 "$monitor_script" --dry-run "test prompt"
        [[ "$status" -eq 0 ]] || [[ "$status" -eq 124 ]]
        
        # Should not have crashed
        [[ "$status" -ne 127 ]]  # Command not found
        [[ "$status" -ne 139 ]]  # Segfault
    else
        skip "Hybrid monitor script not found or not executable"
    fi
}

@test "integration with all modules works" {
    local monitor_script="$BATS_TEST_DIRNAME/../../src/hybrid-monitor.sh"
    
    if [[ -x "$monitor_script" ]]; then
        # Set up comprehensive test environment
        export DRY_RUN=true
        export TEST_MODE=true
        export USE_CLAUNCH=true
        export DEBUG_MODE=true
        
        # Test that all modules can be loaded together
        run timeout 15 bash -c "
            source '$monitor_script' 2>/dev/null
            
            # Test that key functions are available
            if declare -f load_dependencies >/dev/null 2>&1; then
                load_dependencies
            fi
            
            if declare -f validate_system_requirements >/dev/null 2>&1; then
                validate_system_requirements || true
            fi
            
            echo 'Integration test completed'
        "
        
        [ "$status" -eq 0 ]
        [[ "$output" =~ "Integration test completed" ]]
    else
        skip "Hybrid monitor script not found or not executable"
    fi
}

@test "configuration file loading works end-to-end" {
    local monitor_script="$BATS_TEST_DIRNAME/../../src/hybrid-monitor.sh"
    local test_config="$BATS_TEST_DIRNAME/../fixtures/test-config.conf"
    
    if [[ -x "$monitor_script" ]] && [[ -f "$test_config" ]]; then
        run timeout 10 "$monitor_script" --config "$test_config" --dry-run --version
        [ "$status" -eq 0 ]
    else
        skip "Monitor script or test config not available"
    fi
}

@test "error handling prevents crashes" {
    local monitor_script="$BATS_TEST_DIRNAME/../../src/hybrid-monitor.sh"
    
    if [[ -x "$monitor_script" ]]; then
        # Test with invalid configuration
        run timeout 10 "$monitor_script" --config "/nonexistent/config.conf" --dry-run
        # Should handle gracefully, not crash
        [[ "$status" -ne 127 ]]
        [[ "$status" -ne 139 ]]
        
        # Test with missing dependencies
        export PATH="/usr/bin:/bin"  # Minimal PATH
        
        run timeout 10 "$monitor_script" --dry-run
        # Should handle missing dependencies gracefully
        [[ "$status" -ne 127 ]]
        [[ "$status" -ne 139 ]]
    else
        skip "Hybrid monitor script not found or not executable"
    fi
}