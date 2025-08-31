#!/usr/bin/env bash

# Claude Auto-Resume - Local Task Queue Module  
# Project-specific task queue management with .claude-tasks directory
# Version: 2.0.0-local-queue
# Issue: #91

set -euo pipefail

# ===============================================================================
# CONSTANTS AND CONFIGURATION
# ===============================================================================

# Local queue directory and file constants
readonly LOCAL_QUEUE_DIR_NAME=".claude-tasks"
readonly LOCAL_QUEUE_FILE="queue.json"
readonly LOCAL_CONFIG_FILE="config.json"  
readonly LOCAL_COMPLETED_FILE="completed.json"
readonly LOCAL_BACKUP_DIR="backups"

# Default configuration for new local queues
readonly DEFAULT_LOCAL_CONFIG='{
  "version": "1.0",
  "project_name": "",
  "created": "",
  "settings": {
    "auto_backup": true,
    "backup_retention_days": 30,
    "max_completed_tasks": 100,
    "priority_levels": 5,
    "completion_markers": ["TASK_COMPLETED", "FEATURE_READY", "BUG_FIXED"]
  },
  "integrations": {
    "github": {
      "enabled": false,
      "repo_url": "",
      "default_labels": ["enhancement", "task"]
    },
    "version_control": {
      "track_in_git": false,
      "ignore_completed": true
    }
  }
}'

# Default queue structure for new local queues
readonly DEFAULT_LOCAL_QUEUE='{
  "version": "1.0",
  "project": "",
  "created": "",
  "last_modified": "",
  "tasks": []
}'

# Default completed tasks structure
readonly DEFAULT_LOCAL_COMPLETED='{
  "version": "1.0", 
  "project": "",
  "completed_tasks": [],
  "statistics": {
    "total_completed": 0,
    "success_rate": 100.0,
    "average_duration": "0m"
  }
}'

# Global variables for local queue context
LOCAL_QUEUE_PATH=""
LOCAL_QUEUE_ACTIVE=false
LOCAL_PROJECT_NAME=""

# ===============================================================================
# CORE DETECTION FUNCTIONS
# ===============================================================================

# Detect local queue directory by walking up directory tree (similar to git)
detect_local_queue() {
    local current_dir="$PWD"
    local search_dir="$current_dir"
    
    log_debug "Starting local queue detection from: $current_dir"
    
    # Walk up directory tree looking for .claude-tasks
    while [[ "$search_dir" != "/" ]]; do
        local candidate_dir="$search_dir/$LOCAL_QUEUE_DIR_NAME"
        
        log_debug "Checking for local queue at: $candidate_dir"
        
        if [[ -d "$candidate_dir" ]]; then
            # Found .claude-tasks directory, validate structure
            if validate_local_queue_structure "$candidate_dir"; then
                LOCAL_QUEUE_PATH="$candidate_dir"
                LOCAL_QUEUE_ACTIVE=true
                LOCAL_PROJECT_NAME=$(get_project_name_from_config "$candidate_dir")
                
                log_info "Local queue detected: $candidate_dir (project: $LOCAL_PROJECT_NAME)"
                return 0
            else
                log_warn "Found .claude-tasks directory but structure is invalid: $candidate_dir"
            fi
        fi
        
        # Move up one directory
        search_dir="$(dirname "$search_dir")"
    done
    
    log_debug "No local queue found, will use global queue"
    LOCAL_QUEUE_ACTIVE=false
    return 1
}

# Check if local queue is currently active
is_local_queue_active() {
    [[ "$LOCAL_QUEUE_ACTIVE" == "true" && -n "$LOCAL_QUEUE_PATH" ]]
}

# Get current queue context (local or global)
get_queue_context() {
    if is_local_queue_active; then
        echo "local:$LOCAL_QUEUE_PATH"
    else
        echo "global"
    fi
}

# Force local queue context (used by CLI --local flag)
force_local_context() {
    if ! detect_local_queue; then
        log_error "No local queue found and --local flag specified"
        log_info "Use --init-local-queue to create a new local queue"
        return 1
    fi
    return 0
}

# Force global queue context (used by CLI --global flag)
force_global_context() {
    LOCAL_QUEUE_ACTIVE=false
    LOCAL_QUEUE_PATH=""
    LOCAL_PROJECT_NAME=""
    log_debug "Forced global queue context"
}

# ===============================================================================
# VALIDATION FUNCTIONS
# ===============================================================================

# Validate local queue directory structure
validate_local_queue_structure() {
    local queue_dir="$1"
    
    log_debug "Validating local queue structure: $queue_dir"
    
    # Check required files exist
    local required_files=(
        "$LOCAL_QUEUE_FILE"
        "$LOCAL_CONFIG_FILE"
    )
    
    for file in "${required_files[@]}"; do
        local file_path="$queue_dir/$file"
        if [[ ! -f "$file_path" ]]; then
            log_error "Missing required file in local queue: $file"
            return 1
        fi
        
        # Validate JSON structure
        if ! jq empty "$file_path" 2>/dev/null; then
            log_error "Invalid JSON in local queue file: $file"
            return 1
        fi
    done
    
    # Check backup directory exists
    if [[ ! -d "$queue_dir/$LOCAL_BACKUP_DIR" ]]; then
        log_warn "Backup directory missing, will create: $queue_dir/$LOCAL_BACKUP_DIR"
        mkdir -p "$queue_dir/$LOCAL_BACKUP_DIR" || {
            log_error "Failed to create backup directory"
            return 1
        }
    fi
    
    log_debug "Local queue structure validation passed"
    return 0
}

# Validate local queue file format
validate_local_queue_file() {
    local queue_file="$1"
    
    if [[ ! -f "$queue_file" ]]; then
        log_error "Local queue file does not exist: $queue_file"
        return 1
    fi
    
    # Check required JSON structure
    local required_fields=("version" "project" "created" "tasks")
    
    for field in "${required_fields[@]}"; do
        if ! jq -e ".$field" "$queue_file" >/dev/null 2>&1; then
            log_error "Missing required field in local queue: $field"
            return 1
        fi
    done
    
    # Validate tasks array structure
    local task_count=$(jq '.tasks | length' "$queue_file" 2>/dev/null || echo "0")
    log_debug "Local queue contains $task_count tasks"
    
    return 0
}

# ===============================================================================
# INITIALIZATION FUNCTIONS
# ===============================================================================

# Initialize new local queue in current directory
init_local_queue() {
    local project_name="${1:-$(basename "$PWD")}"
    local track_in_git="${2:-false}"
    
    log_info "Initializing local queue for project: $project_name"
    
    local queue_dir="$PWD/$LOCAL_QUEUE_DIR_NAME"
    
    # Check if already exists
    if [[ -d "$queue_dir" ]]; then
        if validate_local_queue_structure "$queue_dir"; then
            log_info "Local queue already exists and is valid: $queue_dir"
            detect_local_queue  # Activate the existing queue
            return 0
        else
            log_warn "Existing local queue has invalid structure, reinitializing"
        fi
    fi
    
    # Create directory structure
    mkdir -p "$queue_dir/$LOCAL_BACKUP_DIR" || {
        log_error "Failed to create local queue directory: $queue_dir"
        return 1
    }
    
    # Create configuration file
    local timestamp=$(date -Iseconds)
    local config_json=$(echo "$DEFAULT_LOCAL_CONFIG" | jq \
        --arg name "$project_name" \
        --arg created "$timestamp" \
        --arg track_git "$track_in_git" \
        '.project_name = $name | .created = $created | .integrations.version_control.track_in_git = ($track_git == "true")')
    
    echo "$config_json" > "$queue_dir/$LOCAL_CONFIG_FILE" || {
        log_error "Failed to create config file"
        return 1
    }
    
    # Create queue file
    local queue_json=$(echo "$DEFAULT_LOCAL_QUEUE" | jq \
        --arg name "$project_name" \
        --arg created "$timestamp" \
        --arg modified "$timestamp" \
        '.project = $name | .created = $created | .last_modified = $modified')
    
    echo "$queue_json" > "$queue_dir/$LOCAL_QUEUE_FILE" || {
        log_error "Failed to create queue file"
        return 1
    }
    
    # Create completed tasks file  
    local completed_json=$(echo "$DEFAULT_LOCAL_COMPLETED" | jq \
        --arg name "$project_name" \
        '.project = $name')
    
    echo "$completed_json" > "$queue_dir/$LOCAL_COMPLETED_FILE" || {
        log_error "Failed to create completed tasks file"
        return 1
    }
    
    # Setup git integration if requested
    if [[ "$track_in_git" == "false" ]]; then
        setup_git_ignore "$queue_dir"
    fi
    
    # Activate the new local queue
    detect_local_queue || {
        log_error "Failed to activate newly created local queue"
        return 1
    }
    
    log_info "Local queue initialized successfully: $queue_dir"
    log_info "Project: $project_name"
    log_info "Track in git: $track_in_git"
    
    return 0
}

# Setup .gitignore for local queue (if needed)
setup_git_ignore() {
    local queue_dir="$1"
    local project_root="$(dirname "$queue_dir")"
    local gitignore_file="$project_root/.gitignore"
    
    # Check if we're in a git repository
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        log_debug "Not a git repository, skipping .gitignore setup"
        return 0
    fi
    
    # Add .claude-tasks to .gitignore if not already present
    local ignore_pattern="$LOCAL_QUEUE_DIR_NAME/"
    
    if [[ -f "$gitignore_file" ]]; then
        if grep -Fxq "$ignore_pattern" "$gitignore_file"; then
            log_debug ".claude-tasks already in .gitignore"
            return 0
        fi
    fi
    
    echo "" >> "$gitignore_file"
    echo "# Claude Auto-Resume local task queue" >> "$gitignore_file"  
    echo "$ignore_pattern" >> "$gitignore_file"
    
    log_info "Added .claude-tasks to .gitignore"
}

# ===============================================================================
# UTILITY FUNCTIONS
# ===============================================================================

# Get project name from local config
get_project_name_from_config() {
    local queue_dir="$1"
    local config_file="$queue_dir/$LOCAL_CONFIG_FILE"
    
    if [[ -f "$config_file" ]]; then
        jq -r '.project_name // "unknown"' "$config_file" 2>/dev/null || echo "unknown"
    else
        echo "unknown"
    fi
}

# Get local queue file path
get_local_queue_file() {
    if is_local_queue_active; then
        echo "$LOCAL_QUEUE_PATH/$LOCAL_QUEUE_FILE"
    else
        return 1
    fi
}

# Get local config file path  
get_local_config_file() {
    if is_local_queue_active; then
        echo "$LOCAL_QUEUE_PATH/$LOCAL_CONFIG_FILE"
    else
        return 1
    fi
}

# Get local backup directory path
get_local_backup_dir() {
    if is_local_queue_active; then
        echo "$LOCAL_QUEUE_PATH/$LOCAL_BACKUP_DIR"
    else
        return 1
    fi
}

# Check if task exists in local queue
local_task_exists() {
    local task_id="$1"
    local queue_file
    
    queue_file=$(get_local_queue_file) || return 1
    
    jq -e ".tasks[] | select(.id == \"$task_id\")" "$queue_file" >/dev/null 2>&1
}

# Get local queue statistics
get_local_queue_stats() {
    local queue_file
    local config_file
    
    queue_file=$(get_local_queue_file) || return 1
    config_file=$(get_local_config_file) || return 1
    
    local project_name=$(jq -r '.project // "unknown"' "$queue_file")
    local task_count=$(jq '.tasks | length' "$queue_file")
    local pending_count=$(jq '[.tasks[] | select(.status == "pending")] | length' "$queue_file")
    local in_progress_count=$(jq '[.tasks[] | select(.status == "in_progress")] | length' "$queue_file")
    local completed_count=$(jq '[.tasks[] | select(.status == "completed")] | length' "$queue_file")
    local failed_count=$(jq '[.tasks[] | select(.status == "failed")] | length' "$queue_file")
    
    cat << EOF
{
  "context": "local",
  "project": "$project_name",
  "queue_path": "$LOCAL_QUEUE_PATH",
  "total_tasks": $task_count,
  "pending": $pending_count,
  "in_progress": $in_progress_count, 
  "completed": $completed_count,
  "failed": $failed_count,
  "last_modified": $(jq '.last_modified' "$queue_file")
}
EOF
}

# ===============================================================================
# LOGGING FUNCTIONS (fallback if not loaded)
# ===============================================================================

# Fallback logging functions if main logging module not loaded
if ! declare -f log_debug >/dev/null 2>&1; then
    log_debug() { echo "[LOCAL-QUEUE] [DEBUG] $*" >&2; }
    log_info() { echo "[LOCAL-QUEUE] [INFO] $*" >&2; }
    log_warn() { echo "[LOCAL-QUEUE] [WARN] $*" >&2; }
    log_error() { echo "[LOCAL-QUEUE] [ERROR] $*" >&2; }
fi

# ===============================================================================
# INITIALIZATION
# ===============================================================================

# Auto-detect local queue on module load (can be overridden)
if [[ "${AUTO_DETECT_LOCAL_QUEUE:-true}" == "true" ]]; then
    detect_local_queue || true  # Don't fail if no local queue found
fi

log_debug "Local queue module loaded (active: $LOCAL_QUEUE_ACTIVE, path: $LOCAL_QUEUE_PATH)"