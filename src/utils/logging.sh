#!/usr/bin/env bash

# Claude Auto-Resume - Logging Utilities
# Strukturiertes Logging-System für das claunch-basierte Session-Management
# Version: 1.0.0-alpha
# Letzte Aktualisierung: 2025-08-05

set -euo pipefail

# ===============================================================================
# GLOBALE VARIABLEN UND KONSTANTEN
# ===============================================================================

# Log-Level Konstanten - only declare as readonly if not already set
if [[ -z "${LOG_LEVEL_DEBUG:-}" ]]; then
    readonly LOG_LEVEL_DEBUG=0
    readonly LOG_LEVEL_INFO=1
    readonly LOG_LEVEL_WARN=2
    readonly LOG_LEVEL_ERROR=3
fi

# Standard-Konfiguration (wird von config/default.conf überschrieben)
LOG_LEVEL="${LOG_LEVEL:-INFO}"
LOG_FILE="${LOG_FILE:-logs/hybrid-monitor.log}"
LOG_ROTATION="${LOG_ROTATION:-true}"
MAX_LOG_SIZE="${MAX_LOG_SIZE:-100M}"
MAX_LOG_ARCHIVES="${MAX_LOG_ARCHIVES:-5}"
JSON_LOGGING="${JSON_LOGGING:-false}"
LOG_TIMESTAMP_FORMAT="${LOG_TIMESTAMP_FORMAT:-%Y-%m-%dT%H:%M:%S%z}"

# Interne Variablen
# Use conditional assignment to avoid readonly variable conflicts when sourced multiple times
# Check if SCRIPT_NAME is already set (and possibly readonly) before trying to assign
if [[ -z "${SCRIPT_NAME:-}" ]]; then
    SCRIPT_NAME=$(basename "$0")
elif ! readonly -p 2>/dev/null | grep -q "SCRIPT_NAME="; then
    # SCRIPT_NAME is set but not readonly, so we can update it if needed
    SCRIPT_NAME="${SCRIPT_NAME:-$(basename "$0")}"
fi
# If SCRIPT_NAME is readonly, we leave it as is
LOG_PID=$$

# ===============================================================================
# HILFSFUNKTIONEN
# ===============================================================================

# Konvertiert Log-Level-String zu numerischem Wert
get_log_level_numeric() {
    case "$(echo "$1" | tr '[:lower:]' '[:upper:]')" in
        "DEBUG") echo "$LOG_LEVEL_DEBUG" ;;
        "INFO")  echo "$LOG_LEVEL_INFO" ;;
        "SUCCESS") echo "$LOG_LEVEL_INFO" ;;  # Same level as INFO
        "WARN")  echo "$LOG_LEVEL_WARN" ;;
        "ERROR") echo "$LOG_LEVEL_ERROR" ;;
        *) echo "$LOG_LEVEL_INFO" ;;
    esac
}

# Prüft ob ein Log-Level ausgegeben werden soll
should_log() {
    local level="$1"
    local current_level_num
    local target_level_num
    
    # Special handling for DEBUG_MODE variable (backward compatibility)
    if [[ "$level" == "DEBUG" ]]; then
        if [[ "${DEBUG_MODE:-}" == "false" ]]; then
            return 1
        elif [[ "${DEBUG_MODE:-}" == "true" ]]; then
            return 0
        fi
    fi
    
    current_level_num=$(get_log_level_numeric "$LOG_LEVEL")
    target_level_num=$(get_log_level_numeric "$level")
    
    [[ $target_level_num -ge $current_level_num ]]
}

# Erstellt Verzeichnis für Log-Datei falls nicht vorhanden
ensure_log_directory() {
    local log_dir
    log_dir=$(dirname "$LOG_FILE")
    
    if [[ ! -d "$log_dir" ]]; then
        mkdir -p "$log_dir" || {
            echo "ERROR: Cannot create log directory: $log_dir" >&2
            return 1
        }
    fi
}

# Konvertiert Größenangabe (z.B. 100M) zu Bytes
size_to_bytes() {
    local size="$1"
    
    # Remove any quotes first
    size=$(echo "$size" | sed 's/^["'\'']\|["'\'']$//g')
    
    local number="${size%[KMG]*}"
    local unit="${size#"$number"}"
    
    # Validate that number is actually numeric
    if ! [[ "$number" =~ ^[0-9]+$ ]]; then
        echo "0"
        return 1
    fi
    
    case "$(echo "$unit" | tr '[:lower:]' '[:upper:]')" in
        "K"|"KB") echo $((number * 1024)) ;;
        "M"|"MB") echo $((number * 1024 * 1024)) ;;
        "G"|"GB") echo $((number * 1024 * 1024 * 1024)) ;;
        *) echo "$number" ;;
    esac
}

# Prüft ob Log-Rotation nötig ist
needs_rotation() {
    [[ "$LOG_ROTATION" != "true" ]] && return 1
    [[ ! -f "$LOG_FILE" ]] && return 1
    
    local max_bytes
    local current_size
    
    max_bytes=$(size_to_bytes "$MAX_LOG_SIZE")
    current_size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
    
    [[ $current_size -gt $max_bytes ]]
}

# Führt Log-Rotation durch
rotate_log() {
    [[ ! -f "$LOG_FILE" ]] && return 0
    
    local base_name="${LOG_FILE%.*}"
    local extension="${LOG_FILE##*.}"
    local max_archives="${MAX_LOG_ARCHIVES:-5}"
    local i
    
    # Rotiere bestehende Archive
    for ((i = max_archives - 1; i >= 1; i--)); do
        local old_file="${base_name}.${i}.${extension}"
        local new_file="${base_name}.$((i + 1)).${extension}"
        
        if [[ -f "$old_file" ]]; then
            mv "$old_file" "$new_file" || return 1
        fi
    done
    
    # Rotiere aktuelle Log-Datei
    mv "$LOG_FILE" "${base_name}.1.${extension}" || return 1
    
    # Entferne alte Archive
    local oldest_archive=$((max_archives + 1))
    local oldest_file="${base_name}.${oldest_archive}.${extension}"
    if [[ -f "$oldest_file" ]]; then
        rm -f "$oldest_file" || return 1
    fi
    
    return 0
}

# Generiert Timestamp für Log-Einträge
get_timestamp() {
    date +"$LOG_TIMESTAMP_FORMAT"
}

# Extrahiert aufrufende Funktion und Zeile
get_caller_info() {
    local frame="${1:-2}"
    local caller_info
    
    if caller_info=$(caller "$frame" 2>/dev/null); then
        local line_number=$(echo "$caller_info" | cut -d' ' -f1)
        local function_name=$(echo "$caller_info" | cut -d' ' -f2)
        local source_file=$(echo "$caller_info" | cut -d' ' -f3)
        
        echo "${source_file##*/}:${function_name}():${line_number}"
    else
        echo "unknown:unknown():0"
    fi
}

# ===============================================================================
# JSON-LOGGING-FUNKTIONEN
# ===============================================================================

# Escaped JSON-String erstellen
json_escape() {
    local string="$1"
    printf '%s' "$string" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g; s/\n/\\n/g; s/\r/\\r/g'
}

# JSON-Log-Eintrag erstellen
create_json_log() {
    local level="$1"
    local message="$2"
    local timestamp="$3"
    local caller="$4"
    
    cat <<EOF
{"timestamp":"$(json_escape "$timestamp")","level":"$(json_escape "$level")","message":"$(json_escape "$message")","caller":"$(json_escape "$caller")","script":"$(json_escape "$SCRIPT_NAME")","pid":$LOG_PID}
EOF
}

# ===============================================================================
# KERN-LOGGING-FUNKTIONEN
# ===============================================================================

# Allgemeine Log-Funktion
log_message() {
    local level="$1"
    local message="$2"
    local timestamp
    local caller_info
    local log_entry
    
    # Prüfe ob Level geloggt werden soll
    should_log "$level" || return 0
    
    # Stelle sicher, dass Log-Verzeichnis existiert
    ensure_log_directory || return 1
    
    # Führe Log-Rotation durch falls nötig
    needs_rotation && rotate_log
    
    # Sammle Metadaten
    timestamp=$(get_timestamp)
    caller_info=$(get_caller_info 3)
    
    # Erstelle Log-Eintrag basierend auf Format
    if [[ "$JSON_LOGGING" == "true" ]]; then
        log_entry=$(create_json_log "$level" "$message" "$timestamp" "$caller_info")
    else
        log_entry="[$timestamp] [$level] [$SCRIPT_NAME] [$caller_info]: $message"
    fi
    
    # Schreibe in Log-Datei und optional zu stderr/stdout
    {
        echo "$log_entry" >> "$LOG_FILE"
        
        # In TEST_MODE auch zu stderr ausgeben für BATS-Tests (nicht stdout, um Return-Werte nicht zu stören)
        if [[ "${TEST_MODE:-false}" == "true" ]]; then
            echo "$log_entry" >&2
        fi
        
        # Bei ERROR und WARN auch zu stderr ausgeben
        if [[ "$level" == "ERROR" || "$level" == "WARN" ]]; then
            echo "$log_entry" >&2
        fi
    } || {
        echo "ERROR: Failed to write to log file: $LOG_FILE" >&2
        return 1
    }
}

# ===============================================================================
# ÖFFENTLICHE LOGGING-FUNKTIONEN
# ===============================================================================

# Debug-Level Logging
log_debug() {
    log_message "DEBUG" "$*"
}

# Info-Level Logging
log_info() {
    log_message "INFO" "$*"
}

# Warning-Level Logging
log_warn() {
    log_message "WARN" "$*"
}

# Error-Level Logging
log_error() {
    log_message "ERROR" "$*"
}

# Success-Level Logging
log_success() {
    log_message "SUCCESS" "$*"
}

# ===============================================================================
# ERWEITERTE LOGGING-FUNKTIONEN
# ===============================================================================

# Logge Befehlsausführung mit Ergebnis
log_command() {
    local cmd="$*"
    local start_time
    local end_time
    local duration
    local exit_code
    local output
    
    log_debug "Executing command: $cmd"
    start_time=$(date +%s)
    
    if output=$(eval "$cmd" 2>&1); then
        exit_code=0
        log_debug "Command succeeded: $cmd"
    else
        exit_code=$?
        log_error "Command failed (exit $exit_code): $cmd"
        log_error "Command output: $output"
    fi
    
    end_time=$(date +%s)
    duration=$((end_time - start_time))
    
    log_debug "Command duration: ${duration}s"
    
    return $exit_code
}

# Logge Funktions-Entry/Exit
log_function_entry() {
    local function_name="${1:-$(get_caller_info 2 | cut -d: -f2 | tr -d '()')}"
    log_debug "Entering function: $function_name"
}

log_function_exit() {
    local function_name="${1:-$(get_caller_info 2 | cut -d: -f2 | tr -d '()')}"
    local exit_code="${2:-0}"
    log_debug "Exiting function: $function_name (exit code: $exit_code)"
}

# Logge Performance-Metriken
log_performance() {
    local operation="$1"
    local duration="$2"
    local unit="${3:-ms}"
    
    log_info "Performance: $operation took ${duration}${unit}"
}

# Logge Session-Events
log_session_event() {
    local session_id="$1"
    local event_type="$2"
    local details="${3:-}"
    
    local message="Session [$session_id] $event_type"
    [[ -n "$details" ]] && message="$message: $details"
    
    log_info "$message"
}

# ===============================================================================
# UTILITY-FUNKTIONEN
# ===============================================================================

# Initialisiere Logging-System
init_logging() {
    local config_file="${1:-config/default.conf}"
    
    # Lade Konfiguration falls vorhanden
    if [[ -f "$config_file" ]]; then
        # Sourcen der Config mit Schutz vor Code-Injection
        while IFS='=' read -r key value; do
            # Überspringe Kommentare und leere Zeilen
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$key" ]] && continue
            
            # Entferne Anführungszeichen von value
            value=$(echo "$value" | sed 's/^["'\'']\|["'\'']$//g')
            
            # Setze nur bekannte Logging-Variablen
            case "$key" in
                LOG_LEVEL|LOG_FILE|LOG_ROTATION|MAX_LOG_SIZE|MAX_LOG_ARCHIVES|JSON_LOGGING|LOG_TIMESTAMP_FORMAT)
                    eval "$key='$value'"
                    ;;
            esac
        done < <(grep -E '^[^#]*=' "$config_file" || true)
        
        log_debug "Logging initialized with config: $config_file"
    else
        log_debug "Logging initialized with default configuration"
    fi
    
    ensure_log_directory
}

# Zeige aktuelle Logging-Konfiguration
show_logging_config() {
    cat <<EOF
Logging Configuration:
  LOG_LEVEL: $LOG_LEVEL
  LOG_FILE: $LOG_FILE
  LOG_ROTATION: $LOG_ROTATION
  MAX_LOG_SIZE: $MAX_LOG_SIZE
  MAX_LOG_ARCHIVES: $MAX_LOG_ARCHIVES
  JSON_LOGGING: $JSON_LOGGING
  LOG_TIMESTAMP_FORMAT: $LOG_TIMESTAMP_FORMAT
EOF
}

# Bereinige alte Log-Dateien
cleanup_logs() {
    local days="${1:-30}"
    local log_dir
    
    log_dir=$(dirname "$LOG_FILE")
    
    log_info "Cleaning up log files older than $days days in $log_dir"
    
    find "$log_dir" -name "*.log*" -type f -mtime +"$days" -delete 2>/dev/null || {
        log_warn "Failed to cleanup some log files"
    }
}

# ===============================================================================
# PHASE 2: ENHANCED ERROR REPORTING (Issue #47)
# ===============================================================================

# Advanced structured error logging with context
log_error_with_context() {
    local message="$1"
    local error_code="${2:-1}"
    local component="${3:-unknown}"
    local operation="${4:-unknown}"
    local additional_context="${5:-}"
    
    # Capture system state for diagnostics
    local timestamp=$(date -Iseconds)
    local pid=$$
    local ppid=$PPID
    local working_dir=$PWD
    local hostname=$(hostname 2>/dev/null || echo "unknown")
    local user=$(whoami 2>/dev/null || echo "$USER")
    
    # Create structured error context
    local error_context=""
    if [[ "$JSON_LOGGING" == "true" ]]; then
        error_context=$(cat <<EOF
{
  "level": "ERROR",
  "timestamp": "$timestamp",
  "message": "$message",
  "error_code": $error_code,
  "component": "$component",
  "operation": "$operation",
  "context": {
    "pid": $pid,
    "ppid": $ppid,
    "hostname": "$hostname",
    "user": "$user",
    "working_dir": "$working_dir",
    "additional": "$additional_context"
  }
}
EOF
        )
    else
        error_context="[$timestamp] [ERROR] [$component:$operation] [PID:$pid] $message"
        if [[ -n "$additional_context" ]]; then
            error_context="$error_context (context: $additional_context)"
        fi
    fi
    
    # Log to both standard error log and structured format
    log_error "$message"
    
    # Also write structured context if available
    if ensure_log_directory; then
        echo "$error_context" >> "${LOG_FILE%.log}_errors.log" 2>/dev/null || true
    fi
}

# Log lock-specific errors with detailed diagnostics
log_lock_error() {
    local lock_operation="$1"
    local lock_file="$2"
    local error_message="$3"
    local lock_details="${4:-}"
    
    # Gather lock-specific diagnostics
    local lock_diagnostics=""
    
    if [[ -n "$lock_file" ]] && [[ -e "$lock_file" || -d "$lock_file" ]]; then
        local lock_permissions=$(stat -c "%A" "$lock_file" 2>/dev/null || stat -f "%Sp" "$lock_file" 2>/dev/null || echo "unknown")
        local lock_owner=$(stat -c "%U:%G" "$lock_file" 2>/dev/null || stat -f "%Su:%Sg" "$lock_file" 2>/dev/null || echo "unknown")
        local lock_size=$(du -sh "$lock_file" 2>/dev/null | cut -f1 || echo "unknown")
        
        lock_diagnostics="permissions=$lock_permissions,owner=$lock_owner,size=$lock_size"
    fi
    
    # Combine with any provided lock details
    if [[ -n "$lock_details" ]]; then
        lock_diagnostics="${lock_diagnostics:+$lock_diagnostics,}$lock_details"
    fi
    
    log_error_with_context \
        "$error_message" \
        1 \
        "locking" \
        "$lock_operation" \
        "lock_file=$lock_file,$lock_diagnostics"
}

# Log performance warnings for slow operations
log_performance_warning() {
    local operation="$1"
    local duration="$2"
    local threshold="${3:-5.0}"
    local context="${4:-}"
    
    # Check if duration exceeds threshold
    local exceeds_threshold=false
    if command -v bc >/dev/null 2>&1; then
        exceeds_threshold=$(echo "$duration > $threshold" | bc -l 2>/dev/null || echo 0)
    else
        # Simple integer comparison fallback
        if [[ ${duration%.*} -gt ${threshold%.*} ]]; then
            exceeds_threshold=1
        fi
    fi
    
    if [[ "$exceeds_threshold" == "1" ]]; then
        local warning_message="Slow operation detected: $operation took ${duration}s (threshold: ${threshold}s)"
        
        log_warn "$warning_message"
        log_error_with_context \
            "$warning_message" \
            0 \
            "performance" \
            "$operation" \
            "duration=${duration}s,threshold=${threshold}s,$context"
    fi
}

# Generate system diagnostic report for troubleshooting
generate_system_diagnostics() {
    local report_file="${1:-/tmp/system_diagnostics_$(date +%s).log}"
    
    {
        echo "=== SYSTEM DIAGNOSTICS REPORT ==="
        echo "Generated: $(date -Iseconds)"
        echo "Hostname: $(hostname 2>/dev/null || echo 'unknown')"
        echo "User: $(whoami 2>/dev/null || echo "$USER")"
        echo "PID: $$"
        echo "Working Directory: $PWD"
        echo ""
        
        echo "=== SYSTEM INFORMATION ==="
        echo "OS Type: $OSTYPE"
        echo "Uname: $(uname -a 2>/dev/null || echo 'N/A')"
        
        if [[ "$OSTYPE" == "linux-gnu"* ]]; then
            echo "Memory: $(free -h 2>/dev/null || echo 'N/A')"
            echo "Disk Space: $(df -h . 2>/dev/null || echo 'N/A')"
        elif [[ "$OSTYPE" == "darwin"* ]]; then
            echo "Memory: $(vm_stat 2>/dev/null | head -10 || echo 'N/A')"
            echo "Disk Space: $(df -h . 2>/dev/null || echo 'N/A')"
        fi
        
        echo "Load Average: $(uptime 2>/dev/null || echo 'N/A')"
        echo "Process Count: $(ps aux 2>/dev/null | wc -l || echo 'N/A')"
        echo ""
        
        echo "=== PROJECT INFORMATION ==="
        echo "Project Root: ${PROJECT_ROOT:-unknown}"
        echo "Task Queue Dir: ${TASK_QUEUE_DIR:-unknown}"
        echo "Script Directory: ${SCRIPT_DIR:-unknown}"
        echo ""
        
        if [[ -n "${PROJECT_ROOT:-}" ]] && [[ -d "$PROJECT_ROOT" ]]; then
            echo "Project Directory Contents:"
            find "$PROJECT_ROOT" -maxdepth 1 -ls 2>/dev/null | head -20 || echo 'N/A'
            echo ""
            
            if [[ -n "${TASK_QUEUE_DIR:-}" ]] && [[ -d "$PROJECT_ROOT/$TASK_QUEUE_DIR" ]]; then
                echo "Queue Directory Contents:"
                ls -la "$PROJECT_ROOT/$TASK_QUEUE_DIR" 2>/dev/null || echo 'N/A'
                echo ""
                
                echo "Active Locks:"
                find "$PROJECT_ROOT/$TASK_QUEUE_DIR" -name "*.lock*" -o -name ".*.lock*" 2>/dev/null | head -10 || echo 'N/A'
                echo ""
            fi
        fi
        
        echo "=== ENVIRONMENT VARIABLES ==="
        env | grep -E "(LOG_|TASK_|QUEUE_|CLI_|DEBUG)" | sort || echo 'N/A'
        echo ""
        
        echo "=== RECENT LOG ENTRIES ==="
        if [[ -f "${LOG_FILE:-}" ]]; then
            tail -20 "$LOG_FILE" 2>/dev/null || echo 'Log file not accessible'
        else
            echo "No log file available: ${LOG_FILE:-unset}"
        fi
        
        echo ""
        echo "=== END DIAGNOSTICS ==="
    } > "$report_file"
    
    echo "$report_file"
}

# Log system diagnostic summary
log_system_status() {
    local component="${1:-system}"
    
    local load_avg="N/A"
    local memory_info="N/A"
    local disk_space="N/A"
    
    # Gather lightweight system info
    if uptime >/dev/null 2>&1; then
        load_avg=$(uptime | awk -F'load average:' '{print $2}' | awk -F',' '{print $1}' | tr -d ' ')
    fi
    
    if [[ "$OSTYPE" == "linux-gnu"* ]] && command -v free >/dev/null; then
        memory_info=$(free | awk 'NR==2{printf "%.1f%%", $3*100/$2}')
    elif [[ "$OSTYPE" == "darwin"* ]] && command -v vm_stat >/dev/null; then
        # Simplified memory calculation for macOS
        memory_info=$(vm_stat | grep "Pages active" | awk '{print $3}' | tr -d '.' || echo "N/A")
    fi
    
    if command -v df >/dev/null; then
        disk_space=$(df -h . 2>/dev/null | awk 'NR==2{print $5}' || echo "N/A")
    fi
    
    log_debug "System status [$component]: load=$load_avg, memory=$memory_info, disk=$disk_space"
}

# Enhanced error recovery logging
log_recovery_attempt() {
    local component="$1"
    local issue="$2"
    local recovery_action="$3"
    local success="${4:-false}"
    
    local status_icon="❌"
    local log_level="warn"
    
    if [[ "$success" == "true" ]]; then
        status_icon="✅"
        log_level="info"
    fi
    
    local message="$status_icon Recovery attempt [$component]: $issue -> $recovery_action"
    
    case "$log_level" in
        "info") log_info "$message" ;;
        "warn") log_warn "$message" ;;
        "error") log_error "$message" ;;
    esac
    
    # Also log with structured context for analysis
    log_error_with_context \
        "Recovery attempt: $recovery_action" \
        $([[ "$success" == "true" ]] && echo 0 || echo 1) \
        "$component" \
        "recovery" \
        "issue=$issue,success=$success"
}

# Batch log multiple related errors
log_error_batch() {
    local batch_name="$1"
    shift
    local errors=("$@")
    
    log_error "Error batch: $batch_name (${#errors[@]} errors)"
    
    local i=1
    for error in "${errors[@]}"; do
        log_error "  $i. $error"
        ((i++))
    done
    
    # Create summary for structured logging
    local error_summary=$(IFS='; '; echo "${errors[*]}")
    log_error_with_context \
        "Batch errors encountered" \
        1 \
        "batch" \
        "$batch_name" \
        "count=${#errors[@]},summary=$error_summary"
}

# ===============================================================================
# MAIN ENTRY POINT (für Testing)
# ===============================================================================

# Nur ausführen wenn Skript direkt aufgerufen wird
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
    # Test-Modus
    init_logging
    
    log_debug "This is a debug message"
    log_info "This is an info message"
    log_warn "This is a warning message"
    log_error "This is an error message"
    
    show_logging_config
fi