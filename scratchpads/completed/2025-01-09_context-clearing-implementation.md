# Context Clearing Implementation Plan
**Issue**: #93 - Implement Context Clearing Between Tasks with Optional Override  
**Date**: 2025-01-09  
**Status**: Completed  
**Priority**: High  

## Problem Analysis

Currently, the Claude Auto-Resume system lacks proper context isolation between tasks. This causes:
- Context pollution where previous task information influences new tasks
- No clean separation between unrelated development work
- Potential confusion when switching between different types of work

## Solution Overview

Implement automatic context clearing between tasks with smart exception handling and optional overrides.

## Implementation Plan

### Phase 1: Configuration Infrastructure
**Files to modify**: `config/default.conf`

1. Add new configuration option `QUEUE_SESSION_CLEAR_BETWEEN_TASKS=true`
2. Add documentation for the new setting
3. Ensure backward compatibility

### Phase 2: Task Queue Enhancement  
**Files to modify**: `src/task-queue.sh`

1. Add `clear_context` field to task JSON structure
2. Implement task-level override logic
3. Add command-line flag parsing for `--no-clear-context` and `--clear-context`
4. Update task creation functions to handle context clearing preferences
5. Add helper functions:
   - `should_clear_context_for_task()`
   - `get_task_clear_context_setting()`

### Phase 3: Session Management Integration
**Files to modify**: `src/session-manager.sh`

1. Add `/clear` command execution function
2. Implement proper timing and error handling for context clearing
3. Add logging for context clearing operations
4. Ensure compatibility with different session types (tmux, direct)

### Phase 4: Core Monitoring Logic
**Files to modify**: `src/hybrid-monitor.sh`

1. Integrate context clearing into task completion workflow
2. Implement smart exception handling for usage limit recovery
3. Add logic to determine when to clear vs preserve context
4. Update task processing loop to handle context clearing
5. Add proper sequencing: task complete → clear context → next task

### Phase 5: Command Line Interface Updates
**Files to modify**: Main entry script (if exists) or calling scripts

1. Add `--no-clear-context` flag support
2. Add `--clear-context` flag for explicit clearing
3. Update help text and documentation
4. Ensure flag propagation to task queue

## Technical Implementation Details

### Context Clearing Sequence
```bash
# Normal task completion
1. Task completes successfully
2. Check if context should be cleared
3. If yes: Send "/clear" command via tmux
4. Wait for context clearing confirmation
5. Proceed to next task

# Usage limit recovery (exception)
1. Usage limit reached during task
2. System waits for limit reset
3. Send recovery command (NO /clear)
4. Continue with preserved context
```

### Decision Logic Flow
```bash
should_clear_context():
  if task.clear_context == false:
    return false
  if task.clear_context == true:
    return true
  if QUEUE_SESSION_CLEAR_BETWEEN_TASKS == false:
    return false
  if is_usage_limit_recovery:
    return false
  return true  # default behavior
```

### Task JSON Structure Update
```json
{
  "id": "custom-12345",
  "description": "Task description",
  "clear_context": true|false|null,
  "status": "pending",
  "created_at": "timestamp",
  "type": "custom"
}
```

## Files Requiring Changes

1. **config/default.conf**
   - Add `QUEUE_SESSION_CLEAR_BETWEEN_TASKS=true`
   - Document the new configuration option

2. **src/task-queue.sh**
   - Task structure updates
   - Command-line flag parsing
   - Context clearing decision logic

3. **src/session-manager.sh**
   - `/clear` command execution
   - Timing and error handling
   - Session type compatibility

4. **src/hybrid-monitor.sh**
   - Task completion workflow integration
   - Usage limit recovery exception handling
   - Main processing loop updates

## Testing Strategy

### Unit Tests
- Test context clearing decision logic
- Test task JSON structure with clear_context field
- Test command-line flag parsing
- Test configuration option parsing

### Integration Tests
- Test full workflow with context clearing enabled
- Test `--no-clear-context` flag behavior
- Test usage limit recovery context preservation
- Test mixed scenarios (some tasks clear, some don't)

### Manual Testing Scenarios
1. Default behavior: multiple unrelated tasks should have clean separation
2. Related tasks: use `--no-clear-context` to maintain context flow
3. Usage limit recovery: ensure context is preserved during wait/recovery
4. Configuration override: test global disable/enable

## Success Criteria

- [ ] Context cleared between tasks by default
- [ ] `--no-clear-context` flag prevents clearing for specific tasks
- [ ] `--clear-context` flag explicitly enables clearing
- [ ] Usage limit recovery preserves context correctly
- [ ] `QUEUE_SESSION_CLEAR_BETWEEN_TASKS` configuration option works globally
- [ ] Task queue stores and respects `clear_context` preference
- [ ] Clean tmux `/clear` command implementation
- [ ] Proper error handling and logging
- [ ] Backward compatibility maintained
- [ ] All tests pass

## Risk Assessment

### Low Risk
- Configuration changes are additive
- Task queue changes are backward compatible
- Command-line flags are optional

### Medium Risk
- Timing of `/clear` command execution needs careful handling
- tmux session management requires proper error handling

### High Risk
- Usage limit recovery logic must not interfere with context preservation
- Sequence of operations critical for proper functionality

## Implementation Order

1. **Start with configuration** (lowest risk, enables testing)
2. **Update task queue** (core data structure changes)
3. **Add session management** (tmux command integration)
4. **Integrate with monitoring** (main workflow changes)
5. **Add CLI flags** (user interface completion)
6. **Comprehensive testing** (validation of all components)

## Notes

- Implementation should be incremental and testable at each step
- Each phase should include appropriate logging for debugging
- Consider edge cases like failed `/clear` commands
- Maintain compatibility with existing task queue files
- Document any breaking changes (none expected)

---
## Completion Summary

**Implementation Completed**: 2025-09-01  
**Pull Request**: #105 - https://github.com/trytofly94/Claude-Auto-Resume-System/pull/105  
**Result**: Successfully implemented complete context clearing functionality

### Final Status
✅ All 5 phases completed successfully
✅ Configuration infrastructure implemented  
✅ Task queue enhancements functional
✅ Session management integration complete
✅ Core monitoring workflow integration working
✅ CLI flag support fully functional
✅ Comprehensive testing validated
✅ Pull request created and documentation updated

### Key Achievements  
- Default context clearing between tasks prevents pollution
- Smart usage limit recovery preserves context as required
- Task-level overrides provide flexibility for related workflows  
- Backward compatibility maintained throughout
- Comprehensive error handling and logging implemented

**Implementation Quality**: Production-ready with full test validation