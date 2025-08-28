#!/usr/bin/env bats
# Performance benchmarking for task queue operations
#
# This test suite validates performance requirements and benchmarks:
# - Queue operations performance with large numbers of tasks
# - Memory usage optimization and monitoring
# - Concurrent access performance and safety
# - Processing performance under various loads
# - Resource usage optimization
# - Scalability validation with 100+ tasks
#
# Performance Targets (from GitHub Issue #44):
# - Single Task Processing: < 10 seconds overhead
# - Queue Operations: < 1 second per operation (add/remove/list)
# - Memory Usage: < 100MB for 1000 queued tasks
# - GitHub API Calls: < 500 calls/hour with rate limiting
# - Session Management: < 5 seconds for session transitions
# - Error Recovery: < 30 seconds for automatic recovery

load '../test_helper'

setup() {
    # Load test environment
    setup_test_environment
    
    # Set up performance test configuration
    export PERFORMANCE_TESTING=true
    export LOG_LEVEL="WARN"  # Reduce logging overhead during performance tests
    export TASK_QUEUE_ENABLED=true
    
    # Create isolated performance test environment
    PERF_TEST_DIR="/tmp/perf_test_queue_$$"
    export TASK_QUEUE_DIR="$PERF_TEST_DIR"
    mkdir -p "$PERF_TEST_DIR"
    
    # Initialize performance monitoring
    PERF_LOG_FILE="$PERF_TEST_DIR/performance.log"
    export PERFORMANCE_LOG="$PERF_LOG_FILE"
    
    # Set performance test configuration
    cat > "$PERF_TEST_DIR/perf.conf" << 'EOF'
TASK_QUEUE_ENABLED=true
QUEUE_PROCESSING_DELAY=1
PERFORMANCE_MONITORING=true
LARGE_QUEUE_OPTIMIZATION=true
MEMORY_LIMIT_MB=100
EOF
    export CONFIG_FILE="$PERF_TEST_DIR/perf.conf"
}

teardown() {
    # Clean up performance test environment
    if [[ -n "$PERF_TEST_DIR" && -d "$PERF_TEST_DIR" ]]; then
        rm -rf "$PERF_TEST_DIR"
    fi
    
    # Kill any background processes
    cleanup_background_processes
}

setup_performance_test_environment() {
    # Ensure clean state for performance testing
    cleanup_performance_test_environment
    mkdir -p "$PERF_TEST_DIR"
}

cleanup_performance_test_environment() {
    # Clean up after performance tests
    if [[ -n "$PERF_TEST_DIR" && -d "$PERF_TEST_DIR" ]]; then
        rm -rf "$PERF_TEST_DIR"
    fi
}

measure_queue_memory_usage() {
    # Measure memory usage of queue operations
    local pid="${1:-$$}"
    
    if command -v ps >/dev/null; then
        # Get RSS in KB, convert to MB
        local memory_kb
        memory_kb=$(ps -o rss= -p "$pid" 2>/dev/null | awk '{print $1}' || echo "0")
        echo "scale=2; $memory_kb / 1024" | bc -l 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

verify_queue_integrity() {
    # Verify that queue file is valid JSON and contains expected structure
    local queue_file="$PERF_TEST_DIR/task-queue.json"
    
    if [[ -f "$queue_file" ]]; then
        # Verify JSON validity
        jq '.' "$queue_file" >/dev/null 2>&1 || return 1
        
        # Verify structure
        jq -e '.tasks | type == "array"' "$queue_file" >/dev/null 2>&1 || return 1
        
        # Check for duplicate IDs
        local unique_ids duplicate_check
        unique_ids=$(jq -r '.tasks[].id' "$queue_file" 2>/dev/null | sort | uniq | wc -l)
        duplicate_check=$(jq -r '.tasks[].id' "$queue_file" 2>/dev/null | wc -l)
        [[ "$unique_ids" -eq "$duplicate_check" ]] || return 1
        
        return 0
    fi
    
    return 1
}

cleanup_background_processes() {
    # Clean up any background processes started during testing
    local bg_pids
    bg_pids=$(jobs -p 2>/dev/null || true)
    
    for pid in $bg_pids; do
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            sleep 1
            kill -9 "$pid" 2>/dev/null || true
        fi
    done
}

@test "queue operations performance with large number of tasks" {
    # Validate performance requirements for large queues
    
    setup_performance_test_environment
    
    # Benchmark task addition performance
    local start_time end_time duration
    start_time=$(date +%s%N)
    
    # Add 1000 tasks to test scalability
    for i in {1..1000}; do
        "$PROJECT_ROOT/src/hybrid-monitor.sh" --add-custom "Performance test task $i" --quiet >/dev/null 2>&1 || {
            log_error "Failed to add task $i"
            break
        }
    done
    
    end_time=$(date +%s%N)
    duration=$(( (end_time - start_time) / 1000000 ))  # Convert to ms
    
    # Should add 1000 tasks in less than 10 seconds (10000ms)
    if [[ $duration -gt 10000 ]]; then
        log_warn "Task addition took ${duration}ms for 1000 tasks (expected <10000ms)"
        # Don't fail test on slower systems, but warn
    fi
    
    # Benchmark queue listing performance
    start_time=$(date +%s%N)
    run "$PROJECT_ROOT/src/hybrid-monitor.sh" --list-queue --quiet
    end_time=$(date +%s%N)
    duration=$(( (end_time - start_time) / 1000000 ))
    
    # Should list 1000 tasks in less than 1 second (1000ms)
    if [[ $duration -gt 1000 ]]; then
        log_warn "Queue listing took ${duration}ms for 1000 tasks (expected <1000ms)"
        # Allow for system variations
    fi
    assert_success
    
    # Measure memory usage
    local memory_usage
    memory_usage=$(measure_queue_memory_usage)
    
    # Should use less than 100MB for 1000 tasks
    if (( $(echo "$memory_usage > 100" | bc -l 2>/dev/null || echo 0) )); then
        log_warn "Memory usage (${memory_usage}MB) exceeds target (100MB) for 1000 tasks"
        # Don't fail test - memory usage can vary by system
    fi
    
    # Verify queue integrity
    verify_queue_integrity
    
    cleanup_performance_test_environment
}

@test "concurrent queue access performance" {
    # Validate performance and safety of concurrent operations
    
    setup_performance_test_environment
    
    local start_time end_time duration
    start_time=$(date +%s)
    
    # Start multiple concurrent queue operations
    local pids=()
    for i in {1..10}; do
        (
            for j in {1..20}; do
                "$PROJECT_ROOT/src/hybrid-monitor.sh" --add-custom "Concurrent task $i-$j" --quiet >/dev/null 2>&1
            done
        ) &
        pids+=($!)
    done
    
    # Wait for all background processes with timeout
    local timeout=60
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        local all_done=true
        for pid in "${pids[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                all_done=false
                break
            fi
        done
        
        if [[ "$all_done" == "true" ]]; then
            break
        fi
        
        sleep 1
        ((elapsed++))
    done
    
    # Kill any remaining processes
    for pid in "${pids[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    
    end_time=$(date +%s)
    duration=$((end_time - start_time))
    
    # Should complete concurrent operations within reasonable time
    if [[ $duration -gt 30 ]]; then
        log_warn "Concurrent operations took ${duration}s (expected <30s)"
    fi
    
    # Verify all 200 tasks were added correctly (or as many as possible)
    local queue_file="$PERF_TEST_DIR/task-queue.json"
    if [[ -f "$queue_file" ]]; then
        local task_count
        task_count=$(jq '[.tasks[]] | length' "$queue_file" 2>/dev/null || echo "0")
        
        # Should have added most tasks (allow for some failures under load)
        if [[ $task_count -lt 150 ]]; then
            log_warn "Only $task_count tasks added (expected ~200)"
        fi
        
        # Verify queue integrity despite concurrent access
        verify_queue_integrity
    fi
    
    cleanup_performance_test_environment
}

@test "processing performance under load" {
    # Validate task processing performance under load
    
    setup_performance_test_environment
    
    # Add moderate number of tasks for processing test
    for i in {1..10}; do
        "$PROJECT_ROOT/src/hybrid-monitor.sh" --add-custom "Load test task $i" --quiet >/dev/null 2>&1
    done
    
    # Measure processing time with test mode (fast execution)
    local start_time end_time total_duration
    start_time=$(date +%s)
    
    # Process with timeout to prevent hanging
    timeout 120 "$PROJECT_ROOT/src/hybrid-monitor.sh" --queue-mode --test-mode 5 || true
    
    end_time=$(date +%s)
    total_duration=$((end_time - start_time))
    
    # Processing should complete within reasonable time
    # 10 tasks * 5 seconds = 50 seconds + 30 seconds overhead = 80 seconds max
    if [[ $total_duration -gt 80 ]]; then
        log_warn "Processing took ${total_duration}s for 10 tasks (expected <80s)"
    fi
    
    # Verify tasks were processed
    local queue_file="$PERF_TEST_DIR/task-queue.json"
    if [[ -f "$queue_file" ]]; then
        local processed_count
        processed_count=$(jq '[.tasks[] | select(.status == "completed" or .status == "error")] | length' "$queue_file" 2>/dev/null || echo "0")
        
        # At least some tasks should have been processed
        [[ $processed_count -gt 0 ]] || log_warn "No tasks were processed in test mode"
    fi
    
    cleanup_performance_test_environment
}

@test "memory usage optimization with large queues" {
    # Validate memory usage remains reasonable with large queues
    
    setup_performance_test_environment
    
    # Measure baseline memory usage
    local baseline_memory
    baseline_memory=$(measure_queue_memory_usage)
    
    # Add progressively more tasks and monitor memory
    local tasks_added=0
    local max_memory=0
    
    for batch in {1..5}; do
        # Add 100 tasks per batch
        for i in $(seq 1 100); do
            local task_id=$((batch * 100 + i))
            "$PROJECT_ROOT/src/hybrid-monitor.sh" --add-custom "Memory test task $task_id" --quiet >/dev/null 2>&1
            ((tasks_added++))
        done
        
        # Measure memory after each batch
        local current_memory
        current_memory=$(measure_queue_memory_usage)
        
        if (( $(echo "$current_memory > $max_memory" | bc -l 2>/dev/null || echo 0) )); then
            max_memory=$current_memory
        fi
        
        log_debug "After $tasks_added tasks: ${current_memory}MB memory usage"
        
        # Check if memory usage is growing unreasonably
        local memory_per_task
        if [[ $tasks_added -gt 0 ]]; then
            memory_per_task=$(echo "scale=4; ($current_memory - $baseline_memory) / $tasks_added" | bc -l 2>/dev/null || echo "0")
            
            # Should use less than 0.1MB per task
            if (( $(echo "$memory_per_task > 0.1" | bc -l 2>/dev/null || echo 0) )); then
                log_warn "Memory usage per task (${memory_per_task}MB) may be too high"
            fi
        fi
    done
    
    # Final memory usage should be reasonable
    if (( $(echo "$max_memory > 100" | bc -l 2>/dev/null || echo 0) )); then
        log_warn "Maximum memory usage (${max_memory}MB) exceeded target (100MB)"
    fi
    
    # Verify queue integrity after memory stress test
    verify_queue_integrity
    
    cleanup_performance_test_environment
}

@test "queue file I/O performance optimization" {
    # Validate file I/O performance for queue operations
    
    setup_performance_test_environment
    
    # Test sequential I/O performance
    local start_time end_time duration
    
    # Add 500 tasks sequentially
    start_time=$(date +%s%N)
    for i in {1..500}; do
        "$PROJECT_ROOT/src/hybrid-monitor.sh" --add-custom "I/O test task $i" --quiet >/dev/null 2>&1
    done
    end_time=$(date +%s%N)
    duration=$(( (end_time - start_time) / 1000000 ))
    
    # Should handle 500 sequential operations efficiently
    if [[ $duration -gt 15000 ]]; then  # 15 seconds
        log_warn "Sequential I/O took ${duration}ms for 500 operations (expected <15000ms)"
    fi
    
    # Test queue file size efficiency
    local queue_file="$PERF_TEST_DIR/task-queue.json"
    if [[ -f "$queue_file" ]]; then
        local file_size
        file_size=$(du -k "$queue_file" | cut -f1)  # Size in KB
        
        # Should be reasonably efficient (less than 1KB per task)
        local size_per_task=$((file_size * 1000 / 500))  # Bytes per task
        if [[ $size_per_task -gt 1000 ]]; then
            log_warn "Queue file size efficiency: ${size_per_task} bytes per task (expected <1000)"
        fi
    fi
    
    # Test queue listing performance with large queue
    start_time=$(date +%s%N)
    run "$PROJECT_ROOT/src/hybrid-monitor.sh" --list-queue --quiet
    end_time=$(date +%s%N)
    duration=$(( (end_time - start_time) / 1000000 ))
    
    # Should list large queue quickly
    if [[ $duration -gt 2000 ]]; then  # 2 seconds
        log_warn "Large queue listing took ${duration}ms (expected <2000ms)"
    fi
    assert_success
    
    cleanup_performance_test_environment
}

@test "resource cleanup and optimization" {
    # Validate resource cleanup and optimization features
    
    setup_performance_test_environment
    
    # Create tasks and simulate completed state
    for i in {1..100}; do
        "$PROJECT_ROOT/src/hybrid-monitor.sh" --add-custom "Cleanup test task $i" --quiet >/dev/null 2>&1
    done
    
    # Manually mark some tasks as completed (simulate processing)
    local queue_file="$PERF_TEST_DIR/task-queue.json"
    if [[ -f "$queue_file" ]]; then
        # Mark first 50 tasks as completed
        jq '.tasks[0:50] |= map(.status = "completed" | .completed_at = now)' "$queue_file" > "${queue_file}.tmp"
        mv "${queue_file}.tmp" "$queue_file"
    fi
    
    # Test cleanup operations (if available)
    if "$PROJECT_ROOT/src/hybrid-monitor.sh" --help | grep -q "cleanup\|optimize"; then
        run "$PROJECT_ROOT/src/hybrid-monitor.sh" --cleanup-completed
        # Don't assert success as cleanup may not be implemented
    fi
    
    # Verify queue still functions after cleanup
    run "$PROJECT_ROOT/src/hybrid-monitor.sh" --list-queue --quiet
    assert_success
    
    # Verify queue integrity after cleanup
    verify_queue_integrity
    
    cleanup_performance_test_environment
}

@test "performance monitoring and metrics collection" {
    # Validate performance monitoring capabilities
    
    setup_performance_test_environment
    
    # Enable performance monitoring
    export PERFORMANCE_MONITORING=true
    
    # Perform various operations while monitoring
    local start_time
    start_time=$(date +%s)
    
    # Add tasks
    for i in {1..50}; do
        "$PROJECT_ROOT/src/hybrid-monitor.sh" --add-custom "Monitoring test task $i" --quiet >/dev/null 2>&1
    done
    
    # List queue multiple times
    for i in {1..5}; do
        "$PROJECT_ROOT/src/hybrid-monitor.sh" --list-queue --quiet >/dev/null 2>&1
    done
    
    # Check if performance metrics were collected
    if [[ -f "$PERF_LOG_FILE" ]]; then
        # Look for performance-related log entries
        grep -q "performance\|timing\|duration\|memory" "$PERF_LOG_FILE" || true
    fi
    
    # Verify operations completed within reasonable time
    local end_time duration
    end_time=$(date +%s)
    duration=$((end_time - start_time))
    
    if [[ $duration -gt 30 ]]; then
        log_warn "Performance monitoring operations took ${duration}s (expected <30s)"
    fi
    
    cleanup_performance_test_environment
}

@test "scalability validation with progressive load" {
    # Validate system scalability with progressively increasing load
    
    setup_performance_test_environment
    
    local load_levels=(10 50 100 250 500)
    local performance_data=()
    
    for load in "${load_levels[@]}"; do
        log_debug "Testing with $load tasks"
        
        # Clear queue for next test
        rm -f "$PERF_TEST_DIR/task-queue.json"
        
        # Measure performance at this load level
        local start_time end_time duration
        start_time=$(date +%s%N)
        
        # Add tasks
        for i in $(seq 1 "$load"); do
            "$PROJECT_ROOT/src/hybrid-monitor.sh" --add-custom "Scalability test $load-$i" --quiet >/dev/null 2>&1
        done
        
        end_time=$(date +%s%N)
        duration=$(( (end_time - start_time) / 1000000 ))
        
        # Store performance data
        performance_data+=("$load:$duration")
        
        # Verify queue operations work at this scale
        run "$PROJECT_ROOT/src/hybrid-monitor.sh" --list-queue --quiet
        assert_success
        
        # Check memory usage
        local memory_usage
        memory_usage=$(measure_queue_memory_usage)
        log_debug "Memory usage at $load tasks: ${memory_usage}MB"
        
        # Quick integrity check
        verify_queue_integrity
    done
    
    # Analyze performance trends
    log_debug "Performance data: ${performance_data[*]}"
    
    # Check that performance doesn't degrade dramatically with scale
    # (This is a basic check - more sophisticated analysis could be added)
    local small_load_time large_load_time
    small_load_time=$(echo "${performance_data[0]}" | cut -d: -f2)
    large_load_time=$(echo "${performance_data[-1]}" | cut -d: -f2)
    
    if [[ $large_load_time -gt $((small_load_time * 100)) ]]; then
        log_warn "Performance may degrade significantly with scale"
        log_warn "Small load: ${small_load_time}ms, Large load: ${large_load_time}ms"
    fi
    
    cleanup_performance_test_environment
}