#!/usr/bin/env bats

# Unit tests for Monitoring Safe Display Functions
# Tests the new safe terminal detection and display functions that fix the hanging bug

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
    export MONITOR_UPDATE_INTERVAL=1
    export MONITOR_LOG_FILE="$TASK_QUEUE_DIR/logs/monitor.log"
    
    # Create required directories
    mkdir -p "$TASK_QUEUE_DIR/logs"
    mkdir -p "$TASK_QUEUE_DIR/tmp"
    
    # Source the monitoring module
    source "$SCRIPT_DIR/src/queue/monitoring.sh" 2>/dev/null || {
        skip "Monitoring module not available"
    }
    
    # Mock logging functions
    mock_command "log_info" 'echo "[INFO] $*" >&2'
    mock_command "log_warn" 'echo "[WARN] $*" >&2'
    mock_command "log_error" 'echo "[ERROR] $*" >&2'
    mock_command "log_debug" 'echo "[DEBUG] $*" >&2'
}

teardown() {
    default_teardown
}

# ===============================================================================
# TERMINAL DETECTION TESTS
# ===============================================================================

@test "terminal_is_interactive_safe: should return true for interactive terminal" {
    # Mock timeout command to simulate interactive terminal
    mock_command "timeout" '
        if [[ "$1" == "2s" && "$2" == "bash" && "$3" == "-c" && "$4" == "[[ -t 1 ]]" ]]; then
            exit 0
        fi
        command timeout "$@"
    '
    
    run terminal_is_interactive_safe
    
    [ "$status" -eq 0 ]
}

@test "terminal_is_interactive_safe: should return false for non-interactive terminal" {
    # Mock timeout command to simulate non-interactive terminal
    mock_command "timeout" '
        if [[ "$1" == "2s" && "$2" == "bash" && "$3" == "-c" && "$4" == "[[ -t 1 ]]" ]]; then
            exit 1
        fi
        command timeout "$@"
    '
    
    run terminal_is_interactive_safe
    
    [ "$status" -eq 1 ]
}

@test "terminal_is_interactive_safe: should timeout and return false if terminal detection hangs" {
    # Mock timeout command to simulate hanging detection
    mock_command "timeout" '
        if [[ "$1" == "2s" ]]; then
            exit 124  # timeout exit code
        fi
        command timeout "$@"
    '
    
    run terminal_is_interactive_safe
    
    [ "$status" -eq 1 ]
}

@test "terminal_is_interactive_safe: should handle timeout command not available" {
    # Mock timeout as unavailable
    mock_command "timeout" 'return 127'  # command not found
    
    run terminal_is_interactive_safe
    
    [ "$status" -eq 1 ]
}

# ===============================================================================
# SAFE DISPLAY FUNCTION TESTS
# ===============================================================================

@test "display_monitoring_update_safe: should call simple display when terminal not interactive" {
    # Mock terminal detection to return false
    terminal_is_interactive_safe() { return 1; }
    
    # Mock the simple display function
    display_monitoring_update_simple() {
        echo "SIMPLE_DISPLAY_CALLED"
        echo "$1" > "$TEST_TEMP_DIR/monitoring_data_received"
    }
    
    local test_data='{"timestamp":"2025-08-31 12:00:00","update_number":1,"queue_stats":{"total":0,"pending":0,"completed":0,"failed":0},"health_status":{"level":"good","message":"Queue operating normally"}}'
    
    run display_monitoring_update_safe "$test_data"
    
    [ "$status" -eq 0 ]
    [[ "$output" == *"SIMPLE_DISPLAY_CALLED"* ]]
    [ -f "$TEST_TEMP_DIR/monitoring_data_received" ]
}

@test "display_monitoring_update_safe: should call fallback display when terminal is interactive" {
    # Mock terminal detection to return true
    terminal_is_interactive_safe() { return 0; }
    
    # Mock the fallback display function to succeed
    display_monitoring_update_with_fallback() {
        echo "FALLBACK_DISPLAY_CALLED"
        return 0
    }
    
    local test_data='{"timestamp":"2025-08-31 12:00:00","update_number":1,"queue_stats":{"total":0,"pending":0,"completed":0,"failed":0},"health_status":{"level":"good","message":"Queue operating normally"}}'
    
    run display_monitoring_update_safe "$test_data"
    
    [ "$status" -eq 0 ]
    [[ "$output" == *"FALLBACK_DISPLAY_CALLED"* ]]
}

@test "display_monitoring_update_safe: should fallback to simple when complex display fails" {
    # Mock terminal detection to return true
    terminal_is_interactive_safe() { return 0; }
    
    # Mock the fallback display function to fail
    display_monitoring_update_with_fallback() {
        echo "FALLBACK_FAILED"
        return 1
    }
    
    # Mock the simple display function
    display_monitoring_update_simple() {
        echo "SIMPLE_DISPLAY_FALLBACK"
        return 0
    }
    
    local test_data='{"timestamp":"2025-08-31 12:00:00","update_number":1,"queue_stats":{"total":0,"pending":0,"completed":0,"failed":0},"health_status":{"level":"good","message":"Queue operating normally"}}'
    
    run display_monitoring_update_safe "$test_data" "true"  # debug mode on
    
    [ "$status" -eq 0 ]
    [[ "$output" == *"SIMPLE_DISPLAY_FALLBACK"* ]]
}

@test "display_monitoring_update_safe: should pass debug mode to display functions" {
    # Mock terminal detection to return true
    terminal_is_interactive_safe() { return 0; }
    
    # Mock the fallback display function to check debug mode
    display_monitoring_update_with_fallback() {
        if [[ "$2" == "true" ]]; then
            echo "DEBUG_MODE_PASSED"
        fi
        return 0
    }
    
    local test_data='{"timestamp":"2025-08-31 12:00:00","update_number":1}'
    
    run display_monitoring_update_safe "$test_data" "true"
    
    [ "$status" -eq 0 ]
    [[ "$output" == *"DEBUG_MODE_PASSED"* ]]
}

# ===============================================================================
# DISPLAY WITH FALLBACK TESTS
# ===============================================================================

@test "display_monitoring_update_with_fallback: should timeout terminal clearing operations" {
    # Mock timeout command to simulate terminal clearing timeout
    mock_command "timeout" '
        if [[ "$1" == "5s" ]]; then
            exit 124  # timeout exit code
        fi
        command timeout "$@"
    '
    
    local test_data='{"timestamp":"2025-08-31 12:00:00"}'
    
    run display_monitoring_update_with_fallback "$test_data" "true"
    
    [ "$status" -eq 1 ]  # Should return failure when timeout occurs
}

@test "display_monitoring_update_with_fallback: should succeed with tput available" {
    # Mock tput as available and working
    mock_command "tput" 'echo "TPUT_CLEAR_CALLED"; exit 0'
    mock_command "timeout" 'shift; "$@"; exit 0'  # Make timeout just execute the command
    
    # Mock display content function
    display_monitoring_update_content() {
        echo "CONTENT_DISPLAYED"
    }
    
    local test_data='{"timestamp":"2025-08-31 12:00:00"}'
    
    run display_monitoring_update_with_fallback "$test_data"
    
    [ "$status" -eq 0 ]
    [[ "$output" == *"CONTENT_DISPLAYED"* ]]
}

@test "display_monitoring_update_with_fallback: should fallback to printf when tput fails" {
    # Mock tput as unavailable
    mock_command "tput" 'exit 127'  # command not found
    mock_command "timeout" 'shift; "$@"; exit 0'
    
    # Mock display content function
    display_monitoring_update_content() {
        echo "CONTENT_DISPLAYED_FALLBACK"
    }
    
    local test_data='{"timestamp":"2025-08-31 12:00:00"}'
    
    run display_monitoring_update_with_fallback "$test_data"
    
    [ "$status" -eq 0 ]
    [[ "$output" == *"CONTENT_DISPLAYED_FALLBACK"* ]]
}

# ===============================================================================
# SIMPLE DISPLAY TESTS
# ===============================================================================

@test "display_monitoring_update_simple: should display basic monitoring info" {
    # Mock jq command for JSON parsing
    mock_command "jq" '
        case "$2" in
            ".timestamp") echo "2025-08-31 12:00:00" ;;
            ".update_number") echo "5" ;;
            ".health_status.level") echo "good" ;;
            ".queue_stats") echo '{"total":10,"pending":3,"completed":7,"failed":0}' ;;
            ".queue_stats.total") echo "10" ;;
            ".queue_stats.pending") echo "3" ;;
            ".queue_stats.completed") echo "7" ;;
            ".queue_stats.failed") echo "0" ;;
        esac
    '
    
    local test_data='{"timestamp":"2025-08-31 12:00:00","update_number":5,"health_status":{"level":"good"},"queue_stats":{"total":10,"pending":3,"completed":7,"failed":0}}'
    
    run display_monitoring_update_simple "$test_data"
    
    [ "$status" -eq 0 ]
    [[ "$output" == *"Task Queue Monitoring Update #5"* ]]
    [[ "$output" == *"Time: 2025-08-31 12:00:00"* ]]
    [[ "$output" == *"Health: good"* ]]
    [[ "$output" == *"Total: 10"* ]]
    [[ "$output" == *"Pending: 3"* ]]
    [[ "$output" == *"Completed: 7"* ]]
    [[ "$output" == *"Failed: 0"* ]]
    [[ "$output" == *"Press Ctrl+C to stop monitoring"* ]]
}

@test "display_monitoring_update_simple: should show health issues for warning/critical status" {
    # Mock jq command for JSON parsing
    mock_command "jq" '
        case "$2" in
            ".timestamp") echo "2025-08-31 12:00:00" ;;
            ".update_number") echo "3" ;;
            ".health_status.level") echo "warning" ;;
            ".health_status.message") echo "Some failed tasks detected: 2" ;;
            ".queue_stats") echo '{"total":10,"pending":3,"completed":5,"failed":2}' ;;
            ".queue_stats.total") echo "10" ;;
            ".queue_stats.pending") echo "3" ;;
            ".queue_stats.completed") echo "5" ;;
            ".queue_stats.failed") echo "2" ;;
        esac
    '
    
    local test_data='{"timestamp":"2025-08-31 12:00:00","update_number":3,"health_status":{"level":"warning","message":"Some failed tasks detected: 2"},"queue_stats":{"total":10,"pending":3,"completed":5,"failed":2}}'
    
    run display_monitoring_update_simple "$test_data"
    
    [ "$status" -eq 0 ]
    [[ "$output" == *"Health: warning"* ]]
    [[ "$output" == *"Issues: Some failed tasks detected: 2"* ]]
}

@test "display_monitoring_update_simple: should handle debug mode logging" {
    # Mock jq command
    mock_command "jq" '
        case "$2" in
            ".timestamp") echo "2025-08-31 12:00:00" ;;
            ".update_number") echo "1" ;;
            ".health_status.level") echo "good" ;;
            ".queue_stats") echo '{"total":0,"pending":0,"completed":0,"failed":0}' ;;
            ".queue_stats.total") echo "0" ;;
            ".queue_stats.pending") echo "0" ;;
            ".queue_stats.completed") echo "0" ;;
            ".queue_stats.failed") echo "0" ;;
        esac
    '
    
    local test_data='{"timestamp":"2025-08-31 12:00:00","update_number":1,"health_status":{"level":"good"},"queue_stats":{"total":0,"pending":0,"completed":0,"failed":0}}'
    
    run display_monitoring_update_simple "$test_data" "true"
    
    [ "$status" -eq 0 ]
    # Should still display normally - debug mode doesn't change simple display output
    [[ "$output" == *"Task Queue Monitoring Update #1"* ]]
}

# ===============================================================================
# ERROR HANDLING TESTS
# ===============================================================================

@test "display_monitoring_update_safe: should handle invalid JSON gracefully" {
    # Mock terminal detection
    terminal_is_interactive_safe() { return 1; }
    
    # Mock simple display to handle bad JSON
    display_monitoring_update_simple() {
        echo "HANDLING_BAD_JSON"
        return 0
    }
    
    local bad_json='{"invalid": json syntax'
    
    run display_monitoring_update_safe "$bad_json"
    
    [ "$status" -eq 0 ]
    [[ "$output" == *"HANDLING_BAD_JSON"* ]]
}

@test "display_monitoring_update_safe: should handle missing data gracefully" {
    # Mock terminal detection
    terminal_is_interactive_safe() { return 1; }
    
    # Mock simple display to handle empty data
    display_monitoring_update_simple() {
        if [[ -z "$1" ]]; then
            echo "HANDLING_EMPTY_DATA"
        fi
        return 0
    }
    
    run display_monitoring_update_safe ""
    
    [ "$status" -eq 0 ]
    [[ "$output" == *"HANDLING_EMPTY_DATA"* ]]
}

@test "terminal_is_interactive_safe: should handle various timeout scenarios" {
    # Test different timeout exit codes
    for exit_code in 1 124 127 130; do
        mock_command "timeout" "exit $exit_code"
        
        run terminal_is_interactive_safe
        
        # All non-zero exit codes should result in non-interactive detection
        [ "$status" -eq 1 ]
    done
}

# ===============================================================================
# INTEGRATION WITH EXISTING MONITORING
# ===============================================================================

@test "safe display functions: should be compatible with existing monitoring data format" {
    # Test with realistic monitoring data structure
    local realistic_data='{
        "timestamp": "2025-08-31 12:30:45",
        "update_number": 15,
        "queue_stats": {
            "total": 25,
            "pending": 5,
            "in_progress": 2,
            "completed": 17,
            "failed": 1,
            "timeout": 0
        },
        "health_status": {
            "level": "warning",
            "message": "Some failed tasks detected: 1",
            "metrics": {
                "failed_tasks": 1,
                "timeout_tasks": 0,
                "total_tasks": 25,
                "stale_locks": 0
            }
        },
        "system_metrics": {
            "disk_usage_percent": 45,
            "memory_usage_percent": 67,
            "cpu_load_average": "2.14",
            "queue_process_count": 3
        }
    }'
    
    # Mock terminal as non-interactive
    terminal_is_interactive_safe() { return 1; }
    
    # Mock jq for realistic data extraction
    mock_command "jq" '
        case "$2" in
            ".timestamp") echo "2025-08-31 12:30:45" ;;
            ".update_number") echo "15" ;;
            ".health_status.level") echo "warning" ;;
            ".health_status.message") echo "Some failed tasks detected: 1" ;;
            ".queue_stats") echo '{"total":25,"pending":5,"completed":17,"failed":1}' ;;
            ".queue_stats.total") echo "25" ;;
            ".queue_stats.pending") echo "5" ;;
            ".queue_stats.completed") echo "17" ;;
            ".queue_stats.failed") echo "1" ;;
        esac
    '
    
    run display_monitoring_update_safe "$realistic_data"
    
    [ "$status" -eq 0 ]
    [[ "$output" == *"Update #15"* ]]
    [[ "$output" == *"Time: 2025-08-31 12:30:45"* ]]
    [[ "$output" == *"Health: warning"* ]]
    [[ "$output" == *"Total: 25"* ]]
    [[ "$output" == *"Issues: Some failed tasks detected: 1"* ]]
}

# ===============================================================================
# PERFORMANCE TESTS
# ===============================================================================

@test "terminal_is_interactive_safe: should complete within reasonable time" {
    # Mock timeout to track execution time
    mock_command "timeout" '
        start_time=$(date +%s%N)
        sleep 0.1  # Simulate some delay but not too much
        end_time=$(date +%s%N)
        duration=$((($end_time - $start_time) / 1000000))  # Convert to milliseconds
        if [[ $duration -lt 2100 ]]; then  # Should be less than 2.1 seconds (timeout is 2s + buffer)
            exit 0
        else
            exit 124  # timeout
        fi
    '
    
    start_test_time=$(date +%s%N)
    run terminal_is_interactive_safe
    end_test_time=$(date +%s%N)
    
    test_duration=$((($end_test_time - $start_test_time) / 1000000))  # Convert to milliseconds
    
    # The entire function should complete within 3 seconds (including overhead)
    [ $test_duration -lt 3000 ]
}