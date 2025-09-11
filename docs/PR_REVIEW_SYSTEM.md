# PR Review System Documentation

## Overview

The Claude Auto-Resume PR Review System provides automated pull request reviews with a focus on core functionality: **task automation** and **usage limit detection/handling**. It integrates seamlessly with the existing agent-based workflow and monitoring infrastructure.

## Key Components

### 1. Core Review Script (`src/pr-review.sh`)
- **Primary Purpose**: Automated PR analysis focused on live operation requirements
- **Core Focus Areas**:
  - Task automation processing capabilities
  - Usage limit detection and recovery (xpm/am patterns) 
  - tmux/claunch integration safety
  - Session management isolation
  - Monitoring system reliability

### 2. Command Wrapper (`review`)
- **Purpose**: Provides `/review` command functionality for agent workflows
- **Usage**: `./review PR-106` or `./review issue-123`

### 3. Integration Module (`src/review-integration.sh`) 
- **Purpose**: Integrates review system with task queue and monitoring infrastructure
- **Functions**:
  - Workflow command handling
  - Task queue integration
  - Error handling and status reporting

## Usage Examples

### Direct Review Execution
```bash
# Quick review of current branch
./review PR-115 --quick

# Full review with specific focus
./review issue-106 --focus-area task_automation

# Branch-specific review
./review --branch feature/array-optimization

# Issue-specific review
./review --issue 94
```

### Workflow Integration
The review system integrates with existing workflow tasks in the task queue:
```json
{
  "phase": "review",
  "command": "/review PR-106", 
  "description": "Review PR for issue 106"
}
```

### Task Queue Integration
```bash
# Add review to task queue
./src/review-integration.sh add_to_queue PR-106 high

# Execute workflow review command
./src/review-integration.sh handle_workflow "/review PR-106"
```

## Review Scratchpad Format

Reviews create structured scratchpads in `scratchpads/active/` with the following sections:

### 1. Review Context
- PR overview with focus on core functionality
- Files changed analysis  
- Key changes summary

### 2. Detailed Code Analysis
- **Core File Analysis**: Critical files for task automation
- **Usage Limit Detection**: Validation of 8 critical patterns
- **Integration Safety**: tmux session isolation and safety measures

### 3. Core Functionality Testing Plan
- Task automation testing
- Usage limit detection testing  
- Live operation safety testing

### 4. Test Execution Log
- Automated safety tests
- Task queue functionality validation
- Monitoring system checks

### 5. Reviewer Agent Analysis  
- Code quality assessment
- Security & safety review
- Performance impact analysis

### 6. Final Review Verdict
- Must-fix issues (BLOCKING)
- Suggested improvements (RECOMMENDED)
- Questions for developer (DISCUSSION)
- Final recommendation

## Critical Usage Limit Patterns

The system validates these essential patterns for xpm/am handling:

1. `"Please try again"`
2. `"Rate limit"`
3. `"Usage limit"`
4. `"Try again later"`
5. `"Claude is currently overloaded"`
6. `"Too many requests"`
7. `"Service temporarily unavailable"`
8. `"pm|am.*try.*again"`

## Integration with Monitoring System

### tmux Safety Measures
- **Session Prefix**: Uses `claude-auto-*` prefix for isolation
- **Existing Session Preservation**: Never disrupts existing sessions
- **Cleanup Mechanisms**: Proper session cleanup on completion
- **Fallback Mode**: Direct Claude CLI if tmux unavailable

### Task Queue Compatibility
- **Status Reporting**: JSON-compatible output for monitoring
- **Error Handling**: Proper exit codes and error messages
- **Timeout Management**: Configurable timeouts (default: 30 minutes)
- **Completion Markers**: Uses `REVIEW_SUCCESS` for task completion

## Reviewer Agent Persona

The system embodies a **detailed and constructive reviewer agent** with these characteristics:

- **Quality Focus**: Deep analysis of code readability, best practices, and performance
- **Security Awareness**: Proactive identification of security vulnerabilities
- **Contextual Understanding**: Tests coverage and documentation requirements
- **Constructive Communication**: Solution-oriented, respectful feedback
- **Core Functionality Priority**: Special focus on task automation and usage limit handling

## Error Handling & Recovery

### Graceful Degradation
- Script continues with warnings if non-critical components fail
- Quick mode available for faster reviews when needed
- Comprehensive logging for debugging

### Integration Safeguards  
- Validates task queue availability before integration
- Checks monitoring system status before execution
- Provides fallback modes for missing dependencies

## Performance Considerations

### Optimization Features
- **Quick Mode**: Skip detailed analysis for faster results
- **Focus Areas**: Target specific functionality areas
- **Minimal Dependencies**: Works with core system components only
- **Efficient Processing**: Streamlined analysis for live operation needs

### Resource Management
- **Timeout Controls**: Prevents hanging processes
- **Memory Efficient**: Minimal memory footprint
- **Clean Output**: Structured results for easy parsing

## Live Operation Safety

The PR review system is specifically designed for safe operation alongside the existing monitoring infrastructure:

- ✅ **No Session Interference**: Will not disrupt existing tmux sessions
- ✅ **Resource Conscious**: Minimal system resource usage
- ✅ **Error Containment**: Failures don't affect main monitoring loop
- ✅ **Integration Compatible**: Works with current task queue and workflow system

## Future Enhancements

### Planned Features (Not Currently Implemented)
- GitHub integration for automated PR comments
- Advanced security scanning integration  
- Performance benchmarking integration
- Multi-repository support

**Note**: Current focus is exclusively on core functionality required for live operation.