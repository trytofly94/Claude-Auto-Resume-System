# Phase 2: GitHub Integration Module Implementation

**Erstellt**: 2025-08-25
**Typ**: Feature
**Geschätzter Aufwand**: Groß
**Verwandtes Issue**: GitHub #41

## Kontext & Ziel

Implementierung des **GitHub Integration Modules** für Claude Auto-Resume als kritischer Baustein des Task Queue Systems. Dieses Modul ermöglicht automatische GitHub API-Integration für Task Queue-Operationen, einschließlich Issue/PR-Metadaten-Abruf, Status-Comment-Management und robuste Fehlerbehandlung mit Rate-Limiting-Support.

**Building on Success**: PR #45 (Task Queue Core Module) wurde mit A- Rating bewertet und ist merge-ready. Dieses Modul baut auf der excellenten Architektur-Foundation auf.

## Anforderungen

- [ ] **Issue/PR Data Retrieval**
  - fetch_issue_details() - GitHub Issue Metadaten abrufen
  - fetch_pr_details() - Pull Request Details und Status
  - validate_github_item() - Existenz und Zugriffsberechtigung prüfen
  - cache_github_data() - API-Call-Reduktion durch Caching

- [ ] **Status Comment Management**
  - post_task_start_comment() - Task-Start-Benachrichtigungen
  - post_progress_comment() - Fortschritts-Updates während Ausführung
  - post_completion_comment() - Completion/Failure-Notifications
  - format_github_comment() - Konsistente Comment-Formatierung

- [ ] **API Error Handling & Rate Limiting**
  - check_api_rate_limit() - Verbleibende API-Calls prüfen
  - handle_api_error() - Exponential backoff und Retry-Logic
  - Graceful degradation bei API-Unavailability
  - Comprehensive error logging und reporting

- [ ] **Authentication & Security**
  - check_github_auth() - GitHub CLI Authentication validation
  - Secure handling von authentication tokens
  - User permission verification für target repositories
  - Input sanitization für comment content

- [ ] **Backup/Restore Operations**
  - save_task_progress_backup() - Progress als GitHub Comment sichern
  - load_task_progress_backup() - Recovery von GitHub Comments
  - JSON-basiertes Progress Backup Format
  - Comment-basierte State-Persistence

## Untersuchung & Analyse

### Prior Art Recherche

**Verwandte Scratchpads analysiert:**
- `scratchpads/completed/2025-08-24_task-queue-core-module-implementation.md` - Core Module Foundation
- `scratchpads/review-PR-45.md` - Excellence Rating (A-) für bestehende Architektur
- Keine vorherigen GitHub Integration Module gefunden - Clean Slate Implementation

**GitHub PRs Research:**
- **PR #45**: feat: Implement Task Queue Core Module (A- Rating, merge-ready)
- **PR #52**: feat: Phase 1 - Task Execution Engine CLI Integration 
- **PR #51**: feat: Implement comprehensive CLI interface

**Erfolgreiche Architektur-Patterns von PR #45:**
- **Modulare Struktur**: 2,415+ Zeilen professioneller Bash-Code
- **Robuste Error-Handling**: `set -euo pipefail`, comprehensive validation
- **State-Management**: Associative Arrays für in-memory operations
- **JSON-Persistenz**: Atomic operations mit jq-based validation
- **Strukturiertes Logging**: Integration mit utils/logging.sh
- **Cross-Platform**: macOS/Linux compatibility mit graceful degradation

### Bestehende Integration-Punkte

**Von PR #45 übernehmen:**
```bash
# Bewährte Patterns aus src/task-queue.sh
declare -A GITHUB_API_CACHE          # Analog zu TASK_STATES pattern
declare -A GITHUB_RATE_LIMITS        # API rate limiting tracking
declare -A COMMENT_TEMPLATES         # Reusable comment formats

# Logging-Integration (bereits etabliert)
log_info "GitHub API operation started"
log_warn "Rate limit threshold approached"  
log_error "GitHub API authentication failed"

# Config-Integration (bestehende config/default.conf erweitern)
GITHUB_AUTO_COMMENT=true
GITHUB_API_CACHE_TTL=300
GITHUB_RETRY_ATTEMPTS=3
```

**GitHub CLI Integration-Strategy:**
- Verwende bestehende `gh auth` für authentication
- Nutze `gh api` für direkte REST API calls
- Fallback auf `curl` für erweiterte API operations
- Respect für GitHub's Rate Limiting (5000 calls/hour)

### API Error-Handling-Patterns (von PR #45 inspiriert)

```bash
# Analog zu with_queue_lock() pattern
with_api_rate_limit() {
    local api_operation="$1"
    shift
    
    # Check rate limit before operation
    check_api_rate_limit || {
        log_warn "API rate limit threshold reached, backing off"
        return 2  # Specific error code for rate limiting
    }
    
    # Execute with retry logic
    execute_with_retry "$api_operation" "$@"
}
```

### Comment Template Design

**Inspiriert von PR #45's JSON-Schema-Design:**
```markdown
🤖 **Claude Auto-Resume Task Queue**

**Task Started**: #{task_id} - {task_description}
**Timestamp**: {iso_timestamp}
**Expected Duration**: ~{estimated_time} minutes

*This task is being processed automatically by Claude Auto-Resume.*

---
**Queue Position**: {position}/{total_tasks}
**Progress**: [████████░░] {progress_percent}%
**Current Step**: {current_step}
**ETA**: {estimated_completion}
```

### Progress Backup JSON Format

```json
{
  "backup_metadata": {
    "backup_type": "task_progress_snapshot",
    "task_id": "task-001-github-41", 
    "timestamp": "2025-08-25T10:30:00Z",
    "claude_session_id": "session-abc123",
    "backup_version": "1.0"
  },
  "task_state": {
    "status": "in_progress",
    "progress_percent": 65,
    "current_step": "implementing GitHub API integration",
    "steps_completed": ["analysis", "planning", "core_structure"],
    "steps_remaining": ["testing", "integration", "documentation"]
  },
  "execution_context": {
    "github_issue": 41,
    "related_pr": null,
    "session_transcript_summary": "Successfully implemented core functions...",
    "next_actions": [
      "complete authentication validation",
      "implement rate limiting logic",
      "add comprehensive error handling"
    ]
  },
  "recovery_data": {
    "last_successful_operation": "fetch_issue_details",
    "current_branch": "feature/issue41-github-integration",
    "files_modified": ["src/github-integration.sh", "config/default.conf"],
    "commit_checkpoint": "abc1234"
  }
}
```

## Implementierungsplan

### Schritt 1: Basis-Framework und Integration erstellen

- [ ] **Module-Struktur etablieren** (Analog zu src/task-queue.sh)
  - Skript-Header mit Version, Dokumentation und Lizenz
  - Dependency-Loading (utils/logging.sh, config/default.conf)
  - Integration mit bestehendem Task Queue Core Module
  - Signal-Handler und cleanup_github_integration()

- [ ] **Core-Variablen und Konstanten definieren**
  ```bash
  # GitHub API Configuration
  GITHUB_API_BASE_URL="https://api.github.com"
  GITHUB_API_VERSION="2022-11-28"
  
  # Rate Limiting Configuration  
  GITHUB_RATE_LIMIT_THRESHOLD=100  # Remaining calls before backing off
  GITHUB_RATE_LIMIT_RESET_BUFFER=60  # Seconds buffer before reset
  
  # Caching Configuration
  GITHUB_CACHE_DEFAULT_TTL=300  # 5 minutes default cache
  GITHUB_CACHE_LONG_TTL=3600   # 1 hour for stable data
  
  # Comment Configuration
  GITHUB_COMMENT_MAX_LENGTH=65536  # GitHub's comment limit
  GITHUB_COMMENT_TRUNCATE_SUFFIX="... (truncated)"
  ```

### Schritt 2: Authentication und Permissions System

- [ ] **GitHub CLI Authentication Integration**
  ```bash
  check_github_auth()              # Verify gh auth status and permissions
  validate_repo_permissions()      # Check read/write access to target repo
  get_authenticated_user()         # Get current GitHub user info
  check_github_cli_version()       # Ensure compatible gh CLI version
  ```

- [ ] **Repository Access Validation**
  ```bash
  validate_github_repository()     # Check if repo exists and is accessible
  check_issue_write_permissions()  # Verify can write comments to issues
  check_pr_write_permissions()     # Verify can write comments to PRs
  get_repository_info()            # Fetch repo metadata and settings
  ```

- [ ] **Security und Input-Validation**
  - Input sanitization für alle GitHub API parameters
  - Comment content validation (length, format, security)
  - URL validation für GitHub-Links
  - Process isolation für sensitive operations

### Schritt 3: Core API Operations implementieren

- [ ] **Issue/PR Data Retrieval Functions**
  ```bash
  fetch_issue_details()            # Get comprehensive issue metadata
  fetch_pr_details()               # Get PR status, files, reviews
  validate_github_item()           # Verify issue/PR exists and accessible
  get_github_item_type()           # Determine if URL is issue or PR
  parse_github_url()               # Extract owner, repo, number from URL
  ```

- [ ] **API Response Processing**
  ```bash
  parse_github_api_response()      # Extract relevant fields from JSON
  validate_api_response()          # Check for errors and completeness
  transform_github_metadata()      # Convert to internal task format
  extract_labels_and_assignees()   # Process GitHub-specific fields
  ```

### Schritt 4: Intelligent Caching System

- [ ] **Multi-Level Caching Architecture**
  ```bash
  cache_github_data()              # Store API response with TTL
  get_cached_github_data()         # Retrieve from cache if valid
  invalidate_github_cache()        # Clear specific cache entries
  cleanup_expired_cache()          # Garbage collect old cache entries
  ```

- [ ] **Cache Strategy Implementation**
  - **Short-term cache (5min)**: Issue/PR status, comments count
  - **Medium-term cache (30min)**: Issue/PR metadata, labels
  - **Long-term cache (1hour)**: Repository info, user permissions
  - **Persistent cache**: Static data (repository name, owner)

- [ ] **Cache Storage und Persistence**
  ```bash
  # Analog zu queue/task-queue.json pattern
  save_github_cache()              # Atomic write to github-cache.json
  load_github_cache()              # Restore cache from file system
  backup_github_cache()            # Create timestamped cache backups
  ```

### Schritt 5: Comment Management System

- [ ] **Comment Template Engine**
  ```bash
  load_comment_templates()         # Load from config or defaults
  render_comment_template()        # Replace variables with actual values
  validate_comment_content()       # Check length and format constraints
  format_task_progress_comment()   # Progress-specific formatting
  ```

- [ ] **Comment Operations**
  ```bash
  post_task_start_comment()        # Initial task notification
  post_progress_comment()          # Update existing progress comment
  post_completion_comment()        # Task completion notification
  post_error_comment()             # Error and failure notifications
  ```

- [ ] **Advanced Comment Features**
  ```bash
  update_existing_comment()        # Edit existing comment instead of new
  find_progress_comment()          # Locate existing progress comment
  create_collapsible_comment()     # Use GitHub's collapsible sections
  add_reaction_to_comment()        # React to comments for status indication
  ```

### Schritt 6: Rate Limiting und Error Handling

- [ ] **Intelligent Rate Limiting**
  ```bash
  check_api_rate_limit()           # Get current rate limit status
  calculate_backoff_delay()        # Exponential backoff calculation
  wait_for_rate_limit_reset()      # Sleep until rate limit resets
  track_api_usage()                # Monitor API calls per hour
  ```

- [ ] **Retry Logic mit Exponential Backoff**
  ```bash
  execute_with_retry()             # Generic retry wrapper for API calls
  handle_api_error()               # Comprehensive API error processing
  determine_retry_eligibility()    # Check if error is retryable
  log_api_failure()                # Structured logging for API failures
  ```

- [ ] **Error Recovery Strategies**
  ```bash
  graceful_api_degradation()       # Continue operation without GitHub API
  fallback_to_local_cache()        # Use stale cache data when API fails
  queue_failed_comments()          # Retry comment posting later
  recover_from_auth_failure()      # Re-authenticate and retry
  ```

### Schritt 7: Backup/Restore System für Task Progress

- [ ] **Progress Backup Implementation**
  ```bash
  save_task_progress_backup()      # Save detailed progress to GitHub comment
  load_task_progress_backup()      # Restore task state from comment
  validate_backup_format()         # Ensure JSON backup is valid
  encrypt_sensitive_backup_data()  # Protect sensitive information in backups
  ```

- [ ] **Comment-based State Persistence**
  ```bash
  create_hidden_progress_comment() # Use HTML comments for state storage
  find_latest_backup_comment()     # Locate most recent backup
  merge_backup_with_current_state() # Combine backup with current progress
  cleanup_old_backup_comments()    # Remove outdated backup comments
  ```

- [ ] **Recovery Workflow Integration**
  - Integration mit Task Queue Core Module für state restoration
  - Automatic backup creation bei critical task transitions
  - Manual backup triggering über CLI interface
  - Cross-session recovery support

### Schritt 8: Configuration Integration

- [ ] **Extend config/default.conf**
  ```bash
  # ===============================================================================
  # GITHUB INTEGRATION CONFIGURATION
  # ===============================================================================
  
  # Core GitHub Integration Settings
  GITHUB_INTEGRATION_ENABLED=true
  GITHUB_AUTO_COMMENT=true
  GITHUB_STATUS_UPDATES=true
  GITHUB_COMPLETION_NOTIFICATIONS=true
  
  # API Configuration
  GITHUB_API_CACHE_TTL=300
  GITHUB_API_TIMEOUT=30
  GITHUB_RETRY_ATTEMPTS=3
  GITHUB_RETRY_DELAY=10
  GITHUB_RATE_LIMIT_THRESHOLD=100
  
  # Comment Configuration  
  GITHUB_COMMENT_TEMPLATES_DIR="config/github-templates"
  GITHUB_PROGRESS_UPDATES_INTERVAL=300
  GITHUB_MAX_COMMENT_LENGTH=65000
  GITHUB_USE_COLLAPSIBLE_SECTIONS=true
  
  # Backup Configuration
  GITHUB_PROGRESS_BACKUP_ENABLED=true
  GITHUB_BACKUP_RETENTION_HOURS=72
  GITHUB_BACKUP_COMPRESSION=true
  ```

- [ ] **Environment Variable Override Support**
  - Alle Config-Parameter als Environment Variables
  - Runtime-Configuration-Changes
  - Backward-compatibility mit bestehenden Settings

### Schritt 9: Integration mit Task Queue Core Module

- [ ] **Task Queue Integration Points**
  ```bash
  register_github_task_handlers()  # Register callbacks for GitHub tasks
  enrich_task_with_github_metadata() # Add GitHub data to task objects
  sync_github_status_with_task()    # Keep GitHub and task status in sync
  trigger_github_notifications()    # Call GitHub operations from task events
  ```

- [ ] **Event-driven Architecture**
  ```bash
  on_task_created()                 # GitHub comment on task creation
  on_task_started()                 # Update GitHub status to "in progress"  
  on_task_progress_update()         # Post progress updates to GitHub
  on_task_completed()               # Post completion notification
  on_task_failed()                  # Post failure notification with details
  ```

### Schritt 10: Testing Infrastructure

- [ ] **Unit Tests für GitHub API Operations**
  - Mock GitHub API responses mit curl/gh CLI stubs
  - Test alle API error scenarios (401, 403, 404, 429, 500)
  - Validate comment template rendering
  - Test cache operations und TTL logic

- [ ] **Integration Tests mit Real API**
  - Test repository für real GitHub API testing
  - Authentication workflow testing
  - Rate limiting behavior validation
  - End-to-end comment posting und retrieval

- [ ] **Error Scenario Testing**
  - Network connectivity failures
  - Authentication token expiration
  - Repository permission changes
  - API rate limit exhaustion
  - Malformed JSON responses

### Schritt 11: Performance Optimierung

- [ ] **API Call Optimization**
  - Batch API operations where possible
  - Intelligent caching strategy implementation
  - Lazy loading von nicht-critical data
  - Connection pooling für multiple API calls

- [ ] **Memory und Storage Efficiency**
  - Efficient JSON processing mit jq
  - Cache size limits und automatic cleanup
  - Streaming für large API responses
  - Compression für backup data

### Schritt 12: Dokumentation und CLI Integration

- [ ] **API Documentation**
  - Complete function documentation mit examples
  - Error code reference guide
  - Configuration parameter documentation
  - Troubleshooting guide

- [ ] **CLI Interface Extensions**
  ```bash
  ./src/github-integration.sh --check-auth
  ./src/github-integration.sh --test-permissions repo/name
  ./src/github-integration.sh --post-comment issue 123 "message"
  ./src/github-integration.sh --backup-progress task-id
  ./src/github-integration.sh --restore-progress comment-id
  ```

## Fortschrittsnotizen

**2025-08-25**: Initial Planning und Architecture Design abgeschlossen
- GitHub Issue #41 analysiert und requirements extrahiert
- Prior Art research durchgeführt - PR #45 als excellence foundation identifiziert
- Bestehende Task Queue Core Module Architektur studiert
- Integration-Strategy mit bewährten Patterns aus PR #45 entwickelt
- 12-Phasen-Implementierungsplan mit 50+ spezifischen Funktionen erstellt
- Comment Template Design und Backup JSON Schema definiert
- Configuration Integration Strategy festgelegt

**Erkannte Synergien mit PR #45:**
- Associative Arrays für in-memory state management
- Atomic JSON operations mit jq-based validation  
- Strukturiertes Logging-System integration
- Cross-platform compatibility patterns
- Error handling mit graceful degradation
- Configuration loading und environment override patterns

**Kritische Erfolgsfaktoren:**
- Authentication robust über GitHub CLI (`gh auth`)
- Rate limiting respektieren (5000 calls/hour limit)
- Comprehensive error handling mit retry logic
- Comment formatting für readability und branding
- Integration mit bestehendem Task Queue ohne breaking changes

## Technische Details

### GitHub API Integration Architecture

```bash
# Core Integration Pattern (inspiriert von PR #45's success)
declare -A GITHUB_API_CACHE
declare -A GITHUB_RATE_LIMITS  
declare -A GITHUB_AUTH_STATUS

# Main entry point
github_integration_main() {
    local operation="$1"
    shift
    
    # Initialize if needed (analog zu init_task_queue pattern)
    if ! github_integration_initialized; then
        init_github_integration || {
            log_error "Failed to initialize GitHub integration"
            return 1
        }
    fi
    
    # Execute operation with proper error handling
    case "$operation" in
        "fetch-issue") fetch_issue_details "$@" ;;
        "fetch-pr") fetch_pr_details "$@" ;;
        "post-comment") post_github_comment "$@" ;;
        "backup-progress") save_task_progress_backup "$@" ;;
        "restore-progress") load_task_progress_backup "$@" ;;
        *) log_error "Unknown GitHub integration operation: $operation"; return 1 ;;
    esac
}
```

### Rate Limiting Strategy

```bash
# Intelligent API rate limiting (building on PR #45's robust patterns)
check_api_rate_limit() {
    local threshold="${GITHUB_RATE_LIMIT_THRESHOLD:-100}"
    local rate_limit_info
    
    # Get current rate limit status
    rate_limit_info=$(gh api rate_limit 2>/dev/null) || {
        log_warn "Unable to check GitHub API rate limit"
        return 0  # Assume OK if can't check
    }
    
    local remaining
    remaining=$(echo "$rate_limit_info" | jq -r '.rate.remaining // 999999')
    
    if [[ "$remaining" -lt "$threshold" ]]; then
        local reset_time
        reset_time=$(echo "$rate_limit_info" | jq -r '.rate.reset // 0')
        local wait_time
        wait_time=$((reset_time - $(date +%s) + 60))  # 60s buffer
        
        log_warn "GitHub API rate limit low: $remaining remaining, waiting ${wait_time}s"
        
        if [[ "$wait_time" -gt 0 ]]; then
            sleep "$wait_time"
        fi
    fi
    
    return 0
}
```

### Comment Template System

```bash
# Template-based comment generation
render_comment_template() {
    local template_name="$1"
    local -A variables
    shift
    
    # Parse key=value pairs into associative array
    while [[ $# -gt 0 ]]; do
        local key_value="$1"
        local key="${key_value%%=*}"
        local value="${key_value#*=}"
        variables["$key"]="$value"
        shift
    done
    
    # Load template
    local template_file="config/github-templates/${template_name}.md"
    if [[ ! -f "$template_file" ]]; then
        log_error "GitHub comment template not found: $template_file"
        return 1
    fi
    
    # Render template with variable substitution
    local rendered_content
    rendered_content=$(cat "$template_file")
    
    for key in "${!variables[@]}"; do
        local value="${variables[$key]}"
        rendered_content="${rendered_content//\{$key\}/$value}"
    done
    
    echo "$rendered_content"
}
```

## Ressourcen & Referenzen

- **GitHub Issue #41**: Complete specification und acceptance criteria
- **PR #45 Review**: Scratchpad `scratchpads/review-PR-45.md` - A- Rating Excellence
- **Task Queue Core Module**: `scratchpads/completed/2025-08-24_task-queue-core-module-implementation.md`
- **GitHub REST API Documentation**: https://docs.github.com/en/rest
- **GitHub CLI Manual**: https://cli.github.com/manual/
- **Rate Limiting Best Practices**: https://docs.github.com/en/rest/guides/best-practices-for-integrators
- **JSON Processing mit jq**: https://stedolan.github.io/jq/manual/

## Abschluss-Checkliste

- [ ] **Kern-Funktionalität implementiert**
  - Alle GitHub API operations (fetch, validate, comment)
  - Rate limiting mit exponential backoff
  - Comprehensive caching system
  - Authentication und permission validation

- [ ] **Integration abgeschlossen**
  - Task Queue Core Module integration
  - Configuration system erweitert  
  - Logging system integration
  - CLI interface extended

- [ ] **Robustheit sichergestellt**
  - Comprehensive error handling für alle API scenarios
  - Graceful degradation bei API unavailability
  - Backup/restore mechanisms functional
  - Cross-platform compatibility validated

- [ ] **Tests geschrieben und bestanden**
  - Unit tests für alle core functions (>50 tests)
  - Integration tests mit real GitHub API
  - Error scenario und edge case testing
  - Performance testing mit rate limits

- [ ] **Dokumentation aktualisiert**
  - API documentation complete
  - Configuration reference guide
  - Troubleshooting documentation
  - Example usage scenarios

---
**Status**: Aktiv
**Zuletzt aktualisiert**: 2025-08-25