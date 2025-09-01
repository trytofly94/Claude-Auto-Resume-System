#!/usr/bin/env bash

# Module Loader - Central module loading system with guards and performance tracking
# Prevents duplicate sourcing and provides lazy loading capabilities
# Part of Issue #111 performance optimization
# Compatible with bash 3.2+ (macOS default)

# Strict error handling
set -euo pipefail

# Avoid self-loading
if [[ -n "${MODULE_LOADER_LOADED:-}" ]]; then
    return 0
fi

# Global module tracking (compatible with bash 3.2+)
# Format: "module1:path1|module2:path2|..."
LOADED_MODULES=""
# Format: "module1:time1|module2:time2|..."
MODULE_LOAD_TIMES=""

# Performance tracking
TOTAL_LOADING_TIME=0

# Get the repository root for reliable path resolution
get_repo_root() {
    local current_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    while [[ "$current_dir" != "/" ]]; do
        if [[ -f "$current_dir/CLAUDE.md" ]]; then
            echo "$current_dir"
            return 0
        fi
        current_dir=$(dirname "$current_dir")
    done
    # Fallback: assume we're in src/utils and go up two levels
    echo "$(dirname "$(dirname "$current_dir")")"
}

REPO_ROOT=$(get_repo_root)

# Module dependencies (hardcoded for compatibility)
get_module_dependencies() {
    local module_name="$1"
    case "$module_name" in
        "logging") echo "" ;;
        "terminal") echo "" ;;
        "network") echo "" ;;
        "session-display") echo "logging" ;;
        "clipboard") echo "logging" ;;
        "installation-path") echo "logging" ;;
        "cli-parser") echo "logging terminal" ;;
        "task-queue") echo "logging" ;;
        "queue/core") echo "logging" ;;
        "queue/cache") echo "logging queue/core" ;;
        "queue/locking") echo "logging" ;;
        "queue/persistence") echo "logging queue/core" ;;
        "queue/cleanup") echo "logging queue/core" ;;
        "queue/interactive") echo "logging terminal queue/core" ;;
        "queue/monitoring") echo "logging queue/core" ;;
        "queue/workflow") echo "logging queue/core queue/interactive" ;;
        *) echo "" ;;
    esac
}

# Check if a module is already loaded
is_module_loaded() {
    local module_name="$1"
    [[ "$LOADED_MODULES" =~ (^|[|])$module_name: ]]
}

# Add module to loaded list
add_to_loaded_modules() {
    local module_name="$1"
    local module_path="$2"
    if [[ -z "$LOADED_MODULES" ]]; then
        LOADED_MODULES="$module_name:$module_path"
    else
        LOADED_MODULES="$LOADED_MODULES|$module_name:$module_path"
    fi
}

# Add loading time
add_loading_time() {
    local module_name="$1"
    local load_time="$2"
    if [[ -z "$MODULE_LOAD_TIMES" ]]; then
        MODULE_LOAD_TIMES="$module_name:$load_time"
    else
        MODULE_LOAD_TIMES="$MODULE_LOAD_TIMES|$module_name:$load_time"
    fi
}

# Get loading time for module
get_loading_time() {
    local module_name="$1"
    if [[ "$MODULE_LOAD_TIMES" =~ (^|[|])$module_name:([^|]+) ]]; then
        echo "${BASH_REMATCH[2]}"
    else
        echo "0"
    fi
}

# Get normalized module name from path
normalize_module_name() {
    local module_path="$1"
    # Remove .sh extension and src/utils/ or src/ prefix
    local normalized
    normalized=$(basename "$module_path" .sh)
    
    # Handle queue modules specially
    if [[ "$module_path" =~ queue/ ]]; then
        normalized="queue/$(basename "$module_path" .sh)"
    fi
    
    echo "$normalized"
}

# Convert module name to file path
get_module_path() {
    local module_name="$1"
    local module_path
    
    # Handle different module types
    if [[ "$module_name" =~ ^queue/ ]]; then
        # Queue module
        module_path="$REPO_ROOT/src/$module_name.sh"
    elif [[ "$module_name" == "task-queue" ]]; then
        # Main task queue file
        module_path="$REPO_ROOT/src/task-queue.sh"
    else
        # Utility module
        module_path="$REPO_ROOT/src/utils/$module_name.sh"
    fi
    
    echo "$module_path"
}

# Track loading performance
track_loading_performance() {
    local module_name="$1"
    local start_time="$2"
    local end_time="$3"
    
    local load_time=0
    if [[ "$end_time" =~ ^[0-9]+$ ]] && [[ "$start_time" =~ ^[0-9]+$ ]]; then
        load_time=$((end_time - start_time))
    fi
    add_loading_time "$module_name" "$load_time"
    TOTAL_LOADING_TIME=$((TOTAL_LOADING_TIME + load_time))
    
    # Log significant loading times (>10ms)
    if [[ $load_time -gt 10000 ]]; then  # 10ms in microseconds
        echo "[MODULE_LOADER] INFO: Module '$module_name' took ${load_time}μs to load" >&2
    fi
}

# Load module dependencies recursively
load_dependencies() {
    local module_name="$1"
    local deps
    deps=$(get_module_dependencies "$module_name")
    
    if [[ -n "$deps" ]]; then
        local dep
        for dep in $deps; do
            if ! is_module_loaded "$dep"; then
                load_module_safe "$dep"
            fi
        done
    fi
}

# Simple circular dependency detection
detect_circular_deps() {
    local module_name="$1"
    local visited_path="${2:-}"
    
    # Check if we've seen this module in the current path
    if [[ "$visited_path" =~ (^| )$module_name( |$) ]]; then
        echo "[MODULE_LOADER] ERROR: Circular dependency detected: $visited_path -> $module_name" >&2
        return 1
    fi
    
    # Check dependencies recursively
    local deps
    deps=$(get_module_dependencies "$module_name")
    if [[ -n "$deps" ]]; then
        local dep
        for dep in $deps; do
            if ! detect_circular_deps "$dep" "$visited_path $module_name"; then
                return 1
            fi
        done
    fi
    
    return 0
}

# Main module loading function with safety guards
load_module_safe() {
    local module_path="$1"
    local force_reload="${2:-false}"
    
    # Normalize the module name
    local module_name
    module_name=$(normalize_module_name "$module_path")
    
    # Skip if already loaded and not forcing reload
    if is_module_loaded "$module_name" && [[ "$force_reload" != "true" ]]; then
        return 0
    fi
    
    # Get full path to module
    local full_module_path
    if [[ "$module_path" =~ ^/ ]]; then
        # Absolute path provided
        full_module_path="$module_path"
    else
        # Relative path - resolve it
        full_module_path=$(get_module_path "$module_name")
    fi
    
    # Check if file exists
    if [[ ! -f "$full_module_path" ]]; then
        echo "[MODULE_LOADER] ERROR: Module not found: $full_module_path" >&2
        return 1
    fi
    
    # Detect circular dependencies before loading
    if ! detect_circular_deps "$module_name"; then
        echo "[MODULE_LOADER] ERROR: Cannot load $module_name due to circular dependency" >&2
        return 1
    fi
    
    # Load dependencies first
    load_dependencies "$module_name"
    
    # Track loading time (use seconds if microseconds not available)
    local start_time end_time
    if date +%s%6N >/dev/null 2>&1; then
        start_time=$(date +%s%6N)
    else
        start_time=$(($(date +%s) * 1000000))  # convert to microseconds
    fi
    
    # Source the module
    # shellcheck source=/dev/null
    if source "$full_module_path"; then
        if date +%s%6N >/dev/null 2>&1; then
            end_time=$(date +%s%6N)
        else
            end_time=$(($(date +%s) * 1000000))  # convert to microseconds
        fi
        
        # Mark as loaded
        add_to_loaded_modules "$module_name" "$full_module_path"
        
        # Track performance
        track_loading_performance "$module_name" "$start_time" "$end_time"
        
        echo "[MODULE_LOADER] DEBUG: Successfully loaded module: $module_name" >&2
        return 0
    else
        echo "[MODULE_LOADER] ERROR: Failed to load module: $full_module_path" >&2
        return 1
    fi
}

# Get list of loaded modules
get_loaded_modules() {
    if [[ -z "$LOADED_MODULES" ]]; then
        return 0
    fi
    
    # Parse the loaded modules string
    echo "$LOADED_MODULES" | tr '|' '\n' | cut -d':' -f1 | sort
}

# Get loading performance stats
get_loading_stats() {
    echo "[MODULE_LOADER] Loading Performance Statistics:"
    local module_count=0
    if [[ -n "$LOADED_MODULES" ]]; then
        module_count=$(echo "$LOADED_MODULES" | tr '|' '\n' | wc -l)
    fi
    echo "Total modules loaded: $module_count"
    echo "Total loading time: ${TOTAL_LOADING_TIME}μs"
    
    if [[ -n "$MODULE_LOAD_TIMES" ]]; then
        echo "Individual module loading times:"
        echo "$MODULE_LOAD_TIMES" | tr '|' '\n' | while IFS=':' read -r module time; do
            printf "  %-30s %10sμs\n" "$module" "$time"
        done
    fi
}

# Bulk load common modules for performance
load_common_modules() {
    local common_modules=("logging" "terminal" "network")
    local module
    
    echo "[MODULE_LOADER] INFO: Pre-loading common modules..." >&2
    
    for module in "${common_modules[@]}"; do
        load_module_safe "$module"
    done
}

# Unload a module (simple - just remove from tracking)
unload_module() {
    local module_name="$1"
    
    if is_module_loaded "$module_name"; then
        # Remove from loaded modules string
        LOADED_MODULES=$(echo "$LOADED_MODULES" | sed "s/|*$module_name:[^|]*|*/|/g" | sed 's/^|//g' | sed 's/|$//g')
        # Remove from load times string  
        MODULE_LOAD_TIMES=$(echo "$MODULE_LOAD_TIMES" | sed "s/|*$module_name:[^|]*|*/|/g" | sed 's/^|//g' | sed 's/|$//g')
        echo "[MODULE_LOADER] DEBUG: Unloaded module: $module_name" >&2
    fi
}

# Initialize the module loader
init_module_loader() {
    # Set up cleanup trap for long-running processes
    trap 'get_loading_stats >&2' EXIT
}

# Main execution check
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Script is being run directly - provide CLI interface
    case "${1:-}" in
        "load")
            if [[ -z "${2:-}" ]]; then
                echo "Usage: $0 load <module_name>"
                exit 1
            fi
            load_module_safe "$2"
            ;;
        "list")
            get_loaded_modules
            ;;
        "stats")
            get_loading_stats
            ;;
        "test")
            echo "Testing module loader..."
            init_module_loader
            load_module_safe "logging"
            load_module_safe "terminal"
            get_loading_stats
            ;;
        *)
            echo "Module Loader - Central module loading system"
            echo "Usage: $0 {load <module>|list|stats|test}"
            echo ""
            echo "Functions available when sourced:"
            echo "  load_module_safe <module_name>     - Load module with safety guards"
            echo "  is_module_loaded <module_name>     - Check if module is loaded"
            echo "  get_loaded_modules                 - List all loaded modules"
            echo "  get_loading_stats                  - Show performance statistics"
            echo "  load_common_modules                - Pre-load common utilities"
            exit 1
            ;;
    esac
else
    # Script is being sourced - initialize
    init_module_loader
fi

# Mark this module as loaded
export MODULE_LOADER_LOADED=1