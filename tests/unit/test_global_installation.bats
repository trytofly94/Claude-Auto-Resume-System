#!/usr/bin/env bats

# Tests for Global CLI Installation (Issue #88)
# Tests installation path detection, global installation, and path resolution

load '../test_helper'

# Setup test environment
setup() {
    default_setup
    
    # Set up additional test directories for global installation tests
    export TEST_INSTALLATION_DIR="$TEST_TEMP_DIR/claude-auto-resume"
    export TEST_BIN_DIR="$TEST_TEMP_DIR/bin"
    export PROJECT_ROOT="$BATS_TEST_DIRNAME/../.."
    
    mkdir -p "$TEST_INSTALLATION_DIR"/{src/{utils,queue},config,scripts,logs}
    mkdir -p "$TEST_BIN_DIR"
    
    # Copy required source files (all files needed for validation)
    cp -r "$PROJECT_ROOT/src/utils/installation-path.sh" "$TEST_INSTALLATION_DIR/src/utils/"
    cp -r "$PROJECT_ROOT/src/utils/path-resolver.sh" "$TEST_INSTALLATION_DIR/src/utils/"
    cp -r "$PROJECT_ROOT/src/task-queue.sh" "$TEST_INSTALLATION_DIR/src/"
    cp -r "$PROJECT_ROOT/src/hybrid-monitor.sh" "$TEST_INSTALLATION_DIR/src/"
    cp -r "$PROJECT_ROOT/scripts/install-global.sh" "$TEST_INSTALLATION_DIR/scripts/"
    cp -r "$PROJECT_ROOT/config/default.conf" "$TEST_INSTALLATION_DIR/config/"
    cp -r "$PROJECT_ROOT/CLAUDE.md" "$TEST_INSTALLATION_DIR/"
    
    # Make scripts executable
    chmod +x "$TEST_INSTALLATION_DIR/src/utils/installation-path.sh"
    chmod +x "$TEST_INSTALLATION_DIR/scripts/install-global.sh"
    chmod +x "$TEST_INSTALLATION_DIR/src/task-queue.sh"
}

teardown() {
    default_teardown
    unset CLAUDE_AUTO_RESUME_HOME
}

# ===============================================================================
# PATH DETECTION TESTS
# ===============================================================================

@test "installation_path: detect_installation_path finds correct directory" {
    cd "$TEST_INSTALLATION_DIR"
    source src/utils/installation-path.sh
    
    local detected_path
    detected_path=$(detect_installation_path)
    
    [[ "$detected_path" == "$TEST_INSTALLATION_DIR" ]]
}

@test "installation_path: get_script_directory returns src directory" {
    cd "$TEST_INSTALLATION_DIR"
    source src/utils/installation-path.sh
    
    local script_dir
    script_dir=$(get_script_directory)
    
    [[ "$script_dir" == "$TEST_INSTALLATION_DIR/src/utils" ]]
}

@test "installation_path: is_global_installation detects global installation" {
    cd "$TEST_INSTALLATION_DIR"
    source src/utils/installation-path.sh
    
    # Test local installation (should return false)
    ! is_global_installation
    
    # Test global installation with environment variable
    export CLAUDE_AUTO_RESUME_HOME="$TEST_INSTALLATION_DIR"
    is_global_installation
}

@test "installation_path: validate_installation passes for complete installation" {
    cd "$TEST_INSTALLATION_DIR"
    source src/utils/installation-path.sh
    
    validate_installation "$TEST_INSTALLATION_DIR"
}

@test "installation_path: validate_installation fails for incomplete installation" {
    cd "$TEST_INSTALLATION_DIR"
    source src/utils/installation-path.sh
    
    # Remove required file
    rm src/task-queue.sh
    
    ! validate_installation "$TEST_INSTALLATION_DIR"
}

# ===============================================================================
# PATH RESOLUTION TESTS
# ===============================================================================

@test "path_resolver: initialize_path_resolver sets environment variables" {
    cd "$TEST_INSTALLATION_DIR"
    source src/utils/path-resolver.sh
    
    initialize_path_resolver
    
    [[ -n "$CLAUDE_INSTALLATION_DIR" ]]
    [[ -n "$CLAUDE_SRC_DIR" ]]
    [[ -n "$CLAUDE_CONFIG_DIR" ]]
}

@test "path_resolver: resolve_resource_path finds existing files" {
    cd "$TEST_INSTALLATION_DIR"
    source src/utils/path-resolver.sh
    initialize_path_resolver
    
    local config_path
    config_path=$(resolve_resource_path "config/default.conf")
    
    [[ "$config_path" == "$TEST_INSTALLATION_DIR/config/default.conf" ]]
    [[ -f "$config_path" ]]
}

@test "path_resolver: resolve_resource_path fails for missing files" {
    cd "$TEST_INSTALLATION_DIR"
    source src/utils/path-resolver.sh
    initialize_path_resolver
    
    ! resolve_resource_path "nonexistent/file.txt"
}

@test "path_resolver: get_effective_config_directory handles local installation" {
    cd "$TEST_INSTALLATION_DIR"
    source src/utils/path-resolver.sh
    initialize_path_resolver
    
    local config_dir
    config_dir=$(get_effective_config_directory)
    
    [[ "$config_dir" == "$TEST_INSTALLATION_DIR/config" ]]
}

@test "path_resolver: get_effective_config_directory handles global installation" {
    cd "$TEST_INSTALLATION_DIR"
    export CLAUDE_AUTO_RESUME_HOME="$TEST_INSTALLATION_DIR"
    # HOME is already set by default_setup
    
    source src/utils/path-resolver.sh
    initialize_path_resolver
    
    local config_dir
    config_dir=$(get_effective_config_directory)
    
    # Should fallback to installation config since no user config exists
    [[ "$config_dir" == "$TEST_INSTALLATION_DIR/config" ]]
}

# ===============================================================================
# GLOBAL INSTALLATION TESTS
# ===============================================================================

@test "install_global: help command works" {
    cd "$TEST_INSTALLATION_DIR"
    
    run scripts/install-global.sh --help
    
    [ "$status" -eq 0 ]
    [[ "$output" == *"Claude Auto-Resume Global Installation Script"* ]]
}

@test "install_global: validate command checks installation" {
    cd "$TEST_INSTALLATION_DIR"
    
    run scripts/install-global.sh --validate
    
    # Should fail since no global installation exists
    [ "$status" -ne 0 ]
}

@test "install_global: install creates wrapper script" {
    cd "$TEST_INSTALLATION_DIR"
    
    run scripts/install-global.sh --install --target-dir "$TEST_BIN_DIR" --force
    
    [ "$status" -eq 0 ]
    [[ -f "$TEST_BIN_DIR/claude-auto-resume" ]]
    [[ -x "$TEST_BIN_DIR/claude-auto-resume" ]]
}

@test "install_global: wrapper script contains correct installation path" {
    cd "$TEST_INSTALLATION_DIR"
    
    scripts/install-global.sh --install --target-dir "$TEST_BIN_DIR" --force
    
    local wrapper_content
    wrapper_content=$(cat "$TEST_BIN_DIR/claude-auto-resume")
    
    [[ "$wrapper_content" == *"CLAUDE_AUTO_RESUME_HOME=\"$TEST_INSTALLATION_DIR\""* ]]
    [[ "$wrapper_content" == *"exec \"\$CLAUDE_AUTO_RESUME_HOME/src/task-queue.sh\" \"\$@\""* ]]
}

@test "install_global: uninstall removes wrapper script" {
    cd "$TEST_INSTALLATION_DIR"
    
    # Install first
    scripts/install-global.sh --install --target-dir "$TEST_BIN_DIR" --force
    [[ -f "$TEST_BIN_DIR/claude-auto-resume" ]]
    
    # Then uninstall
    run scripts/install-global.sh --uninstall --target-dir "$TEST_BIN_DIR"
    
    [ "$status" -eq 0 ]
    [[ ! -f "$TEST_BIN_DIR/claude-auto-resume" ]]
}

# ===============================================================================
# TASK QUEUE INTEGRATION TESTS
# ===============================================================================

@test "task_queue: works with global path resolution" {
    cd "$TEST_INSTALLATION_DIR"
    export CLAUDE_AUTO_RESUME_HOME="$TEST_INSTALLATION_DIR"
    
    # Test that task-queue.sh can load with global paths
    run src/task-queue.sh --help
    
    [ "$status" -eq 0 ]
    [[ "$output" == *"Claude Auto-Resume - Task Queue System"* ]]
}

@test "task_queue: path resolution works from different directory" {
    cd "$TEST_INSTALLATION_DIR"
    export CLAUDE_AUTO_RESUME_HOME="$TEST_INSTALLATION_DIR"
    
    # Create and install wrapper
    scripts/install-global.sh --install --target-dir "$TEST_BIN_DIR" --force
    
    # Test from different directory
    cd "$TEST_HOME"
    run "$TEST_BIN_DIR/claude-auto-resume" --help
    
    [ "$status" -eq 0 ]
    [[ "$output" == *"Claude Auto-Resume - Task Queue System"* ]]
}

# ===============================================================================
# SETUP INTEGRATION TESTS
# ===============================================================================

@test "setup: global flag is recognized" {
    # Test that setup.sh recognizes --global flag
    # (This tests the argument parsing logic)
    
    cd "$PROJECT_ROOT"
    
    # Create a wrapper that just parses arguments and prints configuration
    cat > "$BATS_TEST_TMPDIR/test-setup.sh" << 'EOF'
#!/usr/bin/env bash
source scripts/setup.sh

# Override main function to just parse and report
main() {
    parse_arguments "$@"
    echo "GLOBAL_INSTALLATION=$GLOBAL_INSTALLATION"
}
EOF
    chmod +x "$BATS_TEST_TMPDIR/test-setup.sh"
    
    # Test without --global
    run "$BATS_TEST_TMPDIR/test-setup.sh"
    [[ "$output" == *"GLOBAL_INSTALLATION=false"* ]]
    
    # Test with --global
    run "$BATS_TEST_TMPDIR/test-setup.sh" --global
    [[ "$output" == *"GLOBAL_INSTALLATION=true"* ]]
}

# ===============================================================================
# CROSS-PLATFORM TESTS
# ===============================================================================

@test "platform: detect_platform works on current system" {
    cd "$TEST_INSTALLATION_DIR"
    source scripts/install-global.sh
    
    local platform
    platform=$(detect_platform)
    
    # Should return one of the supported platforms
    [[ "$platform" == "macos" || "$platform" == "linux" || "$platform" == "unsupported" ]]
}

@test "platform: get_system_bin_directory returns valid directory" {
    cd "$TEST_INSTALLATION_DIR"
    source scripts/install-global.sh
    
    local bin_dir
    bin_dir=$(get_system_bin_directory)
    
    # Should return a directory path
    [[ "$bin_dir" =~ ^/.* ]]
    [[ "$bin_dir" == *"/bin" ]]
}

# ===============================================================================
# ERROR HANDLING TESTS
# ===============================================================================

@test "error_handling: installation fails gracefully with missing files" {
    cd "$TEST_INSTALLATION_DIR"
    
    # Remove required file
    rm src/task-queue.sh
    
    run scripts/install-global.sh --install --target-dir "$TEST_BIN_DIR"
    
    [ "$status" -ne 0 ]
    [[ "$output" == *"Main script not found"* ]]
}

@test "error_handling: path resolution handles missing installation directory" {
    # Test with completely invalid installation directory
    export CLAUDE_AUTO_RESUME_HOME="/nonexistent/directory"
    
    cd "$TEST_INSTALLATION_DIR"
    source src/utils/path-resolver.sh
    
    # Should handle missing directory gracefully
    run initialize_path_resolver
    
    # May fail, but shouldn't crash
    [[ -n "$output" || "$status" -ne 0 ]]
}