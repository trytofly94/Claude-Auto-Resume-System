#!/usr/bin/env bash

# Claude Auto-Resume - claunch Integration
# claunch-Wrapper und Session-Management für das Claude Auto-Resume System
# Version: 1.0.0-alpha
# Letzte Aktualisierung: 2025-08-05

set -euo pipefail

# ===============================================================================
# GLOBALE VARIABLEN UND KONSTANTEN
# ===============================================================================

# Standard-Konfiguration (wird von config/default.conf überschrieben)
USE_CLAUNCH="${USE_CLAUNCH:-true}"
CLAUNCH_MODE="${CLAUNCH_MODE:-tmux}"
TMUX_SESSION_PREFIX="${TMUX_SESSION_PREFIX:-claude-auto}"

# claunch-spezifische Variablen
CLAUNCH_PATH=""
CLAUNCH_VERSION=""
PROJECT_NAME=""
SESSION_ID=""
TMUX_SESSION_NAME=""

# ===============================================================================
# HILFSFUNKTIONEN UND DEPENDENCIES
# ===============================================================================

# Lade Utility-Module
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Lade Logging-Utilities
if [[ -f "$SCRIPT_DIR/utils/logging.sh" ]]; then
    # shellcheck source=./utils/logging.sh
    source "$SCRIPT_DIR/utils/logging.sh"
else
    log_debug() { echo "[DEBUG] $*" >&2; }
    log_info() { echo "[INFO] $*" >&2; }
    log_warn() { echo "[WARN] $*" >&2; }
    log_error() { echo "[ERROR] $*" >&2; }
fi

# Lade Terminal-Utilities
if [[ -f "$SCRIPT_DIR/utils/terminal.sh" ]]; then
    # shellcheck source=./utils/terminal.sh
    source "$SCRIPT_DIR/utils/terminal.sh"
fi

# Prüfe ob Kommando verfügbar ist
has_command() {
    command -v "$1" >/dev/null 2>&1
}

# ===============================================================================
# CLAUNCH-ERKENNUNG UND -VALIDIERUNG
# ===============================================================================

# Erkenne claunch-Installation
detect_claunch() {
    log_debug "Detecting claunch installation"
    
    # Methode 1: claunch im PATH
    if has_command claunch; then
        CLAUNCH_PATH=$(command -v claunch)
        log_debug "Found claunch in PATH: $CLAUNCH_PATH"
        return 0
    fi
    
    # Methode 2: Häufige Installationsorte prüfen
    local common_paths=(
        "$HOME/bin/claunch"
        "$HOME/.local/bin/claunch"
        "/usr/local/bin/claunch"
        "/opt/homebrew/bin/claunch"
        "$HOME/.npm-global/bin/claunch"
    )
    
    for path in "${common_paths[@]}"; do
        if [[ -x "$path" ]]; then
            CLAUNCH_PATH="$path"
            log_debug "Found claunch at: $CLAUNCH_PATH"
            return 0
        fi
    done
    
    log_error "claunch not found in PATH or common locations"
    return 1
}

# Validiere claunch-Installation
validate_claunch() {
    log_debug "Validating claunch installation"
    
    if [[ -z "$CLAUNCH_PATH" ]]; then
        detect_claunch || return 1
    fi
    
    # Teste claunch-Aufruf
    if ! "$CLAUNCH_PATH" --help >/dev/null 2>&1; then
        log_error "claunch at $CLAUNCH_PATH is not executable or corrupted"
        return 1
    fi
    
    # Hole Version
    if CLAUNCH_VERSION=$("$CLAUNCH_PATH" --version 2>/dev/null | head -1); then
        log_info "claunch validated: $CLAUNCH_VERSION"
    else
        log_warn "Could not determine claunch version"
        CLAUNCH_VERSION="unknown"
    fi
    
    return 0
}

# Prüfe tmux-Verfügbarkeit (für tmux-Modus)
check_tmux_availability() {
    if [[ "$CLAUNCH_MODE" == "tmux" ]]; then
        if ! has_command tmux; then
            log_error "tmux not found but required for CLAUNCH_MODE=tmux"
            return 1
        fi
        log_debug "tmux is available for claunch tmux mode"
    fi
    return 0
}

# ===============================================================================
# PROJEKT- UND SESSION-MANAGEMENT
# ===============================================================================

# Erkenne aktuelles Projekt
detect_project() {
    local working_dir="${1:-$(pwd)}"
    
    log_debug "Detecting project from directory: $working_dir"
    
    # Projekt-Name basierend auf Verzeichnisname
    PROJECT_NAME=$(basename "$working_dir")
    
    # Bereinige Projekt-Namen für tmux-Session-Kompatibilität
    PROJECT_NAME=${PROJECT_NAME//[^a-zA-Z0-9_-]/_}
    
    log_info "Detected project: $PROJECT_NAME"
    
    # Erstelle tmux-Session-Name
    TMUX_SESSION_NAME="${TMUX_SESSION_PREFIX}-${PROJECT_NAME}"
    
    log_debug "tmux session name: $TMUX_SESSION_NAME"
}

# Erkenne bestehende Session
detect_existing_session() {
    local project_dir="${1:-$(pwd)}"
    
    log_debug "Detecting existing claunch session for project"
    
    # Session-Datei-Pfad
    local session_file="$HOME/.claude_session_${PROJECT_NAME}"
    
    if [[ -f "$session_file" ]]; then
        SESSION_ID=$(cat "$session_file")
        log_info "Found existing session ID: $SESSION_ID"
        
        # Prüfe ob tmux-Session existiert (im tmux-Modus)
        if [[ "$CLAUNCH_MODE" == "tmux" ]]; then
            if tmux has-session -t "$TMUX_SESSION_NAME" 2>/dev/null; then
                log_info "Existing tmux session found: $TMUX_SESSION_NAME"
                return 0
            else
                log_warn "Session file exists but tmux session not found"
                return 1
            fi
        fi
        
        return 0
    else
        log_debug "No existing session file found"
        return 1
    fi
}

# ===============================================================================
# CLAUNCH-WRAPPER-FUNKTIONEN
# ===============================================================================

# Starte neue claunch-Session
start_claunch_session() {
    local working_dir="${1:-$(pwd)}"
    shift
    local claude_args=("$@")
    
    log_info "Starting new claunch session in $CLAUNCH_MODE mode"
    log_debug "Working directory: $working_dir"
    log_debug "Claude arguments: ${claude_args[*]}"
    
    # Wechsele ins Arbeitsverzeichnis
    cd "$working_dir"
    
    # Baue claunch-Kommando zusammen
    local claunch_cmd=("$CLAUNCH_PATH")
    
    if [[ "$CLAUNCH_MODE" == "tmux" ]]; then
        claunch_cmd+=("--tmux")
    fi
    
    # Füge Claude-Argumente hinzu
    if [[ ${#claude_args[@]} -gt 0 ]]; then
        claunch_cmd+=("--" "${claude_args[@]}")
    fi
    
    log_debug "Executing: ${claunch_cmd[*]}"
    
    # Führe claunch aus
    if "${claunch_cmd[@]}"; then
        log_info "claunch session started successfully"
        
        # Aktualisiere Session-Informationen
        detect_existing_session "$working_dir"
        
        return 0
    else
        local exit_code=$?
        log_error "Failed to start claunch session (exit code: $exit_code)"
        return $exit_code
    fi
}

# Starte claunch in neuem Terminal
start_claunch_in_new_terminal() {
    local working_dir="${1:-$(pwd)}"
    shift
    local claude_args=("$@")
    
    log_info "Starting claunch in new terminal window"
    
    # Stelle sicher, dass Terminal-Utils verfügbar sind
    if ! declare -f open_claude_in_terminal >/dev/null 2>&1; then
        log_error "Terminal utilities not available"
        return 1
    fi
    
    # Baue claunch-Kommando für Terminal zusammen
    local claunch_cmd=("$CLAUNCH_PATH")
    
    if [[ "$CLAUNCH_MODE" == "tmux" ]]; then
        claunch_cmd+=("--tmux")
    fi
    
    # Füge Claude-Argumente hinzu
    if [[ ${#claude_args[@]} -gt 0 ]]; then
        # Escape Argumente für Terminal
        local escaped_args=()
        for arg in "${claude_args[@]}"; do
            escaped_args+=("$(printf '%q' "$arg")")
        done
        claunch_cmd+=("--" "${escaped_args[@]}")
    fi
    
    # Öffne in Terminal
    cd "$working_dir"
    open_terminal_window "${claunch_cmd[*]}" "$working_dir" "Claude - $PROJECT_NAME"
}

# Sende Kommando an bestehende Session
send_command_to_session() {
    local command="$1"
    local session_target="${2:-$TMUX_SESSION_NAME}"
    
    log_debug "Sending command to session: $command"
    
    if [[ "$CLAUNCH_MODE" == "tmux" ]]; then
        if tmux has-session -t "$session_target" 2>/dev/null; then
            tmux send-keys -t "$session_target" "$command" Enter
            log_info "Command sent to tmux session: $session_target"
            return 0
        else
            log_error "tmux session not found: $session_target"
            return 1
        fi
    else
        log_warn "Command sending only supported in tmux mode"
        return 1
    fi
}

# ===============================================================================
# SESSION-MANAGEMENT-FUNKTIONEN
# ===============================================================================

# Prüfe Session-Status
check_session_status() {
    log_debug "Checking claunch session status"
    
    if [[ "$CLAUNCH_MODE" == "tmux" ]]; then
        if tmux has-session -t "$TMUX_SESSION_NAME" 2>/dev/null; then
            log_debug "tmux session is active: $TMUX_SESSION_NAME"
            return 0
        else
            log_debug "tmux session not found: $TMUX_SESSION_NAME"
            return 1
        fi
    else
        # Im direct-Modus prüfen wir die Session-Datei
        if [[ -f "$HOME/.claude_session_${PROJECT_NAME}" ]]; then
            log_debug "Session file exists for project: $PROJECT_NAME"
            return 0
        else
            log_debug "No session file found for project: $PROJECT_NAME"
            return 1
        fi
    fi
}

# Liste aktive Sessions
list_active_sessions() {
    log_info "Listing active claunch sessions"
    
    echo "=== Active claunch Sessions ==="
    
    # Nutze claunch list falls verfügbar
    if "$CLAUNCH_PATH" list >/dev/null 2>&1; then
        "$CLAUNCH_PATH" list
    else
        # Fallback: Suche Session-Dateien
        echo "Session files in $HOME:"
        find "$HOME" -name ".claude_session_*" -type f 2>/dev/null | while read -r session_file; do
            local project=$(basename "$session_file" | sed 's/^\.claude_session_//')
            local session_id
            session_id=$(cat "$session_file" 2>/dev/null || echo "invalid")
            echo "  $project: $session_id"
        done
    fi
    
    # Zeige tmux-Sessions falls verfügbar
    if [[ "$CLAUNCH_MODE" == "tmux" ]] && has_command tmux; then
        echo ""
        echo "=== Active tmux Sessions ==="
        tmux list-sessions 2>/dev/null | grep "$TMUX_SESSION_PREFIX" || echo "  No claude tmux sessions found"
    fi
}

# Bereinige verwaiste Sessions
cleanup_orphaned_sessions() {
    log_info "Cleaning up orphaned claunch sessions"
    
    # Nutze claunch clean falls verfügbar
    if "$CLAUNCH_PATH" clean >/dev/null 2>&1; then
        "$CLAUNCH_PATH" clean
        log_info "claunch cleanup completed"
    else
        log_warn "claunch clean command not available"
    fi
    
    # Bereinige verwaiste tmux-Sessions
    if [[ "$CLAUNCH_MODE" == "tmux" ]] && has_command tmux; then
        log_debug "Checking for orphaned tmux sessions"
        
        while IFS= read -r session_name; do
            if [[ "$session_name" =~ ^${TMUX_SESSION_PREFIX}- ]]; then
                local project_name=${session_name#"${TMUX_SESSION_PREFIX}-"}
                local session_file="$HOME/.claude_session_${project_name}"
                
                if [[ ! -f "$session_file" ]]; then
                    log_warn "Orphaned tmux session found: $session_name"
                    echo "Kill orphaned session $session_name? (y/n)"
                    read -r response
                    if [[ "$response" =~ ^[Yy]$ ]]; then
                        tmux kill-session -t "$session_name"
                        log_info "Killed orphaned session: $session_name"
                    fi
                fi
            fi
        done < <(tmux list-sessions -F "#{session_name}" 2>/dev/null || true)
    fi
}

# ===============================================================================
# ÖFFENTLICHE API-FUNKTIONEN
# ===============================================================================

# Initialisiere claunch-Integration
init_claunch_integration() {
    local config_file="${1:-config/default.conf}"
    local working_dir="${2:-$(pwd)}"
    
    log_info "Initializing claunch integration"
    
    # Lade Konfiguration
    if [[ -f "$config_file" ]]; then
        while IFS='=' read -r key value; do
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$key" ]] && continue
            
            value=$(echo "$value" | sed 's/^["'\'']\|["'\'']$//g')
            
            case "$key" in
                USE_CLAUNCH|CLAUNCH_MODE|TMUX_SESSION_PREFIX)
                    eval "$key='$value'"
                    ;;
            esac
        done < <(grep -E '^[^#]*=' "$config_file" || true)
    fi
    
    # Prüfe ob claunch verwendet werden soll
    if [[ "$USE_CLAUNCH" != "true" ]]; then
        log_info "claunch integration disabled by configuration"
        return 1
    fi
    
    # Validiere claunch
    validate_claunch || return 1
    
    # Prüfe tmux-Verfügbarkeit
    check_tmux_availability || return 1
    
    # Erkenne Projekt
    detect_project "$working_dir"
    
    log_info "claunch integration initialized successfully"
    return 0
}

# Starte oder setze Session fort
start_or_resume_session() {
    local working_dir="${1:-$(pwd)}"
    local use_new_terminal="${2:-false}"
    shift 2 2>/dev/null || shift $# # Remove processed args
    local claude_args=("$@")
    
    log_info "Starting or resuming claunch session"
    
    # Erkenne bestehende Session
    if detect_existing_session "$working_dir"; then
        log_info "Resuming existing session"
        
        if [[ "$use_new_terminal" == "true" ]]; then
            # Öffne neues Terminal und attachiere an bestehende Session
            if [[ "$CLAUNCH_MODE" == "tmux" ]]; then
                local attach_cmd="tmux attach-session -t $TMUX_SESSION_NAME"
                open_terminal_window "$attach_cmd" "$working_dir" "Claude - $PROJECT_NAME (Resume)"
            else
                log_warn "Resume in new terminal only supported in tmux mode"
                return 1
            fi
        fi
        
        return 0
    else
        log_info "Starting new session"
        
        if [[ "$use_new_terminal" == "true" ]]; then
            start_claunch_in_new_terminal "$working_dir" "${claude_args[@]}"
        else
            start_claunch_session "$working_dir" "${claude_args[@]}"
        fi
    fi
}

# Sende Recovery-Kommando
send_recovery_command() {
    local recovery_cmd="${1:-/dev bitte mach weiter}"
    
    log_info "Sending recovery command to active session"
    
    if check_session_status; then
        send_command_to_session "$recovery_cmd"
    else
        log_error "No active session found for recovery command"
        return 1
    fi
}

# ===============================================================================
# MAIN ENTRY POINT (für Testing)
# ===============================================================================

# Nur ausführen wenn Skript direkt aufgerufen wird
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Test-Modus
    echo "=== claunch Integration Test ==="
    
    init_claunch_integration
    
    echo "claunch Path: $CLAUNCH_PATH"
    echo "claunch Version: $CLAUNCH_VERSION"
    echo "Project: $PROJECT_NAME"
    echo "tmux Session: $TMUX_SESSION_NAME"
    echo ""
    
    list_active_sessions
    
    # Interaktiver Test
    if [[ "${1:-}" == "--interactive" ]]; then
        echo ""
        echo "Start test session? (y/n)"
        read -r response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            start_or_resume_session "$(pwd)" true "test session"
        fi
    fi
fi