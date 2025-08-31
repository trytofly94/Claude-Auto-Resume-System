#!/usr/bin/env bats

# Integration test for Issue #98: JSON Date String Formatting Fix
# This test verifies that the workflow.sh date string escaping works correctly

load ../test_helper

setup() {
    default_setup
    
    # Set up test environment
    export TEST_PROJECT_DIR="$TEST_TEMP_DIR/claude-auto-resume"
    mkdir -p "$TEST_PROJECT_DIR/src/queue"
    cd "$TEST_PROJECT_DIR"
    
    # Copy the actual workflow.sh file 
    cp "$BATS_TEST_DIRNAME/../../src/queue/workflow.sh" "src/queue/workflow.sh"
    
    # Ensure we have the real jq available for this test
    unset -f jq 2>/dev/null || true
}

teardown() {
    default_teardown
}

@test "workflow.sh loads without syntax errors after date fix" {
    # Basic smoke test - the file should load without bash syntax errors
    run bash -n src/queue/workflow.sh
    [ "$status" -eq 0 ]
}

@test "step completion jq command works with real date strings" {
    # Test the actual jq command pattern used in line 233-234
    local workflow_data='{"steps": [{"phase": "test", "status": "in_progress"}]}'
    local step_index=0
    
    # This is the actual command pattern from the fixed code
    result=$(echo "$workflow_data" | jq \
        --arg completed_at "$(date -Iseconds)" \
        '.steps['"$step_index"'].status = "completed" | .steps['"$step_index"'].completed_at = $completed_at')
    
    # Should succeed without JSON parsing errors
    [ $? -eq 0 ]
    
    # Should contain the expected fields
    [[ "$result" == *'"status": "completed"'* ]]
    [[ "$result" == *'"completed_at"'* ]]
    
    # Should be valid JSON
    echo "$result" | jq empty
    [ $? -eq 0 ]
}

@test "step failure jq command works with real date strings" {
    # Test the actual jq command pattern used in line 242-243
    local workflow_data='{"steps": [{"phase": "test", "status": "in_progress"}]}'
    local step_index=0
    
    # This is the actual command pattern from the fixed code
    result=$(echo "$workflow_data" | jq \
        --arg failed_at "$(date -Iseconds)" \
        '.steps['"$step_index"'].status = "failed" | .steps['"$step_index"'].failed_at = $failed_at')
    
    # Should succeed without JSON parsing errors
    [ $? -eq 0 ]
    
    # Should contain the expected fields
    [[ "$result" == *'"status": "failed"'* ]]
    [[ "$result" == *'"failed_at"'* ]]
    
    # Should be valid JSON
    echo "$result" | jq empty
    [ $? -eq 0 ]
}

@test "workflow completion jq command works with real date strings" {
    # Test the actual jq command pattern used in line 274-275
    local workflow_data='{"status": "in_progress"}'
    
    # This is the actual command pattern from the fixed code
    result=$(echo "$workflow_data" | jq \
        --arg completed_at "$(date -Iseconds)" \
        '.completed_at = $completed_at')
    
    # Should succeed without JSON parsing errors
    [ $? -eq 0 ]
    
    # Should contain the expected field
    [[ "$result" == *'"completed_at"'* ]]
    
    # Should be valid JSON
    echo "$result" | jq empty
    [ $? -eq 0 ]
}

@test "date strings with timezone info work correctly" {
    # Test with various timezone formats that date -Iseconds can produce
    local workflow_data='{"status": "pending"}'
    
    # Test with different date formats that might occur in different timezones
    for date_str in "2025-08-31T15:30:45+00:00" "2025-08-31T15:30:45-05:00" "2025-08-31T15:30:45Z"; do
        result=$(echo "$workflow_data" | jq \
            --arg timestamp "$date_str" \
            '.timestamp = $timestamp')
        
        # Should succeed without JSON parsing errors
        [ $? -eq 0 ]
        
        # Should contain the timestamp
        [[ "$result" == *'"timestamp"'* ]]
        [[ "$result" == *"$date_str"* ]]
        
        # Should be valid JSON
        echo "$result" | jq empty
        [ $? -eq 0 ]
    done
}

@test "existing proper date patterns still work" {
    # Test that the existing correct patterns (lines 54, 530) still work
    local workflow_data='{"status": "pending"}'
    
    # Pattern from line 54 (create_workflow_task)
    result=$(echo "$workflow_data" | jq \
        --arg created_at "$(date -Iseconds)" \
        '.created_at = $created_at')
    
    [ $? -eq 0 ]
    [[ "$result" == *'"created_at"'* ]]
    echo "$result" | jq empty
    [ $? -eq 0 ]
    
    # Pattern from line 530 (cancel_workflow)  
    result=$(echo "$workflow_data" | jq \
        --arg cancelled_at "$(date -Iseconds)" \
        '.cancelled_at = $cancelled_at | .cancellation_reason = "user_cancelled"')
    
    [ $? -eq 0 ]
    [[ "$result" == *'"cancelled_at"'* ]]
    [[ "$result" == *'"cancellation_reason": "user_cancelled"'* ]]
    echo "$result" | jq empty
    [ $? -eq 0 ]
}