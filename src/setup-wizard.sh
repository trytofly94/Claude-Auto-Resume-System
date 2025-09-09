#!/usr/bin/env bash

# Claude Auto-Resume - Setup Wizard
# User-Guided Session Setup Wizard für das Claude Auto-Resume System
# Version: 1.0.0-alpha
# Letzte Aktualisierung: 2025-08-31

set -euo pipefail

# Script directory detection (needed for module loading)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ===============================================================================
# CRITICAL: LOAD LOGGING MODULE FIRST (Issue #127)
# ===============================================================================

# Load logging utilities before any log calls
if [[ -f "$SCRIPT_DIR/utils/logging.sh" ]]; then
    source "$SCRIPT_DIR/utils/logging.sh"
else
    echo "ERROR: Cannot find logging utilities" >&2
    exit 1
fi

# ===============================================================================
# MODULAR ARCHITECTURE - LOAD WIZARD MODULES
# ===============================================================================

# Versuche modulare Architektur zu laden, fallback zu monolithischem Ansatz
WIZARD_MODULES_DIR="$SCRIPT_DIR/wizard"

if [[ -d "$WIZARD_MODULES_DIR" ]]; then
    # Lade Wizard-Module wenn verfügbar (now logging is available)
    for module in config validation detection; do
        module_path="$WIZARD_MODULES_DIR/${module}.sh"
        if [[ -f "$module_path" ]]; then
            source "$module_path"
            log_debug "Loaded wizard module: $module"
        fi
    done
    USING_MODULAR_ARCHITECTURE=true
else
    USING_MODULAR_ARCHITECTURE=false
    log_debug "Using monolithic wizard architecture"
fi

# ===============================================================================
# GLOBALE VARIABLEN UND KONSTANTEN (Fallback für monolithischen Ansatz)
# ===============================================================================

# Nur definieren falls nicht bereits durch Module geladen
if [[ "${USING_MODULAR_ARCHITECTURE:-false}" != "true" ]]; then
    # Wizard-spezifische Konfiguration
    WIZARD_VERSION="1.0.0"
    TMUX_SESSION_PREFIX="${TMUX_SESSION_PREFIX:-claude-auto-resume}"
    
    # Session-Tracking-Variablen (werden während des Setups gesetzt)
    TMUX_SESSION_NAME=""
    SESSION_ID=""
    DETECTED_SESSION_NAME=""
    DETECTED_SESSION_ID=""
    
    # Timeout-Konfiguration für bessere Zuverlässigkeit
    SETUP_SESSION_INIT_WAIT=5       # Warten nach Session-Erstellung
    SETUP_CLAUDE_STARTUP_WAIT=45    # Warten auf Claude-Initialisierung  
    SETUP_VALIDATION_WAIT=3         # Warten zwischen Validierungsschritten
    SETUP_CHECK_INTERVAL=3          # Intervall für Status-Checks
fi

# ===============================================================================
# HILFSFUNKTIONEN UND DEPENDENCIES
# ===============================================================================

# Timeout-Konfiguration für bessere Zuverlässigkeit
SETUP_SESSION_INIT_WAIT=5       # Warten nach Session-Erstellung
SETUP_CLAUDE_STARTUP_WAIT=45    # Warten auf Claude-Initialisierung  
SETUP_VALIDATION_WAIT=3         # Warten zwischen Validierungsschritten
SETUP_CHECK_INTERVAL=3          # Intervall für Status-Checks

# ===============================================================================
# INPUT VALIDATION FUNKTIONEN (Fallback für monolithischen Ansatz)
# ===============================================================================

# Nur definieren falls nicht bereits durch Module geladen
if [[ "${USING_MODULAR_ARCHITECTURE:-false}" != "true" ]]; then

# Validiert tmux session names gegen tmux naming rules
validate_tmux_session_name() {
    local session_name="$1"
    
    # Prüfe auf leeren Input
    if [[ -z "$session_name" ]]; then
        return 1
    fi
    
    # tmux session names dürfen nicht enthalten:
    # - Doppelpunkte (:) - werden für window/pane targeting verwendet
    # - Punkte (.) am Anfang - hidden sessions
    # - Whitespace am Anfang/Ende
    # - Sonderzeichen die Shell-Probleme verursachen können
    if [[ "$session_name" =~ ^[[:space:]]*$ ]]; then
        echo "Session name cannot be empty or only whitespace"
        return 1
    fi
    
    if [[ "$session_name" =~ : ]]; then
        echo "Session name cannot contain colons (:)"
        return 1
    fi
    
    if [[ "$session_name" =~ ^[.] ]]; then
        echo "Session name cannot start with a dot (.)"
        return 1
    fi
    
    if [[ "$session_name" =~ [[:space:]] ]]; then
        echo "Session name cannot contain spaces"
        return 1
    fi
    
    # Prüfe auf gefährliche Zeichen für Shell-Injection
    if [[ "$session_name" =~ [\$\`\;\|\&\>\<] ]]; then
        echo "Session name contains invalid characters (\$\`\;\|\&\>\<)"
        return 1
    fi
    
    # Längen-Validierung (tmux limit ist typischerweise ~200 chars)
    if [[ ${#session_name} -gt 100 ]]; then
        echo "Session name too long (max 100 characters)"
        return 1
    fi
    
    return 0
}

# Validiert Claude session ID format
validate_claude_session_id() {
    local session_id="$1"
    
    # Prüfe auf leeren Input
    if [[ -z "$session_id" ]]; then
        echo "Session ID cannot be empty"
        return 1
    fi
    
    # Entferne Whitespace
    session_id=$(echo "$session_id" | tr -d '[:space:]')
    
    # Auto-add sess- prefix falls nicht vorhanden (aber validiere das Format)
    if [[ ! "$session_id" =~ ^sess- ]]; then
        session_id="sess-$session_id"
    fi
    
    # Claude session IDs sollten dem Format sess-XXXX entsprechen
    # Typische Länge: sess- (5) + mindestens 8 Zeichen = mindestens 13 total
    if [[ ${#session_id} -lt 13 ]]; then
        echo "Session ID too short (minimum format: sess-XXXXXXXX)"
        return 1
    fi
    
    # Prüfe auf gültiges Format: sess- gefolgt von alphanumerischen Zeichen/Bindestriche
    if [[ ! "$session_id" =~ ^sess-[a-zA-Z0-9_-]+$ ]]; then
        echo "Invalid session ID format (must be sess-XXXX with alphanumeric characters)"
        return 1
    fi
    
    # Setze validierte Session ID zurück
    echo "$session_id"
    return 0
}

# Validiert Benutzer-Auswahlen für Multiple-Choice-Prompts
validate_choice() {
    local input="$1"
    local min_choice="$2"
    local max_choice="$3"
    
    # Prüfe auf leeren Input
    if [[ -z "$input" ]]; then
        echo "Please make a selection"
        return 1
    fi
    
    # Prüfe auf numerischen Input
    if [[ ! "$input" =~ ^[0-9]+$ ]]; then
        echo "Please enter a number"
        return 1
    fi
    
    # Prüfe Range
    if [[ $input -lt $min_choice ]] || [[ $input -gt $max_choice ]]; then
        echo "Please choose between $min_choice and $max_choice"
        return 1
    fi
    
    return 0
}

fi  # Ende der monolithischen Input-Validation-Funktionen

# Load remaining utility modules (logging already loaded above)
if [[ -f "$SCRIPT_DIR/session-manager.sh" ]]; then
    source "$SCRIPT_DIR/session-manager.sh"
else
    log_error "Cannot find session-manager.sh"
    exit 1
fi

# ===============================================================================
# SETUP WIZARD KERN-FUNKTIONEN
# ===============================================================================

# Haupt-Wizard-Funktion
setup_wizard_main() {
    log_info "Starting Claude Auto-Resume Setup Wizard v$WIZARD_VERSION"
    
    # Prüfe auf bestehende Session
    if detect_existing_session; then
        log_info "Existing session detected - starting monitoring"
        return 0
    fi
    
    show_wizard_introduction
    
    if run_setup_steps; then
        validate_complete_setup
        show_setup_completion
        return 0
    else
        log_error "Setup wizard failed"
        return 1
    fi
}

# Wizard-Einführung anzeigen
show_wizard_introduction() {
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════════════╗
║                    Claude Auto-Resume Setup Wizard                  ║
║                                                                      ║
║ This wizard will guide you through setting up automated Claude      ║
║ session management with tmux integration.                           ║
║                                                                      ║
║ Steps: 1) Check dependencies  2) Create tmux session                ║
║        3) Start Claude        4) Configure session ID               ║
║        5) Validate setup      6) Begin monitoring                   ║
╚══════════════════════════════════════════════════════════════════════╝
EOF
    
    echo ""
    echo "This setup wizard will help you:"
    echo "  • Verify all required dependencies are installed"
    echo "  • Create and configure a tmux session for Claude"  
    echo "  • Start Claude with proper session management"
    echo "  • Validate the complete setup before monitoring begins"
    echo ""
    read -r -p "Press Enter to begin setup or Ctrl+C to exit..."
    echo ""
}

# Setup-Schritte durchführen
run_setup_steps() {
    local steps=(
        "check_dependencies"
        "create_tmux_session"
        "start_claude_in_session"
        "configure_session_id"
        "validate_session_health"
    )
    
    local current_step=1
    local total_steps=${#steps[@]}
    
    for step in "${steps[@]}"; do
        echo "=== Step $current_step/$total_steps: $(format_step_name "$step") ==="
        echo ""
        
        if ! "$step"; then
            log_error "Setup step failed: $step"
            handle_step_failure "$step"
            return 1
        fi
        
        ((current_step++))
        echo ""
    done
    
    return 0
}

# Step-Namen für Benutzer formatieren
format_step_name() {
    case "$1" in
        "check_dependencies") echo "Checking Dependencies" ;;
        "create_tmux_session") echo "Creating tmux Session" ;;
        "start_claude_in_session") echo "Starting Claude" ;;
        "configure_session_id") echo "Configuring Session ID" ;;
        "validate_session_health") echo "Validating Setup" ;;
        *) echo "$1" ;;
    esac
}

# Setup-Abschluss anzeigen
show_setup_completion() {
    cat << 'EOF'

🎉 Setup Complete! 🎉

Your Claude Auto-Resume system is now configured and ready.

Configuration Summary:
EOF

    echo "  • tmux Session: $TMUX_SESSION_NAME"
    echo "  • Session ID: $SESSION_ID"
    echo "  • Project Directory: $(pwd)"
    
    local project_name
    project_name=$(basename "$(pwd)")
    local session_file="$HOME/.claude_session_${project_name}"
    echo "  • Session File: $session_file"
    
    echo ""
    echo "You can now:"
    echo "  • Monitor your session: tmux attach -t $TMUX_SESSION_NAME"
    echo "  • View logs: tail -f logs/hybrid-monitor.log"
    echo "  • The monitoring will begin automatically"
    echo ""
}

# ===============================================================================
# SESSION DETECTION FUNKTIONEN
# ===============================================================================

# Übergreifende Session-Detection
detect_existing_session() {
    log_debug "Comprehensive session detection starting"
    
    local detection_methods=(
        "check_tmux_sessions"
        "check_session_files"
        "check_process_tree"
    )
    
    for method in "${detection_methods[@]}"; do
        log_debug "Trying detection method: $method"
        
        if "$method"; then
            log_info "Session detected via $method"
            return 0
        fi
    done
    
    log_info "No existing Claude session detected"
    return 1
}

# Prüfe tmux-Sessions auf Claude-Sessions
check_tmux_sessions() {
    local project_name
    project_name=$(basename "$(pwd)")
    local session_pattern="${TMUX_SESSION_PREFIX}-${project_name}"
    
    # Prüfe exakte Übereinstimmung
    if tmux has-session -t "$session_pattern" 2>/dev/null; then
        DETECTED_SESSION_NAME="$session_pattern"
        log_info "Found exact session match: $session_pattern"
        return 0
    fi
    
    # Prüfe auf Pattern-Matches
    local matching_sessions
    matching_sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -E "claude|auto-resume" || true)
    
    if [[ -n "$matching_sessions" ]]; then
        log_info "Found potential Claude sessions: $matching_sessions"
        DETECTED_SESSION_NAME=$(echo "$matching_sessions" | head -1)
        return 0
    fi
    
    return 1
}

# Prüfe Session-Dateien
check_session_files() {
    local project_name
    project_name=$(basename "$(pwd)")
    local session_files=(
        "$HOME/.claude_session_${project_name}"
        "$HOME/.claude_auto_resume_${project_name}"
        "$(pwd)/.claude_session"
    )
    
    for file in "${session_files[@]}"; do
        if [[ -f "$file" && -s "$file" ]]; then
            local session_id
            session_id=$(cat "$file" 2>/dev/null || echo "")
            if [[ -n "$session_id" ]]; then
                log_info "Found session file: $file with ID: $session_id"
                DETECTED_SESSION_ID="$session_id"
                return 0
            fi
        fi
    done
    
    return 1
}

# Prüfe Prozess-Baum auf Claude-Instanzen
check_process_tree() {
    local claude_processes
    claude_processes=$(pgrep -f "claude" 2>/dev/null || true)
    
    if [[ -n "$claude_processes" ]]; then
        log_info "Found running Claude processes: $claude_processes"
        
        # Prüfe ob in tmux läuft
        for pid in $claude_processes; do
            if tmux list-panes -F '#{pane_pid}' 2>/dev/null | grep -q "$pid"; then
                log_info "Found Claude process $pid running in tmux"
                return 0
            fi
        done
    fi
    
    return 1
}

# ===============================================================================
# SETUP STEPS IMPLEMENTIERUNG
# ===============================================================================

# Schritt 1: Abhängigkeiten prüfen
check_dependencies() {
    echo "Checking system dependencies..."
    
    local required_commands=("tmux" "claude")
    local optional_commands=("claunch" "jq")
    local missing_required=()
    local missing_optional=()
    
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_required+=("$cmd")
        else
            echo "✓ $cmd found: $(command -v "$cmd")"
        fi
    done
    
    for cmd in "${optional_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_optional+=("$cmd")
        else
            echo "✓ $cmd found: $(command -v "$cmd")"
        fi
    done
    
    if [[ ${#missing_required[@]} -gt 0 ]]; then
        echo ""
        echo "❌ Missing required dependencies: ${missing_required[*]}"
        show_dependency_installation_help "${missing_required[@]}"
        return 1
    fi
    
    if [[ ${#missing_optional[@]} -gt 0 ]]; then
        echo ""
        echo "⚠️  Optional dependencies missing: ${missing_optional[*]}"
        echo "   (These provide enhanced functionality but are not required)"
    fi
    
    echo ""
    echo "✅ Dependencies check completed successfully"
    read -r -p "Press Enter to continue..."
    return 0
}

# Installations-Hilfe für fehlende Abhängigkeiten anzeigen
show_dependency_installation_help() {
    local missing_deps=("$@")
    
    echo ""
    echo "Installation instructions:"
    
    for dep in "${missing_deps[@]}"; do
        case "$dep" in
            "tmux")
                echo "  tmux:"
                echo "    macOS: brew install tmux"
                echo "    Ubuntu: apt install tmux"
                echo "    CentOS: yum install tmux"
                ;;
            "claude")
                echo "  claude:"
                echo "    Install Claude CLI from https://claude.ai/code"
                echo "    Follow the installation instructions for your platform"
                ;;
            "claunch")
                echo "  claunch (optional):"
                echo "    Run: ./scripts/install-claunch.sh"
                echo "    Or install manually from claunch documentation"
                ;;
        esac
    done
    
    echo ""
    echo "Please install the missing dependencies and run the wizard again."
    echo "You can restart this wizard with: $0 --setup-wizard"
}

# Schritt 2: tmux Session erstellen
create_tmux_session() {
    local project_name
    project_name=$(basename "$(pwd)")
    local session_name="${TMUX_SESSION_PREFIX}-${project_name}"
    
    echo "Creating tmux session for project: $project_name"
    echo "Session name: $session_name"
    echo "Working directory: $(pwd)"
    echo ""
    
    # Prüfe ob Session bereits existiert
    if tmux has-session -t "$session_name" 2>/dev/null; then
        echo "⚠️  Session '$session_name' already exists."
        echo ""
        echo "Options:"
        echo "  1) Use existing session (recommended)"
        echo "  2) Kill existing and create new session"
        echo "  3) Create session with different name"
        echo ""
        
        while true; do
            read -r -p "Choose option (1-3): " choice
            
            # Validiere Benutzer-Eingabe
            if ! validate_choice "$choice" 1 3; then
                continue
            fi
            
            case $choice in
                1)
                    TMUX_SESSION_NAME="$session_name"
                    echo "✓ Using existing session: $session_name"
                    return 0
                    ;;
                2)
                    tmux kill-session -t "$session_name" 2>/dev/null || true
                    echo "Existing session killed"
                    break
                    ;;
                3)
                    while true; do
                        read -r -p "Enter new session name: " custom_name
                        
                        # Validiere Session-Name
                        if validation_msg=$(validate_tmux_session_name "$custom_name"); then
                            session_name="$custom_name"
                            echo "✓ Using custom session name: $session_name"
                            break 2  # Verlasse beide while-loops
                        else
                            echo "Invalid session name: $validation_msg"
                            echo "Please try again."
                        fi
                    done
                    ;;
            esac
        done
    fi
    
    echo "Creating new tmux session..."
    echo "Command: tmux new-session -d -s '$session_name' -c '$(pwd)'"
    
    if tmux new-session -d -s "$session_name" -c "$(pwd)"; then
        echo "✓ tmux session created successfully"
        TMUX_SESSION_NAME="$session_name"
        
        # Warten bis Session vollständig initialisiert ist (erhöht für bessere Zuverlässigkeit)
        log_debug "Waiting ${SETUP_SESSION_INIT_WAIT}s for session initialization"
        sleep $SETUP_SESSION_INIT_WAIT
        
        # Session-Verifizierung
        if tmux has-session -t "$session_name" 2>/dev/null; then
            echo "✓ Session verification passed"
        else
            echo "❌ Session verification failed"
            return 1
        fi
    else
        echo "❌ Failed to create tmux session"
        echo "Please check tmux installation and permissions"
        return 1
    fi
    
    echo ""
    read -r -p "Press Enter to continue to Claude setup..."
    return 0
}

# Schritt 3: Claude in Session starten
start_claude_in_session() {
    echo "Starting Claude in tmux session: $TMUX_SESSION_NAME"
    echo ""
    echo "This step will:"
    echo "  1. Send 'claude continue' command to your tmux session"
    echo "  2. Wait for Claude to initialize"
    echo "  3. Check for successful startup"
    echo ""
    
    read -r -p "Press Enter to start Claude..."
    
    # Verwende bewährte tmux send-keys Methode
    local claude_command="claude continue"
    echo "Sending command: $claude_command"
    
    if tmux send-keys -t "$TMUX_SESSION_NAME" "$claude_command" C-m; then
        echo "✓ Command sent successfully"
    else
        echo "❌ Failed to send command to tmux session"
        return 1
    fi
    
    echo ""
    echo "Claude is starting up..."
    echo "This may take up to ${SETUP_CLAUDE_STARTUP_WAIT} seconds depending on your connection."
    echo ""
    
    # Warte auf Claude-Initialisierung mit erhöhten Timeouts für bessere Zuverlässigkeit
    local wait_time=$SETUP_CLAUDE_STARTUP_WAIT
    local check_interval=$SETUP_CHECK_INTERVAL
    local elapsed=0
    
    echo "Waiting for Claude to initialize (timeout: ${wait_time}s)..."
    while [[ $elapsed -lt $wait_time ]]; do
        printf "."
        sleep $check_interval
        elapsed=$((elapsed + check_interval))
        
        # Prüfe ob Claude gestartet ist durch Session-Output-Analyse
        local session_output
        session_output=$(tmux capture-pane -t "$TMUX_SESSION_NAME" -p 2>/dev/null || echo "")
        
        if echo "$session_output" | grep -q "claude\|Claude\|session\|sess-"; then
            echo ""
            echo "✓ Claude appears to be running"
            break
        fi
    done
    
    echo ""
    echo "Current session status:"
    tmux capture-pane -t "$TMUX_SESSION_NAME" -p | tail -10
    
    echo ""
    echo "Please verify that Claude is running properly in your tmux session."
    echo "You can check by running: tmux attach -t $TMUX_SESSION_NAME"
    echo ""
    
    while true; do
        read -r -p "Is Claude running successfully? (y/n): " response
        case $response in
            [Yy]*)
                echo "✓ Claude startup confirmed"
                return 0
                ;;
            [Nn]*)
                echo "❌ Claude startup failed"
                echo ""
                echo "Troubleshooting steps:"
                echo "  1. Check Claude CLI installation: claude --version"
                echo "  2. Verify internet connection"
                echo "  3. Check Claude authentication status"
                echo "  4. Review tmux session: tmux attach -t $TMUX_SESSION_NAME"
                echo ""
                echo "You can also try manual setup:"
                echo "  1. Attach to session: tmux attach -t $TMUX_SESSION_NAME"
                echo "  2. Start Claude manually: claude continue"
                echo "  3. Detach with: Ctrl+b, then d"
                echo "  4. Restart wizard: $0 --setup-wizard"
                return 1
                ;;
            *)
                echo "Please answer y or n"
                ;;
        esac
    done
}

# Schritt 4: Session ID konfigurieren
configure_session_id() {
    echo "Configuring Claude session ID..."
    echo ""
    echo "Claude generates a unique session ID when it starts."
    echo "This ID typically looks like: sess-xxxxxxxxxxxxxxxxxx"
    echo ""
    echo "To find your session ID:"
    echo "  1. Look at the current Claude output in your tmux session"
    echo "  2. Or ask Claude: 'What is my session ID?'"
    echo "  3. Or check Claude's startup messages"
    echo ""
    
    # Versuche Session ID automatisch zu erkennen
    local detected_session_id=""
    local session_output
    session_output=$(tmux capture-pane -t "$TMUX_SESSION_NAME" -p 2>/dev/null || echo "")
    
    # Suche nach Session ID Patterns im Output
    detected_session_id=$(echo "$session_output" | grep -o "sess-[a-zA-Z0-9]\{20\}" | head -1 || echo "")
    
    if [[ -n "$detected_session_id" ]]; then
        echo "✓ Detected session ID automatically: $detected_session_id"
        echo ""
        while true; do
            read -r -p "Use this detected session ID? (y/n): " response
            case $response in
                [Yy]*)
                    SESSION_ID="$detected_session_id"
                    break
                    ;;
                [Nn]*)
                    detected_session_id=""
                    break
                    ;;
                *)
                    echo "Please answer y or n"
                    ;;
            esac
        done
    fi
    
    # Manuelle Session ID Eingabe falls nicht erkannt oder nicht akzeptiert
    if [[ -z "$detected_session_id" ]]; then
        echo "Manual session ID entry required."
        echo ""
        echo "Please check your tmux session to find the session ID:"
        echo "  tmux attach -t $TMUX_SESSION_NAME"
        echo ""
        echo "You can detach from tmux with: Ctrl+b, then d"
        echo ""
        
        while true; do
            read -r -p "Enter session ID (with or without 'sess-' prefix): " input_session_id
            
            # Validiere Session ID mit umfassender Validierung
            if validated_session_id=$(validate_claude_session_id "$input_session_id"); then
                SESSION_ID="$validated_session_id"
                echo "✓ Session ID validated: $SESSION_ID"
                break
            else
                echo "Invalid session ID: $validated_session_id"
                echo "Please try again."
                echo ""
                echo "Session ID format help:"
                echo "  • Should be at least 8 characters (without sess- prefix)"
                echo "  • Can contain letters, numbers, underscores, and hyphens"
                echo "  • Examples: sess-abc123, abc123-def456, my_session_123"
                echo ""
                continue
            fi
        done
    fi
    
    # Speichere Session ID für Persistenz
    local project_name
    project_name=$(basename "$(pwd)")
    local session_file="$HOME/.claude_session_${project_name}"
    
    echo "$SESSION_ID" > "$session_file"
    echo "✓ Session ID saved to: $session_file"
    
    echo ""
    read -r -p "Press Enter to continue to validation..."
    return 0
}

# Schritt 5: Session Health Validation
validate_session_health() {
    echo "Validating complete setup..."
    echo ""
    
    local validation_steps=(
        "validate_tmux_session"
        "validate_claude_process" 
        "validate_session_id"
        "validate_connectivity"
    )
    
    local failed_validations=()
    
    for step in "${validation_steps[@]}"; do
        echo -n "$(format_validation_name "$step")... "
        
        if "$step"; then
            echo "✓"
        else
            echo "❌"
            failed_validations+=("$step")
        fi
    done
    
    echo ""
    
    if [[ ${#failed_validations[@]} -eq 0 ]]; then
        echo "🎉 All validations passed! Setup is complete."
        return 0
    else
        echo "⚠️  Some validations failed: ${failed_validations[*]}"
        echo ""
        echo "You can:"
        echo "  1. Continue anyway (monitoring may have issues)"
        echo "  2. Retry failed validations"
        echo "  3. Restart setup wizard"
        echo ""
        
        while true; do
            read -r -p "Choose option (1-3): " choice
            case $choice in
                1)
                    echo "⚠️  Continuing with failed validations..."
                    return 0
                    ;;
                2)
                    if retry_failed_validations "${failed_validations[@]}"; then
                        return 0
                    else
                        return 1
                    fi
                    ;;
                3)
                    return 1
                    ;;
                *)
                    echo "Please enter 1, 2, or 3"
                    ;;
            esac
        done
    fi
}

# Validation-Namen für Benutzer formatieren
format_validation_name() {
    case "$1" in
        "validate_tmux_session") echo "tmux session exists" ;;
        "validate_claude_process") echo "Claude process running" ;;
        "validate_session_id") echo "Session ID valid" ;;
        "validate_connectivity") echo "Claude connectivity" ;;
        *) echo "$1" ;;
    esac
}

# Einzelne Validierungs-Funktionen
validate_tmux_session() {
    if [[ -z "$TMUX_SESSION_NAME" ]]; then
        return 1
    fi
    
    tmux has-session -t "$TMUX_SESSION_NAME" 2>/dev/null
}

validate_claude_process() {
    if [[ -z "$TMUX_SESSION_NAME" ]]; then
        return 1
    fi
    
    local session_output
    session_output=$(tmux capture-pane -t "$TMUX_SESSION_NAME" -p 2>/dev/null || echo "")
    
    # Suche nach Claude-Indikatoren
    if echo "$session_output" | grep -q "claude\|Claude\|session\|sess-"; then
        return 0
    fi
    
    return 1
}

validate_session_id() {
    if [[ -z "$SESSION_ID" ]]; then
        return 1
    fi
    
    # Prüfe Format
    if [[ ! "$SESSION_ID" =~ ^sess- ]]; then
        return 1
    fi
    
    # Prüfe Länge
    if [[ ${#SESSION_ID} -lt 10 ]]; then
        return 1
    fi
    
    return 0
}

validate_connectivity() {
    # Einfacher Konnektivitäts-Test
    if timeout 10 claude --help >/dev/null 2>&1; then
        return 0
    fi
    
    return 1
}

# Wiederholung fehlgeschlagener Validierungen
retry_failed_validations() {
    local failed_validations=("$@")
    echo ""
    echo "Retrying failed validations..."
    echo ""
    
    for step in "${failed_validations[@]}"; do
        echo -n "Retrying $(format_validation_name "$step")... "
        
        if "$step"; then
            echo "✓ (fixed)"
        else
            echo "❌ (still failing)"
            return 1
        fi
    done
    
    echo ""
    echo "✅ All validation retries successful!"
    return 0
}

# ===============================================================================
# FEHLERBEHANDLUNG
# ===============================================================================

# Behandlung von Step-Fehlern
handle_step_failure() {
    local failed_step="$1"
    
    echo ""
    echo "❌ Setup step failed: $(format_step_name "$failed_step")"
    echo ""
    echo "Recovery options:"
    echo "  1. Retry this step"
    echo "  2. Skip this step (may cause issues)"
    echo "  3. Restart wizard from beginning"
    echo "  4. Exit wizard"
    echo ""
    
    while true; do
        read -r -p "Choose option (1-4): " choice
        case $choice in
            1)
                echo "Retrying step: $(format_step_name "$failed_step")"
                return 0
                ;;
            2)
                echo "⚠️  Skipping step: $(format_step_name "$failed_step")"
                echo "   This may cause monitoring issues later"
                return 0
                ;;
            3)
                echo "Restarting wizard..."
                setup_wizard_main
                return $?
                ;;
            4)
                echo "Exiting wizard"
                exit 1
                ;;
            *)
                echo "Please enter 1, 2, 3, or 4"
                ;;
        esac
    done
}

# ===============================================================================
# EXPORTIERTE FUNKTIONEN
# ===============================================================================

# Mache Haupt-Funktionen verfügbar für externe Scripts
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    # Script wird gesourced - exportiere nur erforderliche Funktionen
    export -f setup_wizard_main
    export -f detect_existing_session
fi