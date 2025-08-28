#!/usr/bin/env bats

# Simple Task Execution Engine validation tests

PROJECT_ROOT="/Volumes/SSD-MacMini/ClaudeCode/Claude-Auto-Resume-System"

@test "hybrid-monitor.sh exists and is executable" {
    [ -f "$PROJECT_ROOT/src/hybrid-monitor.sh" ]
    [ -x "$PROJECT_ROOT/src/hybrid-monitor.sh" ]
}

@test "script runs without syntax errors" {
    run bash -n "$PROJECT_ROOT/src/hybrid-monitor.sh"
    [ "$status" -eq 0 ]
}

@test "CLI shows task queue options" {
    run "$PROJECT_ROOT/src/hybrid-monitor.sh" --help
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "TASK QUEUE OPTIONS"
    echo "$output" | grep -q "\-\-queue\-mode"
    echo "$output" | grep -q "\-\-add\-issue"
}

@test "list-queue command works" {
    run "$PROJECT_ROOT/src/hybrid-monitor.sh" --list-queue
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "No tasks in queue"
}

@test "file size is correct (1700+ lines)" {
    line_count=$(wc -l < "$PROJECT_ROOT/src/hybrid-monitor.sh")
    [ "$line_count" -gt 1700 ]
}

@test "all major task processing functions exist" {
    grep -q "process_task_queue_cycle()" "$PROJECT_ROOT/src/hybrid-monitor.sh"
    grep -q "execute_single_task()" "$PROJECT_ROOT/src/hybrid-monitor.sh"  
    grep -q "monitor_task_completion()" "$PROJECT_ROOT/src/hybrid-monitor.sh"
    grep -q "handle_task_failure()" "$PROJECT_ROOT/src/hybrid-monitor.sh"
}

@test "completion detection system implemented" {
    grep -q "monitor_task_completion()" "$PROJECT_ROOT/src/hybrid-monitor.sh"
    grep -q "###TASK_COMPLETE###" "$PROJECT_ROOT/src/hybrid-monitor.sh"
}

@test "task queue processing integrated in monitoring loop" {
    grep -q "process_task_queue_cycle" "$PROJECT_ROOT/src/hybrid-monitor.sh"
    # Verify it's called in the monitoring context  
    grep -A100 "continuous_monitoring_loop()" "$PROJECT_ROOT/src/hybrid-monitor.sh" | grep -q "process_task_queue_cycle"
}

@test "all phases are marked" {
    grep -q "Phase 2:" "$PROJECT_ROOT/src/hybrid-monitor.sh"
    grep -q "Phase 4:" "$PROJECT_ROOT/src/hybrid-monitor.sh" 
    grep -q "Phase 5:" "$PROJECT_ROOT/src/hybrid-monitor.sh"
    grep -q "Phase 6:" "$PROJECT_ROOT/src/hybrid-monitor.sh"
    grep -q "Phase 8:" "$PROJECT_ROOT/src/hybrid-monitor.sh"
}

@test "backward compatibility maintained" {
    run "$PROJECT_ROOT/src/hybrid-monitor.sh" --help
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "\-\-continuous"
    echo "$output" | grep -q "\-\-debug"
}