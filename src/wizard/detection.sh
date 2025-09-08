#!/usr/bin/env bash

# Claude Auto-Resume - Setup Wizard Detection Module
# Session detection functions for the setup wizard
# Version: 1.0.0-alpha

set -euo pipefail

# ===============================================================================
# SESSION DETECTION FUNKTIONEN
# ===============================================================================

# Übergreifende Session-Detection
detect_existing_session() {
    log_debug "Comprehensive session detection starting"
    
    local detection_methods=(
        "check_tmux_sessions"
        "check_session_files"
        "check_process_tree"
    )
    
    for method in "${detection_methods[@]}"; do
        log_debug "Trying detection method: $method"
        
        if "$method"; then
            log_info "Session detected via $method"
            return 0
        fi
    done
    
    log_info "No existing Claude session detected"
    return 1
}

# Prüfe tmux-Sessions auf Claude-Sessions
check_tmux_sessions() {
    local project_name
    project_name=$(basename "$(pwd)")
    local session_pattern="${TMUX_SESSION_PREFIX}-${project_name}"
    
    # Prüfe exakte Übereinstimmung
    if tmux has-session -t "$session_pattern" 2>/dev/null; then
        DETECTED_SESSION_NAME="$session_pattern"
        log_info "Found exact session match: $session_pattern"
        return 0
    fi
    
    # Prüfe auf Pattern-Matches
    local matching_sessions
    matching_sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -E "claude|auto-resume" || true)
    
    if [[ -n "$matching_sessions" ]]; then
        log_info "Found potential Claude sessions: $matching_sessions"
        DETECTED_SESSION_NAME=$(echo "$matching_sessions" | head -1)
        return 0
    fi
    
    return 1
}

# Prüfe Session-Dateien
check_session_files() {
    local project_name
    project_name=$(basename "$(pwd)")
    local session_files=(
        "$HOME/.claude_session_${project_name}"
        "$HOME/.claude_auto_resume_${project_name}"
        "$(pwd)/.claude_session"
    )
    
    for file in "${session_files[@]}"; do
        if [[ -f "$file" && -s "$file" ]]; then
            local session_id
            session_id=$(cat "$file" 2>/dev/null || echo "")
            if [[ -n "$session_id" ]]; then
                log_info "Found session file: $file with ID: $session_id"
                DETECTED_SESSION_ID="$session_id"
                return 0
            fi
        fi
    done
    
    return 1
}

# Prüfe Prozess-Baum auf Claude-Instanzen
check_process_tree() {
    local claude_processes
    claude_processes=$(pgrep -f "claude" 2>/dev/null || true)
    
    if [[ -n "$claude_processes" ]]; then
        log_info "Found running Claude processes: $claude_processes"
        
        # Prüfe ob in tmux läuft
        for pid in $claude_processes; do
            if tmux list-panes -F '#{pane_pid}' 2>/dev/null | grep -q "$pid"; then
                log_info "Found Claude process $pid running in tmux"
                return 0
            fi
        done
    fi
    
    return 1
}