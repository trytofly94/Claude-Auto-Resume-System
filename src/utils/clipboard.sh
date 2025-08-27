#!/usr/bin/env bash

# Claude Auto-Resume - Clipboard Utility Module
# Cross-platform clipboard functionality for session ID copying
# Version: 1.0.0-alpha
# Created: 2025-08-27

set -euo pipefail

# ===============================================================================
# GLOBALE VARIABLEN UND KONSTANTEN
# ===============================================================================

# Clipboard-Tools nach Plattform und Verfügbarkeit
declare -A CLIPBOARD_TOOLS=(
    ["pbcopy"]="macOS"
    ["pbpaste"]="macOS"
    ["xclip"]="Linux-X11"
    ["xsel"]="Linux-X11"
    ["wl-copy"]="Linux-Wayland"
    ["wl-paste"]="Linux-Wayland"
)

# Erkannte Tools (werden bei Initialisierung gefüllt)
AVAILABLE_COPY_TOOL=""
AVAILABLE_PASTE_TOOL=""
CLIPBOARD_METHOD=""

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

# Prüfe ob Kommando verfügbar ist
has_command() {
    command -v "$1" >/dev/null 2>&1
}

# Erkenne aktuelle Plattform
detect_platform() {
    case "$(uname -s)" in
        Darwin*)
            echo "macOS"
            ;;
        Linux*)
            # Unterscheide zwischen X11 und Wayland
            if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
                echo "Linux-Wayland"
            elif [[ -n "${DISPLAY:-}" ]]; then
                echo "Linux-X11"
            else
                echo "Linux-unknown"
            fi
            ;;
        CYGWIN*|MINGW*|MSYS*)
            echo "Windows"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

# ===============================================================================
# CLIPBOARD-TOOL-ERKENNUNG
# ===============================================================================

# Erkenne verfügbare Clipboard-Tools
detect_clipboard_tools() {
    log_debug "Detecting available clipboard tools"
    
    local platform
    platform=$(detect_platform)
    log_debug "Detected platform: $platform"
    
    AVAILABLE_COPY_TOOL=""
    AVAILABLE_PASTE_TOOL=""
    CLIPBOARD_METHOD=""
    
    case "$platform" in
        "macOS")
            if has_command pbcopy && has_command pbpaste; then
                AVAILABLE_COPY_TOOL="pbcopy"
                AVAILABLE_PASTE_TOOL="pbpaste"
                CLIPBOARD_METHOD="macOS-native"
                log_debug "Using macOS native clipboard (pbcopy/pbpaste)"
                return 0
            fi
            ;;
        "Linux-X11")
            # Bevorzuge xclip, dann xsel
            if has_command xclip; then
                AVAILABLE_COPY_TOOL="xclip -selection clipboard"
                AVAILABLE_PASTE_TOOL="xclip -selection clipboard -o"
                CLIPBOARD_METHOD="X11-xclip"
                log_debug "Using X11 clipboard via xclip"
                return 0
            elif has_command xsel; then
                AVAILABLE_COPY_TOOL="xsel --clipboard --input"
                AVAILABLE_PASTE_TOOL="xsel --clipboard --output"
                CLIPBOARD_METHOD="X11-xsel"
                log_debug "Using X11 clipboard via xsel"
                return 0
            fi
            ;;
        "Linux-Wayland")
            if has_command wl-copy && has_command wl-paste; then
                AVAILABLE_COPY_TOOL="wl-copy"
                AVAILABLE_PASTE_TOOL="wl-paste"
                CLIPBOARD_METHOD="Wayland-native"
                log_debug "Using Wayland clipboard (wl-copy/wl-paste)"
                return 0
            fi
            ;;
        "Windows")
            # Windows Subsystem for Linux oder native Windows
            if has_command clip.exe; then
                AVAILABLE_COPY_TOOL="clip.exe"
                AVAILABLE_PASTE_TOOL=""  # Windows clip.exe ist nur für Copy
                CLIPBOARD_METHOD="Windows-native"
                log_debug "Using Windows native clipboard (clip.exe)"
                return 0
            fi
            ;;
    esac
    
    log_warn "No suitable clipboard tools found for platform: $platform"
    return 1
}

# Prüfe ob Clipboard verfügbar ist
is_clipboard_available() {
    local check_paste="${1:-false}"
    
    if [[ -z "$AVAILABLE_COPY_TOOL" ]]; then
        detect_clipboard_tools || return 1
    fi
    
    # Prüfe Copy-Tool
    if ! eval "command -v ${AVAILABLE_COPY_TOOL%% *} >/dev/null 2>&1"; then
        return 1
    fi
    
    # Prüfe Paste-Tool falls gewünscht
    if [[ "$check_paste" == "true" && -n "$AVAILABLE_PASTE_TOOL" ]]; then
        if ! eval "command -v ${AVAILABLE_PASTE_TOOL%% *} >/dev/null 2>&1"; then
            return 1
        fi
    fi
    
    return 0
}

# ===============================================================================
# CLIPBOARD-OPERATIONEN
# ===============================================================================

# Kopiere Text in Clipboard
copy_to_clipboard() {
    local text="$1"
    local timeout="${2:-5}"  # Timeout in Sekunden
    
    if [[ -z "$text" ]]; then
        log_error "No text provided to copy"
        return 1
    fi
    
    if ! is_clipboard_available; then
        log_error "Clipboard not available"
        return 1
    fi
    
    log_debug "Copying text to clipboard using: $CLIPBOARD_METHOD"
    
    # Timeout-wrapper für Clipboard-Operationen
    local copy_command="echo '$text' | $AVAILABLE_COPY_TOOL"
    
    if eval "timeout $timeout bash -c \"$copy_command\" 2>/dev/null"; then
        log_debug "Successfully copied text to clipboard"
        return 0
    else
        local exit_code=$?
        if [[ $exit_code -eq 124 ]]; then
            log_error "Clipboard operation timed out after ${timeout}s"
        else
            log_error "Failed to copy to clipboard (exit code: $exit_code)"
        fi
        return 1
    fi
}

# Lese Text aus Clipboard
paste_from_clipboard() {
    local timeout="${1:-5}"  # Timeout in Sekunden
    
    if ! is_clipboard_available true; then
        log_error "Clipboard paste not available"
        return 1
    fi
    
    if [[ -z "$AVAILABLE_PASTE_TOOL" ]]; then
        log_error "No paste tool available"
        return 1
    fi
    
    log_debug "Reading from clipboard using: $CLIPBOARD_METHOD"
    
    # Timeout-wrapper für Paste-Operation
    if timeout "$timeout" bash -c "$AVAILABLE_PASTE_TOOL" 2>/dev/null; then
        log_debug "Successfully read from clipboard"
        return 0
    else
        local exit_code=$?
        if [[ $exit_code -eq 124 ]]; then
            log_error "Clipboard read timed out after ${timeout}s"
        else
            log_error "Failed to read from clipboard (exit code: $exit_code)"
        fi
        return 1
    fi
}

# Teste Clipboard-Funktionalität
test_clipboard() {
    local test_text="${1:-clipboard-test-$(date +%s)}"
    
    echo "Testing clipboard functionality..."
    echo "Platform: $(detect_platform)"
    
    # Erkenne Tools
    if ! detect_clipboard_tools; then
        echo "❌ No clipboard tools available"
        return 1
    fi
    
    echo "✓ Clipboard method: $CLIPBOARD_METHOD"
    echo "  Copy tool: $AVAILABLE_COPY_TOOL"
    echo "  Paste tool: $AVAILABLE_PASTE_TOOL"
    
    # Teste Copy
    echo "Testing copy operation..."
    if copy_to_clipboard "$test_text"; then
        echo "✓ Copy successful"
    else
        echo "❌ Copy failed"
        return 1
    fi
    
    # Teste Paste falls verfügbar
    if [[ -n "$AVAILABLE_PASTE_TOOL" ]]; then
        echo "Testing paste operation..."
        local pasted_text
        if pasted_text=$(paste_from_clipboard); then
            if [[ "$pasted_text" == "$test_text" ]]; then
                echo "✓ Paste successful (content matches)"
            else
                echo "⚠ Paste successful but content differs"
                echo "  Expected: '$test_text'"
                echo "  Got: '$pasted_text'"
            fi
        else
            echo "❌ Paste failed"
            return 1
        fi
    else
        echo "⚠ Paste functionality not available (copy-only mode)"
    fi
    
    echo "✓ Clipboard test completed successfully"
    return 0
}

# ===============================================================================
# ERWEITERTE CLIPBOARD-FUNKTIONEN
# ===============================================================================

# Kopiere mit Fallback-Strategien
copy_to_clipboard_with_fallback() {
    local text="$1"
    local show_instructions="${2:-true}"
    
    if [[ -z "$text" ]]; then
        log_error "No text provided to copy"
        return 1
    fi
    
    log_debug "Attempting clipboard copy with fallback"
    
    # Strategie 1: System-Clipboard
    if copy_to_clipboard "$text"; then
        echo "✓ Copied to system clipboard"
        return 0
    fi
    
    # Strategie 2: tmux-Buffer (falls in tmux)
    if [[ -n "${TMUX:-}" ]]; then
        if tmux set-buffer "$text" 2>/dev/null; then
            echo "✓ Copied to tmux buffer (use Prefix + ] to paste)"
            return 0
        fi
    fi
    
    # Strategie 3: Temporäre Datei für manuelles Kopieren
    local temp_file="/tmp/claude-session-id-$$.txt"
    if echo "$text" > "$temp_file" 2>/dev/null; then
        echo "⚠ Could not copy automatically. Text saved to: $temp_file"
        if [[ "$show_instructions" == "true" ]]; then
            echo "  Manual copy instructions:"
            echo "    cat '$temp_file'  # Display content"
            echo "    rm '$temp_file'   # Remove file when done"
        fi
        return 0
    fi
    
    # Strategie 4: Direkte Anzeige für manuelles Kopieren
    echo "⚠ Clipboard unavailable. Please copy manually:"
    echo ""
    echo "┌$(printf '─%.0s' $(seq 1 $((${#text} + 4))))┐"
    echo "│ $text │"
    echo "└$(printf '─%.0s' $(seq 1 $((${#text} + 4))))┘"
    echo ""
    
    return 1
}

# Zeige verfügbare Clipboard-Informationen
show_clipboard_info() {
    echo "Clipboard System Information:"
    echo "============================"
    
    local platform
    platform=$(detect_platform)
    echo "Platform: $platform"
    
    if detect_clipboard_tools; then
        echo "Status: Available"
        echo "Method: $CLIPBOARD_METHOD"
        echo "Copy Tool: $AVAILABLE_COPY_TOOL"
        echo "Paste Tool: ${AVAILABLE_PASTE_TOOL:-"Not available"}"
        
        # Zeige zusätzliche Informationen
        case "$platform" in
            "macOS")
                echo "Notes: Native macOS clipboard (pbcopy/pbpaste)"
                ;;
            "Linux-X11")
                echo "Notes: X11 clipboard (requires X session)"
                echo "Alternative: Install 'xclip' or 'xsel' packages"
                ;;
            "Linux-Wayland")
                echo "Notes: Wayland clipboard (requires Wayland session)"
                echo "Alternative: Install 'wl-clipboard' package"
                ;;
            "Windows")
                echo "Notes: Windows clipboard (clip.exe)"
                echo "Limitation: Copy-only (no paste support)"
                ;;
        esac
    else
        echo "Status: Not available"
        echo "Reason: No suitable clipboard tools found"
        
        # Gebe Installationshinweise
        case "$platform" in
            "Linux-X11"|"Linux-unknown")
                echo ""
                echo "To enable clipboard support, install one of:"
                echo "  • Ubuntu/Debian: sudo apt install xclip"
                echo "  • CentOS/RHEL: sudo yum install xclip"
                echo "  • Arch: sudo pacman -S xclip"
                ;;
            "Linux-Wayland")
                echo ""
                echo "To enable clipboard support, install:"
                echo "  • Ubuntu/Debian: sudo apt install wl-clipboard"
                echo "  • Arch: sudo pacman -S wl-clipboard"
                ;;
        esac
    fi
    
    # tmux-Buffer-Status
    if [[ -n "${TMUX:-}" ]]; then
        echo ""
        echo "tmux Buffer: Available (current session)"
        echo "  Copy to buffer: tmux set-buffer <text>"
        echo "  Paste from buffer: Prefix + ]"
    else
        echo ""
        echo "tmux Buffer: Not available (not in tmux session)"
    fi
}

# ===============================================================================
# INITIALISIERUNG
# ===============================================================================

# Initialisiere Clipboard-System
init_clipboard() {
    local force_redetect="${1:-false}"
    
    if [[ "$force_redetect" == "true" || -z "$CLIPBOARD_METHOD" ]]; then
        detect_clipboard_tools
    fi
    
    log_debug "Clipboard system initialized: $CLIPBOARD_METHOD"
}

# ===============================================================================
# MAIN ENTRY POINT (für Testing)
# ===============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "=== Clipboard Utility Test ==="
    echo ""
    
    case "${1:-}" in
        "--test")
            test_clipboard "${2:-}"
            ;;
        "--info")
            show_clipboard_info
            ;;
        "--copy")
            if [[ -n "${2:-}" ]]; then
                copy_to_clipboard_with_fallback "$2"
            else
                echo "Usage: $0 --copy <text>"
                exit 1
            fi
            ;;
        "--paste")
            if paste_from_clipboard; then
                echo "(pasted content shown above)"
            else
                echo "Failed to paste from clipboard"
            fi
            ;;
        *)
            echo "Usage: $0 [--test|--info|--copy <text>|--paste]"
            echo ""
            show_clipboard_info
            ;;
    esac
fi