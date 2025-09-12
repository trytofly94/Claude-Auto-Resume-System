# Core Automation Live Operation - Consolidated Implementation Plan

**Created**: 2025-09-12
**Type**: Critical Core Enhancement  
**Estimated Effort**: Medium
**Related Issue**: Focus on live automation functionality - process 18 pending tasks reliably

## Context & Goal

**MISSION**: Make the Claude Auto-Resume system work reliably in live operation to process the 18 pending tasks without manual intervention. The system infrastructure exists but needs focused robustness improvements for real-world usage limit scenarios.

**Current Status Analysis**:
- ✅ **18 pending tasks** ready for processing (confirmed via `task-queue.sh status`)
- ✅ **Core infrastructure** exists: hybrid-monitor.sh, usage-limit-recovery.sh, task-queue.sh
- ✅ **Multiple tmux sessions** running safely (8 existing claude-* sessions) 
- ✅ **Basic usage limit detection** implemented in extract_usage_limit_time_enhanced()
- ⚠️ **Usage limit patterns** need real-world robustness for pm/am scenarios
- ⚠️ **Live automation loop** needs integration with enhanced usage limit handling
- ⚠️ **Extended operation** requires validation for unattended runtime

**User Requirements**:
- Focus ONLY on main functionality - nothing unnecessary for live operation
- Core priority: Automate tasks and detect/handle program blocks until usage limits (xpm/am)
- Test in new tmux session (don't kill existing tmux servers)
- Don't create new issues unless unavoidable bugs are found

## Requirements

### Phase 1: Enhanced Real-World Usage Limit Detection (CRITICAL)
- [ ] **Comprehensive pm/am Pattern Coverage** - Handle all common Claude CLI usage limit response variations
- [ ] **Smart Time Boundary Detection** - Accurate same-day vs next-day calculation for usage limits
- [ ] **Live Wait Progress Display** - Real-time countdown during usage limit wait periods
- [ ] **Error Resilience** - Graceful handling of malformed or unexpected time formats
- [ ] **Pattern Testing** - Validate against real Claude CLI responses

### Phase 2: Automated Task Processing Engine (ESSENTIAL)
- [ ] **18-Task Processing Loop** - Reliable automation of all pending tasks without intervention
- [ ] **Usage Limit Integration** - Seamless handling when tasks hit usage limits during processing
- [ ] **Progress Monitoring** - Clear visibility into task completion status and system state
- [ ] **Recovery Logic** - Intelligent retry and continuation after usage limit waits
- [ ] **Session Safety** - Process in isolated tmux session without disrupting existing work

### Phase 3: Live Operation Validation (DEPLOYMENT-READY)
- [ ] **Extended Runtime Testing** - 30+ minute validation of unattended operation
- [ ] **Resource Management** - Monitor memory usage and prevent resource exhaustion
- [ ] **Crash Recovery** - Automatic system restart and task queue state restoration
- [ ] **Production Deployment** - Simple activation procedure for real-world use

## Investigation & Analysis

### Current System Strengths (Build On These)
**Infrastructure Components**:
- ✅ **usage-limit-recovery.sh**: 150+ lines with comprehensive pattern matching framework
- ✅ **hybrid-monitor.sh**: 2097 lines with main orchestration logic
- ✅ **task-queue.sh**: Working queue management with 18 pending tasks
- ✅ **tmux Integration**: Safe session management (8 existing sessions preserved)

**Working Features**:
- ✅ **Basic pm/am Detection**: Patterns for "blocked until Xpm" exist in extract_usage_limit_time_enhanced()
- ✅ **Queue Processing**: Core loop exists in hybrid-monitor.sh 
- ✅ **Session Management**: Robust claunch/tmux integration
- ✅ **Logging Infrastructure**: Structured logging with debug/info/warn/error levels

### Critical Gaps (Focus Areas)
**Usage Limit Detection Robustness**:
- Current patterns cover basic cases but miss variations like:
  - "available at 3pm" vs "blocked until 3pm" 
  - "come back at 11am" vs "try again at 11am"
  - "limit resets at 2am" (early morning edge case)
  - Mixed time formats: "3pm" vs "15:00" vs "3:30pm"

**Time Calculation Logic**:
- Same-day vs next-day determination needs improvement
- Current time: 2pm, blocked until "3pm" = wait 1 hour (same day)
- Current time: 11pm, blocked until "9am" = wait 10 hours (next day)  
- Edge case: Current time: 1am, blocked until "2am" = wait 1 hour (same day)

**Live Operation Integration**:
- Task processing loop exists but lacks tight integration with enhanced usage limit handling
- No live progress display during long usage limit waits
- Limited validation of extended unattended operation

### Prior Art Analysis
**Related Active Scratchpads**:
- `2025-09-11_core-automation-priority-implementation.md` - Comprehensive analysis, similar goals
- `2025-09-12_core-live-functionality-focus.md` - Focus on live operation, 18 tasks
- `2025-09-11_core-automation-usage-limit-enhancement.md` - Usage limit specific improvements

**Key Insights from Prior Work**:
- Multiple attempts at similar improvements indicate this is the right priority
- User consistently emphasizes "core functionality only" - no unnecessary features
- Testing safety is critical - use isolated tmux sessions
- System architecture is sound - enhance rather than rebuild

## Implementation Plan

### Step 1: Validate Current System with 18 Tasks (BASELINE TEST)
**Priority**: CRITICAL - Understand current failure modes
**Target**: Document specific issues before implementing fixes

```bash
# 1.1 Create isolated test session
tmux new-session -d -s claude-core-test-$(date +%s) 

# 1.2 Start current system in debug mode
./src/hybrid-monitor.sh --queue-mode --continuous --debug

# 1.3 Monitor for 15-20 minutes to observe:
# - How many tasks complete successfully
# - Where usage limit detection fails
# - Specific pm/am patterns that aren't caught
# - Any system errors or resource issues

# 1.4 Document findings for targeted fixes
```

**Success Criteria**:
- [ ] Clear identification of current system behavior with 18 pending tasks
- [ ] Specific documentation of usage limit detection failures  
- [ ] Resource usage baseline established
- [ ] No disruption to existing tmux sessions confirmed

### Step 2: Enhanced Usage Limit Pattern Recognition
**Priority**: CRITICAL - Most common failure point
**Target**: src/usage-limit-recovery.sh - extract_usage_limit_time_enhanced()

#### 2.1 Expand Pattern Coverage for Real-World Scenarios
```bash
# Add to enhanced_patterns array in extract_usage_limit_time_enhanced():

# Common variations observed in Claude CLI responses
"available at ([0-9]{1,2})\s*(am|pm)"
"available at ([0-9]{1,2}):([0-9]{2})\s*(am|pm)"
"come back at ([0-9]{1,2})\s*(am|pm)"
"come back at ([0-9]{1,2}):([0-9]{2})\s*(am|pm)" 
"limit resets at ([0-9]{1,2})\s*(am|pm)"
"usage limit.*until ([0-9]{1,2})\s*(am|pm)"
"please wait until ([0-9]{1,2})\s*(am|pm)"

# Early morning edge cases (2am, 3am scenarios)
"blocked until ([0-9]{1,2})am"
"try again at ([0-9]{1,2})am"
"available at ([0-9]{1,2})am"
```

#### 2.2 Implement Smart Time Boundary Logic
```bash
# Add new function: calculate_wait_until_time_enhanced()
calculate_wait_until_time_enhanced() {
    local target_hour_12="$1"   # e.g., "3"
    local ampm="$2"             # e.g., "pm"
    local target_minutes="${3:-0}"  # e.g., "30" for 3:30pm
    
    # Convert to 24-hour format
    local target_hour_24
    if [[ "$ampm" == "am" ]]; then
        if [[ "$target_hour_12" -eq 12 ]]; then
            target_hour_24=0  # 12am = 0:00
        else
            target_hour_24="$target_hour_12"
        fi
    else  # pm
        if [[ "$target_hour_12" -eq 12 ]]; then
            target_hour_24=12  # 12pm = 12:00
        else
            target_hour_24=$((target_hour_12 + 12))
        fi
    fi
    
    # Get current time components
    local current_hour=$(date +%H)
    local current_minutes=$(date +%M)
    local current_total_minutes=$((current_hour * 60 + current_minutes))
    local target_total_minutes=$((target_hour_24 * 60 + target_minutes))
    
    # Determine if target is today or tomorrow
    local wait_minutes
    if [[ $target_total_minutes -gt $current_total_minutes ]]; then
        # Target is later today
        wait_minutes=$((target_total_minutes - current_total_minutes))
        log_debug "Target ${target_hour_12}${ampm} is later today: ${wait_minutes} minutes"
    else
        # Target is tomorrow (add 24 hours)
        wait_minutes=$((target_total_minutes + 1440 - current_total_minutes))
        log_debug "Target ${target_hour_12}${ampm} is tomorrow: ${wait_minutes} minutes"
    fi
    
    local wait_seconds=$((wait_minutes * 60))
    echo "$wait_seconds"
}
```

#### 2.3 Add Pattern Testing Function
```bash
# Add testing function for pattern validation
test_usage_limit_patterns() {
    local test_cases=(
        "blocked until 3pm"
        "try again at 11am"  
        "available at 4:30pm"
        "come back at 2am"
        "limit resets at 9am"
        "usage limit reached, blocked until 5pm"
    )
    
    echo "Testing usage limit pattern recognition:"
    for test_case in "${test_cases[@]}"; do
        echo "Testing: '$test_case'"
        if result=$(extract_usage_limit_time_enhanced "$test_case"); then
            echo "  ✅ Detected: ${result}s wait time"
        else
            echo "  ❌ Failed to detect usage limit"
        fi
        echo ""
    done
}

# Usage: ./src/usage-limit-recovery.sh test-patterns
```

### Step 3: Integrate Enhanced Detection with Task Processing
**Priority**: ESSENTIAL - Core automation functionality  
**Target**: src/hybrid-monitor.sh - main task processing loop

#### 3.1 Enhanced Task Processing with Live Usage Limit Handling
```bash
# Enhance process_task_queue() function in hybrid-monitor.sh:
process_task_queue_with_live_limits() {
    local total_tasks=$(./src/task-queue.sh status | jq -r '.pending')
    local processed=0
    local usage_limit_encounters=0
    
    log_info "🚀 Starting live task processing: $total_tasks tasks pending"
    
    while [[ $processed -lt $total_tasks ]]; do
        log_info "📋 Processing task $((processed + 1))/$total_tasks"
        
        # Execute next pending task
        local task_output
        local task_exit_code=0
        if ! task_output=$(execute_next_pending_task 2>&1); then
            task_exit_code=$?
        fi
        
        # Check for usage limit in task output
        if [[ $task_exit_code -ne 0 ]] && detect_usage_limit_in_output "$task_output"; then
            ((usage_limit_encounters++))
            log_warn "⏰ Usage limit detected (encounter #$usage_limit_encounters)"
            log_info "Task output that triggered detection: $(echo "$task_output" | head -3)"
            
            # Use enhanced usage limit handling
            if wait_time=$(extract_usage_limit_time_enhanced "$task_output"); then
                log_info "⏳ Enhanced usage limit detection successful: ${wait_time}s wait"
                display_usage_limit_countdown "$wait_time" "usage limit (enhanced detection)"
            else
                log_warn "⏳ Falling back to standard usage limit handling"
                handle_usage_limit_scenario "$task_output"
            fi
            
            # Don't increment processed count - retry the same task
            continue
        else
            # Task completed successfully
            ((processed++))
            log_info "✅ Task $processed/$total_tasks completed successfully"
        fi
        
        # Brief pause between tasks to prevent overwhelming system
        sleep 2
    done
    
    log_info "🎉 Task processing complete: $processed/$total_tasks tasks processed"
    log_info "📊 Usage limit encounters: $usage_limit_encounters"
}
```

#### 3.2 Live Progress Display During Usage Limit Waits
```bash
# Add countdown display function to hybrid-monitor.sh:
display_usage_limit_countdown() {
    local wait_seconds="$1"
    local reason="${2:-usage limit detected}"
    
    log_info "⏰ $reason - waiting ${wait_seconds} seconds"
    log_info "⏰ This will complete at $(date -d "+${wait_seconds} seconds" "+%I:%M:%S %p")"
    
    # Display countdown every 60 seconds for waits > 5 minutes
    if [[ $wait_seconds -gt 300 ]]; then
        local remaining=$wait_seconds
        while [[ $remaining -gt 0 ]]; do
            local hours=$((remaining / 3600))
            local minutes=$(((remaining % 3600) / 60))
            local seconds=$((remaining % 60))
            
            # Log progress every minute
            if [[ $((remaining % 60)) -eq 0 ]]; then
                if [[ $hours -gt 0 ]]; then
                    log_info "⏳ Usage limit expires in ${hours}h ${minutes}m"
                else
                    log_info "⏳ Usage limit expires in ${minutes}m ${seconds}s"
                fi
            fi
            
            sleep 60
            ((remaining -= 60))
        done
    else
        # For short waits, just sleep without logging
        sleep "$wait_seconds"
    fi
    
    log_info "✅ Usage limit expired - resuming task processing"
}
```

### Step 4: Live Operation Testing & Validation
**Priority**: DEPLOYMENT-READY - Prove system reliability
**Target**: Extended runtime validation in isolated environment

#### 4.1 Comprehensive Live Operation Test
```bash
# Create test script: test-live-operation.sh
#!/bin/bash
set -euo pipefail

TEST_DURATION=${1:-1800}  # Default 30 minutes
TEST_SESSION="claude-live-validation-$(date +%s)"

echo "🧪 Starting live operation validation test"
echo "📅 Duration: ${TEST_DURATION} seconds ($(($TEST_DURATION / 60)) minutes)"
echo "🔧 Test session: $TEST_SESSION"

# Create isolated test session
tmux new-session -d -s "$TEST_SESSION"

# Start enhanced system in test session
tmux send-keys -t "$TEST_SESSION" "./src/hybrid-monitor.sh --queue-mode --continuous --debug" Enter

echo "✅ Test started in tmux session: $TEST_SESSION"
echo "📊 Monitor with: tmux attach -t $TEST_SESSION"
echo "🔍 Check progress: ./src/task-queue.sh status"
echo "⏹️  Stop test: tmux kill-session -t $TEST_SESSION"

# Monitor key metrics during test
monitor_test_metrics() {
    local start_time=$(date +%s)
    local end_time=$((start_time + TEST_DURATION))
    
    while [[ $(date +%s) -lt $end_time ]]; do
        # Log system status every 5 minutes
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        if [[ $((elapsed % 300)) -eq 0 ]]; then  # Every 5 minutes
            echo "📊 Test progress: ${elapsed}s elapsed, $(((TEST_DURATION - elapsed) / 60))m remaining"
            
            # Check task progress
            local pending_tasks=$(./src/task-queue.sh status | jq -r '.pending')
            echo "📋 Tasks remaining: $pending_tasks"
            
            # Check memory usage
            local memory_usage=$(ps aux | grep hybrid-monitor | grep -v grep | awk '{print $6}' | head -1)
            echo "💾 Memory usage: ${memory_usage}KB"
            
            # Check if session is still active
            if ! tmux has-session -t "$TEST_SESSION" 2>/dev/null; then
                echo "❌ Test session terminated unexpectedly"
                break
            fi
        fi
        
        sleep 60
    done
}

# Run monitoring in background if requested
if [[ "${MONITOR:-}" == "true" ]]; then
    monitor_test_metrics &
    echo "📈 Monitoring started (PID: $!)"
fi
```

#### 4.2 Resource Usage Monitoring
```bash
# Add system resource monitoring to hybrid-monitor.sh
monitor_system_resources() {
    local max_memory_kb=204800  # 200MB limit
    local current_memory_kb
    current_memory_kb=$(ps -o pid,rss -p $$ | tail -1 | awk '{print $2}')
    
    if [[ $current_memory_kb -gt $max_memory_kb ]]; then
        log_warn "⚠️  High memory usage detected: ${current_memory_kb}KB (limit: ${max_memory_kb}KB)"
        
        # Log top memory consumers
        ps aux --sort=-%mem | head -5 | while read -r line; do
            log_debug "Memory usage: $line"
        done
    fi
    
    # Check disk space for logs
    local log_dir="$PROJECT_ROOT/logs"
    if [[ -d "$log_dir" ]]; then
        local log_size_mb
        log_size_mb=$(du -sm "$log_dir" | cut -f1)
        if [[ $log_size_mb -gt 100 ]]; then
            log_warn "⚠️  Log directory large: ${log_size_mb}MB - consider cleanup"
        fi
    fi
}
```

### Step 5: Simple Activation Procedure 
**Priority**: DEPLOYMENT - User experience
**Target**: One-command live operation deployment

#### 5.1 Create Simple Deployment Script
```bash
# Create deploy-core-automation.sh
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "🚀 Claude Auto-Resume - Core Automation Deployment"
echo ""

# Verify prerequisites
echo "🔍 Checking prerequisites..."

if ! command -v tmux >/dev/null; then
    echo "❌ tmux is required but not installed"
    exit 1
fi

if ! command -v jq >/dev/null; then
    echo "❌ jq is required but not installed"
    exit 1
fi

if ! command -v claude >/dev/null; then
    echo "❌ Claude CLI is required but not installed"
    exit 1
fi

echo "✅ Prerequisites satisfied"

# Check task queue status
echo ""
echo "📋 Checking task queue status..."
PENDING_TASKS=$(./src/task-queue.sh status | jq -r '.pending')
echo "Tasks pending: $PENDING_TASKS"

if [[ "$PENDING_TASKS" -eq 0 ]]; then
    echo "ℹ️  No tasks pending - system ready but nothing to process"
    echo "Add tasks with: ./src/task-queue.sh add-custom 'Your task here'"
    exit 0
fi

# Create deployment session
DEPLOY_SESSION="claude-core-automation-$(date +%s)"
echo ""
echo "🔧 Starting core automation in session: $DEPLOY_SESSION"

tmux new-session -d -s "$DEPLOY_SESSION" \
    "./src/hybrid-monitor.sh --queue-mode --continuous --enhanced-usage-limits"

echo ""
echo "✅ Core automation started successfully!"
echo "📊 Monitor progress: tmux attach -t $DEPLOY_SESSION"
echo "📋 Check task status: ./src/task-queue.sh status"
echo "📜 View logs: tail -f logs/hybrid-monitor.log"
echo "⏹️  Stop system: tmux kill-session -t $DEPLOY_SESSION"
echo ""
echo "🎯 Processing $PENDING_TASKS pending tasks with enhanced usage limit detection"

# Optionally show initial progress
if [[ "${SHOW_INITIAL_PROGRESS:-true}" == "true" ]]; then
    echo ""
    echo "📈 Initial system status (first 30 seconds):"
    sleep 30
    
    REMAINING_TASKS=$(./src/task-queue.sh status | jq -r '.pending')
    if [[ "$REMAINING_TASKS" -lt "$PENDING_TASKS" ]]; then
        COMPLETED=$((PENDING_TASKS - REMAINING_TASKS))
        echo "✅ Progress: $COMPLETED tasks completed, $REMAINING_TASKS remaining"
    else
        echo "⏳ System initializing - check progress with: ./src/task-queue.sh status"
    fi
fi
```

## Progress Notes

**2025-09-12 - Comprehensive Analysis Complete**:
- ✅ **System State Verified**: 18 pending tasks confirmed, 8 existing tmux sessions preserved
- ✅ **Current Capabilities Assessed**: Core infrastructure solid, usage limit detection needs robustness
- ✅ **Prior Art Consolidated**: Multiple related scratchpads analyzed for consistent approach
- ✅ **Implementation Plan**: Focused on enhancing existing components rather than rebuilding
- 🎯 **Critical Path Identified**: Usage limit pattern recognition → Task processing integration → Live validation

**Technical Approach**:
- Enhance `extract_usage_limit_time_enhanced()` with comprehensive pm/am pattern coverage
- Add `calculate_wait_until_time_enhanced()` for smart same-day/next-day boundary detection  
- Integrate enhanced detection into `process_task_queue()` for seamless automation
- Validate with extended live operation testing in isolated tmux sessions
- Create simple deployment procedure for one-command activation

**Safety Protocol**:
- All testing in new tmux sessions with pattern `claude-*-test-$(date +%s)`
- Existing sessions preserved: claude-Claude-Auto-Resume-System, claude-auto-*, etc.
- Resource monitoring to prevent memory leaks during extended operation
- Graceful error handling and automatic recovery mechanisms

**User Requirements Alignment**:
- ✅ Focus ONLY on core functionality for live operation
- ✅ Priority on task automation and usage limit handling
- ✅ Safe testing in new tmux sessions without disrupting existing work
- ✅ No new issue creation unless critical bugs discovered

## Resources & References

### Core Components for Enhancement
- **usage-limit-recovery.sh** (150+ lines) - Primary target for pattern recognition improvements
- **hybrid-monitor.sh** (2097 lines) - Main orchestration requiring enhanced usage limit integration
- **task-queue.sh** - Current queue management (18 pending tasks for testing)

### Enhanced Usage Limit Patterns (Implementation Target)
```bash
# Comprehensive patterns for real-world Claude CLI responses:
ENHANCED_PATTERNS=(
    # Basic am/pm variations
    "blocked until ([0-9]{1,2})\s*(am|pm)"
    "available at ([0-9]{1,2})\s*(am|pm)" 
    "come back at ([0-9]{1,2})\s*(am|pm)"
    "limit resets at ([0-9]{1,2})\s*(am|pm)"
    
    # Time with minutes  
    "blocked until ([0-9]{1,2}):([0-9]{2})\s*(am|pm)"
    "try again at ([0-9]{1,2}):([0-9]{2})\s*(am|pm)"
    
    # Early morning edge cases
    "blocked until ([0-9]{1,2})am"
    "available at ([0-9]{1,2})am"
    
    # General usage limit indicators
    "usage limit.*until ([0-9]{1,2})\s*(am|pm)"
    "please wait until ([0-9]{1,2})\s*(am|pm)"
)
```

### Testing & Validation Commands
```bash
# Pattern testing
./src/usage-limit-recovery.sh test-patterns

# Live operation testing  
./test-live-operation.sh 1800  # 30-minute test

# Core automation deployment
./deploy-core-automation.sh

# System monitoring
./src/task-queue.sh status
tmux list-sessions | grep claude
ps aux | grep hybrid-monitor
```

### Safe Testing Environment
```bash
# Create isolated test session
tmux new-session -d -s claude-core-test-$(date +%s)

# Monitor without disruption
tmux list-sessions  # Before testing
./deploy-core-automation.sh  # Run deployment
tmux list-sessions  # After testing - verify no disruption

# Cleanup when done
tmux kill-session -t claude-core-test-[timestamp]
```

## Completion Checklist

### Core Functionality (MUST HAVE - Live Operation Ready)
- [ ] **Comprehensive pm/am Pattern Detection** - Handle all common Claude CLI usage limit response formats
- [ ] **Smart Time Boundary Calculation** - Accurate same-day vs next-day determination for all time scenarios  
- [ ] **Live Task Processing Integration** - Seamless automation of 18 pending tasks with usage limit handling
- [ ] **Extended Runtime Validation** - 30+ minute unattended operation testing successful
- [ ] **Resource Management** - Memory usage monitoring and leak prevention during extended operation
- [ ] **Simple Deployment** - One-command activation procedure working (`./deploy-core-automation.sh`)

### Safety & Testing (CRITICAL)
- [ ] **Isolated Testing Environment** - All tests in new tmux sessions (claude-*-test-$(date +%s) pattern)
- [ ] **Existing Session Preservation** - No disruption to 8 existing claude-* sessions
- [ ] **Pattern Validation Testing** - Comprehensive test of usage limit pattern recognition  
- [ ] **Error Recovery Testing** - System resilience to unexpected scenarios validated
- [ ] **Resource Monitoring** - Memory and disk usage tracking during extended operation

### Integration & Deployment (ESSENTIAL)
- [ ] **Enhanced Detection Integration** - usage-limit-recovery.sh improvements integrated into hybrid-monitor.sh
- [ ] **Live Progress Display** - Clear countdown and status feedback during usage limit waits
- [ ] **Task Queue Processing** - Reliable processing of all 18 pending tasks without manual intervention
- [ ] **Production Ready** - System deployable for real-world unattended operation

---
**Status**: Active
**Last Updated**: 2025-09-12
**Priority**: CRITICAL - Core automation functionality for live operation
**Next Agent**: creator - Implement enhanced usage limit detection and integrate with live task processing