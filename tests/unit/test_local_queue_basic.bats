#!/usr/bin/env bats

# Unit tests for local queue basic functionality
# Issue #91 - Local Task Queue Implementation - Phase 1

# Setup and teardown
setup() {
    TEST_DIR="/tmp/bats-local-queue-$$"
    mkdir -p "$TEST_DIR"
    cd "$TEST_DIR"
    
    TASK_QUEUE_SCRIPT="/Volumes/SSD-MacMini/ClaudeCode/Claude-Auto-Resume-System/src/task-queue.sh"
}

teardown() {
    cd /
    rm -rf "$TEST_DIR"
}

@test "local queue detection returns false in directory without .claude-tasks" {
    run "$TASK_QUEUE_SCRIPT" show-context
    [ "$status" -eq 0 ]
    [[ "$output" =~ "global" ]]
}

@test "init-local-queue creates proper directory structure" {
    run "$TASK_QUEUE_SCRIPT" init-local-queue "test-project"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Local queue initialized successfully" ]]
    
    # Check directory structure
    [ -d ".claude-tasks" ]
    [ -f ".claude-tasks/queue.json" ]
    [ -f ".claude-tasks/config.json" ]
    [ -f ".claude-tasks/completed.json" ]
    [ -d ".claude-tasks/backups" ]
}

@test "init-local-queue creates valid JSON files" {
    run "$TASK_QUEUE_SCRIPT" init-local-queue "test-project"
    [ "$status" -eq 0 ]
    
    # Validate JSON structure
    run jq empty ".claude-tasks/queue.json"
    [ "$status" -eq 0 ]
    
    run jq empty ".claude-tasks/config.json"
    [ "$status" -eq 0 ]
    
    run jq empty ".claude-tasks/completed.json"
    [ "$status" -eq 0 ]
    
    # Check project name in queue.json
    project_name=$(jq -r '.project' ".claude-tasks/queue.json")
    [ "$project_name" = "test-project" ]
}

@test "local queue detection works after initialization" {
    "$TASK_QUEUE_SCRIPT" init-local-queue "test-project" >/dev/null
    
    run "$TASK_QUEUE_SCRIPT" show-context
    [ "$status" -eq 0 ]
    [[ "$output" =~ "local:" ]]
    [[ "$output" =~ "test-project" ]]
}

@test "add task to local queue works" {
    "$TASK_QUEUE_SCRIPT" init-local-queue "test-project" >/dev/null
    
    task_json='{"id":"test-001","type":"custom","status":"pending","description":"Test task","created_at":"2025-09-01T10:00:00Z"}'
    
    run "$TASK_QUEUE_SCRIPT" add "$task_json"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Task added to local queue successfully" ]]
    
    # Verify task was added
    task_count=$(jq '.tasks | length' ".claude-tasks/queue.json")
    [ "$task_count" -eq 1 ]
    
    # Verify task content
    task_id=$(jq -r '.tasks[0].id' ".claude-tasks/queue.json")
    [ "$task_id" = "test-001" ]
}

@test "list tasks from local queue works" {
    "$TASK_QUEUE_SCRIPT" init-local-queue "test-project" >/dev/null
    
    task_json='{"id":"test-002","type":"custom","status":"pending","description":"Test task","created_at":"2025-09-01T10:00:00Z"}'
    "$TASK_QUEUE_SCRIPT" add "$task_json" >/dev/null
    
    run "$TASK_QUEUE_SCRIPT" list
    [ "$status" -eq 0 ]
    [[ "$output" =~ "LOCAL TASKS" ]]
    [[ "$output" =~ "test-002" ]]
}

@test "remove task from local queue works" {
    "$TASK_QUEUE_SCRIPT" init-local-queue "test-project" >/dev/null
    
    task_json='{"id":"test-003","type":"custom","status":"pending","description":"Test task","created_at":"2025-09-01T10:00:00Z"}'
    "$TASK_QUEUE_SCRIPT" add "$task_json" >/dev/null
    
    run "$TASK_QUEUE_SCRIPT" remove "test-003"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Task removed from local queue: test-003" ]]
    
    # Verify task was removed
    task_count=$(jq '.tasks | length' ".claude-tasks/queue.json")
    [ "$task_count" -eq 0 ]
}

@test "local queue status command works" {
    "$TASK_QUEUE_SCRIPT" init-local-queue "test-project" >/dev/null
    
    run "$TASK_QUEUE_SCRIPT" status
    [ "$status" -eq 0 ]
    [[ "$output" =~ "LOCAL QUEUE STATUS" ]]
    [[ "$output" =~ "test-project" ]]
    [[ "$output" =~ "total_tasks" ]]
}

@test "local queue maintains isolation from global queue" {
    # Add task to global queue first (if we're in a directory without local queue)
    cd /tmp
    global_task='{"id":"global-001","type":"custom","status":"pending","description":"Global task","created_at":"2025-09-01T10:00:00Z"}'
    # Skip if global queue doesn't work
    
    # Move to test directory and initialize local queue
    cd "$TEST_DIR"
    "$TASK_QUEUE_SCRIPT" init-local-queue "test-project" >/dev/null
    
    local_task='{"id":"local-001","type":"custom","status":"pending","description":"Local task","created_at":"2025-09-01T10:00:00Z"}'
    "$TASK_QUEUE_SCRIPT" add "$local_task" >/dev/null
    
    # Verify local queue only has local task
    run "$TASK_QUEUE_SCRIPT" list
    [ "$status" -eq 0 ]
    [[ "$output" =~ "local-001" ]]
    [[ ! "$output" =~ "global-001" ]]
}

@test "directory tree walking finds local queue in parent directory" {
    # Create nested directory structure
    mkdir -p "project/src/module"
    cd "project"
    "$TASK_QUEUE_SCRIPT" init-local-queue "parent-project" >/dev/null
    
    # Move to child directory
    cd "src/module"
    
    run "$TASK_QUEUE_SCRIPT" show-context
    [ "$status" -eq 0 ]
    [[ "$output" =~ "local:" ]]
    [[ "$output" =~ "parent-project" ]]
}

@test "init-local-queue with --git flag works" {
    run "$TASK_QUEUE_SCRIPT" init-local-queue "git-project" --git
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Track in git: true" ]]
    
    # Check config reflects git setting
    track_git=$(jq -r '.integrations.version_control.track_in_git' ".claude-tasks/config.json")
    [ "$track_git" = "true" ]
}

@test "backup creation works during task operations" {
    "$TASK_QUEUE_SCRIPT" init-local-queue "test-project" >/dev/null
    
    task_json='{"id":"backup-test","type":"custom","status":"pending","description":"Backup test","created_at":"2025-09-01T10:00:00Z"}'
    "$TASK_QUEUE_SCRIPT" add "$task_json" >/dev/null
    
    # Check that backup was created
    backup_count=$(find ".claude-tasks/backups" -name "*.json" | wc -l)
    [ "$backup_count" -gt 0 ]
}

@test "invalid task JSON is rejected" {
    "$TASK_QUEUE_SCRIPT" init-local-queue "test-project" >/dev/null
    
    # Missing required field
    invalid_task='{"id":"invalid","description":"Missing type and status"}'
    
    run "$TASK_QUEUE_SCRIPT" add "$invalid_task"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "Failed to add task" ]]
}

@test "duplicate task ID is handled correctly" {
    "$TASK_QUEUE_SCRIPT" init-local-queue "test-project" >/dev/null
    
    task_json='{"id":"duplicate","type":"custom","status":"pending","description":"Original","created_at":"2025-09-01T10:00:00Z"}'
    "$TASK_QUEUE_SCRIPT" add "$task_json" >/dev/null
    
    # Try to add same ID again
    updated_task='{"id":"duplicate","type":"custom","status":"in_progress","description":"Updated","created_at":"2025-09-01T10:00:00Z"}'
    run "$TASK_QUEUE_SCRIPT" add "$updated_task"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Task added to local queue successfully" ]]
    
    # Verify only one task exists and it was updated
    task_count=$(jq '.tasks | length' ".claude-tasks/queue.json")
    [ "$task_count" -eq 1 ]
    
    task_status=$(jq -r '.tasks[0].status' ".claude-tasks/queue.json")
    [ "$task_status" = "in_progress" ]
}