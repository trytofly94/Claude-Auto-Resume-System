#!/usr/bin/env bash

set -euo pipefail

# Global configuration storage
declare -gA SYSTEM_CONFIG
declare -g SYSTEM_CONFIG_LOADED=""
declare -g SYSTEM_CONFIG_FILE=""
declare -g SYSTEM_CONFIG_MTIME=""

# Capability cache for command checks
declare -gA CAPABILITY_CACHE

# Configuration defaults (Issue #114)
declare -gA CONFIG_DEFAULTS=(
    # Session Management
    ["CHECK_INTERVAL_MINUTES"]="5"
    ["MAX_RESTARTS"]="50"
    ["USE_CLAUNCH"]="true"
    ["CLAUNCH_MODE"]="tmux"
    ["NEW_TERMINAL_DEFAULT"]="true"
    ["TMUX_SESSION_PREFIX"]="claude-auto"
    ["SESSION_RESTART_DELAY"]="5"
    ["HEALTH_CHECK_INTERVAL"]="30"
    ["HEALTH_CHECK_TIMEOUT"]="10"
    ["RECOVERY_DELAY"]="10"
    ["MAX_RECOVERY_ATTEMPTS"]="3"
    
    # Usage Limit Handling
    ["USAGE_LIMIT_COOLDOWN"]="300"
    ["BACKOFF_FACTOR"]="1.5"
    ["MAX_WAIT_TIME"]="1800"
    
    # Logging
    ["LOG_LEVEL"]="INFO"
    ["LOG_ROTATION"]="true"
    ["MAX_LOG_SIZE"]="100M"
    ["LOG_FILE"]="logs/hybrid-monitor.log"
    
    # Task Queue
    ["TASK_QUEUE_ENABLED"]="false"
    ["TASK_DEFAULT_TIMEOUT"]="3600"
    ["TASK_MAX_RETRIES"]="3"
    ["TASK_RETRY_DELAY"]="10"
    ["TASK_COMPLETION_PATTERN"]="Task completed|✓ Completed|Done|Finished"
    ["QUEUE_PROCESSING_DELAY"]="2"
    ["QUEUE_MAX_CONCURRENT"]="1"
    ["QUEUE_AUTO_PAUSE_ON_ERROR"]="true"
    ["QUEUE_SESSION_CLEAR_BETWEEN_TASKS"]="false"
    ["TASK_BACKUP_RETENTION_DAYS"]="30"
    ["TASK_AUTO_CLEANUP_DAYS"]="7"
    
    # GitHub Integration
    ["GITHUB_INTEGRATION_ENABLED"]="false"
    ["GITHUB_AUTO_COMMENT"]="false"
    ["GITHUB_STATUS_UPDATES"]="false"
    ["GITHUB_COMPLETION_NOTIFICATIONS"]="false"
    ["GITHUB_API_TIMEOUT"]="30"
    ["GITHUB_RETRY_ATTEMPTS"]="3"
    
    # Health & Recovery
    ["HEALTH_CHECK_ENABLED"]="true"
    ["AUTO_RECOVERY_ENABLED"]="true"
    
    # Debug
    ["DEBUG_MODE"]="false"
    ["DRY_RUN"]="false"
)

# Config validation rules
declare -gA CONFIG_VALIDATORS=(
    ["CHECK_INTERVAL_MINUTES"]="^[0-9]+$"
    ["MAX_RESTARTS"]="^[0-9]+$"
    ["USE_CLAUNCH"]="^(true|false)$"
    ["CLAUNCH_MODE"]="^(direct|tmux)$"
    ["NEW_TERMINAL_DEFAULT"]="^(true|false)$"
    ["TMUX_SESSION_PREFIX"]="^[a-zA-Z0-9_-]+$"
    ["SESSION_RESTART_DELAY"]="^[0-9]+$"
    ["HEALTH_CHECK_INTERVAL"]="^[0-9]+$"
    ["HEALTH_CHECK_TIMEOUT"]="^[0-9]+$"
    ["RECOVERY_DELAY"]="^[0-9]+$"
    ["MAX_RECOVERY_ATTEMPTS"]="^[0-9]+$"
    ["USAGE_LIMIT_COOLDOWN"]="^[0-9]+$"
    ["BACKOFF_FACTOR"]="^[0-9]+(\.[0-9]+)?$"
    ["MAX_WAIT_TIME"]="^[0-9]+$"
    ["LOG_ROTATION"]="^(true|false)$"
    ["TASK_QUEUE_ENABLED"]="^(true|false)$"
    ["TASK_DEFAULT_TIMEOUT"]="^[0-9]+$"
    ["TASK_MAX_RETRIES"]="^[0-9]+$"
    ["TASK_RETRY_DELAY"]="^[0-9]+$"
    ["QUEUE_PROCESSING_DELAY"]="^[0-9]+$"
    ["QUEUE_MAX_CONCURRENT"]="^[0-9]+$"
    ["QUEUE_AUTO_PAUSE_ON_ERROR"]="^(true|false)$"
    ["QUEUE_SESSION_CLEAR_BETWEEN_TASKS"]="^(true|false)$"
    ["TASK_BACKUP_RETENTION_DAYS"]="^[0-9]+$"
    ["TASK_AUTO_CLEANUP_DAYS"]="^[0-9]+$"
    ["GITHUB_INTEGRATION_ENABLED"]="^(true|false)$"
    ["GITHUB_AUTO_COMMENT"]="^(true|false)$"
    ["GITHUB_STATUS_UPDATES"]="^(true|false)$"
    ["GITHUB_COMPLETION_NOTIFICATIONS"]="^(true|false)$"
    ["GITHUB_API_TIMEOUT"]="^[0-9]+$"
    ["GITHUB_RETRY_ATTEMPTS"]="^[0-9]+$"
    ["HEALTH_CHECK_ENABLED"]="^(true|false)$"
    ["AUTO_RECOVERY_ENABLED"]="^(true|false)$"
    ["DEBUG_MODE"]="^(true|false)$"
    ["DRY_RUN"]="^(true|false)$"
)

# Sanitize configuration value by removing quotes
sanitize_config_value() {
    local value="$1"
    
    # Remove leading/trailing whitespace
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    
    # Remove quotes (both single and double)
    value="${value#\"}"
    value="${value%\"}"
    value="${value#\'}"
    value="${value%\'}"
    
    echo "$value"
}

# Validate a configuration value against its rule
validate_config_value() {
    local key="$1"
    local value="$2"
    
    # If no validator exists, consider it valid
    if [[ -z "${CONFIG_VALIDATORS[$key]:-}" ]]; then
        return 0
    fi
    
    local pattern="${CONFIG_VALIDATORS[$key]}"
    
    if [[ "$value" =~ $pattern ]]; then
        return 0
    else
        return 1
    fi
}

# Load system configuration from file (Issue #114)
load_system_config() {
    local config_file="${1:-}"
    local force_reload="${2:-false}"
    
    # If no config file specified, use default locations
    if [[ -z "$config_file" ]]; then
        # Try standard locations
        if [[ -f "config/default.conf" ]]; then
            config_file="config/default.conf"
        elif [[ -f "${SCRIPT_DIR:-}/config/default.conf" ]]; then
            config_file="${SCRIPT_DIR}/config/default.conf"
        elif [[ -f "${SCRIPT_DIR:-}/../config/default.conf" ]]; then
            config_file="${SCRIPT_DIR}/../config/default.conf"
        else
            log_warn "No configuration file found, using defaults"
            apply_config_defaults
            export SYSTEM_CONFIG_LOADED="defaults"
            return 0
        fi
    fi
    
    # Check if already loaded and file hasn't changed
    if [[ "$force_reload" != "true" && -n "$SYSTEM_CONFIG_LOADED" ]]; then
        if [[ -f "$config_file" && "$SYSTEM_CONFIG_FILE" == "$config_file" ]]; then
            local current_mtime
            current_mtime=$(stat -f "%m" "$config_file" 2>/dev/null || stat -c "%Y" "$config_file" 2>/dev/null || echo "0")
            if [[ "$current_mtime" == "$SYSTEM_CONFIG_MTIME" ]]; then
                log_debug "Configuration already loaded and unchanged"
                return 0
            fi
        fi
    fi
    
    # Verify file exists and is readable
    if [[ ! -f "$config_file" ]]; then
        log_error "Configuration file not found: $config_file"
        apply_config_defaults
        export SYSTEM_CONFIG_LOADED="defaults"
        return 1
    fi
    
    if [[ ! -r "$config_file" ]]; then
        log_error "Configuration file not readable: $config_file"
        apply_config_defaults
        export SYSTEM_CONFIG_LOADED="defaults"
        return 1
    fi
    
    log_info "Loading configuration from: $config_file"
    
    # Clear existing config
    SYSTEM_CONFIG=()
    
    # Use mapfile for efficient reading (Issue #114)
    local config_lines=()
    mapfile -t config_lines < <(grep -E '^[^#]*=' "$config_file" 2>/dev/null || true)
    
    local errors=0
    local warnings=0
    
    for line in "${config_lines[@]}"; do
        # Skip empty lines
        [[ -z "$line" ]] && continue
        
        # Parse key=value
        local key="${line%%=*}"
        local value="${line#*=}"
        
        # Sanitize values
        key=$(sanitize_config_value "$key")
        value=$(sanitize_config_value "$value")
        
        # Skip if key is empty
        [[ -z "$key" ]] && continue
        
        # Validate value
        if validate_config_value "$key" "$value"; then
            SYSTEM_CONFIG["$key"]="$value"
            log_debug "Config loaded: $key=$value"
        else
            log_warn "Invalid config value for $key: $value (using default)"
            ((warnings++))
            # Use default if available
            if [[ -n "${CONFIG_DEFAULTS[$key]:-}" ]]; then
                SYSTEM_CONFIG["$key"]="${CONFIG_DEFAULTS[$key]}"
            fi
        fi
    done
    
    # Apply defaults for missing keys
    for key in "${!CONFIG_DEFAULTS[@]}"; do
        if [[ -z "${SYSTEM_CONFIG[$key]:-}" ]]; then
            SYSTEM_CONFIG["$key"]="${CONFIG_DEFAULTS[$key]}"
            log_debug "Using default for $key: ${CONFIG_DEFAULTS[$key]}"
        fi
    done
    
    # Store metadata
    export SYSTEM_CONFIG_FILE="$config_file"
    export SYSTEM_CONFIG_MTIME=$(stat -f "%m" "$config_file" 2>/dev/null || stat -c "%Y" "$config_file" 2>/dev/null || echo "0")
    export SYSTEM_CONFIG_LOADED="file"
    
    if [[ $warnings -gt 0 ]]; then
        log_warn "Configuration loaded with $warnings warnings"
    else
        log_info "Configuration loaded successfully"
    fi
    
    return 0
}

# Apply default configuration values
apply_config_defaults() {
    log_debug "Applying default configuration values"
    
    for key in "${!CONFIG_DEFAULTS[@]}"; do
        SYSTEM_CONFIG["$key"]="${CONFIG_DEFAULTS[$key]}"
    done
}

# Get configuration value with fallback
get_config() {
    local key="$1"
    local default="${2:-}"
    
    # Ensure config is loaded
    if [[ -z "$SYSTEM_CONFIG_LOADED" ]]; then
        load_system_config
    fi
    
    # Return value or default
    echo "${SYSTEM_CONFIG[$key]:-$default}"
}

# Set configuration value (runtime only, not persisted)
set_config() {
    local key="$1"
    local value="$2"
    
    # Validate if validator exists
    if ! validate_config_value "$key" "$value"; then
        log_warn "Invalid value for $key: $value"
        return 1
    fi
    
    SYSTEM_CONFIG["$key"]="$value"
    log_debug "Runtime config set: $key=$value"
    return 0
}

# Export configuration as environment variables
export_config_as_env() {
    local prefix="${1:-}"
    
    # Ensure config is loaded
    if [[ -z "$SYSTEM_CONFIG_LOADED" ]]; then
        load_system_config
    fi
    
    for key in "${!SYSTEM_CONFIG[@]}"; do
        local env_var="${prefix}${key}"
        export "$env_var"="${SYSTEM_CONFIG[$key]}"
        log_debug "Exported: $env_var=${SYSTEM_CONFIG[$key]}"
    done
}

# Check if configuration needs reload
config_needs_reload() {
    local config_file="${SYSTEM_CONFIG_FILE:-}"
    
    # No config loaded yet
    if [[ -z "$SYSTEM_CONFIG_LOADED" ]]; then
        return 0
    fi
    
    # Using defaults, check if file now exists
    if [[ "$SYSTEM_CONFIG_LOADED" == "defaults" ]]; then
        if [[ -f "config/default.conf" || -f "${SCRIPT_DIR:-}/config/default.conf" ]]; then
            return 0
        fi
    fi
    
    # Check if file has been modified
    if [[ -f "$config_file" ]]; then
        local current_mtime
        current_mtime=$(stat -f "%m" "$config_file" 2>/dev/null || stat -c "%Y" "$config_file" 2>/dev/null || echo "0")
        if [[ "$current_mtime" != "$SYSTEM_CONFIG_MTIME" ]]; then
            return 0
        fi
    fi
    
    return 1
}

# Cached command availability check (Issue #114)
has_command_cached() {
    local cmd="$1"
    
    # Check cache first
    if [[ -n "${CAPABILITY_CACHE[$cmd]:-}" ]]; then
        return "${CAPABILITY_CACHE[$cmd]}"
    fi
    
    # Check command availability
    if command -v "$cmd" >/dev/null 2>&1; then
        CAPABILITY_CACHE["$cmd"]=0
        log_debug "Command available (cached): $cmd"
        return 0
    else
        CAPABILITY_CACHE["$cmd"]=1
        log_debug "Command not available (cached): $cmd"
        return 1
    fi
}

# Clear capability cache
clear_capability_cache() {
    CAPABILITY_CACHE=()
    log_debug "Capability cache cleared"
}

# Get all cached capabilities
get_cached_capabilities() {
    for cmd in "${!CAPABILITY_CACHE[@]}"; do
        local status="${CAPABILITY_CACHE[$cmd]}"
        if [[ "$status" -eq 0 ]]; then
            echo "$cmd: available"
        else
            echo "$cmd: not available"
        fi
    done
}

# Validate all configuration values
validate_all_config() {
    local errors=0
    local warnings=0
    
    log_info "Validating all configuration values..."
    
    for key in "${!SYSTEM_CONFIG[@]}"; do
        local value="${SYSTEM_CONFIG[$key]}"
        
        if ! validate_config_value "$key" "$value"; then
            log_error "Invalid config: $key=$value"
            ((errors++))
        fi
    done
    
    # Check for unknown keys
    for key in "${!SYSTEM_CONFIG[@]}"; do
        if [[ -z "${CONFIG_DEFAULTS[$key]:-}" && -z "${CONFIG_VALIDATORS[$key]:-}" ]]; then
            log_warn "Unknown configuration key: $key"
            ((warnings++))
        fi
    done
    
    if [[ $errors -gt 0 ]]; then
        log_error "Configuration validation failed with $errors errors"
        return 1
    elif [[ $warnings -gt 0 ]]; then
        log_warn "Configuration validation completed with $warnings warnings"
        return 0
    else
        log_info "Configuration validation passed"
        return 0
    fi
}

# Dump current configuration (for debugging)
dump_config() {
    local show_defaults="${1:-false}"
    
    echo "=== Current Configuration ==="
    echo "Config File: ${SYSTEM_CONFIG_FILE:-none}"
    echo "Load Status: ${SYSTEM_CONFIG_LOADED:-not loaded}"
    echo "Last Modified: ${SYSTEM_CONFIG_MTIME:-unknown}"
    echo ""
    
    echo "=== Configuration Values ==="
    for key in $(printf '%s\n' "${!SYSTEM_CONFIG[@]}" | sort); do
        local value="${SYSTEM_CONFIG[$key]}"
        local default="${CONFIG_DEFAULTS[$key]:-}"
        
        if [[ "$show_defaults" == "true" && -n "$default" ]]; then
            if [[ "$value" == "$default" ]]; then
                echo "$key=$value (default)"
            else
                echo "$key=$value (default: $default)"
            fi
        else
            echo "$key=$value"
        fi
    done
    
    echo ""
    echo "=== Cached Capabilities ==="
    get_cached_capabilities
}

# Initialize fallback logging if main logging not available
if ! declare -f log_info >/dev/null 2>&1; then
    log_debug() { [[ "${DEBUG_MODE:-false}" == "true" ]] && echo "[DEBUG] $*" >&2 || true; }
    log_info() { echo "[INFO] $*" >&2; }
    log_warn() { echo "[WARN] $*" >&2; }
    log_error() { echo "[ERROR] $*" >&2; }
fi