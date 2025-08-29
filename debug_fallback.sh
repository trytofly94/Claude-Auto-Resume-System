#!/usr/bin/env bash

# Debug script to trace specific claunch fallback behavior
# Created for Issue #77 testing and debugging

set -euo pipefail

echo "=== Debug: Issue #77 - Tracing claunch fallback behavior ==="
echo ""

# Test 1: Manual PATH manipulation
echo "Test 1: Checking PATH manipulation behavior"
echo "Current PATH: $PATH"
echo ""

# Save original PATH
original_path="$PATH"

# Source the claunch-integration script to test functions
echo "Sourcing claunch-integration.sh for function testing..."
source "./src/claunch-integration.sh"

# Test refresh_shell_path function directly
echo ""
echo "Testing refresh_shell_path function:"
refresh_shell_path
echo "Updated PATH: $PATH"
echo ""

# Test detect_claunch function directly
echo "Testing detect_claunch function without claunch:"
# Temporarily hide claunch
if command -v claunch >/dev/null 2>&1; then
    claunch_path=$(command -v claunch)
    mv "$claunch_path" "${claunch_path}.debug_backup"
    echo "Hidden claunch temporarily for testing"
fi

# Run detection
echo ""
echo "--- Detection output (should show fallback) ---"
if detect_claunch; then
    echo "detect_claunch returned success: CLAUNCH_PATH=$CLAUNCH_PATH"
else
    echo "detect_claunch returned failure (expected)"
fi

# Test validate_claunch function
echo ""
echo "Testing validate_claunch function:"
echo "--- Validation output ---"
if validate_claunch; then
    echo "validate_claunch returned success"
else
    echo "validate_claunch returned failure (expected when claunch not available)"
fi

# Test detect_and_configure_fallback function
echo ""
echo "Testing detect_and_configure_fallback function:"
echo "--- Fallback detection output ---"
if detect_and_configure_fallback; then
    echo "detect_and_configure_fallback returned success"
    echo "USE_CLAUNCH is now set to: $USE_CLAUNCH"
else
    echo "detect_and_configure_fallback returned failure"
fi

# Restore claunch if we hid it
if [[ -f "${claunch_path:-}.debug_backup" ]]; then
    mv "${claunch_path}.debug_backup" "$claunch_path"
    echo ""
    echo "Restored claunch"
fi

# Restore original PATH
export PATH="$original_path"

echo ""
echo "=== Debug completed ==="