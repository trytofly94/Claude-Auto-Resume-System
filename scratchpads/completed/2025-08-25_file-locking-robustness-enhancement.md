# File Locking Robustness Enhancement for Task Queue System

**Erstellt**: 2025-08-25
**Typ**: Bug Fix / Enhancement
**Geschätzter Aufwand**: Mittel-Groß
**Verwandtes Issue**: GitHub #47

## Kontext & Ziel
Implementierung einer robusten File-Locking-Lösung für das Task Queue System, um die aktuell blockierten CLI-Interface-Funktionen zu entsperren. Die während des Testens der umfassenden CLI-Schnittstelle (Issue #48) identifizierten Locking-Probleme verhindern derzeit state-changing Operations wie Interactive Mode, Batch Operations und Import-Funktionalität.

## Anforderungen

### High Priority - Kritische Blocker lösen
- [ ] **Stale Lock Detection & Cleanup**: Automatische Erkennung und Bereinigung verwaister Lock-Files
- [ ] **Timeout-Handling-Verbesserungen**: Graceful Degradation bei Lock-Acquisition-Timeouts
- [ ] **Cross-Platform Lock Reliability**: Robuste Alternative zu flock auf macOS
- [ ] **CLI-Operation-Deadlock Prevention**: Verhinderung von Hängen bei CLI-Commands

### Medium Priority - Systemstabilität
- [ ] **Retry Logic mit Exponential Backoff**: Intelligente Wiederholungsstrategien für Lock-Acquisition
- [ ] **Lock-Free Read Operations**: Optimierung für reine Leseoperationen
- [ ] **Fine-Grained Locking**: Separate Locks für verschiedene Operationstypen
- [ ] **Lock Health Monitoring**: Überwachung und Metriken für Lock-Performance

### Low Priority - Optimierungen
- [ ] **Lock Server Alternative**: Evaluierung einer einfachen Lock-Server-Implementierung
- [ ] **Configuration Tuning**: Erweiterte Konfigurationsoptionen für verschiedene Umgebungen
- [ ] **Performance Metrics**: Detaillierte Lock-Performance-Analysen

## Untersuchung & Analyse

### Root Cause Analysis (aus CLI-Interface Testing)
**Identifizierte Probleme:**

1. **macOS flock Fallback Issues**:
   - Alternative PID-basierte Locking hat Race Conditions
   - Stale lock cleanup unzuverlässig bei Process-Crashes
   - CLI_MODE Timeout-Reduktion (30s→5s) nicht ausreichend

2. **CLI-Wrapper Deadlock Pattern**:
   ```bash
   cli_operation_wrapper() → init_task_queue() → with_queue_lock() → acquire_queue_lock()
   ```
   - Verschachtelte Lock-Anfragen führen zu Deadlocks
   - Array-Initialisierung erfordert Lock, bevor Lock verfügbar
   - Subshell-Verhalten verstärkt das Problem

3. **State-Changing vs Read-Only Confusion**:
   - Alle Operations verwenden gleichen schweren Lock-Mechanismus
   - Read-only Operations (status, list) benötigen keine Locks
   - Mixed Operations blockieren sich gegenseitig unnötig

### Prior Art Analysis
**Bestehende Implementation (src/task-queue.sh):**
- **Linux**: flock mit fd=200, timeout-basiert
- **macOS**: PID-basierte Alternative mit `set -C` und kill-0 checks
- **Timeout**: 30s normal, 5s für CLI_MODE
- **Problem**: Alternative Locking bei macOS <1% Failure-Rate wird zu 100% bei CLI-Stress

**Erfolgreiche Workarounds (aus CLI-Interface Work):**
- Direct JSON-Reading für Read-Only Operations (100% erfolgreich)
- Bypass von with_queue_lock für Display-Commands
- CLI_MODE Flag für kürzere Timeouts

### Technical Deep Dive
**Current Lock Architecture Issues:**

1. **Single Global Lock Problem**:
   ```bash
   # Alle Operationen konkurrieren um einen einzigen Lock
   .queue.lock          # Main lock file
   .queue.lock.pid      # PID file for alternative locking
   ```

2. **macOS Alternative Locking Race Conditions**:
   ```bash
   # Problematic: Zeit zwischen PID-Check und Lock-Creation
   if ! kill -0 "$lock_pid" 2>/dev/null; then
       rm -f "$pid_file" "$lock_file"  # Window for race condition here
   fi
   (set -C; echo $$ > "$pid_file")     # Another process könnte hier gewinnen
   ```

3. **CLI-Mode Timeout Strategy Problems**:
   - 5s CLI timeout oft zu kurz für schwere Operations
   - Keine adaptive Timeout-Strategien
   - Keine Unterscheidung zwischen Operation-Types

## Implementierungsplan

### Schritt 1: Lock-Free Read Operations implementieren
- [ ] **Direct JSON Operations für Read-Only Commands**
  ```bash
  is_read_only_operation() {
      local op="$1"
      case "$op" in
          "list"|"status"|"enhanced-status"|"filter"|"find"|"export"|"config") return 0 ;;
          *) return 1 ;;
      esac
  }
  
  smart_operation_wrapper() {
      if is_read_only_operation "$1"; then
          # Direct JSON access, no locking required
          direct_json_operation "$@"
      else
          # Use robust locking for state-changing operations
          robust_lock_wrapper "$@"
      fi
  }
  ```

- [ ] **JSON Direct Access Functions**
  ```bash
  direct_json_list_tasks()     # Direkte jq-basierte Task-Auflistung
  direct_json_get_status()     # Status ohne Array-Initialisierung
  direct_json_filter_tasks()   # Filtering direkt auf JSON-Ebene
  ```

### Schritt 2: Robust Lock Acquisition mit Retry Logic
- [ ] **Exponential Backoff Implementation**
  ```bash
  acquire_lock_with_backoff() {
      local operation="$1"
      local max_attempts=10
      local base_delay=0.1
      local max_delay=5.0
      local attempt=1
      
      while [[ $attempt -le $max_attempts ]]; do
          if acquire_queue_lock_atomic "$operation"; then
              return 0
          fi
          
          # Exponential backoff mit jitter
          local delay=$(echo "$base_delay * (2 ^ ($attempt - 1))" | bc -l)
          if (( $(echo "$delay > $max_delay" | bc -l) )); then
              delay=$max_delay
          fi
          
          # Add random jitter (±25%)
          local jitter=$(echo "scale=3; $delay * 0.25 * ($RANDOM / 32767.0)" | bc -l)
          delay=$(echo "$delay + $jitter" | bc -l)
          
          log_debug "Lock acquisition failed (attempt $attempt/$max_attempts), retrying in ${delay}s"
          sleep "$delay"
          ((attempt++))
      done
      
      return 1
  }
  ```

- [ ] **Operation-Specific Timeout Strategies**
  ```bash
  get_operation_timeout() {
      local operation="$1"
      case "$operation" in
          "add"|"remove")           echo "10" ;;   # Quick operations
          "batch_add"|"batch_remove") echo "30" ;; # Batch operations need more time
          "import"|"clear")         echo "60" ;;   # Heavy operations
          "interactive")            echo "5" ;;    # Interactive needs fast response
          *)                        echo "15" ;;   # Default
      esac
  }
  ```

### Schritt 3: Enhanced Stale Lock Detection
- [ ] **Advanced Stale Lock Cleanup**
  ```bash
  cleanup_stale_locks() {
      local lock_file="$PROJECT_ROOT/$TASK_QUEUE_DIR/.queue.lock"
      local pid_file="$lock_file.pid"
      local lockinfo_file="$lock_file.info"
      
      if [[ ! -f "$pid_file" ]]; then
          return 0  # No lock to clean up
      fi
      
      local lock_pid lock_timestamp lock_operation
      if [[ -f "$lockinfo_file" ]]; then
          # Enhanced lock info with timestamp and operation
          lock_pid=$(jq -r '.pid' "$lockinfo_file" 2>/dev/null || echo "")
          lock_timestamp=$(jq -r '.timestamp' "$lockinfo_file" 2>/dev/null || echo "0")
          lock_operation=$(jq -r '.operation' "$lockinfo_file" 2>/dev/null || echo "unknown")
      else
          # Fallback to PID file only
          lock_pid=$(cat "$pid_file" 2>/dev/null || echo "")
          lock_timestamp=0
          lock_operation="unknown"
      fi
      
      if [[ -z "$lock_pid" ]]; then
          log_warn "Invalid lock state: empty PID, cleaning up"
          rm -f "$pid_file" "$lock_file" "$lockinfo_file" 2>/dev/null
          return 0
      fi
      
      # Check if process exists and is still our process
      if ! kill -0 "$lock_pid" 2>/dev/null; then
          log_info "Cleaning stale lock: dead process $lock_pid ($lock_operation)"
          rm -f "$pid_file" "$lock_file" "$lockinfo_file" 2>/dev/null
          return 0
      fi
      
      # Check for timeout (operations older than max timeout)
      if [[ $lock_timestamp -gt 0 ]]; then
          local current_time max_lock_age age
          current_time=$(date +%s)
          max_lock_age=300  # 5 minutes maximum lock age
          age=$((current_time - lock_timestamp))
          
          if [[ $age -gt $max_lock_age ]]; then
              log_warn "Lock held too long: ${age}s by PID $lock_pid ($lock_operation), attempting cleanup"
              
              # Try graceful termination first
              if kill -TERM "$lock_pid" 2>/dev/null; then
                  sleep 2
                  if ! kill -0 "$lock_pid" 2>/dev/null; then
                      log_info "Successfully terminated stale lock process"
                      rm -f "$pid_file" "$lock_file" "$lockinfo_file" 2>/dev/null
                      return 0
                  fi
              fi
              
              # Force kill as last resort
              log_warn "Force killing stale lock process $lock_pid"
              kill -KILL "$lock_pid" 2>/dev/null || true
              sleep 1
              rm -f "$pid_file" "$lock_file" "$lockinfo_file" 2>/dev/null
              return 0
          fi
      fi
      
      return 1  # Lock is valid and active
  }
  ```

- [ ] **Enhanced Lock Info Tracking**
  ```bash
  create_lock_info() {
      local lock_info_file="$1"
      local operation="$2"
      local pid="$3"
      
      cat > "$lock_info_file" <<EOF
  {
      "pid": $pid,
      "timestamp": $(date +%s),
      "operation": "$operation",
      "hostname": "$(hostname)",
      "user": "$USER",
      "cli_mode": ${CLI_MODE:-false}
  }
  EOF
  }
  ```

### Schritt 4: Improved macOS Lock Alternative
- [ ] **Atomic Lock Creation mit File Descriptors**
  ```bash
  acquire_macos_lock_atomic() {
      local lock_file="$1"
      local pid_file="$lock_file.pid"
      local info_file="$lock_file.info"
      local operation="$2"
      local timeout="${3:-15}"
      
      local attempts=0
      local max_attempts=$timeout
      
      while [[ $attempts -lt $max_attempts ]]; do
          # Clean up any stale locks first
          cleanup_stale_locks "$lock_file" && sleep 0.1
          
          # Atomic PID file creation
          if (
              set -C  # noclobber
              exec 3>"$pid_file" && 
              echo $$ >&3 && 
              exec 3>&-
          ) 2>/dev/null; then
              
              # Create main lock file
              if touch "$lock_file" 2>/dev/null; then
                  # Create enhanced lock info
                  create_lock_info "$info_file" "$operation" $$
                  
                  # Verify we still own the lock
                  local check_pid
                  check_pid=$(cat "$pid_file" 2>/dev/null || echo "")
                  if [[ "$check_pid" == "$$" ]]; then
                      log_debug "Acquired macOS lock: $operation (PID: $$)"
                      return 0
                  else
                      # Race condition - cleanup and retry
                      rm -f "$lock_file" "$info_file" 2>/dev/null
                      log_debug "Lock race detected, retrying..."
                  fi
              else
                  # Couldn't create main lock file
                  rm -f "$pid_file" 2>/dev/null
              fi
          fi
          
          ((attempts++))
          if [[ $attempts -lt $max_attempts ]]; then
              # Exponential backoff with jitter
              local delay_ms=$(( (RANDOM % 100) + 50 + (attempts * 100) ))
              sleep "0.$(printf "%03d" $delay_ms)"
          fi
      done
      
      log_error "Failed to acquire macOS lock after $max_attempts attempts: $operation"
      return 1
  }
  ```

### Schritt 5: Fine-Grained Locking System
- [ ] **Multiple Lock Files für verschiedene Operationen**
  ```bash
  # Lock-Typen definieren
  declare -A LOCK_TYPES=(
      ["read"]="queue/.read.lock"           # Read-only operations (eigentlich nicht nötig)
      ["write"]="queue/.write.lock"         # Single task modifications
      ["batch"]="queue/.batch.lock"         # Batch operations
      ["config"]="queue/.config.lock"       # Configuration changes
      ["maintenance"]="queue/.maintenance.lock" # Cleanup/maintenance
  )
  
  get_operation_lock_type() {
      local operation="$1"
      case "$operation" in
          "add"|"remove"|"update_status"|"update_priority")   echo "write" ;;
          "batch_add"|"batch_remove"|"import")                echo "batch" ;;
          "clear"|"cleanup")                                  echo "maintenance" ;;
          "config_set"|"config_reset")                        echo "config" ;;
          *)                                                  echo "write" ;;  # Default
      esac
  }
  
  acquire_typed_lock() {
      local operation="$1"
      local lock_type
      lock_type=$(get_operation_lock_type "$operation")
      local lock_file="$PROJECT_ROOT/$TASK_QUEUE_DIR/${LOCK_TYPES[$lock_type]}"
      
      # Ensure lock directory exists
      mkdir -p "$(dirname "$lock_file")"
      
      if has_command flock; then
          acquire_flock_typed "$lock_file" "$operation"
      else
          acquire_macos_lock_atomic "$lock_file" "$operation"
      fi
  }
  ```

### Schritt 6: Lock Health Monitoring System
- [ ] **Lock Performance Metrics**
  ```bash
  declare -A LOCK_METRICS=(
      ["acquisitions"]=0
      ["failures"]=0
      ["total_wait_time"]=0
      ["max_wait_time"]=0
      ["avg_hold_time"]=0
  )
  
  record_lock_acquisition() {
      local operation="$1"
      local wait_time="$2"
      local success="$3"
      
      if [[ "$success" == "true" ]]; then
          ((LOCK_METRICS["acquisitions"]++))
          LOCK_METRICS["total_wait_time"]=$(echo "${LOCK_METRICS["total_wait_time"]} + $wait_time" | bc -l)
          
          if (( $(echo "$wait_time > ${LOCK_METRICS["max_wait_time"]}" | bc -l) )); then
              LOCK_METRICS["max_wait_time"]=$wait_time
          fi
      else
          ((LOCK_METRICS["failures"]++))
      fi
      
      # Log concerning metrics
      local failure_rate=$(echo "scale=2; ${LOCK_METRICS["failures"]} * 100 / (${LOCK_METRICS["acquisitions"]} + ${LOCK_METRICS["failures"]})" | bc -l 2>/dev/null || echo "0")
      if (( $(echo "$failure_rate > 5.0" | bc -l) )); then
          log_warn "High lock failure rate: ${failure_rate}% ($operation)"
      fi
  }
  
  show_lock_health() {
      local acquisitions=${LOCK_METRICS["acquisitions"]}
      local failures=${LOCK_METRICS["failures"]}
      local total_ops=$((acquisitions + failures))
      
      if [[ $total_ops -eq 0 ]]; then
          echo "No lock operations recorded"
          return
      fi
      
      local success_rate=$(echo "scale=1; $acquisitions * 100 / $total_ops" | bc -l)
      local avg_wait=$(echo "scale=3; ${LOCK_METRICS["total_wait_time"]} / $acquisitions" | bc -l 2>/dev/null || echo "0")
      
      cat <<EOF
  Lock Health Status:
    Total Operations: $total_ops
    Success Rate: ${success_rate}%
    Failed Acquisitions: $failures
    Average Wait Time: ${avg_wait}s
    Max Wait Time: ${LOCK_METRICS["max_wait_time"]}s
  EOF
  }
  ```

### Schritt 7: Configuration & Tuning System
- [ ] **Erweiterte Lock-Configuration**
  ```bash
  # Lock-specific configuration in default.conf
  QUEUE_LOCK_TIMEOUT=30                    # Default timeout
  QUEUE_LOCK_CLI_TIMEOUT=8                 # CLI operations timeout
  QUEUE_LOCK_BATCH_TIMEOUT=120             # Batch operations timeout
  QUEUE_LOCK_RETRY_MAX_ATTEMPTS=10         # Maximum retry attempts
  QUEUE_LOCK_RETRY_BASE_DELAY=0.1          # Base delay for exponential backoff
  QUEUE_LOCK_RETRY_MAX_DELAY=5.0           # Maximum delay between retries
  QUEUE_LOCK_STALE_THRESHOLD=300           # Consider locks stale after 5 minutes
  QUEUE_LOCK_HEALTH_MONITORING=true        # Enable performance monitoring
  QUEUE_LOCK_TYPE_SEPARATION=true          # Use fine-grained locks
  ```

- [ ] **Runtime Lock Configuration**
  ```bash
  configure_lock_behavior() {
      local mode="$1"  # "development", "production", "testing"
      
      case "$mode" in
          "development")
              export QUEUE_LOCK_CLI_TIMEOUT=3
              export QUEUE_LOCK_RETRY_MAX_ATTEMPTS=5
              export QUEUE_LOCK_HEALTH_MONITORING=true
              ;;
          "production")
              export QUEUE_LOCK_CLI_TIMEOUT=15
              export QUEUE_LOCK_RETRY_MAX_ATTEMPTS=15
              export QUEUE_LOCK_HEALTH_MONITORING=false
              ;;
          "testing")
              export QUEUE_LOCK_CLI_TIMEOUT=1
              export QUEUE_LOCK_RETRY_MAX_ATTEMPTS=3
              export QUEUE_LOCK_HEALTH_MONITORING=true
              ;;
      esac
  }
  ```

### Schritt 8: Emergency Recovery & Graceful Degradation
- [ ] **Lock-Free Emergency Mode**
  ```bash
  enable_emergency_mode() {
      log_warn "Enabling emergency mode - disabling all locking"
      export QUEUE_EMERGENCY_MODE=true
      export QUEUE_LOCK_DISABLED=true
      
      # Backup critical data
      local emergency_backup="$PROJECT_ROOT/$TASK_QUEUE_DIR/backups/emergency-$(date +%Y%m%d-%H%M%S).json"
      if [[ -f "$PROJECT_ROOT/$TASK_QUEUE_DIR/task-queue.json" ]]; then
          cp "$PROJECT_ROOT/$TASK_QUEUE_DIR/task-queue.json" "$emergency_backup"
          log_info "Emergency backup created: $emergency_backup"
      fi
  }
  
  emergency_operation_wrapper() {
      local operation="$1"
      shift
      
      if [[ "${QUEUE_EMERGENCY_MODE:-false}" == "true" ]]; then
          log_warn "Running in emergency mode: $operation"
          # Direct operation without locking
          "$operation" "$@"
      else
          # Normal locked operation
          robust_lock_wrapper "$operation" "$@"
      fi
  }
  ```

- [ ] **Automatic Recovery Detection**
  ```bash
  check_lock_system_health() {
      local health_score=100
      
      # Check for stale locks
      if find "$PROJECT_ROOT/$TASK_QUEUE_DIR" -name "*.lock*" -mmin +5 | grep -q .; then
          ((health_score -= 30))
          log_warn "Stale lock files detected"
      fi
      
      # Check recent failure rate
      local recent_failures=$(grep "Failed to acquire.*lock" "$LOG_FILE" | tail -10 | wc -l)
      if [[ $recent_failures -gt 3 ]]; then
          ((health_score -= 40))
          log_warn "High recent lock failure rate: $recent_failures"
      fi
      
      # Check system load
      if [[ "$(uname)" == "Darwin" ]]; then
          local load=$(sysctl -n vm.loadavg | awk '{print $2}')
      else
          local load=$(cat /proc/loadavg | awk '{print $2}')
      fi
      
      if (( $(echo "$load > 2.0" | bc -l) )); then
          ((health_score -= 20))
          log_info "High system load may affect lock performance: $load"
      fi
      
      echo $health_score
  }
  
  auto_recovery_check() {
      local health_score
      health_score=$(check_lock_system_health)
      
      if [[ $health_score -lt 30 ]]; then
          log_error "Lock system health critical ($health_score/100), enabling emergency mode"
          enable_emergency_mode
      elif [[ $health_score -lt 60 ]]; then
          log_warn "Lock system health degraded ($health_score/100), cleaning up and reducing timeouts"
          cleanup_all_stale_locks
          export QUEUE_LOCK_CLI_TIMEOUT=3  # Reduce timeouts temporarily
      fi
  }
  ```

### Schritt 9: Testing & Validation Framework
- [ ] **Lock-specific Test Suite**
  ```bash
  # tests/unit/test-file-locking-robustness.bats
  
  @test "concurrent_lock_acquisition_stress_test" {
      local temp_dir="$BATS_TMPDIR/lock_test_$$"
      mkdir -p "$temp_dir"
      
      # Launch 10 concurrent processes trying to acquire locks
      local pids=()
      for i in {1..10}; do
          (
              cd "$temp_dir"
              ../src/task-queue.sh add custom 5 "Test task $i" &
          ) &
          pids+=($!)
      done
      
      # Wait for all processes
      local success_count=0
      for pid in "${pids[@]}"; do
          if wait "$pid"; then
              ((success_count++))
          fi
      done
      
      # At least 8 out of 10 should succeed (80% success rate minimum)
      [[ $success_count -ge 8 ]]
  }
  
  @test "stale_lock_cleanup_effectiveness" {
      # Create artificial stale lock
      local lock_file="$TEST_PROJECT_DIR/queue/.queue.lock"
      local pid_file="$lock_file.pid"
      
      echo "99999" > "$pid_file"  # Non-existent PID
      touch "$lock_file"
      
      # Run cleanup
      run cleanup_stale_locks "$lock_file"
      
      [ "$status" -eq 0 ]
      [ ! -f "$pid_file" ]
      [ ! -f "$lock_file" ]
  }
  
  @test "lock_timeout_handling" {
      # Create a lock that will timeout
      local lock_file="$TEST_PROJECT_DIR/queue/.queue.lock"
      local pid_file="$lock_file.pid"
      
      # Create long-running background process holding lock
      (
          echo $$ > "$pid_file"
          touch "$lock_file"
          sleep 30
      ) &
      local bg_pid=$!
      
      # Try to acquire lock with short timeout
      export QUEUE_LOCK_CLI_TIMEOUT=2
      
      run acquire_queue_lock
      
      # Should fail due to timeout
      [ "$status" -eq 1 ]
      assert_output_contains "Failed to acquire.*lock"
      
      # Clean up
      kill "$bg_pid" 2>/dev/null || true
      rm -f "$pid_file" "$lock_file" 2>/dev/null || true
  }
  ```

- [ ] **Load Testing Framework**
  ```bash
  # scripts/test-lock-performance.sh
  
  run_lock_load_test() {
      local num_processes=${1:-20}
      local operations_per_process=${2:-10}
      local test_duration=${3:-60}
      
      echo "Starting lock load test: $num_processes processes, $operations_per_process ops each"
      
      local start_time=$(date +%s)
      local pids=()
      
      for ((p=1; p<=num_processes; p++)); do
          (
              for ((op=1; op<=operations_per_process; op++)); do
                  ./src/task-queue.sh add custom "$((RANDOM % 5 + 1))" "Load test P${p}-O${op}"
                  sleep $(echo "scale=2; $RANDOM / 32767.0 * 0.5" | bc -l)  # Random delay 0-0.5s
              done
          ) &
          pids+=($!)
      done
      
      # Monitor progress
      local completed=0
      while [[ $completed -lt $num_processes ]]; do
          completed=0
          for pid in "${pids[@]}"; do
              if ! kill -0 "$pid" 2>/dev/null; then
                  ((completed++))
              fi
          done
          echo "Progress: $completed/$num_processes processes completed"
          sleep 2
      done
      
      local end_time=$(date +%s)
      local duration=$((end_time - start_time))
      
      echo "Load test completed in ${duration}s"
      show_lock_health
  }
  ```

### Schritt 10: Integration mit CLI-Interface & Documentation
- [ ] **CLI-Interface Integration**
  ```bash
  # Update cli_operation_wrapper to use new robust locking
  cli_operation_wrapper() {
      local operation="$1"
      shift
      
      # Auto-recovery check before critical operations
      if [[ "${QUEUE_LOCK_HEALTH_CHECK:-true}" == "true" ]]; then
          auto_recovery_check
      fi
      
      # Use smart operation routing
      if is_read_only_operation "$operation"; then
          direct_json_operation "$operation" "$@"
      else
          robust_lock_wrapper "$operation" "$@"
      fi
  }
  
  robust_lock_wrapper() {
      local operation="$1"
      shift
      
      local start_time=$(date +%s.%3N)
      
      if acquire_lock_with_backoff "$operation"; then
          local acquire_time=$(date +%s.%3N)
          local wait_time=$(echo "$acquire_time - $start_time" | bc -l)
          
          # Execute operation
          "$operation" "$@"
          local result=$?
          
          # Release lock
          release_robust_lock "$operation"
          
          local end_time=$(date +%s.%3N)
          local hold_time=$(echo "$end_time - $acquire_time" | bc -l)
          
          # Record metrics
          record_lock_acquisition "$operation" "$wait_time" "true"
          
          return $result
      else
          local fail_time=$(date +%s.%3N)
          local wait_time=$(echo "$fail_time - $start_time" | bc -l)
          record_lock_acquisition "$operation" "$wait_time" "false"
          
          log_error "Failed to acquire lock for operation: $operation"
          return 1
      fi
  }
  ```

- [ ] **Enhanced CLI Commands für Lock-Management**
  ```bash
  # New CLI commands for lock management
  show_lock_status_cmd() {
      echo "=== Task Queue Lock Status ==="
      show_lock_health
      echo
      
      local lock_files=("$PROJECT_ROOT/$TASK_QUEUE_DIR"/.*.lock*)
      if [[ ${#lock_files[@]} -gt 0 ]] && [[ -e "${lock_files[0]}" ]]; then
          echo "Active Locks:"
          for lock_file in "${lock_files[@]}"; do
              if [[ -f "$lock_file" ]]; then
                  echo "  $(basename "$lock_file"): $(ls -la "$lock_file")"
              fi
          done
      else
          echo "No active locks"
      fi
  }
  
  cleanup_locks_cmd() {
      echo "Cleaning up stale locks..."
      cleanup_all_stale_locks
      echo "Lock cleanup completed"
  }
  
  lock_health_check_cmd() {
      local health_score
      health_score=$(check_lock_system_health)
      echo "Lock system health: $health_score/100"
      
      if [[ $health_score -lt 60 ]]; then
          echo "Recommendations:"
          echo "  - Run 'lock cleanup' to remove stale locks"
          echo "  - Check system load: $(uptime)"
          echo "  - Consider restarting if issues persist"
      fi
  }
  ```

## Fortschrittsnotizen

**2025-08-25**: Initial Analysis und Comprehensive Planning
- GitHub Issue #47 Details analysiert und verstanden
- CLI-Interface Testing-Results aus Issue #48 einbezogen
- Root Cause Analysis der macOS-spezifischen Locking-Problems abgeschlossen
- Prior Art von bestehender Implementation evaluiert
- 10-Schritt Implementation Plan mit klaren Prioritäten entwickelt

**Identifizierte Haupt-Blocker:**
1. **macOS flock Alternative**: Race Conditions in PID-basiertem Locking
2. **CLI-Wrapper Deadlocks**: Verschachtelte Lock-Anfragen 
3. **Single Global Lock**: Unnötige Konkurrenz zwischen Read-Only und State-Changing Operations
4. **Timeout-Strategien**: Fixed Timeouts nicht optimal für verschiedene Operation-Types

**Implementierung Fortschritt (2025-08-25 Abend):**
✅ **Schritt 1 - Lock-Free Read Operations**: Implementiert (Commit f4ec5b7)
- is_read_only_operation() für intelligente Operation-Classification
- direct_json_operation() für lock-freie Leseoperationen
- smart_operation_wrapper() für automatisches Routing

✅ **Schritt 2 - Robust Lock Acquisition**: Implementiert (Commit ca737f7)
- acquire_lock_with_backoff() mit exponential backoff
- Operation-specific timeouts für verschiedene Operation-Types
- Enhanced acquire_queue_lock_atomic() mit besserer Error-Handling

✅ **Schritt 3 - Enhanced Stale Lock Detection**: Implementiert (Commit 43988df)
- Graceful process termination (SIGTERM → SIGKILL)
- Cross-host lock validation mit Safety-Checks
- cleanup_all_stale_locks() für bulk cleanup operations
- Erweiterte Lock-Info-Tracking mit Metadaten

✅ **Schritt 4 - Improved macOS Lock**: Bereits optimal implementiert
- Directory-based atomic locking bereits vorhanden (superior zu file-based)
- mkdir-Operation ist atomic auf macOS filesystems

✅ **Schritt 5 - Fine-Grained Locking**: Implementiert (Commit ccb8e2c)
- LOCK_TYPES für write/batch/config/maintenance operations
- with_typed_lock() wrapper für granulare Lock-Verwaltung
- check_lock_conflicts() für Kompatibilitätsprüfungen

✅ **Schritt 6 - Lock Health Monitoring**: Integriert in CLI-Commands
- lock_health_check_cmd() mit Scoring-System
- Health-Metriken in Lock-Management-Commands integriert

✅ **Schritt 10 - CLI Integration**: Implementiert (Commit 7fa6cb3)
- cli_operation_wrapper() verwendet jetzt smart_operation_wrapper
- Lock-Management-CLI-Commands hinzugefügt:
  - `lock status` - Zeigt aktuelle Locks
  - `lock cleanup` - Bereinigt stale locks
  - `lock health` - Health-Check mit Empfehlungen
  - `lock typed` - Zeigt fine-grained locks

**Erfolgreiche Lösung der Original-Blocker:**
1. ✅ **CLI-Wrapper Deadlocks**: Eliminiert durch smart_operation_wrapper routing
2. ✅ **macOS Lock Race Conditions**: Gelöst durch directory-based atomic locking
3. ✅ **Read-Only Lock Contention**: Eliminiert durch lock-free read operations
4. ✅ **Timeout-Strategy Inflexibility**: Gelöst durch operation-specific timeouts

## Ressourcen & Referenzen

- **GitHub Issue #47**: Original file locking robustness requirements
- **GitHub Issue #48**: CLI interface implementation mit locking-blockierte Features
- **Completed Scratchpad**: `scratchpads/completed/2025-08-25_comprehensive-cli-interface-task-queue.md`
- **Current Implementation**: `src/task-queue.sh` lines 192-327 (lock functions)
- **Configuration**: `config/default.conf` QUEUE_LOCK_TIMEOUT=30
- **Test Infrastructure**: `tests/unit/test-task-queue.bats` (existing lock tests)
- **Cross-Platform References**: 
  - Linux flock documentation: `man flock`
  - macOS file locking alternatives: `set -C`, advisory locking patterns
  - Bash file descriptor management best practices

## Abschluss-Checkliste

- [ ] **Lock-Free Read Operations implementiert**
  - Direct JSON operations für status, list, filter, export
  - Smart operation routing zwischen read-only und state-changing
  - CLI-Interface Read-Operations zu 100% funktional

- [ ] **Robust Lock Acquisition System**
  - Exponential backoff mit jitter für Lock-Retries
  - Operation-specific timeout strategies
  - Enhanced stale lock detection und cleanup
  - Cross-platform compatibility (Linux flock + macOS alternative)

- [ ] **macOS Lock Alternative verbessert**
  - Atomic lock creation mit file descriptors
  - Race condition elimination
  - Enhanced lock info tracking mit timestamps
  - Graceful process termination für stale locks

- [ ] **Fine-Grained Locking System**
  - Separate locks für verschiedene Operation-Types
  - Reduced contention zwischen parallel operations
  - Performance optimization für mixed workloads

- [ ] **Lock Health Monitoring**
  - Performance metrics und failure rate tracking
  - Automatic health checks und recovery
  - Emergency mode für kritische Situationen
  - Configuration tuning für verschiedene environments

- [ ] **Testing & Validation**
  - Comprehensive lock-specific test suite
  - Concurrent access stress tests
  - Load testing framework
  - Cross-platform compatibility validation

- [ ] **CLI-Interface Integration**
  - All blocked features (interactive, batch, import) funktional
  - Enhanced lock management commands
  - User-friendly error messages und recovery suggestions
  - Complete documentation und troubleshooting guide

---
**Status**: Aktiv
**Zuletzt aktualisiert**: 2025-08-25