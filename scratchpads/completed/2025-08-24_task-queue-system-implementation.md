# Task-Queue-System für Claude Auto-Resume

**Erstellt**: 2025-08-24  
**Typ**: Feature  
**Geschätzter Aufwand**: Groß  
**Verwandtes Issue**: Neue Anforderung  

## Kontext & Ziel

Implementierung eines intelligenten Task-Queue-Systems für das Claude Auto-Resume System, das die Bearbeitung mehrerer Aufgaben (GitHub Issues, PRs, Custom Tasks) in sequenzieller Abarbeitung ermöglicht. Das System soll sich nahtlos in die bestehende hybrid-monitor.sh Architektur integrieren und robuste Error-Handling-Mechanismen bieten.

## Anforderungen

- [ ] **Command-basierte Task-Completion-Erkennung**: Eindeutiges Pattern für erfolgreiche Task-Beendigung
- [ ] **CLI Task-Management**: Hinzufügen/Entfernen von Issues, PRs und Custom Tasks über Command-Line
- [ ] **Session-Trennung**: Automatisches `/clear` zwischen allen Tasks für saubere Trennung
- [ ] **Error-Handling für hängende Tasks**: Status-Backup als GitHub-Kommentar bei Timeouts
- [ ] **Usage-Limit-Recovery**: Intelligente Wiederaufnahme mit `continue`-Befehl nach Usage-Limits
- [ ] **Nahtlose Integration**: Erwiterung des bestehenden hybrid-monitor.sh Systems

## Untersuchung & Analyse

### Bestehende Architektur-Analyse

**Kernkomponenten:**
- `src/hybrid-monitor.sh`: Hauptüberwachungssystem mit kontinuierlicher Monitoring-Loop
- `src/session-manager.sh`: Session-Lifecycle-Management mit State-Tracking
- `src/claunch-integration.sh`: claunch-Wrapper für Session-Management
- `scratchpads/`: Bestehendes Scratchpad-System für Arbeitsplanung

**Integration-Punkte:**
- `continuous_monitoring_loop()` in hybrid-monitor.sh als Basis für Queue-Processing
- `SESSION_STATES` Dictionary in session-manager.sh für Task-Status-Tracking
- `send_command_to_session()` in claunch-integration.sh für Command-Injection

### Task-Completion-Pattern

**Gewähltes Pattern**: `###TASK_COMPLETE###`
- Eindeutig und unverwechselbar
- Nicht natürlich in Claude-Responses vorkommend
- Einfach via Regex erkennbar
- Von Claude leicht verwendbar in /dev-Commands

### State-Management-Strategie

**Lokale JSON-Dateien** für Persistenz:
- `queue/task-queue.json`: Haupt-Queue mit Task-Details
- `queue/queue-state.json`: Globaler Queue-Status
- `queue/task-states/`: Individuelle Task-Status-Dateien

## Implementierungsplan

### Phase 1: Kern-Module entwickeln
- [ ] **Task-Queue-Modul erstellen** (`src/task-queue.sh`)
  - Queue-Management (add, remove, list, status)
  - JSON-basierte Persistenz
  - Task-Status-Tracking
  - Priority-Management
- [ ] **GitHub-Integration-Modul** (`src/github-integration.sh`)
  - Issue/PR-Details abrufen
  - Status-Kommentare posten
  - Completion-Kommentare erstellen
- [ ] **Task-Execution-Engine** (Erweiterung von hybrid-monitor.sh)
  - Sequential Task Processing
  - Command-Completion-Detection
  - Session-Clearing zwischen Tasks
  - Error-Recovery-Mechanismen

### Phase 2: CLI-Interface erweitern
- [ ] **Command-Line-Parameter erweitern** (hybrid-monitor.sh)
  - `--queue-mode`: Queue-Processing aktivieren
  - `--add-issue N`: GitHub Issue zur Queue hinzufügen
  - `--add-pr N`: GitHub PR zur Queue hinzufügen
  - `--add-custom "description"`: Custom Task hinzufügen
  - `--list-queue`: Aktuelle Queue anzeigen
  - `--pause-queue` / `--resume-queue`: Queue-Steuerung
  - `--clear-queue`: Queue leeren
- [ ] **Queue-Status-Display**
  - Live-Progress-Anzeige während Verarbeitung
  - Detaillierte Task-Informationen
  - Completion-Statistiken

### Phase 3: Error-Handling & Recovery
- [ ] **Timeout-Detection implementieren**
  - Configurable Task-Timeouts
  - Automatic Timeout-Recovery
  - Progressive Timeout-Erhöhung
- [ ] **GitHub-Kommentar-Backup**
  - Automatische Status-Updates bei Timeouts
  - Progress-Snapshots bei kritischen Fehlern
  - Recovery-Instruktionen in Kommentaren
- [ ] **Usage-Limit-Integration**
  - Erweitere bestehende Usage-Limit-Erkennung
  - Queue-Pausierung bei Usage-Limits
  - Intelligente Wiederaufnahme nach Freischaltung

### Phase 4: Integration & Testing
- [ ] **Session-Manager-Integration**
  - Task-spezifische Session-States
  - Session-Lifecycle für Task-Processing
  - Session-Recovery bei Task-Fehlern
- [ ] **Comprehensive Testing**
  - Unit-Tests für alle Queue-Operationen
  - Integration-Tests mit echten GitHub-Issues
  - Error-Recovery-Szenarien testen
- [ ] **Configuration & Documentation**
  - Queue-Konfiguration in default.conf
  - CLI-Help-Updates
  - Usage-Beispiele und Best-Practices

## Fortschrittsnotizen

**2025-08-24**: Initial Planning und Architektur-Design abgeschlossen
- Bestehende Komponenten analysiert
- Integration-Strategie definiert
- Task-Completion-Pattern gewählt
- Implementation-Phasen geplant

## Technische Details

### Queue-Datenstrukturen

```json
// queue/task-queue.json
{
  "version": "1.0",
  "created": "2025-08-24T10:00:00Z",
  "tasks": [
    {
      "id": "task-001",
      "type": "github_issue",
      "priority": 1,
      "status": "pending",
      "github_number": 123,
      "title": "Fix login button bug",
      "created_at": "2025-08-24T10:00:00Z",
      "timeout": 3600,
      "retry_count": 0,
      "command": "/dev 123"
    },
    {
      "id": "task-002", 
      "type": "custom",
      "priority": 2,
      "status": "in_progress",
      "description": "Implement dark mode",
      "created_at": "2025-08-24T10:05:00Z",
      "timeout": 7200,
      "retry_count": 1,
      "command": "/dev implement dark mode feature"
    }
  ]
}
```

### Command-Completion-Detection

```bash
# In task-queue.sh
detect_task_completion() {
    local session_id="$1"
    local timeout="${2:-3600}"
    
    local start_time=$(date +%s)
    
    while true; do
        # Lese Session-Output
        local session_output
        session_output=$(capture_session_output "$session_id")
        
        # Prüfe auf Completion-Pattern
        if echo "$session_output" | grep -q "###TASK_COMPLETE###"; then
            log_info "Task completion detected for session: $session_id"
            return 0
        fi
        
        # Timeout-Check
        local current_time=$(date +%s)
        if [[ $((current_time - start_time)) -gt $timeout ]]; then
            log_warn "Task timeout reached for session: $session_id"
            return 1
        fi
        
        sleep 10
    done
}
```

### Session-Clearing-Mechanismus

```bash
# In task-queue.sh
clear_session_between_tasks() {
    local session_id="$1"
    
    log_info "Clearing session between tasks: $session_id"
    
    # Sende /clear Kommando
    if send_command_to_session "/clear" "$session_id"; then
        # Warte auf Clearing-Completion
        sleep 5
        
        # Verifiziere leere Session
        local output
        output=$(capture_session_output "$session_id")
        
        if [[ ${#output} -lt 100 ]]; then
            log_info "Session successfully cleared"
            return 0
        else
            log_warn "Session clearing may have failed"
            return 1
        fi
    else
        log_error "Failed to send clear command"
        return 1
    fi
}
```

### GitHub-Integration für Status-Updates

```bash
# In github-integration.sh  
post_task_status_comment() {
    local issue_number="$1"
    local status="$2"
    local details="$3"
    
    local comment_body="🤖 **Claude Auto-Resume Task Status Update**

**Status**: $status
**Timestamp**: $(date -Iseconds)
**Details**: $details

*This comment was automatically generated by the Claude Auto-Resume Task Queue System*"
    
    if gh issue comment "$issue_number" --body "$comment_body"; then
        log_info "Status comment posted to issue #$issue_number"
        return 0
    else
        log_error "Failed to post status comment to issue #$issue_number"
        return 1
    fi
}
```

## Ressourcen & Referenzen

- **Bestehende CLAUDE.md**: Architektur-Dokumentation und Integration-Guidelines
- **GitHub CLI Documentation**: `gh issue` und `gh pr` Commands für API-Integration
- **tmux Manual**: Session-Management und Command-Injection
- **JSON Specification**: Für Queue-Datenstrukturen und State-Management
- **Bash Best Practices**: Für robuste Error-Handling-Implementierung

## Konfiguration

### Neue Config-Parameter (config/default.conf)

```bash
# Task Queue Configuration
TASK_QUEUE_ENABLED=false
TASK_QUEUE_DIR="queue"
TASK_DEFAULT_TIMEOUT=3600
TASK_MAX_RETRIES=3
TASK_RETRY_DELAY=300
TASK_COMPLETION_PATTERN="###TASK_COMPLETE###"

# GitHub Integration
GITHUB_AUTO_COMMENT=true
GITHUB_STATUS_UPDATES=true
GITHUB_COMPLETION_NOTIFICATIONS=true

# Queue Processing
QUEUE_PROCESSING_DELAY=30
QUEUE_MAX_CONCURRENT=1
QUEUE_AUTO_PAUSE_ON_ERROR=true
QUEUE_BACKUP_FREQUENCY=300
```

## Testing-Strategie

### Unit-Tests
- [ ] Task-Queue-Operations (add, remove, status)
- [ ] JSON-Persistenz und -Recovery
- [ ] Command-Completion-Detection
- [ ] GitHub-API-Integration

### Integration-Tests  
- [ ] End-to-End Task-Processing mit echten GitHub Issues
- [ ] Error-Recovery-Szenarien (Timeouts, Network-Fehler)
- [ ] Usage-Limit-Handling in Queue-Context
- [ ] Session-Management während Task-Processing

### Performance-Tests
- [ ] Queue-Processing mit vielen Tasks
- [ ] Memory-Usage bei Lang-laufenden Queues
- [ ] Recovery-Zeit nach System-Restarts

## Abschluss-Checkliste

- [ ] **Kern-Funktionalität implementiert**
  - Task-Queue-Management vollständig
  - CLI-Interface funktional
  - GitHub-Integration aktiv
- [ ] **Error-Handling robust**  
  - Timeout-Detection funktional
  - Recovery-Mechanismen getestet
  - Usage-Limit-Integration abgeschlossen
- [ ] **Tests geschrieben und bestanden**
  - Unit-Tests für alle Module
  - Integration-Tests erfolgreich
  - Performance-Tests bestanden
- [ ] **Dokumentation aktualisiert**
  - README mit Queue-Funktionalität erweitert
  - CLI-Help-Texte aktualisiert
  - Configuration-Guide erstellt
- [ ] **Code-Review durchgeführt** 
  - Security-Review für GitHub-Integration
  - Performance-Review für Queue-Processing
  - Architecture-Review für bestehende Integration

---
**Status**: Aktiv  
**Zuletzt aktualisiert**: 2025-08-24