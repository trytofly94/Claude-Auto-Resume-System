#!/usr/bin/env bash

# Test Suite for Per-Project Session Management (Issue #89)
# Tests the core functionality of project-aware session isolation
# Version: 1.0.0

set -euo pipefail

# Test configuration
TEST_NAME="Per-Project Session Management"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_TEMP_DIR="/tmp/claude-test-$$"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Stub logging functions to avoid dependency issues
log_debug() { echo "[DEBUG] $*" >&2; }
log_info() { echo "[INFO] $*" >&2; }
log_warn() { echo "[WARN] $*" >&2; }
log_error() { echo "[ERROR] $*" >&2; }

# Source the modules we want to test
source "$PROJECT_ROOT/src/session-manager.sh"

# Initialize test environment
setup_test_environment() {
    echo -e "${YELLOW}Setting up test environment${NC}"
    
    # Create temporary test directories
    mkdir -p "$TEST_TEMP_DIR"/{project-a,project-b,"project with spaces"}
    
    # Initialize session arrays
    init_session_arrays || {
        echo -e "${RED}Failed to initialize session arrays${NC}"
        exit 1
    }
    
    echo "✓ Test environment initialized"
}

# Cleanup test environment
cleanup_test_environment() {
    echo -e "${YELLOW}Cleaning up test environment${NC}"
    
    # Remove test session files
    rm -f "$HOME"/.claude_session_*test* 2>/dev/null || true
    rm -f "$HOME"/.claude_session_*test*.metadata 2>/dev/null || true
    
    # Remove temporary directories
    rm -rf "$TEST_TEMP_DIR" 2>/dev/null || true
    
    echo "✓ Test environment cleaned up"
}

# Test helper functions
run_test() {
    local test_name="$1"
    local test_function="$2"
    
    echo ""
    echo -e "${YELLOW}Running test: $test_name${NC}"
    ((TESTS_RUN++))
    
    if "$test_function"; then
        echo -e "${GREEN}✓ PASS: $test_name${NC}"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}✗ FAIL: $test_name${NC}"
        ((TESTS_FAILED++))
    fi
}

# Assert functions
assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="${3:-Values should be equal}"
    
    if [[ "$expected" == "$actual" ]]; then
        echo "  ✓ $message"
        return 0
    else
        echo "  ✗ $message"
        echo "    Expected: '$expected'"
        echo "    Actual: '$actual'"
        return 1
    fi
}

assert_not_empty() {
    local value="$1"
    local message="${2:-Value should not be empty}"
    
    if [[ -n "$value" ]]; then
        echo "  ✓ $message"
        return 0
    else
        echo "  ✗ $message"
        echo "    Value was empty"
        return 1
    fi
}

assert_file_exists() {
    local file_path="$1"
    local message="${2:-File should exist}"
    
    if [[ -f "$file_path" ]]; then
        echo "  ✓ $message: $file_path"
        return 0
    else
        echo "  ✗ $message: $file_path"
        return 1
    fi
}

# ===============================================================================
# CORE FUNCTIONALITY TESTS
# ===============================================================================

test_project_identifier_generation() {
    local project_path="$TEST_TEMP_DIR/project-a"
    
    # Test basic project identifier generation
    local project_id
    project_id=$(generate_project_identifier "$project_path")
    
    assert_not_empty "$project_id" "Project ID should be generated" || return 1
    
    # Should contain sanitized path components
    if [[ "$project_id" =~ tmp.*claude.*test.*project.*a ]]; then
        echo "  ✓ Project ID contains expected path components"
    else
        echo "  ✗ Project ID should contain sanitized path components"
        echo "    Generated ID: $project_id"
        return 1
    fi
    
    # Should contain hash suffix
    if [[ "$project_id" =~ -[a-f0-9]{6}$ ]]; then
        echo "  ✓ Project ID contains hash suffix"
    else
        echo "  ✗ Project ID should contain 6-character hash suffix"
        echo "    Generated ID: $project_id"
        return 1
    fi
    
    return 0
}

test_project_identifier_consistency() {
    local project_path="$TEST_TEMP_DIR/project-a"
    
    # Generate ID twice for same path
    local id1 id2
    id1=$(generate_project_identifier "$project_path")
    id2=$(generate_project_identifier "$project_path")
    
    assert_equals "$id1" "$id2" "Project ID should be consistent for same path" || return 1
    
    return 0
}

test_project_identifier_uniqueness() {
    local path_a="$TEST_TEMP_DIR/project-a"
    local path_b="$TEST_TEMP_DIR/project-b"
    
    # Generate IDs for different paths
    local id_a id_b
    id_a=$(generate_project_identifier "$path_a")
    id_b=$(generate_project_identifier "$path_b")
    
    if [[ "$id_a" != "$id_b" ]]; then
        echo "  ✓ Different projects generate unique IDs"
        echo "    Project A: $id_a"
        echo "    Project B: $id_b"
    else
        echo "  ✗ Different projects should generate unique IDs"
        echo "    Both generated: $id_a"
        return 1
    fi
    
    return 0
}

test_special_characters_handling() {
    local project_path="$TEST_TEMP_DIR/project with spaces"
    
    local project_id
    project_id=$(generate_project_identifier "$project_path")
    
    assert_not_empty "$project_id" "Should handle spaces in project path" || return 1
    
    # Should not contain spaces
    if [[ "$project_id" != *" "* ]]; then
        echo "  ✓ Project ID does not contain spaces"
    else
        echo "  ✗ Project ID should not contain spaces"
        echo "    Generated ID: '$project_id'"
        return 1
    fi
    
    return 0
}

test_session_file_path_generation() {
    local project_path="$TEST_TEMP_DIR/project-a"
    local project_id
    project_id=$(generate_project_identifier "$project_path")
    
    local session_file_path
    session_file_path=$(get_session_file_path "$project_id")
    
    assert_not_empty "$session_file_path" "Session file path should be generated" || return 1
    
    # Should be in HOME directory
    if [[ "$session_file_path" == "$HOME/.claude_session_"* ]]; then
        echo "  ✓ Session file path in HOME directory"
    else
        echo "  ✗ Session file path should be in HOME directory"
        echo "    Generated path: $session_file_path"
        return 1
    fi
    
    # Should contain project ID
    if [[ "$session_file_path" == *"$project_id" ]]; then
        echo "  ✓ Session file path contains project ID"
    else
        echo "  ✗ Session file path should contain project ID"
        echo "    Expected to contain: $project_id"
        echo "    Generated path: $session_file_path"
        return 1
    fi
    
    return 0
}

test_project_context_caching() {
    local project_path="$TEST_TEMP_DIR/project-a"
    
    # Clear any existing cache
    unset PROJECT_CONTEXT_CACHE 2>/dev/null || true
    declare -gA PROJECT_CONTEXT_CACHE
    
    # First call should generate and cache
    local id1
    id1=$(get_current_project_context "$project_path")
    
    # Check cache was populated
    if [[ -n "${PROJECT_CONTEXT_CACHE[$project_path]:-}" ]]; then
        echo "  ✓ Project context cached after first call"
    else
        echo "  ✗ Project context should be cached"
        return 1
    fi
    
    # Second call should use cache
    local id2
    id2=$(get_current_project_context "$project_path")
    
    assert_equals "$id1" "$id2" "Cached context should match original" || return 1
    
    return 0
}

# ===============================================================================
# SESSION MANAGEMENT TESTS
# ===============================================================================

test_session_registration_with_project() {
    local project_path="$TEST_TEMP_DIR/project-a"
    local project_name="test-project"
    local project_id
    project_id=$(generate_project_identifier "$project_path")
    
    local session_id
    session_id=$(generate_session_id "$project_name" "$project_id")
    
    # Register session with project context
    if register_session "$session_id" "$project_name" "$project_path" "$project_id"; then
        echo "  ✓ Session registered with project context"
    else
        echo "  ✗ Failed to register session with project context"
        return 1
    fi
    
    # Check session data contains project ID
    local session_data="${SESSIONS[$session_id]:-}"
    if [[ "$session_data" == *"$project_id" ]]; then
        echo "  ✓ Session data contains project ID"
    else
        echo "  ✗ Session data should contain project ID"
        echo "    Session data: '$session_data'"
        return 1
    fi
    
    # Check reverse mapping
    if [[ "${PROJECT_SESSIONS[$project_id]:-}" == "$session_id" ]]; then
        echo "  ✓ Project to session mapping created"
    else
        echo "  ✗ Project to session mapping missing"
        return 1
    fi
    
    if [[ "${SESSION_PROJECTS[$session_id]:-}" == "$project_id" ]]; then
        echo "  ✓ Session to project mapping created"
    else
        echo "  ✗ Session to project mapping missing"
        return 1
    fi
    
    return 0
}

test_find_session_by_project() {
    local project_path="$TEST_TEMP_DIR/project-b"
    local project_name="test-project-b"
    local project_id
    project_id=$(generate_project_identifier "$project_path")
    
    local session_id
    session_id=$(generate_session_id "$project_name" "$project_id")
    
    # Register session
    register_session "$session_id" "$project_name" "$project_path" "$project_id"
    
    # Find session by project
    local found_session_id
    if found_session_id=$(find_session_by_project "$project_id"); then
        echo "  ✓ Found session by project ID"
        assert_equals "$session_id" "$found_session_id" "Found session should match registered session" || return 1
    else
        echo "  ✗ Failed to find session by project ID"
        return 1
    fi
    
    return 0
}

# ===============================================================================
# INTEGRATION TESTS
# ===============================================================================

test_session_isolation() {
    # Create sessions for different projects
    local project_a="$TEST_TEMP_DIR/project-a"
    local project_b="$TEST_TEMP_DIR/project-b"
    
    local id_a id_b
    id_a=$(generate_project_identifier "$project_a")
    id_b=$(generate_project_identifier "$project_b")
    
    local session_a session_b
    session_a=$(generate_session_id "proj-a" "$id_a")
    session_b=$(generate_session_id "proj-b" "$id_b")
    
    # Register both sessions
    register_session "$session_a" "proj-a" "$project_a" "$id_a"
    register_session "$session_b" "proj-b" "$project_b" "$id_b"
    
    # Verify isolation
    local found_a found_b
    found_a=$(find_session_by_project "$id_a")
    found_b=$(find_session_by_project "$id_b")
    
    assert_equals "$session_a" "$found_a" "Project A should find its own session" || return 1
    assert_equals "$session_b" "$found_b" "Project B should find its own session" || return 1
    
    if [[ "$found_a" != "$found_b" ]]; then
        echo "  ✓ Sessions are properly isolated"
    else
        echo "  ✗ Sessions should be isolated"
        return 1
    fi
    
    return 0
}

# ===============================================================================
# MAIN TEST RUNNER
# ===============================================================================

main() {
    echo "==============================================================================="
    echo "                      $TEST_NAME Test Suite"
    echo "==============================================================================="
    
    setup_test_environment
    
    # Core functionality tests
    echo ""
    echo -e "${YELLOW}=== CORE FUNCTIONALITY TESTS ===${NC}"
    run_test "Project Identifier Generation" test_project_identifier_generation
    run_test "Project Identifier Consistency" test_project_identifier_consistency  
    run_test "Project Identifier Uniqueness" test_project_identifier_uniqueness
    run_test "Special Characters Handling" test_special_characters_handling
    run_test "Session File Path Generation" test_session_file_path_generation
    run_test "Project Context Caching" test_project_context_caching
    
    # Session management tests
    echo ""
    echo -e "${YELLOW}=== SESSION MANAGEMENT TESTS ===${NC}"
    run_test "Session Registration with Project" test_session_registration_with_project
    run_test "Find Session by Project" test_find_session_by_project
    
    # Integration tests
    echo ""
    echo -e "${YELLOW}=== INTEGRATION TESTS ===${NC}"
    run_test "Session Isolation" test_session_isolation
    
    cleanup_test_environment
    
    # Print final results
    echo ""
    echo "==============================================================================="
    echo "                          TEST RESULTS"
    echo "==============================================================================="
    echo -e "Tests run: $TESTS_RUN"
    echo -e "${GREEN}Tests passed: $TESTS_PASSED${NC}"
    
    if [[ $TESTS_FAILED -gt 0 ]]; then
        echo -e "${RED}Tests failed: $TESTS_FAILED${NC}"
        echo ""
        echo -e "${RED}Some tests failed! Please review the output above.${NC}"
        exit 1
    else
        echo -e "${GREEN}All tests passed!${NC}"
        echo ""
        echo -e "${GREEN}✓ Per-Project Session Management is working correctly${NC}"
        exit 0
    fi
}

# Run tests if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi