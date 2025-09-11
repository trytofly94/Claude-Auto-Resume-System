# Core Automation Priority Implementation - Live Operation Focus

**Created**: 2025-09-11
**Type**: Core Functionality Enhancement
**Estimated Effort**: Medium
**Related Issue**: GitHub #154 - Improve Claude CLI usage limit detection robustness

## Context & Goal

Implement the most critical core functionality for the Claude Auto-Resume System to achieve reliable live operation with focus on:

1. **Task Automation Engine** - Robust processing of the 16 pending tasks
2. **Enhanced Usage Limit Detection** - Reliable detection when Claude is blocked until specific times (xpm/am)
3. **Live Operation Robustness** - System runs unattended without manual intervention
4. **Safe tmux Integration** - No disruption to existing sessions

**Current System State**: 16 pending tasks in queue, multiple background monitors active, core system functional but needs enhanced usage limit handling for real-world deployment.

## Requirements

### Phase 1: Enhanced Usage Limit Detection (CRITICAL)
- [ ] **Robust pm/am Pattern Detection** - Comprehensive regex patterns for various Claude CLI responses
- [ ] **Smart Timestamp Calculation** - Accurate same-day vs next-day determination
- [ ] **Live Recovery Process** - Automatic resumption after wait periods
- [ ] **Real-time Progress Display** - Clear countdown and status feedback
- [ ] **Error Resilience** - Graceful handling of malformed time strings

### Phase 2: Task Automation Engine (ESSENTIAL)
- [ ] **Automated Queue Processing** - Process all 16 pending tasks without intervention
- [ ] **Session Management Integration** - Robust claunch/tmux coordination
- [ ] **Progress Monitoring** - Real-time task execution status
- [ ] **Failure Recovery** - Intelligent retry logic for failed tasks
- [ ] **State Persistence** - Maintain progress across system restarts

### Phase 3: Live Operation Validation (DEPLOYMENT)
- [ ] **Unattended Operation Testing** - Extended runtime without manual intervention
- [ ] **Resource Management** - Prevent memory leaks and resource exhaustion
- [ ] **Crash Recovery** - Automatic restart and state restoration
- [ ] **Safe Session Isolation** - Test in new tmux sessions only
- [ ] **Simple Activation** - One-command deployment capability

## Investigation & Analysis

### Current System Analysis

**Strengths**:
- ✅ **Core Infrastructure**: hybrid-monitor.sh, task-queue.sh, and usage-limit-recovery.sh are functional
- ✅ **Task Queue**: 16 pending tasks ready for processing
- ✅ **Background Monitors**: Multiple processes running successfully
- ✅ **Module Architecture**: 11 modules loading efficiently (0μs load time)
- ✅ **Dependencies**: Claude CLI, claunch v0.0.4, tmux all operational

**Critical Areas Requiring Enhancement**:
- ⚠️ **Usage Limit Detection**: Basic patterns exist but need robustness for real-world pm/am scenarios
- ⚠️ **Task Automation**: Currently manual intervention required for queue processing
- ⚠️ **Live Operation**: Needs validation for extended unattended operation
- ⚠️ **Error Recovery**: Limited resilience to unexpected scenarios

### Prior Art Review

**Related Work**:
- Previous scratchpad: `2025-09-11_core-automation-usage-limit-enhancement.md` - Comprehensive analysis
- GitHub Issue #154: "Improve Claude CLI usage limit detection robustness"
- Multiple active scratchpads addressing core functionality issues
- Recent commits focused on array optimization and system activation

**Usage Limit Detection (Current Implementation)**:
```bash
# From src/usage-limit-recovery.sh - Existing patterns
extract_usage_limit_time_from_output() {
    local time_patterns=(
        "blocked until ([0-9]{1,2})(am|pm)"
        "try again at ([0-9]{1,2})(am|pm)"
        "available.*at ([0-9]{1,2})(am|pm)"
        # ... basic patterns exist
    )
}
```

**Gap Analysis**:
1. **Pattern Coverage**: Missing edge cases and variations in Claude CLI responses
2. **Time Calculation**: Basic logic needs timezone and date boundary handling
3. **User Experience**: No live progress feedback during wait periods
4. **Error Handling**: Limited resilience to unexpected time formats

### Technical Implementation Strategy

**Focus on Simplicity and Reliability**:
- Enhance existing components rather than rebuild
- Prioritize robustness over feature complexity
- Test in isolated environments to ensure safety
- Use proven patterns from existing codebase

## Implementation Plan

### Step 1: Enhanced Usage Limit Detection Engine
```bash
# Target: Improve src/usage-limit-recovery.sh
# Priority: CRITICAL - Required for live operation

# 1.1 Expand time pattern recognition
vim src/usage-limit-recovery.sh

# Add comprehensive patterns for Claude CLI responses:
# - "blocked until 3pm" / "blocked until 15:30"
# - "try again tomorrow at 9am"
# - "usage limit reached, available at 4:30pm"
# - "please wait until 21:00"
# - "retry in X hours" (duration-based)
```

**Enhanced Pattern Implementation**:
```bash
# Comprehensive time patterns to add:
ENHANCED_TIME_PATTERNS=(
    # Basic am/pm formats
    "blocked until ([0-9]{1,2})(am|pm)"
    "blocked until ([0-9]{1,2}):([0-9]{2})(am|pm)"
    
    # Tomorrow/next-day patterns
    "tomorrow at ([0-9]{1,2})(am|pm)"
    "available tomorrow at ([0-9]{1,2}):([0-9]{2})(am|pm)"
    
    # 24-hour formats
    "blocked until ([0-9]{1,2}):([0-9]{2})"
    "retry at ([0-9]{1,2}):([0-9]{2})"
    
    # Duration-based patterns
    "retry in ([0-9]+) hours?"
    "wait ([0-9]+) more hours?"
)
```

**Smart Timestamp Calculation**:
```bash
# 1.2 Implement robust time calculation logic
# Handle scenarios:
# - Current time 2pm, blocked until 3pm (same day)
# - Current time 11pm, blocked until 9am (next day)
# - "tomorrow at 2pm" (explicit next day)
# - Timezone considerations for macOS/Linux

calculate_wait_time_smart() {
    local target_hour="$1"
    local target_ampm="$2"
    local is_tomorrow="${3:-false}"
    
    # Convert to 24-hour format
    # Calculate seconds until target time
    # Handle date boundaries correctly
    # Return precise wait time in seconds
}
```

### Step 2: Task Automation Engine Enhancement
```bash
# Target: Optimize src/hybrid-monitor.sh for robust task processing
# Priority: ESSENTIAL - Core functionality

# 2.1 Enhance queue processing loop
vim src/hybrid-monitor.sh

# Key improvements:
# - Process all 16 pending tasks efficiently
# - Integrate enhanced usage limit detection
# - Real-time progress monitoring
# - Intelligent error recovery
```

**Task Processing Pipeline**:
```bash
# Enhanced queue processing workflow:
process_task_queue_enhanced() {
    local total_tasks=$(get_pending_task_count)  # Expected: 16
    local processed=0
    
    while [[ $processed -lt $total_tasks ]]; do
        # 1. Get next task
        local task=$(get_next_pending_task)
        
        # 2. Execute with claunch integration
        execute_task_with_monitoring "$task"
        
        # 3. Monitor for usage limits with enhanced detection
        if detect_usage_limit_in_queue "$session_output"; then
            handle_usage_limit_with_countdown
            continue  # Resume processing after wait
        fi
        
        # 4. Update progress and continue
        ((processed++))
        update_progress_display "$processed" "$total_tasks"
    done
}
```

### Step 3: Live Operation Testing Framework
```bash
# Target: Validate system for extended unattended operation
# Priority: DEPLOYMENT - Critical for live use

# 3.1 Create isolated testing environment
tmux new-session -d -s claude-live-test-$(date +%s)

# 3.2 Start enhanced monitoring with comprehensive logging
./src/hybrid-monitor.sh --queue-mode --continuous --enhanced-usage-limits --debug

# 3.3 Monitor task progression with real-time updates
./src/task-queue.sh monitor 0 300  # 5-minute continuous monitoring
```

**Live Operation Validation**:
```bash
# Extended runtime test (30+ minutes)
test_live_operation() {
    local test_duration=1800  # 30 minutes
    local start_time=$(date +%s)
    
    # Start enhanced system
    ./src/hybrid-monitor.sh --queue-mode --continuous --test-mode $test_duration
    
    # Monitor key metrics:
    # - Task completion rate
    # - Memory usage stability
    # - Process health
    # - Usage limit handling
    
    # Success criteria:
    # - All 16 tasks processed OR usage limit properly handled
    # - No memory leaks or resource exhaustion
    # - System recovers automatically from errors
}
```

### Step 4: Simple Activation Procedure
```bash
# Target: One-command deployment for live operation
# Priority: DEPLOYMENT - User experience

# 4.1 Create deployment wrapper script
cat > deploy-live-operation.sh << 'EOF'
#!/usr/bin/env bash
# Claude Auto-Resume - Live Operation Deployment
set -euo pipefail

echo "Starting Claude Auto-Resume Live Operation..."
echo "Tasks pending: $(./src/task-queue.sh status | jq '.pending')"
echo ""

# Start in dedicated tmux session
tmux new-session -d -s claude-auto-resume-live \
    "./src/hybrid-monitor.sh --queue-mode --continuous --enhanced-usage-limits"

echo "✅ Live operation started in tmux session 'claude-auto-resume-live'"
echo "📊 Monitor progress: tmux attach -t claude-auto-resume-live"
echo "📋 Check status: ./src/task-queue.sh status"
EOF

chmod +x deploy-live-operation.sh
```

## Progress Notes

**2025-09-11 - Analysis Complete**:
- ✅ **System Assessment**: 16 pending tasks, core infrastructure functional
- ✅ **Priority Identification**: Usage limit detection is the critical bottleneck
- ✅ **Implementation Strategy**: Enhance existing components vs rebuild
- ✅ **Safety Protocol**: Test in isolated tmux sessions only
- 🎯 **Focus Areas**: Enhanced usage limit patterns, task automation, live operation validation

**Key Insights**:
- The core system architecture is solid - need focused enhancements not rebuild
- Usage limit detection has basic patterns but needs robustness for real-world scenarios
- Task automation exists but needs integration with enhanced usage limit handling
- User specifically wants "nothing unnecessary" - focus on core functionality only
- Multiple background monitors already running successfully - build on existing success

**Technical Approach**:
- Enhance `src/usage-limit-recovery.sh` with comprehensive pm/am pattern detection
- Integrate enhanced detection into `src/hybrid-monitor.sh` task processing
- Test extensively in isolated environments before live deployment
- Create simple activation procedure for one-command deployment

## Resources & References

### Core Components for Enhancement
- `src/usage-limit-recovery.sh` - Primary target for usage limit improvements
- `src/hybrid-monitor.sh` - Main orchestrator requiring enhanced integration
- `src/task-queue.sh` - Queue management (currently 16 pending tasks)

### Enhanced Usage Limit Patterns (Target Implementation)
```bash
# Comprehensive patterns for various Claude CLI response formats
USAGE_LIMIT_PATTERNS=(
    # Time-specific blocks
    "blocked until ([0-9]{1,2})(am|pm)"
    "blocked until ([0-9]{1,2}):([0-9]{2})(am|pm)"
    "try again at ([0-9]{1,2})(am|pm)"
    "available.*at ([0-9]{1,2})(am|pm)"
    "tomorrow at ([0-9]{1,2})(am|pm)"
    
    # 24-hour formats
    "blocked until ([0-9]{1,2}):([0-9]{2})"
    "retry at ([0-9]{1,2}):([0-9]{2})"
    
    # Duration-based
    "retry in ([0-9]+) hours?"
    "wait ([0-9]+) more (minutes?|hours?)"
    
    # General limit patterns
    "usage limit" "rate limit" "too many requests"
    "please try again later" "quota exceeded"
)
```

### Live Operation Commands
```bash
# Current working command (basic operation)
./src/hybrid-monitor.sh --queue-mode --continuous

# Enhanced version (target implementation)
./src/hybrid-monitor.sh --queue-mode --continuous --enhanced-usage-limits

# Simple deployment (target)
./deploy-live-operation.sh

# Status monitoring
./src/task-queue.sh status
ps aux | grep hybrid-monitor
tmux list-sessions
```

### Testing Protocol
```bash
# Safe testing in isolated environment
tmux new-session -d -s claude-test-$(date +%s)

# Test enhanced usage limit detection
echo "blocked until 3pm" | ./src/usage-limit-recovery.sh test-pattern

# Test task automation
./src/hybrid-monitor.sh --queue-mode --test-mode 300 --debug

# Validate live operation capability
./test-live-operation.sh 1800  # 30-minute test
```

## Completion Checklist

- [ ] **Enhanced pm/am Pattern Detection** - Comprehensive regex for Claude CLI responses
- [ ] **Smart Timestamp Calculation** - Robust same-day/next-day/timezone handling
- [ ] **Live Countdown Display** - Real-time progress during wait periods
- [ ] **Automated Task Processing** - Process all 16 pending tasks without intervention
- [ ] **Session Integration** - Robust claunch/tmux coordination
- [ ] **Error Recovery** - Intelligent retry logic and graceful error handling
- [ ] **Unattended Operation** - Extended runtime validation (30+ minutes)
- [ ] **Resource Management** - No memory leaks or resource exhaustion
- [ ] **Safe Testing** - Isolated tmux sessions, no disruption to existing sessions
- [ ] **Simple Activation** - One-command deployment procedure (`./deploy-live-operation.sh`)

---
**Status**: Active  
**Last Updated**: 2025-09-11  
**Priority**: HIGH - Critical for live operation readiness  
**Next Agent**: creator - Implement enhanced usage limit detection and task automation engine