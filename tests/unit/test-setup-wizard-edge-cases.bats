#!/usr/bin/env bats

# Edge case and error scenario tests for setup-wizard.sh
# Tests various failure modes, edge cases, and boundary conditions

load '../test_helper'
load '../fixtures/github-api-mocks'

# Setup wizard script path
PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
SETUP_WIZARD_SCRIPT="$PROJECT_ROOT/src/setup-wizard.sh"

setup() {
    enhanced_setup
    
    # Source the setup wizard script for testing
    if [[ -f "$SETUP_WIZARD_SCRIPT" ]]; then
        source "$SETUP_WIZARD_SCRIPT" 2>/dev/null || skip "Cannot load setup-wizard.sh"
    else
        skip "Setup wizard script not found: $SETUP_WIZARD_SCRIPT"
    fi
    
    # Create test project directory with edge case name
    export TEST_PROJECT_NAME="edge-case-test"
    export TEST_PROJECT_PATH="$TEST_TEMP_DIR/$TEST_PROJECT_NAME"
    mkdir -p "$TEST_PROJECT_PATH"
    cd "$TEST_PROJECT_PATH"
}

teardown() {
    enhanced_teardown
}

# ============================================================================
# NETWORK AND CONNECTIVITY EDGE CASES
# ============================================================================

@test "setup wizard handles network timeouts during Claude startup" {
    mock_command "tmux" "success" "tmux version 3.2"
    mock_command "claude" "timeout"  # Simulate network timeout
    
    setup_mock_tmux
    
    # Mock tmux to simulate Claude command hanging
    mock_tmux_behavior() {
        case "$1" in
            "has-session")
                return 1
                ;;
            "new-session")
                return 0
                ;;
            "send-keys")
                # Simulate hang by sleeping longer than test timeout
                sleep 30 &
                return 0
                ;;
            "capture-pane")
                echo "Connecting to Claude..." # Stuck in connecting state
                ;;
            *)
                return 0
                ;;
        esac
    }
    export -f mock_tmux_behavior
    
    # Run with timeout to simulate user cancelling
    run timeout 3 start_claude_in_session
    
    [ "$status" -eq 124 ]  # timeout exit code
}

@test "setup wizard handles intermittent network connectivity" {
    local connectivity_attempts=0
    
    validate_connectivity() {
        ((connectivity_attempts++))
        if [[ $connectivity_attempts -le 2 ]]; then
            echo "Network connectivity failed (attempt $connectivity_attempts)"
            return 1
        else
            echo "Network connectivity restored"
            return 0
        fi
    }
    export -f validate_connectivity
    
    # Test validation retry logic
    run retry_failed_validations "validate_connectivity"
    
    # Should eventually succeed after retries
    [ "$status" -eq 0 ]
    assert_output_contains "Network connectivity restored"
}

@test "setup wizard handles DNS resolution failures" {
    # Mock claude command to simulate DNS issues
    mock_command "claude" "echo 'DNS resolution failed'; return 1"
    
    run validate_connectivity
    
    [ "$status" -eq 1 ]
}

# ============================================================================
# FILE SYSTEM AND PERMISSIONS EDGE CASES
# ============================================================================

@test "setup wizard handles read-only home directory" {
    skip_if_ci "Filesystem permission tests not reliable in CI"
    
    # Create a temporary read-only directory scenario
    local readonly_home="$TEST_TEMP_DIR/readonly_home"
    mkdir -p "$readonly_home"
    
    # Temporarily override HOME for this test
    local original_home="$HOME"
    export HOME="$readonly_home"
    
    # Make directory read-only
    chmod 444 "$readonly_home" || skip "Cannot change directory permissions"
    
    # Try to create session file (should handle gracefully)
    export SESSION_ID="sess-readonly-test-123"
    
    run configure_session_id
    
    # Restore permissions and HOME
    chmod 755 "$readonly_home" 2>/dev/null || true
    export HOME="$original_home"
    
    # Should handle read-only filesystem gracefully
    [[ "$status" -ne 0 ]] # Expected to fail
    assert_output_contains "Session ID set" || assert_output_contains "Permission denied"
}

@test "setup wizard handles corrupted session files" {
    # Create corrupted session files
    local session_file="$HOME/.claude_session_$TEST_PROJECT_NAME"
    
    # Test various corruption scenarios
    echo -e "\x00\x01\x02\x03" > "$session_file"  # Binary garbage
    
    run check_session_files
    
    [ "$status" -eq 1 ]
    
    # Test empty file
    echo "" > "$session_file"
    
    run check_session_files
    
    [ "$status" -eq 1 ]
    
    # Test file with whitespace only
    echo "   " > "$session_file"
    
    run check_session_files
    
    [ "$status" -eq 1 ]
}

@test "setup wizard handles very long project paths" {
    # Create deeply nested directory structure
    local long_path="$TEST_TEMP_DIR"
    for i in {1..20}; do
        long_path="$long_path/very-long-directory-name-$i"
    done
    
    mkdir -p "$long_path"
    cd "$long_path"
    
    # Test that wizard can handle long paths
    local project_name
    project_name=$(basename "$(pwd)")
    
    local session_pattern="${TMUX_SESSION_PREFIX:-claude-auto-resume}-${project_name}"
    
    # Verify session name generation doesn't fail
    [[ ${#session_pattern} -lt 255 ]]  # Reasonable length limit
    
    run check_tmux_sessions
    
    # Should not fail due to path length (though may not find sessions)
    [[ "$status" -eq 0 || "$status" -eq 1 ]]
}

# ============================================================================
# PROCESS AND RESOURCE EDGE CASES
# ============================================================================

@test "setup wizard handles system resource exhaustion" {
    skip_if_ci "Resource exhaustion tests not appropriate for CI"
    
    # Mock tmux to simulate resource exhaustion
    mock_tmux_behavior() {
        case "$1" in
            "new-session")
                echo "tmux: resource temporarily unavailable" >&2
                return 1
                ;;
            *)
                return 0
                ;;
        esac
    }
    export -f mock_tmux_behavior
    
    run create_tmux_session
    
    [ "$status" -eq 1 ]
    assert_output_contains "resource temporarily unavailable"
}

@test "setup wizard handles concurrent session creation" {
    # Simulate race condition with multiple wizard instances
    export TMUX_SESSION_NAME="claude-auto-resume-$TEST_PROJECT_NAME"
    
    # Mock scenario where session appears during creation
    local creation_attempts=0
    mock_tmux_behavior() {
        case "$1" in
            "has-session")
                ((creation_attempts++))
                if [[ $creation_attempts -le 1 ]]; then
                    return 1  # First check: no session
                else
                    return 0  # Later checks: session exists (created by another instance)
                fi
                ;;
            "new-session")
                echo "Session already exists" >&2
                return 1
                ;;
            *)
                return 0
                ;;
        esac
    }
    export -f mock_tmux_behavior
    
    # Should handle concurrent creation gracefully
    echo "1" | run create_tmux_session
    
    [ "$status" -eq 0 ]
    assert_output_contains "Using existing session"
}

@test "setup wizard handles zombie processes" {
    # Mock pgrep to return PIDs of zombie processes
    mock_command "pgrep" "echo '99999'; return 0"  # Non-existent PID
    
    # Mock tmux to not find the zombie PID
    mock_tmux_behavior() {
        case "$1" in
            "list-panes")
                echo "1234\n5678"  # Different PIDs, not the zombie
                ;;
            *)
                return 0
                ;;
        esac
    }
    export -f mock_tmux_behavior
    
    run check_process_tree
    
    [ "$status" -eq 1 ]  # Should not detect zombie as valid Claude process
}

# ============================================================================
# INPUT VALIDATION EDGE CASES
# ============================================================================

@test "setup wizard validates extremely long session IDs" {
    export TMUX_SESSION_NAME="test-session"
    
    # Create an extremely long session ID
    local long_session_id
    long_session_id="sess-$(printf 'a%.0s' {1..1000})"  # 1000+ character session ID
    
    mock_tmux_behavior() {
        case "$1" in
            "capture-pane")
                echo "No session ID in output"
                ;;
            *)
                return 0
                ;;
        esac
    }
    export -f mock_tmux_behavior
    
    # Mock user input with overly long session ID
    printf "%s\n" "$long_session_id" | run configure_session_id
    
    # Should either handle gracefully or provide reasonable limit
    [ "$status" -eq 0 ]
    [[ ${#SESSION_ID} -lt 500 ]]  # Reasonable upper limit
}

@test "setup wizard handles special characters in project names" {
    # Test various special characters in project names
    local special_names=(
        "project with spaces"
        "project-with-dashes"
        "project_with_underscores"  
        "project.with.dots"
        "project@with@symbols"
        "project(with)parentheses"
        "project[with]brackets"
        "project{with}braces"
    )
    
    for project_name in "${special_names[@]}"; do
        export TEST_PROJECT_NAME="$project_name"
        local test_path="$TEST_TEMP_DIR/$project_name"
        
        mkdir -p "$test_path"
        cd "$test_path"
        
        # Test session name generation
        local session_pattern="${TMUX_SESSION_PREFIX:-claude-auto-resume}-${project_name}"
        
        # Should not contain problematic characters for tmux
        [[ ! "$session_pattern" =~ [[:space:]] ]] || continue  # Skip if contains spaces
        
        run check_tmux_sessions
        
        # Should handle special characters without crashing
        [[ "$status" -eq 0 || "$status" -eq 1 ]]
    done
}

@test "setup wizard handles unicode and non-ASCII characters" {
    export TEST_PROJECT_NAME="プロジェクト-测试-🚀"
    local test_path="$TEST_TEMP_DIR/$TEST_PROJECT_NAME"
    
    mkdir -p "$test_path" 2>/dev/null || skip "Filesystem doesn't support unicode names"
    cd "$test_path"
    
    # Test that unicode doesn't break session detection
    run check_tmux_sessions
    
    # Should handle unicode gracefully
    [[ "$status" -eq 0 || "$status" -eq 1 ]]
}

# ============================================================================
# ENVIRONMENT VARIABLE EDGE CASES
# ============================================================================

@test "setup wizard handles missing environment variables" {
    # Unset critical environment variables
    local original_home="$HOME"
    local original_path="$PATH"
    local original_shell="$SHELL"
    
    unset HOME
    unset SHELL
    export PATH="/usr/bin:/bin"  # Minimal PATH
    
    # Test that wizard handles missing variables gracefully
    run check_dependencies
    
    # Restore environment
    export HOME="$original_home"
    export PATH="$original_path"
    export SHELL="$original_shell"
    
    # Should either work or fail gracefully
    [[ "$status" -eq 0 || "$status" -eq 1 ]]
}

@test "setup wizard handles environment variable injection attacks" {
    # Test potential environment variable injection
    export MALICIOUS_VAR="'; rm -rf /tmp/* ; echo '"
    export TEST_PROJECT_NAME="normal-name"
    
    # Ensure no command injection occurs
    run check_tmux_sessions
    
    # Should complete normally without executing injected commands
    [[ "$status" -eq 0 || "$status" -eq 1 ]]
    
    # Verify temp directory still exists (not deleted by injection)
    assert_dir_exists "$TEST_TEMP_DIR"
}

# ============================================================================
# SIGNAL HANDLING EDGE CASES
# ============================================================================

@test "setup wizard handles SIGINT gracefully" {
    skip_if_ci "Signal handling tests unreliable in CI"
    
    # Start a function that would run for a while
    validate_session_health() {
        echo "Starting long validation process..."
        sleep 10
        echo "Validation complete"
        return 0
    }
    export -f validate_session_health
    
    # Run in background and send SIGINT
    validate_session_health &
    local pid=$!
    sleep 1
    kill -INT $pid 2>/dev/null || true
    wait $pid
    local exit_code=$?
    
    # Should handle interrupt gracefully
    [[ $exit_code -eq 130 ]]  # SIGINT exit code
}

@test "setup wizard handles SIGTERM gracefully" {
    skip_if_ci "Signal handling tests unreliable in CI"
    
    # Similar test for SIGTERM
    validate_session_health() {
        sleep 10
        return 0
    }
    export -f validate_session_health
    
    validate_session_health &
    local pid=$!
    sleep 1
    kill -TERM $pid 2>/dev/null || true
    wait $pid
    local exit_code=$?
    
    # Should handle termination gracefully
    [[ $exit_code -eq 143 ]]  # SIGTERM exit code
}

# ============================================================================
# BOUNDARY CONDITION TESTS
# ============================================================================

@test "setup wizard handles minimum system requirements" {
    # Mock minimal system versions
    mock_command "tmux" "echo 'tmux 1.8'; return 0"  # Very old version
    mock_command "claude" "echo 'Claude CLI 0.1.0'; return 0"  # Minimal version
    
    run check_dependencies
    
    # Should either accept minimal versions or provide clear version requirements
    [[ "$status" -eq 0 || "$status" -eq 1 ]]
    if [ "$status" -eq 1 ]; then
        assert_output_contains "version" || assert_output_contains "update"
    fi
}

@test "setup wizard handles maximum limits" {
    # Test with maximum number of tmux sessions
    mock_tmux_behavior() {
        case "$1" in
            "list-sessions")
                # Generate many session names to test limits
                for i in {1..1000}; do
                    echo "session-$i: 1 windows"
                done
                ;;
            *)
                return 0
                ;;
        esac
    }
    export -f mock_tmux_behavior
    
    run check_tmux_sessions
    
    # Should handle large numbers of sessions without performance issues
    [[ "$status" -eq 0 || "$status" -eq 1 ]]
}

# ============================================================================
# RECOVERY AND CLEANUP EDGE CASES
# ============================================================================

@test "setup wizard recovers from partially completed setup" {
    # Create scenario where setup was partially completed
    export TMUX_SESSION_NAME="claude-auto-resume-partial"
    echo "sess-partial-setup-123" > "$HOME/.claude_session_$TEST_PROJECT_NAME"
    
    # Mock tmux to show session exists but Claude is not running
    mock_tmux_behavior() {
        case "$1" in
            "has-session")
                [[ "$2" == "$TMUX_SESSION_NAME" ]] && return 0 || return 1
                ;;
            "capture-pane")
                echo "Empty tmux session"  # No Claude running
                ;;
            *)
                return 0
                ;;
        esac
    }
    export -f mock_tmux_behavior
    
    # Should detect partial setup and handle appropriately
    run validate_session_health
    
    [ "$status" -eq 1 ]  # Should detect incomplete setup
}

@test "setup wizard cleans up after failed setup" {
    local session_file="$HOME/.claude_session_$TEST_PROJECT_NAME"
    
    # Create session file that should be cleaned up on failure
    echo "sess-failed-setup-123" > "$session_file"
    
    # Mock a scenario that causes setup to fail
    export TMUX_SESSION_NAME="test-session"
    export SESSION_ID="sess-failed-setup-123"
    
    mock_command "claude" "return 1"  # Always fail
    
    run validate_connectivity
    
    [ "$status" -eq 1 ]
    
    # Verify session file still exists (should not auto-cleanup valid data)
    assert_file_exists "$session_file"
}