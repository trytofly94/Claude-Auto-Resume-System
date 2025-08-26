# Claude Auto-Resume - Projektspezifische Konfiguration

## 1. Projekt-Übersicht

**Claude Auto-Resume** ist ein intelligentes Automatisierungssystem für robustes Claude CLI Session-Management mit automatischer Wiederherstellung nach Usage-Limits und Verbindungsfehlern.

### Kern-Ziele
- Implementierung des empfohlenen claunch-Hybrid-Ansatzes
- Automatische Usage-Limit-Detection und Recovery
- Persistente Session-Verwaltung mit tmux-Integration
- Robuste Fehlerbehandlung und Monitoring

- The development focus should be with the main program. if tests fail that are expected to work in the real thing then the testing process has to be revised. ok 

## 2. Technologie-Stack

### Kern-Technologien
- **Sprache**: Bash 4.0+, Python 3.8+ (für erweiterte Features)
- **Runtime**: Terminal-basiert, Unix/Linux/macOS
- **Session-Manager**: claunch (primär), tmux (Persistenz)
- **Dependencies**: Claude CLI, jq, curl, standard Unix-Tools

### Entwicklungs-Tools
- **Linting**: ShellCheck für Bash, pylint für Python
- **Testing**: Bats (Bash Automated Testing System)
- **CI/CD**: GitHub Actions (geplant)
- **Dokumentation**: Markdown mit GitHub-Flavored Extensions

## 3. Architektur-Übersicht

### Verzeichnisstruktur
```
Claude-Auto-Resume/
├── CLAUDE.md                              # Diese Datei
├── README.md                              # Benutzer-Dokumentation
├── claude-auto-resume-continuous-v4       # Legacy-Skript (Referenz)
├── src/                                   # Kern-Implementierung
│   ├── hybrid-monitor.sh                  # Haupt-Monitoring-Skript
│   ├── claunch-integration.sh             # claunch-Wrapper-Funktionen
│   ├── session-manager.sh                 # Session-Lifecycle-Management
│   └── utils/                             # Hilfsfunktionen
│       ├── logging.sh                     # Strukturiertes Logging
│       ├── network.sh                     # Netzwerk-Utilities
│       └── terminal.sh                    # Terminal-Detection
├── config/                                # Konfigurationsdateien
│   ├── default.conf                       # Standard-Konfiguration
│   └── templates/                         # Config-Templates
├── scripts/                               # Setup & Utility Scripts
│   ├── setup.sh                           # Installation & Dependencies
│   ├── install-claunch.sh                 # claunch Installation
│   └── dev-setup.sh                       # Entwicklungsumgebung
├── tests/                                 # Test-Suite
│   ├── unit/                              # Unit-Tests
│   ├── integration/                       # Integration-Tests
│   └── fixtures/                          # Test-Daten
└── logs/                                  # Log-Verzeichnis (runtime)
```

### Kern-Komponenten
1. **Hybrid-Monitor**: Hauptüberwachungsloop mit claunch-Integration
2. **Session-Manager**: Lifecycle-Management für Claude-Sessions
3. **Usage-Limit-Handler**: Intelligente Wartezeit-Berechnung
4. **Terminal-Integration**: Multi-Terminal-Support (iTerm, Terminal.app, etc.)
5. **Recovery-System**: Automatische Wiederherstellung nach Fehlern

## 4. Wichtige Befehle

### Setup & Installation
```bash
./scripts/setup.sh                         # Vollständige Installation
./scripts/install-claunch.sh               # nur claunch installieren
./scripts/dev-setup.sh                     # Entwicklungsumgebung
```

### Haupt-Funktionalität
```bash
./src/hybrid-monitor.sh --continuous       # Standard-Monitoring
./src/hybrid-monitor.sh --help              # Hilfe anzeigen
./src/hybrid-monitor.sh --test-mode 30     # Test mit 30s Simulation
```

### Entwicklung & Testing
```bash
./scripts/run-tests.sh                     # Vollständige Test-Suite
./scripts/run-tests.sh unit                # Nur Unit-Tests
./scripts/run-tests.sh integration         # Nur Integration-Tests
shellcheck src/**/*.sh                     # Statische Code-Analyse
```

### Monitoring & Debugging
```bash
tail -f logs/hybrid-monitor.log            # Live-Logs
./scripts/show-stats.sh                    # Statistiken anzeigen
tmux list-sessions | grep claude           # Aktive Sessions
```

## 5. Konfiguration

### Standard-Konfiguration (config/default.conf)
```bash
# Session-Management
CHECK_INTERVAL_MINUTES=5
MAX_RESTARTS=50
USE_CLAUNCH=true
CLAUNCH_MODE="tmux"

# Usage-Limit-Handling
USAGE_LIMIT_COOLDOWN=300
BACKOFF_FACTOR=1.5
MAX_WAIT_TIME=1800

# Logging
LOG_LEVEL="INFO"
LOG_ROTATION=true
MAX_LOG_SIZE="100M"

# Terminal-Integration
PREFERRED_TERMINAL="auto"
NEW_TERMINAL_DEFAULT=true
```

## 6. Entwicklungs-Workflow

### Branch-Naming
- `feature/description` - Neue Features
- `bugfix/description` - Fehlerbehebungen
- `enhancement/description` - Verbesserungen
- `docs/description` - Dokumentationsänderungen

### Commit-Convention
Verwende [Conventional Commits](https://conventionalcommits.org/):
```
feat: add claunch integration for session management
fix: resolve tmux session detection issue
docs: update installation instructions
test: add unit tests for usage limit detection
```

### Code-Standards
- **Bash**: ShellCheck-konform, `set -euo pipefail`
- **Python**: PEP 8, Type Hints wo möglich
- **Dokumentation**: Inline-Kommentare für komplexe Logik
- **Error-Handling**: Robuste Fehlerbehandlung mit Logging

## 7. Agenten-spezifische Anweisungen

### Für planner-Agent
- Nutze die Hybrid-Architektur aus `hybrid_approach_documentation.md` als Grundlage
- Plane modulare Implementierung für einfache Wartung
- Berücksichtige Cross-Platform-Kompatibilität (macOS/Linux)
- Fokus auf schrittweise Migration vom bestehenden v4-Skript

### Für creator-Agent
- Implementiere robuste Fehlerbehandlung (`set -euo pipefail`)
- Verwende strukturiertes Logging für alle wichtigen Events
- Befolge die ShellCheck-Empfehlungen für Bash-Code
- Nutze bestehende `claude-auto-resume-continuous-v4` als Referenz
- Bevorzuge claunch für alle neuen Session-Management-Features
- Implementiere graceful degradation bei fehlenden Dependencies

### Für tester-Agent
- Tests müssen in isolierten Umgebungen laufen (separate tmux-sessions)
- Mock Claude CLI für Unit-Tests (verwende Stubs)
- Teste verschiedene Fehlerszenarien:
  - Netzwerk-Verlust während Session
  - Usage-Limits mit verschiedenen Wartezeiten
  - Terminal-App-Detection auf verschiedenen Systemen
- Validiere Log-Output und Session-Recovery-Verhalten
- Teste sowohl claunch direct-mode als auch tmux-mode

### Für deployer-Agent
- Dokumentiere alle Breaking Changes in der README
- Aktualisiere Installation-Scripts bei neuen Dependencies
- Verifiziere Cross-Platform-Kompatibilität vor Release
- Erstelle Migration-Guide vom v4-Skript zum neuen System
- Tagge Releases mit semantischer Versionierung

## 8. Technische Besonderheiten

### Session-Management-Strategie
- **Primary**: claunch für projektbasierte Session-Verwaltung
- **Persistence**: tmux für Terminal-unabhängige Sessions
- **Fallback**: Direct Claude CLI für Kompatibilität
- **Recovery**: Automatische Session-Wiederherstellung mit State-Persistence

### Usage-Limit-Handling
- Intelligente Backoff-Strategien mit exponential fallback
- Präzise Timestamp-basierte Wartezeit-Berechnung
- Live-Countdown für Benutzer-Feedback
- Graceful handling von Timezone-Unterschieden

### Logging-Architektur
- Strukturiertes JSON-Logging für maschinelle Auswertung
- Verschiedene Log-Levels (DEBUG, INFO, WARN, ERROR)
- Automatische Log-Rotation bei Größenüberschreitung
- Session-spezifische Log-Dateien für Debugging

### Cross-Platform-Unterstützung
- Terminal-App-Detection für macOS (Terminal.app, iTerm2)
- Linux Terminal-Support (gnome-terminal, konsole, xterm)
- AppleScript-Integration für macOS-spezifische Features
- Graceful degradation bei nicht unterstützten Terminals

## 9. Sicherheitsüberlegungen

### Permissions & Access Control
- Minimale Permissions für Script-Ausführung
- Sichere Handling von Session-IDs und Tokens
- Keine Secrets in Log-Dateien
- Verwendung von `--dangerously-skip-permissions` nur in vertrauenswürdigen Umgebungen

### Input-Validation
- Sanitization aller Benutzer-Eingaben
- Validation von Config-File-Parametern
- Schutz vor Command-Injection in Terminal-Commands

## 10. Performance-Überlegungen

### Resource-Verbrauch
- Minimaler Memory-Footprint (<50MB für Monitoring)
- Effiziente tmux-Integration ohne Polling-Overhead
- Optimierte Regex-Patterns für Log-Parsing
- Lazy-Loading von nicht-kritischen Modulen

### Latenz-Optimierung
- Schnelle tmux send-keys für Command-Injection (5-15ms)
- Asynchrone Netzwerk-Checks ohne Blocking
- Cachete Terminal-App-Detection
- Optimierte Session-Recovery-Zeiten

---

**Letzte Aktualisierung**: 2025-08-05
**Version**: 1.0.0-alpha
**Kompatibilität**: macOS 10.14+, Linux (Ubuntu 18.04+, CentOS 7+)