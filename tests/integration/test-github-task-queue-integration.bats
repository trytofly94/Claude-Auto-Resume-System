#!/usr/bin/env bats

# Integration tests for GitHub Integration with Task Queue System
# Tests end-to-end workflow including:
# - GitHub issue/PR to task creation pipeline
# - Real-time status synchronization between systems
# - Cross-system error handling and recovery
# - Performance under combined load
# - Data consistency across state changes
# - Event-driven updates and notifications

load ../test_helper
load ../fixtures/github-api-mocks

# Source all required modules
setup() {
    default_setup
    
    # Create test project directory  
    export TEST_PROJECT_DIR="$TEST_TEMP_DIR/claude-auto-resume"
    mkdir -p "$TEST_PROJECT_DIR"
    cd "$TEST_PROJECT_DIR"
    
    # Set up comprehensive configuration
    export GITHUB_INTEGRATION_ENABLED="true"
    export GITHUB_AUTO_COMMENT="true"
    export GITHUB_STATUS_UPDATES="true"
    export GITHUB_COMPLETION_NOTIFICATIONS="true"
    export TASK_QUEUE_ENABLED="true"
    export TASK_QUEUE_DIR="queue"
    export TASK_QUEUE_MAX_SIZE="0"  # Unlimited for tests
    export GITHUB_TASK_AUTO_CREATE="true"
    export GITHUB_TASK_STATUS_SYNC="true"
    export GITHUB_PROGRESS_BACKUP_ENABLED="true"
    export GITHUB_PROGRESS_UPDATES_INTERVAL="60"  # Faster for tests
    export TASK_DEFAULT_TIMEOUT="300"  # 5 minutes for integration tests
    
    # Create required directories and files
    mkdir -p queue config/github-templates
    
    # Initialize task queue
    cat > queue/task-queue.json << 'EOF'
{
  "metadata": {
    "version": "1.0.0",
    "created_at": "2025-08-25T08:00:00Z",
    "last_modified": "2025-08-25T08:00:00Z",
    "queue_stats": {
      "total_tasks": 0,
      "completed_tasks": 0,
      "failed_tasks": 0
    }
  },
  "tasks": []
}
EOF
    
    # Create GitHub comment templates (minimal for integration tests)
    cat > config/github-templates/task_start.md << 'EOF'
🤖 **Task Started**: {TASK_TITLE}
**Status**: {STATUS}
**Progress**: {PROGRESS_BAR}
EOF
    
    cat > config/github-templates/progress.md << 'EOF'
🔄 **Progress Update**: {PROGRESS}%
{PROGRESS_BAR}
**Current**: {CURRENT_TASKS}
EOF
    
    cat > config/github-templates/completion.md << 'EOF'
✅ **Completed**: {TASK_TITLE}
**Duration**: {TOTAL_DURATION}
**Results**: {RESULTS}
EOF
    
    # Mock all external commands
    mock_command "gh" 'mock_gh "$@"'
    mock_command "jq" 'mock_integration_jq "$@"'
    
    # Reset mock state
    reset_github_mock_state
    
    # Source all modules in correct order
    source "$BATS_TEST_DIRNAME/../../src/utils/logging.sh"
    source "$BATS_TEST_DIRNAME/../../src/task-queue.sh"  
    source "$BATS_TEST_DIRNAME/../../src/github-integration.sh"
    source "$BATS_TEST_DIRNAME/../../src/github-integration-comments.sh"
    source "$BATS_TEST_DIRNAME/../../src/github-task-integration.sh"
    
    # Initialize systems
    init_task_queue || true
    init_github_integration || true
}

teardown() {
    cleanup_github_integration || true
    cleanup_task_queue || true
    default_teardown
}

# Enhanced jq mock for integration tests
mock_integration_jq() {
    local query="$1"
    local file="${2:-queue/task-queue.json}"
    local input="${3:-}"
    
    case "$query" in
        # Basic queue operations
        ".tasks | length")
            if [[ -f "$file" ]]; then
                python3 -c "import json; data=json.load(open('$file')); print(len(data.get('tasks', [])))" 2>/dev/null || echo "0"
            else
                echo "0"
            fi
            ;;
        "-r '.tasks[].id'")
            if [[ -f "$file" ]]; then
                python3 -c "import json; data=json.load(open('$file')); [print(task['id']) for task in data.get('tasks', [])]" 2>/dev/null || true
            fi
            ;;
        # Task property access
        "-r '.id'" | "-r .id")
            echo "task-integration-$(date +%s)"
            ;;
        "-r '.status'" | "-r .status")
            echo "pending"
            ;;
        "-r '.progress'" | "-r .progress")  
            echo "0"
            ;;
        "-r '.github_url'" | "-r .github_url")
            echo "https://github.com/testuser/test-repo/issues/123"
            ;;
        # Task mutations
        ".tasks += ["*)
            if [[ -f "$file" ]]; then
                local task_json="${query#*.tasks += [}"
                task_json="${task_json%]*}"
                python3 -c "
import json
import sys
try:
    with open('$file', 'r') as f:
        data = json.load(f)
    if not isinstance(data.get('tasks'), list):
        data['tasks'] = []
    task = json.loads('$task_json')
    data['tasks'].append(task)
    data['metadata']['last_modified'] = '$(date -u -Iseconds)'
    with open('$file', 'w') as f:
        json.dump(data, f, indent=2)
    print('Task added to queue')
except Exception as e:
    print(f'Error adding task: {e}', file=sys.stderr)
    sys.exit(1)
"
            fi
            ;;
        # Task updates
        "(.tasks[] | select(.id == "*)
            local task_id="${query#*(.tasks[] | select(.id == \"}"
            task_id="${task_id%%\")*}"
            local field_update="${query##*) | .}"
            
            if [[ -f "$file" ]]; then
                python3 -c "
import json
import sys
try:
    with open('$file', 'r') as f:
        data = json.load(f)
    for task in data.get('tasks', []):
        if task.get('id') == '$task_id':
            # Parse field update (simplified)
            if 'status' in '$field_update':
                task['status'] = 'in_progress'
            if 'progress' in '$field_update':
                task['progress'] = 50
            break
    data['metadata']['last_modified'] = '$(date -u -Iseconds)'
    with open('$file', 'w') as f:
        json.dump(data, f, indent=2)
    print('Task updated')
except Exception as e:
    print(f'Error updating task: {e}', file=sys.stderr)
    sys.exit(1)
"
            fi
            ;;
        "empty")
            # JSON validation
            if [[ -n "$file" && -f "$file" ]]; then
                python3 -m json.tool "$file" >/dev/null 2>&1
            else
                return 0
            fi
            ;;
        *)
            # Default fallback
            echo "{}"
            ;;
    esac
}

# ===============================================================================
# END-TO-END WORKFLOW TESTS
# ===============================================================================

@test "e2e: complete GitHub issue to task completion workflow" {
    set_github_mock_auth_state "true" "testuser"
    
    local github_url="https://github.com/testuser/test-repo/issues/123"
    
    # Step 1: Create task from GitHub URL
    run create_task_from_github_url "$github_url"
    assert_success
    assert_output --partial "Task created from GitHub URL"
    
    # Verify task exists in queue
    local task_count=$(jq '.tasks | length' queue/task-queue.json)
    [[ $task_count -eq 1 ]]
    
    # Step 2: Start task execution
    local task_id=$(jq -r '.tasks[0].id' queue/task-queue.json)
    run update_task_status "$task_id" "in_progress"
    assert_success
    
    # Step 3: Update progress
    run update_task_progress "$task_id" 50
    assert_success
    
    # Step 4: Complete task
    run complete_task "$task_id" "Task completed successfully" '["Feature implemented", "Tests added", "Documentation updated"]'
    assert_success
    
    # Verify final state
    local final_status=$(jq -r '.tasks[0].status' queue/task-queue.json)
    [[ "$final_status" == "completed" ]]
    
    # Verify GitHub synchronization calls were made
    local github_api_calls=$(get_github_mock_api_call_count "api_.*comment")
    [[ $github_api_calls -gt 0 ]]
}

@test "e2e: GitHub PR to task workflow with error handling" {
    set_github_mock_auth_state "true" "testuser"
    
    local github_url="https://github.com/testuser/test-repo/pull/456"
    
    # Create task from PR URL
    run create_task_from_github_url "$github_url"
    assert_success
    
    local task_id=$(jq -r '.tasks[0].id' queue/task-queue.json)
    
    # Start task
    run update_task_status "$task_id" "in_progress"  
    assert_success
    
    # Simulate task failure
    run fail_task "$task_id" "Compilation failed: syntax error at line 42" "SyntaxError"
    assert_success
    
    # Verify error state
    local task_status=$(jq -r '.tasks[0].status' queue/task-queue.json)
    [[ "$task_status" == "failed" ]]
    
    # Verify error was posted to GitHub
    local error_comment_calls=$(get_github_mock_api_call_count "api_.*comment.*POST")
    [[ $error_comment_calls -gt 0 ]]
}

@test "e2e: multiple GitHub tasks concurrent execution" {
    set_github_mock_auth_state "true" "testuser"
    
    # Create multiple tasks from different GitHub URLs
    local github_urls=(
        "https://github.com/testuser/test-repo/issues/123"
        "https://github.com/testuser/test-repo/issues/124"  
        "https://github.com/testuser/test-repo/pull/125"
    )
    
    # Create all tasks
    for url in "${github_urls[@]}"; do
        run create_task_from_github_url "$url"
        assert_success
    done
    
    # Verify all tasks created
    local task_count=$(jq '.tasks | length' queue/task-queue.json)
    [[ $task_count -eq 3 ]]
    
    # Start all tasks
    local task_ids=($(jq -r '.tasks[].id' queue/task-queue.json))
    for task_id in "${task_ids[@]}"; do
        run update_task_status "$task_id" "in_progress"
        assert_success
    done
    
    # Update progress on all tasks
    local progress_values=(25 60 90)
    for i in "${!task_ids[@]}"; do
        run update_task_progress "${task_ids[i]}" "${progress_values[i]}"
        assert_success
    done
    
    # Complete first task, fail second, leave third in progress
    run complete_task "${task_ids[0]}" "First task completed" '["Result 1"]'
    assert_success
    
    run fail_task "${task_ids[1]}" "Second task failed" "RuntimeError"
    assert_success
    
    # Verify final states
    local status1=$(jq -r ".tasks[0].status" queue/task-queue.json)
    local status2=$(jq -r ".tasks[1].status" queue/task-queue.json)  
    local status3=$(jq -r ".tasks[2].status" queue/task-queue.json)
    
    [[ "$status1" == "completed" ]]
    [[ "$status2" == "failed" ]]
    [[ "$status3" == "in_progress" ]]
}

# ===============================================================================
# REAL-TIME SYNCHRONIZATION TESTS
# ===============================================================================

@test "sync: task status changes trigger GitHub updates immediately" {
    set_github_mock_auth_state "true" "testuser"
    
    local github_url="https://github.com/testuser/test-repo/issues/123"
    
    # Create and start task
    create_task_from_github_url "$github_url"
    local task_id=$(jq -r '.tasks[0].id' queue/task-queue.json)
    
    # Clear API call tracking
    reset_github_mock_state
    set_github_mock_auth_state "true" "testuser"
    
    # Update status - should trigger immediate GitHub sync
    run update_task_status "$task_id" "in_progress"
    
    assert_success
    
    # Verify GitHub API call was made
    local api_calls=$(get_github_mock_api_call_count "api_.*comment")
    [[ $api_calls -gt 0 ]]
}

@test "sync: progress updates respect throttling intervals" {
    set_github_mock_auth_state "true" "testuser"
    export GITHUB_PROGRESS_UPDATES_INTERVAL="30"  # 30 seconds throttle
    
    local github_url="https://github.com/testuser/test-repo/issues/123"
    create_task_from_github_url "$github_url"
    local task_id=$(jq -r '.tasks[0].id' queue/task-queue.json)
    
    update_task_status "$task_id" "in_progress"
    
    # First progress update - should go through
    reset_github_mock_state
    set_github_mock_auth_state "true" "testuser"
    
    run update_task_progress "$task_id" 25
    assert_success
    
    local first_calls=$(get_github_mock_api_call_count "api_.*comment")
    
    # Second progress update immediately after - should be throttled
    run update_task_progress "$task_id" 30
    assert_success
    
    local second_calls=$(get_github_mock_api_call_count "api_.*comment")
    
    # Second call should not increase API usage significantly
    [[ $second_calls -le $((first_calls + 1)) ]]
}

@test "sync: significant progress changes override throttling" {
    set_github_mock_auth_state "true" "testuser"
    export GITHUB_PROGRESS_UPDATES_INTERVAL="3600"  # 1 hour throttle
    
    local github_url="https://github.com/testuser/test-repo/issues/123"
    create_task_from_github_url "$github_url"
    local task_id=$(jq -r '.tasks[0].id' queue/task-queue.json)
    
    update_task_status "$task_id" "in_progress"
    
    # Small progress change - should be throttled
    reset_github_mock_state
    set_github_mock_auth_state "true" "testuser"
    
    update_task_progress "$task_id" 10
    local small_calls=$(get_github_mock_api_call_count "api_.*comment")
    
    # Large progress jump - should override throttling
    run update_task_progress "$task_id" 75
    assert_success
    
    local large_calls=$(get_github_mock_api_call_count "api_.*comment")
    
    # Large progress change should trigger update
    [[ $large_calls -gt $small_calls ]]
}

# ===============================================================================
# ERROR HANDLING AND RECOVERY TESTS
# ===============================================================================

@test "error handling: GitHub API failures don't break task queue" {
    set_github_mock_auth_state "true" "testuser"
    
    # Mock GitHub API failure
    mock_command "gh" 'echo "API rate limit exceeded" >&2; return 1'
    
    local github_url="https://github.com/testuser/test-repo/issues/123"
    
    # Task creation should handle API failure gracefully
    run create_task_from_github_url "$github_url"
    
    # Should fail but not crash
    assert_failure
    assert_output --partial "Failed to fetch"
    
    # Task queue should still be functional
    run list_tasks
    assert_success
}

@test "error handling: task queue failures are reported to GitHub" {
    set_github_mock_auth_state "true" "testuser"
    
    local github_url="https://github.com/testuser/test-repo/issues/123"
    create_task_from_github_url "$github_url"
    local task_id=$(jq -r '.tasks[0].id' queue/task-queue.json)
    
    # Start task
    update_task_status "$task_id" "in_progress"
    
    # Simulate task system failure
    run fail_task "$task_id" "Critical system error: out of memory" "SystemError"
    
    assert_success
    
    # Verify error was reported to GitHub
    local error_calls=$(get_github_mock_api_call_count "api_.*comment.*POST")
    [[ $error_calls -gt 0 ]]
}

@test "error handling: network failures implement retry with exponential backoff" {
    set_github_mock_auth_state "true" "testuser"
    
    # Mock intermittent network failures
    local fail_count=0
    mock_command "gh" '
        if [[ $fail_count -lt 2 ]]; then
            ((fail_count++))
            echo "Network error" >&2
            return 1
        else
            mock_gh "$@"
        fi'
    
    local github_url="https://github.com/testuser/test-repo/issues/123"
    
    # Should eventually succeed after retries
    run create_task_from_github_url "$github_url"
    
    assert_success
    assert_output --partial "Task created from GitHub URL"
}

# ===============================================================================
# PERFORMANCE UNDER LOAD TESTS
# ===============================================================================

@test "performance: handles high-frequency task updates efficiently" {
    set_github_mock_auth_state "true" "testuser"
    
    local github_url="https://github.com/testuser/test-repo/issues/123"
    create_task_from_github_url "$github_url"
    local task_id=$(jq -r '.tasks[0].id' queue/task-queue.json)
    
    update_task_status "$task_id" "in_progress"
    
    # Rapid progress updates
    local progress_values=(10 15 20 25 30 35 40 45 50)
    
    for progress in "${progress_values[@]}"; do
        run update_task_progress "$task_id" "$progress"
        assert_success
    done
    
    # Should handle all updates without errors
    local final_progress=$(jq -r '.tasks[0].progress' queue/task-queue.json)
    [[ $final_progress -eq 50 ]]
}

@test "performance: caching reduces redundant GitHub API calls" {
    set_github_mock_auth_state "true" "testuser"
    
    # Clear API call tracking
    reset_github_mock_state
    set_github_mock_auth_state "true" "testuser"
    
    local github_url="https://github.com/testuser/test-repo/issues/123"
    
    # First task creation - should hit API
    create_task_from_github_url "$github_url"
    local first_api_calls=$(get_github_mock_api_call_count "api_.*issues.*123")
    
    # Second task creation with same URL - should use cache
    create_task_from_github_url "$github_url"
    local second_api_calls=$(get_github_mock_api_call_count "api_.*issues.*123")
    
    # API calls should not increase significantly (cache hit)
    [[ $second_api_calls -le $((first_api_calls + 1)) ]]
}

@test "performance: bulk operations are optimized" {
    set_github_mock_auth_state "true" "testuser"
    
    # Create multiple tasks quickly
    local github_urls=(
        "https://github.com/testuser/test-repo/issues/201"
        "https://github.com/testuser/test-repo/issues/202"
        "https://github.com/testuser/test-repo/issues/203"
        "https://github.com/testuser/test-repo/issues/204"
        "https://github.com/testuser/test-repo/issues/205"
    )
    
    # Time the bulk creation (simplified timing test)
    local start_time=$(date +%s)
    
    for url in "${github_urls[@]}"; do
        create_task_from_github_url "$url"
    done
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    # Should complete reasonably quickly (under 10 seconds for mocked operations)
    [[ $duration -lt 10 ]]
    
    # Verify all tasks created
    local task_count=$(jq '.tasks | length' queue/task-queue.json)
    [[ $task_count -eq 5 ]]
}

# ===============================================================================
# DATA CONSISTENCY TESTS
# ===============================================================================

@test "consistency: task data remains synchronized across state changes" {
    set_github_mock_auth_state "true" "testuser"
    
    local github_url="https://github.com/testuser/test-repo/issues/123"
    create_task_from_github_url "$github_url"
    local task_id=$(jq -r '.tasks[0].id' queue/task-queue.json)
    
    # Verify initial consistency
    local initial_github_url=$(jq -r '.tasks[0].github_url' queue/task-queue.json)
    [[ "$initial_github_url" == "$github_url" ]]
    
    # Progress through various states
    update_task_status "$task_id" "in_progress"
    update_task_progress "$task_id" 33
    update_task_progress "$task_id" 66
    complete_task "$task_id" "Task done" '["Result 1", "Result 2"]'
    
    # Verify final consistency
    local final_status=$(jq -r '.tasks[0].status' queue/task-queue.json)
    local final_progress=$(jq -r '.tasks[0].progress' queue/task-queue.json)
    local final_github_url=$(jq -r '.tasks[0].github_url' queue/task-queue.json)
    
    [[ "$final_status" == "completed" ]]
    [[ "$final_progress" == "100" ]]
    [[ "$final_github_url" == "$github_url" ]]
}

@test "consistency: concurrent updates maintain data integrity" {
    set_github_mock_auth_state "true" "testuser"
    
    local github_url="https://github.com/testuser/test-repo/issues/123"
    create_task_from_github_url "$github_url"
    local task_id=$(jq -r '.tasks[0].id' queue/task-queue.json)
    
    # Simulate rapid concurrent updates
    update_task_status "$task_id" "in_progress" &
    update_task_progress "$task_id" 25 &
    update_task_progress "$task_id" 50 &
    
    # Wait for all background processes
    wait
    
    # Verify data integrity maintained
    run jq empty queue/task-queue.json
    assert_success  # JSON should still be valid
    
    local task_count=$(jq '.tasks | length' queue/task-queue.json)
    [[ $task_count -eq 1 ]]  # Should still have exactly one task
}

# ===============================================================================
# BACKUP AND RECOVERY INTEGRATION TESTS
# ===============================================================================

@test "backup: progress is automatically backed up to GitHub" {
    set_github_mock_auth_state "true" "testuser"
    export GITHUB_PROGRESS_BACKUP_ENABLED="true"
    
    local github_url="https://github.com/testuser/test-repo/issues/123"
    create_task_from_github_url "$github_url"
    local task_id=$(jq -r '.tasks[0].id' queue/task-queue.json)
    
    # Progress through task with backup points
    update_task_status "$task_id" "in_progress"
    update_task_progress "$task_id" 50
    
    # Should have created backup comments
    local backup_calls=$(get_github_mock_api_call_count "api_.*comment.*POST")
    [[ $backup_calls -gt 0 ]]
}

@test "recovery: can restore task state from GitHub backup" {
    set_github_mock_auth_state "true" "testuser"
    export GITHUB_PROGRESS_BACKUP_ENABLED="true"
    
    local github_url="https://github.com/testuser/test-repo/issues/123"
    local task_id="task-recovery-test"
    
    # Mock existing backup comment
    local backup_data="{\"task_id\": \"$task_id\", \"progress\": 75, \"status\": \"in_progress\"}"
    mock_command "gh" "
        if [[ \"\$*\" =~ comments ]]; then
            echo \"[{\\\"id\\\": 999, \\\"body\\\": \\\"<!-- CLAUDE_PROGRESS_BACKUP:$backup_data -->\\\", \\\"user\\\": {\\\"login\\\": \\\"claude-bot\\\"}}]\"
        else
            mock_gh \"\$@\"
        fi"
    
    # Restore from backup
    run restore_progress_from_github "$github_url" "$task_id"
    
    assert_success
    assert_output --partial "$task_id"
    assert_output --partial "75"
}

# ===============================================================================
# INTEGRATION WITH EXTERNAL SYSTEMS TESTS  
# ===============================================================================

@test "external integration: works with existing task queue workflows" {
    set_github_mock_auth_state "true" "testuser"
    
    # Simulate existing task queue with non-GitHub tasks
    local existing_task='{
        "id": "existing-task-123",
        "title": "Existing Local Task",
        "status": "pending",
        "priority": "medium",
        "timeout": 1800,
        "github_url": null,
        "created_at": "2025-08-25T08:00:00Z"
    }'
    
    # Add existing task directly
    jq ".tasks += [$existing_task]" queue/task-queue.json > temp.json && mv temp.json queue/task-queue.json
    
    # Add GitHub task
    local github_url="https://github.com/testuser/test-repo/issues/123"
    run create_task_from_github_url "$github_url"
    
    assert_success
    
    # Verify both tasks coexist
    local total_tasks=$(jq '.tasks | length' queue/task-queue.json)
    local github_tasks=$(jq '[.tasks[] | select(.github_url != null)] | length' queue/task-queue.json)
    local local_tasks=$(jq '[.tasks[] | select(.github_url == null)] | length' queue/task-queue.json)
    
    [[ $total_tasks -eq 2 ]]
    [[ $github_tasks -eq 1 ]]
    [[ $local_tasks -eq 1 ]]
}

@test "external integration: handles mixed task types correctly" {
    set_github_mock_auth_state "true" "testuser"
    
    # Create mixed task types
    add_task "Local Task 1" "" "high" 3600                                               # Local task
    create_task_from_github_url "https://github.com/testuser/test-repo/issues/123"      # GitHub issue
    add_task "Local Task 2" "" "low" 1800                                                # Local task  
    create_task_from_github_url "https://github.com/testuser/test-repo/pull/456"        # GitHub PR
    
    # List all tasks
    run list_tasks
    assert_success
    
    # Verify correct task types
    local github_issue_tasks=$(jq '[.tasks[] | select(.github_type == "issue")] | length' queue/task-queue.json)
    local github_pr_tasks=$(jq '[.tasks[] | select(.github_type == "pull_request")] | length' queue/task-queue.json)
    local local_tasks=$(jq '[.tasks[] | select(.github_url == null)] | length' queue/task-queue.json)
    
    [[ $github_issue_tasks -eq 1 ]]
    [[ $github_pr_tasks -eq 1 ]]
    [[ $local_tasks -eq 2 ]]
    
    # Update different task types - only GitHub tasks should sync
    local task_ids=($(jq -r '.tasks[].id' queue/task-queue.json))
    
    reset_github_mock_state
    set_github_mock_auth_state "true" "testuser"
    
    # Update all tasks
    for task_id in "${task_ids[@]}"; do
        update_task_status "$task_id" "in_progress"
    done
    
    # Only GitHub tasks should have generated API calls
    local api_calls=$(get_github_mock_api_call_count "api_.*comment")
    [[ $api_calls -eq 2 ]]  # Only 2 GitHub tasks should sync
}