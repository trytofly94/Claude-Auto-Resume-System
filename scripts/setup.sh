#!/usr/bin/env bash

# Claude Auto-Resume - Main Setup Script
# Vollständiges Setup für das claunch-basierte Claude Auto-Resume System
# Version: 1.0.0-alpha
# Letzte Aktualisierung: 2025-08-05

set -euo pipefail

# ===============================================================================
# SCRIPT SETUP AND BASH VERSION VALIDATION (ADDRESSES GITHUB ISSUE #6)
# ===============================================================================

readonly SCRIPT_NAME="setup"
readonly VERSION="1.0.0-alpha"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source bash version check utility - use absolute path resolution
BASH_VERSION_CHECK_SCRIPT="$SCRIPT_DIR/../src/utils/bash-version-check.sh"
if [[ -f "$BASH_VERSION_CHECK_SCRIPT" && -r "$BASH_VERSION_CHECK_SCRIPT" ]]; then
    # shellcheck disable=SC1090
    source "$BASH_VERSION_CHECK_SCRIPT"
else
    echo "[ERROR] Cannot find bash version check utility at: $BASH_VERSION_CHECK_SCRIPT" >&2
    echo "        Please run this script from the project root directory" >&2
    exit 1
fi

# Validate bash version before proceeding with setup
if ! check_bash_version "setup.sh"; then
    exit 1
fi

# ===============================================================================  
# PERMISSION FIXING FUNCTIONALITY (ADDRESSES GITHUB ISSUE #5)
# ===============================================================================

# Function to fix script permissions for all project scripts
fix_script_permissions() {
    log_info "Checking and fixing script permissions..."
    
    local scripts_fixed=0
    local total_scripts=0
    
    # List of all executable scripts in the project
    local script_files=(
        "scripts/setup.sh"
        "scripts/run-tests.sh"
        "scripts/install-claunch.sh" 
        "scripts/dev-setup.sh"
        "src/hybrid-monitor.sh"
        "src/claunch-integration.sh"
        "src/session-manager.sh"
        "src/utils/bash-version-check.sh"
        "src/utils/logging.sh"
        "src/utils/network.sh"
        "src/utils/terminal.sh"
        "claude-auto-resume-continuous-v4"
    )
    
    for script_path in "${script_files[@]}"; do
        local full_path="$PROJECT_ROOT/$script_path"
        if [[ -f "$full_path" ]]; then
            total_scripts=$((total_scripts + 1))
            
            # Check if file is executable
            if [[ ! -x "$full_path" ]]; then
                log_info "  Fixing permissions for: $script_path"
                chmod +x "$full_path"
                scripts_fixed=$((scripts_fixed + 1))
            fi
        else
            log_debug "  Script not found (will be created later): $script_path"
        fi
    done
    
    if [[ $scripts_fixed -gt 0 ]]; then
        log_success "Fixed execute permissions for $scripts_fixed out of $total_scripts scripts"
    else
        log_success "All $total_scripts scripts already have correct permissions"
    fi
}

# ===============================================================================
# GLOBALE VARIABLEN UND KONSTANTEN
# ===============================================================================
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Setup-Optionen
SKIP_DEPENDENCIES=false
SKIP_CLAUNCH=false
SKIP_TESTS=false
INSTALL_DEV_TOOLS=false
FORCE_REINSTALL=false
DRY_RUN=false
INTERACTIVE_MODE=true
CLAUNCH_METHOD="official"  # Use official installer by default (GitHub issue #38)

# System-Information
OS=""
PACKAGE_MANAGER=""
SHELL_TYPE=""

# ===============================================================================
# HILFSFUNKTIONEN
# ===============================================================================

# Logging-Funktionen
log_info() { echo -e "\e[32m[INFO]\e[0m $*"; }
log_warn() { echo -e "\e[33m[WARN]\e[0m $*" >&2; }
log_error() { echo -e "\e[31m[ERROR]\e[0m $*" >&2; }
log_debug() { [[ "${DEBUG:-false}" == "true" ]] && echo -e "\e[36m[DEBUG]\e[0m $*" >&2; }
log_success() { echo -e "\e[32m[SUCCESS]\e[0m $*"; }
log_step() { echo -e "\e[34m[STEP]\e[0m $*"; }

# Prüfe ob Kommando verfügbar ist
has_command() {
    command -v "$1" >/dev/null 2>&1
}

# Benutzer-Input mit Default-Wert
ask_user() {
    local question="$1"
    local default="${2:-}"
    local response
    
    if [[ "$INTERACTIVE_MODE" != "true" ]]; then
        echo "$default"
        return
    fi
    
    if [[ -n "$default" ]]; then
        read -r -p "$question [$default]: " response
        echo "${response:-$default}"
    else
        read -r -p "$question: " response
        echo "$response"
    fi
}

# Ja/Nein-Frage
ask_yes_no() {
    local question="$1"
    local default="${2:-n}"
    
    if [[ "$INTERACTIVE_MODE" != "true" ]]; then
        [[ "$default" =~ ^[Yy] ]] && return 0 || return 1
    fi
    
    local response
    response=$(ask_user "$question (y/n)" "$default")
    
    [[ "$response" =~ ^[Yy] ]]
}

# ===============================================================================
# SYSTEM-ERKENNUNG
# ===============================================================================

# Erkenne Betriebssystem
detect_os() {
    case "$(uname -s)" in
        Darwin) OS="macos" ;;
        Linux) OS="linux" ;;
        CYGWIN*|MINGW*|MSYS*) OS="windows" ;;
        *) OS="unknown" ;;
    esac
    
    log_debug "Detected OS: $OS"
}

# Erkenne Package-Manager
detect_package_manager() {
    if has_command brew; then
        PACKAGE_MANAGER="brew"
    elif has_command apt-get; then
        PACKAGE_MANAGER="apt"
    elif has_command yum; then
        PACKAGE_MANAGER="yum"
    elif has_command dnf; then
        PACKAGE_MANAGER="dnf"
    elif has_command pacman; then
        PACKAGE_MANAGER="pacman"
    else
        PACKAGE_MANAGER="none"
    fi
    
    log_debug "Detected package manager: $PACKAGE_MANAGER"
}

# Erkenne Shell
detect_shell() {
    SHELL_TYPE=$(basename "$SHELL")
    log_debug "Detected shell: $SHELL_TYPE"
}

# Sammle System-Informationen
gather_system_info() {
    log_step "Gathering system information"
    
    detect_os
    detect_package_manager
    detect_shell
    
    log_info "System Information:"
    log_info "  Operating System: $OS"
    log_info "  Package Manager: $PACKAGE_MANAGER"
    log_info "  Shell: $SHELL_TYPE"
    log_info "  Project Root: $PROJECT_ROOT"
    echo
}

# ===============================================================================
# DEPENDENCY-INSTALLATION
# ===============================================================================

# Installiere System-Dependencies
install_system_dependencies() {
    log_step "Installing system dependencies"
    
    local dependencies=()
    
    # Basis-Tools
    case "$OS" in
        "macos")
            dependencies+=("git" "curl" "jq")
            if [[ "$PACKAGE_MANAGER" == "brew" ]]; then
                dependencies+=("tmux" "node")
            fi
            ;;
        "linux")
            dependencies+=("git" "curl" "jq" "tmux")
            case "$PACKAGE_MANAGER" in
                "apt")
                    dependencies+=("nodejs" "npm")
                    ;;
                "yum"|"dnf")
                    dependencies+=("nodejs" "npm")
                    ;;
                "pacman")
                    dependencies+=("nodejs" "npm")
                    ;;
            esac
            ;;
    esac
    
    if [[ ${#dependencies[@]} -eq 0 ]]; then
        log_warn "No automatic dependency installation available for this system"
        return 0
    fi
    
    log_info "Installing dependencies: ${dependencies[*]}"
    
    case "$PACKAGE_MANAGER" in
        "brew")
            for dep in "${dependencies[@]}"; do
                if ! has_command "$dep"; then
                    log_info "Installing $dep via brew"
                    if [[ "$DRY_RUN" == "true" ]]; then
                        log_info "[DRY RUN] Would run: brew install $dep"
                    else
                        brew install "$dep" || log_warn "Failed to install $dep"
                    fi
                fi
            done
            ;;
        "apt")
            if [[ "$DRY_RUN" == "true" ]]; then
                log_info "[DRY RUN] Would run: sudo apt-get update && sudo apt-get install -y ${dependencies[*]}"
            else
                sudo apt-get update
                sudo apt-get install -y "${dependencies[@]}" || log_warn "Some dependencies may have failed to install"
            fi
            ;;
        "yum"|"dnf")
            if [[ "$DRY_RUN" == "true" ]]; then
                log_info "[DRY RUN] Would run: sudo $PACKAGE_MANAGER install -y ${dependencies[*]}"
            else
                sudo "$PACKAGE_MANAGER" install -y "${dependencies[@]}" || log_warn "Some dependencies may have failed to install"
            fi
            ;;
        "pacman")
            if [[ "$DRY_RUN" == "true" ]]; then
                log_info "[DRY RUN] Would run: sudo pacman -S ${dependencies[*]}"
            else
                sudo pacman -S "${dependencies[@]}" || log_warn "Some dependencies may have failed to install"
            fi
            ;;
        *)
            log_warn "Unknown package manager - please install dependencies manually:"
            for dep in "${dependencies[@]}"; do
                log_warn "  - $dep"
            done
            ;;
    esac
    
    log_success "System dependencies installation completed"
}

# Installiere Claude CLI
install_claude_cli() {
    log_step "Checking Claude CLI installation"
    
    if has_command claude; then
        local claude_version
        claude_version=$(claude --version 2>/dev/null | head -1 || echo "unknown")
        log_info "Claude CLI already installed: $claude_version"
        
        if ! ask_yes_no "Update Claude CLI?" "n"; then
            return 0
        fi
    fi
    
    log_info "Installing/Updating Claude CLI"
    log_info "Please visit https://claude.ai/code for installation instructions"
    
    if ask_yes_no "Have you installed Claude CLI and want to continue?" "y"; then
        if has_command claude; then
            log_success "Claude CLI is now available"
        else
            log_error "Claude CLI still not found - please install it manually"
            return 1
        fi
    else
        log_error "Claude CLI is required for the system to work"
        return 1
    fi
}

# Installiere claunch
install_claunch() {
    if [[ "$SKIP_CLAUNCH" == "true" ]]; then
        log_info "Skipping claunch installation (--skip-claunch)"
        return 0
    fi
    
    log_step "Installing claunch"
    
    local install_script="$SCRIPT_DIR/install-claunch.sh"
    
    if [[ ! -f "$install_script" ]]; then
        log_error "claunch installation script not found: $install_script"
        return 1
    fi
    
    # Baue Argumente für claunch-Installer
    local claunch_args=()
    
    # Use specified claunch installation method
    claunch_args+=("--method" "$CLAUNCH_METHOD")
    
    if [[ "$FORCE_REINSTALL" == "true" ]]; then
        claunch_args+=("--force")
    fi
    
    if [[ "$DEBUG" == "true" ]]; then
        claunch_args+=("--debug")
    fi
    
    # Führe claunch-Installation aus
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would run: $install_script ${claunch_args[*]}"
    else
        if bash "$install_script" "${claunch_args[@]}"; then
            log_success "claunch installation completed"
        else
            log_error "claunch installation failed"
            return 1
        fi
    fi
}

# ===============================================================================
# PROJEKT-SETUP
# ===============================================================================

# Erstelle fehlende Verzeichnisse
create_directories() {
    log_step "Creating project directories"
    
    local directories=(
        "logs"
        "config/templates"
    )
    
    for dir in "${directories[@]}"; do
        local full_path="$PROJECT_ROOT/$dir"
        if [[ ! -d "$full_path" ]]; then
            if [[ "$DRY_RUN" == "true" ]]; then
                log_info "[DRY RUN] Would create directory: $full_path"
            else
                mkdir -p "$full_path"
                log_info "Created directory: $dir"
            fi
        else
            log_debug "Directory already exists: $dir"
        fi
    done
    
    log_success "Directory creation completed"
}

# Setze Dateiberechtigungen
set_file_permissions() {
    log_step "Setting file permissions"
    
    local executable_files=(
        "src/hybrid-monitor.sh"
        "src/claunch-integration.sh" 
        "src/session-manager.sh"
        "src/utils/logging.sh"
        "src/utils/network.sh"
        "src/utils/terminal.sh"
        "scripts/setup.sh"
        "scripts/install-claunch.sh"
    )
    
    for file in "${executable_files[@]}"; do
        local full_path="$PROJECT_ROOT/$file"
        if [[ -f "$full_path" ]]; then
            if [[ "$DRY_RUN" == "true" ]]; then
                log_info "[DRY RUN] Would make executable: $file"
            else
                chmod +x "$full_path"
                log_debug "Made executable: $file"
            fi
        else
            log_warn "File not found: $file"
        fi
    done
    
    log_success "File permissions set"
}

# Erstelle Symlinks oder Aliases
create_shortcuts() {
    log_step "Creating shortcuts and aliases"
    
    local bin_dir="$HOME/bin"
    local main_script="$PROJECT_ROOT/src/hybrid-monitor.sh"
    local alias_name="claude-auto-resume"
    
    # Erstelle ~/bin falls nicht vorhanden
    if [[ ! -d "$bin_dir" ]]; then
        if ask_yes_no "Create $bin_dir directory for shortcuts?" "y"; then
            if [[ "$DRY_RUN" == "true" ]]; then
                log_info "[DRY RUN] Would create directory: $bin_dir"
            else
                mkdir -p "$bin_dir"
                log_info "Created directory: $bin_dir"
            fi
        else
            log_info "Skipping shortcut creation"
            return 0
        fi
    fi
    
    # Erstelle Symlink
    local symlink_path="$bin_dir/$alias_name"
    
    if [[ -L "$symlink_path" || -f "$symlink_path" ]]; then
        if ask_yes_no "Shortcut already exists. Replace it?" "y"; then
            if [[ "$DRY_RUN" == "true" ]]; then
                log_info "[DRY RUN] Would remove and recreate: $symlink_path"
            else
                rm -f "$symlink_path"
            fi
        else
            log_info "Keeping existing shortcut"
            return 0
        fi
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create symlink: $symlink_path -> $main_script"
    else
        ln -s "$main_script" "$symlink_path"
        log_info "Created shortcut: $alias_name"
    fi
    
    # Prüfe PATH
    if [[ ":$PATH:" != *":$bin_dir:"* ]]; then
        log_info "Add $bin_dir to your PATH by adding this to your shell profile:"
        log_info "  echo 'export PATH=\"$bin_dir:\$PATH\"' >> ~/.${SHELL_TYPE}rc"
        
        if ask_yes_no "Add to PATH automatically?" "y"; then
            local shell_rc="$HOME/.${SHELL_TYPE}rc"
            local path_line="export PATH=\"$bin_dir:\$PATH\""
            
            if [[ "$DRY_RUN" == "true" ]]; then
                log_info "[DRY RUN] Would add to $shell_rc: $path_line"
            else
                echo "" >> "$shell_rc"
                echo "# Added by Claude Auto-Resume setup" >> "$shell_rc"
                echo "$path_line" >> "$shell_rc"
                log_success "Added $bin_dir to PATH in $shell_rc"
                log_info "Please restart your shell or run: source $shell_rc"
            fi
        fi
    fi
    
    log_success "Shortcuts created"
}

# ===============================================================================
# KONFIGURATION
# ===============================================================================

# Erstelle Benutzer-Konfiguration
create_user_config() {
    log_step "Setting up configuration"
    
    local user_config="$PROJECT_ROOT/config/user.conf"
    local default_config="$PROJECT_ROOT/config/default.conf"
    
    if [[ ! -f "$default_config" ]]; then
        log_error "Default configuration not found: $default_config"
        return 1
    fi
    
    if [[ -f "$user_config" ]]; then
        if ! ask_yes_no "User configuration already exists. Overwrite?" "n"; then
            log_info "Keeping existing user configuration"
            return 0
        fi
    fi
    
    if ask_yes_no "Customize configuration settings?" "y"; then
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would create customized user configuration"
            return 0
        fi
        
        log_info "Creating customized configuration"
        
        # Kopiere Standard-Konfiguration
        cp "$default_config" "$user_config"
        
        # Interaktive Konfiguration
        local check_interval
        check_interval=$(ask_user "Check interval in minutes" "5")
        sed -i.bak "s/CHECK_INTERVAL_MINUTES=.*/CHECK_INTERVAL_MINUTES=$check_interval/" "$user_config"
        
        local use_claunch
        if ask_yes_no "Use claunch for session management?" "y"; then
            use_claunch="true"
        else
            use_claunch="false"
        fi
        sed -i.bak "s/USE_CLAUNCH=.*/USE_CLAUNCH=$use_claunch/" "$user_config"
        
        local claunch_mode
        if [[ "$use_claunch" == "true" ]]; then
            if ask_yes_no "Use tmux mode for persistence?" "y"; then
                claunch_mode="tmux"
            else
                claunch_mode="direct"
            fi
            sed -i.bak "s/CLAUNCH_MODE=.*/CLAUNCH_MODE=\"$claunch_mode\"/" "$user_config"
        fi
        
        local new_terminal
        if ask_yes_no "Open Claude in new terminal windows by default?" "y"; then
            new_terminal="true"
        else
            new_terminal="false"
        fi
        sed -i.bak "s/NEW_TERMINAL_DEFAULT=.*/NEW_TERMINAL_DEFAULT=$new_terminal/" "$user_config"
        
        rm -f "$user_config.bak"
        
        log_success "User configuration created: config/user.conf"
    else
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would copy default configuration"
        else
            cp "$default_config" "$user_config"
            log_info "Copied default configuration to: config/user.conf"
        fi
    fi
}

# ===============================================================================
# CLAUNCH-VALIDIERUNG
# ===============================================================================

# Überprüfe claunch-Installation
verify_claunch_installation() {
    log_debug "Verifying claunch installation"
    
    # Prüfe ob claunch verfügbar ist
    if ! has_command claunch; then
        log_warn "claunch command not found in PATH"
        return 1
    fi
    
    # Teste claunch-Funktionalität
    if claunch --help >/dev/null 2>&1; then
        log_debug "claunch help command works"
        return 0
    else
        log_warn "claunch found but help command fails"
        return 1
    fi
}

# ===============================================================================
# TESTING UND VALIDIERUNG
# ===============================================================================

# Führe Setup-Tests durch
run_setup_tests() {
    if [[ "$SKIP_TESTS" == "true" ]]; then
        log_info "Skipping setup tests (--skip-tests)"
        return 0
    fi
    
    log_step "Running setup validation tests"
    
    # Test 1: Prüfe Dateien
    log_info "Test 1: Checking required files"
    local required_files=(
        "src/hybrid-monitor.sh"
        "config/default.conf"
        "config/user.conf"
    )
    
    local missing_files=0
    for file in "${required_files[@]}"; do
        if [[ ! -f "$PROJECT_ROOT/$file" ]]; then
            log_error "Required file missing: $file"
            ((missing_files++))
        fi
    done
    
    if [[ $missing_files -gt 0 ]]; then
        log_error "Test 1 failed: $missing_files files missing"
        return 1
    fi
    
    log_success "Test 1 passed: All required files present"
    
    # Test 2: Prüfe Ausführbarkeit
    log_info "Test 2: Checking executable permissions"
    if [[ -x "$PROJECT_ROOT/src/hybrid-monitor.sh" ]]; then
        log_success "Test 2 passed: Main script is executable"
    else
        log_error "Test 2 failed: Main script not executable"
        return 1
    fi
    
    # Test 3: Prüfe Dependencies
    log_info "Test 3: Checking dependencies"
    local missing_deps=0
    
    if ! has_command claude; then
        log_error "Claude CLI not found"
        ((missing_deps++))
    fi
    
    # Enhanced claunch verification (addresses GitHub issue #4)
    if [[ "$SKIP_CLAUNCH" != "true" ]]; then
        if has_command claunch; then
            # Test if claunch actually works
            if claunch --help >/dev/null 2>&1; then
                log_info "claunch is available and functional"
            else
                log_warn "claunch found but may not be functional"
            fi
        else
            # Check common installation paths before warning
            local claunch_found=false
            local common_paths=("$HOME/.local/bin/claunch" "$HOME/bin/claunch" "/usr/local/bin/claunch")
            
            for path in "${common_paths[@]}"; do
                if [[ -x "$path" ]] && "$path" --help >/dev/null 2>&1; then
                    log_info "claunch found at $path (may need PATH update)"
                    claunch_found=true
                    break
                fi
            done
            
            if [[ "$claunch_found" == "false" ]]; then
                log_warn "claunch not found - install with: ./scripts/install-claunch.sh"
            fi
        fi
    fi
    
    if [[ $missing_deps -gt 0 ]]; then
        log_error "Test 3 failed: $missing_deps dependencies missing"
        return 1
    fi
    
    log_success "Test 3 passed: Dependencies available"
    
    # Test 4: Syntax-Check
    log_info "Test 4: Checking script syntax"
    if bash -n "$PROJECT_ROOT/src/hybrid-monitor.sh"; then
        log_success "Test 4 passed: Script syntax is valid"
    else
        log_error "Test 4 failed: Script syntax error"
        return 1
    fi
    
    # Test 5: Help-Kommando
    log_info "Test 5: Testing help command"
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would test: $PROJECT_ROOT/src/hybrid-monitor.sh --help"
    else
        if "$PROJECT_ROOT/src/hybrid-monitor.sh" --help >/dev/null 2>&1; then
            log_success "Test 5 passed: Help command works"
        else
            log_error "Test 5 failed: Help command failed"
            return 1
        fi
    fi
    
    log_success "All setup tests passed!"
    return 0
}

# Führe Demo durch
run_demo() {
    log_step "Running system demo"
    
    if ! ask_yes_no "Run a quick demo of the system?" "y"; then
        return 0
    fi
    
    log_info "Starting demo..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would run demo commands"
        return 0
    fi
    
    # Demo 1: Version anzeigen
    log_info "Demo 1: Showing version information"
    "$PROJECT_ROOT/src/hybrid-monitor.sh" --version
    
    echo
    
    # Demo 2: Hilfe anzeigen
    log_info "Demo 2: Showing help (first few lines)"
    "$PROJECT_ROOT/src/hybrid-monitor.sh" --help | head -20
    
    echo
    
    # Demo 3: Konfiguration anzeigen
    log_info "Demo 3: Showing current configuration"
    if [[ -f "$PROJECT_ROOT/config/user.conf" ]]; then
        echo "User configuration (first 10 lines):"
        head -10 "$PROJECT_ROOT/config/user.conf"
    fi
    
    echo
    log_success "Demo completed!"
}

# ===============================================================================
# DEVELOPMENT-TOOLS
# ===============================================================================

# Manuelle BATS-Installation
install_bats_manually() {
    log_info "Attempting manual BATS installation"
    
    local bats_dir="/tmp/bats-core"
    local install_prefix="${HOME}/.local"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would install BATS manually to $install_prefix"
        return 0
    fi
    
    # Erstelle lokales bin-Verzeichnis
    mkdir -p "$install_prefix/bin"
    
    # Entferne eventuell vorhandene BATS-Installation
    rm -rf "$bats_dir"
    
    # Clone BATS repository
    if has_command git; then
        log_info "Cloning BATS repository"
        if git clone https://github.com/bats-core/bats-core.git "$bats_dir"; then
            cd "$bats_dir" || return 1
            
            # Installiere BATS
            log_info "Installing BATS to $install_prefix"
            if bash install.sh "$install_prefix"; then
                log_success "BATS installed manually to $install_prefix/bin"
                
                # Prüfe ob BATS in PATH ist
                if [[ ":$PATH:" != *":$install_prefix/bin:"* ]]; then
                    log_info "Add $install_prefix/bin to your PATH:"
                    log_info "  echo 'export PATH=\"$install_prefix/bin:\$PATH\"' >> ~/.${SHELL_TYPE}rc"
                    
                    if ask_yes_no "Add to PATH automatically?" "y"; then
                        local shell_rc="$HOME/.${SHELL_TYPE}rc"
                        echo "" >> "$shell_rc"
                        echo "# Added by Claude Auto-Resume setup for BATS" >> "$shell_rc"
                        echo "export PATH=\"$install_prefix/bin:\$PATH\"" >> "$shell_rc"
                        log_success "Added $install_prefix/bin to PATH in $shell_rc"
                        
                        # Aktualisiere PATH für aktuelle Session
                        export PATH="$install_prefix/bin:$PATH"
                    fi
                fi
                
                # Cleanup
                cd - >/dev/null || true
                rm -rf "$bats_dir"
                
                return 0
            else
                log_error "BATS manual installation failed"
                rm -rf "$bats_dir"
                return 1
            fi
        else
            log_error "Failed to clone BATS repository"
            return 1
        fi
    else
        log_error "Git not available for manual BATS installation"
        log_info "Please install BATS manually from: https://github.com/bats-core/bats-core"
        return 1
    fi
}

# Installiere Development-Tools
install_dev_tools() {
    if [[ "$INSTALL_DEV_TOOLS" != "true" ]]; then
        return 0
    fi
    
    log_step "Installing development tools"
    
    # ShellCheck für Bash-Linting
    if ! has_command shellcheck; then
        log_info "Installing ShellCheck"
        case "$PACKAGE_MANAGER" in
            "brew")
                if [[ "$DRY_RUN" == "true" ]]; then
                    log_info "[DRY RUN] Would run: brew install shellcheck"
                else
                    brew install shellcheck
                fi
                ;;
            "apt")
                if [[ "$DRY_RUN" == "true" ]]; then
                    log_info "[DRY RUN] Would run: sudo apt-get install shellcheck"
                else
                    sudo apt-get install -y shellcheck
                fi
                ;;
            *)
                log_warn "ShellCheck auto-install not available for $PACKAGE_MANAGER"
                log_info "Please install ShellCheck manually: https://github.com/koalaman/shellcheck"
                ;;
        esac
    fi
    
    # BATS für Bash-Testing
    if ! has_command bats; then
        log_info "Installing BATS (Bash Automated Testing System)"
        log_info "BATS is required for running the test suite"
        
        case "$PACKAGE_MANAGER" in
            "brew")
                if [[ "$DRY_RUN" == "true" ]]; then
                    log_info "[DRY RUN] Would run: brew install bats-core"
                else
                    if brew install bats-core; then
                        log_success "BATS installed successfully via brew"
                    else
                        log_warn "Failed to install BATS via brew, trying manual installation"
                        install_bats_manually
                    fi
                fi
                ;;
            "apt")
                if [[ "$DRY_RUN" == "true" ]]; then
                    log_info "[DRY RUN] Would run: sudo apt-get install bats"
                else
                    if sudo apt-get install -y bats; then
                        log_success "BATS installed successfully via apt"
                    else
                        log_warn "Failed to install BATS via apt, trying manual installation"
                        install_bats_manually
                    fi
                fi
                ;;
            "yum"|"dnf")
                if [[ "$DRY_RUN" == "true" ]]; then
                    log_info "[DRY RUN] Would run: sudo $PACKAGE_MANAGER install bats"
                else
                    if sudo "$PACKAGE_MANAGER" install -y bats; then
                        log_success "BATS installed successfully via $PACKAGE_MANAGER"
                    else
                        log_warn "Failed to install BATS via $PACKAGE_MANAGER, trying manual installation"
                        install_bats_manually
                    fi
                fi
                ;;
            *)
                log_warn "BATS auto-install not available for $PACKAGE_MANAGER - trying manual installation"
                install_bats_manually
                ;;
        esac
        
        # Verify installation after attempt
        if [[ "$DRY_RUN" != "true" ]]; then
            if has_command bats; then
                log_success "BATS installation verification successful"
                local bats_version
                bats_version=$(bats --version 2>/dev/null | head -1 || echo "unknown")
                log_info "BATS version: $bats_version"
            else
                log_error "BATS installation failed - tests will not work properly"
                log_error "You can install BATS manually using:"
                log_error "  macOS:     brew install bats-core"
                log_error "  Ubuntu:    sudo apt-get install bats"
                log_error "  Manual:    git clone https://github.com/bats-core/bats-core.git && ./bats-core/install.sh ~/.local"
            fi
        fi
    else
        local bats_version
        bats_version=$(bats --version 2>/dev/null | head -1 || echo 'version unknown')
        log_info "BATS already installed: $bats_version"
        
        # Verify BATS functionality
        if bats --help >/dev/null 2>&1; then
            log_success "BATS is functional and ready for testing"
        else
            log_warn "BATS found but may not be functioning properly"
        fi
    fi
    
    # Erstelle Dev-Scripts
    local dev_script="$PROJECT_ROOT/scripts/dev-setup.sh"
    if [[ ! -f "$dev_script" ]] && [[ "$DRY_RUN" != "true" ]]; then
        log_info "Creating development setup script"
        cat > "$dev_script" << 'EOF'
#!/usr/bin/env bash
# Development environment setup for Claude Auto-Resume

set -euo pipefail

echo "Setting up development environment..."

# Run syntax checks
if command -v shellcheck >/dev/null 2>&1; then
    echo "Running ShellCheck on all shell scripts..."
    find . -name "*.sh" -exec shellcheck {} +
    echo "ShellCheck completed"
else
    echo "ShellCheck not available - install for better development experience"
fi

# Run tests if available
if [[ -d "tests" ]] && command -v bats >/dev/null 2>&1; then
    echo "Running tests..."
    bats tests/
else
    echo "Tests not available or BATS not installed"
fi

echo "Development environment setup completed!"
EOF
        chmod +x "$dev_script"
    fi
    
    log_success "Development tools setup completed"
}

# ===============================================================================
# COMMAND-LINE-INTERFACE
# ===============================================================================

# Zeige Setup-Hilfe
show_help() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS]

Complete setup script for Claude Auto-Resume system.

OPTIONS:
    --skip-deps             Skip system dependency installation
    --skip-claunch          Skip claunch installation
    --claunch-method METHOD claunch installation method: official, npm, source, auto (default: official)
    --skip-tests            Skip setup validation tests
    --dev                   Install development tools (ShellCheck, BATS)
    --force                 Force reinstallation of components
    --dry-run               Preview actions without executing them
    --non-interactive       Run without user interaction (use defaults)
    --fix-permissions       Fix script permissions and exit (useful after git clone)
    --debug                 Enable debug output
    -h, --help              Show this help message
    --version               Show version information

SETUP PROCESS:
    1. Gather system information
    2. Install system dependencies (git, curl, jq, tmux, node)
    3. Install/verify Claude CLI
    4. Install claunch for session management
    5. Create project directories
    6. Set file permissions
    7. Create shortcuts and PATH entries
    8. Setup configuration
    9. Run validation tests
    10. Optional demo

EXAMPLES:
    # Full interactive setup with official claunch installer (recommended)
    $SCRIPT_NAME

    # Quick setup without interaction
    $SCRIPT_NAME --non-interactive

    # Setup with specific claunch installation method
    $SCRIPT_NAME --claunch-method npm

    # Development setup with tools
    $SCRIPT_NAME --dev

    # Preview what would be done
    $SCRIPT_NAME --dry-run --debug

REQUIREMENTS:
    - Unix-like system (macOS, Linux)
    - Internet connection
    - Administrative privileges (may be required for package installation)

The script will guide you through the setup process and can be safely re-run.
EOF
}

# Zeige Versionsinformation
show_version() {
    echo "$SCRIPT_NAME version $VERSION"
    echo "Claude Auto-Resume System Setup"
}

# Parse Kommandozeilen-Argumente
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --skip-deps)
                SKIP_DEPENDENCIES=true
                shift
                ;;
            --skip-claunch)
                SKIP_CLAUNCH=true
                shift
                ;;
            --claunch-method)
                if [[ -z "${2:-}" ]]; then
                    log_error "Option $1 requires a method (official, npm, source, auto)"
                    exit 1
                fi
                case "${2}" in
                    "official"|"npm"|"source"|"auto")
                        CLAUNCH_METHOD="$2"
                        ;;
                    *)
                        log_error "Invalid claunch method: $2"
                        log_error "Valid methods: official, npm, source, auto"
                        exit 1
                        ;;
                esac
                shift 2
                ;;
            --skip-tests)
                SKIP_TESTS=true
                shift
                ;;
            --dev)
                INSTALL_DEV_TOOLS=true
                shift
                ;;
            --force)
                FORCE_REINSTALL=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --non-interactive)
                INTERACTIVE_MODE=false
                shift
                ;;
            --fix-permissions)
                log_info "Running permission fix only"
                fix_script_permissions
                exit 0
                ;;
            --debug)
                DEBUG=true
                shift
                ;;
            --version)
                show_version
                exit 0
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                log_error "Use --help for usage information"
                exit 1
                ;;
        esac
    done
    
    log_debug "Configuration:"
    log_debug "  SKIP_DEPENDENCIES=$SKIP_DEPENDENCIES"
    log_debug "  SKIP_CLAUNCH=$SKIP_CLAUNCH"
    log_debug "  CLAUNCH_METHOD=$CLAUNCH_METHOD"
    log_debug "  SKIP_TESTS=$SKIP_TESTS"
    log_debug "  INSTALL_DEV_TOOLS=$INSTALL_DEV_TOOLS"
    log_debug "  FORCE_REINSTALL=$FORCE_REINSTALL"
    log_debug "  DRY_RUN=$DRY_RUN"
    log_debug "  INTERACTIVE_MODE=$INTERACTIVE_MODE"
}

# ===============================================================================
# MAIN ENTRY POINT
# ===============================================================================

# Zeige Setup-Header
show_header() {
    echo
    echo "╭─────────────────────────────────────────────────────────────╮"
    echo "│                 Claude Auto-Resume Setup                   │"
    echo "│                     Version $VERSION                        │"
    echo "╰─────────────────────────────────────────────────────────────╯"
    echo
    log_info "Welcome to Claude Auto-Resume setup!"
    echo
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "DRY RUN MODE - No changes will be made"
        echo
    fi
}

# Zeige Setup-Zusammenfassung
show_summary() {
    echo
    echo "╭─────────────────────────────────────────────────────────────╮"
    echo "│                    Setup Completed!                        │"
    echo "╰─────────────────────────────────────────────────────────────╯"
    echo
    log_success "Claude Auto-Resume has been successfully set up!"
    echo
    log_info "Quick start guide:"
    log_info "  1. Start continuous monitoring:"
    log_info "     $PROJECT_ROOT/src/hybrid-monitor.sh --continuous"
    echo
    log_info "  2. Or use the shortcut (if PATH was updated):"
    log_info "     claude-auto-resume --continuous --new-terminal"
    echo
    log_info "  3. For help and options:"
    log_info "     claude-auto-resume --help"
    echo
    log_info "  4. Configuration file:"
    log_info "     $PROJECT_ROOT/config/user.conf"
    echo
    log_info "For more information, see README.md"
    echo
}

main() {
    # Parse Argumente
    parse_arguments "$@"
    
    # Header anzeigen
    show_header
    
    # System-Informationen sammeln
    gather_system_info
    
    # Setup-Schritte ausführen
    local failed_steps=0
    
    # Schritt 1: System-Dependencies
    if [[ "$SKIP_DEPENDENCIES" != "true" ]]; then
        if ! install_system_dependencies; then
            ((failed_steps++))
            log_error "System dependencies installation failed"
        fi
    fi
    
    # Schritt 2: Claude CLI
    if ! install_claude_cli; then
        ((failed_steps++))
        log_error "Claude CLI installation/verification failed"
    fi
    
    # Schritt 3: claunch
    if ! install_claunch; then
        ((failed_steps++))
        log_error "claunch installation failed"
    fi
    
    # Schritt 4: Projekt-Setup
    if ! create_directories; then
        ((failed_steps++))
        log_error "Directory creation failed"
    fi
    
    if ! set_file_permissions; then
        ((failed_steps++))
        log_error "File permissions setup failed"
    fi
    
    if ! create_shortcuts; then
        ((failed_steps++))
        log_error "Shortcuts creation failed"
    fi
    
    # Schritt 5: Konfiguration
    if ! create_user_config; then
        ((failed_steps++))
        log_error "User configuration creation failed"
    fi
    
    # Schritt 6: Development-Tools (optional)
    if ! install_dev_tools; then
        log_warn "Development tools installation had issues"
    fi
    
    # Schritt 7: Tests
    if ! run_setup_tests; then
        ((failed_steps++))
        log_error "Setup validation tests failed"
    fi
    
    # Schritt 8: Demo (optional)
    run_demo
    
    # Zusammenfassung
    if [[ $failed_steps -eq 0 ]]; then
        show_summary
        exit 0
    else
        echo
        log_error "Setup completed with $failed_steps failed step(s)"
        log_error "Please check the error messages above and re-run setup if needed"
        exit 1
    fi
}

# Führe main nur aus wenn Skript direkt aufgerufen wird
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi