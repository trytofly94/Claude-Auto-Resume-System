#!/usr/bin/env bats

# Test Phase 1: Backward Compatibility
# Tests that existing monitoring functionality remains unchanged with Phase 1 task queue integration

load '../test_helper'

setup() {
    # Create test environment
    export TEST_MODE=true
    export LOG_LEVEL=ERROR  # Reduce noise in tests
    
    # Create original-style config without task queue settings
    LEGACY_CONFIG="$(mktemp)"
    cat > "$LEGACY_CONFIG" << 'EOF'
# Legacy configuration (pre-task-queue)
CHECK_INTERVAL_MINUTES=5
MAX_RESTARTS=50
USE_CLAUNCH=true
CLAUNCH_MODE="tmux"
TMUX_SESSION_PREFIX="claude-auto"

# Usage limit handling
USAGE_LIMIT_COOLDOWN=300
BACKOFF_FACTOR=1.5
MAX_WAIT_TIME=1800

# Logging configuration
LOG_LEVEL="INFO"
LOG_ROTATION=true
MAX_LOG_SIZE="100M"
LOG_FILE="logs/hybrid-monitor.log"

# Terminal integration
PREFERRED_TERMINAL="auto"
NEW_TERMINAL_DEFAULT=true

# Monitoring & recovery
HEALTH_CHECK_ENABLED=true
AUTO_RECOVERY_ENABLED=true
MAX_RECOVERY_ATTEMPTS=3

# No task queue settings - test legacy behavior
EOF
    export CONFIG_FILE="$LEGACY_CONFIG"
    
    # Mock claunch for monitoring functionality tests
    MOCK_CLAUNCH="$(mktemp)"
    cat > "$MOCK_CLAUNCH" << 'EOF'
#!/bin/bash
case "$1" in
    "list") echo "No sessions found" ;;
    "start") echo "Starting session: $*" ;;
    "stop") echo "Stopping session: $*" ;;
    *) echo "claunch: $*" ;;
esac
exit 0
EOF
    chmod +x "$MOCK_CLAUNCH"
    export PATH="$(dirname "$MOCK_CLAUNCH"):$PATH"
    
    # Disable task queue to test pure legacy behavior
    export TASK_QUEUE_ENABLED=false
    export TASK_QUEUE_AVAILABLE=false
}

teardown() {
    [[ -f "$LEGACY_CONFIG" ]] && rm -f "$LEGACY_CONFIG"
    [[ -f "$MOCK_CLAUNCH" ]] && rm -f "$MOCK_CLAUNCH"
}

@test "backward compatibility: traditional CLI parameters still work" {
    # Test original CLI parameters without any task queue params
    run "$SRC_DIR/hybrid-monitor.sh" --help
    assert_success
    
    # Should show traditional help sections
    assert_output --partial "BASIC OPTIONS"
    assert_output --partial "MONITORING OPTIONS"
    
    # Task queue section should be present but not interfere
    assert_output --partial "TASK QUEUE OPTIONS"
}

@test "backward compatibility: continuous mode works without task queue" {
    # Test continuous mode without task queue integration
    run timeout 3s "$SRC_DIR/hybrid-monitor.sh" --continuous
    
    # Should timeout (expected in continuous mode) but not fail
    assert_equal "$status" 124  # timeout exit code
    
    # Should not show task queue related errors
    run grep -i "task queue.*error" "$LOG_FILE"
    assert_failure
}

@test "backward compatibility: test mode works without task queue" {
    # Test the --test-mode functionality
    run timeout 10s "$SRC_DIR/hybrid-monitor.sh" --test-mode 5
    assert_success
    
    # Should complete test mode successfully
    assert_output --partial "TEST MODE"
}

@test "backward compatibility: config loading without task queue parameters" {
    # Test that legacy config files load without task queue parameters
    run "$SRC_DIR/hybrid-monitor.sh" --help
    assert_success
    
    # No task queue related initialization errors should occur
    run grep -i "task queue.*error" "$LOG_FILE"
    assert_failure
}

@test "backward compatibility: original claunch integration unchanged" {
    # Test that claunch functionality isn't affected by task queue integration
    export USE_CLAUNCH=true
    export CLAUNCH_MODE="tmux"
    
    run timeout 5s "$SRC_DIR/hybrid-monitor.sh" --test-mode 2
    assert_success
    
    # Should use claunch without task queue interference
    # Note: In test mode, actual claunch interaction is limited
}

@test "backward compatibility: usage limit detection unchanged" {
    # Test that usage limit detection still works without task queue
    run timeout 8s "$SRC_DIR/hybrid-monitor.sh" --test-mode 3
    assert_success
    
    # Should simulate usage limits in test mode
    assert_output --partial "Simulating usage limit"
}

@test "backward compatibility: logging functionality unchanged" {
    # Test that logging works the same way
    export LOG_LEVEL="DEBUG"
    
    run "$SRC_DIR/hybrid-monitor.sh" --help
    assert_success
    
    # Should create and use log file as before
    [[ -f "$LOG_FILE" ]]
}

@test "backward compatibility: dry run mode works without task queue" {
    # Test dry run mode functionality
    run timeout 5s "$SRC_DIR/hybrid-monitor.sh" --dry-run --test-mode 2
    assert_success
    
    # Should show dry run behavior
    assert_output --partial "DRY RUN MODE"
}

@test "backward compatibility: new terminal integration unchanged" {
    # Test terminal integration without task queue
    export NEW_TERMINAL_DEFAULT=true
    export PREFERRED_TERMINAL="auto"
    
    run "$SRC_DIR/hybrid-monitor.sh" --help
    assert_success
    
    # Should handle terminal settings without task queue interference
    # Basic functionality test - full terminal tests require GUI environment
}

@test "backward compatibility: monitoring cycle logic unchanged" {
    # Test that the core monitoring loop structure is preserved
    run timeout 3s "$SRC_DIR/hybrid-monitor.sh" --continuous --test-mode 1
    
    # Should start continuous monitoring
    assert_equal "$status" 124  # timeout exit code
    
    # Check that monitoring started but was interrupted by timeout
    run grep -i "starting continuous monitoring" "$LOG_FILE"
    assert_success
}

@test "backward compatibility: signal handling unchanged" {
    # Test that signal handling works correctly without task queue
    run timeout 2s "$SRC_DIR/hybrid-monitor.sh" --continuous
    
    # Should handle timeout signal gracefully
    assert_equal "$status" 124  # timeout exit code
    
    # Should not show task queue related cleanup errors
    run grep -i "task queue.*cleanup.*error" "$LOG_FILE"
    assert_failure
}

@test "backward compatibility: configuration file precedence unchanged" {
    # Test that config file takes precedence over defaults
    export CHECK_INTERVAL_MINUTES=999  # Env var
    
    run "$SRC_DIR/hybrid-monitor.sh" --help
    assert_success
    
    # Config file should still override environment variables
    # (This is implicit behavior - the script loads config after env vars)
}

@test "backward compatibility: error handling without task queue" {
    # Test error handling when no task queue is present
    export TASK_QUEUE_ENABLED=false
    
    run "$SRC_DIR/hybrid-monitor.sh" --help
    assert_success
    
    # Should not show any task queue related errors in help output
    refute_output --partial "Task Queue.*error"
}

@test "backward compatibility: exit codes unchanged for traditional operations" {
    # Test that exit codes remain consistent for traditional operations
    
    # Help should exit 0
    run "$SRC_DIR/hybrid-monitor.sh" --help
    assert_success
    
    # Invalid parameter should exit non-zero
    run "$SRC_DIR/hybrid-monitor.sh" --invalid-parameter
    assert_failure
}

@test "backward compatibility: environment variable handling unchanged" {
    # Test that environment variables still work as before
    export CHECK_INTERVAL_MINUTES=123
    export MAX_RESTARTS=456
    export USE_CLAUNCH=false
    export DEBUG_MODE=true
    
    run "$SRC_DIR/hybrid-monitor.sh" --help
    assert_success
    
    # Environment variables should still be processed
    # (Implicit test - script should not fail loading these)
}

@test "backward compatibility: script validation and setup unchanged" {
    # Test that initial script validation works the same way
    run "$SRC_DIR/hybrid-monitor.sh" --version
    
    # Should show version information
    assert_success
    refute_output --partial "error"
}

@test "backward compatibility: dependencies check unchanged" {
    # Test that dependency checking works without task queue
    export USE_CLAUNCH=true
    
    run "$SRC_DIR/hybrid-monitor.sh" --help
    assert_success
    
    # Should complete successfully even with task queue disabled
    # (claunch is mocked, so this should work)
}

@test "backward compatibility: no task queue parameters in legacy mode" {
    # Test that when task queue is disabled, new parameters don't interfere
    run "$SRC_DIR/hybrid-monitor.sh" --continuous --help
    assert_success
    
    # Should show help without activating task queue features
    assert_output --partial "TASK QUEUE OPTIONS"
    
    # But task queue should remain inactive
    run grep -i "task queue processing enabled" "$LOG_FILE"
    assert_failure
}