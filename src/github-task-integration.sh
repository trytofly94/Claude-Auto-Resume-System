#!/usr/bin/env bash

# Claude Auto-Resume - GitHub Task Integration
# Integration zwischen GitHub Integration Module und Task Queue Core Module
# Version: 1.0.0-alpha
# Letzte Aktualisierung: 2025-08-25

set -euo pipefail

# ===============================================================================
# GLOBALE VARIABLEN UND INTEGRATION-SETUP
# ===============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Lade Dependencies
if [[ -f "$SCRIPT_DIR/utils/logging.sh" ]]; then
    source "$SCRIPT_DIR/utils/logging.sh"
fi

if [[ -f "$SCRIPT_DIR/github-integration.sh" ]]; then
    source "$SCRIPT_DIR/github-integration.sh"
fi

if [[ -f "$SCRIPT_DIR/task-queue.sh" ]]; then
    source "$SCRIPT_DIR/task-queue.sh"
fi

# GitHub Task Integration Configuration
GITHUB_TASK_INTEGRATION_ENABLED="${GITHUB_TASK_INTEGRATION_ENABLED:-true}"
GITHUB_TASK_AUTO_COMMENT="${GITHUB_TASK_AUTO_COMMENT:-true}"
GITHUB_TASK_PROGRESS_UPDATES="${GITHUB_TASK_PROGRESS_UPDATES:-true}"

# ===============================================================================
# TASK LIFECYCLE INTEGRATION HOOKS
# ===============================================================================

# Hook: Task wurde erstellt
on_task_created() {
    local task_id="$1"
    local github_url="$2"
    local task_description="$3"
    
    log_debug "GitHub integration hook: task created - $task_id"
    
    # Prüfe ob GitHub Integration aktiviert ist
    if [[ "$GITHUB_TASK_INTEGRATION_ENABLED" != "true" ]]; then
        log_debug "GitHub task integration disabled - skipping task created hook"
        return 0
    fi
    
    # Parse GitHub URL
    local parsed_url
    if ! parsed_url=$(parse_github_url "$github_url" 2>/dev/null); then
        log_warn "Invalid GitHub URL for task $task_id: $github_url"
        return 0
    fi
    
    # Extrahiere Repository-Informationen
    local owner repo item_number
    owner=$(echo "$parsed_url" | jq -r '.owner')
    repo=$(echo "$parsed_url" | jq -r '.repo')
    item_number=$(echo "$parsed_url" | jq -r '.item_number')
    
    # Poste Task-Start-Comment falls aktiviert
    if [[ "$GITHUB_TASK_AUTO_COMMENT" == "true" ]]; then
        if post_task_start_comment "$owner" "$repo" "$item_number" "$task_id" "$task_description"; then
            log_info "Task start comment posted for $task_id on $github_url"
        else
            log_warn "Failed to post task start comment for $task_id"
        fi
    fi
    
    return 0
}

# Hook: Task wurde gestartet
on_task_started() {
    local task_id="$1"
    local github_url="$2"
    local task_description="$3"
    
    log_debug "GitHub integration hook: task started - $task_id"
    
    # Prüfe ob GitHub Integration aktiviert ist
    if [[ "$GITHUB_TASK_INTEGRATION_ENABLED" != "true" ]]; then
        return 0
    fi
    
    # Parse GitHub URL
    local parsed_url
    if ! parsed_url=$(parse_github_url "$github_url" 2>/dev/null); then
        return 0
    fi
    
    # Erstelle initiales Progress-Backup
    if [[ "$GITHUB_PROGRESS_BACKUP_ENABLED" == "true" ]]; then
        local backup_data
        backup_data=$(create_task_backup "$task_id" "started" 0 "Task execution started")
        
        local owner repo item_number
        owner=$(echo "$parsed_url" | jq -r '.owner')
        repo=$(echo "$parsed_url" | jq -r '.repo')
        item_number=$(echo "$parsed_url" | jq -r '.item_number')
        
        save_task_progress_backup "$owner" "$repo" "$item_number" "$task_id" "$backup_data" >/dev/null 2>&1 || true
    fi
    
    return 0
}

# Hook: Task-Progress wurde aktualisiert
on_task_progress_update() {
    local task_id="$1"
    local github_url="$2"
    local task_description="$3"
    local progress_percent="$4"
    local current_step="$5"
    local progress_log="${6:-Progress update}"
    
    log_debug "GitHub integration hook: progress update - $task_id ($progress_percent%)"
    
    # Prüfe ob Progress-Updates aktiviert sind
    if [[ "$GITHUB_TASK_PROGRESS_UPDATES" != "true" ]] || [[ "$GITHUB_TASK_INTEGRATION_ENABLED" != "true" ]]; then
        return 0
    fi
    
    # Parse GitHub URL
    local parsed_url
    if ! parsed_url=$(parse_github_url "$github_url" 2>/dev/null); then
        return 0
    fi
    
    local owner repo item_number
    owner=$(echo "$parsed_url" | jq -r '.owner')
    repo=$(echo "$parsed_url" | jq -r '.repo')
    item_number=$(echo "$parsed_url" | jq -r '.item_number')
    
    # Poste Progress-Comment
    if post_progress_comment "$owner" "$repo" "$item_number" "$task_id" "$task_description" "$progress_percent" "$current_step" "$progress_log"; then
        log_debug "Progress comment updated for $task_id"
    else
        log_warn "Failed to update progress comment for $task_id"
    fi
    
    # Aktualisiere Progress-Backup
    if [[ "$GITHUB_PROGRESS_BACKUP_ENABLED" == "true" ]]; then
        local backup_data
        backup_data=$(create_task_backup "$task_id" "in_progress" "$progress_percent" "$current_step")
        save_task_progress_backup "$owner" "$repo" "$item_number" "$task_id" "$backup_data" >/dev/null 2>&1 || true
    fi
    
    return 0
}

# Hook: Task wurde erfolgreich abgeschlossen
on_task_completed() {
    local task_id="$1"
    local github_url="$2"
    local task_description="$3"
    local completion_summary="$4"
    
    log_debug "GitHub integration hook: task completed - $task_id"
    
    # Prüfe ob GitHub Integration aktiviert ist
    if [[ "$GITHUB_TASK_INTEGRATION_ENABLED" != "true" ]]; then
        return 0
    fi
    
    # Parse GitHub URL
    local parsed_url
    if ! parsed_url=$(parse_github_url "$github_url" 2>/dev/null); then
        return 0
    fi
    
    local owner repo item_number
    owner=$(echo "$parsed_url" | jq -r '.owner')
    repo=$(echo "$parsed_url" | jq -r '.repo')
    item_number=$(echo "$parsed_url" | jq -r '.item_number')
    
    # Poste Completion-Comment
    if post_completion_comment "$owner" "$repo" "$item_number" "$task_id" "$task_description" "completed" "$completion_summary"; then
        log_info "Task completion comment posted for $task_id on $github_url"
    else
        log_warn "Failed to post completion comment for $task_id"
    fi
    
    # Finales Progress-Backup
    if [[ "$GITHUB_PROGRESS_BACKUP_ENABLED" == "true" ]]; then
        local backup_data
        backup_data=$(create_task_backup "$task_id" "completed" 100 "Task completed successfully")
        save_task_progress_backup "$owner" "$repo" "$item_number" "$task_id" "$backup_data" >/dev/null 2>&1 || true
    fi
    
    return 0
}

# Hook: Task ist fehlgeschlagen
on_task_failed() {
    local task_id="$1"
    local github_url="$2" 
    local task_description="$3"
    local error_type="$4"
    local error_message="$5"
    local progress_percent="${6:-0}"
    local failed_step="${7:-unknown}"
    
    log_debug "GitHub integration hook: task failed - $task_id"
    
    # Prüfe ob GitHub Integration aktiviert ist
    if [[ "$GITHUB_TASK_INTEGRATION_ENABLED" != "true" ]]; then
        return 0
    fi
    
    # Parse GitHub URL
    local parsed_url
    if ! parsed_url=$(parse_github_url "$github_url" 2>/dev/null); then
        return 0
    fi
    
    local owner repo item_number
    owner=$(echo "$parsed_url" | jq -r '.owner')
    repo=$(echo "$parsed_url" | jq -r '.repo')
    item_number=$(echo "$parsed_url" | jq -r '.item_number')
    
    # Poste Error-Comment
    if post_error_comment "$owner" "$repo" "$item_number" "$task_id" "$task_description" "$error_type" "$error_message" "$progress_percent" "$failed_step"; then
        log_info "Task error comment posted for $task_id on $github_url"
    else
        log_warn "Failed to post error comment for $task_id"
    fi
    
    # Error-Backup
    if [[ "$GITHUB_PROGRESS_BACKUP_ENABLED" == "true" ]]; then
        local backup_data
        backup_data=$(create_task_backup "$task_id" "failed" "$progress_percent" "$failed_step" "$error_message")
        save_task_progress_backup "$owner" "$repo" "$item_number" "$task_id" "$backup_data" >/dev/null 2>&1 || true
    fi
    
    return 0
}

# ===============================================================================
# TASK ENRICHMENT UND METADATA
# ===============================================================================

# Erweitert Task-Objekt mit GitHub-Metadaten
enrich_task_with_github_metadata() {
    local task_id="$1"
    local github_url="$2"
    
    log_debug "Enriching task $task_id with GitHub metadata"
    
    # Parse GitHub URL
    local parsed_url
    if ! parsed_url=$(parse_github_url "$github_url"); then
        log_error "Failed to parse GitHub URL: $github_url"
        return 1
    fi
    
    local owner repo item_number item_type
    owner=$(echo "$parsed_url" | jq -r '.owner')
    repo=$(echo "$parsed_url" | jq -r '.repo')
    item_number=$(echo "$parsed_url" | jq -r '.item_number')
    item_type=$(echo "$parsed_url" | jq -r '.item_type')
    
    # Hole GitHub-Metadaten
    local github_metadata
    case "$item_type" in
        "$GITHUB_ITEM_TYPE_ISSUE")
            if ! github_metadata=$(fetch_issue_details "$owner" "$repo" "$item_number"); then
                log_error "Failed to fetch issue details for $github_url"
                return 1
            fi
            ;;
        "$GITHUB_ITEM_TYPE_PR")
            if ! github_metadata=$(fetch_pr_details "$owner" "$repo" "$item_number"); then
                log_error "Failed to fetch PR details for $github_url"
                return 1
            fi
            ;;
        *)
            # Ermittle Item-Typ
            if item_type=$(get_github_item_type "$owner" "$repo" "$item_number"); then
                case "$item_type" in
                    "$GITHUB_ITEM_TYPE_ISSUE")
                        github_metadata=$(fetch_issue_details "$owner" "$repo" "$item_number")
                        ;;
                    "$GITHUB_ITEM_TYPE_PR")
                        github_metadata=$(fetch_pr_details "$owner" "$repo" "$item_number")
                        ;;
                    *)
                        log_error "Unknown GitHub item type: $item_type"
                        return 1
                        ;;
                esac
            else
                log_error "Failed to determine GitHub item type for $github_url"
                return 1
            fi
            ;;
    esac
    
    # Extrahiere relevante Metadaten für Task-System
    local enhanced_task_data
    enhanced_task_data=$(echo "$github_metadata" | jq \
        --arg task_id "$task_id" \
        --arg github_url "$github_url" \
        '{
            task_id: $task_id,
            github_url: $github_url,
            github_metadata: {
                title: .title,
                state: .state,
                created_at: .created_at,
                updated_at: .updated_at,
                author: .user.login,
                assignees: [.assignees[]?.login],
                labels: [.labels[]?.name],
                milestone: .milestone?.title,
                repository: {
                    owner: .repository_owner,
                    name: .repository_name,
                    full_name: .repository_full_name
                },
                item_type: .item_type,
                html_url: .html_url,
                api_url: .url
            },
            enriched_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
        }')
    
    log_debug "Task $task_id enriched with GitHub metadata successfully"
    echo "$enhanced_task_data"
    return 0
}

# Synchronisiert GitHub-Status mit Task-Status
sync_github_status_with_task() {
    local task_id="$1"
    local github_url="$2"
    local task_status="$3"
    
    log_debug "Syncing GitHub status with task $task_id (status: $task_status)"
    
    # Parse GitHub URL
    local parsed_url
    if ! parsed_url=$(parse_github_url "$github_url" 2>/dev/null); then
        return 0
    fi
    
    # Implementierung für Status-Synchronisation könnte hier erweitert werden
    # z.B. Labels aktualisieren, Issue-Status ändern, etc.
    # Dies würde erweiterte GitHub-Berechtigungen erfordern
    
    log_debug "GitHub status sync completed for task $task_id"
    return 0
}

# ===============================================================================
# BACKUP UND RECOVERY
# ===============================================================================

# Erstellt strukturiertes Backup für Task-Progress
create_task_backup() {
    local task_id="$1"
    local status="$2"
    local progress_percent="$3"
    local current_step="$4"
    local additional_info="${5:-}"
    
    # Hole aktuelle Git-Informationen
    local current_branch
    current_branch=$(git branch --show-current 2>/dev/null || echo "unknown")
    
    local last_commit
    last_commit=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
    
    # Erstelle Backup-JSON
    local backup_data
    backup_data=$(jq -n \
        --arg task_id "$task_id" \
        --arg status "$status" \
        --arg progress_percent "$progress_percent" \
        --arg current_step "$current_step" \
        --arg additional_info "$additional_info" \
        --arg current_branch "$current_branch" \
        --arg last_commit "$last_commit" \
        --arg session_id "${CLAUDE_SESSION_ID:-unknown}" \
        '{
            backup_metadata: {
                backup_type: "task_progress_snapshot",
                task_id: $task_id,
                timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
                claude_session_id: $session_id,
                backup_version: "1.0"
            },
            task_state: {
                status: $status,
                progress_percent: ($progress_percent | tonumber),
                current_step: $current_step,
                additional_info: $additional_info
            },
            execution_context: {
                current_branch: $current_branch,
                last_commit: $last_commit,
                timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
            }
        }')
    
    echo "$backup_data"
}

# Recovery-Funktion für Task-Wiederherstellung
recover_task_from_github() {
    local github_url="$1"
    local task_id="${2:-}"
    
    log_info "Attempting to recover task from GitHub: $github_url"
    
    # Parse GitHub URL
    local parsed_url
    if ! parsed_url=$(parse_github_url "$github_url"); then
        log_error "Failed to parse GitHub URL for recovery: $github_url"
        return 1
    fi
    
    local owner repo item_number
    owner=$(echo "$parsed_url" | jq -r '.owner')
    repo=$(echo "$parsed_url" | jq -r '.repo')
    item_number=$(echo "$parsed_url" | jq -r '.item_number')
    
    # Wenn Task-ID nicht angegeben, versuche sie von existierenden Backups zu ermitteln
    if [[ -z "$task_id" ]]; then
        log_info "No task ID provided - searching for existing backups"
        # Implementierung um Task-ID aus Backup-Comments zu extrahieren würde hier stehen
        task_id="task-recovery-$(date +%s)"
        log_info "Using generated task ID: $task_id"
    fi
    
    # Versuche Backup zu laden
    local backup_data
    if backup_data=$(load_task_progress_backup "$owner" "$repo" "$item_number" "$task_id" 2>/dev/null); then
        log_info "Task backup found and loaded for $task_id"
        echo "$backup_data"
        return 0
    else
        log_warn "No backup found for task $task_id - creating new task context"
        
        # Erstelle minimalen Recovery-Kontext
        local recovery_context
        recovery_context=$(jq -n \
            --arg task_id "$task_id" \
            --arg github_url "$github_url" \
            '{
                backup_metadata: {
                    backup_type: "recovery_context",
                    task_id: $task_id,
                    timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
                    source: "recovery_from_github"
                },
                task_state: {
                    status: "recovered",
                    progress_percent: 0,
                    current_step: "recovery_initialization"
                },
                execution_context: {
                    github_url: $github_url,
                    recovery_timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
                }
            }')
        
        echo "$recovery_context"
        return 0
    fi
}