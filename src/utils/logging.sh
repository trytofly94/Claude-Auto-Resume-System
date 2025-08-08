#!/bin/bash

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
        "DEBUG") echo $LOG_LEVEL_DEBUG ;;
        "INFO")  echo $LOG_LEVEL_INFO ;;
        "WARN")  echo $LOG_LEVEL_WARN ;;
        "ERROR") echo $LOG_LEVEL_ERROR ;;
        *) echo $LOG_LEVEL_INFO ;;
    esac
}

# Prüft ob ein Log-Level ausgegeben werden soll
should_log() {
    local level="$1"
    local current_level_num
    local target_level_num
    
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
    local number="${size%[KMG]*}"
    local unit="${size#"$number"}"
    
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
    local i
    
    # Rotiere bestehende Archive
    for ((i = MAX_LOG_ARCHIVES - 1; i >= 1; i--)); do
        local old_file="${base_name}.${i}.${extension}"
        local new_file="${base_name}.$((i + 1)).${extension}"
        
        [[ -f "$old_file" ]] && mv "$old_file" "$new_file"
    done
    
    # Rotiere aktuelle Log-Datei
    mv "$LOG_FILE" "${base_name}.1.${extension}"
    
    # Entferne alte Archive
    local oldest_archive=$((MAX_LOG_ARCHIVES + 1))
    local oldest_file="${base_name}.${oldest_archive}.${extension}"
    [[ -f "$oldest_file" ]] && rm -f "$oldest_file"
}

# Generiert Timestamp für Log-Einträge
get_timestamp() {
    date +"$LOG_TIMESTAMP_FORMAT"
}

# Extrahiert aufrufende Funktion und Zeile
get_caller_info() {
    local frame="${1:-2}"
    local caller_info
    
    if caller_info=$(caller $frame 2>/dev/null); then
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
{"timestamp":"$(json_escape "$timestamp)","level":"$(json_escape "$level")","message":"$(json_escape "$message")","caller":"$(json_escape "$caller")","script":"$(json_escape "$SCRIPT_NAME")","pid":$LOG_PID}
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
    
    # Schreibe in Log-Datei und optional zu stderr
    {
        echo "$log_entry" >> "$LOG_FILE"
        
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
    
    find "$log_dir" -name "*.log*" -type f -mtime +$days -delete 2>/dev/null || {
        log_warn "Failed to cleanup some log files"
    }
}

# ===============================================================================
# MAIN ENTRY POINT (für Testing)
# ===============================================================================

# Nur ausführen wenn Skript direkt aufgerufen wird
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Test-Modus
    init_logging
    
    log_debug "This is a debug message"
    log_info "This is an info message"
    log_warn "This is a warning message"
    log_error "This is an error message"
    
    show_logging_config
fi