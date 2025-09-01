#!/usr/bin/env bash

# Basic Per-Project Session Management Test
# Quick validation of core functionality

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Stub minimal logging
log_debug() { [[ "${DEBUG:-}" == "1" ]] && echo "[DEBUG] $*" >&2 || true; }
log_info() { echo "[INFO] $*" >&2; }
log_warn() { echo "[WARN] $*" >&2; }
log_error() { echo "[ERROR] $*" >&2; }

# Source just the functions we need
cd "$PROJECT_ROOT"
source src/session-manager.sh

echo "=== Basic Per-Project Session Management Test ==="

# Test 1: Project identifier generation
echo ""
echo "Test 1: Project Identifier Generation"
test_dir="/tmp/claude-test-project"
project_id=$(generate_project_identifier "$test_dir")
echo "✓ Generated project ID: $project_id"

if [[ -n "$project_id" && "$project_id" =~ -[a-f0-9]{6}$ ]]; then
    echo "✓ Project ID format is correct (contains hash suffix)"
else
    echo "✗ Project ID format is incorrect"
    exit 1
fi

# Test 2: Session file path generation
echo ""
echo "Test 2: Session File Path Generation"
session_file=$(get_session_file_path "$project_id")
echo "✓ Generated session file path: $session_file"

if [[ "$session_file" == "$HOME/.claude_session_$project_id" ]]; then
    echo "✓ Session file path format is correct"
else
    echo "✗ Session file path format is incorrect"
    exit 1
fi

# Test 3: Project ID consistency
echo ""
echo "Test 3: Project ID Consistency"
project_id2=$(generate_project_identifier "$test_dir")
if [[ "$project_id" == "$project_id2" ]]; then
    echo "✓ Project ID is consistent for same path"
else
    echo "✗ Project ID should be consistent for same path"
    echo "  First: $project_id"
    echo "  Second: $project_id2"
    exit 1
fi

# Test 4: Different projects generate different IDs
echo ""
echo "Test 4: Project ID Uniqueness"
different_dir="/tmp/claude-different-project"
different_id=$(generate_project_identifier "$different_dir")
if [[ "$project_id" != "$different_id" ]]; then
    echo "✓ Different projects generate unique IDs"
    echo "  First project: $project_id"
    echo "  Second project: $different_id"
else
    echo "✗ Different projects should generate unique IDs"
    exit 1
fi

# Test 5: Session ID generation with project context
echo ""
echo "Test 5: Project-Aware Session ID Generation"
session_id=$(generate_session_id "test-project" "$project_id")
echo "✓ Generated session ID: $session_id"

if [[ "$session_id" =~ ^sess-.*-[0-9]+-[0-9]+$ ]]; then
    echo "✓ Session ID format is correct"
else
    echo "✗ Session ID format is incorrect"
    exit 1
fi

echo ""
echo "=== All Basic Tests Passed! ==="
echo ""
echo "Per-project session management core functionality is working correctly."
echo "Project isolation has been successfully implemented."