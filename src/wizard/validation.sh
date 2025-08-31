#!/usr/bin/env bash

# Claude Auto-Resume - Setup Wizard Validation Module
# Input validation functions for the setup wizard
# Version: 1.0.0-alpha

set -euo pipefail

# ===============================================================================
# INPUT VALIDATION FUNKTIONEN
# ===============================================================================

# Validiert tmux session names gegen tmux naming rules
validate_tmux_session_name() {
    local session_name="$1"
    
    # Prüfe auf leeren Input
    if [[ -z "$session_name" ]]; then
        return 1
    fi
    
    # tmux session names dürfen nicht enthalten:
    # - Doppelpunkte (:) - werden für window/pane targeting verwendet
    # - Punkte (.) am Anfang - hidden sessions
    # - Whitespace am Anfang/Ende
    # - Sonderzeichen die Shell-Probleme verursachen können
    if [[ "$session_name" =~ ^[[:space:]]*$ ]]; then
        echo "Session name cannot be empty or only whitespace"
        return 1
    fi
    
    if [[ "$session_name" =~ : ]]; then
        echo "Session name cannot contain colons (:)"
        return 1
    fi
    
    if [[ "$session_name" =~ ^[.] ]]; then
        echo "Session name cannot start with a dot (.)"
        return 1
    fi
    
    if [[ "$session_name" =~ [[:space:]] ]]; then
        echo "Session name cannot contain spaces"
        return 1
    fi
    
    # Prüfe auf gefährliche Zeichen für Shell-Injection
    if [[ "$session_name" =~ [\$\`\;\|\&\>\<] ]]; then
        echo "Session name contains invalid characters (\$\`\;\|\&\>\<)"
        return 1
    fi
    
    # Längen-Validierung (tmux limit ist typischerweise ~200 chars)
    if [[ ${#session_name} -gt 100 ]]; then
        echo "Session name too long (max 100 characters)"
        return 1
    fi
    
    return 0
}

# Validiert Claude session ID format
validate_claude_session_id() {
    local session_id="$1"
    
    # Prüfe auf leeren Input
    if [[ -z "$session_id" ]]; then
        echo "Session ID cannot be empty"
        return 1
    fi
    
    # Entferne Whitespace
    session_id=$(echo "$session_id" | tr -d '[:space:]')
    
    # Auto-add sess- prefix falls nicht vorhanden (aber validiere das Format)
    if [[ ! "$session_id" =~ ^sess- ]]; then
        session_id="sess-$session_id"
    fi
    
    # Claude session IDs sollten dem Format sess-XXXX entsprechen
    # Typische Länge: sess- (5) + mindestens 8 Zeichen = mindestens 13 total
    if [[ ${#session_id} -lt 13 ]]; then
        echo "Session ID too short (minimum format: sess-XXXXXXXX)"
        return 1
    fi
    
    # Prüfe auf gültiges Format: sess- gefolgt von alphanumerischen Zeichen/Bindestriche
    if [[ ! "$session_id" =~ ^sess-[a-zA-Z0-9_-]+$ ]]; then
        echo "Invalid session ID format (must be sess-XXXX with alphanumeric characters)"
        return 1
    fi
    
    # Setze validierte Session ID zurück
    echo "$session_id"
    return 0
}

# Validiert Benutzer-Auswahlen für Multiple-Choice-Prompts
validate_choice() {
    local input="$1"
    local min_choice="$2"
    local max_choice="$3"
    
    # Prüfe auf leeren Input
    if [[ -z "$input" ]]; then
        echo "Please make a selection"
        return 1
    fi
    
    # Prüfe auf numerischen Input
    if [[ ! "$input" =~ ^[0-9]+$ ]]; then
        echo "Please enter a number"
        return 1
    fi
    
    # Prüfe Range
    if [[ $input -lt $min_choice ]] || [[ $input -gt $max_choice ]]; then
        echo "Please choose between $min_choice and $max_choice"
        return 1
    fi
    
    return 0
}