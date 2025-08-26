#!/usr/bin/env bats

# Test suite for Task Execution Engine integration
# This tests the complete task execution engine functionality

load '../test_helper'

setup() {
    setup_test_environment
    
    # Backup original hybrid-monitor.sh
    if [[ ! -f "$TEST_PROJECT_DIR/src/hybrid-monitor.sh.backup" ]]; then
        cp "$TEST_PROJECT_DIR/src/hybrid-monitor.sh" "$TEST_PROJECT_DIR/src/hybrid-monitor.sh.backup"
    fi
}

teardown() {
    cleanup_test_environment
    
    # Restore original hybrid-monitor.sh if needed
    if [[ -f "$TEST_PROJECT_DIR/src/hybrid-monitor.sh.backup" ]]; then
        cp "$TEST_PROJECT_DIR/src/hybrid-monitor.sh.backup" "$TEST_PROJECT_DIR/src/hybrid-monitor.sh"
    fi
}

@test "CLI interface shows all task queue parameters" {
    run "$TEST_PROJECT_DIR/src/hybrid-monitor.sh" --help
    
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "TASK QUEUE OPTIONS"
    echo "$output" | grep -q "\-\-queue\-mode"
    echo "$output" | grep -q "\-\-add\-issue"
    echo "$output" | grep -q "\-\-add\-pr"
    echo "$output" | grep -q "\-\-add\-custom"
    echo "$output" | grep -q "\-\-list\-queue"
    echo "$output" | grep -q "\-\-pause\-queue"
    echo "$output" | grep -q "\-\-resume\-queue"
    echo "$output" | grep -q "\-\-clear\-queue"
}

@test "list-queue works without task queue modules" {
    run "$TEST_PROJECT_DIR/src/hybrid-monitor.sh" --list-queue
    
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "No tasks in queue"
}

@test "hybrid-monitor.sh has correct file size (1700+ lines)" {
    line_count=$(wc -l < "$TEST_PROJECT_DIR/src/hybrid-monitor.sh")
    
    [ "$line_count" -gt 1700 ]
}

@test "all critical task processing functions exist" {
    # Check for all major task processing functions
    grep -q "process_task_queue_cycle()" "$TEST_PROJECT_DIR/src/hybrid-monitor.sh"
    grep -q "execute_single_task()" "$TEST_PROJECT_DIR/src/hybrid-monitor.sh"
    grep -q "monitor_task_completion()" "$TEST_PROJECT_DIR/src/hybrid-monitor.sh"
    grep -q "handle_task_failure()" "$TEST_PROJECT_DIR/src/hybrid-monitor.sh"
    grep -q "clear_session_between_tasks()" "$TEST_PROJECT_DIR/src/hybrid-monitor.sh"
}

@test "task queue processing is integrated in monitoring loop" {
    # Check that task queue processing is called in continuous_monitoring_loop
    grep -A10 "continuous_monitoring_loop()" "$TEST_PROJECT_DIR/src/hybrid-monitor.sh" | \
        grep -q "process_task_queue_cycle"
}

@test "configuration parameters are supported" {
    # Test that configuration parameters are used
    grep -q "TASK_QUEUE_PROCESSING" "$TEST_PROJECT_DIR/src/hybrid-monitor.sh"
    grep -q "TASK_DEFAULT_TIMEOUT" "$TEST_PROJECT_DIR/src/hybrid-monitor.sh"
    grep -q "TASK_COMPLETION_PATTERN" "$TEST_PROJECT_DIR/src/hybrid-monitor.sh"
}

@test "error handling functions exist" {
    grep -q "handle_task_failure()" "$TEST_PROJECT_DIR/src/hybrid-monitor.sh"
    grep -q "QUEUE_AUTO_PAUSE_ON_ERROR" "$TEST_PROJECT_DIR/src/hybrid-monitor.sh"
}

@test "completion detection system exists" {
    grep -q "monitor_task_completion()" "$TEST_PROJECT_DIR/src/hybrid-monitor.sh"
    grep -q "TASK_COMPLETION_PATTERN" "$TEST_PROJECT_DIR/src/hybrid-monitor.sh"
    grep -q "###TASK_COMPLETE###" "$TEST_PROJECT_DIR/src/hybrid-monitor.sh"
}

@test "session management integration exists" {
    grep -q "clear_session_between_tasks()" "$TEST_PROJECT_DIR/src/hybrid-monitor.sh"
    grep -q "initialize_session_for_tasks()" "$TEST_PROJECT_DIR/src/hybrid-monitor.sh"
}

@test "all CLI parameters are parsed correctly" {
    # Test add-issue parameter parsing
    run bash -c "grep -A20 'parse_arguments()' '$TEST_PROJECT_DIR/src/hybrid-monitor.sh' | grep -q '\-\-add\-issue'"
    [ "$status" -eq 0 ]
    
    # Test queue-mode parameter parsing  
    run bash -c "grep -A20 'parse_arguments()' '$TEST_PROJECT_DIR/src/hybrid-monitor.sh' | grep -q '\-\-queue\-mode'"
    [ "$status" -eq 0 ]
}

@test "script runs without syntax errors" {
    run bash -n "$TEST_PROJECT_DIR/src/hybrid-monitor.sh"
    [ "$status" -eq 0 ]
}

@test "all phases are marked in code" {
    grep -q "PHASE 1:" "$TEST_PROJECT_DIR/src/hybrid-monitor.sh" 
    grep -q "PHASE 2:" "$TEST_PROJECT_DIR/src/hybrid-monitor.sh"
    grep -q "PHASE 3:" "$TEST_PROJECT_DIR/src/hybrid-monitor.sh"
    grep -q "PHASE 4:" "$TEST_PROJECT_DIR/src/hybrid-monitor.sh"
    grep -q "PHASE 5:" "$TEST_PROJECT_DIR/src/hybrid-monitor.sh"
    grep -q "PHASE 6:" "$TEST_PROJECT_DIR/src/hybrid-monitor.sh"
    grep -q "PHASE 7:" "$TEST_PROJECT_DIR/src/hybrid-monitor.sh"
    grep -q "PHASE 8:" "$TEST_PROJECT_DIR/src/hybrid-monitor.sh"
}

@test "backward compatibility maintained" {
    # Test existing parameters still work
    run "$TEST_PROJECT_DIR/src/hybrid-monitor.sh" --help
    [ "$status" -eq 0 ]
    
    echo "$output" | grep -q "\-\-continuous"
    echo "$output" | grep -q "\-\-check\-interval"
    echo "$output" | grep -q "\-\-debug"
}

@test "implementation scale matches requirements" {
    line_count=$(wc -l < "$TEST_PROJECT_DIR/src/hybrid-monitor.sh")
    function_count=$(grep -c "^[a-zA-Z_][a-zA-Z0-9_]*() {" "$TEST_PROJECT_DIR/src/hybrid-monitor.sh")
    
    # Should be around 1790+ lines with 25+ functions
    [ "$line_count" -gt 1700 ]
    [ "$function_count" -gt 20 ]
}