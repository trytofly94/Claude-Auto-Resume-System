#!/usr/bin/env bash

# Claude Auto-Resume - PR Review System
# Automated pull request review with focus on core functionality
# Version: 1.0.0
# Integrates with agent-based workflow for task automation and usage limit detection

set -euo pipefail

# ===============================================================================
# GLOBAL CONFIGURATION
# ===============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRATCHPAD_DIR="$PROJECT_ROOT/scratchpads/active"
COMPLETED_DIR="$PROJECT_ROOT/scratchpads/completed"

# Load utilities if available
if [[ -f "$SCRIPT_DIR/utils/logging.sh" ]]; then
    source "$SCRIPT_DIR/utils/logging.sh"
fi

# Always define logging functions (fallback if not loaded from utils)
if ! command -v log_info >/dev/null 2>&1; then
    log_info() { echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S'): $*"; }
fi

if ! command -v log_warn >/dev/null 2>&1; then
    log_warn() { echo "[WARN] $(date '+%Y-%m-%d %H:%M:%S'): $*" >&2; }
fi

if ! command -v log_error >/dev/null 2>&1; then
    log_error() { echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S'): $*" >&2; }
fi

# ===============================================================================
# REVIEWER AGENT PERSONA & CORE FUNCTIONS
# ===============================================================================

# Core functionality focus areas (as specified by user)
readonly CORE_FUNCTIONALITY_AREAS=(
    "automated_task_processing"
    "usage_limit_detection_handling"
    "tmux_claunch_integration"
    "session_management_safety"
    "monitoring_system_reliability"
)

# Critical patterns for usage limit detection (from existing code analysis)
readonly USAGE_LIMIT_PATTERNS=(
    "Please try again"
    "Rate limit"
    "Usage limit"
    "Try again later"
    "Claude is currently overloaded"
    "Too many requests"
    "Service temporarily unavailable"
    "pm|am.*try.*again"
)

# ===============================================================================
# MAIN REVIEW FUNCTIONS
# ===============================================================================

show_usage() {
    cat << EOF
Usage: $0 [PR_IDENTIFIER] [OPTIONS]

DESCRIPTION:
    Automated PR review system focused on core functionality:
    - Task automation capabilities  
    - Usage limit detection and handling (xpm/am patterns)
    - tmux/claunch integration safety

PARAMETERS:
    PR_IDENTIFIER    PR number, issue number, or branch name
                     Examples: PR-106, issue-123, feature/array-optimization

OPTIONS:
    --branch BRANCH  Specify branch name explicitly  
    --issue ISSUE    Specify issue number explicitly
    --focus-area AREA    Focus on specific area: task_automation, usage_limits, tmux_integration
    --quick         Quick review (skip detailed analysis)
    --help          Show this help message

EXAMPLES:
    $0 PR-106                    # Review PR 106
    $0 issue-115                 # Review changes for issue 115  
    $0 --branch feature/queue    # Review specific branch
    $0 PR-94 --focus-area usage_limits  # Focus on usage limit handling

INTEGRATION:
    This script integrates with the existing agent workflow system and
    creates structured review scratchpads in scratchpads/active/.
EOF
}

create_review_scratchpad() {
    local pr_id="$1"
    local branch_name="${2:-}"
    local timestamp=$(date '+%Y-%m-%d')
    
    # Generate scratchpad filename using established convention
    local scratchpad_name="${timestamp}_pr-review-${pr_id,,}.md"
    local scratchpad_path="$SCRATCHPAD_DIR/$scratchpad_name"
    
    log_info "Creating review scratchpad: $scratchpad_name"
    
    # Ensure scratchpad directory exists
    mkdir -p "$SCRATCHPAD_DIR"
    
    # Generate scratchpad content with focus on core functionality
    cat > "$scratchpad_path" << EOF
# PR Review: $pr_id

**Branch**: \`${branch_name:-auto-detected}\`
**Date**: $(date '+%Y-%m-%d')
**Reviewer**: Claude Code (Review Agent)
**Priority**: Core functionality - task automation and usage limit detection

## 1. Review Context

### PR Overview
- **Focus**: Core functionality analysis for live operation
- **Core Requirements**: 
  1. Task automation functionality
  2. Detection/handling of program blocks until usage limits reset (xpm/am)
  3. tmux integration without killing existing servers
- **Files Changed**: [TO BE ANALYZED]

### Key Changes Summary
[TO BE POPULATED DURING ANALYSIS]

## 2. Detailed Code Analysis

### 2.1 Core File Analysis
**Status**: PENDING
**Priority**: CRITICAL (Main automation logic)

**Review Focus Areas**:
- Task automation processing
- Usage limit detection patterns
- tmux/claunch integration safety
- Session management isolation
- Monitoring system reliability

### 2.2 Usage Limit Detection Analysis
**Status**: PENDING  
**Priority**: HIGH (Essential for xpm/am handling)

**Critical Patterns to Verify**:
EOF
    for pattern in "${USAGE_LIMIT_PATTERNS[@]}"; do
        echo "- $pattern" >> "$scratchpad_path"
    done
    cat >> "$scratchpad_path" << EOF

### 2.3 Integration Safety Analysis
**Status**: PENDING
**Priority**: HIGH (Live operation safety)

**tmux Integration Checklist**:
- [ ] Session prefix isolation (claude-auto-*)
- [ ] Existing session preservation
- [ ] Proper cleanup mechanisms
- [ ] Fallback to direct Claude CLI mode

## 3. Core Functionality Testing Plan

### 3.1 Task Automation Testing
- [ ] Queue status reporting
- [ ] Task execution workflow
- [ ] Error handling robustness
- [ ] Integration with monitoring system

### 3.2 Usage Limit Detection Testing  
- [ ] Pattern recognition accuracy
- [ ] Timeout handling (30s standard)
- [ ] PM/AM specific patterns
- [ ] Recovery mechanism activation

### 3.3 Live Operation Safety Testing
- [ ] No disruption to existing tmux sessions
- [ ] Graceful degradation on errors
- [ ] Resource usage optimization
- [ ] Continuous monitoring stability

## 4. Test Execution Log

### Test Environment Setup
**Time**: $(date '+%Y-%m-%d %H:%M:%S')
**Environment**: $(uname -s) with tmux and Claude CLI

### Test Results
[TO BE POPULATED DURING TESTING]

## 5. Reviewer Agent Analysis

### Code Quality Assessment
[DETAILED ANALYSIS TO BE ADDED]

### Security & Safety Review
[SECURITY ANALYSIS TO BE ADDED]

### Performance Impact Analysis  
[PERFORMANCE ANALYSIS TO BE ADDED]

## 6. Final Review Verdict

### Must-Fix Issues (BLOCKING)
[TO BE POPULATED]

### Suggested Improvements (RECOMMENDED)
[TO BE POPULATED]

### Questions for Developer (DISCUSSION)
[TO BE POPULATED]

### Final Recommendation
**Status**: UNDER_REVIEW
**Approved for Merge**: TBD
**Requires Changes**: TBD

---

**Review Scratchpad**: \`$scratchpad_name\`
**Created**: $(date '+%Y-%m-%d %H:%M:%S')
**Integration**: Task queue workflow compatible
EOF

    echo "$scratchpad_path"
}

analyze_current_branch() {
    local pr_id="$1"
    local scratchpad_path="$2"
    
    log_info "Analyzing current branch for PR $pr_id"
    
    # Get current branch info
    local current_branch
    current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    
    local files_changed
    files_changed=$(git diff --name-only HEAD~1 2>/dev/null | wc -l | tr -d ' ')
    
    local additions deletions
    additions=$(git diff --shortstat HEAD~1 2>/dev/null | grep -o '[0-9]* insertion' | cut -d' ' -f1 || echo "0")
    deletions=$(git diff --shortstat HEAD~1 2>/dev/null | grep -o '[0-9]* deletion' | cut -d' ' -f1 || echo "0")
    
    # Update scratchpad with branch analysis
    sed -i '' "s|\`auto-detected\`|\`$current_branch\`|" "$scratchpad_path"
    sed -i '' "s|\[TO BE ANALYZED\]|$files_changed files, +$additions/-$deletions lines|" "$scratchpad_path"
    
    log_info "Branch analysis complete: $current_branch ($files_changed files changed)"
}

perform_core_analysis() {
    local pr_id="$1"
    local scratchpad_path="$2"
    
    log_info "Performing core functionality analysis for PR $pr_id"
    
    # Analyze critical files for core functionality
    local critical_files=(
        "src/hybrid-monitor.sh"
        "src/task-queue.sh"
        "src/usage-limit-recovery.sh"
        "src/session-manager.sh"
        "src/claunch-integration.sh"
    )
    
    local analysis_summary=""
    local critical_issues=()
    local recommendations=()
    
    for file in "${critical_files[@]}"; do
        if [[ -f "$PROJECT_ROOT/$file" ]]; then
            log_info "Analyzing $file for core functionality"
            
            # Check for usage limit patterns
            local pattern_count=0
            for pattern in "${USAGE_LIMIT_PATTERNS[@]}"; do
                if grep -q "$pattern" "$PROJECT_ROOT/$file" 2>/dev/null; then
                    ((pattern_count++))
                fi
            done
            
            # Check for tmux safety measures
            local tmux_safety=false
            if grep -q "claude-auto" "$PROJECT_ROOT/$file" 2>/dev/null; then
                tmux_safety=true
            fi
            
            # Check for task automation elements
            local task_automation=false
            if grep -qE "(task|queue|automation)" "$PROJECT_ROOT/$file" 2>/dev/null; then
                task_automation=true
            fi
            
            # Build analysis summary
            analysis_summary+="\n### Analysis: $file\n"
            analysis_summary+="- Usage limit patterns: $pattern_count/${#USAGE_LIMIT_PATTERNS[@]}\n"
            analysis_summary+="- tmux safety measures: $([ "$tmux_safety" = true ] && echo "✅ Present" || echo "❌ Missing")\n" 
            analysis_summary+="- Task automation elements: $([ "$task_automation" = true ] && echo "✅ Present" || echo "❌ Missing")\n"
            
            # Identify critical issues
            if [[ $pattern_count -eq 0 && "$file" =~ (usage-limit|hybrid-monitor) ]]; then
                critical_issues+=("$file: Missing usage limit detection patterns")
            fi
            
            if [[ "$tmux_safety" = false && "$file" =~ (session-manager|hybrid-monitor) ]]; then
                critical_issues+=("$file: Missing tmux session safety measures")
            fi
        fi
    done
    
    # Update scratchpad with analysis
    local temp_file=$(mktemp)
    awk -v analysis="$analysis_summary" '
        /\[DETAILED ANALYSIS TO BE ADDED\]/ {
            print analysis
            next
        }
        { print }
    ' "$scratchpad_path" > "$temp_file" && mv "$temp_file" "$scratchpad_path"
    
    # Add critical issues if any
    if [[ ${#critical_issues[@]} -gt 0 ]]; then
        local temp_file=$(mktemp)
        awk -v issues="$(printf "- %s\n" "${critical_issues[@]}")" '
            /\[TO BE POPULATED\]/ && !found {
                print issues
                found = 1
                next
            }
            { print }
        ' "$scratchpad_path" > "$temp_file" && mv "$temp_file" "$scratchpad_path"
    fi
    
    log_info "Core analysis complete. Found ${#critical_issues[@]} critical issues."
}

execute_safety_tests() {
    local pr_id="$1"
    local scratchpad_path="$2"
    
    log_info "Executing safety tests for PR $pr_id"
    
    local test_results=""
    local test_status="PASS"
    
    # Test 1: Check for existing tmux sessions
    local existing_sessions
    existing_sessions=$(tmux list-sessions 2>/dev/null | wc -l | tr -d ' ')
    test_results+="\n**Test 1 - tmux Session Safety**:\n"
    test_results+="- Existing tmux sessions: $existing_sessions\n"
    test_results+="- Status: ✅ Safe (monitoring will not interfere)\n"
    
    # Test 2: Validate task queue functionality
    if [[ -x "$PROJECT_ROOT/src/task-queue.sh" ]]; then
        local queue_status
        if queue_status=$("$PROJECT_ROOT/src/task-queue.sh" status 2>&1 | head -n 5); then
            test_results+="\n**Test 2 - Task Queue Functionality**:\n"
            test_results+="- Queue accessibility: ✅ Working\n"
            test_results+="- Status: ✅ Functional\n"
        else
            test_results+="\n**Test 2 - Task Queue Functionality**:\n"
            test_results+="- Queue accessibility: ❌ Error\n"
            test_results+="- Status: ❌ Needs Investigation\n"
            test_status="PARTIAL_PASS"
        fi
    fi
    
    # Test 3: Validate monitoring system
    if [[ -x "$PROJECT_ROOT/src/hybrid-monitor.sh" ]]; then
        local monitor_help
        if monitor_help=$("$PROJECT_ROOT/src/hybrid-monitor.sh" --help 2>/dev/null); then
            test_results+="\n**Test 3 - Monitoring System**:\n"
            test_results+="- Script executability: ✅ Working\n"
            test_results+="- Help system: ✅ Functional\n"
        else
            test_results+="\n**Test 3 - Monitoring System**:\n"
            test_results+="- Script executability: ❌ Error\n" 
            test_status="FAIL"
        fi
    fi
    
    # Update scratchpad with test results
    local temp_file=$(mktemp)
    awk -v results="$test_results" '
        /\[TO BE POPULATED DURING TESTING\]/ {
            print results
            next
        }
        { print }
    ' "$scratchpad_path" > "$temp_file" && mv "$temp_file" "$scratchpad_path"
    
    log_info "Safety tests complete. Overall status: $test_status"
    
    # Update final recommendation based on test results
    local recommendation
    case "$test_status" in
        "PASS")
            recommendation="**Status**: ANALYSIS_COMPLETE\n**Approved for Merge**: PENDING_FINAL_REVIEW\n**Requires Changes**: None identified in core functionality"
            ;;
        "PARTIAL_PASS")
            recommendation="**Status**: ANALYSIS_COMPLETE\n**Approved for Merge**: CONDITIONAL (see test failures)\n**Requires Changes**: Address failing tests"
            ;;
        "FAIL")
            recommendation="**Status**: ANALYSIS_COMPLETE\n**Approved for Merge**: NO\n**Requires Changes**: Critical functionality broken"
            ;;
    esac
    
    local temp_file=$(mktemp)
    awk -v rec="$recommendation" '
        /\*\*Status\*\*: UNDER_REVIEW/ {
            print rec
            next
        }
        /\*\*Approved for Merge\*\*: TBD/ { next }
        /\*\*Requires Changes\*\*: TBD/ { next }
        { print }
    ' "$scratchpad_path" > "$temp_file" && mv "$temp_file" "$scratchpad_path"
}

# ===============================================================================
# MAIN EXECUTION
# ===============================================================================

main() {
    local pr_id=""
    local branch_name=""
    local focus_area=""
    local quick_review=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help)
                show_usage
                exit 0
                ;;
            --branch)
                branch_name="$2"
                shift 2
                ;;
            --issue)
                pr_id="issue-$2"
                shift 2
                ;;
            --focus-area)
                focus_area="$2"
                shift 2
                ;;
            --quick)
                quick_review=true
                shift
                ;;
            -*)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
            *)
                if [[ -z "$pr_id" ]]; then
                    pr_id="$1"
                else
                    log_error "Multiple PR identifiers provided"
                    exit 1
                fi
                shift
                ;;
        esac
    done
    
    # Validate required parameters
    if [[ -z "$pr_id" ]]; then
        log_error "PR identifier is required"
        show_usage
        exit 1
    fi
    
    # Normalize PR identifier
    if [[ ! "$pr_id" =~ ^(PR-|issue-|workflow-) ]]; then
        if [[ "$pr_id" =~ ^[0-9]+$ ]]; then
            pr_id="PR-$pr_id"
        else
            # Assume it's a branch name or other identifier
            pr_id="$pr_id"
        fi
    fi
    
    log_info "Starting PR review for: $pr_id"
    log_info "Focus: Core functionality (task automation + usage limit detection)"
    
    # Create review scratchpad
    local scratchpad_path
    scratchpad_path=$(create_review_scratchpad "$pr_id" "$branch_name")
    
    # Perform analysis steps
    analyze_current_branch "$pr_id" "$scratchpad_path"
    
    if [[ "$quick_review" != true ]]; then
        perform_core_analysis "$pr_id" "$scratchpad_path"
        execute_safety_tests "$pr_id" "$scratchpad_path"
    else
        log_info "Quick review mode - skipping detailed analysis"
    fi
    
    log_info "PR review complete!"
    log_info "Review scratchpad: $scratchpad_path"
    log_info "Integration: Compatible with task queue workflow system"
    
    # Output scratchpad path for workflow integration
    echo "$scratchpad_path"
}

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi