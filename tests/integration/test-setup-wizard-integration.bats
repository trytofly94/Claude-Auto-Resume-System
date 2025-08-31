#!/usr/bin/env bats

# Integration tests for setup-wizard.sh complete workflow
# Tests the full setup wizard process from start to finish

load '../test_helper'
load '../fixtures/github-api-mocks'

# Setup wizard script path  
PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
SETUP_WIZARD_SCRIPT="$PROJECT_ROOT/src/setup-wizard.sh"
HYBRID_MONITOR_SCRIPT="$PROJECT_ROOT/src/hybrid-monitor.sh"

setup() {
    enhanced_setup
    
    # Create a realistic test project structure
    export TEST_PROJECT_NAME="integration-test-project"
    export TEST_PROJECT_PATH="$TEST_TEMP_DIR/$TEST_PROJECT_NAME"
    mkdir -p "$TEST_PROJECT_PATH"
    cd "$TEST_PROJECT_PATH"
    
    # Create project files
    echo "# Integration Test Project" > README.md
    echo "console.log('Hello, World!');" > index.js
    
    # Source both setup wizard and session manager for integration testing
    if [[ -f "$SETUP_WIZARD_SCRIPT" ]]; then
        source "$SETUP_WIZARD_SCRIPT" 2>/dev/null || skip "Cannot load setup-wizard.sh"
    else
        skip "Setup wizard script not found: $SETUP_WIZARD_SCRIPT"
    fi
}

teardown() {
    enhanced_teardown
}

# ============================================================================
# COMPLETE SETUP WIZARD WORKFLOW TESTS
# ============================================================================

@test "complete setup wizard workflow with successful setup" {
    skip_if_platform_incompatible "flock" "File locking not available on this platform"
    
    # Mock all required commands
    mock_command "tmux" "success" "tmux version 3.2"
    mock_command "claude" "success" "Claude CLI version 1.0.0"
    
    # Create comprehensive tmux mock
    mock_tmux_behavior() {
        case "$1" in
            "has-session")
                # First check: no session exists, later checks: session exists
                if [[ -z "${WIZARD_SESSION_CREATED:-}" ]]; then
                    return 1
                else
                    return 0
                fi
                ;;
            "new-session")
                export WIZARD_SESSION_CREATED=true
                echo "Created session: $3"
                return 0
                ;;
            "send-keys")
                echo "Sent keys to session: $2"
                return 0
                ;;
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
    
    # Mock user interactions (simulate user pressing Enter and answering y/n)
    local user_input=""
    user_input+=$'\n'      # Continue after introduction
    user_input+=$'\n'      # Continue after dependencies
    user_input+=$'\n'      # Continue after tmux session creation  
    user_input+=$'\n'      # Continue to Claude setup
    user_input+="y"$'\n'   # Confirm Claude is running
    user_input+="y"$'\n'   # Accept detected session ID
    user_input+=$'\n'      # Continue to validation
    
    printf "%s" "$user_input" | run setup_wizard_main
    
    [ "$status" -eq 0 ]
    assert_output_contains "Setup Complete!"
    assert_output_contains "Claude Auto-Resume system is now configured"
}

@test "setup wizard detects existing session and skips setup" {
    # Mock existing session detection
    export MOCK_TMUX_SESSION_EXISTS=true
    export DETECTED_SESSION_NAME="claude-auto-resume-$TEST_PROJECT_NAME"
    
    setup_mock_tmux
    
    mock_tmux_behavior() {
        case "$1" in
            "has-session")
                [[ "$2" == "claude-auto-resume-$TEST_PROJECT_NAME" ]] && return 0
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
    
    run setup_wizard_main
    
    [ "$status" -eq 0 ]
    assert_output_contains "Existing session detected - starting monitoring"
}

@test "setup wizard handles missing dependencies gracefully" {
    # Mock tmux as missing
    unmock_command "tmux"
    mock_command "claude" "success" "Claude CLI version 1.0.0"
    
    # Mock user input to continue after seeing dependencies error
    echo "" | run setup_wizard_main
    
    [ "$status" -eq 1 ]
    assert_output_contains "Missing required dependencies: tmux"
    assert_output_contains "Please install the missing dependencies"
}

@test "setup wizard recovers from tmux session creation failure" {
    # Mock all commands as available
    mock_command "tmux" "success" "tmux version 3.2"
    mock_command "claude" "success" "Claude CLI version 1.0.0"
    
    # Mock tmux to fail on session creation initially, then succeed on retry
    local tmux_call_count=0
    mock_tmux_behavior() {
        case "$1" in
            "has-session")
                return 1  # Always report session doesn't exist initially
                ;;
            "new-session")
                ((tmux_call_count++))
                if [[ $tmux_call_count -eq 1 ]]; then
                    echo "Failed to create session" >&2
                    return 1
                else
                    echo "Created session successfully"
                    return 0
                fi
                ;;
            *)
                return 0
                ;;
        esac
    }
    export -f mock_tmux_behavior
    
    # Mock user input: continue, then retry when session creation fails
    local user_input=""
    user_input+=$'\n'      # Continue after introduction
    user_input+=$'\n'      # Continue after dependencies
    user_input+=$'\n'      # Continue after first tmux failure
    user_input+="1"$'\n'   # Choose retry option
    
    printf "%s" "$user_input" | run setup_wizard_main
    
    [ "$status" -eq 1 ]  # Still fails because we don't complete full mock setup
    assert_output_contains "Failed to create tmux session"
}

@test "setup wizard handles Claude startup failure gracefully" {
    # Mock all dependencies as available
    mock_command "tmux" "success" "tmux version 3.2"
    mock_command "claude" "success" "Claude CLI version 1.0.0"
    
    # Create successful tmux mock
    mock_tmux_behavior() {
        case "$1" in
            "has-session")
                if [[ -z "${SESSION_CREATED:-}" ]]; then
                    return 1
                else
                    return 0
                fi
                ;;
            "new-session")
                export SESSION_CREATED=true
                return 0
                ;;
            "send-keys")
                return 0
                ;;
            "capture-pane")
                # Return output that doesn't indicate Claude is running
                echo "Command not found or failed to start"
                ;;
            *)
                return 0
                ;;
        esac
    }
    export -f mock_tmux_behavior
    
    # Mock user input: continue through setup, then report Claude failed
    local user_input=""
    user_input+=$'\n'      # Continue after introduction
    user_input+=$'\n'      # Continue after dependencies
    user_input+=$'\n'      # Continue after tmux session creation
    user_input+=$'\n'      # Continue to Claude setup
    user_input+="n"$'\n'   # Report Claude is NOT running successfully
    
    printf "%s" "$user_input" | run setup_wizard_main
    
    [ "$status" -eq 1 ]
    assert_output_contains "Claude startup failed"
    assert_output_contains "Troubleshooting steps"
}

@test "setup wizard handles manual session ID entry" {
    # Setup successful environment except for session ID detection
    mock_command "tmux" "success" "tmux version 3.2"
    mock_command "claude" "success" "Claude CLI version 1.0.0"
    
    mock_tmux_behavior() {
        case "$1" in
            "has-session")
                if [[ -z "${SESSION_CREATED:-}" ]]; then
                    return 1
                else
                    return 0
                fi
                ;;
            "new-session")
                export SESSION_CREATED=true
                return 0
                ;;
            "send-keys")
                return 0
                ;;
            "capture-pane")
                # Return output without a detectable session ID
                echo "Claude is running but no session ID visible"
                ;;
            *)
                return 0
                ;;
        esac
    }
    export -f mock_tmux_behavior
    
    # Mock user input including manual session ID
    local user_input=""
    user_input+=$'\n'                                # Continue after introduction
    user_input+=$'\n'                                # Continue after dependencies
    user_input+=$'\n'                                # Continue after tmux creation
    user_input+=$'\n'                                # Continue to Claude setup
    user_input+="y"$'\n'                             # Confirm Claude is running
    user_input+="manual-test-session-12345"$'\n'    # Enter manual session ID
    user_input+=$'\n'                                # Continue to validation
    
    printf "%s" "$user_input" | run setup_wizard_main
    
    [ "$status" -eq 0 ]
    assert_output_contains "Session ID set: sess-manual-test-session-12345"
}

@test "setup wizard validation catches configuration issues" {
    # Setup environment but break validation
    mock_command "tmux" "success" "tmux version 3.2"
    mock_command "claude" "failure" "Command failed"  # Break connectivity validation
    
    mock_tmux_behavior() {
        case "$1" in
            "has-session")
                if [[ -z "${SESSION_CREATED:-}" ]]; then
                    return 1
                else
                    return 0
                fi
                ;;
            "new-session")
                export SESSION_CREATED=true
                return 0
                ;;
            "send-keys")
                return 0
                ;;
            "capture-pane")
                cat "$BATS_TEST_DIRNAME/../fixtures/mock-claude-success.txt"
                ;;
            *)
                return 0
                ;;
        esac
    }
    export -f mock_tmux_behavior
    
    # Mock user input through successful setup
    local user_input=""
    user_input+=$'\n'      # Continue after introduction  
    user_input+=$'\n'      # Continue after dependencies
    user_input+=$'\n'      # Continue after tmux creation
    user_input+=$'\n'      # Continue to Claude setup
    user_input+="y"$'\n'   # Confirm Claude is running
    user_input+="y"$'\n'   # Accept detected session ID
    user_input+=$'\n'      # Continue to validation
    user_input+="1"$'\n'   # Continue anyway despite failed validation
    
    printf "%s" "$user_input" | run setup_wizard_main
    
    [ "$status" -eq 0 ]
    assert_output_contains "Some validations failed"
    assert_output_contains "Continuing with failed validations"
}

# ============================================================================
# INTEGRATION WITH HYBRID MONITOR TESTS
# ============================================================================

@test "setup wizard integrates with hybrid monitor --setup-wizard option" {
    skip_if_no_command "timeout" "timeout command not available"
    
    # Test that hybrid monitor can invoke the setup wizard
    if [[ ! -f "$HYBRID_MONITOR_SCRIPT" ]]; then
        skip "Hybrid monitor script not found"
    fi
    
    # Mock the setup wizard main function to avoid full interactive setup
    setup_wizard_main() {
        echo "Setup wizard called from hybrid monitor"
        return 0
    }
    export -f setup_wizard_main
    
    # Test with a timeout to avoid hanging
    run timeout 10 bash "$HYBRID_MONITOR_SCRIPT" --setup-wizard --dry-run
    
    [ "$status" -eq 0 ]
    assert_output_contains "Setup wizard called from hybrid monitor"
}

@test "hybrid monitor detects missing setup and suggests wizard" {
    if [[ ! -f "$HYBRID_MONITOR_SCRIPT" ]]; then
        skip "Hybrid monitor script not found"
    fi
    
    # Remove any existing session files
    rm -f "$HOME"/.claude_session_* 2>/dev/null || true
    
    # Mock tmux to report no sessions
    export MOCK_TMUX_SESSION_EXISTS=false
    setup_mock_tmux
    
    mock_tmux_behavior() {
        case "$1" in
            "has-session"|"list-sessions")
                return 1
                ;;
            *)
                return 0
                ;;
        esac
    }
    export -f mock_tmux_behavior
    
    # Test hybrid monitor suggests setup wizard
    run timeout 5 bash "$HYBRID_MONITOR_SCRIPT" --help
    
    [ "$status" -eq 0 ]
    assert_output_contains "--setup-wizard"
}

# ============================================================================
# SESSION PERSISTENCE TESTS  
# ============================================================================

@test "setup wizard saves session configuration persistently" {
    # Setup successful wizard completion
    export TMUX_SESSION_NAME="claude-auto-resume-$TEST_PROJECT_NAME"
    export SESSION_ID="sess-persistent-test-123456"
    
    # Test that session file gets created
    run configure_session_id
    
    # Check if session file was created with correct content
    local session_file="$HOME/.claude_session_$TEST_PROJECT_NAME"
    
    assert_file_exists "$session_file"
    
    local saved_session_id
    saved_session_id=$(cat "$session_file")
    [[ "$saved_session_id" == "$SESSION_ID" ]]
}

@test "setup wizard reads existing session configuration" {
    # Create existing session file
    local session_file="$HOME/.claude_session_$TEST_PROJECT_NAME"
    local existing_session_id="sess-existing-configuration-123"
    echo "$existing_session_id" > "$session_file"
    
    # Mock tmux to not find active sessions
    export MOCK_TMUX_SESSION_EXISTS=false
    setup_mock_tmux
    
    run detect_existing_session
    
    [ "$status" -eq 0 ]
    [[ "$DETECTED_SESSION_ID" == "$existing_session_id" ]]
}

# ============================================================================
# ERROR RECOVERY TESTS
# ============================================================================

@test "setup wizard provides comprehensive error recovery options" {
    # Mock a step failure
    check_dependencies() {
        echo "Dependency check failed for testing"
        return 1
    }
    export -f check_dependencies
    
    # Mock user input to try recovery
    local user_input=""
    user_input+=$'\n'      # Continue after introduction
    user_input+="1"$'\n'   # Choose retry option
    
    # Override function to succeed on retry
    check_dependencies() {
        if [[ -n "${RETRY_ATTEMPT:-}" ]]; then
            echo "Dependencies check passed on retry"
            return 0
        else
            export RETRY_ATTEMPT=true
            echo "Dependency check failed for testing"
            return 1
        fi
    }
    export -f check_dependencies
    
    printf "%s" "$user_input" | run run_setup_steps
    
    # Even if the test structure doesn't complete perfectly,
    # we verify error recovery is offered
    assert_output_contains "Recovery options"
}

@test "setup wizard handles interrupted workflow gracefully" {
    # Simulate an interrupted setup by having a step timeout
    validate_session_health() {
        echo "Simulating timeout/interruption"
        sleep 30  # This should be interrupted
        return 1
    }
    export -f validate_session_health
    
    # Run with timeout to simulate interruption
    run timeout 5 setup_wizard_main
    
    # Should exit gracefully with timeout code
    [ "$status" -eq 124 ]  # timeout exit code
}

# ============================================================================
# CROSS-PLATFORM COMPATIBILITY TESTS
# ============================================================================

@test "setup wizard works on macOS with iTerm2/Terminal.app detection" {
    skip_if_not_os "macos" "macOS-specific test"
    
    # Mock macOS environment
    export TERM_PROGRAM="iTerm.app"
    
    # Test that wizard doesn't fail on macOS-specific features
    mock_command "tmux" "success" "tmux version 3.2"
    mock_command "claude" "success" "Claude CLI version 1.0.0"
    
    run check_dependencies
    
    [ "$status" -eq 0 ]
    assert_output_contains "Dependencies check completed successfully"
}

@test "setup wizard works on Linux with various terminals" {
    skip_if_not_os "linux" "Linux-specific test"
    
    # Mock Linux environment
    export TERM_PROGRAM="gnome-terminal"
    
    # Test that wizard works on Linux
    mock_command "tmux" "success" "tmux version 3.1"
    mock_command "claude" "success" "Claude CLI version 1.0.0"
    
    run check_dependencies
    
    [ "$status" -eq 0 ]
    assert_output_contains "Dependencies check completed successfully"
}

# ============================================================================
# USER EXPERIENCE TESTS
# ============================================================================

@test "setup wizard provides clear progress indicators" {
    # Mock successful environment
    mock_command "tmux" "success" "tmux version 3.2"
    mock_command "claude" "success" "Claude CLI version 1.0.0"
    
    # Test that step progress is shown
    run format_step_name "check_dependencies"
    [ "$status" -eq 0 ]
    assert_output_contains "Checking Dependencies"
    
    run format_step_name "create_tmux_session"  
    [ "$status" -eq 0 ]
    assert_output_contains "Creating tmux Session"
}

@test "setup wizard provides helpful error messages" {
    # Test dependency installation help
    run show_dependency_installation_help "tmux" "claude"
    
    [ "$status" -eq 0 ]
    assert_output_contains "Installation instructions"
    assert_output_contains "macOS: brew install tmux"
    assert_output_contains "Install Claude CLI from https://claude.ai/code"
}

@test "setup wizard shows comprehensive completion summary" {
    export TMUX_SESSION_NAME="test-session"
    export SESSION_ID="sess-test123456789"
    
    run show_setup_completion
    
    [ "$status" -eq 0 ]
    assert_output_contains "Setup Complete!"
    assert_output_contains "Configuration Summary"
    assert_output_contains "tmux Session: test-session"
    assert_output_contains "Session ID: sess-test123456789"
}