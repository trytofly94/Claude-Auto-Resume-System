#!/usr/bin/env bash

# Claude Auto-Resume - Task Queue Main Module
# Refactored modular task queue system with global installation support
# Version: 2.0.0-global-cli (Issue #88)

set -euo pipefail

# ===============================================================================
# GLOBAL INSTALLATION SUPPORT
# ===============================================================================

# Initialize path resolution for global vs local execution
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load path resolution utilities
if [[ -f "$SCRIPT_DIR/utils/path-resolver.sh" ]]; then
    source "$SCRIPT_DIR/utils/path-resolver.sh"
    initialize_path_resolver
elif [[ -f "$SCRIPT_DIR/utils/installation-path.sh" ]]; then
    # Fallback to basic path detection
    source "$SCRIPT_DIR/utils/installation-path.sh"
    export CLAUDE_INSTALLATION_DIR="$(get_installation_directory)"
    export CLAUDE_SRC_DIR="$(get_src_directory)"
    export CLAUDE_CONFIG_DIR="$(get_config_directory)"
    export CLAUDE_SCRIPTS_DIR="$(get_scripts_directory)"
    export CLAUDE_LOGS_DIR="$(get_logs_directory)"
else
    # Legacy path detection for backward compatibility
    CLAUDE_INSTALLATION_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
    CLAUDE_SRC_DIR="$CLAUDE_INSTALLATION_DIR/src"
    CLAUDE_CONFIG_DIR="$CLAUDE_INSTALLATION_DIR/config" 
    CLAUDE_SCRIPTS_DIR="$CLAUDE_INSTALLATION_DIR/scripts"
    CLAUDE_LOGS_DIR="$CLAUDE_INSTALLATION_DIR/logs"
fi

# Update legacy variables for backward compatibility
SCRIPT_DIR="$CLAUDE_SRC_DIR"
PROJECT_ROOT="$CLAUDE_INSTALLATION_DIR"

# Configuration defaults (loaded from config/default.conf if available)
TASK_QUEUE_DIR="${TASK_QUEUE_DIR:-$CLAUDE_INSTALLATION_DIR/queue}"
TASK_QUEUE_ENABLED="${TASK_QUEUE_ENABLED:-true}"

# ===============================================================================
# MODULE LOADING
# ===============================================================================

# Load core modules in order
load_queue_modules() {
    load_module_loader
    
    local required_modules=(
        "cache"
        "core"
        "locking"
        "persistence"
        "cleanup"
        "interactive" 
        "monitoring"
        "workflow"
    )
    
    for module in "${required_modules[@]}"; do
        local queue_module="queue/$module"
        
        if command -v load_module_safe >/dev/null 2>&1; then
            if load_module_safe "$queue_module"; then
                log_debug "Loaded queue module: $module"
            else
                log_error "Failed to load queue module: $module"
                return 1
            fi
        else
            # Fallback to direct sourcing
            local module_file="$SCRIPT_DIR/queue/${module}.sh"
            if [[ -f "$module_file" ]]; then
                source "$module_file" || {
                    log_error "Failed to load module: $module"
                    return 1
                }
                log_debug "Loaded module: $module"
            else
                log_error "Required module not found: $module_file"
                return 1
            fi
        fi
    done
    
    # Load local queue modules (Issue #91) - keeping direct loading for now
    local local_modules=(
        "$SCRIPT_DIR/local-queue.sh"
        "$SCRIPT_DIR/queue/local-operations.sh"
    )
    
    for module in "${local_modules[@]}"; do
        if [[ -f "$module" ]]; then
            source "$module" || {
                log_error "Failed to load local queue module: $(basename "$module")"
                return 1
            }
            log_debug "Loaded local queue module: $(basename "$module")"
        else
            log_warn "Local queue module not found: $(basename "$module")"
        fi
    done
    
    log_info "All queue modules loaded successfully"
}

# Load configuration
load_configuration() {
    local config_file
    
    # Use path resolution if available, otherwise fall back to legacy
    if command -v resolve_config_file >/dev/null 2>&1; then
        config_file="$(resolve_config_file "default.conf" 2>/dev/null || echo "$PROJECT_ROOT/config/default.conf")"
    else
        config_file="$PROJECT_ROOT/config/default.conf"
    fi
    
    if [[ -f "$config_file" ]]; then
        source "$config_file" || log_warn "Failed to load configuration: $config_file"
        log_debug "Configuration loaded from: $config_file"
    else
        log_debug "No configuration file found, using defaults"
    fi
}

# Load central module loader first
load_module_loader() {
    if [[ -z "${MODULE_LOADER_LOADED:-}" ]] && [[ -f "$SCRIPT_DIR/utils/module-loader.sh" ]]; then
        source "$SCRIPT_DIR/utils/module-loader.sh"
    fi
}

# Load logging utilities using module loader
load_logging() {
    load_module_loader
    if command -v load_module_safe >/dev/null 2>&1; then
        load_module_safe "logging"
    elif [[ -f "$SCRIPT_DIR/utils/logging.sh" ]]; then
        source "$SCRIPT_DIR/utils/logging.sh"
    else
        # Fallback logging functions
        log_debug() { echo "[DEBUG] $*" >&2; }
        log_info() { echo "[INFO] $*" >&2; }
        log_warn() { echo "[WARN] $*" >&2; }
        log_error() { echo "[ERROR] $*" >&2; }
    fi
}

# Load CLI parser utilities (Issue #93)
load_cli_parser() {
    load_module_loader
    if command -v load_module_safe >/dev/null 2>&1; then
        if load_module_safe "cli-parser"; then
            log_debug "CLI parser loaded for context clearing support"
        else
            log_warn "Failed to load CLI parser utilities"
        fi
    elif [[ -f "$SCRIPT_DIR/utils/cli-parser.sh" ]]; then
        source "$SCRIPT_DIR/utils/cli-parser.sh"
        log_debug "CLI parser loaded for context clearing support"
    else
        log_warn "CLI parser not found, context clearing flags unavailable"
    fi
}

# ===============================================================================
# MAIN COMMAND INTERFACE
# ===============================================================================

# Main command dispatcher
main() {
    local command="${1:-help}"
    shift || true
    
    case "$command" in
        # Core operations
        "add")
            cmd_add_task "$@"
            ;;
        "remove"|"rm")
            cmd_remove_task "$@"
            ;;
        "list"|"ls")
            cmd_list_tasks "$@"
            ;;
        
        # Enhanced commands with context clearing support (Issue #93)
        "add-custom")
            cmd_add_custom_with_context "$@"
            ;;
        "add-issue")
            cmd_add_github_issue_with_context "$@"
            ;;
        "status")
            cmd_show_status "$@"
            ;;
        "stats")
            cmd_show_stats "$@"
            ;;
        
        # Workflow operations
        "workflow")
            cmd_workflow "$@"
            ;;
        "create-issue-merge")
            cmd_create_issue_merge_workflow "$@"
            ;;
        
        # Interactive mode
        "interactive"|"shell")
            run_interactive_mode
            ;;
        
        # Monitoring
        "monitor")
            cmd_start_monitoring "$@"
            ;;
        "health")
            cmd_check_health "$@"
            ;;
        
        # Maintenance
        "cleanup")
            cmd_cleanup "$@"
            ;;
        "backup")
            cmd_backup "$@"
            ;;
        "restore")
            cmd_restore "$@"
            ;;
        
        # System operations
        "save")
            cmd_save_queue "$@"
            ;;
        "load")
            cmd_load_queue "$@"
            ;;
        "validate")
            cmd_validate_queue "$@"
            ;;
        
        # Local queue operations (Issue #91)
        "init-local-queue")
            cmd_init_local_queue "$@"
            ;;
        "show-context")
            cmd_show_context "$@"
            ;;
        "migrate-to-local")
            cmd_migrate_to_local "$@"
            ;;
        
        # Help and information
        "help"|"-h"|"--help")
            show_help
            ;;
        "version"|"-v"|"--version")
            show_version
            ;;
        
        *)
            echo "Unknown command: $command" >&2
            echo "Use 'help' to see available commands" >&2
            return 1
            ;;
    esac
}

# ===============================================================================
# COMMAND IMPLEMENTATIONS
# ===============================================================================

# Add task command (context-aware for local queues)
cmd_add_task() {
    local task_json="${1:-}"
    
    if [[ -z "$task_json" ]]; then
        echo "Usage: $0 add <task_json>"
        echo "Example: $0 add '{\"id\":\"task-123\",\"type\":\"custom\",\"status\":\"pending\",\"created_at\":\"$(date -Iseconds)\"}'"
        return 1
    fi
    
    # Use local queue if active, otherwise global
    if is_local_queue_active; then
        if add_local_task "$task_json"; then
            echo "Task added to local queue successfully"
        else
            echo "Failed to add task to local queue" >&2
            return 1
        fi
    else
        if add_task "$task_json"; then
            echo "Task added to global queue successfully"
            save_queue_state false
        else
            echo "Failed to add task to global queue" >&2
            return 1
        fi
    fi
}

# Remove task command (context-aware for local queues)
cmd_remove_task() {
    local task_id="${1:-}"
    
    if [[ -z "$task_id" ]]; then
        echo "Usage: $0 remove <task_id>"
        return 1
    fi
    
    # Use local queue if active, otherwise global
    if is_local_queue_active; then
        if remove_local_task "$task_id"; then
            echo "Task removed from local queue: $task_id"
        else
            echo "Failed to remove task from local queue: $task_id" >&2
            return 1
        fi
    else
        if remove_task "$task_id"; then
            echo "Task removed from global queue: $task_id"
            save_queue_state false
        else
            echo "Failed to remove task from global queue: $task_id" >&2
            return 1
        fi
    fi
}

# List tasks command
cmd_list_tasks() {
    local status_filter="${1:-all}"
    local format="${2:-json}"
    
    list_tasks "$status_filter" "$format"
}

# Show status command
cmd_show_status() {
    get_queue_stats | jq .
}

# Show detailed stats command
cmd_show_stats() {
    local stats=$(get_queue_stats)
    echo "$stats" | jq .
    
    echo
    echo "Queue file information:"
    get_queue_file_stats | jq .
}

# Workflow command dispatcher
cmd_workflow() {
    local subcommand="${1:-list}"
    shift || true
    
    case "$subcommand" in
        "create")
            local workflow_type="${1:-}"
            local config="${2:-{}}"
            
            if [[ -z "$workflow_type" ]]; then
                echo "Usage: $0 workflow create <type> [config_json]"
                return 1
            fi
            
            # Call create_workflow_task directly to avoid subshell issues
            create_workflow_task "$workflow_type" "$config"
            local create_result=$?
            
            if [[ $create_result -eq 0 ]]; then
                # Persist the workflow to disk
                save_queue_state false
            else
                echo "Failed to create workflow" >&2
                return 1
            fi
            ;;
        "execute")
            local workflow_id="${1:-}"
            
            if [[ -z "$workflow_id" ]]; then
                echo "Usage: $0 workflow execute <workflow_id>"
                return 1
            fi
            
            execute_workflow_task "$workflow_id"
            ;;
        "status")
            local workflow_id="${1:-}"
            local detailed="${2:-}"
            
            if [[ -z "$workflow_id" ]]; then
                echo "Usage: $0 workflow status <workflow_id> [detailed]"
                return 1
            fi
            
            if [[ "$detailed" == "detailed" ]] || [[ "$detailed" == "-d" ]]; then
                get_workflow_detailed_status "$workflow_id"
            else
                get_workflow_status "$workflow_id"
            fi
            ;;
        "list")
            list_workflows "${1:-all}"
            ;;
        "pause")
            local workflow_id="${1:-}"
            
            if [[ -z "$workflow_id" ]]; then
                echo "Usage: $0 workflow pause <workflow_id>"
                return 1
            fi
            
            pause_workflow "$workflow_id"
            ;;
        "resume")
            local workflow_id="${1:-}"
            local resume_step="${2:-}"
            
            if [[ -z "$workflow_id" ]]; then
                echo "Usage: $0 workflow resume <workflow_id> [step_index]"
                return 1
            fi
            
            if [[ -n "$resume_step" ]] && [[ "$resume_step" =~ ^[0-9]+$ ]]; then
                resume_workflow_from_step "$workflow_id" "$resume_step"
            else
                resume_workflow "$workflow_id"
            fi
            ;;
        "cancel")
            local workflow_id="${1:-}"
            
            if [[ -z "$workflow_id" ]]; then
                echo "Usage: $0 workflow cancel <workflow_id>"
                return 1
            fi
            
            cancel_workflow "$workflow_id"
            ;;
        "checkpoint")
            local workflow_id="${1:-}"
            local reason="${2:-manual_checkpoint}"
            
            if [[ -z "$workflow_id" ]]; then
                echo "Usage: $0 workflow checkpoint <workflow_id> [reason]"
                return 1
            fi
            
            create_workflow_checkpoint "$workflow_id" "$reason"
            ;;
        *)
            echo "Unknown workflow subcommand: $subcommand" >&2
            echo "Available: create, execute, status, list, pause, resume, cancel, checkpoint" >&2
            return 1
            ;;
    esac
}

# Create issue-merge workflow (convenience command)
cmd_create_issue_merge_workflow() {
    local issue_id="${1:-}"
    
    if [[ -z "$issue_id" ]]; then
        echo "Usage: $0 create-issue-merge <issue_id>"
        return 1
    fi
    
    local config="{\"issue_id\": \"$issue_id\"}"
    
    # Call create_workflow_task directly to avoid subshell issues
    create_workflow_task "$WORKFLOW_TYPE_ISSUE_MERGE" "$config"
    local create_result=$?
    
    if [[ $create_result -eq 0 ]]; then
        # Persist the workflow to disk
        save_queue_state false
    else
        echo "Failed to create workflow" >&2
        return 1
    fi
}

# Start monitoring command
cmd_start_monitoring() {
    local duration="${1:-30}"  # Default 30 seconds
    local interval="${2:-5}"   # Default 5 second intervals
    local debug_mode="false"
    
    # Check for debug flag in arguments
    local arg
    for arg in "$@"; do
        case "$arg" in
            "--debug"|"--verbose"|"debug")
                debug_mode="true"
                shift || true
                ;;
        esac
    done
    
    # Reparse arguments after removing debug flags
    duration="${1:-30}"
    interval="${2:-5}"
    
    if [[ "$debug_mode" == "true" ]]; then
        log_info "Starting monitoring in debug mode (duration: ${duration}s, interval: ${interval}s)"
    fi
    
    start_monitoring_daemon "$duration" "$interval" "$debug_mode"
}

# Check health command
cmd_check_health() {
    get_queue_health_status | jq .
}

# Cleanup command
cmd_cleanup() {
    local cleanup_type="${1:-full}"
    
    case "$cleanup_type" in
        "full")
            run_full_cleanup | jq .
            ;;
        "auto")
            run_auto_cleanup "${2:-false}" | jq .
            ;;
        "completed")
            local count=$(cleanup_completed_tasks "${2:-7}")
            echo "{\"cleaned\": $count, \"type\": \"completed_tasks\"}" | jq .
            ;;
        "failed")
            local count=$(cleanup_failed_tasks "${2:-14}")
            echo "{\"cleaned\": $count, \"type\": \"failed_tasks\"}" | jq .
            ;;
        "backups")
            local count=$(cleanup_old_backups_with_count "${2:-30}")
            echo "{\"cleaned\": $count, \"type\": \"old_backups\"}" | jq .
            ;;
        *)
            echo "Unknown cleanup type: $cleanup_type" >&2
            echo "Available: full, auto, completed, failed, backups" >&2
            return 1
            ;;
    esac
}

# Backup command
cmd_backup() {
    local suffix="${1:-$(date +%Y%m%d-%H%M%S)}"
    
    if create_backup "$suffix"; then
        echo "Backup created successfully with suffix: $suffix"
    else
        echo "Failed to create backup" >&2
        return 1
    fi
}

# Restore command
cmd_restore() {
    local backup_file="${1:-}"
    
    if [[ -z "$backup_file" ]]; then
        echo "Available backups:"
        list_backups "detailed"
        echo
        echo "Usage: $0 restore <backup_file>"
        return 1
    fi
    
    if restore_from_backup "$backup_file"; then
        echo "Restored from backup: $backup_file"
    else
        echo "Failed to restore from backup: $backup_file" >&2
        return 1
    fi
}

# Save queue command
cmd_save_queue() {
    local with_backup="${1:-true}"
    
    if save_queue_state "$with_backup"; then
        echo "Queue state saved successfully"
    else
        echo "Failed to save queue state" >&2
        return 1
    fi
}

# Load queue command
cmd_load_queue() {
    if load_queue_state; then
        echo "Queue state loaded successfully"
        cmd_show_status
    else
        echo "Failed to load queue state" >&2
        return 1
    fi
}

# Validate queue command
cmd_validate_queue() {
    if validate_queue_integrity; then
        echo "Queue validation passed"
        
        if validate_queue_file; then
            echo "Queue file validation passed"
        else
            echo "Queue file validation failed" >&2
            return 1
        fi
    else
        echo "Queue validation failed" >&2
        return 1
    fi
}

# ===============================================================================
# LOCAL QUEUE COMMAND IMPLEMENTATIONS (Issue #91)
# ===============================================================================

# Initialize local queue command
cmd_init_local_queue() {
    local project_name="${1:-$(basename "$PWD")}"
    local track_in_git="${2:-false}"
    
    # Parse additional flags
    local force_flag="false"
    local arg
    for arg in "$@"; do
        case "$arg" in
            "--force")
                force_flag="true"
                ;;
            "--git"|"--track-git")
                track_in_git="true"
                ;;
        esac
    done
    
    if init_local_queue "$project_name" "$track_in_git"; then
        echo "Local queue initialized successfully"
        echo "Project: $project_name"
        echo "Location: $PWD/.claude-tasks"
        echo "Track in git: $track_in_git"
        
        # Show initial status
        cmd_show_context
    else
        echo "Failed to initialize local queue" >&2
        return 1
    fi
}

# Show current queue context command
cmd_show_context() {
    local context=$(get_queue_context)
    
    echo "Current queue context: $context"
    
    if is_local_queue_active; then
        echo "Local queue details:"
        get_local_queue_stats | jq .
    else
        echo "Using global queue"
        get_queue_stats | jq .
    fi
}

# Migrate to local queue command
cmd_migrate_to_local() {
    local project_name="${1:-$(basename "$PWD")}"
    local copy_mode="${2:-move}"  # move or copy
    
    echo "Migration to local queue not implemented yet in Phase 1"
    echo "This will be implemented in Phase 2 of the local queue rollout"
    echo ""
    echo "For now, use: $0 init-local-queue \"$project_name\""
    echo "Then manually recreate your tasks in the new local queue"
    
    return 1
}

# Enhanced status command with local queue support
cmd_show_status() {
    if is_local_queue_active; then
        echo "=== LOCAL QUEUE STATUS ==="
        get_local_queue_stats | jq .
    else
        echo "=== GLOBAL QUEUE STATUS ==="
        get_queue_stats | jq .
    fi
}

# Enhanced list command with local queue support  
cmd_list_tasks() {
    local status_filter="${1:-all}"
    local format="${2:-json}"
    
    if is_local_queue_active; then
        echo "=== LOCAL TASKS ($LOCAL_PROJECT_NAME) ==="
        local queue_file=$(get_local_queue_file)
        
        if [[ "$status_filter" == "all" ]]; then
            jq '.tasks' "$queue_file"
        else
            jq --arg status "$status_filter" '[.tasks[] | select(.status == $status)]' "$queue_file"
        fi
    else
        echo "=== GLOBAL TASKS ==="
        list_tasks "$status_filter" "$format"
    fi
}

# ===============================================================================
# HELP AND VERSION
# ===============================================================================

# Show help information
show_help() {
    cat << 'EOF'
Claude Auto-Resume - Task Queue System v2.0.0-refactored

USAGE:
    task-queue.sh <command> [arguments]

CORE COMMANDS:
    add <task_json>              Add new task
    remove <task_id>             Remove task by ID
    list [status] [format]       List tasks (optional status filter)
    status                       Show queue status summary
    stats                        Show detailed statistics

WORKFLOW COMMANDS:
    workflow create <type> [config]      Create new workflow
    workflow execute <workflow_id>       Execute workflow
    workflow status <workflow_id> [detailed] Get workflow status (add 'detailed' for full info)
    workflow list [status]               List workflows
    workflow pause <workflow_id>         Pause workflow
    workflow resume <workflow_id> [step] Resume workflow (optionally from specific step)
    workflow cancel <workflow_id>        Cancel workflow
    workflow checkpoint <workflow_id> [reason] Create workflow checkpoint
    
    create-issue-merge <issue_id>        Create issue-merge workflow (shortcut)

INTERACTIVE MODE:
    interactive                  Start interactive shell mode
    shell                        Alias for interactive

MONITORING:
    monitor [duration] [interval] [--debug] Start real-time monitoring (add --debug for verbose output)
    health                              Check queue health status

MAINTENANCE:
    cleanup [type] [args]               Run cleanup operations
    backup [suffix]                     Create backup
    restore <backup_file>               Restore from backup

SYSTEM:
    save [with_backup]                  Save queue state
    load                               Load queue state
    validate                           Validate queue integrity

LOCAL QUEUE (Issue #91):
    init-local-queue [name] [--git]     Initialize .claude-tasks/ in current directory
    show-context                        Show current queue context (local/global)
    migrate-to-local [name]             Migrate global tasks to local queue (Phase 2)

HELP:
    help                               Show this help
    version                            Show version information

EXAMPLES:
    task-queue.sh add '{"id":"test","type":"custom","status":"pending","created_at":"2025-08-31T10:00:00Z"}'
    task-queue.sh list pending
    task-queue.sh create-issue-merge 94
    task-queue.sh workflow execute workflow-123
    task-queue.sh interactive
    task-queue.sh monitor 60 10
    task-queue.sh cleanup full
    
    # Local queue examples (Issue #91)
    task-queue.sh init-local-queue "my-project"     # Initialize local queue
    task-queue.sh init-local-queue --git           # Initialize with git tracking
    task-queue.sh show-context                      # Check current context
    task-queue.sh list                             # List tasks (auto-detects local/global)

EOF
}

# Show version information
show_version() {
    echo "Claude Auto-Resume Task Queue System"
    echo "Version: 2.1.0-efficiency-optimization"
    echo "Architecture: Modular (reduced from 4843 to ~1000 lines total)"
    echo "Features: Core, Cache, Persistence, Locking, Interactive, Monitoring, Workflow, Cleanup, LocalQueue"
    echo "Local Queue Support: Issue #91 - Phase 1 Implementation"
    echo "Performance Optimization: Issue #116 - JSON parsing cache and single-pass operations"
}

# ===============================================================================
# INITIALIZATION AND STARTUP
# ===============================================================================

# Initialize the task queue system
initialize_system() {
    # Load logging first
    load_logging
    
    # Load core queue modules (needed for monitoring functions)
    if [[ -f "$SCRIPT_DIR/queue/core.sh" ]]; then
        source "$SCRIPT_DIR/queue/core.sh"
    fi
    if [[ -f "$SCRIPT_DIR/queue/monitoring.sh" ]]; then
        source "$SCRIPT_DIR/queue/monitoring.sh"
    fi
    
    # Load configuration
    load_configuration
    
    # Load CLI parser (Issue #93)
    load_cli_parser
    
    # Check if task queue is enabled
    if [[ "$TASK_QUEUE_ENABLED" != "true" ]]; then
        log_info "Task queue is disabled in configuration"
        return 1
    fi
    
    # Load all modules
    if ! load_queue_modules; then
        log_error "Failed to initialize queue modules"
        return 1
    fi
    
    # Ensure queue directories exist
    ensure_queue_directories || {
        log_error "Failed to create queue directories"
        return 1
    }
    
    # Load existing queue state
    load_queue_state || {
        log_warn "Failed to load existing queue state, starting fresh"
        initialize_empty_queue
    }
    
    log_info "Task queue system initialized successfully"
    return 0
}

# ===============================================================================
# SCRIPT ENTRY POINT
# ===============================================================================

# Main execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Initialize system
    if ! initialize_system; then
        echo "Failed to initialize task queue system" >&2
        exit 1
    fi
    
    # Run main command with all arguments
    main "$@"
else
    # Script is being sourced, only load modules
    load_logging
    
    # Load core queue modules
    if [[ -f "$SCRIPT_DIR/queue/core.sh" ]]; then
        source "$SCRIPT_DIR/queue/core.sh"
    fi
    if [[ -f "$SCRIPT_DIR/queue/monitoring.sh" ]]; then
        source "$SCRIPT_DIR/queue/monitoring.sh"
    fi
    
    load_configuration
    load_queue_modules
fi