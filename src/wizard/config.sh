#!/usr/bin/env bash

# Claude Auto-Resume - Setup Wizard Configuration Module
# Configuration constants and variables for the setup wizard
# Version: 1.0.0-alpha

set -euo pipefail

# ===============================================================================
# GLOBALE VARIABLEN UND KONSTANTEN
# ===============================================================================

# Wizard-spezifische Konfiguration
WIZARD_VERSION="1.0.0"
TMUX_SESSION_PREFIX="${TMUX_SESSION_PREFIX:-claude-auto-resume}"

# Session-Tracking-Variablen (werden während des Setups gesetzt)
TMUX_SESSION_NAME=""
SESSION_ID=""
DETECTED_SESSION_NAME=""
DETECTED_SESSION_ID=""

# Timeout-Konfiguration für bessere Zuverlässigkeit
SETUP_SESSION_INIT_WAIT=5       # Warten nach Session-Erstellung
SETUP_CLAUDE_STARTUP_WAIT=45    # Warten auf Claude-Initialisierung  
SETUP_VALIDATION_WAIT=3         # Warten zwischen Validierungsschritten
SETUP_CHECK_INTERVAL=3          # Intervall für Status-Checks

# Export wichtige Variablen für andere Module
export WIZARD_VERSION
export TMUX_SESSION_PREFIX
export SETUP_SESSION_INIT_WAIT
export SETUP_CLAUDE_STARTUP_WAIT
export SETUP_VALIDATION_WAIT
export SETUP_CHECK_INTERVAL