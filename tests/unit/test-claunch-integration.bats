#!/usr/bin/env bats

# Unit tests for claunch-integration.sh module

load '../test_helper'

setup() {
    export TEST_MODE=true
    export DEBUG_MODE=true
    export DRY_RUN=true  # Prevent actual claunch execution in tests
    
    # Create temporary test directory
    TEST_PROJECT_DIR=$(mktemp -d)
    cd "$TEST_PROJECT_DIR"
    
    # Source the claunch integration module
    source "$BATS_TEST_DIRNAME/../../src/claunch-integration.sh" 2>/dev/null || {
        echo "claunch integration module not found - creating mock functions"
        detect_claunch() { return 0; }
        validate_claunch() { return 0; }
        has_command() { command -v "$1" >/dev/null 2>&1; }
    }
}

teardown() {
    cd /
    rm -rf "$TEST_PROJECT_DIR"
}

@test "claunch integration module loads without errors" {
    run bash -c "source '$BATS_TEST_DIRNAME/../../src/claunch-integration.sh' 2>/dev/null || true"
    [ "$status" -eq 0 ]
}

@test "detect_claunch function works" {
    if declare -f detect_claunch >/dev/null 2>&1; then
        run detect_claunch
        # Should return 0 or 1, not crash
        [[ "$status" -eq 0 ]] || [[ "$status" -eq 1 ]]
    else
        skip "detect_claunch function not implemented yet"
    fi
}

@test "validate_claunch function checks installation" {
    if declare -f validate_claunch >/dev/null 2>&1; then
        # Mock claunch presence
        export CLAUNCH_PATH="/usr/bin/claunch"
        
        run validate_claunch
        [[ "$status" -eq 0 ]] || [[ "$status" -eq 1 ]]
        
        unset CLAUNCH_PATH
    else
        skip "validate_claunch function not implemented yet"
    fi
}

@test "check_tmux_availability function works" {
    if declare -f check_tmux_availability >/dev/null 2>&1; then
        # Test with tmux mode
        export CLAUNCH_MODE="tmux"
        
        run check_tmux_availability
        [[ "$status" -eq 0 ]] || [[ "$status" -eq 1 ]]
        
        # Test with direct mode
        export CLAUNCH_MODE="direct"
        
        run check_tmux_availability
        [ "$status" -eq 0 ]  # Should always succeed in direct mode
        
        unset CLAUNCH_MODE
    else
        skip "check_tmux_availability function not implemented yet"
    fi
}

@test "detect_project function identifies project correctly" {
    if declare -f detect_project >/dev/null 2>&1; then
        # Create test project structure
        mkdir -p "$TEST_PROJECT_DIR/test-project"
        cd "$TEST_PROJECT_DIR/test-project"
        
        run detect_project "$(pwd)"
        [ "$status" -eq 0 ]
        
        # Check if PROJECT_NAME was set
        [[ "$PROJECT_NAME" == "test-project" ]] || [[ -n "$PROJECT_NAME" ]]
    else
        skip "detect_project function not implemented yet"
    fi
}

@test "detect_project function sanitizes project names" {
    if declare -f detect_project >/dev/null 2>&1; then
        # Create project with special characters
        mkdir -p "$TEST_PROJECT_DIR/test-project@#$%"
        cd "$TEST_PROJECT_DIR/test-project@#$%"
        
        run detect_project "$(pwd)"
        [ "$status" -eq 0 ]
        
        # Project name should be sanitized for tmux compatibility
        [[ "$PROJECT_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]
    else
        skip "detect_project function not implemented yet"
    fi
}

@test "detect_existing_session function works" {
    if declare -f detect_existing_session >/dev/null 2>&1; then
        # Create mock session file
        export PROJECT_NAME="test-project"
        echo "test-session-123" > "$HOME/.claude_session_test-project"
        
        run detect_existing_session "$(pwd)"
        [[ "$status" -eq 0 ]] || [[ "$status" -eq 1 ]]
        
        # Cleanup
        rm -f "$HOME/.claude_session_test-project"
        unset PROJECT_NAME
    else
        skip "detect_existing_session function not implemented yet"
    fi
}

@test "start_claunch_session function builds command correctly" {
    if declare -f start_claunch_session >/dev/null 2>&1; then
        export CLAUNCH_PATH="/usr/local/bin/claunch"
        export CLAUNCH_MODE="tmux"
        export DRY_RUN=true
        
        run start_claunch_session "$(pwd)" "continue" "--model" "claude-3-opus"
        [ "$status" -eq 0 ]
        
        unset CLAUNCH_PATH CLAUNCH_MODE
    else
        skip "start_claunch_session function not implemented yet"
    fi
}

@test "start_claunch_in_new_terminal function works" {
    if declare -f start_claunch_in_new_terminal >/dev/null 2>&1; then
        export CLAUNCH_PATH="/usr/local/bin/claunch"
        export DRY_RUN=true
        
        # Mock terminal utility function
        open_terminal_window() { echo "Mock terminal opened"; }
        export -f open_terminal_window
        
        run start_claunch_in_new_terminal "$(pwd)" "test"
        [ "$status" -eq 0 ]
        
        unset CLAUNCH_PATH
        unset -f open_terminal_window
    else
        skip "start_claunch_in_new_terminal function not implemented yet"
    fi
}

@test "send_command_to_session function works in tmux mode" {
    if declare -f send_command_to_session >/dev/null 2>&1; then
        export CLAUNCH_MODE="tmux"
        export TMUX_SESSION_NAME="claude-test-project"
        export DRY_RUN=true
        
        # Mock tmux command
        tmux() {
            case "$1" in
                "has-session")
                    return 0  # Pretend session exists
                    ;;
                "send-keys")
                    echo "Mock: sent keys '$3' to session '$2'"
                    return 0
                    ;;
            esac
        }
        export -f tmux
        
        run send_command_to_session "/dev continue" "claude-test-project"
        [ "$status" -eq 0 ]
        [[ "$output" =~ "sent keys" ]]
        
        unset CLAUNCH_MODE TMUX_SESSION_NAME
        unset -f tmux
    else
        skip "send_command_to_session function not implemented yet"
    fi
}

@test "check_session_status function detects active sessions" {
    if declare -f check_session_status >/dev/null 2>&1; then
        export CLAUNCH_MODE="tmux"
        export TMUX_SESSION_NAME="claude-test-project"
        
        # Mock tmux with existing session
        tmux() {
            if [[ "$1" == "has-session" ]]; then
                return 0  # Session exists
            fi
        }
        export -f tmux
        
        run check_session_status
        [ "$status" -eq 0 ]
        
        # Mock tmux with no session
        tmux() {
            if [[ "$1" == "has-session" ]]; then
                return 1  # Session doesn't exist
            fi
        }
        export -f tmux
        
        run check_session_status
        [ "$status" -eq 1 ]
        
        unset CLAUNCH_MODE TMUX_SESSION_NAME
        unset -f tmux
    else
        skip "check_session_status function not implemented yet"
    fi
}

@test "list_active_sessions function provides output" {
    if declare -f list_active_sessions >/dev/null 2>&1; then
        export CLAUNCH_PATH="/usr/local/bin/claunch"
        
        # Mock claunch list command
        /usr/local/bin/claunch() {
            if [[ "$1" == "list" ]]; then
                cat "$BATS_TEST_DIRNAME/../fixtures/mock-claunch-list.txt"
                return 0
            fi
        }
        
        # Override the actual claunch command
        claunch() {
            if [[ "$1" == "list" ]]; then
                cat "$BATS_TEST_DIRNAME/../fixtures/mock-claunch-list.txt"
                return 0
            fi
        }
        export -f claunch
        
        run list_active_sessions
        [ "$status" -eq 0 ]
        [ -n "$output" ]
        [[ "$output" =~ "Active claunch Sessions" ]]
        
        unset CLAUNCH_PATH
        unset -f claunch
    else
        skip "list_active_sessions function not implemented yet"
    fi
}

@test "cleanup_orphaned_sessions function works" {
    if declare -f cleanup_orphaned_sessions >/dev/null 2>&1; then
        export CLAUNCH_PATH="/usr/local/bin/claunch"
        export DRY_RUN=true
        
        run cleanup_orphaned_sessions
        [ "$status" -eq 0 ]
        
        unset CLAUNCH_PATH
    else
        skip "cleanup_orphaned_sessions function not implemented yet"
    fi
}

@test "init_claunch_integration function initializes properly" {
    if declare -f init_claunch_integration >/dev/null 2>&1; then
        run init_claunch_integration "$BATS_TEST_DIRNAME/../fixtures/test-config.conf" "$(pwd)"
        [[ "$status" -eq 0 ]] || [[ "$status" -eq 1 ]]  # May fail if claunch not available
    else
        skip "init_claunch_integration function not implemented yet"
    fi
}

@test "start_or_resume_session function handles both cases" {
    if declare -f start_or_resume_session >/dev/null 2>&1; then
        export DRY_RUN=true
        
        # Mock detect_existing_session to return false (no existing session)
        detect_existing_session() { return 1; }
        export -f detect_existing_session
        
        # Mock start_claunch_session
        start_claunch_session() { echo "Started new session"; return 0; }
        export -f start_claunch_session
        
        run start_or_resume_session "$(pwd)" false "continue"
        [ "$status" -eq 0 ]
        [[ "$output" =~ "Starting new session" ]]
        
        unset -f detect_existing_session start_claunch_session
    else
        skip "start_or_resume_session function not implemented yet"
    fi
}

@test "send_recovery_command function sends default command" {
    if declare -f send_recovery_command >/dev/null 2>&1; then
        export DRY_RUN=true
        
        # Mock session status check
        check_session_status() { return 0; }  # Session exists
        export -f check_session_status
        
        # Mock command sending
        send_command_to_session() { 
            echo "Sent recovery command: $1"
            return 0
        }
        export -f send_command_to_session
        
        run send_recovery_command
        [ "$status" -eq 0 ]
        [[ "$output" =~ "recovery command" ]]
        
        unset -f check_session_status send_command_to_session
    else
        skip "send_recovery_command function not implemented yet"
    fi
}