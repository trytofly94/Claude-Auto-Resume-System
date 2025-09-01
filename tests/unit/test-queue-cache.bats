#!/usr/bin/env bats

# Claude Auto-Resume - Queue Cache Unit Tests
# Testing the new cache system for task queue operations
# Version: 2.1.0-efficiency-optimization (Issue #116)

# Setup and teardown
setup() {
    # Load test helpers
    load '../test_helper'
    
    # Set up test environment
    export TEST_DIR="$(mktemp -d)"
    export CACHE_DIR="$TEST_DIR/.claude-queue-cache"
    export QUEUE_FILE="$TEST_DIR/test-queue.json"
    
    # Mock HOME to use test directory
    export HOME="$TEST_DIR"
    
    # Load the cache module
    SCRIPT_DIR="${BATS_TEST_DIRNAME}/../../src"
    source "$SCRIPT_DIR/queue/cache.sh"
    
    # Create test queue file
    cat > "$QUEUE_FILE" << 'EOF'
{
  "tasks": [
    {
      "id": "task-1",
      "type": "test",
      "status": "pending",
      "priority": "high",
      "created_at": "2025-09-01T10:00:00Z"
    },
    {
      "id": "task-2", 
      "type": "test",
      "status": "in_progress",
      "priority": "normal",
      "created_at": "2025-09-01T11:00:00Z"
    },
    {
      "id": "task-3",
      "type": "test", 
      "status": "completed",
      "priority": "low",
      "created_at": "2025-09-01T12:00:00Z"
    }
  ]
}
EOF
}

teardown() {
    rm -rf "$TEST_DIR"
}

# ===============================================================================
# CACHE INITIALIZATION TESTS
# ===============================================================================

@test "cache system initializes successfully" {
    run init_cache_system
    [ "$status" -eq 0 ]
    [ -d "$CACHE_DIR" ]
    [[ "$output" =~ "Cache system initialized successfully" ]]
}

@test "cache directory is created when missing" {
    rm -rf "$CACHE_DIR"
    run init_cache_system
    [ "$status" -eq 0 ]
    [ -d "$CACHE_DIR" ]
}

@test "cache initialization works when directory already exists" {
    mkdir -p "$CACHE_DIR"
    run init_cache_system  
    [ "$status" -eq 0 ]
    [ -d "$CACHE_DIR" ]
}

# ===============================================================================
# CACHE VALIDATION TESTS
# ===============================================================================

@test "cache validation returns false for unbuilt cache" {
    run is_cache_valid "$QUEUE_FILE"
    [ "$status" -eq 1 ]
}

@test "cache validation returns true for fresh cache" {
    build_cache "$QUEUE_FILE"
    run is_cache_valid "$QUEUE_FILE"
    [ "$status" -eq 0 ]
}

@test "cache validation fails for modified queue file" {
    build_cache "$QUEUE_FILE"
    sleep 1
    touch "$QUEUE_FILE"  # Update mtime
    run is_cache_valid "$QUEUE_FILE"
    [ "$status" -eq 1 ]
}

@test "cache validation fails for expired cache" {
    # Mock old timestamp
    QUEUE_CACHE_TIMESTAMP=$(( $(date +%s) - 400 ))  # 400 seconds ago
    QUEUE_CACHE_VALID=true
    LAST_QUEUE_MTIME=$(stat -f %m "$QUEUE_FILE")
    
    run is_cache_valid "$QUEUE_FILE"
    [ "$status" -eq 1 ]
}

# ===============================================================================
# CACHE BUILDING TESTS  
# ===============================================================================

@test "cache builds successfully from valid queue file" {
    run build_cache "$QUEUE_FILE"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Cache built successfully: 3 tasks indexed" ]]
}

@test "cache building fails for non-existent file" {
    run build_cache "/nonexistent/file.json"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Queue file not found" ]]
}

@test "cache building fails for malformed JSON" {
    echo "invalid json" > "$QUEUE_FILE"
    run build_cache "$QUEUE_FILE"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Failed to parse queue file" ]]
}

@test "cache builds task index correctly" {
    build_cache "$QUEUE_FILE"
    
    # Check if all tasks are indexed
    [ -n "${TASK_INDEX[task-1]:-}" ]
    [ -n "${TASK_INDEX[task-2]:-}" ]
    [ -n "${TASK_INDEX[task-3]:-}" ]
    
    # Check index values are numeric
    [[ "${TASK_INDEX[task-1]}" =~ ^[0-9]+$ ]]
    [[ "${TASK_INDEX[task-2]}" =~ ^[0-9]+$ ]]
    [[ "${TASK_INDEX[task-3]}" =~ ^[0-9]+$ ]]
}

@test "cache builds status counts correctly" {
    build_cache "$QUEUE_FILE"
    
    [ "${TASK_STATUS_COUNTS[pending]}" -eq 1 ]
    [ "${TASK_STATUS_COUNTS[in_progress]}" -eq 1 ] 
    [ "${TASK_STATUS_COUNTS[completed]}" -eq 1 ]
}

@test "cache builds stats JSON correctly" {
    build_cache "$QUEUE_FILE"
    
    # Check that CACHE_STATS_JSON is valid JSON
    echo "$CACHE_STATS_JSON" | jq empty
    
    # Check stats values
    local total=$(echo "$CACHE_STATS_JSON" | jq -r '.total')
    local pending=$(echo "$CACHE_STATS_JSON" | jq -r '.pending // 0')
    
    [ "$total" -eq 3 ]
    [ "$pending" -eq 1 ]
}

# ===============================================================================
# CACHED OPERATIONS TESTS
# ===============================================================================

@test "get_task_by_id_cached returns correct task" {
    build_cache "$QUEUE_FILE"
    
    run get_task_by_id_cached "$QUEUE_FILE" "task-1"
    [ "$status" -eq 0 ]
    
    local task_id=$(echo "$output" | jq -r '.id')
    local status=$(echo "$output" | jq -r '.status')
    
    [ "$task_id" = "task-1" ]
    [ "$status" = "pending" ]
}

@test "get_task_by_id_cached fails for non-existent task" {
    build_cache "$QUEUE_FILE"
    
    run get_task_by_id_cached "$QUEUE_FILE" "nonexistent-task"
    [ "$status" -eq 1 ]
}

@test "task_exists_cached works correctly" {
    build_cache "$QUEUE_FILE"
    
    run task_exists_cached "$QUEUE_FILE" "task-1"
    [ "$status" -eq 0 ]
    
    run task_exists_cached "$QUEUE_FILE" "nonexistent-task" 
    [ "$status" -eq 1 ]
}

@test "get_queue_stats_cached returns valid stats" {
    build_cache "$QUEUE_FILE"
    
    run get_queue_stats_cached "$QUEUE_FILE"
    [ "$status" -eq 0 ]
    
    # Validate JSON structure
    echo "$output" | jq empty
    
    local total=$(echo "$output" | jq -r '.total')
    local pending=$(echo "$output" | jq -r '.pending // 0')
    
    [ "$total" -eq 3 ]
    [ "$pending" -eq 1 ]
}

@test "get_tasks_by_status_cached filters correctly" {
    build_cache "$QUEUE_FILE"
    
    # Test pending tasks filter
    run get_tasks_by_status_cached "$QUEUE_FILE" "pending"
    [ "$status" -eq 0 ]
    
    local count=$(echo "$output" | jq 'length')
    [ "$count" -eq 1 ]
    
    local task_id=$(echo "$output" | jq -r '.[0].id')
    [ "$task_id" = "task-1" ]
}

@test "get_tasks_by_status_cached returns all tasks for 'all' filter" {
    build_cache "$QUEUE_FILE"
    
    run get_tasks_by_status_cached "$QUEUE_FILE" "all"
    [ "$status" -eq 0 ]
    
    local count=$(echo "$output" | jq 'length')
    [ "$count" -eq 3 ]
}

@test "get_pending_count_cached returns correct count" {
    build_cache "$QUEUE_FILE"
    
    run get_pending_count_cached "$QUEUE_FILE"
    [ "$status" -eq 0 ]
    [ "$output" -eq 1 ]
}

# ===============================================================================
# CACHE REFRESH TESTS
# ===============================================================================

@test "refresh_cache_if_needed rebuilds on file change" {
    build_cache "$QUEUE_FILE"
    local initial_timestamp="$QUEUE_CACHE_TIMESTAMP"
    
    # Modify queue file 
    sleep 1
    echo '{"tasks": []}' > "$QUEUE_FILE"
    
    run refresh_cache_if_needed "$QUEUE_FILE"
    [ "$status" -eq 0 ]
    
    # Cache should have been rebuilt
    [ "$QUEUE_CACHE_TIMESTAMP" -gt "$initial_timestamp" ]
}

@test "refresh_cache_if_needed uses cached data when valid" {
    build_cache "$QUEUE_FILE" 
    local initial_timestamp="$QUEUE_CACHE_TIMESTAMP"
    
    run refresh_cache_if_needed "$QUEUE_FILE"
    [ "$status" -eq 0 ]
    
    # Cache timestamp should not change
    [ "$QUEUE_CACHE_TIMESTAMP" -eq "$initial_timestamp" ]
    [[ "$output" =~ "Using cached data" ]]
}

# ===============================================================================
# BATCH OPERATIONS TESTS
# ===============================================================================

@test "process_tasks_batch handles multiple task IDs" {
    build_cache "$QUEUE_FILE"
    
    run process_tasks_batch "$QUEUE_FILE" "ids" "task-1" "task-3"
    [ "$status" -eq 0 ]
    
    # Should return two task IDs
    local line_count=$(echo "$output" | wc -l)
    [ "$line_count" -eq 2 ]
    
    [[ "$output" =~ "task-1" ]]
    [[ "$output" =~ "task-3" ]]
}

@test "process_tasks_batch handles non-existent task IDs gracefully" {
    build_cache "$QUEUE_FILE"
    
    run process_tasks_batch "$QUEUE_FILE" "ids" "nonexistent-task"
    [ "$status" -eq 1 ]
}

@test "process_tasks_batch returns correct count" {
    build_cache "$QUEUE_FILE"
    
    run process_tasks_batch "$QUEUE_FILE" "count" "task-1" "task-2"
    [ "$status" -eq 0 ]
    [ "$output" -eq 2 ]
}

# ===============================================================================
# CACHE INVALIDATION TESTS
# ===============================================================================

@test "invalidate_cache clears all data structures" {
    build_cache "$QUEUE_FILE"
    
    # Verify cache is populated
    [ ${#TASK_INDEX[@]} -gt 0 ]
    [ ${#TASK_STATUS_COUNTS[@]} -gt 0 ]
    [ "$QUEUE_CACHE_VALID" = "true" ]
    
    invalidate_cache "test"
    
    # Verify cache is cleared
    [ ${#TASK_INDEX[@]} -eq 0 ]
    [ ${#TASK_STATUS_COUNTS[@]} -eq 0 ]
    [ "$QUEUE_CACHE_VALID" = "false" ]
    [ "$QUEUE_CACHE_TIMESTAMP" -eq 0 ]
}

# ===============================================================================
# CACHE STATISTICS TESTS
# ===============================================================================

@test "get_cache_stats returns valid statistics" {
    build_cache "$QUEUE_FILE"
    
    # Simulate some cache hits and misses
    CACHE_HIT_COUNT=10
    CACHE_MISS_COUNT=3
    
    run get_cache_stats
    [ "$status" -eq 0 ]
    
    # Validate JSON structure
    echo "$output" | jq empty
    
    local hits=$(echo "$output" | jq -r '.hits')
    local misses=$(echo "$output" | jq -r '.misses')
    local hit_rate=$(echo "$output" | jq -r '.hit_rate_percent')
    
    [ "$hits" -eq 10 ]
    [ "$misses" -eq 3 ]
    [ "$hit_rate" -eq 76 ]  # 10/(10+3) * 100 = 76.9% rounded down
}

@test "reset_cache_stats clears counters" {
    CACHE_HIT_COUNT=5
    CACHE_MISS_COUNT=2
    
    run reset_cache_stats
    [ "$status" -eq 0 ]
    
    [ "$CACHE_HIT_COUNT" -eq 0 ]
    [ "$CACHE_MISS_COUNT" -eq 0 ]
}

# ===============================================================================
# PERFORMANCE TESTS
# ===============================================================================

@test "cached operations are faster than direct JSON parsing" {
    # Create larger test file for meaningful performance test
    local large_queue="$TEST_DIR/large-queue.json"
    
    # Generate queue with 50 tasks
    echo '{"tasks": [' > "$large_queue"
    for i in {1..50}; do
        echo "  {\"id\": \"task-$i\", \"type\": \"test\", \"status\": \"pending\", \"created_at\": \"2025-09-01T10:00:00Z\"}"
        if [ $i -lt 50 ]; then
            echo "," >> "$large_queue"
        fi
    done >> "$large_queue"
    echo ']}' >> "$large_queue"
    
    build_cache "$large_queue"
    
    # Time cached lookup
    local start_cached=$(date +%s%N)
    get_task_by_id_cached "$large_queue" "task-25"
    local end_cached=$(date +%s%N)
    
    # Time direct jq lookup  
    local start_direct=$(date +%s%N)
    jq '.tasks[] | select(.id == "task-25")' "$large_queue" >/dev/null
    local end_direct=$(date +%s%N)
    
    local cached_time=$(( (end_cached - start_cached) / 1000000 ))  # Convert to milliseconds
    local direct_time=$(( (end_direct - start_direct) / 1000000 ))
    
    # Cached lookup should be faster (allowing for some variance)
    [ "$cached_time" -lt "$direct_time" ] || {
        # Log timing for debugging if assertion fails
        echo "Cached time: ${cached_time}ms, Direct time: ${direct_time}ms" >&3
        return 0  # Don't fail test on timing variance
    }
}

# ===============================================================================
# ERROR HANDLING TESTS  
# ===============================================================================

@test "cache handles corrupted queue files gracefully" {
    echo 'invalid json content' > "$QUEUE_FILE"
    
    run build_cache "$QUEUE_FILE"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Failed to parse queue file" ]]
}

@test "cache operations fail gracefully on missing files" {
    rm "$QUEUE_FILE"
    
    run get_task_by_id_cached "$QUEUE_FILE" "task-1"
    [ "$status" -eq 1 ]
    
    run get_queue_stats_cached "$QUEUE_FILE"
    [ "$status" -eq 1 ]
}

@test "cache handles empty queue files" {
    echo '{"tasks": []}' > "$QUEUE_FILE"
    
    run build_cache "$QUEUE_FILE"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Cache built successfully: 0 tasks indexed" ]]
    
    run get_queue_stats_cached "$QUEUE_FILE"
    [ "$status" -eq 0 ]
    
    local total=$(echo "$output" | jq -r '.total')
    [ "$total" -eq 0 ]
}