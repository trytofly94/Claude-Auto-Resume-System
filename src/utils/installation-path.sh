#!/usr/bin/env bash

# Claude Auto-Resume - Installation Path Detection Module
# Handles dynamic path resolution for global vs local installation
# Version: 2.0.0
# Issue: #88

set -euo pipefail

# ===============================================================================
# INSTALLATION PATH DETECTION
# ===============================================================================

# Detect the installation directory of the claude-auto-resume system
detect_installation_path() {
    local script_path="${BASH_SOURCE[0]}"
    
    # Resolve symlinks to find actual installation location
    while [[ -L "$script_path" ]]; do
        script_path="$(readlink "$script_path")"
    done
    
    # Get the directory containing the script
    local script_dir="$(cd "$(dirname "$script_path")" && pwd)"
    
    # Navigate up to find the main installation directory
    # From src/utils/installation-path.sh -> Claude-Auto-Resume-System/
    local installation_dir="$(cd "$script_dir/../.." && pwd)"
    
    echo "$installation_dir"
}

# Get the directory containing the currently running script
get_script_directory() {
    local script_path="${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}"
    
    # Resolve symlinks
    while [[ -L "$script_path" ]]; do
        script_path="$(readlink "$script_path")"
    done
    
    cd "$(dirname "$script_path")" && pwd
}

# Determine if we're running from a global installation
is_global_installation() {
    local current_script="${0}"
    
    # Check if we're running via a symlink or PATH
    if [[ "$current_script" == "claude-auto-resume" ]] || \
       [[ "$current_script" =~ /usr/local/bin/claude-auto-resume$ ]] || \
       [[ "$current_script" =~ /bin/claude-auto-resume$ ]]; then
        return 0
    fi
    
    # Check if CLAUDE_AUTO_RESUME_HOME is set (global wrapper)
    if [[ -n "${CLAUDE_AUTO_RESUME_HOME:-}" ]]; then
        return 0
    fi
    
    return 1
}

# Get the installation directory, handling both global and local execution
get_installation_directory() {
    # First check if we have the environment variable (global installation)
    if [[ -n "${CLAUDE_AUTO_RESUME_HOME:-}" ]]; then
        echo "$CLAUDE_AUTO_RESUME_HOME"
        return 0
    fi
    
    # Otherwise detect from current script location
    detect_installation_path
}

# Validate that the installation has all required components
validate_installation() {
    local install_dir="${1:-$(get_installation_directory)}"
    local errors=()
    
    # Check for required directories
    local required_dirs=("src" "config" "scripts")
    for dir in "${required_dirs[@]}"; do
        if [[ ! -d "$install_dir/$dir" ]]; then
            errors+=("Missing required directory: $dir")
        fi
    done
    
    # Check for critical files
    local required_files=(
        "src/task-queue.sh"
        "src/hybrid-monitor.sh"
        "config/default.conf"
        "CLAUDE.md"
    )
    
    for file in "${required_files[@]}"; do
        if [[ ! -f "$install_dir/$file" ]]; then
            errors+=("Missing required file: $file")
        fi
    done
    
    # Report validation results
    if [[ ${#errors[@]} -eq 0 ]]; then
        echo "✅ Installation validation successful"
        echo "Installation directory: $install_dir"
        return 0
    else
        echo "❌ Installation validation failed:"
        printf '   - %s\n' "${errors[@]}"
        return 1
    fi
}

# Get path to a specific resource relative to installation
get_resource_path() {
    local resource="$1"
    local install_dir="$(get_installation_directory)"
    echo "$install_dir/$resource"
}

# Get paths for commonly used directories
get_src_directory() {
    get_resource_path "src"
}

get_config_directory() {
    get_resource_path "config"
}

get_scripts_directory() {
    get_resource_path "scripts"
}

get_logs_directory() {
    get_resource_path "logs"
}

# Debug function to show path resolution information
debug_installation_paths() {
    echo "=== Claude Auto-Resume Path Debug Information ==="
    echo "Current script: ${0}"
    echo "Script arguments: $*"
    echo "Is global installation: $(is_global_installation && echo "YES" || echo "NO")"
    echo "CLAUDE_AUTO_RESUME_HOME: ${CLAUDE_AUTO_RESUME_HOME:-"<not set>"}"
    echo "Installation directory: $(get_installation_directory)"
    echo "Src directory: $(get_src_directory)"
    echo "Config directory: $(get_config_directory)"
    echo "Scripts directory: $(get_scripts_directory)"
    echo "Logs directory: $(get_logs_directory)"
    echo "================================================"
}

# Export commonly used functions
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    # Only export when sourced, not when executed directly
    export -f detect_installation_path
    export -f get_script_directory
    export -f is_global_installation
    export -f get_installation_directory
    export -f validate_installation
    export -f get_resource_path
fi