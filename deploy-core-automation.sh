#!/usr/bin/env bash
set -euo pipefail

# Claude Auto-Resume - Core Automation Deployment
# One-command activation for live operation with 18 pending tasks
# Version: 1.0.0-enhanced

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "🚀 Claude Auto-Resume - Core Automation Deployment"
echo "======================================================"
echo ""

# Verify prerequisites
echo "🔍 Checking prerequisites..."

if ! command -v tmux >/dev/null; then
    echo "❌ tmux is required but not installed"
    echo "   Install with: brew install tmux (macOS) or apt-get install tmux (Linux)"
    exit 1
fi

if ! command -v jq >/dev/null; then
    echo "❌ jq is required but not installed"
    echo "   Install with: brew install jq (macOS) or apt-get install jq (Linux)"
    exit 1
fi

if ! command -v claude >/dev/null; then
    echo "❌ Claude CLI is required but not installed"
    echo "   Install from: https://github.com/anthropics/claude-cli"
    exit 1
fi

echo "✅ Prerequisites satisfied"

# Check task queue status
echo ""
echo "📋 Checking task queue status..."
if [[ -f "$SCRIPT_DIR/src/task-queue.sh" && -x "$SCRIPT_DIR/src/task-queue.sh" ]]; then
    PENDING_TASKS=$("$SCRIPT_DIR/src/task-queue.sh" status | jq -r '.pending' 2>/dev/null || echo "0")
    echo "Tasks pending: $PENDING_TASKS"
    
    if [[ "$PENDING_TASKS" -eq 0 ]]; then
        echo "ℹ️  No tasks pending - system ready but nothing to process"
        echo "Add tasks with: ./src/task-queue.sh add-custom 'Your task here'"
        exit 0
    fi
else
    echo "❌ Task queue system not found at: $SCRIPT_DIR/src/task-queue.sh"
    exit 1
fi

# Validate core system files
echo ""
echo "🔧 Validating core system files..."

if [[ ! -f "$SCRIPT_DIR/src/hybrid-monitor.sh" ]]; then
    echo "❌ Core monitoring system not found: src/hybrid-monitor.sh"
    exit 1
fi

if [[ ! -f "$SCRIPT_DIR/src/usage-limit-recovery.sh" ]]; then
    echo "❌ Enhanced usage limit system not found: src/usage-limit-recovery.sh"
    exit 1
fi

echo "✅ Core system files validated"

# Create deployment session with timestamp
DEPLOY_SESSION="claude-core-automation-$(date +%s)"
echo ""
echo "🔧 Starting enhanced core automation in session: $DEPLOY_SESSION"

# Ensure the script is executable
if [[ ! -x "$SCRIPT_DIR/src/hybrid-monitor.sh" ]]; then
    echo "🔧 Making hybrid-monitor.sh executable..."
    chmod +x "$SCRIPT_DIR/src/hybrid-monitor.sh"
fi

# Start the enhanced system with all necessary flags
echo "🚀 Launching enhanced system with live operation capabilities..."

tmux new-session -d -s "$DEPLOY_SESSION" \
    "cd '$SCRIPT_DIR' && ./src/hybrid-monitor.sh --queue-mode --continuous --enhanced-usage-limits"

# Verify session started successfully
if tmux has-session -t "$DEPLOY_SESSION" 2>/dev/null; then
    echo ""
    echo "✅ Core automation started successfully!"
    echo ""
    echo "📊 Monitor progress:"
    echo "   tmux attach -t $DEPLOY_SESSION"
    echo ""
    echo "📋 Check task status:"
    echo "   ./src/task-queue.sh status"
    echo ""
    echo "📜 View logs:"
    echo "   tail -f logs/hybrid-monitor.log"
    echo ""
    echo "⏹️  Stop system:"
    echo "   tmux kill-session -t $DEPLOY_SESSION"
    echo ""
    echo "🎯 Processing $PENDING_TASKS pending tasks with enhanced usage limit detection"
    echo "🔄 System will automatically handle usage limits and continue processing"
    
    # Optionally show initial progress
    if [[ "${SHOW_INITIAL_PROGRESS:-true}" == "true" ]]; then
        echo ""
        echo "📈 Initial system status (checking after 30 seconds):"
        sleep 30
        
        if tmux has-session -t "$DEPLOY_SESSION" 2>/dev/null; then
            REMAINING_TASKS=$("$SCRIPT_DIR/src/task-queue.sh" status | jq -r '.pending' 2>/dev/null || echo "unknown")
            if [[ "$REMAINING_TASKS" != "unknown" && "$REMAINING_TASKS" -lt "$PENDING_TASKS" ]]; then
                COMPLETED=$((PENDING_TASKS - REMAINING_TASKS))
                echo "✅ Progress: $COMPLETED tasks completed, $REMAINING_TASKS remaining"
            else
                echo "⏳ System initializing - check progress with: ./src/task-queue.sh status"
            fi
            echo "📺 Connect to monitor session: tmux attach -t $DEPLOY_SESSION"
        else
            echo "⚠️  Session may have exited - check logs: tail logs/hybrid-monitor.log"
        fi
    fi
    
    echo ""
    echo "🌟 Enhanced Core Automation is now active!"
else
    echo "❌ Failed to start deployment session"
    echo "Check for errors and try again"
    exit 1
fi