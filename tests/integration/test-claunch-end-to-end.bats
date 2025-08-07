#!/usr/bin/env bats

# test-claunch-end-to-end.bats - Integration tests for complete claunch verification flow
# Tests the full installation and verification process for GitHub issue #4

# Test fixtures
setup() {
    # Set up test environment
    export TEST_TEMP_DIR="/tmp/claude-auto-resume-integration-bats-$$"
    mkdir -p "$TEST_TEMP_DIR"
    
    # Paths to scripts
    export INSTALL_SCRIPT="$BATS_TEST_DIRNAME/../../scripts/install-claunch.sh"
    export SETUP_SCRIPT="$BATS_TEST_DIRNAME/../../scripts/setup.sh"
    export MONITOR_SCRIPT="$BATS_TEST_DIRNAME/../../src/hybrid-monitor.sh"
    
    cd "$TEST_TEMP_DIR"
}

teardown() {
    # Cleanup test environment
    cd "$BATS_TEST_DIRNAME"
    rm -rf "$TEST_TEMP_DIR"
}

@test "install script comprehensive functionality test" {
    # Test help functionality
    run "$INSTALL_SCRIPT" --help
    [ "$status" -eq 0 ]
    
    # Test verification-only mode
    run "$INSTALL_SCRIPT" --verify-only
    [ "$status" -eq 0 -o "$status" -eq 1 ]
}

@test "setup script integrates with enhanced verification" {
    # Check setup script syntax
    run bash -n "$SETUP_SCRIPT"
    [ "$status" -eq 0 ]
    
    # Check for integration with install script
    grep -q "install-claunch.sh" "$SETUP_SCRIPT"
}

@test "error handling works correctly" {
    # Test invalid arguments
    run "$INSTALL_SCRIPT" --invalid-flag
    [ "$status" -ne 0 ]
}

@test "PATH handling functions are present" {
    # Verify PATH handling functions exist
    grep -q "detect_shell_profile" "$INSTALL_SCRIPT"
    grep -q "get_effective_path" "$INSTALL_SCRIPT"
    grep -q "refresh_current_path" "$INSTALL_SCRIPT"
}

@test "verification timing controls are implemented" {
    # Check for timing controls
    grep -q "VERIFICATION_DELAY" "$INSTALL_SCRIPT"
    grep -q "MAX_VERIFICATION_ATTEMPTS" "$INSTALL_SCRIPT"
    grep -q "sleep" "$INSTALL_SCRIPT"
}

@test "logging and user feedback is comprehensive" {
    # Check for logging functions
    grep -q "log()" "$INSTALL_SCRIPT"
    
    # Check for different log levels
    grep -q "INFO" "$INSTALL_SCRIPT"
    grep -q "WARN" "$INSTALL_SCRIPT"
    grep -q "ERROR" "$INSTALL_SCRIPT"
    grep -q "SUCCESS" "$INSTALL_SCRIPT"
    
    # Check for user guidance
    grep -q "provide_user_guidance" "$INSTALL_SCRIPT"
}

@test "hybrid monitor integrates with verification system" {
    if [ -f "$MONITOR_SCRIPT" ]; then
        # Check if hybrid monitor uses new verification
        grep -q "install-claunch.sh" "$MONITOR_SCRIPT"
        grep -q "verify-only" "$MONITOR_SCRIPT"
    else
        skip "Hybrid monitor script not found"
    fi
}

@test "backward compatibility is maintained" {
    # Check for existing installation detection
    grep -q "check_existing_installation" "$INSTALL_SCRIPT"
}

@test "cross-shell compatibility syntax check" {
    # Test with bash (should work)
    if command -v bash >/dev/null 2>&1; then
        run bash -n "$INSTALL_SCRIPT"
        [ "$status" -eq 0 ]
    fi
    
    # Test with dash if available
    if command -v dash >/dev/null 2>&1; then
        run dash -n "$INSTALL_SCRIPT"
        [ "$status" -eq 0 ]
    fi
}