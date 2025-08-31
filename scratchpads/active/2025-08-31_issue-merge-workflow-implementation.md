# Issue-Merge Workflow Implementation Plan

**Created**: 2025-08-31  
**Type**: Feature  
**Estimated Effort**: Medium-High  
**Related Issue**: #94  
**Status**: Planning Phase  

## Context & Objective

Implement an `issue-merge` workflow type in the existing task queue system that automates the complete development lifecycle: develop → clear → review → merge. This feature will integrate with the existing task queue infrastructure and enable sequential, automated processing of GitHub issues from development to main branch integration.

## Issue Analysis Summary

**Key Requirements from Issue #94:**
- Sequential execution of four phases: develop, clear, review, merge
- Integration with existing `/dev`, `/clear`, `/review` commands
- Error handling with interruption and resumption capabilities
- Status tracking and progress monitoring
- Workflow data structure with step-by-step execution

**Benefits:**
- Eliminates branch conflicts through ordered execution
- Reduces manual coordination overhead
- Leverages existing task queue infrastructure
- Aligns with main functionality focus (per CLAUDE.md)

## Architecture Analysis

### Current System Overview

**Existing Components:**
- `src/task-queue.sh` - Main queue system with modular architecture (v2.0.0-refactored)
- `src/queue/workflow.sh` - **Partially implemented** workflow module with placeholder functions
- `src/queue/core.sh` - Core task operations with global state management
- `src/claunch-integration.sh` - Command execution via `send_command_to_session()`

**Key Data Structures:**
```bash
# Global state arrays (from core.sh)
declare -gA TASK_STATES=()      # Task status tracking
declare -gA TASK_METADATA=()    # Task JSON data storage
declare -gA TASK_RETRY_COUNTS=()
declare -gA TASK_TIMESTAMPS=()
```

**Existing Workflow Infrastructure:**
- Workflow constants already defined (`WORKFLOW_TYPE_ISSUE_MERGE`, status constants)
- Basic workflow creation and execution functions exist but use simulation
- Issue-merge workflow steps defined in `initialize_issue_merge_workflow()`
- Command dispatcher in main task-queue.sh supports workflow operations

### Integration Points

1. **Command Execution**: `send_command_to_session()` in `claunch-integration.sh`
2. **Session Management**: tmux-based session handling for command delivery
3. **State Persistence**: `save_queue_state()` and `load_queue_state()` functions
4. **Error Recovery**: Existing retry and timeout mechanisms in core.sh

## Technical Implementation Plan

### Phase 1: Replace Simulation with Real Command Execution

**Current State:** `workflow.sh` contains placeholder simulation functions
**Target:** Replace with actual Claude CLI command execution

#### 1.1 Command Execution Integration
- **File**: `src/queue/workflow.sh`
- **Functions to modify:**
  - `execute_workflow_step()` - Remove simulation, add real command execution
  - `simulate_dev_command()` → `execute_dev_command()`
  - `simulate_clear_command()` → `execute_clear_command()`
  - `simulate_review_command()` → `execute_review_command()`
  - `simulate_merge_command()` → `execute_merge_command()`

#### 1.2 Command Integration Dependencies
- Import `claunch-integration.sh` functions
- Add session detection and validation
- Implement command result validation

#### 1.3 Real Command Implementation Strategy
```bash
# Example replacement pattern:
execute_dev_command() {
    local command="$1"
    local issue_id="$2"
    
    # Ensure session exists and is active
    if ! check_session_status; then
        log_error "No active Claude session for dev command"
        return 1
    fi
    
    # Send command and monitor for completion
    if send_command_to_session "$command"; then
        monitor_command_completion "$command" "$issue_id"
    else
        log_error "Failed to send command: $command"
        return 1
    fi
}
```

### Phase 2: Command Completion Detection

**Challenge:** Need to detect when Claude CLI commands complete successfully

#### 2.1 Completion Detection Strategy
- **Pattern-based detection**: Look for Claude's response patterns
- **Timeout mechanism**: Set reasonable timeouts per phase
- **Error detection**: Recognize failure patterns

#### 2.2 Implementation Approach
```bash
monitor_command_completion() {
    local command="$1"
    local timeout="${2:-300}"  # 5 minutes default
    local start_time=$(date +%s)
    
    while true; do
        # Check for completion patterns in Claude output
        if check_command_completion_pattern "$command"; then
            return 0
        fi
        
        # Check for timeout
        local current_time=$(date +%s)
        if (( current_time - start_time > timeout )); then
            log_error "Command timeout: $command"
            return 1
        fi
        
        sleep 5  # Check every 5 seconds
    done
}
```

#### 2.3 Phase-Specific Completion Patterns
- **Develop phase**: Look for PR creation confirmation or specific success messages
- **Clear phase**: Immediate completion (context clearing is instant)
- **Review phase**: Look for review completion indicators
- **Merge phase**: Look for merge success confirmation

### Phase 3: Error Handling and Resumability

#### 3.1 Error Classification System
- **Recoverable errors**: Network issues, temporary unavailability
- **Non-recoverable errors**: Invalid commands, authentication failures
- **User intervention required**: Conflicts, manual review needed

#### 3.2 Workflow State Persistence
```bash
# Enhanced workflow data structure
{
    "id": "workflow-issue-94-20250831",
    "type": "workflow",
    "workflow_type": "issue-merge",
    "status": "in_progress",
    "issue_id": "94",
    "current_step": 1,
    "steps": [
        {
            "phase": "develop",
            "status": "completed",
            "started_at": "2025-08-31T10:00:00Z",
            "completed_at": "2025-08-31T10:15:00Z",
            "command": "/dev 94",
            "result": {
                "pr_number": "123",
                "branch": "feature/issue-merge-workflow"
            }
        },
        {
            "phase": "clear", 
            "status": "in_progress",
            "started_at": "2025-08-31T10:15:00Z",
            "command": "/clear"
        }
    ],
    "error_history": [],
    "retry_count": 0,
    "last_error": null
}
```

#### 3.3 Resume Mechanism
- **Checkpoint creation**: Save state after each successful step
- **Resume from last checkpoint**: Skip completed steps on restart
- **Error recovery**: Retry failed steps with exponential backoff

### Phase 4: Status Tracking and Monitoring

#### 4.1 Progress Tracking Enhancement
- **Real-time status updates**: Update workflow data after each step
- **Progress percentage**: Calculate based on completed/total steps
- **Time tracking**: Record duration for each phase
- **Resource usage**: Monitor session health during execution

#### 4.2 Monitoring Integration
```bash
# Enhanced status reporting
get_workflow_detailed_status() {
    local workflow_id="$1"
    local workflow_data=$(get_task "$workflow_id" "json")
    
    jq -n \
        --argjson workflow "$workflow_data" \
        --arg current_time "$(date -Iseconds)" \
        '{
            workflow_id: $workflow.id,
            status: $workflow.status,
            progress: {
                current_step: $workflow.current_step,
                total_steps: ($workflow.steps | length),
                percentage: (($workflow.current_step * 100) / ($workflow.steps | length))
            },
            timing: {
                started_at: $workflow.created_at,
                current_time: $current_time,
                elapsed_seconds: ((now | strftime("%s")) - ($workflow.created_at | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime))
            },
            current_phase: $workflow.steps[$workflow.current_step].phase,
            session_health: "active"  # To be implemented
        }'
}
```

### Phase 5: Testing Strategy

#### 5.1 Unit Tests
- **File**: `tests/unit/test-workflow-issue-merge.bats`
- **Coverage**:
  - Workflow creation and initialization
  - Step execution logic
  - Error handling and recovery
  - State persistence and resumption

#### 5.2 Integration Tests
- **File**: `tests/integration/test-issue-merge-workflow.bats`
- **Scenarios**:
  - Complete workflow execution (with mocked commands)
  - Interruption and resumption
  - Error recovery
  - Multiple concurrent workflows

#### 5.3 End-to-End Tests
- **Approach**: Use test issues in sandbox environment
- **Validation**: Actual Claude CLI integration
- **Monitoring**: Real session management and command execution

### Phase 6: Documentation and CLI Interface

#### 6.1 CLI Usage Examples
```bash
# Create issue-merge workflow
./src/task-queue.sh create-issue-merge 94

# Monitor workflow progress
./src/task-queue.sh workflow status workflow-issue-94-20250831

# Resume failed workflow
./src/task-queue.sh workflow resume workflow-issue-94-20250831

# List all workflows
./src/task-queue.sh workflow list in_progress
```

#### 6.2 Documentation Updates
- Update `CLAUDE.md` with workflow usage instructions
- Add workflow examples to `README.md`
- Create troubleshooting guide for common workflow issues

## Implementation Steps

### Step 1: Command Execution Foundation (Day 1)
1. **Modify `src/queue/workflow.sh`**:
   - Replace all `simulate_*` functions with `execute_*` functions
   - Add `claunch-integration.sh` dependency
   - Implement basic command execution without completion detection

2. **Add command validation**:
   - Verify session availability before command execution
   - Add basic error logging

3. **Test basic command sending**:
   - Verify commands reach Claude CLI
   - Ensure no syntax errors in workflow module

### Step 2: Completion Detection (Day 2)
1. **Implement completion monitoring**:
   - Add `monitor_command_completion()` function
   - Create phase-specific completion patterns
   - Add timeout mechanisms

2. **Enhance step execution**:
   - Integrate completion detection into `execute_workflow_step()`
   - Add proper error handling for timeouts

3. **Test completion detection**:
   - Verify detection works for each phase
   - Test timeout scenarios

### Step 3: Error Handling and Recovery (Day 3)
1. **Implement error classification**:
   - Add error type detection
   - Create recovery strategies for each error type
   - Implement retry mechanisms

2. **Enhance state persistence**:
   - Add error history to workflow data
   - Implement checkpoint system
   - Add resume capability

3. **Test error scenarios**:
   - Test various failure modes
   - Verify recovery mechanisms

### Step 4: Status Tracking and CLI (Day 4)
1. **Enhance status reporting**:
   - Add detailed progress tracking
   - Implement time tracking
   - Add session health monitoring

2. **Improve CLI interface**:
   - Add workflow-specific commands
   - Enhance status display
   - Add progress indicators

3. **Test complete system**:
   - End-to-end workflow testing
   - CLI interface validation
   - Performance testing

### Step 5: Documentation and Finalization (Day 5)
1. **Update documentation**:
   - Add workflow usage to CLAUDE.md
   - Create examples and troubleshooting guide
   - Update README with new features

2. **Final testing**:
   - Complete test suite execution
   - Integration testing with existing features
   - Performance and reliability testing

3. **Code review and cleanup**:
   - Code quality review
   - Remove debug code
   - Finalize error messages and logging

## Risk Assessment

### High-Risk Areas

#### 1. Command Completion Detection
**Risk**: Unreliable detection of Claude CLI command completion
**Mitigation**: 
- Implement multiple detection strategies (pattern-based, timeout-based)
- Add manual intervention options
- Comprehensive testing with various Claude responses

#### 2. Session Management Integration  
**Risk**: Workflow conflicts with existing session management
**Mitigation**:
- Careful integration with existing claunch-integration.sh
- Preserve existing session functionality
- Add session isolation for workflow execution

#### 3. State Persistence Under Failures
**Risk**: Workflow state corruption during system failures
**Mitigation**:
- Atomic state updates
- Regular state backups
- State validation on load
- Recovery mechanisms for corrupted states

### Medium-Risk Areas

#### 1. Performance Impact
**Risk**: Workflow monitoring may impact system performance
**Mitigation**:
- Optimized polling intervals
- Efficient state management
- Resource usage monitoring

#### 2. Concurrent Workflow Handling
**Risk**: Multiple workflows may interfere with each other
**Mitigation**:
- Workflow isolation mechanisms
- Resource contention handling
- Clear workflow priority system

### Low-Risk Areas

#### 1. CLI Interface Changes
**Risk**: New commands may conflict with existing CLI
**Mitigation**: Backward compatibility preservation, clear command namespacing

#### 2. Documentation Gaps
**Risk**: Insufficient documentation for new features
**Mitigation**: Comprehensive documentation plan, examples, troubleshooting guides

## Success Criteria

### Functional Requirements
- ✅ Create issue-merge workflows via CLI
- ✅ Execute all four phases sequentially (develop, clear, review, merge)
- ✅ Detect command completion reliably
- ✅ Handle errors with interruption and resumption
- ✅ Track workflow progress and status
- ✅ Integrate with existing task queue system

### Performance Requirements  
- ✅ Workflow creation < 2 seconds
- ✅ Command execution monitoring < 5% CPU overhead
- ✅ State persistence < 1 second per update
- ✅ Resume from failure < 10 seconds

### Reliability Requirements
- ✅ Handle network interruptions gracefully
- ✅ Survive system restarts (persistent state)
- ✅ Detect and recover from command failures
- ✅ Maintain data integrity under all failure conditions

## Implementation Notes

### Code Quality Standards
- Follow existing Bash coding conventions (`set -euo pipefail`)
- Use structured logging for all workflow operations
- Maintain ShellCheck compliance
- Add comprehensive error messages

### Testing Approach
- Unit tests for all new functions
- Integration tests for workflow execution
- Mocking strategy for Claude CLI commands
- Performance testing for monitoring overhead

### Backward Compatibility
- Preserve all existing task queue functionality
- Maintain existing CLI command interface
- Ensure existing workflows continue to work
- Add new features as extensions, not replacements

---

**Implementation Timeline**: 5 days  
**Key Dependencies**: Claude CLI availability, tmux session management, GitHub API access  
**Next Steps**: Begin Phase 1 implementation with command execution foundation