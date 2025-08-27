# Phase 4: Error Handling and Recovery Systems Implementation

**Erstellt**: 2025-08-27
**Typ**: Feature - Core Error Handling
**Geschätzter Aufwand**: Groß
**Verwandtes Issue**: GitHub #43

## Kontext & Ziel
Implementierung der kritischen Fehlerbehandlungs- und Recovery-Systeme für das Task Queue System im Claude Auto-Resume Projekt. Das Ziel ist es, robuste Mechanismen für Timeout-Detection, Session-Recovery, und Backup-Strategien zu schaffen, die das System automatisch von verschiedenen Ausfallszenarien erholen können.

**Kern-Problem**: Das aktuelle System hat grundlegende Task-Verarbeitung, aber keine umfassenden Mechanismen für:
- Timeout-Detection bei langen oder hängenden Tasks
- Automatische Session-Recovery bei Claude CLI Ausfällen
- Backup-Systeme für Task-State-Preservation
- Intelligente Usage-Limit-Recovery für Queue-Processing

**Fokus auf Kernfunktionalität**: Diese Implementierung konzentriert sich auf die essentiellen Fehlerbehandlungskomponenten und verzichtet zunächst auf komplexe Features wie GitHub Comment Backups.

## Anforderungen
- [ ] **Timeout Detection System**: Konfigurierbare Task-Timeouts mit progressiver Eskalation
- [ ] **Core Session Recovery**: Session-Health-Monitoring und automatische Recovery
- [ ] **Basic Backup Strategy**: Task-State-Preservation mit lokalen Backups
- [ ] **Usage Limit Integration**: Queue-bewusste Usage-Limit-Behandlung
- [ ] **Error Classification Engine**: Intelligente Fehlerklassifizierung und -behandlung
- [ ] **Retry Logic**: Exponential backoff und configurable retry strategies
- [ ] **Emergency Protocols**: Safe-mode und emergency shutdown mechanisms
- [ ] **State Persistence**: Robuste Task-State-Erhaltung während Recovery-Szenarien

## Untersuchung & Analyse

### Existing Error Handling Analysis
**✅ Vorhandene Komponenten**:
- Task Queue System mit grundlegenden Task States (pending/in_progress/completed/failed/timeout)
- Logging System mit strukturierten Log-Levels
- File Locking für atomic operations
- Session Manager mit basic health checks
- Configuration system für Timeout-Parameter

**❌ Fehlende Robuste Mechanismen**:
- Keine automatische Timeout-Detection während Task-Execution
- Keine Session-Recovery bei Claude CLI crashes
- Keine Backup-Systeme für Task-Progress-Preservation
- Keine intelligente Usage-Limit-Integration mit Queue-Processing
- Keine Error-Classification für unterschiedliche Recovery-Strategien

### Prior Art aus dem System
- `src/task-queue.sh`: Grundlegende Task-State-Management (1600+ lines) mit TASK_STATE_TIMEOUT
- `src/session-manager.sh`: Session lifecycle management mit basic error handling
- `scratchpads/completed/2025-08-25_enhance-file-locking-robustness.md`: Robuste File-Operations
- Current Config System: TASK_DEFAULT_TIMEOUT, TASK_MAX_RETRIES bereits definiert

### Technical Architecture Analysis
**Current Error Flow**:
```bash
Task Execution → Basic Logging → Simple State Update
```

**Target Robust Error Flow**:
```bash
Task Execution → Timeout Monitor → Error Classification → Recovery Strategy
                      ↓                    ↓                    ↓
              Emergency Termination → Backup Creation → Session Recovery
                      ↓                    ↓                    ↓
              State Preservation → Retry Logic → Progress Restoration
```

## Implementierungsplan

### Phase 1: Core Timeout Detection System
**Ziel**: Implementierung einer robusten Timeout-Detection für Task-Execution
**Dateien**: `src/task-timeout-monitor.sh` (new), `src/hybrid-monitor.sh` (extend)

#### Schritt 1: Timeout Monitor Module
**Neue Datei**: `src/task-timeout-monitor.sh`
```bash
# Timeout Management Functions
start_task_timeout_monitor() {
    local task_id="$1"
    local timeout_seconds="$2"
    local task_pid="$3"
    
    # Create timeout tracking file
    local timeout_file="$TASK_QUEUE_DIR/timeouts/${task_id}.timeout"
    echo "{
        \"task_id\": \"$task_id\",
        \"start_time\": $(date +%s),
        \"timeout_seconds\": $timeout_seconds,
        \"task_pid\": \"$task_pid\",
        \"warnings_sent\": 0
    }" > "$timeout_file"
    
    # Start timeout monitor in background
    (monitor_task_timeout "$task_id" "$timeout_seconds" &)
    echo $! > "${timeout_file}.monitor_pid"
}

monitor_task_timeout() {
    local task_id="$1"
    local timeout_seconds="$2"
    local warning_threshold=$((timeout_seconds - 300))  # 5 min warning
    
    local start_time=$(date +%s)
    local warning_sent=false
    
    while true; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        # Check if task is still active
        if ! is_task_active "$task_id"; then
            cleanup_timeout_monitor "$task_id"
            return 0
        fi
        
        # Send warning before timeout
        if [[ $elapsed -ge $warning_threshold ]] && [[ "$warning_sent" == "false" ]]; then
            send_timeout_warning "$task_id" "$elapsed" "$timeout_seconds"
            warning_sent=true
        fi
        
        # Handle timeout
        if [[ $elapsed -ge $timeout_seconds ]]; then
            handle_task_timeout "$task_id" "$elapsed"
            return 1
        fi
        
        sleep 30  # Check every 30 seconds
    done
}

handle_task_timeout() {
    local task_id="$1"
    local elapsed_time="$2"
    
    log_warn "TIMEOUT: Task $task_id timed out after ${elapsed_time}s"
    
    # Create timeout backup before termination
    create_timeout_backup "$task_id"
    
    # Update task status
    update_task_status "$task_id" "$TASK_STATE_TIMEOUT"
    
    # Terminate task if possible
    terminate_task_safely "$task_id"
    
    # Trigger timeout recovery workflow
    trigger_timeout_recovery "$task_id"
}
```

#### Schritt 2: Integration in Task Execution
**Extend**: `src/hybrid-monitor.sh` - Task execution loop
```bash
execute_single_task() {
    local task_id="$1"
    local task_command="$2"
    local timeout="${3:-$TASK_DEFAULT_TIMEOUT}"
    
    log_info "Starting task $task_id with ${timeout}s timeout"
    
    # Start timeout monitoring
    start_task_timeout_monitor "$task_id" "$timeout" "$$"
    
    # Execute task with robust error handling
    if execute_task_with_recovery "$task_id" "$task_command"; then
        stop_timeout_monitor "$task_id"
        return 0
    else
        # Timeout monitor will handle timeout case
        return 1
    fi
}
```

### Phase 2: Session Recovery Mechanisms
**Ziel**: Robuste Session-Health-Monitoring und automatische Recovery
**Dateien**: `src/session-recovery.sh` (new), `src/session-manager.sh` (extend)

#### Schritt 1: Session Health Monitor
**Neue Datei**: `src/session-recovery.sh`
```bash
# Session Recovery Core Functions
monitor_session_health_during_task() {
    local session_id="$1"
    local task_id="$2"
    
    # Continuous session health checking
    while is_task_active "$task_id"; do
        if ! verify_session_responsiveness "$session_id"; then
            log_warn "Session $session_id unresponsive during task $task_id"
            
            # Create session failure backup
            create_session_failure_backup "$task_id" "$session_id"
            
            # Attempt session recovery
            if recover_session_with_task_context "$session_id" "$task_id"; then
                log_info "Session recovery successful for task $task_id"
            else
                log_error "Session recovery failed for task $task_id"
                handle_session_recovery_failure "$task_id" "$session_id"
                return 1
            fi
        fi
        sleep 60  # Check every minute during task execution
    done
}

recover_session_with_task_context() {
    local session_id="$1"
    local task_id="$2"
    
    log_info "Attempting session recovery for $session_id (task: $task_id)"
    
    # Preserve task state before recovery
    preserve_task_state_during_recovery "$task_id"
    
    # Attempt graceful session restart
    if restart_claude_session "$session_id"; then
        # Restore task context in new session
        restore_task_context_after_recovery "$task_id"
        
        # Validate session is ready
        if validate_session_after_recovery "$session_id"; then
            log_info "Session recovery completed successfully"
            return 0
        fi
    fi
    
    # Fallback to emergency session creation
    log_warn "Graceful recovery failed, attempting emergency session creation"
    if create_emergency_session_for_task "$task_id"; then
        return 0
    fi
    
    return 1
}

verify_session_responsiveness() {
    local session_id="$1"
    local test_command="echo 'health_check_$(date +%s)'"
    
    # Send test command and monitor for response
    if send_command_to_session "$test_command"; then
        # Wait for response with timeout
        local response_timeout=30
        local start_time=$(date +%s)
        
        while [[ $(($(date +%s) - start_time)) -lt $response_timeout ]]; do
            if session_has_recent_output "$session_id"; then
                return 0  # Session responsive
            fi
            sleep 2
        done
    fi
    
    return 1  # Session unresponsive
}
```

### Phase 3: Basic Backup and State Preservation
**Ziel**: Einfache aber robuste Backup-Strategien für Task-State
**Dateien**: `src/task-state-backup.sh` (new)

#### Schritt 1: Local Backup System
**Neue Datei**: `src/task-state-backup.sh`
```bash
# Task State Backup Core Functions
create_task_checkpoint() {
    local task_id="$1"
    local checkpoint_reason="${2:-periodic}"
    
    local backup_dir="$TASK_QUEUE_DIR/backups"
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_file="$backup_dir/checkpoint-${task_id}-${timestamp}.json"
    
    # Gather comprehensive task state
    local task_data
    task_data=$(get_comprehensive_task_state "$task_id")
    
    # Create backup with metadata
    echo "{
        \"task_id\": \"$task_id\",
        \"checkpoint_time\": \"$(date -Iseconds)\",
        \"checkpoint_reason\": \"$checkpoint_reason\",
        \"system_state\": {
            \"session_id\": \"${MAIN_SESSION_ID:-}\",
            \"queue_status\": \"$(get_queue_status)\",
            \"current_cycle\": \"${CURRENT_CYCLE:-0}\"
        },
        \"task_state\": $task_data
    }" > "$backup_file"
    
    log_debug "Task checkpoint created: $backup_file"
    
    # Cleanup old checkpoints
    cleanup_old_checkpoints "$task_id"
}

restore_from_checkpoint() {
    local task_id="$1"
    local backup_file="${2:-$(find_latest_checkpoint "$task_id")}"
    
    if [[ ! -f "$backup_file" ]]; then
        log_error "No checkpoint found for task $task_id"
        return 1
    fi
    
    log_info "Restoring task $task_id from checkpoint: $backup_file"
    
    # Extract and restore task state
    local task_state
    task_state=$(jq -r '.task_state' "$backup_file")
    
    if restore_task_state "$task_id" "$task_state"; then
        log_info "Task $task_id restored from checkpoint"
        return 0
    else
        log_error "Failed to restore task $task_id from checkpoint"
        return 1
    fi
}

create_emergency_system_backup() {
    local reason="${1:-manual}"
    local backup_dir="$TASK_QUEUE_DIR/backups"
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local emergency_backup="$backup_dir/emergency-system-${timestamp}.json"
    
    log_warn "Creating emergency system backup: $reason"
    
    # Comprehensive system state backup
    echo "{
        \"backup_time\": \"$(date -Iseconds)\",
        \"backup_reason\": \"$reason\",
        \"system_info\": {
            \"hostname\": \"$(hostname)\",
            \"pid\": $$,
            \"session_id\": \"${MAIN_SESSION_ID:-}\",
            \"current_cycle\": \"${CURRENT_CYCLE:-0}\"
        },
        \"queue_state\": $(get_complete_queue_state),
        \"active_tasks\": $(get_all_active_tasks),
        \"configuration\": $(export_current_configuration)
    }" > "$emergency_backup"
    
    log_info "Emergency backup created: $emergency_backup"
    echo "$emergency_backup"
}
```

### Phase 4: Usage Limit Recovery Enhancement
**Ziel**: Queue-bewusste Usage-Limit-Behandlung mit automatischem Resume
**Dateien**: `src/usage-limit-recovery.sh` (new)

#### Schritt 1: Enhanced Usage Limit Detection
```bash
# Enhanced Usage Limit Recovery for Queue Processing
detect_usage_limit_in_queue() {
    local session_output="$1"
    local task_id="${2:-}"
    
    # Enhanced usage limit patterns
    local limit_patterns=(
        "usage limit"
        "rate limit"
        "too many requests"
        "please try again later"
    )
    
    for pattern in "${limit_patterns[@]}"; do
        if echo "$session_output" | grep -qi "$pattern"; then
            log_warn "Usage limit detected during queue processing"
            
            # Create usage limit checkpoint if task is active
            if [[ -n "$task_id" ]]; then
                create_task_checkpoint "$task_id" "usage_limit"
            fi
            
            return 0  # Usage limit detected
        fi
    done
    
    return 1  # No usage limit detected
}

pause_queue_for_usage_limit() {
    local estimated_wait_time="${1:-1800}"  # 30 min default
    local current_task_id="$2"
    
    log_warn "Pausing queue for usage limit (estimated wait: ${estimated_wait_time}s)"
    
    # Pause queue with preservation of current state
    pause_task_queue "usage_limit"
    
    # Create comprehensive system backup before waiting
    create_emergency_system_backup "usage_limit_pause"
    
    # Calculate resume time
    local resume_time=$(($(date +%s) + estimated_wait_time))
    local resume_timestamp=$(date -d "@$resume_time" "+%Y-%m-%d %H:%M:%S")
    
    log_info "Queue will automatically resume at: $resume_timestamp"
    
    # Create usage limit recovery marker
    echo "{
        \"pause_time\": $(date +%s),
        \"estimated_resume_time\": $resume_time,
        \"current_task_id\": \"$current_task_id\",
        \"pause_reason\": \"usage_limit\"
    }" > "$TASK_QUEUE_DIR/usage-limit-pause.marker"
    
    return 0
}

resume_queue_after_limit() {
    local recovery_file="$TASK_QUEUE_DIR/usage-limit-pause.marker"
    
    if [[ ! -f "$recovery_file" ]]; then
        log_warn "No usage limit recovery marker found"
        return 1
    fi
    
    log_info "Resuming queue after usage limit"
    
    # Resume queue processing
    resume_task_queue "usage_limit_recovery"
    
    # Clean up recovery marker
    rm -f "$recovery_file"
    
    log_info "Queue successfully resumed after usage limit"
    return 0
}
```

### Phase 5: Error Classification and Recovery Strategy Engine
**Ziel**: Intelligente Fehlerklassifizierung für angemessene Recovery-Strategien
**Dateien**: `src/error-classification.sh` (new)

#### Schritt 1: Error Classification System
```bash
# Error Classification and Recovery Strategy Engine
classify_error_severity() {
    local error_message="$1"
    local error_context="${2:-general}"
    local task_id="${3:-}"
    
    # Critical errors requiring immediate intervention
    local critical_patterns=(
        "segmentation fault"
        "out of memory"
        "disk full"
        "permission denied"
        "authentication failed"
    )
    
    # Warning level errors that can be retried
    local warning_patterns=(
        "network timeout"
        "connection refused"
        "temporary failure"
        "usage limit"
        "rate limit"
    )
    
    # Info level errors that are recoverable
    local info_patterns=(
        "command not found"
        "file not found"
        "syntax error"
    )
    
    # Check error severity
    for pattern in "${critical_patterns[@]}"; do
        if echo "$error_message" | grep -qi "$pattern"; then
            log_error "CRITICAL error detected: $pattern"
            return 3  # Critical
        fi
    done
    
    for pattern in "${warning_patterns[@]}"; do
        if echo "$error_message" | grep -qi "$pattern"; then
            log_warn "WARNING level error detected: $pattern"
            return 2  # Warning
        fi
    done
    
    for pattern in "${info_patterns[@]}"; do
        if echo "$error_message" | grep -qi "$pattern"; then
            log_info "INFO level error detected: $pattern"
            return 1  # Info
        fi
    done
    
    return 0  # Unknown error
}

determine_recovery_strategy() {
    local error_severity="$1"
    local task_id="$2"
    local retry_count="${3:-0}"
    
    case "$error_severity" in
        3)  # Critical
            log_error "Critical error - initiating emergency protocols"
            echo "emergency_shutdown"
            ;;
        2)  # Warning
            if [[ $retry_count -lt $TASK_MAX_RETRIES ]]; then
                log_warn "Warning level error - attempting automatic recovery"
                echo "automatic_recovery"
            else
                log_warn "Max retries exceeded - escalating to manual recovery"
                echo "manual_recovery"
            fi
            ;;
        1)  # Info
            log_info "Info level error - attempting simple retry"
            echo "simple_retry"
            ;;
        *)  # Unknown
            log_warn "Unknown error type - using safe recovery strategy"
            echo "safe_recovery"
            ;;
    esac
}

execute_recovery_strategy() {
    local strategy="$1"
    local task_id="$2"
    local error_context="$3"
    
    case "$strategy" in
        "emergency_shutdown")
            emergency_queue_shutdown "$error_context"
            ;;
        "automatic_recovery")
            attempt_automatic_recovery "$task_id" "$error_context"
            ;;
        "manual_recovery")
            escalate_to_manual_recovery "$task_id" "$error_context"
            ;;
        "simple_retry")
            schedule_simple_retry "$task_id"
            ;;
        "safe_recovery")
            fallback_to_safe_mode "$task_id" "$error_context"
            ;;
        *)
            log_error "Unknown recovery strategy: $strategy"
            fallback_to_safe_mode "$task_id" "$error_context"
            ;;
    esac
}
```

### Phase 6: Integration und Configuration
**Ziel**: Integration aller Error Handling Komponenten in das bestehende System
**Dateien**: `config/default.conf` (extend), `src/hybrid-monitor.sh` (integrate)

#### Schritt 1: Configuration Extensions
**Extend**: `config/default.conf`
```bash
# Error Handling and Recovery Configuration
ERROR_HANDLING_ENABLED=true
ERROR_AUTO_RECOVERY=true
ERROR_MAX_RETRIES=3
ERROR_RETRY_DELAY=300                    # 5 minutes
ERROR_ESCALATION_THRESHOLD=5

# Timeout Configuration
TIMEOUT_DETECTION_ENABLED=true
TIMEOUT_WARNING_THRESHOLD=300            # 5 minutes before timeout
TIMEOUT_AUTO_ESCALATION=true
TIMEOUT_EMERGENCY_TERMINATION=true

# Backup Configuration
BACKUP_ENABLED=true
BACKUP_RETENTION_HOURS=168               # 1 week
BACKUP_CHECKPOINT_FREQUENCY=1800         # 30 minutes
BACKUP_COMPRESSION=false

# Recovery Configuration
RECOVERY_AUTO_ATTEMPT=true
RECOVERY_MAX_ATTEMPTS=3
RECOVERY_FALLBACK_MODE=true
RECOVERY_USER_NOTIFICATION=true

# Session Recovery Configuration  
SESSION_HEALTH_CHECK_INTERVAL=60         # 1 minute during task execution
SESSION_RECOVERY_TIMEOUT=300             # 5 minutes
SESSION_RECOVERY_MAX_ATTEMPTS=3
```

#### Schritt 2: Integration in Main Loop
**Extend**: `src/hybrid-monitor.sh`
```bash
# Load error handling modules
load_error_handling_modules() {
    local modules=(
        "task-timeout-monitor.sh"
        "session-recovery.sh"  
        "task-state-backup.sh"
        "usage-limit-recovery.sh"
        "error-classification.sh"
    )
    
    for module in "${modules[@]}"; do
        local module_path="$PROJECT_ROOT/src/$module"
        if [[ -f "$module_path" ]]; then
            source "$module_path"
            log_debug "Error handling module loaded: $module"
        else
            log_warn "Error handling module not found: $module"
        fi
    done
    
    log_info "Error handling system initialized"
}

# Enhanced monitoring loop with error handling
continuous_monitoring_loop() {
    log_info "Starting enhanced monitoring with error handling"
    
    while [[ "$MONITORING_ACTIVE" == "true" && $CURRENT_CYCLE -lt $MAX_RESTARTS ]]; do
        ((CURRENT_CYCLE++))
        
        log_info "=== Enhanced Monitoring Cycle $CURRENT_CYCLE/$MAX_RESTARTS ==="
        
        # Existing monitoring logic...
        
        # Enhanced task processing with error handling
        if [[ "${TASK_QUEUE_ENABLED:-false}" == "true" ]]; then
            if ! process_task_queue_with_error_handling; then
                log_warn "Task queue processing encountered errors"
                handle_queue_processing_error
            fi
        fi
        
        # Create periodic system checkpoint
        if should_create_checkpoint; then
            create_emergency_system_backup "periodic"
        fi
        
        sleep "$check_interval_seconds"
    done
}
```

## Tests und Validierung

### Unit Tests (New)
```bash
tests/unit/test-error-handling-core.bats        # Core error handling functions
tests/unit/test-timeout-monitor.bats            # Timeout detection and handling  
tests/unit/test-session-recovery.bats           # Session recovery mechanisms
tests/unit/test-backup-system.bats              # Backup and restore functionality
tests/unit/test-error-classification.bats       # Error classification engine
```

### Integration Tests (New) 
```bash
tests/integration/test-end-to-end-error-recovery.bats  # Full error recovery workflows
tests/integration/test-timeout-scenarios.bats          # Various timeout scenarios
tests/integration/test-session-failure-recovery.bats   # Session failure handling
tests/integration/test-usage-limit-integration.bats    # Usage limit integration
```

### Error Scenario Tests
```bash
# Test various error conditions:
- Task timeouts with different durations
- Session crashes during task execution  
- Network disconnections
- Usage limit scenarios
- Disk space exhaustion
- Memory exhaustion (simulated)
- Concurrent access conflicts
- Configuration errors
```

## Fortschrittsnotizen
- **Architecture designed**: Focused on core functionality without complex GitHub integration initially
- **Module separation planned**: Each error handling component in separate, focused files
- **Configuration integration**: Comprehensive configuration options for all error handling aspects
- **Backward compatibility**: All error handling is optional and configurable
- **Performance considerations**: Efficient monitoring without excessive resource usage

## Ressourcen & Referenzen
- Existing task queue system: `src/task-queue.sh`
- Session management: `src/session-manager.sh`  
- Configuration system: `config/default.conf`
- GitHub Issue #43: Complete acceptance criteria and technical details
- Related scratchpads: Task execution engine implementation, file locking enhancements

## Abschluss-Checkliste
- [ ] **Timeout Detection System**: Robust timeout monitoring with warnings and escalation
- [ ] **Session Recovery Mechanisms**: Automatic session health monitoring and recovery
- [ ] **Basic Backup Strategy**: Local checkpoint system with state preservation
- [ ] **Usage Limit Integration**: Queue-aware usage limit handling with automatic resume
- [ ] **Error Classification**: Intelligent error severity classification and recovery strategies
- [ ] **Integration Testing**: End-to-end error handling scenario testing
- [ ] **Performance Validation**: Ensure error handling doesn't impact normal operation performance
- [ ] **Configuration Documentation**: Complete documentation of all error handling configuration options
- [ ] **Recovery Procedures**: Clear procedures for manual intervention when automatic recovery fails

---
**Status**: Aktiv
**Zuletzt aktualisiert**: 2025-08-27
**Nächster Agent**: creator (für Implementierung der Core Error Handling Komponenten)
**Geschätzte Implementierungszeit**: 3-4 Tage für alle 6 Phasen