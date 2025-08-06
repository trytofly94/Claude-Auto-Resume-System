#!/bin/bash

# Claude Auto-Resume - Terminal Utilities
# Terminal-Detection und -Integration für das claunch-basierte Session-Management
# Version: 1.0.0-alpha
# Letzte Aktualisierung: 2025-08-05

set -euo pipefail

# ===============================================================================
# GLOBALE VARIABLEN UND KONSTANTEN
# ===============================================================================

# Standard-Konfiguration (wird von config/default.conf überschrieben)
PREFERRED_TERMINAL="${PREFERRED_TERMINAL:-auto}"
NEW_TERMINAL_DEFAULT="${NEW_TERMINAL_DEFAULT:-true}"
TERMINAL_TITLE="${TERMINAL_TITLE:-Claude Auto-Resume}"
AUTO_CLOSE_TERMINAL="${AUTO_CLOSE_TERMINAL:-false}"
APPLESCRIPT_INTEGRATION="${APPLESCRIPT_INTEGRATION:-true}"

# Terminal-App-Definitionen
readonly TERMINAL_APPS=(
    "iterm2:iTerm.app"
    "iterm:iTerm.app"
    "terminal:Terminal.app"
    "gnome-terminal:gnome-terminal"
    "konsole:konsole"
    "xterm:xterm"
    "alacritty:alacritty"
    "kitty:kitty"
)

# Erkannte Terminal-Informationen
DETECTED_TERMINAL=""
DETECTED_TERMINAL_PATH=""
CURRENT_TERMINAL_PID=""

# ===============================================================================
# HILFSFUNKTIONEN
# ===============================================================================

# Lade Logging-Utilities falls verfügbar
if [[ -f "$(dirname "${BASH_SOURCE[0]}")/logging.sh" ]]; then
    # shellcheck source=./logging.sh
    source "$(dirname "${BASH_SOURCE[0]}")/logging.sh"
else
    # Fallback-Logging
    log_debug() { echo "[DEBUG] $*" >&2; }
    log_info() { echo "[INFO] $*" >&2; }
    log_warn() { echo "[WARN] $*" >&2; }
    log_error() { echo "[ERROR] $*" >&2; }
fi

# Prüfe ob Kommando verfügbar ist
has_command() {
    command -v "$1" >/dev/null 2>&1
}

# Erkenne Betriebssystem
get_os() {
    case "$(uname -s)" in
        Darwin) echo "macos" ;;
        Linux) echo "linux" ;;
        CYGWIN*|MINGW*|MSYS*) echo "windows" ;;
        *) echo "unknown" ;;
    esac
}

# ===============================================================================
# TERMINAL-ERKENNUNG
# ===============================================================================

# Erkenne aktuelles Terminal anhand von Umgebungsvariablen
detect_current_terminal() {
    log_debug "Detecting current terminal"
    
    # Setze Standardwerte zurück
    DETECTED_TERMINAL=""
    DETECTED_TERMINAL_PATH=""
    CURRENT_TERMINAL_PID=""
    
    # Methode 1: TERM_PROGRAM (macOS)
    if [[ -n "${TERM_PROGRAM:-}" ]]; then
        case "$TERM_PROGRAM" in
            "iTerm.app") 
                DETECTED_TERMINAL="iterm2"
                DETECTED_TERMINAL_PATH="/Applications/iTerm.app"
                ;;
            "Apple_Terminal") 
                DETECTED_TERMINAL="terminal"
                DETECTED_TERMINAL_PATH="/Applications/Utilities/Terminal.app"
                ;;
            "vscode") 
                DETECTED_TERMINAL="vscode"
                DETECTED_TERMINAL_PATH="code"
                ;;
        esac
    fi
    
    # Methode 2: Parent-Process-Name
    if [[ -z "$DETECTED_TERMINAL" ]]; then
        local parent_pid=$PPID
        local parent_cmd=""
        
        if has_command ps; then
            parent_cmd=$(ps -p "$parent_pid" -o comm= 2>/dev/null || echo "")
        fi
        
        case "$parent_cmd" in
            *iTerm*|*iterm*) 
                DETECTED_TERMINAL="iterm2"
                DETECTED_TERMINAL_PATH="/Applications/iTerm.app"
                ;;
            *Terminal*|*terminal*) 
                if [[ "$(get_os)" == "macos" ]]; then
                    DETECTED_TERMINAL="terminal"
                    DETECTED_TERMINAL_PATH="/Applications/Utilities/Terminal.app"
                else
                    DETECTED_TERMINAL="gnome-terminal"
                    DETECTED_TERMINAL_PATH="gnome-terminal"
                fi
                ;;
            *gnome-terminal*) 
                DETECTED_TERMINAL="gnome-terminal"
                DETECTED_TERMINAL_PATH="gnome-terminal"
                ;;
            *konsole*) 
                DETECTED_TERMINAL="konsole"
                DETECTED_TERMINAL_PATH="konsole"
                ;;
            *xterm*) 
                DETECTED_TERMINAL="xterm"
                DETECTED_TERMINAL_PATH="xterm"
                ;;
            *alacritty*) 
                DETECTED_TERMINAL="alacritty"
                DETECTED_TERMINAL_PATH="alacritty"
                ;;
            *kitty*) 
                DETECTED_TERMINAL="kitty"
                DETECTED_TERMINAL_PATH="kitty"
                ;;
        esac
        
        CURRENT_TERMINAL_PID="$parent_pid"
    fi
    
    # Methode 3: Fallback basierend auf verfügbaren Terminals
    if [[ -z "$DETECTED_TERMINAL" ]]; then
        case "$(get_os)" in
            "macos")
                if [[ -d "/Applications/iTerm.app" ]]; then
                    DETECTED_TERMINAL="iterm2"
                    DETECTED_TERMINAL_PATH="/Applications/iTerm.app"
                elif [[ -d "/Applications/Utilities/Terminal.app" ]] || [[ -d "/System/Applications/Utilities/Terminal.app" ]]; then
                    DETECTED_TERMINAL="terminal"
                    DETECTED_TERMINAL_PATH="/Applications/Utilities/Terminal.app"
                fi
                ;;
            "linux")
                for terminal in gnome-terminal konsole xterm alacritty kitty; do
                    if has_command "$terminal"; then
                        DETECTED_TERMINAL="$terminal"
                        DETECTED_TERMINAL_PATH="$terminal"
                        break
                    fi
                done
                ;;
        esac
    fi
    
    if [[ -n "$DETECTED_TERMINAL" ]]; then
        log_info "Detected terminal: $DETECTED_TERMINAL (path: $DETECTED_TERMINAL_PATH)"
        return 0
    else
        log_warn "Could not detect current terminal"
        return 1
    fi
}

# Liste verfügbare Terminal-Emulatoren
list_available_terminals() {
    log_debug "Listing available terminal emulators"
    
    local available_terminals=()
    
    case "$(get_os)" in
        "macos")
            # macOS Terminal-Apps prüfen
            for app_path in "/Applications/iTerm.app" "/Applications/Utilities/Terminal.app" "/System/Applications/Utilities/Terminal.app"; do
                if [[ -d "$app_path" ]]; then
                    case "$app_path" in
                        *iTerm*) available_terminals+=("iterm2:$app_path") ;;
                        *Terminal*) available_terminals+=("terminal:$app_path") ;;
                    esac
                fi
            done
            ;;
        "linux")
            # Linux Terminal-Emulatoren prüfen
            for terminal in gnome-terminal konsole xterm alacritty kitty; do
                if has_command "$terminal"; then
                    available_terminals+=("$terminal:$(command -v "$terminal")")
                fi
            done
            ;;
    esac
    
    printf '%s\n' "${available_terminals[@]}"
}

# Wähle besten verfügbaren Terminal-Emulator
select_best_terminal() {
    local preference="${1:-$PREFERRED_TERMINAL}"
    
    log_debug "Selecting best terminal (preference: $preference)"
    
    # Wenn spezifische Präferenz gesetzt ist, prüfe diese zuerst
    if [[ "$preference" != "auto" ]]; then
        if validate_terminal_app "$preference"; then
            DETECTED_TERMINAL="$preference"
            set_terminal_path "$preference"
            log_info "Selected preferred terminal: $DETECTED_TERMINAL"
            return 0
        else
            log_warn "Preferred terminal '$preference' not available, falling back to auto-detection"
        fi
    fi
    
    # Auto-Detection
    detect_current_terminal && return 0
    
    # Fallback: Nimm ersten verfügbaren Terminal
    local available_terminals
    available_terminals=$(list_available_terminals)
    
    if [[ -n "$available_terminals" ]]; then
        local first_terminal
        first_terminal=$(echo "$available_terminals" | head -1)
        DETECTED_TERMINAL="${first_terminal%%:*}"
        DETECTED_TERMINAL_PATH="${first_terminal##*:}"
        log_info "Selected fallback terminal: $DETECTED_TERMINAL"
        return 0
    fi
    
    log_error "No suitable terminal emulator found"
    return 1
}

# Validiere Terminal-App
validate_terminal_app() {
    local terminal_name="$1"
    
    case "$(get_os)" in
        "macos")
            case "$terminal_name" in
                "iterm2"|"iterm") [[ -d "/Applications/iTerm.app" ]] ;;
                "terminal") [[ -d "/Applications/Utilities/Terminal.app" ]] || [[ -d "/System/Applications/Utilities/Terminal.app" ]] ;;
                *) return 1 ;;
            esac
            ;;
        "linux")
            has_command "$terminal_name"
            ;;
        *) return 1 ;;
    esac
}

# Setze Terminal-Pfad basierend auf Name
set_terminal_path() {
    local terminal_name="$1"
    
    case "$(get_os)" in
        "macos")
            case "$terminal_name" in
                "iterm2"|"iterm") DETECTED_TERMINAL_PATH="/Applications/iTerm.app" ;;
                "terminal") 
                    if [[ -d "/System/Applications/Utilities/Terminal.app" ]]; then
                        DETECTED_TERMINAL_PATH="/System/Applications/Utilities/Terminal.app"
                    else
                        DETECTED_TERMINAL_PATH="/Applications/Utilities/Terminal.app"
                    fi
                    ;;
            esac
            ;;
        "linux")
            if has_command "$terminal_name"; then
                DETECTED_TERMINAL_PATH=$(command -v "$terminal_name")
            fi
            ;;
    esac
}

# ===============================================================================
# TERMINAL-STEUERUNG
# ===============================================================================

# Öffne neues Terminal-Fenster mit Kommando
open_terminal_window() {
    local command="$1"
    local working_dir="${2:-$(pwd)}"
    local window_title="${3:-$TERMINAL_TITLE}"
    
    log_info "Opening new terminal window: $DETECTED_TERMINAL"
    log_debug "Command: $command"
    log_debug "Working directory: $working_dir"
    log_debug "Window title: $window_title"
    
    case "$DETECTED_TERMINAL" in
        "iterm2"|"iterm")
            open_iterm_window "$command" "$working_dir" "$window_title"
            ;;
        "terminal")
            open_terminal_app_window "$command" "$working_dir" "$window_title"
            ;;
        "gnome-terminal")
            open_gnome_terminal_window "$command" "$working_dir" "$window_title"
            ;;
        "konsole")
            open_konsole_window "$command" "$working_dir" "$window_title"
            ;;
        "xterm")
            open_xterm_window "$command" "$working_dir" "$window_title"
            ;;
        "alacritty")
            open_alacritty_window "$command" "$working_dir" "$window_title"
            ;;
        "kitty")
            open_kitty_window "$command" "$working_dir" "$window_title"
            ;;
        *)
            log_error "Unsupported terminal: $DETECTED_TERMINAL"
            return 1
            ;;
    esac
}

# ===============================================================================
# TERMINAL-SPEZIFISCHE IMPLEMENTIERUNGEN
# ===============================================================================

# iTerm2-Fenster öffnen
open_iterm_window() {
    local command="$1"
    local working_dir="$2"
    local window_title="$3"
    
    if [[ "$APPLESCRIPT_INTEGRATION" != "true" ]] || ! has_command osascript; then
        log_error "AppleScript integration disabled or osascript not available"
        return 1
    fi
    
    # Escape für AppleScript
    local escaped_dir="${working_dir//\\/\\\\}"
    escaped_dir="${escaped_dir//\"/\\\"}"
    local escaped_cmd="${command//\\/\\\\}"
    escaped_cmd="${escaped_cmd//\"/\\\"}"
    local escaped_title="${window_title//\\/\\\\}"
    escaped_title="${escaped_title//\"/\\\"}"
    
    osascript <<EOF
tell application "iTerm"
    create window with default profile
    tell current session of current window
        set name to "$escaped_title"
        write text "cd \"$escaped_dir\""
        write text "$escaped_cmd"
    end tell
    activate
end tell
EOF
}

# macOS Terminal.app-Fenster öffnen
open_terminal_app_window() {
    local command="$1"
    local working_dir="$2"
    local window_title="$3"
    
    if [[ "$APPLESCRIPT_INTEGRATION" != "true" ]] || ! has_command osascript; then
        log_error "AppleScript integration disabled or osascript not available"
        return 1
    fi
    
    # Für Terminal.app müssen wir alles in einem do script kombinieren
    local full_command="cd \"$working_dir\" && $command"
    local escaped_cmd="${full_command//\\/\\\\}"
    escaped_cmd="${escaped_cmd//\"/\\\"}"
    
    osascript <<EOF
tell application "Terminal"
    activate
    set newWindow to do script "$escaped_cmd"
    set custom title of newWindow to "$window_title"
end tell
EOF
}

# GNOME Terminal-Fenster öffnen
open_gnome_terminal_window() {
    local command="$1"
    local working_dir="$2"
    local window_title="$3"
    
    local args=(
        "--working-directory=$working_dir"
        "--title=$window_title"
    )
    
    if [[ "$AUTO_CLOSE_TERMINAL" == "true" ]]; then
        args+=("--command" "bash -c '$command; exec bash'")
    else
        args+=("--command" "bash -c 'cd \"$working_dir\" && $command; exec bash'")
    fi
    
    gnome-terminal "${args[@]}" &
}

# KDE Konsole-Fenster öffnen
open_konsole_window() {
    local command="$1"
    local working_dir="$2"
    local window_title="$3"
    
    konsole --workdir "$working_dir" --title "$window_title" \
            -e bash -c "cd \"$working_dir\" && $command; exec bash" &
}

# XTerm-Fenster öffnen
open_xterm_window() {
    local command="$1"
    local working_dir="$2"
    local window_title="$3"
    
    cd "$working_dir"
    xterm -title "$window_title" -e bash -c "$command; exec bash" &
}

# Alacritty-Fenster öffnen
open_alacritty_window() {
    local command="$1"
    local working_dir="$2"
    local window_title="$3"
    
    alacritty --working-directory "$working_dir" --title "$window_title" \
              -e bash -c "$command; exec bash" &
}

# Kitty-Fenster öffnen
open_kitty_window() {
    local command="$1"
    local working_dir="$2"
    local window_title="$3"
    
    kitty --directory="$working_dir" --title="$window_title" \
          bash -c "cd \"$working_dir\" && $command; exec bash" &
}

# ===============================================================================
# ÖFFENTLICHE FUNKTIONEN
# ===============================================================================

# Initialisiere Terminal-Utilities
init_terminal_utils() {
    local config_file="${1:-config/default.conf}"
    
    log_debug "Initializing terminal utilities"
    
    # Lade Konfiguration falls vorhanden
    if [[ -f "$config_file" ]]; then
        while IFS='=' read -r key value; do
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$key" ]] && continue
            
            value=$(echo "$value" | sed 's/^["'\'']\|["'\'']$//g')
            
            case "$key" in
                PREFERRED_TERMINAL|NEW_TERMINAL_DEFAULT|TERMINAL_TITLE|AUTO_CLOSE_TERMINAL|APPLESCRIPT_INTEGRATION)
                    eval "$key='$value'"
                    ;;
            esac
        done < <(grep -E '^[^#]*=' "$config_file" || true)
        
        log_debug "Terminal utilities initialized with config: $config_file"
    fi
    
    # Erkenne und wähle besten Terminal
    select_best_terminal
}

# Zeige Terminal-Informationen
show_terminal_info() {
    echo "Terminal Information:"
    echo "  Current OS: $(get_os)"
    echo "  Detected Terminal: ${DETECTED_TERMINAL:-none}"
    echo "  Terminal Path: ${DETECTED_TERMINAL_PATH:-none}"
    echo "  Current PID: ${CURRENT_TERMINAL_PID:-none}"
    echo "  Preferred Terminal: $PREFERRED_TERMINAL"
    echo ""
    echo "Available Terminals:"
    list_available_terminals | while IFS=: read -r name path; do
        echo "  $name: $path"
    done
}

# Öffne Claude in neuem Terminal
open_claude_in_terminal() {
    local claude_args=("$@")
    local working_dir
    working_dir=$(pwd)
    
    # Stelle sicher, dass Terminal verfügbar ist
    if [[ -z "$DETECTED_TERMINAL" ]]; then
        if ! select_best_terminal; then
            log_error "No terminal available for opening Claude"
            return 1
        fi
    fi
    
    # Baue Claude-Kommando zusammen
    local claude_cmd="claude"
    if [[ ${#claude_args[@]} -gt 0 ]]; then
        # Escape Argumente für Shell
        local escaped_args=()
        for arg in "${claude_args[@]}"; do
            escaped_args+=("$(printf '%q' "$arg")")
        done
        claude_cmd="$claude_cmd ${escaped_args[*]}"
    fi
    
    log_info "Opening Claude in new $DETECTED_TERMINAL window"
    open_terminal_window "$claude_cmd" "$working_dir" "Claude CLI - $(basename "$working_dir")"
}

# ===============================================================================
# MAIN ENTRY POINT (für Testing)
# ===============================================================================

# Nur ausführen wenn Skript direkt aufgerufen wird
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    init_terminal_utils
    
    echo "=== Terminal Utilities Test ==="
    show_terminal_info
    echo
    
    echo "Testing terminal detection..."
    detect_current_terminal
    echo "Current terminal: $DETECTED_TERMINAL"
    
    # Interaktiver Test (nur wenn explizit gewünscht)
    if [[ "${1:-}" == "--interactive" ]]; then
        echo
        echo "Opening test terminal window in 3 seconds..."
        sleep 3
        open_terminal_window "echo 'Terminal test successful! Press Enter to continue...'; read" "$(pwd)" "Terminal Test"
    fi
fi