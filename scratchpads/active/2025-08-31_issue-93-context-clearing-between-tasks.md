# Issue #93: Implement Context Clearing Between Tasks with Optional Override

**Planner Agent Report**
**Date:** 2025-08-31
**Issue:** https://github.com/trytofly94/Claude-Auto-Resume-System/issues/93
**Priority:** High - Essential for clean task separation

## 📋 Executive Summary

Issue #93 requests implementation of automatic context clearing between tasks to prevent context pollution, with optional override capability for related tasks. This is a critical enhancement to maintain clean task isolation while preserving flexibility for multi-task workflows.

## 🔍 Current System Analysis

### Task Management Architecture
The system uses a sophisticated modular task queue architecture:

- **Core Task Queue:** `src/task-queue.sh` - Main interface with command dispatcher
- **Queue Modules:** `src/queue/` - Modular architecture (core, persistence, workflow, etc.)
- **Session Manager:** `src/session-manager.sh` - Session lifecycle management  
- **Hybrid Monitor:** `src/hybrid-monitor.sh` - Main monitoring loop with claunch integration

### Current Task Processing Flow
1. Tasks are stored in associative arrays in memory and persisted to JSON
2. Task objects have: `id`, `type`, `status`, `created_at`, `retry_count`, etc.
3. `hybrid-monitor.sh` processes tasks from the queue
4. Sessions are managed via claunch with tmux integration
5. Commands are sent to Claude via `tmux send-keys`

### Context Management Gap
**Current State:** Tasks share Claude's context across execution
**Problem:** Context pollution between unrelated tasks
**Impact:** Previous task information influences new tasks

## 🎯 Implementation Requirements Analysis

### 1. Configuration Layer (`config/default.conf`)
```bash
# New configuration option (default: true for clean separation)
QUEUE_SESSION_CLEAR_BETWEEN_TASKS=true
```

### 2. Task-Level Override Capability
Tasks need a new `clear_context` field:
```json
{
  "id": "custom-12345",
  "type": "custom",
  "description": "Task description",
  "clear_context": false,  // Override default behavior
  "status": "pending",
  "created_at": "2025-08-31T10:00:00Z"
}
```

### 3. Command-Line Interface Extensions
```bash
# New flags for claude-auto-resume command
--no-clear-context    # Disable context clearing for this task
--clear-context       # Explicitly enable (override global config)
```

### 4. Smart Context Management Logic
```
Normal Task Completion → Check clear_context preference → Send "/clear" → Next task
Usage Limit Recovery → Skip "/clear" (preserve context for continuation)
Manual Override → Honor task-level clear_context setting
```

## 🏗️ Technical Implementation Plan

### Phase 1: Core Infrastructure (Creator Tasks 1-3)

#### Task 1: Configuration Integration
**File:** `config/default.conf`
- Add `QUEUE_SESSION_CLEAR_BETWEEN_TASKS=true` configuration option
- Add supporting documentation comments

**File:** `src/task-queue.sh` (load_configuration function)
- Ensure new config option is loaded properly
- Add validation for boolean values

#### Task 2: Task Data Model Extension  
**File:** `src/queue/core.sh`
- Extend task validation to support optional `clear_context` field
- Update `validate_task_structure` function to accept this new field
- Ensure backward compatibility with existing tasks

**File:** `src/queue/persistence.sh`
- Update JSON serialization/deserialization to handle `clear_context` field
- Maintain backward compatibility with existing task files

#### Task 3: Command-Line Interface Extension
**Primary File:** `claude-auto-resume` (main entry point script - need to locate)
- Add `--no-clear-context` and `--clear-context` flags
- Parse flags and set `clear_context` field in task JSON
- Update help text and usage examples

**Alternative:** If no main CLI script exists, modify task creation functions in `src/task-queue.sh`

### Phase 2: Context Management Logic (Creator Tasks 4-5)

#### Task 4: Context Clearing Implementation
**File:** `src/session-manager.sh`
- Add `send_context_clear_command()` function
- Implement `/clear` command sending via tmux send-keys
- Add proper timing and error handling
- Add logging for context clearing actions

**Function Signature:**
```bash
send_context_clear_command() {
    local session_name="$1"
    local wait_seconds="${2:-2}"
    
    log_info "Clearing context for session: $session_name"
    tmux send-keys -t "$session_name" '/clear' C-m
    sleep "$wait_seconds"
    log_debug "Context clear command sent, waited ${wait_seconds}s"
}
```

#### Task 5: Smart Context Decision Logic
**File:** `src/hybrid-monitor.sh` (main task processing loop)
- Add `should_clear_context()` decision function
- Integrate context clearing into task completion flow
- Handle usage limit scenarios (preserve context)
- Implement task-level override logic

**Decision Logic:**
```bash
should_clear_context() {
    local task_json="$1"
    local completion_reason="${2:-normal}"
    
    # Usage limit recovery: never clear
    if [[ "$completion_reason" == "usage_limit_recovery" ]]; then
        return 1  # Don't clear
    fi
    
    # Task-level override
    local task_clear_preference=$(echo "$task_json" | jq -r '.clear_context // null')
    if [[ "$task_clear_preference" != "null" ]]; then
        [[ "$task_clear_preference" == "true" ]] && return 0 || return 1
    fi
    
    # Global configuration default
    [[ "$QUEUE_SESSION_CLEAR_BETWEEN_TASKS" == "true" ]] && return 0 || return 1
}
```

### Phase 3: Integration and Testing (Tester Tasks 1-3)

#### Task 6: Unit Tests for Context Management
**File:** `tests/unit/test-context-clearing.bats`
- Test `should_clear_context()` decision logic
- Test task data model validation with `clear_context` field
- Test configuration loading and defaults
- Mock tmux send-keys for isolated testing

#### Task 7: Integration Tests for Task Processing
**File:** `tests/integration/test-task-context-flow.bats`
- Test end-to-end task processing with context clearing
- Test usage limit recovery scenarios (context preservation)
- Test command-line flag integration
- Test configuration override scenarios

#### Task 8: Manual Testing and Validation
- Create test tasks with different `clear_context` settings
- Verify `/clear` command is sent at appropriate times
- Test usage limit recovery behavior
- Validate command-line flags work correctly

### Phase 4: Documentation and Deployment (Deployer Tasks 1-2)

#### Task 9: Documentation Updates
**File:** `README.md`
- Update usage examples with new flags
- Document configuration options
- Add context clearing behavior explanation
- Include migration notes for existing users

**File:** `CLAUDE.md`
- Update project-specific configuration section
- Document new config option and behavior
- Update troubleshooting section

#### Task 10: Final Integration and PR Creation
- Create feature branch: `feature/issue-93-context-clearing`
- Ensure all tests pass
- Update CHANGELOG if exists
- Create comprehensive PR with:
  - Link to issue #93
  - Summary of changes
  - Usage examples
  - Testing notes

## 🔄 Usage Scenarios & Examples

### Scenario 1: Default Behavior (Clean Separation)
```bash
# Task 1: Fix login bug (completes)
# → System automatically sends "/clear"
# Task 2: Add dark mode (starts with fresh context)
```

### Scenario 2: Related Tasks (Context Preservation)
```bash
claude-auto-resume --add-custom "Design user model" --no-clear-context  
claude-auto-resume --add-custom "Implement user model" --no-clear-context
claude-auto-resume --add-custom "Test user model" --clear-context
# → Context flows through first two, clears after third
```

### Scenario 3: Usage Limit Recovery
```bash
# Task 1: Fix complex bug (usage limit hit)
# → System waits for limit reset
# → System sends recovery command (NO /clear sent)
# → Context preserved for task continuation
```

### Scenario 4: Global Configuration Override
```bash
# In config/default.conf:
QUEUE_SESSION_CLEAR_BETWEEN_TASKS=false
# → Old behavior maintained globally
# → Individual tasks can still use --clear-context flag
```

## 🚨 Risk Assessment & Mitigation

### High Risk: Backward Compatibility
**Risk:** Breaking existing task queue workflows
**Mitigation:** 
- Default to `true` for context clearing (better default)
- Make `clear_context` field optional with fallback to global config
- Extensive testing with existing task formats

### Medium Risk: tmux Integration Reliability  
**Risk:** `/clear` command might fail or timeout
**Mitigation:**
- Add proper error handling in `send_context_clear_command()`
- Implement timeout and retry logic
- Log all context clearing attempts for debugging

### Medium Risk: Usage Limit Recovery Complexity
**Risk:** Complex logic for determining when to preserve context
**Mitigation:**
- Clear documentation of decision logic
- Comprehensive test coverage for edge cases
- Conservative approach: prefer context preservation for recovery scenarios

### Low Risk: Performance Impact
**Risk:** Additional 2-second delay per task for context clearing
**Mitigation:**
- Configurable wait time (default 2s, can be reduced)
- Only applies when context clearing is enabled
- Minimal impact compared to overall task execution time

## ✅ Success Criteria

### Functional Requirements
- [ ] Context automatically cleared between tasks by default
- [ ] `--no-clear-context` flag prevents context clearing
- [ ] Usage limit recovery preserves context correctly
- [ ] Global configuration option `QUEUE_SESSION_CLEAR_BETWEEN_TASKS` works
- [ ] Task queue stores and respects `clear_context` preference
- [ ] Clean tmux send-keys implementation with proper error handling

### Non-Functional Requirements
- [ ] Backward compatibility with existing task formats
- [ ] Performance impact < 5 seconds per task
- [ ] Comprehensive test coverage (>90% for new functions)
- [ ] Clear documentation and usage examples
- [ ] Graceful error handling and logging

### Testing Requirements
- [ ] Unit tests for all new functions pass
- [ ] Integration tests for task processing flow pass
- [ ] Manual testing scenarios validated
- [ ] No regression in existing functionality

## 📝 Implementation Notes

### Key Files to Modify
1. `config/default.conf` - Add configuration option
2. `src/queue/core.sh` - Extend task validation
3. `src/queue/persistence.sh` - Update JSON handling
4. `src/session-manager.sh` - Add context clearing function
5. `src/hybrid-monitor.sh` - Integrate context clearing logic
6. Main CLI script - Add command-line flags (location TBD)

### Key Functions to Implement
1. `send_context_clear_command(session_name, wait_seconds)`
2. `should_clear_context(task_json, completion_reason)`
3. Updated `validate_task_structure()` - Support clear_context field
4. Command-line flag parsing for context clearing options

### Backward Compatibility Strategy
- All new features are additive, not breaking
- Existing tasks without `clear_context` field use global config default
- Global config defaults to `true` (better isolation by default)
- Existing command-line interfaces remain unchanged

## 🏃‍♂️ Next Steps

This scratchpad serves as the comprehensive implementation plan for issue #93. The **creator** agent should:

1. Start with Phase 1 (Core Infrastructure) tasks
2. Implement each task systematically with proper testing
3. Follow the project's coding standards and conventions
4. Ensure all changes are backward compatible
5. Create comprehensive tests for new functionality

The implementation focuses on clean separation of concerns, robust error handling, and maintaining the existing modular architecture while adding the new context clearing functionality.

---

**Status:** Planning Complete - Ready for Implementation
**Estimated Effort:** Medium-High (8-12 hours)
**Dependencies:** None (self-contained feature)
**Next Agent:** Creator (implement Phase 1 tasks)