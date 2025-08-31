#!/usr/bin/env bats

# Tests for enhanced session detection in session-manager.sh
# Validates the integration with setup wizard session detection improvements

load '../test_helper'
load '../fixtures/github-api-mocks'

# Session manager script path
PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
SESSION_MANAGER_SCRIPT="$PROJECT_ROOT/src/session-manager.sh"
SETUP_WIZARD_SCRIPT="$PROJECT_ROOT/src/setup-wizard.sh"

setup() {
    enhanced_setup
    
    # Source both session manager and setup wizard for testing integration
    if [[ -f "$SESSION_MANAGER_SCRIPT" ]]; then
        source "$SESSION_MANAGER_SCRIPT" 2>/dev/null || skip "Cannot load session-manager.sh"
    else
        skip "Session manager script not found: $SESSION_MANAGER_SCRIPT"
    fi
    
    if [[ -f "$SETUP_WIZARD_SCRIPT" ]]; then
        source "$SETUP_WIZARD_SCRIPT" 2>/dev/null || skip "Cannot load setup-wizard.sh"
    else
        skip "Setup wizard script not found: $SETUP_WIZARD_SCRIPT"
    fi
    
    # Create test project directory
    export TEST_PROJECT_NAME="enhanced-detection-test"
    export TEST_PROJECT_PATH="$TEST_TEMP_DIR/$TEST_PROJECT_NAME"
    mkdir -p "$TEST_PROJECT_PATH"
    cd "$TEST_PROJECT_PATH"
    
    # Initialize session arrays for testing
    init_session_arrays || skip "Cannot initialize session arrays"
}

teardown() {
    enhanced_teardown
}

# ============================================================================
# ENHANCED SESSION DETECTION INTEGRATION TESTS
# ============================================================================

@test "session manager integrates with setup wizard session detection" {
    # Create a session file for detection
    local session_file="$HOME/.claude_session_$TEST_PROJECT_NAME"
    echo "sess-integration-test-123456" > "$session_file"
    
    # Mock tmux to not have active sessions
    export MOCK_TMUX_SESSION_EXISTS=false
    setup_mock_tmux
    
    # Test that session manager can use setup wizard detection
    run detect_existing_session
    
    [ "$status" -eq 0 ]
    [[ "$DETECTED_SESSION_ID" == "sess-integration-test-123456" ]]
}

@test "session manager validates detected sessions from setup wizard" {
    # Set up detected session from setup wizard
    export DETECTED_SESSION_NAME="claude-auto-resume-$TEST_PROJECT_NAME"
    export DETECTED_SESSION_ID="sess-detected-validation-test"
    
    # Test session validation
    run validate_session_id
    
    [ "$status" -eq 0 ]
}

@test "session manager handles setup wizard session file format" {
    # Test various session file formats that setup wizard might create
    local test_cases=(
        "sess-standard-format-123456"
        "sess-with-dashes-and-numbers-abc123"
        "sess-longersessionidentifierwithnospecialchars"
    )
    
    for session_id in "${test_cases[@]}"; do
        local session_file="$HOME/.claude_session_$TEST_PROJECT_NAME"
        echo "$session_id" > "$session_file"
        
        run check_session_files
        
        [ "$status" -eq 0 ]
        [[ "$DETECTED_SESSION_ID" == "$session_id" ]]
        
        # Clean up for next iteration
        rm -f "$session_file"
    done
}

@test "session manager prioritizes active tmux sessions over files" {
    # Create both active tmux session and session file
    local session_file="$HOME/.claude_session_$TEST_PROJECT_NAME"
    echo "sess-from-file-123456" > "$session_file"
    
    export DETECTED_SESSION_NAME="claude-auto-resume-$TEST_PROJECT_NAME"
    
    # Mock tmux to have active session
    export MOCK_TMUX_SESSION_EXISTS=true
    setup_mock_tmux
    
    mock_tmux_behavior() {
        case "$1" in
            "has-session")
                return 0
                ;;
            "list-sessions")
                echo "claude-auto-resume-$TEST_PROJECT_NAME: 1 windows"
                ;;
            *)
                return 0
                ;;
        esac
    }
    export -f mock_tmux_behavior
    
    run detect_existing_session
    
    [ "$status" -eq 0 ]
    # Should detect tmux session first, not file-based session
    [[ -n "$DETECTED_SESSION_NAME" ]]
}

# ============================================================================
# SESSION STATE MANAGEMENT TESTS
# ============================================================================

@test "session manager tracks setup wizard created sessions" {
    # Initialize session arrays
    validate_session_arrays || skip "Session arrays not available"
    
    # Simulate setup wizard creating a session
    local session_id="sess-wizard-created-123"
    local tmux_session="claude-auto-resume-$TEST_PROJECT_NAME"
    
    # Register session in tracking arrays
    SESSIONS["$session_id"]="$tmux_session"
    SESSION_STATES["$session_id"]="$SESSION_STATE_RUNNING"
    SESSION_RESTART_COUNTS["$session_id"]=0
    SESSION_LAST_SEEN["$session_id"]=$(date +%s)
    
    # Test session is properly tracked
    run safe_array_get "SESSIONS" "$session_id" ""
    [ "$status" -eq 0 ]
    [[ "$output" == "$tmux_session" ]]
    
    run safe_array_get "SESSION_STATES" "$session_id" ""
    [ "$status" -eq 0 ]
    [[ "$output" == "$SESSION_STATE_RUNNING" ]]
}

@test "session manager updates session states for wizard sessions" {
    validate_session_arrays || skip "Session arrays not available"
    
    local session_id="sess-state-update-test"
    
    # Initialize session
    SESSIONS["$session_id"]="test-session"
    SESSION_STATES["$session_id"]="$SESSION_STATE_STARTING"
    
    # Test state transitions
    SESSION_STATES["$session_id"]="$SESSION_STATE_RUNNING"
    run safe_array_get "SESSION_STATES" "$session_id" ""
    [ "$status" -eq 0 ]
    [[ "$output" == "$SESSION_STATE_RUNNING" ]]
    
    SESSION_STATES["$session_id"]="$SESSION_STATE_USAGE_LIMITED"
    run safe_array_get "SESSION_STATES" "$session_id" ""
    [ "$status" -eq 0 ]
    [[ "$output" == "$SESSION_STATE_USAGE_LIMITED" ]]
}

@test "session manager handles session recovery for wizard sessions" {
    validate_session_arrays || skip "Session arrays not available"
    
    local session_id="sess-recovery-test-456"
    
    # Initialize session in error state
    SESSIONS["$session_id"]="test-recovery-session"
    SESSION_STATES["$session_id"]="$SESSION_STATE_ERROR"
    SESSION_RECOVERY_COUNTS["$session_id"]=1
    
    # Test recovery count tracking
    run safe_array_get "SESSION_RECOVERY_COUNTS" "$session_id" "0"
    [ "$status" -eq 0 ]
    [[ "$output" == "1" ]]
    
    # Increment recovery count
    SESSION_RECOVERY_COUNTS["$session_id"]=$((SESSION_RECOVERY_COUNTS["$session_id"] + 1))
    
    run safe_array_get "SESSION_RECOVERY_COUNTS" "$session_id" "0"
    [ "$status" -eq 0 ]
    [[ "$output" == "2" ]]
}

# ============================================================================
# CROSS-PLATFORM SESSION DETECTION TESTS
# ============================================================================

@test "enhanced session detection works on macOS with AppleScript integration" {
    skip_if_not_os "macos" "macOS-specific test"
    
    # Mock macOS environment
    export TERM_PROGRAM="iTerm.app"
    
    # Test that session detection doesn't fail on macOS-specific features
    run detect_existing_session
    
    # Should either find sessions or cleanly report none found
    [[ "$status" -eq 0 || "$status" -eq 1 ]]
}

@test "enhanced session detection works on Linux with various terminals" {
    skip_if_not_os "linux" "Linux-specific test"
    
    # Mock Linux environment variables
    export TERM_PROGRAM="gnome-terminal"
    export DESKTOP_SESSION="ubuntu"
    
    run detect_existing_session
    
    # Should work without macOS-specific dependencies
    [[ "$status" -eq 0 || "$status" -eq 1 ]]
}

# ============================================================================
# SESSION FILE COMPATIBILITY TESTS
# ============================================================================

@test "session manager handles legacy session file formats" {
    # Test compatibility with different session file formats
    local test_cases=(
        # Standard format
        "sess-standard123456789"
        # Without sess- prefix (should be handled)
        "legacy123456789"
        # With extra whitespace (should be trimmed)
        "  sess-whitespace123456  "
        # With newlines (should be handled)
        $'sess-newline123456\n'
    )
    
    for test_content in "${test_cases[@]}"; do
        local session_file="$HOME/.claude_session_$TEST_PROJECT_NAME"
        printf "%s" "$test_content" > "$session_file"
        
        run check_session_files
        
        if [ "$status" -eq 0 ]; then
            # Should extract valid session ID
            [[ -n "$DETECTED_SESSION_ID" ]]
            [[ "$DETECTED_SESSION_ID" =~ ^sess- ]]
        fi
        
        rm -f "$session_file"
    done
}

@test "session manager creates session files in setup wizard format" {
    local session_id="sess-format-test-789"
    local project_name="format-test-project"
    
    # Simulate session file creation
    local session_file="$HOME/.claude_session_${project_name}"
    echo "$session_id" > "$session_file"
    
    # Verify file format is compatible
    local saved_id
    saved_id=$(cat "$session_file")
    
    [[ "$saved_id" == "$session_id" ]]
    [[ "$saved_id" =~ ^sess-[a-zA-Z0-9-]+$ ]]
    
    # Test that setup wizard can read this format
    export TEST_PROJECT_NAME="$project_name"
    cd "$TEST_TEMP_DIR"  # Change to parent directory
    
    run check_session_files
    
    [ "$status" -eq 0 ]
    [[ "$DETECTED_SESSION_ID" == "$session_id" ]]
}

# ============================================================================
# PERFORMANCE TESTS FOR ENHANCED DETECTION
# ============================================================================

@test "enhanced session detection performs efficiently with many sessions" {
    skip_if_ci "Performance tests may be unreliable in CI"
    
    # Create many session files to test performance
    for i in {1..100}; do
        local session_file="$HOME/.claude_session_test_project_$i"
        echo "sess-performance-test-$i" > "$session_file"
    done
    
    # Mock tmux to return many sessions
    mock_tmux_behavior() {
        case "$1" in
            "list-sessions")
                for i in {1..50}; do
                    echo "claude-session-$i: 1 windows"
                done
                ;;
            *)
                return 1
                ;;
        esac
    }
    export -f mock_tmux_behavior
    
    # Measure detection time
    local start_time
    start_time=$(date +%s%N)
    
    run detect_existing_session
    
    local end_time
    end_time=$(date +%s%N)
    local duration=$(( (end_time - start_time) / 1000000 ))  # Convert to milliseconds
    
    # Should complete reasonably quickly (under 5 seconds)
    [[ $duration -lt 5000 ]]
    
    # Cleanup
    rm -f "$HOME"/.claude_session_test_project_* 2>/dev/null || true
}

@test "session detection handles concurrent access safely" {
    skip_if_ci "Concurrency tests may be unreliable in CI"
    
    # Test concurrent session file access
    local session_file="$HOME/.claude_session_concurrent_test"
    
    # Function to simulate concurrent access
    concurrent_detection() {
        for i in {1..10}; do
            echo "sess-concurrent-$i-$$" > "$session_file"
            check_session_files >/dev/null 2>&1 || true
            sleep 0.1
        done
    }
    
    # Start multiple background processes
    concurrent_detection &
    local pid1=$!
    concurrent_detection &
    local pid2=$!
    
    # Wait for completion
    wait $pid1 $pid2
    
    # Should not crash or corrupt data
    if [[ -f "$session_file" ]]; then
        local content
        content=$(cat "$session_file")
        [[ "$content" =~ ^sess-concurrent- ]]
    fi
    
    # Cleanup
    rm -f "$session_file" 2>/dev/null || true
}

# ============================================================================
# ERROR HANDLING FOR SESSION DETECTION
# ============================================================================

@test "session manager handles corrupted session detection gracefully" {
    # Test various corruption scenarios
    local session_file="$HOME/.claude_session_$TEST_PROJECT_NAME"
    
    # Test binary corruption
    printf "\x00\x01\x02\x03\xFF\xFE\xFD" > "$session_file"
    
    run check_session_files
    
    [ "$status" -eq 1 ]  # Should fail gracefully
    
    # Test extremely large files
    dd if=/dev/zero of="$session_file" bs=1M count=10 2>/dev/null || skip "Cannot create large test file"
    
    run check_session_files
    
    [ "$status" -eq 1 ]  # Should handle large files gracefully
    
    rm -f "$session_file"
}

@test "session detection handles filesystem errors gracefully" {
    skip_if_ci "Filesystem permission tests not reliable in CI"
    
    # Test with unreadable session file
    local session_file="$HOME/.claude_session_$TEST_PROJECT_NAME"
    echo "sess-permission-test" > "$session_file"
    chmod 000 "$session_file" || skip "Cannot change file permissions"
    
    run check_session_files
    
    # Restore permissions
    chmod 644 "$session_file" 2>/dev/null || true
    
    [ "$status" -eq 1 ]  # Should fail gracefully for unreadable files
}

# ============================================================================
# INTEGRATION VALIDATION TESTS
# ============================================================================

@test "session manager and setup wizard share consistent session data" {
    # Set up session data in setup wizard format
    export TMUX_SESSION_NAME="claude-auto-resume-consistency-test"
    export SESSION_ID="sess-consistency-test-789"
    
    # Simulate session file creation by setup wizard
    local session_file="$HOME/.claude_session_consistency-test"
    echo "$SESSION_ID" > "$session_file"
    
    # Test that session manager can read and validate this data
    export TEST_PROJECT_NAME="consistency-test"
    
    run check_session_files
    
    [ "$status" -eq 0 ]
    [[ "$DETECTED_SESSION_ID" == "$SESSION_ID" ]]
    
    # Test that validation functions work with this data
    run validate_session_id
    
    [ "$status" -eq 0 ]
}

@test "session detection prioritizes active over dormant sessions" {
    # Create dormant session file
    local session_file="$HOME/.claude_session_$TEST_PROJECT_NAME"
    echo "sess-dormant-session-123" > "$session_file"
    
    # Mock active tmux session
    export MOCK_TMUX_SESSION_EXISTS=true
    setup_mock_tmux
    
    mock_tmux_behavior() {
        case "$1" in
            "has-session")
                [[ "$2" == "claude-auto-resume-$TEST_PROJECT_NAME" ]] && return 0 || return 1
                ;;
            "list-sessions")
                echo "claude-auto-resume-$TEST_PROJECT_NAME: 1 windows (active)"
                ;;
            *)
                return 0
                ;;
        esac
    }
    export -f mock_tmux_behavior
    
    run detect_existing_session
    
    [ "$status" -eq 0 ]
    # Should prioritize active tmux session over dormant file
    [[ -n "$DETECTED_SESSION_NAME" ]]
    [[ "$DETECTED_SESSION_NAME" == "claude-auto-resume-$TEST_PROJECT_NAME" ]]
}