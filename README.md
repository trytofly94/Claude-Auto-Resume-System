# Claude Auto-Resume

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Shell](https://img.shields.io/badge/Shell-Bash_4.0+-blue.svg)](https://www.gnu.org/software/bash/)
[![Platform](https://img.shields.io/badge/Platform-macOS%20%7C%20Linux-lightgrey.svg)](#system-requirements)

Ein intelligentes Automatisierungssystem für robustes Claude CLI Session-Management mit automatischer Wiederherstellung nach Usage-Limits und Verbindungsfehlern.

## 📚 Projektgrundlagen

Dieses Projekt erweitert zwei wichtige Open-Source-Tools um robuste Automatisierung:

### 🔗 Zugrundeliegende Repositories

1. **[Claude CLI](https://github.com/anthropics/claude-code)** - Die offizielle Anthropic Claude Command Line Interface
   - Basis für alle Claude-Interaktionen und AI-assistierte Entwicklung
   - Stellt die Core-Funktionalität für Code-Integration bereit

2. **[claunch](https://github.com/eeshugerman/claunch)** - Claude Launch Utility  
   - Projektbasiertes Session-Management für Claude CLI
   - tmux-Integration und organisierte Workflow-Verwaltung
   - Foundation für den in diesem Projekt implementierten Hybrid-Ansatz

## 🚀 Überblick

Claude Auto-Resume implementiert einen **erweiterten Hybrid-Ansatz**, der die Stärken von `claunch` und `tmux` kombiniert und um intelligente Automatisierung erweitert:

- **Automatische Recovery-Mechanismen** für Usage-Limits und Verbindungsabbrüche
- **Robuste Fehlerbehandlung** mit strukturiertem Logging
- **Cross-Platform-Unterstützung** für verschiedene Terminal-Umgebungen  
- **Production-Ready-Architektur** mit umfassender Test-Suite

### ✨ Kern-Features

- 🔄 **Automatische Session-Wiederherstellung** nach Usage-Limits
- ⏱️ **Intelligente Wartezeiten** mit exponentiellen Backoff-Strategien  
- 🖥️ **tmux-Integration** für persistente Terminal-Sessions
- 📊 **Präzise Usage-Limit-Detection** mit Live-Countdown
- 🛡️ **Fehlertolerante Wiederverbindung** bei Netzwerkproblemen
- 📝 **Strukturiertes Logging** für Debugging und Monitoring
- 🎯 **Projektbasierte Session-Trennung** via claunch
- 🔧 **Cross-Platform-Support** (macOS, Linux)

## 📋 Voraussetzungen

### Erforderliche Software
- **Claude CLI** - [Anthropic Claude CLI](https://claude.ai/code)
- **claunch** - Session-Management-Tool für Claude CLI
- **tmux** - Terminal-Multiplexer für Session-Persistenz
- **jq** - JSON-Processor für Log-Parsing
- **Bash 4.0+** - Shell-Environment

### Unterstützte Plattformen
- macOS 10.14+ (Terminal.app, iTerm2)
- Linux (Ubuntu 18.04+, CentOS 7+, Debian 10+)
- WSL2 (Windows Subsystem for Linux)

## 🛠️ Installation

### Automatische Installation
```bash
# Repository klonen
git clone https://github.com/LennartZi/Claude-Auto-Resume.git
cd Claude-Auto-Resume

# Vollständige Installation mit Dependencies
./scripts/setup.sh

# Konfiguration überprüfen
./src/hybrid-monitor.sh --version
```

### Manuelle Installation
```bash
# Claude CLI installieren (falls nicht vorhanden)
# Siehe: https://claude.ai/code

# claunch installieren
npm install -g @0xkaz/claunch
# oder: ./scripts/install-claunch.sh

# tmux installieren
# macOS: brew install tmux
# Ubuntu: sudo apt install tmux
# CentOS: sudo yum install tmux

# Repository Setup
chmod +x src/*.sh scripts/*.sh
```

## 🎯 Schnellstart

### Einfache Nutzung
```bash
# Auto-Resume mit Standard-Konfiguration starten
./src/hybrid-monitor.sh --continuous --new-terminal

# Mit spezifischen Parametern
./src/hybrid-monitor.sh --continuous --claunch-mode tmux --check-interval 3
```

### Projekt-spezifische Sessions
```bash
# In Ihrem Projekt-Verzeichnis
cd /path/to/your/project
/path/to/Claude-Auto-Resume/src/hybrid-monitor.sh --continuous --claunch-mode tmux

# Das System erkennt automatisch das Projekt und erstellt separate Sessions
```

### Persistente Sessions (empfohlen)
```bash
# In tmux-Session starten (überlebt Terminal-Crashes)
tmux new-session -d -s claude-monitor \
    "cd $(pwd) && ./src/hybrid-monitor.sh --continuous --claunch-mode tmux"

# Session wieder anhängen
tmux attach -t claude-monitor
```

## 🏗️ Architektur

### Hybrid-Ansatz Diagramm
```
┌─────────────────────────────────────────────────────────────┐
│                 Monitoring-Terminal                         │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  hybrid-monitor.sh                                  │    │
│  │  • Usage-Limit-Detection                           │    │
│  │  • Periodische Health-Checks                       │    │
│  │  • Automatische Recovery-Kommandos                 │    │
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

### Komponenten-Übersicht
```
src/
├── hybrid-monitor.sh          # 🎯 Haupt-Monitoring-System
├── claunch-integration.sh     # 🔗 claunch-Wrapper-Funktionen  
├── session-manager.sh         # 📊 Session-Lifecycle-Management
└── utils/
    ├── logging.sh            # 📝 Strukturiertes Logging
    ├── network.sh            # 🌐 Netzwerk-Utilities
    └── terminal.sh           # 🖥️ Terminal-Detection
```

## ⚙️ Konfiguration

### Standard-Konfiguration
```bash
# config/default.conf
CHECK_INTERVAL_MINUTES=5        # Monitoring-Intervall
MAX_RESTARTS=50                 # Maximale Überwachungszyklen
USE_CLAUNCH=true               # claunch-Integration aktivieren
CLAUNCH_MODE="tmux"            # "tmux" oder "direct"
USAGE_LIMIT_COOLDOWN=300       # Wartezeit nach Usage-Limit (Sekunden)
```

### Erweiterte Optionen
```bash
# Eigene Konfiguration erstellen
cp config/default.conf config/my-project.conf

# Mit custom Config starten
./src/hybrid-monitor.sh --config config/my-project.conf --continuous
```

## 📊 Monitoring & Debugging

### Live-Monitoring
```bash
# Logs in Echtzeit verfolgen
tail -f logs/hybrid-monitor.log

# Strukturierte Logs durchsuchen
jq '.level == "ERROR"' logs/hybrid-monitor.json

# Aktive Sessions anzeigen
tmux list-sessions | grep claude
claunch list
```

### Performance-Statistiken
```bash
# System-Status anzeigen
./scripts/show-stats.sh

# Session-Health prüfen
./scripts/health-check.sh
```

### Debug-Modus
```bash
# Vollständige Debug-Ausgabe
DEBUG=1 ./src/hybrid-monitor.sh --continuous --debug

# Spezifische Komponenten debuggen
DEBUG_CLAUNCH=1 ./src/hybrid-monitor.sh --continuous
```

## 🧪 Testing

### Test-Suite ausführen
```bash
# Vollständige Tests
./scripts/run-tests.sh

# Spezifische Test-Kategorien
./scripts/run-tests.sh unit           # Unit-Tests
./scripts/run-tests.sh integration    # Integration-Tests
./scripts/run-tests.sh e2e            # End-to-End-Tests
```

### Test-Modus für Entwicklung
```bash
# Simuliere Usage-Limit mit 30 Sekunden Wartezeit
./src/hybrid-monitor.sh --test-mode 30 --continuous --debug

# Teste verschiedene Terminal-Apps
FORCE_TERMINAL=iterm ./src/hybrid-monitor.sh --new-terminal
```

## 🔧 Troubleshooting

### Häufige Probleme

#### claunch-Session wird nicht erkannt
```bash
# Session-Dateien prüfen
ls -la ~/.claude_session_*

# tmux-Sessions auflisten
tmux list-sessions

# Manuell Session-Datei erstellen
echo "sess-your-session-id" > ~/.claude_session_$(basename $(pwd))
```

#### Terminal-App wird nicht erkannt
```bash
# Manuell Terminal-App spezifizieren
./src/hybrid-monitor.sh --terminal-app terminal --new-terminal --continuous

# Verfügbare Terminal-Apps anzeigen
./src/hybrid-monitor.sh --list-terminals
```

#### Usage-Limit-Detection funktioniert nicht
```bash
# Debug-Modus für Limit-Detection
DEBUG_LIMITS=1 ./src/hybrid-monitor.sh --continuous

# Manuelle Limit-Prüfung
claude -p 'check'
```

### Logs analysieren
```bash
# Fehler-Logs filtern
grep "ERROR" logs/hybrid-monitor.log

# Session-Recovery-Events anzeigen
grep "Session recovery" logs/hybrid-monitor.log

# Performance-Metriken extrahieren
jq '.metrics' logs/hybrid-monitor.json
```

## 🚀 Erweiterte Nutzung

### Multi-Projekt-Workflow
```bash
# Terminal 1: Web-App
cd ~/projects/webapp
./src/hybrid-monitor.sh --continuous --claunch-mode tmux

# Terminal 2: API
cd ~/projects/api  
./src/hybrid-monitor.sh --continuous --claunch-mode tmux

# Terminal 3: Mobile App
cd ~/projects/mobile
./src/hybrid-monitor.sh --continuous --claunch-mode tmux

# Jedes Projekt erhält eine separate claunch-Session
```

### Automatisierung mit Systemd (Linux)
```bash
# Service-Datei erstellen
sudo cp scripts/systemd/claude-auto-resume.service /etc/systemd/system/

# Service aktivieren
sudo systemctl enable claude-auto-resume
sudo systemctl start claude-auto-resume

# Status prüfen
sudo systemctl status claude-auto-resume
```

### LaunchAgent (macOS)
```bash
# LaunchAgent installieren
cp scripts/macos/com.user.claude-auto-resume.plist ~/Library/LaunchAgents/

# Service laden
launchctl load ~/Library/LaunchAgents/com.user.claude-auto-resume.plist
```

## 🤝 Entwicklung & Beitragen

### Entwicklungsumgebung einrichten
```bash
# Development Dependencies installieren
./scripts/dev-setup.sh

# Pre-commit Hooks aktivieren
pre-commit install

# Code-Quality prüfen
shellcheck src/**/*.sh
pylint scripts/*.py
```

### Branch-Workflow
```bash
# Feature-Branch erstellen
git checkout -b feature/neue-funktion

# Changes committen (Conventional Commits)
git commit -m "feat: add new session recovery strategy"

# Tests vor Push ausführen
./scripts/run-tests.sh
```

### Beiträge erwünscht
1. **Fork** das Repository
2. **Feature-Branch** erstellen
3. **Tests** hinzufügen/aktualisieren
4. **Pull Request** erstellen
5. **Code Review** abwarten

## 📄 Lizenz

[MIT License](LICENSE) - Siehe LICENSE-Datei für Details.

## 🆘 Support

### Hilfe erhalten
- 📚 **GitHub Issues** - Bug-Reports und Feature-Requests
- 💬 **Discussions** - Allgemeine Fragen und Community-Support
- 🔍 **Debug-Logs** - Verwende `DEBUG=1` für detaillierte Ausgaben

### Nützliche Links
- [Claude CLI Dokumentation](https://claude.ai/code)
- [claunch Repository](https://github.com/0xkaz/claunch)
- [tmux Manual](https://man.openbsd.org/tmux.1)

---

**💡 Tipp**: Für optimale Ergebnisse verwenden Sie das System in tmux-Sessions und aktivieren Sie strukturiertes Logging für einfacheres Debugging.

**⭐ Wenn Ihnen dieses Projekt hilft, geben Sie ihm einen Stern auf GitHub!**