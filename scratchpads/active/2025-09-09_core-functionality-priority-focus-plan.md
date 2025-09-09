# Core Functionality Priority Focus Plan - Live Operation Essentials

**Created**: 2025-09-09
**Type**: Critical System Stabilization
**Estimated Effort**: Small-Medium
**Related Issue**: User Request - Focus on main functionality for live operation
**Priority**: CRITICAL - Essential for live deployment

## Context & Goal

Focus exclusively on the core functionality necessary for the Claude Auto-Resume System to work in live operation, specifically:
1. **Task automation capabilities** - Automated processing of the 10 pending tasks 
2. **Detection and handling of program blocking until specific times (xpm/am)** - Usage limit recovery
3. **Safe operation** - No disruption to existing tmux sessions

**Current Critical Issues**:
- ❌ **Readonly variable conflicts** in `session-manager.sh` preventing hybrid-monitor from running
- ❌ **Background processes failing** - 3 hybrid-monitor processes are failing with readonly errors
- ✅ **10 pending tasks** ready for processing (task queue functional)
- ✅ **Usage limit detection** system exists but needs validation for pm/am patterns

## Current State Analysis

### ✅ What's Already Working
- **Task Queue System**: 10 tasks pending, core queue functionality operational
- **Core Components**: All major modules present (hybrid-monitor.sh, task-queue.sh, usage-limit-recovery.sh)  
- **Dependencies**: Claude CLI, claunch v0.0.4, tmux all available and validated
- **Configuration**: All config loaded successfully from `config/default.conf`
- **Session Management**: claunch integration detected and configured

### ❌ Critical Blocking Issues
- **Readonly Variable Conflicts**: Lines 44-46 in `src/session-manager.sh`
  - `DEFAULT_SESSION_CLEANUP_AGE: Schreibgeschützte Variable`
  - `DEFAULT_ERROR_SESSION_CLEANUP_AGE: Schreibgeschützte Variable` 
  - `BATCH_OPERATION_THRESHOLD: Schreibgeschützte Variable`
- **Multiple Process Failures**: 3 background hybrid-monitor processes failing
- **Orchestration Broken**: Core components exist but can't run due to readonly conflicts

### 📊 System Status
```
Task Queue: 10 pending, 0 in_progress, 0 completed
Background Processes: 3 failing (c14a30, 421e04, fea853)
Error Pattern: Readonly variable conflicts in session-manager.sh
Critical Path Blocked: hybrid-monitor.sh --queue-mode --continuous
```

## Requirements

- [ ] **Fix readonly variable conflicts** preventing hybrid-monitor execution
- [ ] **Validate task automation** processes the 10 pending tasks successfully
- [ ] **Confirm usage limit detection** with pm/am blocking patterns works live
- [ ] **Test safe operation** without disrupting existing tmux sessions (s000, s001, s002, s004, s005, s012)
- [ ] **Ensure continuous operation** for live deployment readiness
- [ ] **Focus only on essential functionality** - ignore non-critical features

## Investigation & Analysis

### Prior Work Analysis
- ✅ **Recent Commits**: Attempted fixes for readonly variables (commits ece1e41, 2f5f757)
- ✅ **Core System Built**: All functionality exists from previous development phases
- ✅ **Usage Limit Detection**: Basic patterns present in `usage-limit-recovery.sh`
- ❌ **PM/AM Enhancement**: Need to locate/validate enhanced pm/am patterns mentioned in logs

### Root Cause Analysis
**Primary Issue**: Variable redeclaration conflict in `session-manager.sh`
- Lines 45-53: Using readonly with conditional guards, but variables already declared elsewhere
- Multiple script sourcing causing variable redeclaration attempts
- Guards present (`if [[ -z "${VAR:-}" ]]`) but not preventing conflicts

**Secondary Issues**:
- Multiple concurrent hybrid-monitor processes interfering with each other
- Need validation of actual pm/am usage limit detection patterns

## Implementation Plan

### Phase 1: Critical Bug Fixes (IMMEDIATE)
- [ ] **Step 1**: Fix readonly variable conflicts in session-manager.sh
  - Replace readonly declarations with proper conditional setting
  - Use `declare -gx` instead of `readonly` for already-declared variables
  - Test variable isolation between multiple script instances
  - Validate fix doesn't break session management functionality

- [ ] **Step 2**: Stop conflicting background processes safely
  - Identify which hybrid-monitor processes are failing
  - Gracefully terminate failed processes to prevent interference
  - Clear any stale process locks or state files

### Phase 2: Core Functionality Validation (PRIMARY)
- [ ] **Step 3**: Test task automation in isolated environment
  - Start single hybrid-monitor instance: `./src/hybrid-monitor.sh --queue-mode --continuous --debug`
  - Monitor task progression from 10 pending to processing
  - Verify claunch integration handles task execution properly
  - Confirm task completion detection and queue state updates

- [ ] **Step 4**: Validate usage limit detection with pm/am patterns  
  - Locate enhanced pm/am detection patterns (mentioned in recent work)
  - Test patterns: "blocked until 3pm", "try again at 9am", etc.
  - Verify timestamp calculation for today/tomorrow scenarios
  - Confirm waiting/blocking behavior until specified times

### Phase 3: Live Operation Readiness (ESSENTIAL)
- [ ] **Step 5**: Safe operation validation
  - Confirm no interference with existing tmux sessions
  - Test isolation using dedicated session naming
  - Verify resource usage remains minimal
  - Test graceful shutdown/restart capabilities

- [ ] **Step 6**: Live deployment preparation
  - Document single-command startup for live operation
  - Create monitoring checklist for live deployment
  - Verify system can run unattended and recover from errors
  - Test continuous operation over extended period (30+ minutes)

## Progress Notes

**2025-09-09 - Critical Issues Identified**:
- ✅ **Root Cause Found**: Readonly variable conflicts in `session-manager.sh` lines 44-46
- ✅ **System Architecture**: All core components present and functional
- ✅ **Task Queue Ready**: 10 tasks pending, queue system operational
- ❌ **Blocking**: 3 background processes failing due to readonly variable errors
- 🎯 **Next Action**: Fix readonly variable conflicts to unblock system operation

**Key Insights**:
- This is a bug fix and validation task, not new development
- All major functionality already exists from previous development phases
- Focus must be laser-focused on fixing blocking issues and validating core features
- User explicitly wants to avoid non-essential features and focus on live operation needs

## Resources & References

### Core Components (Already Built)
- `src/hybrid-monitor.sh` - Main orchestrator (failing due to readonly errors)
- `src/task-queue.sh` - Task management (10 tasks ready, fully functional)
- `src/session-manager.sh` - Session management (has readonly variable conflicts)  
- `src/usage-limit-recovery.sh` - Usage limit detection (needs pm/am pattern validation)

### Critical Commands for Live Operation

#### Bug Fix Commands
```bash
# Fix readonly variable conflicts
vim src/session-manager.sh  # Edit lines 45-53
shellcheck src/session-manager.sh  # Validate syntax

# Stop failing background processes
ps aux | grep hybrid-monitor  # Identify failing processes
kill [PIDs]  # Gracefully terminate if needed
```

#### Core Functionality Testing
```bash
# Start single hybrid-monitor for testing
./src/hybrid-monitor.sh --queue-mode --continuous --debug

# Monitor task queue status
./src/task-queue.sh status
./src/task-queue.sh list

# Test usage limit patterns (when needed)
# [To be determined based on pattern location]
```

#### Live Operation Commands (Target)
```bash
# Single command for live deployment
./src/hybrid-monitor.sh --queue-mode --continuous

# Monitor system status
./src/task-queue.sh monitor 0 60  # Continuous monitoring
```

### Current System State
- **Branch**: feature/issue-115-array-optimization  
- **Task Queue**: 10 pending (custom tasks, workflow tasks for issues 106, 107, 94, 98, etc.)
- **Dependencies**: All validated (claude CLI, claunch v0.0.4, tmux)
- **Recent Work**: Array optimization and session management enhancements

## Success Criteria

- [ ] **Bug Fixes**: No more readonly variable errors in hybrid-monitor execution
- [ ] **Task Automation**: All 10 pending tasks processed successfully  
- [ ] **Usage Limit Detection**: PM/AM blocking patterns work correctly in live scenarios
- [ ] **Safe Operation**: No disruption to existing tmux sessions during operation
- [ ] **Live Ready**: System runs continuously and handles errors gracefully
- [ ] **Core Focus**: Only essential functionality active, no unnecessary features

## Completion Checklist

- [ ] Fixed readonly variable conflicts preventing hybrid-monitor startup
- [ ] Validated task automation processes pending tasks automatically
- [ ] Confirmed usage limit detection with pm/am patterns works live
- [ ] Tested safe operation without tmux session interference  
- [ ] Documented simple activation procedure for live deployment
- [ ] System validated for continuous unattended operation

---
**Status**: Active
**Last Updated**: 2025-09-09
**Priority**: CRITICAL - Core functionality must work for live operation