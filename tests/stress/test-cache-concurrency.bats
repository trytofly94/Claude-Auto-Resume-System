#!/usr/bin/env bats

# Claude Auto-Resume - Cache Concurrency Stress Tests
# Testing cache behavior under concurrent access patterns
# Version: 2.1.0-efficiency-optimization (Issue #116)

# Setup and teardown
setup() {
    # Load test helpers
    load '../test_helper'
    
    # Set up test environment
    export TEST_DIR="$(mktemp -d)"
    export CACHE_DIR="$TEST_DIR/.claude-queue-cache"
    export QUEUE_FILE="$TEST_DIR/stress-queue.json"
    export HOME="$TEST_DIR"
    
    # Load the cache module
    SCRIPT_DIR="${BATS_TEST_DIRNAME}/../../src"
    source "$SCRIPT_DIR/queue/cache.sh"
    
    # Create large test queue for stress testing
    create_large_test_queue() {
        local task_count="$1"
        local queue_file="$2"
        
        echo '{"tasks": [' > "$queue_file"
        for i in $(seq 1 $task_count); do
            local status="pending"
            case $(( i % 4 )) in
                1) status="in_progress" ;;
                2) status="completed" ;;
                3) status="failed" ;;
            esac
            
            echo "  {\"id\": \"stress-task-$i\", \"type\": \"stress-test\", \"status\": \"$status\", \"priority\": \"normal\", \"created_at\": \"2025-09-01T$(printf '%02d' $((i % 24))):$(printf '%02d' $((i % 60))):00Z\"}"
            if [ $i -lt $task_count ]; then
                echo "," >> "$queue_file"
            fi
        done >> "$queue_file"
        echo '], "last_modified": '$(date +%s)'}' >> "$queue_file"
    }
    
    # Create test queue with 200 tasks for stress testing
    create_large_test_queue 200 "$QUEUE_FILE"
}

teardown() {
    # Kill any background processes
    jobs -p | xargs -r kill 2>/dev/null || true
    wait 2>/dev/null || true
    
    rm -rf "$TEST_DIR"
}

# ===============================================
# CONCURRENT ACCESS STRESS TESTS  
# ===============================================

@test "concurrent cache building from multiple processes" {
    # Test multiple processes trying to build cache simultaneously
    local pids=()
    local results_dir="$TEST_DIR/concurrent-results"
    mkdir -p "$results_dir"
    
    # Function to run in background
    cache_build_worker() {
        local worker_id="$1"
        local result_file="$results_dir/worker-$worker_id.result"
        
        # Try to build cache and record result
        if build_cache "$QUEUE_FILE"; then
            echo "SUCCESS" > "$result_file"
            get_cache_stats > "$result_file.stats"
        else
            echo "FAILED" > "$result_file"
        fi
    }
    
    # Start 5 concurrent cache building processes
    for i in {1..5}; do
        cache_build_worker $i &
        pids+=($!)
    done
    
    # Wait for all processes to complete
    for pid in "${pids[@]}"; do
        wait $pid
    done
    
    # Verify results
    local success_count=0
    local failed_count=0
    
    for i in {1..5}; do
        local result_file="$results_dir/worker-$i.result"
        if [[ -f "$result_file" ]]; then
            local result=$(cat "$result_file")
            if [[ "$result" == "SUCCESS" ]]; then
                ((success_count++))
            else
                ((failed_count++))
            fi
        fi
    done
    
    # At least one should succeed, others may fail gracefully due to locking
    [[ $success_count -ge 1 ]]
    
    # Verify cache is in valid state after concurrent access
    [[ "$QUEUE_CACHE_VALID" == "true" ]]
    [[ ${#TASK_INDEX[@]} -eq 200 ]]
}

@test "concurrent cache access with rapid operations" {
    # Build initial cache
    run build_cache "$QUEUE_FILE"
    [[ $status -eq 0 ]]
    
    local pids=()
    local operations_dir="$TEST_DIR/operations-results"
    mkdir -p "$operations_dir"
    
    # Worker function for rapid cache operations
    cache_operation_worker() {
        local worker_id="$1"
        local result_file="$operations_dir/worker-$worker_id.log"
        
        # Perform various cache operations rapidly
        for j in {1..20}; do
            local task_id="stress-task-$(( (worker_id - 1) * 20 + j ))"
            
            # Test cache operations
            if task_exists_cached "$QUEUE_FILE" "$task_id"; then
                echo "EXISTS:$task_id" >> "$result_file"
            fi
            
            if get_task_by_id_cached "$QUEUE_FILE" "$task_id" >/dev/null 2>&1; then
                echo "GET:$task_id" >> "$result_file"
            fi
            
            # Test stats access
            if get_queue_stats_cached "$QUEUE_FILE" >/dev/null 2>&1; then
                echo "STATS:OK" >> "$result_file"
            fi
        done
    }
    
    # Start 10 concurrent workers performing rapid operations
    for i in {1..10}; do
        cache_operation_worker $i &
        pids+=($!)
    done
    
    # Wait for all operations to complete
    for pid in "${pids[@]}"; do
        wait $pid
    done
    
    # Verify all workers completed their operations
    for i in {1..10}; do
        local result_file="$operations_dir/worker-$i.log"
        [[ -f "$result_file" ]]
        
        # Should have 41 operations logged (20 EXISTS + 20 GET + 20 STATS, some may overlap)
        local op_count=$(wc -l < "$result_file")
        [[ $op_count -ge 20 ]]  # At least the EXISTS operations should succeed
    done
    
    # Cache should still be valid and consistent
    [[ "$QUEUE_CACHE_VALID" == "true" ]]
    [[ ${#TASK_INDEX[@]} -eq 200 ]]
}

@test "cache invalidation under concurrent load" {
    # Build initial cache
    run build_cache "$QUEUE_FILE"
    [[ $status -eq 0 ]]
    
    local pids=()
    local invalidation_dir="$TEST_DIR/invalidation-results"
    mkdir -p "$invalidation_dir"
    
    # Worker that continuously accesses cache
    cache_access_worker() {
        local worker_id="$1"
        local result_file="$invalidation_dir/access-worker-$worker_id.log"
        
        # Continuously access cache for 2 seconds
        local end_time=$(( $(date +%s) + 2 ))
        local access_count=0
        
        while [[ $(date +%s) -lt $end_time ]]; do
            if get_queue_stats_cached "$QUEUE_FILE" >/dev/null 2>&1; then
                ((access_count++))
            fi
            sleep 0.01  # 10ms between accesses
        done
        
        echo "$access_count" > "$result_file"
    }
    
    # Worker that invalidates cache periodically
    cache_invalidation_worker() {
        local result_file="$invalidation_dir/invalidation-worker.log"
        local invalidation_count=0
        
        # Invalidate cache 5 times over 2 seconds
        for i in {1..5}; do
            sleep 0.4
            invalidate_cache "stress-test-$i"
            ((invalidation_count++))
            echo "INVALIDATED:$i" >> "$result_file"
        done
        
        echo "$invalidation_count" >> "$result_file"
    }
    
    # Start cache access workers
    for i in {1..3}; do
        cache_access_worker $i &
        pids+=($!)
    done
    
    # Start cache invalidation worker
    cache_invalidation_worker &
    pids+=($!)
    
    # Wait for all workers
    for pid in "${pids[@]}"; do
        wait $pid
    done
    
    # Verify invalidation worker completed its task
    local invalidation_file="$invalidation_dir/invalidation-worker.log"
    [[ -f "$invalidation_file" ]]
    local invalidation_count=$(tail -1 "$invalidation_file")
    [[ $invalidation_count -eq 5 ]]
    
    # Verify access workers handled invalidations gracefully
    for i in {1..3}; do
        local access_file="$invalidation_dir/access-worker-$i.log"
        [[ -f "$access_file" ]]
        local access_count=$(cat "$access_file")
        # Should have completed some accesses despite invalidations
        [[ $access_count -gt 0 ]]
    done
}

@test "memory usage stability under extended concurrent load" {
    # Build initial cache
    run build_cache "$QUEUE_FILE"
    [[ $status -eq 0 ]]
    
    # Get initial memory usage
    local initial_memory
    if command -v ps >/dev/null 2>&1; then
        initial_memory=$(ps -o rss= -p $$ | awk '{print $1}')
    else
        skip "ps command not available for memory testing"
    fi
    
    local pids=()
    local memory_dir="$TEST_DIR/memory-results"
    mkdir -p "$memory_dir"
    
    # Worker that performs continuous cache operations
    memory_stress_worker() {
        local worker_id="$1"
        local result_file="$memory_dir/memory-worker-$worker_id.log"
        
        # Run for 3 seconds with intensive operations
        local end_time=$(( $(date +%s) + 3 ))
        local operation_count=0
        
        while [[ $(date +%s) -lt $end_time ]]; do
            # Mix of different cache operations
            case $(( operation_count % 4 )) in
                0) get_queue_stats_cached "$QUEUE_FILE" >/dev/null 2>&1 ;;
                1) task_exists_cached "$QUEUE_FILE" "stress-task-$(( (operation_count % 200) + 1 ))" >/dev/null 2>&1 ;;
                2) get_task_by_id_cached "$QUEUE_FILE" "stress-task-$(( (operation_count % 200) + 1 ))" >/dev/null 2>&1 ;;
                3) get_pending_count_cached "$QUEUE_FILE" >/dev/null 2>&1 ;;
            esac
            
            ((operation_count++))
            
            # Brief sleep to prevent overwhelming the system
            sleep 0.001
        done
        
        echo "$operation_count" > "$result_file"
    }
    
    # Start 8 concurrent memory stress workers
    for i in {1..8}; do
        memory_stress_worker $i &
        pids+=($!)
    done
    
    # Wait for all workers to complete
    for pid in "${pids[@]}"; do
        wait $pid
    done
    
    # Check final memory usage
    local final_memory
    if command -v ps >/dev/null 2>&1; then
        final_memory=$(ps -o rss= -p $$ | awk '{print $1}')
    else
        skip "ps command not available for memory testing"
    fi
    
    # Verify workers completed significant operations
    local total_operations=0
    for i in {1..8}; do
        local result_file="$memory_dir/memory-worker-$i.log"
        [[ -f "$result_file" ]]
        local worker_ops=$(cat "$result_file")
        [[ $worker_ops -gt 100 ]]  # Each worker should complete at least 100 operations
        total_operations=$((total_operations + worker_ops))
    done
    
    # Total should be substantial
    [[ $total_operations -gt 800 ]]
    
    # Memory usage should not have exploded (allow for 50% increase max)
    local memory_increase=$(( final_memory - initial_memory ))
    local max_allowed_increase=$(( initial_memory / 2 ))
    
    echo "Memory usage: ${initial_memory}KB -> ${final_memory}KB (increase: ${memory_increase}KB)"
    echo "Total operations completed: $total_operations"
    
    # Memory increase should be reasonable
    [[ $memory_increase -lt $max_allowed_increase ]]
}

@test "cache consistency during queue file modifications" {
    # Build initial cache
    run build_cache "$QUEUE_FILE"
    [[ $status -eq 0 ]]
    
    local initial_task_count=${#TASK_INDEX[@]}
    [[ $initial_task_count -eq 200 ]]
    
    # Simulate queue file modification (add tasks)
    local temp_queue="$TEST_DIR/modified-queue.json"
    
    # Create modified queue with 250 tasks (50 more)
    echo '{"tasks": [' > "$temp_queue"
    for i in $(seq 1 250); do
        local status="pending"
        case $(( i % 4 )) in
            1) status="in_progress" ;;
            2) status="completed" ;;
            3) status="failed" ;;
        esac
        
        echo "  {\"id\": \"stress-task-$i\", \"type\": \"stress-test\", \"status\": \"$status\", \"priority\": \"normal\", \"created_at\": \"2025-09-01T$(printf '%02d' $((i % 24))):$(printf '%02d' $((i % 60))):00Z\"}"
        if [ $i -lt 250 ]; then
            echo "," >> "$temp_queue"
        fi
    done >> "$temp_queue"
    echo '], "last_modified": '$(date +%s)'}' >> "$temp_queue"
    
    # Replace original queue file
    mv "$temp_queue" "$QUEUE_FILE"
    
    # Sleep briefly to ensure mtime difference
    sleep 1
    
    # Access cache - should detect modification and rebuild
    run get_queue_stats_cached "$QUEUE_FILE"
    [[ $status -eq 0 ]]
    
    # Verify cache was rebuilt with new task count
    [[ ${#TASK_INDEX[@]} -eq 250 ]]
    
    # Verify specific new task exists
    run task_exists_cached "$QUEUE_FILE" "stress-task-250"
    [[ $status -eq 0 ]]
    
    # Verify stats reflect new count
    local stats_output=$(get_queue_stats_cached "$QUEUE_FILE")
    local total_tasks=$(echo "$stats_output" | jq -r '.total')
    [[ $total_tasks -eq 250 ]]
}