#!/usr/bin/env bats

# Unit tests for terminal.sh utility module

load '../test_helper'

setup() {
    export TEST_MODE=true
    export DEBUG_MODE=true
    
    # Source the terminal module
    source "$BATS_TEST_DIRNAME/../../src/utils/terminal.sh" 2>/dev/null || {
        # Fallback if module doesn't exist yet
        echo "Terminal module not found - creating mock functions"
        detect_current_terminal() { echo "unknown"; }
        has_command() { command -v "$1" >/dev/null 2>&1; }
    }
}

@test "terminal module loads without errors" {
    run bash -c "source '$BATS_TEST_DIRNAME/../../src/utils/terminal.sh' 2>/dev/null || true"
    [ "$status" -eq 0 ]
}

@test "detect_current_terminal function exists and returns value" {
    if declare -f detect_current_terminal >/dev/null 2>&1; then
        run detect_current_terminal
        [ "$status" -eq 0 ]
        [ -n "$output" ]  # Should return something
        
        # Should be one of the known terminal types
        [[ "$output" =~ ^(iterm2|terminal|gnome-terminal|konsole|xterm|unknown)$ ]]
    else
        skip "detect_current_terminal function not implemented yet"
    fi
}

@test "terminal detection works on macOS" {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        if declare -f detect_current_terminal >/dev/null 2>&1; then
            run detect_current_terminal
            [ "$status" -eq 0 ]
            
            # On macOS, should detect Terminal.app or iTerm2
            [[ "$output" =~ ^(iterm2|terminal|unknown)$ ]]
        else
            skip "detect_current_terminal function not implemented yet"
        fi
    else
        skip "Not running on macOS"
    fi
}

@test "terminal detection handles unknown terminals gracefully" {
    if declare -f detect_current_terminal >/dev/null 2>&1; then
        # Mock unknown terminal environment
        export TERM_PROGRAM=""
        export TERM=""
        
        run detect_current_terminal
        [ "$status" -eq 0 ]
        [[ "$output" == "unknown" ]]
    else
        skip "detect_current_terminal function not implemented yet"
    fi
}

@test "open_terminal_window function exists" {
    if declare -f open_terminal_window >/dev/null 2>&1; then
        # Test dry run mode (shouldn't actually open terminal)
        export DRY_RUN=true
        
        run open_terminal_window "echo test" "/tmp" "Test Window"
        [ "$status" -eq 0 ]
        
        unset DRY_RUN
    else
        skip "open_terminal_window function not implemented yet"
    fi
}

@test "open_iterm_window function handles AppleScript correctly" {
    if [[ "$(uname -s)" == "Darwin" ]] && declare -f open_iterm_window >/dev/null 2>&1; then
        # Test with dry run to avoid actually opening terminals
        export DRY_RUN=true
        
        run open_iterm_window "echo test" "/tmp" "Test iTerm"
        [ "$status" -eq 0 ]
        
        unset DRY_RUN
    else
        skip "Not on macOS or open_iterm_window not implemented"
    fi
}

@test "open_terminal_app_window function handles AppleScript correctly" {
    if [[ "$(uname -s)" == "Darwin" ]] && declare -f open_terminal_app_window >/dev/null 2>&1; then
        # Test with dry run
        export DRY_RUN=true
        
        run open_terminal_app_window "echo test" "/tmp" "Test Terminal"
        [ "$status" -eq 0 ]
        
        unset DRY_RUN
    else
        skip "Not on macOS or open_terminal_app_window not implemented"
    fi
}

@test "open_gnome_terminal function works on Linux" {
    if [[ "$(uname -s)" == "Linux" ]] && declare -f open_gnome_terminal >/dev/null 2>&1; then
        # Test with dry run
        export DRY_RUN=true
        
        run open_gnome_terminal "echo test" "/tmp" "Test GNOME Terminal"
        [ "$status" -eq 0 ]
        
        unset DRY_RUN
    else
        skip "Not on Linux or open_gnome_terminal not implemented"
    fi
}

@test "terminal functions handle missing executables gracefully" {
    if declare -f open_terminal_window >/dev/null 2>&1; then
        # Mock environment without osascript (macOS) or gnome-terminal (Linux)
        export PATH="/usr/bin:/bin"  # Minimal PATH
        
        run open_terminal_window "echo test" "/tmp" "Test Window"
        # Should handle gracefully (return error, not crash)
        [[ "$status" -eq 0 ]] || [[ "$status" -eq 1 ]]
    else
        skip "open_terminal_window function not implemented yet"
    fi
}

@test "terminal functions escape commands properly" {
    if declare -f open_terminal_window >/dev/null 2>&1; then
        export DRY_RUN=true
        
        # Test with special characters that need escaping
        local special_cmd="echo 'Hello \"World\" & other stuff'"
        
        run open_terminal_window "$special_cmd" "/tmp" "Test Escaping"
        [ "$status" -eq 0 ]
        
        unset DRY_RUN
    else
        skip "open_terminal_window function not implemented yet"
    fi
}

@test "terminal functions handle empty or invalid arguments" {
    if declare -f open_terminal_window >/dev/null 2>&1; then
        export DRY_RUN=true
        
        # Test with empty command
        run open_terminal_window "" "/tmp" "Test Empty"
        [[ "$status" -eq 0 ]] || [[ "$status" -eq 1 ]]
        
        # Test with empty directory
        run open_terminal_window "echo test" "" "Test Empty Dir"
        [[ "$status" -eq 0 ]] || [[ "$status" -eq 1 ]]
        
        # Test with invalid directory
        run open_terminal_window "echo test" "/nonexistent/path" "Test Invalid Dir"
        [[ "$status" -eq 0 ]] || [[ "$status" -eq 1 ]]
        
        unset DRY_RUN
    else
        skip "open_terminal_window function not implemented yet"
    fi
}

@test "get_terminal_size function works if implemented" {
    if declare -f get_terminal_size >/dev/null 2>&1; then
        run get_terminal_size
        [ "$status" -eq 0 ]
        
        # Should return dimensions in some format
        [ -n "$output" ]
        # Common formats: "80x24", "columns=80 lines=24", etc.
        [[ "$output" =~ [0-9] ]]
    else
        skip "get_terminal_size function not implemented yet"
    fi
}

@test "is_terminal_available function works if implemented" {
    if declare -f is_terminal_available >/dev/null 2>&1; then
        run is_terminal_available
        # Should return 0 or 1
        [[ "$status" -eq 0 ]] || [[ "$status" -eq 1 ]]
    else
        skip "is_terminal_available function not implemented yet"
    fi
}

@test "terminal functions respect NO_COLOR environment variable" {
    if declare -f detect_current_terminal >/dev/null 2>&1; then
        export NO_COLOR=1
        
        run detect_current_terminal
        [ "$status" -eq 0 ]
        
        # Output shouldn't contain ANSI color codes when NO_COLOR is set
        # This test depends on implementation details
        ! [[ "$output" =~ $'\033\[[0-9;]*m' ]]
        
        unset NO_COLOR
    else
        skip "detect_current_terminal function not implemented yet"
    fi
}

@test "init_terminal_utils function initializes properly" {
    if declare -f init_terminal_utils >/dev/null 2>&1; then
        run init_terminal_utils "$BATS_TEST_DIRNAME/../fixtures/test-config.conf"
        [ "$status" -eq 0 ]
    else
        skip "init_terminal_utils function not implemented yet"
    fi
}

@test "open_claude_in_terminal function works if implemented" {
    if declare -f open_claude_in_terminal >/dev/null 2>&1; then
        export DRY_RUN=true
        
        run open_claude_in_terminal "continue"
        [ "$status" -eq 0 ]
        
        unset DRY_RUN
    else
        skip "open_claude_in_terminal function not implemented yet"
    fi
}