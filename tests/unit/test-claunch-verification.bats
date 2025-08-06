#!/usr/bin/env bats

# test-claunch-verification.bats - BATS tests for claunch installation verification
# Tests the enhanced verification logic introduced to fix GitHub issue #4

# Test fixtures
setup() {
    # Set up test environment
    export TEST_TEMP_DIR="/tmp/claude-auto-resume-bats-$$"
    mkdir -p "$TEST_TEMP_DIR"
    
    # Paths to scripts
    export INSTALL_SCRIPT="$BATS_TEST_DIRNAME/../../scripts/install-claunch.sh"
    export SETUP_SCRIPT="$BATS_TEST_DIRNAME/../../scripts/setup.sh"
    
    # Change to test directory
    cd "$TEST_TEMP_DIR"
    
    # Copy scripts for testing
    cp "$INSTALL_SCRIPT" "./install-claunch.sh"
    chmod +x "./install-claunch.sh"
}

teardown() {
    # Cleanup test environment
    cd "$BATS_TEST_DIRNAME"
    rm -rf "$TEST_TEMP_DIR"
}

@test "install script exists and is executable" {
    [ -f "$INSTALL_SCRIPT" ]
    [ -x "$INSTALL_SCRIPT" ]
}

@test "install script help functionality works" {
    run "$INSTALL_SCRIPT" --help
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Usage:" ]]
}

@test "install script handles invalid arguments" {
    run "$INSTALL_SCRIPT" --invalid-argument
    [ "$status" -ne 0 ]
}

@test "verification-only mode executes without errors" {
    # This test checks if --verify-only flag works
    # Exit codes 0 (success) or 1 (verification failed) are both acceptable
    run "$INSTALL_SCRIPT" --verify-only
    [ "$status" -eq 0 -o "$status" -eq 1 ]
}

@test "install script has proper configuration variables" {
    # Check for key configuration variables in the script
    grep -q "INSTALL_DIR=" "$INSTALL_SCRIPT"
    grep -q "MAX_VERIFICATION_ATTEMPTS=" "$INSTALL_SCRIPT"
    grep -q "VERIFICATION_DELAY=" "$INSTALL_SCRIPT"
}

@test "install script has logging functionality" {
    # Check for logging functions
    grep -q "log()" "$INSTALL_SCRIPT"
    grep -q "INFO" "$INSTALL_SCRIPT"
    grep -q "ERROR" "$INSTALL_SCRIPT"
    grep -q "SUCCESS" "$INSTALL_SCRIPT"
}

@test "install script has PATH detection functions" {
    # Check for PATH handling functions
    grep -q "detect_shell_profile" "$INSTALL_SCRIPT"
    grep -q "get_effective_path" "$INSTALL_SCRIPT"
    grep -q "refresh_current_path" "$INSTALL_SCRIPT"
}

@test "install script has verification functions" {
    # Check for verification functions
    grep -q "verify_claunch_installation" "$INSTALL_SCRIPT"
    grep -q "check_existing_installation" "$INSTALL_SCRIPT"
}

@test "install script has user guidance functions" {
    # Check for user guidance functionality
    grep -q "provide_user_guidance" "$INSTALL_SCRIPT"
}

@test "install script has proper error handling" {
    # Check for error handling patterns
    grep -q "set -euo pipefail" "$INSTALL_SCRIPT"
}

@test "setup script exists and is executable" {
    [ -f "$SETUP_SCRIPT" ]
    [ -x "$SETUP_SCRIPT" ]
}

@test "setup script integrates with enhanced claunch verification" {
    # Check if setup script uses the new verification system
    grep -q "install-claunch.sh" "$SETUP_SCRIPT"
    grep -q "verify.*dependencies" "$SETUP_SCRIPT"
}

@test "install script syntax is valid" {
    # Test script syntax
    run bash -n "$INSTALL_SCRIPT"
    [ "$status" -eq 0 ]
}

@test "install script has shell compatibility checks" {
    # Check for shell detection logic
    grep -q "bash" "$INSTALL_SCRIPT"
    grep -q "zsh" "$INSTALL_SCRIPT"
    grep -q "SHELL" "$INSTALL_SCRIPT"
}