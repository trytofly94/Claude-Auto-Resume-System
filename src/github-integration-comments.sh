#!/usr/bin/env bash

# Claude Auto-Resume - GitHub Integration Module - Comment Management
# Erweiterte Comment-Management-Funktionen für GitHub Integration
# Diese Datei wird von github-integration.sh geladen

# ===============================================================================
# COMMENT MANAGEMENT SYSTEM  
# ===============================================================================

# Lädt Comment-Templates
load_comment_templates() {
    log_debug "Loading GitHub comment templates..."
    
    # Template-Verzeichnis prüfen
    local templates_dir="$PROJECT_ROOT/$GITHUB_COMMENT_TEMPLATES_DIR"
    
    if [[ ! -d "$templates_dir" ]]; then
        log_debug "Comment templates directory not found: $templates_dir"
        log_debug "Loading built-in default templates"
        load_builtin_comment_templates
        return 0
    fi
    
    # Lade Standard-Templates
    local template_files=("task_start.md" "progress.md" "completion.md" "error.md")
    local loaded_count=0
    
    for template_file in "${template_files[@]}"; do
        local template_path="$templates_dir/$template_file"
        local template_name="${template_file%.md}"
        
        if [[ -f "$template_path" ]]; then
            local template_content
            if template_content=$(cat "$template_path" 2>/dev/null); then
                COMMENT_TEMPLATES["$template_name"]="$template_content"
                ((loaded_count++))
                log_debug "Loaded comment template: $template_name"
            else
                log_warn "Failed to read comment template: $template_path"
            fi
        fi
    done
    
    # Fallback auf built-in templates für fehlende Templates
    if [[ $loaded_count -eq 0 ]]; then
        log_warn "No comment templates loaded from $templates_dir"
        load_builtin_comment_templates
    else
        log_debug "Loaded $loaded_count comment templates from $templates_dir"
        # Ergänze fehlende Templates mit built-in versions
        load_builtin_comment_templates "supplement"
    fi
    
    return 0
}

# Lädt built-in Comment-Templates
load_builtin_comment_templates() {
    local mode="${1:-replace}"  # replace oder supplement
    
    log_debug "Loading built-in comment templates (mode: $mode)"
    
    # Task Start Template
    if [[ "$mode" == "replace" ]] || [[ -z "${COMMENT_TEMPLATES[$GITHUB_COMMENT_TEMPLATE_TASK_START]:-}" ]]; then
        COMMENT_TEMPLATES["$GITHUB_COMMENT_TEMPLATE_TASK_START"]='🤖 **Claude Auto-Resume Task Queue**

**Task Started**: #{task_id} - {task_description}  
**Timestamp**: {iso_timestamp}  
**Expected Duration**: ~{estimated_time} minutes

*This task is being processed automatically by Claude Auto-Resume.*

---
**Progress**: [░░░░░░░░░░] 0% - Initializing...  
**Queue Position**: {position}/{total_tasks}  
**ETA**: {estimated_completion}

<details>
<summary>📊 Task Details</summary>

- **Task Type**: {task_type}
- **Priority**: {priority}
- **Session ID**: `{session_id}`
- **Branch**: `{git_branch}`

</details>

*Comment will be updated with progress automatically.*'
    fi
    
    # Progress Update Template
    if [[ "$mode" == "replace" ]] || [[ -z "${COMMENT_TEMPLATES[$GITHUB_COMMENT_TEMPLATE_PROGRESS]:-}" ]]; then
        COMMENT_TEMPLATES["$GITHUB_COMMENT_TEMPLATE_PROGRESS"]='🤖 **Claude Auto-Resume Task Queue** - Progress Update

**Task**: #{task_id} - {task_description}  
**Status**: {status} | **Progress**: {progress_percent}%  
**Updated**: {iso_timestamp}

---
**Progress**: [{progress_bar}] {progress_percent}%  
**Current Step**: {current_step}  
**ETA**: {estimated_completion}

<details>
<summary>📝 Progress Log</summary>

{progress_log}

</details>

*Updated automatically by Claude Auto-Resume.*'
    fi
    
    # Task Completion Template  
    if [[ "$mode" == "replace" ]] || [[ -z "${COMMENT_TEMPLATES[$GITHUB_COMMENT_TEMPLATE_COMPLETION]:-}" ]]; then
        COMMENT_TEMPLATES["$GITHUB_COMMENT_TEMPLATE_COMPLETION"]='✅ **Claude Auto-Resume Task Queue** - Task Completed

**Task**: #{task_id} - {task_description}  
**Completed**: {iso_timestamp}  
**Duration**: {actual_duration} minutes  
**Status**: {final_status}

---
**Final Progress**: [██████████] 100% ✅  
**Total Steps**: {total_steps_completed}  
**Success Rate**: {success_rate}%

<details>
<summary>📋 Completion Summary</summary>

{completion_summary}

**Files Modified**: {files_modified}  
**Commits Created**: {commits_count}  
**Tests Status**: {tests_status}

</details>

*Task completed successfully by Claude Auto-Resume.*'
    fi
    
    # Error/Failure Template
    if [[ "$mode" == "replace" ]] || [[ -z "${COMMENT_TEMPLATES[$GITHUB_COMMENT_TEMPLATE_ERROR]:-}" ]]; then
        COMMENT_TEMPLATES["$GITHUB_COMMENT_TEMPLATE_ERROR"]='❌ **Claude Auto-Resume Task Queue** - Task Failed

**Task**: #{task_id} - {task_description}  
**Failed**: {iso_timestamp}  
**Duration**: {partial_duration} minutes  
**Error**: {error_type}

---
**Progress**: [{progress_bar}] {progress_percent}% ❌  
**Failed Step**: {failed_step}  
**Retry Count**: {retry_count}/{max_retries}

<details>
<summary>🔍 Error Details</summary>

```
{error_message}
```

**Stack Trace**:
```
{error_stack_trace}
```

**Recovery Actions**:
{recovery_actions}

</details>

*Task failed - manual intervention may be required.*'
    fi
    
    local template_count=${#COMMENT_TEMPLATES[@]}
    log_debug "Built-in comment templates loaded (total templates: $template_count)"
    
    return 0
}

# Rendert Comment-Template mit Variablen-Substitution
render_comment_template() {
    local template_name="$1"
    shift
    
    log_debug "Rendering comment template: $template_name"
    
    # Prüfe ob Template existiert
    if [[ -z "${COMMENT_TEMPLATES[$template_name]:-}" ]]; then
        log_error "Comment template not found: $template_name"
        log_error "Available templates: ${!COMMENT_TEMPLATES[*]}"
        return 1
    fi
    
    # Parse key=value pairs in associative array
    local -A template_vars
    while [[ $# -gt 0 ]]; do
        local key_value="$1"
        if [[ "$key_value" == *"="* ]]; then
            local key="${key_value%%=*}"
            local value="${key_value#*=}"
            template_vars["$key"]="$value"
        else
            log_warn "Invalid template variable format (expected key=value): $key_value"
        fi
        shift
    done
    
    # Template-Inhalt abrufen
    local template_content="${COMMENT_TEMPLATES[$template_name]}"
    
    # Variable-Substitution durchführen
    local rendered_content="$template_content"
    for key in "${!template_vars[@]}"; do
        local value="${template_vars[$key]}"
        # Escape special characters for sed
        value=$(printf '%s\n' "$value" | sed 's/[[\.*^$()+?{|]/\\&/g')
        rendered_content=$(echo "$rendered_content" | sed "s/{$key}/$value/g")
    done
    
    # Prüfe auf nicht-substituierte Variablen
    local unsubstituted_vars
    unsubstituted_vars=$(echo "$rendered_content" | grep -o '{[^}]*}' | sort -u | tr '\n' ' ') || true
    
    if [[ -n "$unsubstituted_vars" ]]; then
        log_warn "Template has unsubstituted variables: $unsubstituted_vars"
        # Ersetze unsubstituted variables mit placeholder
        for var in $unsubstituted_vars; do
            rendered_content=$(echo "$rendered_content" | sed "s/$var/[${var:1:-1}]/g")
        done
    fi
    
    # Validiere Content-Length
    local content_length=${#rendered_content}
    if [[ $content_length -gt $GITHUB_MAX_COMMENT_LENGTH ]]; then
        log_warn "Rendered comment exceeds GitHub maximum length ($content_length > $GITHUB_MAX_COMMENT_LENGTH)"
        # Truncate mit suffix
        local truncate_length=$((GITHUB_MAX_COMMENT_LENGTH - ${#GITHUB_COMMENT_TRUNCATE_SUFFIX}))
        rendered_content="${rendered_content:0:$truncate_length}$GITHUB_COMMENT_TRUNCATE_SUFFIX"
        log_warn "Comment truncated to fit GitHub limits"
    fi
    
    log_debug "Successfully rendered comment template: $template_name ($content_length characters)"
    echo "$rendered_content"
    
    return 0
}

# Postet Task-Start-Comment
post_task_start_comment() {
    local owner="$1"
    local repo="$2" 
    local item_number="$3"
    local task_id="$4"
    local task_description="$5"
    
    log_debug "Posting task start comment for $owner/$repo#$item_number (task: $task_id)"
    
    # Prüfe ob Auto-Commenting aktiviert ist
    if [[ "$GITHUB_AUTO_COMMENT" != "true" ]]; then
        log_debug "Auto-commenting disabled - skipping task start comment"
        return 0
    fi
    
    # Template-Variablen zusammenstellen
    local current_time
    current_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    local comment_content
    if ! comment_content=$(render_comment_template "$GITHUB_COMMENT_TEMPLATE_TASK_START" \
        "task_id=$task_id" \
        "task_description=$task_description" \
        "iso_timestamp=$current_time" \
        "estimated_time=15" \
        "position=1" \
        "total_tasks=1" \
        "estimated_completion=TBD" \
        "task_type=automated" \
        "priority=normal" \
        "session_id=${CLAUDE_SESSION_ID:-unknown}" \
        "git_branch=$(git branch --show-current 2>/dev/null || echo 'unknown')"); then
        log_error "Failed to render task start comment template"
        return 1
    fi
    
    # Poste Comment via GitHub API
    if post_github_comment "$owner" "$repo" "$item_number" "$comment_content" "task_start"; then
        log_info "Task start comment posted successfully for $owner/$repo#$item_number"
        return 0
    else
        log_error "Failed to post task start comment for $owner/$repo#$item_number"
        return 1
    fi
}

# Postet Progress-Update-Comment
post_progress_comment() {
    local owner="$1"
    local repo="$2"
    local item_number="$3" 
    local task_id="$4"
    local task_description="$5"
    local progress_percent="$6"
    local current_step="$7"
    local progress_log="${8:-No progress log available}"
    
    log_debug "Posting progress comment for $owner/$repo#$item_number (progress: $progress_percent%)"
    
    # Prüfe ob Progress-Updates aktiviert sind
    if [[ "$GITHUB_STATUS_UPDATES" != "true" ]]; then
        log_debug "Status updates disabled - skipping progress comment" 
        return 0
    fi
    
    # Erstelle Progress-Bar
    local progress_bar
    progress_bar=$(create_progress_bar "$progress_percent")
    
    # Template-Variablen
    local current_time
    current_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    local comment_content
    if ! comment_content=$(render_comment_template "$GITHUB_COMMENT_TEMPLATE_PROGRESS" \
        "task_id=$task_id" \
        "task_description=$task_description" \
        "status=in_progress" \
        "progress_percent=$progress_percent" \
        "iso_timestamp=$current_time" \
        "progress_bar=$progress_bar" \
        "current_step=$current_step" \
        "estimated_completion=TBD" \
        "progress_log=$progress_log"); then
        log_error "Failed to render progress comment template"
        return 1
    fi
    
    # Versuche existierenden Progress-Comment zu updaten
    local existing_comment_id
    if existing_comment_id=$(find_progress_comment "$owner" "$repo" "$item_number" "$task_id"); then
        log_debug "Updating existing progress comment: $existing_comment_id"
        if update_github_comment "$owner" "$repo" "$existing_comment_id" "$comment_content"; then
            log_info "Progress comment updated successfully for $owner/$repo#$item_number"
            return 0
        else
            log_warn "Failed to update existing progress comment - posting new one"
        fi
    fi
    
    # Poste neuen Progress-Comment
    if post_github_comment "$owner" "$repo" "$item_number" "$comment_content" "progress"; then
        log_info "Progress comment posted successfully for $owner/$repo#$item_number ($progress_percent%)"
        return 0
    else
        log_error "Failed to post progress comment for $owner/$repo#$item_number"
        return 1
    fi
}

# Postet Task-Completion-Comment
post_completion_comment() {
    local owner="$1"
    local repo="$2"
    local item_number="$3"
    local task_id="$4"
    local task_description="$5"
    local final_status="$6"
    local completion_summary="${7:-Task completed successfully}"
    
    log_debug "Posting completion comment for $owner/$repo#$item_number (status: $final_status)"
    
    # Prüfe ob Completion-Notifications aktiviert sind
    if [[ "$GITHUB_COMPLETION_NOTIFICATIONS" != "true" ]]; then
        log_debug "Completion notifications disabled - skipping completion comment"
        return 0
    fi
    
    # Template-Variablen
    local current_time
    current_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    local comment_content
    if ! comment_content=$(render_comment_template "$GITHUB_COMMENT_TEMPLATE_COMPLETION" \
        "task_id=$task_id" \
        "task_description=$task_description" \
        "iso_timestamp=$current_time" \
        "actual_duration=15" \
        "final_status=$final_status" \
        "total_steps_completed=5" \
        "success_rate=100" \
        "completion_summary=$completion_summary" \
        "files_modified=TBD" \
        "commits_count=TBD" \
        "tests_status=TBD"); then
        log_error "Failed to render completion comment template"
        return 1
    fi
    
    # Poste Completion-Comment
    if post_github_comment "$owner" "$repo" "$item_number" "$comment_content" "completion"; then
        log_info "Completion comment posted successfully for $owner/$repo#$item_number"
        return 0
    else
        log_error "Failed to post completion comment for $owner/$repo#$item_number"
        return 1
    fi
}

# Postet Error/Failure-Comment
post_error_comment() {
    local owner="$1"
    local repo="$2" 
    local item_number="$3"
    local task_id="$4"
    local task_description="$5"
    local error_type="$6"
    local error_message="$7"
    local progress_percent="${8:-0}"
    local failed_step="${9:-unknown}"
    
    log_debug "Posting error comment for $owner/$repo#$item_number (error: $error_type)"
    
    # Erstelle Progress-Bar für aktuellen Stand
    local progress_bar
    progress_bar=$(create_progress_bar "$progress_percent")
    
    # Template-Variablen
    local current_time
    current_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    local comment_content
    if ! comment_content=$(render_comment_template "$GITHUB_COMMENT_TEMPLATE_ERROR" \
        "task_id=$task_id" \
        "task_description=$task_description" \
        "iso_timestamp=$current_time" \
        "partial_duration=10" \
        "error_type=$error_type" \
        "progress_bar=$progress_bar" \
        "progress_percent=$progress_percent" \
        "failed_step=$failed_step" \
        "retry_count=0" \
        "max_retries=3" \
        "error_message=$error_message" \
        "error_stack_trace=N/A" \
        "recovery_actions=Manual review required"); then
        log_error "Failed to render error comment template"
        return 1
    fi
    
    # Poste Error-Comment
    if post_github_comment "$owner" "$repo" "$item_number" "$comment_content" "error"; then
        log_info "Error comment posted successfully for $owner/$repo#$item_number"
        return 0
    else
        log_error "Failed to post error comment for $owner/$repo#$item_number"
        return 1
    fi
}

# Generisches GitHub Comment Posting
post_github_comment() {
    local owner="$1"
    local repo="$2"
    local item_number="$3"
    local comment_body="$4"
    local comment_type="${5:-general}"
    
    log_debug "Posting GitHub comment to $owner/$repo#$item_number (type: $comment_type)"
    
    # Input-Validation
    if [[ -z "$owner" ]] || [[ -z "$repo" ]] || [[ -z "$item_number" ]] || [[ -z "$comment_body" ]]; then
        log_error "Invalid parameters for posting GitHub comment"
        return 1
    fi
    
    # Sanitize comment body (basic security)
    local sanitized_body
    sanitized_body=$(echo "$comment_body" | sed 's/\x00//g' | head -c "$GITHUB_MAX_COMMENT_LENGTH")
    
    # Erstelle API request payload
    local payload
    payload=$(jq -n --arg body "$sanitized_body" '{"body": $body}')
    
    # Post comment mit Retry-Logic
    local api_endpoint="repos/$owner/$repo/issues/$item_number/comments"
    local response
    
    if response=$(execute_with_retry "gh api" gh api "$api_endpoint" --method POST --input - <<< "$payload" 2>&1); then
        # Parse Comment-ID aus Response für future updates
        local comment_id
        comment_id=$(echo "$response" | jq -r '.id // empty' 2>/dev/null) || comment_id=""
        
        if [[ -n "$comment_id" ]]; then
            log_debug "Comment posted successfully with ID: $comment_id"
            
            # Cache Comment-ID für Updates
            local cache_key="${owner}/${repo}:${item_number}:comment:${comment_type}"
            GITHUB_API_CACHE["$cache_key"]=$(jq -n \
                --arg comment_id "$comment_id" \
                --arg cached_at "$(date +%s)" \
                '{comment_id: $comment_id, cached_at: ($cached_at | tonumber)}')
            
            echo "$comment_id"
            return 0
        else
            log_warn "Comment posted but could not parse comment ID from response"
            return 0
        fi
    else
        local exit_code=$?
        log_error "Failed to post GitHub comment to $owner/$repo#$item_number"
        handle_api_error "post_comment" "$exit_code" "$response"
        return $exit_code
    fi
}

# Updated existierenden GitHub Comment
update_github_comment() {
    local owner="$1"
    local repo="$2"
    local comment_id="$3"
    local new_body="$4"
    
    log_debug "Updating GitHub comment $comment_id in $owner/$repo"
    
    # Input-Validation
    if [[ -z "$owner" ]] || [[ -z "$repo" ]] || [[ -z "$comment_id" ]] || [[ -z "$new_body" ]]; then
        log_error "Invalid parameters for updating GitHub comment"
        return 1
    fi
    
    # Sanitize comment body
    local sanitized_body
    sanitized_body=$(echo "$new_body" | sed 's/\x00//g' | head -c "$GITHUB_MAX_COMMENT_LENGTH")
    
    # Erstelle API request payload
    local payload
    payload=$(jq -n --arg body "$sanitized_body" '{"body": $body}')
    
    # Update comment mit Retry-Logic  
    local api_endpoint="repos/$owner/$repo/issues/comments/$comment_id"
    local response
    
    if response=$(execute_with_retry "gh api" gh api "$api_endpoint" --method PATCH --input - <<< "$payload" 2>&1); then
        log_debug "Comment $comment_id updated successfully"
        return 0
    else
        local exit_code=$?
        log_error "Failed to update GitHub comment $comment_id in $owner/$repo"
        handle_api_error "update_comment" "$exit_code" "$response"
        return $exit_code
    fi
}

# Findet existierenden Progress-Comment
find_progress_comment() {
    local owner="$1"
    local repo="$2"
    local item_number="$3"
    local task_id="$4"
    
    log_debug "Searching for progress comment for task $task_id in $owner/$repo#$item_number"
    
    # Prüfe Cache zuerst
    local cache_key="${owner}/${repo}:${item_number}:comment:progress"
    if [[ -n "${GITHUB_API_CACHE[$cache_key]:-}" ]]; then
        local cached_entry="${GITHUB_API_CACHE[$cache_key]}"
        local comment_id
        comment_id=$(echo "$cached_entry" | jq -r '.comment_id // empty')
        
        if [[ -n "$comment_id" ]]; then
            log_debug "Found cached progress comment ID: $comment_id"
            echo "$comment_id"
            return 0
        fi
    fi
    
    # Hole Comments über API und suche Progress-Comment
    local api_endpoint="repos/$owner/$repo/issues/$item_number/comments"
    local comments_response
    
    if ! comments_response=$(gh api "$api_endpoint" 2>/dev/null); then
        log_warn "Failed to fetch comments for $owner/$repo#$item_number"
        return 1
    fi
    
    # Suche Comment mit Task-ID und Progress-Marker
    local comment_id
    comment_id=$(echo "$comments_response" | jq -r --arg task_id "$task_id" '
        .[] | select(.body | contains("**Task**: #" + $task_id) and contains("Progress Update")) | .id' | head -n1)
    
    if [[ -n "$comment_id" ]] && [[ "$comment_id" != "null" ]]; then
        log_debug "Found progress comment with ID: $comment_id"
        
        # Cache für future lookups
        GITHUB_API_CACHE["$cache_key"]=$(jq -n \
            --arg comment_id "$comment_id" \
            --arg cached_at "$(date +%s)" \
            '{comment_id: $comment_id, cached_at: ($cached_at | tonumber)}')
        
        echo "$comment_id"
        return 0
    else
        log_debug "No existing progress comment found for task $task_id"
        return 1
    fi
}

# Erstellt ASCII Progress-Bar
create_progress_bar() {
    local progress_percent="$1"
    local bar_length=10
    
    # Berechne gefüllte Segmente
    local filled_length
    filled_length=$(( (progress_percent * bar_length) / 100 ))
    
    # Baue Progress-Bar
    local progress_bar=""
    local i
    for ((i=0; i<filled_length; i++)); do
        progress_bar+="█"
    done
    for ((i=filled_length; i<bar_length; i++)); do
        progress_bar+="░"
    done
    
    echo "$progress_bar"
}