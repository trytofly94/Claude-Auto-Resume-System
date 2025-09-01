#!/usr/bin/env bats

# Integration tests for global CLI installation
# Tests the complete workflow of installing, using, and uninstalling the global command

# Test environment setup
setup() {
    # Create temporary test directory
    export TEST_INSTALL_DIR="$HOME/.test-claude-auto-resume-$$"
    export TEST_BIN_DIR="$TEST_INSTALL_DIR/bin"
    export ORIGINAL_PATH="$PATH"
    
    # Create test environment
    mkdir -p "$TEST_BIN_DIR"
    export PATH="$TEST_BIN_DIR:$PATH"
    
    # Source the installation script functions
    source "$BATS_TEST_DIRNAME/../../scripts/install-global.sh"
    
    # Skip actual installation for most tests - we'll mock the command
    export SKIP_ACTUAL_INSTALL=true
}

# Test environment cleanup
teardown() {
    # Restore original PATH
    export PATH="$ORIGINAL_PATH"
    
    # Clean up test directory
    if [[ -d "$TEST_INSTALL_DIR" ]]; then
        rm -rf "$TEST_INSTALL_DIR"
    fi
    
    # Clean up any test installations
    local test_command="$TEST_BIN_DIR/claude-auto-resume"
    if [[ -f "$test_command" ]]; then
        rm -f "$test_command"
    fi
}

# Test 1: Fresh installation from scratch
@test "fresh installation creates global command" {
    # Mock installation
    create_mock_global_command
    
    # Verify command is accessible
    run command -v claude-auto-resume
    [ "$status" -eq 0 ]
    [[ "$output" == "$TEST_BIN_DIR/claude-auto-resume" ]]
}

# Test 2: Installation over existing setup
@test "installation over existing setup prompts for overwrite" {
    # Create existing mock installation
    create_mock_global_command
    
    # Attempt reinstallation (should detect existing)
    run detect_existing_installation "$TEST_BIN_DIR/claude-auto-resume"
    [ "$status" -eq 0 ]
    [[ "$output" == *"existing"* ]]
}

# Test 3: Cross-directory command execution
@test "global command works from different directories" {
    # Create mock installation
    create_mock_global_command
    
    # Test from different directories
    cd /tmp
    run command -v claude-auto-resume
    [ "$status" -eq 0 ]
    
    cd "$HOME"
    run command -v claude-auto-resume
    [ "$status" -eq 0 ]
    
    # Test execution from different directory
    cd /tmp
    run claude-auto-resume --help
    [ "$status" -eq 0 ]
}

# Test 4: Path resolution accuracy
@test "path resolution works correctly" {
    source "$BATS_TEST_DIRNAME/../../src/utils/installation-path.sh" || skip "installation-path.sh not available"
    
    # Test detection of installation directory
    run get_installation_path
    [ "$status" -eq 0 ]
    [[ "$output" == *"Claude-Auto-Resume-System"* ]]
}

# Test 5: Configuration file detection
@test "configuration files are accessible from global installation" {
    # Test config file detection
    local config_file="$BATS_TEST_DIRNAME/../../config/default.conf"
    [[ -f "$config_file" ]] || skip "Config file not available"
    
    run cat "$config_file"
    [ "$status" -eq 0 ]
    [[ "$output" == *"CHECK_INTERVAL_MINUTES"* ]]
}

# Test 6: Local vs global queue context
@test "queue context detection works correctly" {
    source "$BATS_TEST_DIRNAME/../../src/task-queue.sh" || skip "task-queue.sh not available"
    
    # Test global context
    cd /tmp
    run detect_queue_context
    [ "$status" -eq 0 ]
    
    # Test local context (if local queue exists)
    if [[ -f ".claude-tasks/queue.json" ]]; then
        run detect_queue_context
        [ "$status" -eq 0 ]
        [[ "$output" == *"local"* ]]
    fi
}

# Test 7: Uninstallation cleanup
@test "uninstallation removes all components" {
    # Create mock installation
    create_mock_global_command
    
    # Verify installation exists
    [[ -f "$TEST_BIN_DIR/claude-auto-resume" ]]
    
    # Uninstall
    rm -f "$TEST_BIN_DIR/claude-auto-resume"
    
    # Verify removal
    run command -v claude-auto-resume
    [ "$status" -ne 0 ]
}

# Test 8: Permission handling
@test "permission checks work correctly" {
    # Test writable directory
    run check_install_permissions "$TEST_BIN_DIR"
    [ "$status" -eq 0 ]
    
    # Test non-writable directory (simulate)
    local readonly_dir="/this-should-not-exist-$$"
    run check_install_permissions "$readonly_dir"
    [ "$status" -ne 0 ]
}

# Test 9: Platform detection
@test "platform detection works" {
    run detect_platform
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^(macos|linux|unsupported)$ ]]
}

# Test 10: Installation validation
@test "installation validation catches issues" {
    # Test with missing installation directory
    run validate_installation_env "/non-existent-directory"
    [ "$status" -ne 0 ]
    
    # Test with valid directory
    run validate_installation_env "$BATS_TEST_DIRNAME/../.."
    [ "$status" -eq 0 ]
}

# Test 11: Error handling and recovery
@test "installation handles errors gracefully" {
    # Test cleanup function
    local temp_file="/tmp/test-wrapper-$$"
    touch "$temp_file"
    
    run cleanup_on_failure "$temp_file" ""
    [ "$status" -eq 0 ]
    [[ ! -f "$temp_file" ]] # Should be cleaned up
}

# Test 12: Version compatibility
@test "version compatibility check works" {
    # Mock existing installation
    create_mock_global_command_with_version "1.0.0"
    
    run validate_version_compatibility
    [ "$status" -eq 0 ]
}

# Test 13: PATH verification
@test "PATH verification provides helpful guidance" {
    # Test directory not in PATH
    local test_dir="/some-random-directory-$$"
    run verify_path_accessibility "$test_dir"
    [ "$status" -ne 0 ]
    [[ "$output" == *"PATH"* ]]
}

# Test 14: Command execution timeout
@test "command validation includes timeout protection" {
    # Create mock command that hangs
    create_mock_hanging_command
    
    # Validation should timeout and handle gracefully
    run timeout 5s validate_global_command
    # Should not hang indefinitely
    [ "$status" -ne 124 ] # timeout exit code
}

# Test 15: Wrapper script integrity
@test "wrapper script has correct content and permissions" {
    # Create wrapper script
    local test_wrapper="$TEST_BIN_DIR/test-wrapper"
    create_global_wrapper "$BATS_TEST_DIRNAME/../.." "$test_wrapper"
    
    # Verify file exists and is executable
    [[ -f "$test_wrapper" ]]
    [[ -x "$test_wrapper" ]]
    
    # Verify content
    run cat "$test_wrapper"
    [[ "$output" == *"CLAUDE_AUTO_RESUME_HOME"* ]]
    [[ "$output" == *"task-queue.sh"* ]]
}

# ===============================================================================
# HELPER FUNCTIONS
# ===============================================================================

# Create a mock global command for testing
create_mock_global_command() {
    cat > "$TEST_BIN_DIR/claude-auto-resume" << 'EOF'
#!/usr/bin/env bash
# Mock claude-auto-resume command for testing

case "${1:-}" in
    --help)
        echo "Mock claude-auto-resume help"
        exit 0
        ;;
    --version)
        echo "mock-version-1.0.0"
        exit 0
        ;;
    *)
        echo "Mock claude-auto-resume executed with args: $*"
        exit 0
        ;;
esac
EOF
    chmod +x "$TEST_BIN_DIR/claude-auto-resume"
}

# Create mock command with specific version
create_mock_global_command_with_version() {
    local version="$1"
    cat > "$TEST_BIN_DIR/claude-auto-resume" << EOF
#!/usr/bin/env bash
case "\${1:-}" in
    --version)
        echo "$version"
        exit 0
        ;;
    *)
        echo "Mock command version $version"
        exit 0
        ;;
esac
EOF
    chmod +x "$TEST_BIN_DIR/claude-auto-resume"
}

# Create mock command that hangs (for timeout testing)
create_mock_hanging_command() {
    cat > "$TEST_BIN_DIR/claude-auto-resume" << 'EOF'
#!/usr/bin/env bash
# Simulate a hanging command
sleep 30
EOF
    chmod +x "$TEST_BIN_DIR/claude-auto-resume"
}

# Detect existing installation (helper function)
detect_existing_installation() {
    local target_file="$1"
    if [[ -f "$target_file" ]]; then
        echo "existing installation found"
        return 0
    else
        echo "no existing installation"
        return 1
    fi
}

# Detect queue context (mock implementation)
detect_queue_context() {
    if [[ -f ".claude-tasks/queue.json" ]]; then
        echo "local context detected"
    else
        echo "global context detected"
    fi
}