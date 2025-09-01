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

# Enhanced shell PATH environment refresh (from 2025-08-27 enhancement)
refresh_shell_path() {
    log_debug "Refreshing shell PATH environment with enhanced detection"
    
    # Add common claunch installation paths to PATH
    local common_claunch_paths=(
        "$HOME/.local/bin"
        "$HOME/bin"
        "/usr/local/bin"
        "$HOME/.npm-global/bin"
        "$HOME/.nvm/versions/node/*/bin"
        "/opt/homebrew/bin"
    )
    
    for path in "${common_claunch_paths[@]}"; do
        # Handle glob patterns for NVM paths
        if [[ "$path" == *"*"* ]]; then
            for expanded_path in $path; do
                if [[ -d "$expanded_path" ]] && [[ ":$PATH:" != *":$expanded_path:"* ]]; then
                    export PATH="$expanded_path:$PATH"
                    log_debug "Added NVM path $expanded_path to current PATH"
                fi
            done
        else
            if [[ -d "$path" ]] && [[ ":$PATH:" != *":$path:"* ]]; then
                export PATH="$path:$PATH"
                log_debug "Added common path $path to current PATH"
            fi
        fi
    done
    
    # Refresh hash table for command lookups
    hash -r 2>/dev/null || true
    
    # Allow a moment for environment changes to take effect
    sleep 1
    
    log_debug "PATH refresh completed. Current PATH length: ${#PATH}"
}

# Enhanced claunch detection with comprehensive methods (from 2025-08-27 enhancement)
detect_claunch() {
    log_debug "Detecting claunch installation with enhanced multi-method approach"
    
    # First refresh the PATH to pick up any new installations
    refresh_shell_path
    
    # Multi-round detection with different strategies
    local detection_attempts=5
    local attempt=1
    local detection_methods=()
    
    while [[ $attempt -le $detection_attempts ]]; do
        log_debug "Detection attempt $attempt/$detection_attempts"
        
        # Method 1: Check if claunch is in PATH
        if has_command claunch; then
            CLAUNCH_PATH=$(command -v claunch 2>/dev/null)
            if [[ -n "$CLAUNCH_PATH" && -x "$CLAUNCH_PATH" ]]; then
                detection_methods+=("PATH lookup")
                log_debug "Found claunch via PATH: $CLAUNCH_PATH"
                return 0
            fi
        fi
        
        # Method 2: Check common installation paths
        local common_paths=(
            "$HOME/.local/bin/claunch"
            "$HOME/bin/claunch"
            "/usr/local/bin/claunch"
            "$HOME/.npm-global/bin/claunch"
            "/opt/homebrew/bin/claunch"
            "/usr/bin/claunch"
        )
        
        local found_common=false
        for path in "${common_paths[@]}"; do
            if [[ -x "$path" ]]; then
                CLAUNCH_PATH="$path"
                detection_methods+=("Common path")
                log_debug "Found claunch at common path: $CLAUNCH_PATH"
                found_common=true
                break
            fi
        done
        
        if [[ "$found_common" == "true" ]]; then
            return 0
        fi
        
        # Method 3: Search in NVM paths (for npm installations)
        local nvm_search_paths=("$HOME/.nvm/versions/node/*/bin/claunch")
        for nvm_path in "${nvm_search_paths[@]}"; do
            # Use shell globbing to expand the path
            for expanded_nvm_path in $nvm_path; do
                if [[ -x "$expanded_nvm_path" ]]; then
                    CLAUNCH_PATH="$expanded_nvm_path"
                    detection_methods+=("NVM path")
                    log_debug "Found claunch in NVM path: $CLAUNCH_PATH"
                    return 0
                fi
            done
        done
        
        # Method 4: Search via which/whereis commands
        if has_command which; then
            local which_result
            which_result=$(which claunch 2>/dev/null) || true
            if [[ -n "$which_result" && -x "$which_result" ]]; then
                CLAUNCH_PATH="$which_result"
                detection_methods+=("which command")
                log_debug "Found claunch via 'which': $CLAUNCH_PATH"
                return 0
            fi
        fi
        
        if has_command whereis; then
            local whereis_result
            whereis_result=$(whereis claunch 2>/dev/null | cut -d: -f2 | awk '{print $1}') || true
            if [[ -n "$whereis_result" && -x "$whereis_result" ]]; then
                CLAUNCH_PATH="$whereis_result"
                detection_methods+=("whereis command")
                log_debug "Found claunch via 'whereis': $CLAUNCH_PATH"
                return 0
            fi
        fi
        
        # If not found and we have more attempts, wait and refresh
        if [[ $attempt -lt $detection_attempts ]]; then
            log_debug "claunch not found, waiting 2s and refreshing environment..."
            sleep 2
            refresh_shell_path
        fi
        
        ((attempt++))
    done
    
    # Enhanced error reporting with diagnostic information
    log_error "claunch not found after $detection_attempts comprehensive detection attempts"
    log_error "Searched in:"
    log_error "  - PATH directories: $(echo "$PATH" | tr ':' ' ' | wc -w) locations"
    log_error "  - Common installation paths: $HOME/.local/bin, $HOME/bin, /usr/local/bin, etc."
    log_error "  - NVM node versions: $HOME/.nvm/versions/node/*/bin"
    log_error "  - System commands: which, whereis"
    log_error ""
    log_error "Possible solutions:"
    log_error "  1. Install claunch: ./scripts/install-claunch.sh"
    log_error "  2. Add claunch to PATH if already installed"
    log_error "  3. Use direct Claude CLI mode (fallback)"
    
    return 1
}

# Enhanced claunch validation with comprehensive testing (from 2025-08-27 enhancement)
validate_claunch() {
    log_debug "Validating claunch installation with comprehensive testing"
    
    if [[ -z "$CLAUNCH_PATH" ]]; then
        if ! detect_claunch; then
            log_error "claunch detection failed - cannot proceed with validation"
            return 1
        fi
    fi
    
    log_info "Performing comprehensive claunch validation at: $CLAUNCH_PATH"
    
    # Test 1: File existence and permissions
    if [[ ! -f "$CLAUNCH_PATH" ]]; then
        log_error "claunch file not found: $CLAUNCH_PATH"
        return 1
    fi
    
    if [[ ! -x "$CLAUNCH_PATH" ]]; then
        log_error "claunch file not executable: $CLAUNCH_PATH"
        return 1
    fi
    
    # Test 2: File type validation
    local file_type
    if file_type=$(file "$CLAUNCH_PATH" 2>/dev/null); then
        log_debug "claunch file type: $file_type"
    else
        log_warn "Could not determine file type for $CLAUNCH_PATH"
    fi
    
    # Test 3: Help command functionality
    log_debug "Testing claunch help command..."
    if ! "$CLAUNCH_PATH" --help >/dev/null 2>&1; then
        log_error "claunch at $CLAUNCH_PATH is not functional (help command failed)"
        log_error "This may indicate a corrupted or incompatible installation"
        return 1
    fi
    
    # Test 4: Version retrieval
    log_debug "Retrieving claunch version..."
    if CLAUNCH_VERSION=$("$CLAUNCH_PATH" --version 2>/dev/null | head -1); then
        log_info "claunch validated successfully: $CLAUNCH_VERSION"
    else
        log_warn "Could not determine claunch version (non-critical)"
        CLAUNCH_VERSION="unknown"
    fi
    
    # Test 5: List command (non-critical, may fail if no sessions)
    log_debug "Testing claunch list command..."
    if "$CLAUNCH_PATH" list >/dev/null 2>&1; then
        log_debug "claunch list command works"
    else
        log_debug "claunch list command failed (may be normal if no sessions exist)"
    fi
    
    log_info "claunch validation completed successfully"
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

# ===============================================================================
# PROJECT DETECTION AND CONTEXT MANAGEMENT (Issue #89)
# ===============================================================================

# Erkenne aktuelles Projekt mit Enhanced Project Context
detect_project() {
    local working_dir="${1:-$(pwd)}"
    
    log_debug "Detecting project from directory: $working_dir"
    
    # Generate unique project identifier using session-manager function
    if declare -f get_current_project_context >/dev/null 2>&1; then
        PROJECT_ID=$(get_current_project_context "$working_dir")
        log_debug "Generated project ID: $PROJECT_ID"
    else
        # Fallback if session-manager not available
        log_warn "session-manager functions not available, using basic project detection"
        PROJECT_ID=$(basename "$working_dir" | sed 's/[^a-zA-Z0-9-]//g')-$(date +%s | cut -c-6)
    fi
    
    # Backward compatible project name (for legacy code)
    PROJECT_NAME=$(basename "$working_dir")
    PROJECT_NAME=${PROJECT_NAME//[^a-zA-Z0-9_-]/_}
    
    log_info "Detected project: $PROJECT_NAME (ID: $PROJECT_ID)"
    
    # Create project-specific tmux session name
    TMUX_SESSION_NAME="${TMUX_SESSION_PREFIX}-${PROJECT_ID}"
    
    log_debug "Project-aware tmux session name: $TMUX_SESSION_NAME"
}

# Store project-specific session information
store_project_session_info() {
    local working_dir="${1:-$(pwd)}"
    
    # Ensure we have project context
    if [[ -z "${PROJECT_ID:-}" ]]; then
        log_warn "No project ID available for storing session info"
        return 1
    fi
    
    local session_file
    if declare -f get_session_file_path >/dev/null 2>&1; then
        session_file="$(get_session_file_path "$PROJECT_ID")"
    else
        session_file="$HOME/.claude_session_${PROJECT_ID}"
    fi
    
    # Create session metadata file
    local metadata_file="${session_file}.metadata"
    
    cat > "$metadata_file" <<EOF
{
  "project_id": "$PROJECT_ID",
  "project_name": "$PROJECT_NAME",
  "working_dir": "$working_dir",
  "tmux_session_name": "$TMUX_SESSION_NAME",
  "claunch_mode": "$CLAUNCH_MODE",
  "created": "$(date -Iseconds)",
  "created_timestamp": $(date +%s)
}
EOF
    
    log_debug "Stored project session metadata: $metadata_file"
    return 0
}

# Erkenne bestehende Session (Project-aware - Issue #89)
detect_existing_session() {
    local working_dir="${1:-$(pwd)}"
    
    log_debug "Detecting existing claunch session for project"
    
    # Ensure project context is established
    if [[ -z "${PROJECT_ID:-}" ]]; then
        detect_project "$working_dir"
    fi
    
    # Project-specific session file path
    local session_file
    if declare -f get_session_file_path >/dev/null 2>&1; then
        session_file="$(get_session_file_path "$PROJECT_ID")"
    else
        # Fallback to project-based naming
        session_file="$HOME/.claude_session_${PROJECT_ID}"
    fi
    
    log_debug "Checking for session file: $session_file"
    
    if [[ -f "$session_file" ]]; then
        SESSION_ID=$(cat "$session_file" 2>/dev/null)
        
        if [[ -n "$SESSION_ID" ]]; then
            log_info "Found existing session ID: $SESSION_ID (project: $PROJECT_ID)"
            
            # Prüfe ob tmux-Session existiert (im tmux-Modus)
            if [[ "$CLAUNCH_MODE" == "tmux" ]]; then
                if tmux has-session -t "$TMUX_SESSION_NAME" 2>/dev/null; then
                    log_info "Existing project tmux session found: $TMUX_SESSION_NAME"
                    return 0
                else
                    log_warn "Session file exists but tmux session not found for project: $PROJECT_ID"
                    return 1
                fi
            fi
            
            return 0
        else
            log_warn "Session file exists but is empty for project: $PROJECT_ID"
            return 1
        fi
    else
        log_debug "No existing session file found for project: $PROJECT_ID"
        return 1
    fi
}

# ===============================================================================
# CLAUNCH-WRAPPER-FUNKTIONEN
# ===============================================================================

# Starte neue claunch-Session (Project-aware - Issue #89)
start_claunch_session() {
    local working_dir="${1:-$(pwd)}"
    shift
    local claude_args=("$@")
    
    log_info "Starting new project-aware claunch session in $CLAUNCH_MODE mode"
    log_debug "Working directory: $working_dir"
    log_debug "Claude arguments: ${claude_args[*]}"
    
    # Ensure project detection first
    detect_project "$working_dir"
    
    # Wechsele ins Arbeitsverzeichnis
    cd "$working_dir"
    
    # Initialize local task queue if available
    if declare -f init_local_queue >/dev/null 2>&1; then
        log_debug "Attempting to initialize local task queue for project"
        if init_local_queue "$PROJECT_NAME" 2>/dev/null; then
            log_info "Local task queue initialized for project: $PROJECT_NAME"
        else
            log_debug "Local task queue initialization skipped or failed (non-critical)"
        fi
    fi
    
    # Baue claunch-Kommando zusammen
    local claunch_cmd=("$CLAUNCH_PATH")
    
    if [[ "$CLAUNCH_MODE" == "tmux" ]]; then
        claunch_cmd+=("--tmux")
        # Add project-specific session name if supported by claunch
        if "$CLAUNCH_PATH" --help 2>/dev/null | grep -q "\-\-session-name\|--name"; then
            claunch_cmd+=("--session-name" "$TMUX_SESSION_NAME")
            log_debug "Using explicit session name: $TMUX_SESSION_NAME"
        fi
    fi
    
    # Füge Claude-Argumente hinzu
    if [[ ${#claude_args[@]} -gt 0 ]]; then
        claunch_cmd+=("--" "${claude_args[@]}")
    fi
    
    log_debug "Executing project-aware claunch: ${claunch_cmd[*]}"
    
    # Führe claunch aus
    if "${claunch_cmd[@]}"; then
        log_info "Project-aware claunch session started successfully (project: $PROJECT_ID)"
        
        # Store project-specific session information
        store_project_session_info "$working_dir"
        
        # Aktualisiere Session-Informationen
        detect_existing_session "$working_dir"
        
        return 0
    else
        local exit_code=$?
        log_error "Failed to start project-aware claunch session (exit code: $exit_code)"
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

# Prüfe Session-Status (Project-aware - Issue #89)
check_session_status() {
    local working_dir="${1:-$(pwd)}"
    
    log_debug "Checking project-aware claunch session status"
    
    # Ensure project context
    if [[ -z "${PROJECT_ID:-}" ]]; then
        detect_project "$working_dir"
    fi
    
    if [[ "$CLAUNCH_MODE" == "tmux" ]]; then
        if tmux has-session -t "$TMUX_SESSION_NAME" 2>/dev/null; then
            log_debug "Project tmux session is active: $TMUX_SESSION_NAME"
            return 0
        else
            log_debug "Project tmux session not found: $TMUX_SESSION_NAME"
            return 1
        fi
    else
        # Im direct-Modus prüfen wir die projektspezifische Session-Datei
        local session_file
        if declare -f get_session_file_path >/dev/null 2>&1; then
            session_file="$(get_session_file_path "$PROJECT_ID")"
        else
            session_file="$HOME/.claude_session_${PROJECT_ID}"
        fi
        
        if [[ -f "$session_file" ]]; then
            log_debug "Session file exists for project: $PROJECT_ID"
            return 0
        else
            log_debug "No session file found for project: $PROJECT_ID"
            return 1
        fi
    fi
}

# Liste aktive Sessions (Enhanced with Project Context - Issue #89)
list_active_sessions() {
    log_info "Listing active project-aware claunch sessions"
    
    echo "=== Active Project-Aware Claude Sessions ==="
    
    # Nutze claunch list falls verfügbar
    if "$CLAUNCH_PATH" list >/dev/null 2>&1; then
        echo "Via claunch:"
        "$CLAUNCH_PATH" list
    else
        echo "claunch list not available, using file-based detection"
    fi
    
    # Enhanced project-aware session file detection
    echo ""
    echo "=== Project Session Files ==="
    local found_sessions=0
    local session_files=()
    
    # Find all project-specific session files efficiently
    mapfile -t session_files < <(find "$HOME" -name ".claude_session_*" -type f 2>/dev/null | sort)
    
    for session_file in "${session_files[@]}"; do
        local project_id
        project_id=$(basename "$session_file" | sed 's/^\.claude_session_//')
        
        local session_id
        session_id=$(cat "$session_file" 2>/dev/null || echo "invalid")
        
        # Look for associated metadata
        local metadata_file="${session_file}.metadata"
        local project_name="unknown"
        local working_dir="unknown"
        
        if [[ -f "$metadata_file" ]]; then
            if command -v jq >/dev/null 2>&1; then
                project_name=$(jq -r '.project_name // "unknown"' "$metadata_file" 2>/dev/null)
                working_dir=$(jq -r '.working_dir // "unknown"' "$metadata_file" 2>/dev/null)
            else
                # Fallback parsing without jq
                project_name=$(grep '"project_name":' "$metadata_file" | sed 's/.*"project_name": *"\\([^"]*\\)".*/\\1/' || echo "unknown")
                working_dir=$(grep '"working_dir":' "$metadata_file" | sed 's/.*"working_dir": *"\\([^"]*\\)".*/\\1/' || echo "unknown")
            fi
        fi
        
        printf "  %-25s %-15s %-40s %s\\n" "$project_id" "$project_name" "$working_dir" "$session_id"
        ((found_sessions++)) || true
    done
    
    # Check if we found any sessions
    if [[ $found_sessions -eq 0 ]]; then
        echo "  No project session files found"
    fi
    
    # Zeige project-aware tmux-Sessions
    if [[ "$CLAUNCH_MODE" == "tmux" ]] && has_command tmux; then
        echo ""
        echo "=== Active Project tmux Sessions ==="
        local tmux_sessions_found=0
        local session_lines=()
        
        mapfile -t session_lines < <(tmux list-sessions -F "#{session_name} #{session_created}" 2>/dev/null | grep "^$TMUX_SESSION_PREFIX")
        
        for session_line in "${session_lines[@]}"; do
            local session_name created_time
            session_name=$(echo "$session_line" | cut -d' ' -f1)
            created_time=$(echo "$session_line" | cut -d' ' -f2-)
            
            # Extract project ID from session name
            local project_id
            if [[ "$session_name" =~ ^${TMUX_SESSION_PREFIX}-(.+)$ ]]; then
                project_id="${BASH_REMATCH[1]}"
            else
                project_id="unknown"
            fi
            
            printf "  %-30s %-25s %s\\n" "$session_name" "$project_id" "$(date -d "@$created_time" 2>/dev/null || echo "unknown time")"
            ((tmux_sessions_found++)) || true
        done
        
        if [[ $tmux_sessions_found -eq 0 ]]; then
            echo "  No project tmux sessions found"
        fi
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

# Fallback detection and automatic mode switching
detect_and_configure_fallback() {
    log_info "Detecting optimal session management mode"
    
    # Try to detect and validate claunch
    if detect_claunch && validate_claunch; then
        log_info "claunch detected and validated - using claunch mode"
        USE_CLAUNCH="true"
        return 0
    else
        log_warn "claunch not available - switching to direct Claude CLI mode"
        log_info "This is a graceful fallback and the system will still function"
        USE_CLAUNCH="false"
        
        # Inform user about the mode switch with helpful information
        echo ""
        log_info "═══════════════════════════════════════════════════════════"
        log_info "  FALLBACK MODE: Direct Claude CLI"
        log_info "═══════════════════════════════════════════════════════════"
        log_info "The system has automatically switched to direct Claude CLI mode"
        log_info "because claunch is not available on this system."
        log_info ""
        log_info "What this means:"
        log_info "  ✓ The system will still work normally"
        log_info "  ✓ Claude CLI sessions will be managed directly"
        log_info "  ✗ No automatic session persistence across terminal restarts"
        log_info "  ✗ No tmux integration for background sessions"
        log_info ""
        log_info "To enable full claunch functionality:"
        log_info "  1. Install claunch: ./scripts/install-claunch.sh"
        log_info "  2. Or install manually: curl -sSL https://raw.githubusercontent.com/0xkaz/claunch/main/install.sh | bash"
        log_info "  3. Then restart the system to automatically detect claunch"
        log_info "═══════════════════════════════════════════════════════════"
        echo ""
        
        return 0  # Don't fail - this is a valid fallback mode
    fi
}

# Initialisiere claunch-Integration mit intelligenter Fallback-Erkennung
init_claunch_integration() {
    local config_file="${1:-config/default.conf}"
    local working_dir="${2:-$(pwd)}"
    
    log_info "Initializing claunch integration with fallback detection"
    
    # Lade Konfiguration
    if [[ -f "$config_file" ]]; then
        while IFS='=' read -r key value; do
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$key" ]] && continue
            
            # Remove leading/trailing quotes using parameter expansion
            value=${value#[\"\']}
            value=${value%[\"\']}
            
            case "$key" in
                USE_CLAUNCH|CLAUNCH_MODE|TMUX_SESSION_PREFIX)
                    eval "$key='$value'"
                    ;;
            esac
        done < <(grep -E '^[^#]*=' "$config_file" || true)
    fi
    
    # Intelligent mode detection with fallback
    if [[ "$USE_CLAUNCH" == "true" ]]; then
        log_debug "Configuration specifies claunch mode - attempting detection"
        detect_and_configure_fallback
    else
        log_info "claunch integration disabled by configuration - using direct mode"
        USE_CLAUNCH="false"
    fi
    
    # If claunch is enabled, check tmux availability for tmux mode
    if [[ "$USE_CLAUNCH" == "true" ]]; then
        if ! check_tmux_availability; then
            log_warn "tmux not available - falling back to claunch direct mode"
            CLAUNCH_MODE="direct"
        fi
    fi
    
    # Erkenne Projekt
    detect_project "$working_dir"
    
    # Report final configuration
    log_info "Session management configuration:"
    log_info "  Mode: $(if [[ "$USE_CLAUNCH" == "true" ]]; then echo "claunch ($CLAUNCH_MODE)"; else echo "direct Claude CLI"; fi)"
    log_info "  Project: $PROJECT_NAME"
    if [[ "$USE_CLAUNCH" == "true" && "$CLAUNCH_MODE" == "tmux" ]]; then
        log_info "  tmux session: $TMUX_SESSION_NAME"
    fi
    
    log_info "Session management initialization completed successfully"
    return 0
}

# Direct Claude CLI fallback functions
start_claude_direct() {
    local working_dir="${1:-$(pwd)}"
    shift
    local claude_args=("$@")
    
    log_info "Starting Claude CLI directly (no claunch)"
    log_debug "Working directory: $working_dir"
    log_debug "Claude arguments: ${claude_args[*]}"
    
    # Wechsele ins Arbeitsverzeichnis
    cd "$working_dir"
    
    # Baue Claude-Kommando zusammen
    local claude_cmd=("claude")
    
    # Füge Claude-Argumente hinzu
    if [[ ${#claude_args[@]} -gt 0 ]]; then
        claude_cmd+=("${claude_args[@]}")
    fi
    
    log_debug "Executing: ${claude_cmd[*]}"
    
    # Führe Claude direkt aus
    if "${claude_cmd[@]}"; then
        log_info "Claude session completed successfully"
        return 0
    else
        local exit_code=$?
        log_error "Claude session failed (exit code: $exit_code)"
        return $exit_code
    fi
}

start_claude_direct_in_new_terminal() {
    local working_dir="${1:-$(pwd)}"
    shift
    local claude_args=("$@")
    
    log_info "Starting Claude CLI in new terminal (direct mode)"
    
    # Stelle sicher, dass Terminal-Utils verfügbar sind
    if ! declare -f open_terminal_window >/dev/null 2>&1; then
        log_error "Terminal utilities not available for new terminal mode"
        log_info "Falling back to current terminal"
        start_claude_direct "$working_dir" "${claude_args[@]}"
        return $?
    fi
    
    # Baue Claude-Kommando für Terminal zusammen
    local claude_cmd=("claude")
    
    # Füge Claude-Argumente hinzu
    if [[ ${#claude_args[@]} -gt 0 ]]; then
        # Escape Argumente für Terminal
        local escaped_args=()
        for arg in "${claude_args[@]}"; do
            escaped_args+=("$(printf '%q' "$arg")")
        done
        claude_cmd+=("${escaped_args[@]}")
    fi
    
    # Öffne in Terminal
    cd "$working_dir"
    open_terminal_window "${claude_cmd[*]}" "$working_dir" "Claude Direct - $PROJECT_NAME"
}

# Starte oder setze Session fort mit intelligenter Fallback-Unterstützung
start_or_resume_session() {
    local working_dir="${1:-$(pwd)}"
    local use_new_terminal="${2:-false}"
    shift 2 2>/dev/null || shift $# # Remove processed args
    local claude_args=("$@")
    
    log_info "Starting or resuming session with intelligent mode selection"
    
    # Check if claunch mode is enabled and available
    if [[ "$USE_CLAUNCH" == "true" ]] && [[ -n "$CLAUNCH_PATH" ]]; then
        log_debug "Using claunch mode for session management"
        
        # Erkenne bestehende Session
        if detect_existing_session "$working_dir"; then
            log_info "Resuming existing claunch session"
            
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
            log_info "Starting new claunch session"
            
            if [[ "$use_new_terminal" == "true" ]]; then
                start_claunch_in_new_terminal "$working_dir" "${claude_args[@]}"
            else
                start_claunch_session "$working_dir" "${claude_args[@]}"
            fi
        fi
    else
        # Fallback to direct Claude CLI mode
        log_debug "Using direct Claude CLI mode (claunch not available)"
        
        if [[ "$use_new_terminal" == "true" ]]; then
            start_claude_direct_in_new_terminal "$working_dir" "${claude_args[@]}"
        else
            start_claude_direct "$working_dir" "${claude_args[@]}"
        fi
    fi
}

# Sende Recovery-Kommando mit Fallback-Unterstützung
send_recovery_command() {
    local recovery_cmd="${1:-/dev bitte mach weiter}"
    
    log_info "Sending recovery command to active session"
    
    # Only works in claunch mode with tmux
    if [[ "$USE_CLAUNCH" == "true" && "$CLAUNCH_MODE" == "tmux" ]]; then
        if check_session_status; then
            send_command_to_session "$recovery_cmd"
        else
            log_error "No active claunch session found for recovery command"
            return 1
        fi
    else
        log_warn "Recovery commands only supported in claunch tmux mode"
        log_info "Current mode: $(if [[ "$USE_CLAUNCH" == "true" ]]; then echo "claunch ($CLAUNCH_MODE)"; else echo "direct Claude CLI"; fi)"
        log_info "To use recovery commands, enable claunch with tmux mode"
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