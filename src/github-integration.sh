#!/usr/bin/env bash

# Claude Auto-Resume - GitHub Integration Module
# GitHub API Integration System für automatisierte Issue/PR Operations
# Version: 1.0.0-alpha
# Letzte Aktualisierung: 2025-08-25
# 
# Dieses Modul implementiert umfassende GitHub API-Integration für das Task Queue System
# inklusive Issue/PR-Metadaten-Abruf, Status-Comment-Management und robuste
# Fehlerbehandlung mit Rate-Limiting-Support.

set -euo pipefail

# ===============================================================================
# GLOBALE VARIABLEN UND KONSTANTEN
# ===============================================================================

# GitHub API Configuration
# Protect against re-sourcing - only declare readonly if not already set
if [[ -z "${GITHUB_API_BASE_URL:-}" ]]; then
    readonly GITHUB_API_BASE_URL="https://api.github.com"
    readonly GITHUB_API_VERSION="2022-11-28"

    # Rate Limiting Configuration  
    readonly GITHUB_RATE_LIMIT_THRESHOLD="${GITHUB_RATE_LIMIT_THRESHOLD:-100}"
    readonly GITHUB_RATE_LIMIT_RESET_BUFFER="${GITHUB_RATE_LIMIT_RESET_BUFFER:-60}"

    # Caching Configuration
    readonly GITHUB_CACHE_DEFAULT_TTL="${GITHUB_CACHE_DEFAULT_TTL:-300}"
    readonly GITHUB_CACHE_LONG_TTL="${GITHUB_CACHE_LONG_TTL:-3600}"

    # Comment Configuration
    readonly GITHUB_COMMENT_MAX_LENGTH="${GITHUB_COMMENT_MAX_LENGTH:-65536}"
    readonly GITHUB_COMMENT_TRUNCATE_SUFFIX="${GITHUB_COMMENT_TRUNCATE_SUFFIX:-... (truncated)}"
fi

# GitHub Integration Status
GITHUB_INTEGRATION_ENABLED="${GITHUB_INTEGRATION_ENABLED:-true}"
GITHUB_AUTO_COMMENT="${GITHUB_AUTO_COMMENT:-true}"
GITHUB_STATUS_UPDATES="${GITHUB_STATUS_UPDATES:-true}"
GITHUB_COMPLETION_NOTIFICATIONS="${GITHUB_COMPLETION_NOTIFICATIONS:-true}"

# API Configuration
GITHUB_API_CACHE_TTL="${GITHUB_API_CACHE_TTL:-300}"
GITHUB_API_TIMEOUT="${GITHUB_API_TIMEOUT:-30}"
GITHUB_RETRY_ATTEMPTS="${GITHUB_RETRY_ATTEMPTS:-3}"
GITHUB_RETRY_DELAY="${GITHUB_RETRY_DELAY:-10}"

# Comment Configuration  
GITHUB_COMMENT_TEMPLATES_DIR="${GITHUB_COMMENT_TEMPLATES_DIR:-config/github-templates}"
GITHUB_PROGRESS_UPDATES_INTERVAL="${GITHUB_PROGRESS_UPDATES_INTERVAL:-300}"
GITHUB_MAX_COMMENT_LENGTH="${GITHUB_MAX_COMMENT_LENGTH:-65000}"
GITHUB_USE_COLLAPSIBLE_SECTIONS="${GITHUB_USE_COLLAPSIBLE_SECTIONS:-true}"

# Backup Configuration
GITHUB_PROGRESS_BACKUP_ENABLED="${GITHUB_PROGRESS_BACKUP_ENABLED:-true}"
GITHUB_BACKUP_RETENTION_HOURS="${GITHUB_BACKUP_RETENTION_HOURS:-72}"
GITHUB_BACKUP_COMPRESSION="${GITHUB_BACKUP_COMPRESSION:-true}"

# State-Tracking (global associative arrays) - analog zu task-queue.sh patterns
if ! declare -p GITHUB_API_CACHE >/dev/null 2>&1; then
    declare -gA GITHUB_API_CACHE
fi
if ! declare -p GITHUB_RATE_LIMITS >/dev/null 2>&1; then
    declare -gA GITHUB_RATE_LIMITS
fi
if ! declare -p GITHUB_AUTH_STATUS >/dev/null 2>&1; then
    declare -gA GITHUB_AUTH_STATUS
fi
if ! declare -p COMMENT_TEMPLATES >/dev/null 2>&1; then
    declare -gA COMMENT_TEMPLATES
fi
if ! declare -p GITHUB_REPOSITORY_INFO >/dev/null 2>&1; then
    declare -gA GITHUB_REPOSITORY_INFO
fi

# GitHub Item Type Constants
if [[ -z "${GITHUB_ITEM_TYPE_ISSUE:-}" ]]; then
    readonly GITHUB_ITEM_TYPE_ISSUE="issue"
    readonly GITHUB_ITEM_TYPE_PR="pull_request"
    readonly GITHUB_ITEM_TYPE_UNKNOWN="unknown"

    # Comment Template Constants
    readonly GITHUB_COMMENT_TEMPLATE_TASK_START="task_start"
    readonly GITHUB_COMMENT_TEMPLATE_PROGRESS="progress"
    readonly GITHUB_COMMENT_TEMPLATE_COMPLETION="completion"
    readonly GITHUB_COMMENT_TEMPLATE_ERROR="error"
fi

# Module initialization flag
GITHUB_INTEGRATION_INITIALIZED=false

# ===============================================================================
# HILFSFUNKTIONEN UND DEPENDENCIES
# ===============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Lade Utility-Module
if [[ -f "$SCRIPT_DIR/utils/logging.sh" ]]; then
    source "$SCRIPT_DIR/utils/logging.sh"
else
    log_debug() { echo "[DEBUG] $*" >&2; }
    log_info() { echo "[INFO] $*" >&2; }
    log_warn() { echo "[WARN] $*" >&2; }
    log_error() { echo "[ERROR] $*" >&2; }
fi

# Lade Konfiguration
if [[ -f "$PROJECT_ROOT/config/default.conf" ]]; then
    # Source config with proper error handling
    if ! source "$PROJECT_ROOT/config/default.conf" 2>/dev/null; then
        log_warn "Failed to source config file, using default values"
    fi
fi

# Prüfe ob Kommando verfügbar ist
has_command() {
    command -v "$1" >/dev/null 2>&1
}

# Prüfe Dependencies für GitHub Integration
check_github_dependencies() {
    local missing_deps=()
    
    if ! has_command jq; then
        missing_deps+=("jq")
    fi
    
    if ! has_command gh; then
        missing_deps+=("gh (GitHub CLI)")
    fi
    
    if ! has_command curl; then
        missing_deps+=("curl")
    fi
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Missing required GitHub integration dependencies: ${missing_deps[*]}"
        log_error "Please install missing dependencies:"
        log_error "  - jq: sudo apt-get install jq (Ubuntu/Debian) or brew install jq (macOS)"
        log_error "  - gh: https://cli.github.com/"
        log_error "  - curl: usually pre-installed on most systems"
        return 1
    fi
    
    return 0
}

# ===============================================================================
# SIGNAL-HANDLER UND CLEANUP
# ===============================================================================

# Cleanup-Funktion für GitHub Integration
cleanup_github_integration() {
    log_debug "Cleaning up GitHub integration resources..."
    
    # Cleanup temporäre Cache-Dateien
    if [[ -n "${GITHUB_TEMP_CACHE_FILE:-}" ]] && [[ -f "$GITHUB_TEMP_CACHE_FILE" ]]; then
        rm -f "$GITHUB_TEMP_CACHE_FILE" 2>/dev/null || true
    fi
    
    # Cleanup Lock-Dateien
    if [[ -n "${GITHUB_CACHE_LOCK_FILE:-}" ]] && [[ -f "$GITHUB_CACHE_LOCK_FILE" ]]; then
        rm -f "$GITHUB_CACHE_LOCK_FILE" 2>/dev/null || true
    fi
    
    log_debug "GitHub integration cleanup completed"
}

# Signal-Handler registrieren
trap cleanup_github_integration EXIT
trap 'cleanup_github_integration; exit 130' INT
trap 'cleanup_github_integration; exit 143' TERM

# ===============================================================================
# MODUL-INITIALISIERUNG
# ===============================================================================

# Initialisiert das GitHub Integration Module
init_github_integration() {
    log_debug "Initializing GitHub integration module..."
    
    # Prüfe Dependencies
    if ! check_github_dependencies; then
        log_error "GitHub integration dependencies check failed"
        return 1
    fi
    
    # Erstelle Cache-Verzeichnis falls nicht vorhanden
    local cache_dir="$PROJECT_ROOT/.github-cache"
    if [[ ! -d "$cache_dir" ]]; then
        if ! mkdir -p "$cache_dir" 2>/dev/null; then
            log_error "Failed to create GitHub cache directory: $cache_dir"
            return 1
        fi
        log_debug "Created GitHub cache directory: $cache_dir"
    fi
    
    # Prüfe GitHub CLI Authentication
    if ! check_github_auth; then
        log_warn "GitHub CLI not authenticated - some features may not work"
        log_info "Run 'gh auth login' to authenticate with GitHub"
    fi
    
    # Lade Comment-Templates
    if ! load_comment_templates; then
        log_warn "Failed to load comment templates - using built-in defaults"
    fi
    
    # Cleanup abgelaufene Cache-Einträge
    cleanup_expired_cache
    
    GITHUB_INTEGRATION_INITIALIZED=true
    log_info "GitHub integration module initialized successfully"
    return 0
}

# Prüft ob GitHub Integration Module initialisiert ist
github_integration_initialized() {
    [[ "$GITHUB_INTEGRATION_INITIALIZED" == true ]]
}

# ===============================================================================
# AUTHENTICATION UND PERMISSIONS SYSTEM
# ===============================================================================

# Überprüft GitHub CLI Authentication Status
check_github_auth() {
    log_debug "Checking GitHub CLI authentication status..."
    
    # Prüfe ob gh CLI verfügbar ist
    if ! has_command gh; then
        log_error "GitHub CLI (gh) not found in PATH"
        GITHUB_AUTH_STATUS["authenticated"]="false"
        GITHUB_AUTH_STATUS["error"]="gh_cli_not_found"
        return 1
    fi
    
    # Prüfe GitHub CLI Version
    local gh_version
    if ! gh_version=$(gh --version 2>/dev/null | head -n1 | grep -o 'gh version [0-9][0-9.]*' | cut -d' ' -f3); then
        log_error "Failed to determine GitHub CLI version"
        GITHUB_AUTH_STATUS["authenticated"]="false" 
        GITHUB_AUTH_STATUS["error"]="version_check_failed"
        return 1
    fi
    
    log_debug "GitHub CLI version: $gh_version"
    GITHUB_AUTH_STATUS["gh_version"]="$gh_version"
    
    # Prüfe Authentication Status
    local auth_status
    if auth_status=$(gh auth status --hostname github.com 2>&1); then
        # Parse authenticated user
        local authenticated_user
        authenticated_user=$(echo "$auth_status" | grep "Logged in to github.com as" | sed 's/.*as \([^ ]*\).*/\1/' || echo "unknown")
        
        GITHUB_AUTH_STATUS["authenticated"]="true"
        GITHUB_AUTH_STATUS["user"]="$authenticated_user"
        GITHUB_AUTH_STATUS["hostname"]="github.com"
        GITHUB_AUTH_STATUS["error"]=""
        
        log_debug "GitHub authentication successful - user: $authenticated_user"
        return 0
    else
        log_warn "GitHub CLI not authenticated"
        log_debug "Auth status output: $auth_status"
        
        GITHUB_AUTH_STATUS["authenticated"]="false"
        GITHUB_AUTH_STATUS["error"]="not_authenticated"
        GITHUB_AUTH_STATUS["auth_status_output"]="$auth_status"
        
        return 1
    fi
}

# Validiert Repository-Zugriff und Berechtigungen
validate_repo_permissions() {
    local repo_full_name="$1"
    local required_permission="${2:-read}"  # read, write, admin
    
    log_debug "Validating repository permissions for $repo_full_name (required: $required_permission)"
    
    # Prüfe ob Authentication verfügbar ist
    if [[ "${GITHUB_AUTH_STATUS[authenticated]:-false}" != "true" ]]; then
        log_error "Cannot validate repository permissions - not authenticated"
        return 1
    fi
    
    # Repository-Informationen abrufen
    local repo_info
    if ! repo_info=$(gh api "repos/$repo_full_name" 2>/dev/null); then
        log_error "Failed to access repository: $repo_full_name"
        log_error "Repository may not exist or you may not have access"
        return 1
    fi
    
    # Parse Repository-Berechtigungen
    local permissions
    permissions=$(echo "$repo_info" | jq -r '.permissions // {}' 2>/dev/null) || {
        log_warn "Could not parse repository permissions"
        # Fallback: Annahme dass Repository öffentlich ist
        if echo "$repo_info" | jq -e '.private == false' >/dev/null 2>&1; then
            log_debug "Repository appears to be public - assuming read access"
            return 0
        else
            log_error "Cannot determine repository permissions"
            return 1
        fi
    }
    
    # Prüfe spezifische Berechtigung
    local has_permission=false
    case "$required_permission" in
        "read")
            # Read-Zugriff ist erfüllt wenn wir Repository-Info abrufen konnten
            has_permission=true
            ;;
        "write")
            if echo "$permissions" | jq -e '.push == true or .maintain == true or .admin == true' >/dev/null 2>&1; then
                has_permission=true
            fi
            ;;
        "admin")
            if echo "$permissions" | jq -e '.admin == true' >/dev/null 2>&1; then
                has_permission=true
            fi
            ;;
        *)
            log_error "Unknown permission level: $required_permission"
            return 1
            ;;
    esac
    
    if [[ "$has_permission" == true ]]; then
        log_debug "Repository permission '$required_permission' verified for $repo_full_name"
        
        # Cache Repository-Info für spätere Verwendung
        GITHUB_REPOSITORY_INFO["${repo_full_name}:permissions"]="$permissions"
        GITHUB_REPOSITORY_INFO["${repo_full_name}:full_name"]="$repo_full_name"
        GITHUB_REPOSITORY_INFO["${repo_full_name}:cached_at"]="$(date +%s)"
        
        return 0
    else
        log_error "Insufficient repository permissions for $repo_full_name (required: $required_permission)"
        return 1
    fi
}

# Ruft Informationen über den authentifizierten Benutzer ab
get_authenticated_user() {
    log_debug "Getting authenticated user information..."
    
    if [[ "${GITHUB_AUTH_STATUS[authenticated]:-false}" != "true" ]]; then
        log_error "Cannot get user information - not authenticated"
        return 1
    fi
    
    # Bereits gecached?
    if [[ -n "${GITHUB_AUTH_STATUS[user]:-}" ]]; then
        echo "${GITHUB_AUTH_STATUS[user]}"
        return 0
    fi
    
    # User-Info über API abrufen
    local user_info
    if user_info=$(gh api user 2>/dev/null); then
        local username
        username=$(echo "$user_info" | jq -r '.login' 2>/dev/null) || username="unknown"
        
        GITHUB_AUTH_STATUS["user"]="$username"
        echo "$username"
        return 0
    else
        log_error "Failed to fetch authenticated user information"
        return 1
    fi
}

# Validiert GitHub Repository URL und extrahiert Komponenten
parse_github_url() {
    local github_url="$1"
    
    log_debug "Parsing GitHub URL: $github_url"
    
    # Normalisiere URL (entferne trailing slash, etc.)
    github_url=$(echo "$github_url" | sed 's/\/$//')
    
    # Regex patterns für verschiedene GitHub URL-Formate
    local owner repo item_type item_number
    
    # Pattern 1: https://github.com/owner/repo/issues/123
    if [[ "$github_url" =~ ^https://github\.com/([^/]+)/([^/]+)/issues/([0-9]+)$ ]]; then
        owner="${BASH_REMATCH[1]}"
        repo="${BASH_REMATCH[2]}"
        item_type="$GITHUB_ITEM_TYPE_ISSUE"
        item_number="${BASH_REMATCH[3]}"
    # Pattern 2: https://github.com/owner/repo/pull/123
    elif [[ "$github_url" =~ ^https://github\.com/([^/]+)/([^/]+)/pull/([0-9]+)$ ]]; then
        owner="${BASH_REMATCH[1]}"
        repo="${BASH_REMATCH[2]}"
        item_type="$GITHUB_ITEM_TYPE_PR"
        item_number="${BASH_REMATCH[3]}"
    # Pattern 3: owner/repo#123 (short format)
    elif [[ "$github_url" =~ ^([^/]+)/([^/#]+)#([0-9]+)$ ]]; then
        owner="${BASH_REMATCH[1]}"
        repo="${BASH_REMATCH[2]}"
        item_number="${BASH_REMATCH[3]}"
        # Item-Typ muss separat ermittelt werden
        item_type="$GITHUB_ITEM_TYPE_UNKNOWN"
    else
        log_error "Invalid GitHub URL format: $github_url"
        log_error "Supported formats:"
        log_error "  - https://github.com/owner/repo/issues/123"
        log_error "  - https://github.com/owner/repo/pull/123"
        log_error "  - owner/repo#123"
        return 1
    fi
    
    # Output as JSON for easy parsing
    jq -n \
        --arg owner "$owner" \
        --arg repo "$repo" \
        --arg item_type "$item_type" \
        --arg item_number "$item_number" \
        --arg full_name "${owner}/${repo}" \
        '{
            owner: $owner,
            repo: $repo,
            item_type: $item_type,
            item_number: ($item_number | tonumber),
            full_name: $full_name,
            github_url: $ARGS.positional[0]
        }' --args "$github_url"
}

# ===============================================================================
# CORE API OPERATIONS
# ===============================================================================

# Ermittelt den Typ eines GitHub Items (Issue oder PR)
get_github_item_type() {
    local owner="$1"
    local repo="$2"
    local item_number="$3"
    
    log_debug "Determining GitHub item type for $owner/$repo#$item_number"
    
    # Prüfe Cache
    local cache_key="${owner}/${repo}:${item_number}:type"
    if [[ -n "${GITHUB_API_CACHE[$cache_key]:-}" ]]; then
        local cached_entry="${GITHUB_API_CACHE[$cache_key]}"
        local cached_at expiry_time
        cached_at=$(echo "$cached_entry" | jq -r '.cached_at // 0')
        expiry_time=$((cached_at + GITHUB_CACHE_DEFAULT_TTL))
        
        if [[ $(date +%s) -lt $expiry_time ]]; then
            local cached_type
            cached_type=$(echo "$cached_entry" | jq -r '.data.item_type')
            log_debug "Using cached item type: $cached_type"
            echo "$cached_type"
            return 0
        fi
    fi
    
    # Rate-Limiting prüfen
    if ! check_api_rate_limit; then
        log_warn "API rate limit reached - cannot determine item type"
        return 2
    fi
    
    # Versuche zuerst Issue-API
    local api_response
    if api_response=$(gh api "repos/$owner/$repo/issues/$item_number" 2>/dev/null); then
        # Prüfe ob es ein Pull Request ist
        if echo "$api_response" | jq -e '.pull_request' >/dev/null 2>&1; then
            local item_type="$GITHUB_ITEM_TYPE_PR"
            
            # Cache das Ergebnis
            cache_github_data "$cache_key" "$item_type" "$GITHUB_CACHE_DEFAULT_TTL"
            
            echo "$item_type"
            return 0
        else
            local item_type="$GITHUB_ITEM_TYPE_ISSUE"
            
            # Cache das Ergebnis
            cache_github_data "$cache_key" "$item_type" "$GITHUB_CACHE_DEFAULT_TTL"
            
            echo "$item_type"
            return 0
        fi
    else
        log_error "GitHub item not found or not accessible: $owner/$repo#$item_number"
        return 1
    fi
}

# Ruft detaillierte Issue-Informationen ab
fetch_issue_details() {
    local owner="$1"
    local repo="$2"
    local issue_number="$3"
    
    log_debug "Fetching issue details for $owner/$repo#$issue_number"
    
    # Prüfe Cache
    local cache_key="${owner}/${repo}:issue:${issue_number}:details"
    if [[ -n "${GITHUB_API_CACHE[$cache_key]:-}" ]]; then
        local cached_entry="${GITHUB_API_CACHE[$cache_key]}"
        local cached_at expiry_time
        cached_at=$(echo "$cached_entry" | jq -r '.cached_at // 0')
        expiry_time=$((cached_at + GITHUB_CACHE_DEFAULT_TTL))
        
        if [[ $(date +%s) -lt $expiry_time ]]; then
            log_debug "Using cached issue details for $owner/$repo#$issue_number"
            echo "$cached_entry" | jq -r '.data'
            return 0
        fi
    fi
    
    # Rate-Limiting prüfen
    if ! check_api_rate_limit; then
        log_error "API rate limit reached - cannot fetch issue details"
        return 2
    fi
    
    # Issue-Details über API abrufen
    local issue_data
    if issue_data=$(gh api "repos/$owner/$repo/issues/$issue_number" 2>/dev/null); then
        # Validiere dass es wirklich ein Issue ist (nicht PR)
        if echo "$issue_data" | jq -e '.pull_request' >/dev/null 2>&1; then
            log_error "Item $owner/$repo#$issue_number is a Pull Request, not an Issue"
            return 1
        fi
        
        # Erweitere Issue-Daten mit nützlichen Informationen
        local enhanced_data
        enhanced_data=$(echo "$issue_data" | jq \
            --arg owner "$owner" \
            --arg repo "$repo" \
            --arg full_name "${owner}/${repo}" \
            '. + {
                repository_owner: $owner,
                repository_name: $repo,
                repository_full_name: $full_name,
                item_type: "issue",
                fetched_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
            }')
        
        # Cache das Ergebnis
        cache_github_data "$cache_key" "$enhanced_data" "$GITHUB_CACHE_DEFAULT_TTL"
        
        log_debug "Successfully fetched issue details for $owner/$repo#$issue_number"
        echo "$enhanced_data"
        return 0
    else
        log_error "Failed to fetch issue details for $owner/$repo#$issue_number"
        log_error "Issue may not exist or you may not have access"
        return 1
    fi
}

# Ruft detaillierte Pull Request-Informationen ab
fetch_pr_details() {
    local owner="$1"
    local repo="$2"
    local pr_number="$3"
    
    log_debug "Fetching PR details for $owner/$repo#$pr_number"
    
    # Prüfe Cache
    local cache_key="${owner}/${repo}:pr:${pr_number}:details"
    if [[ -n "${GITHUB_API_CACHE[$cache_key]:-}" ]]; then
        local cached_entry="${GITHUB_API_CACHE[$cache_key]}"
        local cached_at expiry_time
        cached_at=$(echo "$cached_entry" | jq -r '.cached_at // 0')
        expiry_time=$((cached_at + GITHUB_CACHE_DEFAULT_TTL))
        
        if [[ $(date +%s) -lt $expiry_time ]]; then
            log_debug "Using cached PR details for $owner/$repo#$pr_number"
            echo "$cached_entry" | jq -r '.data'
            return 0
        fi
    fi
    
    # Rate-Limiting prüfen
    if ! check_api_rate_limit; then
        log_error "API rate limit reached - cannot fetch PR details"
        return 2
    fi
    
    # PR-Details über API abrufen
    local pr_data
    if pr_data=$(gh api "repos/$owner/$repo/pulls/$pr_number" 2>/dev/null); then
        # Erweitere PR-Daten mit nützlichen Informationen
        local enhanced_data
        enhanced_data=$(echo "$pr_data" | jq \
            --arg owner "$owner" \
            --arg repo "$repo" \
            --arg full_name "${owner}/${repo}" \
            '. + {
                repository_owner: $owner,
                repository_name: $repo,
                repository_full_name: $full_name,
                item_type: "pull_request",
                fetched_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
            }')
        
        # Cache das Ergebnis
        cache_github_data "$cache_key" "$enhanced_data" "$GITHUB_CACHE_DEFAULT_TTL"
        
        log_debug "Successfully fetched PR details for $owner/$repo#$pr_number"
        echo "$enhanced_data"
        return 0
    else
        log_error "Failed to fetch PR details for $owner/$repo#$pr_number"
        log_error "PR may not exist or you may not have access"
        return 1
    fi
}

# Validiert GitHub Item Existenz und Zugriff
validate_github_item() {
    local github_url="$1"
    
    log_debug "Validating GitHub item: $github_url"
    
    # Parse GitHub URL
    local parsed_url
    if ! parsed_url=$(parse_github_url "$github_url"); then
        log_error "Failed to parse GitHub URL: $github_url"
        return 1
    fi
    
    # Extrahiere Komponenten
    local owner repo item_number item_type
    owner=$(echo "$parsed_url" | jq -r '.owner')
    repo=$(echo "$parsed_url" | jq -r '.repo')
    item_number=$(echo "$parsed_url" | jq -r '.item_number')
    item_type=$(echo "$parsed_url" | jq -r '.item_type')
    
    # Prüfe Repository-Zugriff
    if ! validate_repo_permissions "${owner}/${repo}" "read"; then
        log_error "Cannot access repository ${owner}/${repo}"
        return 1
    fi
    
    # Ermittele Item-Typ falls unbekannt
    if [[ "$item_type" == "$GITHUB_ITEM_TYPE_UNKNOWN" ]]; then
        if ! item_type=$(get_github_item_type "$owner" "$repo" "$item_number"); then
            log_error "Failed to determine item type for $github_url"
            return 1
        fi
    fi
    
    # Validiere Item basierend auf Typ
    case "$item_type" in
        "$GITHUB_ITEM_TYPE_ISSUE")
            if fetch_issue_details "$owner" "$repo" "$item_number" >/dev/null; then
                log_debug "GitHub issue validated successfully: $github_url"
                return 0
            else
                log_error "GitHub issue validation failed: $github_url"
                return 1
            fi
            ;;
        "$GITHUB_ITEM_TYPE_PR")
            if fetch_pr_details "$owner" "$repo" "$item_number" >/dev/null; then
                log_debug "GitHub PR validated successfully: $github_url"
                return 0
            else
                log_error "GitHub PR validation failed: $github_url"
                return 1
            fi
            ;;
        *)
            log_error "Unknown GitHub item type: $item_type"
            return 1
            ;;
    esac
}

# ===============================================================================
# INTELLIGENT CACHING SYSTEM
# ===============================================================================

# Cacht GitHub API-Daten mit TTL
cache_github_data() {
    local cache_key="$1"
    local data="$2"
    local ttl="${3:-$GITHUB_CACHE_DEFAULT_TTL}"
    
    log_debug "Caching GitHub data with key: $cache_key (TTL: ${ttl}s)"
    
    # Erstelle Cache-Eintrag mit Metadaten
    local cache_entry
    cache_entry=$(jq -n \
        --argjson data "$data" \
        --arg ttl "$ttl" \
        '{
            data: $data,
            cached_at: (now | floor),
            ttl: ($ttl | tonumber),
            cache_key: $ARGS.positional[0]
        }' --args "$cache_key")
    
    # Speichere in In-Memory-Cache
    GITHUB_API_CACHE["$cache_key"]="$cache_entry"
    
    # Persistiere kritische Cache-Einträge auf Disk
    local cache_file="$PROJECT_ROOT/.github-cache/cache.json"
    if [[ "$ttl" -ge "$GITHUB_CACHE_LONG_TTL" ]]; then
        save_cache_to_disk "$cache_file"
    fi
    
    return 0
}

# Ruft Daten aus GitHub Cache ab
get_cached_github_data() {
    local cache_key="$1"
    
    # Prüfe In-Memory-Cache
    if [[ -n "${GITHUB_API_CACHE[$cache_key]:-}" ]]; then
        local cached_entry="${GITHUB_API_CACHE[$cache_key]}"
        local cached_at expiry_time
        cached_at=$(echo "$cached_entry" | jq -r '.cached_at // 0')
        local ttl
        ttl=$(echo "$cached_entry" | jq -r '.ttl // 300')
        expiry_time=$((cached_at + ttl))
        
        if [[ $(date +%s) -lt $expiry_time ]]; then
            log_debug "Cache hit for key: $cache_key"
            echo "$cached_entry" | jq -r '.data'
            return 0
        else
            log_debug "Cache expired for key: $cache_key"
            # Entferne abgelaufenen Cache-Eintrag
            unset GITHUB_API_CACHE["$cache_key"]
            return 1
        fi
    fi
    
    # Kein Cache-Hit
    log_debug "Cache miss for key: $cache_key"
    return 1
}

# Invalidiert spezifische Cache-Einträge
invalidate_github_cache() {
    local cache_pattern="$1"
    
    log_debug "Invalidating GitHub cache entries matching pattern: $cache_pattern"
    
    local invalidated_count=0
    local cache_key
    for cache_key in "${!GITHUB_API_CACHE[@]}"; do
        if [[ "$cache_key" == $cache_pattern ]]; then
            unset GITHUB_API_CACHE["$cache_key"]
            ((invalidated_count++))
            log_debug "Invalidated cache entry: $cache_key"
        fi
    done
    
    log_debug "Invalidated $invalidated_count cache entries"
    return 0
}

# Entfernt abgelaufene Cache-Einträge
cleanup_expired_cache() {
    log_debug "Cleaning up expired GitHub cache entries..."
    
    local current_time
    current_time=$(date +%s)
    local cleaned_count=0
    local cache_key
    
    for cache_key in "${!GITHUB_API_CACHE[@]}"; do
        local cached_entry="${GITHUB_API_CACHE[$cache_key]}"
        local cached_at expiry_time
        cached_at=$(echo "$cached_entry" | jq -r '.cached_at // 0' 2>/dev/null) || cached_at=0
        local ttl
        ttl=$(echo "$cached_entry" | jq -r '.ttl // 300' 2>/dev/null) || ttl=300
        expiry_time=$((cached_at + ttl))
        
        if [[ $current_time -ge $expiry_time ]]; then
            unset GITHUB_API_CACHE["$cache_key"]
            ((cleaned_count++))
            log_debug "Cleaned expired cache entry: $cache_key"
        fi
    done
    
    log_debug "Cleaned up $cleaned_count expired cache entries"
    return 0
}

# Speichert Cache auf Disk (für Persistierung)
save_cache_to_disk() {
    local cache_file="$1"
    
    log_debug "Saving GitHub cache to disk: $cache_file"
    
    # Erstelle Cache-Verzeichnis falls nicht vorhanden
    local cache_dir
    cache_dir=$(dirname "$cache_file")
    if [[ ! -d "$cache_dir" ]]; then
        mkdir -p "$cache_dir" 2>/dev/null || {
            log_warn "Failed to create cache directory: $cache_dir"
            return 1
        }
    fi
    
    # Konvertiere Associative Array zu JSON
    local cache_json
    cache_json=$(
        printf '{\n'
        local first=true
        for key in "${!GITHUB_API_CACHE[@]}"; do
            if [[ "$first" == true ]]; then
                first=false
            else
                printf ',\n'
            fi
            printf '  %s: %s' "$(jq -n --arg k "$key" '$k')" "${GITHUB_API_CACHE[$key]}"
        done
        printf '\n}\n'
    )
    
    # Atomic write mit temporärer Datei
    local temp_file="${cache_file}.tmp.$$"
    if echo "$cache_json" > "$temp_file" 2>/dev/null && mv "$temp_file" "$cache_file" 2>/dev/null; then
        log_debug "Successfully saved cache to disk"
        return 0
    else
        log_warn "Failed to save cache to disk"
        rm -f "$temp_file" 2>/dev/null || true
        return 1
    fi
}

# Lädt Cache von Disk (bei Startup)
load_cache_from_disk() {
    local cache_file="$1"
    
    if [[ ! -f "$cache_file" ]]; then
        log_debug "No cache file found: $cache_file"
        return 0
    fi
    
    log_debug "Loading GitHub cache from disk: $cache_file"
    
    # Lade und validiere Cache-Datei
    local cache_data
    if ! cache_data=$(cat "$cache_file" 2>/dev/null); then
        log_warn "Failed to read cache file: $cache_file"
        return 1
    fi
    
    # Validiere JSON-Format
    if ! echo "$cache_data" | jq empty 2>/dev/null; then
        log_warn "Invalid JSON in cache file: $cache_file"
        return 1
    fi
    
    # Lade Cache-Einträge in Associative Array
    local loaded_count=0
    local cache_key cache_value
    while IFS=$'\t' read -r cache_key cache_value; do
        GITHUB_API_CACHE["$cache_key"]="$cache_value"
        ((loaded_count++))
    done < <(echo "$cache_data" | jq -r 'to_entries[] | [.key, (.value | tostring)] | @tsv')
    
    log_debug "Loaded $loaded_count cache entries from disk"
    
    # Cleanup abgelaufene Einträge
    cleanup_expired_cache
    
    return 0
}

# ===============================================================================
# RATE LIMITING UND ERROR HANDLING
# ===============================================================================

# Überprüft aktuelle GitHub API Rate Limits
check_api_rate_limit() {
    local threshold="${1:-$GITHUB_RATE_LIMIT_THRESHOLD}"
    
    log_debug "Checking GitHub API rate limits (threshold: $threshold)"
    
    # Verwende gecachte Rate-Limit-Info falls verfügbar und aktuell
    local cache_key="rate_limit:core"
    local current_time
    current_time=$(date +%s)
    
    if [[ -n "${GITHUB_RATE_LIMITS[$cache_key]:-}" ]]; then
        local cached_info="${GITHUB_RATE_LIMITS[$cache_key]}"
        local cached_at
        cached_at=$(echo "$cached_info" | jq -r '.cached_at // 0')
        
        # Cache ist 30 Sekunden gültig
        if [[ $((current_time - cached_at)) -lt 30 ]]; then
            local remaining
            remaining=$(echo "$cached_info" | jq -r '.remaining // 999999')
            
            if [[ "$remaining" -lt "$threshold" ]]; then
                log_warn "GitHub API rate limit low: $remaining remaining (cached)"
                wait_for_rate_limit_reset "$cached_info"
                return $?
            fi
            
            return 0
        fi
    fi
    
    # Hole aktuelle Rate-Limit-Informationen
    local rate_limit_info
    if ! rate_limit_info=$(gh api rate_limit 2>/dev/null); then
        log_warn "Unable to check GitHub API rate limit - assuming OK"
        return 0
    fi
    
    # Parse Rate-Limit-Informationen
    local core_info
    core_info=$(echo "$rate_limit_info" | jq '.rate // {}')
    
    local remaining limit reset_timestamp
    remaining=$(echo "$core_info" | jq -r '.remaining // 5000')
    limit=$(echo "$core_info" | jq -r '.limit // 5000')  
    reset_timestamp=$(echo "$core_info" | jq -r '.reset // 0')
    
    # Cache Rate-Limit-Info
    local cached_entry
    cached_entry=$(jq -n \
        --arg remaining "$remaining" \
        --arg limit "$limit" \
        --arg reset_timestamp "$reset_timestamp" \
        --arg cached_at "$current_time" \
        '{
            remaining: ($remaining | tonumber),
            limit: ($limit | tonumber),
            reset: ($reset_timestamp | tonumber),
            cached_at: ($cached_at | tonumber)
        }')
    
    GITHUB_RATE_LIMITS["$cache_key"]="$cached_entry"
    
    log_debug "API Rate Limit Status: $remaining/$limit remaining, resets at $(date -d "@$reset_timestamp" 2>/dev/null || date -r "$reset_timestamp" 2>/dev/null || echo "unknown")"
    
    # Prüfe ob Rate-Limit-Threshold erreicht ist
    if [[ "$remaining" -lt "$threshold" ]]; then
        log_warn "GitHub API rate limit threshold reached: $remaining/$limit remaining"
        wait_for_rate_limit_reset "$cached_entry"
        return $?
    fi
    
    return 0
}

# Wartet bis Rate-Limit zurückgesetzt wird
wait_for_rate_limit_reset() {
    local rate_limit_info="$1"
    
    local reset_timestamp
    reset_timestamp=$(echo "$rate_limit_info" | jq -r '.reset // 0')
    
    if [[ "$reset_timestamp" -eq 0 ]]; then
        log_warn "Cannot determine rate limit reset time - waiting default period"
        sleep "$GITHUB_RETRY_DELAY"
        return 0
    fi
    
    local current_time wait_time
    current_time=$(date +%s)
    wait_time=$((reset_timestamp - current_time + GITHUB_RATE_LIMIT_RESET_BUFFER))
    
    if [[ "$wait_time" -le 0 ]]; then
        log_debug "Rate limit should already be reset"
        return 0
    fi
    
    # Begrenze Wartezeit auf maximum 1 Stunde
    if [[ "$wait_time" -gt 3600 ]]; then
        log_error "Rate limit reset time too far in future ($wait_time seconds) - something may be wrong"
        wait_time=300  # Fallback auf 5 Minuten
    fi
    
    log_info "Waiting for GitHub API rate limit reset: ${wait_time} seconds (until $(date -d "@$reset_timestamp" 2>/dev/null || date -r "$reset_timestamp" 2>/dev/null || echo "unknown"))"
    
    # Zeige Countdown für lange Wartezeiten
    if [[ "$wait_time" -gt 60 ]]; then
        local remaining="$wait_time"
        while [[ "$remaining" -gt 0 ]]; do
            local minutes=$((remaining / 60))
            local seconds=$((remaining % 60))
            printf "\rRate limit reset in: %02d:%02d" "$minutes" "$seconds"
            sleep 10
            remaining=$((remaining - 10))
            
            # Aktualisiere alle 60 Sekunden
            if [[ $((remaining % 60)) -eq 0 ]] && [[ "$remaining" -gt 0 ]]; then
                printf "\n"
                log_info "Still waiting for rate limit reset: ${remaining} seconds remaining"
            fi
        done
        printf "\n"
    else
        sleep "$wait_time"
    fi
    
    log_info "Rate limit wait period completed"
    return 0
}

# Führt API-Aufruf mit Retry-Logic aus
execute_with_retry() {
    local operation_name="$1"
    shift
    local attempts=0
    local max_attempts="${GITHUB_RETRY_ATTEMPTS:-3}"
    local base_delay="${GITHUB_RETRY_DELAY:-10}"
    
    log_debug "Executing API operation with retry: $operation_name (max attempts: $max_attempts)"
    
    while [[ $attempts -lt $max_attempts ]]; do
        ((attempts++))
        
        log_debug "API operation attempt $attempts/$max_attempts: $operation_name"
        
        # Rate-Limiting prüfen vor jedem Versuch
        if ! check_api_rate_limit; then
            log_warn "Rate limit check failed for operation: $operation_name"
        fi
        
        # Führe Operation aus
        local exit_code=0
        "$@" || exit_code=$?
        
        case $exit_code in
            0)
                log_debug "API operation succeeded: $operation_name (attempt $attempts)"
                return 0
                ;;
            2)
                # Rate limit error - bereits durch check_api_rate_limit behandelt
                log_warn "Rate limit error in operation: $operation_name (attempt $attempts)"
                ;;
            22)
                # HTTP error (curl) - könnte retryable sein
                log_warn "HTTP error in operation: $operation_name (attempt $attempts)"
                ;;
            *)
                # Andere Fehler - prüfe ob retryable
                if ! is_error_retryable "$exit_code"; then
                    log_error "Non-retryable error in operation: $operation_name (exit code: $exit_code)"
                    return $exit_code
                fi
                log_warn "Retryable error in operation: $operation_name (exit code: $exit_code, attempt $attempts)"
                ;;
        esac
        
        # Berechne Backoff-Delay (exponentiell mit Jitter)
        if [[ $attempts -lt $max_attempts ]]; then
            local delay=$((base_delay * (2 ** (attempts - 1))))
            # Füge Jitter hinzu (±25%)
            local jitter=$((delay / 4))
            local random_jitter=$((RANDOM % (2 * jitter + 1) - jitter))
            delay=$((delay + random_jitter))
            
            # Begrenze maximum delay
            if [[ $delay -gt 300 ]]; then
                delay=300
            fi
            
            log_info "Retrying operation '$operation_name' in ${delay} seconds (attempt $attempts/$max_attempts failed)"
            sleep "$delay"
        fi
    done
    
    log_error "API operation failed after $max_attempts attempts: $operation_name"
    return 1
}

# Prüft ob ein Fehler retryable ist
is_error_retryable() {
    local exit_code="$1"
    
    case $exit_code in
        # Network/connection errors (retryable)
        2|22|35|56) return 0 ;;
        # Authentication errors (not retryable)
        3|4|22) return 1 ;;
        # Permission/not found errors (not retryable) 
        1|8) return 1 ;;
        # Rate limiting (retryable)
        429) return 0 ;;
        # Server errors (retryable)
        500|502|503|504) return 0 ;;
        # Default: not retryable
        *) return 1 ;;
    esac
}

# Behandelt API-Fehler umfassend
handle_api_error() {
    local operation="$1"
    local exit_code="$2" 
    local error_output="$3"
    
    log_error "GitHub API error in operation '$operation' (exit code: $exit_code)"
    
    if [[ -n "$error_output" ]]; then
        log_error "Error output: $error_output"
        
        # Parse bekannte Error-Patterns
        if echo "$error_output" | grep -q "rate limit exceeded"; then
            log_error "Rate limit exceeded - please wait before retrying"
            return 2
        elif echo "$error_output" | grep -q "authentication"; then
            log_error "Authentication failed - please check your GitHub token"
            log_info "Run 'gh auth login' to re-authenticate"
            return 3
        elif echo "$error_output" | grep -q "not found\|404"; then
            log_error "Resource not found - check repository/issue/PR exists and you have access"
            return 4
        elif echo "$error_output" | grep -q "forbidden\|403"; then
            log_error "Access forbidden - insufficient permissions"
            return 5
        fi
    fi
    
    return 1
}

# ===============================================================================
# BACKUP/RESTORE SYSTEM FÜR TASK PROGRESS
# ===============================================================================

# Speichert Task-Progress als Backup in GitHub Comment
save_task_progress_backup() {
    local owner="$1"
    local repo="$2"
    local item_number="$3"
    local task_id="$4"
    local backup_data="$5"
    
    log_debug "Saving task progress backup for $task_id to $owner/$repo#$item_number"
    
    # Prüfe ob Progress-Backup aktiviert ist
    if [[ "$GITHUB_PROGRESS_BACKUP_ENABLED" != "true" ]]; then
        log_debug "Progress backup disabled - skipping backup"
        return 0
    fi
    
    # Validiere backup_data als JSON
    if ! echo "$backup_data" | jq empty 2>/dev/null; then
        log_error "Invalid JSON in backup data"
        return 1
    fi
    
    # Erstelle versteckten Backup-Comment (HTML comment)
    local backup_comment_body
    backup_comment_body="<!-- 
CLAUDE_AUTO_RESUME_BACKUP
Task ID: $task_id
Backup Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
Data: $backup_data
END_BACKUP
-->"
    
    # Poste Backup-Comment
    if post_github_comment "$owner" "$repo" "$item_number" "$backup_comment_body" "backup"; then
        log_info "Task progress backup saved successfully for $task_id"
        return 0
    else
        log_error "Failed to save task progress backup for $task_id"
        return 1
    fi
}

# Lädt Task-Progress-Backup von GitHub Comment
load_task_progress_backup() {
    local owner="$1"
    local repo="$2"
    local item_number="$3"
    local task_id="$4"
    
    log_debug "Loading task progress backup for $task_id from $owner/$repo#$item_number"
    
    # Suche Backup-Comment
    local backup_comment_id
    if ! backup_comment_id=$(find_latest_backup_comment "$owner" "$repo" "$item_number" "$task_id"); then
        log_warn "No backup comment found for task $task_id"
        return 1
    fi
    
    # Hole Comment-Inhalt
    local api_endpoint="repos/$owner/$repo/issues/comments/$backup_comment_id"
    local comment_data
    
    if ! comment_data=$(gh api "$api_endpoint" 2>/dev/null); then
        log_error "Failed to fetch backup comment $backup_comment_id"
        return 1
    fi
    
    # Extrahiere Backup-Daten aus Comment-Body
    local comment_body
    comment_body=$(echo "$comment_data" | jq -r '.body')
    
    # Parse Backup-Daten
    local backup_data
    backup_data=$(echo "$comment_body" | sed -n '/CLAUDE_AUTO_RESUME_BACKUP/,/END_BACKUP/p' | grep '^Data: ' | sed 's/^Data: //')
    
    if [[ -z "$backup_data" ]]; then
        log_error "No backup data found in comment $backup_comment_id"
        return 1
    fi
    
    # Validiere wiederhergestellte Daten
    if ! echo "$backup_data" | jq empty 2>/dev/null; then
        log_error "Invalid JSON in restored backup data"
        return 1
    fi
    
    log_info "Task progress backup loaded successfully for $task_id"
    echo "$backup_data"
    return 0
}

# Findet neuesten Backup-Comment
find_latest_backup_comment() {
    local owner="$1"
    local repo="$2"
    local item_number="$3"
    local task_id="$4"
    
    log_debug "Searching for latest backup comment for task $task_id"
    
    # Hole alle Comments
    local api_endpoint="repos/$owner/$repo/issues/$item_number/comments"
    local comments_response
    
    if ! comments_response=$(gh api "$api_endpoint" 2>/dev/null); then
        log_warn "Failed to fetch comments for backup search"
        return 1
    fi
    
    # Suche Backup-Comments für Task-ID
    local backup_comment_id
    backup_comment_id=$(echo "$comments_response" | jq -r --arg task_id "$task_id" '
        .[] | select(.body | contains("CLAUDE_AUTO_RESUME_BACKUP") and contains("Task ID: " + $task_id)) | 
        [.id, .created_at] | 
        @csv' | sort -t, -k2 -r | head -n1 | cut -d, -f1 | tr -d '"')
    
    if [[ -n "$backup_comment_id" ]] && [[ "$backup_comment_id" != "null" ]]; then
        log_debug "Found latest backup comment with ID: $backup_comment_id"
        echo "$backup_comment_id"
        return 0
    else
        log_debug "No backup comment found for task $task_id"
        return 1
    fi
}

# ===============================================================================
# CLI INTERFACE UND MAIN ENTRY POINT
# ===============================================================================

# Haupt-Entry-Point für GitHub Integration
github_integration_main() {
    local operation="$1"
    shift
    
    log_debug "GitHub integration main entry point: $operation"
    
    # Initialisiere falls nötig
    if ! github_integration_initialized; then
        if ! init_github_integration; then
            log_error "Failed to initialize GitHub integration"
            return 1
        fi
    fi
    
    # Führe Operation aus
    case "$operation" in
        # Authentication operations
        "check-auth")
            check_github_auth && echo "GitHub authentication: OK" || echo "GitHub authentication: FAILED"
            ;;
        "get-user")
            get_authenticated_user || return $?
            ;;
        
        # Repository operations
        "validate-repo")
            local repo_name="$1"
            local permission="${2:-read}"
            validate_repo_permissions "$repo_name" "$permission"
            ;;
        
        # GitHub item operations  
        "parse-url")
            local github_url="$1"
            parse_github_url "$github_url" || return $?
            ;;
        "validate-item")
            local github_url="$1"
            validate_github_item "$github_url"
            ;;
        "fetch-issue")
            local owner="$1" repo="$2" issue_number="$3"
            fetch_issue_details "$owner" "$repo" "$issue_number" || return $?
            ;;
        "fetch-pr")
            local owner="$1" repo="$2" pr_number="$3"
            fetch_pr_details "$owner" "$repo" "$pr_number" || return $?
            ;;
        
        # Comment operations
        "post-comment")
            local owner="$1" repo="$2" item_number="$3" comment_body="$4" comment_type="${5:-general}"
            post_github_comment "$owner" "$repo" "$item_number" "$comment_body" "$comment_type"
            ;;
        "post-task-start")
            local owner="$1" repo="$2" item_number="$3" task_id="$4" task_description="$5"
            post_task_start_comment "$owner" "$repo" "$item_number" "$task_id" "$task_description"
            ;;
        "post-progress")
            local owner="$1" repo="$2" item_number="$3" task_id="$4" task_description="$5" progress_percent="$6" current_step="$7"
            post_progress_comment "$owner" "$repo" "$item_number" "$task_id" "$task_description" "$progress_percent" "$current_step"
            ;;
        "post-completion")
            local owner="$1" repo="$2" item_number="$3" task_id="$4" task_description="$5" final_status="$6" completion_summary="${7:-Task completed successfully}"
            post_completion_comment "$owner" "$repo" "$item_number" "$task_id" "$task_description" "$final_status" "$completion_summary"
            ;;
        "post-error")
            local owner="$1" repo="$2" item_number="$3" task_id="$4" task_description="$5" error_type="$6" error_message="$7" progress_percent="${8:-0}" failed_step="${9:-unknown}"
            post_error_comment "$owner" "$repo" "$item_number" "$task_id" "$task_description" "$error_type" "$error_message" "$progress_percent" "$failed_step"
            ;;
        
        # Backup operations
        "backup-progress")
            local owner="$1" repo="$2" item_number="$3" task_id="$4" backup_data="$5"
            save_task_progress_backup "$owner" "$repo" "$item_number" "$task_id" "$backup_data"
            ;;
        "restore-progress")
            local owner="$1" repo="$2" item_number="$3" task_id="$4"
            load_task_progress_backup "$owner" "$repo" "$item_number" "$task_id" || return $?
            ;;
        
        # Cache operations
        "clear-cache")
            local pattern="${1:-*}"
            invalidate_github_cache "$pattern"
            log_info "Cache cleared (pattern: $pattern)"
            ;;
        "cleanup-cache")
            cleanup_expired_cache
            log_info "Expired cache entries cleaned up"
            ;;
        
        # Rate limit operations
        "check-rate-limit")
            local threshold="${1:-$GITHUB_RATE_LIMIT_THRESHOLD}"
            check_api_rate_limit "$threshold"
            ;;
        
        # Status operations
        "status")
            echo "GitHub Integration Module Status:"
            echo "  Initialized: $(github_integration_initialized && echo 'Yes' || echo 'No')"
            echo "  Authentication: $(check_github_auth >/dev/null 2>&1 && echo 'OK' || echo 'FAILED')"
            echo "  User: $(get_authenticated_user 2>/dev/null || echo 'Unknown')"
            echo "  Cache entries: $(([[ -v GITHUB_API_CACHE ]] && echo ${#GITHUB_API_CACHE[@]}) || echo 0)"
            echo "  Rate limit cache: $(([[ -v GITHUB_RATE_LIMITS ]] && echo ${#GITHUB_RATE_LIMITS[@]}) || echo 0)"
            echo "  Comment templates: $(([[ -v COMMENT_TEMPLATES ]] && echo ${#COMMENT_TEMPLATES[@]}) || echo 0)"
            ;;
        
        *)
            log_error "Unknown GitHub integration operation: $operation"
            echo "Usage: $0 <operation> [arguments...]"
            echo "Available operations:"
            echo "  Authentication: check-auth, get-user"
            echo "  Repository: validate-repo <repo> [permission]"
            echo "  GitHub Items: parse-url <url>, validate-item <url>, fetch-issue <owner> <repo> <number>, fetch-pr <owner> <repo> <number>"
            echo "  Comments: post-comment <owner> <repo> <number> <body> [type], post-task-start <owner> <repo> <number> <task_id> <description>"
            echo "  Progress: post-progress <owner> <repo> <number> <task_id> <description> <percent> <step>"
            echo "  Completion: post-completion <owner> <repo> <number> <task_id> <description> <status> [summary]"
            echo "  Error: post-error <owner> <repo> <number> <task_id> <description> <error_type> <message> [percent] [step]"
            echo "  Backup: backup-progress <owner> <repo> <number> <task_id> <data>, restore-progress <owner> <repo> <number> <task_id>"
            echo "  Cleanup: clear-cache [pattern], cleanup-cache"
            echo "  Utility: check-rate-limit [threshold], status"
            return 1
            ;;
    esac
}

# ===============================================================================
# SECURITY VALIDATION FUNCTIONS
# ===============================================================================

# Validiert und bereinigt Benutzereingaben für GitHub-Integration
validate_github_input() {
    local input="$1"
    local input_type="$2"  # 'issue_number', 'comment', 'url', etc.
    
    if [[ -z "$input" ]]; then
        log_error "Empty input provided for validation"
        return 1
    fi
    
    # Bereinige potentiell gefährliche Zeichen
    case "$input_type" in
        "issue_number")
            # Sollte nur Ziffern enthalten
            if [[ ! "$input" =~ ^[0-9]+$ ]]; then
                log_error "Invalid issue number format: $input"
                return 1
            fi
            # Prüfe vernünftige Grenzen
            if [[ ${#input} -gt 10 ]]; then
                log_error "Issue number too long: $input"
                return 1
            fi
            ;;
        "comment")
            # Escape HTML/markdown special chars und limitiere Länge
            if [[ ${#input} -gt 65000 ]]; then  # GitHub comment limit
                log_error "Comment too long: ${#input} characters (max 65000)"
                return 1
            fi
            # Escape potentielle HTML injection
            input=$(echo "$input" | sed 's/</\&lt;/g; s/>/\&gt;/g; s/&/\&amp;/g')
            ;;
        "url")
            # Validiere GitHub URL Format
            if [[ ! "$input" =~ ^https://github\.com/[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+/(issues|pull)/[0-9]+/?$ ]]; then
                log_error "Invalid GitHub URL format: $input"
                return 1
            fi
            ;;
        "repository")
            # Validiere Repository Format (owner/repo)
            if [[ ! "$input" =~ ^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$ ]]; then
                log_error "Invalid repository format: $input"
                return 1
            fi
            ;;
        "username")
            # Validiere GitHub Username Format
            if [[ ! "$input" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]){0,38}[a-zA-Z0-9]?$ ]]; then
                log_error "Invalid GitHub username format: $input"
                return 1
            fi
            ;;
    esac
    
    return 0
}

# Bereinigt Benutzereingaben von potentiell gefährlichen Inhalten
sanitize_user_input() {
    local input="$1"
    
    if [[ -z "$input" ]]; then
        echo ""
        return 0
    fi
    
    # Entferne null bytes und Steuerzeichen
    input=$(echo "$input" | tr -d '\000-\031\177-\377')
    
    # Limitiere Eingabelänge
    if [[ ${#input} -gt 10000 ]]; then
        input="${input:0:10000}"
        log_warn "Input truncated to 10000 characters for security"
    fi
    
    # Entferne potentielle Command Injection Patterns
    input=$(echo "$input" | sed 's/;[[:space:]]*[|&]/; /g; s/\$(/$/g; s/`/'"'"'/g')
    
    echo "$input"
}

# Validiert GitHub Token Format und Struktur
validate_github_token() {
    local token="$1"
    
    if [[ -z "$token" ]]; then
        log_debug "No GitHub token provided"
        return 1
    fi
    
    # Prüfe GitHub Token Format
    case "$token" in
        ghp_*)
            # Personal Access Token format
            if [[ ${#token} -ne 40 ]]; then
                log_error "Invalid GitHub personal access token format (wrong length)"
                return 1
            fi
            if [[ ! "$token" =~ ^ghp_[a-zA-Z0-9]{36}$ ]]; then
                log_error "Invalid GitHub personal access token format (invalid characters)"
                return 1
            fi
            ;;
        gho_*)
            # OAuth token format
            if [[ ${#token} -ne 40 ]]; then
                log_error "Invalid GitHub OAuth token format (wrong length)"
                return 1
            fi
            ;;
        ghu_*)
            # User-to-server token format
            if [[ ${#token} -ne 40 ]]; then
                log_error "Invalid GitHub user-to-server token format (wrong length)"
                return 1
            fi
            ;;
        ghs_*)
            # Server-to-server token format
            if [[ ${#token} -ne 40 ]]; then
                log_error "Invalid GitHub server-to-server token format (wrong length)"
                return 1
            fi
            ;;
        *)
            log_error "Unrecognized GitHub token format"
            return 1
            ;;
    esac
    
    return 0
}

# Verifiziert GitHub Repository Permissions
verify_github_permissions() {
    local repo_url="$1"
    
    if [[ -z "$repo_url" ]]; then
        log_error "No repository URL provided for permission verification"
        return 1
    fi
    
    # Validiere URL Format zuerst
    if ! validate_github_input "$repo_url" "url"; then
        return 1
    fi
    
    # Extrahiere owner/repo aus URL
    local repo_path
    repo_path=$(echo "$repo_url" | sed -n 's|.*github\.com/\([^/]*/[^/]*\).*|\1|p')
    
    if [[ -z "$repo_path" ]]; then
        log_error "Could not extract repository path from URL: $repo_url"
        return 1
    fi
    
    # Prüfe ob Benutzer Schreibzugriff hat (benötigt für Kommentare)
    local permissions_check
    if ! permissions_check=$(gh api "repos/$repo_path" --jq '.permissions.push // false' 2>/dev/null); then
        log_error "Failed to check repository permissions for: $repo_path"
        return 1
    fi
    
    if [[ "$permissions_check" != "true" ]]; then
        log_error "Insufficient permissions for repository: $repo_path"
        log_error "Write access is required for GitHub integration features"
        return 1
    fi
    
    log_debug "Repository permissions verified for: $repo_path"
    return 0
}

# Validiert GitHub API Response auf potentielle Sicherheitsprobleme
validate_github_api_response() {
    local response="$1"
    local expected_fields="${2:-}"  # Optional: comma-separated list of required fields
    
    if [[ -z "$response" ]]; then
        log_error "Empty GitHub API response"
        return 1
    fi
    
    # Prüfe ob Response gültiges JSON ist
    if ! echo "$response" | jq . >/dev/null 2>&1; then
        log_error "Invalid JSON in GitHub API response"
        return 1
    fi
    
    # Prüfe auf GitHub API Error Messages
    local error_message
    error_message=$(echo "$response" | jq -r '.message // empty' 2>/dev/null)
    if [[ -n "$error_message" ]]; then
        log_error "GitHub API error: $error_message"
        
        # Spezielle Behandlung für häufige Fehler
        case "$error_message" in
            *"rate limit"*|*"API rate limit"*)
                log_warn "Rate limit exceeded - implementing backoff strategy"
                return 2  # Special return code for rate limiting
                ;;
            *"authentication"*|*"token"*)
                log_error "Authentication failed - check GitHub token"
                return 3  # Special return code for auth issues
                ;;
            *"permission"*|*"access"*)
                log_error "Permission denied - check repository access"
                return 4  # Special return code for permission issues
                ;;
        esac
        
        return 1
    fi
    
    # Validiere erwartete Felder falls angegeben
    if [[ -n "$expected_fields" ]]; then
        IFS=',' read -ra fields <<< "$expected_fields"
        for field in "${fields[@]}"; do
            if ! echo "$response" | jq -e ".$field" >/dev/null 2>&1; then
                log_error "Required field '$field' missing in GitHub API response"
                return 1
            fi
        done
    fi
    
    # Prüfe auf verdächtig große Responses (DoS-Schutz)
    local response_size=${#response}
    if [[ $response_size -gt 1048576 ]]; then  # 1MB limit
        log_warn "GitHub API response is very large: ${response_size} bytes"
        log_warn "This might indicate an unexpected response or potential DoS"
    fi
    
    return 0
}

# Sichere GitHub API Request Funktion mit Input Validation
secure_github_api_request() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"
    
    # Validiere Method
    case "$method" in
        GET|POST|PATCH|DELETE)
            ;;
        *)
            log_error "Invalid HTTP method: $method"
            return 1
            ;;
    esac
    
    # Validiere Endpoint
    if [[ ! "$endpoint" =~ ^[a-zA-Z0-9/_.-]+$ ]]; then
        log_error "Invalid API endpoint format: $endpoint"
        return 1
    fi
    
    # Validiere GitHub Token
    if [[ -n "${GITHUB_TOKEN:-}" ]] && ! validate_github_token "$GITHUB_TOKEN"; then
        log_error "Invalid GitHub token - cannot make API request"
        return 1
    fi
    
    # Sanitize data falls bereitgestellt
    if [[ -n "$data" ]]; then
        data=$(sanitize_user_input "$data")
    fi
    
    # Make request mit Error Handling
    local response http_code
    if [[ "$method" == "GET" ]]; then
        response=$(gh api "$endpoint" 2>&1) || {
            http_code=$?
            log_error "GitHub API request failed: $response"
            return $http_code
        }
    else
        if [[ -n "$data" ]]; then
            response=$(gh api "$endpoint" --method "$method" --input - <<< "$data" 2>&1) || {
                http_code=$?
                log_error "GitHub API request failed: $response"
                return $http_code
            }
        else
            response=$(gh api "$endpoint" --method "$method" 2>&1) || {
                http_code=$?
                log_error "GitHub API request failed: $response"
                return $http_code
            }
        fi
    fi
    
    # Validiere Response
    if ! validate_github_api_response "$response"; then
        log_error "GitHub API response validation failed"
        return 1
    fi
    
    # Return clean response
    echo "$response"
    return 0
}

# Prüft auf verdächtige GitHub URLs oder Inhalte
check_suspicious_github_content() {
    local content="$1"
    local content_type="${2:-unknown}"
    
    if [[ -z "$content" ]]; then
        return 0
    fi
    
    # Patterns die auf verdächtige Inhalte hinweisen könnten
    local suspicious_patterns=(
        "javascript:"
        "data:"
        "<script"
        "onclick="
        "onerror="
        "onload="
        "eval\("
        "document\."
        "window\."
    )
    
    local suspicious_found=false
    for pattern in "${suspicious_patterns[@]}"; do
        if [[ "$content" == *"$pattern"* ]]; then
            log_warn "Suspicious pattern found in $content_type: $pattern"
            suspicious_found=true
        fi
    done
    
    # Prüfe auf ungewöhnlich lange URLs
    while IFS= read -r line; do
        if [[ "$line" =~ https?://[^[:space:]]{200,} ]]; then
            log_warn "Unusually long URL found in $content_type (potential security risk)"
            suspicious_found=true
        fi
    done <<< "$content"
    
    if [[ "$suspicious_found" == "true" ]]; then
        return 1
    fi
    
    return 0
}

# ===============================================================================
# MODULE LOADING UND SCRIPT EXECUTION
# ===============================================================================

# Lade Comment-Management-Module
if [[ -f "$SCRIPT_DIR/github-integration-comments.sh" ]]; then
    source "$SCRIPT_DIR/github-integration-comments.sh"
else
    log_warn "Comment management module not found - some functions may not be available"
fi

# Führe main function aus wenn Skript direkt aufgerufen wird
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ $# -eq 0 ]]; then
        github_integration_main "status"
    else
        github_integration_main "$@"
    fi
fi