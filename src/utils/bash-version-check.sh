#!/bin/bash
# Bash version check utility for Claude Auto-Resume
# This function ensures bash 4.0+ compatibility across all scripts

# Function to check bash version compatibility
check_bash_version() {
    local required_major=4
    local current_major=${BASH_VERSINFO[0]:-0}
    local script_name="${1:-this script}"
    
    if [[ $current_major -lt $required_major ]]; then
        echo "[ERROR] Incompatible bash version detected!" >&2
        echo "        Current version: bash $BASH_VERSION" >&2
        echo "        Required: bash $required_major.0 or higher" >&2
        echo "" >&2
        echo "This project uses advanced bash features (associative arrays, advanced regex)" >&2
        echo "that require bash 4.0 or higher." >&2
        echo "" >&2
        
        # Platform-specific upgrade instructions
        case "$OSTYPE" in
            darwin*)
                echo "On macOS, upgrade bash using Homebrew:" >&2
                echo "  1. Install Homebrew: https://brew.sh" >&2
                echo "  2. Install modern bash: brew install bash" >&2
                echo "  3. Add to your PATH: echo '/opt/homebrew/bin/bash' | sudo tee -a /etc/shells" >&2
                echo "  4. Change shell: chsh -s /opt/homebrew/bin/bash" >&2
                echo "  5. Restart your terminal and run: bash --version" >&2
                ;;
            linux*)
                echo "On Linux, bash 4.0+ should be available via your package manager:" >&2
                echo "  Ubuntu/Debian: sudo apt update && sudo apt install bash" >&2
                echo "  CentOS/RHEL: sudo yum update bash" >&2
                echo "  Fedora: sudo dnf update bash" >&2
                ;;
            *)
                echo "Please upgrade to bash 4.0 or higher for your platform." >&2
                ;;
        esac
        
        echo "" >&2
        echo "After upgrading, verify with: bash --version" >&2
        echo "" >&2
        return 1
    fi
    
    return 0
}

# If script is executed directly (not sourced), run the check
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    check_bash_version "bash-version-check.sh"
fi