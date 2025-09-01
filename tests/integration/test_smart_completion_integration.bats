#!/usr/bin/env bats

# Integration Tests for Smart Task Completion Detection (Issue #90)  
# Tests end-to-end workflow with completion detection in real scenarios

load "../test_helper"

# Setup test environment
setup() {
    # Create isolated test environment
    export TEST_DIR="$(mktemp -d)"
    export CLAUDE_INSTALLATION_DIR="$TEST_DIR"
    export CLAUDE_SRC_DIR="$TEST_DIR/src"
    export CLAUDE_CONFIG_DIR="$TEST_DIR/config"
    export CLAUDE_LOGS_DIR="$TEST_DIR/logs"
    export TASK_QUEUE_DIR="$TEST_DIR/queue"
    
    mkdir -p "$CLAUDE_SRC_DIR" "$CLAUDE_CONFIG_DIR" "$CLAUDE_LOGS_DIR" "$TASK_QUEUE_DIR"
    
    # Copy source files
    cp -r "$BATS_TEST_DIRNAME/../../src/"*.sh "$CLAUDE_SRC_DIR/"
    cp -r "$BATS_TEST_DIRNAME/../../src/queue" "$CLAUDE_SRC_DIR/"
    cp -r "$BATS_TEST_DIRNAME/../../src/utils" "$CLAUDE_SRC_DIR/"
    cp "$BATS_TEST_DIRNAME/../../config/default.conf" "$CLAUDE_CONFIG_DIR/"
    
    # Initialize empty queue
    echo '{"tasks": [], "metadata": {"created": "'$(date -Iseconds)'", "version": "2.0.0"}}' > "$TASK_QUEUE_DIR/queue.json"
    
    # Configure for testing
    export SMART_COMPLETION_ENABLED=true
    export COMPLETION_CONFIDENCE_THRESHOLD=0.8
    export FALLBACK_STRATEGY=timeout
    export USE_CLAUNCH=false  # Disable tmux for unit testing
    
    # Load modules
    source "$CLAUDE_SRC_DIR/task-queue.sh"
}

# Cleanup test environment
teardown() {
    rm -rf "$TEST_DIR"
}

# Test end-to-end task creation with completion markers
@test "add-custom command creates task with auto-generated completion marker" {
    cd "$TEST_DIR"
    
    run ./src/task-queue.sh add-custom "Fix authentication bug"
    
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Custom task added:" ]]
    [[ "$output" =~ "Completion marker:" ]]
    
    # Verify task was saved with marker
    local queue_content=$(cat "$TASK_QUEUE_DIR/queue.json")
    echo "$queue_content" | jq -e '.tasks[0].completion_marker'
}

@test "add-custom command with explicit completion marker" {
    cd "$TEST_DIR"
    
    run ./src/task-queue.sh add-custom "Deploy to production" --completion-marker "DEPLOY_COMPLETE_123"
    
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Completion marker: DEPLOY_COMPLETE_123" ]]
    
    # Verify specific marker was used
    local queue_content=$(cat "$TASK_QUEUE_DIR/queue.json")
    local stored_marker=$(echo "$queue_content" | jq -r '.tasks[0].completion_marker')
    [ "$stored_marker" = "DEPLOY_COMPLETE_123" ]
}

@test "add-custom command with custom completion patterns" {
    cd "$TEST_DIR"
    
    run ./src/task-queue.sh add-custom "Review code changes" \
        --completion-pattern "Code review complete" \
        --completion-pattern "All checks passed"
    
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Custom patterns: 2 pattern(s)" ]]
    
    # Verify patterns were stored
    local queue_content=$(cat "$TASK_QUEUE_DIR/queue.json")
    local pattern_count=$(echo "$queue_content" | jq '.tasks[0].completion_patterns | length')
    [ "$pattern_count" -eq 2 ]
}

@test "add-custom command with timeout override" {
    cd "$TEST_DIR"
    
    run ./src/task-queue.sh add-custom "Long running task" --completion-timeout 1800
    
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Custom timeout: 1800s" ]]
    
    # Verify timeout was stored
    local queue_content=$(cat "$TASK_QUEUE_DIR/queue.json")
    local timeout=$(echo "$queue_content" | jq -r '.tasks[0].custom_timeout')
    [ "$timeout" = "1800" ]
}

@test "add-issue command creates task with issue-specific marker" {
    cd "$TEST_DIR"
    
    # Mock gh command for testing
    cat > gh <<'EOF'
#!/bin/bash
echo '{"title": "Fix login bug", "body": "User authentication not working", "state": "open"}'
EOF
    chmod +x gh
    export PATH="$PWD:$PATH"
    
    run ./src/task-queue.sh add-issue 123
    
    [ "$status" -eq 0 ]
    
    # Verify issue-specific marker pattern
    local queue_content=$(cat "$TASK_QUEUE_DIR/queue.json")
    local marker=$(echo "$queue_content" | jq -r '.tasks[0].completion_marker')
    [[ "$marker" =~ ^ISSUE_.*_[0-9]+$ ]]
}

# Test smart completion detection workflow
@test "monitor_smart_completion handles task with completion marker" {
    cd "$TEST_DIR"
    source "$CLAUDE_SRC_DIR/queue/workflow.sh"
    
    # Create task with known marker
    ./src/task-queue.sh add-custom "Test task" --completion-marker "TEST_MARKER_999" >/dev/null
    
    # Get task ID from queue
    local task_id=$(cat "$TASK_QUEUE_DIR/queue.json" | jq -r '.tasks[0].id')
    
    # Mock session output that includes completion marker
    export TMUX_SESSION_NAME="test-session"
    export USE_CLAUNCH=true
    export CLAUNCH_MODE=tmux
    
    # Create mock tmux command that returns completion text
    cat > tmux <<'EOF'
#!/bin/bash
case "$1 $2" in
    "has-session -t")
        exit 0  # Session exists
        ;;
    "capture-pane -t")
        echo "Task output"
        echo "###TASK_COMPLETE:TEST_MARKER_999###"
        echo "More output"
        ;;
esac
EOF
    chmod +x tmux
    export PATH="$PWD:$PATH"
    
    # Test smart completion monitoring (should detect completion quickly)
    timeout 10 run monitor_smart_completion "$task_id" "test command" "custom" 30
    
    [ "$status" -eq 0 ]  # Should complete successfully
}

@test "monitor_smart_completion falls back to timeout when no patterns match" {
    cd "$TEST_DIR"
    source "$CLAUDE_SRC_DIR/queue/workflow.sh"
    
    # Create task with specific marker
    ./src/task-queue.sh add-custom "Test task" --completion-marker "NEVER_FOUND_MARKER" >/dev/null
    
    local task_id=$(cat "$TASK_QUEUE_DIR/queue.json" | jq -r '.tasks[0].id')
    
    # Mock session output without completion marker
    export TMUX_SESSION_NAME="test-session"
    export USE_CLAUNCH=true
    export CLAUNCH_MODE=tmux
    
    cat > tmux <<'EOF'
#!/bin/bash
case "$1 $2" in
    "has-session -t")
        exit 0
        ;;
    "capture-pane -t")
        echo "Task is running but not complete yet"
        ;;
esac
EOF
    chmod +x tmux
    export PATH="$PWD:$PATH"
    
    # Set short timeout and timeout fallback strategy
    export FALLBACK_STRATEGY=timeout
    
    # Should timeout quickly and fall back to timeout completion
    timeout 15 run monitor_smart_completion "$task_id" "test command" "custom" 5
    
    [ "$status" -eq 0 ]  # Should succeed via fallback
}

# Test fallback mechanisms
@test "interactive fallback prompts user for confirmation" {
    cd "$TEST_DIR"
    source "$CLAUDE_SRC_DIR/completion-fallback.sh"
    
    # Create test task
    ./src/task-queue.sh add-custom "Test interactive task" >/dev/null
    local task_id=$(cat "$TASK_QUEUE_DIR/queue.json" | jq -r '.tasks[0].id')
    
    export FALLBACK_STRATEGY=interactive
    
    # Mock user input (simulate "yes" response)
    echo "y" | run prompt_completion_confirmation "$task_id"
    
    [ "$status" -eq 0 ]
}

@test "timeout-based completion calculation considers task complexity" {
    source "$CLAUDE_SRC_DIR/completion-fallback.sh"
    
    # Simple task
    run calculate_task_timeout "custom" "Fix typo" ""
    simple_timeout="$output"
    
    # Complex task
    run calculate_task_timeout "custom" "Implement comprehensive authentication system with OAuth2 integration, database migrations, and full test coverage" ""
    complex_timeout="$output"
    
    # Complex task should have longer timeout
    [ "$complex_timeout" -gt "$simple_timeout" ]
}

# Test configuration integration
@test "smart completion respects SMART_COMPLETION_ENABLED=false" {
    cd "$TEST_DIR"
    export SMART_COMPLETION_ENABLED=false
    
    run ./src/task-queue.sh add-custom "Test task with completion disabled"
    
    [ "$status" -eq 0 ]
    [[ ! "$output" =~ "Completion marker:" ]]
    
    # Verify no marker was generated
    local queue_content=$(cat "$TASK_QUEUE_DIR/queue.json")
    local marker=$(echo "$queue_content" | jq -r '.tasks[0].completion_marker // "null"')
    [ "$marker" = "null" ]
}

@test "configuration values are loaded from default.conf" {
    cd "$TEST_DIR"
    source "$CLAUDE_SRC_DIR/completion-prompts.sh"
    
    # Modify config
    echo "COMPLETION_CONFIDENCE_THRESHOLD=0.9" >> "$CLAUDE_CONFIG_DIR/default.conf"
    
    # Reload configuration
    load_completion_config
    
    [ "$COMPLETION_CONFIDENCE_THRESHOLD" = "0.9" ]
}

# Test error handling and edge cases
@test "invalid completion marker flag shows error" {
    cd "$TEST_DIR"
    
    run ./src/task-queue.sh add-custom "Test task" --completion-marker
    
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Error:" ]]
}

@test "invalid completion timeout shows error" {
    cd "$TEST_DIR"
    
    run ./src/task-queue.sh add-custom "Test task" --completion-timeout "not-a-number"
    
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Error:" ]]
}

@test "task with missing completion marker falls back to standard detection" {
    cd "$TEST_DIR"
    source "$CLAUDE_SRC_DIR/queue/workflow.sh"
    
    # Create task without completion marker (disable auto-generation)
    export SMART_COMPLETION_ENABLED=false
    ./src/task-queue.sh add-custom "Test task" >/dev/null
    export SMART_COMPLETION_ENABLED=true
    
    local task_id=$(cat "$TASK_QUEUE_DIR/queue.json" | jq -r '.tasks[0].id')
    
    # Mock standard completion detection
    monitor_command_completion() {
        echo "Falling back to standard detection"
        return 0
    }
    export -f monitor_command_completion
    
    run monitor_smart_completion "$task_id" "test command" "custom" 30
    
    [ "$status" -eq 0 ]
}

# Test multiple tasks and marker uniqueness
@test "multiple tasks generate unique completion markers" {
    cd "$TEST_DIR"
    
    # Create multiple tasks
    ./src/task-queue.sh add-custom "Task 1" >/dev/null
    ./src/task-queue.sh add-custom "Task 2" >/dev/null
    ./src/task-queue.sh add-custom "Task 3" >/dev/null
    
    # Extract all markers
    local queue_content=$(cat "$TASK_QUEUE_DIR/queue.json")
    local marker1=$(echo "$queue_content" | jq -r '.tasks[0].completion_marker')
    local marker2=$(echo "$queue_content" | jq -r '.tasks[1].completion_marker')
    local marker3=$(echo "$queue_content" | jq -r '.tasks[2].completion_marker')
    
    # Verify all markers are different
    [ "$marker1" != "$marker2" ]
    [ "$marker2" != "$marker3" ]
    [ "$marker1" != "$marker3" ]
}

# Test performance and resource usage
@test "smart completion detection does not significantly impact performance" {
    cd "$TEST_DIR"
    source "$CLAUDE_SRC_DIR/queue/workflow.sh"
    
    # Create task
    ./src/task-queue.sh add-custom "Performance test task" --completion-marker "PERF_TEST_123" >/dev/null
    local task_id=$(cat "$TASK_QUEUE_DIR/queue.json" | jq -r '.tasks[0].id')
    
    # Mock quick completion
    export USE_CLAUNCH=true
    export CLAUNCH_MODE=tmux
    cat > tmux <<'EOF'
#!/bin/bash
case "$1 $2" in
    "has-session -t") exit 0 ;;
    "capture-pane -t") echo "###TASK_COMPLETE:PERF_TEST_123###" ;;
esac
EOF
    chmod +x tmux
    export PATH="$PWD:$PATH"
    
    # Time the completion detection
    local start_time=$(date +%s)
    timeout 30 monitor_smart_completion "$task_id" "test command" "custom" 30
    local end_time=$(date +%s)
    local elapsed=$((end_time - start_time))
    
    # Should complete quickly (within 10 seconds)
    [ "$elapsed" -lt 10 ]
}