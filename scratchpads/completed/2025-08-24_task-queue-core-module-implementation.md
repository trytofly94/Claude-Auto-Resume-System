# Phase 1: Task Queue Core Module Implementation

**Erstellt**: 2025-08-24
**Typ**: Feature  
**Geschätzter Aufwand**: Groß
**Verwandtes Issue**: GitHub #40

## Kontext & Ziel

Implementierung des Kern-Task-Queue-Management-Systems für Claude Auto-Resume als Fundament für sequenzielle Task-Verarbeitung. Dieses Modul bildet das Herzstück des geplanten Task-Queue-Systems und stellt alle essentiellen Funktionen für Queue-Management, JSON-basierte Persistenz und Task-Status-Tracking bereit.

## Anforderungen

- [ ] **Queue-Management-Funktionen**
  - Tasks zur Queue hinzufügen (GitHub Issues, PRs, Custom Tasks)
  - Tasks aus Queue entfernen
  - Aktuellen Queue-Status auflisten
  - Gesamte Queue leeren
  - Task-Prioritäten aktualisieren

- [ ] **JSON-basierte Persistenz**
  - Queue-State in `queue/task-queue.json` speichern
  - Individuelle Task-States in `queue/task-states/` speichern
  - Atomare Datei-Operationen für Datenintegrität
  - Queue-Recovery nach System-Neustart

- [ ] **Task-Status-Tracking**
  - Task-States verfolgen: pending, in_progress, completed, failed, timeout
  - Task-Erstellungszeiten und Verarbeitungsdauer aufzeichnen
  - Retry-Counts und Fehler-Historien verwalten
  - Task-Priorisierung (Skala 1-10) unterstützen

- [ ] **Datenstrukturen**
  - Task-Objekte mit: id, type, priority, status, metadata
  - GitHub Issue/PR Tasks mit issue_number, title, labels
  - Custom Tasks mit description und custom commands
  - Queue-Statistiken und Verarbeitungsmetriken

## Untersuchung & Analyse

### Bestehende Architektur-Integration-Punkte

**Analyisierte Kern-Komponenten:**
- `src/hybrid-monitor.sh`: Haupt-Monitoring-Loop als Basis für Queue-Processing-Integration
- `src/session-manager.sh`: Session-State-Management mit `SESSION_STATES` Dictionary - perfekt als Muster für Task-State-Tracking
- `src/utils/logging.sh`: Strukturiertes Logging-System mit JSON-Support - direkt wiederverwendbar
- `config/default.conf`: Konfigurationssystem - erweiterbar für Queue-spezifische Einstellungen

**Identifizierte Integration-Patterns:**
- Bestehende `SESSION_STATES` Dictionary-Struktur als Vorlage für `TASK_STATES`
- Logging-Functions `log_info`, `log_warn`, `log_error` für konsistente Ausgaben
- Config-Loading-Pattern aus `hybrid-monitor.sh` für Queue-Konfiguration
- Signal-Handler und Cleanup-Pattern für robuste Resource-Management

**Prior Art Recherche:**
- Bestehender Scratchpad: `scratchpads/active/2025-08-24_task-queue-system-implementation.md` enthält übergeordnete Architektur
- Related Issues: #41 (GitHub Integration), #42 (Task Execution Engine), #43 (Error Handling), #44 (Testing)
- Kein vorheriger Code für Task-Queue-Module gefunden - Clean Slate Implementation

### Datenstruktur-Design basierend auf bestehenden Patterns

**Angelehnt an SESSION_STATES Pattern aus session-manager.sh:**
```bash
# Analog zu declare -A SESSION_STATES
declare -A TASK_STATES
declare -A TASK_METADATA
declare -A TASK_RETRY_COUNTS
declare -A TASK_TIMESTAMPS
```

**JSON-Schema-Design basierend auf Claude Auto-Resume Logging-Patterns:**
```json
{
  "version": "1.0",
  "created": "2025-08-24T10:00:00Z",
  "last_updated": "2025-08-24T10:15:00Z", 
  "total_tasks": 2,
  "pending_tasks": 1,
  "active_tasks": 1,
  "completed_tasks": 0,
  "failed_tasks": 0,
  "tasks": [
    {
      "id": "task-001",
      "type": "github_issue", 
      "priority": 1,
      "status": "pending",
      "github_number": 40,
      "title": "Phase 1: Implement Task Queue Core Module",
      "labels": ["enhancement"],
      "created_at": "2025-08-24T10:00:00Z",
      "updated_at": "2025-08-24T10:00:00Z",
      "timeout": 3600,
      "retry_count": 0,
      "max_retries": 3,
      "command": "/dev 40"
    }
  ]
}
```

## Implementierungsplan

### Schritt 1: Verzeichnisstruktur und Grundlagen schaffen
- [ ] `queue/` Basis-Verzeichnis erstellen
- [ ] `queue/task-states/` Verzeichnis für individuelle Task-Files
- [ ] `queue/backups/` Verzeichnis für Queue-Backups
- [ ] Basis-Funktionen für Verzeichnis-Existenz-Prüfung

### Schritt 2: Core Task-Queue-Modul entwickeln (`src/task-queue.sh`)
- [ ] **Basis-Framework erstellen**
  - Skript-Header mit Version und Dokumentation
  - Dependency-Loading (logging.sh, existierende Utilities)
  - Globale Variablen und Konstanten definieren
  - Signal-Handler und Cleanup-Functions

- [ ] **Task-ID-Generation und Validation**
  ```bash
  generate_task_id()        # UUID-ähnliche eindeutige IDs
  validate_task_data()      # Input-Sanitization und Struktur-Validation
  ```

- [ ] **Kern-Queue-Operations**
  ```bash
  add_task_to_queue()       # Task mit allen Metadaten hinzufügen
  remove_task_from_queue()  # Task entfernen mit Cleanup
  get_next_task()          # Nächster Task basierend auf Priority/FIFO
  update_task_status()     # Status-Update mit Timestamp
  update_task_priority()   # Priority-Update mit Queue-Resort
  list_queue_tasks()       # Formatierte Ausgabe aller Tasks
  clear_task_queue()       # Complete Queue-Reset mit Backup
  ```

### Schritt 3: JSON-Persistenz-Layer implementieren
- [ ] **Atomare File-Operations** (kritisch für Datenintegrität)
  ```bash
  save_queue_state()       # Atomic write mit temp-file + mv
  load_queue_state()       # JSON parsing mit jq + validation
  backup_queue_state()     # Timestamped backup creation
  recover_queue_state()    # Backup-basierte Recovery
  ```

- [ ] **Individual Task-State-Files**
  ```bash
  save_task_state()        # Ein Task-State in queue/task-states/
  load_task_state()        # Einzelnen Task-State laden
  cleanup_old_task_states() # Garbage collection für completed/failed
  ```

- [ ] **File-Locking für Concurrent Access** (mit flock)
  ```bash
  acquire_queue_lock()     # Exclusive lock für queue-operations
  release_queue_lock()     # Clean lock release
  with_queue_lock()        # Wrapper-Function für sichere Operationen
  ```

### Schritt 4: Task-Status-Tracking-System
- [ ] **Status-Management-Functions**
  ```bash
  initialize_task_state()  # Neuer Task mit "pending" Status
  transition_task_state()  # Status-Übergänge mit Validation
  get_task_status()        # Current status mit Metadata
  get_task_history()       # Complete state-change history
  ```

- [ ] **Retry-Logic und Error-Tracking**
  ```bash
  increment_retry_count()  # Retry-Counter mit Max-Limit-Check
  record_task_error()      # Error-Details mit Timestamp
  check_retry_eligibility() # Retry-berechtigung prüfen
  ```

- [ ] **Timing und Performance-Tracking**
  ```bash
  record_task_start()      # Start-Timestamp setzen
  record_task_completion() # End-Timestamp und Duration berechnen
  get_task_duration()      # Verarbeitungszeit abrufen
  get_queue_statistics()   # Overall Queue-Performance-Metrics
  ```

### Schritt 5: Priority-Management und Task-Ordering
- [ ] **Priority-System implementieren**
  ```bash
  set_task_priority()      # Priority 1-10 mit Validation
  get_priority_order()     # Sortierte Task-Liste nach Priority
  reorder_queue()          # Queue neu sortieren nach Priority-Changes
  ```

- [ ] **Smart Queue-Ordering Logic**
  - Priority-basierte Sortierung (1 = höchste Priority)
  - FIFO für gleiche Priority-Level
  - Berücksichtigung von Retry-Tasks (lower effective priority)

### Schritt 6: Integration-Support für GitHub Tasks
- [ ] **GitHub-spezifische Task-Typen**
  ```bash
  create_github_issue_task() # Issue-basierte Task-Erstellung
  create_github_pr_task()    # PR-basierte Task-Erstellung
  validate_github_task()     # GitHub-specific validation
  ```

- [ ] **GitHub-Metadata-Handling**
  - Issue/PR Nummer, Title, Labels
  - URL-Generation für GitHub-Links
  - Kommando-Template-Generation (`/dev N`)

### Schritt 7: Error-Handling und Robustness
- [ ] **Comprehensive Input-Validation**
  - JSON-Schema-Validation mit jq
  - Task-ID-Format-Validation
  - Status-Transition-Validation
  - Priority-Range-Validation

- [ ] **Error-Recovery-Mechanisms**
  - Corrupted JSON-File Recovery von Backups
  - Missing Task-State-File Recreation
  - Inconsistent State-Resolution
  - Partial Operation Recovery

- [ ] **Logging und Monitoring-Integration**
  - Structured Logging für alle Operations
  - Performance-Metrics-Logging
  - Error-Tracking mit Details
  - Integration mit bestehendem Logging-System

### Schritt 8: Tests und Validation
- [ ] **Unit-Tests für Core Functions**
  - Queue-Operations (add, remove, list, clear)
  - JSON-Persistenz und Recovery
  - Task-Status-Transitions
  - Priority-Management

- [ ] **Integration-Tests** 
  - File-Locking unter Concurrent-Access
  - JSON-File-Corruption-Recovery
  - Large-Queue-Performance (100+ Tasks)
  - Memory-Usage-Profiling

- [ ] **Error-Scenario-Testing**
  - Disk-Full-Scenarios
  - Permission-Issues
  - Corrupted-JSON-Files
  - Missing-Dependencies (jq, flock)

## Fortschrittsnotizen

**2025-08-24**: Initial Analysis und Detailed Planning abgeschlossen
- GitHub Issue #40 Details analysiert  
- Bestehende Codebase-Patterns studiert (hybrid-monitor.sh, session-manager.sh, logging.sh)
- Integration-Punkte mit bestehender Architektur identifiziert
- Übergeordneten Task-Queue-System-Scratchpad als Context einbezogen
- Detaillierten Implementierungsplan mit 8 Phasen entwickelt
- Technical Design für JSON-Schema und Function-API erstellt

**2025-08-24**: Core Module Implementation abgeschlossen
- ✅ **Kern-Task-Queue-Modul entwickelt** (`src/task-queue.sh`)
  - Vollständige Implementierung aller Queue-Management-Funktionen
  - Task-ID-Generation mit Validation
  - Comprehensive Input-Validation für alle Parameter
  - Robuste Error-Handling mit strukturiertem Logging
  
- ✅ **JSON-Persistenz-Layer implementiert**
  - Atomare File-Operations mit temp-file + mv Pattern
  - JSON-Schema-konforme Datenstrukturen 
  - Backup-System für Data-Recovery
  - jq-basierte JSON-Validation
  
- ✅ **Task-Status-Tracking-System**
  - State-Machine mit validierten Transitionen
  - Timestamp-Tracking für alle Status-Changes
  - Retry-Counter und Error-History
  - Performance-Metrics (Duration-Tracking)
  
- ✅ **Priority-Management implementiert**
  - 1-10 Priority-Scale (1 = höchste Priority)
  - FIFO für gleiche Priority-Level
  - Smart Queue-Ordering-Algorithmus
  
- ✅ **GitHub-Integration-Support**
  - Spezielle Task-Typen für Issues und PRs
  - Metadata-Handling für GitHub-spezifische Felder
  - Command-Template-Generation (`/dev N`)
  
- ✅ **Konfiguration erweitert**
  - Alle Task-Queue-Parameter in `config/default.conf`
  - Environment-Variable-Override-Support
  - Backward-Compatibility gewährleistet
  
- ✅ **Verzeichnisstruktur erstellt**
  - `queue/` für JSON-Persistenz
  - `queue/task-states/` für individuelle Task-Files (vorbereitet)
  - `queue/backups/` für automatische Backups
  
- ✅ **Cross-Platform-Compatibility**
  - Alternative File-Locking für macOS (ohne flock)
  - Robust gegen fehlende Dependencies
  - Graceful Degradation bei System-Unterschieden

**Bekannte Limitations:**
- ⚠️ CLI `with_queue_lock` Mechanismus benötigt Verfeinerung
- ⚠️ File-Locking kann in Edge-Cases timeout
- ⚠️ Subshell-Issue bei CLI-Operations (Arrays persistieren nicht zwischen Calls)

**Produktive Funktionen:**
- Alle Core-Functions arbeiten korrekt in Memory
- JSON-Persistenz und Recovery funktional
- Task-Lifecycle-Management vollständig implementiert
- Statistics und Monitoring bereit
- Error-Handling und Validation robust

**Commit:** `c87c049` - Vollständige Core-Implementierung mit 2415+ Zeilen Code

## Technische Details

### File-Locking-Strategie für Atomic Operations

```bash
# Wrapper für sichere Queue-Operationen
with_queue_lock() {
    local operation="$1"
    shift
    local lock_file="queue/.queue.lock"
    local lock_timeout=30
    
    # Acquire exclusive lock
    (
        flock -x -w $lock_timeout 200
        if [[ $? -ne 0 ]]; then
            log_error "Failed to acquire queue lock within $lock_timeout seconds"
            return 1
        fi
        
        log_debug "Acquired queue lock for operation: $operation"
        
        # Execute operation with lock held
        "$operation" "$@"
        local result=$?
        
        log_debug "Released queue lock for operation: $operation"
        return $result
        
    ) 200>"$lock_file"
}
```

### Atomic JSON-File-Writing Pattern

```bash
save_queue_state() {
    local queue_file="queue/task-queue.json"
    local temp_file="$queue_file.tmp.$$"
    local backup_file="queue/backups/backup-$(date +%Y%m%d-%H%M%S).json"
    
    # Create backup of existing file
    if [[ -f "$queue_file" ]]; then
        cp "$queue_file" "$backup_file" || {
            log_error "Failed to create backup before save"
            return 1
        }
    fi
    
    # Write to temp file first
    if generate_queue_json > "$temp_file"; then
        # Validate JSON before replacing original
        if jq empty "$temp_file" 2>/dev/null; then
            mv "$temp_file" "$queue_file" || {
                log_error "Failed to move temp file to queue file"
                rm -f "$temp_file"
                return 1
            }
            log_debug "Queue state saved successfully"
            return 0
        else
            log_error "Generated JSON is invalid, aborting save"
            rm -f "$temp_file"
            return 1
        fi
    else
        log_error "Failed to generate JSON for queue state"
        rm -f "$temp_file"
        return 1
    fi
}
```

### Task-State-Transition-Logic

```bash
# Valid state transitions
declare -A VALID_TRANSITIONS=(
    ["pending"]="in_progress,failed"
    ["in_progress"]="completed,failed,timeout" 
    ["completed"]=""  # Terminal state
    ["failed"]="pending"  # Can retry
    ["timeout"]="pending"  # Can retry
)

transition_task_state() {
    local task_id="$1"
    local new_state="$2"
    local current_state
    
    current_state=$(get_task_status "$task_id")
    if [[ $? -ne 0 ]]; then
        log_error "Cannot transition unknown task: $task_id"
        return 1
    fi
    
    # Check if transition is valid
    local valid_next_states="${VALID_TRANSITIONS[$current_state]}"
    if [[ "$valid_next_states" != *"$new_state"* ]]; then
        log_error "Invalid state transition: $current_state -> $new_state for task $task_id"
        return 1
    fi
    
    # Perform transition
    TASK_STATES["$task_id"]="$new_state"
    TASK_TIMESTAMPS["${task_id}_${new_state}"]=$(date -Iseconds)
    
    log_info "Task $task_id transitioned: $current_state -> $new_state"
    
    # Save updated state
    save_task_state "$task_id"
}
```

## Ressourcen & Referenzen

- **GitHub Issue #40**: Spezifikation und Acceptance Criteria
- **Übergeordneter Scratchpad**: `scratchpads/active/2025-08-24_task-queue-system-implementation.md` für System-Architektur
- **Bestehende Codebase-Patterns**: `src/session-manager.sh` für State-Management-Patterns
- **JSON-Processing**: jq Dokumentation für robuste JSON-Operationen
- **File-Locking**: flock Manual für Concurrent-Access-Prevention
- **Bash Best Practices**: Advanced Bash Scripting Guide für Error-Handling

## Konfigurationserweiterungen

### Neue Config-Parameter (config/default.conf)

```bash
# ===============================================================================
# TASK QUEUE CONFIGURATION
# ===============================================================================

# Task Queue System aktivieren
TASK_QUEUE_ENABLED=false

# Queue-Verzeichnis (relativ zum Projekt-Root)
TASK_QUEUE_DIR="queue"

# Standard-Timeout für Tasks in Sekunden (1 Stunde)
TASK_DEFAULT_TIMEOUT=3600

# Maximale Retry-Versuche pro Task
TASK_MAX_RETRIES=3

# Delay zwischen Retry-Versuchen in Sekunden
TASK_RETRY_DELAY=300

# Task-Completion-Detection-Pattern
TASK_COMPLETION_PATTERN="###TASK_COMPLETE###"

# Maximale Queue-Größe (0 = unbegrenzt)
TASK_QUEUE_MAX_SIZE=0

# Auto-Cleanup für alte completed/failed Tasks (in Tagen)
TASK_AUTO_CLEANUP_DAYS=7

# Backup-Aufbewahrungszeit in Tagen
TASK_BACKUP_RETENTION_DAYS=30

# JSON-File-Locking-Timeout in Sekunden
QUEUE_LOCK_TIMEOUT=30
```

## Abschluss-Checkliste

- [ ] **Kern-Funktionalität implementiert**
  - Alle Queue-Management-Functions vollständig
  - JSON-Persistenz mit atomaren Operationen
  - Task-Status-Tracking mit Historien
  - Priority-Management funktional

- [ ] **Datenintegrität sichergestellt**
  - File-Locking für Concurrent-Access
  - Atomic-Write-Operations für JSON-Files
  - Backup- und Recovery-Mechanismen
  - Input-Validation und Error-Handling

- [ ] **Tests geschrieben und bestanden**
  - Unit-Tests für alle Core-Functions
  - Integration-Tests für File-Operations
  - Error-Recovery-Scenario-Tests
  - Performance-Tests mit Large-Queues

- [ ] **Integration vorbereitet**
  - Konsistente Logging mit bestehendem System
  - Config-Integration in default.conf
  - API-Dokumentation für nachfolgende Module
  - Example-Usage und Best-Practices

- [ ] **Code-Review durchgeführt**
  - ShellCheck-konformer Code
  - Konsistente Naming-Conventions
  - Comprehensive Error-Handling
  - Performance-Optimization

---
**Status**: Aktiv  
**Zuletzt aktualisiert**: 2025-08-24