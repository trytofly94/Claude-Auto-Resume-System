# Test Development Best Practices

**Document Version**: 1.0  
**Created**: 2025-08-30  
**Target Audience**: Developers contributing to Claude Auto-Resume  
**Related**: Issue #84 - Test Suite Reliability Improvements

---

## Overview

This document establishes best practices for developing reliable, maintainable tests in the Claude Auto-Resume project. These guidelines are based on lessons learned from comprehensive test suite reliability improvements.

## Core Principles

### 1. Test Reliability First
- **Every test must complete within 5 seconds** (individual test timeout)
- **Tests must be deterministic** - same input produces same output every time
- **Tests must not depend on external network access** unless specifically testing network functionality
- **Tests must clean up all resources** - no lingering processes or files
- **Tests must not affect global state** beyond their test scope

### 2. BATS-Specific Guidelines

#### Array Persistence Challenges
**Problem**: Bash associative arrays don't persist across BATS subprocess boundaries

**Solutions**:
```bash
# ✅ GOOD: Use BATS-safe array operations
bats_safe_array_operation "set" "TASK_STATES" "$task_id" "$state"
result=$(bats_safe_array_operation "get" "TASK_STATES" "$task_id")

# ❌ AVOID: Direct array access in subprocess contexts
TASK_STATES["$task_id"]="$state"  # May not persist
```

#### State Management Pattern
```bash
@test "example test with state management" {
    # Initialize test
    test_init_task_queue
    
    # Save state before subprocess operations
    bats_safe_array_operation "sync_from_array" "TASK_STATES"
    
    # Run operation in subprocess with state persistence
    run bash -c "
        source 'path/to/bats-compatibility.bash'
        source 'path/to/module.sh'
        
        # Load state
        bats_safe_array_operation 'sync_to_array' 'TASK_STATES'
        
        # Perform operation
        your_function_here
        
        # Save state back
        bats_safe_array_operation 'sync_from_array' 'TASK_STATES'
    "
    
    # Verify results
    [ "$status" -eq 0 ]
    
    # Load updated state for verification
    bats_safe_array_operation "sync_to_array" "TASK_STATES"
    
    # Use BATS-safe operations for verification
    result=$(bats_safe_array_operation "get" "TASK_STATES" "$key")
    [ "$result" = "expected_value" ]
}
```

### 3. Performance Guidelines

#### Test Execution Time
- **Individual tests**: < 5 seconds each
- **Test file**: < 30 seconds total
- **Full test suite**: < 2 minutes total

#### Optimization Techniques
```bash
# ✅ Use fast temporary filesystems
setup() {
    if [[ -d "/dev/shm" && -w "/dev/shm" ]]; then
        export TEST_TEMP_BASE="/dev/shm"
    fi
}

# ✅ Cache expensive operations
setup_file() {
    # Expensive setup once per file
    export CACHED_CONFIG=$(parse_config_once)
}

# ✅ Use efficient data structures
# Avoid nested loops, use hash lookups when possible
```

### 4. Resource Management

#### Always Use Timeouts
```bash
# ✅ Wrap potentially hanging operations
timeout 5 your_operation_here

# ✅ Use BATS-safe timeout wrapper
bats_safe_timeout 5 "per_test" your_operation_here
```

#### Comprehensive Cleanup
```bash
teardown() {
    # Clean up processes
    pkill -f "test-specific-process" 2>/dev/null || true
    
    # Clean up files with timeout to prevent hanging
    timeout 3 rm -rf "$TEST_TEMP_DIR" 2>/dev/null || true
    
    # Reset environment variables
    unset TEST_SPECIFIC_VAR 2>/dev/null || true
    
    # Use enhanced teardown if available
    if declare -f enhanced_test_teardown >/dev/null; then
        enhanced_test_teardown
    fi
}
```

### 5. Mocking External Dependencies

#### External Commands
```bash
setup() {
    # Mock external commands
    mock_command "jq" 'mock_jq "$@"'
    mock_command "curl" 'mock_curl "$@"'
    
    # Implement mock functions
    mock_jq() {
        case "$1" in
            "empty") 
                # Validate JSON syntax
                python3 -m json.tool "$2" >/dev/null
                ;;
            -r)
                # Return test data
                echo "mock_result"
                ;;
        esac
    }
}
```

#### Network Operations
```bash
# ✅ Mock network calls
mock_network_check() {
    # Return predictable results
    echo "network_ok"
    return 0
}

# ✅ Use local test servers when needed
setup_local_test_server() {
    # Start minimal test server on localhost
    python3 -m http.server 8999 --directory "$TEST_FIXTURES_DIR" &
    TEST_SERVER_PID=$!
    
    # Wait for server to start
    timeout 5 bash -c 'while ! curl -s http://localhost:8999 >/dev/null; do sleep 0.1; done'
}

teardown() {
    # Clean up test server
    [[ -n "${TEST_SERVER_PID:-}" ]] && kill "$TEST_SERVER_PID" 2>/dev/null || true
}
```

### 6. Error Handling and Debugging

#### Comprehensive Error Information
```bash
@test "example test with good error handling" {
    run your_function_with_complex_logic
    
    # Provide context on failure
    if [[ $status -ne 0 ]]; then
        echo "Function failed with status: $status"
        echo "Output: $output"
        echo "Test environment: $(env | grep TEST_)"
        echo "Current directory: $PWD"
        echo "Available files: $(ls -la)"
    fi
    
    [ "$status" -eq 0 ]
}
```

#### Debug-Friendly Assertions
```bash
# ✅ GOOD: Descriptive assertion with context
local expected="expected_value"
local actual="$output"
if [[ "$actual" != "$expected" ]]; then
    echo "ASSERTION FAILED:"
    echo "  Expected: '$expected'"
    echo "  Actual:   '$actual'"
    echo "  Context:  Testing function X with input Y"
    false
fi

# ❌ POOR: Generic assertion
[ "$output" = "expected_value" ]
```

### 7. Test Isolation

#### Each Test is Independent
```bash
# ✅ GOOD: Each test sets up its own environment
@test "test 1" {
    setup_test_environment
    # Test logic
}

@test "test 2" {
    setup_test_environment  # Fresh environment
    # Test logic
}

# ❌ AVOID: Tests depending on each other
@test "test 1 - creates data" { }
@test "test 2 - uses data from test 1" { }  # BAD
```

#### Environment Isolation
```bash
setup() {
    # Create isolated environment
    export TEST_TMP_DIR=$(mktemp -d)
    export HOME="$TEST_TMP_DIR/home"
    export PROJECT_ROOT="$TEST_TMP_DIR/project"
    
    # Copy necessary files
    cp -r "$BATS_TEST_DIRNAME/../src" "$PROJECT_ROOT/"
}
```

## Testing Patterns

### 1. Unit Test Pattern
```bash
@test "unit test: function_name does specific_thing" {
    # Arrange
    setup_test_data
    local input="test_input"
    local expected="expected_output"
    
    # Act
    run function_name "$input"
    
    # Assert
    [ "$status" -eq 0 ]
    [ "$output" = "$expected" ]
    
    # Additional state verification if needed
    [ -f "$EXPECTED_OUTPUT_FILE" ]
}
```

### 2. Integration Test Pattern
```bash
@test "integration test: end_to_end_workflow_works" {
    # Arrange - more complex setup
    setup_full_test_environment
    create_test_data_files
    start_test_dependencies
    
    # Act - test complete workflow
    run full_workflow_command
    
    # Assert - verify all expected outcomes
    [ "$status" -eq 0 ]
    verify_output_files
    verify_state_changes
    verify_side_effects
}
```

### 3. Error Condition Testing
```bash
@test "error handling: function handles invalid input gracefully" {
    # Test various error conditions
    local invalid_inputs=("" "invalid" "too_long_$(printf 'x%.0s' {1..1000})")
    
    for input in "${invalid_inputs[@]}"; do
        run function_name "$input"
        
        # Should fail gracefully
        [ "$status" -ne 0 ]
        assert_output_contains "error"
    done
}
```

## Anti-Patterns to Avoid

### ❌ Common Mistakes

#### 1. Hanging Operations
```bash
# BAD: Infinite loop potential
while ! condition_that_might_never_be_true; do
    sleep 1
done

# GOOD: Timeout with failure handling
timeout 10 bash -c '
    while ! condition_that_might_never_be_true; do
        sleep 1
    done
' || {
    echo "Condition not met within timeout"
    return 1
}
```

#### 2. Resource Leaks
```bash
# BAD: Background process without cleanup
your_daemon &

# GOOD: Background process with cleanup
your_daemon &
DAEMON_PID=$!
trap 'kill $DAEMON_PID 2>/dev/null || true' EXIT
```

#### 3. Flaky Tests
```bash
# BAD: Time-dependent test
sleep 1
check_if_file_exists  # Race condition

# GOOD: Wait with timeout
timeout 5 bash -c '
    while [[ ! -f "$expected_file" ]]; do
        sleep 0.1
    done
'
```

## Debugging Failed Tests

### 1. Add Debug Output
```bash
@test "failing test with debug info" {
    # Enable debug output for failing tests
    if [[ "${DEBUG_TESTS:-}" == "true" ]]; then
        set -x  # Enable command tracing
    fi
    
    # Your test logic
    run problematic_function
    
    # Debug information on failure
    if [[ $status -ne 0 ]]; then
        echo "DEBUG: Function failed"
        echo "DEBUG: Status: $status"
        echo "DEBUG: Output: $output" 
        echo "DEBUG: Environment: $(env | grep TEST_ | sort)"
        echo "DEBUG: Files in PWD: $(ls -la)"
    fi
    
    [ "$status" -eq 0 ]
}
```

### 2. Run Individual Tests
```bash
# Run specific failing test
DEBUG_TESTS=true bats tests/unit/test-file.bats -f "specific test name"

# Run with verbose output
bats tests/unit/test-file.bats --verbose-run
```

### 3. Temporary Debug Files
```bash
setup() {
    export TEST_DEBUG_DIR="$TEST_TMP_DIR/debug"
    mkdir -p "$TEST_DEBUG_DIR"
}

@test "debug test with trace files" {
    # Save debug information
    env | grep TEST_ > "$TEST_DEBUG_DIR/environment.txt"
    ls -la > "$TEST_DEBUG_DIR/filesystem.txt"
    
    # Your test logic
    
    # Save post-test state
    echo "Test completed with status: $status" >> "$TEST_DEBUG_DIR/result.txt"
}
```

## Performance Optimization

### 1. Profile Test Execution
```bash
# Time individual operations
time_operation() {
    local start=$(date +%s%N)
    "$@"
    local end=$(date +%s%N)
    local duration_ms=$(( (end - start) / 1000000 ))
    echo "Operation took ${duration_ms}ms: $*" >&2
}

@test "performance test" {
    time_operation slow_operation
    time_operation another_operation
}
```

### 2. Use Efficient Tools
```bash
# ✅ Fast file operations
# Use Python for complex JSON operations
python3 -c "import json; data=json.load(open('$file')); print(data['key'])"

# Use native bash for simple operations
value=${line#*=}  # Instead of cut or sed for simple parsing
```

## Continuous Improvement

### 1. Test Metrics Tracking
- Monitor test execution times
- Track success rates over time
- Identify flaky tests through multiple runs
- Use test-reliability-monitor.sh for automated tracking

### 2. Regular Review
- Weekly review of test failures
- Monthly review of test performance
- Quarterly review of testing practices
- Annual review of testing architecture

### 3. Documentation Updates
- Update this document when new patterns emerge
- Document new anti-patterns discovered
- Share lessons learned from debugging difficult issues

---

## Conclusion

Following these best practices will help maintain a reliable, fast, and maintainable test suite. The key principles are:

1. **Reliability over complexity** - simple, predictable tests are better
2. **Fast feedback** - tests should provide quick results
3. **Clear failures** - when tests fail, make it easy to understand why
4. **Resource consciousness** - clean up properly, use timeouts
5. **Isolation** - tests should not affect each other

When in doubt, prioritize test reliability and clarity over cleverness or performance micro-optimizations.

---

**Maintainers**: Claude Auto-Resume Development Team  
**Review Schedule**: Quarterly  
**Last Updated**: 2025-08-30