#!/bin/bash

# Test helper functions for Claude Auto-Resume test suite
# This file is loaded by all BATS test files
# Enhanced with Issue #46 BATS compatibility improvements

# Set up test environment
export BATS_TEST_SKIPPED=
export TEST_TEMP_DIR=""

# Load BATS compatibility utilities (Issue #46 Phase 1)
BATS_HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$BATS_HELPER_DIR/utils/bats-compatibility.bash" ]]; then
    source "$BATS_HELPER_DIR/utils/bats-compatibility.bash" 2>/dev/null || true
fi

# Test configuration
setup_test_environment() {
    # Phase 2: Enhanced test isolation (Issue #46)
    # Create isolated test environment
    export TEST_TEMP_DIR=$(mktemp -d)
    export HOME="$TEST_TEMP_DIR/home"
    export XDG_CONFIG_HOME="$TEST_TEMP_DIR/config"
    export TEST_PROJECT_DIR="$BATS_HELPER_DIR/.."
    
    mkdir -p "$HOME" "$XDG_CONFIG_HOME"
    
    # Set test-friendly defaults optimized for performance
    export DEBUG_MODE=false  # Reduced logging for performance
    export TEST_MODE=true
    export LOG_LEVEL="ERROR"  # Minimal logging during tests
    
    # Prevent actual network calls in tests
    export OFFLINE_MODE=true
    
    # Use test configuration
    export TEST_CONFIG_FILE="$BATS_TEST_DIRNAME/fixtures/test-config.conf"
    
    # Performance optimizations
    export TASK_QUEUE_PERFORMANCE_MODE=true
    export SKIP_BACKUP_CREATION=true  # Skip backups during tests
    export DISABLE_JSON_VALIDATION=true  # Skip expensive JSON validation
    
    # Phase 2: Setup test-specific logging (Issue #46)
    if command -v setup_test_logging >/dev/null 2>&1; then
        setup_test_logging "${BATS_TEST_NAME:-unknown_test}"
    fi
}

# Cleanup test environment
teardown_test_environment() {
    # Phase 2: Enhanced test cleanup (Issue #46)
    if command -v enhanced_test_teardown >/dev/null 2>&1; then
        enhanced_test_teardown
    else
        # Fallback to basic cleanup
        if [[ -n "$TEST_TEMP_DIR" && -d "$TEST_TEMP_DIR" ]]; then
            rm -rf "$TEST_TEMP_DIR"
        fi
    fi
}

# Mock command function for testing
mock_command() {
    local cmd_name="$1"
    local mock_behavior="$2"
    local mock_output="${3:-}"
    
    case "$mock_behavior" in
        "success")
            eval "$cmd_name() { echo '$mock_output'; return 0; }"
            ;;
        "failure")
            eval "$cmd_name() { echo '$mock_output' >&2; return 1; }"
            ;;
        "timeout")
            eval "$cmd_name() { sleep 10; echo '$mock_output'; return 124; }"
            ;;
        *)
            eval "$cmd_name() { $mock_behavior; }"
            ;;
    esac
    
    export -f "$cmd_name"
}

# Remove mock command
unmock_command() {
    local cmd_name="$1"
    
    # First, unset the function
    unset -f "$cmd_name" 2>/dev/null || true
    
    # For dependency tests, we need to temporarily hide the real command
    # Create a disabled mock that returns 127 (command not found)
    if [[ -n "${TEST_TEMP_DIR:-}" ]]; then
        local mock_dir="$TEST_TEMP_DIR/disabled_mock_bin"
        mkdir -p "$mock_dir"
        
        cat > "$mock_dir/$cmd_name" << 'EOF'
#!/bin/bash
# Disabled mock to simulate missing dependency
echo "bash: $0: command not found" >&2
exit 127
EOF
        chmod +x "$mock_dir/$cmd_name"
        
        # Prepend to PATH to override real command
        export PATH="$mock_dir:$PATH"
        
        # Track for cleanup
        echo "$cmd_name" >> "$TEST_TEMP_DIR/disabled_mocks" || true
    fi
}

# Create mock file with content
create_mock_file() {
    local file_path="$1"
    local content="$2"
    
    mkdir -p "$(dirname "$file_path")"
    echo "$content" > "$file_path"
}

# Check if a function is defined
function_exists() {
    declare -f "$1" >/dev/null 2>&1
}

# Check if a variable is set
variable_exists() {
    [[ -n "${!1:-}" ]]
}

# Assert that output contains expected text
assert_output_contains() {
    local expected="$1"
    local actual="${output:-}"
    
    if [[ "$actual" != *"$expected"* ]]; then
        echo "Expected output to contain: '$expected'"
        echo "Actual output: '$actual'"
        return 1
    fi
}

# Assert that output matches pattern
assert_output_matches() {
    local pattern="$1"
    local actual="${output:-}"
    
    if ! [[ "$actual" =~ $pattern ]]; then
        echo "Expected output to match pattern: '$pattern'"
        echo "Actual output: '$actual'"
        return 1
    fi
}

# Assert that a file exists
assert_file_exists() {
    local file_path="$1"
    
    if [[ ! -f "$file_path" ]]; then
        echo "Expected file to exist: '$file_path'"
        return 1
    fi
}

# Assert that a file does not exist
assert_file_not_exists() {
    local file_path="$1"
    
    if [[ -f "$file_path" ]]; then
        echo "Expected file to not exist: '$file_path'"
        return 1
    fi
}

# Assert that a directory exists
assert_dir_exists() {
    local dir_path="$1"
    
    if [[ ! -d "$dir_path" ]]; then
        echo "Expected directory to exist: '$dir_path'"
        return 1
    fi
}

# Skip test if command is not available
skip_if_no_command() {
    local cmd_name="$1"
    local message="${2:-Command '$cmd_name' not available}"
    
    if ! command -v "$cmd_name" >/dev/null 2>&1; then
        skip "$message"
    fi
}

# Skip test if not on specific OS
skip_if_not_os() {
    local expected_os="$1"
    local current_os
    
    case "$(uname -s)" in
        Darwin) current_os="macos" ;;
        Linux) current_os="linux" ;;
        CYGWIN*|MINGW*|MSYS*) current_os="windows" ;;
        *) current_os="unknown" ;;
    esac
    
    if [[ "$current_os" != "$expected_os" ]]; then
        skip "Test only runs on $expected_os (current: $current_os)"
    fi
}

# Skip test if running in CI environment
skip_if_ci() {
    local message="${1:-Test skipped in CI environment}"
    
    if [[ "${CI:-}" == "true" ]] || [[ "${GITHUB_ACTIONS:-}" == "true" ]] || [[ "${TRAVIS:-}" == "true" ]]; then
        skip "$message"
    fi
}

# Create mock tmux environment
setup_mock_tmux() {
    mock_command "tmux" "mock_tmux_behavior"
    
    mock_tmux_behavior() {
        case "$1" in
            "has-session")
                if [[ "${MOCK_TMUX_SESSION_EXISTS:-true}" == "true" ]]; then
                    return 0
                else
                    return 1
                fi
                ;;
            "list-sessions")
                echo "claude-test-project: 1 windows (created Mon Aug  5 12:30:00 2025)"
                echo "claude-test-example: 2 windows (created Mon Aug  5 12:31:00 2025)"
                ;;
            "send-keys")
                echo "Mock: sent keys '$3' to session '$2'"
                return 0
                ;;
            "capture-pane")
                if [[ "$3" == "-p" ]]; then
                    # Return mock session output
                    cat "$BATS_TEST_DIRNAME/fixtures/mock-claude-output.txt" 2>/dev/null || echo "Mock tmux output"
                fi
                ;;
            *)
                echo "Mock tmux command: $*"
                return 0
                ;;
        esac
    }
    
    export -f mock_tmux_behavior
}

# Setup mock Claude CLI
setup_mock_claude() {
    local behavior="${1:-success}"
    
    case "$behavior" in
        "usage_limit")
            mock_command "claude" "cat '$BATS_TEST_DIRNAME/fixtures/mock-claude-output.txt'; return 1"
            ;;
        "success")
            mock_command "claude" "cat '$BATS_TEST_DIRNAME/fixtures/mock-claude-success.txt'; return 0"
            ;;
        "timeout")
            mock_command "claude" "sleep 30; return 124"
            ;;
        *)
            mock_command "claude" "$behavior"
            ;;
    esac
}

# Setup mock claunch
setup_mock_claunch() {
    local claunch_exists="${1:-true}"
    
    if [[ "$claunch_exists" == "true" ]]; then
        mock_command "claunch" "mock_claunch_behavior"
        
        mock_claunch_behavior() {
            case "$1" in
                "--version")
                    echo "claunch v1.0.0"
                    ;;
                "--help")
                    echo "claunch - Claude CLI launcher"
                    echo "Usage: claunch [options] [-- claude_args...]"
                    ;;
                "list")
                    cat "$BATS_TEST_DIRNAME/fixtures/mock-claunch-list.txt" 2>/dev/null || echo "No active sessions"
                    ;;
                "clean")
                    echo "Cleaned up orphaned sessions"
                    ;;
                *)
                    echo "Mock claunch started with args: $*"
                    return 0
                    ;;
            esac
        }
        
        export -f mock_claunch_behavior
        export CLAUNCH_PATH="claunch"
    else
        # Make claunch unavailable
        export PATH="/usr/bin:/bin"  # Remove claunch from PATH
        unset CLAUNCH_PATH
    fi
}

# Create test project structure
create_test_project() {
    local project_name="${1:-test-project}"
    local project_dir="$TEST_TEMP_DIR/$project_name"
    
    mkdir -p "$project_dir"
    cd "$project_dir"
    
    # Create basic project files
    echo "# Test Project" > README.md
    echo "console.log('Hello, World!');" > index.js
    
    # Create mock git repository
    mkdir -p .git/hooks
    
    echo "$project_dir"
}

# Wait for condition with timeout
wait_for_condition() {
    local condition="$1"
    local timeout="${2:-10}"
    local interval="${3:-1}"
    
    local elapsed=0
    
    while ! eval "$condition" && [[ $elapsed -lt $timeout ]]; do
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    
    if [[ $elapsed -ge $timeout ]]; then
        echo "Timeout waiting for condition: $condition"
        return 1
    fi
    
    return 0
}

# Generate mock session ID
generate_mock_session_id() {
    local project_name="${1:-test-project}"
    local timestamp="${2:-$(date +%s)}"
    local pid="${3:-$$}"
    
    echo "${project_name}-${timestamp}-${pid}"
}

# Helper to run command with timeout
run_with_timeout() {
    local timeout="$1"
    shift
    
    timeout "$timeout" "$@"
}

# Debug helper - print all environment variables starting with prefix
debug_env() {
    local prefix="${1:-TEST_}"
    
    echo "Environment variables starting with $prefix:"
    env | grep "^$prefix" | sort
}

# Cleanup function for tests
cleanup_test_artifacts() {
    # Remove any test session files
    rm -f "$HOME"/.claude_session_* 2>/dev/null || true
    
    # Kill any background processes started by tests
    jobs -p | xargs -r kill 2>/dev/null || true
    
    # Clean up disabled mocks and restore PATH
    if [[ -n "${TEST_TEMP_DIR:-}" && -f "$TEST_TEMP_DIR/disabled_mocks" ]]; then
        while IFS= read -r cmd_name; do
            # Remove disabled mock directory from PATH
            local mock_dir="$TEST_TEMP_DIR/disabled_mock_bin"
            if [[ ":$PATH:" == *":$mock_dir:"* ]]; then
                export PATH="${PATH//$mock_dir:/}"
                export PATH="${PATH%:}"  # Remove trailing colon if present
            fi
        done < "$TEST_TEMP_DIR/disabled_mocks"
        rm -rf "$TEST_TEMP_DIR/disabled_mock_bin" 2>/dev/null || true
        rm -f "$TEST_TEMP_DIR/disabled_mocks" 2>/dev/null || true
    fi
    
    # Reset important environment variables
    unset MOCK_TMUX_SESSION_EXISTS
    unset OFFLINE_MODE
    unset FORCE_NETWORK_FAILURE
}

# Default setup function that can be called by individual tests
default_setup() {
    setup_test_environment
    
    # Load common mocks
    setup_mock_tmux
    setup_mock_claude "success"
    setup_mock_claunch "true"
}

# Default teardown function
default_teardown() {
    cleanup_test_artifacts
    teardown_test_environment
}

# ===============================================================================
# ENHANCED FUNCTIONS FOR ISSUE #46 BATS COMPATIBILITY
# ===============================================================================

# Enhanced setup with BATS compatibility features
enhanced_setup() {
    setup_test_environment
    
    # Load common mocks
    setup_mock_tmux
    setup_mock_claude "success"
    setup_mock_claunch "true"
    
    # Phase 1: Optimize BATS state tracking (Issue #46)
    if command -v optimize_bats_state_tracking >/dev/null 2>&1; then
        optimize_bats_state_tracking
    fi
}

# Enhanced teardown with BATS compatibility features
enhanced_teardown() {
    # Phase 2: Use enhanced cleanup if available
    if command -v enhanced_test_teardown >/dev/null 2>&1; then
        enhanced_test_teardown
    else
        default_teardown
    fi
}

# Timeout-aware test execution wrapper
run_with_bats_timeout() {
    local test_type="${1:-default}"
    shift
    
    # Use BATS-compatible timeout if available
    if command -v bats_safe_timeout >/dev/null 2>&1; then
        case "$test_type" in
            "unit")
                bats_safe_timeout 30 "unit" "$@"
                ;;
            "integration") 
                bats_safe_timeout 45 "integration" "$@"
                ;;
            "setup")
                bats_safe_timeout 10 "setup" "$@"
                ;;
            "cleanup")
                bats_safe_timeout 5 "cleanup" "$@"
                ;;
            *)
                bats_safe_timeout 30 "default" "$@"
                ;;
        esac
    else
        # Fallback to run_with_timeout
        run_with_timeout 30 "$@"
    fi
}

# Platform-aware test skipping
skip_if_platform_incompatible() {
    local requirement="$1"
    local message="${2:-Test incompatible with current platform}"
    
    if command -v skip_if_incompatible >/dev/null 2>&1; then
        skip_if_incompatible "$requirement" "$message"
    else
        # Fallback platform detection
        case "$requirement" in
            "flock")
                if [[ "$(uname -s)" == "Darwin" ]]; then
                    skip "$message (macOS: flock unavailable)"
                fi
                ;;
            "linux_only")
                if [[ "$(uname -s)" != "Linux" ]]; then
                    skip "$message (Linux required)"
                fi
                ;;
            "macos_only")
                if [[ "$(uname -s)" != "Darwin" ]]; then
                    skip "$message (macOS required)"
                fi
                ;;
        esac
    fi
}

# Safe array operations for BATS
test_array_operation() {
    local operation="$1"
    local array_name="$2"
    shift 2
    
    if command -v bats_safe_array_operation >/dev/null 2>&1; then
        bats_safe_array_operation "$operation" "$array_name" "$@"
    else
        # Fallback: basic array operations
        case "$operation" in
            "get")
                local key="$1"
                local -n array_ref="$array_name"
                echo "${array_ref[$key]:-}"
                ;;
            "set")
                local key="$1"
                local value="$2"
                local -n array_ref="$array_name"
                array_ref["$key"]="$value"
                ;;
            "exists")
                local key="$1"
                local -n array_ref="$array_name"
                [[ -v "array_ref[$key]" ]]
                ;;
            "clear")
                unset "$array_name"
                declare -gA "$array_name"
                ;;
        esac
    fi
}

# Isolated test execution
run_isolated_test() {
    local test_function="$1"
    shift
    
    if command -v bats_isolated_test_run >/dev/null 2>&1; then
        bats_isolated_test_run "$test_function" "$@"
    else
        # Fallback: basic isolation
        (
            enhanced_setup
            "$test_function" "$@"
            local result=$?
            enhanced_teardown
            return $result
        )
    fi
}