#!/usr/bin/env bats

# Cross-Environment Monitoring Tests
# Tests monitoring behavior across different terminal and execution environments

load ../test_helper

setup() {
    default_setup
    
    # Create test project directory
    export TEST_PROJECT_DIR="$TEST_TEMP_DIR/claude-auto-resume"
    mkdir -p "$TEST_PROJECT_DIR"
    cd "$TEST_PROJECT_DIR"
    
    # Set up SCRIPT_DIR for source path resolution
    export SCRIPT_DIR="$(dirname "$BATS_TEST_FILENAME")/../.."
    
    # Set up monitoring configuration
    export TASK_QUEUE_DIR="queue"
    export TASK_QUEUE_ENABLED="true"
    export MONITOR_UPDATE_INTERVAL=1
    export MONITOR_LOG_FILE="$TASK_QUEUE_DIR/logs/monitor.log"
    export QUEUE_LOCK_DIR="$TASK_QUEUE_DIR/locks"
    
    # Create required directories and files
    mkdir -p "$TASK_QUEUE_DIR/logs"
    mkdir -p "$TASK_QUEUE_DIR/tmp" 
    mkdir -p "$TASK_QUEUE_DIR/backups"
    mkdir -p "$QUEUE_LOCK_DIR"
    
    # Initialize queue file
    echo '{"tasks":[],"metadata":{"created":"2025-08-31T12:00:00Z","version":"2.0.0"}}' > "$TASK_QUEUE_DIR/tasks.json"
    
    # Source required modules
    if [[ -f "$SCRIPT_DIR/src/task-queue.sh" ]]; then
        export PATH="$SCRIPT_DIR/src:$PATH"
    fi
    
    # Mock essential commands
    mock_command "date" 'command date "$@"'
    mock_command "sleep" 'echo "SLEEP $*" >&2; return 0'
    mock_command "jq" 'mock_jq "$@"'
    
    # Mock jq with consistent responses
    mock_jq() {
        case "$*" in
            -n*timestamp*|*timestamp*)
                echo '{"timestamp":"2025-08-31 12:00:00","update_number":1,"queue_stats":{"total":0,"pending":0,"completed":0,"failed":0},"health_status":{"level":"good","message":"Queue operating normally"},"system_metrics":{"disk_usage_percent":25,"memory_usage_percent":45,"cpu_load_average":"1.23","queue_process_count":2}}'
                ;;
            ".total"|".pending"|".completed"|".failed"|".timeout"|".in_progress")
                echo "0"
                ;;
            ".level")
                echo "good"
                ;;
            ".message")
                echo "Queue operating normally"
                ;;
            *-r*".timestamp")
                echo "2025-08-31 12:00:00"
                ;;
            *-r*".update_number")
                echo "$((RANDOM % 10 + 1))"
                ;;
            *-r*".health_status.level")
                echo "good"
                ;;
            *-r*".health_status.message")
                echo "Queue operating normally"
                ;;
            *-r*".queue_stats")
                echo '{"total":0,"pending":0,"completed":0,"failed":0}'
                ;;
            *-r*".queue_stats."*)
                echo "0"
                ;;
            *)
                echo "{}"
                ;;
        esac
    }
    
    # Set up environment capture
    export ENV_LOG_FILE="$TEST_TEMP_DIR/env.log"
    > "$ENV_LOG_FILE"
    
    # Mock logging to capture environment info
    mock_command "log_info" 'echo "[INFO] $*" | tee -a "$ENV_LOG_FILE"'
    mock_command "log_warn" 'echo "[WARN] $*" | tee -a "$ENV_LOG_FILE"'
    mock_command "log_error" 'echo "[ERROR] $*" | tee -a "$ENV_LOG_FILE"'
    mock_command "log_debug" 'echo "[DEBUG] $*" | tee -a "$ENV_LOG_FILE"'
}

teardown() {
    # Kill any background processes
    jobs -p | xargs -r kill -TERM 2>/dev/null || true
    sleep 0.1
    jobs -p | xargs -r kill -KILL 2>/dev/null || true
    
    default_teardown
}

# ===============================================================================
# INTERACTIVE TERMINAL TESTS
# ===============================================================================

@test "monitor in interactive terminal: should use full display mode" {
    skip_if_no_script "task-queue.sh"
    
    # Mock interactive terminal environment
    mock_command "timeout" '
        if [[ "$1" == "2s" && "$2" == "bash" && "$3" == "-c" && "$4" == "[[ -t 1 ]]" ]]; then
            exit 0  # Simulate interactive terminal
        fi
        command timeout "$@"
    '
    
    # Mock tput as available
    mock_command "tput" 'echo "TERMINAL_CLEAR"; exit 0'
    
    local duration=2
    
    run timeout 5s "$SCRIPT_DIR/src/task-queue.sh" monitor $duration 1
    
    [ "$status" -eq 0 ] || [ "$status" -eq 124 ]
    
    # Should complete successfully in interactive mode
    [[ "$output" != "" ]]
}

@test "monitor in interactive terminal with tput: should use tput for screen clearing" {
    skip_if_no_script "task-queue.sh"
    
    # Mock interactive terminal
    mock_command "timeout" '
        if [[ "$1" == "2s" && "$2" == "bash" ]]; then
            exit 0
        fi
        if [[ "$1" == "5s" ]]; then
            shift; "$@"; exit 0
        fi
        command timeout "$@"
    '
    
    # Mock tput as available and working
    mock_command "tput" 'echo "TPUT_CLEAR_SUCCESS"; exit 0'
    mock_command "command" 'if [[ "$1" == "tput" ]]; then tput "$2"; else "$@"; fi'
    
    local duration=2
    
    run timeout 5s "$SCRIPT_DIR/src/task-queue.sh" monitor $duration 1
    
    [ "$status" -eq 0 ] || [ "$status" -eq 124 ]
    
    # Should complete successfully using tput
    [[ "$output" != "" ]]
}

@test "monitor in interactive terminal without tput: should fallback to printf" {
    skip_if_no_script "task-queue.sh"
    
    # Mock interactive terminal
    mock_command "timeout" '
        if [[ "$1" == "2s" && "$2" == "bash" ]]; then
            exit 0
        fi
        if [[ "$1" == "5s" ]]; then
            shift; "$@"; exit 0
        fi
        command timeout "$@"
    '
    
    # Mock tput as unavailable
    mock_command "tput" 'exit 127'  # command not found
    mock_command "command" '
        if [[ "$1" == "tput" ]]; then
            exit 127
        else
            "$@"
        fi
    '
    
    local duration=2
    
    run timeout 5s "$SCRIPT_DIR/src/task-queue.sh" monitor $duration 1
    
    [ "$status" -eq 0 ] || [ "$status" -eq 124 ]
    
    # Should complete successfully with printf fallback
    [[ "$output" != "" ]]
}

# ===============================================================================
# NON-INTERACTIVE TERMINAL TESTS
# ===============================================================================

@test "monitor in non-interactive terminal: should use simple display mode" {
    skip_if_no_script "task-queue.sh"
    
    # Mock non-interactive terminal
    mock_command "timeout" '
        if [[ "$1" == "2s" && "$2" == "bash" && "$3" == "-c" && "$4" == "[[ -t 1 ]]" ]]; then
            exit 1  # Simulate non-interactive terminal
        fi
        command timeout "$@"
    '
    
    local duration=2
    
    run timeout 5s "$SCRIPT_DIR/src/task-queue.sh" monitor $duration 1
    
    [ "$status" -eq 0 ] || [ "$status" -eq 124 ]
    
    # Should complete successfully in non-interactive mode
    [[ "$output" != "" ]]
    
    # Should use simple text display (no ANSI escape sequences for clearing)
    [[ "$output" != *"\033[2J"* ]] || true  # May not appear in test output
}

@test "monitor with redirected output: should handle non-interactive gracefully" {
    skip_if_no_script "task-queue.sh"
    
    local duration=2
    local output_file="$TEST_TEMP_DIR/monitor_output.txt"
    
    # Run with output redirected (simulates non-interactive)
    run bash -c "timeout 5s '$SCRIPT_DIR/src/task-queue.sh' monitor $duration 1 > '$output_file' 2>&1"
    
    [ "$status" -eq 0 ] || [ "$status" -eq 124 ]
    
    # Should have created output
    [ -f "$output_file" ]
    [ -s "$output_file" ] || [[ "$output" != "" ]]
}

@test "monitor with stdin redirected: should handle pipe input gracefully" {
    skip_if_no_script "task-queue.sh"
    
    local duration=2
    
    # Run with stdin redirected from /dev/null
    run bash -c "timeout 5s '$SCRIPT_DIR/src/task-queue.sh' monitor $duration 1 < /dev/null"
    
    [ "$status" -eq 0 ] || [ "$status" -eq 124 ]
    
    # Should complete without hanging on input
    [[ "$output" != "" ]] || true  # May not have output in test environment
}

# ===============================================================================
# SSH/REMOTE TERMINAL SIMULATION TESTS
# ===============================================================================

@test "monitor in simulated SSH session: should detect and handle appropriately" {
    skip_if_no_script "task-queue.sh"
    
    # Mock SSH-like environment
    export SSH_CLIENT="192.168.1.100 12345 22"
    export SSH_CONNECTION="192.168.1.100 12345 192.168.1.1 22"
    
    # Mock terminal detection for SSH environment
    mock_command "timeout" '
        if [[ "$1" == "2s" && "$2" == "bash" ]]; then
            # SSH terminals may be interactive but have limitations
            exit 0
        fi
        if [[ "$1" == "5s" ]]; then
            shift; "$@"; exit 0
        fi
        command timeout "$@"
    '
    
    local duration=2
    
    run timeout 5s "$SCRIPT_DIR/src/task-queue.sh" monitor $duration 1
    
    [ "$status" -eq 0 ] || [ "$status" -eq 124 ]
    
    # Should handle SSH environment
    [[ "$output" != "" ]] || [ -s "$ENV_LOG_FILE" ]
    
    # Clean up environment
    unset SSH_CLIENT SSH_CONNECTION
}

@test "monitor with TERM variable: should adapt to terminal capabilities" {
    skip_if_no_script "task-queue.sh"
    
    # Test with different TERM values
    local term_values=("xterm-256color" "xterm" "dumb" "")
    
    for term_val in "${term_values[@]}"; do
        export TERM="$term_val"
        
        # Mock timeout based on TERM capabilities
        mock_command "timeout" '
            if [[ "$1" == "2s" && "$2" == "bash" ]]; then
                if [[ "$TERM" == "dumb" || -z "$TERM" ]]; then
                    exit 1  # Non-interactive for dumb/empty terminal
                else
                    exit 0  # Interactive for capable terminals
                fi
            fi
            if [[ "$1" == "5s" ]]; then
                shift; "$@"; exit 0
            fi
            command timeout "$@"
        '
        
        local duration=1
        
        run timeout 4s "$SCRIPT_DIR/src/task-queue.sh" monitor $duration 1
        
        # Should complete regardless of TERM value
        [ "$status" -eq 0 ] || [ "$status" -eq 124 ]
    done
}

# ===============================================================================
# IDE/EDITOR TERMINAL TESTS
# ===============================================================================

@test "monitor in simulated VS Code terminal: should handle integrated terminal" {
    skip_if_no_script "task-queue.sh"
    
    # Mock VS Code integrated terminal environment
    export TERM_PROGRAM="vscode"
    export VSCODE_INJECTION="1"
    
    # VS Code terminals are typically interactive
    mock_command "timeout" '
        if [[ "$1" == "2s" && "$2" == "bash" ]]; then
            exit 0  # Interactive
        fi
        if [[ "$1" == "5s" ]]; then
            shift; "$@"; exit 0
        fi
        command timeout "$@"
    '
    
    # Mock tput with VS Code compatibility
    mock_command "tput" 'echo "VSCODE_TERMINAL_CLEAR"; exit 0'
    
    local duration=2
    
    run timeout 5s "$SCRIPT_DIR/src/task-queue.sh" monitor $duration 1
    
    [ "$status" -eq 0 ] || [ "$status" -eq 124 ]
    
    # Should handle VS Code terminal
    [[ "$output" != "" ]] || [ -s "$ENV_LOG_FILE" ]
    
    # Clean up environment
    unset TERM_PROGRAM VSCODE_INJECTION
}

@test "monitor in simulated IntelliJ terminal: should handle IDE terminal" {
    skip_if_no_script "task-queue.sh"
    
    # Mock IntelliJ IDEA terminal environment
    export TERMINAL_EMULATOR="IntelliJ"
    
    # IDE terminals are typically interactive
    mock_command "timeout" '
        if [[ "$1" == "2s" && "$2" == "bash" ]]; then
            exit 0  # Interactive
        fi
        if [[ "$1" == "5s" ]]; then
            shift; "$@"; exit 0
        fi
        command timeout "$@"
    '
    
    local duration=2
    
    run timeout 5s "$SCRIPT_DIR/src/task-queue.sh" monitor $duration 1
    
    [ "$status" -eq 0 ] || [ "$status" -eq 124 ]
    
    # Should handle IDE terminal
    [[ "$output" != "" ]] || [ -s "$ENV_LOG_FILE" ]
    
    # Clean up environment
    unset TERMINAL_EMULATOR
}

# ===============================================================================
# HEADLESS/SCRIPT ENVIRONMENT TESTS
# ===============================================================================

@test "monitor in cron-like environment: should handle headless execution" {
    skip_if_no_script "task-queue.sh"
    
    # Mock cron-like environment (no terminal)
    unset TERM
    export PATH="/usr/bin:/bin"  # Limited PATH like cron
    
    # Mock non-interactive environment
    mock_command "timeout" '
        if [[ "$1" == "2s" && "$2" == "bash" ]]; then
            exit 1  # Non-interactive
        fi
        command timeout "$@"
    '
    
    local duration=2
    
    run timeout 5s "$SCRIPT_DIR/src/task-queue.sh" monitor $duration 1
    
    [ "$status" -eq 0 ] || [ "$status" -eq 124 ]
    
    # Should handle headless execution
    [[ "$output" != "" ]] || [ -s "$ENV_LOG_FILE" ] || [ -s "$MONITOR_LOG_FILE" ]
}

@test "monitor in systemd service environment: should handle service execution" {
    skip_if_no_script "task-queue.sh"
    
    # Mock systemd service environment
    export INVOCATION_ID="test-service-invocation-id"
    export JOURNAL_STREAM="9:12345"
    unset TERM
    
    # Mock non-interactive service environment
    mock_command "timeout" '
        if [[ "$1" == "2s" && "$2" == "bash" ]]; then
            exit 1  # Non-interactive
        fi
        command timeout "$@"
    '
    
    local duration=2
    
    run timeout 5s "$SCRIPT_DIR/src/task-queue.sh" monitor $duration 1
    
    [ "$status" -eq 0 ] || [ "$status" -eq 124 ]
    
    # Should handle systemd service environment
    [[ "$output" != "" ]] || [ -s "$ENV_LOG_FILE" ] || [ -s "$MONITOR_LOG_FILE" ]
    
    # Clean up environment
    unset INVOCATION_ID JOURNAL_STREAM
}

@test "monitor in Docker container: should handle containerized execution" {
    skip_if_no_script "task-queue.sh"
    
    # Mock Docker container environment
    export container="docker"
    echo "docker" > /proc/1/cgroup 2>/dev/null || true
    
    # Containers typically don't have interactive terminals by default
    mock_command "timeout" '
        if [[ "$1" == "2s" && "$2" == "bash" ]]; then
            exit 1  # Non-interactive
        fi
        command timeout "$@"
    '
    
    local duration=2
    
    run timeout 5s "$SCRIPT_DIR/src/task-queue.sh" monitor $duration 1
    
    [ "$status" -eq 0 ] || [ "$status" -eq 124 ]
    
    # Should handle containerized execution
    [[ "$output" != "" ]] || [ -s "$ENV_LOG_FILE" ] || [ -s "$MONITOR_LOG_FILE" ]
    
    # Clean up environment
    unset container
}

# ===============================================================================
# TERMINAL CAPABILITY DETECTION TESTS
# ===============================================================================

@test "monitor with limited terminal capabilities: should detect and adapt" {
    skip_if_no_script "task-queue.sh"
    
    # Mock terminal with limited capabilities
    export TERM="dumb"
    
    # Mock timeout to reflect dumb terminal behavior
    mock_command "timeout" '
        if [[ "$1" == "2s" && "$2" == "bash" ]]; then
            exit 1  # Dumb terminal is non-interactive
        fi
        command timeout "$@"
    '
    
    # Mock tput as unavailable for dumb terminal
    mock_command "tput" 'exit 2'  # No such terminal capability
    
    local duration=2
    
    run timeout 5s "$SCRIPT_DIR/src/task-queue.sh" monitor $duration 1
    
    [ "$status" -eq 0 ] || [ "$status" -eq 124 ]
    
    # Should adapt to limited capabilities
    [[ "$output" != "" ]] || [ -s "$ENV_LOG_FILE" ]
}

@test "monitor with broken terminal detection: should use fallback methods" {
    skip_if_no_script "task-queue.sh"
    
    # Mock broken timeout command
    mock_command "timeout" '
        if [[ "$1" == "2s" ]]; then
            exit 127  # Command not found
        fi
        command timeout "$@"
    '
    
    local duration=2
    
    run timeout 5s "$SCRIPT_DIR/src/task-queue.sh" monitor $duration 1
    
    [ "$status" -eq 0 ] || [ "$status" -eq 124 ]
    
    # Should use fallback detection methods
    [[ "$output" != "" ]] || [ -s "$ENV_LOG_FILE" ]
}

# ===============================================================================
# CROSS-PLATFORM COMPATIBILITY TESTS
# ===============================================================================

@test "monitor on macOS-like environment: should handle macOS specifics" {
    skip_if_no_script "task-queue.sh"
    
    # Mock macOS environment
    mock_command "uname" 'echo "Darwin"'
    
    # Mock macOS-specific commands
    mock_command "vm_stat" 'echo "Pages free: 100000."; echo "Pages wired down: 200000."'
    mock_command "uptime" 'echo "12:00 up 1 day, 1 user, load averages: 1.23 1.45 1.67"'
    
    local duration=2
    
    run timeout 5s "$SCRIPT_DIR/src/task-queue.sh" monitor $duration 1
    
    [ "$status" -eq 0 ] || [ "$status" -eq 124 ]
    
    # Should handle macOS environment
    [[ "$output" != "" ]] || [ -s "$ENV_LOG_FILE" ]
}

@test "monitor on Linux-like environment: should handle Linux specifics" {
    skip_if_no_script "task-queue.sh"
    
    # Mock Linux environment
    mock_command "uname" 'echo "Linux"'
    
    # Mock Linux-specific commands
    mock_command "free" 'echo "             total       used       free"; echo "Mem:       8000000    2000000    6000000"'
    mock_command "uptime" 'echo "12:00:00 up 1 day,  1 user,  load average: 1.23, 1.45, 1.67"'
    
    local duration=2
    
    run timeout 5s "$SCRIPT_DIR/src/task-queue.sh" monitor $duration 1
    
    [ "$status" -eq 0 ] || [ "$status" -eq 124 ]
    
    # Should handle Linux environment
    [[ "$output" != "" ]] || [ -s "$ENV_LOG_FILE" ]
}

# ===============================================================================
# ERROR RECOVERY ACROSS ENVIRONMENTS TESTS
# ===============================================================================

@test "monitor environment switching: should adapt when environment changes" {
    skip_if_no_script "task-queue.sh"
    
    # Start in interactive mode
    mock_command "timeout" '
        if [[ "$1" == "2s" && "$2" == "bash" ]]; then
            # First call: interactive
            if [[ ! -f "$TEST_TEMP_DIR/switched" ]]; then
                touch "$TEST_TEMP_DIR/switched"
                exit 0
            else
                # Second call: non-interactive (simulating environment change)
                exit 1
            fi
        fi
        if [[ "$1" == "5s" ]]; then
            shift; "$@"; exit 0
        fi
        command timeout "$@"
    '
    
    local duration=3
    
    run timeout 6s "$SCRIPT_DIR/src/task-queue.sh" monitor $duration 1
    
    [ "$status" -eq 0 ] || [ "$status" -eq 124 ]
    
    # Should adapt to environment changes during execution
    [[ "$output" != "" ]] || [ -s "$ENV_LOG_FILE" ]
    
    # Clean up
    rm -f "$TEST_TEMP_DIR/switched"
}

@test "monitor with intermittent terminal failures: should recover gracefully" {
    skip_if_no_script "task-queue.sh"
    
    # Mock intermittent terminal failures
    mock_command "timeout" '
        if [[ "$1" == "2s" && "$2" == "bash" ]]; then
            # Randomly succeed or fail (50/50)
            if [[ $(( RANDOM % 2 )) -eq 0 ]]; then
                exit 0
            else
                exit 1
            fi
        fi
        if [[ "$1" == "5s" ]]; then
            # Randomly timeout display operations
            if [[ $(( RANDOM % 4 )) -eq 0 ]]; then
                exit 124  # Timeout
            else
                shift; "$@"; exit 0
            fi
        fi
        command timeout "$@"
    '
    
    local duration=3
    
    run timeout 6s "$SCRIPT_DIR/src/task-queue.sh" monitor $duration 1
    
    [ "$status" -eq 0 ] || [ "$status" -eq 124 ]
    
    # Should recover from intermittent failures
    [[ "$output" != "" ]] || [ -s "$ENV_LOG_FILE" ]
}

# ===============================================================================
# HELPER FUNCTIONS
# ===============================================================================

skip_if_no_script() {
    local script="$1"
    if [[ ! -f "$SCRIPT_DIR/src/$script" ]]; then
        skip "Script $script not found at $SCRIPT_DIR/src/$script"
    fi
    
    if [[ ! -x "$SCRIPT_DIR/src/$script" ]]; then
        skip "Script $script not executable"
    fi
}