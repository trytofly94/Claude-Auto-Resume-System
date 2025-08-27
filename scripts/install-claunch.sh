#!/usr/bin/env bash

# Claude Auto-Resume - claunch Installation Script
# Automatische Installation von claunch für das Claude Auto-Resume System
# Version: 1.0.0-alpha
# Letzte Aktualisierung: 2025-08-05

set -euo pipefail

# ===============================================================================
# GLOBALE VARIABLEN UND KONSTANTEN
# ===============================================================================

readonly SCRIPT_NAME="install-claunch"
readonly VERSION="1.0.0-alpha"
# SCRIPT_DIR was unused and removed

# claunch-Installationsoptionen
INSTALL_METHOD="auto"
FORCE_REINSTALL=false
SKIP_DEPENDENCIES=false
INSTALL_TARGET="$HOME/bin"
VERIFY_INSTALLATION=true

# claunch-Konfiguration
CLAUNCH_REPO="https://github.com/0xkaz/claunch.git"
CLAUNCH_NPM_PACKAGE="@0xkaz/claunch"
CLAUNCH_OFFICIAL_INSTALLER_URL="https://raw.githubusercontent.com/0xkaz/claunch/main/install.sh"

# Network and retry configuration for official installer
NETWORK_TIMEOUT=30
MAX_RETRY_ATTEMPTS=3
RETRY_DELAY=2

# ===============================================================================
# HILFSFUNKTIONEN
# ===============================================================================

# Logging-Funktionen
log_info() { echo "[INFO] $*"; }
log_warn() { echo "[WARN] $*" >&2; }
log_error() { echo "[ERROR] $*" >&2; }
log_debug() { [[ "${DEBUG:-false}" == "true" ]] && echo "[DEBUG] $*" >&2; }

# Prüfe ob Kommando verfügbar ist
has_command() {
    command -v "$1" >/dev/null 2>&1
}

# Erkenne Betriebssystem
detect_os() {
    case "$(uname -s)" in
        Darwin) echo "macos" ;;
        Linux) echo "linux" ;;
        CYGWIN*|MINGW*|MSYS*) echo "windows" ;;
        *) echo "unknown" ;;
    esac
}

# Erkenne Package-Manager
detect_package_manager() {
    if has_command brew; then
        echo "brew"
    elif has_command apt-get; then
        echo "apt"
    elif has_command yum; then
        echo "yum"
    elif has_command dnf; then
        echo "dnf"
    elif has_command pacman; then
        echo "pacman"
    else
        echo "none"
    fi
}

# ===============================================================================
# DEPENDENCY-INSTALLATION
# ===============================================================================

# Installiere Node.js falls nicht vorhanden
install_nodejs() {
    log_info "Checking Node.js installation"
    
    if has_command node && has_command npm; then
        local node_version
        node_version=$(node --version 2>/dev/null || echo "unknown")
        log_info "Node.js already installed: $node_version"
        return 0
    fi
    
    log_info "Node.js not found - installing"
    
    local os
    os=$(detect_os)
    local pkg_manager
    pkg_manager=$(detect_package_manager)
    
    case "$os" in
        "macos")
            if [[ "$pkg_manager" == "brew" ]]; then
                brew install node
            else
                log_error "Homebrew not found. Please install Node.js manually:"
                log_error "  https://nodejs.org/en/download/"
                return 1
            fi
            ;;
        "linux")
            case "$pkg_manager" in
                "apt")
                    sudo apt-get update
                    sudo apt-get install -y nodejs npm
                    ;;
                "yum"|"dnf")
                    sudo "$pkg_manager" install -y nodejs npm
                    ;;
                "pacman")
                    sudo pacman -S nodejs npm
                    ;;
                *)
                    log_error "No supported package manager found for Node.js installation"
                    log_error "Please install Node.js manually: https://nodejs.org/"
                    return 1
                    ;;
            esac
            ;;
        *)
            log_error "Unsupported operating system for automatic Node.js installation"
            log_error "Please install Node.js manually: https://nodejs.org/"
            return 1
            ;;
    esac
    
    # Verifiziere Installation
    if has_command node && has_command npm; then
        log_info "Node.js installation successful"
        return 0
    else
        log_error "Node.js installation failed"
        return 1
    fi
}

# Installiere Git falls nicht vorhanden
install_git() {
    if has_command git; then
        log_info "Git already installed: $(git --version | head -1)"
        return 0
    fi
    
    log_info "Git not found - installing"
    
    local os
    os=$(detect_os)
    local pkg_manager
    pkg_manager=$(detect_package_manager)
    
    case "$os" in
        "macos")
            if [[ "$pkg_manager" == "brew" ]]; then
                brew install git
            else
                log_error "Homebrew not found. Please install Git manually."
                return 1
            fi
            ;;
        "linux")
            case "$pkg_manager" in
                "apt")
                    sudo apt-get update
                    sudo apt-get install -y git
                    ;;
                "yum"|"dnf")
                    sudo "$pkg_manager" install -y git
                    ;;
                "pacman")
                    sudo pacman -S git
                    ;;
                *)
                    log_error "No supported package manager found for Git installation"
                    return 1
                    ;;
            esac
            ;;
        *)
            log_error "Unsupported operating system for automatic Git installation"
            return 1
            ;;
    esac
    
    if has_command git; then
        log_info "Git installation successful"
        return 0
    else
        log_error "Git installation failed"
        return 1
    fi
}

# Installiere alle Dependencies
install_dependencies() {
    if [[ "$SKIP_DEPENDENCIES" == "true" ]]; then
        log_info "Skipping dependency installation"
        return 0
    fi
    
    log_info "Installing dependencies"
    
    # Node.js und npm
    if ! install_nodejs; then
        return 1
    fi
    
    # Git (für Source-Installation)
    if [[ "$INSTALL_METHOD" == "source" ]] || [[ "$INSTALL_METHOD" == "auto" ]]; then
        if ! install_git; then
            log_warn "Git installation failed - source installation not available"
        fi
    fi
    
    log_info "Dependencies installation completed"
    return 0
}

# ===============================================================================
# NETWORK AND DOWNLOAD UTILITIES
# ===============================================================================

# Test network connectivity to a given URL
test_network_connectivity() {
    local url="$1"
    local timeout="${2:-$NETWORK_TIMEOUT}"
    
    log_debug "Testing connectivity to: $url"
    
    if has_command curl; then
        if curl --connect-timeout "$timeout" --max-time "$timeout" --silent --head "$url" >/dev/null 2>&1; then
            log_debug "Network connectivity test successful"
            return 0
        else
            log_debug "Network connectivity test failed"
            return 1
        fi
    elif has_command wget; then
        if wget --timeout="$timeout" --tries=1 --spider --quiet "$url" 2>/dev/null; then
            log_debug "Network connectivity test successful (wget)"
            return 0
        else
            log_debug "Network connectivity test failed (wget)"
            return 1
        fi
    else
        log_warn "No network test tool available (curl or wget required)"
        return 1
    fi
}

# Download content with retry logic
download_with_retry() {
    local url="$1"
    local output_file="${2:-}"
    local max_attempts="${3:-$MAX_RETRY_ATTEMPTS}"
    local delay="${4:-$RETRY_DELAY}"
    
    log_info "Downloading from: $url"
    
    for ((attempt=1; attempt<=max_attempts; attempt++)); do
        log_debug "Download attempt $attempt/$max_attempts"
        
        # Test connectivity first
        if ! test_network_connectivity "$url"; then
            if [[ $attempt -lt $max_attempts ]]; then
                log_warn "Network connectivity test failed, retrying in ${delay}s..."
                sleep "$delay"
                continue
            else
                log_error "Network connectivity test failed after $max_attempts attempts"
                return 1
            fi
        fi
        
        # Attempt download
        local download_success=false
        
        if has_command curl; then
            if [[ -n "$output_file" ]]; then
                if curl --fail --location --connect-timeout "$NETWORK_TIMEOUT" --max-time "$((NETWORK_TIMEOUT * 2))" --silent --output "$output_file" "$url" 2>/dev/null; then
                    download_success=true
                fi
            else
                # Download to stdout for piping
                if curl --fail --location --connect-timeout "$NETWORK_TIMEOUT" --max-time "$((NETWORK_TIMEOUT * 2))" --silent "$url" 2>/dev/null; then
                    download_success=true
                fi
            fi
        elif has_command wget; then
            if [[ -n "$output_file" ]]; then
                if wget --timeout="$NETWORK_TIMEOUT" --tries=1 --output-document="$output_file" --quiet "$url" 2>/dev/null; then
                    download_success=true
                fi
            else
                # Download to stdout for piping
                if wget --timeout="$NETWORK_TIMEOUT" --tries=1 --output-document=- --quiet "$url" 2>/dev/null; then
                    download_success=true
                fi
            fi
        else
            log_error "No download tool available (curl or wget required)"
            return 1
        fi
        
        if [[ "$download_success" == "true" ]]; then
            log_debug "Download successful on attempt $attempt"
            return 0
        fi
        
        if [[ $attempt -lt $max_attempts ]]; then
            log_warn "Download failed, retrying in ${delay}s..."
            sleep "$delay"
            # Exponential backoff
            delay=$((delay * 2))
        fi
    done
    
    log_error "Download failed after $max_attempts attempts"
    return 1
}

# ===============================================================================
# CLAUNCH-INSTALLATION
# ===============================================================================

# Prüfe ob claunch bereits installiert ist
check_existing_claunch() {
    log_info "Checking for existing claunch installation"
    
    # Prüfe globale npm-Installation
    if has_command claunch; then
        local claunch_path
        claunch_path=$(command -v claunch)
        local claunch_version
        claunch_version=$(claunch --version 2>/dev/null | head -1 || echo "unknown")
        
        log_info "claunch found in PATH: $claunch_path"
        log_info "claunch version: $claunch_version"
        
        if [[ "$FORCE_REINSTALL" == "true" ]]; then
            log_info "Force reinstall requested - proceeding with installation"
            return 1
        else
            log_info "claunch already installed - use --force to reinstall"
            return 0
        fi
    fi
    
    # Prüfe lokale Installationen
    local local_paths=(
        "$HOME/bin/claunch"
        "$HOME/.local/bin/claunch"
        "$INSTALL_TARGET/claunch"
    )
    
    for path in "${local_paths[@]}"; do
        if [[ -x "$path" ]]; then
            log_info "claunch found at: $path"
            
            if [[ "$FORCE_REINSTALL" == "true" ]]; then
                log_info "Force reinstall requested - proceeding with installation"
                return 1
            else
                log_info "claunch already installed - use --force to reinstall"
                return 0
            fi
        fi
    done
    
    log_info "claunch not found - proceeding with installation"
    return 1
}

# Installiere claunch via official installer (GitHub #38)
install_claunch_official() {
    log_info "Installing claunch via official installer"
    
    # Verify network connectivity first
    if ! test_network_connectivity "$CLAUNCH_OFFICIAL_INSTALLER_URL"; then
        log_error "Cannot reach official installer URL"
        log_error "Please check your internet connection"
        return 1
    fi
    
    log_info "Downloading and executing official installer from GitHub"
    log_info "Installer URL: $CLAUNCH_OFFICIAL_INSTALLER_URL"
    
    # Download and execute the installer
    local installer_success=false
    local temp_installer
    
    # Create temporary file for installer
    temp_installer=$(mktemp) || {
        log_error "Failed to create temporary file for installer"
        return 1
    }
    
    # Cleanup function for temporary installer
    cleanup_installer() {
        rm -f "$temp_installer"
    }
    
    trap cleanup_installer EXIT
    
    # Download installer script with retry logic
    if download_with_retry "$CLAUNCH_OFFICIAL_INSTALLER_URL" "$temp_installer"; then
        log_info "Installer downloaded successfully"
        
        # Verify the downloaded file is not empty and contains bash script
        if [[ ! -s "$temp_installer" ]]; then
            log_error "Downloaded installer is empty"
            return 1
        fi
        
        if ! head -1 "$temp_installer" | grep -q "^#!.*bash"; then
            log_warn "Downloaded installer may not be a bash script"
            log_info "First line: $(head -1 "$temp_installer")"
        fi
        
        # Make installer executable
        chmod +x "$temp_installer"
        
        # Execute installer
        log_info "Executing official claunch installer..."
        if bash "$temp_installer"; then
            installer_success=true
            log_info "Official installer completed successfully"
        else
            log_error "Official installer execution failed"
            return 1
        fi
    else
        log_error "Failed to download official installer"
        return 1
    fi
    
    # Verify installation was successful
    if [[ "$installer_success" == "true" ]]; then
        # Allow some time for installer to complete its work
        sleep 2
        
        # Refresh shell environment to pick up any PATH changes
        refresh_shell_path
        
        # Check if claunch is now available
        if has_command claunch || [[ -x "$INSTALL_TARGET/claunch" ]]; then
            log_info "claunch official installation completed successfully"
            return 0
        else
            log_warn "Official installer completed but claunch not found in PATH"
            log_warn "You may need to restart your terminal or update your PATH"
            return 0  # Don't fail here as installer may have succeeded
        fi
    else
        log_error "Official installer failed"
        return 1
    fi
}

# Installiere claunch via npm
install_claunch_npm() {
    log_info "Installing claunch via npm"
    
    # Versuche globale Installation
    if npm install -g "$CLAUNCH_NPM_PACKAGE"; then
        log_info "claunch installed globally via npm"
        return 0
    else
        log_warn "Global npm installation failed - trying alternative methods"
        
        # Alternative: User-lokale npm-Installation
        if npm config get prefix >/dev/null 2>&1; then
            local npm_prefix
            npm_prefix=$(npm config get prefix)
            
            if [[ "$npm_prefix" == "$HOME"* ]]; then
                log_info "Trying user-local npm installation"
                if npm install -g "$CLAUNCH_NPM_PACKAGE" --prefix="$HOME/.npm-global"; then
                    log_info "claunch installed via user-local npm"
                    
                    # Füge zu PATH hinzu falls nötig
                    local npm_bin="$HOME/.npm-global/bin"
                    if [[ ":$PATH:" != *":$npm_bin:"* ]]; then
                        log_info "Adding $npm_bin to PATH"
                        echo "export PATH=\"$npm_bin:\$PATH\"" >> "$HOME/.bashrc"
                        echo "export PATH=\"$npm_bin:\$PATH\"" >> "$HOME/.zshrc" 2>/dev/null || true
                    fi
                    
                    return 0
                fi
            fi
        fi
        
        return 1
    fi
}

# Installiere claunch von Source
install_claunch_source() {
    log_info "Installing claunch from source"
    
    if ! has_command git; then
        log_error "Git not available for source installation"
        return 1
    fi
    
    local temp_dir
    temp_dir=$(mktemp -d)
    local original_dir
    original_dir=$(pwd)
    
    # Cleanup-Funktion für temporäres Verzeichnis
    cleanup_temp() {
        cd "$original_dir"
        rm -rf "$temp_dir"
    }
    
    trap cleanup_temp EXIT
    
    log_info "Cloning claunch repository to: $temp_dir"
    
    if ! git clone "$CLAUNCH_REPO" "$temp_dir"; then
        log_error "Failed to clone claunch repository"
        return 1
    fi
    
    cd "$temp_dir"
    
    # Installiere Dependencies
    if ! npm install; then
        log_error "Failed to install claunch dependencies"
        return 1
    fi
    
    # Build falls nötig
    if [[ -f "package.json" ]] && grep -q '"build":' package.json; then
        log_info "Building claunch"
        if ! npm run build; then
            log_warn "Build failed - proceeding anyway"
        fi
    fi
    
    # Stelle sicher, dass Zielverzeichnis existiert
    mkdir -p "$INSTALL_TARGET"
    
    # Installiere claunch
    if npm install -g .; then
        log_info "claunch installed from source"
        return 0
    else
        # Alternative: Manuelle Installation
        log_info "Trying manual installation to $INSTALL_TARGET"
        
        local main_script
        main_script=$(node -p "require('./package.json').bin.claunch || require('./package.json').main" 2>/dev/null || echo "index.js")
        
        if [[ -f "$main_script" ]]; then
            cp "$main_script" "$INSTALL_TARGET/claunch"
            chmod +x "$INSTALL_TARGET/claunch"
            
            # Füge Shebang hinzu falls nicht vorhanden
            if ! head -1 "$INSTALL_TARGET/claunch" | grep -q "^#!"; then
                sed -i.bak '1i\
#!/usr/bin/env node
' "$INSTALL_TARGET/claunch" 2>/dev/null || {
                    # Fallback für macOS
                    echo '#!/usr/bin/env node' > "$INSTALL_TARGET/claunch.tmp"
                    cat "$INSTALL_TARGET/claunch" >> "$INSTALL_TARGET/claunch.tmp"
                    mv "$INSTALL_TARGET/claunch.tmp" "$INSTALL_TARGET/claunch"
                    chmod +x "$INSTALL_TARGET/claunch"
                }
                rm -f "$INSTALL_TARGET/claunch.bak"
            fi
            
            log_info "claunch manually installed to: $INSTALL_TARGET/claunch"
            
            # PATH-Hinweis
            if [[ ":$PATH:" != *":$INSTALL_TARGET:"* ]]; then
                log_info "Add $INSTALL_TARGET to your PATH:"
                log_info "  echo 'export PATH=\"$INSTALL_TARGET:\$PATH\"' >> ~/.bashrc"
            fi
            
            return 0
        else
            log_error "Could not find main script for manual installation"
            return 1
        fi
    fi
}

# Installiere claunch mit automatischer Methodenwahl
install_claunch_auto() {
    log_info "Installing claunch with automatic method selection"
    
    # Prüfe welche Methoden verfügbar sind (prioritized order: official -> npm -> source)
    local methods=()
    
    # Check if we have network tools for official installation
    if has_command curl || has_command wget; then
        methods+=("official")
    fi
    
    if has_command npm; then
        methods+=("npm")
    fi
    
    if has_command git; then
        methods+=("source")
    fi
    
    if [[ ${#methods[@]} -eq 0 ]]; then
        log_error "No installation methods available"
        log_error "Please install curl/wget for official installer, npm for npm method, or git for source method"
        return 1
    fi
    
    log_info "Available installation methods: ${methods[*]}"
    
    # Versuche Installationsmethoden in der Reihenfolge
    for method in "${methods[@]}"; do
        log_info "Trying installation method: $method"
        
        case "$method" in
            "official")
                if install_claunch_official; then
                    return 0
                fi
                ;;
            "npm")
                if install_claunch_npm; then
                    return 0
                fi
                ;;
            "source")
                if install_claunch_source; then
                    return 0
                fi
                ;;
        esac
        
        log_warn "Installation method '$method' failed"
    done
    
    log_error "All installation methods failed"
    return 1
}

# Hauptinstallationsfunktion
install_claunch() {
    log_info "Starting claunch installation (method: $INSTALL_METHOD)"
    
    # Prüfe existierende Installation
    if check_existing_claunch; then
        return 0
    fi
    
    # Installiere Dependencies
    if ! install_dependencies; then
        log_error "Dependency installation failed"
        return 1
    fi
    
    # Installiere claunch basierend auf Methode
    case "$INSTALL_METHOD" in
        "official")
            install_claunch_official
            ;;
        "npm")
            install_claunch_npm
            ;;
        "source")
            install_claunch_source
            ;;
        "auto")
            install_claunch_auto
            ;;
        *)
            log_error "Unknown installation method: $INSTALL_METHOD"
            log_error "Valid methods: official, npm, source, auto"
            return 1
            ;;
    esac
}

# ===============================================================================
# PATH AND ENVIRONMENT MANAGEMENT
# ===============================================================================

# Enhanced shell PATH environment refresh (addresses GitHub issue #4)
refresh_shell_path() {
    log_debug "Refreshing shell PATH environment with enhanced detection"
    
    # Add install target to current PATH if not already present
    if [[ ":$PATH:" != *":$INSTALL_TARGET:"* ]]; then
        export PATH="$INSTALL_TARGET:$PATH"
        log_debug "Added $INSTALL_TARGET to current PATH"
    fi
    
    # Add common claunch installation paths to PATH
    local common_claunch_paths=(
        "$HOME/.local/bin"
        "$HOME/bin"
        "/usr/local/bin"
        "$HOME/.npm-global/bin"
        "$HOME/.nvm/versions/node/*/bin"
    )
    
    for path in "${common_claunch_paths[@]}"; do
        # Handle glob patterns for NVM paths
        if [[ "$path" == *"*"* ]]; then
            for expanded_path in $path; do
                if [[ -d "$expanded_path" ]] && [[ ":$PATH:" != *":$expanded_path:"* ]]; then
                    export PATH="$expanded_path:$PATH"
                    log_debug "Added NVM path $expanded_path to current PATH"
                fi
            done
        else
            if [[ -d "$path" ]] && [[ ":$PATH:" != *":$path:"* ]]; then
                export PATH="$path:$PATH"
                log_debug "Added common path $path to current PATH"
            fi
        fi
    done
    
    # Source shell configuration files in priority order
    local shell_configs=()
    
    # Detect current shell and prioritize its config
    if [[ -n "${ZSH_VERSION:-}" ]] || [[ "$SHELL" == */zsh ]]; then
        shell_configs+=("$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.zshenv")
    elif [[ -n "${BASH_VERSION:-}" ]] || [[ "$SHELL" == */bash ]]; then
        shell_configs+=("$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.bash_login")
    fi
    
    # Add common configs
    shell_configs+=("$HOME/.profile" "$HOME/.shellrc")
    
    local configs_sourced=0
    for config in "${shell_configs[@]}"; do
        if [[ -f "$config" ]] && [[ -r "$config" ]]; then
            log_debug "Sourcing $config"
            # shellcheck disable=SC1090
            if source "$config" 2>/dev/null; then
                ((configs_sourced++))
                log_debug "Successfully sourced $config"
            else
                log_debug "Failed to source $config (may contain syntax errors)"
            fi
        fi
    done
    
    log_debug "Sourced $configs_sourced shell configuration files"
    
    # Refresh hash table for command lookups
    hash -r 2>/dev/null || true
    
    # Allow a moment for environment changes to take effect
    sleep 1
    
    log_debug "PATH refresh completed. Current PATH length: ${#PATH}"
}

# Ensure PATH is configured in shell configuration files
ensure_path_configuration() {
    log_info "Ensuring PATH configuration for claunch"
    
    # Check if INSTALL_TARGET is already in PATH configuration
    local shell_configs=("$HOME/.bashrc" "$HOME/.zshrc")
    local path_configured=false
    
    for config in "${shell_configs[@]}"; do
        if [[ -f "$config" ]] && grep -q "$INSTALL_TARGET" "$config" 2>/dev/null; then
            log_info "PATH already configured in $config"
            path_configured=true
            break
        fi
    done
    
    # If not configured, add to appropriate shell config
    if [[ "$path_configured" == "false" ]]; then
        local target_config=""
        
        # Determine which shell config to use
        if [[ -n "${ZSH_VERSION:-}" ]] || [[ "$SHELL" == */zsh ]]; then
            target_config="$HOME/.zshrc"
        elif [[ -n "${BASH_VERSION:-}" ]] || [[ "$SHELL" == */bash ]]; then
            target_config="$HOME/.bashrc"
        else
            target_config="$HOME/.profile"
        fi
        
        # Create config file if it doesn't exist
        if [[ ! -f "$target_config" ]]; then
            touch "$target_config"
            log_info "Created shell configuration file: $target_config"
        fi
        
        # Add PATH export
        log_info "Adding $INSTALL_TARGET to PATH in $target_config"
        echo "" >> "$target_config"
        echo "# Added by claunch installer ($(date))" >> "$target_config"
        echo "export PATH=\"$INSTALL_TARGET:\$PATH\"" >> "$target_config"
        
        log_info "PATH configuration added. Please restart your terminal or run: source $target_config"
    fi
}

# ===============================================================================
# INSTALLATION-VERIFIZIERUNG
# ===============================================================================

# Enhanced claunch installation verification with comprehensive detection (addresses GitHub issue #4)
verify_installation() {
    log_info "Verifying claunch installation with comprehensive detection"
    
    # First, refresh PATH environment to pick up any new installations
    refresh_shell_path
    
    # Multi-round verification with different strategies
    local claunch_path=""
    local verification_attempts=5
    local attempt=1
    local verification_methods=()
    
    while [[ $attempt -le $verification_attempts ]]; do
        log_info "Verification attempt $attempt/$verification_attempts"
        
        # Method 1: Check if claunch is in PATH
        if has_command claunch; then
            claunch_path=$(command -v claunch 2>/dev/null)
            if [[ -n "$claunch_path" && -x "$claunch_path" ]]; then
                verification_methods+=("PATH lookup")
                log_info "Found claunch via PATH: $claunch_path"
                break
            fi
        fi
        
        # Method 2: Check install target directory
        if [[ -x "$INSTALL_TARGET/claunch" ]]; then
            claunch_path="$INSTALL_TARGET/claunch"
            verification_methods+=("Install target")
            log_info "Found claunch at install target: $claunch_path"
            break
        fi
        
        # Method 3: Check common installation paths
        local common_paths=(
            "$HOME/.local/bin/claunch"
            "$HOME/bin/claunch"
            "/usr/local/bin/claunch"
            "$HOME/.npm-global/bin/claunch"
            "/opt/homebrew/bin/claunch"
            "/usr/bin/claunch"
        )
        
        local found_common=false
        for path in "${common_paths[@]}"; do
            if [[ -x "$path" ]]; then
                claunch_path="$path"
                verification_methods+=("Common path")
                log_info "Found claunch at common path: $claunch_path"
                found_common=true
                break
            fi
        done
        
        if [[ "$found_common" == "true" ]]; then
            break
        fi
        
        # Method 4: Search in NVM paths (for npm installations)
        local nvm_search_paths=("$HOME/.nvm/versions/node/*/bin/claunch")
        for nvm_path in $nvm_search_paths; do
            if [[ -x "$nvm_path" ]]; then
                claunch_path="$nvm_path"
                verification_methods+=("NVM path")
                log_info "Found claunch in NVM path: $claunch_path"
                found_common=true
                break
            fi
        done
        
        if [[ "$found_common" == "true" ]]; then
            break
        fi
        
        # Method 5: Search via which/whereis commands
        if has_command which; then
            local which_result
            which_result=$(which claunch 2>/dev/null) || true
            if [[ -n "$which_result" && -x "$which_result" ]]; then
                claunch_path="$which_result"
                verification_methods+=("which command")
                log_info "Found claunch via 'which': $claunch_path"
                break
            fi
        fi
        
        if has_command whereis; then
            local whereis_result
            whereis_result=$(whereis claunch 2>/dev/null | cut -d: -f2 | awk '{print $1}') || true
            if [[ -n "$whereis_result" && -x "$whereis_result" ]]; then
                claunch_path="$whereis_result"
                verification_methods+=("whereis command")
                log_info "Found claunch via 'whereis': $claunch_path"
                break
            fi
        fi
        
        # If not found and we have more attempts, wait and refresh
        if [[ $attempt -lt $verification_attempts ]]; then
            log_info "claunch not found, waiting 3s and refreshing environment..."
            sleep 3
            refresh_shell_path
            hash -r 2>/dev/null || true
        fi
        
        ((attempt++))
    done
    
    # Report verification results
    if [[ -z "$claunch_path" ]]; then
        log_error "claunch not found after $verification_attempts comprehensive verification attempts"
        log_error "Searched in:"
        log_error "  - PATH directories"
        log_error "  - Install target: $INSTALL_TARGET"
        log_error "  - Common installation paths"
        log_error "  - NVM node versions"
        log_error ""
        log_error "Possible solutions:"
        log_error "  1. Restart your terminal to refresh PATH"
        log_error "  2. Run: source ~/.bashrc (or ~/.zshrc)"
        log_error "  3. Add claunch location to PATH manually"
        log_error "  4. Reinstall with: $0 --force --method official"
        return 1
    fi
    
    log_info "claunch successfully located at: $claunch_path"
    log_info "Detection method(s): ${verification_methods[*]}"
    
    # Comprehensive functionality testing
    local tests_passed=0
    local tests_failed=0
    
    # Test 1: Version check
    log_info "Testing claunch version command..."
    local version_output
    if version_output=$("$claunch_path" --version 2>&1); then
        log_info "✓ Version test passed: $version_output"
        ((tests_passed++))
    else
        log_warn "✗ Version test failed"
        ((tests_failed++))
    fi
    
    # Test 2: Help command
    log_info "Testing claunch help command..."
    if "$claunch_path" --help >/dev/null 2>&1; then
        log_info "✓ Help command test passed"
        ((tests_passed++))
    else
        log_warn "✗ Help command test failed"
        ((tests_failed++))
    fi
    
    # Test 3: List command (non-critical, may fail if no sessions)
    log_info "Testing claunch list command..."
    if "$claunch_path" list >/dev/null 2>&1; then
        log_info "✓ List command test passed"
        ((tests_passed++))
    else
        log_info "○ List command test inconclusive (no sessions may exist)"
        # Don't count as failure
    fi
    
    # Test 4: File permissions and executable check
    log_info "Testing file permissions..."
    if [[ -x "$claunch_path" ]]; then
        log_info "✓ Executable permissions test passed"
        ((tests_passed++))
    else
        log_error "✗ Executable permissions test failed"
        ((tests_failed++))
    fi
    
    # Test 5: File type check (should be script or binary)
    log_info "Testing file type..."
    local file_type
    if file_type=$(file "$claunch_path" 2>/dev/null); then
        log_info "✓ File type: $file_type"
        ((tests_passed++))
    else
        log_warn "✗ Could not determine file type"
        ((tests_failed++))
    fi
    
    # Summary
    local total_tests=$((tests_passed + tests_failed))
    log_info ""
    log_info "Verification summary:"
    log_info "  Tests passed: $tests_passed"
    log_info "  Tests failed: $tests_failed"
    log_info "  Total tests: $total_tests"
    
    if [[ $tests_failed -eq 0 ]]; then
        log_info "🎉 claunch installation verification completed successfully!"
        return 0
    elif [[ $tests_failed -le 1 ]]; then
        log_warn "⚠️  claunch installation verification completed with minor issues"
        return 0
    else
        log_error "❌ claunch installation verification failed with $tests_failed critical issues"
        return 1
    fi
}

# ===============================================================================
# INSTALLATION STATUS REPORTING
# ===============================================================================

# Report comprehensive installation status with guidance
report_installation_status() {
    local install_success="$1"
    local installation_method="${2:-unknown}"
    
    echo
    echo "╭─────────────────────────────────────────────────────────────╮"
    echo "│                Installation Status Report                   │"
    echo "╰─────────────────────────────────────────────────────────────╯"
    echo
    
    # System information
    log_info "System Information:"
    log_info "  Operating System: $(detect_os)"
    log_info "  Package Manager: $(detect_package_manager)"
    log_info "  Shell: $(basename "$SHELL")"
    log_info "  Install Method: $installation_method"
    log_info "  Install Target: $INSTALL_TARGET"
    echo
    
    # Installation result
    if [[ "$install_success" == "true" ]]; then
        log_info "✅ Installation Status: SUCCESS"
        
        # Find claunch location
        local claunch_location=""
        if has_command claunch; then
            claunch_location=$(command -v claunch)
            log_info "✅ claunch Command: Available in PATH ($claunch_location)"
        elif [[ -x "$INSTALL_TARGET/claunch" ]]; then
            claunch_location="$INSTALL_TARGET/claunch"
            log_info "⚠️  claunch Command: Available at install target (may need PATH update)"
        else
            log_warn "❌ claunch Command: Not found in PATH"
        fi
        
        # Version information
        if [[ -n "$claunch_location" && -x "$claunch_location" ]]; then
            local version_info
            if version_info=$("$claunch_location" --version 2>/dev/null); then
                log_info "📋 claunch Version: $version_info"
            else
                log_warn "📋 claunch Version: Could not determine"
            fi
        fi
        
        echo
        log_info "🎉 claunch installation completed successfully!"
        echo
        log_info "Next Steps:"
        log_info "  1. You can now use claunch for Claude CLI session management"
        log_info "  2. Try: claunch --help to see available options"
        log_info "  3. Try: claunch to start Claude in current project"
        log_info "  4. Try: claunch --tmux for persistent sessions"
        
        # PATH guidance if needed
        if [[ -n "$claunch_location" ]] && ! has_command claunch; then
            echo
            log_info "PATH Configuration:"
            log_info "  claunch is installed but not in PATH"
            local claunch_dir
            claunch_dir=$(dirname "$claunch_location")
            log_info "  Add to your shell profile: export PATH=\"$claunch_dir:\$PATH\""
            log_info "  Or restart your terminal to pick up PATH changes"
        fi
        
    else
        log_error "❌ Installation Status: FAILED"
        echo
        log_error "Installation Diagnostics:"
        
        # Check system requirements
        local missing_deps=()
        if ! has_command curl && ! has_command wget; then
            missing_deps+=("curl or wget (for official installer)")
        fi
        if ! has_command npm && ! has_command git; then
            missing_deps+=("npm or git (for fallback methods)")
        fi
        
        if [[ ${#missing_deps[@]} -gt 0 ]]; then
            log_error "  Missing dependencies: ${missing_deps[*]}"
        fi
        
        # Check network connectivity
        if ! test_network_connectivity "$CLAUNCH_OFFICIAL_INSTALLER_URL" 5; then
            log_error "  Network: Cannot reach official installer"
        else
            log_info "  Network: OK (can reach official installer)"
        fi
        
        # Check permissions
        if [[ ! -w "$INSTALL_TARGET" ]]; then
            if [[ ! -d "$INSTALL_TARGET" ]]; then
                log_error "  Permissions: Install target directory does not exist: $INSTALL_TARGET"
            else
                log_error "  Permissions: Cannot write to install target: $INSTALL_TARGET"
            fi
        else
            log_info "  Permissions: OK (can write to install target)"
        fi
        
        echo
        log_error "Troubleshooting Suggestions:"
        log_error "  1. Check your internet connection"
        log_error "  2. Install missing dependencies (curl, npm, or git)"
        log_error "  3. Try a different installation method:"
        log_error "     • $0 --method npm"
        log_error "     • $0 --method source"
        log_error "  4. Try with debug output: $0 --debug"
        log_error "  5. Check permissions for: $INSTALL_TARGET"
        log_error "  6. Force reinstall: $0 --force"
    fi
    
    echo
    log_info "Installation Details:"
    log_info "  Script Version: $VERSION"
    log_info "  Timestamp: $(date)"
    log_info "  Configuration:"
    log_info "    METHOD=$INSTALL_METHOD"
    log_info "    TARGET=$INSTALL_TARGET" 
    log_info "    FORCE_REINSTALL=$FORCE_REINSTALL"
    log_info "    SKIP_DEPENDENCIES=$SKIP_DEPENDENCIES"
    log_info "    VERIFY_INSTALLATION=$VERIFY_INSTALLATION"
    log_info "    NETWORK_TIMEOUT=$NETWORK_TIMEOUT"
    log_info "    MAX_RETRY_ATTEMPTS=$MAX_RETRY_ATTEMPTS"
    
    echo
    log_info "For more help, visit:"
    log_info "  • claunch GitHub: https://github.com/0xkaz/claunch"
    log_info "  • Claude CLI: https://claude.ai/code"
    log_info "  • This project: $(pwd)"
    echo
}

# ===============================================================================
# COMMAND-LINE-INTERFACE
# ===============================================================================

# Zeige Hilfe
show_help() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS]

Install claunch for Claude CLI session management.

OPTIONS:
    --method METHOD         Installation method: official, npm, source, auto (default: auto)
    --target DIR           Installation target directory (default: $INSTALL_TARGET)
    --force                Force reinstallation if claunch already exists
    --skip-deps            Skip dependency installation
    --no-verify            Skip installation verification
    --timeout SECONDS      Network timeout for downloads (default: $NETWORK_TIMEOUT)
    --max-retries N        Maximum retry attempts for downloads (default: $MAX_RETRY_ATTEMPTS)
    --debug                Enable debug output
    -h, --help             Show this help message
    --version              Show version information

INSTALLATION METHODS:
    official    Install via official GitHub installer (recommended, addresses issue #38)
    npm         Install via npm package manager
    source      Install from GitHub source repository
    auto        Try official first, then npm, then source (default)

EXAMPLES:
    # Install with default settings
    $SCRIPT_NAME

    # Install from source with custom target directory
    $SCRIPT_NAME --method source --target /usr/local/bin

    # Force reinstall with debug output
    $SCRIPT_NAME --force --debug

REQUIREMENTS:
    For npm method:     Node.js and npm
    For source method:  Node.js, npm, and git

The script will automatically install missing requirements if possible.
EOF
}

# Zeige Versionsinformation
show_version() {
    echo "$SCRIPT_NAME version $VERSION"
}

# Parse Kommandozeilen-Argumente
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --method)
                if [[ -z "${2:-}" ]]; then
                    log_error "Option $1 requires a method (official, npm, source, auto)"
                    exit 1
                fi
                INSTALL_METHOD="$2"
                shift 2
                ;;
            --target)
                if [[ -z "${2:-}" ]]; then
                    log_error "Option $1 requires a directory path"
                    exit 1
                fi
                INSTALL_TARGET="$2"
                shift 2
                ;;
            --timeout)
                if [[ -z "${2:-}" ]] || ! [[ "${2:-}" =~ ^[0-9]+$ ]]; then
                    log_error "Option $1 requires a numeric timeout value in seconds"
                    exit 1
                fi
                NETWORK_TIMEOUT="$2"
                shift 2
                ;;
            --max-retries)
                if [[ -z "${2:-}" ]] || ! [[ "${2:-}" =~ ^[0-9]+$ ]]; then
                    log_error "Option $1 requires a numeric retry count"
                    exit 1
                fi
                MAX_RETRY_ATTEMPTS="$2"
                shift 2
                ;;
            --force)
                FORCE_REINSTALL=true
                shift
                ;;
            --skip-deps)
                SKIP_DEPENDENCIES=true
                shift
                ;;
            --no-verify)
                VERIFY_INSTALLATION=false
                shift
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
    
    # Validiere Installation-Methode
    case "$INSTALL_METHOD" in
        "official"|"npm"|"source"|"auto") ;;
        *)
            log_error "Invalid installation method: $INSTALL_METHOD"
            log_error "Valid methods: official, npm, source, auto"
            exit 1
            ;;
    esac
    
    log_debug "Configuration:"
    log_debug "  INSTALL_METHOD=$INSTALL_METHOD"
    log_debug "  INSTALL_TARGET=$INSTALL_TARGET"
    log_debug "  FORCE_REINSTALL=$FORCE_REINSTALL"
    log_debug "  SKIP_DEPENDENCIES=$SKIP_DEPENDENCIES"
    log_debug "  VERIFY_INSTALLATION=$VERIFY_INSTALLATION"
    log_debug "  NETWORK_TIMEOUT=$NETWORK_TIMEOUT"
    log_debug "  MAX_RETRY_ATTEMPTS=$MAX_RETRY_ATTEMPTS"
}

# ===============================================================================
# MAIN ENTRY POINT
# ===============================================================================

main() {
    log_info "claunch Installation Script v$VERSION"
    log_info "Operating system: $(detect_os)"
    log_info "Package manager: $(detect_package_manager)"
    echo ""
    
    # Parse Argumente
    parse_arguments "$@"
    
    # Track installation method that was used
    local actual_method="$INSTALL_METHOD"
    local install_success=false
    
    # Installiere claunch
    if install_claunch; then
        install_success=true
        log_info "claunch installation successful!"
        
        # Ensure PATH configuration (addresses GitHub issue #4)
        ensure_path_configuration
        
        # Verifiziere Installation
        if [[ "$VERIFY_INSTALLATION" == "true" ]]; then
            if ! verify_installation; then
                log_warn "Installation verification had issues, but installation may still be functional"
                # Don't fail here as installation might still work
            fi
        fi
        
    else
        install_success=false
        log_error "claunch installation failed"
    fi
    
    # Always show comprehensive status report
    report_installation_status "$install_success" "$actual_method"
    
    # Exit with appropriate code
    if [[ "$install_success" == "true" ]]; then
        exit 0
    else
        exit 1
    fi
}

# Führe main nur aus wenn Skript direkt aufgerufen wird
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi