# Hybrid Claude CLI Automation: Monitoring + claunch Integration

## Konzept-Übersicht

Der hybride Ansatz kombiniert das bewährte **Usage-Limit-Monitoring** aus Ihrem bestehenden `claude-auto-resume-continuous-v4` Skript mit der **überlegenen Session-Management-Funktionalität** von `claunch`. Diese Lösung adressiert beide Kernprobleme:

1. **Automatische Usage-Limit-Erholung** durch bewährtes Monitoring
2. **Zuverlässige Session-Kontinuität** durch claunch's projektbasierte Session-Verwaltung

### Architektur-Diagramm

```
┌─────────────────────────────────────────────────────────────┐
│                 Monitoring-Terminal                         │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  Ihr bestehender Monitoring-Code                   │    │
│  │  • check_claude_limits()                           │    │
│  │  • Usage-Limit-Detection                           │    │
│  │  • Periodische Checks alle 5 Min                   │    │
│  └─────────────────────────────────────────────────────┘    │
│                            │                                │
│                            ▼                                │
│    Bei Usage Limit: tmux send-keys "/dev bitte mach weiter" │
└─────────────────────────────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────┐
│                Interactive Terminal                         │
│  ┌─────────────────────────────────────────────────────┐    │
│  │                 claunch Session                     │    │
│  │  • Projektbasierte Session-Verwaltung               │    │
│  │  • Automatische --resume mit Session-IDs           │    │
│  │  • tmux-Persistenz (optional)                      │    │
│  │  • CLAUDE.md Memory-Management                      │    │
│  └─────────────────────────────────────────────────────┘    │
│                                                             │
│  Benutzer arbeitet hier interaktiv mit Claude              │
└─────────────────────────────────────────────────────────────┘
```

## claunch: Vollständige Dokumentation

### Was ist claunch?

**claunch** (Claude + Launch) ist ein lightweight Session-Manager für Claude CLI, der projektbasierte Session-Verwaltung mit automatischer tmux-Integration bietet. Es löst das fundamentale Problem der Context-Loss in Claude CLI durch intelligente Session-Persistenz.

### Kernfeatures

#### 🧠 **Projektbasierte Session-Verwaltung**
- Automatische Session-Erkennung per Projektverzeichnis
- Session-IDs werden in `~/.claude_session_PROJECT_NAME` gespeichert
- Automatisches Resume beim Neustart

#### 🔄 **Zwei Betriebsmodi**
```bash
claunch          # Direct Mode - Lightweight, schnell
claunch --tmux   # Persistent Mode - Überlebt Terminal-Crashes
```

#### 📁 **Intelligente Projekt-Erkennung**
- Auto-Detection basierend auf Verzeichnisnamen
- Separate Sessions für jedes Projekt
- Session-Isolation zwischen Projekten

#### 🛠️ **Session-Management-Commands**
```bash
claunch list     # Zeigt alle aktiven Sessions
claunch clean    # Bereinigt verwaiste Session-Dateien
claunch --help   # Vollständige Hilfe
```

### Installation

#### Option 1: npm Installation (Empfohlen)
```bash
npm install -g @0xkaz/claunch
```

#### Option 2: Direkte Installation nach $HOME/bin
```bash
curl -fsSL https://raw.githubusercontent.com/0xkaz/claunch/main/install.sh | bash
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

#### Option 3: Von Source bauen
```bash
git clone https://github.com/0xkaz/claunch.git
cd claunch
npm install -g .
```

### Basis-Verwendung

#### Neues Projekt starten
```bash
cd /path/to/your/project
claunch
# ✓ Claude CLI session started for: your-project
# Session-ID wird automatisch gespeichert
```

#### Session fortsetzen
```bash
cd /path/to/your/project
claunch
# Lädt automatisch die existierende Session
# Kontext bleibt vollständig erhalten
```

#### Mit tmux-Persistenz (Empfohlen für kritische Sessions)
```bash
cd /path/to/your/project
claunch --tmux
# 🚀 Creating tmux session: your-project
# ✓ Persistent Claude session started
```

### Erweiterte Features

#### Multi-Projekt-Workflow
```bash
# Terminal 1: Web-App
cd ~/projects/webapp
claunch --tmux

# Terminal 2: API
cd ~/projects/api  
claunch --tmux

# Terminal 3: Mobile App
cd ~/projects/mobile
claunch --tmux

# Jedes Projekt behält seinen eigenen Kontext
```

#### Session-Management
```bash
# Aktive Sessions anzeigen
claunch list
# Output:
# 📋 Active Claude sessions:
# - webapp: sess-abc123def
# - api: sess-ghi456jkl  
# - mobile: sess-mno789pqr

# Verwaiste Sessions bereinigen
claunch clean
# 🧹 Cleaned up 2 orphaned session files
```

#### tmux-Integration (Persistent Mode)

Wenn Sie `claunch --tmux` verwenden, erhalten Sie Zugriff auf tmux-Befehle:

```bash
# Session detachen (läuft im Hintergrund weiter)
Ctrl+B, dann d

# Session wieder anhängen
tmux attach -t claude-PROJEKTNAME

# Sessions auflisten
tmux list-sessions

# Session beenden
tmux kill-session -t claude-PROJEKTNAME
```

### claunch Konfiguration

#### Automatische tmux-Installation
claunch installiert tmux automatisch, wenn es nicht vorhanden ist:
- **macOS**: `brew install tmux`
- **Ubuntu/Debian**: `apt-get install tmux`
- **CentOS/RHEL**: `yum install tmux`

#### Session-Dateien-Verwaltung
```bash
# Session-Dateien-Pfad
~/.claude_session_PROJEKTNAME

# Beispiel für Projekt "webapp"
~/.claude_session_webapp
# Inhalt: sess-abc123def456
```

#### Erweiterte Konfiguration
```bash
# Benutzerdefinierte Projekt-Namen
CLAUNCH_PROJECT_NAME="custom-name" claunch

# Debug-Modus
DEBUG=1 claunch --tmux

# Claude-spezifische Flags weiterleiten
claunch --tmux -- --model opus-4 --verbose
```

## Hybrid-Integration: Implementierung

### 1. Erweiterte Monitoring-Funktion

```bash
#!/bin/bash
# hybrid-claude-monitor.sh

# Bestehende Variablen aus Ihrem Skript
CHECK_INTERVAL_MINUTES=5
MAX_RESTARTS=50
RESTART_COUNT=0
DEBUG_MODE=false

# Neue Hybrid-Variablen
USE_CLAUNCH=true
CLAUNCH_MODE="tmux"  # oder "direct"
PROJECT_NAME=""
TMUX_SESSION_NAME=""

# Auto-detect Projekt aus Verzeichnis
detect_project_info() {
    PROJECT_NAME=$(basename "$(pwd)")
    TMUX_SESSION_NAME="claude-${PROJECT_NAME}"
    
    debug_echo "Detected project: $PROJECT_NAME"
    debug_echo "Expected tmux session: $TMUX_SESSION_NAME"
}

# Erweiterte claunch-Session-Erkennung
detect_claunch_session() {
    local session_file="$HOME/.claude_session_${PROJECT_NAME}"
    local detected_session=""
    
    # Prüfe claunch Session-Datei
    if [ -f "$session_file" ]; then
        local session_id=$(cat "$session_file")
        debug_echo "Found claunch session ID: $session_id"
    fi
    
    # Bei tmux-Modus: Erkenne aktive tmux-Session
    if [ "$CLAUNCH_MODE" = "tmux" ]; then
        detected_session=$(tmux list-sessions -F "#{session_name}" 2>/dev/null | grep "^claude-${PROJECT_NAME}$" | head -1)
        if [ -n "$detected_session" ]; then
            TMUX_SESSION_NAME="$detected_session"
            debug_echo "Active tmux session found: $TMUX_SESSION_NAME"
            return 0
        fi
    fi
    
    return 1
}

# Intelligente Usage-Limit-Detection mit tmux-Integration
check_claude_limits_hybrid() {
    debug_echo "Checking Claude usage limits (hybrid mode)..."
    
    local claude_output=""
    local ret_code=0
    
    # Test-Modus (aus Ihrem bestehenden Code)
    if [ "$TEST_MODE" = true ]; then
        echo "[TEST MODE] Simulating usage limit..."
        local now_timestamp=$(date +%s)
        local resume_timestamp=$((now_timestamp + TEST_WAIT_SECONDS))
        claude_output="Claude AI usage limit reached|$resume_timestamp"
        ret_code=1
    else
        # Hybrid-Modus: Prüfe je nach Session-Typ
        if [ "$CLAUNCH_MODE" = "tmux" ] && tmux has-session -t "$TMUX_SESSION_NAME" 2>/dev/null; then
            # tmux-basierte Erkennung - capture pane output
            claude_output=$(tmux capture-pane -t "$TMUX_SESSION_NAME" -p 2>/dev/null || echo "")
            if echo "$claude_output" | grep -q "usage limit reached\|Claude AI usage limit"; then
                ret_code=1
                debug_echo "Usage limit detected in tmux session output"
            fi
        else
            # Fallback: Traditionelle Claude CLI-Prüfung
            claude_output=$(timeout 30s claude -p 'check' 2>&1)
            ret_code=$?
        fi
    fi
    
    # Verarbeite Ergebnis (aus Ihrem bestehenden Code)
    if [ $ret_code -eq 124 ]; then
        echo "[WARNING] Claude CLI operation timed out after 30 seconds."
        return 2
    fi
    
    # Check für Usage Limit
    local limit_msg=$(echo "$claude_output" | grep "Claude AI usage limit reached\|usage limit reached")
    
    if [ -n "$limit_msg" ]; then
        debug_echo "Usage limit detected: $limit_msg"
        handle_usage_limit_hybrid
        return 1
    fi
    
    return 0
}

# Hybrid Usage-Limit-Handler
handle_usage_limit_hybrid() {
    echo "$(date): Usage limit detected in $PROJECT_NAME session"
    
    if [ "$CLAUNCH_MODE" = "tmux" ] && tmux has-session -t "$TMUX_SESSION_NAME" 2>/dev/null; then
        echo "Sending continuation command to tmux session: $TMUX_SESSION_NAME"
        tmux send-keys -t "$TMUX_SESSION_NAME" "/dev bitte mach weiter" Enter
    else
        echo "Warning: Cannot send continuation command - no active tmux session found"
        echo "Consider manually resuming the session"
    fi
    
    # Warte den üblichen Cooldown-Zeitraum
    local resume_timestamp=$(date -d "+5 minutes" +%s 2>/dev/null || date -v+5M +%s 2>/dev/null || echo $(($(date +%s) + 300)))
    local wait_seconds=$((resume_timestamp - $(date +%s)))
    
    if [ $wait_seconds -gt 0 ]; then
        echo "Waiting for cooldown period: $wait_seconds seconds"
        while [ $wait_seconds -gt 0 ]; do
            printf "\rResuming in %02d:%02d:%02d..." \
                $((wait_seconds/3600)) $(( (wait_seconds%3600)/60 )) $((wait_seconds%60))
            sleep 1
            wait_seconds=$((wait_seconds - 1))
        done
        printf "\rCooldown complete. Monitoring resumed.    \n"
    fi
}

# Hauptfunktion: Starte claunch in neuem Terminal
start_claunch_session() {
    local working_dir="$1"
    shift
    local claude_args=("$@")
    
    debug_echo "Starting claunch session in: $working_dir"
    debug_echo "Arguments: ${claude_args[*]}"
    
    # Terminal-App erkennen (aus Ihrem bestehenden Code)
    detect_terminal_app || return 1
    
    # claunch-Befehl zusammenstellen
    local claunch_cmd="claunch"
    if [ "$CLAUNCH_MODE" = "tmux" ]; then
        claunch_cmd="claunch --tmux"
    fi
    
    # Terminal-spezifische Implementierung
    case "$TERMINAL_APP" in
        "iterm")
            osascript <<EOF
tell application "iTerm"
    create window with default profile
    tell current session of current window
        write text "cd '$working_dir'"
        write text "$claunch_cmd"
    end tell
end tell
EOF
            ;;
        "terminal")
            local full_command="cd '$working_dir' && $claunch_cmd"
            full_command=${full_command//\\/\\\\}
            full_command=${full_command//\"/\\\"}
            
            osascript <<EOF
tell application "Terminal"
    activate
    do script "$full_command"
end tell
EOF
            ;;
        *)
            echo "[ERROR] Terminal app $TERMINAL_APP not supported in hybrid mode"
            return 1
            ;;
    esac
    
    # Warte auf claunch-Start
    sleep 5
    
    # Erkenne die gestartete Session
    detect_claunch_session
    
    echo "✓ claunch session started successfully"
    if [ "$CLAUNCH_MODE" = "tmux" ]; then
        echo "  tmux session: $TMUX_SESSION_NAME"
        echo "  Access with: tmux attach -t $TMUX_SESSION_NAME"
    fi
    
    return 0
}

# Hauptüberwachungsschleife (Hybrid)
hybrid_continuous_loop() {
    echo "=== Starting Hybrid Claude Monitoring ==="
    echo "Project: $PROJECT_NAME"
    echo "Working directory: $ORIGINAL_DIR"
    echo "Check interval: $CHECK_INTERVAL_MINUTES minutes"
    echo "claunch mode: $CLAUNCH_MODE"
    echo "Max cycles: $MAX_RESTARTS"
    echo ""
    
    local check_interval_seconds=$((CHECK_INTERVAL_MINUTES * 60))
    
    while [ $RESTART_COUNT -lt $MAX_RESTARTS ]; do
        echo "=== Monitoring Cycle $((RESTART_COUNT + 1))/$MAX_RESTARTS ==="
        echo "$(date): Checking project '$PROJECT_NAME' for usage limits..."
        
        # Limit-Check
        local limit_status=0
        if [ "$CLAUDE_TEST_MODE" = true ] && [ $RESTART_COUNT -eq 0 ]; then
            echo "[CLAUDE_TEST_MODE] Skipping initial limit check"
            limit_status=0
        else
            check_claude_limits_hybrid
            limit_status=$?
        fi
        
        case $limit_status in
            0)
                echo "✓ No usage limit detected"
                
                # Prüfe ob Session bereits läuft
                if ! detect_claunch_session; then
                    echo "No active claunch session found. Starting new session..."
                    
                    if ! check_network_connectivity; then
                        echo "[ERROR] Network connectivity failed"
                        sleep 60
                        continue
                    fi
                    
                    # Starte neue claunch-Session
                    start_claunch_session "$ORIGINAL_DIR" "${CLAUDE_PASSTHROUGH_ARGS[@]}"
                    if [ $? -eq 0 ]; then
                        echo "✓ New claunch session started successfully"
                    else
                        echo "✗ Failed to start claunch session"
                    fi
                else
                    echo "✓ claunch session is active and healthy"
                fi
                ;;
            1)
                echo "⚠ Usage limit detected and handled"
                ;;
            2)
                echo "⚠ Timeout during limit check - retrying in 1 minute"
                sleep 60
                continue
                ;;
        esac
        
        RESTART_COUNT=$((RESTART_COUNT + 1))
        
        if [ $RESTART_COUNT -lt $MAX_RESTARTS ]; then
            echo ""
            echo "Next check in $CHECK_INTERVAL_MINUTES minutes..."
            echo "Next check at: $(date -d "+$CHECK_INTERVAL_MINUTES minutes" 2>/dev/null || date -v+${CHECK_INTERVAL_MINUTES}M 2>/dev/null || echo "in $CHECK_INTERVAL_MINUTES minutes")"
            sleep $check_interval_seconds
        fi
    done
    
    echo ""
    echo "=== Monitoring completed after $MAX_RESTARTS cycles ==="
}

# Haupt-Initialisierung
main() {
    echo "Hybrid Claude CLI Automation v$VERSION"
    echo "Combining proven monitoring with claunch session management"
    echo ""
    
    # Validierungen
    if ! command -v claunch &> /dev/null; then
        echo "[ERROR] claunch not found. Please install:"
        echo "  npm install -g @0xkaz/claunch"
        exit 1
    fi
    
    validate_claude_cli || exit 1
    
    # Projekt-Info erkennen
    ORIGINAL_DIR="$(pwd)"
    detect_project_info
    
    echo "Project detected: $PROJECT_NAME"
    echo "Working directory: $ORIGINAL_DIR"
    echo ""
    
    if [ "$CONTINUOUS_MODE" = true ]; then
        hybrid_continuous_loop
    else
        echo "Single execution mode..."
        check_claude_limits_hybrid
        case $? in
            0|1) start_claunch_session "$ORIGINAL_DIR" "${CLAUDE_PASSTHROUGH_ARGS[@]}" ;;
            2) echo "[ERROR] Failed to check limits"; exit 3 ;;
        esac
    fi
}

# Bestehende Hilfsfunktionen aus Ihrem Skript
source_existing_functions() {
    # detect_terminal_app, check_network_connectivity, validate_claude_cli, etc.
    # (Ihre bestehenden Funktionen bleiben unverändert)
}

# Argument-Parsing (erweitert um Hybrid-Optionen)
while [[ $# -gt 0 ]]; do
    case "$1" in
        --continuous) CONTINUOUS_MODE=true; shift ;;
        --claunch-mode)
            case "$2" in
                tmux|direct) CLAUNCH_MODE="$2"; shift 2 ;;
                *) echo "[ERROR] Invalid claunch mode: $2"; exit 1 ;;
            esac
            ;;
        --project-name) PROJECT_NAME="$2"; shift 2 ;;
        --debug) DEBUG_MODE=true; shift ;;
        # ... weitere bestehende Argumente
        *) CLAUDE_PASSTHROUGH_ARGS+=("$1"); shift ;;
    esac
done

# Führe das Hauptprogramm aus
main "$@"
```

### 2. Vereinfachte Nutzung

#### Standard-Workflow
```bash
# Terminal 1: Starte Monitoring
cd /path/to/your/project
./hybrid-claude-monitor.sh --continuous --claunch-mode tmux

# Das Skript öffnet automatisch ein zweites Terminal mit claunch
# Im zweiten Terminal arbeiten Sie interaktiv mit Claude
# Das erste Terminal überwacht Usage Limits und sendet automatisch Fortsetzungsbefehle
```

#### Erweiterte Optionen
```bash
# Mit spezifischem Projekt-Namen
./hybrid-claude-monitor.sh --continuous --project-name "special-project" --claunch-mode tmux

# Direct Mode (ohne tmux)
./hybrid-claude-monitor.sh --continuous --claunch-mode direct

# Mit Test-Mode
./hybrid-claude-monitor.sh --continuous --test-mode 30 --claunch-mode tmux
```

## Vorteile des Hybrid-Ansatzes

### 1. **Bewährte Zuverlässigkeit + Moderne Features**
- ✅ Ihr erprobtes Usage-Limit-Monitoring bleibt erhalten
- ✅ claunch's überlegene Session-Verwaltung wird hinzugefügt
- ✅ Kein Verlust bestehender Funktionalität

### 2. **Verbesserte Session-Kontinuität**
- ✅ Projektbasierte Session-Trennung
- ✅ Automatische Session-IDs-Verwaltung  
- ✅ tmux-Persistenz für kritische Sessions
- ✅ CLAUDE.md-Integration für Projekt-Memory

### 3. **Skalierbarkeit**
- ✅ Multi-Projekt-Unterstützung
- ✅ Parallele Sessions möglich
- ✅ Team-Workflow-kompatibel

### 4. **Robuste Fehlerbehandlung**
- ✅ Fallback auf traditionelle Monitoring-Methoden
- ✅ Graceful Degradation bei claunch-Fehlern
- ✅ Comprehensive Logging und Debugging

## Vergleich: Bestehend vs. Hybrid

| Aspekt | Ihr v4 Skript | Hybrid-Ansatz |
|--------|---------------|---------------|
| **Usage-Limit-Detection** | ✅ Bewährt, zuverlässig | ✅ Erweitert um tmux-Integration |
| **Session-Kontinuität** | ❌ Problematisch mit --continue | ✅ Zuverlässig durch claunch |
| **Projekt-Management** | ❌ Nicht projektbasiert | ✅ Automatische Projekt-Trennung |
| **Multi-Session-Support** | ❌ Ein Terminal pro Monitoring | ✅ Parallel-Sessions möglich |
| **Persistenz** | ❌ Bei Terminal-Crash verloren | ✅ tmux-Persistenz verfügbar |
| **Memory-Management** | ❌ Kein Projekt-Memory | ✅ CLAUDE.md-Integration |
| **Community-Support** | ❌ Eigene Lösung | ✅ Aktive Community-Tools |

## Migration von v4 zu Hybrid

### Schritt 1: Vorbereitung
```bash
# claunch installieren
npm install -g @0xkaz/claunch

# Bestehende Session-Dateien sichern
cp -r ~/.claude* ~/claude-backup/

# Test-Projekt erstellen
mkdir ~/claude-hybrid-test
cd ~/claude-hybrid-test
```

### Schritt 2: Hybrid-Skript Integration
```bash
# Ihr bestehendes v4-Skript als Basis verwenden
cp claude-auto-resume-continuous-v4 hybrid-claude-monitor.sh

# Hybrid-Funktionen hinzufügen (siehe Implementierung oben)
# Oder komplett neues Skript erstellen
```

### Schritt 3: Testing
```bash
# Test mit kurzer Interval
./hybrid-claude-monitor.sh --continuous --test-mode 10 --claunch-mode tmux --check-interval 1

# Überprüfe tmux-Sessions
tmux list-sessions

# Manuell in claunch-Session verbinden
tmux attach -t claude-claude-hybrid-test
```

### Schritt 4: Produktion
```bash
# Standard-Konfiguration für Ihre Projekte
cd /path/to/real/project
./hybrid-claude-monitor.sh --continuous --claunch-mode tmux
```

## Fehlerbehandlung und Debugging

### Debug-Modus aktivieren
```bash
./hybrid-claude-monitor.sh --continuous --debug --claunch-mode tmux
```

### Häufige Probleme und Lösungen

#### Problem: claunch-Session wird nicht erkannt
```bash
# Lösung: Session-Dateien prüfen
ls -la ~/.claude_session_*

# Tmux-Sessions auflisten
tmux list-sessions

# Manuell Session-Datei erstellen
echo "sess-your-session-id" > ~/.claude_session_PROJECT_NAME
```

#### Problem: tmux send-keys funktioniert nicht
```bash
# Lösung: Session-Name verifizieren
tmux list-sessions | grep claude

# Korrekten Session-Namen verwenden
tmux send-keys -t "claude-exact-name" "/dev bitte mach weiter" Enter
```

#### Problem: Terminal-App wird nicht erkannt
```bash
# Lösung: Manuell spezifizieren
./hybrid-claude-monitor.sh --terminal-app terminal --continuous --claunch-mode tmux
```

### Logging und Monitoring
```bash
# Logs anzeigen
tail -f ~/.claude-automation.log

# tmux-Session-Logs
tmux capture-pane -t claude-PROJECT -p > session-output.log

# claunch-Status prüfen
claunch list
```

## Erweiterte Konfiguration

### Systemd Service (Linux)
```ini
[Unit]
Description=Hybrid Claude CLI Monitor
After=network.target

[Service]
Type=simple
User=%i
WorkingDirectory=%h/projects/main-project
ExecStart=%h/bin/hybrid-claude-monitor.sh --continuous --claunch-mode tmux
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
```

### LaunchAgent (macOS)
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.user.hybrid-claude-monitor</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Users/USERNAME/bin/hybrid-claude-monitor.sh</string>
        <string>--continuous</string>
        <string>--claunch-mode</string>
        <string>tmux</string>
    </array>
    <key>WorkingDirectory</key>
    <string>/Users/USERNAME/projects/main-project</string>
    <key>KeepAlive</key>
    <true/>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
```

## Fazit

Der Hybrid-Ansatz kombiniert das Beste aus beiden Welten:
- **Ihre bewährte Usage-Limit-Detection** bleibt vollständig funktional
- **claunch's Session-Management** löst die Kontinuitätsprobleme
- **Minimaler Migrationsaufwand** durch Integration in bestehende Architektur
- **Zukunftssicher** durch Nutzung aktiver Community-Tools

Diese Lösung bietet eine solide Basis für produktive Claude CLI-Workflows mit automatischer Überwachung und zuverlässiger Session-Kontinuität.