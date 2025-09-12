#!/usr/bin/env bash

# Claude Auto-Resume - Live Operation Deployment Script
# Version: 1.0.0-alpha
# Enhanced deployment for automated task processing with usage limit handling

set -euo pipefail

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color

# Emojis for better UX
readonly ROCKET="🚀"
readonly CHECK="✅"
readonly WARNING="⚠️"
readonly ERROR="❌"
readonly INFO="ℹ️"
readonly GEAR="⚙️"
readonly CHART="📊"
readonly PHONE="📱"
readonly STOP="🛑"
readonly REPEAT="🔄"

echo -e "${BLUE}${ROCKET} Claude Auto-Resume - Live Operation Deployment${NC}"
echo "=================================================="
echo ""

# Load logging functions if available
if [[ -f "$SCRIPT_DIR/src/utils/logging.sh" ]]; then
    source "$SCRIPT_DIR/src/utils/logging.sh"
else
    # Fallback logging functions
    log_debug() { [[ "${DEBUG_MODE:-false}" == "true" ]] && echo -e "${CYAN}[DEBUG]${NC} $*" >&2 || true; }
    log_info() { echo -e "${GREEN}[INFO]${NC} $*" >&2; }
    log_warn() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
    log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
fi

# Validate system prerequisites
validate_prerequisites() {
    local errors=0
    
    log_info "${GEAR} Validating system prerequisites..."
    echo ""
    
    # Check Claude CLI
    if ! command -v claude >/dev/null 2>&1; then
        echo -e "${ERROR} Claude CLI not found"
        echo "   Please install Claude CLI first: https://claude.ai/cli"
        ((errors++))
    else
        local claude_version
        claude_version=$(claude --version 2>/dev/null | head -1 || echo "unknown")
        echo -e "${CHECK} Claude CLI available (version: $claude_version)"
    fi
    
    # Check claunch (optional)
    if ! command -v claunch >/dev/null 2>&1; then
        echo -e "${WARNING} claunch not found - will use direct mode"
        echo "   For better session management, consider installing claunch"
    else
        local claunch_version
        claunch_version=$(claunch --version 2>/dev/null | head -1 || echo "unknown")
        echo -e "${CHECK} claunch available (version: $claunch_version)"
    fi
    
    # Check tmux
    if ! command -v tmux >/dev/null 2>&1; then
        echo -e "${ERROR} tmux not found"
        echo "   Please install tmux: brew install tmux (macOS) or apt install tmux (Linux)"
        ((errors++))
    else
        local tmux_version
        tmux_version=$(tmux -V 2>/dev/null || echo "unknown")
        echo -e "${CHECK} tmux available (version: $tmux_version)"
    fi
    
    # Check jq (highly recommended)
    if ! command -v jq >/dev/null 2>&1; then
        echo -e "${WARNING} jq not found - JSON processing will use fallback methods"
        echo "   For better performance, consider installing jq: brew install jq (macOS) or apt install jq (Linux)"
    else
        local jq_version
        jq_version=$(jq --version 2>/dev/null || echo "unknown")
        echo -e "${CHECK} jq available (version: $jq_version)"
    fi
    
    # Check project structure
    local required_files=(
        "src/hybrid-monitor.sh"
        "src/task-queue.sh"
        "src/usage-limit-recovery.sh"
        "src/session-manager.sh"
    )
    
    for file in "${required_files[@]}"; do
        if [[ -f "$PROJECT_ROOT/$file" ]]; then
            echo -e "${CHECK} Core component available: $file"
        else
            echo -e "${ERROR} Missing core component: $file"
            ((errors++))
        fi
    done
    
    # Check execute permissions
    if [[ ! -x "$PROJECT_ROOT/src/hybrid-monitor.sh" ]]; then
        echo -e "${WARNING} hybrid-monitor.sh is not executable - fixing..."
        chmod +x "$PROJECT_ROOT/src/hybrid-monitor.sh" 2>/dev/null || true
    fi
    
    if [[ ! -x "$PROJECT_ROOT/src/task-queue.sh" ]]; then
        echo -e "${WARNING} task-queue.sh is not executable - fixing..."
        chmod +x "$PROJECT_ROOT/src/task-queue.sh" 2>/dev/null || true
    fi
    
    echo ""
    return $errors
}

# Check task queue status and provide detailed information
check_task_queue_status() {
    log_info "${CHART} Checking task queue status..."
    echo ""
    
    local task_queue_script="$PROJECT_ROOT/src/task-queue.sh"
    
    if [[ ! -x "$task_queue_script" ]]; then
        log_error "Task queue script not executable or not found"
        return 1
    fi
    
    local queue_status
    if queue_status=$("$task_queue_script" status 2>/dev/null); then
        
        # Extract task counts using various methods
        local pending_tasks completed_tasks failed_tasks total_tasks
        
        if command -v jq >/dev/null 2>&1; then
            # Use jq for precise parsing
            pending_tasks=$(echo "$queue_status" | grep -A 20 "GLOBAL QUEUE STATUS" | jq -r '.pending // 0' 2>/dev/null || echo "0")
            completed_tasks=$(echo "$queue_status" | grep -A 20 "GLOBAL QUEUE STATUS" | jq -r '.completed // 0' 2>/dev/null || echo "0")
            failed_tasks=$(echo "$queue_status" | grep -A 20 "GLOBAL QUEUE STATUS" | jq -r '.failed // 0' 2>/dev/null || echo "0")
            total_tasks=$(echo "$queue_status" | grep -A 20 "GLOBAL QUEUE STATUS" | jq -r '.total // 0' 2>/dev/null || echo "0")
        else
            # Fallback parsing
            pending_tasks=$(echo "$queue_status" | grep '"pending"' | grep -o '[0-9]*' | head -1 || echo "0")
            completed_tasks=$(echo "$queue_status" | grep '"completed"' | grep -o '[0-9]*' | head -1 || echo "0")
            failed_tasks=$(echo "$queue_status" | grep '"failed"' | grep -o '[0-9]*' | head -1 || echo "0")
            total_tasks=$(echo "$queue_status" | grep '"total"' | grep -o '[0-9]*' | head -1 || echo "0")
        fi
        
        echo -e "Total tasks: ${total_tasks}"
        echo -e "${BLUE}Pending tasks: ${pending_tasks}${NC}"
        echo -e "${GREEN}Completed tasks: ${completed_tasks}${NC}"
        echo -e "${RED}Failed tasks: ${failed_tasks}${NC}"
        echo ""
        
        if [[ "$pending_tasks" -eq 0 ]]; then
            echo -e "${INFO} No pending tasks - system will monitor for new tasks"
        else
            echo -e "${ROCKET} Will process $pending_tasks pending tasks with enhanced automation"
        fi
        
        return 0
    else
        log_error "Failed to retrieve task queue status"
        return 1
    fi
}

# Create unique session name
generate_session_name() {
    local timestamp=$(date +%s)
    local random_suffix=$(( (RANDOM % 1000) + 1 ))
    echo "claude-auto-resume-live-${timestamp}-${random_suffix}"
}

# Display deployment information
display_deployment_info() {
    local session_name="$1"
    
    echo ""
    echo -e "${CHECK} ${GREEN}Live operation started successfully!${NC}"
    echo ""
    echo -e "${PHONE} ${BLUE}Session Information:${NC}"
    echo -e "   Session name: $session_name"
    echo ""
    echo -e "${GEAR} ${BLUE}Monitoring Commands:${NC}"
    echo -e "   Monitor progress: ${CYAN}tmux attach -t $session_name${NC}"
    echo -e "   Check task status: ${CYAN}./src/task-queue.sh status${NC}"
    echo -e "   View live logs: ${CYAN}tail -f logs/hybrid-monitor.log${NC}"
    echo ""
    echo -e "${STOP} ${BLUE}Control Commands:${NC}"
    echo -e "   Stop operation: ${CYAN}tmux kill-session -t $session_name${NC}"
    echo -e "   Pause queue: ${CYAN}./src/task-queue.sh pause${NC}"
    echo -e "   Resume queue: ${CYAN}./src/task-queue.sh resume${NC}"
    echo ""
    echo -e "${REPEAT} ${BLUE}System Features:${NC}"
    echo -e "   ${CHECK} Automatic task processing"
    echo -e "   ${CHECK} Enhanced usage limit detection with live countdown"
    echo -e "   ${CHECK} Automatic resume after wait periods"
    echo -e "   ${CHECK} Real-time progress monitoring"
    echo -e "   ${CHECK} Intelligent error recovery"
    echo -e "   ${CHECK} Resource usage monitoring"
    echo ""
}

# Main deployment function
deploy_live_operation() {
    echo -e "${INFO} ${BLUE}Starting live operation deployment...${NC}"
    echo ""
    
    # Validate prerequisites
    if ! validate_prerequisites; then
        echo ""
        log_error "Prerequisites not met - aborting deployment"
        echo ""
        echo -e "${INFO} To fix issues:"
        echo -e "   1. Install missing dependencies"
        echo -e "   2. Ensure all core components are present"
        echo -e "   3. Run: ${CYAN}chmod +x src/*.sh${NC}"
        echo ""
        exit 1
    fi
    
    # Check task queue
    if ! check_task_queue_status; then
        echo ""
        log_warn "Task queue status check failed - continuing with deployment"
    fi
    
    echo ""
    log_info "${ROCKET} Starting live operation in dedicated tmux session..."
    
    # Generate unique session name
    local session_name
    session_name=$(generate_session_name)
    
    # Build enhanced command with all advanced features
    local monitor_command="./src/hybrid-monitor.sh --queue-mode --continuous --enhanced-usage-limits --debug"
    
    # Start in dedicated tmux session with enhanced monitoring
    if tmux new-session -d -s "$session_name" -c "$PROJECT_ROOT" "$monitor_command"; then
        
        # Brief pause to let the session initialize
        sleep 2
        
        # Verify session is running
        if tmux has-session -t "$session_name" 2>/dev/null; then
            display_deployment_info "$session_name"
            
            # Optional: Show initial session output
            echo -e "${INFO} ${BLUE}Initial session output:${NC}"
            echo "----------------------------------------"
            tmux capture-pane -t "$session_name" -p | tail -5
            echo "----------------------------------------"
            echo ""
            
            log_info "Live operation deployment completed successfully!"
            
            # Provide option to attach immediately
            echo -e "${INFO} Would you like to attach to the session now? (y/N)"
            read -r -n 1 -t 10 response || response=""
            echo ""
            
            if [[ "$response" =~ ^[Yy]$ ]]; then
                echo -e "${INFO} Attaching to session... (Press ${CYAN}Ctrl+B, then D${NC} to detach)"
                sleep 1
                tmux attach -t "$session_name"
            else
                echo -e "${INFO} Session is running in background. Use the commands above to monitor."
            fi
            
        else
            log_error "Session creation appeared successful but session is not running"
            exit 1
        fi
        
    else
        log_error "Failed to start live operation in tmux session"
        echo ""
        echo -e "${INFO} Troubleshooting:"
        echo -e "   1. Check if tmux is working: ${CYAN}tmux list-sessions${NC}"
        echo -e "   2. Try manual start: ${CYAN}$monitor_command${NC}"
        echo -e "   3. Check logs: ${CYAN}ls -la logs/${NC}"
        echo ""
        exit 1
    fi
}

# Handle command line arguments
case "${1:-deploy}" in
    "deploy"|"start"|"")
        deploy_live_operation
        ;;
    "status")
        check_task_queue_status
        ;;
    "check"|"validate")
        validate_prerequisites
        echo ""
        if [[ $? -eq 0 ]]; then
            echo -e "${CHECK} ${GREEN}All prerequisites met - ready for deployment${NC}"
        else
            echo -e "${ERROR} ${RED}Prerequisites not met - see issues above${NC}"
        fi
        ;;
    "help"|"-h"|"--help")
        echo -e "${BLUE}Claude Auto-Resume Live Operation Deployment${NC}"
        echo ""
        echo "Usage: $0 [command]"
        echo ""
        echo "Commands:"
        echo "  deploy, start    Deploy live operation (default)"
        echo "  status          Check task queue status"
        echo "  check, validate  Validate system prerequisites"
        echo "  help            Show this help message"
        echo ""
        echo "Examples:"
        echo "  $0               # Start live operation"
        echo "  $0 deploy        # Same as above"
        echo "  $0 status        # Check task queue"
        echo "  $0 check         # Validate prerequisites"
        echo ""
        ;;
    *)
        log_error "Unknown command: $1"
        echo -e "${INFO} Use ${CYAN}$0 help${NC} for usage information"
        exit 1
        ;;
esac