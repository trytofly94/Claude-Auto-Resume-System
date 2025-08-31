#!/usr/bin/env bash

# Claude Auto-Resume - Session Manager
# Session-Lifecycle-Management für das Claude Auto-Resume System
# Version: 1.0.0-alpha
# Letzte Aktualisierung: 2025-08-05

set -euo pipefail

# ===============================================================================
# GLOBALE VARIABLEN UND KONSTANTEN
# ===============================================================================

# Standard-Konfiguration (wird von config/default.conf überschrieben)
MAX_RESTARTS="${MAX_RESTARTS:-50}"
SESSION_RESTART_DELAY="${SESSION_RESTART_DELAY:-10}"
HEALTH_CHECK_ENABLED="${HEALTH_CHECK_ENABLED:-true}"
HEALTH_CHECK_INTERVAL="${HEALTH_CHECK_INTERVAL:-60}"
HEALTH_CHECK_TIMEOUT="${HEALTH_CHECK_TIMEOUT:-30}"
AUTO_RECOVERY_ENABLED="${AUTO_RECOVERY_ENABLED:-true}"
RECOVERY_DELAY="${RECOVERY_DELAY:-30}"
MAX_RECOVERY_ATTEMPTS="${MAX_RECOVERY_ATTEMPTS:-3}"

# Session-State-Tracking
# Arrays will be initialized via init_session_arrays() when needed
# This prevents issues with sourcing contexts and scope problems
SESSIONS_INITIALIZED=false

# Session-Status-Konstanten
# Protect against re-sourcing - only declare readonly if not already set
if [[ -z "${SESSION_STATE_UNKNOWN:-}" ]]; then
    readonly SESSION_STATE_UNKNOWN="unknown"
    readonly SESSION_STATE_STARTING="starting"
    readonly SESSION_STATE_RUNNING="running"
    readonly SESSION_STATE_USAGE_LIMITED="usage_limited"
    readonly SESSION_STATE_ERROR="error"
    readonly SESSION_STATE_STOPPED="stopped"
    readonly SESSION_STATE_RECOVERING="recovering"
fi

# ===============================================================================
# HILFSFUNKTIONEN UND DEPENDENCIES
# ===============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Lade Utility-Module
if [[ -f "$SCRIPT_DIR/utils/logging.sh" ]]; then
    source "$SCRIPT_DIR/utils/logging.sh"
else
    log_debug() { echo "[DEBUG] $*" >&2; }
    log_info() { echo "[INFO] $*" >&2; }
    log_warn() { echo "[WARN] $*" >&2; }
    log_error() { echo "[ERROR] $*" >&2; }
fi

if [[ -f "$SCRIPT_DIR/utils/network.sh" ]]; then
    source "$SCRIPT_DIR/utils/network.sh"
fi

if [[ -f "$SCRIPT_DIR/claunch-integration.sh" ]]; then
    source "$SCRIPT_DIR/claunch-integration.sh"
fi

# Prüfe ob Kommando verfügbar ist
has_command() {
    command -v "$1" >/dev/null 2>&1
}

# Generiere Session-ID
generate_session_id() {
    local project_name="$1"
    local timestamp=$(date +%s)
    echo "${project_name}-${timestamp}-$$"
}

# ===============================================================================
# ARRAY INITIALIZATION AND VALIDATION
# ===============================================================================

# Bulletproof array initialization
init_session_arrays() {
    log_debug "Initializing session management arrays"
    
    # Use declare -gA for global associative arrays
    # This ensures arrays are available globally when sourced
    declare -gA SESSIONS 2>/dev/null || true
    declare -gA SESSION_STATES 2>/dev/null || true  
    declare -gA SESSION_RESTART_COUNTS 2>/dev/null || true
    declare -gA SESSION_RECOVERY_COUNTS 2>/dev/null || true
    declare -gA SESSION_LAST_SEEN 2>/dev/null || true
    
    # Verify successful initialization  
    if ! declare -p SESSIONS >/dev/null 2>&1; then
        log_error "CRITICAL: Failed to declare SESSIONS array"
        return 1
    fi
    
    # Initialize with empty state if not already set
    # Use safer array length check to avoid nounset errors
    local session_count=0
    set +u  # Temporarily disable nounset for array access
    if declare -p SESSIONS >/dev/null 2>&1; then
        session_count=${#SESSIONS[@]}
    fi
    set -u  # Re-enable nounset
    
    if [[ $session_count -eq 0 ]]; then
        log_debug "SESSIONS array initialized (empty state)"
    else
        log_debug "SESSIONS array already contains $session_count entries"
    fi
    
    log_info "Session arrays initialized successfully"
    return 0
}

# Comprehensive array validation function
validate_session_arrays() {
    local errors=0
    
    # Check each required array
    for array_name in SESSIONS SESSION_STATES SESSION_RESTART_COUNTS SESSION_RECOVERY_COUNTS SESSION_LAST_SEEN; do
        if ! declare -p "$array_name" >/dev/null 2>&1; then
            log_error "Array $array_name is not declared"
            ((errors++))
        else
            log_debug "Array $array_name is properly declared"
        fi
    done
    
    if [[ $errors -gt 0 ]]; then
        log_error "Found $errors array declaration errors"
        return 1
    fi
    
    log_debug "All session arrays are properly validated"
    return 0
}

# Safe array access wrapper
safe_array_get() {
    local array_name="$1"
    local key="$2"
    local default_value="${3:-}"
    
    # Ensure array exists
    if ! declare -p "$array_name" >/dev/null 2>&1; then
        echo "$default_value"
        return 1
    fi
    
    # Access array value safely
    local -n array_ref="$array_name"
    echo "${array_ref[$key]:-$default_value}"
}

# Ensure arrays are initialized before access
ensure_arrays_initialized() {
    if [[ "$SESSIONS_INITIALIZED" != "true" ]]; then
        log_debug "Arrays not initialized, calling init_session_arrays"
        init_session_arrays || return 1
        SESSIONS_INITIALIZED=true
    fi
}

# ===============================================================================
# SESSION-STATE-MANAGEMENT
# ===============================================================================

# Registriere neue Session
register_session() {
    local session_id="$1"
    local project_name="$2"
    local working_dir="$3"
    
    log_info "Registering new session: $session_id"
    
    # CRITICAL FIX: Ensure arrays are initialized before access
    if ! declare -p SESSIONS >/dev/null 2>&1; then
        log_warn "SESSIONS array not declared, initializing now"
        init_session_arrays || {
            log_error "Failed to initialize session arrays"
            return 1
        }
    fi
    
    # Validate parameters
    if [[ -z "$session_id" ]] || [[ -z "$project_name" ]] || [[ -z "$working_dir" ]]; then
        log_error "Invalid parameters for session registration"
        return 1
    fi
    
    # Defensive array access with error handling
    SESSIONS["$session_id"]="$project_name:$working_dir" || {
        log_error "Failed to register session in SESSIONS array"
        return 1
    }
    
    SESSION_STATES["$session_id"]="$SESSION_STATE_STARTING" || {
        log_error "Failed to set session state"
        return 1  
    }
    
    SESSION_RESTART_COUNTS["$session_id"]=0
    SESSION_RECOVERY_COUNTS["$session_id"]=0
    SESSION_LAST_SEEN["$session_id"]=$(date +%s)
    
    log_debug "Session registered: $session_id -> ${SESSIONS[$session_id]}"
    return 0
}

# Aktualisiere Session-Status
update_session_state() {
    local session_id="$1"
    local new_state="$2"
    local details="${3:-}"
    
    # Ensure arrays are initialized
    ensure_arrays_initialized || return 1
    
    local old_state="${SESSION_STATES[$session_id]:-$SESSION_STATE_UNKNOWN}"
    
    if [[ "$old_state" != "$new_state" ]]; then
        log_info "Session $session_id state change: $old_state -> $new_state"
        [[ -n "$details" ]] && log_debug "State change details: $details"
        
        SESSION_STATES["$session_id"]="$new_state"
        SESSION_LAST_SEEN["$session_id"]=$(date +%s)
        
        # Log Session-Event
        if declare -f log_session_event >/dev/null 2>&1; then
            log_session_event "$session_id" "state_change" "$old_state -> $new_state"
        fi
    fi
}

# Hole Session-Informationen
get_session_info() {
    local session_id="$1"
    
    # Ensure arrays are initialized
    ensure_arrays_initialized || return 1
    
    if [[ -z "${SESSIONS[$session_id]:-}" ]]; then
        return 1
    fi
    
    local project_and_dir="${SESSIONS[$session_id]}"
    local project_name="${project_and_dir%%:*}"
    local working_dir="${project_and_dir#*:}"
    local state="${SESSION_STATES[$session_id]:-$SESSION_STATE_UNKNOWN}"
    local restart_count="${SESSION_RESTART_COUNTS[$session_id]:-0}"
    local recovery_count="${SESSION_RECOVERY_COUNTS[$session_id]:-0}"
    local last_seen="${SESSION_LAST_SEEN[$session_id]:-0}"
    
    echo "SESSION_ID=$session_id"
    echo "PROJECT_NAME=$project_name"
    echo "WORKING_DIR=$working_dir"
    echo "STATE=$state"
    echo "RESTART_COUNT=$restart_count"
    echo "RECOVERY_COUNT=$recovery_count"
    echo "LAST_SEEN=$last_seen"
}

# Liste alle Sessions
list_sessions() {
    echo "=== Active Sessions ==="
    
    # Ensure SESSIONS array is initialized globally
    if ! declare -p SESSIONS >/dev/null 2>&1; then
        declare -gA SESSIONS
        declare -gA SESSION_STATES  
        declare -gA SESSION_RESTART_COUNTS
        declare -gA SESSION_RECOVERY_COUNTS
        declare -gA SESSION_LAST_SEEN
    fi
    
    # Use safer array length check to avoid nounset errors
    local session_count=0
    set +u  # Temporarily disable nounset for array access
    if declare -p SESSIONS >/dev/null 2>&1; then
        session_count=${#SESSIONS[@]}
    fi
    set -u  # Re-enable nounset
    
    if [[ $session_count -eq 0 ]]; then
        echo "No sessions registered"
        return 0
    fi
    
    for session_id in "${!SESSIONS[@]}"; do
        local project_and_dir="${SESSIONS[$session_id]}"
        local project_name="${project_and_dir%%:*}"
        local state="${SESSION_STATES[$session_id]:-$SESSION_STATE_UNKNOWN}"
        local restart_count="${SESSION_RESTART_COUNTS[$session_id]:-0}"
        local last_seen="${SESSION_LAST_SEEN[$session_id]:-0}"
        local age=$(($(date +%s) - last_seen))
        
        printf "%-20s %-15s %-10s %3d restarts %3ds ago\n" \
               "$session_id" "$project_name" "$state" "$restart_count" "$age"
    done
}

# Bereinige Sessions
cleanup_sessions() {
    local max_age="${1:-3600}"  # 1 Stunde Standard
    
    log_debug "Cleaning up sessions older than ${max_age}s"
    
    local current_time=$(date +%s)
    local cleaned_count=0
    
    for session_id in "${!SESSIONS[@]}"; do
        local last_seen="${SESSION_LAST_SEEN[$session_id]:-0}"
        local age=$((current_time - last_seen))
        
        if [[ $age -gt $max_age ]]; then
            local state="${SESSION_STATES[$session_id]:-$SESSION_STATE_UNKNOWN}"
            
            if [[ "$state" == "$SESSION_STATE_STOPPED" ]] || [[ "$state" == "$SESSION_STATE_ERROR" ]]; then
                log_info "Cleaning up old session: $session_id (age: ${age}s, state: $state)"
                
                unset "SESSIONS[$session_id]"
                unset "SESSION_STATES[$session_id]"
                unset "SESSION_RESTART_COUNTS[$session_id]"
                unset "SESSION_RECOVERY_COUNTS[$session_id]"
                unset "SESSION_LAST_SEEN[$session_id]"
                
                ((cleaned_count++))
            fi
        fi
    done
    
    if [[ $cleaned_count -gt 0 ]]; then
        log_info "Cleaned up $cleaned_count old sessions"
    fi
}

# ===============================================================================
# HEALTH-CHECK-FUNKTIONEN
# ===============================================================================

# Führe Health-Check für Session durch
perform_health_check() {
    local session_id="$1"
    
    log_debug "Performing health check for session: $session_id"
    
    if [[ -z "${SESSIONS[$session_id]:-}" ]]; then
        log_error "Session not found: $session_id"
        return 1
    fi
    
    local project_and_dir="${SESSIONS[$session_id]}"
    local project_name="${project_and_dir%%:*}"
    
    # Methode 1: tmux-Session-Check
    if [[ "$CLAUNCH_MODE" == "tmux" ]]; then
        local tmux_session_name="${TMUX_SESSION_PREFIX}-${project_name}"
        
        if tmux has-session -t "$tmux_session_name" 2>/dev/null; then
            # Prüfe ob Session aktiv ist (nicht suspended)
            local session_info
            session_info=$(tmux display-message -t "$tmux_session_name" -p "#{session_attached}")
            
            if [[ "$session_info" -gt 0 ]]; then
                update_session_state "$session_id" "$SESSION_STATE_RUNNING" "tmux session active"
                return 0
            else
                update_session_state "$session_id" "$SESSION_STATE_RUNNING" "tmux session detached but alive"
                return 0
            fi
        else
            update_session_state "$session_id" "$SESSION_STATE_STOPPED" "tmux session not found"
            return 1
        fi
    fi
    
    # Methode 2: Session-Datei-Check
    local session_file="$HOME/.claude_session_${project_name}"
    if [[ -f "$session_file" ]]; then
        local stored_session_id
        stored_session_id=$(cat "$session_file" 2>/dev/null || echo "")
        
        if [[ -n "$stored_session_id" ]]; then
            update_session_state "$session_id" "$SESSION_STATE_RUNNING" "session file exists"
            return 0
        fi
    fi
    
    update_session_state "$session_id" "$SESSION_STATE_STOPPED" "no active session found"
    return 1
}

# Erkenne Usage-Limit-Status
detect_usage_limit() {
    local session_id="$1"
    
    log_debug "Checking for usage limits in session: $session_id"
    
    if [[ -z "${SESSIONS[$session_id]:-}" ]]; then
        return 1
    fi
    
    local project_and_dir="${SESSIONS[$session_id]}"
    local project_name="${project_and_dir%%:*}"
    
    # Prüfe tmux-Session-Output auf Usage-Limit-Meldungen
    if [[ "$CLAUNCH_MODE" == "tmux" ]]; then
        local tmux_session_name="${TMUX_SESSION_PREFIX}-${project_name}"
        
        if tmux has-session -t "$tmux_session_name" 2>/dev/null; then
            local session_output
            session_output=$(tmux capture-pane -t "$tmux_session_name" -p 2>/dev/null || echo "")
            
            if echo "$session_output" | grep -q "Claude AI usage limit reached\|usage limit reached"; then
                log_info "Usage limit detected in session: $session_id"
                update_session_state "$session_id" "$SESSION_STATE_USAGE_LIMITED" "usage limit detected in output"
                return 0
            fi
        fi
    fi
    
    # Alternative: Teste Claude CLI direkt
    local test_output
    if test_output=$(timeout "$HEALTH_CHECK_TIMEOUT" claude -p 'check' 2>&1); then
        if echo "$test_output" | grep -q "Claude AI usage limit reached\|usage limit reached"; then
            log_info "Usage limit detected via direct CLI test"
            update_session_state "$session_id" "$SESSION_STATE_USAGE_LIMITED" "usage limit detected via CLI"
            return 0
        fi
    fi
    
    return 1
}

# ===============================================================================
# RECOVERY-FUNKTIONEN
# ===============================================================================

# Führe Session-Recovery durch
perform_session_recovery() {
    local session_id="$1"
    local recovery_type="${2:-auto}"
    
    log_info "Starting session recovery: $session_id (type: $recovery_type)"
    
    if [[ -z "${SESSIONS[$session_id]:-}" ]]; then
        log_error "Cannot recover unknown session: $session_id"
        return 1
    fi
    
    # Prüfe Recovery-Limits
    local recovery_count="${SESSION_RECOVERY_COUNTS[$session_id]:-0}"
    if [[ $recovery_count -ge $MAX_RECOVERY_ATTEMPTS ]]; then
        log_error "Maximum recovery attempts reached for session: $session_id"
        update_session_state "$session_id" "$SESSION_STATE_ERROR" "max recovery attempts reached"
        return 1
    fi
    
    update_session_state "$session_id" "$SESSION_STATE_RECOVERING" "recovery attempt $((recovery_count + 1))"
    SESSION_RECOVERY_COUNTS["$session_id"]=$((recovery_count + 1))
    
    local project_and_dir="${SESSIONS[$session_id]}"
    local project_name="${project_and_dir%%:*}"
    local working_dir="${project_and_dir#*:}"
    
    # Recovery-Strategie basierend auf aktuellem Zustand
    local current_state="${SESSION_STATES[$session_id]:-$SESSION_STATE_UNKNOWN}"
    
    case "$current_state" in
        "$SESSION_STATE_USAGE_LIMITED")
            recover_from_usage_limit "$session_id"
            ;;
        "$SESSION_STATE_STOPPED")
            recover_stopped_session "$session_id" "$working_dir"
            ;;
        "$SESSION_STATE_ERROR")
            recover_error_session "$session_id" "$working_dir"
            ;;
        *)
            log_warn "No specific recovery strategy for state: $current_state"
            generic_session_recovery "$session_id" "$working_dir"
            ;;
    esac
}

# Recovery von Usage-Limit
recover_from_usage_limit() {
    local session_id="$1"
    
    log_info "Recovering from usage limit: $session_id"
    
    local project_and_dir="${SESSIONS[$session_id]}"
    local project_name="${project_and_dir%%:*}"
    
    # Sende Recovery-Kommando an Session
    if [[ "$CLAUNCH_MODE" == "tmux" ]]; then
        local tmux_session_name="${TMUX_SESSION_PREFIX}-${project_name}"
        
        if tmux has-session -t "$tmux_session_name" 2>/dev/null; then
            log_info "Sending recovery command to session: $session_id"
            tmux send-keys -t "$tmux_session_name" "/dev bitte mach weiter" Enter
            
            # Warte auf Recovery
            sleep "$RECOVERY_DELAY"
            
            # Prüfe ob Recovery erfolgreich war
            if ! detect_usage_limit "$session_id"; then
                log_info "Usage limit recovery successful: $session_id"
                update_session_state "$session_id" "$SESSION_STATE_RUNNING" "recovered from usage limit"
                SESSION_RECOVERY_COUNTS["$session_id"]=0  # Reset bei erfolgreichem Recovery
                return 0
            else
                log_warn "Usage limit recovery failed: $session_id"
                return 1
            fi
        fi
    fi
    
    log_error "Cannot send recovery command - no active tmux session"
    return 1
}

# ===============================================================================
# CONTEXT CLEARING FUNCTIONS (Issue #93)
# ===============================================================================

# Send context clear command to a session
# This function sends the /clear command to Claude via tmux send-keys
send_context_clear_command() {
    local session_name="$1"
    local wait_seconds="${2:-${QUEUE_CONTEXT_CLEAR_WAIT:-2}}"
    
    if [[ -z "$session_name" ]]; then
        log_error "send_context_clear_command: session_name parameter required"
        return 1
    fi
    
    log_info "Clearing context for session: $session_name"
    
    # Check if this is a tmux session or session ID  
    if [[ "$CLAUNCH_MODE" == "tmux" ]]; then
        local tmux_session_name
        
        # If it looks like a session ID, convert to tmux session name
        if [[ "$session_name" =~ ^sess- ]]; then
            # Extract project name from session data
            local project_and_dir="${SESSIONS[$session_name]:-}"
            if [[ -n "$project_and_dir" ]]; then
                local project_name="${project_and_dir%%:*}"
                tmux_session_name="${TMUX_SESSION_PREFIX}-${project_name}"
            else
                log_error "Cannot find project name for session ID: $session_name"
                return 1
            fi
        else
            # Assume it's already a tmux session name
            tmux_session_name="$session_name"
        fi
        
        if tmux has-session -t "$tmux_session_name" 2>/dev/null; then
            log_debug "Sending /clear command to tmux session: $tmux_session_name"
            
            # Send the /clear command
            if tmux send-keys -t "$tmux_session_name" '/clear' C-m 2>/dev/null; then
                log_debug "Context clear command sent, waiting ${wait_seconds}s for completion"
                sleep "$wait_seconds"
                log_info "Context cleared for session: $session_name"
                return 0
            else
                log_error "Failed to send context clear command to session: $tmux_session_name"
                return 1
            fi
        else
            log_warn "tmux session not found, cannot clear context: $tmux_session_name"
            return 1
        fi
    else
        log_warn "Context clearing only supported in tmux mode, current mode: ${CLAUNCH_MODE:-direct}"
        return 1
    fi
}

# Check if context clearing is supported for the current session
is_context_clearing_supported() {
    local session_id="$1"
    
    # Context clearing requires tmux mode
    if [[ "$CLAUNCH_MODE" != "tmux" ]]; then
        return 1
    fi
    
    # Session must exist and be active
    if [[ -z "${SESSIONS[$session_id]:-}" ]]; then
        return 1
    fi
    
    # Extract tmux session name and check if it exists
    local project_and_dir="${SESSIONS[$session_id]}"
    local project_name="${project_and_dir%%:*}"
    local tmux_session_name="${TMUX_SESSION_PREFIX}-${project_name}"
    
    tmux has-session -t "$tmux_session_name" 2>/dev/null
}

# Recovery gestoppter Session
recover_stopped_session() {
    local session_id="$1"
    local working_dir="$2"
    
    log_info "Recovering stopped session: $session_id"
    
    # Prüfe Restart-Limits
    local restart_count="${SESSION_RESTART_COUNTS[$session_id]:-0}"
    if [[ $restart_count -ge $MAX_RESTARTS ]]; then
        log_error "Maximum restarts reached for session: $session_id"
        update_session_state "$session_id" "$SESSION_STATE_ERROR" "max restarts reached"
        return 1
    fi
    
    SESSION_RESTART_COUNTS["$session_id"]=$((restart_count + 1))
    
    # Warte vor Neustart
    if [[ $SESSION_RESTART_DELAY -gt 0 ]]; then
        log_debug "Waiting ${SESSION_RESTART_DELAY}s before session restart"
        sleep "$SESSION_RESTART_DELAY"
    fi
    
    # Starte Session neu
    if declare -f start_claunch_session >/dev/null 2>&1; then
        cd "$working_dir"
        if start_claunch_session "$working_dir" "continue"; then
            log_info "Session restart successful: $session_id"
            update_session_state "$session_id" "$SESSION_STATE_RUNNING" "restarted successfully"
            SESSION_RECOVERY_COUNTS["$session_id"]=0
            return 0
        else
            log_error "Session restart failed: $session_id"
            update_session_state "$session_id" "$SESSION_STATE_ERROR" "restart failed"
            return 1
        fi
    else
        log_error "claunch integration not available for restart"
        return 1
    fi
}

# Recovery bei Fehlern
recover_error_session() {
    local session_id="$1"
    local working_dir="$2"
    
    log_info "Recovering error session: $session_id"
    
    # Bereinige potentiell korrupte Session-Dateien
    local project_and_dir="${SESSIONS[$session_id]}"
    local project_name="${project_and_dir%%:*}"
    local session_file="$HOME/.claude_session_${project_name}"
    
    if [[ -f "$session_file" ]]; then
        log_debug "Removing potentially corrupt session file: $session_file"
        rm -f "$session_file"
    fi
    
    # Versuche Clean-Restart
    recover_stopped_session "$session_id" "$working_dir"
}

# Generische Recovery
generic_session_recovery() {
    local session_id="$1"
    local working_dir="$2"
    
    log_info "Performing generic recovery: $session_id"
    
    # Erst Health-Check versuchen
    if perform_health_check "$session_id"; then
        log_info "Session is actually healthy: $session_id"
        return 0
    fi
    
    # Dann Standard-Recovery
    recover_stopped_session "$session_id" "$working_dir"
}

# ===============================================================================
# MONITORING-LOOP
# ===============================================================================

# Kontinuierliches Monitoring aller Sessions
monitor_sessions() {
    local check_interval="${1:-$HEALTH_CHECK_INTERVAL}"
    
    log_info "Starting session monitoring (interval: ${check_interval}s)"
    
    while true; do
        log_debug "Performing session health checks"
        
        # Health-Check für alle aktiven Sessions
        for session_id in "${!SESSIONS[@]}"; do
            local current_state="${SESSION_STATES[$session_id]:-$SESSION_STATE_UNKNOWN}"
            
            # Überspringe Sessions, die bereits in Recovery sind
            if [[ "$current_state" == "$SESSION_STATE_RECOVERING" ]]; then
                continue
            fi
            
            # Führe Health-Check durch
            if ! perform_health_check "$session_id"; then
                log_warn "Health check failed for session: $session_id"
                
                # Auto-Recovery falls aktiviert
                if [[ "$AUTO_RECOVERY_ENABLED" == "true" ]]; then
                    log_info "Starting automatic recovery for session: $session_id"
                    perform_session_recovery "$session_id" "auto"
                fi
            else
                # Prüfe auf Usage-Limits
                if detect_usage_limit "$session_id"; then
                    if [[ "$AUTO_RECOVERY_ENABLED" == "true" ]]; then
                        log_info "Starting automatic usage limit recovery: $session_id"
                        perform_session_recovery "$session_id" "usage_limit"
                    fi
                fi
            fi
        done
        
        # Session-Cleanup
        cleanup_sessions
        
        # Warte bis zum nächsten Check
        sleep "$check_interval"
    done
}

# ===============================================================================
# ÖFFENTLICHE API-FUNKTIONEN
# ===============================================================================

# Initialisiere Session-Manager
init_session_manager() {
    local config_file="${1:-config/default.conf}"
    
    log_info "Initializing session manager"
    
    # CRITICAL: Initialize arrays first
    if ! init_session_arrays; then
        log_error "Failed to initialize session arrays"
        return 1
    fi
    
    # Mark arrays as initialized
    SESSIONS_INITIALIZED=true
    
    # Validate array initialization  
    if ! validate_session_arrays; then
        log_error "Session array validation failed"
        return 1
    fi
    
    # Lade Konfiguration
    if [[ -f "$config_file" ]]; then
        while IFS='=' read -r key value; do
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$key" ]] && continue
            
            # Remove quotes from beginning and end
            value=${value#\"} 
            value=${value%\"}
            value=${value#\'} 
            value=${value%\'}
            
            case "$key" in
                MAX_RESTARTS|SESSION_RESTART_DELAY|HEALTH_CHECK_ENABLED|HEALTH_CHECK_INTERVAL|HEALTH_CHECK_TIMEOUT|AUTO_RECOVERY_ENABLED|RECOVERY_DELAY|MAX_RECOVERY_ATTEMPTS)
                    eval "$key='$value'"
                    ;;
            esac
        done < <(grep -E '^[^#]*=' "$config_file" || true)
        
        log_debug "Session manager configured from: $config_file"
    fi
    
    # Initialisiere claunch-Integration falls verfügbar
    if declare -f init_claunch_integration >/dev/null 2>&1; then
        init_claunch_integration "$config_file"
    fi
    
    log_info "Session manager initialized successfully"
}

# Starte verwaltete Session
start_managed_session() {
    local project_name="$1"
    local working_dir="$2"
    local use_new_terminal="${3:-false}"
    shift 3
    local claude_args=("$@")
    
    log_info "Starting managed session for project: $project_name"
    
    # Generiere Session-ID
    local session_id
    session_id=$(generate_session_id "$project_name")
    
    # Registriere Session
    register_session "$session_id" "$project_name" "$working_dir"
    
    # Starte Session über claunch-Integration
    if declare -f start_or_resume_session >/dev/null 2>&1; then
        if start_or_resume_session "$working_dir" "$use_new_terminal" "${claude_args[@]}"; then
            update_session_state "$session_id" "$SESSION_STATE_RUNNING" "session started successfully"
            echo "$session_id"  # Return session ID für Tracking
            return 0
        else
            update_session_state "$session_id" "$SESSION_STATE_ERROR" "failed to start session"
            return 1
        fi
    else
        log_error "claunch integration not available"
        update_session_state "$session_id" "$SESSION_STATE_ERROR" "claunch integration unavailable"
        return 1
    fi
}

# Stoppe verwaltete Session
stop_managed_session() {
    local session_id="$1"
    
    log_info "Stopping managed session: $session_id"
    
    if [[ -z "${SESSIONS[$session_id]:-}" ]]; then
        log_error "Session not found: $session_id"
        return 1
    fi
    
    local project_and_dir="${SESSIONS[$session_id]}"
    local project_name="${project_and_dir%%:*}"
    
    # Stoppe tmux-Session falls vorhanden
    if [[ "$CLAUNCH_MODE" == "tmux" ]]; then
        local tmux_session_name="${TMUX_SESSION_PREFIX}-${project_name}"
        
        if tmux has-session -t "$tmux_session_name" 2>/dev/null; then
            tmux kill-session -t "$tmux_session_name"
            log_info "tmux session terminated: $tmux_session_name"
        fi
    fi
    
    update_session_state "$session_id" "$SESSION_STATE_STOPPED" "stopped by user"
    return 0
}

# ===============================================================================
# ENHANCED SESSION DETECTION FUNCTIONS (für Setup Wizard)
# ===============================================================================

# Übergreifende Claude Session Detection für Setup Wizard
# 
# Diese Funktion implementiert eine mehrstufige Erkennungsstrategie für bestehende Claude-Sessions:
# 1. tmux-Sessions: Sucht nach aktiven tmux-Sessions mit Claude-bezogenen Namen
# 2. Session-Dateien: Prüft persistierte Session-IDs in bekannten Dateipfaden
# 3. Prozess-Baum: Analysiert laufende Prozesse auf Claude-Instanzen
# 4. Socket-Verbindungen: Heuristische Netzwerk-Analyse (experimentell)
#
# Die Methoden werden sequenziell ausgeführt und die erste erfolgreiche Detection
# bestimmt das Ergebnis. Dies ermöglicht robuste Erkennung auch bei partiellen
# System-Zuständen (z.B. tmux läuft aber Session-Datei fehlt).
#
# Rückgabe: 0 wenn Session gefunden, 1 wenn keine Session erkannt
detect_existing_claude_session() {
    log_debug "Starting comprehensive Claude session detection"
    
    # Definiere Detection-Methoden in Prioritätsreihenfolge
    # (von spezifischsten zu allgemeinsten)
    local detection_methods=(
        "check_tmux_sessions"        # Spezifisch: aktive tmux-Sessions
        "check_session_files"        # Spezifisch: persistierte Session-IDs
        "check_process_tree"         # Allgemein: laufende Claude-Prozesse
        "check_socket_connections"   # Heuristisch: Netzwerk-Verbindungen
    )
    
    for method in "${detection_methods[@]}"; do
        log_debug "Trying detection method: $method"
        
        if "$method"; then
            log_info "Claude session detected via $method"
            return 0
        fi
    done
    
    log_info "No existing Claude session detected"
    return 1
}

# Prüfe tmux-Sessions auf Claude-bezogene Sessions
#
# Implementiert eine zweistufige tmux-Session-Erkennung:
# 1. Exakte Übereinstimmung: Sucht nach dem erwarteten Session-Namen für das aktuelle Projekt
# 2. Pattern-Matching: Sucht nach Sessions mit Claude-relevanten Namensmustern
# 3. Content-Validation: Analysiert Session-Inhalte auf Claude-spezifische Ausgaben
#
# Die Funktion verwendet tmux's session formatting (#{session_name}) für zuverlässige
# Namensextraktion und grep mit erweiterten Regex für flexible Pattern-Erkennung.
check_tmux_sessions() {
    local project_name=$(basename "$(pwd)")
    local session_pattern="${TMUX_SESSION_PREFIX:-claude-auto-resume}-${project_name}"
    
    # Stufe 1: Exakte Übereinstimmung mit erwartetem Session-Namen
    # Dies ist der optimale Fall - die Session wurde von unserem System erstellt
    if tmux has-session -t "$session_pattern" 2>/dev/null; then
        DETECTED_SESSION_NAME="$session_pattern"
        log_info "Found exact tmux session match: $session_pattern"
        return 0
    fi
    
    # Stufe 2: Pattern-basierte Suche nach Claude-relevanten Session-Namen
    # Regex erklärt: "claude" (case-insensitive), "auto-resume", oder "sess-" (Session-ID Präfix)
    local matching_sessions
    matching_sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -E "claude|auto-resume|sess-" || true)
    
    if [[ -n "$matching_sessions" ]]; then
        log_info "Found potential Claude tmux sessions: $matching_sessions"
        DETECTED_SESSION_NAME=$(echo "$matching_sessions" | head -1)
        
        # Stufe 3: Content-Validation - verifiziere Claude-Aktivität in gefundenen Sessions
        # Verwende tmux capture-pane um den aktuellen Session-Inhalt zu analysieren
        # Dies verhindert False-Positives von unrelated Sessions mit ähnlichen Namen
        for session in $matching_sessions; do
            local session_output
            session_output=$(tmux capture-pane -t "$session" -p 2>/dev/null || echo "")
            
            # Suche nach Claude-spezifischen Ausgabeindikatoren:
            # - "claude"/"Claude": Kommandozeilen-Tool oder Begrüßung
            # - "session"/"sess-": Session-ID-Referenzen in Claude-Ausgaben
            if echo "$session_output" | grep -q "claude\|Claude\|session\|sess-"; then
                DETECTED_SESSION_NAME="$session"
                log_info "Confirmed Claude activity in session: $session"
                return 0
            fi
        done
    fi
    
    return 1
}

# Prüfe Session-Dateien auf persistierte Session-IDs
#
# Durchsucht bekannte Dateipfade nach gespeicherten Claude Session-IDs.
# Diese Dateien werden vom System erstellt um Session-Persistenz über
# Terminal-Neustarts hinweg zu ermöglichen.
# 
# Priorität der Dateipfade (wichtigste zuerst):
# 1. Projektspezifische Session-Datei im Home-Verzeichnis
# 2. Legacy Auto-Resume Session-Datei (Backwards-Kompatibilität) 
# 3. Lokale Session-Datei im Projektverzeichnis
# 4. Globale Session-Datei (fallback für nicht-projekt-spezifische Usage)
check_session_files() {
    local project_name=$(basename "$(pwd)")
    local session_files=(
        "$HOME/.claude_session_${project_name}"     # Projekt-spezifisch
        "$HOME/.claude_auto_resume_${project_name}" # Legacy-Format
        "$(pwd)/.claude_session"                    # Lokal im Projekt
        "$HOME/.claude_session"
    )
    
    for file in "${session_files[@]}"; do
        if [[ -f "$file" && -s "$file" ]]; then
            local session_id
            session_id=$(cat "$file" 2>/dev/null | head -1 | tr -d '\n\r' | sed 's/[[:space:]]*$//')
            
            if [[ -n "$session_id" ]]; then
                log_info "Found session file: $file with ID: $session_id"
                
                # Validiere Session ID Format
                if [[ "$session_id" =~ ^sess- ]] && [[ ${#session_id} -ge 10 ]]; then
                    DETECTED_SESSION_ID="$session_id"
                    
                    # Prüfe ob Session noch aktiv ist (optional)
                    if validate_session_id_active "$session_id"; then
                        log_info "Confirmed active session from file: $session_id"
                        return 0
                    else
                        log_warn "Session file found but session may be inactive: $session_id"
                        return 0  # Trotzdem als gefunden markieren
                    fi
                else
                    log_warn "Invalid session ID format in file $file: $session_id"
                fi
            fi
        fi
    done
    
    return 1
}

# Prüfe Prozess-Baum auf Claude-Instanzen
check_process_tree() {
    log_debug "Checking process tree for Claude instances"
    
    # Finde Claude-Prozesse
    local claude_processes
    claude_processes=$(pgrep -f "claude" 2>/dev/null || true)
    
    if [[ -n "$claude_processes" ]]; then
        log_info "Found running Claude processes: $claude_processes"
        
        # Prüfe ob Claude-Prozesse in tmux laufen
        for pid in $claude_processes; do
            # Prüfe ob der Prozess in einer tmux-Session läuft
            if tmux list-panes -a -F '#{pane_pid} #{session_name}' 2>/dev/null | grep -q "^$pid "; then
                local session_name
                session_name=$(tmux list-panes -a -F '#{pane_pid} #{session_name}' 2>/dev/null | grep "^$pid " | head -1 | cut -d' ' -f2)
                log_info "Found Claude process $pid running in tmux session: $session_name"
                DETECTED_SESSION_NAME="$session_name"
                return 0
            fi
        done
        
        # Auch wenn nicht in tmux, könnte es eine direkte Claude-Instanz sein
        log_info "Found Claude processes but not in tmux sessions"
        return 0
    fi
    
    return 1
}

# Prüfe Socket-Verbindungen (erweiterte Detection)
check_socket_connections() {
    log_debug "Checking socket connections for Claude activity"
    
    # Prüfe auf offene Netzwerkverbindungen zu Claude-Servern
    # Dies ist eine heuristische Methode, die nach typischen Claude-Verbindungen sucht
    if has_command "netstat"; then
        local claude_connections
        claude_connections=$(netstat -an 2>/dev/null | grep -E "anthropic|claude|443" | grep ESTABLISHED || true)
        
        if [[ -n "$claude_connections" ]]; then
            log_debug "Found potential Claude network connections"
            return 0
        fi
    elif has_command "lsof"; then
        local claude_network
        claude_network=$(lsof -i -n 2>/dev/null | grep -E "claude|anthropic" || true)
        
        if [[ -n "$claude_network" ]]; then
            log_debug "Found Claude network activity via lsof"
            return 0
        fi
    fi
    
    return 1
}

# Validiere ob eine Session-ID noch aktiv ist
validate_session_id_active() {
    local session_id="$1"
    
    # Basis-Validierung der Session-ID-Format
    if [[ ! "$session_id" =~ ^sess- ]] || [[ ${#session_id} -lt 10 ]]; then
        log_debug "Invalid session ID format: $session_id"
        return 1
    fi
    
    # Prüfe ob tmux-Sessions mit dieser Session-ID in Verbindung stehen
    local tmux_sessions
    tmux_sessions=$(tmux list-sessions 2>/dev/null || true)
    
    if [[ -n "$tmux_sessions" ]]; then
        # Durchsuche Session-Outputs nach der Session-ID
        while IFS= read -r session_line; do
            if [[ -n "$session_line" ]]; then
                local session_name
                session_name=$(echo "$session_line" | cut -d':' -f1)
                
                local session_output
                session_output=$(tmux capture-pane -t "$session_name" -p 2>/dev/null || echo "")
                
                if echo "$session_output" | grep -q "$session_id"; then
                    log_debug "Session ID $session_id found in tmux session: $session_name"
                    return 0
                fi
            fi
        done <<< "$tmux_sessions"
    fi
    
    # Session-ID nicht in aktiven Sessions gefunden
    return 1
}

# Erweiterte Session-Information sammeln
get_session_info() {
    local session_identifier="$1"
    
    echo "Session Information:"
    echo "=================="
    
    # Falls es eine tmux-Session ist
    if tmux has-session -t "$session_identifier" 2>/dev/null; then
        echo "Type: tmux session"
        echo "Name: $session_identifier"
        echo "Created: $(tmux list-sessions -F '#{session_created} #{session_name}' | grep "$session_identifier" | cut -d' ' -f1)"
        echo "Windows: $(tmux list-windows -t "$session_identifier" | wc -l)"
        echo ""
        echo "Recent output:"
        tmux capture-pane -t "$session_identifier" -p | tail -5
    # Falls es eine Session-ID ist
    elif [[ "$session_identifier" =~ ^sess- ]]; then
        echo "Type: Claude session ID"
        echo "Session ID: $session_identifier"
        echo "Format: $(if [[ ${#session_identifier} -ge 20 ]]; then echo "Valid"; else echo "Short/Invalid"; fi)"
        
        # Suche zugehörige tmux-Session
        local found_session=""
        local tmux_sessions
        tmux_sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)
        
        if [[ -n "$tmux_sessions" ]]; then
            while IFS= read -r session_name; do
                if [[ -n "$session_name" ]]; then
                    local session_output
                    session_output=$(tmux capture-pane -t "$session_name" -p 2>/dev/null || echo "")
                    
                    if echo "$session_output" | grep -q "$session_identifier"; then
                        found_session="$session_name"
                        break
                    fi
                fi
            done <<< "$tmux_sessions"
        fi
        
        if [[ -n "$found_session" ]]; then
            echo "Associated tmux session: $found_session"
        else
            echo "Associated tmux session: Not found"
        fi
    else
        echo "Type: Unknown"
        echo "Identifier: $session_identifier"
    fi
}

# ===============================================================================
# MAIN ENTRY POINT (für Testing)
# ===============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "=== Session Manager Test ==="
    
    init_session_manager
    
    echo "Configuration:"
    echo "  MAX_RESTARTS: $MAX_RESTARTS"
    echo "  HEALTH_CHECK_ENABLED: $HEALTH_CHECK_ENABLED"
    echo "  AUTO_RECOVERY_ENABLED: $AUTO_RECOVERY_ENABLED"
    echo ""
    
    list_sessions
    
    if [[ "${1:-}" == "--monitor" ]]; then
        echo "Starting session monitoring..."
        monitor_sessions
    fi
fi