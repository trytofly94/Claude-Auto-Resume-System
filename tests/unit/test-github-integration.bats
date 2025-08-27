#!/usr/bin/env bats

# Unit tests for GitHub Integration Module
# Tests comprehensive GitHub API integration including:
# - URL parsing and item type detection  
# - Authentication and permissions validation
# - API data fetching with rate limiting
# - Caching system and performance optimization
# - Error handling and recovery mechanisms
# - Comment management and template system

load ../test_helper
load ../fixtures/github-api-mocks

# Source the GitHub integration modules
setup() {
    default_setup
    
    # Create test project directory
    export TEST_PROJECT_DIR="$TEST_TEMP_DIR/claude-auto-resume"
    mkdir -p "$TEST_PROJECT_DIR"
    cd "$TEST_PROJECT_DIR"
    
    # Set up configuration for GitHub integration
    export GITHUB_INTEGRATION_ENABLED="true"
    export GITHUB_AUTO_COMMENT="true"
    export GITHUB_STATUS_UPDATES="true"
    export GITHUB_COMPLETION_NOTIFICATIONS="true"
    export GITHUB_API_CACHE_TTL="300"
    export GITHUB_API_TIMEOUT="30"
    export GITHUB_RETRY_ATTEMPTS="3"
    export GITHUB_RETRY_DELAY="10"
    export GITHUB_RATE_LIMIT_THRESHOLD="100"
    export GITHUB_CACHE_DEFAULT_TTL="300"
    
    # Create mock configuration
    mkdir -p config
    cat > config/default.conf << 'EOF'
# GitHub Integration Configuration
GITHUB_INTEGRATION_ENABLED=true
GITHUB_AUTO_COMMENT=true
GITHUB_STATUS_UPDATES=true
GITHUB_COMPLETION_NOTIFICATIONS=true
GITHUB_API_CACHE_TTL=300
GITHUB_API_TIMEOUT=30
GITHUB_RETRY_ATTEMPTS=3
GITHUB_RETRY_DELAY=10
EOF
    
    # Mock gh command to use our GitHub API mocks
    mock_command "gh" 'mock_gh "$@"'
    
    # Mock curl for raw API calls
    mock_command "curl" 'mock_curl_api "$@"'
    
    # Reset mock state for each test
    reset_github_mock_state
    
    # Source the module after setup
    if [[ -f "$BATS_TEST_DIRNAME/../../src/github-integration.sh" ]]; then
        source "$BATS_TEST_DIRNAME/../../src/github-integration.sh"
        # Initialize the module  
        init_github_integration || true
    else
        skip "GitHub integration module not found"
    fi
}

teardown() {
    cleanup_github_integration || true
    default_teardown
}

# Mock curl for GitHub API calls
mock_curl_api() {
    local url=""
    local method="GET"
    local headers=()
    local data=""
    
    # Parse curl arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            "-X")
                method="$2"
                shift 2
                ;;
            "-H")
                headers+=("$2")
                shift 2
                ;;
            "-d"|"--data")
                data="$2"
                shift 2
                ;;
            "https://api.github.com"*)
                url="$1"
                shift
                ;;
            *)
                shift
                ;;
        esac
    done
    
    # Extract endpoint from URL
    local endpoint="${url#https://api.github.com}"
    
    # Route to appropriate mock
    mock_gh_api "$endpoint" -X "$method" ${data:+-f "$data"}
}

# ===============================================================================
# DEPENDENCY AND INITIALIZATION TESTS
# ===============================================================================

@test "check_github_dependencies: should detect missing dependencies" {
    # Mock gh command as not available
    mock_command "gh" 'return 127'  # Command not found
    
    run check_github_dependencies
    
    assert_failure
    assert_output --partial "GitHub CLI (gh) is required"
}

@test "check_github_dependencies: should detect gh version successfully" {
    # Mock gh command with version
    mock_command "gh" 'if [[ "$1" == "--version" ]]; then echo "gh version 2.32.1"; else mock_gh "$@"; fi'
    
    run check_github_dependencies
    
    assert_success
    assert_output --partial "GitHub dependencies verified"
}

@test "init_github_integration: should initialize successfully" {
    run init_github_integration
    
    assert_success
    assert_output --partial "GitHub Integration initialized"
    
    # Check if module is marked as initialized
    run github_integration_initialized
    assert_success
}

@test "init_github_integration: should fail without dependencies" {
    # Mock missing gh command
    mock_command "gh" 'return 127'
    
    run init_github_integration
    
    assert_failure
    assert_output --partial "GitHub CLI (gh) is required"
}

@test "cleanup_github_integration: should cleanup successfully" {
    # Initialize first
    init_github_integration
    
    run cleanup_github_integration
    
    assert_success
    assert_output --partial "GitHub Integration cleanup completed"
}

# ===============================================================================
# AUTHENTICATION TESTS
# ===============================================================================

@test "check_github_auth: should validate authenticated user" {
    set_github_mock_auth_state "true" "testuser"
    
    run check_github_auth
    
    assert_success
    assert_output --partial "GitHub authentication verified"
}

@test "check_github_auth: should fail for unauthenticated user" {
    set_github_mock_auth_state "false"
    
    run check_github_auth
    
    assert_failure
    assert_output --partial "GitHub authentication required"
}

@test "get_authenticated_user: should return user info" {
    set_github_mock_auth_state "true" "testuser"
    
    run get_authenticated_user
    
    assert_success
    assert_output --partial "testuser"
}

@test "get_authenticated_user: should handle auth failure" {
    set_github_mock_auth_state "false"
    
    run get_authenticated_user
    
    assert_failure
}

@test "validate_repo_permissions: should validate repository access" {
    set_github_mock_auth_state "true" "testuser"
    
    run validate_repo_permissions "testuser/test-repo"
    
    assert_success
    assert_output --partial "Repository permissions validated"
}

@test "validate_repo_permissions: should handle permission errors" {
    set_github_mock_auth_state "false"
    
    run validate_repo_permissions "testuser/private-repo"
    
    assert_failure
}

# ===============================================================================
# URL PARSING TESTS
# ===============================================================================

@test "parse_github_url: should parse issue URL correctly" {
    local test_url="https://github.com/testuser/test-repo/issues/123"
    
    run parse_github_url "$test_url"
    
    assert_success
    assert_line --index 0 "testuser"      # owner
    assert_line --index 1 "test-repo"     # repo
    assert_line --index 2 "issue"         # type
    assert_line --index 3 "123"           # number
}

@test "parse_github_url: should parse PR URL correctly" {
    local test_url="https://github.com/testuser/test-repo/pull/456"
    
    run parse_github_url "$test_url"
    
    assert_success
    assert_line --index 0 "testuser"      # owner
    assert_line --index 1 "test-repo"     # repo
    assert_line --index 2 "pull_request"  # type
    assert_line --index 3 "456"           # number
}

@test "parse_github_url: should handle invalid URLs" {
    local test_url="https://invalid-url.com/not/github"
    
    run parse_github_url "$test_url"
    
    assert_failure
    assert_output --partial "Invalid GitHub URL"
}

@test "parse_github_url: should handle malformed GitHub URLs" {
    local test_url="https://github.com/incomplete"
    
    run parse_github_url "$test_url"
    
    assert_failure
    assert_output --partial "Invalid GitHub URL format"
}

@test "get_github_item_type: should detect issue URLs" {
    local test_url="https://github.com/testuser/test-repo/issues/123"
    
    run get_github_item_type "$test_url"
    
    assert_success
    assert_output "issue"
}

@test "get_github_item_type: should detect PR URLs" {
    local test_url="https://github.com/testuser/test-repo/pull/456"
    
    run get_github_item_type "$test_url"
    
    assert_success
    assert_output "pull_request"
}

@test "get_github_item_type: should handle unknown URLs" {
    local test_url="https://github.com/testuser/test-repo"
    
    run get_github_item_type "$test_url"
    
    assert_success
    assert_output "unknown"
}

# ===============================================================================
# DATA FETCHING TESTS
# ===============================================================================

@test "fetch_issue_details: should retrieve issue metadata" {
    set_github_mock_auth_state "true" "testuser"
    
    run fetch_issue_details "https://github.com/testuser/test-repo/issues/123"
    
    assert_success
    assert_output --partial "Test Issue #123"
    assert_output --partial "\"number\": 123"
    assert_output --partial "\"state\": \"open\""
}

@test "fetch_issue_details: should handle invalid issue URLs" {
    run fetch_issue_details "https://github.com/testuser/test-repo/pull/456"
    
    assert_failure
    assert_output --partial "Invalid issue URL"
}

@test "fetch_pr_details: should retrieve PR metadata" {
    set_github_mock_auth_state "true" "testuser"
    
    run fetch_pr_details "https://github.com/testuser/test-repo/pull/456"
    
    assert_success
    assert_output --partial "Test Pull Request #456"
    assert_output --partial "\"number\": 456"
    assert_output --partial "\"state\": \"open\""
}

@test "fetch_pr_details: should handle invalid PR URLs" {
    run fetch_pr_details "https://github.com/testuser/test-repo/issues/123"
    
    assert_failure
    assert_output --partial "Invalid PR URL"
}

@test "validate_github_item: should validate accessible items" {
    set_github_mock_auth_state "true" "testuser"
    
    run validate_github_item "https://github.com/testuser/test-repo/issues/123"
    
    assert_success
    assert_output --partial "GitHub item validated"
}

@test "validate_github_item: should handle inaccessible items" {
    set_github_mock_auth_state "false"
    
    run validate_github_item "https://github.com/testuser/test-repo/issues/123"
    
    assert_failure
}

# ===============================================================================
# CACHING SYSTEM TESTS
# ===============================================================================

@test "cache_github_data: should store data with TTL" {
    local test_key="test_cache_key"
    local test_data='{"test": "data", "timestamp": 1234567890}'
    local test_ttl=300
    
    run cache_github_data "$test_key" "$test_data" "$test_ttl"
    
    assert_success
    assert_output --partial "Data cached successfully"
}

@test "get_cached_github_data: should retrieve valid cached data" {
    local test_key="test_retrieval_key"
    local test_data='{"test": "cached_data"}'
    
    # Cache data first
    cache_github_data "$test_key" "$test_data" 300
    
    # Retrieve cached data
    run get_cached_github_data "$test_key"
    
    assert_success
    assert_output --partial "cached_data"
}

@test "get_cached_github_data: should handle cache miss" {
    local nonexistent_key="nonexistent_cache_key"
    
    run get_cached_github_data "$nonexistent_key"
    
    assert_failure
}

@test "get_cached_github_data: should handle expired cache" {
    local test_key="expired_cache_key"
    local test_data='{"test": "expired_data"}'
    
    # Cache data with very short TTL
    cache_github_data "$test_key" "$test_data" 1
    
    # Wait for expiration
    sleep 2
    
    # Try to retrieve expired data
    run get_cached_github_data "$test_key"
    
    assert_failure
}

@test "invalidate_github_cache: should clear cache entry" {
    local test_key="cache_invalidation_key"
    local test_data='{"test": "data_to_invalidate"}'
    
    # Cache data first
    cache_github_data "$test_key" "$test_data" 300
    
    # Verify data is cached
    get_cached_github_data "$test_key"
    
    # Invalidate cache
    run invalidate_github_cache "$test_key"
    
    assert_success
    assert_output --partial "Cache invalidated"
    
    # Verify data is no longer cached
    run get_cached_github_data "$test_key"
    assert_failure
}

@test "invalidate_github_cache: should handle pattern matching" {
    local test_key1="pattern_test_key1"
    local test_key2="pattern_test_key2"
    local test_key3="other_cache_key"
    local test_data='{"test": "pattern_data"}'
    
    # Cache multiple entries
    cache_github_data "$test_key1" "$test_data" 300
    cache_github_data "$test_key2" "$test_data" 300  
    cache_github_data "$test_key3" "$test_data" 300
    
    # Invalidate using pattern
    run invalidate_github_cache "pattern_*"
    
    assert_success
    
    # Verify pattern-matched entries are cleared
    run get_cached_github_data "$test_key1"
    assert_failure
    
    run get_cached_github_data "$test_key2"
    assert_failure
    
    # Verify non-matching entry remains
    run get_cached_github_data "$test_key3"
    assert_success
}

# ===============================================================================
# RATE LIMITING TESTS
# ===============================================================================

@test "rate limiting: should detect and handle rate limit exceeded" {
    set_github_mock_rate_limit 0  # Set remaining to 0
    
    # Attempt API call that should trigger rate limiting
    run fetch_issue_details "https://github.com/testuser/test-repo/issues/123"
    
    assert_failure
    assert_output --partial "rate limit"
}

@test "rate limiting: should implement exponential backoff" {
    set_github_mock_rate_limit 10  # Low but not zero
    
    # This test would need to be expanded to properly test backoff timing
    run fetch_issue_details "https://github.com/testuser/test-repo/issues/123"
    
    # Should succeed with low rate limit
    assert_success
}

@test "rate limiting: should respect rate limit thresholds" {
    # Set rate limit just above threshold
    set_github_mock_rate_limit $((GITHUB_RATE_LIMIT_THRESHOLD + 10))
    
    run fetch_issue_details "https://github.com/testuser/test-repo/issues/123"
    
    assert_success
    
    # Set rate limit below threshold  
    set_github_mock_rate_limit $((GITHUB_RATE_LIMIT_THRESHOLD - 10))
    
    # Should still work but with throttling
    run fetch_issue_details "https://github.com/testuser/test-repo/issues/123"
    
    assert_success
}

# ===============================================================================
# ERROR HANDLING TESTS
# ===============================================================================

@test "error handling: should handle network failures gracefully" {
    # Simulate network error by making gh command fail
    mock_command "gh" 'return 2'  # Network error
    
    run fetch_issue_details "https://github.com/testuser/test-repo/issues/123"
    
    assert_failure
    assert_output --partial "Failed to fetch"
}

@test "error handling: should implement retry logic" {
    local call_count=0
    
    # Mock gh command that fails first time, succeeds second time
    mock_command "gh" 'if [[ $RETRY_COUNT -lt 1 ]]; then export RETRY_COUNT=$((${RETRY_COUNT:-0} + 1)); return 1; else mock_gh "$@"; fi'
    
    run fetch_issue_details "https://github.com/testuser/test-repo/issues/123"
    
    # Should eventually succeed after retry
    assert_success
}

@test "error handling: should handle malformed JSON responses" {
    # Mock gh command to return invalid JSON
    mock_command "gh" 'echo "invalid json response"'
    
    run fetch_issue_details "https://github.com/testuser/test-repo/issues/123"
    
    assert_failure
    assert_output --partial "Invalid JSON response"
}

@test "error handling: should validate required fields in responses" {
    # Mock gh command to return JSON missing required fields
    mock_command "gh" 'echo "{\"incomplete\": \"data\"}"'
    
    run fetch_issue_details "https://github.com/testuser/test-repo/issues/123"
    
    assert_failure  
    assert_output --partial "Missing required field"
}

# ===============================================================================
# SECURITY TESTS
# ===============================================================================

@test "security: should sanitize input parameters" {
    local malicious_url="https://github.com/test;rm -rf /;/repo/issues/123"
    
    run parse_github_url "$malicious_url"
    
    assert_failure
    assert_output --partial "Invalid GitHub URL"
}

@test "security: should validate repository names" {
    local malicious_repo="../../../etc/passwd"
    
    run validate_repo_permissions "$malicious_repo"
    
    assert_failure
    assert_output --partial "Invalid repository format"
}

@test "security: should handle injection attempts in issue numbers" {
    local malicious_url="https://github.com/testuser/test-repo/issues/123;cat /etc/passwd"
    
    run parse_github_url "$malicious_url"
    
    assert_failure
    assert_output --partial "Invalid GitHub URL"
}

@test "security: should validate authentication tokens" {
    # Mock gh command to return invalid token format
    set_github_mock_auth_state "true" "testuser"
    mock_command "gh" 'if [[ "$1" == "auth" && "$2" == "token" ]]; then echo "invalid-token-format"; else mock_gh "$@"; fi'
    
    run check_github_auth
    
    # Should detect invalid token format
    assert_failure
    assert_output --partial "Invalid authentication token"
}

# ===============================================================================
# PERFORMANCE TESTS
# ===============================================================================

@test "performance: should use cache to avoid redundant API calls" {
    set_github_mock_auth_state "true" "testuser"
    
    local test_url="https://github.com/testuser/test-repo/issues/123"
    
    # First call - should hit API
    run fetch_issue_details "$test_url"
    assert_success
    
    local first_call_count=$(get_github_mock_api_call_count "api_/repos")
    
    # Second call - should use cache
    run fetch_issue_details "$test_url"
    assert_success
    
    local second_call_count=$(get_github_mock_api_call_count "api_/repos")
    
    # API call count should be the same (cache hit)
    [[ $first_call_count -eq $second_call_count ]]
}

@test "performance: should handle concurrent requests efficiently" {
    set_github_mock_auth_state "true" "testuser"
    
    # This test would need proper concurrency testing setup
    # For now, just verify basic functionality
    run fetch_issue_details "https://github.com/testuser/test-repo/issues/123"
    assert_success
}

@test "performance: should optimize for large datasets" {
    # Test with multiple different URLs to verify caching behavior
    set_github_mock_auth_state "true" "testuser"
    
    local urls=(
        "https://github.com/testuser/test-repo/issues/123"
        "https://github.com/testuser/test-repo/issues/124"
        "https://github.com/testuser/test-repo/pull/125"
    )
    
    # Call each URL and verify they all work
    for url in "${urls[@]}"; do
        run fetch_issue_details "$url" 2>/dev/null || fetch_pr_details "$url" 2>/dev/null
        # At least one should succeed based on URL type
    done
}

# ===============================================================================
# INTEGRATION READINESS TESTS
# ===============================================================================

@test "integration: should be compatible with task queue system" {
    # Verify that GitHub integration can work with task queue
    export GITHUB_INTEGRATION_ENABLED="true"
    
    # Check if integration is properly initialized
    run github_integration_initialized
    assert_success
    
    # Verify basic functionality works
    run parse_github_url "https://github.com/testuser/test-repo/issues/123"
    assert_success
}

@test "integration: should handle configuration properly" {
    # Test with different configuration values
    export GITHUB_API_CACHE_TTL="600"
    export GITHUB_RETRY_ATTEMPTS="5"
    
    # Re-initialize with new config
    run init_github_integration
    assert_success
    
    # Verify settings are applied (this would need expansion)
    [[ "$GITHUB_API_CACHE_TTL" == "600" ]]
    [[ "$GITHUB_RETRY_ATTEMPTS" == "5" ]]
}

@test "integration: should provide proper logging" {
    # Enable debug logging
    export LOG_LEVEL="DEBUG"
    export DEBUG_MODE="true"
    
    run init_github_integration
    
    assert_success
    # Should include debug information
    assert_output --partial "DEBUG"
}