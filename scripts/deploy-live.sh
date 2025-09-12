#!/bin/bash

# Live Deployment Script for Claude Auto-Resume System
# Optimized for production deployment with safety checks

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Configuration
LOG_FILE="$PROJECT_ROOT/logs/deployment.log"
PID_FILE="$PROJECT_ROOT/logs/hybrid-monitor.pid"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Safety check - ensure we don't disrupt existing sessions
check_existing_sessions() {
    log "Checking existing tmux sessions for safety..."
    local session_count
    session_count=$(tmux list-sessions 2>/dev/null | wc -l || echo "0")
    log "Found $session_count existing tmux sessions (will be protected)"
    
    if [ "$session_count" -gt 20 ]; then
        echo -e "${YELLOW}WARNING: High number of tmux sessions detected ($session_count)${NC}"
        echo -e "${YELLOW}Continuing in 5 seconds... Press Ctrl+C to abort${NC}"
        sleep 5
    fi
}

# Validate system readiness
validate_system() {
    log "Validating system requirements..."
    
    # Check task queue
    local pending_tasks
    pending_tasks=$("$PROJECT_ROOT/src/task-queue.sh" status | grep -o '"pending": [0-9]*' | cut -d' ' -f2 || echo "0")
    log "Found $pending_tasks pending tasks ready for processing"
    
    if [ "$pending_tasks" -eq 0 ]; then
        echo -e "${YELLOW}WARNING: No pending tasks found${NC}"
    fi
    
    # Check dependencies
    if ! command -v claude >/dev/null 2>&1; then
        echo -e "${RED}ERROR: Claude CLI not found${NC}"
        exit 1
    fi
    
    if ! command -v claunch >/dev/null 2>&1; then
        echo -e "${RED}ERROR: claunch not found${NC}"
        exit 1
    fi
    
    log "System validation completed successfully"
}

# Start live deployment
start_live_deployment() {
    log "Starting live Claude Auto-Resume deployment..."
    
    # Ensure logs directory exists
    mkdir -p "$PROJECT_ROOT/logs"
    
    # Remove stale PID file if exists
    if [ -f "$PID_FILE" ]; then
        log "Removing stale PID file"
        rm -f "$PID_FILE"
    fi
    
    # Start the hybrid monitor in background
    log "Launching hybrid monitor in queue mode with continuous operation..."
    nohup "$PROJECT_ROOT/src/hybrid-monitor.sh" --queue-mode --continuous \
        >"$PROJECT_ROOT/logs/hybrid-monitor-live.log" 2>&1 &
    
    local pid=$!
    echo "$pid" > "$PID_FILE"
    
    log "Hybrid monitor started with PID: $pid"
    echo -e "${GREEN}✅ Claude Auto-Resume System deployed successfully${NC}"
    echo -e "${GREEN}   PID: $pid${NC}"
    echo -e "${GREEN}   Logs: $PROJECT_ROOT/logs/hybrid-monitor-live.log${NC}"
}

# Monitor deployment status
monitor_deployment() {
    log "Monitoring initial deployment health..."
    sleep 5
    
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE")
        if ps -p "$pid" > /dev/null 2>&1; then
            echo -e "${GREEN}✅ Process is running (PID: $pid)${NC}"
        else
            echo -e "${RED}❌ Process not found - deployment may have failed${NC}"
            return 1
        fi
    else
        echo -e "${RED}❌ PID file not found - deployment failed${NC}"
        return 1
    fi
    
    # Show last few log lines
    echo -e "\n${GREEN}Recent activity:${NC}"
    tail -n 5 "$PROJECT_ROOT/logs/hybrid-monitor-live.log" 2>/dev/null || log "No logs available yet"
}

# Stop deployment
stop_deployment() {
    log "Stopping live deployment..."
    
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE")
        if ps -p "$pid" > /dev/null 2>&1; then
            kill "$pid"
            log "Stopped process with PID: $pid"
            rm -f "$PID_FILE"
            echo -e "${GREEN}✅ Deployment stopped${NC}"
        else
            log "Process already stopped"
            rm -f "$PID_FILE"
        fi
    else
        log "No PID file found - nothing to stop"
    fi
}

# Show deployment status
status_deployment() {
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE")
        if ps -p "$pid" > /dev/null 2>&1; then
            echo -e "${GREEN}✅ Claude Auto-Resume is running (PID: $pid)${NC}"
            
            # Show task queue status
            echo -e "\n${GREEN}Task Queue Status:${NC}"
            "$PROJECT_ROOT/src/task-queue.sh" status | head -n 8
            
            # Show recent logs
            echo -e "\n${GREEN}Recent Activity (last 10 lines):${NC}"
            tail -n 10 "$PROJECT_ROOT/logs/hybrid-monitor-live.log" 2>/dev/null || echo "No logs available"
            
        else
            echo -e "${RED}❌ Process not running (stale PID file)${NC}"
            rm -f "$PID_FILE"
            return 1
        fi
    else
        echo -e "${YELLOW}⚠️  Claude Auto-Resume not deployed${NC}"
        return 1
    fi
}

# Main execution
main() {
    cd "$PROJECT_ROOT"
    
    case "${1:-start}" in
        start)
            echo -e "${GREEN}🚀 Claude Auto-Resume Live Deployment${NC}"
            check_existing_sessions
            validate_system
            start_live_deployment
            monitor_deployment
            echo -e "\n${GREEN}Use '$0 status' to monitor${NC}"
            echo -e "${GREEN}Use '$0 stop' to halt deployment${NC}"
            ;;
        stop)
            stop_deployment
            ;;
        status)
            status_deployment
            ;;
        restart)
            stop_deployment
            sleep 2
            echo -e "${GREEN}🚀 Restarting Claude Auto-Resume${NC}"
            check_existing_sessions
            validate_system
            start_live_deployment
            monitor_deployment
            ;;
        *)
            echo "Usage: $0 {start|stop|status|restart}"
            echo ""
            echo "Commands:"
            echo "  start   - Deploy Claude Auto-Resume for live operation"
            echo "  stop    - Stop the live deployment"
            echo "  status  - Check deployment status"
            echo "  restart - Stop and start the deployment"
            exit 1
            ;;
    esac
}

# Execute main function with all arguments
main "$@"