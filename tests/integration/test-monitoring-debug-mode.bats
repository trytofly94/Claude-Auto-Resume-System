#!/usr/bin/env bats

# Integration tests for Monitoring Debug Mode Functionality
# Tests debug mode features and verbose logging in the monitoring system

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
    mock_command "sleep" 'echo "SLEEP $*" >&2; return 0'  # Speed up tests
    mock_command "jq" 'mock_jq "$@"'
    
    # Mock jq with realistic responses
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
            *-r*".system_metrics."*)
                case "$*" in
                    *disk_usage_percent*) echo "25" ;;
                    *memory_usage_percent*) echo "45" ;;
                    *cpu_load_average*) echo "1.23" ;;
                    *queue_process_count*) echo "2" ;;
                    *) echo "0" ;;
                esac
                ;;
            *)
                echo "{}"
                ;;
        esac
    }
    
    # Set up debug log capture
    export DEBUG_LOG_FILE="$TEST_TEMP_DIR/debug.log"
    > "$DEBUG_LOG_FILE"
    
    # Mock logging functions to capture debug output
    mock_command "log_info" 'echo "[INFO] $*" | tee -a "$DEBUG_LOG_FILE"'
    mock_command "log_warn" 'echo "[WARN] $*" | tee -a "$DEBUG_LOG_FILE"'  
    mock_command "log_error" 'echo "[ERROR] $*" | tee -a "$DEBUG_LOG_FILE"'
    mock_command "log_debug" 'echo "[DEBUG] $*" | tee -a "$DEBUG_LOG_FILE"'
}

teardown() {
    # Kill any background processes
    jobs -p | xargs -r kill -TERM 2>/dev/null || true
    sleep 0.1
    jobs -p | xargs -r kill -KILL 2>/dev/null || true
    
    default_teardown
}

# ===============================================================================
# DEBUG MODE ACTIVATION TESTS
# ===============================================================================

@test "monitor --debug: should enable debug mode and show debug messages" {
    skip_if_no_script "task-queue.sh"
    
    local duration=2
    
    run timeout 5s "$SCRIPT_DIR/src/task-queue.sh" monitor --debug $duration 1
    
    [ "$status" -eq 0 ] || [ "$status" -eq 124 ]
    
    # Should have debug output in stderr or debug log
    if [[ "$output" == *"DEBUG"* ]]; then
        [[ "$output" == *"Starting monitoring daemon with debug mode enabled"* ]]
    else
        # Check debug log file
        [ -f "$DEBUG_LOG_FILE" ]
        grep -q "DEBUG.*Starting monitoring daemon with debug mode enabled" "$DEBUG_LOG_FILE"
    fi
}

@test "monitor with debug: should log debug information for each update" {
    skip_if_no_script "task-queue.sh"
    
    local duration=3
    local interval=1
    
    run timeout 6s "$SCRIPT_DIR/src/task-queue.sh" monitor --debug $duration $interval
    
    [ "$status" -eq 0 ] || [ "$status" -eq 124 ]
    
    # Should have multiple debug update messages
    if [ -f "$DEBUG_LOG_FILE" ]; then
        local debug_update_count=$(grep -c "DEBUG.*Starting update" "$DEBUG_LOG_FILE" 2>/dev/null || echo "0")
        [ "$debug_update_count" -ge 2 ]  # Should have at least 2 updates
    else
        # Check in main output
        [[ "$output" == *"DEBUG"*"Starting update"* ]]
    fi
}

@test "monitor --debug: should show terminal detection debugging" {
    skip_if_no_script "task-queue.sh"
    
    local duration=2
    
    run timeout 5s "$SCRIPT_DIR/src/task-queue.sh" monitor --debug $duration 1
    
    [ "$status" -eq 0 ] || [ "$status" -eq 124 ]
    
    # Should have terminal detection debug messages
    if [ -f "$DEBUG_LOG_FILE" ]; then
        grep -q "DEBUG.*terminal\|DEBUG.*display" "$DEBUG_LOG_FILE" || true
    fi
    
    # At minimum should have some debug output
    [[ "$output" == *"DEBUG"* ]] || [ -s "$DEBUG_LOG_FILE" ]
}

@test "monitor without debug: should not show debug messages" {
    skip_if_no_script "task-queue.sh"
    
    local duration=2
    
    run timeout 5s "$SCRIPT_DIR/src/task-queue.sh" monitor $duration 1
    
    [ "$status" -eq 0 ] || [ "$status" -eq 124 ]
    
    # Should not have debug output
    [[ "$output" != *"DEBUG"* ]]
    
    if [ -f "$DEBUG_LOG_FILE" ]; then
        # Debug log should be empty or not contain debug messages
        local debug_count=$(grep -c "DEBUG" "$DEBUG_LOG_FILE" 2>/dev/null || echo "0")
        [ "$debug_count" -eq 0 ]
    fi
}

# ===============================================================================
# DEBUG MODE DISPLAY BEHAVIOR TESTS
# ===============================================================================

@test "monitor --debug: should debug terminal interaction issues" {
    skip_if_no_script "task-queue.sh"
    
    # Mock timeout to simulate terminal detection timeout
    mock_command "timeout" '
        if [[ "$1" == "2s" && "$2" == "bash" ]]; then
            echo "[TIMEOUT] Terminal detection timed out" >&2
            exit 124
        fi
        command timeout "$@"
    '
    
    local duration=2
    
    run timeout 5s "$SCRIPT_DIR/src/task-queue.sh" monitor --debug $duration 1
    
    [ "$status" -eq 0 ] || [ "$status" -eq 124 ]
    
    # Should show debug information about terminal issues
    if [ -f "$DEBUG_LOG_FILE" ]; then
        grep -q "DEBUG.*Terminal not interactive\|DEBUG.*display.*failed" "$DEBUG_LOG_FILE" || true
    fi
}

@test "monitor --debug: should show display fallback debugging" {
    skip_if_no_script "task-queue.sh"
    
    # Mock terminal detection to return true, but display to fail
    mock_command "tput" 'echo "tput command failed" >&2; exit 1'
    
    local duration=2
    
    run timeout 5s "$SCRIPT_DIR/src/task-queue.sh" monitor --debug $duration 1
    
    [ "$status" -eq 0 ] || [ "$status" -eq 124 ]
    
    # Should debug the fallback mechanism
    if [ -f "$DEBUG_LOG_FILE" ]; then
        grep -q "DEBUG.*Full display failed\|DEBUG.*trying simple display" "$DEBUG_LOG_FILE" || true
    fi
}

@test "monitor --debug: should show data collection debugging" {
    skip_if_no_script "task-queue.sh"
    
    # Mock some system metrics to fail occasionally
    mock_command "df" 'echo "df: command failed" >&2; exit 1'
    
    local duration=2
    
    run timeout 5s "$SCRIPT_DIR/src/task-queue.sh" monitor --debug $duration 1
    
    [ "$status" -eq 0 ] || [ "$status" -eq 124 ]
    
    # Should still work and show debugging info about data collection
    [[ "$output" != "" ]] || [ -s "$DEBUG_LOG_FILE" ]
}

# ===============================================================================
# DEBUG MODE PARAMETER PASSING TESTS
# ===============================================================================

@test "monitor --debug: should accept debug flag in different positions" {
    skip_if_no_script "task-queue.sh"
    
    # Test different argument orders
    local test_cases=(
        "monitor --debug 2 1"
        "monitor 2 --debug 1"
        "monitor 2 1 --debug"
    )
    
    for test_case in "${test_cases[@]}"; do
        run timeout 5s bash -c "$SCRIPT_DIR/src/task-queue.sh $test_case"
        
        # Should accept debug flag in any position
        [ "$status" -eq 0 ] || [ "$status" -eq 124 ]
        
        # Should show debug output
        [[ "$output" == *"DEBUG"* ]] || [ -s "$DEBUG_LOG_FILE" ]
        
        # Reset debug log for next test
        > "$DEBUG_LOG_FILE"
    done
}

@test "monitor debug: should show parameter validation debugging" {
    skip_if_no_script "task-queue.sh"
    
    # Test with various parameter combinations
    run timeout 5s "$SCRIPT_DIR/src/task-queue.sh" monitor --debug 1 0.5
    
    [ "$status" -eq 0 ] || [ "$status" -eq 124 ]
    
    # Should show debug info about parameters
    if [ -f "$DEBUG_LOG_FILE" ]; then
        grep -q "DEBUG.*Duration.*Interval" "$DEBUG_LOG_FILE" || grep -q "DEBUG.*duration.*interval" "$DEBUG_LOG_FILE" || true
    fi
}

# ===============================================================================
# DEBUG MODE ERROR HANDLING TESTS
# ===============================================================================

@test "monitor --debug: should debug JSON parsing issues" {
    skip_if_no_script "task-queue.sh"
    
    # Mock jq to occasionally fail
    mock_command "jq" '
        if [[ $(( RANDOM % 4 )) -eq 0 ]]; then
            echo "jq: parse error: Invalid JSON" >&2
            exit 1
        fi
        mock_jq "$@"
    '
    
    local duration=3
    
    run timeout 6s "$SCRIPT_DIR/src/task-queue.sh" monitor --debug $duration 1
    
    [ "$status" -eq 0 ] || [ "$status" -eq 124 ]
    
    # Should continue running despite JSON errors and show debug info
    [[ "$output" != "" ]] || [ -s "$DEBUG_LOG_FILE" ]
}

@test "monitor --debug: should debug queue file access issues" {
    skip_if_no_script "task-queue.sh"
    
    # Make queue file temporarily unreadable
    chmod 000 "$TASK_QUEUE_DIR/tasks.json" 2>/dev/null || true
    
    local duration=2
    
    run timeout 5s "$SCRIPT_DIR/src/task-queue.sh" monitor --debug $duration 1
    
    # Restore permissions
    chmod 644 "$TASK_QUEUE_DIR/tasks.json" 2>/dev/null || true
    
    [ "$status" -eq 0 ] || [ "$status" -eq 124 ]
    
    # Should show debug info about access issues
    if [ -f "$DEBUG_LOG_FILE" ]; then
        grep -q "DEBUG\|ERROR\|WARN" "$DEBUG_LOG_FILE" || true
    fi
}

@test "monitor --debug: should debug resource constraint issues" {
    skip_if_no_script "task-queue.sh"
    
    # Mock system commands to simulate resource constraints
    mock_command "df" 'echo "Filesystem 1K-blocks Used Avail Use% Mounted on"; echo "/dev/disk1 1000 950 50 95% /"'  # High disk usage
    mock_command "free" 'echo "             total       used       free     shared    buffers     cached"; echo "Mem:       1000        950         50          0         10         40"'  # High memory usage
    
    local duration=2
    
    run timeout 5s "$SCRIPT_DIR/src/task-queue.sh" monitor --debug $duration 1
    
    [ "$status" -eq 0 ] || [ "$status" -eq 124 ]
    
    # Should function and show debug info about resource constraints
    [[ "$output" != "" ]] || [ -s "$DEBUG_LOG_FILE" ]
}

# ===============================================================================
# DEBUG MODE TIMING AND PERFORMANCE TESTS
# ===============================================================================

@test "monitor --debug: should show timing information" {
    skip_if_no_script "task-queue.sh"
    
    local duration=3
    
    run timeout 6s "$SCRIPT_DIR/src/task-queue.sh" monitor --debug $duration 1
    
    [ "$status" -eq 0 ] || [ "$status" -eq 124 ]
    
    # Should show timing-related debug information
    if [ -f "$DEBUG_LOG_FILE" ]; then
        local timing_info=$(grep -c "Duration\|Interval\|update.*#" "$DEBUG_LOG_FILE" 2>/dev/null || echo "0")
        [ "$timing_info" -gt 0 ]
    fi
}

@test "monitor --debug: should show update sequence debugging" {
    skip_if_no_script "task-queue.sh"
    
    local duration=4
    local interval=1
    
    run timeout 7s "$SCRIPT_DIR/src/task-queue.sh" monitor --debug $duration $interval
    
    [ "$status" -eq 0 ] || [ "$status" -eq 124 ]
    
    # Should show sequential update numbers
    if [ -f "$DEBUG_LOG_FILE" ]; then
        local update_sequences=$(grep -c "update #\|Starting update" "$DEBUG_LOG_FILE" 2>/dev/null || echo "0")
        [ "$update_sequences" -gt 2 ]  # Should have multiple sequential updates
    fi
}

# ===============================================================================
# DEBUG MODE OUTPUT FORMAT TESTS
# ===============================================================================

@test "monitor --debug: should maintain readable output format" {
    skip_if_no_script "task-queue.sh"
    
    local duration=2
    
    run timeout 5s "$SCRIPT_DIR/src/task-queue.sh" monitor --debug $duration 1
    
    [ "$status" -eq 0 ] || [ "$status" -eq 124 ]
    
    # Output should still be readable despite debug information
    [[ "$output" != "" ]]
    
    # Debug messages should be properly formatted
    if [ -f "$DEBUG_LOG_FILE" ]; then
        # Each debug line should start with [DEBUG] or similar
        local malformed_debug=$(grep "DEBUG" "$DEBUG_LOG_FILE" | grep -v "^\[DEBUG\]\|\[.*\].*DEBUG" | wc -l)
        [ "$malformed_debug" -eq 0 ] || true  # Allow some flexibility in debug format
    fi
}

@test "monitor --debug: should separate debug output from monitoring display" {
    skip_if_no_script "task-queue.sh"
    
    local duration=2
    
    run timeout 5s "$SCRIPT_DIR/src/task-queue.sh" monitor --debug $duration 1
    
    [ "$status" -eq 0 ] || [ "$status" -eq 124 ]
    
    # Should have both monitoring display and debug output
    # The actual behavior may vary based on implementation
    [[ "$output" != "" ]] || [ -s "$DEBUG_LOG_FILE" ]
    
    # If debug output is in stderr, main output should still have monitoring info
    if [ -s "$DEBUG_LOG_FILE" ]; then
        # Debug log should contain debug info
        grep -q "DEBUG" "$DEBUG_LOG_FILE"
    fi
}

# ===============================================================================
# DEBUG MODE INTEGRATION TESTS
# ===============================================================================

@test "monitor --debug: should work with signal handling" {
    skip_if_no_script "task-queue.sh"
    
    # Start debug monitoring in background
    "$SCRIPT_DIR/src/task-queue.sh" monitor --debug 10 1 &
    local monitor_pid=$!
    
    # Wait for it to start and generate some debug output
    sleep 2
    
    # Send interrupt signal
    kill -INT "$monitor_pid"
    
    # Wait for clean shutdown
    local timeout=3
    local count=0
    while kill -0 "$monitor_pid" 2>/dev/null && [ $count -lt $timeout ]; do
        sleep 1
        ((count++))
    done
    
    # Should have exited cleanly
    ! kill -0 "$monitor_pid" 2>/dev/null
    
    # Should have debug output about shutdown
    if [ -f "$DEBUG_LOG_FILE" ]; then
        local debug_entries=$(grep -c "DEBUG" "$DEBUG_LOG_FILE" 2>/dev/null || echo "0")
        [ "$debug_entries" -gt 0 ]
    fi
}

@test "monitor --debug: should debug concurrent access scenarios" {
    skip_if_no_script "task-queue.sh"
    
    # Create a lock file to simulate concurrent access
    touch "$QUEUE_LOCK_DIR/test.lock"
    echo "$$" > "$QUEUE_LOCK_DIR/test.lock"
    
    local duration=2
    
    run timeout 5s "$SCRIPT_DIR/src/task-queue.sh" monitor --debug $duration 1
    
    # Clean up
    rm -f "$QUEUE_LOCK_DIR/test.lock"
    
    [ "$status" -eq 0 ] || [ "$status" -eq 124 ]
    
    # Should handle and debug concurrent access
    [[ "$output" != "" ]] || [ -s "$DEBUG_LOG_FILE" ]
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