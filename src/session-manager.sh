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
declare -A SESSIONS
declare -A SESSION_STATES
declare -A SESSION_RESTART_COUNTS
declare -A SESSION_RECOVERY_COUNTS
declare -A SESSION_LAST_SEEN

# Session-Status-Konstanten
readonly SESSION_STATE_UNKNOWN="unknown"
readonly SESSION_STATE_STARTING="starting"
readonly SESSION_STATE_RUNNING="running"
readonly SESSION_STATE_USAGE_LIMITED="usage_limited"
readonly SESSION_STATE_ERROR="error"
readonly SESSION_STATE_STOPPED="stopped"
readonly SESSION_STATE_RECOVERING="recovering"

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
# SESSION-STATE-MANAGEMENT
# ===============================================================================

# Registriere neue Session
register_session() {
    local session_id="$1"
    local project_name="$2"
    local working_dir="$3"
    
    log_info "Registering new session: $session_id"
    
    SESSIONS["$session_id"]="$project_name:$working_dir"
    SESSION_STATES["$session_id"]="$SESSION_STATE_STARTING"
    SESSION_RESTART_COUNTS["$session_id"]=0
    SESSION_RECOVERY_COUNTS["$session_id"]=0
    SESSION_LAST_SEEN["$session_id"]=$(date +%s)
    
    log_debug "Session registered: $session_id -> ${SESSIONS[$session_id]}"
}

# Aktualisiere Session-Status
update_session_state() {
    local session_id="$1"
    local new_state="$2"
    local details="${3:-}"
    
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
    
    if [[ ${#SESSIONS[@]} -eq 0 ]]; then
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
    
    # Lade Konfiguration
    if [[ -f "$config_file" ]]; then
        while IFS='=' read -r key value; do
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$key" ]] && continue
            
            value=$(echo "$value" | sed 's/^["'\'']\|["'\'']$//g')
            
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