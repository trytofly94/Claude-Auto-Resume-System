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
ENHANCED_USAGE_LIMITS=false
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
    # Note: Cannot use log_debug yet - logging.sh not loaded
    echo "[DEBUG] Loading dependencies from: $SCRIPT_DIR" >&2
    
    # CRITICAL: Load logging.sh FIRST so other modules can use logging functions
    # Then load other utilities in dependency order
    local modules=(
        "utils/logging.sh"
        "utils/config-loader.sh"
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
            
            # Load Usage Limit Recovery Module for enhanced features
            if [[ "${ENHANCED_USAGE_LIMITS:-false}" == "true" ]]; then
                local usage_limit_script="$SCRIPT_DIR/usage-limit-recovery.sh"
                if [[ -f "$usage_limit_script" && -r "$usage_limit_script" ]]; then
                    source "$usage_limit_script"
                    log_debug "Enhanced usage limit recovery module loaded"
                    export ENHANCED_USAGE_LIMITS_AVAILABLE=true
                else
                    log_warn "Enhanced usage limits requested but module not available"
                    export ENHANCED_USAGE_LIMITS_AVAILABLE=false
                fi
            fi
        else
            log_warn "Task Queue script exists but not functional"
            export TASK_QUEUE_AVAILABLE=false
        fi
    else
        log_warn "Task Queue script not found or not executable at: $task_queue_script"
        export TASK_QUEUE_AVAILABLE=false
    fi
    
    local logging_loaded=false
    
    for module in "${modules[@]}"; do
        local module_path="$SCRIPT_DIR/$module"
        if [[ -f "$module_path" ]]; then
            # shellcheck source=/dev/null
            source "$module_path"
            
            # After loading logging.sh, we can use log functions
            if [[ "$module" == "utils/logging.sh" ]]; then
                logging_loaded=true
                log_debug "Logging module loaded, switching to structured logging"
            fi
            
            # Use appropriate logging method
            if [[ "$logging_loaded" == "true" ]]; then
                log_debug "Loaded module: $module"
            else
                echo "[DEBUG] Loaded module: $module" >&2
            fi
        else
            if [[ "$logging_loaded" == "true" ]]; then
                log_warn "Module not found: $module_path"
            else
                echo "[WARN] Module not found: $module_path" >&2
            fi
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

# Enhanced task queue processing with comprehensive usage limit integration
process_task_queue() {
    log_debug "Starting enhanced task queue processing with live usage limit handling"
    
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
    
    # Auto-resume queue if usage limit wait period is complete
    if declare -f auto_resume_queue_if_ready >/dev/null 2>&1; then
        if auto_resume_queue_if_ready; then
            log_info "🔄 Queue automatically resumed after usage limit wait period"
        fi
    fi
    
    # Prüfe auf pending tasks - verwende task-queue.sh list command
    local pending_tasks
    pending_tasks=$("${TASK_QUEUE_SCRIPT}" list --status=pending --count-only 2>/dev/null)
    if [[ -z "$pending_tasks" || "$pending_tasks" -eq 0 ]]; then
        log_debug "No pending tasks in queue"
        return 0
    fi
    
    log_info "📋 Enhanced processing: $pending_tasks pending tasks found"
    
    # Check if enhanced usage limits are enabled
    if [[ "${ENHANCED_USAGE_LIMITS:-false}" == "true" ]]; then
        log_info "🚀 Starting live task processing with enhanced usage limit detection"
        process_task_queue_with_live_limits
        return $?
    fi
    
    # Hole nächste Task - für Phase 1 nur ersten pending task identifizieren
    local next_task_id
    next_task_id=$("${TASK_QUEUE_SCRIPT}" list --status=pending --format=id-only --limit=1 2>/dev/null | head -1)
    if [[ -z "$next_task_id" ]]; then
        log_debug "No executable tasks available"
        return 0
    fi
    
    log_info "🎯 Found pending task for enhanced processing: $next_task_id"
    
    # Get task data for context clearing decisions
    local task_data
    task_data=$("${TASK_QUEUE_SCRIPT}" show "$next_task_id" 2>/dev/null)
    
    # Enhanced task metadata extraction
    local task_type="unknown"
    local task_priority="normal"
    if [[ -n "$task_data" ]] && has_command jq; then
        task_type=$(echo "$task_data" | jq -r '.type // "custom"' 2>/dev/null || echo "custom")
        task_priority=$(echo "$task_data" | jq -r '.priority // "normal"' 2>/dev/null || echo "normal")
    fi
    
    log_debug "Enhanced task details: ID=$next_task_id, Type=$task_type, Priority=$task_priority"
    
    # Execute the task with enhanced error handling, progress monitoring, and usage limit detection
    local execution_result
    local completion_reason="normal"
    local start_time=$(date +%s)
    
    log_info "🚀 Starting enhanced execution of task $next_task_id"
    
    if execute_single_task_enhanced "$next_task_id" "$task_data"; then
        execution_result="success"
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        log_info "✅ Task $next_task_id completed successfully in ${duration}s"
        
        # Update task status to completed with enhanced metadata
        local completion_message="Task completed successfully by enhanced automated processing (duration: ${duration}s)"
        if ! "${TASK_QUEUE_SCRIPT}" update-status "$next_task_id" "completed" "$completion_message"; then
            log_warn "Failed to update task status to completed for $next_task_id"
        fi
        
    else
        execution_result="failed"
        local exit_code=$?
        
        # Check if failure was due to usage limit
        if [[ $exit_code -eq 42 ]]; then
            completion_reason="usage_limit_recovery"
            log_warn "Task $next_task_id paused due to usage limit - will resume automatically with enhanced recovery"
            
            # Update task status to pending (so it will be retried after usage limit expires)
            if ! "${TASK_QUEUE_SCRIPT}" update-status "$next_task_id" "pending" "Task paused due to usage limit, will resume automatically after wait period"; then
                log_warn "Failed to update task status for paused task $next_task_id"
            fi
            
            log_info "🔄 Enhanced usage limit handling completed - task queued for automatic retry"
            
        else
            completion_reason="error"
            log_error "Task $next_task_id failed with exit code: $exit_code"
            
            # Update task status to error with details
            local error_message="Task failed during automated processing (exit code: $exit_code)"
            if ! "${TASK_QUEUE_SCRIPT}" update-status "$next_task_id" "error" "$error_message"; then
                log_warn "Failed to update task status to error for $next_task_id"
            fi
        fi
    fi
    
    # Context clearing decision logic
    if should_clear_context "$task_data" "$completion_reason"; then
        log_debug "Context clearing recommended for task $next_task_id (reason: $completion_reason)"
        execute_context_clearing "$task_data" "$completion_reason" "${MAIN_SESSION_ID:-}"
    else
        log_debug "Context preservation recommended for task $next_task_id (reason: $completion_reason)"
    fi
    
    return 0
}

# Enhanced task processing with live usage limit handling and intelligent recovery
process_task_queue_with_live_limits() {
    local total_tasks
    total_tasks=$("${TASK_QUEUE_SCRIPT}" list --status=pending --count-only 2>/dev/null)
    local processed=0
    local usage_limit_encounters=0
    
    log_info "🚀 Starting live task processing: $total_tasks tasks pending"
    
    while [[ $processed -lt $total_tasks ]]; do
        log_info "📋 Processing task $((processed + 1))/$total_tasks"
        
        # Get next pending task
        local next_task_id
        next_task_id=$("${TASK_QUEUE_SCRIPT}" list --status=pending --format=id-only --limit=1 2>/dev/null | head -1)
        
        if [[ -z "$next_task_id" ]]; then
            log_warn "No more pending tasks available"
            break
        fi
        
        local task_data
        task_data=$("${TASK_QUEUE_SCRIPT}" show "$next_task_id" 2>/dev/null)
        
        if [[ -z "$task_data" ]]; then
            log_error "Could not retrieve task data for $next_task_id"
            ((processed++))
            continue
        fi
        
        # Execute next pending task with enhanced monitoring
        local task_output
        local task_exit_code=0
        log_info "⚙️ Executing task $next_task_id with enhanced usage limit detection"
        
        if ! task_output=$(execute_single_task_enhanced "$next_task_id" "$task_data" 2>&1); then
            task_exit_code=$?
        fi
        
        # Check for usage limit in task output using enhanced detection
        if [[ $task_exit_code -ne 0 ]] && detect_usage_limit_in_output_enhanced "$task_output"; then
            ((usage_limit_encounters++))
            log_warn "⏰ Enhanced usage limit detected (encounter #$usage_limit_encounters)"
            log_info "Task output that triggered detection: $(echo "$task_output" | head -3)"
            
            # Use enhanced usage limit handling with sourced function
            if [[ -f "$SCRIPT_DIR/usage-limit-recovery.sh" ]]; then
                source "$SCRIPT_DIR/usage-limit-recovery.sh" || true
            fi
            
            if declare -f extract_usage_limit_time_enhanced >/dev/null 2>&1 && wait_time=$(extract_usage_limit_time_enhanced "$task_output"); then
                log_info "⏳ Enhanced usage limit detection successful: ${wait_time}s wait"
                display_usage_limit_countdown_enhanced "$wait_time" "usage limit (enhanced detection)"
            else
                log_warn "⏳ Falling back to standard usage limit handling"
                if declare -f handle_usage_limit_scenario >/dev/null 2>&1 && handle_usage_limit_scenario "$task_output"; then
                    log_info "✅ Standard usage limit handling completed"
                else
                    log_error "❌ Usage limit handling failed"
                fi
            fi
            
            # Don't increment processed count - retry the same task
            continue
        else
            # Task completed successfully
            ((processed++))
            log_info "✅ Task $processed/$total_tasks completed successfully"
        fi
        
        # Brief pause between tasks to prevent overwhelming system
        sleep 2
        
        # Safety check for infinite loops
        if [[ $usage_limit_encounters -gt 10 ]]; then
            log_error "❌ Too many usage limit encounters ($usage_limit_encounters) - stopping processing"
            break
        fi
    done
    
    log_info "🎉 Live task processing complete: $processed/$total_tasks tasks processed"
    log_info "📊 Usage limit encounters: $usage_limit_encounters"
    return 0
}

# Enhanced usage limit detection for task output
detect_usage_limit_in_output_enhanced() {
    local output="$1"
    
    if [[ -z "$output" ]]; then
        return 1  # No output to check
    fi
    
    log_debug "🔍 Enhanced usage limit detection in task output"
    
    # Load usage-limit-recovery module if not already loaded
    if ! declare -f extract_usage_limit_time_enhanced >/dev/null 2>&1; then
        if [[ -f "$SCRIPT_DIR/usage-limit-recovery.sh" ]]; then
            source "$SCRIPT_DIR/usage-limit-recovery.sh" || return 1
        else
            log_error "Usage limit recovery module not found"
            return 1
        fi
    fi
    
    # First try enhanced time-specific detection
    if extract_usage_limit_time_enhanced "$output" >/dev/null 2>&1; then
        log_info "✨ Enhanced time-specific usage limit detected"
        return 0
    fi
    
    # Fallback to standard detection patterns
    local limit_patterns=(
        "usage limit"
        "rate limit"
        "too many requests"
        "please try again later"
        "request limit exceeded"
        "quota exceeded"
        "temporarily unavailable"
        "service temporarily overloaded"
        "blocked until"
        "try again at"
        "available.*at"
        "retry at"
        "wait until"
    )
    
    for pattern in "${limit_patterns[@]}"; do
        if echo "$output" | grep -qi "$pattern"; then
            log_info "📋 Standard usage limit pattern detected: '$pattern'"
            return 0
        fi
    done
    
    return 1  # No usage limit detected
}

# Enhanced countdown display with live progress feedback
display_usage_limit_countdown_enhanced() {
    local total_wait_time="$1"
    local reason="${2:-enhanced usage limit}"
    local start_time=$(date +%s)
    local end_time=$((start_time + total_wait_time))
    
    log_info "⏰ Starting enhanced usage limit countdown display (reason: $reason, duration: ${total_wait_time}s)"
    
    # Calculate ETA
    local eta_timestamp
    if has_command date; then
        if date -d "@$end_time" "+%H:%M:%S" >/dev/null 2>&1; then
            eta_timestamp=$(date -d "@$end_time" "+%H:%M:%S")
        elif date -r "$end_time" "+%H:%M:%S" >/dev/null 2>&1; then
            eta_timestamp=$(date -r "$end_time" "+%H:%M:%S")
        else
            eta_timestamp="unknown"
        fi
    else
        eta_timestamp="unknown"
    fi
    
    log_info "Usage limit will expire at: $eta_timestamp"
    
    local update_interval=60  # Update every minute
    local last_minute_display=""
    
    while [[ $(date +%s) -lt $end_time ]]; do
        local current_time=$(date +%s)
        local remaining=$((end_time - current_time))
        
        if [[ $remaining -le 0 ]]; then
            break
        fi
        
        # Format remaining time
        local hours=$((remaining / 3600))
        local minutes=$(((remaining % 3600) / 60))
        local seconds=$((remaining % 60))
        
        local time_display=""
        if [[ $hours -gt 0 ]]; then
            time_display="${hours}h ${minutes}m"
        elif [[ $minutes -gt 0 ]]; then
            time_display="${minutes}m ${seconds}s"
        else
            time_display="${seconds}s"
        fi
        
        # Calculate progress percentage
        local elapsed=$((current_time - start_time))
        local progress_percent=$(( (elapsed * 100) / total_wait_time ))
        
        # Enhanced progress display with emojis for live operation
        if [[ $remaining -le 300 ]]; then  # Last 5 minutes
            if [[ "$last_minute_display" != "shown" ]]; then
                log_info "🔥 Final 5 minutes countdown starting..."
                last_minute_display="shown"
            fi
            update_interval=30  # Update every 30 seconds in final 5 minutes
        fi
        
        # Display enhanced countdown with progress and ETA
        log_info "⏳ $reason - ${time_display} remaining (${progress_percent}% complete, ETA: $eta_timestamp)"
        
        sleep "$update_interval"
    done
    
    log_info "✅ Enhanced usage limit wait period completed - resuming live task processing"
    return 0
}

# ===============================================================================
# TASK EXECUTION ENGINE (Phase 2 Implementation)
# ===============================================================================

# Execute a single task with comprehensive error handling and progress monitoring
execute_single_task() {
    local task_id="$1"
    local task_data="$2"
    
    if [[ -z "$task_id" || -z "$task_data" ]]; then
        log_error "execute_single_task: task_id and task_data required"
        return 1
    fi
    
    log_info "Starting execution of task: $task_id"
    
    # Extract task details from JSON data
    local task_type task_command task_description task_priority
    if has_command jq; then
        task_type=$(echo "$task_data" | jq -r '.type // "custom"')
        task_command=$(echo "$task_data" | jq -r '.command // .description // ""')
        task_description=$(echo "$task_data" | jq -r '.description // .command // ""')
        task_priority=$(echo "$task_data" | jq -r '.priority // "normal"')
    else
        # Fallback parsing without jq
        task_type="custom"
        task_command=$(echo "$task_data" | grep -o '"command"[^,]*' | sed 's/"command"[^"]*"\([^"]*\)".*/\1/' || echo "")
        task_description=$(echo "$task_data" | grep -o '"description"[^,]*' | sed 's/"description"[^"]*"\([^"]*\)".*/\1/' || echo "")
        task_priority="normal"
    fi
    
    log_debug "Task details: type=$task_type, priority=$task_priority"
    log_debug "Task command/description: $task_command"
    
    # Update task status to in_progress
    if ! "${TASK_QUEUE_SCRIPT}" update-status "$task_id" "in_progress" "Task execution started by automated processing"; then
        log_warn "Failed to update task status to in_progress for $task_id"
    fi
    
    # Ensure we have an active Claude session for task execution
    local session_id="${MAIN_SESSION_ID:-}"
    if [[ -z "$session_id" ]]; then
        log_info "No active session found, starting new Claude session for task execution"
        if ! start_or_continue_claude_session; then
            log_error "Failed to start Claude session for task execution"
            return 1
        fi
        session_id="${MAIN_SESSION_ID:-}"
    fi
    
    if [[ -z "$session_id" ]]; then
        log_error "No session available for task execution"
        return 1
    fi
    
    log_debug "Using session $session_id for task execution"
    
    # Execute task based on type
    local execution_start_time=$(date +%s)
    local execution_success=false
    
    case "$task_type" in
        "github_issue")
            execution_success=$(execute_github_issue_task "$session_id" "$task_id" "$task_data")
            ;;
        "github_pr")
            execution_success=$(execute_github_pr_task "$session_id" "$task_id" "$task_data")
            ;;
        "custom")
            execution_success=$(execute_custom_task "$session_id" "$task_id" "$task_data")
            ;;
        *)
            log_warn "Unknown task type: $task_type, treating as custom task"
            execution_success=$(execute_custom_task "$session_id" "$task_id" "$task_data")
            ;;
    esac
    
    local execution_end_time=$(date +%s)
    local execution_duration=$((execution_end_time - execution_start_time))
    
    log_debug "Task execution completed in ${execution_duration}s"
    
    if [[ "$execution_success" == "true" ]]; then
        log_info "Task $task_id executed successfully"
        return 0
    else
        log_error "Task $task_id execution failed"
        return 1
    fi
}

# Enhanced single task execution with usage limit integration
execute_single_task_enhanced() {
    local task_id="$1"
    local task_data="$2"
    
    if [[ -z "$task_id" || -z "$task_data" ]]; then
        log_error "execute_single_task_enhanced: task_id and task_data required"
        return 1
    fi
    
    log_info "🚀 Starting enhanced execution of task: $task_id"
    
    # Extract task details from JSON data with enhanced parsing
    local task_type task_command task_description task_priority
    if has_command jq; then
        task_type=$(echo "$task_data" | jq -r '.type // "custom"' 2>/dev/null || echo "custom")
        task_command=$(echo "$task_data" | jq -r '.command // .description // ""' 2>/dev/null || echo "")
        task_description=$(echo "$task_data" | jq -r '.description // .command // ""' 2>/dev/null || echo "")
        task_priority=$(echo "$task_data" | jq -r '.priority // "normal"' 2>/dev/null || echo "normal")
    else
        # Enhanced fallback parsing without jq
        task_type="custom"
        task_command=$(echo "$task_data" | grep -o '"command"[^,]*' | sed 's/"command"[^"]*"\([^"]*\)".*/\1/' || echo "")
        task_description=$(echo "$task_data" | grep -o '"description"[^,]*' | sed 's/"description"[^"]*"\([^"]*\)".*/\1/' || echo "")
        task_priority="normal"
    fi
    
    log_debug "Enhanced task details: type=$task_type, priority=$task_priority"
    log_debug "Enhanced task command/description: ${task_command:0:100}..."
    
    # Update task status to in_progress with enhanced metadata
    local in_progress_message="Enhanced task execution started by automated processing (type: $task_type, priority: $task_priority)"
    if ! "${TASK_QUEUE_SCRIPT}" update-status "$task_id" "in_progress" "$in_progress_message"; then
        log_warn "Failed to update task status to in_progress for $task_id"
    fi
    
    # Ensure we have an active Claude session for task execution
    local session_id="${MAIN_SESSION_ID:-}"
    if [[ -z "$session_id" ]]; then
        log_info "🔍 No active session found, starting new Claude session for enhanced task execution"
        if ! start_or_continue_claude_session; then
            log_error "Failed to start Claude session for enhanced task execution"
            return 1
        fi
        session_id="${MAIN_SESSION_ID:-}"
    fi
    
    if [[ -z "$session_id" ]]; then
        log_error "No session available for enhanced task execution"
        return 1
    fi
    
    log_debug "Using session $session_id for enhanced task execution"
    
    # Enhanced task execution with retry logic and usage limit handling
    local execution_start_time=$(date +%s)
    local execution_success=false
    local max_retries=3
    local retry_count=0
    
    while [[ $retry_count -lt $max_retries ]]; do
        ((retry_count++))
        
        if [[ $retry_count -gt 1 ]]; then
            log_info "🔄 Enhanced retry attempt $retry_count/$max_retries for task $task_id"
            # Brief pause between retries
            sleep 5
        fi
        
        # Execute task based on type with enhanced monitoring
        case "$task_type" in
            "github_issue")
                if execute_github_issue_task_enhanced "$session_id" "$task_id" "$task_data"; then
                    execution_success=true
                    break
                fi
                ;;
            "github_pr")
                if execute_github_pr_task_enhanced "$session_id" "$task_id" "$task_data"; then
                    execution_success=true
                    break
                fi
                ;;
            "custom")
                if execute_custom_task_enhanced "$session_id" "$task_id" "$task_data"; then
                    execution_success=true
                    break
                fi
                ;;
            *)
                log_warn "Unknown task type: $task_type, treating as enhanced custom task"
                if execute_custom_task_enhanced "$session_id" "$task_id" "$task_data"; then
                    execution_success=true
                    break
                fi
                ;;
        esac
        
        # Check if last attempt failed due to usage limit
        local last_exit_code=$?
        if [[ $last_exit_code -eq 42 ]]; then
            log_info "⏰ Task execution paused due to usage limit - execution will be retried automatically"
            # Don't count usage limit as a retry attempt
            ((retry_count--))
            return 42  # Propagate usage limit exit code
        fi
        
        if [[ $retry_count -lt $max_retries ]]; then
            log_warn "⚠️ Task execution attempt $retry_count failed, will retry"
        fi
    done
    
    local execution_end_time=$(date +%s)
    local execution_duration=$((execution_end_time - execution_start_time))
    
    log_debug "Enhanced task execution completed in ${execution_duration}s (${retry_count} attempts)"
    
    if [[ "$execution_success" == "true" ]]; then
        log_info "✅ Enhanced task $task_id executed successfully"
        return 0
    else
        log_error "❌ Enhanced task $task_id execution failed after $retry_count attempts"
        return 1
    fi
}

# Enhanced GitHub issue task execution
execute_github_issue_task_enhanced() {
    local session_id="$1"
    local task_id="$2"
    local task_data="$3"
    
    local issue_number repo_url issue_url
    if has_command jq; then
        issue_number=$(echo "$task_data" | jq -r '.issue_number // ""' 2>/dev/null || echo "")
        repo_url=$(echo "$task_data" | jq -r '.repo_url // ""' 2>/dev/null || echo "")
        issue_url=$(echo "$task_data" | jq -r '.issue_url // ""' 2>/dev/null || echo "")
    else
        issue_number=$(echo "$task_data" | grep -o '"issue_number"[^,]*' | sed 's/.*"\([^"]*\)".*/\1/' || echo "")
        repo_url=""
        issue_url=""
    fi
    
    if [[ -z "$issue_number" ]]; then
        log_error "Enhanced GitHub issue task missing issue_number"
        return 1
    fi
    
    log_info "🐛 Executing enhanced GitHub issue task: #$issue_number"
    
    # Send enhanced command to Claude session to process the GitHub issue
    local command="/dev $issue_number"
    if ! execute_command_in_session "$session_id" "$command"; then
        log_error "Failed to send enhanced GitHub issue command to session"
        return 1
    fi
    
    # Monitor task execution with enhanced usage limit detection
    if monitor_task_execution_enhanced "$session_id" "$task_id" "github_issue"; then
        return 0
    else
        local exit_code=$?
        return $exit_code
    fi
}

# Enhanced GitHub PR task execution
execute_github_pr_task_enhanced() {
    local session_id="$1"
    local task_id="$2"
    local task_data="$3"
    
    local pr_number repo_url pr_url
    if has_command jq; then
        pr_number=$(echo "$task_data" | jq -r '.pr_number // ""' 2>/dev/null || echo "")
        repo_url=$(echo "$task_data" | jq -r '.repo_url // ""' 2>/dev/null || echo "")
        pr_url=$(echo "$task_data" | jq -r '.pr_url // ""' 2>/dev/null || echo "")
    else
        pr_number=$(echo "$task_data" | grep -o '"pr_number"[^,]*' | sed 's/.*"\([^"]*\)".*/\1/' || echo "")
        repo_url=""
        pr_url=""
    fi
    
    if [[ -z "$pr_number" ]]; then
        log_error "Enhanced GitHub PR task missing pr_number"
        return 1
    fi
    
    log_info "🔀 Executing enhanced GitHub PR task: #$pr_number"
    
    # Send enhanced command to Claude session to process the GitHub PR
    local command="/dev pr/$pr_number"
    if ! execute_command_in_session "$session_id" "$command"; then
        log_error "Failed to send enhanced GitHub PR command to session"
        return 1
    fi
    
    # Monitor task execution with enhanced usage limit detection
    if monitor_task_execution_enhanced "$session_id" "$task_id" "github_pr"; then
        return 0
    else
        local exit_code=$?
        return $exit_code
    fi
}

# Enhanced custom task execution
execute_custom_task_enhanced() {
    local session_id="$1"
    local task_id="$2"
    local task_data="$3"
    
    local command description
    if has_command jq; then
        command=$(echo "$task_data" | jq -r '.command // .description // ""' 2>/dev/null || echo "")
        description=$(echo "$task_data" | jq -r '.description // .command // ""' 2>/dev/null || echo "")
    else
        command=$(echo "$task_data" | grep -o '"command"[^,]*' | sed 's/.*"\([^"]*\)".*/\1/' || echo "")
        description=$(echo "$task_data" | grep -o '"description"[^,]*' | sed 's/.*"\([^"]*\)".*/\1/' || echo "")
    fi
    
    if [[ -z "$command" && -z "$description" ]]; then
        log_error "Enhanced custom task missing command or description"
        return 1
    fi
    
    local task_content="${command:-$description}"
    log_info "⚙️ Executing enhanced custom task: ${task_content:0:50}..."
    
    # Send enhanced command to Claude session
    if ! execute_command_in_session "$session_id" "$task_content"; then
        log_error "Failed to send enhanced custom task command to session"
        return 1
    fi
    
    # Monitor task execution with enhanced usage limit detection
    if monitor_task_execution_enhanced "$session_id" "$task_id" "custom"; then
        return 0
    else
        local exit_code=$?
        return $exit_code
    fi
}

# Enhanced task execution monitoring with improved usage limit detection
monitor_task_execution_enhanced() {
    local session_id="$1"
    local task_id="$2"
    local task_type="$3"
    local max_wait_time="${4:-1800}"  # Default 30 minutes max
    
    log_debug "🔍 Enhanced monitoring of task $task_id (type: $task_type, max_wait: ${max_wait_time}s)"
    
    local start_time=$(date +%s)
    local last_activity_time=$start_time
    local check_interval=8  # Check every 8 seconds for better responsiveness
    local activity_timeout=300  # 5 minutes without activity = timeout
    local consecutive_checks=0
    local max_consecutive_checks=$((max_wait_time / check_interval))
    local usage_limit_checks=0
    
    while [[ $consecutive_checks -lt $max_consecutive_checks ]]; do
        ((consecutive_checks++))
        local current_time=$(date +%s)
        local elapsed_time=$((current_time - start_time))
        
        log_debug "Enhanced monitoring cycle $consecutive_checks/$max_consecutive_checks (elapsed: ${elapsed_time}s)"
        
        # Get session output for enhanced analysis
        local session_output
        if session_output=$(get_session_output "$session_id" 2>/dev/null); then
            
            # Enhanced usage limit detection with comprehensive pattern matching
            if detect_usage_limit_in_queue "$session_output" "$task_id"; then
                ((usage_limit_checks++))
                log_warn "⏰ Enhanced usage limit detected during task execution (check #$usage_limit_checks)"
                
                # Use enhanced pause function with live countdown
                if declare -f pause_queue_for_usage_limit_enhanced >/dev/null 2>&1; then
                    if pause_queue_for_usage_limit_enhanced "" "$task_id" "enhanced_time_specific_limit"; then
                        log_info "✅ Enhanced usage limit handling completed - task will resume automatically"
                        return 42  # Special exit code for usage limit
                    else
                        log_error "Failed to execute enhanced usage limit handling"
                        return 1
                    fi
                else
                    # Fallback to standard handling
                    if pause_queue_for_usage_limit "" "$task_id" "time_specific_limit"; then
                        log_info "Standard usage limit handling completed - task will resume automatically"
                        return 42
                    else
                        log_error "Failed to execute usage limit handling"
                        return 1
                    fi
                fi
            fi
            
            # Enhanced task completion detection
            if check_task_completion_indicators_enhanced "$session_output" "$task_type"; then
                log_info "✅ Enhanced task completion detected for $task_id"
                return 0
            fi
            
            # Enhanced error detection
            if check_task_error_indicators_enhanced "$session_output"; then
                log_warn "⚠️ Enhanced task error indicators detected for $task_id"
                return 1
            fi
            
            # Update last activity time if there's new content
            if [[ -n "$session_output" ]]; then
                last_activity_time=$current_time
            fi
        fi
        
        # Enhanced activity timeout detection
        local time_since_activity=$((current_time - last_activity_time))
        if [[ $time_since_activity -gt $activity_timeout ]]; then
            log_warn "⏰ Enhanced task $task_id appears inactive (${time_since_activity}s without activity)"
            return 1
        fi
        
        # Enhanced real-time progress reporting
        if [[ $((consecutive_checks % 8)) -eq 0 ]]; then  # Every 64 seconds
            local remaining_time=$((max_wait_time - elapsed_time))
            local progress_percent=$(( (elapsed_time * 100) / max_wait_time ))
            log_info "📈 Enhanced task $task_id monitoring: ${elapsed_time}s elapsed, ${remaining_time}s remaining ($progress_percent%)"
        fi
        
        sleep $check_interval
    done
    
    log_warn "⏰ Enhanced task execution monitoring timeout reached for $task_id"
    return 1
}

# Enhanced task completion detection
check_task_completion_indicators_enhanced() {
    local output="$1"
    local task_type="$2"
    
    # Enhanced completion patterns with more comprehensive detection
    local enhanced_completion_patterns=(
        "task.*completed"
        "successfully.*finished"
        "done.*processing"
        "completed.*successfully"
        "finished.*task"
        "pull request.*created"
        "commit.*created"
        "issue.*resolved"
        "implementation.*complete"
        "deployment.*successful"
        "analysis.*complete"
        "review.*finished"
        "changes.*applied"
        "ready.*for.*review"
        "solution.*implemented"
    )
    
    # Check enhanced patterns
    for pattern in "${enhanced_completion_patterns[@]}"; do
        if echo "$output" | grep -qi "$pattern"; then
            log_debug "Enhanced completion pattern matched: $pattern"
            return 0
        fi
    done
    
    # Task-type-specific enhanced patterns
    case "$task_type" in
        "github_issue")
            if echo "$output" | grep -qiE "(issue.*closed|pr.*created|solution.*provided)"; then
                return 0
            fi
            ;;
        "github_pr")
            if echo "$output" | grep -qiE "(pr.*reviewed|changes.*approved|merge.*ready)"; then
                return 0
            fi
            ;;
        "custom")
            if echo "$output" | grep -qiE "(task.*done|objective.*achieved|request.*fulfilled)"; then
                return 0
            fi
            ;;
    esac
    
    return 1
}

# Enhanced task error detection
check_task_error_indicators_enhanced() {
    local output="$1"
    
    # Enhanced error patterns (excluding usage limit patterns)
    local enhanced_error_patterns=(
        "error.*occurred"
        "failed.*to"
        "cannot.*complete"
        "unable.*to.*process"
        "task.*failed"
        "execution.*error"
        "critical.*error"
        "fatal.*error"
        "invalid.*request"
        "permission.*denied"
        "access.*denied"
        "not.*found"
        "timeout.*exceeded"
        "connection.*failed"
    )
    
    # Check enhanced error patterns, but exclude usage limit patterns
    for pattern in "${enhanced_error_patterns[@]}"; do
        if echo "$output" | grep -qi "$pattern"; then
            # Double-check this is not a usage limit message
            if ! echo "$output" | grep -qiE "(usage limit|rate limit|blocked until|try again|wait until)"; then
                log_debug "Enhanced error pattern matched: $pattern"
                return 0
            fi
        fi
    done
    
    return 1
}

# Execute GitHub issue task
execute_github_issue_task() {
    local session_id="$1"
    local task_id="$2"
    local task_data="$3"
    
    local issue_number repo_url issue_url
    if has_command jq; then
        issue_number=$(echo "$task_data" | jq -r '.issue_number // ""')
        repo_url=$(echo "$task_data" | jq -r '.repo_url // ""')
        issue_url=$(echo "$task_data" | jq -r '.issue_url // ""')
    else
        issue_number=$(echo "$task_data" | grep -o '"issue_number"[^,]*' | sed 's/.*"\([^"]*\)".*/\1/' || echo "")
        repo_url=""
        issue_url=""
    fi
    
    if [[ -z "$issue_number" ]]; then
        log_error "GitHub issue task missing issue_number"
        echo "false"
        return 1
    fi
    
    log_info "Executing GitHub issue task: #$issue_number"
    
    # Send command to Claude session to process the GitHub issue
    local command="/dev $issue_number"
    if ! execute_command_in_session "$session_id" "$command"; then
        log_error "Failed to send GitHub issue command to session"
        echo "false"
        return 1
    fi
    
    # Monitor task execution with enhanced usage limit detection
    if monitor_task_execution "$session_id" "$task_id" "github_issue"; then
        echo "true"
        return 0
    else
        local exit_code=$?
        echo "false"
        return $exit_code
    fi
}

# Execute GitHub PR task
execute_github_pr_task() {
    local session_id="$1"
    local task_id="$2"
    local task_data="$3"
    
    local pr_number repo_url pr_url
    if has_command jq; then
        pr_number=$(echo "$task_data" | jq -r '.pr_number // ""')
        repo_url=$(echo "$task_data" | jq -r '.repo_url // ""')
        pr_url=$(echo "$task_data" | jq -r '.pr_url // ""')
    else
        pr_number=$(echo "$task_data" | grep -o '"pr_number"[^,]*' | sed 's/.*"\([^"]*\)".*/\1/' || echo "")
        repo_url=""
        pr_url=""
    fi
    
    if [[ -z "$pr_number" ]]; then
        log_error "GitHub PR task missing pr_number"
        echo "false"
        return 1
    fi
    
    log_info "Executing GitHub PR task: #$pr_number"
    
    # Send command to Claude session to process the GitHub PR
    local command="/dev pr:$pr_number"
    if ! execute_command_in_session "$session_id" "$command"; then
        log_error "Failed to send GitHub PR command to session"
        echo "false"
        return 1
    fi
    
    # Monitor task execution with enhanced usage limit detection
    if monitor_task_execution "$session_id" "$task_id" "github_pr"; then
        echo "true"
        return 0
    else
        local exit_code=$?
        echo "false"
        return $exit_code
    fi
}

# Execute custom task
execute_custom_task() {
    local session_id="$1"
    local task_id="$2"
    local task_data="$3"
    
    local command description
    if has_command jq; then
        command=$(echo "$task_data" | jq -r '.command // .description // ""')
        description=$(echo "$task_data" | jq -r '.description // .command // ""')
    else
        command=$(echo "$task_data" | grep -o '"command"[^,]*' | sed 's/.*"\([^"]*\)".*/\1/' || echo "")
        description=$(echo "$task_data" | grep -o '"description"[^,]*' | sed 's/.*"\([^"]*\)".*/\1/' || echo "")
    fi
    
    if [[ -z "$command" && -z "$description" ]]; then
        log_error "Custom task missing both command and description"
        echo "false"
        return 1
    fi
    
    local task_command="${command:-$description}"
    log_info "Executing custom task: $task_command"
    
    # Send command to Claude session
    if ! execute_command_in_session "$session_id" "$task_command"; then
        log_error "Failed to send custom command to session"
        echo "false"
        return 1
    fi
    
    # Monitor task execution with enhanced usage limit detection
    if monitor_task_execution "$session_id" "$task_id" "custom"; then
        echo "true"
        return 0
    else
        local exit_code=$?
        echo "false"
        return $exit_code
    fi
}

# Execute command in Claude session
execute_command_in_session() {
    local session_id="$1"
    local command="$2"
    
    log_debug "Sending command to session $session_id: $command"
    
    # Use claunch to send command to session
    if declare -f send_command_to_session >/dev/null 2>&1; then
        if send_command_to_session "$session_id" "$command"; then
            log_debug "Command sent successfully to session"
            return 0
        else
            log_error "Failed to send command via session manager"
            return 1
        fi
    fi
    
    # Fallback: direct claunch execution
    if has_command claunch; then
        if echo "$command" | claunch send "$session_id" 2>/dev/null; then
            log_debug "Command sent via direct claunch"
            return 0
        else
            log_error "Failed to send command via direct claunch"
            return 1
        fi
    fi
    
    log_error "No method available to send command to session"
    return 1
}

# Monitor task execution with enhanced usage limit detection and real-time progress
monitor_task_execution() {
    local session_id="$1"
    local task_id="$2"
    local task_type="$3"
    local max_wait_time="${4:-1800}"  # Default 30 minutes max
    
    log_debug "Monitoring execution of task $task_id (type: $task_type, max_wait: ${max_wait_time}s)"
    
    local start_time=$(date +%s)
    local last_activity_time=$start_time
    local check_interval=10  # Check every 10 seconds
    local activity_timeout=300  # 5 minutes without activity = timeout
    local consecutive_checks=0
    local max_consecutive_checks=$((max_wait_time / check_interval))
    
    while [[ $consecutive_checks -lt $max_consecutive_checks ]]; do
        ((consecutive_checks++))
        local current_time=$(date +%s)
        local elapsed_time=$((current_time - start_time))
        
        log_debug "Task monitoring cycle $consecutive_checks/$max_consecutive_checks (elapsed: ${elapsed_time}s)"
        
        # Get session output for analysis
        local session_output
        if session_output=$(get_session_output "$session_id" 2>/dev/null); then
            
            # Check for usage limit with enhanced detection
            if detect_usage_limit_in_queue "$session_output" "$task_id"; then
                log_warn "Enhanced usage limit detected during task execution - initiating intelligent pause"
                
                # Use enhanced pause function with live countdown
                if pause_queue_for_usage_limit_enhanced "" "$task_id" "time_specific_limit_enhanced"; then
                    log_info "Enhanced usage limit handling completed - task will resume automatically"
                    return 42  # Special exit code for usage limit
                else
                    log_error "Failed to execute enhanced usage limit handling"
                    return 1
                fi
            fi
            
            # Check for task completion indicators
            if check_task_completion_indicators "$session_output" "$task_type"; then
                log_info "Task completion detected for $task_id"
                return 0
            fi
            
            # Check for error indicators
            if check_task_error_indicators "$session_output"; then
                log_warn "Task error indicators detected for $task_id"
                return 1
            fi
            
            # Update last activity time if there's new content
            if [[ -n "$session_output" ]]; then
                last_activity_time=$current_time
            fi
        fi
        
        # Check for activity timeout
        local time_since_activity=$((current_time - last_activity_time))
        if [[ $time_since_activity -gt $activity_timeout ]]; then
            log_warn "Task $task_id appears inactive (${time_since_activity}s without activity)"
            return 1
        fi
        
        # Real-time progress reporting
        if [[ $((consecutive_checks % 6)) -eq 0 ]]; then  # Every 60 seconds
            local remaining_time=$((max_wait_time - elapsed_time))
            log_info "Task $task_id monitoring: ${elapsed_time}s elapsed, ${remaining_time}s remaining"
        fi
        
        sleep $check_interval
    done
    
    log_warn "Task execution monitoring timeout reached for $task_id"
    return 1
}

# Check for task completion indicators in session output
check_task_completion_indicators() {
    local output="$1"
    local task_type="$2"
    
    # Common completion patterns
    local completion_patterns=(
        "task.*completed"
        "successfully.*finished"
        "done.*processing"
        "completed.*successfully"
        "finished.*task"
        "pull request.*created"
        "commit.*created"
        "issue.*resolved"
        "implementation.*complete"
    )
    
    # Task-type-specific patterns
    case "$task_type" in
        "github_issue")
            completion_patterns+=(
                "issue.*implemented"
                "branch.*created"
                "changes.*committed"
            )
            ;;
        "github_pr")
            completion_patterns+=(
                "pr.*reviewed"
                "pull request.*analyzed"
                "merge.*ready"
            )
            ;;
    esac
    
    # Check for completion patterns
    for pattern in "${completion_patterns[@]}"; do
        if echo "$output" | grep -qi "$pattern"; then
            log_debug "Task completion pattern matched: $pattern"
            return 0
        fi
    done
    
    return 1
}

# Check for task error indicators in session output
check_task_error_indicators() {
    local output="$1"
    
    local error_patterns=(
        "error.*occurred"
        "failed.*to"
        "could.*not"
        "unable.*to"
        "exception.*occurred"
        "fatal.*error"
        "command.*not.*found"
        "permission.*denied"
    )
    
    # Check for error patterns
    for pattern in "${error_patterns[@]}"; do
        if echo "$output" | grep -qi "$pattern"; then
            log_debug "Task error pattern matched: $pattern"
            return 0
        fi
    done
    
    return 1
}

# Get session output for monitoring
get_session_output() {
    local session_id="$1"
    local lines="${2:-100}"  # Increased default for better monitoring
    
    if declare -f get_session_recent_output >/dev/null 2>&1; then
        get_session_recent_output "$session_id" "$lines"
    elif has_command claunch; then
        # Enhanced claunch output retrieval with error handling
        if claunch logs "$session_id" --lines="$lines" 2>/dev/null; then
            return 0
        else
            log_debug "Failed to get session output via claunch for session $session_id"
            return 1
        fi
    else
        log_debug "No method available to get session output"
        return 1
    fi
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
        
        # Try Claude CLI limit check with error handling
        if claude_output=$(timeout 30 claude --help 2>&1); then
            local exit_code=$?
            
            if [[ $exit_code -eq 124 ]]; then
                log_warn "Claude CLI timeout during limit check"
                return 2
            fi
            
            # Comprehensive usage limit pattern detection
            local limit_patterns=(
                "Claude AI usage limit reached"
                "usage limit reached"
                "rate limit"
                "too many requests"
                "please try again later"
                "request limit exceeded"
                "quota exceeded"
                "temporarily unavailable"
                "service temporarily overloaded"
                "try again at [0-9]\+[ap]m"
                "try again after [0-9]\+[ap]m"
                "come back at [0-9]\+[ap]m"
                "available again at [0-9]\+[ap]m"
                "reset at [0-9]\+[ap]m"
                "limit resets at [0-9]\+[ap]m"
                "wait until [0-9]\+[ap]m"
                "blocked until [0-9]\+[ap]m"
            )
            
            local pattern_found=""
            for pattern in "${limit_patterns[@]}"; do
                if echo "$claude_output" | grep -iq "$pattern"; then
                    pattern_found="$pattern"
                    log_info "Usage limit detected via pattern: $pattern_found"
                    limit_detected=true
                    break
                fi
            done
            
            if [[ "$limit_detected" == "true" ]]; then
                # Enhanced timestamp extraction for pm/am patterns
                local extracted_timestamp=""
                
                # Try to extract pm/am time patterns
                local time_match
                if time_match=$(echo "$claude_output" | grep -io "[0-9]\+[ap]m" | head -1); then
                    log_debug "Extracted time pattern: $time_match"
                    
                    # Convert pm/am to 24h timestamp
                    local hour_part="${time_match%[ap]m}"
                    local ampm_part="${time_match: -2}"
                    
                    # Convert to 24h format
                    if [[ "$ampm_part" == "pm" && "$hour_part" -ne 12 ]]; then
                        hour_part=$((hour_part + 12))
                    elif [[ "$ampm_part" == "am" && "$hour_part" -eq 12 ]]; then
                        hour_part=0
                    fi
                    
                    # Calculate next occurrence of this time today or tomorrow
                    local target_time
                    target_time=$(date -d "today ${hour_part}:00" +%s 2>/dev/null || date -j -f "%H:%M" "${hour_part}:00" +%s 2>/dev/null)
                    local current_time=$(date +%s)
                    
                    if [[ $target_time -le $current_time ]]; then
                        # If time has passed today, set for tomorrow
                        target_time=$(date -d "tomorrow ${hour_part}:00" +%s 2>/dev/null || date -j -v+1d -f "%H:%M" "${hour_part}:00" +%s 2>/dev/null)
                    fi
                    
                    extracted_timestamp="$target_time"
                    log_debug "Calculated resume timestamp: $extracted_timestamp"
                fi
                
                # Fallback: try to extract raw timestamp
                if [[ -z "$extracted_timestamp" ]]; then
                    extracted_timestamp=$(echo "$claude_output" | grep -o '[0-9]\{10,\}' | head -1 || echo "")
                fi
                
                if [[ -n "$extracted_timestamp" && "$extracted_timestamp" =~ ^[0-9]+$ ]]; then
                    resume_timestamp="$extracted_timestamp"
                    log_debug "Using extracted timestamp: $extracted_timestamp"
                else
                    # Standard-Wartezeit falls kein Timestamp verfügbar
                    resume_timestamp=$(date -d "+${USAGE_LIMIT_COOLDOWN:-300} seconds" +%s 2>/dev/null || date -v+"${USAGE_LIMIT_COOLDOWN:-300}"S +%s 2>/dev/null || echo $(($(date +%s) + ${USAGE_LIMIT_COOLDOWN:-300})))
                    log_debug "Using default cooldown: ${USAGE_LIMIT_COOLDOWN:-300}s"
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
    log_info "  Enhanced usage limits: ${ENHANCED_USAGE_LIMITS:-false}"
    
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
    --enhanced-usage-limits  Enable enhanced usage limit detection with live countdown
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
            --enhanced-usage-limits)
                ENHANCED_USAGE_LIMITS=true
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
    # Note: Cannot use logging functions yet - dependencies not loaded
    echo "[INFO] Hybrid Claude Monitor v$VERSION starting up"
    
    # Parse Kommandozeilen-Argumente first (no dependencies needed)
    parse_arguments "$@"
    
    # CRITICAL FIX: Load dependencies BEFORE trying to load configuration
    # This ensures config-loader.sh is sourced before load_system_config() is called
    load_dependencies
    
    # Now logging functions are available
    log_debug "Script directory: $SCRIPT_DIR"
    log_debug "Working directory: $WORKING_DIR"
    
    # Load configuration (now dependencies are available)
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