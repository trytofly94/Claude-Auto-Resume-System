#!/usr/bin/env bats

# Unit tests for setup-wizard.sh core functionality
# Tests the core setup wizard functions and session detection

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
    
    # Create test project directory
    export TEST_PROJECT_NAME="test-wizard-project"
    export TEST_PROJECT_PATH="$TEST_TEMP_DIR/$TEST_PROJECT_NAME"
    mkdir -p "$TEST_PROJECT_PATH"
    cd "$TEST_PROJECT_PATH"
}

teardown() {
    enhanced_teardown
}

# ============================================================================
# SESSION DETECTION TESTS
# ============================================================================

@test "detect_existing_session detects tmux sessions correctly" {
    # Mock tmux to return existing sessions
    export MOCK_TMUX_SESSION_EXISTS=true
    setup_mock_tmux
    
    # Override tmux behavior to simulate found session
    mock_tmux_behavior() {
        case "$1" in
            "has-session")
                return 0
                ;;
            "list-sessions")
                echo "claude-auto-resume-test-wizard-project: 1 windows (created Mon Aug 31 10:00:00 2025)"
                ;;
            *)
                return 0
                ;;
        esac
    }
    export -f mock_tmux_behavior
    
    run detect_existing_session
    
    [ "$status" -eq 0 ]
    [[ "$DETECTED_SESSION_NAME" == "claude-auto-resume-test-wizard-project" ]]
}

@test "detect_existing_session detects session files correctly" {
    # Mock tmux to not find sessions
    export MOCK_TMUX_SESSION_EXISTS=false
    setup_mock_tmux
    
    # Create a mock session file
    local session_file="$HOME/.claude_session_$TEST_PROJECT_NAME"
    echo "sess-testfile1234567890" > "$session_file"
    
    run detect_existing_session
    
    [ "$status" -eq 0 ]
    [[ "$DETECTED_SESSION_ID" == "sess-testfile1234567890" ]]
}

@test "detect_existing_session returns false when no sessions found" {
    # Mock all detection methods to fail
    export MOCK_TMUX_SESSION_EXISTS=false
    setup_mock_tmux
    
    # Make sure no session files exist
    rm -f "$HOME"/.claude_session_* "$HOME"/.claude_auto_resume_* "$(pwd)/.claude_session" 2>/dev/null || true
    
    # Mock pgrep to return no processes
    mock_command "pgrep" "return 1"
    
    run detect_existing_session
    
    [ "$status" -eq 1 ]
}

@test "check_tmux_sessions handles project names with spaces" {
    export TEST_PROJECT_NAME="test project with spaces"
    export TEST_PROJECT_PATH="$TEST_TEMP_DIR/$TEST_PROJECT_NAME"
    mkdir -p "$TEST_PROJECT_PATH"
    cd "$TEST_PROJECT_PATH"
    
    # Mock tmux to handle session names with spaces
    mock_tmux_behavior() {
        case "$1" in
            "has-session")
                if [[ "$2" =~ .*spaces.* ]]; then
                    return 0
                else
                    return 1
                fi
                ;;
            *)
                return 0
                ;;
        esac
    }
    export -f mock_tmux_behavior
    
    run check_tmux_sessions
    
    [ "$status" -eq 0 ]
}

@test "check_process_tree detects claude processes" {
    # Mock pgrep to return a PID
    mock_command "pgrep" "echo '12345'; return 0"
    
    # Mock tmux list-panes to show the PID
    mock_tmux_behavior() {
        case "$1" in
            "list-panes")
                echo "12345"
                ;;
            *)
                return 0
                ;;
        esac
    }
    export -f mock_tmux_behavior
    
    run check_process_tree
    
    [ "$status" -eq 0 ]
}

# ============================================================================
# DEPENDENCY CHECK TESTS
# ============================================================================

@test "check_dependencies passes with all required commands available" {
    # Mock all required commands as available
    mock_command "tmux" "echo 'tmux version 3.2'; return 0"
    mock_command "claude" "echo 'Claude CLI version 1.0.0'; return 0"
    mock_command "claunch" "echo 'claunch v1.0.0'; return 0"
    mock_command "jq" "echo 'jq-1.6'; return 0"
    
    run check_dependencies
    
    [ "$status" -eq 0 ]
    assert_output_contains "Dependencies check completed successfully"
}

@test "check_dependencies fails when tmux is missing" {
    # Mock tmux as unavailable
    unmock_command "tmux"
    
    # Mock other required commands as available
    mock_command "claude" "echo 'Claude CLI version 1.0.0'; return 0"
    
    run check_dependencies
    
    [ "$status" -eq 1 ]
    assert_output_contains "Missing required dependencies: tmux"
}

@test "check_dependencies fails when claude is missing" {
    # Mock claude as unavailable
    unmock_command "claude"
    
    # Mock other required commands as available
    mock_command "tmux" "echo 'tmux version 3.2'; return 0"
    
    run check_dependencies
    
    [ "$status" -eq 1 ]
    assert_output_contains "Missing required dependencies: claude"
}

@test "check_dependencies warns about missing optional commands" {
    # Mock required commands as available
    mock_command "tmux" "echo 'tmux version 3.2'; return 0"
    mock_command "claude" "echo 'Claude CLI version 1.0.0'; return 0"
    
    # Mock optional commands as unavailable
    unmock_command "claunch"
    unmock_command "jq"
    
    run check_dependencies
    
    [ "$status" -eq 0 ]
    assert_output_contains "Optional dependencies missing: claunch jq"
    assert_output_contains "Dependencies check completed successfully"
}

# ============================================================================
# TMUX SESSION CREATION TESTS
# ============================================================================

@test "create_tmux_session creates new session successfully" {
    # Mock tmux session creation
    export MOCK_TMUX_SESSION_EXISTS=false
    setup_mock_tmux
    
    mock_tmux_behavior() {
        case "$1" in
            "has-session")
                # First call: session doesn't exist, second call: session exists
                if [[ -z "${TMUX_SESSION_CHECKED:-}" ]]; then
                    export TMUX_SESSION_CHECKED=true
                    return 1
                else
                    return 0
                fi
                ;;
            "new-session")
                echo "Created session: $2"
                return 0
                ;;
            *)
                return 0
                ;;
        esac
    }
    export -f mock_tmux_behavior
    
    # Mock user input to continue
    echo "" | run create_tmux_session
    
    [ "$status" -eq 0 ]
    assert_output_contains "tmux session created successfully"
    [[ -n "$TMUX_SESSION_NAME" ]]
}

@test "create_tmux_session handles existing session gracefully" {
    # Mock existing session
    export MOCK_TMUX_SESSION_EXISTS=true
    setup_mock_tmux
    
    mock_tmux_behavior() {
        case "$1" in
            "has-session")
                return 0
                ;;
            *)
                return 0
                ;;
        esac
    }
    export -f mock_tmux_behavior
    
    # Mock user input to use existing session (option 1)
    echo "1" | run create_tmux_session
    
    [ "$status" -eq 0 ]
    assert_output_contains "Using existing session"
}

@test "create_tmux_session fails gracefully when tmux fails" {
    # Mock tmux creation failure
    mock_tmux_behavior() {
        case "$1" in
            "has-session")
                return 1
                ;;
            "new-session")
                echo "Failed to create session" >&2
                return 1
                ;;
            *)
                return 1
                ;;
        esac
    }
    export -f mock_tmux_behavior
    
    # Mock user input to continue
    echo "" | run create_tmux_session
    
    [ "$status" -eq 1 ]
    assert_output_contains "Failed to create tmux session"
}

# ============================================================================
# SESSION ID CONFIGURATION TESTS
# ============================================================================

@test "configure_session_id detects session ID from tmux output" {
    # Set up a mock tmux session name
    export TMUX_SESSION_NAME="claude-auto-resume-test"
    
    # Mock tmux capture-pane to return Claude output with session ID
    mock_tmux_behavior() {
        case "$1" in
            "capture-pane")
                if [[ "$3" == "-p" ]]; then
                    cat "$BATS_TEST_DIRNAME/../fixtures/mock-claude-success.txt"
                fi
                ;;
            *)
                return 0
                ;;
        esac
    }
    export -f mock_tmux_behavior
    
    # Mock user input to accept detected session ID ("y")
    echo "y" | run configure_session_id
    
    [ "$status" -eq 0 ]
    assert_output_contains "Detected session ID automatically"
    [[ "$SESSION_ID" == "sess-abcd1234567890123456" ]]
}

@test "configure_session_id handles manual session ID input" {
    # Set up a mock tmux session name
    export TMUX_SESSION_NAME="claude-auto-resume-test"
    
    # Mock tmux capture-pane to return output without session ID
    mock_tmux_behavior() {
        case "$1" in
            "capture-pane")
                if [[ "$3" == "-p" ]]; then
                    echo "Regular tmux output without session ID"
                fi
                ;;
            *)
                return 0
                ;;
        esac
    }
    export -f mock_tmux_behavior
    
    # Mock user input: manual session ID entry
    printf "manual123456789test\n" | run configure_session_id
    
    [ "$status" -eq 0 ]
    assert_output_contains "Session ID set: sess-manual123456789test"
}

@test "configure_session_id validates session ID format" {
    export TMUX_SESSION_NAME="claude-auto-resume-test"
    
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
    
    # Mock user input: too short session ID, then valid one
    printf "short\nvalidlongersessionid\n" | run configure_session_id
    
    [ "$status" -eq 0 ]
    assert_output_contains "Session ID seems too short"
    assert_output_contains "Session ID set: sess-validlongersessionid"
}

@test "configure_session_id adds sess- prefix when missing" {
    export TMUX_SESSION_NAME="claude-auto-resume-test"
    
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
    
    # Mock user input: session ID without sess- prefix
    printf "abcd1234567890123456\n" | run configure_session_id
    
    [ "$status" -eq 0 ]
    [[ "$SESSION_ID" == "sess-abcd1234567890123456" ]]
}

# ============================================================================
# VALIDATION TESTS
# ============================================================================

@test "validate_tmux_session passes with valid session" {
    export TMUX_SESSION_NAME="test-session"
    
    mock_tmux_behavior() {
        case "$1" in
            "has-session")
                [[ "$2" == "test-session" ]] && return 0 || return 1
                ;;
            *)
                return 0
                ;;
        esac
    }
    export -f mock_tmux_behavior
    
    run validate_tmux_session
    
    [ "$status" -eq 0 ]
}

@test "validate_claude_process detects Claude indicators" {
    export TMUX_SESSION_NAME="test-session"
    
    mock_tmux_behavior() {
        case "$1" in
            "capture-pane")
                if [[ "$3" == "-p" ]]; then
                    echo "Claude is running with session sess-test123"
                fi
                ;;
            *)
                return 0
                ;;
        esac
    }
    export -f mock_tmux_behavior
    
    run validate_claude_process
    
    [ "$status" -eq 0 ]
}

@test "validate_session_id validates correct format" {
    export SESSION_ID="sess-abcd1234567890123456"
    
    run validate_session_id
    
    [ "$status" -eq 0 ]
}

@test "validate_session_id fails with invalid format" {
    export SESSION_ID="invalid-format"
    
    run validate_session_id
    
    [ "$status" -eq 1 ]
}

@test "validate_session_id fails with too short ID" {
    export SESSION_ID="sess-short"
    
    run validate_session_id
    
    [ "$status" -eq 1 ]
}

@test "validate_connectivity passes with working claude command" {
    mock_command "claude" "echo 'Claude CLI Help'; return 0"
    
    run validate_connectivity
    
    [ "$status" -eq 0 ]
}

@test "validate_connectivity fails with broken claude command" {
    mock_command "claude" "echo 'Command failed'; return 1"
    
    run validate_connectivity
    
    [ "$status" -eq 1 ]
}

# ============================================================================
# UTILITY FUNCTION TESTS
# ============================================================================

@test "format_step_name returns readable names" {
    run format_step_name "check_dependencies"
    [ "$status" -eq 0 ]
    assert_output_contains "Checking Dependencies"
    
    run format_step_name "create_tmux_session"
    [ "$status" -eq 0 ]
    assert_output_contains "Creating tmux Session"
}

@test "format_validation_name returns readable names" {
    run format_validation_name "validate_tmux_session"
    [ "$status" -eq 0 ]
    assert_output_contains "tmux session exists"
    
    run format_validation_name "validate_claude_process"
    [ "$status" -eq 0 ]
    assert_output_contains "Claude process running"
}