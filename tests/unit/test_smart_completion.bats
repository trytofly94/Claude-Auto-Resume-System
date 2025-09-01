#!/usr/bin/env bats

# Test Smart Task Completion Detection (Issue #90)
# Unit tests for completion marker generation, pattern matching, and CLI integration

load "../test_helper"

# Setup test environment
setup() {
    # Create test directories
    export TEST_DIR="$(mktemp -d)"
    export CLAUDE_INSTALLATION_DIR="$TEST_DIR"
    export CLAUDE_SRC_DIR="$TEST_DIR/src"
    export CLAUDE_CONFIG_DIR="$TEST_DIR/config"
    export TASK_QUEUE_DIR="$TEST_DIR/queue"
    
    mkdir -p "$CLAUDE_SRC_DIR" "$CLAUDE_CONFIG_DIR" "$TASK_QUEUE_DIR"
    
    # Copy source files for testing
    cp -r "$BATS_TEST_DIRNAME/../../src/"*.sh "$CLAUDE_SRC_DIR/"
    cp -r "$BATS_TEST_DIRNAME/../../src/queue" "$CLAUDE_SRC_DIR/"
    cp -r "$BATS_TEST_DIRNAME/../../src/utils" "$CLAUDE_SRC_DIR/"
    cp "$BATS_TEST_DIRNAME/../../config/default.conf" "$CLAUDE_CONFIG_DIR/"
    
    # Source the modules
    source "$CLAUDE_SRC_DIR/completion-prompts.sh"
    source "$CLAUDE_SRC_DIR/completion-fallback.sh"
    source "$CLAUDE_SRC_DIR/queue/core.sh"
    
    # Enable smart completion for tests
    export SMART_COMPLETION_ENABLED=true
    export COMPLETION_CONFIDENCE_THRESHOLD=0.8
}

# Cleanup test environment
teardown() {
    rm -rf "$TEST_DIR"
}

# Test completion marker generation
@test "generate_completion_marker creates valid markers" {
    run generate_completion_marker "Fix login bug" "custom"
    
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^TASK_[A-Z0-9_]+_[0-9]+$ ]]
}

@test "generate_completion_marker handles different task types" {
    # Test github issue type
    run generate_completion_marker "Fix authentication" "github_issue"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^ISSUE_[A-Z0-9_]+_[0-9]+$ ]]
    
    # Test github PR type
    run generate_completion_marker "Review pull request" "github_pr"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^PR_[A-Z0-9_]+_[0-9]+$ ]]
    
    # Test workflow type
    run generate_completion_marker "Deploy application" "workflow"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^WORKFLOW_[A-Z0-9_]+_[0-9]+$ ]]
}

@test "validate_completion_marker accepts valid formats" {
    run validate_completion_marker "TASK_LOGIN_BUG_FIX_1725202800"
    [ "$status" -eq 0 ]
    
    run validate_completion_marker "ISSUE_AUTH_PROBLEM_1725202800"
    [ "$status" -eq 0 ]
}

@test "validate_completion_marker rejects invalid formats" {
    run validate_completion_marker "invalid_marker"
    [ "$status" -eq 1 ]
    
    run validate_completion_marker "TASK_123"
    [ "$status" -eq 1 ]
}

# Test completion pattern generation
@test "get_default_completion_patterns generates appropriate patterns" {
    run get_default_completion_patterns "dev" "TASK_LOGIN_FIX_123"
    
    [ "$status" -eq 0 ]
    [[ "$output" =~ "###TASK_COMPLETE:TASK_LOGIN_FIX_123###" ]]
    [[ "$output" =~ "Task completed successfully" ]]
}

@test "get_default_completion_patterns handles review tasks" {
    run get_default_completion_patterns "review" "REVIEW_CODE_123"
    
    [ "$status" -eq 0 ]
    [[ "$output" =~ "###REVIEW_COMPLETE:REVIEW_CODE_123###" ]]
    [[ "$output" =~ "Code review completed" ]]
}

@test "parse_custom_patterns handles various input formats" {
    run parse_custom_patterns "pattern1,pattern2;pattern3"
    
    [ "$status" -eq 0 ]
    [[ "$output" =~ "pattern1|pattern2|pattern3" ]]
}

# Test completion detection
@test "test_completion_match detects exact marker matches" {
    local test_text="Some output\n###TASK_COMPLETE:TEST_MARKER_123###\nMore output"
    local patterns="###TASK_COMPLETE:TEST_MARKER_123###|Task completed"
    
    run test_completion_match "$test_text" "$patterns" "0.5"
    [ "$status" -eq 0 ]
}

@test "test_completion_match handles confidence thresholds" {
    local test_text="Task completed successfully"
    local patterns="###TASK_COMPLETE:MARKER###|Task completed|Work finished|Done"
    
    # Should pass with low threshold
    run test_completion_match "$test_text" "$patterns" "0.2"
    [ "$status" -eq 0 ]
    
    # Should fail with high threshold (only 1 of 4 patterns match)
    run test_completion_match "$test_text" "$patterns" "0.9"
    [ "$status" -eq 1 ]
}

@test "extract_completion_marker extracts valid markers" {
    local test_text="Output\n###TASK_COMPLETE:EXTRACTED_MARKER_123###\nMore"
    
    run extract_completion_marker "$test_text"
    [ "$status" -eq 0 ]
    [ "$output" = "EXTRACTED_MARKER_123" ]
}

# Test CLI flag parsing
@test "parse_completion_flags handles completion marker flag" {
    run parse_completion_flags --completion-marker "TEST_MARKER_123"
    
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.completion_marker == "TEST_MARKER_123"'
}

@test "parse_completion_flags handles multiple completion patterns" {
    run parse_completion_flags --completion-pattern "pattern1" --completion-pattern "pattern2"
    
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.completion_patterns | length == 2'
    echo "$output" | jq -e '.completion_patterns[0] == "pattern1"'
    echo "$output" | jq -e '.completion_patterns[1] == "pattern2"'
}

@test "parse_completion_flags handles timeout flag" {
    run parse_completion_flags --completion-timeout 600
    
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.custom_timeout == 600'
}

@test "parse_completion_flags rejects invalid timeout" {
    run parse_completion_flags --completion-timeout "invalid"
    
    [ "$status" -eq 1 ]
}

@test "parse_enhanced_flags combines completion and context flags" {
    source "$CLAUDE_SRC_DIR/utils/cli-parser.sh"
    
    run parse_enhanced_flags --completion-marker "TEST_123" --clear-context
    
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.completion_marker == "TEST_123"'
    echo "$output" | jq -e '.clear_context == true'
}

# Test task creation with completion markers
@test "task creation includes completion markers when enabled" {
    source "$CLAUDE_SRC_DIR/utils/cli-parser.sh"
    
    # Mock generate_task_id function
    generate_task_id() { echo "test_task_123"; }
    export -f generate_task_id
    
    run create_task_with_context_options "custom" "Test task" --completion-marker "CUSTOM_MARKER_123"
    
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.completion_marker == "CUSTOM_MARKER_123"'
}

# Test fallback mechanism
@test "calculate_task_timeout adjusts timeout based on task type" {
    run calculate_task_timeout "dev" "Simple bug fix" ""
    
    [ "$status" -eq 0 ]
    timeout1="$output"
    
    run calculate_task_timeout "dev" "Implement complex feature with database migrations and API changes" ""
    
    [ "$status" -eq 0 ]
    timeout2="$output"
    
    # Complex task should have longer timeout
    [ "$timeout2" -gt "$timeout1" ]
}

@test "calculate_task_timeout respects custom timeout" {
    run calculate_task_timeout "dev" "Any task" 1800
    
    [ "$status" -eq 0 ]
    [ "$output" -eq 1800 ]
}

# Test integration with core queue system
@test "add_task stores completion markers in global arrays" {
    source "$CLAUDE_SRC_DIR/utils/cli-parser.sh"
    
    # Initialize task arrays
    declare -gA TASK_COMPLETION_MARKERS=()
    declare -gA TASK_COMPLETION_PATTERNS=()
    
    # Mock generate_task_id function
    generate_task_id() { echo "test_task_456"; }
    export -f generate_task_id
    
    # Create task with completion marker
    local task_json
    task_json=$(create_task_with_context_options "custom" "Test task" --completion-marker "TEST_MARKER_456")
    
    # Add task to queue
    run add_task "$task_json"
    [ "$status" -eq 0 ]
    
    # Verify marker was stored
    [ "${TASK_COMPLETION_MARKERS[test_task_456]}" = "TEST_MARKER_456" ]
}

# Test configuration loading
@test "load_completion_config sets default values" {
    unset SMART_COMPLETION_ENABLED
    unset COMPLETION_CONFIDENCE_THRESHOLD
    
    run load_completion_config
    
    [ "$status" -eq 0 ]
    [ "$SMART_COMPLETION_ENABLED" = "true" ]
    [ "$COMPLETION_CONFIDENCE_THRESHOLD" = "0.8" ]
}

# Test error handling
@test "completion functions handle missing dependencies gracefully" {
    # Test without bc command (confidence calculation)
    PATH="/dev/null" run test_completion_match "text" "pattern" "0.5"
    [ "$status" -eq 1 ]  # Should fail gracefully
}

@test "completion marker generation is unique" {
    # Generate multiple markers and check uniqueness
    local markers=()
    for i in {1..5}; do
        marker=$(generate_completion_marker "Test task $i" "custom")
        markers+=("$marker")
        sleep 1  # Ensure different timestamps
    done
    
    # Check all markers are different
    local unique_count=$(printf '%s\n' "${markers[@]}" | sort -u | wc -l)
    [ "$unique_count" -eq 5 ]
}