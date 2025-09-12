#!/usr/bin/env bash

# Claude Auto-Resume - Simple Production Start Script
# Start live task automation with 18 pending tasks

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors and emojis for output
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

echo -e "${BLUE}🚀 Claude Auto-Resume - Live Task Automation${NC}"
echo "=============================================="
echo ""

# Check prerequisites
check_prerequisites() {
    echo -e "${BLUE}🔍 Checking prerequisites...${NC}"
    
    # Check Claude CLI
    if ! command -v claude >/dev/null 2>&1; then
        echo -e "${RED}❌ Claude CLI not found${NC}"
        echo "Please install Claude CLI first"
        return 1
    fi
    
    # Check tmux
    if ! command -v tmux >/dev/null 2>&1; then
        echo -e "${RED}❌ tmux not found${NC}"
        echo "Please install tmux first"
        return 1
    fi
    
    # Check task queue
    local task_count
    if task_count=$(./src/task-queue.sh status 2>/dev/null | grep -A 10 "GLOBAL QUEUE STATUS" | tail -n +2 | jq -r '.pending // 0' 2>/dev/null); then
        echo -e "${GREEN}✅ Found $task_count pending tasks${NC}"
        if [[ $task_count -eq 0 ]]; then
            echo -e "${YELLOW}⚠️ No pending tasks to process${NC}"
            return 1
        fi
    else
        echo -e "${RED}❌ Task queue not accessible${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✅ Prerequisites satisfied${NC}"
    echo ""
    return 0
}

# Create unique session name
create_session_name() {
    local timestamp=$(date +%s)
    echo "claude-live-automation-$timestamp"
}

# Start automation in dedicated session
start_automation() {
    local session_name="$1"
    
    echo -e "${BLUE}🎯 Starting live automation in session: $session_name${NC}"
    
    # Create dedicated session
    if ! tmux new-session -d -s "$session_name" -c "$SCRIPT_DIR"; then
        echo -e "${RED}❌ Failed to create automation session${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✅ Automation session created${NC}"
    
    # Build the hybrid monitor command with safe settings
    local monitor_command="./src/hybrid-monitor.sh --queue-mode --continuous --enhanced-usage-limits --debug"
    
    # Start the automation
    tmux send-keys -t "$session_name" "$monitor_command" Enter
    
    # Give it a moment to start
    sleep 3
    
    # Check if it started successfully
    if tmux has-session -t "$session_name" 2>/dev/null; then
        echo -e "${GREEN}✅ Live automation started successfully${NC}"
        echo ""
        echo -e "${BLUE}📊 Monitor commands:${NC}"
        echo "  tmux attach -t $session_name    # Attach to session"
        echo "  tmux capture-pane -t $session_name -p    # View output"
        echo "  tmux kill-session -t $session_name       # Stop automation"
        echo ""
        echo -e "${BLUE}📈 Queue monitoring:${NC}"
        echo "  ./src/task-queue.sh status      # Check task status"
        echo "  ./src/task-queue.sh monitor     # Real-time monitoring"
        echo ""
        return 0
    else
        echo -e "${RED}❌ Automation failed to start${NC}"
        return 1
    fi
}

# Main execution
main() {
    echo -e "${BLUE}Starting Claude Auto-Resume live automation system...${NC}"
    echo "Time: $(date)"
    echo ""
    
    if ! check_prerequisites; then
        echo -e "${RED}❌ Prerequisites check failed${NC}"
        echo ""
        echo -e "${YELLOW}💡 Solutions:${NC}"
        echo "  - Install Claude CLI if missing"
        echo "  - Add tasks to the queue if empty:"
        echo "    ./src/task-queue.sh add-custom \"Your task description\""
        echo ""
        exit 1
    fi
    
    local session_name
    session_name=$(create_session_name)
    
    if start_automation "$session_name"; then
        echo -e "${GREEN}🎉 Claude Auto-Resume is now running live!${NC}"
        echo ""
        echo -e "${BLUE}💡 What happens next:${NC}"
        echo "  1. The system will automatically process all pending tasks"
        echo "  2. Usage limits will be detected and handled automatically"
        echo "  3. Tasks will continue processing until complete"
        echo "  4. Progress will be logged and monitored"
        echo ""
        echo -e "${YELLOW}⚠️ Important:${NC}"
        echo "  - Do not close this terminal if you want to see progress"
        echo "  - The automation runs in background session: $session_name"
        echo "  - Use the monitor commands above to check progress"
        echo ""
        
        # Offer to show live output
        echo -n "Show live output? (y/n): "
        read -r response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            echo ""
            echo -e "${BLUE}📺 Connecting to live session...${NC}"
            echo -e "${YELLOW}Press Ctrl+B then D to detach (keep running)${NC}"
            sleep 2
            tmux attach -t "$session_name"
        fi
        
        exit 0
    else
        echo -e "${RED}❌ Failed to start automation${NC}"
        exit 1
    fi
}

# Handle script arguments
case "${1:-}" in
    "help"|"-h"|"--help")
        echo -e "${BLUE}Claude Auto-Resume - Live Automation Starter${NC}"
        echo ""
        echo "Usage: $0 [options]"
        echo ""
        echo "This script starts the Claude Auto-Resume system to automatically"
        echo "process all pending tasks with intelligent usage limit handling."
        echo ""
        echo "Prerequisites:"
        echo "  - Claude CLI installed and working"  
        echo "  - tmux installed"
        echo "  - Pending tasks in the task queue"
        echo ""
        echo "Examples:"
        echo "  $0          # Start live automation"
        echo "  $0 help     # Show this help"
        echo ""
        ;;
    "")
        main
        ;;
    *)
        echo -e "${RED}❌ Unknown argument: $1${NC}"
        echo -e "${BLUE}Use $0 help for usage information${NC}"
        exit 1
        ;;
esac