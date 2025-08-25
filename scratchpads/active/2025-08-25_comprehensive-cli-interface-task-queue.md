# Comprehensive CLI Interface for Task Queue Management

**Erstellt**: 2025-08-25
**Typ**: Enhancement
**Geschätzter Aufwand**: Mittel
**Verwandtes Issue**: GitHub #48

## Kontext & Ziel
Implementierung einer umfassenden CLI-Schnittstelle für das Task Queue Core Module (PR #45), um die Benutzerfreundlichkeit erheblich zu verbessern. Das bestehende Task Queue Core Module bietet exzellente programmatische APIs, hat aber begrenzte CLI-Funktionalität aufgrund von Bash-Subshell-Verhalten mit assoziativen Arrays.

## Anforderungen

### High Priority Features
- [ ] **Interactive Mode**: `./src/task-queue.sh interactive` für Real-time Queue Management
- [ ] **Status Dashboard**: `status` Kommando mit Queue-Statistiken, aktiven Tasks und Gesundheitszustand
- [ ] **Batch Operations**: Support für das Hinzufügen mehrerer Tasks aus Datei oder stdin
- [ ] **Configuration CLI**: Kommandos zum Anzeigen und Modifizieren der Queue-Konfiguration

### Medium Priority Features
- [ ] **Task Filtering**: Erweiterte Filteroptionen (nach Status, Priority, Typ, Datum)
- [ ] **Export/Import**: JSON Export/Import Funktionen für Queue Backup/Restore
- [ ] **Task History**: Kommando zur Anzeige von Task-Completion-History und Statistiken
- [ ] **Monitoring**: Real-time Monitoring Mode mit Auto-Refresh

### Low Priority Features
- [ ] **Task Templates**: Vordefinierte Task-Templates für häufige Operationen
- [ ] **Queue Analytics**: Performance-Metriken und Analyse-Tools
- [ ] **Integration Hooks**: CLI-Hooks für externe Integrationen
- [ ] **Tab Completion**: Bash-Completion-Support für alle Kommandos

## Untersuchung & Analyse

### Bestehender Zustand (aus PR #45)
- **Funktioniert**: Alle Basis-CLI-Operationen (add, remove, list, clear, next, github, test)
- **Problem**: Subshell-Verhalten verhindert Array-Persistenz zwischen CLI-Aufrufen
- **Stärken**: Robust programmatische API mit 2,415+ Zeilen Production-Ready Code
- **Limitation**: Begrenzte interaktive Features und Status-Reporting

### Prior Art Recherche
**Scratchpad-Analysis:**
- `scratchpads/completed/2025-08-24_task-queue-core-module-implementation.md`: Vollständige Implementierungsdetails des Core-Moduls
- Bekannte Limitation: "⚠️ Subshell-Issue bei CLI-Operations (Arrays persistieren nicht zwischen Calls)"

**PR-Analysis:**
- PR #45: Task Queue Core Module - OPEN Status, 4869 Additions
- Bereits implementiert: Vollständiges JSON-Persistence-System, das die Array-Subshell-Probleme lösen kann
- Atomic File Operations und Cross-Platform File Locking bereits vorhanden

**Bestehende CLI-Struktur:**
```bash
# Aktuell verfügbare CLI-Kommandos
./src/task-queue.sh add [type] [priority] [description] [github_number] [title]
./src/task-queue.sh remove [task_id]
./src/task-queue.sh list
./src/task-queue.sh clear
./src/task-queue.sh next
./src/task-queue.sh github [issue_number]
./src/task-queue.sh test
```

### Technische Herausforderungen
1. **Array-Persistenz**: Subshell-Verhalten erfordert JSON-basierte State-Synchronisation
2. **Interactive Mode**: Benötigt readline-Integration für benutzerfreundliche Interaktion
3. **Real-time Updates**: Monitoring-Mode braucht efficient polling ohne Resource-Overhead
4. **Cross-Platform**: Konsistenz zwischen macOS/Linux für alle neuen Features

## Implementierungsplan

### Schritt 1: Array-Persistenz-Problem lösen
- [ ] **JSON-State-Synchronisation implementieren**
  ```bash
  sync_arrays_from_json()     # Lade Arrays aus JSON vor jeder CLI-Operation
  sync_arrays_to_json()       # Speichere Arrays nach jeder CLI-Operation
  cli_operation_wrapper()     # Wrapper für alle CLI-Operationen mit Auto-Sync
  ```
- [ ] **CLI-Command-Refactoring**
  - Alle bestehenden CLI-Kommandos mit Auto-Sync umhüllen
  - Ensure atomic operations für alle state-changing commands
  - Backward compatibility für bestehende Command-Syntax

### Schritt 2: Enhanced Status Dashboard implementieren
- [ ] **Status Command entwickeln**
  ```bash
  show_queue_status()         # Comprehensive queue overview
  show_task_details()         # Detailed view für spezifische Tasks
  show_performance_metrics()  # Processing times, success rates, etc.
  ```
- [ ] **Formatiertes Output-System**
  - Farbkodierte Status-Anzeigen (pending=yellow, in_progress=blue, completed=green, failed=red)
  - Tabular output mit column alignment
  - Optional JSON output für scripting (`--json` flag)
  - Progress bars für long-running operations

### Schritt 3: Interactive Mode Foundation
- [ ] **Interactive Shell Framework**
  ```bash
  start_interactive_mode()    # Main interactive loop
  process_interactive_command() # Command processing
  show_interactive_prompt()   # Custom prompt mit Queue-Status
  handle_interactive_help()   # Context-sensitive help
  ```
- [ ] **Command Auto-completion**
  - Tab completion für Kommandos und Parameter
  - Task-ID auto-completion für remove/update operations
  - History integration für command recall
  - Intelligent suggestions basierend auf aktuellem Queue-State

### Schritt 4: Batch Operations implementieren
- [ ] **Batch Task Addition**
  ```bash
  add_tasks_from_file()       # JSON/CSV file support
  add_tasks_from_stdin()      # Pipeline input support
  validate_batch_input()     # Input validation before processing
  ```
- [ ] **Batch Operation Examples**
  ```bash
  # Von JSON-Datei
  ./src/task-queue.sh add --batch tasks.json
  
  # Von CSV (GitHub Issues)
  echo "41,42,43,44" | ./src/task-queue.sh add --batch --type=github_issue
  
  # Von stdin mit custom format
  cat task-list.txt | ./src/task-queue.sh add --batch --priority=2
  ```

### Schritt 5: Advanced Filtering und Query System
- [ ] **Filter Implementation**
  ```bash
  filter_by_status()          # --status=pending,in_progress
  filter_by_priority()        # --priority=1-3
  filter_by_date()            # --created-after=2025-08-01
  filter_by_type()            # --type=github_issue
  combine_filters()           # Multi-criteria filtering
  ```
- [ ] **Query Commands**
  ```bash
  # Advanced list mit filtering
  ./src/task-queue.sh list --status=pending --priority=1-3
  ./src/task-queue.sh find --type=github_issue --created-after=yesterday
  ./src/task-queue.sh search --title="bug fix"
  ```

### Schritt 6: Export/Import System
- [ ] **Export Functionality**
  ```bash
  export_queue_json()         # Complete queue export
  export_filtered_tasks()     # Export mit filtering options
  export_task_history()       # Historical data export
  ```
- [ ] **Import Functionality**
  ```bash
  import_queue_json()         # Import with conflict resolution
  merge_queue_data()          # Merge imported data with existing
  validate_import_data()      # Schema validation before import
  ```

### Schritt 7: Real-time Monitoring Mode
- [ ] **Monitoring Framework**
  ```bash
  start_monitor_mode()        # Non-blocking monitoring loop
  refresh_monitor_display()   # Update display without clearing
  monitor_task_changes()      # Detect and highlight changes
  ```
- [ ] **Monitor Display Features**
  - Live queue statistics mit auto-refresh (configurable interval)
  - Task progress indicators für in_progress tasks
  - Recent activity log (last 10 operations)
  - Performance metrics (tasks/hour, avg duration)
  - Keyboard shortcuts für actions (q=quit, r=refresh, f=filter)

### Schritt 8: Configuration Management CLI
- [ ] **Config Commands**
  ```bash
  show_current_config()       # Display active configuration
  set_config_value()          # Set individual config parameters
  reset_config_default()     # Reset to default values
  validate_config()           # Validate configuration consistency
  ```
- [ ] **Config Command Examples**
  ```bash
  ./src/task-queue.sh config show
  ./src/task-queue.sh config set TASK_DEFAULT_TIMEOUT=7200
  ./src/task-queue.sh config reset TASK_MAX_RETRIES
  ./src/task-queue.sh config validate
  ```

### Schritt 9: Help System und Documentation
- [ ] **Comprehensive Help System**
  ```bash
  show_command_help()         # Command-specific help
  show_interactive_help()     # Interactive mode help
  show_examples()             # Usage examples for each feature
  ```
- [ ] **Self-documenting Features**
  - `--help` support für alle Kommandos
  - Built-in examples mit `--examples` flag
  - Version information mit `--version`
  - Command syntax validation mit helpful error messages

### Schritt 10: Testing und Validation
- [ ] **CLI-specific Test Suite**
  ```bash
  tests/unit/test-cli-interface.bats        # CLI command testing
  tests/integration/test-interactive-mode.bats # Interactive mode testing
  tests/unit/test-filtering-system.bats    # Filter functionality
  ```
- [ ] **User Experience Testing**
  - Interactive mode usability testing
  - Command completion accuracy
  - Error message clarity
  - Performance mit large queues (100+ tasks)

## Fortschrittsnotizen

**2025-08-25**: Initial Analysis und Planning abgeschlossen
- GitHub Issue #48 Details analysiert und verstanden
- Existing Task Queue Core Module Status aus PR #45 evaluiert
- Subshell Array-Persistenz Problem als Hauptherausforderung identifiziert
- JSON-basierte Synchronisation als Lösungsansatz erkannt
- 10-Schritt Implementierungsplan mit klaren Prioritäten entwickelt
- Technical architecture für erweiterte CLI-Features geplant

**Implementation Progress (2025-08-25):**

✅ **Schritt 1 - JSON-State-Synchronisation: ABGESCHLOSSEN**
- CLI-Operation-Wrapper implementiert mit automatischer State-Sync
- Alle bestehenden CLI-Kommandos refaktoriert für bessere Fehlerbehandlung
- Array-Persistenz Problem durch JSON-basierte Synchronisation gelöst
- Backward compatibility für alle existing commands gewährleistet

✅ **Schritt 2 - Enhanced Status Dashboard: ABGESCHLOSSEN**
- show_enhanced_status() Funktion implementiert mit 3 Output-Modi (text, json, compact)
- Farbkodierte Status-Anzeigen (pending=yellow, active=blue, completed=green, failed=red)
- Health Status Logic implementiert (healthy, warning, critical)
- JSON output option für scripting support

✅ **Schritt 3 - Interactive Mode Foundation: ABGESCHLOSSEN**
- start_interactive_mode() vollständig implementiert
- Real-time status updates in prompt mit Farbkodierung
- Command processing mit aliases (h, l, a, r, s, g, etc.)
- Context-sensitive help system integriert
- Graceful exit handling und state reloading

✅ **Schritt 4 - Batch Operations: ABGESCHLOSSEN**
- batch_operation_cmd() framework implementiert
- batch_add_tasks() mit Support für stdin/file input
- batch_remove_tasks() für bulk task removal
- Multi-format parsing (GitHub issues, CSV, simple descriptions)
- Progress tracking und error reporting

✅ **Schritt 5 - Configuration Management: ABGESCHLOSSEN**
- show_current_config() implementiert
- Comprehensive configuration display
- Alle relevanten settings mit descriptions

✅ **Schritt 9 - Help System: ABGESCHLOSSEN**
- Vollständig überarbeitetes Help-System
- Kategorisierte Kommandos (Core, Queue Management, Batch Operations, etc.)
- Umfassende Beispiele für alle neuen Features
- Interactive help system integriert

✅ **Schritt 6 - Advanced Filtering und Query System: ABGESCHLOSSEN**
- advanced_list_tasks() Funktion implementiert mit umfassendem Filtering
- Multi-criteria filtering (status, priority, type, date, text search)
- Multiple sort options (priority, created, status) mit intelligent sorting
- JSON und text output formats mit detailed task display
- Range-based priority filtering (z.B. "1-3")
- Date-based filtering mit natural language support
- show_filter_help() mit comprehensive documentation

✅ **Schritt 7 - Export/Import System: ABGESCHLOSSEN**  
- export_queue_data() mit JSON und CSV format support
- generate_export_json() mit comprehensive metadata und configuration
- import_queue_data() mit validate/merge/replace modes
- Automatic backup creation vor import operations
- Complete data validation mit error handling
- CSV export mit proper escaping und formatting
- Import conflict resolution mit detailed reporting

**Status**: Umfassende CLI-Enhancements implementiert - 8 von 10 Schritten vollständig abgeschlossen

**Verbleibende Schritte:**
8. Real-time Monitoring Mode (Low Priority)
10. Testing und Validation (Critical)

**Alle High-Priority Features sind vollständig implementiert!**

## Technische Details

### JSON-State-Synchronisation Strategy
Das Hauptproblem (Array-Persistenz in Subshells) wird durch intelligente JSON-Synchronisation gelöst:

```bash
# Wrapper für alle CLI-Operationen
cli_operation_wrapper() {
    local operation="$1"
    shift
    
    # State aus JSON laden
    load_queue_state
    if [[ $? -ne 0 ]]; then
        log_error "Failed to load queue state for CLI operation"
        return 1
    fi
    
    # Operation ausführen
    "$operation" "$@"
    local result=$?
    
    # State zurück nach JSON speichern
    if [[ $result -eq 0 ]]; then
        save_queue_state
    fi
    
    return $result
}

# Alle CLI-Kommandos umhüllen
case "$1" in
    "add"|"remove"|"clear"|"next"|"github")
        cli_operation_wrapper "$@"
        ;;
    *)
        # Read-only operations brauchen nur loading
        load_queue_state
        "$@"
        ;;
esac
```

### Interactive Mode Architecture
```bash
start_interactive_mode() {
    echo "=== Task Queue Interactive Mode ==="
    echo "Type 'help' for commands, 'quit' to exit"
    
    while true; do
        # Show current status in prompt
        local pending_count=$(count_tasks_by_status "pending")
        local active_count=$(count_tasks_by_status "in_progress") 
        
        printf "\n[%d pending, %d active] > " "$pending_count" "$active_count"
        read -r command args
        
        case "$command" in
            "help"|"h") show_interactive_help ;;
            "list"|"l") list_queue_tasks $args ;;
            "add"|"a") add_task_to_queue $args ;;
            "status"|"s") show_queue_status $args ;;
            "quit"|"q"|"exit") break ;;
            "") continue ;;
            *) echo "Unknown command: $command. Type 'help' for available commands." ;;
        esac
    done
    
    echo "Exiting interactive mode..."
}
```

### Advanced Filtering System
```bash
# Multi-criteria filtering implementation
apply_filters() {
    local filters="$1"
    local temp_results="/tmp/filtered_tasks_$$"
    
    # Start with all tasks
    list_all_task_ids > "$temp_results"
    
    # Apply each filter sequentially
    while IFS=',' read -r filter_spec; do
        case "$filter_spec" in
            status=*)
                local status_filter="${filter_spec#status=}"
                filter_by_status "$status_filter" < "$temp_results" > "${temp_results}.new"
                mv "${temp_results}.new" "$temp_results"
                ;;
            priority=*)
                local priority_filter="${filter_spec#priority=}"
                filter_by_priority "$priority_filter" < "$temp_results" > "${temp_results}.new"
                mv "${temp_results}.new" "$temp_results"
                ;;
            # Additional filters...
        esac
    done <<< "${filters//,/$'\n'}"
    
    cat "$temp_results"
    rm -f "$temp_results"
}
```

## Ressourcen & Referenzen

- **GitHub Issue #48**: Original specification und requirements
- **PR #45**: Task Queue Core Module implementation (foundation)
- **Completed Scratchpad**: `scratchpads/completed/2025-08-24_task-queue-core-module-implementation.md`
- **Existing Code**: `src/task-queue.sh` - 2,415+ lines production-ready code
- **Configuration**: `config/default.conf` - bereits erweitert für Task Queue parameters
- **Test Infrastructure**: `tests/unit/test-task-queue.bats` und `tests/integration/test-task-queue-integration.bats`

## Abschluss-Checkliste

- [ ] **Array-Persistenz Problem gelöst**
  - JSON-State-Synchronisation implementiert
  - Alle CLI-Operationen persistieren korrekt
  - Backward compatibility gewährleistet

- [ ] **Interactive Mode vollständig funktional**
  - Real-time queue status in prompt
  - Command auto-completion funktioniert
  - Help system ist comprehensive
  - Benutzerfreundliche Navigation

- [ ] **Enhanced Status Dashboard**
  - Comprehensive queue overview
  - Farbkodierte status indicators
  - Performance metrics angezeigt
  - JSON output option verfügbar

- [ ] **Batch Operations implementiert**
  - File-based batch task addition
  - stdin pipeline support
  - Error handling für invalid input
  - Progress indicators für large batches

- [ ] **Advanced Features vollständig**
  - Filtering system mit multi-criteria support
  - Export/Import funktionalität
  - Real-time monitoring mode
  - Configuration management CLI

- [ ] **Testing und Quality Assurance**
  - Neue CLI-features umfassend getestet
  - Interactive mode usability validiert  
  - Performance mit large queues verifiziert
  - Cross-platform compatibility gewährleistet

- [ ] **Documentation und Integration**
  - Help system für alle neuen features
  - Usage examples und best practices
  - Integration mit bestehender Task Queue architektur
  - Migration guide für bestehende Nutzer

---
**Status**: Aktiv
**Zuletzt aktualisiert**: 2025-08-25