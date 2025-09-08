#!/usr/bin/env bash

# Claude Auto-Resume - Hybrid Monitor
# Haupt-Monitoring-System für das claunch-basierte Claude Auto-Resume System
# Version: 1.0.0-alpha
# Letzte Aktualisierung: 2025-08-05

set -euo pipefail

# ===============================================================================
# BASH VERSION VALIDATION (ADDRESSES GITHUB ISSUE #6)
# ===============================================================================

# Script-Informationen - protect against re-sourcing
if [[ -z "${SCRIPT_NAME:-}" ]]; then
    readonly SCRIPT_NAME="hybrid-monitor"
    readonly VERSION="1.0.0-alpha"
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source bash version check utility - use absolute path resolution
BASH_VERSION_CHECK_SCRIPT="$SCRIPT_DIR/utils/bash-version-check.sh"
if [[ -f "$BASH_VERSION_CHECK_SCRIPT" && -r "$BASH_VERSION_CHECK_SCRIPT" ]]; then
    # shellcheck disable=SC1090
    source "$BASH_VERSION_CHECK_SCRIPT"
else
    echo "[ERROR] Cannot find bash version check utility at: $BASH_VERSION_CHECK_SCRIPT" >&2
    echo "        Please ensure the script is run from the correct directory" >&2
    exit 1
fi

# Validate bash version before proceeding with session management
if ! check_bash_version "hybrid-monitor.sh"; then
    exit 1
fi

# Check if this script has execute permissions (addresses GitHub issue #5)
if [[ ! -x "${BASH_SOURCE[0]}" ]]; then
    echo "[ERROR] This script is not executable!" >&2
    echo "        This usually happens after 'git clone' which doesn't preserve execute permissions." >&2
    echo "" >&2
    echo "To fix this issue, run:" >&2
    echo "  chmod +x \"${BASH_SOURCE[0]}\"" >&2
    echo "  # Or fix all project scripts at once:" >&2
    echo "  bash scripts/setup.sh --fix-permissions" >&2
    echo "" >&2
    exit 1
fi

# ===============================================================================
# GLOBALE VARIABLEN UND KONSTANTEN
# ===============================================================================
WORKING_DIR="$(pwd)"
CONFIG_FILE="config/default.conf"

# Monitoring-Konfiguration
CHECK_INTERVAL_MINUTES="${CHECK_INTERVAL_MINUTES:-5}"
MAX_RESTARTS="${MAX_RESTARTS:-50}"
USE_CLAUNCH="${USE_CLAUNCH:-true}"
NEW_TERMINAL_DEFAULT="${NEW_TERMINAL_DEFAULT:-true}"
DEBUG_MODE="${DEBUG_MODE:-false}"
DRY_RUN="${DRY_RUN:-false}"

# Runtime-Variablen
CURRENT_CYCLE=0
MAIN_SESSION_ID=""
MONITORING_ACTIVE=false
CLEANUP_DONE=false

# Command-Line-Argumente
CONTINUOUS_MODE=false
USE_NEW_TERMINAL=false
SPECIFIED_CONFIG=""
CLAUDE_ARGS=()
TEST_MODE=false
TEST_WAIT_SECONDS=30

# Task Queue Mode Argumente
QUEUE_MODE=false
ADD_ISSUE=""
ADD_PR=""
ADD_CUSTOM=""
LIST_QUEUE=false
PAUSE_QUEUE=false
RESUME_QUEUE=false
CLEAR_QUEUE=false

# Session Management Argumente (Enhanced for Per-Project - Issue #89)
LIST_SESSIONS=false
LIST_SESSIONS_BY_PROJECT=false
STOP_SESSION=false
STOP_PROJECT_SESSION=false
CLEANUP_SESSIONS=false
SWITCH_PROJECT=""
SHOW_SESSION_ID=false
SYSTEM_STATUS=false

# Setup Wizard Argumente
FORCE_WIZARD=false
SKIP_WIZARD=false

# ===============================================================================
# UTILITY-FUNKTIONEN (früh definiert für Validierung)
# ===============================================================================

# Prüfe ob Kommando verfügbar ist
has_command() {
    command -v "$1" >/dev/null 2>&1
}

# ===============================================================================
# SIGNAL-HANDLER UND CLEANUP
# ===============================================================================

# Cleanup-Funktion
cleanup_on_exit() {
    local exit_code=$?
    
    if [[ "$CLEANUP_DONE" == "true" ]]; then
        return
    fi
    
    CLEANUP_DONE=true
    MONITORING_ACTIVE=false
    
    # Don't log the exit code for help/version commands that exit 0
    if [[ $exit_code -eq 0 ]]; then
        log_debug "Hybrid monitor shutting down normally"
    else
        log_info "Hybrid monitor shutting down (exit code: $exit_code)"
    fi
    
    # Stoppe Hintergrund-Prozesse
    pkill -P $$ 2>/dev/null || true
    
    # Session-Cleanup falls erforderlich
    if [[ -n "$MAIN_SESSION_ID" ]] && declare -f stop_managed_session >/dev/null 2>&1; then
        log_debug "Cleaning up main session: $MAIN_SESSION_ID"
        stop_managed_session "$MAIN_SESSION_ID" >/dev/null 2>&1 || true
    fi
    
    log_debug "Hybrid monitor cleanup completed"
}

# Signal-Handler
interrupt_handler() {
    log_info "Interrupt signal received (Ctrl+C)"
    MONITORING_ACTIVE=false
    cleanup_on_exit
    exit 130
}

# Frühe Logging-Initialisierung vor Signal-Handlern
init_early_logging() {
    # Fallback-Logging falls Module noch nicht geladen
    if ! declare -f log_info >/dev/null 2>&1; then
        log_debug() { [[ "${DEBUG_MODE:-false}" == "true" ]] && echo "[DEBUG] $*" >&2 || true; }
        log_info() { echo "[INFO] $*" >&2; }
        log_warn() { echo "[WARN] $*" >&2; }
        log_error() { echo "[ERROR] $*" >&2; }
    fi
}

# Initialisiere frühe Logging-Funktionen
init_early_logging

# Signal-Handler registrieren
trap cleanup_on_exit EXIT
trap interrupt_handler INT TERM

# ===============================================================================
# DEPENDENCY-LOADING UND INITIALIZATION
# ===============================================================================

# Lade alle erforderlichen Module
load_dependencies() {
    log_debug "Loading dependencies from: $SCRIPT_DIR"
    
    # Lade Utility-Module in korrekter Reihenfolge
    local modules=(
        "utils/config-loader.sh"
        "utils/logging.sh"
        "utils/network.sh" 
        "utils/terminal.sh"
        "claunch-integration.sh"
        "session-manager.sh"
    )
    
    # Task Queue Module (optional - nur wenn verfügbar)
    # Note: task-queue.sh is designed as standalone script, not for sourcing
    # We'll use it via direct execution rather than sourcing
    local task_queue_script="$SCRIPT_DIR/task-queue.sh"
    if [[ -f "$task_queue_script" && -r "$task_queue_script" && -x "$task_queue_script" ]]; then
        # Test if task-queue.sh is functional
        if "$task_queue_script" list >/dev/null 2>&1; then
            log_debug "Task Queue script validated and functional"
            export TASK_QUEUE_AVAILABLE=true
            export TASK_QUEUE_SCRIPT="$task_queue_script"
        else
            log_warn "Task Queue script exists but not functional"
            export TASK_QUEUE_AVAILABLE=false
        fi
    else
        log_warn "Task Queue script not found or not executable at: $task_queue_script"
        export TASK_QUEUE_AVAILABLE=false
    fi
    
    for module in "${modules[@]}"; do
        local module_path="$SCRIPT_DIR/$module"
        if [[ -f "$module_path" ]]; then
            # shellcheck source=/dev/null
            source "$module_path"
            log_debug "Loaded module: $module"
        else
            log_warn "Module not found: $module_path"
        fi
    done
}


# ===============================================================================
# KONFIGURATION UND VALIDIERUNG
# ===============================================================================

# Load configuration using centralized loader (Issue #114)
load_configuration() {
    local config_path="${SPECIFIED_CONFIG:-$CONFIG_FILE}"
    
    # Try to resolve config path if not absolute
    if [[ ! -f "$config_path" ]]; then
        config_path="$SCRIPT_DIR/../$CONFIG_FILE"
    fi
    
    # Use centralized config loader
    if ! load_system_config "$config_path"; then
        log_warn "Failed to load configuration, using defaults"
        return 1
    fi
    
    # Export configuration as environment variables for backward compatibility
    export_config_as_env
    
    return 0
}

# Lade Task Queue Konfiguration und bestimme Processing-Modus
load_task_queue_config() {
    log_debug "Loading task queue configuration"
    
    # Task Queue Processing aktivieren wenn:
    # 1. TASK_QUEUE_ENABLED=true in config, oder 
    # 2. --queue-mode CLI parameter verwendet wird
    local task_enabled
    task_enabled=$(get_config "TASK_QUEUE_ENABLED" "false")
    if [[ "$task_enabled" == "true" || "${QUEUE_MODE:-false}" == "true" ]]; then
        if [[ "${TASK_QUEUE_AVAILABLE:-false}" == "true" ]]; then
            export TASK_QUEUE_PROCESSING=true
            log_info "Task Queue processing enabled"
            
            # Initialize task queue system
            if declare -f init_task_queue_system >/dev/null 2>&1; then
                if ! init_task_queue_system; then
                    log_error "Failed to initialize task queue system"
                    export TASK_QUEUE_PROCESSING=false
                    return 1
                fi
            fi
        else
            log_warn "Task Queue processing requested but module not available"
            export TASK_QUEUE_PROCESSING=false
            return 1
        fi
    else
        export TASK_QUEUE_PROCESSING=false
        log_debug "Task Queue processing disabled"
    fi
    
    return 0
}

# Validiere Systemvoraussetzungen
validate_system_requirements() {
    log_info "Validating system requirements"
    
    local errors=0
    
    # Claude CLI prüfen
    if ! has_command claude; then
        log_error "Claude CLI not found in PATH"
        log_error "Please install Claude CLI: https://claude.ai/code"
        ((errors++))
    fi
    
    # Enhanced claunch detection with graceful fallback (addresses GitHub issue #77)
    if [[ "$USE_CLAUNCH" == "true" ]]; then
        log_debug "Validating claunch availability with enhanced detection..."
        
        # Use enhanced detection if available
        if declare -f detect_claunch >/dev/null 2>&1; then
            if detect_claunch >/dev/null 2>&1; then
                log_debug "claunch detected successfully via enhanced detection"
                
                # Validate functionality
                if declare -f validate_claunch >/dev/null 2>&1; then
                    if validate_claunch >/dev/null 2>&1; then
                        log_debug "claunch validated and functional"
                    else
                        log_warn "claunch detected but validation failed"
                        log_info "System will automatically fall back to direct Claude CLI mode"
                        USE_CLAUNCH="false"
                    fi
                fi
            else
                log_warn "claunch not detected with enhanced detection methods"
                log_info "Gracefully falling back to direct Claude CLI mode"
                log_info "Install claunch to enable full session management features:"
                log_info "  ./scripts/install-claunch.sh"
                USE_CLAUNCH="false"
            fi
        else
            # Fallback to basic detection
            if ! has_command claunch; then
                log_warn "claunch not found in PATH (USE_CLAUNCH=true but claunch unavailable)"
                log_info "Automatically switching to direct Claude CLI mode"
                log_info "To enable claunch features, install with: ./scripts/install-claunch.sh"
                USE_CLAUNCH="false"
            fi
        fi
    fi
    
    # tmux prüfen (falls CLAUNCH_MODE=tmux)
    if [[ "$USE_CLAUNCH" == "true" && "$CLAUNCH_MODE" == "tmux" ]]; then
        if ! has_command tmux; then
            log_error "tmux not found but CLAUNCH_MODE=tmux"
            log_error "Please install tmux: brew install tmux (macOS) or apt install tmux (Ubuntu)"
            ((errors++))
        fi
    fi
    
    # Netzwerk-Connectivity prüfen
    if ! check_network_connectivity >/dev/null 2>&1; then
        log_warn "Network connectivity issues detected"
        log_warn "Some features may not work properly"
    fi
    
    if [[ $errors -gt 0 ]]; then
        log_error "$errors system requirement(s) not met"
        return 1
    fi
    
    log_info "All system requirements validated"
    return 0
}

# ===============================================================================
# TASK QUEUE OPERATIONS
# ===============================================================================

# Behandle Task Queue CLI Operations
handle_task_queue_operations() {
    log_debug "Processing task queue operations"
    
    # Prüfe ob Task Queue verfügbar ist
    if [[ "${TASK_QUEUE_AVAILABLE:-false}" != "true" ]]; then
        log_error "Task Queue module not available - cannot process queue operations"
        return 1
    fi
    
    # Handle verschiedene Queue-Operationen
    local operation_handled=false
    
    if [[ "$ADD_ISSUE" != "" ]]; then
        log_info "Adding GitHub issue to queue: $ADD_ISSUE"
        if "${TASK_QUEUE_SCRIPT}" add github_issue "$ADD_ISSUE" "Process GitHub Issue #$ADD_ISSUE"; then
            log_info "Successfully added GitHub issue $ADD_ISSUE to queue"
            operation_handled=true
        else
            log_error "Failed to add GitHub issue $ADD_ISSUE to queue"
        fi
    fi
    
    if [[ "$ADD_PR" != "" ]]; then
        log_info "Adding GitHub PR to queue: $ADD_PR"
        if "${TASK_QUEUE_SCRIPT}" add github_pr "$ADD_PR" "Process GitHub PR #$ADD_PR"; then
            log_info "Successfully added GitHub PR $ADD_PR to queue"
            operation_handled=true
        else
            log_error "Failed to add GitHub PR $ADD_PR to queue"
        fi
    fi
    
    if [[ "$ADD_CUSTOM" != "" ]]; then
        log_info "Adding custom task to queue: $ADD_CUSTOM"
        # Generate unique task ID
        local task_id
        task_id="custom-$(date +%s)"
        if "${TASK_QUEUE_SCRIPT}" add custom 3 "$task_id" "description" "$ADD_CUSTOM"; then
            log_info "Successfully added custom task to queue: $task_id"
            operation_handled=true
        else
            log_error "Failed to add custom task to queue"
        fi
    fi
    
    if [[ "$LIST_QUEUE" == "true" ]]; then
        log_info "Displaying task queue:"
        "${TASK_QUEUE_SCRIPT}" list
        operation_handled=true
    fi
    
    if [[ "$PAUSE_QUEUE" == "true" ]]; then
        log_info "Pausing task queue"
        if "${TASK_QUEUE_SCRIPT}" pause "Manual pause via CLI"; then
            log_info "Task queue paused successfully"
            operation_handled=true
        else
            log_error "Failed to pause task queue"
        fi
    fi
    
    if [[ "$RESUME_QUEUE" == "true" ]]; then
        log_info "Resuming task queue"
        if "${TASK_QUEUE_SCRIPT}" resume; then
            log_info "Task queue resumed successfully"
            operation_handled=true
        else
            log_error "Failed to resume task queue"
        fi
    fi
    
    if [[ "$CLEAR_QUEUE" == "true" ]]; then
        log_info "Clearing task queue"
        if "${TASK_QUEUE_SCRIPT}" clear "Manual clear via CLI"; then
            log_info "Task queue cleared successfully"
            operation_handled=true
        else
            log_error "Failed to clear task queue"
        fi
    fi
    
    return 0
}

# Verarbeite Task Queue (wird von continuous_monitoring_loop() aufgerufen)
process_task_queue() {
    log_debug "Checking task queue for pending tasks"
    
    # Prüfe ob Queue verfügbar ist
    if [[ "${TASK_QUEUE_AVAILABLE:-false}" != "true" ]]; then
        log_debug "Task queue not available - skipping processing"
        return 0
    fi
    
    # Prüfe ob Queue pausiert ist
    if "${TASK_QUEUE_SCRIPT}" status | grep -q "Queue Status: paused"; then
        log_debug "Task queue is paused - skipping processing"
        return 0
    fi
    
    # Prüfe auf pending tasks - verwende task-queue.sh list command
    local pending_tasks
    pending_tasks=$("${TASK_QUEUE_SCRIPT}" list --status=pending --count-only 2>/dev/null)
    if [[ -z "$pending_tasks" || "$pending_tasks" -eq 0 ]]; then
        log_debug "No pending tasks in queue"
        return 0
    fi
    
    # Hole nächste Task - für Phase 1 nur ersten pending task identifizieren
    local next_task_id
    next_task_id=$("${TASK_QUEUE_SCRIPT}" list --status=pending --format=id-only --limit=1 2>/dev/null | head -1)
    if [[ -z "$next_task_id" ]]; then
        log_debug "No executable tasks available"
        return 0
    fi
    
    log_info "Found pending task for processing: $next_task_id"
    
    # Get task data for context clearing decisions
    local task_data
    task_data=$("${TASK_QUEUE_SCRIPT}" show "$next_task_id" 2>/dev/null)
    
    # Placeholder für Phase 2 - aktuell nur logging
    # TODO: Implement execute_single_task function in Phase 2
    log_info "Task processing will be implemented in Phase 2: $next_task_id"
    
    # NOTE: When task execution is implemented, add context clearing here:
    # if task_completed_successfully; then
    #     execute_context_clearing "$task_data" "normal" "${MAIN_SESSION_ID:-}"
    # elif usage_limit_hit; then
    #     # Don't clear context for usage limit recovery
    #     log_debug "Usage limit hit, preserving context for recovery"
    # fi
    
    return 0
}

# ===============================================================================
# CONTEXT CLEARING DECISION LOGIC (Issue #93)
# ===============================================================================

# Decide whether context should be cleared after task completion
# Arguments:
#   $1: task_json - JSON data of the task
#   $2: completion_reason - "normal", "usage_limit_recovery", "error", etc.
should_clear_context() {
    local task_json="$1"
    local completion_reason="${2:-normal}"
    
    # Validate input
    if [[ -z "$task_json" ]]; then
        log_error "should_clear_context: task_json parameter required"
        return 1
    fi
    
    log_debug "Evaluating context clearing for completion reason: $completion_reason"
    
    # Usage limit recovery: never clear context (preserve for continuation)
    if [[ "$completion_reason" == "usage_limit_recovery" ]]; then
        log_debug "Usage limit recovery detected - preserving context"
        return 1  # Don't clear
    fi
    
    # Error scenarios: preserve context for debugging
    if [[ "$completion_reason" == "error" || "$completion_reason" == "timeout" ]]; then
        log_debug "Error/timeout completion - preserving context for debugging"
        return 1  # Don't clear
    fi
    
    # Check task-level override (takes priority over global config)
    local task_clear_preference
    task_clear_preference=$(echo "$task_json" | jq -r '.clear_context // null')
    
    if [[ "$task_clear_preference" != "null" ]]; then
        log_debug "Task-level clear_context preference found: $task_clear_preference"
        if [[ "$task_clear_preference" == "true" ]]; then
            log_debug "Task explicitly requests context clearing"
            return 0  # Clear
        else
            log_debug "Task explicitly requests context preservation"
            return 1  # Don't clear
        fi
    fi
    
    # Fall back to global configuration
    local global_clear_setting="${QUEUE_SESSION_CLEAR_BETWEEN_TASKS:-true}"
    log_debug "Using global configuration QUEUE_SESSION_CLEAR_BETWEEN_TASKS: $global_clear_setting"
    
    if [[ "$global_clear_setting" == "true" ]]; then
        log_debug "Global config enables context clearing between tasks"
        return 0  # Clear
    else
        log_debug "Global config disables context clearing between tasks"
        return 1  # Don't clear
    fi
}

# Execute context clearing for a completed task
execute_context_clearing() {
    local task_json="$1"
    local completion_reason="${2:-normal}"
    local session_id="${3:-}"
    
    # Validate required parameters
    if [[ -z "$task_json" ]]; then
        log_error "execute_context_clearing: task_json parameter required"
        return 1
    fi
    
    # Check if we should clear context
    if ! should_clear_context "$task_json" "$completion_reason"; then
        log_info "Skipping context clearing per configuration/task preference"
        return 0
    fi
    
    # If no specific session ID provided, try to find the active one
    if [[ -z "$session_id" ]]; then
        # Try to find an active session (this logic might need refinement)
        if [[ -n "${MAIN_SESSION_ID:-}" ]] && is_context_clearing_supported "${MAIN_SESSION_ID}"; then
            session_id="$MAIN_SESSION_ID"
            log_debug "Using main session for context clearing: $session_id"
        else
            log_warn "No suitable session found for context clearing"
            return 1
        fi
    fi
    
    # Verify context clearing is supported for this session
    if ! is_context_clearing_supported "$session_id"; then
        log_warn "Context clearing not supported for session: $session_id"
        return 1
    fi
    
    # Execute the context clear
    local task_id
    task_id=$(echo "$task_json" | jq -r '.id // "unknown"')
    
    log_info "Executing context clearing after task completion: $task_id"
    if send_context_clear_command "$session_id"; then
        log_info "Context successfully cleared after task: $task_id"
        return 0
    else
        log_error "Failed to clear context after task: $task_id"
        return 1
    fi
}

# ===============================================================================
# MONITORING-KERNFUNKTIONEN
# ===============================================================================

# Prüfe Usage-Limits mit verschiedenen Methoden
check_usage_limits() {
    log_debug "Checking for Claude usage limits"
    
    local limit_detected=false
# Removed unused wait_time variable
    local resume_timestamp=0
    
    # Test-Modus für Entwicklung
    if [[ "$TEST_MODE" == "true" ]]; then
        log_info "[TEST MODE] Simulating usage limit with ${TEST_WAIT_SECONDS}s wait"
        resume_timestamp=$(date -d "+${TEST_WAIT_SECONDS} seconds" +%s 2>/dev/null || date -v+"${TEST_WAIT_SECONDS}"S +%s 2>/dev/null || echo $(($(date +%s) + "${TEST_WAIT_SECONDS}")))
        limit_detected=true
    else
        # Echte Limit-Prüfung
        local claude_output
        
        if claude_output=$(timeout 30 claude -p 'check' 2>&1); then
            local exit_code=$?
            
            if [[ $exit_code -eq 124 ]]; then
                log_warn "Claude CLI timeout during limit check"
                return 2
            fi
            
            # Prüfe Output auf Limit-Meldungen
            if echo "$claude_output" | grep -q "Claude AI usage limit reached\|usage limit reached"; then
                log_info "Usage limit detected via CLI check"
                limit_detected=true
                
                # Extrahiere Timestamp falls vorhanden
                local extracted_timestamp
                extracted_timestamp=$(echo "$claude_output" | grep -o '[0-9]\{10,\}' | head -1 || echo "")
                
                if [[ -n "$extracted_timestamp" && "$extracted_timestamp" =~ ^[0-9]+$ ]]; then
                    resume_timestamp="$extracted_timestamp"
                else
                    # Standard-Wartezeit falls kein Timestamp verfügbar
                    resume_timestamp=$(date -d "+${USAGE_LIMIT_COOLDOWN:-300} seconds" +%s 2>/dev/null || date -v+"${USAGE_LIMIT_COOLDOWN:-300}"S +%s 2>/dev/null || echo $(($(date +%s) + ${USAGE_LIMIT_COOLDOWN:-300})))
                fi
            fi
        else
            log_warn "Failed to check Claude usage limits"
            return 2
        fi
    fi
    
    if [[ "$limit_detected" == "true" ]]; then
        handle_usage_limit "$resume_timestamp"
        return 1
    fi
    
    return 0
}

# Behandle Usage-Limit mit intelligentem Warten
handle_usage_limit() {
    local resume_timestamp="$1"
    local current_timestamp
    current_timestamp=$(date +%s)
    local wait_seconds=$((resume_timestamp - current_timestamp))
    
    if [[ $wait_seconds -le 0 ]]; then
        log_info "Usage limit already expired"
        return 0
    fi
    
    log_info "Usage limit detected - waiting $wait_seconds seconds"
    
    # Live-Countdown anzeigen
    while [[ $wait_seconds -gt 0 ]]; do
        local hours=$((wait_seconds / 3600))
        local minutes=$(((wait_seconds % 3600) / 60))
        local seconds=$((wait_seconds % 60))
        
        printf "\rUsage limit expires in %02d:%02d:%02d..." "$hours" "$minutes" "$seconds"
        sleep 1
        
        current_timestamp=$(date +%s)
        wait_seconds=$((resume_timestamp - current_timestamp))
    done
    
    printf "\rUsage limit expired - resuming operations    \n"
    log_info "Usage limit wait period completed"
}

# Starte oder setze Claude-Session fort
start_or_continue_claude_session() {
    log_info "Starting or continuing Claude session"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would start Claude session with args: ${CLAUDE_ARGS[*]}"
        return 0
    fi
    
    local project_name
    project_name=$(basename "$WORKING_DIR")
    
    # Enhanced session management with intelligent fallback (addresses GitHub issue #77)
    if [[ "$USE_CLAUNCH" == "true" ]]; then
        log_info "Starting Claude via claunch integration"
        
        # Try claunch integration first
        if declare -f start_managed_session >/dev/null 2>&1; then
            if MAIN_SESSION_ID=$(start_managed_session "$project_name" "$WORKING_DIR" "$USE_NEW_TERMINAL" "${CLAUDE_ARGS[@]}"); then
                log_info "Claude session started successfully via claunch (ID: $MAIN_SESSION_ID)"
                return 0
            else
                log_warn "claunch session start failed - falling back to direct mode"
                USE_CLAUNCH="false"
                # Continue to direct mode below
            fi
        else
            log_warn "claunch session management not available - falling back to direct mode"
            USE_CLAUNCH="false"
            # Continue to direct mode below  
        fi
    fi
    
    # Direct Claude CLI mode (either configured or fallen back)
    if [[ "$USE_CLAUNCH" == "false" ]]; then
        log_info "Starting Claude directly (direct mode)"
        
        # Use enhanced direct mode functions if available
        if declare -f start_claude_direct >/dev/null 2>&1; then
            if [[ "$USE_NEW_TERMINAL" == "true" ]]; then
                start_claude_direct_in_new_terminal "$WORKING_DIR" "${CLAUDE_ARGS[@]}"
            else
                start_claude_direct "$WORKING_DIR" "${CLAUDE_ARGS[@]}"
            fi
        else
            # Fallback to terminal integration or basic direct execution
            if [[ "$USE_NEW_TERMINAL" == "true" ]]; then
                # Try to use terminal integration
                if declare -f open_claude_in_terminal >/dev/null 2>&1; then
                    open_claude_in_terminal "${CLAUDE_ARGS[@]}"
                else
                    log_warn "Terminal integration not available - running in current terminal"
                    claude "${CLAUDE_ARGS[@]}"
                fi
            else
                # Direct execution without bypass flags for security
                claude "${CLAUDE_ARGS[@]}"
            fi
        fi
    fi
}

# Sende Recovery-Kommando an aktive Session
send_recovery_command() {
    local recovery_command="${1:-/dev bitte mach weiter}"
    
    log_info "Sending recovery command to active session"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would send recovery command: $recovery_command"
        return 0
    fi
    
    # Enhanced recovery with fallback support (addresses GitHub issue #77)
    if [[ "$USE_CLAUNCH" == "true" && -n "$MAIN_SESSION_ID" ]]; then
        # Verwende Session-Manager für Recovery
        if declare -f perform_session_recovery >/dev/null 2>&1; then
            perform_session_recovery "$MAIN_SESSION_ID" "usage_limit"
        elif declare -f send_recovery_command >/dev/null 2>&1; then
            send_recovery_command "$recovery_command"
        else
            log_warn "No recovery method available in claunch mode"
            return 1
        fi
    else
        log_warn "Recovery command sending only supported with claunch integration"
        if [[ "$USE_CLAUNCH" == "false" ]]; then
            log_info "Running in direct Claude CLI mode - automatic recovery not available"
            log_info "Please manually restart your Claude session if needed"
        fi
        return 1
    fi
}

# ===============================================================================
# HAUPT-MONITORING-SCHLEIFE
# ===============================================================================

# Kontinuierliches Monitoring
continuous_monitoring_loop() {
    log_info "Starting continuous monitoring mode"
    log_info "Configuration:"
    log_info "  Check interval: $CHECK_INTERVAL_MINUTES minutes"
    log_info "  Max cycles: $MAX_RESTARTS"
    log_info "  Working directory: $WORKING_DIR"
    log_info "  Use claunch: $USE_CLAUNCH"
    log_info "  Use new terminal: $USE_NEW_TERMINAL"
    log_info "  Task queue processing: ${TASK_QUEUE_PROCESSING:-false}"
    
    if [[ "${#CLAUDE_ARGS[@]}" -gt 0 ]]; then
        log_info "  Claude arguments: ${CLAUDE_ARGS[*]}"
    fi
    
    echo ""
    
    MONITORING_ACTIVE=true
    local check_interval_seconds=$((CHECK_INTERVAL_MINUTES * 60))
    
    while [[ "$MONITORING_ACTIVE" == "true" && $CURRENT_CYCLE -lt $MAX_RESTARTS ]]; do
        ((CURRENT_CYCLE++))
        
        log_info "=== Monitoring Cycle $CURRENT_CYCLE/$MAX_RESTARTS ==="
        echo "$(date): Starting check cycle $CURRENT_CYCLE"
        
        # Schritt 1: Prüfe Usage-Limits
        log_debug "Step 1: Checking usage limits"
        case $(check_usage_limits; echo $?) in
            0)
                log_info "✓ No usage limits detected"
                ;;
            1)
                log_info "⚠ Usage limit detected and handled"
                # Nach Usage-Limit-Behandlung zum nächsten Zyklus
                continue
                ;;
            2)
                log_warn "⚠ Usage limit check failed - retrying in 1 minute"
                sleep 60
                continue
                ;;
        esac
        
        # Schritt 2: Prüfe Session-Status (falls claunch verwendet wird)
        if [[ "$USE_CLAUNCH" == "true" && -n "$MAIN_SESSION_ID" ]]; then
            log_debug "Step 2: Checking session health"
            
            if declare -f perform_health_check >/dev/null 2>&1; then
                if perform_health_check "$MAIN_SESSION_ID"; then
                    log_info "✓ Session health check passed"
                    
                    # Prüfe auf Usage-Limits in der Session
                    if declare -f detect_usage_limit >/dev/null 2>&1; then
                        if detect_usage_limit "$MAIN_SESSION_ID"; then
                            log_info "Usage limit detected in session - sending recovery command"
                            send_recovery_command
                        fi
                    fi
                else
                    log_warn "⚠ Session health check failed"
                    
                    if [[ "$AUTO_RECOVERY_ENABLED" == "true" ]]; then
                        log_info "Starting automatic session recovery"
                        if declare -f perform_session_recovery >/dev/null 2>&1; then
                            perform_session_recovery "$MAIN_SESSION_ID" "auto"
                        fi
                    fi
                fi
            fi
        else
            log_debug "Step 2: Starting new Claude session"
            
            # Keine aktive Session - starte neue
            if ! start_or_continue_claude_session; then
                log_error "Failed to start Claude session"
                continue
            fi
        fi
        
        # Schritt 2.5: Task Queue Processing (NEU)
        if [[ "${TASK_QUEUE_PROCESSING:-false}" == "true" ]]; then
            log_debug "Step 2.5: Processing task queue"
            process_task_queue
        fi
        
        # Schritt 3: Nächster Check
        if [[ $CURRENT_CYCLE -lt $MAX_RESTARTS && "$MONITORING_ACTIVE" == "true" ]]; then
            local next_check_time
            next_check_time=$(date -d "+$CHECK_INTERVAL_MINUTES minutes" 2>/dev/null || date -v+"${CHECK_INTERVAL_MINUTES}"M 2>/dev/null || echo "in $CHECK_INTERVAL_MINUTES minutes")
            
            log_info "Next check at: $next_check_time"
            log_debug "Waiting $CHECK_INTERVAL_MINUTES minutes before next check"
            
            # Interruptable sleep
            for ((i = 0; i < check_interval_seconds && MONITORING_ACTIVE; i++)); do
                sleep 1
            done
        fi
    done
    
    if [[ $CURRENT_CYCLE -ge $MAX_RESTARTS ]]; then
        log_info "Maximum monitoring cycles reached ($MAX_RESTARTS)"
    fi
    
    log_info "Continuous monitoring completed"
}

# ===============================================================================
# SESSION MANAGEMENT OPERATIONS
# ===============================================================================

# Handle Session Management Operations (non-queue operations)
# Enhanced Session Management Operations Handler (Issue #89)
handle_session_management_operations() {
    log_debug "Processing enhanced session management operations"
    
    local operation_handled=false
    
    # Legacy session listing
    if [[ "$LIST_SESSIONS" == "true" ]]; then
        log_info "Listing active Claude sessions (legacy format)"
        if declare -f list_sessions >/dev/null 2>&1; then
            list_sessions
            operation_handled=true
        else
            log_error "Session management module not available"
            return 1
        fi
    fi
    
    # Enhanced project-aware session listing  
    if [[ "$LIST_SESSIONS_BY_PROJECT" == "true" ]]; then
        log_info "Listing sessions organized by project"
        if declare -f list_sessions_by_project >/dev/null 2>&1; then
            list_sessions_by_project
            operation_handled=true
        else
            log_warn "Per-project session listing not available, falling back to legacy format"
            if declare -f list_sessions >/dev/null 2>&1; then
                list_sessions
                operation_handled=true
            fi
        fi
    fi
    
    # Stop session for current project
    if [[ "$STOP_SESSION" == "true" || "$STOP_PROJECT_SESSION" == "true" ]]; then
        log_info "Stopping session for current project"
        if declare -f stop_project_session >/dev/null 2>&1; then
            if stop_project_session; then
                log_info "Project session stopped successfully"
                operation_handled=true
            else
                log_error "Failed to stop project session"
                return 1
            fi
        else
            log_error "Per-project session management not available"
            return 1
        fi
    fi
    
    # Clean up inactive/orphaned sessions
    if [[ "$CLEANUP_SESSIONS" == "true" ]]; then
        log_info "Cleaning up inactive/orphaned sessions"
        local cleaned_count=0
        
        # Clean up session-manager tracked sessions
        if declare -f cleanup_sessions >/dev/null 2>&1; then
            cleanup_sessions
            ((cleaned_count++)) || true
        fi
        
        # Clean up claunch orphaned sessions  
        if declare -f cleanup_orphaned_sessions >/dev/null 2>&1; then
            cleanup_orphaned_sessions
            ((cleaned_count++)) || true
        fi
        
        if [[ $cleaned_count -gt 0 ]]; then
            log_info "Session cleanup completed"
            operation_handled=true
        else
            log_warn "No session cleanup functions available"
        fi
    fi
    
    # Switch project context
    if [[ -n "$SWITCH_PROJECT" ]]; then
        log_info "Switching to project context: $SWITCH_PROJECT"
        
        # Validate project path
        if [[ ! -d "$SWITCH_PROJECT" ]]; then
            log_error "Project directory does not exist: $SWITCH_PROJECT"
            return 1
        fi
        
        # Change working directory 
        if cd "$SWITCH_PROJECT"; then
            log_info "Switched to project directory: $(pwd)"
            
            # Initialize local queue if available
            if declare -f detect_local_queue >/dev/null 2>&1; then
                if detect_local_queue; then
                    log_info "Local task queue detected for project"
                else
                    log_debug "No local task queue found for project"
                fi
            fi
            
            # Update working directory for subsequent operations
            WORKING_DIR="$(pwd)"
            operation_handled=true
        else
            log_error "Failed to switch to project directory: $SWITCH_PROJECT"
            return 1
        fi
    fi
    
    if [[ "$SHOW_SESSION_ID" == "true" ]]; then
        log_info "Showing current session ID"
        if [[ -n "${MAIN_SESSION_ID:-}" ]]; then
            echo "Current session ID: $MAIN_SESSION_ID"
            operation_handled=true
        elif declare -f get_current_session_id >/dev/null 2>&1; then
            local session_id
            if session_id=$(get_current_session_id); then
                echo "Current session ID: $session_id"
                operation_handled=true
            else
                echo "No active session found"
                operation_handled=true
            fi
        else
            echo "Session management not initialized - no session ID available"
            operation_handled=true
        fi
    fi
    
    if [[ "$SYSTEM_STATUS" == "true" ]]; then
        log_info "Showing system status"
        echo "=== Hybrid Claude Monitor System Status ==="
        echo "Version: $VERSION"
        echo "Script Directory: $SCRIPT_DIR"
        echo "Working Directory: $WORKING_DIR"
        echo "Configuration: ${SPECIFIED_CONFIG:-$CONFIG_FILE}"
        echo ""
        echo "=== Module Status ==="
        echo "Task Queue Available: ${TASK_QUEUE_AVAILABLE:-false}"
        echo "Task Queue Processing: ${TASK_QUEUE_PROCESSING:-false}"
        echo "Claude Integration: $USE_CLAUNCH"
        if [[ "$USE_CLAUNCH" == "true" ]]; then
            echo "Claunch Mode: $CLAUNCH_MODE"
        else
            echo "Claunch Mode: Direct Claude CLI (fallback)"
        fi
        echo ""
        echo "=== Dependencies ==="
        echo "Claude CLI: $(which claude 2>/dev/null || echo 'Not found')"
        
        # Enhanced claunch detection for status report
        local claunch_status="Not found"
        if has_command claunch; then
            claunch_status="$(claunch --version 2>/dev/null | head -1 || echo 'Found but version unknown')"
        elif declare -f detect_claunch >/dev/null 2>&1 && detect_claunch >/dev/null 2>&1; then
            claunch_status="Detected at: $CLAUNCH_PATH"
        fi
        echo "Claunch: $claunch_status"
        
        echo "tmux: $(which tmux 2>/dev/null || echo 'Not found')"
        echo "jq: $(which jq 2>/dev/null || echo 'Not found')"
        echo ""
        if [[ "${TASK_QUEUE_AVAILABLE:-false}" == "true" ]]; then
            echo "=== Task Queue Status ==="
            "${TASK_QUEUE_SCRIPT:-src/task-queue.sh}" status 2>/dev/null || echo "Task queue status unavailable"
        else
            echo "=== Task Queue Status ==="
            echo "Task Queue module not available"
        fi
        operation_handled=true
    fi
    
    if [[ "$operation_handled" == "false" ]]; then
        log_error "No valid session management operations specified"
        return 1
    fi
    
    return 0
}

# ===============================================================================
# COMMAND-LINE-INTERFACE
# ===============================================================================

# Zeige Hilfe
show_help() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS] [CLAUDE_ARGS...]

Hybrid monitoring system for Claude CLI sessions with claunch integration.

OPTIONS:
    --continuous              Enable continuous monitoring mode
    --check-interval MINUTES  Monitoring check interval (default: $CHECK_INTERVAL_MINUTES)
    --max-cycles COUNT        Maximum monitoring cycles (default: $MAX_RESTARTS)
    --new-terminal           Open Claude in new terminal windows
    --config FILE            Use specific configuration file
    --test-mode SECONDS      [DEV] Simulate usage limit with specified wait time
    --debug                  Enable debug output
    --dry-run                Preview actions without executing them
    --version                Show version information
    -h, --help               Show this help message

TASK QUEUE OPTIONS:
    --queue-mode             Enable task queue processing mode
    --add-issue NUMBER       Add GitHub issue to task queue
    --add-pr NUMBER          Add GitHub PR to task queue  
    --add-custom "TASK"      Add custom task to queue
    --list-queue             Display current task queue
    --pause-queue            Pause task queue processing
    --resume-queue           Resume task queue processing
    --clear-queue            Clear all tasks from queue

SESSION MANAGEMENT OPTIONS:
    --list-sessions                 List active Claude sessions (legacy format)
    --list-sessions-by-project     List sessions organized by project
    --stop-session                 Stop session for current project
    --stop-project-session         Stop session for current project (alias)
    --cleanup-sessions             Clean up inactive/orphaned sessions
    --switch-project PATH          Switch context to different project directory
    --show-session-id              Display current session ID
    --system-status                Show system status and diagnostics

SETUP OPTIONS:
    --setup-wizard           Force run setup wizard even if session detected
    --skip-wizard           Skip automatic wizard trigger

CLAUDE_ARGS:
    Any arguments to pass to the Claude CLI (e.g., "continue", --model opus)
    If no arguments provided, defaults to "continue"

EXAMPLES:
    # Start continuous monitoring with default settings
    $SCRIPT_NAME --continuous

    # Monitor with new terminal windows every 3 minutes
    $SCRIPT_NAME --continuous --check-interval 3 --new-terminal

    # Single run with specific Claude arguments
    $SCRIPT_NAME "implement a new feature" --model claude-3-opus-20240229

    # Test mode with 30-second simulated usage limit
    $SCRIPT_NAME --continuous --test-mode 30 --debug

    # Dry run to preview actions
    $SCRIPT_NAME --continuous --dry-run --debug

    # Queue mode examples
    $SCRIPT_NAME --add-custom "Implement user authentication feature"
    $SCRIPT_NAME --add-issue 123
    $SCRIPT_NAME --queue-mode --continuous

CONFIGURATION:
    Configuration is loaded from $CONFIG_FILE by default.
    Use --config to specify an alternative configuration file.

DEPENDENCIES:
    - Claude CLI (required)
    - claunch (optional but recommended)
    - tmux (required if using claunch in tmux mode)

For more information, see README.md or visit the project repository.
EOF
}

# Zeige Versionsinformation
show_version() {
    echo "$SCRIPT_NAME version $VERSION"
    echo ""
    echo "Dependencies:"
    
    if command -v claude >/dev/null 2>&1; then
        echo "  Claude CLI: $(claude --version 2>/dev/null | head -1 || echo "installed")"
    else
        echo "  Claude CLI: not found"
    fi
    
    if command -v claunch >/dev/null 2>&1; then
        echo "  claunch: $(claunch --version 2>/dev/null | head -1 || echo "installed")"
    else
        echo "  claunch: not found"
    fi
    
    if command -v tmux >/dev/null 2>&1; then
        echo "  tmux: $(tmux -V 2>/dev/null || echo "installed")"
    else
        echo "  tmux: not found"
    fi
}

# Parse Kommandozeilen-Argumente
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --continuous)
                CONTINUOUS_MODE=true
                shift
                ;;
            --check-interval)
                if [[ -z "${2:-}" ]] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
                    log_error "Option $1 requires a valid number of minutes"
                    exit 1
                fi
                CHECK_INTERVAL_MINUTES="$2"
                shift 2
                ;;
            --max-cycles)
                if [[ -z "${2:-}" ]] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
                    log_error "Option $1 requires a valid number"
                    exit 1
                fi
                MAX_RESTARTS="$2"
                shift 2
                ;;
            --new-terminal)
                USE_NEW_TERMINAL=true
                shift
                ;;
            --config)
                if [[ -z "${2:-}" ]]; then
                    log_error "Option $1 requires a configuration file path"
                    exit 1
                fi
                SPECIFIED_CONFIG="$2"
                shift 2
                ;;
            --test-mode)
                if [[ -z "${2:-}" ]] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
                    log_error "Option $1 requires a valid number of seconds"
                    exit 1
                fi
                TEST_MODE=true
                TEST_WAIT_SECONDS="$2"
                shift 2
                ;;
            --debug)
                DEBUG_MODE=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --queue-mode)
                QUEUE_MODE=true
                shift
                ;;
            --add-issue)
                if [[ -z "${2:-}" ]]; then
                    log_error "Option $1 requires an issue number or URL"
                    exit 1
                fi
                # Validate that issue number is numeric
                if [[ ! "$2" =~ ^[0-9]+$ ]]; then
                    log_error "Error: Invalid issue number '$2'. Issue numbers must be numeric."
                    exit 1
                fi
                ADD_ISSUE="$2"
                shift 2
                ;;
            --add-pr)
                if [[ -z "${2:-}" ]]; then
                    log_error "Option $1 requires a PR number or URL"
                    exit 1
                fi
                # Validate that PR number is numeric
                if [[ ! "$2" =~ ^[0-9]+$ ]]; then
                    log_error "Error: Invalid PR number '$2'. PR numbers must be numeric."
                    exit 1
                fi
                ADD_PR="$2"
                shift 2
                ;;
            --add-custom)
                if [[ -z "${2:-}" ]]; then
                    log_error "Error: --add-custom requires a task description"
                    exit 1
                fi
                ADD_CUSTOM="$2"
                shift 2
                ;;
            --list-queue)
                LIST_QUEUE=true
                shift
                ;;
            --pause-queue)
                PAUSE_QUEUE=true
                shift
                ;;
            --resume-queue)
                RESUME_QUEUE=true
                shift
                ;;
            --clear-queue)
                CLEAR_QUEUE=true
                shift
                ;;
            --list-sessions)
                LIST_SESSIONS=true
                shift
                ;;
            --list-sessions-by-project)
                LIST_SESSIONS_BY_PROJECT=true
                shift
                ;;
            --stop-session)
                STOP_SESSION=true
                shift
                ;;
            --stop-project-session)
                STOP_PROJECT_SESSION=true
                shift
                ;;
            --cleanup-sessions)
                CLEANUP_SESSIONS=true
                shift
                ;;
            --switch-project)
                if [[ -z "${2:-}" ]]; then
                    log_error "Option $1 requires a project path"
                    exit 1
                fi
                SWITCH_PROJECT="$2"
                shift 2
                ;;
            --show-session-id)
                SHOW_SESSION_ID=true
                shift
                ;;
            --system-status)
                SYSTEM_STATUS=true
                shift
                ;;
            --setup-wizard)
                FORCE_WIZARD=true
                shift
                ;;
            --skip-wizard)
                SKIP_WIZARD=true
                shift
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
                # Unbekannte Option - zu Claude-Args hinzufügen
                CLAUDE_ARGS+=("$1")
                shift
                ;;
            *)
                # Argument ohne führenden Bindestrich - zu Claude-Args hinzufügen
                CLAUDE_ARGS+=("$1")
                shift
                ;;
        esac
    done
    
    # Standard-Argumente falls keine spezifiziert
    if [[ ${#CLAUDE_ARGS[@]} -eq 0 ]]; then
        CLAUDE_ARGS=("continue")
    fi
    
    log_debug "Parsed arguments:"
    log_debug "  CONTINUOUS_MODE=$CONTINUOUS_MODE"
    log_debug "  USE_NEW_TERMINAL=$USE_NEW_TERMINAL"
    log_debug "  CHECK_INTERVAL_MINUTES=$CHECK_INTERVAL_MINUTES"
    log_debug "  CLAUDE_ARGS=(${CLAUDE_ARGS[*]})"
    log_debug "  TEST_MODE=$TEST_MODE"
    log_debug "  DEBUG_MODE=$DEBUG_MODE"
    log_debug "  DRY_RUN=$DRY_RUN"
}

# ===============================================================================
# MAIN ENTRY POINT
# ===============================================================================

main() {
    log_info "Hybrid Claude Monitor v$VERSION starting up"
    log_debug "Script directory: $SCRIPT_DIR"
    log_debug "Working directory: $WORKING_DIR"
    
    # Parse Kommandozeilen-Argumente
    parse_arguments "$@"
    
    # Lade Dependencies (muss vor load_configuration aufgerufen werden)
    load_dependencies
    
    # Lade Konfiguration
    load_configuration
    
    # Handle Session Management Operations (these work even if task queue is unavailable)
    # Enhanced Session Management Operations Check (Issue #89)
    if [[ "$LIST_SESSIONS" == "true" || "$LIST_SESSIONS_BY_PROJECT" == "true" || "$STOP_SESSION" == "true" || "$STOP_PROJECT_SESSION" == "true" || "$CLEANUP_SESSIONS" == "true" || -n "$SWITCH_PROJECT" || "$SHOW_SESSION_ID" == "true" || "$SYSTEM_STATUS" == "true" ]]; then
        handle_session_management_operations
        # Exit after session operations unless in continuous mode
        if [[ "$CONTINUOUS_MODE" != "true" && "$QUEUE_MODE" != "true" ]]; then
            log_info "Per-project session management operations completed"
            exit 0
        fi
    fi
    
    # Lade Task Queue Konfiguration
    load_task_queue_config
    
    # Handle Task Queue Operations (falls CLI-Parameter gesetzt)
    if [[ "$ADD_ISSUE" != "" || "$ADD_PR" != "" || "$ADD_CUSTOM" != "" || "$LIST_QUEUE" == "true" || "$PAUSE_QUEUE" == "true" || "$RESUME_QUEUE" == "true" || "$CLEAR_QUEUE" == "true" ]]; then
        handle_task_queue_operations
        # Exit nach Queue-Operationen falls nicht in continuous mode
        if [[ "$CONTINUOUS_MODE" != "true" && "$QUEUE_MODE" != "true" ]]; then
            log_info "Queue operations completed"
            exit 0
        fi
    fi
    
    # Initialisiere Logging mit vollständiger Konfiguration
    if declare -f init_logging >/dev/null 2>&1; then
        init_logging "${SPECIFIED_CONFIG:-$CONFIG_FILE}"
    fi
    
    # Initialisiere andere Module
    if declare -f init_terminal_utils >/dev/null 2>&1; then
        init_terminal_utils "${SPECIFIED_CONFIG:-$CONFIG_FILE}"
    fi
    
    # Enhanced claunch integration initialization with fallback support (addresses GitHub issue #77)
    if declare -f init_claunch_integration >/dev/null 2>&1; then
        log_debug "Initializing claunch integration with fallback detection..."
        
        if ! init_claunch_integration "${SPECIFIED_CONFIG:-$CONFIG_FILE}" "$WORKING_DIR"; then
            log_warn "claunch integration initialization failed"
            log_info "Continuing with direct Claude CLI mode"
            
            # Ensure USE_CLAUNCH is properly set to false for fallback mode
            USE_CLAUNCH="false"
        else
            log_debug "claunch integration initialized successfully"
        fi
    else
        log_warn "claunch integration module not available"
        if [[ "$USE_CLAUNCH" == "true" ]]; then
            log_info "Falling back to direct Claude CLI mode"
            USE_CLAUNCH="false"
        fi
    fi
    
    if declare -f init_session_manager >/dev/null 2>&1; then
        init_session_manager "${SPECIFIED_CONFIG:-$CONFIG_FILE}"
    fi
    
    # Validiere Systemvoraussetzungen
    if ! validate_system_requirements; then
        log_error "System requirements not met - exiting"
        exit 1
    fi
    
    # Setup Wizard Integration - prüfe ob Wizard ausgeführt werden soll
    if [[ "$FORCE_WIZARD" == "true" ]] || [[ "$CONTINUOUS_MODE" == "true" && "$SKIP_WIZARD" != "true" ]]; then
        log_debug "Checking if setup wizard should be triggered"
        
        # Lade Setup Wizard Modul falls verfügbar
        if [[ -f "$SCRIPT_DIR/setup-wizard.sh" ]]; then
            if ! source "$SCRIPT_DIR/setup-wizard.sh"; then
                log_error "Failed to load setup wizard module"
                if [[ "$FORCE_WIZARD" == "true" ]]; then
                    exit 1
                fi
            fi
        else
            log_error "Setup wizard module not found at: $SCRIPT_DIR/setup-wizard.sh"
            if [[ "$FORCE_WIZARD" == "true" ]]; then
                exit 1
            fi
        fi
        
        # Entscheide ob Wizard ausgeführt werden soll
        local should_run_wizard=false
        
        if [[ "$FORCE_WIZARD" == "true" ]]; then
            log_info "Forcing setup wizard execution as requested"
            should_run_wizard=true
        elif declare -f detect_existing_claude_session >/dev/null 2>&1; then
            if ! detect_existing_claude_session; then
                log_info "No existing Claude session detected - starting setup wizard"
                should_run_wizard=true
            else
                log_info "Existing Claude session detected - skipping wizard"
            fi
        else
            log_warn "Session detection not available - skipping wizard"
        fi
        
        # Führe Setup Wizard aus falls erforderlich
        if [[ "$should_run_wizard" == "true" ]]; then
            if declare -f setup_wizard_main >/dev/null 2>&1; then
                log_info "Starting Setup Wizard"
                
                if setup_wizard_main; then
                    log_info "Setup wizard completed successfully"
                    
                    # Nach erfolgreichem Setup, setze Wizard-flags zurück
                    FORCE_WIZARD=false
                else
                    log_error "Setup wizard failed"
                    exit 1
                fi
            else
                log_error "Setup wizard function not available"
                if [[ "$FORCE_WIZARD" == "true" ]]; then
                    exit 1
                fi
            fi
        fi
    fi
    
    # Hauptfunktionalität ausführen
    if [[ "$CONTINUOUS_MODE" == "true" ]]; then
        continuous_monitoring_loop
    else
        log_info "Running in single-execution mode"
        
        # Einmaliger Usage-Limit-Check
        case $(check_usage_limits; echo $?) in
            0|1) ;; # OK oder behandelt
            2) log_error "Usage limit check failed"; exit 3 ;;
        esac
        
        # Starte Claude-Session
        start_or_continue_claude_session
    fi
    
    log_info "Hybrid monitor completed successfully"
}

# Führe main nur aus wenn Skript direkt aufgerufen wird
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi