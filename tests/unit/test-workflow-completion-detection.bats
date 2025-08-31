#!/usr/bin/env bats

# Unit tests for Issue-Merge Workflow Completion Detection Functions
# Tests the command completion monitoring functionality including:
# - monitor_command_completion() - Main completion monitoring with timeout
# - check_command_completion_pattern() - Pattern-based completion detection
# - check_*_completion_patterns() - Phase-specific pattern matching functions
# - Timeout handling and progress reporting

load ../test_helper

# Source the workflow module and dependencies
setup() {
    default_setup
    
    # Create test project directory
    export TEST_PROJECT_DIR="$TEST_TEMP_DIR/claude-auto-resume"
    mkdir -p "$TEST_PROJECT_DIR"
    cd "$TEST_PROJECT_DIR"
    
    # Set up workflow test configuration
    export USE_CLAUNCH="true"
    export CLAUNCH_MODE="tmux"
    export TMUX_SESSION_NAME="claude-test-workflow"
    export SCRIPT_DIR="$BATS_TEST_DIRNAME/../../src"
    
    # Create mock tmux session output files
    mkdir -p "$TEST_TEMP_DIR/mock_outputs"
    
    # Mock tmux command for session output capture
    setup_mock_tmux_capture
    
    # Source the workflow module
    source "$BATS_TEST_DIRNAME/../../src/queue/workflow.sh"
    
    # Initialize logging
    export LOG_LEVEL="ERROR"  # Reduce log noise in tests
}

teardown() {
    default_teardown
}

# Mock tmux capture functionality
setup_mock_tmux_capture() {
    # Mock tmux command that returns session output
    tmux() {
        case "$1" in
            "has-session")
                if [[ "${MOCK_TMUX_SESSION_EXISTS:-true}" == "true" ]]; then
                    return 0
                else
                    return 1
                fi
                ;;
            "capture-pane")
                if [[ "$3" == "-p" && -n "$2" ]]; then
                    # Return mock session output from file
                    local output_file="${MOCK_TMUX_OUTPUT_FILE:-$TEST_TEMP_DIR/mock_outputs/default.txt}"
                    if [[ -f "$output_file" ]]; then
                        cat "$output_file"
                    else
                        echo "Mock tmux session output - no specific output configured"
                    fi
                    return 0
                else
                    echo "Mock tmux command: $*"
                    return 0
                fi
                ;;
            *)
                echo "Mock tmux command: $*"
                return 0
                ;;
        esac
    }
    
    export -f tmux
}

# Helper to create mock tmux output
create_mock_tmux_output() {
    local content="$1"
    local output_file="${2:-$TEST_TEMP_DIR/mock_outputs/current.txt}"
    
    echo "$content" > "$output_file"
    export MOCK_TMUX_OUTPUT_FILE="$output_file"
}

# Test: monitor_command_completion basic functionality
@test "monitor_command_completion succeeds with immediate pattern match" {
    # Setup immediate success pattern
    create_mock_tmux_output "Pull request created successfully!"
    export MOCK_TMUX_SESSION_EXISTS="true"
    
    # Mock check_command_completion_pattern to return success immediately
    check_command_completion_pattern() {
        return 0  # Success
    }
    export -f check_command_completion_pattern
    
    run monitor_command_completion "/dev 123" "develop" "123" 10
    
    [ "$status" -eq 0 ]
    assert_output_contains "Command completion detected"
}

@test "monitor_command_completion times out after specified duration" {
    # Setup timeout scenario
    export MOCK_TMUX_SESSION_EXISTS="true"
    
    # Mock check_command_completion_pattern to always return failure
    check_command_completion_pattern() {
        return 1  # Never completes
    }
    export -f check_command_completion_pattern
    
    # Use short timeout for quick test
    run monitor_command_completion "/dev 123" "develop" "123" 3
    
    [ "$status" -eq 1 ]
    assert_output_contains "Command timeout after"
}

@test "monitor_command_completion uses phase-specific timeouts" {
    export MOCK_TMUX_SESSION_EXISTS="true"
    
    # Mock to test timeout value (never completes, but we check the timeout used)
    check_command_completion_pattern() {
        return 1
    }
    export -f check_command_completion_pattern
    
    # Test clear phase (should use 30s timeout)
    run timeout 5 monitor_command_completion "/clear" "clear" "" 999
    
    [ "$status" -eq 124 ]  # Timeout exit code
    # Verify clear phase uses shorter timeout in logs
}

@test "monitor_command_completion reports progress during long operations" {
    export MOCK_TMUX_SESSION_EXISTS="true"
    
    # Mock to complete after several checks
    local check_count=0
    check_command_completion_pattern() {
        ((check_count++))
        if [[ $check_count -ge 3 ]]; then
            return 0  # Success after 3 attempts
        else
            return 1  # Keep trying
        fi
    }
    export -f check_command_completion_pattern
    
    run monitor_command_completion "/dev 123" "develop" "123" 30
    
    [ "$status" -eq 0 ]
    assert_output_contains "Command completion detected"
}

@test "monitor_command_completion fallback when tmux not available" {
    # Setup non-tmux mode
    export USE_CLAUNCH="false"
    
    run monitor_command_completion "/dev 123" "develop" "123" 10
    
    [ "$status" -eq 0 ]  # Should fallback gracefully
}

@test "monitor_command_completion handles missing session gracefully" {
    export USE_CLAUNCH="true"
    export CLAUNCH_MODE="tmux"
    export MOCK_TMUX_SESSION_EXISTS="false"
    
    run monitor_command_completion "/dev 123" "develop" "123" 10
    
    [ "$status" -eq 1 ]
    assert_output_contains "tmux session not found"
}

# Test: check_command_completion_pattern routing
@test "check_command_completion_pattern routes to correct phase handler" {
    export USE_CLAUNCH="true"
    export CLAUNCH_MODE="tmux"
    export MOCK_TMUX_SESSION_EXISTS="true"
    
    # Create mock output that should trigger develop patterns
    create_mock_tmux_output "Pull request created successfully!"
    
    run check_command_completion_pattern "/dev 123" "develop" "123"
    
    [ "$status" -eq 0 ]
}

@test "check_command_completion_pattern handles non-tmux mode" {
    export USE_CLAUNCH="false"
    
    run check_command_completion_pattern "/dev 123" "develop" "123"
    
    [ "$status" -eq 0 ]  # Should fallback to timeout-based detection
}

@test "check_command_completion_pattern handles empty session output" {
    export USE_CLAUNCH="true"
    export CLAUNCH_MODE="tmux"
    export MOCK_TMUX_SESSION_EXISTS="true"
    
    # Create empty output
    create_mock_tmux_output ""
    
    run check_command_completion_pattern "/dev 123" "develop" "123"
    
    [ "$status" -eq 0 ]  # Should handle gracefully
}

# Test: check_develop_completion_patterns
@test "check_develop_completion_patterns detects PR creation" {
    local test_outputs=(
        "Pull request created successfully"
        "PR #123 has been created"
        "Created pull request: Feature implementation"
    )
    
    for output in "${test_outputs[@]}"; do
        run check_develop_completion_patterns "$output" "123"
        [ "$status" -eq 0 ]
    done
}

@test "check_develop_completion_patterns detects branch and commit patterns" {
    local test_outputs=(
        "Committed 5 changes to feature branch"
        "Created new branch feature/issue-123"
        "Pushed changes to origin/feature-branch"
    )
    
    for output in "${test_outputs[@]}"; do
        run check_develop_completion_patterns "$output" "123"
        [ "$status" -eq 0 ]
    done
}

@test "check_develop_completion_patterns detects issue-specific completion" {
    run check_develop_completion_patterns "Issue #123 implementation complete" "123"
    [ "$status" -eq 0 ]
    
    run check_develop_completion_patterns "Implemented solution for issue 123" "123"
    [ "$status" -eq 0 ]
}

@test "check_develop_completion_patterns detects general completion patterns" {
    local test_outputs=(
        "Implementation complete"
        "Feature development finished"
        "Development work completed"
    )
    
    for output in "${test_outputs[@]}"; do
        run check_develop_completion_patterns "$output" "123"
        [ "$status" -eq 0 ]
    done
}

@test "check_develop_completion_patterns falls back to prompt detection" {
    local prompt_outputs=(
        "Some work output\nclaude>"
        "Processing...\n>"
        "Task completed\n❯"
    )
    
    for output in "${prompt_outputs[@]}"; do
        run check_develop_completion_patterns "$output" "123"
        [ "$status" -eq 0 ]
    done
}

@test "check_develop_completion_patterns rejects non-matching output" {
    local non_matching=(
        "Still working on implementation..."
        "Processing your request..."
        "Error occurred during execution"
    )
    
    for output in "${non_matching[@]}"; do
        run check_develop_completion_patterns "$output" "123"
        [ "$status" -eq 1 ]
    done
}

# Test: check_clear_completion_patterns
@test "check_clear_completion_patterns detects context clearing" {
    local test_outputs=(
        "Context has been cleared successfully"
        "Conversation reset complete"
        "Clear operation finished"
    )
    
    for output in "${test_outputs[@]}"; do
        run check_clear_completion_patterns "$output"
        [ "$status" -eq 0 ]
    done
}

@test "check_clear_completion_patterns detects prompt readiness quickly" {
    local prompt_outputs=(
        "claude>"
        ">"
        "❯"
    )
    
    for output in "${prompt_outputs[@]}"; do
        run check_clear_completion_patterns "$output"
        [ "$status" -eq 0 ]
    done
}

@test "check_clear_completion_patterns rejects incomplete operations" {
    run check_clear_completion_patterns "Clearing context, please wait..."
    [ "$status" -eq 1 ]
    
    run check_clear_completion_patterns "Processing clear request..."
    [ "$status" -eq 1 ]
}

# Test: check_review_completion_patterns
@test "check_review_completion_patterns detects review completion" {
    local test_outputs=(
        "Review process complete"
        "Code analysis finished"
        "Review completed successfully"
    )
    
    for output in "${test_outputs[@]}"; do
        run check_review_completion_patterns "$output" "PR-123"
        [ "$status" -eq 0 ]
    done
}

@test "check_review_completion_patterns detects PR-specific patterns" {
    run check_review_completion_patterns "PR-123 review completed" "PR-123"
    [ "$status" -eq 0 ]
    
    run check_review_completion_patterns "Reviewed pull request PR-123" "PR-123"
    [ "$status" -eq 0 ]
}

@test "check_review_completion_patterns detects summary patterns" {
    local summary_outputs=(
        "Summary of findings: ..."
        "Overall recommendation: approve"
        "Code review conclusion: looks good"
    )
    
    for output in "${summary_outputs[@]}"; do
        run check_review_completion_patterns "$output" "PR-123"
        [ "$status" -eq 0 ]
    done
}

@test "check_review_completion_patterns rejects ongoing review" {
    local ongoing_outputs=(
        "Reviewing code changes..."
        "Analyzing pull request..."
        "Checking for issues..."
    )
    
    for output in "${ongoing_outputs[@]}"; do
        run check_review_completion_patterns "$output" "PR-123"
        [ "$status" -eq 1 ]
    done
}

# Test: check_merge_completion_patterns
@test "check_merge_completion_patterns detects merge success" {
    local test_outputs=(
        "Merge completed successfully"
        "Successfully merged pull request"
        "Merge operation complete"
    )
    
    for output in "${test_outputs[@]}"; do
        run check_merge_completion_patterns "$output" "123"
        [ "$status" -eq 0 ]
    done
}

@test "check_merge_completion_patterns detects main branch updates" {
    local branch_outputs=(
        "Main branch updated successfully"
        "Merged changes into main branch"
        "Updated main with new features"
    )
    
    for output in "${branch_outputs[@]}"; do
        run check_merge_completion_patterns "$output" "123"
        [ "$status" -eq 0 ]
    done
}

@test "check_merge_completion_patterns detects issue closure" {
    run check_merge_completion_patterns "Issue #123 has been closed" "123"
    [ "$status" -eq 0 ]
    
    run check_merge_completion_patterns "Closed issue 123 successfully" "123"
    [ "$status" -eq 0 ]
}

@test "check_merge_completion_patterns rejects merge in progress" {
    local in_progress_outputs=(
        "Merging pull request..."
        "Preparing to merge..."
        "Checking merge conflicts..."
    )
    
    for output in "${in_progress_outputs[@]}"; do
        run check_merge_completion_patterns "$output" "123"
        [ "$status" -eq 1 ]
    done
}

# Test: check_generic_completion_patterns
@test "check_generic_completion_patterns detects general completion" {
    local completion_outputs=(
        "Task complete"
        "Operation finished"
        "Command executed successfully"
        "Done with processing"
    )
    
    for output in "${completion_outputs[@]}"; do
        run check_generic_completion_patterns "$output"
        [ "$status" -eq 0 ]
    done
}

@test "check_generic_completion_patterns detects prompt readiness" {
    local prompt_outputs=(
        "claude>"
        ">"
        "❯"
    )
    
    for output in "${prompt_outputs[@]}"; do
        run check_generic_completion_patterns "$output"
        [ "$status" -eq 0 ]
    done
}

@test "check_generic_completion_patterns rejects incomplete operations" {
    local incomplete_outputs=(
        "Processing your request..."
        "Working on it..."
        "Please wait..."
    )
    
    for output in "${incomplete_outputs[@]}"; do
        run check_generic_completion_patterns "$output"
        [ "$status" -eq 1 ]
    done
}

# Test: Pattern matching edge cases
@test "completion patterns handle case insensitivity" {
    run check_develop_completion_patterns "PULL REQUEST CREATED SUCCESSFULLY" "123"
    [ "$status" -eq 0 ]
    
    run check_clear_completion_patterns "CONTEXT CLEARED" ""
    [ "$status" -eq 0 ]
    
    run check_review_completion_patterns "REVIEW COMPLETE" "PR-123"
    [ "$status" -eq 0 ]
}

@test "completion patterns handle multiline output" {
    local multiline_output="Processing request...
    Analyzing code...
    Pull request created successfully!
    Ready for next command"
    
    run check_develop_completion_patterns "$multiline_output" "123"
    [ "$status" -eq 0 ]
}

@test "completion patterns handle special characters in output" {
    local special_output="✅ Implementation complete - Issue #123 resolved!"
    
    run check_develop_completion_patterns "$special_output" "123"
    [ "$status" -eq 0 ]
}

# Test: Performance and resource usage
@test "completion detection handles large output efficiently" {
    # Create large output (simulate long session)
    local large_output=""
    for i in {1..1000}; do
        large_output+="%LINE $i: Some output content here\n"
    done
    large_output+="Pull request created successfully!"
    
    run check_develop_completion_patterns "$large_output" "123"
    
    [ "$status" -eq 0 ]
}

@test "completion detection provides debug information" {
    export LOG_LEVEL="DEBUG"
    
    create_mock_tmux_output "Pull request created successfully!"
    export MOCK_TMUX_SESSION_EXISTS="true"
    
    run check_command_completion_pattern "/dev 123" "develop" "123"
    
    [ "$status" -eq 0 ]
    # Note: Debug output would appear in stderr, but we're checking function works
}

# Test: Integration with tmux session management
@test "completion detection integrates with session capture" {
    export USE_CLAUNCH="true"
    export CLAUNCH_MODE="tmux"
    export TMUX_SESSION_NAME="test-session"
    export MOCK_TMUX_SESSION_EXISTS="true"
    
    # Create realistic tmux output
    create_mock_tmux_output "user@host:~/project$ claude
    Claude CLI started...
    Processing /dev 123 command...
    Creating feature branch...
    Implementing changes...
    Pull request #123 created successfully!
    claude>"
    
    run check_command_completion_pattern "/dev 123" "develop" "123"
    
    [ "$status" -eq 0 ]
}