# Issue #98: JSON Date String Formatting Error in Workflow Execution

**Created**: 2025-08-31
**Issue**: GitHub Issue #98
**Priority**: LOW (but blocks workflow automation)
**Status**: ACTIVE PLANNING

## Problem Analysis

### Issue Description
JSON parsing errors due to improper date string formatting in workflow execution, specifically in the `execute_issue_merge_workflow()` function in `src/queue/workflow.sh`. Date strings are not properly escaped in jq commands, leading to JSON syntax errors.

### Root Cause Analysis

After examining `src/queue/workflow.sh`, I identified **4 critical vulnerabilities** where date strings are improperly embedded into jq commands:

1. **Line 233**: `'.steps[' "$step_index" '].status = "completed" | .steps[' "$step_index" '].completed_at = "' "$(date -Iseconds)" '"'`
2. **Line 241**: `'.steps[' "$step_index" '].status = "failed" | .steps[' "$step_index" '].failed_at = "' "$(date -Iseconds)" '"'`  
3. **Line 271**: `'.completed_at = "' "$(date -Iseconds)" '"'`
4. **Line 530**: Uses `--arg` properly (this one is actually correct!)

### Technical Issues

The problematic pattern is **direct string interpolation** of `$(date -Iseconds)` into jq filter strings:

```bash
# PROBLEMATIC - Direct string interpolation:
jq '.field = "' "$(date -Iseconds)" '"'

# CORRECT - Using jq --arg:
jq --arg timestamp "$(date -Iseconds)" '.field = $timestamp'
```

**Why this fails:**
- If the date string contains special characters that jq interprets as syntax
- Potential for command injection
- Breaks JSON parsing when date format changes
- Not following established project patterns

### Project Context Analysis

**Positive patterns found in codebase:**
- `src/queue/workflow.sh:54`: ✅ Uses `--arg created_at "$(date -Iseconds)"`
- `src/queue/workflow.sh:530`: ✅ Uses `--arg cancelled_at "$(date -Iseconds)"`  
- `src/queue/cleanup.sh:82`: ✅ Uses `--arg completed_at "$(date -Iseconds)"`
- `src/queue/monitoring.sh:98`: ✅ Uses `--arg timestamp "$timestamp"`

**Inconsistent pattern in the same file:**
The workflow.sh file mixes both approaches - some places use proper `--arg` escaping while others use dangerous string interpolation.

## Implementation Plan

### Phase 1: Fix Date String Escaping

**Files to modify:**
- `src/queue/workflow.sh` (lines 233, 241, 271)

**Changes required:**

1. **Line 233** - Step completion timestamp:
   ```bash
   # BEFORE:
   workflow_data=$(echo "$workflow_data" | jq \
       '.steps[' "$step_index" '].status = "completed" | .steps[' "$step_index" '].completed_at = "' "$(date -Iseconds)" '"')
   
   # AFTER:
   workflow_data=$(echo "$workflow_data" | jq \
       --arg completed_at "$(date -Iseconds)" \
       '.steps['"$step_index"'].status = "completed" | .steps['"$step_index"'].completed_at = $completed_at')
   ```

2. **Line 241** - Step failure timestamp:
   ```bash
   # BEFORE:
   workflow_data=$(echo "$workflow_data" | jq \
       '.steps[' "$step_index" '].status = "failed" | .steps[' "$step_index" '].failed_at = "' "$(date -Iseconds)" '"')
   
   # AFTER:
   workflow_data=$(echo "$workflow_data" | jq \
       --arg failed_at "$(date -Iseconds)" \
       '.steps['"$step_index"'].status = "failed" | .steps['"$step_index"'].failed_at = $failed_at')
   ```

3. **Line 271** - Workflow completion timestamp:
   ```bash
   # BEFORE:
   workflow_data=$(echo "$workflow_data" | jq '.completed_at = "' "$(date -Iseconds)" '"')
   
   # AFTER:
   workflow_data=$(echo "$workflow_data" | jq \
       --arg completed_at "$(date -Iseconds)" \
       '.completed_at = $completed_at')
   ```

### Phase 2: Enhanced Error Handling

**Add JSON validation and error handling:**

1. Create helper function for safe jq operations:
   ```bash
   safe_jq_update() {
       local input_data="$1"
       local jq_filter="$2"
       shift 2
       local jq_args=("$@")
       
       local result
       if result=$(echo "$input_data" | jq "${jq_args[@]}" "$jq_filter" 2>/dev/null); then
           echo "$result"
           return 0
       else
           log_error "JSON update failed: $jq_filter"
           return 1
       fi
   }
   ```

2. Add validation for critical workflow updates
3. Implement graceful degradation on JSON parsing errors

### Phase 3: Testing Strategy

**Test Coverage Required:**

1. **Unit Tests** (`tests/unit/test-workflow-date-handling.bats`):
   - Test date string formatting with various timestamp formats
   - Test JSON parsing with edge cases (special characters in dates)
   - Test error handling when jq operations fail
   - Test workflow step completion/failure timestamp recording

2. **Integration Tests** (add to existing `tests/integration/test-task-queue-integration.bats`):
   - Full workflow execution with date timestamp validation
   - Verify JSON structure integrity after date operations
   - Test workflow persistence and recovery with timestamps

3. **Regression Tests**:
   - Ensure all existing workflow functionality continues to work
   - Validate that proper `--arg` patterns remain intact (lines 54, 530)

### Phase 4: Code Quality Improvements

**Standards Compliance:**
1. Ensure all changes pass ShellCheck validation
2. Follow project's bash standards (`set -euo pipefail`)
3. Maintain consistent code formatting
4. Update inline documentation where needed

**Performance Considerations:**
- Minimal overhead from additional error handling
- Maintain backward compatibility
- No breaking changes to workflow API

### Phase 5: Documentation Updates

**Documentation to update:**
1. Add comments to clarify the date handling approach
2. Update any relevant README sections about JSON handling
3. Document the safe_jq_update helper function (if implemented)

## Risk Assessment

**Impact**: LOW-MEDIUM
- Bug affects workflow automation but doesn't impact core session management
- Failure mode is visible (JSON parsing errors)
- No data corruption risk (only affects timestamps)

**Mitigation Strategy**:
- Implement safe fallback behavior
- Add comprehensive logging for debugging
- Maintain backward compatibility
- Test thoroughly before deployment

## Dependencies

**Required for implementation:**
- `jq` (already in use throughout project)
- Standard bash tools (`date`)
- Existing logging infrastructure (`src/utils/logging.sh`)

**Required for testing:**
- `bats` testing framework
- `make test` infrastructure
- Existing task queue test fixtures

## Success Criteria

1. ✅ All date string operations use proper `--arg` escaping
2. ✅ No JSON parsing errors in workflow execution
3. ✅ All existing tests continue to pass
4. ✅ New tests cover date handling edge cases
5. ✅ ShellCheck validation passes
6. ✅ Code follows project standards and patterns
7. ✅ No performance regression in workflow execution

## Implementation Steps

1. **Create feature branch**: `bugfix/issue-98-json-date-formatting`
2. **Fix the 3 problematic jq date operations** in `src/queue/workflow.sh`
3. **Add helper function for safe JSON operations** (optional enhancement)
4. **Write comprehensive tests** for date handling
5. **Run full test suite** to ensure no regressions
6. **Update documentation** as needed
7. **Create PR** linking to issue #98

---

**Next Phase**: CREATOR - Implement the fixes outlined in this plan