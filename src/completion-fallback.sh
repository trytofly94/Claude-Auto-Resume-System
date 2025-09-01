#!/usr/bin/env bash

# Claude Auto-Resume - Smart Completion Fallback System
# Handles edge cases and provides intelligent fallback mechanisms
# Version: 1.0.0 (Issue #90)

set -euo pipefail

# Load completion prompts module
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/completion-prompts.sh"

# ===============================================================================
# FALLBACK CONFIGURATION
# ===============================================================================

# Default fallback timeouts (in seconds)
FALLBACK_DEV_TIMEOUT="${FALLBACK_DEV_TIMEOUT:-900}"      # 15 minutes for dev tasks
FALLBACK_REVIEW_TIMEOUT="${FALLBACK_REVIEW_TIMEOUT:-600}" # 10 minutes for reviews
FALLBACK_CUSTOM_TIMEOUT="${FALLBACK_CUSTOM_TIMEOUT:-600}" # 10 minutes for custom tasks
FALLBACK_GENERIC_TIMEOUT="${FALLBACK_GENERIC_TIMEOUT:-300}" # 5 minutes for generic tasks

# Fallback strategies
FALLBACK_STRATEGY="${FALLBACK_STRATEGY:-interactive}" # interactive, timeout, manual
FALLBACK_RETRY_COUNT="${FALLBACK_RETRY_COUNT:-2}"
FALLBACK_RETRY_DELAY="${FALLBACK_RETRY_DELAY:-30}"

# ===============================================================================
# TIMEOUT-BASED COMPLETION
# ===============================================================================

# Calculate timeout for task based on type and complexity
calculate_task_timeout() {
    local task_type="$1"
    local description="$2"
    local custom_timeout="${3:-}"
    
    # Use custom timeout if provided
    if [[ -n "$custom_timeout" && "$custom_timeout" -gt 0 ]]; then
        echo "$custom_timeout"
        return 0
    fi
    
    # Base timeout by task type
    local base_timeout
    case "$task_type" in
        "dev"|"development")
            base_timeout=$FALLBACK_DEV_TIMEOUT
            ;;
        "review")
            base_timeout=$FALLBACK_REVIEW_TIMEOUT
            ;;
        "custom")
            base_timeout=$FALLBACK_CUSTOM_TIMEOUT
            ;;
        *)
            base_timeout=$FALLBACK_GENERIC_TIMEOUT
            ;;
    esac
    
    # Adjust timeout based on description complexity
    local word_count
    word_count=$(echo "$description" | wc -w)
    
    # Add 60 seconds per 10 words over 5 words
    if (( word_count > 5 )); then
        local additional_time
        additional_time=$(( (word_count - 5) / 10 * 60 ))
        base_timeout=$((base_timeout + additional_time))
    fi
    
    # Look for complexity indicators
    if echo "$description" | grep -qi "\(implement\|create\|build\|develop\)"; then
        base_timeout=$((base_timeout + 300))  # Add 5 minutes for implementation tasks
    fi
    
    if echo "$description" | grep -qi "\(refactor\|migrate\|optimize\)"; then
        base_timeout=$((base_timeout + 600))  # Add 10 minutes for complex tasks
    fi
    
    echo "$base_timeout"
}

# Handle timeout-based completion
handle_timeout_completion() {
    local task_id="$1"
    local elapsed_time="$2"
    local max_timeout="$3"
    
    log_warn "Task $task_id reached timeout after ${elapsed_time}s (limit: ${max_timeout}s)"
    
    case "$FALLBACK_STRATEGY" in
        "interactive")
            return $(prompt_completion_confirmation "$task_id")
            ;;
        "timeout")
            log_info "Automatic timeout completion for task $task_id"
            return 0
            ;;
        "manual")
            log_info "Manual completion required for task $task_id"
            return 1
            ;;
        *)
            log_warn "Unknown fallback strategy: $FALLBACK_STRATEGY, using interactive"
            return $(prompt_completion_confirmation "$task_id")
            ;;
    esac
}

# ===============================================================================
# INTERACTIVE COMPLETION CONFIRMATION
# ===============================================================================

# Prompt user for completion confirmation
prompt_completion_confirmation() {
    local task_id="$1"
    local task_description
    
    # Get task description from metadata
    if [[ -n "${TASK_METADATA[$task_id]:-}" ]]; then
        task_description=$(echo "${TASK_METADATA[$task_id]}" | jq -r '.description // "Unknown task"')
    else
        task_description="Unknown task"
    fi
    
    log_info "Task completion confirmation needed for: $task_description"
    echo "========================================="
    echo "Task Completion Confirmation Required"
    echo "========================================="
    echo "Task ID: $task_id"
    echo "Description: $task_description"
    echo ""
    echo "The task has exceeded its expected completion time."
    echo "Please review the output and confirm completion status."
    echo ""
    
    # Show recent output if available
    show_recent_output "$task_id"
    
    while true; do
        echo -n "Has the task completed successfully? (y/n/r): "
        read -r response
        
        case "$response" in
            [Yy]*)
                log_info "User confirmed task $task_id completion"
                return 0
                ;;
            [Nn]*)
                log_info "User indicated task $task_id not completed"
                return 1
                ;;
            [Rr]*)
                echo "Retrying completion detection for 30 more seconds..."
                return 2  # Special return code for retry
                ;;
            *)
                echo "Please answer y(es), n(o), or r(etry)"
                ;;
        esac
    done
}

# Show recent output for task context
show_recent_output() {
    local task_id="$1"
    local log_file="$CLAUDE_LOGS_DIR/hybrid-monitor.log"
    
    if [[ -f "$log_file" ]]; then
        echo "Recent activity (last 10 lines):"
        echo "-----------------------------------"
        tail -n 10 "$log_file" | grep -E "(INFO|WARN|ERROR)" || echo "No recent activity found"
        echo ""
    fi
}

# ===============================================================================
# CONTEXT-AWARE COMPLETION HINTS
# ===============================================================================

# Analyze context to provide completion hints
analyze_completion_context() {
    local task_id="$1"
    local output_text="$2"
    local elapsed_time="$3"
    
    local hints=()
    
    # Check for common success indicators
    if echo "$output_text" | grep -qi "success\|complete\|done\|finished"; then
        hints+=("Found success indicators in output")
    fi
    
    # Check for error indicators  
    if echo "$output_text" | grep -qi "error\|fail\|exception"; then
        hints+=("WARNING: Found error indicators in output")
    fi
    
    # Check for waiting indicators
    if echo "$output_text" | grep -qi "waiting\|pending\|loading"; then
        hints+=("Task appears to be waiting or in progress")
    fi
    
    # Check execution time patterns
    if (( elapsed_time > 600 )); then  # More than 10 minutes
        hints+=("Long execution time suggests complex task")
    fi
    
    # Show hints if any found
    if (( ${#hints[@]} > 0 )); then
        echo "Context Analysis Hints:"
        echo "----------------------"
        for hint in "${hints[@]}"; do
            echo "• $hint"
        done
        echo ""
    fi
}

# ===============================================================================
# CONFIDENCE SCORING
# ===============================================================================

# Calculate completion confidence based on multiple factors
calculate_completion_confidence() {
    local output_text="$1"
    local patterns="$2"
    local elapsed_time="$3"
    local expected_time="$4"
    
    local confidence=0.0
    local factors=()
    
    # Pattern matching confidence (0.0 - 0.6)
    local pattern_matches=0
    local total_patterns=0
    
    IFS='|' read -ra pattern_array <<< "$patterns"
    total_patterns=${#pattern_array[@]}
    
    for pattern in "${pattern_array[@]}"; do
        if [[ -n "$pattern" ]] && echo "$output_text" | grep -q "$pattern"; then
            ((pattern_matches++))
        fi
    done
    
    if (( total_patterns > 0 )); then
        local pattern_confidence
        pattern_confidence=$(echo "scale=2; ($pattern_matches / $total_patterns) * 0.6" | bc -l 2>/dev/null || echo "0")
        confidence=$(echo "scale=2; $confidence + $pattern_confidence" | bc -l 2>/dev/null || echo "$confidence")
        factors+=("Pattern matching: $pattern_matches/$total_patterns")
    fi
    
    # Time-based confidence (0.0 - 0.2)
    local time_ratio
    time_ratio=$(echo "scale=2; $elapsed_time / $expected_time" | bc -l 2>/dev/null || echo "0")
    
    if (( $(echo "$time_ratio > 0.5 && $time_ratio < 2.0" | bc -l 2>/dev/null) )); then
        confidence=$(echo "scale=2; $confidence + 0.2" | bc -l 2>/dev/null || echo "$confidence")
        factors+=("Reasonable execution time")
    elif (( $(echo "$time_ratio >= 2.0" | bc -l 2>/dev/null) )); then
        confidence=$(echo "scale=2; $confidence + 0.1" | bc -l 2>/dev/null || echo "$confidence")
        factors+=("Extended execution time")
    fi
    
    # Context indicators confidence (0.0 - 0.2)
    if echo "$output_text" | grep -qi "success\|complete\|done\|✅"; then
        confidence=$(echo "scale=2; $confidence + 0.15" | bc -l 2>/dev/null || echo "$confidence")
        factors+=("Success indicators found")
    fi
    
    if echo "$output_text" | grep -qi "error\|fail\|exception"; then
        confidence=$(echo "scale=2; $confidence - 0.2" | bc -l 2>/dev/null || echo "$confidence")
        factors+=("Error indicators found (negative)")
    fi
    
    # Output final confidence and factors
    echo "Confidence: $confidence"
    for factor in "${factors[@]}"; do
        echo "• $factor"
    done
}

# ===============================================================================
# RETRY MECHANISM
# ===============================================================================

# Handle completion detection retry
retry_completion_detection() {
    local task_id="$1"
    local retry_count="${2:-1}"
    local max_retries="${3:-$FALLBACK_RETRY_COUNT}"
    
    if (( retry_count > max_retries )); then
        log_error "Maximum retry attempts ($max_retries) exceeded for task $task_id"
        return 1
    fi
    
    log_info "Retrying completion detection for task $task_id (attempt $retry_count/$max_retries)"
    
    # Wait before retry
    sleep "$FALLBACK_RETRY_DELAY"
    
    return 0
}

# ===============================================================================
# EDGE CASE HANDLERS
# ===============================================================================

# Handle session interruption during task execution
handle_session_interruption() {
    local task_id="$1"
    local interruption_time="$2"
    
    log_warn "Session interruption detected for task $task_id at $interruption_time"
    
    # Mark task for recovery
    if [[ -n "${TASK_METADATA[$task_id]:-}" ]]; then
        local updated_metadata
        updated_metadata=$(echo "${TASK_METADATA[$task_id]}" | jq '. + {"interrupted_at": "'$interruption_time'", "requires_recovery": true}')
        TASK_METADATA["$task_id"]="$updated_metadata"
    fi
    
    log_info "Task $task_id marked for recovery after session interruption"
}

# Handle partial completion detection
handle_partial_completion() {
    local task_id="$1" 
    local completion_percentage="${2:-0}"
    
    log_info "Partial completion detected for task $task_id: ${completion_percentage}%"
    
    if (( completion_percentage >= 80 )); then
        log_info "High completion percentage, prompting for confirmation"
        return $(prompt_completion_confirmation "$task_id")
    elif (( completion_percentage >= 50 )); then
        log_info "Moderate completion, extending timeout"
        return 2  # Retry with extended timeout
    else
        log_info "Low completion percentage, task likely still in progress"
        return 1
    fi
}

# ===============================================================================
# EXPORT FUNCTIONS
# ===============================================================================

export -f calculate_task_timeout
export -f handle_timeout_completion
export -f prompt_completion_confirmation
export -f show_recent_output
export -f analyze_completion_context
export -f calculate_completion_confidence
export -f retry_completion_detection
export -f handle_session_interruption
export -f handle_partial_completion