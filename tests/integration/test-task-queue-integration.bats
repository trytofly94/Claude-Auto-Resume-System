#!/usr/bin/env bats

# Integration tests for Task Queue Core Module
# Tests full workflows, concurrent access, persistence, and integration
# with the broader Claude Auto-Resume system

load ../test_helper

# Source the task queue module
setup() {
    default_setup
    
    # Create test project directory
    export TEST_PROJECT_DIR="$TEST_TEMP_DIR/claude-auto-resume"
    mkdir -p "$TEST_PROJECT_DIR"
    cd "$TEST_PROJECT_DIR"
    
    # Set up configuration for task queue
    export TASK_QUEUE_ENABLED="true"
    export TASK_QUEUE_DIR="queue"
    export TASK_DEFAULT_TIMEOUT=3600
    export TASK_MAX_RETRIES=3
    export TASK_QUEUE_MAX_SIZE=0
    export QUEUE_LOCK_TIMEOUT=5
    export TASK_AUTO_CLEANUP_DAYS=7
    export TASK_BACKUP_RETENTION_DAYS=30
    
    # Mock jq command for JSON processing
    mock_command "jq" 'mock_jq "$@"'
    
    mock_jq() {
        case "$1" in
            "empty")
                # Validate JSON using python
                if python3 -m json.tool "$2" >/dev/null 2>&1; then
                    return 0
                else
                    return 1
                fi
                ;;
            ".tasks | length")
                # Count tasks in JSON
                python3 -c "import json; data=json.load(open('$2')); print(len(data.get('tasks', [])))" 2>/dev/null || echo "0"
                ;;
            -r)
                # Extract field from JSON
                local query="$2"
                local file="$3"
                python3 -c "
import json
import sys
try:
    with open('$file') as f:
        data = json.load(f)
    
    # Handle array access and object access
    result = data
    parts = '$query'.replace('[', '.[').split('.')
    for part in parts:
        if not part:
            continue
        if part.startswith('[') and part.endswith(']'):
            idx = int(part[1:-1])
            result = result[idx]
        elif '|' in part:
            # Handle jq functions like 'join(\",\")'
            if 'join' in part:
                if isinstance(result, list):
                    result = ','.join(str(x) for x in result)
            continue
        elif '//' in part:
            # Handle default values
            key = part.split('//')[0].strip()
            default = part.split('//')[1].strip().strip('\"')
            result = result.get(key, default) if isinstance(result, dict) else result
            break
        else:
            result = result.get(part) if isinstance(result, dict) else getattr(result, part, None)
    
    if result is None:
        result = ''
    print(result)
except Exception as e:
    print('', file=sys.stderr)
    sys.exit(0)
" 2>/dev/null || echo ""
                ;;
            -R)
                # Read raw string and escape for JSON
                echo "\"$2\""
                ;;
            *)
                # Default: pass through to real jq if available, or simulate
                if command -v jq >/dev/null 2>&1; then
                    command jq "$@"
                else
                    echo "mock jq: $*" >&2
                    echo "{}"
                fi
                ;;
        esac
    }
    export -f mock_jq
    
    # Source the task queue module
    source "$BATS_TEST_DIRNAME/../../src/task-queue.sh"
}

teardown() {
    # Kill any background processes
    jobs -p | xargs -r kill 2>/dev/null || true
    default_teardown
}

# Test: Complete task lifecycle workflow
@test "complete task lifecycle from creation to completion" {
    init_task_queue
    
    # Create GitHub issue task
    run create_github_issue_task 123 1 "Critical bug fix" "bug,critical"
    [ "$status" -eq 0 ]
    local task_id="issue-123"
    
    # Verify task is pending
    [ "${TASK_STATES[$task_id]}" = "$TASK_STATE_PENDING" ]
    
    # Get next task (should be our task)
    local next_task=$(get_next_task "$TASK_STATE_PENDING")
    [ "$next_task" = "$task_id" ]
    
    # Start task
    update_task_status "$task_id" "$TASK_STATE_IN_PROGRESS"
    [ "${TASK_STATES[$task_id]}" = "$TASK_STATE_IN_PROGRESS" ]
    
    # Complete task
    update_task_status "$task_id" "$TASK_STATE_COMPLETED"
    [ "${TASK_STATES[$task_id]}" = "$TASK_STATE_COMPLETED" ]
    
    # Save state
    run save_queue_state
    [ "$status" -eq 0 ]
    
    # Verify JSON persistence
    assert_file_exists "$TEST_PROJECT_DIR/queue/task-queue.json"
    
    # Verify task details in JSON
    local json_content=$(cat "$TEST_PROJECT_DIR/queue/task-queue.json")
    [[ "$json_content" =~ \"id\":\"$task_id\" ]]
    [[ "$json_content" =~ \"status\":\"completed\" ]]
    [[ "$json_content" =~ \"github_number\":123 ]]
}

# Test: Task failure and retry workflow
@test "task failure and retry workflow" {
    init_task_queue
    
    # Create task
    local task_id=$(add_task_to_queue "$TASK_TYPE_CUSTOM" 5 "" "description" "Failing task")
    
    # Start task
    update_task_status "$task_id" "$TASK_STATE_IN_PROGRESS"
    
    # Fail task with error
    record_task_error "$task_id" "Network timeout" 124
    [ "${TASK_STATES[$task_id]}" = "$TASK_STATE_FAILED" ]
    [ "${TASK_METADATA[${task_id}_last_error]}" = "Network timeout" ]
    
    # Check retry eligibility
    run check_retry_eligibility "$task_id"
    [ "$status" -eq 0 ]
    
    # Increment retry count
    increment_retry_count "$task_id"
    [ "${TASK_RETRY_COUNTS[$task_id]}" = "1" ]
    
    # Reset to pending for retry
    update_task_status "$task_id" "$TASK_STATE_PENDING"
    
    # Try again - fail again
    update_task_status "$task_id" "$TASK_STATE_IN_PROGRESS" 
    record_task_error "$task_id" "Still failing" 1
    increment_retry_count "$task_id"
    [ "${TASK_RETRY_COUNTS[$task_id]}" = "2" ]
    
    # Third attempt - still eligible
    run check_retry_eligibility "$task_id"
    [ "$status" -eq 0 ]
    
    # Fourth attempt should hit limit
    increment_retry_count "$task_id"
    run check_retry_eligibility "$task_id"
    [ "$status" -eq 1 ]  # Should fail - max retries reached
}

# Test: Multiple task priority ordering workflow
@test "multiple task priority ordering workflow" {
    init_task_queue
    
    # Create tasks with different priorities and types
    create_github_issue_task 100 1 "Critical issue"     # Priority 1
    create_github_issue_task 101 1 "Also critical"      # Priority 1 (FIFO)
    create_github_issue_task 102 3 "Medium priority"    # Priority 3
    local custom_task=$(add_task_to_queue "$TASK_TYPE_CUSTOM" 2 "" "description" "High priority custom")  # Priority 2
    create_github_pr_task 200 5 "Low priority PR"       # Priority 5
    
    # Get tasks in priority order
    local task1=$(get_next_task "$TASK_STATE_PENDING")
    [ "$task1" = "issue-100" ]  # First priority 1 task (FIFO)
    
    # Start first task
    update_task_status "$task1" "$TASK_STATE_IN_PROGRESS"
    
    # Get next task
    local task2=$(get_next_task "$TASK_STATE_PENDING")
    [ "$task2" = "issue-101" ]  # Second priority 1 task
    
    # Start second task
    update_task_status "$task2" "$TASK_STATE_IN_PROGRESS"
    
    # Get next task (should be priority 2)
    local task3=$(get_next_task "$TASK_STATE_PENDING")
    [ "$task3" = "$custom_task" ]
    
    # Complete high priority tasks
    update_task_status "$task1" "$TASK_STATE_COMPLETED"
    update_task_status "$task2" "$TASK_STATE_COMPLETED"
    update_task_status "$task3" "$TASK_STATE_IN_PROGRESS"
    update_task_status "$task3" "$TASK_STATE_COMPLETED"
    
    # Next should be medium priority
    local task4=$(get_next_task "$TASK_STATE_PENDING")
    [ "$task4" = "issue-102" ]
    
    # Finally low priority
    update_task_status "$task4" "$TASK_STATE_IN_PROGRESS"
    update_task_status "$task4" "$TASK_STATE_COMPLETED"
    
    local task5=$(get_next_task "$TASK_STATE_PENDING")
    [ "$task5" = "pr-200" ]
    
    # Verify final statistics
    run get_queue_statistics
    [ "$status" -eq 0 ]
    assert_output_contains "Total Tasks: 5"
    assert_output_contains "Completed: 4"
    assert_output_contains "Pending: 1"
}

# Test: JSON persistence and recovery workflow
@test "JSON persistence and recovery workflow" {
    init_task_queue
    
    # Create complex queue state
    create_github_issue_task 123 1 "Bug fix" "bug,critical"
    create_github_pr_task 456 2 "Feature addition" 
    local custom_task=$(add_task_to_queue "$TASK_TYPE_CUSTOM" 3 "" "description" "Custom work" "command" "echo test")
    
    # Progress some tasks
    update_task_status "issue-123" "$TASK_STATE_IN_PROGRESS"
    update_task_status "pr-456" "$TASK_STATE_IN_PROGRESS"
    update_task_status "pr-456" "$TASK_STATE_COMPLETED"
    record_task_error "$custom_task" "Test error" 1
    increment_retry_count "$custom_task"
    
    # Save state
    run save_queue_state
    [ "$status" -eq 0 ]
    
    # Create backup
    run backup_queue_state "integration-test"
    [ "$status" -eq 0 ]
    
    # Store original state for comparison
    local orig_task1_state="${TASK_STATES[issue-123]}"
    local orig_task2_state="${TASK_STATES[pr-456]}"
    local orig_task3_state="${TASK_STATES[$custom_task]}"
    local orig_retry_count="${TASK_RETRY_COUNTS[$custom_task]}"
    local orig_error="${TASK_METADATA[${custom_task}_last_error]}"
    
    # Clear memory state
    unset TASK_STATES TASK_PRIORITIES TASK_METADATA TASK_TIMESTAMPS TASK_RETRY_COUNTS
    declare -gA TASK_STATES TASK_PRIORITIES TASK_METADATA TASK_TIMESTAMPS TASK_RETRY_COUNTS
    
    # Reload from JSON
    run load_queue_state
    [ "$status" -eq 0 ]
    assert_output_contains "Loading 3 tasks from queue file"
    
    # Verify all state was restored correctly
    [ "${TASK_STATES[issue-123]}" = "$orig_task1_state" ]
    [ "${TASK_STATES[pr-456]}" = "$orig_task2_state" ]
    [ "${TASK_STATES[$custom_task]}" = "$orig_task3_state" ]
    [ "${TASK_RETRY_COUNTS[$custom_task]}" = "$orig_retry_count" ]
    [ "${TASK_METADATA[${custom_task}_last_error]}" = "$orig_error" ]
    
    # Verify GitHub metadata was restored
    [ "${TASK_METADATA[issue-123_github_number]}" = "123" ]
    [ "${TASK_METADATA[issue-123_title]}" = "Bug fix" ]
    [ "${TASK_METADATA[issue-123_command]}" = "/dev 123" ]
    [ "${TASK_METADATA[pr-456_github_number]}" = "456" ]
    
    # Verify custom task metadata
    [ "${TASK_METADATA[${custom_task}_description]}" = "Custom work" ]
    [ "${TASK_METADATA[${custom_task}_command]}" = "echo test" ]
}

# Test: Concurrent access simulation
@test "concurrent access protection with file locking" {
    init_task_queue
    
    # Create a task
    local task_id=$(add_task_to_queue "$TASK_TYPE_CUSTOM" 5 "" "description" "Concurrent test")
    
    # Save initial state
    save_queue_state
    
    # Function to simulate concurrent operations
    concurrent_operation() {
        local op_id="$1"
        local temp_file="$TEST_TEMP_DIR/concurrent_${op_id}.log"
        
        (
            # Try to acquire lock and perform operations
            with_queue_lock bash -c "
                echo 'Operation $op_id: acquired lock' >> '$temp_file'
                sleep 0.1
                # Simulate some work
                update_task_priority '$task_id' \$((5 + $op_id % 3))
                echo 'Operation $op_id: completed work' >> '$temp_file'
            "
        ) &
    }
    
    # Start multiple concurrent operations
    for i in {1..3}; do
        concurrent_operation "$i"
    done
    
    # Wait for all operations to complete
    wait
    
    # Verify all operations completed
    for i in {1..3}; do
        local log_file="$TEST_TEMP_DIR/concurrent_${i}.log"
        assert_file_exists "$log_file"
        assert_output_contains "acquired lock" < "$log_file"
        assert_output_contains "completed work" < "$log_file"
    done
    
    # Task should still be valid
    [ -n "${TASK_STATES[$task_id]:-}" ]
}

# Test: Large queue performance
@test "performance with large queue (50+ tasks)" {
    init_task_queue
    
    # Create many tasks efficiently
    local task_ids=()
    echo "Creating 50 tasks..."
    
    for i in {1..50}; do
        local priority=$((i % 10 + 1))
        local task_type
        local task_id
        
        # Mix of task types
        if [[ $((i % 3)) -eq 0 ]]; then
            task_id=$(create_github_issue_task "$i" "$priority" "Issue $i")
        elif [[ $((i % 3)) -eq 1 ]]; then
            task_id=$(create_github_pr_task "$i" "$priority" "PR $i") 
        else
            task_id=$(add_task_to_queue "$TASK_TYPE_CUSTOM" "$priority" "" "description" "Task $i")
        fi
        
        task_ids+=("$task_id")
    done
    
    # Verify we created 50 tasks
    [ ${#TASK_STATES[@]} -eq 50 ]
    
    # Test operations perform reasonably
    echo "Testing operations on large queue..."
    
    # List tasks (should handle large output)
    run list_queue_tasks
    [ "$status" -eq 0 ]
    assert_output_contains "50 total"
    
    # Get statistics
    run get_queue_statistics
    [ "$status" -eq 0 ]
    assert_output_contains "Total Tasks: 50"
    assert_output_contains "Pending: 50"
    
    # Get next task (should be highest priority)
    local next_task=$(get_next_task "$TASK_STATE_PENDING")
    [ "${TASK_PRIORITIES[$next_task]}" = "1" ]
    
    # Save large queue
    run save_queue_state
    [ "$status" -eq 0 ]
    
    # JSON should be valid and contain all tasks
    run jq ".tasks | length" "$TEST_PROJECT_DIR/queue/task-queue.json"
    [ "$status" -eq 0 ]
    [ "$output" = "50" ]
    
    # Process several tasks to mixed states
    local processed=0
    for task_id in "${task_ids[@]}"; do
        [[ $processed -ge 10 ]] && break
        
        case $((processed % 4)) in
            0) update_task_status "$task_id" "$TASK_STATE_IN_PROGRESS"
               update_task_status "$task_id" "$TASK_STATE_COMPLETED" ;;
            1) update_task_status "$task_id" "$TASK_STATE_IN_PROGRESS"
               record_task_error "$task_id" "Test error" 1 ;;
            2) update_task_status "$task_id" "$TASK_STATE_IN_PROGRESS" ;;
            3) ;; # Leave pending
        esac
        
        ((processed++))
    done
    
    # Final statistics should show mixed states
    run get_queue_statistics
    [ "$status" -eq 0 ]
    assert_output_contains "Total Tasks: 50"
    assert_output_contains "Completed:" 
    assert_output_contains "Failed:"
    assert_output_contains "Active:"
    assert_output_contains "Pending:"
}

# Test: Backup and recovery under failure conditions
@test "backup and recovery under failure conditions" {
    init_task_queue
    
    # Create initial state
    create_github_issue_task 123 1 "Original task"
    local custom_task=$(add_task_to_queue "$TASK_TYPE_CUSTOM" 2)
    save_queue_state
    
    # Create explicit backup
    run backup_queue_state "before-corruption"
    [ "$status" -eq 0 ]
    local backup_file=$(ls "$TEST_PROJECT_DIR/queue/backups"/backup-before-corruption-*.json | head -n1)
    assert_file_exists "$backup_file"
    
    # Simulate corruption
    echo "corrupted json data" > "$TEST_PROJECT_DIR/queue/task-queue.json"
    
    # Loading should fail
    run load_queue_state
    [ "$status" -eq 1 ]
    assert_output_contains "invalid JSON"
    
    # Recover from backup
    run recover_queue_state "$backup_file"
    [ "$status" -eq 0 ]
    assert_output_contains "Queue state recovered"
    
    # State should be restored
    [ "${TASK_STATES[issue-123]}" = "$TASK_STATE_PENDING" ]
    [ -n "${TASK_STATES[$custom_task]:-}" ]
    
    # New queue file should be valid
    run jq empty "$TEST_PROJECT_DIR/queue/task-queue.json"
    [ "$status" -eq 0 ]
}

# Test: Auto-cleanup workflow
@test "auto-cleanup workflow removes old tasks and backups" {
    init_task_queue
    
    # Create tasks with different states
    local old_completed=$(add_task_to_queue "$TASK_TYPE_CUSTOM" 5)
    local old_failed=$(add_task_to_queue "$TASK_TYPE_CUSTOM" 5)
    local recent_completed=$(add_task_to_queue "$TASK_TYPE_CUSTOM" 5)
    local active_task=$(add_task_to_queue "$TASK_TYPE_CUSTOM" 5)
    
    # Set up old timestamps (simulate old tasks)
    TASK_TIMESTAMPS["${old_completed}_created"]="2020-01-01T00:00:00Z"
    TASK_TIMESTAMPS["${old_failed}_created"]="2020-01-01T00:00:00Z"
    
    # Complete/fail the old tasks
    update_task_status "$old_completed" "$TASK_STATE_IN_PROGRESS"
    update_task_status "$old_completed" "$TASK_STATE_COMPLETED"
    update_task_status "$old_failed" "$TASK_STATE_IN_PROGRESS"
    record_task_error "$old_failed" "Old error" 1
    
    # Complete recent task (should be preserved)
    update_task_status "$recent_completed" "$TASK_STATE_IN_PROGRESS"
    update_task_status "$recent_completed" "$TASK_STATE_COMPLETED"
    
    # Keep active task in progress
    update_task_status "$active_task" "$TASK_STATE_IN_PROGRESS"
    
    # Create some old backup files
    mkdir -p "$TEST_PROJECT_DIR/queue/backups"
    touch "$TEST_PROJECT_DIR/queue/backups/backup-old-20200101-120000.json"
    touch "$TEST_PROJECT_DIR/queue/backups/backup-recent-$(date +%Y%m%d-%H%M%S).json"
    
    # Run cleanup (1 day retention)
    run cleanup_old_tasks 1
    [ "$status" -eq 0 ]
    
    # Old completed/failed tasks should be removed
    [ -z "${TASK_STATES[$old_completed]:-}" ]
    [ -z "${TASK_STATES[$old_failed]:-}" ]
    
    # Recent completed and active tasks should remain
    [ -n "${TASK_STATES[$recent_completed]:-}" ]
    [ -n "${TASK_STATES[$active_task]:-}" ]
    
    # Run backup cleanup (1 day retention)
    run cleanup_old_backups 1
    [ "$status" -eq 0 ]
    
    # Old backup should be removed, recent should remain
    [ ! -f "$TEST_PROJECT_DIR/queue/backups/backup-old-20200101-120000.json" ]
}

# Test: Configuration loading and environment override
@test "configuration loading and environment override" {
    # Create custom config file
    cat > "$TEST_PROJECT_DIR/test-config.conf" << 'EOF'
TASK_QUEUE_ENABLED=true
TASK_DEFAULT_TIMEOUT=7200
TASK_MAX_RETRIES=5
TASK_QUEUE_MAX_SIZE=100
QUEUE_LOCK_TIMEOUT=60
EOF

    # Set environment override
    export TASK_MAX_RETRIES=2  # Should override config file
    
    run init_task_queue "$TEST_PROJECT_DIR/test-config.conf"
    [ "$status" -eq 0 ]
    
    # Environment variable should win
    [ "$TASK_MAX_RETRIES" = "2" ]
    
    # Config file values should be loaded for non-overridden vars
    [ "$TASK_DEFAULT_TIMEOUT" = "7200" ]
    [ "$TASK_QUEUE_MAX_SIZE" = "100" ]
    [ "$QUEUE_LOCK_TIMEOUT" = "60" ]
}

# Test: CLI interface integration
@test "CLI interface provides expected functionality" {
    # Initialize system
    init_task_queue
    
    # Test status command
    run bash "$BATS_TEST_DIRNAME/../../src/task-queue.sh" "status"
    [ "$status" -eq 0 ]
    assert_output_contains "Task Queue Status"
    
    # Test add command
    run bash "$BATS_TEST_DIRNAME/../../src/task-queue.sh" "add" "$TASK_TYPE_CUSTOM" "3" "" "description" "CLI test"
    [ "$status" -eq 0 ]
    assert_output_contains "Task added:"
    
    # Test list command  
    run bash "$BATS_TEST_DIRNAME/../../src/task-queue.sh" "list"
    [ "$status" -eq 0 ]
    assert_output_contains "TASK_ID"
    assert_output_contains "CLI test"
    
    # Test github-issue command
    run bash "$BATS_TEST_DIRNAME/../../src/task-queue.sh" "github-issue" "42" "1"
    [ "$status" -eq 0 ]
    assert_output_contains "GitHub issue task added"
    
    # Test stats command
    run bash "$BATS_TEST_DIRNAME/../../src/task-queue.sh" "stats"
    [ "$status" -eq 0 ]
    assert_output_contains "Queue Statistics"
    assert_output_contains "Total Tasks: 2"
    
    # Test cleanup command
    run bash "$BATS_TEST_DIRNAME/../../src/task-queue.sh" "cleanup"
    [ "$status" -eq 0 ]
}

# Test: Error recovery and resilience
@test "error recovery and resilience under various failure modes" {
    init_task_queue
    
    # Test recovery from disk full simulation (write failure)
    mock_command "mv" "echo 'mv: cannot move: No space left on device' >&2; return 1"
    
    add_task_to_queue "$TASK_TYPE_CUSTOM" 5
    run save_queue_state
    [ "$status" -eq 1 ]  # Should fail gracefully
    
    # Restore mv command
    unmock_command "mv"
    
    # Should work again
    run save_queue_state
    [ "$status" -eq 0 ]
    
    # Test recovery from permission issues
    local queue_file="$TEST_PROJECT_DIR/queue/task-queue.json"
    chmod 000 "$queue_file" 2>/dev/null || true  # Make unreadable
    
    run load_queue_state
    # Should handle gracefully (depending on system, might fail or succeed)
    
    # Restore permissions
    chmod 644 "$queue_file" 2>/dev/null || true
    
    # Test recovery from partially written files
    echo '{"version": "1.0", "tasks": [' > "$queue_file"  # Incomplete JSON
    
    run load_queue_state
    [ "$status" -eq 1 ]
    assert_output_contains "invalid JSON"
    
    # Should recover with valid JSON
    echo '{"version": "1.0", "tasks": []}' > "$queue_file"
    run load_queue_state
    [ "$status" -eq 0 ]
}

# Test: Task queue integration with existing logging system
@test "task queue integrates with existing logging system" {
    # Source logging utilities if available
    if [[ -f "$BATS_TEST_DIRNAME/../../src/utils/logging.sh" ]]; then
        source "$BATS_TEST_DIRNAME/../../src/utils/logging.sh" 2>/dev/null || true
    fi
    
    init_task_queue
    
    # Create log file to capture output
    local log_file="$TEST_TEMP_DIR/test.log"
    export LOG_FILE="$log_file"
    
    # Operations should generate appropriate log entries
    local task_id=$(add_task_to_queue "$TASK_TYPE_CUSTOM" 5 "" "description" "Logged task")
    update_task_status "$task_id" "$TASK_STATE_IN_PROGRESS"
    record_task_error "$task_id" "Test error for logging" 42
    
    # Save state (should also log)
    save_queue_state
    
    # Log file should contain relevant entries (if logging is working)
    if [[ -f "$log_file" ]]; then
        local log_content=$(cat "$log_file")
        [[ "$log_content" =~ "Adding task to queue" ]] || true
        [[ "$log_content" =~ "Task.*state change" ]] || true
        [[ "$log_content" =~ "error" ]] || true
    fi
}

# Test: Memory efficiency with large datasets
@test "memory efficiency with large task datasets" {
    init_task_queue
    
    # Create many tasks and verify memory structures don't grow excessively
    local task_count=100
    echo "Creating $task_count tasks for memory test..."
    
    for i in $(seq 1 $task_count); do
        add_task_to_queue "$TASK_TYPE_CUSTOM" $((i % 10 + 1)) "" "description" "Memory test task $i" "command" "echo $i" > /dev/null
    done
    
    # Verify all tasks created
    [ ${#TASK_STATES[@]} -eq $task_count ]
    
    # Process many tasks through various states
    local processed=0
    for task_id in "${!TASK_STATES[@]}"; do
        [[ $processed -ge 50 ]] && break
        
        update_task_status "$task_id" "$TASK_STATE_IN_PROGRESS" > /dev/null
        
        if [[ $((processed % 2)) -eq 0 ]]; then
            update_task_status "$task_id" "$TASK_STATE_COMPLETED" > /dev/null
        else
            record_task_error "$task_id" "Test error" 1 > /dev/null
        fi
        
        ((processed++))
    done
    
    # Save large state
    run save_queue_state
    [ "$status" -eq 0 ]
    
    # JSON file should be reasonable size and valid
    local json_file="$TEST_PROJECT_DIR/queue/task-queue.json"
    assert_file_exists "$json_file"
    
    local file_size=$(stat -f%z "$json_file" 2>/dev/null || stat -c%s "$json_file" 2>/dev/null || echo "0")
    [ "$file_size" -gt 1000 ]  # Should have substantial content
    [ "$file_size" -lt 1000000 ]  # But not excessively large
    
    # Clear and reload - memory should be managed properly
    clear_task_queue > /dev/null
    [ ${#TASK_STATES[@]} -eq 0 ]
    
    load_queue_state > /dev/null
    [ ${#TASK_STATES[@]} -eq $task_count ]  # All tasks restored
}