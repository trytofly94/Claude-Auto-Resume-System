#!/usr/bin/env bash

# Claude Auto-Resume - Hybrid Monitor
# Haupt-Monitoring-System für das claunch-basierte Claude Auto-Resume System
# Version: 1.0.0-alpha
# Letzte Aktualisierung: 2025-08-05

set -euo pipefail

# ===============================================================================
# BASH VERSION VALIDATION (ADDRESSES GITHUB ISSUE #6)
# ===============================================================================

# Script-Informationen
readonly SCRIPT_NAME="hybrid-monitor"
readonly VERSION="1.0.0-alpha"
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

# Session ID Management-spezifische Variablen
SHOW_SESSION_ID=false
COPY_SESSION_ID=false
COPY_SESSION_TARGET=""
SHOW_FULL_SESSION_ID=false
LIST_SESSIONS_MODE=false
RESUME_SESSION_ID=""

# Task Queue-spezifische Variablen
QUEUE_MODE=false
QUEUE_ACTION=""
QUEUE_ITEM=""
TASK_QUEUE_ENABLED="${TASK_QUEUE_ENABLED:-false}"
TASK_DEFAULT_TIMEOUT="${TASK_DEFAULT_TIMEOUT:-3600}"
TASK_MAX_RETRIES="${TASK_MAX_RETRIES:-3}"
TASK_DEFAULT_PRIORITY="${TASK_DEFAULT_PRIORITY:-5}"
ADD_ISSUE=""
ADD_PR=""
ADD_CUSTOM=""
LIST_QUEUE=false
PAUSE_QUEUE=false
RESUME_QUEUE=false
CLEAR_QUEUE=false

# ===============================================================================
# UTILITY-FUNKTIONEN (früh definiert für Validierung)
# ===============================================================================

# Prüfe ob Kommando verfügbar ist
has_command() {
    command -v "$1" >/dev/null 2>&1
}

# Validiere numerische Parameter mit optionalen Bereichen
validate_number_parameter() {
    local option_name="$1"
    local value="$2"
    local min_value="${3:-}"
    local max_value="${4:-}"
    
    if [[ -z "$value" ]]; then
        log_error "Option $option_name requires a numeric value"
        exit 1
    fi
    
    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        log_error "Option $option_name requires a valid number, got: $value"
        exit 1
    fi
    
    if [[ -n "$min_value" && "$value" -lt "$min_value" ]]; then
        log_error "Option $option_name value must be >= $min_value, got: $value"
        exit 1
    fi
    
    if [[ -n "$max_value" && "$value" -gt "$max_value" ]]; then
        log_error "Option $option_name value must be <= $max_value, got: $value"
        exit 1
    fi
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
    
    # Lade Utility-Module
    local modules=(
        "utils/logging.sh"
        "utils/network.sh" 
        "utils/terminal.sh"
        "utils/session-display.sh"
        "utils/clipboard.sh"
    )
    
    # Lade Core-Module (vom src Verzeichnis)
    local core_modules=(
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
    
    # Change to script directory to ensure correct relative paths during sourcing
    local original_dir="$(pwd)"
    cd "$SCRIPT_DIR"
    
    # Load utility modules
    for module in "${modules[@]}"; do
        local module_path="$module"
        log_debug "Attempting to load module: $module from path: $SCRIPT_DIR/$module_path"
        if [[ -f "$module_path" ]]; then
            # shellcheck source=/dev/null
            source "$module_path"
            log_debug "Loaded module: $module"
        else
            log_warn "Module not found: $SCRIPT_DIR/$module_path"
        fi
    done
    
    # Load core modules
    for module in "${core_modules[@]}"; do
        local module_path="$module"
        log_debug "Attempting to load core module: $module from path: $SCRIPT_DIR/$module_path"
        if [[ -f "$module_path" ]]; then
            # shellcheck source=/dev/null
            source "$module_path"
            log_debug "Loaded core module: $module"
        else
            log_warn "Core module not found: $SCRIPT_DIR/$module_path"
        fi
    done
    
    # Restore original directory
    cd "$original_dir"
    
    # Task Queue Integration - Load only if enabled
    if [[ "${TASK_QUEUE_ENABLED:-false}" == "true" ]]; then
        log_info "Task Queue processing enabled - loading integration modules"
        
        # Task Queue Core Module is already checked above and accessible via TASK_QUEUE_SCRIPT
        if [[ "${TASK_QUEUE_AVAILABLE:-false}" != "true" ]]; then
            log_error "Task Queue module not available but processing is enabled"
            log_error "Please ensure task-queue.sh is executable and functional"
            exit 1
        fi
        
        log_debug "Task Queue Core Module is available at: $TASK_QUEUE_SCRIPT"
        
        # Load GitHub Integration Modules (conditional - non-fatal if missing)
        local github_modules=(
            "github-integration.sh"
            "github-integration-comments.sh" 
            "github-task-integration.sh"
        )
        
        for module in "${github_modules[@]}"; do
            local github_module="$SCRIPT_DIR/$module"
            if [[ -f "$github_module" ]]; then
                # shellcheck source=/dev/null
                source "$github_module"
                log_debug "GitHub integration module loaded: $module"
            else
                log_warn "Optional GitHub module not found: $module"
                log_warn "GitHub integration features may be limited"
            fi
        done
        
        # Initialize Task Queue System
        if declare -f init_task_queue >/dev/null 2>&1; then
            log_debug "Initializing Task Queue system"
            if init_task_queue; then
                log_info "Task Queue system initialized successfully"
            else
                log_error "Failed to initialize Task Queue system"
                exit 1
            fi
        else
            log_error "Task Queue initialization function not available"
            exit 1
        fi
        
        # Initialize GitHub Integration (if available and enabled)
        if [[ "${GITHUB_INTEGRATION_ENABLED:-false}" == "true" ]] && declare -f init_github_integration >/dev/null 2>&1; then
            log_debug "Initializing GitHub integration"
            if init_github_integration; then
                log_info "GitHub integration initialized successfully"
            else
                log_warn "GitHub integration initialization failed - continuing without GitHub features"
            fi
        fi
        
        log_info "Task execution engine modules loaded successfully"
    fi
}


# ===============================================================================
# KONFIGURATION UND VALIDIERUNG
# ===============================================================================

# Lade Konfiguration
load_configuration() {
    local config_path="${SPECIFIED_CONFIG:-$CONFIG_FILE}"
    
    if [[ ! -f "$config_path" ]]; then
        config_path="$SCRIPT_DIR/../$CONFIG_FILE"
    fi
    
    if [[ -f "$config_path" ]]; then
        log_info "Loading configuration from: $config_path"
        
        while IFS='=' read -r key value; do
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$key" ]] && continue
            
            value=$(echo "$value" | sed 's/^["'\'']\|["'\'']$//g')
            
            # Setze bekannte Konfigurationsvariablen
            case "$key" in
                CHECK_INTERVAL_MINUTES|MAX_RESTARTS|USE_CLAUNCH|NEW_TERMINAL_DEFAULT|DEBUG_MODE|DRY_RUN|CLAUNCH_MODE|TMUX_SESSION_PREFIX|USAGE_LIMIT_COOLDOWN|BACKOFF_FACTOR|MAX_WAIT_TIME|LOG_LEVEL|HEALTH_CHECK_ENABLED|AUTO_RECOVERY_ENABLED|TASK_QUEUE_ENABLED|TASK_DEFAULT_TIMEOUT|TASK_MAX_RETRIES|TASK_RETRY_DELAY|TASK_COMPLETION_PATTERN|QUEUE_PROCESSING_DELAY|QUEUE_MAX_CONCURRENT|QUEUE_AUTO_PAUSE_ON_ERROR)
                    eval "$key='$value'"
                    log_debug "Config: $key=$value"
                    ;;
                # Task Queue Configuration Parameters
                TASK_QUEUE_ENABLED|TASK_DEFAULT_TIMEOUT|TASK_MAX_RETRIES|TASK_RETRY_DELAY|TASK_COMPLETION_PATTERN|QUEUE_PROCESSING_DELAY|QUEUE_MAX_CONCURRENT|QUEUE_AUTO_PAUSE_ON_ERROR|QUEUE_SESSION_CLEAR_BETWEEN_TASKS)
                    eval "$key='$value'"
                    log_debug "Config: $key=$value"
                    ;;
                # GitHub Integration Configuration Parameters  
                GITHUB_INTEGRATION_ENABLED|GITHUB_AUTO_COMMENT|GITHUB_STATUS_UPDATES|GITHUB_COMPLETION_NOTIFICATIONS|GITHUB_API_TIMEOUT|GITHUB_RETRY_ATTEMPTS)
                    eval "$key='$value'"
                    log_debug "Config: $key=$value"
                    ;;
            esac
        done < <(grep -E '^[^#]*=' "$config_path" || true)
    else
        log_warn "Configuration file not found: $config_path (using defaults)"
    fi
}

# Lade Task Queue Konfiguration und bestimme Processing-Modus
load_task_queue_config() {
    log_debug "Loading task queue configuration"
    
    # Task Queue Processing aktivieren wenn:
    # 1. TASK_QUEUE_ENABLED=true in config, oder 
    # 2. --queue-mode CLI parameter verwendet wird
    if [[ "${TASK_QUEUE_ENABLED:-false}" == "true" || "${QUEUE_MODE:-false}" == "true" ]]; then
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
    
    # claunch prüfen (falls aktiviert)
    if [[ "$USE_CLAUNCH" == "true" ]]; then
        if ! has_command claunch && ! detect_claunch >/dev/null 2>&1; then
            log_error "claunch not found but USE_CLAUNCH=true"
            log_error "Please install claunch: npm install -g @0xkaz/claunch"
            ((errors++))
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
    
    # Task Queue Dependencies (wenn aktiviert)
    if [[ "$TASK_QUEUE_ENABLED" == "true" ]]; then
        log_debug "Validating Task Queue system dependencies"
        
        # jq für JSON-Verarbeitung
        if ! has_command jq; then
            log_error "jq not found but Task Queue is enabled"
            log_error "Please install jq: brew install jq (macOS) or apt install jq (Ubuntu)"
            ((errors++))
        fi
        
        # GitHub CLI für GitHub Integration (optional aber empfohlen)
        if [[ "${GITHUB_INTEGRATION_ENABLED:-false}" == "true" ]]; then
            if ! has_command gh; then
                log_warn "GitHub CLI not found but GitHub integration is enabled"
                log_warn "Please install GitHub CLI for full GitHub integration: https://cli.github.com/"
                log_warn "GitHub features will be limited or disabled"
            fi
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
        local task_id="custom-$(date +%s)"
        if "${TASK_QUEUE_SCRIPT}" add custom "$task_id" "$ADD_CUSTOM"; then
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
    
    # Placeholder für Phase 2 - aktuell nur logging
    # TODO: Implement execute_single_task function in Phase 2
    log_info "Task processing will be implemented in Phase 2: $next_task_id"
    
    return 0
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
        resume_timestamp=$(date -d "+${TEST_WAIT_SECONDS} seconds" +%s 2>/dev/null || date -v+"${TEST_WAIT_SECONDS}"S +%s 2>/dev/null || echo $(($(date +%s) + TEST_WAIT_SECONDS)))
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
    
    if [[ "$USE_CLAUNCH" == "true" ]]; then
        log_info "Starting Claude via claunch integration"
        
        if MAIN_SESSION_ID=$(start_managed_session "$project_name" "$WORKING_DIR" "$USE_NEW_TERMINAL" "${CLAUDE_ARGS[@]}"); then
            log_info "Claude session started successfully (ID: $MAIN_SESSION_ID)"
            
            # Initialize session for task processing if task queue is enabled
            if [[ "${TASK_QUEUE_ENABLED:-false}" == "true" ]]; then
                log_debug "Preparing session for task queue processing"
                
                # Brief pause to let session stabilize
                sleep 3
                
                # Verify session is responsive
                if declare -f verify_session_responsiveness >/dev/null 2>&1; then
                    if ! verify_session_responsiveness "$MAIN_SESSION_ID"; then
                        log_warn "Session not responsive after startup, attempting recovery"
                        if declare -f recover_session >/dev/null 2>&1; then
                            if ! recover_session "$MAIN_SESSION_ID"; then
                                log_error "Session recovery failed"
                                return 1
                            fi
                        else
                            log_warn "Session recovery function not available"
                        fi
                    fi
                fi
                
                # Initialize session for task processing
                initialize_session_for_tasks "$MAIN_SESSION_ID"
            fi
            
            return 0
        else
            log_error "Failed to start Claude session via claunch"
            return 1
        fi
    else
        log_info "Starting Claude in legacy mode"
        
        if [[ "$USE_NEW_TERMINAL" == "true" ]]; then
            # Starte in neuem Terminal
            open_claude_in_terminal "${CLAUDE_ARGS[@]}"
        else
            # Direkte Ausführung
            # Direct execution without bypass flags for security
            claude "${CLAUDE_ARGS[@]}"
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
        return 1
    fi
}

# ===============================================================================
# HAUPT-MONITORING-SCHLEIFE
# ===============================================================================

# Kontinuierliches Monitoring
continuous_monitoring_loop() {
    log_info "Starting enhanced continuous monitoring mode"
    log_info "Configuration:"
    log_info "  Check interval: $CHECK_INTERVAL_MINUTES minutes"
    log_info "  Max cycles: $MAX_RESTARTS"
    log_info "  Working directory: $WORKING_DIR"
    log_info "  Use claunch: $USE_CLAUNCH"
    log_info "  Use new terminal: $USE_NEW_TERMINAL"
    log_info "  Task queue processing: ${TASK_QUEUE_PROCESSING:-false}"
    
    # Task Queue Configuration Display
    if [[ "${TASK_QUEUE_ENABLED:-false}" == "true" ]]; then
        log_info "Task Queue Configuration:"
        log_info "  Task queue enabled: true"
        log_info "  Default timeout: ${TASK_DEFAULT_TIMEOUT:-3600}s"
        log_info "  Max retries: ${TASK_MAX_RETRIES:-3}"
        log_info "  Queue processing delay: ${QUEUE_PROCESSING_DELAY:-30}s"
        log_info "  Completion pattern: ${TASK_COMPLETION_PATTERN:-###TASK_COMPLETE###}"
        log_info "  GitHub integration: ${GITHUB_INTEGRATION_ENABLED:-false}"
    else
        log_info "  Task queue: disabled"
    fi
    
    if [[ "${#CLAUDE_ARGS[@]}" -gt 0 && "$QUEUE_MODE" == "false" ]]; then
        log_info "  Claude arguments: ${CLAUDE_ARGS[*]}"
    fi
    
    echo ""
    
    MONITORING_ACTIVE=true
    local check_interval_seconds=$((CHECK_INTERVAL_MINUTES * 60))
    
    while [[ "$MONITORING_ACTIVE" == "true" && $CURRENT_CYCLE -lt $MAX_RESTARTS ]]; do
        ((CURRENT_CYCLE++))
        
        log_info "=== Enhanced Monitoring Cycle $CURRENT_CYCLE/$MAX_RESTARTS ==="
        echo "$(date): Starting enhanced check cycle $CURRENT_CYCLE"
        
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
        
        # Schritt 3: Task Queue Processing (NEW)
        if [[ "${TASK_QUEUE_ENABLED:-false}" == "true" ]]; then
            log_debug "Step 3: Processing task queue"
            
            # Ensure session is ready for task processing if we have one
            if [[ -n "$MAIN_SESSION_ID" ]] && [[ "$USE_CLAUNCH" == "true" ]]; then
                # Verify session is responsive before processing tasks
                if declare -f verify_session_responsiveness >/dev/null 2>&1; then
                    if ! verify_session_responsiveness "$MAIN_SESSION_ID"; then
                        log_warn "Session not responsive for task processing, attempting recovery"
                        if ! start_or_continue_claude_session; then
                            log_error "Failed to establish session for task processing"
                            continue
                        fi
                    fi
                fi
                
                # Initialize session for tasks if needed
                if declare -f initialize_session_for_tasks >/dev/null 2>&1; then
                    initialize_session_for_tasks "$MAIN_SESSION_ID"
                fi
            fi
            
            # Process task queue
            process_task_queue_cycle
        else
            log_debug "Step 3: Task queue disabled - performing regular monitoring"
        fi
        
        # Schritt 4: Nächster Check
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
# COMMAND-LINE-INTERFACE
# ===============================================================================

# Zeige Hilfe
show_help() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS] [CLAUDE_ARGS...]

Hybrid monitoring system for Claude CLI sessions with claunch integration and task queue processing.

STANDARD OPTIONS:
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

SESSION ID MANAGEMENT:
    --show-session-id        Display current session ID
    --show-full-session-id   Display complete session ID (not shortened)  
    --copy-session-id [ID]   Copy session ID to clipboard (current or specific)
    --list-sessions          List all active sessions with copyable IDs
    --resume-session ID      Resume specific session by ID

TASK QUEUE OPTIONS:
    --queue-mode             Enable task queue processing mode
    
    Task Management:
    --add-issue NUMBER       Add GitHub issue to task queue
    --add-pr NUMBER          Add GitHub pull request to task queue  
    --add-custom "DESC"      Add custom task to queue with description
    --list-queue             Display current queue status and tasks
    --clear-queue            Remove all tasks from queue (with confirmation)
    
    Queue Control:
    --pause-queue            Pause task queue processing
    --resume-queue           Resume paused task queue processing
    --skip-current           Skip currently processing task
    --retry-current          Retry current failed task
    
    Queue Configuration:
    --queue-timeout SECONDS  Default task timeout (60-86400, default: $TASK_DEFAULT_TIMEOUT)
    --queue-retries COUNT    Max retry attempts per task (0-10, default: $TASK_MAX_RETRIES)
    --queue-priority NUM     Default priority for new tasks (1-10, default: $TASK_DEFAULT_PRIORITY)

CLAUDE_ARGS:
    Any arguments to pass to the Claude CLI (e.g., "continue", --model opus)
    If no arguments provided, defaults to "continue" (ignored in queue mode)

EXAMPLES:
    # Traditional monitoring mode
    $SCRIPT_NAME --continuous

    # Session ID management
    $SCRIPT_NAME --show-session-id
    $SCRIPT_NAME --copy-session-id
    $SCRIPT_NAME --list-sessions
    $SCRIPT_NAME --resume-session project-name-1672531200-12345

    # Task queue mode with continuous processing
    $SCRIPT_NAME --queue-mode --continuous

    # Add GitHub issue to queue and start processing
    $SCRIPT_NAME --add-issue 123 --queue-mode --continuous

    # Add custom task and configure timeout
    $SCRIPT_NAME --add-custom "Fix the login bug" --queue-timeout 7200 --queue-mode

    # Check queue status
    $SCRIPT_NAME --list-queue

    # Pause queue processing  
    $SCRIPT_NAME --pause-queue

    # Advanced: Custom task with priority and retries
    $SCRIPT_NAME --add-custom "Implement new feature" --queue-priority 8 --queue-retries 5

TASK QUEUE WORKFLOW:
    1. Add tasks: Use --add-issue, --add-pr, or --add-custom
    2. Start processing: Use --queue-mode --continuous
    3. Monitor progress: Task completion detected via pattern matching
    4. Review results: GitHub integration provides progress comments

    # Queue mode examples
    $SCRIPT_NAME --add-custom "Implement user authentication feature"
    $SCRIPT_NAME --add-issue 123
    $SCRIPT_NAME --queue-mode --continuous

CONFIGURATION:
    Configuration is loaded from $CONFIG_FILE by default.
    Use --config to specify an alternative configuration file.
    Task queue settings can be configured in the config file.

DEPENDENCIES:
    - Claude CLI (required)
    - claunch (optional but recommended)
    - tmux (required if using claunch in tmux mode)
    - jq (required for task queue functionality)
    - GitHub CLI (optional, for GitHub integration features)

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
                validate_number_parameter "$1" "${2:-}"
                CHECK_INTERVAL_MINUTES="$2"
                shift 2
                ;;
            --max-cycles)
                validate_number_parameter "$1" "${2:-}"
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
                validate_number_parameter "$1" "${2:-}"
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
            --show-session-id)
                SHOW_SESSION_ID=true
                shift
                ;;
            --show-full-session-id)
                SHOW_SESSION_ID=true
                SHOW_FULL_SESSION_ID=true
                shift
                ;;
            --copy-session-id)
                COPY_SESSION_ID=true
                if [[ -n "${2:-}" && ! "${2:-}" =~ ^-- ]]; then
                    COPY_SESSION_TARGET="$2"
                    shift 2
                else
                    COPY_SESSION_TARGET="current"
                    shift
                fi
                ;;
            --list-sessions)
                LIST_SESSIONS_MODE=true
                shift
                ;;
            --resume-session)
                if [[ -z "${2:-}" ]]; then
                    log_error "Option $1 requires a session ID"
                    exit 1
                fi
                RESUME_SESSION_ID="$2"
                shift 2
                ;;
            --version)
                show_version
                exit 0
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
                
            # ============ NEW: Task Queue Parameters ============
            
            # Queue Mode Activation
            --queue-mode)
                QUEUE_MODE=true
                TASK_QUEUE_ENABLED=true  # Auto-enable task queue
                shift
                ;;
            
            # Task Management
            --add-issue)
                validate_number_parameter "$1" "${2:-}"
                QUEUE_ACTION="add_issue"
                QUEUE_ITEM="$2"
                QUEUE_MODE=true
                TASK_QUEUE_ENABLED=true
                shift 2
                ;;
                
            --add-pr)
                validate_number_parameter "$1" "${2:-}"
                QUEUE_ACTION="add_pr" 
                QUEUE_ITEM="$2"
                QUEUE_MODE=true
                TASK_QUEUE_ENABLED=true
                shift 2
                ;;
                
            --add-custom)
                if [[ -z "${2:-}" ]]; then
                    log_error "Option $1 requires a task description"
                    exit 1
                fi
                QUEUE_ACTION="add_custom"
                QUEUE_ITEM="$2"
                QUEUE_MODE=true
                TASK_QUEUE_ENABLED=true
                shift 2
                ;;
                
            --list-queue)
                QUEUE_ACTION="list_queue"
                QUEUE_MODE=true
                TASK_QUEUE_ENABLED=true
                shift
                ;;
                
            --clear-queue)
                QUEUE_ACTION="clear_queue"
                QUEUE_MODE=true
                TASK_QUEUE_ENABLED=true
                shift
                ;;
                
            # Queue Control
            --pause-queue)
                QUEUE_ACTION="pause_queue"
                QUEUE_MODE=true
                TASK_QUEUE_ENABLED=true
                shift
                ;;
                
            --resume-queue)
                QUEUE_ACTION="resume_queue"
                QUEUE_MODE=true
                TASK_QUEUE_ENABLED=true
                shift
                ;;
                
            --skip-current)
                QUEUE_ACTION="skip_current"
                QUEUE_MODE=true
                TASK_QUEUE_ENABLED=true
                shift
                ;;
                
            --retry-current)
                QUEUE_ACTION="retry_current"
                QUEUE_MODE=true
                TASK_QUEUE_ENABLED=true
                shift
                ;;
                
            # Queue Configuration
            --queue-timeout)
                validate_number_parameter "$1" "${2:-}" 60 86400  # 1 minute to 24 hours
                TASK_DEFAULT_TIMEOUT="$2"
                shift 2
                ;;
                
            --queue-retries)
                validate_number_parameter "$1" "${2:-}" 0 10  # 0 to 10 retries
                TASK_MAX_RETRIES="$2"
                shift 2
                ;;
                
            --queue-priority)
                validate_number_parameter "$1" "${2:-}" 1 10  # Priority 1-10
                TASK_DEFAULT_PRIORITY="$2"
                shift 2
                ;;
                
            # ============ END: Task Queue Parameters ============
            
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
    if [[ ${#CLAUDE_ARGS[@]} -eq 0 && "$QUEUE_MODE" == "false" ]]; then
        CLAUDE_ARGS=("continue")
    fi
    
    # Export Task Queue variables for use in functions
    export QUEUE_MODE QUEUE_ACTION QUEUE_ITEM TASK_QUEUE_ENABLED TASK_DEFAULT_TIMEOUT TASK_MAX_RETRIES TASK_DEFAULT_PRIORITY
    
    log_debug "Parsed arguments:"
    log_debug "  CONTINUOUS_MODE=$CONTINUOUS_MODE"
    log_debug "  USE_NEW_TERMINAL=$USE_NEW_TERMINAL"
    log_debug "  CHECK_INTERVAL_MINUTES=$CHECK_INTERVAL_MINUTES"
    log_debug "  CLAUDE_ARGS=(${CLAUDE_ARGS[*]})"
    log_debug "  TEST_MODE=$TEST_MODE"
    log_debug "  DEBUG_MODE=$DEBUG_MODE"
    log_debug "  DRY_RUN=$DRY_RUN"
    log_debug "  QUEUE_MODE=$QUEUE_MODE"
    log_debug "  QUEUE_ACTION=$QUEUE_ACTION"
    log_debug "  TASK_QUEUE_ENABLED=$TASK_QUEUE_ENABLED"
}

# ===============================================================================
# TASK QUEUE PROCESSING ENGINE
# ===============================================================================

# Process task queue cycle (called from monitoring loop)
process_task_queue_cycle() {
    log_debug "Starting task queue processing cycle"
    
    # Check if queue processing is paused
    if declare -f is_queue_paused >/dev/null 2>&1 && is_queue_paused; then
        log_debug "Task queue processing is paused - skipping cycle"
        return 0
    fi
    
    # Get next task to process
    local next_task_id
    if ! next_task_id=$(get_next_task 2>/dev/null); then
        log_debug "No tasks available for processing (or error getting next task)"
        return 0
    fi
    
    if [[ -z "$next_task_id" ]]; then
        log_debug "Task queue is empty"
        return 0
    fi
    
    log_info "Processing task from queue: $next_task_id"
    
    # Execute single task with comprehensive error handling
    if execute_single_task "$next_task_id"; then
        log_info "✓ Task $next_task_id completed successfully"
        
        # Brief pause before continuing to next task
        local processing_delay="${QUEUE_PROCESSING_DELAY:-30}"
        log_debug "Task completed - waiting ${processing_delay}s before next cycle"
        sleep "$processing_delay"
    else
        log_warn "✗ Task $next_task_id failed or timed out"
        handle_task_failure "$next_task_id" "execution_failure"
        
        # Longer pause after failure
        local processing_delay="${QUEUE_PROCESSING_DELAY:-30}"
        local failure_delay=$((processing_delay * 2))
        log_debug "Task failed - waiting ${failure_delay}s before next cycle"
        sleep "$failure_delay"
    fi
    
    return 0
}

# Execute single task with full lifecycle management
execute_single_task() {
    local task_id="$1"
    
    if [[ -z "$task_id" ]]; then
        log_error "execute_single_task: Task ID is required"
        return 1
    fi
    
    log_info "Executing task: $task_id"
    
    # Get task details
    local task_data
    if ! task_data=$(get_task_details "$task_id" 2>/dev/null); then
        log_error "Failed to retrieve task details for: $task_id"
        return 1
    fi
    
    if [[ -z "$task_data" ]]; then
        log_error "Task data is empty for task: $task_id"
        return 1
    fi
    
    # Parse task information using jq
    local task_type task_command task_timeout task_description
    
    if ! task_type=$(echo "$task_data" | jq -r '.type // "unknown"' 2>/dev/null); then
        log_error "Failed to parse task type from task data"
        return 1
    fi
    
    if ! task_command=$(echo "$task_data" | jq -r '.command // ""' 2>/dev/null); then
        log_error "Failed to parse task command from task data" 
        return 1
    fi
    
    if ! task_timeout=$(echo "$task_data" | jq -r '.timeout // 3600' 2>/dev/null); then
        log_warn "Failed to parse task timeout, using default"
        task_timeout="${TASK_DEFAULT_TIMEOUT:-3600}"
    fi
    
    if ! task_description=$(echo "$task_data" | jq -r '.description // ""' 2>/dev/null); then
        log_debug "No task description available"
        task_description="Task $task_id"
    fi
    
    log_info "Task details: type=$task_type, timeout=${task_timeout}s"
    log_info "Task command: $task_command"
    
    # Validate task command
    if [[ -z "$task_command" ]]; then
        log_error "Task command is empty for task: $task_id"
        return 1
    fi
    
    # Update task status to in_progress
    if ! update_task_status "$task_id" "in_progress"; then
        log_error "Failed to update task status to in_progress"
        return 1
    fi
    
    # Post GitHub start notification if applicable
    if [[ "$task_type" =~ ^github_ ]]; then
        if declare -f post_task_start_notification >/dev/null 2>&1; then
            post_task_start_notification "$task_id" "$task_description"
        fi
    fi
    
    # Execute task with timeout and completion detection
    local execution_result=0
    if execute_task_with_monitoring "$task_id" "$task_command" "$task_timeout"; then
        log_info "✓ Task execution completed successfully"
        
        # Update task status to completed
        if ! update_task_status "$task_id" "completed"; then
            log_warn "Failed to update task status to completed"
        fi
        
        # Post GitHub completion notification
        if [[ "$task_type" =~ ^github_ ]]; then
            if declare -f post_task_completion_notification >/dev/null 2>&1; then
                post_task_completion_notification "$task_id" "success" "Task completed successfully"
            fi
        fi
        
        execution_result=0
    else
        log_warn "✗ Task execution failed or timed out"
        
        # Update task status to failed (will be handled by failure handler)
        if ! update_task_status "$task_id" "failed"; then
            log_warn "Failed to update task status to failed"
        fi
        
        # Post GitHub failure notification
        if [[ "$task_type" =~ ^github_ ]]; then
            if declare -f post_task_completion_notification >/dev/null 2>&1; then
                post_task_completion_notification "$task_id" "failure" "Task execution failed or timed out"
            fi
        fi
        
        execution_result=1
    fi
    
    return $execution_result
}

# Execute task with monitoring and completion detection
execute_task_with_monitoring() {
    local task_id="$1"
    local task_command="$2"
    local timeout="${3:-3600}"
    
    if [[ -z "$task_id" || -z "$task_command" ]]; then
        log_error "execute_task_with_monitoring: Task ID and command are required"
        return 1
    fi
    
    log_info "Starting task execution with ${timeout}s timeout"
    
    # Ensure we have an active session
    if [[ -z "$MAIN_SESSION_ID" ]]; then
        log_error "No active Claude session available for task execution"
        return 1
    fi
    
    # Clear session before starting new task (if configured)
    if [[ "${QUEUE_SESSION_CLEAR_BETWEEN_TASKS:-true}" == "true" ]]; then
        log_debug "Clearing session before task execution"
        
        if declare -f send_command_to_session >/dev/null 2>&1; then
            if ! send_command_to_session "/clear"; then
                log_warn "Failed to clear session, continuing anyway"
            else
                log_debug "Session cleared successfully"
                sleep 2  # Brief pause for clear to complete
            fi
        else
            log_debug "send_command_to_session function not available"
        fi
    fi
    
    # Send task command to Claude session
    log_info "Sending task command to Claude session"
    log_debug "Command: $task_command"
    
    if declare -f send_command_to_session >/dev/null 2>&1; then
        if ! send_command_to_session "$task_command"; then
            log_error "Failed to send command to Claude session"
            return 1
        fi
    else
        log_error "send_command_to_session function not available"
        return 1
    fi
    
    log_info "Command sent successfully, monitoring for completion..."
    
    # Monitor for completion with timeout
    if monitor_task_completion "$MAIN_SESSION_ID" "$timeout" "$task_id"; then
        log_info "✓ Task completed successfully within timeout"
        return 0
    else
        log_warn "✗ Task timed out or failed completion detection"
        return 1
    fi
}

# Monitor task completion using pattern detection
monitor_task_completion() {
    local session_id="$1"
    local timeout="$2"
    local task_id="${3:-unknown}"
    
    if [[ -z "$session_id" || -z "$timeout" ]]; then
        log_error "monitor_task_completion: Session ID and timeout are required"
        return 1
    fi
    
    local start_time completion_pattern check_interval
    start_time=$(date +%s)
    completion_pattern="${TASK_COMPLETION_PATTERN:-###TASK_COMPLETE###}"
    check_interval=10  # Check every 10 seconds
    
    log_debug "Monitoring task completion for session: $session_id"
    log_debug "Timeout: ${timeout}s, Pattern: $completion_pattern"
    log_info "Task execution started - monitoring for completion pattern..."
    
    while true; do
        local current_time elapsed_time
        current_time=$(date +%s)
        elapsed_time=$((current_time - start_time))
        
        # Check for timeout
        if [[ $elapsed_time -gt $timeout ]]; then
            log_warn "Task timeout reached after ${elapsed_time}s (limit: ${timeout}s)"
            return 1
        fi
        
        # Show progress every minute
        if [[ $((elapsed_time % 60)) -eq 0 && $elapsed_time -gt 0 ]]; then
            local remaining_time=$((timeout - elapsed_time))
            log_info "Task running for ${elapsed_time}s, ${remaining_time}s remaining..."
        fi
        
        # Capture current session output
        local session_output=""
        if declare -f capture_recent_session_output >/dev/null 2>&1; then
            if session_output=$(capture_recent_session_output "$session_id" 2>/dev/null); then
                log_debug "Captured ${#session_output} characters of session output"
                
                # Check for completion pattern
                if echo "$session_output" | grep -q "$completion_pattern"; then
                    log_info "✓ Completion pattern detected after ${elapsed_time}s"
                    log_debug "Task completion confirmed via pattern: $completion_pattern"
                    return 0
                fi
                
                # Check for common error patterns (but don't fail immediately)
                if echo "$session_output" | grep -qE "(Error:|Failed:|Exception:|CRITICAL:|ERROR:)"; then
                    log_debug "Error pattern detected in session output, but continuing monitoring"
                    # Don't immediately fail - let it timeout naturally in case it recovers
                fi
                
                # Check for usage limit patterns
                if echo "$session_output" | grep -qE "(usage limit reached|Usage limit|rate limit)"; then
                    log_warn "Usage limit detected during task execution"
                    # Let the normal usage limit handling in the monitoring loop handle this
                fi
            else
                log_debug "Could not capture session output, continuing monitoring"
            fi
        else
            log_debug "capture_recent_session_output function not available"
        fi
        
        # Update task progress in GitHub if available (every 5 minutes)
        if [[ $((elapsed_time % 300)) -eq 0 && $elapsed_time -gt 0 ]]; then
            if declare -f update_task_progress >/dev/null 2>&1; then
                local progress_percent
                progress_percent=$(( (elapsed_time * 100) / timeout ))
                
                # Cap progress at 95% since we're not actually done
                if [[ $progress_percent -gt 95 ]]; then
                    progress_percent=95
                fi
                
                local progress_message="Task execution in progress (${elapsed_time}s elapsed)..."
                update_task_progress "$task_id" "$progress_percent" "$progress_message" 2>/dev/null || true
                log_debug "Updated task progress: ${progress_percent}%"
            fi
        fi
        
        # Brief pause before next check
        sleep "$check_interval"
    done
}

# Initialize Claude session for task queue processing
initialize_session_for_tasks() {
    local session_id="$1"
    
    if [[ -z "$session_id" ]]; then
        log_error "initialize_session_for_tasks: Session ID is required"
        return 1
    fi
    
    log_debug "Initializing session $session_id for task processing"
    
    # Check if send_command_to_session function is available
    if ! declare -f send_command_to_session >/dev/null 2>&1; then
        log_warn "send_command_to_session function not available - skipping session initialization"
        return 0
    fi
    
    # Send initialization commands to prepare Claude for task processing
    local init_commands=(
        "I'm ready to work with the Claude Auto-Resume task queue system."
        "I understand that I should complete each task thoroughly and end my response with: ###TASK_COMPLETE###"
        "I'll process tasks individually and wait for the next task after completion."
        "Please proceed with the first task when ready."
    )
    
    log_info "Sending task processing initialization to Claude session"
    
    local command_count=0
    for cmd in "${init_commands[@]}"; do
        ((command_count++))
        log_debug "Sending initialization command $command_count/${#init_commands[@]}: $cmd"
        
        if ! send_command_to_session "$cmd"; then
            log_warn "Failed to send initialization command $command_count: $cmd"
            # Don't fail completely, just warn and continue
        else
            log_debug "Initialization command $command_count sent successfully"
        fi
        
        # Brief pause between commands to avoid overwhelming the session
        sleep 1
    done
    
    # Wait for Claude to process initialization
    log_debug "Waiting for Claude to process initialization..."
    sleep 3
    
    # Optionally verify Claude is ready by checking session output
    if declare -f capture_recent_session_output >/dev/null 2>&1; then
        local session_output
        if session_output=$(capture_recent_session_output "$session_id" 2>/dev/null); then
            if echo "$session_output" | grep -qE "(ready|understand|proceed)"; then
                log_info "✓ Session initialized successfully for task processing"
            else
                log_debug "Session initialization response received (content not validated)"
            fi
        else
            log_debug "Could not capture initialization response"
        fi
    fi
    
    log_info "Task processing session initialization completed"
    return 0
}

# ===============================================================================
# TASK QUEUE ERROR HANDLING & RECOVERY
# ===============================================================================

# Handle task failure with retry logic and recovery
handle_task_failure() {
    local task_id="$1"
    local failure_reason="${2:-unknown_failure}"
    
    if [[ -z "$task_id" ]]; then
        log_error "handle_task_failure: Task ID is required"
        return 1
    fi
    
    log_warn "Handling task failure: $task_id (reason: $failure_reason)"
    
    # Get current retry count
    local retry_count
    if ! retry_count=$(get_task_retry_count "$task_id" 2>/dev/null); then
        log_warn "Could not get retry count for task $task_id, assuming 0"
        retry_count=0
    fi
    
    local max_retries="${TASK_MAX_RETRIES:-3}"
    
    if [[ $retry_count -lt $max_retries ]]; then
        local next_retry=$((retry_count + 1))
        log_info "Scheduling retry $next_retry/$max_retries for task $task_id"
        
        # Calculate retry delay with exponential backoff
        local base_delay="${TASK_RETRY_DELAY:-300}"
        local retry_delay=$((base_delay * next_retry))
        
        # Cap maximum retry delay at 30 minutes
        if [[ $retry_delay -gt 1800 ]]; then
            retry_delay=1800
        fi
        
        log_info "Task $task_id will be retried in ${retry_delay}s (exponential backoff)"
        
        # Increment retry counter
        if declare -f increment_task_retry_count >/dev/null 2>&1; then
            if ! increment_task_retry_count "$task_id"; then
                log_warn "Failed to increment retry count for task $task_id"
            fi
        fi
        
        # Update task status back to pending for retry
        if declare -f update_task_status >/dev/null 2>&1; then
            if ! update_task_status "$task_id" "pending"; then
                log_error "Failed to update task status to pending for retry"
                return 1
            fi
        fi
        
        # Post GitHub retry notification if applicable
        if declare -f post_task_retry_notification >/dev/null 2>&1; then
            post_task_retry_notification "$task_id" "$next_retry" "$max_retries" "$failure_reason"
        fi
        
        log_info "✓ Task $task_id scheduled for retry (attempt $next_retry/$max_retries)"
        return 0
        
    else
        log_error "Task $task_id permanently failed after $max_retries retry attempts"
        
        # Mark task as permanently failed
        if declare -f update_task_status >/dev/null 2>&1; then
            if ! update_task_status "$task_id" "failed_permanent"; then
                log_warn "Failed to update task status to failed_permanent"
            fi
        fi
        
        # Post GitHub permanent failure notification
        if declare -f post_task_permanent_failure_notification >/dev/null 2>&1; then
            post_task_permanent_failure_notification "$task_id" "$max_retries" "$failure_reason"
        fi
        
        # Check if queue should be auto-paused
        if [[ "${QUEUE_AUTO_PAUSE_ON_ERROR:-true}" == "true" ]]; then
            log_warn "Auto-pausing task queue due to permanent task failure"
            
            if declare -f pause_task_queue >/dev/null 2>&1; then
                if pause_task_queue "auto_pause_permanent_failure"; then
                    log_info "✓ Task queue paused automatically due to permanent failure"
                else
                    log_warn "Failed to auto-pause task queue"
                fi
            fi
        fi
        
        log_error "✗ Task $task_id marked as permanently failed"
        return 1
    fi
}

# Recover from critical task processing errors
recover_from_task_processing_error() {
    local error_type="${1:-general_error}"
    local session_id="${2:-$MAIN_SESSION_ID}"
    
    log_warn "Attempting recovery from task processing error: $error_type"
    
    case "$error_type" in
        "session_unresponsive")
            log_info "Attempting session recovery for unresponsive session"
            
            if [[ -n "$session_id" ]] && declare -f perform_session_recovery >/dev/null 2>&1; then
                if perform_session_recovery "$session_id" "task_processing_recovery"; then
                    log_info "✓ Session recovery successful"
                    
                    # Re-initialize session for tasks
                    if initialize_session_for_tasks "$session_id"; then
                        log_info "✓ Session re-initialized for task processing"
                        return 0
                    else
                        log_warn "Session recovery succeeded but re-initialization failed"
                        return 1
                    fi
                else
                    log_error "Session recovery failed"
                    return 1
                fi
            else
                log_warn "No session recovery function available or session ID missing"
                return 1
            fi
            ;;
            
        "queue_corruption")
            log_error "Task queue corruption detected - this requires manual intervention"
            log_error "Please check the task queue files and consider running queue repair"
            
            # Auto-pause queue to prevent further issues
            if declare -f pause_task_queue >/dev/null 2>&1; then
                pause_task_queue "auto_pause_queue_corruption"
            fi
            
            return 1
            ;;
            
        "module_failure")
            log_warn "Task queue module failure detected - attempting to reload modules"
            
            # Try to reload task queue modules
            if [[ "${TASK_QUEUE_ENABLED:-false}" == "true" ]]; then
                log_info "Attempting to reload task queue modules"
                
                # This would require re-sourcing the modules
                local task_queue_module="$SCRIPT_DIR/task-queue.sh"
                if [[ -f "$task_queue_module" ]]; then
                    # shellcheck source=/dev/null
                    if source "$task_queue_module"; then
                        log_info "✓ Task queue module reloaded successfully"
                        
                        # Re-initialize if function is available
                        if declare -f init_task_queue >/dev/null 2>&1; then
                            if init_task_queue; then
                                log_info "✓ Task queue system re-initialized"
                                return 0
                            fi
                        fi
                    else
                        log_error "Failed to reload task queue module"
                        return 1
                    fi
                else
                    log_error "Task queue module not found for reload"
                    return 1
                fi
            fi
            ;;
            
        *)
            log_warn "Unknown error type for recovery: $error_type"
            log_info "Attempting generic recovery procedures"
            
            # Generic recovery: brief pause and continue
            sleep 10
            return 0
            ;;
    esac
    
    return 1
}

# ===============================================================================
# TASK QUEUE ACTION HANDLERS
# ===============================================================================

# Handle immediate queue actions (non-monitoring mode)
handle_queue_actions() {
    if [[ -z "$QUEUE_ACTION" ]]; then
        return 0  # No action specified
    fi
    
    log_info "Processing queue action: $QUEUE_ACTION"
    
    case "$QUEUE_ACTION" in
        "add_issue")
            log_info "Adding GitHub issue #$QUEUE_ITEM to task queue"
            
            if declare -f create_github_issue_task >/dev/null 2>&1; then
                local task_id
                if task_id=$(create_github_issue_task "$QUEUE_ITEM" "${TASK_DEFAULT_PRIORITY:-5}"); then
                    log_info "✓ Issue #$QUEUE_ITEM added to queue successfully (Task ID: $task_id)"
                    
                    # Display queue status after adding
                    if declare -f display_queue_status >/dev/null 2>&1; then
                        echo ""
                        log_info "Current queue status:"
                        display_queue_status
                    fi
                else
                    log_error "Failed to add issue #$QUEUE_ITEM to queue"
                    exit 1
                fi
            else
                log_error "GitHub issue integration not available"
                log_error "Please ensure GitHub integration modules are loaded and configured"
                exit 1
            fi
            ;;
            
        "add_pr")
            log_info "Adding GitHub PR #$QUEUE_ITEM to task queue"
            
            if declare -f create_github_pr_task >/dev/null 2>&1; then
                local task_id
                if task_id=$(create_github_pr_task "$QUEUE_ITEM" "${TASK_DEFAULT_PRIORITY:-5}"); then
                    log_info "✓ PR #$QUEUE_ITEM added to queue successfully (Task ID: $task_id)"
                    
                    # Display queue status after adding
                    if declare -f display_queue_status >/dev/null 2>&1; then
                        echo ""
                        log_info "Current queue status:"
                        display_queue_status
                    fi
                else
                    log_error "Failed to add PR #$QUEUE_ITEM to queue"
                    exit 1
                fi
            else
                log_error "GitHub PR integration not available"
                log_error "Please ensure GitHub integration modules are loaded and configured"
                exit 1
            fi
            ;;
            
        "add_custom")
            log_info "Adding custom task to queue: $QUEUE_ITEM"
            
            if declare -f add_task_to_queue >/dev/null 2>&1; then
                local task_id
                if task_id=$(add_task_to_queue "custom" "${TASK_DEFAULT_PRIORITY:-5}" "" "$QUEUE_ITEM"); then
                    log_info "✓ Custom task added to queue successfully (Task ID: $task_id)"
                    
                    # Display queue status after adding
                    if declare -f display_queue_status >/dev/null 2>&1; then
                        echo ""
                        log_info "Current queue status:"
                        display_queue_status
                    fi
                else
                    log_error "Failed to add custom task to queue"
                    exit 1
                fi
            else
                log_error "Task queue system not available"
                log_error "Please ensure task queue module is loaded"
                exit 1
            fi
            ;;
            
        "list_queue")
            log_info "Displaying current task queue status"
            
            if declare -f display_queue_status >/dev/null 2>&1; then
                echo ""
                display_queue_status
                echo ""
                
                # Additional queue statistics if available
                if declare -f get_queue_statistics >/dev/null 2>&1; then
                    local stats
                    if stats=$(get_queue_statistics); then
                        echo "Queue Statistics:"
                        echo "$stats"
                    fi
                fi
            else
                log_error "Task queue system not available"
                log_error "Please ensure task queue module is loaded"
                exit 1
            fi
            ;;
            
        "clear_queue")
            log_warn "Clearing entire task queue - this will remove ALL tasks"
            echo ""
            echo "⚠️  WARNING: This will permanently delete all tasks in the queue!"
            echo "   This action cannot be undone."
            echo ""
            
            # Show current queue before clearing
            if declare -f display_queue_status >/dev/null 2>&1; then
                echo "Current queue contents:"
                display_queue_status
                echo ""
            fi
            
            read -p "Are you absolutely sure you want to clear the entire queue? (y/N): " -n 1 -r
            echo ""
            
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                if declare -f clear_task_queue >/dev/null 2>&1; then
                    if clear_task_queue; then
                        log_info "✓ Task queue cleared successfully"
                    else
                        log_error "Failed to clear task queue"
                        exit 1
                    fi
                else
                    log_error "Task queue system not available"
                    exit 1
                fi
            else
                log_info "Queue clearing cancelled - no changes made"
            fi
            ;;
            
        "pause_queue")
            log_info "Pausing task queue processing"
            
            if declare -f pause_task_queue >/dev/null 2>&1; then
                if pause_task_queue "manual_pause"; then
                    log_info "✓ Task queue processing paused successfully"
                else
                    log_error "Failed to pause task queue"
                    exit 1
                fi
            else
                log_error "Task queue system not available"
                exit 1
            fi
            ;;
            
        "resume_queue")
            log_info "Resuming task queue processing"
            
            if declare -f resume_task_queue >/dev/null 2>&1; then
                if resume_task_queue; then
                    log_info "✓ Task queue processing resumed successfully"
                else
                    log_error "Failed to resume task queue"
                    exit 1
                fi
            else
                log_error "Task queue system not available"
                exit 1
            fi
            ;;
            
        "skip_current")
            log_info "Skipping current task"
            
            if declare -f skip_current_task >/dev/null 2>&1; then
                if skip_current_task; then
                    log_info "✓ Current task skipped successfully"
                else
                    log_error "Failed to skip current task (may not be running)"
                    exit 1
                fi
            else
                log_error "Task queue system not available"
                exit 1
            fi
            ;;
            
        "retry_current")
            log_info "Retrying current failed task"
            
            if declare -f retry_current_task >/dev/null 2>&1; then
                if retry_current_task; then
                    log_info "✓ Current task scheduled for retry"
                else
                    log_error "Failed to retry current task (may not be in failed state)"
                    exit 1
                fi
            else
                log_error "Task queue system not available"
                exit 1
            fi
            ;;
            
        *)
            log_error "Unknown queue action: $QUEUE_ACTION"
            exit 1
            ;;
    esac
}

# ===============================================================================
# SESSION ID MANAGEMENT OPERATIONS
# ===============================================================================

# Handle Session ID Management CLI Operations
handle_session_id_operations() {
    log_debug "Processing session ID management operations"
    
    # Initialize session display system
    if declare -f init_clipboard >/dev/null 2>&1; then
        init_clipboard
    fi
    
    # Initialize session manager if needed
    if declare -f init_session_manager >/dev/null 2>&1; then
        init_session_manager "${SPECIFIED_CONFIG:-$CONFIG_FILE}"
    fi
    
    local operation_handled=false
    
    # Handle --show-session-id / --show-full-session-id
    if [[ "$SHOW_SESSION_ID" == "true" ]]; then
        log_info "Displaying session ID information"
        if declare -f show_current_session_id >/dev/null 2>&1; then
            show_current_session_id "$MAIN_SESSION_ID" "$SHOW_FULL_SESSION_ID"
            operation_handled=true
        else
            log_error "Session display functions not available"
            echo "Error: Session display module not loaded"
            return 1
        fi
    fi
    
    # Handle --copy-session-id
    if [[ "$COPY_SESSION_ID" == "true" ]]; then
        local target_session_id=""
        
        if [[ "$COPY_SESSION_TARGET" == "current" || -z "$COPY_SESSION_TARGET" ]]; then
            if [[ -n "$MAIN_SESSION_ID" ]]; then
                target_session_id="$MAIN_SESSION_ID"
                log_info "Copying current session ID to clipboard"
            else
                log_error "No current session ID available"
                echo "Error: No active session found to copy"
                return 1
            fi
        else
            target_session_id="$COPY_SESSION_TARGET"
            log_info "Copying specified session ID to clipboard: $(shorten_session_id "$target_session_id" 20)"
        fi
        
        if declare -f show_and_copy_session_id >/dev/null 2>&1; then
            if show_and_copy_session_id "$target_session_id" true false; then
                operation_handled=true
            else
                log_error "Failed to copy session ID"
                return 1
            fi
        else
            log_error "Session copy functions not available"
            echo "Error: Session display module not loaded"
            return 1
        fi
    fi
    
    # Handle --list-sessions
    if [[ "$LIST_SESSIONS_MODE" == "true" ]]; then
        log_info "Listing all active sessions"
        if declare -f list_sessions_with_copy_options >/dev/null 2>&1; then
            list_sessions_with_copy_options "table" true
            operation_handled=true
        else
            log_error "Session listing functions not available"
            echo "Error: Session display module not loaded"
            return 1
        fi
    fi
    
    # Handle --resume-session
    if [[ -n "$RESUME_SESSION_ID" ]]; then
        log_info "Resuming session: $RESUME_SESSION_ID"
        
        # Verify session exists
        if declare -f get_session_info >/dev/null 2>&1; then
            if ! get_session_info "$RESUME_SESSION_ID" >/dev/null 2>&1; then
                log_error "Session not found: $RESUME_SESSION_ID"
                echo "Error: Session '$RESUME_SESSION_ID' not found"
                
                # Show available sessions
                echo ""
                echo "Available sessions:"
                if declare -f list_sessions_with_copy_options >/dev/null 2>&1; then
                    list_sessions_with_copy_options "list" false
                fi
                return 1
            fi
        fi
        
        # Set the session for resuming
        MAIN_SESSION_ID="$RESUME_SESSION_ID"
        log_info "Set session ID for resume: $MAIN_SESSION_ID"
        echo "Resuming session: $(shorten_session_id "$MAIN_SESSION_ID" 30)"
        operation_handled=true
        
        # Continue with normal monitoring for this session
        # (Don't exit - let continuous mode handle the session)
    fi
    
    if [[ "$operation_handled" == "false" ]]; then
        log_warn "No session ID operations were handled"
        return 1
    fi
    
    return 0
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
    
    # Lade Konfiguration
    load_configuration
    
    # Lade Dependencies
    load_dependencies
    
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
    
    # Handle Session ID Management Operations (falls CLI-Parameter gesetzt)
    if [[ "$SHOW_SESSION_ID" == "true" || "$COPY_SESSION_ID" == "true" || "$LIST_SESSIONS_MODE" == "true" || -n "$RESUME_SESSION_ID" ]]; then
        handle_session_id_operations
        # Exit nach Session-Operationen falls nicht in continuous mode
        if [[ "$CONTINUOUS_MODE" != "true" ]]; then
            log_info "Session ID operations completed"
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
    
    if declare -f init_claunch_integration >/dev/null 2>&1; then
        init_claunch_integration "${SPECIFIED_CONFIG:-$CONFIG_FILE}" "$WORKING_DIR"
    fi
    
    if declare -f init_session_manager >/dev/null 2>&1; then
        init_session_manager "${SPECIFIED_CONFIG:-$CONFIG_FILE}"
    fi
    
    # Validiere Systemvoraussetzungen
    if ! validate_system_requirements; then
        log_error "System requirements not met - exiting"
        exit 1
    fi
    
    # Handle immediate queue actions first (non-continuous mode)
    if [[ -n "$QUEUE_ACTION" ]]; then
        handle_queue_actions
        
        # If not in continuous mode, exit after handling the action
        if [[ "$CONTINUOUS_MODE" == "false" ]]; then
            log_info "Queue action completed - exiting"
            exit 0
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