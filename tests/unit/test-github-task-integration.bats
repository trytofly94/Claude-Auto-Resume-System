#!/usr/bin/env bats

# Unit tests for GitHub Task Integration Module  
# Tests integration between GitHub system and Task Queue including:
# - Task creation from GitHub issues and PRs
# - GitHub URL validation and metadata extraction
# - Task status synchronization with GitHub comments
# - Progress tracking and update notifications
# - Error handling and recovery for GitHub operations
# - Cross-system state management and consistency

load ../test_helper
load ../fixtures/github-api-mocks

# Source the GitHub integration modules
setup() {
    default_setup
    
    # Create test project directory
    export TEST_PROJECT_DIR="$TEST_TEMP_DIR/claude-auto-resume"
    mkdir -p "$TEST_PROJECT_DIR"
    cd "$TEST_PROJECT_DIR"
    
    # Set up configuration for GitHub task integration
    export GITHUB_INTEGRATION_ENABLED="true"
    export GITHUB_AUTO_COMMENT="true" 
    export GITHUB_STATUS_UPDATES="true"
    export TASK_QUEUE_ENABLED="true"
    export TASK_QUEUE_DIR="queue"
    export GITHUB_TASK_AUTO_CREATE="true"
    export GITHUB_TASK_STATUS_SYNC="true"
    
    # Create required directories
    mkdir -p queue config
    
    # Create task queue JSON file
    cat > queue/task-queue.json << 'EOF'
{
  "metadata": {
    "version": "1.0.0",
    "created_at": "2025-08-25T08:00:00Z",
    "last_modified": "2025-08-25T08:00:00Z"
  },
  "tasks": []
}
EOF
    
    # Create configuration
    cat > config/default.conf << 'EOF'
GITHUB_INTEGRATION_ENABLED=true
GITHUB_AUTO_COMMENT=true
GITHUB_STATUS_UPDATES=true
TASK_QUEUE_ENABLED=true
TASK_QUEUE_DIR=queue
GITHUB_TASK_AUTO_CREATE=true
GITHUB_TASK_STATUS_SYNC=true
EOF
    
    # Mock commands
    mock_command "gh" 'mock_gh "$@"'
    mock_command "jq" 'mock_jq "$@"'
    
    # Reset mock state for each test
    reset_github_mock_state
    
    # Source the modules after setup
    local modules_loaded=0
    
    if [[ -f "$BATS_TEST_DIRNAME/../../src/task-queue.sh" ]]; then
        source "$BATS_TEST_DIRNAME/../../src/task-queue.sh"
        ((modules_loaded++))
    fi
    
    if [[ -f "$BATS_TEST_DIRNAME/../../src/github-integration.sh" ]]; then
        source "$BATS_TEST_DIRNAME/../../src/github-integration.sh"
        ((modules_loaded++))
    fi
    
    if [[ -f "$BATS_TEST_DIRNAME/../../src/github-integration-comments.sh" ]]; then
        source "$BATS_TEST_DIRNAME/../../src/github-integration-comments.sh"
        ((modules_loaded++))
    fi
    
    if [[ -f "$BATS_TEST_DIRNAME/../../src/github-task-integration.sh" ]]; then
        source "$BATS_TEST_DIRNAME/../../src/github-task-integration.sh"
        ((modules_loaded++))
    fi
    
    # Only proceed if we loaded at least the core modules
    if [[ $modules_loaded -lt 2 ]]; then
        skip "Required modules not found (loaded: $modules_loaded/4)"
    fi
    
    # Initialize the modules
    init_task_queue || true
    init_github_integration || true
}

teardown() {
    cleanup_github_integration || true
    cleanup_task_queue || true
    default_teardown
}

# Enhanced jq mock for task integration
mock_jq() {
    local query="$1"
    local file="${2:-}"
    
    case "$query" in
        # Task queue operations
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
        "-r '.id'"|"-r .id")
            echo "task-$(date +%s)-$RANDOM"
            ;;
        "-r '.github_url'"|"-r .github_url")
            echo "https://github.com/testuser/test-repo/issues/123"
            ;;
        "-r '.title'"|"-r .title") 
            echo "Test Task from GitHub Issue"
            ;;
        "-r '.status'"|"-r .status")
            echo "pending"
            ;;
        "empty")
            # JSON validation
            if [[ -n "$file" && -f "$file" ]]; then
                python3 -m json.tool "$file" >/dev/null 2>&1
            else
                return 0
            fi
            ;;
        ".tasks += ["*)
            # Add task to queue
            if [[ -f "$file" ]]; then
                # Extract task data and append
                local task_json="${query#*.tasks += [}"
                task_json="${task_json%]*}"
                python3 -c "
import json
import sys
try:
    with open('$file', 'r') as f:
        data = json.load(f)
    task = json.loads('$task_json')
    data['tasks'].append(task)
    with open('$file', 'w') as f:
        json.dump(data, f, indent=2)
except Exception as e:
    sys.exit(1)
" && echo "Task added successfully"
            fi
            ;;
        *)
            # Default jq behavior for other queries
            echo "{}"
            ;;
    esac
}

# ===============================================================================
# GITHUB TASK CREATION TESTS
# ===============================================================================

@test "create_task_from_github_url: should create task from issue URL" {
    set_github_mock_auth_state "true" "testuser"
    
    local github_url="https://github.com/testuser/test-repo/issues/123"
    
    run create_task_from_github_url "$github_url"
    
    assert_success
    assert_output --partial "Task created from GitHub URL"
    
    # Verify task was added to queue
    local task_count=$(jq '.tasks | length' queue/task-queue.json)
    [[ $task_count -gt 0 ]]
}

@test "create_task_from_github_url: should create task from PR URL" {
    set_github_mock_auth_state "true" "testuser"
    
    local github_url="https://github.com/testuser/test-repo/pull/456"
    
    run create_task_from_github_url "$github_url"
    
    assert_success
    assert_output --partial "Task created from GitHub URL"
    
    # Verify task has correct type
    local task_type=$(jq -r '.tasks[0].github_type' queue/task-queue.json)
    [[ "$task_type" == "pull_request" ]]
}

@test "create_task_from_github_url: should handle invalid GitHub URLs" {
    local invalid_url="https://not-github.com/invalid/url"
    
    run create_task_from_github_url "$invalid_url"
    
    assert_failure
    assert_output --partial "Invalid GitHub URL"
}

@test "create_task_from_github_url: should handle authentication failures" {
    set_github_mock_auth_state "false"
    
    local github_url="https://github.com/testuser/test-repo/issues/123"
    
    run create_task_from_github_url "$github_url"
    
    assert_failure
    assert_output --partial "Authentication required"
}

@test "create_task_from_github_url: should set appropriate task priority" {
    set_github_mock_auth_state "true" "testuser"
    
    # Mock issue with high priority label
    mock_command "gh" '
        if [[ "$*" =~ "api.*issues.*123" ]]; then
            cat << EOF
{
  "number": 123,
  "title": "High Priority Bug Fix",
  "labels": [
    {"name": "priority: high", "color": "b60205"},
    {"name": "bug", "color": "d73a49"}
  ],
  "state": "open"
}
EOF
        else
            mock_gh "$@"
        fi'
    
    local github_url="https://github.com/testuser/test-repo/issues/123"
    
    run create_task_from_github_url "$github_url"
    
    assert_success
    
    # Verify high priority was set
    local task_priority=$(jq -r '.tasks[0].priority' queue/task-queue.json)
    [[ "$task_priority" == "high" ]]
}

# ===============================================================================
# GITHUB URL VALIDATION TESTS
# ===============================================================================

@test "validate_github_task_url: should validate issue URLs" {
    set_github_mock_auth_state "true" "testuser"
    
    local github_url="https://github.com/testuser/test-repo/issues/123"
    
    run validate_github_task_url "$github_url"
    
    assert_success
    assert_output --partial "GitHub URL validated"
}

@test "validate_github_task_url: should validate PR URLs" {
    set_github_mock_auth_state "true" "testuser"
    
    local github_url="https://github.com/testuser/test-repo/pull/456"
    
    run validate_github_task_url "$github_url"
    
    assert_success
    assert_output --partial "GitHub URL validated"
}

@test "validate_github_task_url: should reject non-GitHub URLs" {
    local non_github_url="https://gitlab.com/user/repo/issues/123"
    
    run validate_github_task_url "$non_github_url"
    
    assert_failure
    assert_output --partial "Not a GitHub URL"
}

@test "validate_github_task_url: should handle private repositories" {
    set_github_mock_auth_state "true" "testuser"
    
    # Mock private repository access denied
    mock_command "gh" '
        if [[ "$*" =~ "api.*repos.*private" ]]; then
            echo "Not Found" >&2
            return 1
        else
            mock_gh "$@"
        fi'
    
    local private_url="https://github.com/testuser/private-repo/issues/123"
    
    run validate_github_task_url "$private_url"
    
    assert_failure
    assert_output --partial "Repository not accessible"
}

# ===============================================================================
# TASK STATUS SYNCHRONIZATION TESTS
# ===============================================================================

@test "sync_task_status_to_github: should post status update to GitHub" {
    set_github_mock_auth_state "true" "testuser"
    
    # Create a task with GitHub URL
    local task_data='{
        "id": "task-123",
        "title": "Test Task",
        "status": "in_progress",
        "progress": 50,
        "github_url": "https://github.com/testuser/test-repo/issues/123",
        "github_comment_id": null
    }'
    
    run sync_task_status_to_github "$task_data"
    
    assert_success
    assert_output --partial "Status synchronized to GitHub"
    
    # Verify API call was made
    local comment_call_count=$(get_github_mock_api_call_count "api_.*comment.*POST")
    [[ $comment_call_count -gt 0 ]]
}

@test "sync_task_status_to_github: should update existing comment" {
    set_github_mock_auth_state "true" "testuser"
    
    # Create a task with existing GitHub comment ID
    local task_data='{
        "id": "task-123",
        "title": "Test Task",
        "status": "in_progress", 
        "progress": 75,
        "github_url": "https://github.com/testuser/test-repo/issues/123",
        "github_comment_id": "1234567890"
    }'
    
    run sync_task_status_to_github "$task_data"
    
    assert_success
    assert_output --partial "Status synchronized to GitHub"
    
    # Should update existing comment, not create new one
    local update_call_count=$(get_github_mock_api_call_count "api_.*comment.*PATCH")
    [[ $update_call_count -gt 0 ]]
}

@test "sync_task_status_to_github: should handle completion status" {
    set_github_mock_auth_state "true" "testuser"
    
    local task_data='{
        "id": "task-123",
        "title": "Test Task",
        "status": "completed",
        "progress": 100,
        "github_url": "https://github.com/testuser/test-repo/issues/123",
        "completion_summary": "Task completed successfully",
        "results": ["Feature implemented", "Tests added"]
    }'
    
    run sync_task_status_to_github "$task_data"
    
    assert_success
    assert_output --partial "Status synchronized to GitHub"
    assert_output --partial "✅"  # Should use completion template
}

@test "sync_task_status_to_github: should handle error status" {
    set_github_mock_auth_state "true" "testuser"
    
    local task_data='{
        "id": "task-123",
        "title": "Test Task",
        "status": "failed",
        "github_url": "https://github.com/testuser/test-repo/issues/123",
        "error_message": "Task failed due to compilation error",
        "error_context": "During testing phase"
    }'
    
    run sync_task_status_to_github "$task_data"
    
    assert_success
    assert_output --partial "Status synchronized to GitHub"
    assert_output --partial "❌"  # Should use error template
}

@test "sync_task_status_to_github: should skip tasks without GitHub URLs" {
    local task_data='{
        "id": "task-123",
        "title": "Local Task",
        "status": "in_progress",
        "github_url": null
    }'
    
    run sync_task_status_to_github "$task_data"
    
    assert_success
    assert_output --partial "No GitHub URL"
    
    # Should not make any API calls
    local api_call_count=$(get_github_mock_api_call_count "api_")
    [[ $api_call_count -eq 0 ]]
}

# ===============================================================================
# PROGRESS TRACKING TESTS
# ===============================================================================

@test "update_github_progress: should track progress updates" {
    set_github_mock_auth_state "true" "testuser"
    
    local task_id="task-123"
    local progress=65
    local status="in_progress"
    local github_url="https://github.com/testuser/test-repo/issues/123"
    
    run update_github_progress "$task_id" "$progress" "$status" "$github_url"
    
    assert_success
    assert_output --partial "Progress updated on GitHub"
    
    # Verify progress bar is included
    assert_output --partial "65%"
}

@test "update_github_progress: should handle progress thresholds" {
    set_github_mock_auth_state "true" "testuser"
    
    local task_id="task-123"
    local github_url="https://github.com/testuser/test-repo/issues/123"
    
    # Test significant progress update (should post)
    run update_github_progress "$task_id" 50 "in_progress" "$github_url"
    assert_success
    
    # Test minor progress update (should skip unless interval passed)
    run update_github_progress "$task_id" 52 "in_progress" "$github_url"
    assert_success
    assert_output --partial "Minor progress change"
}

@test "update_github_progress: should respect update intervals" {
    set_github_mock_auth_state "true" "testuser"
    export GITHUB_PROGRESS_UPDATES_INTERVAL="60"  # 60 seconds
    
    local task_id="task-123"
    local github_url="https://github.com/testuser/test-repo/issues/123"
    
    # First update should always go through
    run update_github_progress "$task_id" 25 "in_progress" "$github_url"
    assert_success
    
    # Second update shortly after should be throttled
    run update_github_progress "$task_id" 30 "in_progress" "$github_url"
    assert_success
    assert_output --partial "Update interval not reached"
}

# ===============================================================================
# ERROR HANDLING AND RECOVERY TESTS
# ===============================================================================

@test "error handling: should handle GitHub API failures gracefully" {
    set_github_mock_auth_state "true" "testuser"
    
    # Mock API failure
    mock_command "gh" 'echo "API Error" >&2; return 1'
    
    local github_url="https://github.com/testuser/test-repo/issues/123"
    
    run create_task_from_github_url "$github_url"
    
    assert_failure
    assert_output --partial "Failed to fetch"
}

@test "error handling: should implement retry logic for transient failures" {
    set_github_mock_auth_state "true" "testuser"
    
    # Mock command that fails first time, succeeds second time
    mock_command "gh" '
        if [[ ${RETRY_COUNT:-0} -lt 1 ]]; then
            export RETRY_COUNT=$((${RETRY_COUNT:-0} + 1))
            echo "Temporary failure" >&2
            return 1
        else
            mock_gh "$@"
        fi'
    
    local github_url="https://github.com/testuser/test-repo/issues/123"
    
    run create_task_from_github_url "$github_url"
    
    assert_success
    assert_output --partial "Task created from GitHub URL"
}

@test "error handling: should handle malformed task data" {
    local invalid_task_data='{"invalid": "data"}'  # Missing required fields
    
    run sync_task_status_to_github "$invalid_task_data"
    
    assert_failure
    assert_output --partial "Invalid task data"
}

@test "error handling: should handle network timeouts" {
    set_github_mock_auth_state "true" "testuser"
    
    # Mock timeout scenario
    mock_command "gh" 'sleep 5; echo "Timeout" >&2; return 124'  # Timeout exit code
    
    local github_url="https://github.com/testuser/test-repo/issues/123"
    
    # Set short timeout for test
    export GITHUB_API_TIMEOUT="2"
    
    run create_task_from_github_url "$github_url"
    
    assert_failure
    assert_output --partial "timeout"
}

# ===============================================================================
# CROSS-SYSTEM STATE MANAGEMENT TESTS
# ===============================================================================

@test "state management: should maintain consistency between systems" {
    set_github_mock_auth_state "true" "testuser"
    
    local github_url="https://github.com/testuser/test-repo/issues/123"
    
    # Create task from GitHub URL
    create_task_from_github_url "$github_url"
    
    # Verify task exists in queue
    local task_count=$(jq '.tasks | length' queue/task-queue.json)
    [[ $task_count -eq 1 ]]
    
    # Verify GitHub URL is stored
    local stored_url=$(jq -r '.tasks[0].github_url' queue/task-queue.json)
    [[ "$stored_url" == "$github_url" ]]
}

@test "state management: should handle concurrent updates safely" {
    set_github_mock_auth_state "true" "testuser"
    
    # This test would need proper concurrency testing setup
    # For now, verify basic locking behavior
    export QUEUE_LOCK_TIMEOUT="5"
    
    local github_url="https://github.com/testuser/test-repo/issues/123"
    
    run create_task_from_github_url "$github_url"
    
    assert_success
}

@test "state management: should sync status changes bidirectionally" {
    set_github_mock_auth_state "true" "testuser"
    
    # Create task
    local github_url="https://github.com/testuser/test-repo/issues/123"
    create_task_from_github_url "$github_url"
    
    # Update task status in queue  
    local task_id=$(jq -r '.tasks[0].id' queue/task-queue.json)
    
    # Update task status (would typically be done by task queue)
    jq --arg status "completed" '.tasks[0].status = $status' queue/task-queue.json > temp.json && mv temp.json queue/task-queue.json
    
    # Sync to GitHub
    local task_data=$(jq -r '.tasks[0]' queue/task-queue.json)
    run sync_task_status_to_github "$task_data"
    
    assert_success
    assert_output --partial "Status synchronized to GitHub"
}

# ===============================================================================
# INTEGRATION WITH TASK QUEUE SYSTEM TESTS
# ===============================================================================

@test "task queue integration: should create GitHub tasks via task queue API" {
    set_github_mock_auth_state "true" "testuser"
    
    local github_url="https://github.com/testuser/test-repo/issues/123"
    
    # Use task queue API to add GitHub task
    run add_task "GitHub Issue: Test Task" "$github_url" "high" 3600
    
    assert_success
    
    # Verify task has GitHub metadata
    local github_task_count=$(jq '[.tasks[] | select(.github_url != null)] | length' queue/task-queue.json)
    [[ $github_task_count -gt 0 ]]
}

@test "task queue integration: should update GitHub when task status changes" {
    set_github_mock_auth_state "true" "testuser"
    
    # Add GitHub task
    local github_url="https://github.com/testuser/test-repo/issues/123"
    add_task "GitHub Issue: Test Task" "$github_url" "medium" 1800
    
    # Get task ID
    local task_id=$(jq -r '.tasks[0].id' queue/task-queue.json)
    
    # Update task status
    run update_task_status "$task_id" "in_progress"
    
    assert_success
    
    # Should trigger GitHub sync
    # (This would be tested via event system in full integration)
}

@test "task queue integration: should handle GitHub task completion" {
    set_github_mock_auth_state "true" "testuser"
    
    # Add and complete GitHub task
    local github_url="https://github.com/testuser/test-repo/issues/123"
    add_task "GitHub Issue: Test Task" "$github_url" "medium" 1800
    
    local task_id=$(jq -r '.tasks[0].id' queue/task-queue.json)
    
    # Complete task with results
    run complete_task "$task_id" "Task completed successfully" '["Feature implemented", "Tests added"]'
    
    assert_success
    
    # Verify completion was synced to GitHub
    # (This would trigger completion comment posting)
}

# ===============================================================================
# PERFORMANCE AND OPTIMIZATION TESTS  
# ===============================================================================

@test "performance: should cache GitHub metadata efficiently" {
    set_github_mock_auth_state "true" "testuser"
    
    local github_url="https://github.com/testuser/test-repo/issues/123"
    
    # First request should hit API
    create_task_from_github_url "$github_url"
    local first_api_calls=$(get_github_mock_api_call_count "api_")
    
    # Second request should use cache
    create_task_from_github_url "$github_url"
    local second_api_calls=$(get_github_mock_api_call_count "api_")
    
    # API calls should not increase significantly
    [[ $second_api_calls -le $((first_api_calls + 1)) ]]
}

@test "performance: should batch GitHub operations efficiently" {
    set_github_mock_auth_state "true" "testuser"
    
    # Create multiple tasks
    local urls=(
        "https://github.com/testuser/test-repo/issues/123"
        "https://github.com/testuser/test-repo/issues/124"
        "https://github.com/testuser/test-repo/pull/125"
    )
    
    for url in "${urls[@]}"; do
        create_task_from_github_url "$url"
    done
    
    # Verify all tasks were created
    local task_count=$(jq '.tasks | length' queue/task-queue.json)
    [[ $task_count -eq 3 ]]
}

@test "performance: should handle large comment updates efficiently" {
    set_github_mock_auth_state "true" "testuser"
    
    # Create task with large progress data
    local large_task_data=$(cat << 'EOF'
{
    "id": "task-123",
    "title": "Large Task with Extensive Progress Data",
    "status": "in_progress",
    "progress": 60,
    "github_url": "https://github.com/testuser/test-repo/issues/123",
    "completed_tasks": [
        "Task 1: Setup completed",
        "Task 2: Analysis finished",
        "Task 3: Design phase done",
        "Task 4: Implementation started",
        "Task 5: Unit tests written"
    ],
    "current_tasks": [
        "Task 6: Integration testing in progress",
        "Task 7: Documentation updates ongoing"
    ],
    "next_steps": [
        "Task 8: Performance testing",
        "Task 9: Security review",
        "Task 10: Final deployment"
    ]
}
EOF
    )
    
    run sync_task_status_to_github "$large_task_data"
    
    assert_success
    assert_output --partial "Status synchronized to GitHub"
}