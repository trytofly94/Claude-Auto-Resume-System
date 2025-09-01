# Task Queue Efficiency Optimization - Issue #116

**Date**: 2025-09-01  
**Issue**: [#116 - Efficiency: Streamline task queue processing and reduce JSON parsing overhead](https://github.com/trytofly94/Claude-Auto-Resume-System/issues/116)  
**Status**: Active  
**Priority**: High  

## Problem Analysis

### Current Performance Bottlenecks

Through analysis of the task queue implementation, I've identified the following performance issues:

1. **Excessive JSON Parsing**: 
   - Multiple functions parse the same queue file repeatedly
   - Each status check re-parses the entire queue JSON
   - No caching mechanism between operations

2. **Inefficient File Access Patterns**:
   - `list_tasks()` always reads entire queue file
   - Status queries like `get_local_queue_stats()` parse entire JSON multiple times
   - Each task lookup requires full file parsing

3. **Suboptimal jq Usage**:
   - Multiple separate jq calls for related data
   - Complex patterns like `jq '[.tasks[] | select(.status == "pending")] | length'` repeated
   - No batch processing for multiple task operations

4. **Memory Inefficiency**:
   - No in-memory caching of frequently accessed data
   - Temporary variables created/destroyed repeatedly
   - Large JSON structures copied multiple times

### Performance Impact Areas

**High Impact Files**:
- `src/task-queue.sh` (main command interface)
- `src/queue/local-operations.sh` (local queue operations)  
- `src/local-queue.sh` (local queue core)
- `src/queue/persistence.sh` (file I/O operations)

**Critical Functions**:
- `get_local_queue_stats()` - 5 separate jq calls
- `list_local_tasks()` - Full file parsing for filtering
- `cmd_list_tasks()` - Redundant parsing in display logic
- Task validation functions - Repeated JSON structure validation

## Solution Architecture

### 1. Queue Data Caching System

**Cache Layer Design**:
```bash
# Cache file locations
QUEUE_CACHE_DIR="$HOME/.claude-queue-cache"
GLOBAL_QUEUE_CACHE="$QUEUE_CACHE_DIR/global-cache"
LOCAL_QUEUE_CACHE="$QUEUE_CACHE_DIR/local-cache"

# Cache data structures
declare -gA QUEUE_CACHE_DATA=()
declare -g QUEUE_CACHE_TIMESTAMP=0
declare -g QUEUE_CACHE_VALID=false
```

**Cache Invalidation Strategy**:
- File modification time comparison
- Atomic cache updates
- Graceful degradation on cache miss

### 2. Optimized JSON Processing

**Single-Pass Operations**:
```bash
# Current inefficient pattern (5 jq calls):
local task_count=$(jq '.tasks | length' "$queue_file")
local pending_count=$(jq '[.tasks[] | select(.status == "pending")] | length' "$queue_file")
local in_progress_count=$(jq '[.tasks[] | select(.status == "in_progress")] | length' "$queue_file")
local completed_count=$(jq '[.tasks[] | select(.status == "completed")] | length' "$queue_file")
local failed_count=$(jq '[.tasks[] | select(.status == "failed")] | length' "$queue_file")

# Optimized single-pass pattern (1 jq call):
get_queue_summary_optimized() {
    local queue_file="$1"
    jq -r '
        .tasks | 
        group_by(.status) | 
        map({
            status: .[0].status,
            count: length
        }) |
        reduce .[] as $item ({}; .[$item.status] = $item.count) |
        . + {total: (. | add)}
    ' "$queue_file"
}
```

**Batch Processing Implementation**:
```bash
# Process multiple tasks in single operation
process_multiple_tasks() {
    local operation="$1"
    shift
    local task_ids=("$@")
    
    # Build jq filter for multiple tasks
    local filter=".tasks[] | select(.id | IN("
    filter+=$(printf '"%s";' "${task_ids[@]}")
    filter=${filter%;}"))"
    
    jq -c "$filter" "$queue_file"
}
```

### 3. Memory-Resident Cache Architecture

**In-Memory Data Structures**:
```bash
# Lightweight task index for fast lookup
declare -gA TASK_INDEX=()  # task_id -> array_position
declare -gA TASK_STATUS_COUNTS=()  # status -> count
declare -g CACHE_STATS_JSON=""  # Pre-computed stats JSON

# Fast task lookup without file parsing
get_task_by_id_cached() {
    local task_id="$1"
    
    if [[ -n "${TASK_INDEX[$task_id]:-}" ]]; then
        local position="${TASK_INDEX[$task_id]}"
        jq -r ".tasks[$position]" "$queue_file"
    else
        return 1
    fi
}
```

**Smart Cache Refresh**:
```bash
refresh_cache_if_needed() {
    local queue_file="$1"
    local current_mtime
    
    current_mtime=$(stat -f %m "$queue_file" 2>/dev/null || echo 0)
    
    if [[ $current_mtime -gt $QUEUE_CACHE_TIMESTAMP ]] || [[ "$QUEUE_CACHE_VALID" != "true" ]]; then
        rebuild_task_cache "$queue_file"
        QUEUE_CACHE_TIMESTAMP=$current_mtime
        QUEUE_CACHE_VALID="true"
    fi
}
```

## Implementation Plan

### Phase 1: Core Cache Implementation (Priority 1)

**File**: `src/queue/cache.sh` (new)
- Implement cache data structures
- Add cache validation and invalidation logic  
- Create cache rebuild functions
- Add graceful degradation for cache failures

**File**: `src/queue/core.sh` (modify)
- Integrate cache layer into core operations
- Update task existence checks to use cache
- Modify task retrieval to check cache first

### Phase 2: Optimize Critical Functions (Priority 1)

**File**: `src/queue/local-operations.sh` (optimize)
- Replace 5 separate jq calls in `get_local_queue_stats()` with single-pass operation
- Implement batch processing for `list_local_tasks()`
- Add caching to `get_local_task()` function

**File**: `src/local-queue.sh` (optimize)
- Optimize `get_local_queue_stats()` to use cached data
- Update `local_task_exists()` to use index lookup
- Implement fast path for common operations

### Phase 3: Command Interface Optimization (Priority 2)

**File**: `src/task-queue.sh` (optimize)
- Update `cmd_list_tasks()` to use optimized queries
- Implement batch operations for multiple task commands
- Add performance monitoring to command execution

### Phase 4: Advanced Optimizations (Priority 3)

**Streaming for Large Queues**:
```bash
# For queues with 100+ tasks, use streaming processing
stream_pending_tasks() {
    jq -c --stream 'select(.[0][1] == "status" and .[1] == "pending") | .[0][0]' "$queue_file" |
    while read -r task_index; do
        jq -r ".tasks[$task_index].id" "$queue_file"
    done
}
```

**Index Files for Ultra-Fast Lookup**:
```bash
# Maintain separate index files for O(1) lookups
QUEUE_INDEX_FILE="$queue_file.index"
# Format: task_id:line_number:status:priority
```

## Performance Targets

### Current Benchmarks (Estimated)
- `get_local_queue_stats()`: ~150ms with 50 tasks (5 jq calls)
- `list_tasks pending`: ~80ms with 50 tasks (full file scan)
- Task lookup by ID: ~50ms (full file search)

### Target Performance (Post-Optimization)
- `get_local_queue_stats()`: ~30ms with 50 tasks (single jq call + cache)
- `list_tasks pending`: ~10ms with 50 tasks (cache lookup)
- Task lookup by ID: ~5ms (index lookup)

**Overall Target**: 3-5x performance improvement for common operations

## Testing Strategy

### Performance Tests
- Benchmark existing functions before changes
- Create test queues with 10, 50, 100, 500 tasks
- Measure operations per second for key functions
- Validate memory usage patterns

### Integration Tests
- Ensure all existing functionality works with caching
- Test cache invalidation scenarios
- Verify fallback behavior when cache is corrupted
- Test concurrent access patterns

### Stress Tests
- Large queue handling (1000+ tasks)
- Rapid successive operations
- Cache invalidation under load
- Memory leak detection

## Risk Mitigation

### Backward Compatibility
- All optimizations maintain existing API
- Graceful degradation if cache fails
- Fallback to original implementation on errors

### Data Integrity
- Atomic cache updates prevent corruption
- Cache validation on every access
- Original file remains authoritative source

### Memory Management
- Cache size limits to prevent memory exhaustion
- Automatic cleanup of stale cache entries
- Memory usage monitoring and reporting

## Success Criteria

1. **Performance**: 3x improvement in common queue operations
2. **Reliability**: All existing tests pass without modification
3. **Scalability**: No performance degradation with 100+ tasks
4. **Memory**: Stable memory usage under extended operation
5. **Compatibility**: Zero breaking changes to existing API

## Implementation Notes

- Use `set -euo pipefail` for all new cache functions
- Implement comprehensive error handling and logging
- Add debug mode for cache operations diagnostics
- Document all performance optimizations for future maintenance

---

**Next Steps**: Begin Phase 1 implementation with core cache system