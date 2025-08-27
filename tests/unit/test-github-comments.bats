#!/usr/bin/env bats

# Unit tests for GitHub Comments Module
# Tests comprehensive comment management including:
# - Template-based comment generation and formatting
# - Progress tracking and status updates
# - Collapsible sections and markdown formatting  
# - Comment posting, updating, and cleanup
# - Backup and restore functionality via hidden comments
# - Rate limiting and error handling for comment operations

load ../test_helper
load ../fixtures/github-api-mocks

# Source the GitHub integration modules
setup() {
    default_setup
    
    # Create test project directory
    export TEST_PROJECT_DIR="$TEST_TEMP_DIR/claude-auto-resume"
    mkdir -p "$TEST_PROJECT_DIR"
    cd "$TEST_PROJECT_DIR"
    
    # Set up configuration for GitHub comments
    export GITHUB_INTEGRATION_ENABLED="true"
    export GITHUB_AUTO_COMMENT="true"
    export GITHUB_STATUS_UPDATES="true"
    export GITHUB_COMPLETION_NOTIFICATIONS="true"
    export GITHUB_USE_COLLAPSIBLE_SECTIONS="true"
    export GITHUB_MAX_COMMENT_LENGTH="65000"
    export GITHUB_PROGRESS_UPDATES_INTERVAL="300"
    export GITHUB_PROGRESS_BACKUP_ENABLED="true"
    export GITHUB_BACKUP_RETENTION_HOURS="72"
    
    # Create mock configuration and templates directory
    mkdir -p config/github-templates
    
    # Create comment templates
    cat > config/github-templates/task_start.md << 'EOF'
🤖 **Task Started**

**Task**: {TASK_TITLE}
**Started**: {TIMESTAMP}
**Status**: In Progress

---

## Progress Tracking

{PROGRESS_BAR}

### Current Phase
{CURRENT_PHASE}

### Next Steps
{NEXT_STEPS}

---

<details>
<summary>📊 Task Details</summary>

**Task ID**: {TASK_ID}
**Priority**: {PRIORITY}
**Estimated Duration**: {DURATION}

</details>

*This comment will be updated automatically as the task progresses.*
EOF

    cat > config/github-templates/progress.md << 'EOF'
🔄 **Progress Update**

**Task**: {TASK_TITLE}
**Updated**: {TIMESTAMP}
**Status**: {STATUS}
**Progress**: {PROGRESS}%

---

## Progress Tracking

{PROGRESS_BAR}

### Recently Completed
{COMPLETED_TASKS}

### Currently Working On  
{CURRENT_TASKS}

### Next Steps
{NEXT_STEPS}

---

<details>
<summary>📈 Detailed Progress</summary>

### Phase Breakdown
{PHASE_DETAILS}

### Time Tracking
- **Started**: {START_TIME}
- **Last Update**: {LAST_UPDATE}  
- **Estimated Completion**: {ETA}

</details>

*Progress updates are posted automatically every {UPDATE_INTERVAL} seconds.*
EOF

    cat > config/github-templates/completion.md << 'EOF'
✅ **Task Completed Successfully**

**Task**: {TASK_TITLE}
**Completed**: {TIMESTAMP}
**Duration**: {TOTAL_DURATION}

---

## Summary

{COMPLETION_SUMMARY}

### Completed Tasks
{COMPLETED_TASKS}

### Results
{RESULTS}

---

<details>
<summary>📊 Task Statistics</summary>

**Total Duration**: {TOTAL_DURATION}
**Phases Completed**: {PHASES_COUNT}
**Files Modified**: {FILES_COUNT}
**Tests Added/Updated**: {TESTS_COUNT}

### Performance Metrics
- **Setup Time**: {SETUP_TIME}
- **Implementation Time**: {IMPL_TIME}
- **Testing Time**: {TEST_TIME}
- **Documentation Time**: {DOC_TIME}

</details>

**Task successfully completed! 🎉**
EOF

    cat > config/github-templates/error.md << 'EOF'
❌ **Task Error Occurred**

**Task**: {TASK_TITLE}
**Error Time**: {TIMESTAMP}
**Status**: Failed

---

## Error Details

{ERROR_MESSAGE}

### Stack Trace
```
{STACK_TRACE}
```

### Context
{ERROR_CONTEXT}

---

<details>
<summary>🔍 Debugging Information</summary>

**Error Type**: {ERROR_TYPE}
**Exit Code**: {EXIT_CODE}
**Phase**: {CURRENT_PHASE}

### Environment
{ENV_INFO}

### Logs
{LOG_EXCERPT}

</details>

**Manual intervention required to resolve this issue.**
EOF
    
    # Mock gh command to use our GitHub API mocks
    mock_command "gh" 'mock_gh "$@"'
    
    # Mock jq for JSON processing
    mock_command "jq" 'mock_jq "$@"'
    
    # Reset mock state for each test
    reset_github_mock_state
    
    # Source the modules after setup
    if [[ -f "$BATS_TEST_DIRNAME/../../src/github-integration.sh" ]]; then
        source "$BATS_TEST_DIRNAME/../../src/github-integration.sh"
        if [[ -f "$BATS_TEST_DIRNAME/../../src/github-integration-comments.sh" ]]; then
            source "$BATS_TEST_DIRNAME/../../src/github-integration-comments.sh"
            # Initialize the modules
            init_github_integration || true
        else
            skip "GitHub comments module not found"
        fi
    else
        skip "GitHub integration module not found"
    fi
}

teardown() {
    cleanup_github_integration || true
    default_teardown
}

# Custom jq mock for comment tests
mock_jq() {
    case "$*" in
        "-r '.id'")
            echo "1234567890"
            ;;
        "-r '.body'") 
            echo "Mock comment body content"
            ;;
        "-r '.html_url'")
            echo "https://github.com/testuser/test-repo/issues/123#issuecomment-1234567890"
            ;;
        "empty")
            # JSON validation
            return 0
            ;;
        *)
            # Default jq behavior
            python3 -c "import json, sys; print(json.dumps(json.load(sys.stdin)))" 2>/dev/null || echo "{}"
            ;;
    esac
}

# ===============================================================================
# COMMENT TEMPLATE TESTS
# ===============================================================================

@test "load_comment_templates: should load all template files" {
    run load_comment_templates
    
    assert_success
    assert_output --partial "Comment templates loaded"
    
    # Verify templates are loaded into associative array
    [[ -n "${COMMENT_TEMPLATES[task_start]:-}" ]]
    [[ -n "${COMMENT_TEMPLATES[progress]:-}" ]]
    [[ -n "${COMMENT_TEMPLATES[completion]:-}" ]]
    [[ -n "${COMMENT_TEMPLATES[error]:-}" ]]
}

@test "load_comment_templates: should handle missing template directory" {
    # Remove templates directory
    rm -rf config/github-templates
    
    run load_comment_templates
    
    assert_failure
    assert_output --partial "Template directory not found"
}

@test "load_comment_templates: should handle missing template files" {
    # Remove one template file
    rm config/github-templates/task_start.md
    
    run load_comment_templates
    
    assert_success
    # Should warn about missing template but continue
    assert_output --partial "Template file not found: task_start.md"
}

@test "get_comment_template: should return correct template" {
    load_comment_templates
    
    run get_comment_template "task_start"
    
    assert_success
    assert_output --partial "🤖 **Task Started**"
    assert_output --partial "{TASK_TITLE}"
    assert_output --partial "{TIMESTAMP}"
}

@test "get_comment_template: should handle unknown template type" {
    load_comment_templates
    
    run get_comment_template "unknown_template"
    
    assert_failure
    assert_output --partial "Unknown template type"
}

# ===============================================================================
# COMMENT GENERATION TESTS  
# ===============================================================================

@test "generate_task_start_comment: should create properly formatted comment" {
    load_comment_templates
    
    local task_data='{
        "id": "task-123",
        "title": "Test Task Implementation",
        "priority": "high",
        "duration": "2h",
        "phases": ["setup", "implementation", "testing"]
    }'
    
    run generate_task_start_comment "$task_data"
    
    assert_success
    assert_output --partial "🤖 **Task Started**"
    assert_output --partial "Test Task Implementation"
    assert_output --partial "task-123"
    assert_output --partial "high"
    assert_output --partial "2h"
}

@test "generate_progress_update_comment: should create progress comment" {
    load_comment_templates
    
    local task_data='{
        "id": "task-123",
        "title": "Test Task Implementation",
        "progress": 65,
        "status": "in_progress",
        "completed_tasks": ["Setup completed", "Basic implementation done"],
        "current_tasks": ["Writing tests"],
        "next_steps": ["Documentation", "Final review"]
    }'
    
    run generate_progress_update_comment "$task_data"
    
    assert_success
    assert_output --partial "🔄 **Progress Update**"
    assert_output --partial "65%"
    assert_output --partial "Setup completed"
    assert_output --partial "Writing tests"
    assert_output --partial "Documentation"
}

@test "generate_completion_comment: should create completion comment" {
    load_comment_templates
    
    local task_data='{
        "id": "task-123",
        "title": "Test Task Implementation",
        "status": "completed",
        "duration": "2h 15m",
        "summary": "Task completed successfully with all objectives met",
        "results": ["Feature implemented", "Tests added", "Documentation updated"],
        "stats": {
            "files_modified": 15,
            "tests_added": 23,
            "phases_completed": 4
        }
    }'
    
    run generate_completion_comment "$task_data"
    
    assert_success
    assert_output --partial "✅ **Task Completed Successfully**"
    assert_output --partial "2h 15m"
    assert_output --partial "Feature implemented"
    assert_output --partial "Tests added"
    assert_output --partial "15"
    assert_output --partial "23"
}

@test "generate_error_comment: should create error comment" {
    load_comment_templates
    
    local error_data='{
        "id": "task-123",
        "title": "Test Task Implementation",
        "error_message": "Compilation failed due to syntax error",
        "error_type": "SyntaxError",
        "exit_code": 1,
        "stack_trace": "Error at line 45: unexpected token",
        "context": "During testing phase",
        "phase": "testing"
    }'
    
    run generate_error_comment "$error_data"
    
    assert_success
    assert_output --partial "❌ **Task Error Occurred**"
    assert_output --partial "Compilation failed due to syntax error"
    assert_output --partial "SyntaxError"
    assert_output --partial "Error at line 45"
    assert_output --partial "During testing phase"
}

# ===============================================================================
# PROGRESS BAR TESTS
# ===============================================================================

@test "generate_progress_bar: should create visual progress bar" {
    run generate_progress_bar 65 50  # 65% progress, 50 char width
    
    assert_success
    assert_output --partial "█████████████████████████████████░░░░░░░░░░░░░░░░░░░"
    assert_output --partial "65%"
}

@test "generate_progress_bar: should handle edge cases" {
    # Test 0% progress
    run generate_progress_bar 0 20
    assert_success
    assert_output --partial "░░░░░░░░░░░░░░░░░░░░"
    
    # Test 100% progress  
    run generate_progress_bar 100 20
    assert_success
    assert_output --partial "████████████████████"
    
    # Test invalid progress values
    run generate_progress_bar 150 20
    assert_success
    assert_output --partial "100%"  # Should cap at 100%
    
    run generate_progress_bar -10 20
    assert_success  
    assert_output --partial "0%"    # Should floor at 0%
}

@test "generate_progress_bar: should handle different widths" {
    # Test small width
    run generate_progress_bar 50 10
    assert_success
    assert_output --partial "█████░░░░░"
    
    # Test large width
    run generate_progress_bar 50 100
    assert_success
    # Should have 50 filled chars and 50 empty chars
    local output_line
    output_line=$(generate_progress_bar 50 100 | head -1)
    local filled_count=$(echo "$output_line" | grep -o "█" | wc -l)
    [[ $filled_count -eq 50 ]]
}

# ===============================================================================
# COLLAPSIBLE SECTIONS TESTS
# ===============================================================================

@test "create_collapsible_section: should format collapsible HTML" {
    local title="Test Section"
    local content="This is test content\nwith multiple lines"
    
    run create_collapsible_section "$title" "$content"
    
    assert_success
    assert_output --partial "<details>"
    assert_output --partial "<summary>Test Section</summary>"
    assert_output --partial "This is test content"
    assert_output --partial "</details>"
}

@test "create_collapsible_section: should handle empty content" {
    local title="Empty Section"
    local content=""
    
    run create_collapsible_section "$title" "$content"
    
    assert_success
    assert_output --partial "<details>"
    assert_output --partial "<summary>Empty Section</summary>"
    assert_output --partial "</details>"
}

@test "create_collapsible_section: should escape HTML characters" {
    local title="Section with <tags>"  
    local content="Content with <script>alert('test')</script>"
    
    run create_collapsible_section "$title" "$content"
    
    assert_success
    # HTML should be escaped in title and content
    assert_output --partial "&lt;tags&gt;"
    assert_output --partial "&lt;script&gt;"
}

# ===============================================================================
# COMMENT POSTING TESTS
# ===============================================================================

@test "post_github_comment: should post comment to issue" {
    set_github_mock_auth_state "true" "testuser"
    load_comment_templates
    
    local github_url="https://github.com/testuser/test-repo/issues/123"
    local comment_body="Test comment body"
    
    run post_github_comment "$github_url" "$comment_body"
    
    assert_success
    assert_output --partial "Comment posted successfully"
    assert_output --partial "1234567890"  # Comment ID from mock
}

@test "post_github_comment: should post comment to PR" {
    set_github_mock_auth_state "true" "testuser"
    load_comment_templates
    
    local github_url="https://github.com/testuser/test-repo/pull/456"
    local comment_body="Test PR comment body"
    
    run post_github_comment "$github_url" "$comment_body"
    
    assert_success
    assert_output --partial "Comment posted successfully"
}

@test "post_github_comment: should handle comment length limits" {
    set_github_mock_auth_state "true" "testuser"
    load_comment_templates
    
    # Create comment that exceeds limit
    local long_comment=$(printf "%.0s*" {1..70000})  # 70k chars
    local github_url="https://github.com/testuser/test-repo/issues/123"
    
    run post_github_comment "$github_url" "$long_comment"
    
    assert_success
    assert_output --partial "Comment truncated"
    assert_output --partial "Comment posted successfully"
}

@test "post_github_comment: should handle authentication failures" {
    set_github_mock_auth_state "false"
    
    local github_url="https://github.com/testuser/test-repo/issues/123"
    local comment_body="Test comment"
    
    run post_github_comment "$github_url" "$comment_body"
    
    assert_failure
    assert_output --partial "Authentication required"
}

@test "post_github_comment: should handle invalid URLs" {
    set_github_mock_auth_state "true" "testuser"
    
    local invalid_url="https://invalid-url.com/not/github"
    local comment_body="Test comment"
    
    run post_github_comment "$invalid_url" "$comment_body"
    
    assert_failure
    assert_output --partial "Invalid GitHub URL"
}

# ===============================================================================
# COMMENT UPDATE TESTS
# ===============================================================================

@test "update_github_comment: should update existing comment" {
    set_github_mock_auth_state "true" "testuser"
    
    local comment_id="1234567890"
    local new_body="Updated comment body"
    local github_url="https://github.com/testuser/test-repo/issues/123"
    
    run update_github_comment "$github_url" "$comment_id" "$new_body"
    
    assert_success
    assert_output --partial "Comment updated successfully"
}

@test "update_github_comment: should handle non-existent comments" {
    set_github_mock_auth_state "true" "testuser"
    
    # Mock gh to return 404 for non-existent comment
    mock_command "gh" 'if [[ "$*" =~ comment.*update ]]; then echo "Comment not found" >&2; return 1; else mock_gh "$@"; fi'
    
    local comment_id="nonexistent"
    local new_body="Updated body"
    local github_url="https://github.com/testuser/test-repo/issues/123"
    
    run update_github_comment "$github_url" "$comment_id" "$new_body"
    
    assert_failure
    assert_output --partial "Comment not found"
}

# ===============================================================================
# COMMENT SEARCH AND MANAGEMENT TESTS
# ===============================================================================

@test "find_existing_task_comment: should find existing task comment" {
    set_github_mock_auth_state "true" "testuser"
    
    local github_url="https://github.com/testuser/test-repo/issues/123"
    local task_id="task-123"
    
    # Mock comment that contains task ID
    mock_command "gh" 'if [[ "$*" =~ comments ]]; then echo "[{\"id\": 1234567890, \"body\": \"Task ID: task-123\nSome content\", \"user\": {\"login\": \"claude-bot\"}}]"; else mock_gh "$@"; fi'
    
    run find_existing_task_comment "$github_url" "$task_id"
    
    assert_success
    assert_output "1234567890"  # Should return comment ID
}

@test "find_existing_task_comment: should handle no existing comments" {
    set_github_mock_auth_state "true" "testuser"
    
    local github_url="https://github.com/testuser/test-repo/issues/123"
    local task_id="task-nonexistent"
    
    # Mock empty comments response
    mock_command "gh" 'if [[ "$*" =~ comments ]]; then echo "[]"; else mock_gh "$@"; fi'
    
    run find_existing_task_comment "$github_url" "$task_id"
    
    assert_failure
}

@test "cleanup_old_task_comments: should remove outdated comments" {
    set_github_mock_auth_state "true" "testuser"
    
    local github_url="https://github.com/testuser/test-repo/issues/123"
    local current_task_id="task-current"
    
    # Mock old comments that should be cleaned up
    mock_command "gh" '
        if [[ "$*" =~ "api.*comments" && "$*" =~ "GET" ]]; then
            echo "[{\"id\": 111, \"body\": \"Task ID: task-old\", \"user\": {\"login\": \"claude-bot\"}}, {\"id\": 222, \"body\": \"Task ID: task-current\", \"user\": {\"login\": \"claude-bot\"}}]"
        elif [[ "$*" =~ "api.*comment.*111" && "$*" =~ DELETE ]]; then
            echo "Comment deleted"
        else
            mock_gh "$@"
        fi'
    
    run cleanup_old_task_comments "$github_url" "$current_task_id"
    
    assert_success
    assert_output --partial "Cleaned up"
}

# ===============================================================================
# BACKUP AND RESTORE TESTS
# ===============================================================================

@test "backup_progress_to_github: should create hidden backup comment" {
    set_github_mock_auth_state "true" "testuser"
    
    local github_url="https://github.com/testuser/test-repo/issues/123"
    local progress_data='{"task_id": "task-123", "progress": 50, "status": "in_progress"}'
    
    run backup_progress_to_github "$github_url" "$progress_data"
    
    assert_success
    assert_output --partial "Progress backup created"
    
    # Verify backup comment format
    local api_call_count=$(get_github_mock_api_call_count "api_.*comment.*POST")
    [[ $api_call_count -gt 0 ]]
}

@test "restore_progress_from_github: should restore from backup comment" {
    set_github_mock_auth_state "true" "testuser"
    
    local github_url="https://github.com/testuser/test-repo/issues/123"
    local task_id="task-123"
    
    # Mock backup comment
    local backup_data='{"task_id": "task-123", "progress": 75, "status": "in_progress", "timestamp": "2025-08-25T10:00:00Z"}'
    mock_command "gh" "
        if [[ \"\$*\" =~ comments ]]; then
            echo \"[{\\\"id\\\": 999, \\\"body\\\": \\\"<!-- CLAUDE_PROGRESS_BACKUP:$backup_data -->\\\", \\\"user\\\": {\\\"login\\\": \\\"claude-bot\\\"}}]\"
        else
            mock_gh \"\$@\"
        fi"
    
    run restore_progress_from_github "$github_url" "$task_id"
    
    assert_success
    assert_output --partial "task-123"
    assert_output --partial "75"
    assert_output --partial "in_progress"
}

@test "restore_progress_from_github: should handle missing backups" {
    set_github_mock_auth_state "true" "testuser"
    
    local github_url="https://github.com/testuser/test-repo/issues/123" 
    local task_id="task-nonexistent"
    
    # Mock no backup comments
    mock_command "gh" 'if [[ "$*" =~ comments ]]; then echo "[]"; else mock_gh "$@"; fi'
    
    run restore_progress_from_github "$github_url" "$task_id"
    
    assert_failure
    assert_output --partial "No backup found"
}

@test "cleanup_old_backups: should remove expired backup comments" {
    set_github_mock_auth_state "true" "testuser"
    
    local github_url="https://github.com/testuser/test-repo/issues/123"
    
    # Mock old backup comments (older than retention period)
    local old_timestamp=$(date -d '4 days ago' -u -Iseconds)
    local old_backup="{\"timestamp\": \"$old_timestamp\", \"task_id\": \"old-task\"}"
    
    mock_command "gh" "
        if [[ \"\$*\" =~ \"api.*comments\" && \"\$*\" =~ \"GET\" ]]; then
            echo \"[{\\\"id\\\": 888, \\\"body\\\": \\\"<!-- CLAUDE_PROGRESS_BACKUP:$old_backup -->\\\", \\\"user\\\": {\\\"login\\\": \\\"claude-bot\\\"}}]\"
        elif [[ \"\$*\" =~ \"api.*comment.*888\" && \"\$*\" =~ DELETE ]]; then
            echo \"Backup comment deleted\"
        else
            mock_gh \"\$@\"
        fi"
    
    run cleanup_old_backups "$github_url"
    
    assert_success
    assert_output --partial "Cleaned up expired backups"
}

# ===============================================================================
# ERROR HANDLING AND EDGE CASES
# ===============================================================================

@test "comment handling: should handle rate limiting gracefully" {
    set_github_mock_rate_limit 0  # Trigger rate limiting
    
    local github_url="https://github.com/testuser/test-repo/issues/123"
    local comment_body="Test comment"
    
    run post_github_comment "$github_url" "$comment_body"
    
    assert_failure
    assert_output --partial "rate limit"
}

@test "comment handling: should retry failed operations" {
    set_github_mock_auth_state "true" "testuser"
    
    # Mock command that fails first time, succeeds second time
    local call_count=0
    mock_command "gh" '
        if [[ "$*" =~ comment.*post ]]; then
            if [[ ${RETRY_COUNT:-0} -lt 1 ]]; then
                export RETRY_COUNT=$((${RETRY_COUNT:-0} + 1))
                echo "Network error" >&2
                return 1
            else
                echo "Comment posted successfully"
                return 0
            fi
        else
            mock_gh "$@"
        fi'
    
    local github_url="https://github.com/testuser/test-repo/issues/123"
    local comment_body="Test retry comment"
    
    run post_github_comment "$github_url" "$comment_body"
    
    assert_success
    assert_output --partial "Comment posted successfully"
}

@test "comment handling: should validate template variables" {
    load_comment_templates
    
    # Test with missing required variables
    local invalid_task_data='{
        "id": "task-123"
        # Missing title and other required fields
    }'
    
    run generate_task_start_comment "$invalid_task_data"
    
    assert_failure
    assert_output --partial "Missing required field"
}