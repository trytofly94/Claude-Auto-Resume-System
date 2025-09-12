#!/usr/bin/env bash
set -euo pipefail

# Claude Auto-Resume Live Operation Launcher
# Created: 2025-09-12
# Purpose: One-command startup for live deployment

echo "🚀 Starting Claude Auto-Resume Live Operation"
echo ""

# Check task queue status
echo "📊 Checking task queue status..."
TASK_STATUS=$(./src/task-queue.sh status 2>/dev/null | head -n 10 | grep -E '^\{.*\}$' | head -n 1 || echo '{"pending":"Unknown"}')
PENDING_COUNT=$(echo "$TASK_STATUS" | jq -r '.pending // "Unknown"' 2>/dev/null || echo "Unknown")
echo "   Tasks pending: $PENDING_COUNT"

# Basic system health check
echo ""
echo "🔍 Running system health check..."

# Check core dependencies
echo "   ✅ Checking Claude CLI..."
if ! command -v claude >/dev/null 2>&1; then
    echo "   ❌ ERROR: Claude CLI not found. Please install it first."
    exit 1
fi

echo "   ✅ Checking tmux..."
if ! command -v tmux >/dev/null 2>&1; then
    echo "   ❌ ERROR: tmux not found. Please install it first."
    exit 1
fi

echo "   ✅ Checking claunch (optional)..."
if command -v claunch >/dev/null 2>&1; then
    echo "   ✅ claunch available"
else
    echo "   ⚠️  claunch not found - will use fallback mode"
fi

# Check for existing session
echo ""
echo "🔄 Checking for existing sessions..."
SESSION_NAME="claude-auto-resume-live"

if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo "   ⚠️  Session '$SESSION_NAME' already exists"
    echo ""
    echo "Options:"
    echo "   1. Attach to existing session: tmux attach -t $SESSION_NAME"
    echo "   2. Kill existing session: tmux kill-session -t $SESSION_NAME"
    echo "   3. Use different session name (edit this script)"
    echo ""
    read -p "Kill existing session and start new? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "   🗑️  Killing existing session..."
        tmux kill-session -t "$SESSION_NAME"
    else
        echo "   📺 To attach: tmux attach -t $SESSION_NAME"
        exit 1
    fi
fi

# Clean up any stale claunch sessions for this project
echo "   🧹 Cleaning up stale sessions..."
./src/session-manager.sh --cleanup-sessions >/dev/null 2>&1 || true

echo ""
echo "🚀 Starting live operation..."

# Create log monitoring command
LOG_CMD="tail -f logs/hybrid-monitor.log 2>/dev/null || echo 'Waiting for logs...'"

# Start the live session with hybrid monitor
tmux new-session -d -s "$SESSION_NAME" \
    "./src/hybrid-monitor.sh --queue-mode --continuous --debug"

# Give it time to start
sleep 5

# Check if session is still running
if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo "   ❌ Session failed to start or exited immediately"
    echo ""
    echo "🔧 Troubleshooting steps:"
    echo "   1. Check logs: tail -f logs/hybrid-monitor.log"
    echo "   2. Test manually: ./src/hybrid-monitor.sh --help"
    echo "   3. Check dependencies: ./scripts/debug-environment.sh"
    exit 1
fi

echo "   ✅ Live operation started successfully!"
echo ""
echo "📋 Management Commands:"
echo "   📺 Attach to session:    tmux attach -t $SESSION_NAME"
echo "   📊 Check task status:    ./src/task-queue.sh status"
echo "   📄 Monitor logs:         tail -f logs/hybrid-monitor.log"
echo "   🛑 Stop system:          tmux kill-session -t $SESSION_NAME"
echo ""
echo "🎯 The system will now:"
echo "   • Process all $PENDING_COUNT pending tasks automatically"
echo "   • Handle usage limits with proper waiting"
echo "   • Run continuously until all tasks complete"
echo "   • Log all activity to logs/hybrid-monitor.log"
echo ""
echo "📍 Session started: $SESSION_NAME"
echo "🔗 Attach now with: tmux attach -t $SESSION_NAME"