# Core Live Functionality Focus

**Erstellt**: 2025-09-12
**Typ**: Critical Core Enhancement
**Geschätzter Aufwand**: Mittel
**Verwandtes Issue**: Focus on main functionality - live operation readiness

## Kontext & Ziel

FOCUS: Get the Claude Auto-Resume system working LIVE for real task automation. We have 18 pending tasks waiting to be processed. The emphasis is on **core functionality that works live** - nothing that isn't necessary for live operation matters right now.

**Current Status**: 
- 18 pending tasks in queue ready for processing
- Multiple tmux sessions already running (safe existing environment)
- Core infrastructure exists but needs focused enhancement for live reliability
- Usage limit detection exists but needs robustness for real pm/am scenarios
- System needs to handle automation without manual intervention

**Key Requirement**: Test in NEW tmux sessions, don't kill existing ones. Focus on what makes the core automation work reliably.

## Anforderungen

**ESSENTIAL (Must work live):**
- [ ] Robust pm/am usage limit detection that catches real Claude CLI responses
- [ ] Automatic task processing of all 18 pending tasks without manual intervention
- [ ] Reliable recovery after usage limit waits (until xpm/am works correctly)
- [ ] Safe testing in isolated tmux session without disrupting existing sessions
- [ ] Live monitoring that shows progress and handles errors gracefully

**NOT ESSENTIAL (Skip for now):**
- ❌ Perfect UI/UX enhancements
- ❌ Comprehensive logging improvements (basic is fine)  
- ❌ Advanced error handling beyond core needs
- ❌ Documentation updates (existing docs are sufficient)
- ❌ New features not directly related to task automation

## Untersuchung & Analyse

### Current System Analysis

**What Works (Build on this):**
- ✅ Task queue with 18 pending tasks ready to process
- ✅ Basic usage limit detection patterns exist in `usage-limit-recovery.sh`
- ✅ Session management with tmux/claunch integration
- ✅ Core monitoring loop in `hybrid-monitor.sh` (2097 lines)
- ✅ Safe session creation capabilities

**Critical Gaps (Fix these only):**
- ⚠️ **pm/am Pattern Recognition**: Needs real-world robustness for "blocked until 3pm" scenarios
- ⚠️ **Wait Time Calculation**: Smart same-day vs next-day detection for usage limits  
- ⚠️ **Task Automation Loop**: Process tasks with automatic usage limit handling
- ⚠️ **Live Operation Testing**: Validate extended runtime without manual intervention

### Real-World Usage Limit Scenarios

From the existing `extract_usage_limit_time_enhanced()` function, current patterns include:
```bash
"blocked until ([0-9]{1,2})\s*(am|pm)"
"try again at ([0-9]{1,2})\s*(am|pm)"
```

**Missing Real-World Cases**:
- "blocked until 3pm" → Should wait until 3pm today or tomorrow
- "try again at 11am" → Should determine if it's today's 11am or tomorrow's 11am  
- "available at 5pm" → Common variation
- "come back at 2am" → Edge case for early morning times

## Implementierungsplan

### Schritt 1: Test Current System with 18 Pending Tasks
**Priorität**: FIRST - Validate current capabilities

- [ ] Create new isolated tmux session for testing: `tmux new-session -d -s claude-live-test-$(date +%s)`
- [ ] Run current hybrid-monitor in test session: `./src/hybrid-monitor.sh --queue-mode --continuous --debug`
- [ ] Monitor task processing for 15-30 minutes to identify specific failure points
- [ ] Document exactly where and how usage limit detection fails in practice

### Schritt 2: Enhance pm/am Pattern Detection (ONLY Critical Fixes)
**Priorität**: CRITICAL - Focus on most common failure patterns

#### 2.1 Add Missing Common Patterns
```bash
# Add to extract_usage_limit_time_enhanced() in usage-limit-recovery.sh
"available at ([0-9]{1,2})\s*(am|pm)"
"available at ([0-9]{1,2}):([0-9]{2})\s*(am|pm)"  
"come back at ([0-9]{1,2})\s*(am|pm)"
"limit resets at ([0-9]{1,2})\s*(am|pm)"
"usage limit.*until ([0-9]{1,2})\s*(am|pm)"
```

#### 2.2 Fix Same-Day/Next-Day Logic  
```bash
# In calculate_wait_until_time_enhanced() - Fix the core time calculation bug
determine_target_day() {
    local target_hour_24="$1"
    local current_hour=$(date +%H)
    
    # If target time has already passed today, it means tomorrow
    if [[ $target_hour_24 -le $current_hour ]]; then
        echo "tomorrow"
    else
        echo "today"  
    fi
}
```

### Schritt 3: Automated Task Processing Loop
**Priorität**: ESSENTIAL - Core automation functionality

#### 3.1 Enhanced Task Execution with Usage Limit Handling
```bash
# Add to hybrid-monitor.sh - process_task_queue() function
process_tasks_with_live_usage_handling() {
    local total_tasks=$(./src/task-queue.sh status | jq -r '.pending')
    local processed=0
    
    log_info "Starting live task processing: $total_tasks tasks pending"
    
    while [[ $processed -lt $total_tasks ]]; do
        # Get next task
        local task_result
        if task_result=$(execute_next_pending_task); then
            ((processed++))
            log_info "✅ Task $processed/$total_tasks completed"
        else
            local exit_code=$?
            if [[ $exit_code -eq 42 ]]; then
                # Usage limit detected - handle and continue
                log_info "⏰ Usage limit detected - handling automatically"
                handle_usage_limit_wait_live
                # Continue with same task after wait
                continue
            else  
                log_error "❌ Task failed with exit code $exit_code"
                ((processed++))  # Count as processed to avoid infinite loop
            fi
        fi
    done
}
```

#### 3.2 Live Usage Limit Wait with Progress
```bash
# Add simple countdown functionality
display_usage_limit_countdown() {
    local wait_seconds="$1"
    local reason="${2:-usage limit detected}"
    
    log_info "Usage limit: $reason - waiting ${wait_seconds}s"
    
    # Simple countdown every 60 seconds  
    local remaining=$wait_seconds
    while [[ $remaining -gt 0 ]]; do
        local hours=$((remaining / 3600))
        local minutes=$(((remaining % 3600) / 60))
        
        if [[ $((remaining % 60)) -eq 0 ]]; then  # Log every minute
            log_info "⏰ Usage limit expires in ${hours}h ${minutes}m"
        fi
        
        sleep 60
        ((remaining -= 60))
    done
    
    log_info "✅ Usage limit expired - resuming task processing"
}
```

### Schritt 4: Live Operation Validation
**Priorität**: DEPLOYMENT - Prove it works end-to-end

- [ ] **30-Minute Live Test**: Create isolated test session, start processing, monitor for 30 minutes
- [ ] **Usage Limit Simulation**: Manually trigger usage limit scenarios to validate pm/am detection
- [ ] **Task Completion Validation**: Verify all 18 tasks can be processed without intervention
- [ ] **Resource Monitoring**: Ensure no memory leaks during extended operation

### Schritt 5: Simple Activation Script (if time permits)
**Priorität**: NICE TO HAVE - Only if core functionality is rock solid

```bash
#!/bin/bash
# start-live-operation.sh - Simple activation
echo "🚀 Starting Claude Auto-Resume Live Operation"

# Check prerequisites
if ! command -v tmux >/dev/null; then
    echo "❌ tmux required but not found"
    exit 1
fi

# Start in new session
SESSION="claude-live-$(date +%s)"
tmux new-session -d -s "$SESSION" "./src/hybrid-monitor.sh --queue-mode --continuous --debug"

echo "✅ Started in session: $SESSION"
echo "📊 Monitor: tmux attach -t $SESSION"
echo "🛑 Stop: tmux kill-session -t $SESSION"
```

## Fortschrittsnotizen

**2025-09-12 - Initial Analysis Complete**:
- ✅ **Current State**: 18 pending tasks ready for processing, multiple monitoring sessions active
- ✅ **Core Infrastructure**: Exists and functional, needs focused enhancements only
- ✅ **Priority Identified**: pm/am detection robustness and automated task processing
- 🎯 **Next Action**: Test current system with 18 tasks to identify specific failure points

**Testing Protocol**:
- Test in `claude-live-test-$(date +%s)` session - isolated, safe
- Monitor existing sessions: `tmux list-sessions | grep claude`  
- Verify no disruption to existing work
- Focus on documenting specific failure patterns for targeted fixes

**Development Approach**:
- Enhance existing components, don't rebuild
- Fix only critical issues that prevent live operation
- Validate each enhancement with real task processing
- Keep changes minimal and focused

## Ressourcen & Referenzen

### Core Files for Enhancement
- `src/usage-limit-recovery.sh` (100 lines) - Primary target for pm/am pattern fixes
- `src/hybrid-monitor.sh` (2097 lines) - Task processing integration
- `src/task-queue.sh` - 18 pending tasks for testing

### Critical Functions to Enhance
```bash
# In usage-limit-recovery.sh
extract_usage_limit_time_enhanced()    # Add missing patterns
calculate_wait_until_time_enhanced()   # Fix same-day/next-day logic

# In hybrid-monitor.sh  
process_task_queue()                   # Add usage limit integration
handle_usage_limit_scenario()         # Enhance wait handling
```

### Live Operation Commands
```bash
# Test current system
tmux new-session -d -s claude-live-test-$(date +%s)
./src/hybrid-monitor.sh --queue-mode --continuous --debug

# Check progress
./src/task-queue.sh status
tmux list-sessions | grep claude

# Monitor resource usage
ps aux | grep hybrid-monitor
```

### Safe Testing Environment
- **New Sessions Only**: `claude-live-test-$(date +%s)` pattern
- **Existing Sessions**: Preserve `claude-auto-*`, `claude-test*` sessions  
- **Monitoring**: `tmux list-sessions` before and after testing
- **Cleanup**: `tmux kill-session -t [test-session-name]` when done

## Abschluss-Checkliste

**Core Live Functionality (MUST HAVE)**:
- [ ] Enhanced pm/am pattern detection handles real Claude CLI responses
- [ ] Same-day vs next-day calculation works correctly for all times
- [ ] Automated processing of all 18 pending tasks without intervention
- [ ] Usage limit recovery with automatic resumption works reliably
- [ ] Extended runtime validation (30+ minutes) successful

**Safety & Testing (CRITICAL)**:
- [ ] All testing done in isolated new tmux sessions
- [ ] No disruption to existing claude-auto-*, claude-test* sessions
- [ ] Resource usage monitored and controlled
- [ ] Clear activation procedure documented

**Nice to Have (OPTIONAL)**:
- [ ] Simple start-live-operation.sh script
- [ ] Enhanced progress logging
- [ ] Resource monitoring alerts

---
**Status**: Aktiv
**Zuletzt aktualisiert**: 2025-09-12  
**Priorität**: KRITISCH - Focus on core live functionality only
**Nächster Agent**: creator - Implement focused enhancements for live operation reliability