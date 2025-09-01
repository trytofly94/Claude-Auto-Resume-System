#!/usr/bin/env bats

# Integration Tests for Global CLI Installation Workflow (Issue #88)
# Tests the complete installation, usage, and uninstallation process

load '../test_helper'

# Setup test environment
setup() {
    export TEST_PROJECT_ROOT="$PROJECT_ROOT"
    export TEST_BIN_DIR="$BATS_TEST_TMPDIR/test-bin"
    export TEST_HOME="$BATS_TEST_TMPDIR/home"
    export TEST_PROJECT_DIR="$BATS_TEST_TMPDIR/test-project"
    
    mkdir -p "$TEST_BIN_DIR"
    mkdir -p "$TEST_HOME"
    mkdir -p "$TEST_PROJECT_DIR"
    
    # Create a temporary PATH that includes our test bin directory
    export ORIGINAL_PATH="$PATH"
    export PATH="$TEST_BIN_DIR:$PATH"
    export HOME="$TEST_HOME"
}

teardown() {
    # Restore original PATH and HOME
    export PATH="$ORIGINAL_PATH"
    export HOME="$ORIGINAL_HOME"
    
    # Clean up test installation
    rm -f "$TEST_BIN_DIR/claude-auto-resume"
    rm -rf "$BATS_TEST_TMPDIR"
    
    unset CLAUDE_AUTO_RESUME_HOME
    unset TEST_PROJECT_ROOT
    unset TEST_BIN_DIR
    unset TEST_HOME
    unset TEST_PROJECT_DIR
}

# ===============================================================================
# COMPLETE INSTALLATION WORKFLOW TESTS
# ===============================================================================

@test "workflow: complete global installation process" {
    cd "$TEST_PROJECT_ROOT"
    
    # Step 1: Install globally
    run scripts/install-global.sh --install --target-dir "$TEST_BIN_DIR" --force
    
    [ "$status" -eq 0 ]
    [[ "$output" == *"Global installation completed successfully"* ]]
    [[ -x "$TEST_BIN_DIR/claude-auto-resume" ]]
}

@test "workflow: global command works from any directory" {
    cd "$TEST_PROJECT_ROOT"
    
    # Install globally
    scripts/install-global.sh --install --target-dir "$TEST_BIN_DIR" --force
    
    # Test from project root
    run claude-auto-resume --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Claude Auto-Resume - Task Queue System"* ]]
    
    # Test from different directory
    cd "$TEST_PROJECT_DIR"
    run claude-auto-resume --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Claude Auto-Resume - Task Queue System"* ]]
    
    # Test from home directory
    cd "$TEST_HOME"
    run claude-auto-resume --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Claude Auto-Resume - Task Queue System"* ]]
}

@test "workflow: version command works globally" {
    cd "$TEST_PROJECT_ROOT"
    
    scripts/install-global.sh --install --target-dir "$TEST_BIN_DIR" --force
    
    cd "$TEST_PROJECT_DIR"
    run claude-auto-resume --version
    
    [ "$status" -eq 0 ]
    [[ "$output" == *"2.0.0"* ]]
}

@test "workflow: status command works from any directory" {
    cd "$TEST_PROJECT_ROOT"
    
    scripts/install-global.sh --install --target-dir "$TEST_BIN_DIR" --force
    
    cd "$TEST_PROJECT_DIR"
    run claude-auto-resume status
    
    [ "$status" -eq 0 ]
    [[ "$output" == *"Queue Status"* ]]
}

@test "workflow: local queue detection works with global installation" {
    cd "$TEST_PROJECT_ROOT"
    
    scripts/install-global.sh --install --target-dir "$TEST_BIN_DIR" --force
    
    # Initialize a local queue in test project
    cd "$TEST_PROJECT_DIR"
    run claude-auto-resume init-local-queue "test-project"
    
    [ "$status" -eq 0 ]
    [[ "$output" == *"Local queue initialized successfully"* ]]
    [[ -d ".claude-tasks" ]]
}

@test "workflow: can add and list tasks globally" {
    cd "$TEST_PROJECT_ROOT"
    
    scripts/install-global.sh --install --target-dir "$TEST_BIN_DIR" --force
    
    # Test from different directory
    cd "$TEST_PROJECT_DIR"
    
    # Initialize local queue first
    claude-auto-resume init-local-queue "test-project"
    
    # Add a task
    run claude-auto-resume add-custom "Test global task"
    [ "$status" -eq 0 ]
    
    # List tasks
    run claude-auto-resume list
    [ "$status" -eq 0 ]
    [[ "$output" == *"Test global task"* ]]
}

# ===============================================================================
# SETUP SCRIPT INTEGRATION TESTS
# ===============================================================================

@test "setup_integration: setup script with global flag" {
    cd "$TEST_PROJECT_ROOT"
    
    # Test setup.sh with --global flag (dry run to avoid full installation)
    run scripts/setup.sh --global --dry-run --non-interactive
    
    [ "$status" -eq 0 ]
    [[ "$output" == *"GLOBAL_INSTALLATION=true"* ]]
    [[ "$output" == *"Would execute:"* && "$output" == *"install-global.sh --install"* ]]
}

# ===============================================================================
# PATH RESOLUTION INTEGRATION TESTS
# ===============================================================================

@test "path_resolution: configuration files resolved correctly" {
    cd "$TEST_PROJECT_ROOT"
    
    scripts/install-global.sh --install --target-dir "$TEST_BIN_DIR" --force
    
    # Test from different directory
    cd "$TEST_PROJECT_DIR"
    
    # Create a test script that checks path resolution
    cat > "$BATS_TEST_TMPDIR/test-paths.sh" << 'EOF'
#!/usr/bin/env bash
export CLAUDE_AUTO_RESUME_HOME="$1"
source "$CLAUDE_AUTO_RESUME_HOME/src/utils/path-resolver.sh"
initialize_path_resolver

echo "Installation dir: $CLAUDE_INSTALLATION_DIR"
echo "Config dir: $CLAUDE_CONFIG_DIR"
echo "Effective config dir: $(get_effective_config_directory)"
echo "Config file exists: $(test -f "$CLAUDE_CONFIG_DIR/default.conf" && echo "yes" || echo "no")"
EOF
    chmod +x "$BATS_TEST_TMPDIR/test-paths.sh"
    
    run "$BATS_TEST_TMPDIR/test-paths.sh" "$TEST_PROJECT_ROOT"
    
    [ "$status" -eq 0 ]
    [[ "$output" == *"Installation dir: $TEST_PROJECT_ROOT"* ]]
    [[ "$output" == *"Config file exists: yes"* ]]
}

@test "path_resolution: working directory context detection" {
    cd "$TEST_PROJECT_ROOT"
    
    scripts/install-global.sh --install --target-dir "$TEST_BIN_DIR" --force
    
    # Test context detection from regular directory
    cd "$TEST_PROJECT_DIR"
    
    # Create test script for context detection
    cat > "$BATS_TEST_TMPDIR/test-context.sh" << 'EOF'
#!/usr/bin/env bash
export CLAUDE_AUTO_RESUME_HOME="$1"
source "$CLAUDE_AUTO_RESUME_HOME/src/utils/path-resolver.sh"
initialize_path_resolver

get_working_directory_context | jq -r .type
EOF
    chmod +x "$BATS_TEST_TMPDIR/test-context.sh"
    
    run "$BATS_TEST_TMPDIR/test-context.sh" "$TEST_PROJECT_ROOT"
    [ "$status" -eq 0 ]
    [[ "$output" == "regular_directory" ]]
    
    # Test with local queue
    claude-auto-resume init-local-queue "test-project"
    run "$BATS_TEST_TMPDIR/test-context.sh" "$TEST_PROJECT_ROOT"
    [ "$status" -eq 0 ]
    [[ "$output" == "project_with_local_queue" ]]
}

# ===============================================================================
# ERROR HANDLING AND RECOVERY TESTS
# ===============================================================================

@test "error_handling: graceful handling of missing installation" {
    # Test global command when installation is broken
    cd "$TEST_PROJECT_ROOT"
    
    scripts/install-global.sh --install --target-dir "$TEST_BIN_DIR" --force
    
    # Break the installation by removing key files
    rm -f "$TEST_PROJECT_ROOT/src/task-queue.sh"
    
    cd "$TEST_PROJECT_DIR"
    run claude-auto-resume --help
    
    # Should fail gracefully, not crash
    [ "$status" -ne 0 ]
}

@test "error_handling: handles corrupted wrapper script" {
    cd "$TEST_PROJECT_ROOT"
    
    scripts/install-global.sh --install --target-dir "$TEST_BIN_DIR" --force
    
    # Corrupt the wrapper script
    echo "broken wrapper" > "$TEST_BIN_DIR/claude-auto-resume"
    
    cd "$TEST_PROJECT_DIR"
    run claude-auto-resume --help
    
    # Should fail gracefully
    [ "$status" -ne 0 ]
}

# ===============================================================================
# UNINSTALLATION TESTS
# ===============================================================================

@test "uninstallation: complete removal process" {
    cd "$TEST_PROJECT_ROOT"
    
    # Install first
    scripts/install-global.sh --install --target-dir "$TEST_BIN_DIR" --force
    [[ -x "$TEST_BIN_DIR/claude-auto-resume" ]]
    
    # Verify it works
    cd "$TEST_PROJECT_DIR"
    run claude-auto-resume --help
    [ "$status" -eq 0 ]
    
    # Uninstall
    cd "$TEST_PROJECT_ROOT"
    run scripts/install-global.sh --uninstall --target-dir "$TEST_BIN_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Global uninstallation completed successfully"* ]]
    
    # Verify removal
    [[ ! -f "$TEST_BIN_DIR/claude-auto-resume" ]]
    
    # Verify command no longer works
    cd "$TEST_PROJECT_DIR"
    run claude-auto-resume --help
    [ "$status" -ne 0 ]
}

# ===============================================================================
# BACKWARD COMPATIBILITY TESTS
# ===============================================================================

@test "backward_compatibility: local execution still works" {
    cd "$TEST_PROJECT_ROOT"
    
    # Test that local execution works even with global installation available
    scripts/install-global.sh --install --target-dir "$TEST_BIN_DIR" --force
    
    # Direct execution should still work
    run ./src/task-queue.sh --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Claude Auto-Resume - Task Queue System"* ]]
}

@test "backward_compatibility: existing scripts still work" {
    cd "$TEST_PROJECT_ROOT"
    
    scripts/install-global.sh --install --target-dir "$TEST_BIN_DIR" --force
    
    # Test that hybrid-monitor.sh still works
    run ./src/hybrid-monitor.sh --help
    [ "$status" -eq 0 ]
}

# ===============================================================================
# PERFORMANCE TESTS
# ===============================================================================

@test "performance: global command startup time is reasonable" {
    cd "$TEST_PROJECT_ROOT"
    
    scripts/install-global.sh --install --target-dir "$TEST_BIN_DIR" --force
    
    cd "$TEST_PROJECT_DIR"
    
    # Measure startup time (should be under 2 seconds)
    local start_time end_time duration
    start_time=$(date +%s)
    claude-auto-resume --help > /dev/null
    end_time=$(date +%s)
    duration=$((end_time - start_time))
    
    # Should complete quickly (allowing some margin for CI environments)
    [[ $duration -le 5 ]]
}

# ===============================================================================
# MULTI-PROJECT TESTS
# ===============================================================================

@test "multi_project: different projects have isolated contexts" {
    cd "$TEST_PROJECT_ROOT"
    
    scripts/install-global.sh --install --target-dir "$TEST_BIN_DIR" --force
    
    # Create two test projects
    local project1="$BATS_TEST_TMPDIR/project1"
    local project2="$BATS_TEST_TMPDIR/project2"
    mkdir -p "$project1" "$project2"
    
    # Initialize local queues in both
    cd "$project1"
    claude-auto-resume init-local-queue "project1"
    claude-auto-resume add-custom "Task for project 1"
    
    cd "$project2"  
    claude-auto-resume init-local-queue "project2"
    claude-auto-resume add-custom "Task for project 2"
    
    # Verify isolation
    cd "$project1"
    run claude-auto-resume list
    [ "$status" -eq 0 ]
    [[ "$output" == *"Task for project 1"* ]]
    [[ "$output" != *"Task for project 2"* ]]
    
    cd "$project2"
    run claude-auto-resume list  
    [ "$status" -eq 0 ]
    [[ "$output" == *"Task for project 2"* ]]
    [[ "$output" != *"Task for project 1"* ]]
}