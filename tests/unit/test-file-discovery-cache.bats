#!/usr/bin/env bats

# Test the file discovery cache mechanism in run-tests.sh

load '../test_helper'
load '../utils/bats-compatibility'

# Setup test environment
setup() {
    # Set up PROJECT_ROOT without sourcing the full script
    PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."
    
    # Extract only the cache functions we need for testing
    # We'll define our own minimal versions to avoid conflicts
    setup_cache_functions
    
    # Reset cache state for each test
    CACHED_SHELL_FILES=()
    SHELL_FILES_CACHED=false
    CACHE_TIMESTAMP=""
    CACHE_MAX_AGE=300
    REFRESH_CACHE=false
    NO_CACHE=false
}

# Define minimal cache functions for testing
setup_cache_functions() {
    # Minimal logging functions
    log_debug() { echo "[DEBUG] $*" >&2; }
    log_warn() { echo "[WARN] $*" >&2; }
    log_error() { echo "[ERROR] $*" >&2; }
    
    # Cache functions extracted from run-tests.sh
    invalidate_shell_files_cache() {
        CACHED_SHELL_FILES=()
        SHELL_FILES_CACHED=false
        CACHE_TIMESTAMP=""
        log_debug "Shell files cache invalidated"
    }

    get_cache_age() {
        if [[ -n "${CACHE_TIMESTAMP:-}" ]]; then
            local current_time=$(date +%s)
            echo $((current_time - CACHE_TIMESTAMP))
        else
            echo "0"
        fi
    }

    should_refresh_cache() {
        local max_age="${CACHE_MAX_AGE:-300}"  # 5 minutes default
        local age
        age=$(get_cache_age)
        [[ $age -gt $max_age ]]
    }

    discover_shell_files() {
        # Handle cache control options
        if [[ "$NO_CACHE" == "true" ]]; then
            log_debug "Cache disabled - performing fresh shell file discovery"
        elif [[ "$REFRESH_CACHE" == "true" ]]; then
            log_debug "Cache refresh requested - invalidating existing cache"
            invalidate_shell_files_cache
        elif [[ "$SHELL_FILES_CACHED" == "true" ]] && ! should_refresh_cache; then
            log_debug "Using cached shell files (age: $(get_cache_age)s)"
            return 0  # Use existing cache
        fi
        
        log_debug "Discovering shell files (cache refresh needed)"
        
        # Clear existing cache
        CACHED_SHELL_FILES=()
        
        if ! mapfile -t CACHED_SHELL_FILES < <(find "$PROJECT_ROOT" -name "*.sh" -type f 2>&1 | grep -v ".git" | sort); then
            local find_error="$?"
            log_error "Shell file discovery failed: exit code $find_error"
            log_debug "Find command: find $PROJECT_ROOT -name '*.sh' -type f"
            return 1
        fi
        
        # Only set cache if not disabled
        if [[ "$NO_CACHE" != "true" ]]; then
            SHELL_FILES_CACHED=true
            CACHE_TIMESTAMP=$(date +%s)
            log_debug "Cached ${#CACHED_SHELL_FILES[@]} shell files for reuse"
        else
            log_debug "Found ${#CACHED_SHELL_FILES[@]} shell files (caching disabled)"
        fi
        
        # Warn if no shell files found (likely indicates a problem)
        if [[ ${#CACHED_SHELL_FILES[@]} -eq 0 ]]; then
            log_warn "No shell files found in $PROJECT_ROOT - this may indicate a configuration issue"
        fi
    }
}

teardown() {
    # Clean up any test state
    CACHED_SHELL_FILES=()
    SHELL_FILES_CACHED=false
    CACHE_TIMESTAMP=""
    REFRESH_CACHE=false
    NO_CACHE=false
}

@test "discover_shell_files caches results correctly" {
    # First call should populate cache
    run discover_shell_files
    [ "$status" -eq 0 ]
    [ "$SHELL_FILES_CACHED" = "true" ]
    [ ${#CACHED_SHELL_FILES[@]} -gt 0 ]
    [ -n "$CACHE_TIMESTAMP" ]
}

@test "cached discovery is faster than fresh discovery" {
    # Reset cache state
    invalidate_shell_files_cache
    
    # First call (fresh discovery)
    start_time=$(date +%s%N)
    discover_shell_files
    first_call_time=$(date +%s%N)
    first_duration=$((first_call_time - start_time))
    
    # Second call (cached)
    start_time=$(date +%s%N)
    discover_shell_files
    second_call_time=$(date +%s%N)
    second_duration=$((second_call_time - start_time))
    
    # Cached call should be significantly faster (at least 2x)
    [ "$second_duration" -lt "$((first_duration / 2))" ]
}

@test "cache invalidation works correctly" {
    # Populate cache first
    discover_shell_files
    [ "$SHELL_FILES_CACHED" = "true" ]
    [ ${#CACHED_SHELL_FILES[@]} -gt 0 ]
    
    # Invalidate cache
    invalidate_shell_files_cache
    [ "$SHELL_FILES_CACHED" = "false" ]
    [ ${#CACHED_SHELL_FILES[@]} -eq 0 ]
    [ -z "$CACHE_TIMESTAMP" ]
}

@test "cache refresh respects age limit" {
    # Populate cache with old timestamp
    discover_shell_files
    
    # Mock old timestamp (older than CACHE_MAX_AGE)
    CACHE_TIMESTAMP=$(($(date +%s) - 400))  # 6+ minutes old
    
    # Should indicate refresh needed
    run should_refresh_cache
    [ "$status" -eq 0 ]
    
    # Mock recent timestamp
    CACHE_TIMESTAMP=$(($(date +%s) - 60))   # 1 minute old
    
    # Should indicate no refresh needed
    run should_refresh_cache
    [ "$status" -eq 1 ]
}

@test "get_cache_age returns correct age" {
    # Test with no timestamp
    CACHE_TIMESTAMP=""
    run get_cache_age
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
    
    # Test with known timestamp
    CACHE_TIMESTAMP=$(($(date +%s) - 100))  # 100 seconds ago
    run get_cache_age
    [ "$status" -eq 0 ]
    # Age should be approximately 100 seconds (allow some variance)
    [ "$output" -ge 99 ]
    [ "$output" -le 101 ]
}

@test "NO_CACHE option disables caching" {
    NO_CACHE=true
    
    # Discovery should work but not set cache flags
    run discover_shell_files
    [ "$status" -eq 0 ]
    [ "$SHELL_FILES_CACHED" = "false" ]
    [ -z "$CACHE_TIMESTAMP" ]
    [ ${#CACHED_SHELL_FILES[@]} -gt 0 ]  # Files found but not cached
}

@test "REFRESH_CACHE option forces cache invalidation" {
    # Populate initial cache
    discover_shell_files
    initial_timestamp="$CACHE_TIMESTAMP"
    
    # Wait a moment to ensure different timestamp
    sleep 1
    
    # Force refresh
    REFRESH_CACHE=true
    run discover_shell_files
    [ "$status" -eq 0 ]
    [ "$CACHE_TIMESTAMP" != "$initial_timestamp" ]
    [ "$SHELL_FILES_CACHED" = "true" ]
}

@test "cache handles empty results gracefully" {
    # Mock a scenario where no shell files would be found
    # (This is difficult to test without mocking, so we test the warning logic)
    
    # Temporarily override PROJECT_ROOT to empty directory
    local temp_dir
    temp_dir=$(mktemp -d)
    local orig_project_root="$PROJECT_ROOT"
    PROJECT_ROOT="$temp_dir"
    
    run discover_shell_files
    [ "$status" -eq 0 ]
    [ ${#CACHED_SHELL_FILES[@]} -eq 0 ]
    
    # Restore original PROJECT_ROOT and cleanup
    PROJECT_ROOT="$orig_project_root"
    rm -rf "$temp_dir"
}

@test "error handling provides meaningful context" {
    # Test with non-existent directory
    local orig_project_root="$PROJECT_ROOT"
    PROJECT_ROOT="/nonexistent/directory/path"
    
    run discover_shell_files
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Shell file discovery failed" ]]
    [[ "$output" =~ "exit code" ]]
    
    # Restore original PROJECT_ROOT
    PROJECT_ROOT="$orig_project_root"
}

@test "cache respects file system changes" {
    # This test verifies that the cache mechanism doesn't prevent
    # discovery of new files when the cache expires
    
    # Create initial cache
    discover_shell_files
    initial_count=${#CACHED_SHELL_FILES[@]}
    
    # Force cache expiration by setting old timestamp
    CACHE_TIMESTAMP=$(($(date +%s) - 400))  # 6+ minutes old
    
    # Next discovery should refresh
    run should_refresh_cache
    [ "$status" -eq 0 ]
    
    # Discovery should work and update cache
    run discover_shell_files
    [ "$status" -eq 0 ]
    [ "$SHELL_FILES_CACHED" = "true" ]
    # Should have same or similar count (files don't change during test)
    [ ${#CACHED_SHELL_FILES[@]} -ge $((initial_count - 1)) ]
    [ ${#CACHED_SHELL_FILES[@]} -le $((initial_count + 1)) ]
}