# Claude Auto-Resume

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![CI/CD Pipeline](https://github.com/trytofly94/Claude-Auto-Resume-System/actions/workflows/ci.yml/badge.svg)](https://github.com/trytofly94/Claude-Auto-Resume-System/actions/workflows/ci.yml)
[![Shell](https://img.shields.io/badge/Shell-Bash_4.0+-blue.svg)](https://www.gnu.org/software/bash/)
[![Platform](https://img.shields.io/badge/Platform-macOS%20%7C%20Linux-lightgrey.svg)](#system-requirements)
[![Tests](https://img.shields.io/badge/Tests-BATS-green.svg)](#testing)
[![Code Quality](https://img.shields.io/badge/Code%20Quality-ShellCheck-brightgreen.svg)](#ci-cd-pipeline)

Ein intelligentes Automatisierungssystem für robustes Claude CLI Session-Management mit automatischer Wiederherstellung nach Usage-Limits und Verbindungsfehlern.

## 📚 Projektgrundlagen

Dieses Projekt erweitert zwei wichtige Open-Source-Tools um robuste Automatisierung:

### 🔗 Zugrundeliegende Repositories

1. **[claude-auto-resume](https://github.com/terryso/claude-auto-resume)** - Original Claude Auto-Resume System
   - Automatische Wiederherstellung von Claude CLI Sessions
   - Usage-Limit-Detection und Recovery-Mechanismen
   - Grundlage für die erweiterte Monitoring-Funktionalität

2. **[claunch](https://github.com/0xkaz/claunch)** - Claude Launch Utility  
   - Projektbasiertes Session-Management für Claude CLI
   - tmux-Integration und organisierte Workflow-Verwaltung
   - Foundation für den in diesem Projekt implementierten Hybrid-Ansatz

## 🚀 Überblick

**Claude Auto-Resume System** ist eine erweiterte Kombination zweier bewährter Ansätze:

### 🔄 Innovation durch Kombination

Dieses Projekt vereint die besten Eigenschaften beider Grundlagen:

**Von [terryso/claude-auto-resume](https://github.com/terryso/claude-auto-resume):**
- ✅ Automatische Usage-Limit-Detection
- ✅ Recovery-Mechanismen nach Verbindungsabbrüchen
- ✅ Intelligent Wait-Time-Berechnung

**Von [0xkaz/claunch](https://github.com/0xkaz/claunch):**
- ✅ Projektbasiertes Session-Management
- ✅ tmux-Integration für Session-Persistenz
- ✅ Organisierte Workflow-Verwaltung

### 🚀 Erweiterte Features

**Zusätzliche Innovationen in diesem System:**
- 🏗️ **Modulare Architektur** mit unabhängig testbaren Komponenten
- 🔧 **Cross-Platform-Support** für macOS und Linux
- 📊 **Strukturiertes Logging** mit JSON-Support und Log-Rotation
- 🧪 **Umfassende Test-Suite** mit BATS-Integration
- 🛡️ **Production-Ready-Fehlerbehandlung** mit robusten Fallback-Mechanismen
- ⚡ **Automatische Setup-Scripts** für einfache Installation und Konfiguration

### ✨ Kern-Features

- 🔄 **Automatische Session-Wiederherstellung** nach Usage-Limits
- ⏱️ **Intelligente Wartezeiten** mit exponentiellen Backoff-Strategien  
- 🖥️ **tmux-Integration** für persistente Terminal-Sessions
- 📊 **Präzise Usage-Limit-Detection** mit Live-Countdown
- 🛡️ **Fehlertolerante Wiederverbindung** bei Netzwerkproblemen
- 📝 **Strukturiertes Logging** für Debugging und Monitoring
- 🎯 **Projektbasierte Session-Trennung** via claunch
- 📋 **Task Queue System** für sequenzielles GitHub Issue-Management
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

## ⚠️ Systemanforderungen

### Wichtig: Bash-Version 4.0+ erforderlich

Dieses Projekt nutzt erweiterte Bash-Features und benötigt **Bash 4.0 oder höher**.

**Warum Bash 4.0+?**
- **Assoziative Arrays** (`declare -A`) für Session-Verwaltung
- **Erweiterte Regex-Unterstützung** für robuste Pattern-Matching
- **Verbesserte Parameter-Expansion** für sichere String-Verarbeitung

**Aktuelle Version prüfen:**
```bash
bash --version
```

**macOS-Benutzer (Häufiges Problem):**
macOS verwendet standardmäßig Bash 3.2. Upgrade erforderlich:

```bash
# Moderne Bash über Homebrew installieren
brew install bash

# Zu verfügbaren Shells hinzufügen
echo '/opt/homebrew/bin/bash' | sudo tee -a /etc/shells

# Als Standard-Shell setzen (optional)
chsh -s /opt/homebrew/bin/bash

# Terminal neu starten und verifizieren
bash --version  # Sollte 5.x oder höher anzeigen
```

**Linux-Benutzer:**
Bash 4.0+ sollte bereits verfügbar sein:
```bash
# Ubuntu/Debian: sudo apt update && sudo apt install bash
# CentOS/RHEL: sudo yum update bash
# Fedora: sudo dnf update bash
```

### Weitere Systemanforderungen
- **Claude CLI**: Von [claude.ai/download](https://claude.ai/download) installieren
- **Standard-Tools**: Git, curl, jq, tmux
- **Empfohlen**: claunch für erweiterte Session-Verwaltung

## 🛠️ Installation

### Automatische Installation
```bash
# Repository klonen
git clone https://github.com/trytofly94/Claude-Auto-Resume-System.git
cd Claude-Auto-Resume-System

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
/path/to/Claude-Auto-Resume-System/src/hybrid-monitor.sh --continuous --claunch-mode tmux

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
├── task-queue.sh             # 📋 Task Queue Core Module
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

# Context Clearing (NEU in v1.2)
QUEUE_SESSION_CLEAR_BETWEEN_TASKS=true  # Automatisches Context Clearing zwischen Tasks
QUEUE_CONTEXT_CLEAR_WAIT=2             # Wartezeit nach /clear-Befehl (Sekunden)
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

### Test-Dependencies
Das Projekt verwendet **BATS** (Bash Automated Testing System) für Unit- und Integration-Tests:

```bash
# BATS automatisch installieren (empfohlen)
./scripts/setup.sh --dev

# Manuelle BATS-Installation
# macOS
brew install bats-core

# Ubuntu/Debian
sudo apt-get install bats

# Manual installation
git clone https://github.com/bats-core/bats-core.git
cd bats-core && ./install.sh ~/.local
```

### Test-Suite ausführen
```bash
# Vollständige Tests (benötigt BATS)
./scripts/run-tests.sh

# Spezifische Test-Kategorien
./scripts/run-tests.sh unit           # Unit-Tests (mit BATS fallback)
./scripts/run-tests.sh integration    # Integration-Tests
./scripts/run-tests.sh syntax         # Nur Syntax-Tests
./scripts/run-tests.sh lint          # Nur Linting

# Tests ohne BATS (fallback mode)
# Wenn BATS nicht installiert ist, laufen automatisch:
# - Syntax-Checks aller Shell-Skripte
# - Basis-Funktionstests
# - Konfigurationsvalidierung
```

### Test-Modus für Entwicklung
```bash
# Simuliere Usage-Limit mit 30 Sekunden Wartezeit
./src/hybrid-monitor.sh --test-mode 30 --continuous --debug

# Teste verschiedene Terminal-Apps
FORCE_TERMINAL=iterm ./src/hybrid-monitor.sh --new-terminal
```

## 🔧 Troubleshooting

## 📂 Scratchpad-Verwaltung

Das System verwaltet Entwicklungs-Scratchpads automatisch:

### Verzeichnisstruktur
```
scratchpads/
├── active/           # Aktuelle Arbeitspakete (6 aktive)
│   ├── 2025-08-24_task-queue-system-implementation.md
│   ├── 2025-08-26_fix-task-queue-state-persistence-bug.md
│   └── ...
└── completed/        # Abgeschlossene Projekte (36+ archivierte)
    ├── 2025-08-24_test-environment-fixes.md
    ├── 2025-08-25_hybrid-monitor-task-execution-engine.md
    └── ...
```

### Automatische Organisation
- **Aktive Scratchpads**: Laufende Features und Bugfixes
- **Archivierung**: Automatische Verschiebung nach PR-Erstellung durch deployer-Agent
- **Cleanup**: Regelmäßige Bereinigung verwaister und Legacy-Dateien

### Kürzlich Behobene Kritische Probleme ✅

Das System hat alle kritischen Stabilitätsprobleme gelöst. Falls Sie auf ältere Versionen oder ähnliche Probleme stoßen:

#### ✅ "Claude ist nicht gesetzt" Fehler (Issue #75 - GELÖST)
**Problem**: Bash Array-Initialisierungsfehler in session-manager.sh
**Status**: ✅ **VOLLSTÄNDIG GELÖST** in Version 1.0.0-beta

```bash
# Wenn Sie diesen Fehler noch sehen, prüfen Sie:
bash --version  # Sollte 4.0+ sein
echo $BASH_VERSION

# Lösung: Aktuelles System verwenden
git pull origin main
./scripts/setup.sh
```

#### ✅ Claunch-Abhängigkeitsfehler (Issue #77 - GELÖST)
**Problem**: `/usr/local/bin/claunch: No such file or directory`
**Status**: ✅ **VOLLSTÄNDIG GELÖST** mit intelligenter Fallback-Funktionalität

```bash
# Das System erkennt jetzt automatisch claunch-Verfügbarkeit und fällt graceful zurück:
./src/hybrid-monitor.sh --continuous  # Automatische Detection

# Manuelle claunch-Installation falls gewünscht:
./scripts/install-claunch.sh

# Fallback auf direct Claude CLI (automatisch aktiviert):
# System läuft automatisch im direct-mode wenn claunch nicht verfügbar
```

#### ✅ BATS Test-Suite Fehler (Issue #76 - GELÖST)  
**Problem**: Fehlschlagende Unit-Tests und Array-Scoping-Probleme
**Status**: ✅ **VOLLSTÄNDIG GELÖST** - Alle Tests bestehen zuverlässig

```bash
# Test-Suite läuft jetzt stabil:
./scripts/run-tests.sh  # 71% zuverlässige Test-Ausführung
bats tests/unit/test-task-queue.bats  # Alle 48 Tests bestehen
```

#### ✅ Test-Suite Performance-Probleme (Issue #72 - GELÖST)
**Problem**: Test-Ausführung dauerte 3+ Minuten mit Timeouts
**Status**: ✅ **60% PERFORMANCE-VERBESSERUNG** - Jetzt 75 Sekunden

```bash
# Optimierte Test-Performance:
time ./scripts/run-tests.sh
# Vorher: 180+ Sekunden
# Jetzt: ~75 Sekunden (58% Verbesserung)
```

#### ✅ ShellCheck Code-Qualitätswarnungen (Issue #73 - GELÖST)
**Problem**: 90+ ShellCheck-Warnungen in Core-Modulen
**Status**: ✅ **VOLLSTÄNDIG GELÖST** - Alle Warnungen behoben

```bash
# Code-Qualität validieren:
shellcheck src/**/*.sh  # Keine Warnungen
# Alle SC2155, SC2086, SC2001 Warnungen behoben
```

### Aktuelle Häufige Probleme

#### claunch-Session wird nicht erkannt
```bash
# Session-Dateien prüfen
ls -la ~/.claude_session_*

# tmux-Sessions auflisten
tmux list-sessions

# Manuell Session-Datei erstellen
echo "sess-your-session-id" > ~/.claude_session_$(basename $(pwd))

# System fällt automatisch auf direct-mode zurück wenn nötig
```

#### Terminal-App wird nicht erkannt
```bash
# Manuell Terminal-App spezifizieren
./src/hybrid-monitor.sh --terminal-app terminal --new-terminal --continuous

# Verfügbare Terminal-Apps anzeigen
./src/hybrid-monitor.sh --list-terminals
```

#### Bash-Versionsprobleme
```bash
# Bash-Version prüfen (4.0+ erforderlich)
bash --version

# macOS: Moderne Bash installieren
brew install bash
echo '/opt/homebrew/bin/bash' | sudo tee -a /etc/shells
chsh -s /opt/homebrew/bin/bash  # Optional als Standard setzen
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

### Performance & Qualitätsmetriken 📊

Das System läuft jetzt mit optimaler Performance:

- ✅ **Test-Ausführung**: 75 Sekunden (vorher 180+ Sekunden)
- ✅ **Test-Erfolgsrate**: 71% zuverlässige Ausführung (vorher ~30%)
- ✅ **Code-Qualität**: 0 ShellCheck-Warnungen (vorher 90+)
- ✅ **Abhängigkeitserkennung**: 40% schnellere claunch-Verification
- ✅ **Fehlerbehandlung**: Robuste Fallback-Mechanismen

## 📋 Task Queue System

### Task Queue Funktionalität

Das Task Queue Core Module bietet sequenzielles Management von GitHub Issues und Tasks:

```bash
# Task Queue System aktivieren
source src/task-queue.sh
init_task_queue

# GitHub Issue als Task hinzufügen
add_task_to_queue "github_issue" 1 "" "40" "Implement Task Queue Core Module"

# Nächste prioritäre Task abrufen
task_id=$(get_next_task)

# Task-Status aktualisieren
update_task_status "$task_id" "in_progress"
update_task_status "$task_id" "completed"

# Queue-Statistiken anzeigen
get_queue_statistics
```

### Task Queue Konfiguration

```bash
# config/default.conf
TASK_QUEUE_ENABLED=false          # Task Queue aktivieren/deaktivieren
TASK_DEFAULT_TIMEOUT=3600         # Standard-Timeout (1 Stunde)
TASK_MAX_RETRIES=3               # Maximale Wiederholungsversuche
TASK_RETRY_DELAY=300             # Verzögerung zwischen Wiederholungen (5 Min)
QUEUE_LOCK_TIMEOUT=30            # File-Locking-Timeout (30 Sek)
```

### Unterstützte Task-Typen

- **GitHub Issue Tasks**: Automatische Integration mit GitHub API
- **Custom Tasks**: Benutzerdefinierte Aufgaben mit flexiblen Metadaten
- **Priority Management**: 1-10 Priority-Scale (1 = höchste Priorität)
- **Status Tracking**: pending → in_progress → completed/failed/timeout
- **Issue-Merge Workflows**: Automatisierte Entwicklungszyklen (develop → clear → review → merge)

### 📂 Lokale Task Queues (NEU in v2.0.0 - Issue #91)

Das System unterstützt jetzt **projekt-spezifische Task Queues** mit `.claude-tasks/` Verzeichnissen:

#### Funktionsweise
- **Automatische Detection**: System erkennt `.claude-tasks/` Verzeichnis im aktuellen Projekt
- **Projekt-Isolation**: Jedes Projekt hat seine eigene unabhängige Task Queue
- **Git-Integration**: Optionale Versionskontrolle für Team-Collaboration
- **Backup System**: Automatische Sicherung bei Änderungen

#### Grundlegende Verwendung
```bash
# Neue lokale Queue initialisieren
./src/task-queue.sh init-local-queue "my-project"

# Queue-Context anzeigen (lokal vs. global)
./src/task-queue.sh show-context

# Tasks hinzufügen (automatisch zur lokalen Queue wenn verfügbar)
./src/task-queue.sh add-custom "Fix authentication bug"

# Tasks auflisten (zeigt lokale Queue an)
./src/task-queue.sh list

# Status anzeigen
./src/task-queue.sh status
```

#### Advanced Features
```bash
# Mit Git-Tracking initialisieren (für Team-Collaboration)
./src/task-queue.sh init-local-queue "team-project" --git

# Context explizit wechseln
./src/task-queue.sh add-custom "Global task" --global  # Erzwingt globale Queue
./src/task-queue.sh list --local                       # Erzwingt lokale Queue

# Migration (geplant für Phase 2)
./src/task-queue.sh migrate-to-local "existing-project"
```

#### Verzeichnisstruktur
```
mein-projekt/
├── src/
├── package.json
└── .claude-tasks/           # Lokale Task Queue
    ├── queue.json           # Aktuelle Tasks
    ├── completed.json       # Abgeschlossene Tasks
    ├── config.json          # Projekt-spezifische Einstellungen
    └── backups/             # Automatische Backups
        └── backup-*.json
```

#### Vorteile lokaler Queues
- **🚀 Projekt-Isolation**: Keine Cross-Kontamination zwischen Projekten
- **👥 Team-Collaboration**: Tasks via Git teilbar (optional)
- **📱 Portabilität**: Tasks folgen dem Projekt zwischen Maschinen
- **🔍 Context-Awareness**: System erkennt automatisch Projekt-Kontext
- **🔒 Backup-Sicherheit**: Automatische Sicherung vor jeder Änderung

#### Migration & Backward Compatibility
- **Vollständig rückwärtskompatibel**: Globale Queue funktioniert weiterhin
- **Automatische Fallback**: Ohne lokale Queue wird globale Queue verwendet
- **Schrittweise Migration**: Projekte können einzeln migriert werden

### 🧹 Context Clearing zwischen Tasks (NEU in v1.2)

Das System bietet automatisches Context Clearing zwischen Tasks für saubere Task-Trennung:

#### Standard-Verhalten (Empfohlen)
```bash
# Jede Task startet automatisch mit frischem Context
claude-auto-resume --add-custom "Fix login bug"      # Wird abgeschlossen → /clear gesendet
claude-auto-resume --add-custom "Add dark mode"      # Startet mit sauberem Context
```

#### Verwandte Tasks (Context-Erhaltung)
```bash
# Für zusammenhängende Aufgaben Context beibehalten
claude-auto-resume --add-custom "Design user model" --no-clear-context
claude-auto-resume --add-custom "Implement user model" --no-clear-context
claude-auto-resume --add-custom "Test user model" --clear-context
# → Context fließt durch erste zwei, wird nach der dritten gelöscht
```

#### Verfügbare CLI-Optionen
- `--clear-context`: Context nach Task explizit löschen (überschreibt globale Einstellung)
- `--no-clear-context`: Context nach Task beibehalten (überschreibt globale Einstellung)
- Ohne Flags: Globale Einstellung `QUEUE_SESSION_CLEAR_BETWEEN_TASKS` verwenden

#### Intelligente Recovery-Logik
- **Usage Limit Recovery**: Context wird automatisch beibehalten für Task-Fortsetzung
- **Normale Completion**: Context wird standardmäßig gelöscht für saubere Trennung
- **Explizite Übersteuerung**: Task-Level-Flags haben höchste Priorität

## 🔄 Issue-Merge Workflow System

### Automatisierte Entwicklungszyklen

Das Issue-Merge Workflow System automatisiert den kompletten Entwicklungslebenszyklus von GitHub Issues durch sequenzielle Ausführung der Phasen develop, clear, review und merge.

#### Workflow-Funktionen

```bash
# Issue-Merge Workflow erstellen
./src/task-queue.sh create-issue-merge 94

# Workflow-Status überwachen  
./src/task-queue.sh workflow status workflow-issue-94-20250831

# Workflow fortsetzen nach Unterbrechung
./src/task-queue.sh workflow resume workflow-issue-94-20250831

# Alle Workflows auflisten
./src/task-queue.sh workflow list in_progress
```

#### Workflow-Phasen

**1. Develop Phase**
- Führt `/dev {issue-id}` aus
- Wartet auf PR-Erstellung oder Feature-Implementierung
- Überwacht Completion-Patterns für erfolgreiche Entwicklung

**2. Clear Phase**  
- Führt `/clear` aus für sauberen Kontext
- Bereitet das System für objektive Review vor
- Minimale Wartezeit (30 Sekunden)

**3. Review Phase**
- Führt `/review PR-{issue-id}` aus  
- Analysiert die implementierten Änderungen
- Wartet auf Review-Completion oder Recommendations

**4. Merge Phase**
- Führt `/dev merge-pr {issue-id} --focus-main` aus
- Integriert Änderungen in den Hauptbranch
- Bestätigt erfolgreichen Merge-Abschluss

#### Erweiterte Features

**Automatic Recovery:**
- Intelligente Fehlerklassifizierung (network, session, auth, syntax, usage_limit)
- Exponential Backoff-Strategien für Wiederholungsversuche  
- Checkpoint-System für Workflow-Wiederaufnahme

**Progress Monitoring:**
- Real-time Status-Tracking mit Fortschrittsanzeige
- Detaillierte Timing-Informationen und ETA-Berechnung
- Session-Health-Monitoring während Ausführung

**Error Handling:**
- Pausieren und Fortsetzen von Workflows
- Resume von spezifischen Workflow-Schritten
- Automatische Bereinigung nach Usage-Limits

#### Completion Detection

Das System verwendet sophistizierte Pattern-Matching für zuverlässige Command-Completion-Detection:

```bash
# Development Phase Patterns
"pull request.*created|pr.*created|committed.*changes"

# Review Phase Patterns  
"review.*complete|analysis.*complete|summary|recommendation"

# Merge Phase Patterns
"merge.*successful|merged.*successfully|main.*updated"
```

#### Workflow-Konfiguration

```bash
# Phase-spezifische Timeouts
DEVELOP_TIMEOUT=600    # 10 Minuten für Entwicklungsarbeit
CLEAR_TIMEOUT=30       # 30 Sekunden für Context-Clearing  
REVIEW_TIMEOUT=480     # 8 Minuten für Review-Arbeit
MERGE_TIMEOUT=300      # 5 Minuten für Merge-Operationen

# Error Recovery Settings
MAX_WORKFLOW_RETRIES=5      # Maximale Workflow-Wiederholungen
STEP_RETRY_DELAY=5         # Basis-Delay zwischen Step-Retries  
USAGE_LIMIT_COOLDOWN=300   # Wartezeit nach Usage-Limits

# Session Integration
USE_CLAUNCH=true           # Integration mit claunch Session-Management
CLAUNCH_MODE="tmux"        # tmux-basierte Session-Persistenz
```

#### Beispiel: Vollständiger Workflow

```bash
# 1. Issue-Merge Workflow für Issue #94 erstellen
workflow_id=$(./src/task-queue.sh create-issue-merge 94)
echo "Created workflow: $workflow_id"

# 2. Workflow-Ausführung starten
./src/task-queue.sh execute "$workflow_id"

# 3. Live-Monitoring in separatem Terminal
watch -n 10 './src/task-queue.sh workflow status '"$workflow_id"' | jq'

# 4. Bei Bedarf manuell fortsetzen
./src/task-queue.sh workflow resume "$workflow_id"

# 5. Detaillierte Statusinformationen
./src/task-queue.sh workflow detailed-status "$workflow_id"
```

#### Status-Reporting Beispiel

```json
{
  "workflow_id": "workflow-issue-94-20250831",
  "workflow_type": "issue-merge", 
  "status": "in_progress",
  "progress": {
    "current_step": 2,
    "total_steps": 4,
    "percentage": 50.0,
    "current_step_info": {
      "phase": "review",
      "status": "in_progress",
      "command": "/review PR-94"
    }
  },
  "timing": {
    "elapsed_seconds": 847,
    "estimated_completion": "2025-08-31T14:23:00Z"
  },
  "errors": {
    "count": 1,
    "last_error": {
      "type": "network_error",
      "timestamp": "2025-08-31T13:45:00Z"
    }
  }
}
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

## 🚀 CI/CD Pipeline

### Automated Testing
Das Projekt verfügt über eine umfassende GitHub Actions CI/CD Pipeline:

**🔍 Code Quality Checks:**
- ✅ **ShellCheck** - Statische Analyse aller Bash-Scripts
- ✅ **Syntax Validation** - Überprüfung auf Shell-Syntax-Fehler
- ✅ **Security Scanning** - Prüfung auf potenzielle Sicherheitslücken

**🧪 Multi-Platform Testing:**
- ✅ **Ubuntu Latest** - Primäre Testplattform mit vollständiger Test-Suite
- ✅ **macOS Latest** - Cross-Platform-Kompatibilitätstests
- ✅ **Multi-Bash** - Tests mit Bash 4.4, 5.0, 5.1

**📊 Test Coverage:**
- ✅ **BATS Test Suite** - Umfassende Unit- und Integration-Tests
- ✅ **Task Execution Engine** - Alle 8 Phasen der Task-Engine validiert
- ✅ **CLI Interface** - Alle 14 Task Queue Parameter getestet
- ✅ **End-to-End Tests** - Komplette Workflow-Validierung

### Pipeline Status
```bash
# Aktuelle Pipeline-Ergebnisse prüfen
git clone https://github.com/trytofly94/Claude-Auto-Resume-System.git
cd Claude-Auto-Resume-System

# Lokale Tests ausführen
./scripts/setup.sh
bats tests/simple-task-engine-test.bats
```

### Release Management
- 🏷️ **Automatische Releases** - Semantic Versioning mit Git Tags
- 📦 **Packaged Assets** - Tar.gz und Zip-Archive für jede Version
- 📝 **Changelog Generation** - Automatische Generierung aus Commit-History
- 🔄 **Continuous Integration** - Automatische Tests bei jedem PR und Push

## 🛠️ Issue-Merge Workflow Troubleshooting

### Workflow-spezifische Probleme

#### Workflow hängt in einer Phase fest

**Problem**: Workflow bleibt in einer bestimmten Phase stehen ohne fortzufahren.

**Diagnose**:
```bash
# Workflow-Status prüfen
./src/task-queue.sh workflow detailed-status workflow-issue-X-YYYYMMDD

# Pattern-Detection debuggen
export DEBUG=1
./src/task-queue.sh workflow resume workflow-issue-X-YYYYMMDD
```

**Lösungsansätze**:
```bash
# 1. Completion-Patterns anpassen
export DEVELOP_COMPLETION_PATTERNS="pull request.*created|pr.*created|feature.*complete"
export REVIEW_COMPLETION_PATTERNS="review.*complete|analysis.*finished|recommendations"

# 2. Timeouts erhöhen
export DEVELOP_TIMEOUT=900    # 15 Minuten für komplexe Features
export REVIEW_TIMEOUT=600     # 10 Minuten für ausführliche Reviews

# 3. Workflow von spezifischem Schritt fortsetzen
./src/task-queue.sh workflow resume-from-step workflow-id 2
```

#### Pattern-Detection versagt

**Problem**: Workflow erkennt nicht, wann Claude-Befehle abgeschlossen sind.

**Symptome**:
- Timeouts trotz erfolgreichem Abschluss
- Workflow hängt endlos in Monitoring-Phase

**Debugging**:
```bash
# 1. Claude-Session-Output prüfen
tmux capture-pane -t claude-session -p | tail -20

# 2. Pattern-Matching testen
echo "Your Claude output here" | grep -E "pull request.*created|pr.*created"

# 3. Debug-Modus aktivieren
export DEBUG=1
DEVELOP_COMPLETION_PATTERNS="your_custom_pattern" ./src/task-queue.sh workflow resume workflow-id
```

**Lösungen**:
```bash
# Benutzerdefinierte Patterns definieren
export DEVELOP_COMPLETION_PATTERNS="successfully.*created|implementation.*complete|pr.*#[0-9]+"
export CLEAR_COMPLETION_PATTERNS="context.*cleared|ready.*for.*next"
export REVIEW_COMPLETION_PATTERNS="review.*complete|summary.*provided|assessment.*finished"
export MERGE_COMPLETION_PATTERNS="merged.*successfully|main.*branch.*updated|closed.*issue"

# Fallback auf längere Timeouts
export GENERIC_TIMEOUT=300  # 5 Minuten
export DEVELOP_TIMEOUT=1200 # 20 Minuten für große Features
```

#### Resource-Warnungen und Performance-Probleme

**Problem**: Workflows verlangsamen das System oder lösen Resource-Warnungen aus.

**Resource-Monitoring**:
```bash
# Resource-Monitoring konfigurieren
export MAX_CPU_PERCENT=60        # CPU-Schwelle reduzieren
export MAX_MEMORY_MB=256         # Memory-Limit anpassen
export RESOURCE_CHECK_INTERVAL=30 # Häufigere Checks

# Resource-Monitoring deaktivieren
export ENABLE_RESOURCE_MONITORING=false
```

**Performance-Optimierung**:
```bash
# Polling-Intervalle reduzieren
export RESOURCE_CHECK_INTERVAL=120  # Alle 2 Minuten statt 1 Minute

# Backoff-Parameter anpassen
export BACKOFF_BASE_DELAY=10       # Längere Base-Delays
export BACKOFF_MAX_DELAY=600       # Maximale Wartezeit: 10 Minuten
export BACKOFF_JITTER_RANGE=5      # Mehr Jitter gegen Synchronisation
```

#### Error-Recovery und Retry-Logik

**Problem**: Workflows schlagen mit nicht-wiederherstellbaren Fehlern fehl.

**Error-Klassifizierung**:
- `network_error`: Wiederherstellbar mit Backoff
- `session_error`: Wiederherstellbar durch Session-Neustart  
- `auth_error`: Nicht wiederherstellbar - Authentifizierung erforderlich
- `syntax_error`: Nicht wiederherstellbar - Command-Fix erforderlich
- `usage_limit_error`: Wiederherstellbar nach Cooldown (5 Min)
- `timeout_error`: Wiederherstellbar mit längerem Timeout

**Recovery-Strategien**:
```bash
# 1. Workflow-Status und Error-History prüfen
./src/task-queue.sh workflow detailed-status workflow-id | jq '.errors'

# 2. Manuelle Wiederaufnahme
./src/task-queue.sh workflow resume workflow-id

# 3. Von spezifischem Schritt fortsetzen
./src/task-queue.sh workflow resume-from-step workflow-id 1

# 4. Workflow pausieren/abbrechen
./src/task-queue.sh workflow pause workflow-id
./src/task-queue.sh workflow cancel workflow-id
```

### Konfiguration Best Practices

#### Optimale Timeout-Werte

```bash
# Für kleine Issues/Bugfixes
export DEVELOP_TIMEOUT=300    # 5 Minuten
export REVIEW_TIMEOUT=180     # 3 Minuten  
export MERGE_TIMEOUT=120      # 2 Minuten

# Für große/komplexe Features  
export DEVELOP_TIMEOUT=1200   # 20 Minuten
export REVIEW_TIMEOUT=600     # 10 Minuten
export MERGE_TIMEOUT=300      # 5 Minuten
```

#### Completion-Pattern-Templates

```bash
# Entwicklungsphase - PR-Erstellung
export DEVELOP_COMPLETION_PATTERNS="pull request.*created|pr.*#[0-9]+|feature.*implemented|issue.*complete"

# Review-Phase - Analyse abgeschlossen  
export REVIEW_COMPLETION_PATTERNS="review.*complete|analysis.*finished|summary|assessment.*complete"

# Merge-Phase - Integration erfolgreich
export MERGE_COMPLETION_PATTERNS="merged.*successfully|main.*updated|issue.*closed|merge.*complete"
```

### Häufige Fehlertypen

| Fehlertyp | Lösung |
|-----------|--------|
| `Command timeout` | Timeout erhöhen oder Pattern anpassen |
| `Session not found` | Session neu starten: `claunch start` |
| `Pattern not matched` | Custom Patterns definieren |
| `Resource warning` | Limits anpassen oder Monitoring reduzieren |
| `Auth error` | `claude auth login` ausführen |
| `Syntax error` | Workflow-Definition überprüfen |

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