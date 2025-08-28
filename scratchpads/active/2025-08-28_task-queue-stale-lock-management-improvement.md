# Task Queue Stale Lock Management Improvement - Issue #71

**Erstellt**: 2025-08-28
**Typ**: Bug Fix / Enhancement
**Geschätzter Aufwand**: Mittel
**Verwandtes Issue**: GitHub #71

## Kontext & Ziel

Behebung kritischer Stale-Lock-Probleme im Task Queue System, die Write-Operationen wie `clear`, `add` und andere Queue-Modifikationen vollständig blockieren. Das aktuelle Enhanced Directory-Based Locking System hat eine unvollständige Implementierung der Stale Lock Detection, wodurch tote Prozesse das Queue-System dauerhaft blockieren können.

**Aktueller Zustand**: Stale Lock von PID 7408 blockiert alle Write-Operationen, obwohl der Prozess nicht mehr existiert.

## Anforderungen

- [x] Aktuelle Stale Lock Situation analysiert (PID 7408 tot, Lock-Verzeichnis existiert)
- [ ] Robuste Stale Lock Detection implementiert mit mehreren Validierungskriterien
- [ ] Automatische Cleanup-Mechanismen für tote Prozesse
- [ ] Emergency Unlock-Commands für Benutzer-Intervention
- [ ] Lock Timeout und Force-Cleanup nach angemessener Wartezeit  
- [ ] Verbesserte Error Messages mit Recovery-Guidance
- [ ] Vollständige Wiederherstellung der Write-Operationen ohne manuelle Intervention

## Untersuchung & Analyse

### Aktueller Stale Lock Zustand (PID 7408)

**Konkrete Evidence des Problems**:
```bash
$ ls -la queue/.queue.lock*
-rw-r--r--@ 1 lennart staff 0 28 Aug 09:40 .queue.lock          # Legacy lock file
-rw-r--r--@ 1 lennart staff 6 28 Aug 09:40 .queue.lock.pid      # Legacy PID file  
drwxr-xr-x@ 8 lennart staff 272 28 Aug 09:54 .queue.lock.d/     # Directory lock

$ cat queue/.queue.lock.d/pid
7408

$ ps -p 7408
PID TTY          TIME CMD
(process not found)  # ❌ Prozess ist tot, Lock bleibt bestehen
```

**Fehlerverhalten**:
```bash
$ ./src/task-queue.sh clear
[ERROR] Failed to acquire atomic queue lock after 10 attempts
[ERROR] Cannot execute operation without enhanced lock: clear_task_queue
```

### Code-Analyse: Bestehende Lock-Implementation

**Aktuell Implementierte Stale Lock Cleanup (`cleanup_stale_lock()`):**
```bash
# Line 212 in src/task-queue.sh - GOOD: Basic framework exists
cleanup_stale_lock() {
    local lock_dir="$1"
    [[ -d "$lock_dir" ]] || return 0
    
    local pid_file="$lock_dir/pid"
    local lock_pid=$(cat "$pid_file" 2>/dev/null || echo "")
    
    if [[ -z "$lock_pid" ]]; then
        rm -rf "$lock_dir" 2>/dev/null
        return 0
    fi
    
    if ! kill -0 "$lock_pid" 2>/dev/null; then  # ✅ Process validation works
        log_debug "Lock process $lock_pid is dead - cleaning up"
        rm -rf "$lock_dir" 2>/dev/null           # ✅ Cleanup attempts work
        return 0
    else
        log_debug "Lock process $lock_pid is alive - not cleaning up"
        return 1
    fi
}
```

### Root Cause Analysis

**Problem #1: Unvollständige Integration der Stale Lock Cleanup**
- `cleanup_stale_lock()` wird zwar in `acquire_queue_lock_atomic()` aufgerufen (Line 370, 406, 432)
- ABER: Fehlende robuste Error-Handling bei Cleanup-Fehlern
- ABER: Keine regelmäßige Cleanup-Zyklen außerhalb von Lock-Acquisition-Versuchen

**Problem #2: Lock Acquisition Logic Race Condition**
```bash
# Line 376 in acquire_queue_lock_atomic()
if mkdir "$lock_dir" 2>/dev/null; then
    # Success path - metadata writing
else
    # Failure path - calls cleanup_stale_lock
    cleanup_stale_lock "$lock_dir"    # ❌ PROBLEM: Wenn cleanup fehlschlägt, wird weitergegangen
fi
```

**Problem #3: Unzureichende Error Recovery**
- Bei wiederholen gescheiterten Lock-Acquisitions wird der Stale Lock nicht aggressiv genug behandelt
- Keine Fallback-Strategien bei persistenten Lock-Problemen
- CLI timeout von 5 attempts führt zu schneller Aufgabe ohne ausreichende Recovery-Versuche

**Problem #4: Fehlende Emergency Recovery Commands**
- Benutzer können bei Stale Locks nicht manuell intervenieren
- Keine `--force-unlock` oder ähnliche Bypass-Optionen
- Keine diagnostischen Commands für Lock-Zustand

### Prior Art aus Bestehenden Scratchpads

**Erfolgreiche Referenz-Implementation**: `scratchpads/completed/2025-08-25_enhance-file-locking-robustness.md`
- Zeigt, dass das Enhanced Directory-Based Locking System bereits **Phase 1 & 2 erfolgreich implementiert** wurde
- **Wichtiger Erkenntnisse**: 100% Success Rate unter Load wurde bereits erreicht
- **Aber**: Issue #71 zeigt, dass noch ein spezifischer Edge Case mit Stale Lock Cleanup existiert

**Aktuelle Directory-Based Lock Implementation**: Bereits robust, aber Stale Cleanup braucht Verbesserung
- Atomic `mkdir` für Lock Acquisition ✅
- Rich metadata (PID, timestamp, hostname, operation) ✅  
- Multi-criteria validation framework ✅
- **Lücke**: Aggressive Stale Lock Recovery bei hartnäckigen Cases

## Implementierungsplan

### Phase 1: Critical Stale Lock Resolution (Tag 1-2)

#### Schritt 1: Enhanced Stale Lock Detection mit Force Cleanup
- [ ] **Aggressive Multi-Pass Cleanup Strategy**
  ```bash
  cleanup_stale_lock_aggressive() {
      local lock_dir="$1"
      local force_cleanup="${2:-false}"
      
      [[ -d "$lock_dir" ]] || return 0
      
      local pid_file="$lock_dir/pid"
      local timestamp_file="$lock_dir/timestamp"
      local hostname_file="$lock_dir/hostname"
      
      # Pass 1: Standard validation
      local lock_pid=$(cat "$pid_file" 2>/dev/null || echo "")
      local lock_timestamp=$(cat "$timestamp_file" 2>/dev/null || echo "")
      local lock_hostname=$(cat "$hostname_file" 2>/dev/null || echo "")
      local should_cleanup=false
      local cleanup_reason=""
      
      # Criteria 1: Dead process check
      if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
          log_info "Stale lock detected: Process $lock_pid is dead"
          should_cleanup=true
          cleanup_reason="dead_process"
      fi
      
      # Criteria 2: Age-based cleanup (locks older than 10 minutes)
      if [[ -n "$lock_timestamp" ]]; then
          local current_time=$(date +%s)
          local lock_time=$(date -d "$lock_timestamp" +%s 2>/dev/null || echo 0)
          local age=$((current_time - lock_time))
          
          if [[ $age -gt 600 ]]; then  # 10 minutes
              log_info "Stale lock detected: Lock age ${age}s exceeds timeout"
              should_cleanup=true
              cleanup_reason="age_timeout"
          fi
      fi
      
      # Criteria 3: Different hostname (network filesystem safety)
      if [[ -n "$lock_hostname" && "$lock_hostname" != "$HOSTNAME" ]]; then
          log_debug "Cross-host lock detected: $lock_hostname vs $HOSTNAME"
          # Only cleanup if process is confirmed dead or very old
          if [[ "$should_cleanup" == "true" ]]; then
              cleanup_reason="${cleanup_reason}_cross_host"
          fi
      fi
      
      # Criteria 4: Force cleanup (emergency override)
      if [[ "$force_cleanup" == "true" ]]; then
          log_warn "Force cleanup requested for lock in $lock_dir"
          should_cleanup=true
          cleanup_reason="force_cleanup"
      fi
      
      # Execute cleanup with verification
      if [[ "$should_cleanup" == "true" ]]; then
          log_info "Removing stale lock: $lock_dir (reason: $cleanup_reason)"
          
          # Attempt removal with verification
          if rm -rf "$lock_dir" 2>/dev/null; then
              log_info "Successfully removed stale lock: $lock_dir"
              return 0
          else
              log_error "Failed to remove stale lock directory: $lock_dir"
              return 1
          fi
      else
          log_debug "Lock appears valid - not cleaning up: $lock_dir"
          return 1
      fi
  }
  ```

#### Schritt 2: Enhanced Lock Acquisition mit Aggressive Recovery
- [ ] **Multi-Phase Lock Acquisition Strategy**
  ```bash
  acquire_queue_lock_with_aggressive_recovery() {
      local lock_dir="$PROJECT_ROOT/$TASK_QUEUE_DIR/.queue.lock.d"
      local operation="${1:-unknown}"
      local max_attempts=15  # Increased from 10
      local attempts=0
      
      log_debug "Starting aggressive lock acquisition for: $operation"
      
      while [[ $attempts -lt $max_attempts ]]; do
          # Phase 1: Standard acquisition attempt
          if mkdir "$lock_dir" 2>/dev/null; then
              # Success - write metadata
              echo $$ > "$lock_dir/pid" 2>/dev/null || {
                  rm -rf "$lock_dir" 2>/dev/null
                  log_error "Failed to write PID to lock directory"
                  ((attempts++))
                  continue
              }
              
              date -Iseconds > "$lock_dir/timestamp" 2>/dev/null || {
                  rm -rf "$lock_dir" 2>/dev/null
                  log_error "Failed to write timestamp to lock directory" 
                  ((attempts++))
                  continue
              }
              
              echo "$HOSTNAME" > "$lock_dir/hostname" 2>/dev/null || {
                  rm -rf "$lock_dir" 2>/dev/null
                  log_error "Failed to write hostname to lock directory"
                  ((attempts++))
                  continue
              }
              
              echo "$USER" > "$lock_dir/user" 2>/dev/null || true
              echo "$operation" > "$lock_dir/operation" 2>/dev/null || true
              echo "${CLI_MODE:-false}" > "$lock_dir/cli_mode" 2>/dev/null || true
              
              log_info "Acquired queue lock (pid: $$, attempt: $attempts, operation: $operation)"
              return 0
          fi
          
          # Phase 2: Standard stale lock cleanup
          if cleanup_stale_lock_aggressive "$lock_dir" false; then
              log_debug "Standard cleanup successful, retrying immediately"
              continue  # Retry immediately after successful cleanup
          fi
          
          # Phase 3: Escalated cleanup after multiple failures
          if [[ $attempts -ge 5 ]]; then
              log_warn "Multiple lock acquisition failures, attempting aggressive cleanup"
              if cleanup_stale_lock_aggressive "$lock_dir" false; then
                  log_info "Aggressive cleanup successful, retrying"
                  continue
              fi
          fi
          
          # Phase 4: Emergency force cleanup (last resort)
          if [[ $attempts -ge 12 ]]; then
              log_error "Emergency force cleanup - persistent lock blocking operations"
              if cleanup_stale_lock_aggressive "$lock_dir" true; then
                  log_warn "Force cleanup successful - lock was likely stale"
                  continue
              else
                  log_error "Force cleanup failed - lock directory may have permission issues"
              fi
          fi
          
          # Exponential backoff with jitter
          local wait_time=$(echo "scale=2; 0.1 * (1.5 ^ $attempts) + ($RANDOM % 1000) / 10000" | bc -l 2>/dev/null || echo "1")
          wait_time=$(echo "if ($wait_time > 5.0) 5.0 else $wait_time" | bc -l 2>/dev/null || echo "2")
          
          log_debug "Lock attempt $((attempts + 1))/$max_attempts failed, waiting ${wait_time}s"
          sleep "$wait_time" 2>/dev/null || sleep 1
          
          ((attempts++))
      done
      
      # Final attempt with full diagnostic information
      log_error "Failed to acquire queue lock after $max_attempts aggressive attempts"
      show_lock_diagnostic_info "$lock_dir"
      return 1
  }
  ```

#### Schritt 3: Emergency Commands für Benutzer-Intervention
- [ ] **Lock Management CLI Commands**
  ```bash
  # Emergency unlock command
  force_unlock_queue_cmd() {
      local lock_dir="$PROJECT_ROOT/$TASK_QUEUE_DIR/.queue.lock.d"
      
      echo "🚨 EMERGENCY QUEUE UNLOCK"
      echo "Current lock status:"
      
      if [[ -d "$lock_dir" ]]; then
          get_lock_info "$lock_dir"
          echo
          echo "⚠️  WARNING: Force unlock will remove the lock regardless of validity"
          echo "   Only proceed if you're certain no other processes are using the queue"
          echo
          
          if [[ "${CLI_MODE:-false}" != "true" ]]; then
              read -p "Proceed with force unlock? (yes/NO): " confirm
              if [[ "$confirm" != "yes" ]]; then
                  echo "Force unlock cancelled"
                  return 1
              fi
          fi
          
          if cleanup_stale_lock_aggressive "$lock_dir" true; then
              echo "✅ Queue unlocked successfully"
              echo "📋 Testing queue functionality..."
              
              # Test queue operations
              if ./src/task-queue.sh status >/dev/null 2>&1; then
                  echo "✅ Queue is now functional"
                  return 0
              else
                  echo "⚠️  Queue unlock succeeded but functionality test failed"
                  return 1
              fi
          else
              echo "❌ Force unlock failed - check directory permissions"
              return 1
          fi
      else
          echo "No active locks found"
          return 0
      fi
  }
  
  # Diagnostic information display
  show_lock_diagnostic_info() {
      local lock_dir="$1"
      
      echo "=== LOCK DIAGNOSTIC INFORMATION ==="
      echo "Lock directory: $lock_dir"
      echo "Directory exists: $([[ -d "$lock_dir" ]] && echo "YES" || echo "NO")"
      
      if [[ -d "$lock_dir" ]]; then
          echo "Lock details:"
          get_lock_info "$lock_dir" | sed 's/^/  /'
          echo
          echo "Directory contents:"
          ls -la "$lock_dir" 2>/dev/null | sed 's/^/  /' || echo "  (Cannot list contents)"
          echo
          echo "Directory permissions:"
          ls -ld "$lock_dir" 2>/dev/null | sed 's/^/  /' || echo "  (Cannot check permissions)"
      fi
      
      echo "System information:"
      echo "  Current user: $USER"
      echo "  Current PID: $$"
      echo "  Hostname: $HOSTNAME"
      echo "  System load: $(uptime | awk -F'load average:' '{print $2}' | awk -F',' '{print $1}' | tr -d ' ')"
      echo "  Available disk space:"
      df -h "$PROJECT_ROOT" 2>/dev/null | tail -n 1 | sed 's/^/    /' || echo "    (Cannot check disk space)"
      echo "================================="
  }
  ```

### Phase 2: Enhanced Error Recovery & User Guidance (Tag 2-3)

#### Schritt 4: Verbesserte Error Messages mit Recovery Instructions
- [ ] **User-Friendly Error Reporting**
  ```bash
  handle_lock_acquisition_failure() {
      local operation="$1"
      local attempts="$2"
      local lock_dir="$PROJECT_ROOT/$TASK_QUEUE_DIR/.queue.lock.d"
      
      echo "❌ QUEUE LOCK ACQUISITION FAILED"
      echo "   Operation: $operation"
      echo "   Attempts: $attempts"
      echo
      
      # Analyze failure reason
      if [[ -d "$lock_dir" ]]; then
          local lock_pid=$(cat "$lock_dir/pid" 2>/dev/null || echo "unknown")
          local lock_timestamp=$(cat "$lock_dir/timestamp" 2>/dev/null || echo "unknown")
          
          echo "🔒 ACTIVE LOCK DETECTED"
          echo "   Process ID: $lock_pid"
          echo "   Created: $lock_timestamp"
          
          if [[ "$lock_pid" != "unknown" ]]; then
              if kill -0 "$lock_pid" 2>/dev/null; then
                  echo "   Status: ✅ Process is running"
                  echo
                  echo "📋 RECOMMENDED ACTIONS:"
                  echo "   1. Wait for the running operation to complete"
                  echo "   2. Check if process $lock_pid is stuck: ps -p $lock_pid -o pid,etime,comm"
                  echo "   3. If stuck, terminate process: kill $lock_pid"
                  echo "   4. If terminated, retry your operation immediately"
              else
                  echo "   Status: ❌ Process is dead (STALE LOCK DETECTED)"
                  echo
                  echo "🚨 STALE LOCK RECOVERY:"
                  echo "   The lock is held by a dead process. This should be cleaned up automatically."
                  echo
                  echo "📋 RECOMMENDED ACTIONS:"
                  echo "   1. Retry your operation (stale locks are cleaned up automatically)"  
                  echo "   2. If problem persists, run: ./src/task-queue.sh lock cleanup"
                  echo "   3. For emergency unlock: ./src/task-queue.sh lock force-unlock"
              fi
          else
              echo "   Status: ❓ Invalid lock (no PID)"
              echo
              echo "📋 RECOMMENDED ACTIONS:"
              echo "   1. Run: ./src/task-queue.sh lock cleanup"
              echo "   2. Retry your operation"
          fi
      else
          echo "🚨 UNKNOWN LOCK FAILURE"
          echo "   No active lock detected, but acquisition failed"
          echo
          echo "📋 POSSIBLE CAUSES:"
          echo "   1. Permission issues with queue directory"
          echo "   2. Disk space exhaustion" 
          echo "   3. File system errors"
          echo "   4. High system load causing timeouts"
          echo
          echo "📋 RECOMMENDED ACTIONS:"
          echo "   1. Check disk space: df -h $PROJECT_ROOT"
          echo "   2. Check permissions: ls -ld $PROJECT_ROOT/$TASK_QUEUE_DIR"
          echo "   3. Check system load: uptime"
          echo "   4. Retry operation with higher timeout"
      fi
      
      echo
      echo "🔧 SUPPORT COMMANDS:"
      echo "   ./src/task-queue.sh lock status      - Show lock status"
      echo "   ./src/task-queue.sh lock health      - System health check"
      echo "   ./src/task-queue.sh lock cleanup     - Clean stale locks"
      echo "   ./src/task-queue.sh lock force-unlock - Emergency unlock"
  }
  ```

#### Schritt 5: Automatic Periodic Cleanup Background Process
- [ ] **Background Stale Lock Monitor**
  ```bash
  # Periodic cleanup function (called from hybrid-monitor.sh or as standalone)
  periodic_stale_lock_cleanup() {
      local cleanup_interval_minutes="${1:-5}"  # Default: every 5 minutes
      local max_lock_age_minutes="${2:-15}"     # Default: locks older than 15 minutes
      
      while true; do
          log_debug "Starting periodic stale lock cleanup cycle"
          
          # Cleanup main queue locks
          local main_lock_dir="$PROJECT_ROOT/$TASK_QUEUE_DIR/.queue.lock.d"
          if [[ -d "$main_lock_dir" ]]; then
              local lock_timestamp=$(cat "$main_lock_dir/timestamp" 2>/dev/null || echo "")
              if [[ -n "$lock_timestamp" ]]; then
                  local current_time=$(date +%s)
                  local lock_time=$(date -d "$lock_timestamp" +%s 2>/dev/null || echo 0)
                  local age_minutes=$(((current_time - lock_time) / 60))
                  
                  if [[ $age_minutes -gt $max_lock_age_minutes ]]; then
                      log_info "Periodic cleanup: Removing aged lock ($age_minutes minutes old)"
                      cleanup_stale_lock_aggressive "$main_lock_dir" false
                  fi
              fi
          fi
          
          # Cleanup typed locks
          cleanup_all_typed_locks
          
          # Update cleanup metrics
          log_debug "Periodic cleanup cycle completed, sleeping ${cleanup_interval_minutes}m"
          sleep $((cleanup_interval_minutes * 60))
      done
  }
  
  # Integration with hybrid-monitor.sh
  start_periodic_cleanup_monitor() {
      if [[ "${ENABLE_PERIODIC_CLEANUP:-true}" == "true" ]]; then
          log_info "Starting periodic stale lock cleanup monitor"
          periodic_stale_lock_cleanup 5 15 &  # 5min interval, 15min max age
          echo $! > "$PROJECT_ROOT/logs/cleanup-monitor.pid"
      fi
  }
  ```

### Phase 3: Testing & Validation (Tag 3-4)

#### Schritt 6: Comprehensive Stale Lock Testing Framework  
- [ ] **Stale Lock Test Suite**
  ```bash
  # tests/integration/test-stale-lock-recovery.bats
  
  @test "stale lock cleanup - dead process detection" {
      # Create artificial stale lock
      create_fake_stale_lock "99999"  # Non-existent PID
      
      # Verify lock exists and blocks operations
      run ./src/task-queue.sh status
      [ "$status" -eq 1 ]
      [[ "$output" =~ "Failed to acquire" ]]
      
      # Attempt operation - should auto-cleanup and succeed
      run ./src/task-queue.sh add custom 1 "Test task"
      [ "$status" -eq 0 ]
      
      # Verify lock was cleaned up
      [ ! -d "$PROJECT_ROOT/$TASK_QUEUE_DIR/.queue.lock.d" ]
  }
  
  @test "stale lock cleanup - age-based timeout" {
      # Create old lock (simulate by manipulating timestamp)
      create_fake_old_lock "20 minutes ago"
      
      # Should be cleaned up automatically
      run ./src/task-queue.sh status  
      [ "$status" -eq 0 ]
      
      # Lock should be gone
      [ ! -d "$PROJECT_ROOT/$TASK_QUEUE_DIR/.queue.lock.d" ]
  }
  
  @test "force unlock command functionality" {
      # Create artificial lock
      create_fake_stale_lock "99999"
      
      # Force unlock should work
      run ./src/task-queue.sh lock force-unlock
      [ "$status" -eq 0 ]
      [[ "$output" =~ "unlocked successfully" ]]
      
      # Queue should be functional
      run ./src/task-queue.sh status
      [ "$status" -eq 0 ]
  }
  
  @test "diagnostic commands provide useful information" {
      create_fake_stale_lock "99999"
      
      # Lock status should show details
      run ./src/task-queue.sh lock status
      [ "$status" -eq 0 ]
      [[ "$output" =~ "99999" ]]
      [[ "$output" =~ "Process is dead" ]]
      
      # Health check should identify problems
      run ./src/task-queue.sh lock health
      [ "$status" -eq 1 ]  # Should fail due to stale lock
      [[ "$output" =~ "Invalid main lock detected" ]]
  }
  
  create_fake_stale_lock() {
      local fake_pid="$1"
      local lock_dir="$PROJECT_ROOT/$TASK_QUEUE_DIR/.queue.lock.d"
      
      mkdir -p "$lock_dir"
      echo "$fake_pid" > "$lock_dir/pid"
      echo "$(date -Iseconds)" > "$lock_dir/timestamp"
      echo "$HOSTNAME" > "$lock_dir/hostname"
      echo "fake_operation" > "$lock_dir/operation"
      echo "$USER" > "$lock_dir/user"
  }
  
  create_fake_old_lock() {
      local age_description="$1"
      local lock_dir="$PROJECT_ROOT/$TASK_QUEUE_DIR/.queue.lock.d"
      
      mkdir -p "$lock_dir"
      echo "$$" > "$lock_dir/pid"
      echo "$(date -d "$age_description" -Iseconds 2>/dev/null || date -Iseconds)" > "$lock_dir/timestamp"
      echo "$HOSTNAME" > "$lock_dir/hostname"
      echo "old_operation" > "$lock_dir/operation"
      echo "$USER" > "$lock_dir/user"
  }
  ```

#### Schritt 7: Performance Impact Validation
- [ ] **Lock Performance Benchmarking**
  ```bash
  benchmark_lock_performance_with_cleanup() {
      local operations_count=${1:-100}
      local concurrent_workers=${2:-5}
      
      echo "Benchmarking lock performance with enhanced stale lock cleanup"
      echo "Operations: $operations_count, Workers: $concurrent_workers"
      
      local start_time=$(date +%s.%N)
      local success_count=0
      local failure_count=0
      
      for ((worker=1; worker<=concurrent_workers; worker++)); do
          (
              for ((op=1; op<=operations_count; op++)); do
                  local op_start=$(date +%s.%N)
                  
                  if ./src/task-queue.sh add custom $RANDOM "Benchmark task $worker-$op" >/dev/null 2>&1; then
                      echo "SUCCESS,$worker,$op,$(echo "$(date +%s.%N) - $op_start" | bc -l)" >> /tmp/benchmark_results.csv
                  else
                      echo "FAILURE,$worker,$op,$(echo "$(date +%s.%N) - $op_start" | bc -l)" >> /tmp/benchmark_results.csv
                  fi
                  
                  # Small delay to simulate realistic usage
                  sleep 0.01
              done
          ) &
      done
      
      wait
      
      local end_time=$(date +%s.%N)
      local total_time=$(echo "$end_time - $start_time" | bc -l)
      
      # Analyze results
      local success_ops=$(grep -c "^SUCCESS" /tmp/benchmark_results.csv 2>/dev/null || echo 0)
      local failure_ops=$(grep -c "^FAILURE" /tmp/benchmark_results.csv 2>/dev/null || echo 0)
      local total_ops=$((success_ops + failure_ops))
      
      echo "=== PERFORMANCE BENCHMARK RESULTS ==="
      echo "Total time: ${total_time}s"
      echo "Total operations: $total_ops"
      echo "Successful operations: $success_ops"
      echo "Failed operations: $failure_ops" 
      echo "Success rate: $(echo "scale=2; $success_ops * 100 / $total_ops" | bc -l)%"
      echo "Average operation time: $(echo "scale=3; $total_time / $total_ops" | bc -l)s"
      echo "Operations per second: $(echo "scale=2; $total_ops / $total_time" | bc -l)"
      
      # Validate performance criteria
      local success_rate=$(echo "scale=2; $success_ops * 100 / $total_ops" | bc -l)
      if (( $(echo "$success_rate >= 99.0" | bc -l) )); then
          echo "✅ Performance criteria met (≥99% success rate)"
          return 0
      else
          echo "❌ Performance criteria failed (<99% success rate)"
          return 1
      fi
  }
  ```

### Phase 4: Integration & Documentation (Tag 4-5)

#### Schritt 8: Integration mit bestehenden Lock Commands
- [ ] **Enhanced Lock CLI Integration**
  ```bash
  # Update existing lock management commands in src/task-queue.sh
  
  case "$1" in
      "lock")
          case "$2" in
              "status")
                  show_lock_status_cmd
                  ;;
              "cleanup")
                  echo "Cleaning up stale locks with enhanced detection..."
                  cleanup_all_stale_locks
                  cleanup_all_typed_locks
                  echo "✅ Stale lock cleanup completed"
                  ;;
              "health")
                  lock_health_check_cmd
                  ;;
              "force-unlock"|"unlock")
                  force_unlock_queue_cmd
                  ;;
              "diagnostic"|"diag")
                  show_lock_diagnostic_info "$PROJECT_ROOT/$TASK_QUEUE_DIR/.queue.lock.d"
                  ;;
              "benchmark")
                  benchmark_lock_performance_with_cleanup "${3:-50}" "${4:-3}"
                  ;;
              *)
                  echo "Usage: $0 lock [status|cleanup|health|force-unlock|diagnostic|benchmark]"
                  echo "  status       - Show current lock status with detailed information"
                  echo "  cleanup      - Clean up stale locks (enhanced detection)"  
                  echo "  health       - Check lock system health"
                  echo "  force-unlock - Emergency unlock (removes any locks)"
                  echo "  diagnostic   - Show detailed diagnostic information"
                  echo "  benchmark    - Run lock performance benchmark"
                  exit 1
                  ;;
          esac
          ;;
  esac
  ```

#### Schritt 9: Documentation Updates
- [ ] **User Documentation für Lock Management**
  ```markdown
  # Lock Management Troubleshooting Guide
  
  ## Problem: "Failed to acquire atomic queue lock"
  
  ### Quick Resolution:
  ```bash
  # Check lock status
  ./src/task-queue.sh lock status
  
  # Clean up stale locks
  ./src/task-queue.sh lock cleanup
  
  # If problem persists, force unlock (use with caution)
  ./src/task-queue.sh lock force-unlock
  ```
  
  ### Detailed Diagnosis:
  ```bash
  # Full system health check
  ./src/task-queue.sh lock health
  
  # Detailed diagnostic information
  ./src/task-queue.sh lock diagnostic
  
  # Performance benchmark
  ./src/task-queue.sh lock benchmark
  ```
  
  ### Common Scenarios:
  
  1. **Dead Process Lock**: Automatically cleaned up on next operation
  2. **Long-Running Operation**: Wait for completion or check process status
  3. **System Crash Recovery**: Use `lock cleanup` to remove stale locks
  4. **Permission Issues**: Check directory ownership and permissions
  5. **Emergency Situations**: Use `lock force-unlock` as last resort
  
  ### Prevention:
  - Regular system maintenance with `lock cleanup`
  - Monitor system load and disk space
  - Proper process termination (avoid kill -9 when possible)
  ```

## Fortschrittsnotizen

**2025-08-28**: Initial Analysis Completed
- GitHub Issue #71 analyzed with concrete evidence of stale lock problem (PID 7408)
- Current lock system implementation reviewed - robust framework exists but needs enhanced stale detection
- Root cause identified: Incomplete integration of existing stale lock cleanup functions
- Specific failure modes documented: Race conditions in cleanup, insufficient recovery attempts, missing emergency commands
- Prior art analysis shows successful Enhanced Directory-Based Locking from Issue #47 provides solid foundation

**Immediate Impact Assessment**:
- **High Priority**: All write operations currently blocked (add, remove, clear, batch operations)
- **User Experience**: Frustrating "Failed to acquire lock" messages with no clear resolution path
- **System Reliability**: Queue system non-functional for state changes
- **Business Impact**: Development workflow completely blocked until resolution

## Ressourcen & Referenzen

- **GitHub Issue #71**: Task Queue Lock Management - Stale lock handling needs improvement
- **Prior Implementation**: `scratchpads/completed/2025-08-25_enhance-file-locking-robustness.md` - Successful Phase 1&2 Enhanced Directory-Based Locking
- **Current Lock System**: `src/task-queue.sh` lines 212-1034 - Enhanced locking with atomic directory operations
- **Existing Commands**: `./src/task-queue.sh lock [status|cleanup|health]` - Basic lock management already available
- **Test Framework**: `tests/unit/test-task-queue.bats` - Base for enhanced stale lock testing

## Abschluss-Checkliste

- [ ] **Enhanced Stale Lock Detection & Cleanup (Phase 1)**
  - [ ] Aggressive multi-pass cleanup strategy with force cleanup option
  - [ ] Enhanced lock acquisition with escalated recovery phases (3-phase approach)
  - [ ] Multi-criteria validation: dead process, age timeout, cross-host safety
  - [ ] Emergency force cleanup for persistent stale locks

- [ ] **User-Friendly Error Recovery & Commands (Phase 2)**
  - [ ] Emergency unlock commands für manual intervention (`lock force-unlock`)
  - [ ] Enhanced error messages mit specific recovery instructions
  - [ ] Diagnostic commands für detailed lock state analysis (`lock diagnostic`)
  - [ ] Background periodic cleanup monitor integration

- [ ] **Testing & Validation (Phase 3)**
  - [ ] Comprehensive stale lock recovery test suite
  - [ ] Performance benchmarking mit concurrent operations
  - [ ] Dead process detection and cleanup testing
  - [ ] Age-based timeout and force unlock testing
  - [ ] Success rate validation (≥99% target maintained)

- [ ] **Integration & Documentation (Phase 4)**
  - [ ] Integration mit existing lock management commands
  - [ ] User documentation für troubleshooting and recovery procedures  
  - [ ] Performance impact analysis and optimization
  - [ ] CLI help text and error message improvements

## Testing Strategy

### Manual Testing Checklist

1. **Reproduce Current Issue**:
   ```bash
   # Verify current stale lock blocks operations
   ./src/task-queue.sh clear  # Should fail with lock error
   ```

2. **Test Stale Lock Detection**:
   ```bash
   # Verify PID 7408 detection and cleanup
   ./src/task-queue.sh lock status  # Should show dead process
   ./src/task-queue.sh lock cleanup # Should remove stale lock
   ```

3. **Test Emergency Recovery**:
   ```bash
   # Create artificial lock and test force unlock
   ./src/task-queue.sh lock force-unlock  # Should remove any lock
   ./src/task-queue.sh clear # Should now work
   ```

4. **Test Normal Operations**:
   ```bash
   # Verify all write operations work after fix
   ./src/task-queue.sh add custom 1 "Test task"
   ./src/task-queue.sh status
   ./src/task-queue.sh clear
   ```

### Automated Testing Goals

- **Stale Lock Recovery**: 100% success rate for dead process detection
- **Age-Based Cleanup**: Locks older than timeout threshold cleaned automatically  
- **Emergency Commands**: Force unlock works in all scenarios
- **Performance**: No degradation in normal operation performance
- **Concurrent Safety**: Multiple operations don't create race conditions

## Success Metrics

- **Functional**: All write operations work without manual intervention
- **Reliability**: Stale locks cleaned up automatically within 1 retry attempt
- **Usability**: Clear error messages guide users to resolution
- **Performance**: <2s average operation time maintained (from Issue #47)
- **Recovery**: Emergency unlock provides 100% reliable fallback

---
**Status**: Aktiv - Detaillierte Implementierung geplant für sofortige Umsetzung
**Zuletzt aktualisiert**: 2025-08-28
**Implementierung Priority**: CRITICAL - Blockiert alle Queue Write-Operationen