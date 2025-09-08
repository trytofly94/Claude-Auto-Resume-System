#!/usr/bin/env bash

# Claude Auto-Resume - Streamlined Core Monitor
# Focused on essential functionality: usage limit detection + task automation
# Version: 1.0.0-streamlined
# Streamlined: 2025-09-08 - removed bloat, fixed hanging issues

set -euo pipefail

# ===============================================================================
# STREAMLINED INITIALIZATION
# ===============================================================================

# Core script info - minimal validation only
readonly SCRIPT_NAME="hybrid-monitor-streamlined"
readonly VERSION="1.0.0-streamlined"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Basic bash version check (no external deps)
if [[ "${BASH_VERSION%%.*}" -lt 4 ]]; then
    echo "[ERROR] Bash 4.0+ required. Current: $BASH_VERSION" >&2
    exit 1
fi

# ===============================================================================
# ESSENTIAL CONFIGURATION - MINIMAL ONLY
# ===============================================================================

# Core directories and runtime
WORKING_DIR="$(pwd)"
CURRENT_CYCLE=0
MONITORING_ACTIVE=false
CLEANUP_DONE=false

# Essential configuration (hardcoded to prevent complex loading)
CHECK_INTERVAL_MINUTES=5
MAX_RESTARTS=50
USAGE_LIMIT_COOLDOWN=300
USE_CLAUNCH=true
TMUX_SESSION_PREFIX="claude-auto"
LOG_LEVEL="WARN"  # Reduced logging noise
TASK_QUEUE_ENABLED=true

# Command-line variables - minimal set
CONTINUOUS_MODE=false
TEST_MODE=false
TEST_WAIT_SECONDS=30
CLAUDE_ARGS=()

# Usage limit detection patterns (CRITICAL - preserve all 8)
readonly USAGE_LIMIT_PATTERNS=(
    "usage limit exceeded"
    "Claude AI usage limit reached"
    "blocking until [0-9]+[ap]m"
    "try again at [0-9]+[ap]m"
    "rate limit exceeded"
    "too many requests"
    "request limit exceeded"
    "temporarily unavailable"
)

# ===============================================================================
# STREAMLINED UTILITIES
# ===============================================================================

# Essential utility functions only
has_command() {
    command -v "$1" >/dev/null 2>&1
}

# Simple logging without complex module loading
log_debug() { [[ "${LOG_LEVEL}" == "DEBUG" ]] && echo "[DEBUG] $*" >&2 || true; }
log_info() { [[ "${LOG_LEVEL}" =~ ^(DEBUG|INFO)$ ]] && echo "[INFO] $*" >&2 || true; }
log_warn() { echo "[WARN] $*" >&2; }
log_error() { echo "[ERROR] $*" >&2; }

# ===============================================================================
# STREAMLINED CLEANUP & SIGNALS
# ===============================================================================

# Simplified cleanup
cleanup_on_exit() {
    [[ "$CLEANUP_DONE" == "true" ]] && return
    CLEANUP_DONE=true
    MONITORING_ACTIVE=false
    log_info "Streamlined monitor shutting down"
    pkill -P $$ 2>/dev/null || true
}

# Simple interrupt handler
interrupt_handler() {
    log_info "Interrupt received - stopping monitor"
    MONITORING_ACTIVE=false
    exit 130
}

# Register signal handlers
trap cleanup_on_exit EXIT
trap interrupt_handler INT TERM

# ===============================================================================
# STREAMLINED DEPENDENCIES - ESSENTIAL ONLY
# ===============================================================================

# Load only essential dependencies without complex loading cycles
load_essential_deps() {
    log_info "Loading essential dependencies only"
    
    # Load usage limit recovery (CRITICAL - preserve all patterns)
    local usage_limit_script="$SCRIPT_DIR/usage-limit-recovery.sh"
    if [[ -f "$usage_limit_script" ]]; then
        source "$usage_limit_script" || log_warn "Failed to load usage limit recovery"
    else
        log_error "CRITICAL: Usage limit recovery not found at: $usage_limit_script"
        return 1
    fi
    
    # Load task queue (if enabled)
    if [[ "$TASK_QUEUE_ENABLED" == "true" ]]; then
        local task_queue_script="$SCRIPT_DIR/task-queue.sh"
        if [[ -f "$task_queue_script" && -x "$task_queue_script" ]]; then
            export TASK_QUEUE_SCRIPT="$task_queue_script"
            export TASK_QUEUE_AVAILABLE=true
            log_info "Task queue available"
        else
            export TASK_QUEUE_AVAILABLE=false
            log_warn "Task queue not available"
        fi
    else
        export TASK_QUEUE_AVAILABLE=false
    fi
    
    # Basic tmux validation (no complex claunch cycles)
    if [[ "$USE_CLAUNCH" == "true" ]] && ! has_command tmux; then
        log_warn "tmux not found - falling back to direct Claude CLI"
        USE_CLAUNCH=false
    fi
}


# ===============================================================================
# STREAMLINED VALIDATION - ESSENTIAL CHECKS ONLY
# ===============================================================================

# Simplified system validation without complex cycles
validate_essential_requirements() {
    log_info "Validating essential requirements only"
    
    # Claude CLI (REQUIRED)
    if ! has_command claude; then
        log_error "Claude CLI required but not found"
        log_error "Install: https://claude.ai/code"
        return 1
    fi
    
    # tmux (if using claunch mode)
    if [[ "$USE_CLAUNCH" == "true" ]] && ! has_command tmux; then
        log_warn "tmux not found - disabling claunch mode"
        USE_CLAUNCH=false
    fi
    
    # Basic directory structure
    if [[ ! -d "$SCRIPT_DIR" ]]; then
        log_error "Script directory not accessible: $SCRIPT_DIR"
        return 1
    fi
    
    log_info "Essential requirements validated"
    return 0
}

# ===============================================================================
# STREAMLINED TASK AUTOMATION - BASIC EXECUTION ONLY
# ===============================================================================

# Simple task processing without complex state management
process_pending_tasks() {
    [[ "${TASK_QUEUE_AVAILABLE:-false}" != "true" ]] && return 0
    
    log_info "Checking for pending tasks"
    
    # Simple task check without complex parsing
    local pending_count
    if pending_count=$("${TASK_QUEUE_SCRIPT}" list 2>/dev/null | grep -c "pending" || echo "0"); then
        if [[ "$pending_count" -gt 0 ]]; then
            log_info "Found $pending_count pending tasks"
            # TODO: Basic task execution logic here
            # For now, just log the finding
            return 0
        fi
    fi
    
    return 0
}

# Removed complex context clearing logic - not essential for core operation

# ===============================================================================
# CORE MONITORING - USAGE LIMIT DETECTION (CRITICAL)
# ===============================================================================

# Streamlined usage limit detection using all 8 critical patterns
check_usage_limits() {
    log_info "Checking for usage limits"
    
    # Test mode simulation
    if [[ "$TEST_MODE" == "true" ]]; then
        log_info "[TEST] Simulating usage limit (${TEST_WAIT_SECONDS}s)"
        handle_usage_limit $(($(date +%s) + TEST_WAIT_SECONDS))
        return 1
    fi
    
    # Real usage limit check
    local claude_output
    if claude_output=$(timeout 30 claude -p 'status check' 2>&1); then
        # Check all 8 critical usage limit patterns
        for pattern in "${USAGE_LIMIT_PATTERNS[@]}"; do
            if echo "$claude_output" | grep -qi "$pattern"; then
                log_warn "Usage limit detected: $pattern"
                
                # Extract timestamp if available, otherwise use default cooldown
                local resume_time
                resume_time=$(echo "$claude_output" | grep -o '[0-9]\{10,\}' | head -1 || echo "")
                if [[ -z "$resume_time" || ! "$resume_time" =~ ^[0-9]+$ ]]; then
                    resume_time=$(($(date +%s) + USAGE_LIMIT_COOLDOWN))
                fi
                
                handle_usage_limit "$resume_time"
                return 1
            fi
        done
    else
        log_warn "Failed to check Claude status"
        return 2
    fi
    
    return 0
}

# Simple usage limit waiting with countdown
handle_usage_limit() {
    local resume_timestamp="$1"
    local wait_seconds=$((resume_timestamp - $(date +%s)))
    
    [[ $wait_seconds -le 0 ]] && return 0
    
    log_info "Usage limit active - waiting ${wait_seconds}s"
    
    # Simple countdown without overwhelming output
    while [[ $wait_seconds -gt 0 ]]; do
        local hours=$((wait_seconds / 3600))
        local minutes=$(((wait_seconds % 3600) / 60))
        local secs=$((wait_seconds % 60))
        
        printf "\rResuming in: %02d:%02d:%02d" "$hours" "$minutes" "$secs"
        sleep 10  # Update every 10 seconds to reduce noise
        
        wait_seconds=$((resume_timestamp - $(date +%s)))
    done
    
    printf "\rUsage limit expired - continuing...\n"
    log_info "Usage limit wait completed"
}

# Simplified session management - basic tmux integration
start_claude_session() {
    local project_name="$(basename "$WORKING_DIR")"
    local session_name="${TMUX_SESSION_PREFIX}-${project_name}"
    
    log_info "Starting Claude session: $session_name"
    
    # Simple tmux session creation without complex validation
    if [[ "$USE_CLAUNCH" == "true" ]] && has_command tmux; then
        # Check if session already exists
        if tmux has-session -t "$session_name" 2>/dev/null; then
            log_info "Session $session_name already exists"
            return 0
        fi
        
        # Create new tmux session
        if tmux new-session -d -s "$session_name" -c "$WORKING_DIR"; then
            log_info "Created tmux session: $session_name"
            
            # Send Claude command to the session
            tmux send-keys -t "$session_name" "claude ${CLAUDE_ARGS[*]}" C-m
            return 0
        else
            log_warn "Failed to create tmux session - falling back to direct mode"
        fi
    fi
    
    # Direct Claude CLI execution (fallback)
    log_info "Starting Claude directly: ${CLAUDE_ARGS[*]}"
    claude "${CLAUDE_ARGS[@]}" &
    return 0
}

# Simple recovery command sending
send_recovery_command() {
    local project_name="$(basename "$WORKING_DIR")"
    local session_name="${TMUX_SESSION_PREFIX}-${project_name}"
    local recovery_cmd="${1:-/dev continue}"
    
    log_info "Sending recovery command: $recovery_cmd"
    
    # Send command to tmux session if available
    if has_command tmux && tmux has-session -t "$session_name" 2>/dev/null; then
        tmux send-keys -t "$session_name" "$recovery_cmd" C-m
        log_info "Recovery command sent to session $session_name"
        return 0
    else
        log_warn "No active tmux session found for recovery"
        return 1
    fi
}

# ===============================================================================
# STREAMLINED MONITORING LOOP - CORE FUNCTIONALITY ONLY
# ===============================================================================

# Main monitoring loop focused on usage limit detection + task automation
continuous_monitoring_loop() {
    log_info "Starting streamlined monitoring"
    log_info "Interval: ${CHECK_INTERVAL_MINUTES}m | Max cycles: $MAX_RESTARTS"
    log_info "Working dir: $WORKING_DIR | Args: ${CLAUDE_ARGS[*]}"
    
    MONITORING_ACTIVE=true
    local check_interval_seconds=$((CHECK_INTERVAL_MINUTES * 60))
    
    # Start initial Claude session
    start_claude_session
    
    while [[ "$MONITORING_ACTIVE" == "true" && $CURRENT_CYCLE -lt $MAX_RESTARTS ]]; do
        ((CURRENT_CYCLE++))
        
        log_info "=== Cycle $CURRENT_CYCLE/$MAX_RESTARTS ==="
        
        # Core function 1: Check usage limits (CRITICAL)
        case $(check_usage_limits; echo $?) in
            0) log_info "✓ No usage limits" ;;
            1) 
                log_info "⚠ Usage limit handled - sending recovery"
                send_recovery_command
                continue
                ;;
            2) 
                log_warn "⚠ Usage check failed - retry in 1min"
                sleep 60
                continue
                ;;
        esac
        
        # Core function 2: Process pending tasks (if enabled)
        process_pending_tasks
        
        # Wait for next check
        if [[ $CURRENT_CYCLE -lt $MAX_RESTARTS && "$MONITORING_ACTIVE" == "true" ]]; then
            log_info "Next check in ${CHECK_INTERVAL_MINUTES}m"
            
            # Interruptible sleep
            for ((i = 0; i < check_interval_seconds && MONITORING_ACTIVE; i++)); do
                sleep 1
            done
        fi
    done
    
    [[ $CURRENT_CYCLE -ge $MAX_RESTARTS ]] && log_info "Max cycles reached ($MAX_RESTARTS)"
    log_info "Monitoring completed"
}

# ===============================================================================
# STREAMLINED SESSION OPERATIONS - BASIC ONLY
# ===============================================================================

# Simple session listing
list_sessions() {
    if has_command tmux; then
        echo "Active tmux sessions:"
        tmux list-sessions 2>/dev/null | grep "$TMUX_SESSION_PREFIX" || echo "No Claude sessions found"
    else
        echo "tmux not available - cannot list sessions"
    fi
}

# Simple system status
show_system_status() {
    echo "=== Streamlined Monitor Status ==="
    echo "Version: $VERSION"
    echo "Working Directory: $WORKING_DIR"
    echo "Claude CLI: $(which claude 2>/dev/null || echo 'Not found')"
    echo "tmux: $(which tmux 2>/dev/null || echo 'Not found')"
    echo "Task Queue: ${TASK_QUEUE_AVAILABLE:-false}"
}

# Simple session cleanup
cleanup_sessions() {
    if has_command tmux; then
        log_info "Cleaning up Claude tmux sessions"
        tmux list-sessions 2>/dev/null | grep "$TMUX_SESSION_PREFIX" | cut -d: -f1 | while read -r session; do
            if tmux has-session -t "$session" 2>/dev/null; then
                tmux kill-session -t "$session" 2>/dev/null && log_info "Cleaned up session: $session" || true
            fi
        done
    fi
}

# Streamlined help - essential options only
show_help() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS] [CLAUDE_ARGS...]

Streamlined Claude monitoring with usage limit detection and task automation.

OPTIONS:
    --continuous              Enable continuous monitoring
    --check-interval MINUTES  Check interval (default: $CHECK_INTERVAL_MINUTES)
    --max-cycles COUNT        Max monitoring cycles (default: $MAX_RESTARTS) 
    --test-mode SECONDS      [DEV] Simulate usage limit wait
    --list-sessions          List active sessions
    --cleanup-sessions       Clean up orphaned sessions
    --system-status          Show system status
    --version                Show version
    -h, --help               Show this help

CLAUDE_ARGS:
    Arguments passed to Claude CLI (default: "continue")

EXAMPLES:
    # Start monitoring
    $SCRIPT_NAME --continuous
    
    # Test mode with 30s simulation
    $SCRIPT_NAME --continuous --test-mode 30
    
    # Check system status
    $SCRIPT_NAME --system-status

DEPENDENCIES:
    - Claude CLI (required)
    - tmux (optional for session management)
EOF
}

# Simple version info
show_version() {
    echo "$SCRIPT_NAME $VERSION - Streamlined Core Monitor"
    echo "Claude CLI: $(has_command claude && echo 'found' || echo 'NOT FOUND')"
    echo "tmux: $(has_command tmux && echo 'found' || echo 'not found')"
}

# Streamlined argument parsing - essential options only
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --continuous)
                CONTINUOUS_MODE=true
                shift
                ;;
            --check-interval)
                if [[ -z "${2:-}" ]] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
                    log_error "--check-interval requires valid minutes"
                    exit 1
                fi
                CHECK_INTERVAL_MINUTES="$2"
                shift 2
                ;;
            --max-cycles)
                if [[ -z "${2:-}" ]] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
                    log_error "--max-cycles requires valid number"
                    exit 1
                fi
                MAX_RESTARTS="$2"
                shift 2
                ;;
            --test-mode)
                if [[ -z "${2:-}" ]] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
                    log_error "--test-mode requires valid seconds"
                    exit 1
                fi
                TEST_MODE=true
                TEST_WAIT_SECONDS="$2"
                shift 2
                ;;
            --list-sessions)
                list_sessions
                exit 0
                ;;
            --cleanup-sessions)
                cleanup_sessions
                exit 0
                ;;
            --system-status)
                show_system_status
                exit 0
                ;;
            --version)
                show_version
                exit 0
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            -*)
                CLAUDE_ARGS+=("$1")
                shift
                ;;
            *)
                CLAUDE_ARGS+=("$1")
                shift
                ;;
        esac
    done
    
    # Default Claude args if none specified
    [[ ${#CLAUDE_ARGS[@]} -eq 0 ]] && CLAUDE_ARGS=("continue")
    
    log_info "Parsed: continuous=$CONTINUOUS_MODE, test=$TEST_MODE, args=${CLAUDE_ARGS[*]}"
}

# ===============================================================================
# STREAMLINED MAIN ENTRY POINT
# ===============================================================================

main() {
    log_info "$SCRIPT_NAME v$VERSION starting"
    
    # Parse arguments
    parse_arguments "$@"
    
    # Load essential dependencies only
    if ! load_essential_deps; then
        log_error "Failed to load essential dependencies"
        exit 1
    fi
    
    # Validate system requirements
    if ! validate_essential_requirements; then
        log_error "Essential requirements not met"
        exit 1
    fi
    
    # Main functionality
    if [[ "$CONTINUOUS_MODE" == "true" ]]; then
        continuous_monitoring_loop
    else
        log_info "Single execution mode"
        
        # Single usage limit check
        case $(check_usage_limits; echo $?) in
            0) log_info "No usage limits detected" ;;
            1) log_info "Usage limit handled" ;;
            2) log_error "Usage limit check failed"; exit 3 ;;
        esac
        
        # Start Claude session
        start_claude_session
    fi
    
    log_info "Monitor completed"
}

# Execute main if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi