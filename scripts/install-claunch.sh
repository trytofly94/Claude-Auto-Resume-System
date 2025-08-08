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
    
    # Prüfe welche Methoden verfügbar sind
    local methods=()
    
    if has_command npm; then
        methods+=("npm")
    fi
    
    if has_command git; then
        methods+=("source")
    fi
    
    if [[ ${#methods[@]} -eq 0 ]]; then
        log_error "No installation methods available"
        log_error "Please install npm or git first"
        return 1
    fi
    
    # Versuche Installationsmethoden in der Reihenfolge
    for method in "${methods[@]}"; do
        log_info "Trying installation method: $method"
        
        case "$method" in
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
            return 1
            ;;
    esac
}

# ===============================================================================
# PATH AND ENVIRONMENT MANAGEMENT
# ===============================================================================

# Refresh shell PATH environment (addresses GitHub issue #4)
refresh_shell_path() {
    log_debug "Refreshing shell PATH environment"
    
    # Add install target to current PATH if not already present
    if [[ ":$PATH:" != *":$INSTALL_TARGET:"* ]]; then
        export PATH="$INSTALL_TARGET:$PATH"
        log_debug "Added $INSTALL_TARGET to current PATH"
    fi
    
    # Source common shell configuration files to pick up PATH changes
    local shell_configs=("$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc" "$HOME/.profile")
    
    for config in "${shell_configs[@]}"; do
        if [[ -f "$config" ]]; then
            log_debug "Sourcing $config"
            # shellcheck disable=SC1090
            source "$config" 2>/dev/null || true
        fi
    done
    
    # Allow a moment for environment changes to take effect
    sleep 1
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

# Enhanced claunch installation verification (addresses GitHub issue #4)
verify_installation() {
    log_info "Verifying claunch installation with enhanced detection"
    
    # First, try to refresh PATH environment
    refresh_shell_path
    
    # Multi-strategy verification
    local claunch_path=""
    local verification_attempts=3
    local attempt=1
    
    while [[ $attempt -le $verification_attempts ]]; do
        log_info "Verification attempt $attempt/$verification_attempts"
        
        if has_command claunch; then
            claunch_path=$(command -v claunch)
            log_info "Found claunch via command: $claunch_path"
            break
        elif [[ -x "$INSTALL_TARGET/claunch" ]]; then
            claunch_path="$INSTALL_TARGET/claunch"
            log_info "Found claunch at install target: $claunch_path"
            break
        else
            # Check common paths
            local common_paths=("$HOME/.local/bin/claunch" "$HOME/bin/claunch" "/usr/local/bin/claunch")
            local found_alt=false
            
            for path in "${common_paths[@]}"; do
                if [[ -x "$path" ]]; then
                    claunch_path="$path"
                    log_info "Found claunch at alternative path: $claunch_path"
                    found_alt=true
                    break
                fi
            done
            
            if [[ "$found_alt" == "true" ]]; then
                break
            fi
        fi
        
        if [[ $attempt -lt $verification_attempts ]]; then
            log_info "claunch not found, waiting 2s and refreshing environment..."
            sleep 2
            refresh_shell_path
        fi
        
        ((attempt++))
    done
    
    if [[ -z "$claunch_path" ]]; then
        log_error "claunch command not found after installation and verification attempts"
        log_error "Please check if $INSTALL_TARGET is in your PATH or restart your terminal"
        return 1
    fi
    
    log_info "claunch found at: $claunch_path"
    
    # Teste Basis-Funktionalität
    local version_output
    if version_output=$("$claunch_path" --version 2>&1); then
        log_info "claunch version: $version_output"
    else
        log_warn "Could not determine claunch version"
    fi
    
    # Teste Hilfe-Kommando
    if "$claunch_path" --help >/dev/null 2>&1; then
        log_info "claunch help command works"
    else
        log_warn "claunch help command failed"
    fi
    
    # Teste list-Kommando
    if "$claunch_path" list >/dev/null 2>&1; then
        log_info "claunch list command works"
    else
        log_warn "claunch list command failed (may be normal if no sessions exist)"
    fi
    
    log_info "claunch installation verification completed"
    return 0
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
    --method METHOD         Installation method: npm, source, auto (default: auto)
    --target DIR           Installation target directory (default: $INSTALL_TARGET)
    --force                Force reinstallation if claunch already exists
    --skip-deps            Skip dependency installation
    --no-verify            Skip installation verification
    --debug                Enable debug output
    -h, --help             Show this help message
    --version              Show version information

INSTALLATION METHODS:
    npm         Install via npm package manager (recommended)
    source      Install from GitHub source repository
    auto        Try npm first, then source (default)

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
                    log_error "Option $1 requires a method (npm, source, auto)"
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
        "npm"|"source"|"auto") ;;
        *)
            log_error "Invalid installation method: $INSTALL_METHOD"
            log_error "Valid methods: npm, source, auto"
            exit 1
            ;;
    esac
    
    log_debug "Configuration:"
    log_debug "  INSTALL_METHOD=$INSTALL_METHOD"
    log_debug "  INSTALL_TARGET=$INSTALL_TARGET"
    log_debug "  FORCE_REINSTALL=$FORCE_REINSTALL"
    log_debug "  SKIP_DEPENDENCIES=$SKIP_DEPENDENCIES"
    log_debug "  VERIFY_INSTALLATION=$VERIFY_INSTALLATION"
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
    
    # Installiere claunch
    if install_claunch; then
        log_info "claunch installation successful!"
    else
        log_error "claunch installation failed"
        exit 1
    fi
    
    # Ensure PATH configuration (addresses GitHub issue #4)
    ensure_path_configuration
    
    # Verifiziere Installation
    if [[ "$VERIFY_INSTALLATION" == "true" ]]; then
        if ! verify_installation; then
            log_error "Installation verification failed"
            exit 1
        fi
    fi
    
    echo ""
    log_info "claunch installation completed successfully!"
    log_info ""
    log_info "You can now use claunch for Claude CLI session management:"
    log_info "  claunch                    # Start Claude in current project"
    log_info "  claunch --tmux            # Start with tmux persistence"
    log_info "  claunch list              # List active sessions"
    log_info "  claunch clean             # Clean up orphaned sessions"
    log_info ""
    log_info "For more information, visit: https://github.com/0xkaz/claunch"
}

# Führe main nur aus wenn Skript direkt aufgerufen wird
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi