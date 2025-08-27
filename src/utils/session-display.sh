#!/usr/bin/env bash

# Claude Auto-Resume - Session Display Module
# User-friendly session ID presentation and management
# Version: 1.0.0-alpha
# Created: 2025-08-27

set -euo pipefail

# ===============================================================================
# GLOBALE VARIABLEN UND KONSTANTEN
# ===============================================================================

# Display formatting
readonly SESSION_DISPLAY_WIDTH=80
readonly SESSION_ID_LABEL_WIDTH=15
readonly SESSION_STATUS_WIDTH=12
readonly SESSION_TIME_WIDTH=10

# ANSI Color codes for enhanced display
if [[ -t 1 ]]; then  # Only use colors if output is to terminal
    readonly COLOR_RESET='\033[0m'
    readonly COLOR_BOLD='\033[1m'
    readonly COLOR_DIM='\033[2m'
    readonly COLOR_GREEN='\033[32m'
    readonly COLOR_YELLOW='\033[33m'
    readonly COLOR_RED='\033[31m'
    readonly COLOR_BLUE='\033[34m'
    readonly COLOR_CYAN='\033[36m'
else
    readonly COLOR_RESET=''
    readonly COLOR_BOLD=''
    readonly COLOR_DIM=''
    readonly COLOR_GREEN=''
    readonly COLOR_YELLOW=''
    readonly COLOR_RED=''
    readonly COLOR_BLUE=''
    readonly COLOR_CYAN=''
fi

# ===============================================================================
# HILFSFUNKTIONEN UND DEPENDENCIES
# ===============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Lade Logging-Utilities falls verfügbar
if [[ -f "$SCRIPT_DIR/logging.sh" ]]; then
    # shellcheck source=./logging.sh
    source "$SCRIPT_DIR/logging.sh"
else
    log_debug() { echo "[DEBUG] $*" >&2; }
    log_info() { echo "[INFO] $*" >&2; }
    log_warn() { echo "[WARN] $*" >&2; }
    log_error() { echo "[ERROR] $*" >&2; }
fi

# Lade Clipboard-Utilities
if [[ -f "$SCRIPT_DIR/clipboard.sh" ]]; then
    # shellcheck source=./clipboard.sh
    source "$SCRIPT_DIR/clipboard.sh"
fi

# Formatiere Zeitstempel für Anzeige
format_timestamp() {
    local timestamp="$1"
    local current_time=$(date +%s)
    local age=$((current_time - timestamp))
    
    if [[ $age -lt 60 ]]; then
        echo "${age}s ago"
    elif [[ $age -lt 3600 ]]; then
        echo "$((age / 60))m ago"
    elif [[ $age -lt 86400 ]]; then
        echo "$((age / 3600))h ago"
    else
        echo "$((age / 86400))d ago"
    fi
}

# Verkürze Session-ID für kompakte Anzeige
shorten_session_id() {
    local session_id="$1"
    local max_length="${2:-20}"
    
    if [[ ${#session_id} -le $max_length ]]; then
        echo "$session_id"
    else
        # Zeige Anfang und Ende der Session-ID
        local prefix_length=$(( (max_length - 3) / 2 ))
        local suffix_length=$(( max_length - prefix_length - 3 ))
        echo "${session_id:0:$prefix_length}...${session_id: -$suffix_length}"
    fi
}

# ===============================================================================
# SESSION-DISPLAY-FUNKTIONEN
# ===============================================================================

# Zeige aktuelle Session-ID
show_current_session_id() {
    local session_id="${1:-}"
    local show_full="${2:-false}"
    
    if [[ -z "$session_id" ]]; then
        if [[ -n "${MAIN_SESSION_ID:-}" ]]; then
            session_id="$MAIN_SESSION_ID"
        else
            echo -e "${COLOR_YELLOW}No active session found${COLOR_RESET}"
            return 1
        fi
    fi
    
    echo -e "${COLOR_BOLD}Current Session:${COLOR_RESET}"
    echo "================"
    
    if [[ "$show_full" == "true" ]]; then
        echo -e "${COLOR_CYAN}Session ID:${COLOR_RESET} $session_id"
    else
        local short_id
        short_id=$(shorten_session_id "$session_id" 40)
        echo -e "${COLOR_CYAN}Session ID:${COLOR_RESET} $short_id"
        echo -e "${COLOR_DIM}(Use --show-full-session-id for complete ID)${COLOR_RESET}"
    fi
    
    # Zeige zusätzliche Session-Informationen falls verfügbar
    if declare -f get_session_info >/dev/null 2>&1; then
        local session_info
        if session_info=$(get_session_info "$session_id" 2>/dev/null); then
            local project_name state last_seen
            project_name=$(echo "$session_info" | grep "^PROJECT_NAME=" | cut -d'=' -f2)
            state=$(echo "$session_info" | grep "^STATE=" | cut -d'=' -f2)
            last_seen=$(echo "$session_info" | grep "^LAST_SEEN=" | cut -d'=' -f2)
            
            if [[ -n "$project_name" ]]; then
                echo -e "${COLOR_CYAN}Project:${COLOR_RESET} $project_name"
            fi
            
            if [[ -n "$state" ]]; then
                local state_color="$COLOR_GREEN"
                case "$state" in
                    "error"|"stopped") state_color="$COLOR_RED" ;;
                    "usage_limited") state_color="$COLOR_YELLOW" ;;
                    "recovering") state_color="$COLOR_YELLOW" ;;
                esac
                echo -e "${COLOR_CYAN}Status:${COLOR_RESET} ${state_color}${state}${COLOR_RESET}"
            fi
            
            if [[ -n "$last_seen" && "$last_seen" != "0" ]]; then
                local formatted_time
                formatted_time=$(format_timestamp "$last_seen")
                echo -e "${COLOR_CYAN}Last Seen:${COLOR_RESET} $formatted_time"
            fi
        fi
    fi
    
    echo ""
}

# Zeige kopierbaren Session-ID-Block
display_copyable_session_id() {
    local session_id="${1:-}"
    local include_copy_hint="${2:-true}"
    
    if [[ -z "$session_id" ]]; then
        if [[ -n "${MAIN_SESSION_ID:-}" ]]; then
            session_id="$MAIN_SESSION_ID"
        else
            echo -e "${COLOR_RED}Error: No session ID available to display${COLOR_RESET}"
            return 1
        fi
    fi
    
    echo -e "${COLOR_BOLD}Session ID (ready to copy):${COLOR_RESET}"
    echo "=================================="
    
    # Zeige Session-ID in einem kopierbaren Block
    echo ""
    echo -e "${COLOR_CYAN}┌$(printf '─%.0s' $(seq 1 $((${#session_id} + 4))))┐${COLOR_RESET}"
    echo -e "${COLOR_CYAN}│${COLOR_RESET} ${COLOR_BOLD}$session_id${COLOR_RESET} ${COLOR_CYAN}│${COLOR_RESET}"
    echo -e "${COLOR_CYAN}└$(printf '─%.0s' $(seq 1 $((${#session_id} + 4))))┘${COLOR_RESET}"
    echo ""
    
    if [[ "$include_copy_hint" == "true" ]]; then
        echo -e "${COLOR_DIM}Copy instructions:${COLOR_RESET}"
        echo -e "${COLOR_DIM}  • Select the text above${COLOR_RESET}"
        echo -e "${COLOR_DIM}  • Use Cmd+C (macOS) or Ctrl+C (Linux) to copy${COLOR_RESET}"
        echo -e "${COLOR_DIM}  • Or use: ${COLOR_CYAN}$0 --copy-session-id${COLOR_RESET} ${COLOR_DIM}to copy automatically${COLOR_RESET}"
        
        # Zeige tmux-spezifische Hints wenn in tmux
        if [[ -n "${TMUX:-}" ]]; then
            echo -e "${COLOR_DIM}  • tmux users: Enter copy-mode with ${COLOR_CYAN}Prefix + [${COLOR_RESET}${COLOR_DIM}, select text, and copy${COLOR_RESET}"
        fi
    fi
    
    echo ""
}

# Zeige Session-Übersicht mit kopierbaren IDs
show_session_summary() {
    local show_all="${1:-false}"
    local format="${2:-table}"  # table, list, or ids-only
    
    echo -e "${COLOR_BOLD}Session Summary:${COLOR_RESET}"
    echo "==============="
    
    # Prüfe ob Session-Manager verfügbar ist
    if ! declare -f list_sessions >/dev/null 2>&1; then
        echo -e "${COLOR_YELLOW}Session manager not available${COLOR_RESET}"
        return 1
    fi
    
    # Hole Session-Liste
    local sessions_output
    if ! sessions_output=$(list_sessions 2>/dev/null); then
        echo -e "${COLOR_YELLOW}No sessions available or session manager error${COLOR_RESET}"
        return 1
    fi
    
    # Parse Sessions und formatiere Ausgabe
    if echo "$sessions_output" | grep -q "No sessions registered"; then
        echo -e "${COLOR_YELLOW}No active sessions found${COLOR_RESET}"
        return 0
    fi
    
    case "$format" in
        "ids-only")
            # Nur Session-IDs ausgeben (nützlich für Scripting)
            echo "$sessions_output" | tail -n +2 | while read -r line; do
                local session_id=$(echo "$line" | awk '{print $1}')
                [[ -n "$session_id" ]] && echo "$session_id"
            done
            ;;
        "list")
            # Einfache Listendarstellung
            echo "$sessions_output" | tail -n +2 | while read -r line; do
                local session_id project_name state
                session_id=$(echo "$line" | awk '{print $1}')
                project_name=$(echo "$line" | awk '{print $2}')
                state=$(echo "$line" | awk '{print $3}')
                
                if [[ -n "$session_id" ]]; then
                    local short_id
                    short_id=$(shorten_session_id "$session_id" 25)
                    echo -e "  ${COLOR_CYAN}•${COLOR_RESET} $short_id ${COLOR_DIM}($project_name - $state)${COLOR_RESET}"
                fi
            done
            ;;
        "table"|*)
            # Tabellen-Darstellung (Standard)
            echo "$sessions_output"
            echo ""
            echo -e "${COLOR_DIM}Use --copy-session-id <SESSION_ID> to copy a specific session ID${COLOR_RESET}"
            ;;
    esac
    
    echo ""
}

# Formatiere Session-Informationen für erweiterte Anzeige
format_session_info() {
    local session_id="$1"
    local format="${2:-standard}"  # standard, compact, or detailed
    
    if ! declare -f get_session_info >/dev/null 2>&1; then
        echo -e "${COLOR_RED}Error: Session manager not available${COLOR_RESET}"
        return 1
    fi
    
    local session_info
    if ! session_info=$(get_session_info "$session_id" 2>/dev/null); then
        echo -e "${COLOR_RED}Error: Session '$session_id' not found${COLOR_RESET}"
        return 1
    fi
    
    # Parse Session-Informationen
    local project_name working_dir state restart_count recovery_count last_seen
    project_name=$(echo "$session_info" | grep "^PROJECT_NAME=" | cut -d'=' -f2)
    working_dir=$(echo "$session_info" | grep "^WORKING_DIR=" | cut -d'=' -f2)
    state=$(echo "$session_info" | grep "^STATE=" | cut -d'=' -f2)
    restart_count=$(echo "$session_info" | grep "^RESTART_COUNT=" | cut -d'=' -f2)
    recovery_count=$(echo "$session_info" | grep "^RECOVERY_COUNT=" | cut -d'=' -f2)
    last_seen=$(echo "$session_info" | grep "^LAST_SEEN=" | cut -d'=' -f2)
    
    case "$format" in
        "compact")
            # Kompakte einzeilige Darstellung
            local short_id time_ago state_icon
            short_id=$(shorten_session_id "$session_id" 20)
            time_ago=$(format_timestamp "$last_seen")
            
            case "$state" in
                "running") state_icon="${COLOR_GREEN}●${COLOR_RESET}" ;;
                "usage_limited") state_icon="${COLOR_YELLOW}⚠${COLOR_RESET}" ;;
                "error"|"stopped") state_icon="${COLOR_RED}●${COLOR_RESET}" ;;
                *) state_icon="${COLOR_DIM}●${COLOR_RESET}" ;;
            esac
            
            echo -e "$state_icon $short_id ${COLOR_DIM}($project_name, $time_ago)${COLOR_RESET}"
            ;;
        "detailed")
            # Detaillierte Informationsdarstellung
            echo -e "${COLOR_BOLD}Session Details:${COLOR_RESET}"
            echo -e "${COLOR_CYAN}Session ID:${COLOR_RESET} $session_id"
            echo -e "${COLOR_CYAN}Project:${COLOR_RESET} $project_name"
            echo -e "${COLOR_CYAN}Working Directory:${COLOR_RESET} $working_dir"
            echo -e "${COLOR_CYAN}Status:${COLOR_RESET} $state"
            echo -e "${COLOR_CYAN}Restart Count:${COLOR_RESET} $restart_count"
            echo -e "${COLOR_CYAN}Recovery Count:${COLOR_RESET} $recovery_count"
            
            if [[ "$last_seen" != "0" ]]; then
                local formatted_time
                formatted_time=$(format_timestamp "$last_seen")
                echo -e "${COLOR_CYAN}Last Seen:${COLOR_RESET} $formatted_time"
            fi
            ;;
        "standard"|*)
            # Standard-Darstellung
            local short_id
            short_id=$(shorten_session_id "$session_id" 30)
            
            echo -e "${COLOR_BOLD}Session:${COLOR_RESET} $short_id"
            echo -e "${COLOR_CYAN}Project:${COLOR_RESET} $project_name"
            
            local state_color="$COLOR_GREEN"
            case "$state" in
                "error"|"stopped") state_color="$COLOR_RED" ;;
                "usage_limited") state_color="$COLOR_YELLOW" ;;
                "recovering") state_color="$COLOR_YELLOW" ;;
            esac
            echo -e "${COLOR_CYAN}Status:${COLOR_RESET} ${state_color}${state}${COLOR_RESET}"
            
            if [[ "$last_seen" != "0" ]]; then
                local formatted_time
                formatted_time=$(format_timestamp "$last_seen")
                echo -e "${COLOR_CYAN}Last Seen:${COLOR_RESET} $formatted_time"
            fi
            ;;
    esac
}

# ===============================================================================
# TMUX-SPEZIFISCHE FUNKTIONEN
# ===============================================================================

# Zeige Session-ID in tmux Status-Bar
show_session_in_tmux_status() {
    local session_id="${1:-}"
    local position="${2:-right}"  # left oder right
    
    if [[ -z "${TMUX:-}" ]]; then
        log_debug "Not in tmux session, skipping status bar update"
        return 0
    fi
    
    if [[ -z "$session_id" ]]; then
        if [[ -n "${MAIN_SESSION_ID:-}" ]]; then
            session_id="$MAIN_SESSION_ID"
        else
            log_warn "No session ID available for tmux status"
            return 1
        fi
    fi
    
    local short_id
    short_id=$(shorten_session_id "$session_id" 15)
    
    # Setze tmux Status-Variable
    local status_var="status-${position}"
    local current_status
    current_status=$(tmux show-options -g "$status_var" 2>/dev/null | cut -d'"' -f2 || echo "")
    
    # Füge Session-ID zum Status hinzu (falls nicht bereits vorhanden)
    if [[ "$current_status" != *"$short_id"* ]]; then
        local new_status
        if [[ "$position" == "right" ]]; then
            new_status="[$short_id] $current_status"
        else
            new_status="$current_status [$short_id]"
        fi
        
        tmux set-option -g "$status_var" "$new_status"
        log_debug "Updated tmux $status_var with session ID: $short_id"
    fi
}

# Kopiere Session-ID in tmux-Buffer
copy_session_to_tmux_buffer() {
    local session_id="${1:-}"
    
    if [[ -z "${TMUX:-}" ]]; then
        log_debug "Not in tmux session, cannot use tmux buffer"
        return 1
    fi
    
    if [[ -z "$session_id" ]]; then
        if [[ -n "${MAIN_SESSION_ID:-}" ]]; then
            session_id="$MAIN_SESSION_ID"
        else
            log_error "No session ID available to copy"
            return 1
        fi
    fi
    
    # Kopiere in tmux-Buffer
    if tmux set-buffer "$session_id" 2>/dev/null; then
        log_info "Session ID copied to tmux buffer: $(shorten_session_id "$session_id" 20)"
        echo -e "${COLOR_GREEN}✓${COLOR_RESET} Session ID copied to tmux buffer"
        echo -e "${COLOR_DIM}Use ${COLOR_CYAN}Prefix + ]${COLOR_RESET}${COLOR_DIM} to paste in tmux${COLOR_RESET}"
        return 0
    else
        log_error "Failed to copy session ID to tmux buffer"
        return 1
    fi
}

# ===============================================================================
# ÖFFENTLICHE API-FUNKTIONEN
# ===============================================================================

# Hauptfunktion: Zeige Session-ID mit automatischer Kopierfunktionalität
show_and_copy_session_id() {
    local session_id="${1:-}"
    local copy_to_clipboard="${2:-false}"
    local show_full="${3:-false}"
    
    # Zeige Session-ID
    if [[ "$show_full" == "true" ]]; then
        show_current_session_id "$session_id" true
    else
        display_copyable_session_id "$session_id"
    fi
    
    # Kopiere automatisch falls gewünscht
    if [[ "$copy_to_clipboard" == "true" ]]; then
        local final_session_id="$session_id"
        [[ -z "$final_session_id" && -n "${MAIN_SESSION_ID:-}" ]] && final_session_id="$MAIN_SESSION_ID"
        
        if [[ -n "$final_session_id" ]]; then
            # Versuche System-Clipboard
            if declare -f copy_to_clipboard >/dev/null 2>&1; then
                if copy_to_clipboard "$final_session_id"; then
                    echo -e "${COLOR_GREEN}✓${COLOR_RESET} Session ID copied to system clipboard"
                    return 0
                fi
            fi
            
            # Fallback zu tmux-Buffer
            if copy_session_to_tmux_buffer "$final_session_id"; then
                return 0
            fi
            
            echo -e "${COLOR_YELLOW}⚠${COLOR_RESET} Could not copy to clipboard. Please copy manually."
            return 1
        else
            echo -e "${COLOR_RED}✗${COLOR_RESET} No session ID available to copy"
            return 1
        fi
    fi
    
    return 0
}

# Liste Sessions mit Copy-Optionen
list_sessions_with_copy_options() {
    local format="${1:-table}"
    local show_copy_hints="${2:-true}"
    
    show_session_summary false "$format"
    
    if [[ "$show_copy_hints" == "true" && "$format" != "ids-only" ]]; then
        echo -e "${COLOR_DIM}Copy options:${COLOR_RESET}"
        echo -e "${COLOR_DIM}  • ${COLOR_CYAN}--copy-session-id <SESSION_ID>${COLOR_RESET}${COLOR_DIM} - Copy specific session${COLOR_RESET}"
        echo -e "${COLOR_DIM}  • ${COLOR_CYAN}--copy-session-id current${COLOR_RESET}${COLOR_DIM} - Copy current session${COLOR_RESET}"
        echo ""
    fi
}

# ===============================================================================
# MAIN ENTRY POINT (für Testing)
# ===============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "=== Session Display Module Test ==="
    echo ""
    
    # Test mit Mock-Session-ID
    MAIN_SESSION_ID="test-project-1672531200-12345"
    
    echo "1. Current Session Display:"
    show_current_session_id
    
    echo "2. Copyable Session ID:"
    display_copyable_session_id
    
    echo "3. Session Summary:"
    show_session_summary
    
    if [[ "${1:-}" == "--copy-test" ]]; then
        echo "4. Copy Test:"
        show_and_copy_session_id "" true
    fi
fi