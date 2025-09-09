#!/usr/bin/env bash

# Claude Auto-Resume - Path Resolution Module  
# Dynamic path resolution for global vs local execution
# Version: 2.0.0
# Issue: #88

set -euo pipefail

# ===============================================================================
# PATH RESOLUTION SYSTEM
# ===============================================================================

# Source the installation path utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/installation-path.sh"

# Initialize path resolution system
initialize_path_resolver() {
    # Set global variables for commonly used paths
    export CLAUDE_INSTALLATION_DIR="$(get_installation_directory)"
    export CLAUDE_SRC_DIR="$(get_src_directory)"
    export CLAUDE_CONFIG_DIR="$(get_config_directory)"
    export CLAUDE_SCRIPTS_DIR="$(get_scripts_directory)"
    export CLAUDE_LOGS_DIR="$(get_logs_directory)"
    
    # Ensure logs directory exists
    mkdir -p "$CLAUDE_LOGS_DIR"
    
    return 0
}

# Resolve path for a specific resource
resolve_resource_path() {
    local resource="$1"
    local base_dir="${2:-$CLAUDE_INSTALLATION_DIR}"
    
    # Handle absolute paths
    if [[ "$resource" =~ ^/ ]]; then
        echo "$resource"
        return 0
    fi
    
    # Construct path relative to base directory
    local resolved_path="$base_dir/$resource"
    
    # Verify path exists for critical resources
    if [[ ! -e "$resolved_path" ]]; then
        echo "WARNING: Resource not found: $resolved_path" >&2
        return 1
    fi
    
    echo "$resolved_path"
}

# Get configuration directory (supports both global and local)
get_effective_config_directory() {
    if is_global_installation; then
        # For global installations, check for user config first
        local user_config_dir="$HOME/.claude-auto-resume"
        if [[ -d "$user_config_dir" ]]; then
            echo "$user_config_dir"
        else
            # Fall back to installation config
            echo "$CLAUDE_CONFIG_DIR"
        fi
    else
        # For local installations, use project config
        echo "$CLAUDE_CONFIG_DIR"
    fi
}

# Get logs directory (supports both global and local)
get_effective_logs_directory() {
    if is_global_installation; then
        # For global installations, use user-specific logs
        local user_logs_dir="$HOME/.claude-auto-resume/logs"
        mkdir -p "$user_logs_dir"
        echo "$user_logs_dir"
    else
        # For local installations, use project logs
        echo "$CLAUDE_LOGS_DIR"
    fi
}

# Resolve configuration file path
resolve_config_file() {
    local config_file="${1:-default.conf}"
    local config_dir="$(get_effective_config_directory)"
    
    # Check user-specific config first (global installation)
    if is_global_installation; then
        local user_config="$HOME/.claude-auto-resume/$config_file"
        if [[ -f "$user_config" ]]; then
            echo "$user_config"
            return 0
        fi
    fi
    
    # Fall back to installation config
    local install_config="$config_dir/$config_file"
    if [[ -f "$install_config" ]]; then
        echo "$install_config"
        return 0
    fi
    
    echo "ERROR: Config file not found: $config_file" >&2
    return 1
}

# Source a script with proper path resolution
source_script() {
    local script_path="$1"
    local resolved_path
    
    # Try to resolve the script path
    if resolved_path="$(resolve_resource_path "$script_path")"; then
        source "$resolved_path"
        return 0
    else
        echo "ERROR: Cannot source script: $script_path" >&2
        return 1
    fi
}

# Execute a script with proper path resolution
execute_script() {
    local script_path="$1"
    shift # Remove script_path from arguments
    local resolved_path
    
    # Try to resolve the script path
    if resolved_path="$(resolve_resource_path "$script_path")"; then
        exec "$resolved_path" "$@"
    else
        echo "ERROR: Cannot execute script: $script_path" >&2
        return 1
    fi
}

# Set up PATH for finding related scripts
setup_script_path() {
    local script_dirs=(
        "$CLAUDE_SRC_DIR"
        "$CLAUDE_SCRIPTS_DIR"
        "$CLAUDE_SRC_DIR/utils"
        "$CLAUDE_SRC_DIR/queue"
    )
    
    # Add script directories to PATH if not already present
    for dir in "${script_dirs[@]}"; do
        if [[ -d "$dir" ]] && [[ ":$PATH:" != *":$dir:"* ]]; then
            export PATH="$dir:$PATH"
        fi
    done
}

# Working directory context detection
get_working_directory_context() {
    local current_dir="$(pwd)"
    
    # Check if we're in a project with local task queue
    local context_info="{}"
    
    # Look for .claude-tasks directory (local queue)
    if [[ -d "$current_dir/.claude-tasks" ]]; then
        context_info=$(jq -n \
            --arg type "project_with_local_queue" \
            --arg path "$current_dir" \
            --arg queue_path "$current_dir/.claude-tasks" \
            '{"type": $type, "path": $path, "queue_path": $queue_path}')
    # Look for .git directory (git project)
    elif [[ -d "$current_dir/.git" ]]; then
        context_info=$(jq -n \
            --arg type "git_project" \
            --arg path "$current_dir" \
            '{"type": $type, "path": $path}')
    else
        # Regular directory
        context_info=$(jq -n \
            --arg type "regular_directory" \
            --arg path "$current_dir" \
            '{"type": $type, "path": $path}')
    fi
    
    echo "$context_info"
}

# Debug function for path resolution
debug_path_resolution() {
    echo "=== Path Resolution Debug Information ==="
    echo "Installation directory: $CLAUDE_INSTALLATION_DIR"
    echo "Source directory: $CLAUDE_SRC_DIR"
    echo "Config directory: $CLAUDE_CONFIG_DIR"
    echo "Effective config directory: $(get_effective_config_directory)"
    echo "Scripts directory: $CLAUDE_SCRIPTS_DIR"
    echo "Logs directory: $CLAUDE_LOGS_DIR"
    echo "Effective logs directory: $(get_effective_logs_directory)"
    echo "Working directory context:"
    get_working_directory_context | jq .
    echo "Current PATH additions:"
    echo "$PATH" | tr ':' '\n' | grep claude || echo "(none)"
    echo "=========================================="
}

# Initialization check
ensure_path_resolver_initialized() {
    if [[ -z "${CLAUDE_INSTALLATION_DIR:-}" ]]; then
        initialize_path_resolver
    fi
}

# Export functions for use by other scripts
export -f initialize_path_resolver
export -f resolve_resource_path
export -f get_effective_config_directory
export -f get_effective_logs_directory
export -f resolve_config_file
export -f source_script
export -f setup_script_path
export -f get_working_directory_context
export -f debug_path_resolution
export -f ensure_path_resolver_initialized