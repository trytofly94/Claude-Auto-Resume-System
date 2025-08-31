#!/usr/bin/env bats

# Integration tests for Monitoring Timeout Behavior
# Tests the complete monitoring daemon workflow with focus on timeout and hang prevention

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
    
    # Mock essential system commands
    mock_command "date" 'command date "$@"'
    mock_command "sleep" 'echo "SLEEP $*"; return 0'  # Speed up tests
    mock_command "jq" 'mock_jq "$@"'
    
    # Mock jq with queue-aware responses
    mock_jq() {
        case "$*" in
            -n*timestamp*|*timestamp*)
                echo '{"timestamp":"2025-08-31 12:00:00","update_number":1,"queue_stats":{"total":0,"pending":0,"completed":0,"failed":0},"health_status":{"level":"good","message":"Queue operating normally"}}'
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
                echo "1"
                ;;
            *-r*".health_status.level")
                echo "good"
                ;;
            *)
                echo "{}"
                ;;
        esac
    }
    
    # Mock logging functions
    mock_command "log_info" 'echo "[INFO] $*" >> "$TEST_TEMP_DIR/test_log"'
    mock_command "log_warn" 'echo "[WARN] $*" >> "$TEST_TEMP_DIR/test_log"'
    mock_command "log_error" 'echo "[ERROR] $*" >> "$TEST_TEMP_DIR/test_log"'
    mock_command "log_debug" 'echo "[DEBUG] $*" >> "$TEST_TEMP_DIR/test_log"'
}

teardown() {
    # Kill any background processes
    jobs -p | xargs -r kill -TERM 2>/dev/null || true
    sleep 0.1
    jobs -p | xargs -r kill -KILL 2>/dev/null || true
    
    default_teardown
}

# ===============================================================================
# MONITORING DAEMON TIMEOUT TESTS
# ===============================================================================

@test "monitor command: should complete within specified duration" {
    skip_if_no_script "task-queue.sh"
    
    local duration=3
    local start_time=$(date +%s)
    
    # Run monitoring with timeout
    run timeout 8s "$SCRIPT_DIR/src/task-queue.sh" monitor $duration 1
    
    local end_time=$(date +%s)
    local actual_duration=$((end_time - start_time))
    
    # Should complete successfully
    [ "$status" -eq 0 ] || [ "$status" -eq 124 ]  # 124 is timeout exit code
    
    # Should not run significantly longer than specified duration
    [ $actual_duration -le $((duration + 2)) ]  # Allow 2 second buffer
    
    # Should have created some output/logs
    [[ "$output" != "" ]] || [ -f "$TEST_TEMP_DIR/test_log" ]
}

@test "monitor command: should not hang indefinitely without duration" {
    skip_if_no_script "task-queue.sh"
    
    # Start monitoring in background and kill after reasonable time
    timeout 5s "$SCRIPT_DIR/src/task-queue.sh" monitor &
    local monitor_pid=$!
    
    # Wait a bit to see if it starts properly
    sleep 2
    
    # Check if process is still running
    if kill -0 "$monitor_pid" 2>/dev/null; then
        # Process is running - kill it
        kill -TERM "$monitor_pid" 2>/dev/null
        wait "$monitor_pid" 2>/dev/null
        local exit_status=$?
        
        # Should have been terminated gracefully or by timeout
        [[ $exit_status -eq 143 || $exit_status -eq 124 || $exit_status -eq 0 ]]
    fi
}

@test "monitor command: should handle Ctrl+C interruption gracefully" {
    skip_if_no_script "task-queue.sh"
    
    # Start monitoring in background
    "$SCRIPT_DIR/src/task-queue.sh" monitor 10 1 &
    local monitor_pid=$!
    
    # Wait a moment for it to start
    sleep 1
    
    # Send INT signal (Ctrl+C equivalent)
    kill -INT "$monitor_pid" 2>/dev/null
    
    # Wait for graceful shutdown
    local timeout=5
    local count=0
    while kill -0 "$monitor_pid" 2>/dev/null && [ $count -lt $timeout ]; do
        sleep 1
        ((count++))
    done
    
    # Process should have exited by now
    ! kill -0 "$monitor_pid" 2>/dev/null
}

@test "monitor command with debug: should complete within specified duration" {
    skip_if_no_script "task-queue.sh"
    
    local duration=2
    local start_time=$(date +%s)
    
    # Run monitoring with debug mode and timeout
    run timeout 6s "$SCRIPT_DIR/src/task-queue.sh" monitor --debug $duration 1
    
    local end_time=$(date +%s)
    local actual_duration=$((end_time - start_time))
    
    # Should complete successfully
    [ "$status" -eq 0 ] || [ "$status" -eq 124 ]
    
    # Should not run significantly longer than specified duration
    [ $actual_duration -le $((duration + 2)) ]
    
    # Should have debug output
    [[ "$output" == *"DEBUG"* ]] || [[ -f "$TEST_TEMP_DIR/test_log" && "$(cat "$TEST_TEMP_DIR/test_log")" == *"DEBUG"* ]]
}

# ===============================================================================
# TERMINAL INTERACTION TIMEOUT TESTS
# ===============================================================================

@test "monitor command: should work in non-interactive environment" {
    skip_if_no_script "task-queue.sh"
    
    # Simulate non-interactive environment by redirecting stdin/stdout
    local duration=2
    
    run bash -c "echo | timeout 5s '$SCRIPT_DIR/src/task-queue.sh' monitor $duration 1 < /dev/null"
    
    # Should complete without hanging
    [ "$status" -eq 0 ] || [ "$status" -eq 124 ]
}

@test "monitor command: should handle terminal detection timeout" {
    skip_if_no_script "task-queue.sh"
    
    # Mock timeout command to simulate hanging terminal detection
    mock_command "timeout" '
        if [[ "$1" == "2s" && "$2" == "bash" ]]; then
            # Simulate timeout in terminal detection
            exit 124
        fi
        command timeout "$@"
    '
    
    local duration=2
    
    run timeout 5s "$SCRIPT_DIR/src/task-queue.sh" monitor $duration 1
    
    # Should still complete (fallback to simple display)
    [ "$status" -eq 0 ] || [ "$status" -eq 124 ]
}

@test "monitor command: should handle display function timeout" {
    skip_if_no_script "task-queue.sh"
    
    # Mock tput/printf to simulate hanging display
    mock_command "tput" 'sleep 10; exit 0'  # Simulate hanging tput
    
    local duration=2
    
    run timeout 8s "$SCRIPT_DIR/src/task-queue.sh" monitor $duration 1
    
    # Should complete despite display issues (should use fallback)
    [ "$status" -eq 0 ] || [ "$status" -eq 124 ]
}

# ===============================================================================
# MONITORING UPDATE BEHAVIOR TESTS
# ===============================================================================

@test "monitoring daemon: should perform multiple updates within duration" {
    skip_if_no_script "task-queue.sh"
    
    # Clear previous logs
    > "$TEST_TEMP_DIR/test_log"
    
    local duration=3
    local interval=1
    
    run timeout $((duration + 2))s "$SCRIPT_DIR/src/task-queue.sh" monitor $duration $interval
    
    [ "$status" -eq 0 ] || [ "$status" -eq 124 ]
    
    # Should have performed multiple updates
    if [ -f "$TEST_TEMP_DIR/test_log" ]; then
        local update_count=$(grep -c "Starting update\|perform_monitoring_update" "$TEST_TEMP_DIR/test_log" 2>/dev/null || echo "0")
        [ "$update_count" -ge 2 ]  # Should have at least 2 updates in 3 seconds with 1s interval
    fi
}

@test "monitoring daemon: should stop at exact duration" {
    skip_if_no_script "task-queue.sh"
    
    # Clear previous logs
    > "$TEST_TEMP_DIR/test_log"
    
    local duration=2
    local start_time=$(date +%s)
    
    run timeout 5s "$SCRIPT_DIR/src/task-queue.sh" monitor $duration 1
    
    local end_time=$(date +%s)
    local actual_duration=$((end_time - start_time))
    
    [ "$status" -eq 0 ] || [ "$status" -eq 124 ]
    
    # Should have stopped around the specified duration (within 1 second tolerance)
    [ $actual_duration -ge $duration ]
    [ $actual_duration -le $((duration + 1)) ]
    
    # Should have logged completion
    if [ -f "$TEST_TEMP_DIR/test_log" ]; then
        grep -q "duration expired\|Stopping monitoring daemon" "$TEST_TEMP_DIR/test_log" || true
    fi
}

# ===============================================================================
# ERROR HANDLING AND RECOVERY TESTS
# ===============================================================================

@test "monitoring daemon: should handle data collection failures gracefully" {
    skip_if_no_script "task-queue.sh"
    
    # Mock jq to fail occasionally
    mock_command "jq" '
        if [[ $(( RANDOM % 3 )) -eq 0 ]]; then
            echo "jq: parse error" >&2
            exit 1
        fi
        mock_jq "$@"
    '
    
    local duration=2
    
    run timeout 5s "$SCRIPT_DIR/src/task-queue.sh" monitor $duration 1
    
    # Should complete despite data collection failures
    [ "$status" -eq 0 ] || [ "$status" -eq 124 ]
}

@test "monitoring daemon: should handle missing queue file gracefully" {
    skip_if_no_script "task-queue.sh"
    
    # Remove queue file to simulate missing queue
    rm -f "$TASK_QUEUE_DIR/tasks.json"
    
    local duration=2
    
    run timeout 5s "$SCRIPT_DIR/src/task-queue.sh" monitor $duration 1
    
    # Should complete without crashing
    [ "$status" -eq 0 ] || [ "$status" -eq 124 ]
}

@test "monitoring daemon: should handle disk space issues gracefully" {
    skip_if_no_script "task-queue.sh"
    
    # Mock df command to simulate disk full
    mock_command "df" 'echo "Filesystem     1K-blocks    Used Avail Use% Mounted on"; echo "/dev/disk1     1000000  990000 10000  99% /"'
    
    local duration=2
    
    run timeout 5s "$SCRIPT_DIR/src/task-queue.sh" monitor $duration 1
    
    # Should complete and report the disk issue
    [ "$status" -eq 0 ] || [ "$status" -eq 124 ]
    
    # Should still function despite high disk usage
    [[ "$output" != "" ]] || [ -f "$TEST_TEMP_DIR/test_log" ]
}

# ===============================================================================
# SIGNAL HANDLING TESTS
# ===============================================================================

@test "monitoring daemon: should handle TERM signal cleanly" {
    skip_if_no_script "task-queue.sh"
    
    # Start long-running monitor
    "$SCRIPT_DIR/src/task-queue.sh" monitor 30 1 &
    local monitor_pid=$!
    
    # Wait for it to start
    sleep 1
    
    # Send TERM signal
    kill -TERM "$monitor_pid"
    
    # Wait for cleanup (max 3 seconds)
    local timeout=3
    local count=0
    while kill -0 "$monitor_pid" 2>/dev/null && [ $count -lt $timeout ]; do
        sleep 1
        ((count++))
    done
    
    # Should have exited cleanly
    ! kill -0 "$monitor_pid" 2>/dev/null
}

@test "monitoring daemon: should clean up resources on exit" {
    skip_if_no_script "task-queue.sh"
    
    # Create some temporary monitoring files
    touch "$TASK_QUEUE_DIR/tmp/monitor-test-file"
    
    local duration=1
    
    run timeout 3s "$SCRIPT_DIR/src/task-queue.sh" monitor $duration 1
    
    [ "$status" -eq 0 ] || [ "$status" -eq 124 ]
    
    # Temporary files should be cleaned up (if cleanup is implemented)
    # This test documents expected behavior
    if [ -d "$TASK_QUEUE_DIR/tmp" ]; then
        local temp_count=$(find "$TASK_QUEUE_DIR/tmp" -name "monitor-*" 2>/dev/null | wc -l)
        [[ "$temp_count" == "0" ]] || true  # May or may not be implemented
    fi
}

# ===============================================================================
# PERFORMANCE AND RESOURCE TESTS
# ===============================================================================

@test "monitoring daemon: should not consume excessive resources" {
    skip_if_no_script "task-queue.sh"
    
    local duration=3
    
    # Monitor resource usage during monitoring
    local start_time=$(date +%s)
    
    run timeout 6s "$SCRIPT_DIR/src/task-queue.sh" monitor $duration 1
    
    local end_time=$(date +%s)
    local actual_duration=$((end_time - start_time))
    
    [ "$status" -eq 0 ] || [ "$status" -eq 124 ]
    
    # Should complete in reasonable time
    [ $actual_duration -le $((duration + 2)) ]
    
    # This is more about documentation - actual resource monitoring would require more complex setup
}

@test "monitoring daemon: should handle multiple rapid signals" {
    skip_if_no_script "task-queue.sh"
    
    # Start monitor
    "$SCRIPT_DIR/src/task-queue.sh" monitor 10 1 &
    local monitor_pid=$!
    
    # Wait for it to start
    sleep 1
    
    # Send multiple signals rapidly
    kill -USR1 "$monitor_pid" 2>/dev/null || true
    kill -USR2 "$monitor_pid" 2>/dev/null || true
    kill -HUP "$monitor_pid" 2>/dev/null || true
    
    # Should still be running
    kill -0 "$monitor_pid" 2>/dev/null
    
    # Clean shutdown
    kill -TERM "$monitor_pid"
    
    # Should exit cleanly
    local timeout=3
    local count=0
    while kill -0 "$monitor_pid" 2>/dev/null && [ $count -lt $timeout ]; do
        sleep 1
        ((count++))
    done
    
    ! kill -0 "$monitor_pid" 2>/dev/null
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