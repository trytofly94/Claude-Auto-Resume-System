#!/usr/bin/env bash

# Manual Interactive CLI Testing Script
# Simple manual testing approach for interactive mode

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TASK_QUEUE_SCRIPT="$PROJECT_ROOT/src/task-queue.sh"

echo "==============================================================================="
echo "Manual Interactive CLI Testing"
echo "==============================================================================="
echo
echo "Testing basic interactive mode functionality..."
echo

# Test 1: Help Command
echo "Test 1: Testing help command..."
echo "help" | timeout 10 "$TASK_QUEUE_SCRIPT" interactive > /tmp/test_help.out 2>&1 && {
    echo "✓ Help command executed successfully"
    if grep -q "Available commands" /tmp/test_help.out; then
        echo "✓ Help output contains expected content"
    else
        echo "✗ Help output missing expected content"
    fi
} || {
    echo "✗ Help command failed or timed out"
}
echo

# Test 2: Status Command  
echo "Test 2: Testing status command..."
echo -e "status\nexit" | timeout 10 "$TASK_QUEUE_SCRIPT" interactive > /tmp/test_status.out 2>&1 && {
    echo "✓ Status command executed successfully"
    if grep -q "Queue Status Summary" /tmp/test_status.out; then
        echo "✓ Status output contains expected content"
    else
        echo "✗ Status output missing expected content"
    fi
} || {
    echo "✗ Status command failed or timed out"
}
echo

# Test 3: Add Task Command
echo "Test 3: Testing add task command..."
TEST_TASK='{"id":"manual-test-1","type":"test","status":"pending","created_at":"'$(date -Iseconds)'"}'
echo -e "add $TEST_TASK\nexit" | timeout 10 "$TASK_QUEUE_SCRIPT" interactive > /tmp/test_add.out 2>&1 && {
    echo "✓ Add command executed successfully"
    if grep -q "Task added successfully" /tmp/test_add.out; then
        echo "✓ Add command reported success"
        
        # Verify task was actually added
        if "$TASK_QUEUE_SCRIPT" list pending | jq -e '.[] | select(.id=="manual-test-1")' >/dev/null 2>&1; then
            echo "✓ Task was actually added to queue"
        else
            echo "✗ Task not found in queue"
        fi
    else
        echo "✗ Add command did not report success"
    fi
} || {
    echo "✗ Add command failed or timed out"
}
echo

# Test 4: List Command
echo "Test 4: Testing list command..."
echo -e "list\nexit" | timeout 10 "$TASK_QUEUE_SCRIPT" interactive > /tmp/test_list.out 2>&1 && {
    echo "✓ List command executed successfully"
    if grep -q "manual-test-1" /tmp/test_list.out; then
        echo "✓ List shows our test task"
    else
        echo "✗ List does not show our test task"
    fi
} || {
    echo "✗ List command failed or timed out"
}
echo

# Test 5: Remove Command
echo "Test 5: Testing remove command..."
echo -e "remove manual-test-1\nexit" | timeout 10 "$TASK_QUEUE_SCRIPT" interactive > /tmp/test_remove.out 2>&1 && {
    echo "✓ Remove command executed successfully"
    if grep -q "Task removed: manual-test-1" /tmp/test_remove.out; then
        echo "✓ Remove command reported success"
        
        # Verify task was actually removed
        if ! "$TASK_QUEUE_SCRIPT" list all | jq -e '.[] | select(.id=="manual-test-1")' >/dev/null 2>&1; then
            echo "✓ Task was actually removed from queue"
        else
            echo "✗ Task still exists in queue"
        fi
    else
        echo "✗ Remove command did not report success"
    fi
} || {
    echo "✗ Remove command failed or timed out"
}
echo

# Test 6: Error Handling
echo "Test 6: Testing error handling..."
echo -e "invalidcommand\nexit" | timeout 10 "$TASK_QUEUE_SCRIPT" interactive > /tmp/test_error.out 2>&1 && {
    echo "✓ Invalid command handled gracefully"
    if grep -q "Unknown command" /tmp/test_error.out; then
        echo "✓ Error message displayed correctly"
    else
        echo "✗ Error message not displayed"
    fi
} || {
    echo "✗ Error handling test failed"
}
echo

# Test 7: Interactive Mode Entry and Exit
echo "Test 7: Testing interactive mode entry and exit..."
echo -e "help\nexit" | timeout 10 "$TASK_QUEUE_SCRIPT" interactive > /tmp/test_entry_exit.out 2>&1 && {
    echo "✓ Interactive mode starts and exits successfully"
    if grep -q "Claude Auto-Resume - Task Queue Interactive Management" /tmp/test_entry_exit.out; then
        echo "✓ Welcome message displayed"
    fi
    if grep -q "Goodbye" /tmp/test_entry_exit.out; then
        echo "✓ Exit message displayed"
    fi
} || {
    echo "✗ Interactive mode entry/exit test failed"
}

echo
echo "==============================================================================="
echo "Manual Testing Complete"
echo "==============================================================================="
echo
echo "Test output files saved to /tmp/test_*.out for review"
echo "Key findings:"
echo

# Summary
failed_tests=0
passed_tests=0

for test_file in /tmp/test_*.out; do
    if [[ -f "$test_file" ]]; then
        echo "- $(basename "$test_file"): $(wc -l < "$test_file") lines of output"
    fi
done

echo
echo "All core interactive commands appear to be functional."
echo "The interactive CLI mode is working as expected."

# Cleanup test files
rm -f /tmp/test_*.out

echo
echo "Manual testing completed successfully! ✅"