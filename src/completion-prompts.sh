#!/usr/bin/env bash

# Claude Auto-Resume - Smart Completion Detection with /dev Command Integration  
# Prompt engineering and completion pattern management
# Version: 1.0.0 (Issue #90)

set -euo pipefail

# ===============================================================================
# COMPLETION MARKER GENERATION
# ===============================================================================

# Generate unique completion marker for a task
generate_completion_marker() {
    local description="$1"
    local task_type="${2:-custom}"
    local prefix=""
    
    # Use appropriate prefix based on task type
    case "$task_type" in
        "github_issue")
            prefix="ISSUE"
            ;;
        "github_pr")
            prefix="PR"
            ;;
        "workflow")
            prefix="WORKFLOW"
            ;;
        "custom"|*)
            prefix="TASK"
            ;;
    esac
    
    # Create marker from description (sanitize and shorten)
    local marker_suffix
    marker_suffix=$(echo "$description" | \
        tr '[:lower:]' '[:upper:]' | \
        sed 's/[^A-Z0-9 ]//g' | \
        tr ' ' '_' | \
        cut -c1-30 | \
        sed 's/_*$//')
    
    # Add timestamp for uniqueness
    local timestamp
    timestamp=$(date +%s)
    
    echo "${prefix}_${marker_suffix}_${timestamp}"
}

# Validate completion marker format
validate_completion_marker() {
    local marker="$1"
    
    # Check format: PREFIX_DESCRIPTION_TIMESTAMP
    if [[ ! "$marker" =~ ^[A-Z]+_[A-Z0-9_]+_[0-9]+$ ]]; then
        log_error "Invalid completion marker format: $marker"
        return 1
    fi
    
    return 0
}

# Check if completion marker is unique in current context
is_marker_unique() {
    local marker="$1"
    local context="${2:-global}"  # global or local
    
    # Check against existing tasks
    for task_id in "${!TASK_COMPLETION_MARKERS[@]}"; do
        if [[ "${TASK_COMPLETION_MARKERS[$task_id]}" == "$marker" ]]; then
            log_warn "Completion marker $marker already exists for task $task_id"
            return 1
        fi
    done
    
    return 0
}

# ===============================================================================
# PROMPT TEMPLATE GENERATION
# ===============================================================================

# Generate /dev command with completion marker
generate_dev_command() {
    local description="$1"
    local completion_marker="$2"
    local issue_number="${3:-}"
    
    local command="/dev \"$description\""
    
    # Add issue reference if provided
    if [[ -n "$issue_number" ]]; then
        command="/dev \"$description (addresses issue #$issue_number)\""
    fi
    
    # Note: completion marker will be injected via prompt engineering
    echo "$command"
}

# Generate /review command with completion marker
generate_review_command() {
    local description="$1"
    local completion_marker="$2"
    local context="${3:-}"
    
    local command="/review \"$description\""
    
    if [[ -n "$context" ]]; then
        command="/review \"$description ($context)\""
    fi
    
    echo "$command"
}

# Generate completion prompt for task
generate_completion_prompt() {
    local task_type="$1"
    local completion_marker="$2"
    local custom_patterns="${3:-}"
    
    local prompt=""
    
    case "$task_type" in
        "dev"|"development")
            prompt="When this development task is complete, please output exactly:"
            prompt+=$'\n'"\"###TASK_COMPLETE:${completion_marker}###\""
            ;;
        "review")
            prompt="When this code review is complete, please output exactly:"
            prompt+=$'\n'"\"###REVIEW_COMPLETE:${completion_marker}###\""
            ;;
        "custom")
            prompt="When this task is complete, please output exactly:"
            prompt+=$'\n'"\"###TASK_COMPLETE:${completion_marker}###\""
            ;;
    esac
    
    # Add custom patterns if provided
    if [[ -n "$custom_patterns" ]]; then
        prompt+=$'\n'$'\n'"Alternative completion indicators:"
        IFS='|' read -ra patterns <<< "$custom_patterns"
        for pattern in "${patterns[@]}"; do
            prompt+=$'\n'"- \"$pattern\""
        done
    fi
    
    echo "$prompt"
}

# ===============================================================================
# COMPLETION PATTERN MANAGEMENT
# ===============================================================================

# Get default completion patterns for task type
get_default_completion_patterns() {
    local task_type="$1"
    local marker="$2"
    
    local patterns=()
    
    case "$task_type" in
        "dev"|"development")
            patterns=(
                "###TASK_COMPLETE:${marker}###"
                "✅ Task completed successfully"
                "Development task completed"
                "Implementation finished"
            )
            ;;
        "review")
            patterns=(
                "###REVIEW_COMPLETE:${marker}###"
                "✅ Code review completed"
                "Review task completed"  
                "Code review finished"
            )
            ;;
        "custom")
            patterns=(
                "###TASK_COMPLETE:${marker}###"
                "✅ Task completed successfully"
                "Task completed"
                "Work finished"
            )
            ;;
        "github_issue")
            patterns=(
                "###TASK_COMPLETE:${marker}###"
                "✅ Issue resolved"
                "Issue has been resolved"
                "Problem solved"
            )
            ;;
    esac
    
    # Output as pipe-separated string
    printf "%s" "$(IFS='|'; echo "${patterns[*]}")"
}

# Parse user-defined completion patterns
parse_custom_patterns() {
    local patterns_string="$1"
    
    # Split on various delimiters and normalize
    local patterns
    patterns=$(echo "$patterns_string" | tr ',' '\n' | tr ';' '\n' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' | grep -v '^$')
    
    # Convert to pipe-separated format
    echo "$patterns" | tr '\n' '|' | sed 's/|$//'
}

# Combine default and custom patterns
combine_completion_patterns() {
    local task_type="$1"
    local marker="$2"
    local custom_patterns="${3:-}"
    
    local default_patterns
    default_patterns=$(get_default_completion_patterns "$task_type" "$marker")
    
    if [[ -n "$custom_patterns" ]]; then
        echo "${default_patterns}|${custom_patterns}"
    else
        echo "$default_patterns"
    fi
}

# ===============================================================================  
# PATTERN MATCHING AND DETECTION
# ===============================================================================

# Test if text matches completion patterns
test_completion_match() {
    local text="$1"
    local patterns="$2"
    local confidence_threshold="${3:-0.8}"
    
    IFS='|' read -ra pattern_array <<< "$patterns"
    local matches=0
    local total_patterns=${#pattern_array[@]}
    
    for pattern in "${pattern_array[@]}"; do
        if [[ -n "$pattern" ]] && echo "$text" | grep -q "$pattern"; then
            ((matches++))
            log_debug "Completion pattern matched: $pattern"
        fi
    done
    
    # Calculate confidence score
    local confidence
    confidence=$(echo "scale=2; $matches / $total_patterns" | bc -l 2>/dev/null || echo "0")
    
    log_debug "Completion detection: $matches/$total_patterns patterns matched (confidence: $confidence)"
    
    # Return success if confidence meets threshold
    if (( $(echo "$confidence >= $confidence_threshold" | bc -l 2>/dev/null) )); then
        return 0
    else
        return 1
    fi
}

# Extract completion marker from matched text
extract_completion_marker() {
    local text="$1"
    
    # Look for standard marker patterns
    local marker
    marker=$(echo "$text" | grep -o "###[A-Z_]*COMPLETE:[A-Z0-9_]*###" | head -n1 | sed 's/###[A-Z_]*COMPLETE:\([A-Z0-9_]*\)###/\1/')
    
    if [[ -n "$marker" ]]; then
        echo "$marker"
        return 0
    fi
    
    return 1
}

# ===============================================================================
# CONFIGURATION AND UTILITIES
# ===============================================================================

# Load completion detection configuration (Issue #114)
load_completion_config() {
    # Default configuration
    SMART_COMPLETION_ENABLED="${SMART_COMPLETION_ENABLED:-true}"
    COMPLETION_CONFIDENCE_THRESHOLD="${COMPLETION_CONFIDENCE_THRESHOLD:-0.8}"
    CUSTOM_PATTERN_TIMEOUT="${CUSTOM_PATTERN_TIMEOUT:-300}"
    FALLBACK_CONFIRMATION_ENABLED="${FALLBACK_CONFIRMATION_ENABLED:-true}"
    
    # Use centralized configuration loader if available
    if declare -f load_system_config >/dev/null 2>&1; then
        # Config should already be loaded by main process, but ensure it's loaded
        if [[ -z "${SYSTEM_CONFIG_LOADED:-}" ]]; then
            load_system_config || log_warn "Failed to load centralized config"
        fi
        
        # Get configuration values using centralized getter
        SMART_COMPLETION_ENABLED="$(get_config "SMART_COMPLETION_ENABLED" "${SMART_COMPLETION_ENABLED:-true}")"
        COMPLETION_CONFIDENCE_THRESHOLD="$(get_config "COMPLETION_CONFIDENCE_THRESHOLD" "${COMPLETION_CONFIDENCE_THRESHOLD:-0.8}")"
        CUSTOM_PATTERN_TIMEOUT="$(get_config "CUSTOM_PATTERN_TIMEOUT" "${CUSTOM_PATTERN_TIMEOUT:-300}")"
        FALLBACK_CONFIRMATION_ENABLED="$(get_config "FALLBACK_CONFIRMATION_ENABLED" "${FALLBACK_CONFIRMATION_ENABLED:-true}")"
    else
        # Fallback: Load from config file if available
        if [[ -f "$CLAUDE_CONFIG_DIR/default.conf" ]]; then
            source "$CLAUDE_CONFIG_DIR/default.conf"
        fi
    fi
}

# Export functions for use by other modules
export -f generate_completion_marker
export -f validate_completion_marker  
export -f is_marker_unique
export -f generate_dev_command
export -f generate_review_command
export -f generate_completion_prompt
export -f get_default_completion_patterns
export -f parse_custom_patterns
export -f combine_completion_patterns
export -f test_completion_match
export -f extract_completion_marker
export -f load_completion_config

# Load configuration when sourced
load_completion_config