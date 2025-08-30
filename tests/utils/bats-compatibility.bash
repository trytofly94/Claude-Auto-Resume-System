#!/bin/bash

# BATS Compatibility Utilities
# Enhanced utilities for reliable BATS test execution with timeout handling,
# environment detection, and subprocess state management.
# 
# Based on breakthrough work from 2025-08-24_test-environment-fixes.md
# Addresses Issue #46 BATS test environment compatibility

set -euo pipefail

# ===============================================================================
# GLOBAL VARIABLES AND CONSTANTS
# ===============================================================================

# Test timeouts (seconds) - Phase 1 requirement
readonly UNIT_TEST_TIMEOUT=30        # Individual unit tests
readonly INTEGRATION_TEST_TIMEOUT=45 # Individual integration tests
readonly SETUP_TIMEOUT=10            # Test initialization
readonly CLEANUP_TIMEOUT=5           # Test cleanup
readonly TOTAL_SUITE_TIMEOUT=300     # Maximum total execution time

# Environment detection
MACOS_ENVIRONMENT=false
LINUX_ENVIRONMENT=false
FILE_LOCKING_TIMEOUT=5

# BATS detection - using proven ${BATS_TEST_NAME:-} pattern
BATS_SUBPROCESS_MODE=false
BATS_STATE_DIR=""

# ===============================================================================
# PHASE 1: ENVIRONMENT DETECTION AND TIMEOUT CONTROLS
# ===============================================================================

# Detect and adapt to platform-specific behavior
detect_test_environment() {
    local platform
    platform=$(uname -s)
    
    case "$platform" in
        "Darwin") 
            export MACOS_ENVIRONMENT=true
            export LINUX_ENVIRONMENT=false
            export EXPECTED_FLOCK_UNAVAILABLE=true
            export FILE_LOCKING_TIMEOUT=15  # Longer timeout for macOS
            ;;
        "Linux") 
            export MACOS_ENVIRONMENT=false
            export LINUX_ENVIRONMENT=true
            export FILE_LOCKING_TIMEOUT=5   # Shorter timeout for Linux
            ;;
        *)
            echo "[BATS-COMPAT] [WARN] Unknown platform: $platform, assuming Linux defaults" >&2
            export MACOS_ENVIRONMENT=false
            export LINUX_ENVIRONMENT=false
            export FILE_LOCKING_TIMEOUT=10  # Conservative timeout
            ;;
    esac
    
    # BATS subprocess detection using proven pattern
    if [[ -n "${BATS_TEST_NAME:-}" ]]; then
        export BATS_SUBPROCESS_MODE=true
        export BATS_STATE_DIR="${TEST_PROJECT_DIR:-${BATS_TEST_DIRNAME}/..}/queue/bats_state"
        mkdir -p "$BATS_STATE_DIR"
    else
        export BATS_SUBPROCESS_MODE=false
    fi
    
    echo "[BATS-COMPAT] [INFO] Environment detected: platform=$platform, bats_mode=$BATS_SUBPROCESS_MODE" >&2
}

# Skip problematic tests on specific systems
skip_if_incompatible() {
    local test_requires="${1:-}"
    local skip_reason="${2:-Test incompatible with current environment}"
    
    case "$test_requires" in
        "flock")
            if [[ "$MACOS_ENVIRONMENT" == "true" ]]; then
                skip "$skip_reason (macOS: flock unavailable)"
            fi
            ;;
        "linux_only")
            if [[ "$LINUX_ENVIRONMENT" != "true" ]]; then
                skip "$skip_reason (Linux required)"
            fi
            ;;
        "macos_only")
            if [[ "$MACOS_ENVIRONMENT" != "true" ]]; then
                skip "$skip_reason (macOS required)"
            fi
            ;;
    esac
}

# ===============================================================================
# PHASE 1: OPTIMIZED BATS SUBPROCESS HANDLING
# ===============================================================================

# Enhanced file-based state tracking for BATS associative arrays
# Phase 2 Solution: Robust BATS array persistence with JSON-based state management
bats_safe_array_operation() {
    local operation="$1"
    local array_name="$2"
    shift 2
    
    if [[ "$BATS_SUBPROCESS_MODE" == "true" ]]; then
        # Use enhanced file-based tracking in BATS context with JSON format
        local state_file="${BATS_STATE_DIR}/${array_name//[^A-Za-z0-9]/_}.json"
        
        case "$operation" in
            "get")
                local key="$1"
                if [[ -f "$state_file" ]]; then
                    # Use Python for reliable JSON parsing
                    python3 -c "
import json, sys
try:
    with open('$state_file') as f:
        data = json.load(f)
    print(data.get('$key', ''))
except:
    print('')
" 2>/dev/null || echo ""
                else
                    echo ""
                fi
                ;;
            "set")
                local key="$1"
                local value="$2"
                # Ensure state directory exists
                mkdir -p "$BATS_STATE_DIR"
                
                # Use Python for atomic JSON update
                python3 -c "
import json, os
state_file = '$state_file'
temp_file = state_file + '.tmp.' + str(os.getpid())

# Load existing data or create empty dict
data = {}
if os.path.exists(state_file):
    try:
        with open(state_file) as f:
            data = json.load(f)
    except:
        data = {}

# Update data
data['$key'] = '$value'

# Write atomically
with open(temp_file, 'w') as f:
    json.dump(data, f, indent=2)
    
os.rename(temp_file, state_file)
" 2>/dev/null || {
                    # Fallback to simple key=value format if Python fails
                    local temp_file="${state_file}.tmp.$$"
                    if [[ -f "$state_file" ]]; then
                        grep -v "^$key=" "$state_file" 2>/dev/null > "$temp_file" || true
                    fi
                    echo "$key=$value" >> "$temp_file"
                    mv "$temp_file" "$state_file"
                }
                ;;
            "exists")
                local key="$1"
                if [[ -f "$state_file" ]]; then
                    python3 -c "
import json
try:
    with open('$state_file') as f:
        data = json.load(f)
    exit(0 if '$key' in data else 1)
except:
    exit(1)
" 2>/dev/null
                else
                    return 1
                fi
                ;;
            "clear")
                rm -f "$state_file" 2>/dev/null || true
                ;;
            "sync_from_array")
                # Sync array contents to JSON file for BATS persistence
                local -n array_ref="$array_name"
                mkdir -p "$BATS_STATE_DIR"
                
                # Create JSON representation using Python
                python3 -c "
import json
data = {}
" > /tmp/array_data.py
                
                # Add array elements to Python script
                for key in "${!array_ref[@]}"; do
                    # Escape special characters for Python
                    local escaped_key="${key//\'/\'\"\'\"\'}"
                    local escaped_value="${array_ref[$key]//\'/\'\"\'\"\'}"
                    echo "data['$escaped_key'] = '$escaped_value'" >> /tmp/array_data.py
                done
                
                echo "
with open('$state_file', 'w') as f:
    json.dump(data, f, indent=2)
" >> /tmp/array_data.py
                
                python3 /tmp/array_data.py 2>/dev/null || {
                    # Fallback to simple format
                    rm -f "$state_file"
                    for key in "${!array_ref[@]}"; do
                        echo "$key=${array_ref[$key]}" >> "$state_file"
                    done
                }
                rm -f /tmp/array_data.py
                ;;
            "sync_to_array")
                # Load JSON contents into array for BATS context
                if [[ -f "$state_file" ]]; then
                    # Ensure array exists
                    if ! declare -p "$array_name" >/dev/null 2>&1; then
                        declare -gA "$array_name"
                    fi
                    
                    local -n array_ref="$array_name"
                    
                    # Try JSON format first
                    if python3 -c "
import json
try:
    with open('$state_file') as f:
        data = json.load(f)
    for key, value in data.items():
        print(f'{key}={value}')
except:
    exit(1)
" 2>/dev/null > /tmp/array_restore.txt; then
                        # Load from JSON format
                        while IFS='=' read -r key value; do
                            if [[ -n "$key" ]]; then
                                array_ref["$key"]="$value"
                            fi
                        done < /tmp/array_restore.txt
                        rm -f /tmp/array_restore.txt
                    else
                        # Fallback to key=value format
                        while IFS='=' read -r key value; do
                            if [[ -n "$key" ]]; then
                                array_ref["$key"]="$value"
                            fi
                        done < "$state_file"
                    fi
                fi
                ;;
            *)
                echo "[BATS-COMPAT] [ERROR] Unknown array operation: $operation" >&2
                return 1
                ;;
        esac
    else
        # Use direct associative array operations in regular bash context
        local -n array_ref="$array_name"
        
        case "$operation" in
            "get")
                local key="$1"
                echo "${array_ref[$key]:-}"
                ;;
            "set")
                local key="$1"
                local value="$2"
                array_ref["$key"]="$value"
                ;;
            "exists")
                local key="$1"
                [[ -v "array_ref[$key]" ]]
                ;;
            "clear")
                unset "$array_name"
                declare -gA "$array_name"
                ;;
            "sync_from_array"|"sync_to_array")
                # No-op in regular bash context
                return 0
                ;;
        esac
    fi
}

# Optimized state cleanup between tests
optimize_bats_state_tracking() {
    if [[ "$BATS_SUBPROCESS_MODE" == "true" && -n "$BATS_STATE_DIR" ]]; then
        # Clean up state files from previous test
        rm -f "$BATS_STATE_DIR"/*.state 2>/dev/null || true
        
        # Validate state directory is ready
        mkdir -p "$BATS_STATE_DIR"
        
        echo "[BATS-COMPAT] [DEBUG] BATS state tracking optimized for test: ${BATS_TEST_NAME:-unknown}" >&2
    fi
}

# Load BATS state from files into arrays
load_bats_state() {
    if [[ "$BATS_SUBPROCESS_MODE" == "true" && -n "$BATS_STATE_DIR" ]]; then
        # Load all array states from files
        local array_names=("TASK_STATES" "TASK_PRIORITIES" "TASK_METADATA" "TASK_RETRY_COUNTS" "TASK_TIMESTAMPS")
        
        for array_name in "${array_names[@]}"; do
            # Ensure array is declared first
            if ! declare -p "$array_name" >/dev/null 2>&1; then
                declare -gA "$array_name"
            fi
            
            # Sync from file to array
            bats_safe_array_operation "sync_to_array" "$array_name"
        done
        
        echo "[BATS-COMPAT] [DEBUG] Loaded BATS state for ${#array_names[@]} arrays" >&2
    fi
}

# Save current array state to BATS files
save_bats_state() {
    if [[ "$BATS_SUBPROCESS_MODE" == "true" && -n "$BATS_STATE_DIR" ]]; then
        # Save all array states to files
        local array_names=("TASK_STATES" "TASK_PRIORITIES" "TASK_METADATA" "TASK_RETRY_COUNTS" "TASK_TIMESTAMPS")
        
        for array_name in "${array_names[@]}"; do
            if declare -p "$array_name" >/dev/null 2>&1; then
                bats_safe_array_operation "sync_from_array" "$array_name"
            fi
        done
        
        echo "[BATS-COMPAT] [DEBUG] Saved BATS state for ${#array_names[@]} arrays" >&2
    fi
}

# ===============================================================================
# PHASE 1: GRANULAR TIMEOUT CONTROLS
# ===============================================================================

# Timeout wrapper that works reliably in BATS subprocess context
# Phase 1: Enhanced with per-test timeouts and hanging test detection
bats_safe_timeout() {
    local timeout_duration="$1"
    local timeout_type="${2:-default}"
    shift 2
    
    # Determine appropriate timeout based on test phase
    case "$timeout_type" in
        "setup")
            timeout_duration="$SETUP_TIMEOUT"
            ;;
        "cleanup") 
            timeout_duration="$CLEANUP_TIMEOUT"
            ;;
        "unit")
            timeout_duration="$UNIT_TEST_TIMEOUT"
            ;;
        "integration")
            timeout_duration="$INTEGRATION_TEST_TIMEOUT"
            ;;
        "per_test")
            # Individual test timeout - use default passed value
            ;;
    esac
    
    echo "[BATS-COMPAT] [DEBUG] Running with timeout: ${timeout_duration}s (type: $timeout_type)" >&2
    
    # Start timeout watchdog
    local watchdog_pid=""
    if [[ "$timeout_type" == "per_test" ]]; then
        # Enhanced watchdog for individual tests
        (
            local elapsed=0
            local warning_threshold=$((timeout_duration * 3 / 4))
            
            while [[ $elapsed -lt $timeout_duration ]]; do
                sleep 1
                elapsed=$((elapsed + 1))
                
                # Warning at 75% threshold
                if [[ $elapsed -eq $warning_threshold ]]; then
                    echo "[BATS-COMPAT] [WARN] Test approaching timeout: ${elapsed}s/${timeout_duration}s" >&2
                fi
            done
            
            echo "[BATS-COMPAT] [ERROR] Test watchdog triggered after ${timeout_duration}s" >&2
            # Force kill the test subprocess tree
            pkill -P $$ 2>/dev/null || true
        ) &
        watchdog_pid=$!
    fi
    
    # Use timeout with proper signal handling
    local exit_code=0
    if timeout --preserve-status "$timeout_duration" "$@"; then
        exit_code=0
    else
        exit_code=$?
        if [[ $exit_code -eq 124 ]]; then
            echo "[BATS-COMPAT] [ERROR] Operation timed out after ${timeout_duration}s: $*" >&2
            echo "[BATS-COMPAT] [ERROR] Timeout type: $timeout_type" >&2
            
            # Additional diagnostics for hanging tests
            if [[ "$timeout_type" == "per_test" ]]; then
                echo "[BATS-COMPAT] [ERROR] Possible hanging test detected - consider optimization" >&2
                echo "[BATS-COMPAT] [ERROR] Test name: ${BATS_TEST_NAME:-unknown}" >&2
            fi
        fi
    fi
    
    # Cleanup watchdog
    if [[ -n "$watchdog_pid" ]]; then
        kill "$watchdog_pid" 2>/dev/null || true
    fi
    
    return $exit_code
}

# Timeout warnings before reaching limits
implement_timeout_warnings() {
    local current_duration="$1"
    local max_duration="$2"
    local operation_name="${3:-operation}"
    
    # Calculate 75% threshold
    local warning_threshold=$((max_duration * 3 / 4))
    
    if [[ $current_duration -ge $warning_threshold ]]; then
        echo "[BATS-COMPAT] [WARN] $operation_name approaching timeout: ${current_duration}s/${max_duration}s" >&2
    fi
}

# Progress feedback for long-running operations
provide_timeout_progress() {
    local operation_name="$1"
    local max_duration="$2"
    
    echo "[BATS-COMPAT] [INFO] Starting $operation_name (max: ${max_duration}s)" >&2
    
    # Background progress indicator
    (
        local elapsed=0
        while [[ $elapsed -lt $max_duration ]]; do
            sleep 5
            elapsed=$((elapsed + 5))
            implement_timeout_warnings "$elapsed" "$max_duration" "$operation_name"
        done
    ) &
    
    echo $!  # Return PID of background process
}

# ===============================================================================
# PHASE 2: TEST ISOLATION AND CLEANUP 
# ===============================================================================

# Enhanced teardown function for each test
# Phase 1: Comprehensive resource cleanup to prevent hanging tests
enhanced_test_teardown() {
    local test_name="${BATS_TEST_NAME:-unknown_test}"
    
    echo "[BATS-COMPAT] [DEBUG] Starting enhanced teardown for: $test_name" >&2
    
    # Phase 1: Kill any lingering background processes first
    local test_pids=($(jobs -p 2>/dev/null || true))
    for pid in "${test_pids[@]}"; do
        if [[ -n "$pid" ]]; then
            echo "[BATS-COMPAT] [DEBUG] Killing background job: $pid" >&2
            kill "$pid" 2>/dev/null || true
        fi
    done
    
    # Kill test-specific processes that might hang
    pkill -f "test-hybrid-monitor" 2>/dev/null || true
    pkill -f "bats-test-$$" 2>/dev/null || true
    pkill -f "task-queue-test" 2>/dev/null || true
    pkill -f "${test_name//[^A-Za-z0-9]/_}" 2>/dev/null || true
    
    # Wait briefly for process cleanup
    sleep 0.1
    
    # Phase 1: Enhanced temporary file cleanup
    if [[ -n "${TEST_TMP_DIR:-}" && -d "${TEST_TMP_DIR}" ]]; then
        # Clean with timeout to prevent hanging on stuck file operations
        timeout 5 find "$TEST_TMP_DIR" -name "test-*" -mtime +0 -delete 2>/dev/null || true
        timeout 5 find "$TEST_TMP_DIR" -name "bats_*" -type f -delete 2>/dev/null || true
        timeout 5 find "$TEST_TMP_DIR" -name "*.tmp" -delete 2>/dev/null || true
        timeout 5 find "$TEST_TMP_DIR" -name "*.lock" -delete 2>/dev/null || true
    fi
    
    # Phase 1: Reset environment variables comprehensively
    local test_vars=(
        "TASK_QUEUE_ENABLED" "TEST_MODE" "BATS_TEST_STATE"
        "TEST_TASK_ID" "TEST_TIMEOUT_PID" "TEST_LOG_DIR"
        "HYBRID_MONITOR_LOG" "TASK_QUEUE_LOG" "BATS_COMPAT_LOG"
    )
    
    for var in "${test_vars[@]}"; do
        unset "$var" 2>/dev/null || true
    done
    
    # Phase 1: Clean up BATS state files with enhanced patterns
    if [[ -n "$BATS_STATE_DIR" && -d "$BATS_STATE_DIR" ]]; then
        timeout 3 rm -f "$BATS_STATE_DIR"/*.state 2>/dev/null || true
        timeout 3 rm -f "$BATS_STATE_DIR"/*.json 2>/dev/null || true
        timeout 3 rm -f "$BATS_STATE_DIR"/*.tmp.* 2>/dev/null || true
    fi
    
    # Phase 1: Clean up any test-specific log files
    if [[ -n "${TEST_LOG_DIR:-}" && -d "${TEST_LOG_DIR}" ]]; then
        timeout 2 rm -rf "$TEST_LOG_DIR" 2>/dev/null || true
    fi
    
    # Phase 1: Clear any file locks that might cause hanging
    local lock_patterns=(
        "${TEST_PROJECT_DIR:-}/queue/*.lock"
        "${TEST_PROJECT_DIR:-}/queue/task-states/*.lock" 
        "/tmp/test-*.lock"
    )
    
    for pattern in "${lock_patterns[@]}"; do
        timeout 2 rm -f $pattern 2>/dev/null || true
    done
    
    # Validate clean state before next test
    if ! verify_clean_test_state; then
        echo "[BATS-COMPAT] [WARN] Test state not completely clean after teardown" >&2
        # Force additional cleanup for critical issues
        pkill -f "python3.*test" 2>/dev/null || true
        sleep 0.2
    fi
    
    echo "[BATS-COMPAT] [DEBUG] Enhanced teardown completed for: $test_name" >&2
}

# State validation function
verify_clean_test_state() {
    local issues=0
    
    # Check for lingering processes
    if pgrep -f "test-hybrid-monitor" >/dev/null 2>&1; then
        echo "[BATS-COMPAT] [WARN] Lingering test processes found" >&2
        ((issues++))
    fi
    
    # Check for temporary files
    if [[ -n "${TEST_TMP_DIR:-}" ]] && find "$TEST_TMP_DIR" -name "test-*" -type f 2>/dev/null | head -1 | grep -q .; then
        echo "[BATS-COMPAT] [WARN] Temporary test files remain" >&2
        ((issues++))
    fi
    
    # Check for state file contamination
    if [[ -n "$BATS_STATE_DIR" ]] && find "$BATS_STATE_DIR" -name "*.state" -type f 2>/dev/null | head -1 | grep -q .; then
        echo "[BATS-COMPAT] [WARN] BATS state files remain" >&2
        ((issues++))
    fi
    
    return $issues
}

# ===============================================================================
# PHASE 2: TEST OUTPUT SEPARATION
# ===============================================================================

# Implement test-specific logging separation  
setup_test_logging() {
    local test_name="${1:-${BATS_TEST_NAME:-unknown}}"
    local test_log_base="${TEST_PROJECT_DIR:-$BATS_TEST_DIRNAME/..}/tests/logs"
    
    # Create test-specific log directory
    export TEST_LOG_DIR="$test_log_base/${test_name//[^A-Za-z0-9]/_}"
    mkdir -p "$TEST_LOG_DIR"
    
    # Redirect application logs to test-specific files
    export HYBRID_MONITOR_LOG="$TEST_LOG_DIR/hybrid-monitor.log"
    export TASK_QUEUE_LOG="$TEST_LOG_DIR/task-queue.log"
    export BATS_COMPAT_LOG="$TEST_LOG_DIR/bats-compatibility.log"
    
    echo "[BATS-COMPAT] [DEBUG] Test logging setup for: $test_name -> $TEST_LOG_DIR" >&2
}

# Clean log separation for debugging
capture_test_output() {
    local test_name="${1:-${BATS_TEST_NAME:-unknown}}"
    
    # Separate stdout (test results) from stderr (debugging)
    exec 3>&1  # Save stdout
    exec 4>&2  # Save stderr
    
    # Redirect to test-specific files
    if [[ -n "${TEST_LOG_DIR:-}" ]]; then
        exec 1>"$TEST_LOG_DIR/test-output.log"
        exec 2>"$TEST_LOG_DIR/test-debug.log"
        
        echo "[BATS-COMPAT] [DEBUG] Output capture started for: $test_name" >&4
    fi
}

# Restore output streams
restore_test_output() {
    # Restore original stdout/stderr
    exec 1>&3 3>&-  # Restore stdout
    exec 2>&4 4>&-  # Restore stderr
    
    echo "[BATS-COMPAT] [DEBUG] Output streams restored" >&2
}

# ===============================================================================
# PHASE 2: BATS ISOLATION UTILITIES
# ===============================================================================

# Run test in completely isolated environment
bats_isolated_test_run() {
    local test_function="$1"
    shift
    
    # Create completely fresh environment
    local isolated_tmp_dir
    isolated_tmp_dir=$(mktemp -d)
    
    (
        # Subshell for complete isolation
        export TEST_TMP_DIR="$isolated_tmp_dir"
        export HOME="$isolated_tmp_dir/home"
        export XDG_CONFIG_HOME="$isolated_tmp_dir/config"
        
        mkdir -p "$HOME" "$XDG_CONFIG_HOME"
        
        # Fresh state tracking
        optimize_bats_state_tracking
        
        # Setup isolated logging
        setup_test_logging "${BATS_TEST_NAME:-isolated_test}"
        
        # Run the test function
        "$test_function" "$@"
        
        local result=$?
        
        # Cleanup isolated environment
        rm -rf "$isolated_tmp_dir" 2>/dev/null || true
        
        return $result
    )
}

# ===============================================================================
# INITIALIZATION AND SETUP
# ===============================================================================

# Initialize BATS compatibility environment
init_bats_compatibility() {
    echo "[BATS-COMPAT] [INFO] Initializing BATS compatibility utilities v1.0" >&2
    
    # Phase 1: Critical environment detection
    detect_test_environment
    
    # Phase 2: Setup state tracking optimization
    optimize_bats_state_tracking
    
    # Phase 2: Setup test logging if in BATS mode
    if [[ "$BATS_SUBPROCESS_MODE" == "true" ]]; then
        setup_test_logging
    fi
    
    echo "[BATS-COMPAT] [INFO] BATS compatibility initialization complete" >&2
    echo "[BATS-COMPAT] [INFO] Platform: $(uname -s), BATS Mode: $BATS_SUBPROCESS_MODE" >&2
    echo "[BATS-COMPAT] [INFO] Timeouts: unit=${UNIT_TEST_TIMEOUT}s, integration=${INTEGRATION_TEST_TIMEOUT}s" >&2
}

# Export all functions for use in BATS tests
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    # Being sourced, export functions
    export -f detect_test_environment
    export -f skip_if_incompatible  
    export -f bats_safe_array_operation
    export -f optimize_bats_state_tracking
    export -f load_bats_state
    export -f save_bats_state
    export -f bats_safe_timeout
    export -f implement_timeout_warnings
    export -f provide_timeout_progress
    export -f enhanced_test_teardown
    export -f verify_clean_test_state
    export -f setup_test_logging
    export -f capture_test_output
    export -f restore_test_output
    export -f bats_isolated_test_run
    export -f init_bats_compatibility
    
    # Auto-initialize when sourced
    init_bats_compatibility
fi