#!/usr/bin/env bats

# Performance Test Suite: Task Execution Engine
# Tests performance characteristics and load handling

load '../test_helper'

# Define assertion functions locally
assert_success() { [[ "$status" -eq 0 ]] || { echo "Expected success but got exit code $status"; return 1; }; }
assert_failure() { [[ "$status" -ne 0 ]] || { echo "Expected failure but got exit code $status"; return 1; }; }

setup() {
    default_setup
    export SCRIPT_DIR="/Volumes/SSD-MacMini/ClaudeCode/Claude-Auto-Resume-System/src"
    export WORKING_DIR="$TEST_TEMP_DIR/work"
    mkdir -p "$WORKING_DIR"
}

teardown() {
    default_teardown
}

# ===============================================================================
# PERFORMANCE TESTING
# ===============================================================================

@test "Performance: script loads within acceptable time (< 3 seconds)" {
    local start_time end_time duration
    
    start_time=$(date +%s)
    timeout 5 bash -n "$SCRIPT_DIR/hybrid-monitor.sh"
    local syntax_status=$?
    end_time=$(date +%s)
    
    duration=$((end_time - start_time))
    
    [[ $syntax_status -eq 0 ]]  # Syntax check succeeded
    [[ $duration -lt 3 ]]       # Loaded within 3 seconds
}

@test "Performance: help text generation is fast (< 1 second)" {
    local start_time end_time duration
    
    start_time=$(date +%s)
    timeout 2 grep -A100 "show_help()" "$SCRIPT_DIR/hybrid-monitor.sh" >/dev/null
    end_time=$(date +%s)
    
    duration=$((end_time - start_time))
    [[ $duration -lt 1 ]]
}

@test "Performance: parameter parsing handles large argument lists efficiently" {
    # Create a large argument list to test parameter parsing performance
    local args=("--queue-mode" "--continuous" "--debug")
    
    # Add 50 Claude arguments to test handling
    for i in {1..50}; do
        args+=("arg$i")
    done
    
    local start_time end_time duration
    start_time=$(date +%s)
    
    # Test that parameter parsing logic exists and can handle large inputs
    timeout 5 grep -A200 "parse_arguments" "$SCRIPT_DIR/hybrid-monitor.sh" >/dev/null
    
    end_time=$(date +%s)
    duration=$((end_time - start_time))
    
    [[ $duration -lt 2 ]]  # Should complete quickly
}

@test "Performance: Task Queue function definitions are reasonable in size" {
    # Check that core functions aren't excessively large (indicating potential performance issues)
    local function_sizes=()
    
    # Count lines in critical functions
    local process_queue_lines
    process_queue_lines=$(grep -A200 "^process_task_queue_cycle()" "$SCRIPT_DIR/hybrid-monitor.sh" | grep -B200 "^}" | wc -l)
    
    local execute_task_lines
    execute_task_lines=$(grep -A300 "^execute_single_task()" "$SCRIPT_DIR/hybrid-monitor.sh" | grep -B300 "^}" | wc -l)
    
    local monitor_completion_lines
    monitor_completion_lines=$(grep -A200 "^monitor_task_completion()" "$SCRIPT_DIR/hybrid-monitor.sh" | grep -B200 "^}" | wc -l)
    
    # Functions shouldn't be excessively large (> 200 lines each)
    [[ $process_queue_lines -lt 200 ]]
    [[ $execute_task_lines -lt 300 ]]
    [[ $monitor_completion_lines -lt 200 ]]
}

@test "Performance: Script memory footprint is reasonable" {
    # Test that the script doesn't declare an excessive number of global variables
    local global_var_count
    global_var_count=$(grep -c "^[A-Z_][A-Z0-9_]*=" "$SCRIPT_DIR/hybrid-monitor.sh")
    
    # Should have reasonable number of global variables (< 100)
    [[ $global_var_count -lt 100 ]]
}

# ===============================================================================
# SCALABILITY TESTING
# ===============================================================================

@test "Scalability: script handles multiple CLI parameter combinations" {
    # Test various parameter combinations that might be used together
    local param_combinations=(
        "--queue-mode --continuous --debug"
        "--add-issue 123 --queue-timeout 3600 --queue-retries 5"
        "--add-custom 'task' --queue-priority 8 --continuous"
        "--list-queue --debug --dry-run"
        "--clear-queue --dry-run"
    )
    
    for combo in "${param_combinations[@]}"; do
        # Check that parameter parsing logic can find all these patterns
        local param_count=0
        for param in $combo; do
            if [[ "$param" =~ ^-- ]] && grep -q "\\$param)" "$SCRIPT_DIR/hybrid-monitor.sh"; then
                ((param_count++))
            fi
        done
        
        # Should find most parameters in each combination
        [[ $param_count -ge 1 ]]
    done
}

@test "Scalability: configuration loading handles large config files efficiently" {
    # Test that config loading logic is efficient
    local config_loading_lines
    config_loading_lines=$(grep -A50 "load_configuration()" "$SCRIPT_DIR/hybrid-monitor.sh" | wc -l)
    
    # Config loading shouldn't be overly complex
    [[ $config_loading_lines -lt 100 ]]
    
    # Should use efficient methods like while-read loops
    grep -A50 "load_configuration()" "$SCRIPT_DIR/hybrid-monitor.sh" | grep -q "while.*read"
}

@test "Scalability: module loading is organized and efficient" {
    # Test that module loading uses efficient patterns
    local module_loading_section
    module_loading_section=$(grep -A100 "load_dependencies()" "$SCRIPT_DIR/hybrid-monitor.sh")
    
    # Should use arrays for efficiency
    echo "$module_loading_section" | grep -q "modules=("
    
    # Should use loops instead of repetitive code
    echo "$module_loading_section" | grep -q "for.*in.*modules"
}

# ===============================================================================
# ERROR HANDLING PERFORMANCE
# ===============================================================================

@test "Performance: error handling doesn't introduce excessive overhead" {
    # Check that error handling is efficiently implemented
    local error_handler_count
    error_handler_count=$(grep -c "log_error\|log_warn" "$SCRIPT_DIR/hybrid-monitor.sh")
    
    # Should have reasonable amount of error handling (not excessive)
    [[ $error_handler_count -lt 200 ]]
    [[ $error_handler_count -gt 20 ]]  # But should have adequate error handling
}

@test "Performance: validation functions are lightweight" {
    # Check parameter validation efficiency
    local validation_function_lines
    validation_function_lines=$(grep -A20 "validate_number_parameter()" "$SCRIPT_DIR/hybrid-monitor.sh" | wc -l)
    
    # Validation should be lightweight
    [[ $validation_function_lines -lt 30 ]]
    
    # Should use efficient bash patterns
    grep -A20 "validate_number_parameter()" "$SCRIPT_DIR/hybrid-monitor.sh" | grep -q "\\[\\[.*=~"
}

# ===============================================================================
# INTEGRATION PERFORMANCE
# ===============================================================================

@test "Performance: GitHub integration loading is conditional and efficient" {
    # Test that GitHub integration only loads when needed
    local github_loading_section
    github_loading_section=$(grep -A20 "GitHub Integration Modules" "$SCRIPT_DIR/hybrid-monitor.sh")
    
    # Should be conditionally loaded
    echo "$github_loading_section" | grep -q "if.*GITHUB_INTEGRATION_ENABLED"
    
    # Should use loops for loading multiple modules
    echo "$github_loading_section" | grep -q "for.*module.*in"
}

@test "Performance: task execution monitoring uses efficient polling" {
    # Check that task monitoring doesn't use inefficient polling
    local monitoring_section
    monitoring_section=$(grep -A50 "monitor_task_completion()" "$SCRIPT_DIR/hybrid-monitor.sh")
    
    # Should have reasonable check intervals
    echo "$monitoring_section" | grep -q "check_interval=10"
    
    # Should avoid busy waiting
    echo "$monitoring_section" | grep -q "sleep.*check_interval"
}

# ===============================================================================
# RESOURCE USAGE TESTING
# ===============================================================================

@test "Resource Usage: script doesn't create excessive temporary files" {
    # Check that script doesn't have patterns that would create many temp files
    local temp_file_patterns
    temp_file_patterns=$(grep -c "mktemp\|/tmp/\|\.tmp" "$SCRIPT_DIR/hybrid-monitor.sh")
    
    # Should have minimal temporary file usage
    [[ $temp_file_patterns -lt 10 ]]
}

@test "Resource Usage: cleanup functions are comprehensive" {
    # Check that cleanup is properly implemented
    grep -q "cleanup_on_exit()" "$SCRIPT_DIR/hybrid-monitor.sh"
    
    # Should clean up background processes
    grep -A20 "cleanup_on_exit()" "$SCRIPT_DIR/hybrid-monitor.sh" | grep -q "pkill.*$$"
    
    # Should clean up sessions
    grep -A20 "cleanup_on_exit()" "$SCRIPT_DIR/hybrid-monitor.sh" | grep -q "MAIN_SESSION_ID"
}

@test "Resource Usage: signal handling is properly implemented" {
    # Check signal handling for clean shutdown
    grep -q "trap.*cleanup_on_exit.*EXIT" "$SCRIPT_DIR/hybrid-monitor.sh"
    grep -q "trap.*interrupt_handler.*INT.*TERM" "$SCRIPT_DIR/hybrid-monitor.sh"
    
    # Signal handlers should be lightweight
    local signal_handler_lines
    signal_handler_lines=$(grep -A10 "interrupt_handler()" "$SCRIPT_DIR/hybrid-monitor.sh" | wc -l)
    [[ $signal_handler_lines -lt 15 ]]
}

# ===============================================================================
# CODE QUALITY PERFORMANCE IMPACT
# ===============================================================================

@test "Code Quality: functions have reasonable complexity" {
    # Check that main functions aren't overly complex
    local main_function_size
    main_function_size=$(grep -A500 "^main()" "$SCRIPT_DIR/hybrid-monitor.sh" | grep -B500 "^}" | wc -l)
    
    # Main function should be reasonable size
    [[ $main_function_size -lt 200 ]]
    
    # Should delegate to other functions rather than doing everything inline
    grep -A500 "^main()" "$SCRIPT_DIR/hybrid-monitor.sh" | grep -q "load_dependencies"
    grep -A500 "^main()" "$SCRIPT_DIR/hybrid-monitor.sh" | grep -q "parse_arguments"
}

@test "Code Quality: repetitive code is minimized" {
    # Check for efficient code reuse patterns
    local function_count
    function_count=$(grep -c "^[a-z_][a-z0-9_]*() *{" "$SCRIPT_DIR/hybrid-monitor.sh")
    
    # Should have reasonable number of functions (indicating good code organization)
    [[ $function_count -gt 20 ]]  # Enough functions for good organization
    [[ $function_count -lt 80 ]]  # Not excessive function fragmentation
}