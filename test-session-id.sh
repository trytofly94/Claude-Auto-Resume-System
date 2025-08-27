#!/usr/bin/env bash

# Simple test script for session ID functionality
# This bypasses the complex module loading of hybrid-monitor.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Simple logging functions
log_info() { echo "[INFO] $*"; }
log_warn() { echo "[WARN] $*"; }
log_error() { echo "[ERROR] $*"; }
log_debug() { [[ "${DEBUG_MODE:-false}" == "true" ]] && echo "[DEBUG] $*"; }

# Change to src directory to avoid path issues
cd "$SCRIPT_DIR/src"

# Load utilities from correct relative paths
source "utils/clipboard.sh"
source "utils/session-display.sh"

# Mock session ID for testing
MAIN_SESSION_ID="test-project-$(date +%s)-$$"

echo "=== Session ID Functionality Test ==="
echo ""

case "${1:-}" in
    "--show-session-id")
        echo "Testing --show-session-id:"
        show_current_session_id "$MAIN_SESSION_ID" false
        ;;
    "--show-full-session-id")
        echo "Testing --show-full-session-id:"
        show_current_session_id "$MAIN_SESSION_ID" true
        ;;
    "--copy-session-id")
        echo "Testing --copy-session-id:"
        show_and_copy_session_id "$MAIN_SESSION_ID" true false
        ;;
    "--list-sessions")
        echo "Testing --list-sessions:"
        echo "Note: Session manager not available in test mode"
        echo "Mock session: $MAIN_SESSION_ID"
        ;;
    "--test-clipboard")
        echo "Testing clipboard functionality:"
        echo "Clipboard detection:"
        if declare -f detect_clipboard_tools >/dev/null 2>&1; then
            detect_clipboard_tools
            echo "Method: ${CLIPBOARD_METHOD:-not set}"
            echo "Copy tool: ${AVAILABLE_COPY_TOOL:-not set}"
            echo "Paste tool: ${AVAILABLE_PASTE_TOOL:-not set}"
        else
            echo "Clipboard functions not available"
        fi
        ;;
    *)
        echo "Usage: $0 [--show-session-id|--show-full-session-id|--copy-session-id|--list-sessions|--test-clipboard]"
        echo ""
        echo "Available tests:"
        echo "  --show-session-id      Test session ID display"
        echo "  --show-full-session-id Test full session ID display"
        echo "  --copy-session-id      Test session ID copying"
        echo "  --list-sessions        Test session listing (mock)"
        echo "  --test-clipboard       Test clipboard functionality"
        echo ""
        echo "Current mock session: $MAIN_SESSION_ID"
        ;;
esac