#!/usr/bin/env bash

# Claude Auto-Resume - Development Environment Setup Script
# Entwicklungsumgebung-Setup für das Claude Auto-Resume System
# Version: 1.0.0-alpha
# Letzte Aktualisierung: 2025-08-05

set -euo pipefail

# ===============================================================================
# GLOBALE VARIABLEN UND KONSTANTEN
# ===============================================================================

readonly SCRIPT_NAME="dev-setup"
readonly VERSION="1.0.0-alpha"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Development-Tools-Konfiguration
INSTALL_ALL_TOOLS=false
INSTALL_SHELLCHECK=false
INSTALL_BATS=false
INSTALL_SHFMT=false
SKIP_GIT_HOOKS=false
FORCE_REINSTALL=false
DRY_RUN=false
INTERACTIVE_MODE=true

# Pre-commit-Hook-Konfiguration
ENABLE_PRECOMMIT_HOOKS=true
HOOK_TYPES=("shellcheck" "syntax-check" "test-runner")

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
# DEVELOPMENT-TOOLS-INSTALLATION
# ===============================================================================

# Installiere ShellCheck
install_shellcheck() {
    log_step "Installing ShellCheck for shell script linting"
    
    if has_command shellcheck && [[ "$FORCE_REINSTALL" != "true" ]]; then
        log_info "ShellCheck already installed: $(shellcheck --version | head -1)"
        return 0
    fi
    
    local os pkg_manager
    os=$(detect_os)
    pkg_manager=$(detect_package_manager)
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would install ShellCheck"
        return 0
    fi
    
    case "$os" in
        "macos")
            if [[ "$pkg_manager" == "brew" ]]; then
                brew install shellcheck
            else
                log_error "Homebrew not found. Please install ShellCheck manually:"
                log_error "  https://github.com/koalaman/shellcheck#installing"
                return 1
            fi
            ;;
        "linux")
            case "$pkg_manager" in
                "apt")
                    sudo apt-get update
                    sudo apt-get install -y shellcheck
                    ;;
                "yum"|"dnf")
                    sudo "$pkg_manager" install -y ShellCheck
                    ;;
                "pacman")
                    sudo pacman -S shellcheck
                    ;;
                *)
                    log_error "No supported package manager for ShellCheck installation"
                    log_error "Please install manually: https://github.com/koalaman/shellcheck#installing"
                    return 1
                    ;;
            esac
            ;;
        *)
            log_error "Unsupported OS for automatic ShellCheck installation"
            log_error "Please install manually: https://github.com/koalaman/shellcheck#installing"
            return 1
            ;;
    esac
    
    if has_command shellcheck; then
        log_success "ShellCheck installed successfully: $(shellcheck --version | head -1)"
    else
        log_error "ShellCheck installation failed"
        return 1
    fi
}

# Installiere BATS
install_bats() {
    log_step "Installing BATS (Bash Automated Testing System)"
    
    if has_command bats && [[ "$FORCE_REINSTALL" != "true" ]]; then
        log_info "BATS already installed: $(bats --version)"
        return 0
    fi
    
    local os pkg_manager
    os=$(detect_os)
    pkg_manager=$(detect_package_manager)
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would install BATS"
        return 0
    fi
    
    case "$os" in
        "macos")
            if [[ "$pkg_manager" == "brew" ]]; then
                brew install bats-core
            else
                log_error "Homebrew not found. Installing BATS from source..."
                install_bats_from_source
            fi
            ;;
        "linux")
            case "$pkg_manager" in
                "apt")
                    # Ubuntu/Debian - oft veraltete Version in Repos
                    log_info "Installing BATS from source for latest version"
                    install_bats_from_source
                    ;;
                *)
                    log_info "Installing BATS from source"
                    install_bats_from_source
                    ;;
            esac
            ;;
        *)
            log_info "Installing BATS from source"
            install_bats_from_source
            ;;
    esac
    
    if has_command bats; then
        log_success "BATS installed successfully: $(bats --version)"
    else
        log_error "BATS installation failed"
        return 1
    fi
}

# Installiere BATS von Source
install_bats_from_source() {
    log_info "Installing BATS from GitHub source"
    
    if ! has_command git; then
        log_error "Git required for source installation"
        return 1
    fi
    
    local temp_dir
    temp_dir=$(mktemp -d)
    local original_dir
    original_dir=$(pwd)
    
    cleanup_bats_temp() {
        cd "$original_dir"
        rm -rf "$temp_dir"
    }
    
    trap cleanup_bats_temp EXIT
    
    log_info "Cloning BATS repository to: $temp_dir"
    
    if ! git clone https://github.com/bats-core/bats-core.git "$temp_dir"; then
        log_error "Failed to clone BATS repository"
        return 1
    fi
    
    cd "$temp_dir"
    
    # Installiere nach /usr/local oder $HOME/bin
    local install_prefix
    if [[ -w "/usr/local" ]]; then
        install_prefix="/usr/local"
    else
        install_prefix="$HOME/.local"
        mkdir -p "$install_prefix"
    fi
    
    log_info "Installing BATS to: $install_prefix"
    
    if ./install.sh "$install_prefix"; then
        # Füge zu PATH hinzu falls nötig
        local bin_dir="$install_prefix/bin"
        if [[ ":$PATH:" != *":$bin_dir:"* ]]; then
            log_info "Add $bin_dir to your PATH by adding this to your shell profile:"
            log_info "  echo 'export PATH=\"$bin_dir:\$PATH\"' >> ~/.bashrc"
        fi
        
        log_success "BATS installed from source"
        return 0
    else
        log_error "BATS source installation failed"
        return 1
    fi
}

# Installiere shfmt (Shell-Formatter)
install_shfmt() {
    log_step "Installing shfmt for shell script formatting"
    
    if has_command shfmt && [[ "$FORCE_REINSTALL" != "true" ]]; then
        log_info "shfmt already installed: $(shfmt --version)"
        return 0
    fi
    
    local os pkg_manager
    os=$(detect_os)
    pkg_manager=$(detect_package_manager)
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would install shfmt"
        return 0
    fi
    
    case "$os" in
        "macos")
            if [[ "$pkg_manager" == "brew" ]]; then
                brew install shfmt
            else
                install_shfmt_binary
            fi
            ;;
        "linux")
            case "$pkg_manager" in
                "apt")
                    # shfmt meist nicht in Standard-Repos
                    install_shfmt_binary
                    ;;
                *)
                    install_shfmt_binary
                    ;;
            esac
            ;;
        *)
            install_shfmt_binary
            ;;
    esac
    
    if has_command shfmt; then
        log_success "shfmt installed successfully: $(shfmt --version)"
    else
        log_error "shfmt installation failed"
        return 1
    fi
}

# Installiere shfmt Binary
install_shfmt_binary() {
    log_info "Installing shfmt binary from GitHub releases"
    
    local os arch install_dir binary_name
    os=$(detect_os)
    
    case "$(uname -m)" in
        x86_64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) log_error "Unsupported architecture"; return 1 ;;
    esac
    
    case "$os" in
        "macos") binary_name="shfmt_v3.7.0_darwin_${arch}" ;;
        "linux") binary_name="shfmt_v3.7.0_linux_${arch}" ;;
        *) log_error "Unsupported OS for binary installation"; return 1 ;;
    esac
    
    # Bestimme Installationsverzeichnis
    if [[ -w "/usr/local/bin" ]]; then
        install_dir="/usr/local/bin"
    else
        install_dir="$HOME/bin"
        mkdir -p "$install_dir"
    fi
    
    local download_url="https://github.com/mvdan/sh/releases/download/v3.7.0/$binary_name"
    local target_path="$install_dir/shfmt"
    
    log_info "Downloading shfmt from: $download_url"
    
    if curl -fsSL -o "$target_path" "$download_url"; then
        chmod +x "$target_path"
        
        # PATH-Hinweis falls nötig
        if [[ ":$PATH:" != *":$install_dir:"* ]]; then
            log_info "Add $install_dir to your PATH if needed"
        fi
        
        log_success "shfmt binary installed to: $target_path"
        return 0
    else
        log_error "Failed to download shfmt binary"
        return 1
    fi
}

# ===============================================================================
# GIT-HOOKS-SETUP
# ===============================================================================

# Erstelle Pre-commit-Hook
create_precommit_hook() {
    log_step "Creating pre-commit Git hooks"
    
    local git_hooks_dir="$PROJECT_ROOT/.git/hooks"
    local precommit_hook="$git_hooks_dir/pre-commit"
    
    if [[ ! -d "$PROJECT_ROOT/.git" ]]; then
        log_warn "Not in a Git repository - skipping Git hooks"
        return 0
    fi
    
    if [[ -f "$precommit_hook" ]] && [[ "$FORCE_REINSTALL" != "true" ]]; then
        if ! ask_yes_no "Pre-commit hook already exists. Replace it?" "n"; then
            log_info "Keeping existing pre-commit hook"
            return 0
        fi
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create pre-commit hook at: $precommit_hook"
        return 0
    fi
    
    log_info "Creating pre-commit hook: $precommit_hook"
    
    cat > "$precommit_hook" << 'EOF'
#!/usr/bin/env bash

# Claude Auto-Resume - Pre-commit Hook
# Automatische Code-Qualitätsprüfungen vor jedem Commit

set -e

echo "Running pre-commit checks..."

# Finde alle geänderten Shell-Dateien
changed_shell_files=$(git diff --cached --name-only --diff-filter=ACM | grep '\.sh$' || true)

if [[ -z "$changed_shell_files" ]]; then
    echo "No shell files changed - skipping shell checks"
    exit 0
fi

echo "Checking shell files: $changed_shell_files"

# ShellCheck-Prüfung
if command -v shellcheck >/dev/null 2>&1; then
    echo "Running ShellCheck..."
    for file in $changed_shell_files; do
        if [[ -f "$file" ]]; then
            echo "  Checking: $file"
            shellcheck "$file" || {
                echo "ShellCheck failed for: $file"
                echo "Fix the issues above or use 'git commit --no-verify' to skip checks"
                exit 1
            }
        fi
    done
    echo "✓ ShellCheck passed"
else
    echo "⚠ ShellCheck not available - install for better code quality"
fi

# Syntax-Check
echo "Running syntax checks..."
for file in $changed_shell_files; do
    if [[ -f "$file" ]]; then
        echo "  Syntax check: $file"
        bash -n "$file" || {
            echo "Syntax error in: $file"
            exit 1
        }
    fi
done
echo "✓ Syntax checks passed"

# Formatierung mit shfmt (falls verfügbar)
if command -v shfmt >/dev/null 2>&1; then
    echo "Running shfmt format check..."
    for file in $changed_shell_files; do
        if [[ -f "$file" ]]; then
            # Prüfe ob Datei korrekt formatiert ist
            if ! shfmt -d "$file" >/dev/null 2>&1; then
                echo "File not properly formatted: $file"
                echo "Run: shfmt -w $file"
                echo "Or use 'git commit --no-verify' to skip format checks"
                exit 1
            fi
        fi
    done
    echo "✓ Format checks passed"
fi

# Führe Tests aus falls vorhanden
if [[ -d "tests" ]] && command -v bats >/dev/null 2>&1; then
    echo "Running tests..."
    if ! bats tests/; then
        echo "Tests failed - fix before committing"
        exit 1
    fi
    echo "✓ Tests passed"
fi

echo "All pre-commit checks passed! 🎉"
EOF
    
    chmod +x "$precommit_hook"
    log_success "Pre-commit hook created and made executable"
    
    # Test-Hook
    log_info "Testing pre-commit hook..."
    if "$precommit_hook"; then
        log_success "Pre-commit hook test passed"
    else
        log_warn "Pre-commit hook test failed - please check manually"
    fi
}

# Erstelle Post-commit-Hook für Dokumentations-Updates
create_postcommit_hook() {
    log_step "Creating post-commit Git hook"
    
    local git_hooks_dir="$PROJECT_ROOT/.git/hooks"
    local postcommit_hook="$git_hooks_dir/post-commit"
    
    if [[ ! -d "$PROJECT_ROOT/.git" ]]; then
        return 0
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create post-commit hook"
        return 0
    fi
    
    log_info "Creating post-commit hook: $postcommit_hook"
    
    cat > "$postcommit_hook" << 'EOF'
#!/usr/bin/env bash

# Claude Auto-Resume - Post-commit Hook
# Automatische Aktionen nach erfolgreichem Commit

# Aktualisiere Last-Updated-Datum in CLAUDE.md
if [[ -f "CLAUDE.md" ]]; then
    current_date=$(date +%Y-%m-%d)
    sed -i.bak "s/\*\*Letzte Aktualisierung\*\*:.*/\*\*Letzte Aktualisierung\*\*: $current_date/" CLAUDE.md 2>/dev/null || true
    rm -f CLAUDE.md.bak
fi

# Log commit für Entwicklungsstatistiken
echo "$(date): Commit $(git rev-parse HEAD)" >> .git/commit-log 2>/dev/null || true
EOF
    
    chmod +x "$postcommit_hook"
    log_success "Post-commit hook created"
}

# ===============================================================================
# ENTWICKLUNGSUMGEBUNG-SETUP
# ===============================================================================

# Erstelle Development-Scripts
create_dev_scripts() {
    log_step "Creating development utility scripts"
    
    local scripts_dir="$PROJECT_ROOT/scripts"
    
    # Lint-Script
    local lint_script="$scripts_dir/lint.sh"
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create $lint_script"
    else
        log_info "Creating lint script: $lint_script"
        cat > "$lint_script" << 'EOF'
#!/usr/bin/env bash

# Claude Auto-Resume - Lint Script
# Führt alle Linting-Tools aus

set -e

echo "🔍 Running code linting..."

# ShellCheck
if command -v shellcheck >/dev/null 2>&1; then
    echo "Running ShellCheck on all shell files..."
    find . -name "*.sh" -type f -exec shellcheck {} +
    echo "✅ ShellCheck completed"
else
    echo "⚠️  ShellCheck not available"
fi

# shfmt
if command -v shfmt >/dev/null 2>&1; then
    echo "Checking shell script formatting..."
    if shfmt -d $(find . -name "*.sh" -type f); then
        echo "✅ All files properly formatted"
    else
        echo "❌ Some files need formatting - run: shfmt -w \$(find . -name \"*.sh\" -type f)"
        exit 1
    fi
else
    echo "⚠️  shfmt not available"
fi

echo "🎉 Linting completed successfully!"
EOF
        chmod +x "$lint_script"
    fi
    
    # Test-Runner-Script
    local test_script="$scripts_dir/run-tests.sh"
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create $test_script"
    else
        log_info "Creating test runner script: $test_script"
        cat > "$test_script" << 'EOF'
#!/usr/bin/env bash

# Claude Auto-Resume - Test Runner Script
# Führt alle Tests aus

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "🧪 Running test suite..."

# Bestimme Test-Art
TEST_TYPE="${1:-all}"

case "$TEST_TYPE" in
    "unit")
        echo "Running unit tests..."
        if [[ -d "$PROJECT_ROOT/tests/unit" ]] && command -v bats >/dev/null 2>&1; then
            bats "$PROJECT_ROOT/tests/unit/"*.bats
        else
            echo "No unit tests found or BATS not available"
        fi
        ;;
    "integration")
        echo "Running integration tests..."
        if [[ -d "$PROJECT_ROOT/tests/integration" ]] && command -v bats >/dev/null 2>&1; then
            bats "$PROJECT_ROOT/tests/integration/"*.bats
        else
            echo "No integration tests found or BATS not available"
        fi
        ;;
    "all"|*)
        echo "Running all tests..."
        if [[ -d "$PROJECT_ROOT/tests" ]] && command -v bats >/dev/null 2>&1; then
            bats "$PROJECT_ROOT/tests/"**/*.bats
        else
            echo "No tests found or BATS not available"
            
            # Fallback: Syntax-Tests
            echo "Running syntax tests as fallback..."
            find "$PROJECT_ROOT" -name "*.sh" -type f -exec bash -n {} \;
            echo "✅ All scripts have valid syntax"
        fi
        ;;
esac

echo "🎉 Test suite completed!"
EOF
        chmod +x "$test_script"
    fi
    
    # Format-Script
    local format_script="$scripts_dir/format.sh"
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create $format_script"
    else
        log_info "Creating format script: $format_script"
        cat > "$format_script" << 'EOF'
#!/usr/bin/env bash

# Claude Auto-Resume - Format Script
# Formatiert alle Shell-Skripte

set -e

echo "🎨 Formatting shell scripts..."

if ! command -v shfmt >/dev/null 2>&1; then
    echo "❌ shfmt not available - cannot format scripts"
    echo "Install with: brew install shfmt (macOS) or download from GitHub"
    exit 1
fi

# Formatiere alle Shell-Dateien
find . -name "*.sh" -type f -exec shfmt -w -i 4 -ci {} +

echo "✅ All shell scripts formatted!"
echo "💡 Consider running: git add . && git commit -m 'Format shell scripts'"
EOF
        chmod +x "$format_script"
    fi
    
    log_success "Development scripts created"
}

# Erstelle EditorConfig
create_editorconfig() {
    log_step "Creating EditorConfig for consistent code style"
    
    local editorconfig="$PROJECT_ROOT/.editorconfig"
    
    if [[ -f "$editorconfig" ]] && [[ "$FORCE_REINSTALL" != "true" ]]; then
        if ! ask_yes_no "EditorConfig already exists. Replace it?" "n"; then
            log_info "Keeping existing EditorConfig"
            return 0
        fi
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create .editorconfig"
        return 0
    fi
    
    log_info "Creating EditorConfig: $editorconfig"
    
    cat > "$editorconfig" << 'EOF'
# EditorConfig for Claude Auto-Resume Project
# See: https://editorconfig.org/

root = true

[*]
charset = utf-8
end_of_line = lf
insert_final_newline = true
trim_trailing_whitespace = true
indent_style = space
indent_size = 4

[*.sh]
indent_style = space
indent_size = 4
max_line_length = 120

[*.{yml,yaml}]
indent_style = space
indent_size = 2

[*.{md,markdown}]
trim_trailing_whitespace = false
max_line_length = 80

[*.{json,conf}]
indent_style = space
indent_size = 2

[Makefile]
indent_style = tab
EOF
    
    log_success "EditorConfig created"
}

# Erstelle Development-Konfigurationsdatei
create_dev_config() {
    log_step "Creating development configuration"
    
    local dev_config="$PROJECT_ROOT/.development.conf"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create .development.conf"
        return 0
    fi
    
    log_info "Creating development configuration: $dev_config"
    
    cat > "$dev_config" << 'EOF'
# Development Environment Configuration
# This file is used by development tools and scripts

# Code Style
SHELL_INDENT_SIZE=4
MAX_LINE_LENGTH=120
FORMAT_ON_SAVE=true

# Testing
RUN_TESTS_ON_COMMIT=true
TEST_TIMEOUT=300

# Linting
ENABLE_SHELLCHECK=true
ENABLE_SYNTAX_CHECK=true
SHELLCHECK_SEVERITY=error

# Development Tools Paths
# Leave empty to use system PATH
SHELLCHECK_PATH=""
BATS_PATH=""
SHFMT_PATH=""

# Git Hooks
ENABLE_PRECOMMIT_HOOKS=true
ENABLE_POSTCOMMIT_HOOKS=true

# Debug Settings
DEBUG_MODE=false
VERBOSE_OUTPUT=false
EOF
    
    log_success "Development configuration created"
}

# ===============================================================================
# COMMAND-LINE-INTERFACE
# ===============================================================================

# Zeige Hilfe
show_help() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS]

Set up development environment for Claude Auto-Resume project.

OPTIONS:
    --all                   Install all development tools
    --shellcheck            Install ShellCheck (shell script linter)
    --bats                  Install BATS (testing framework)
    --shfmt                 Install shfmt (shell formatter)
    --no-git-hooks          Skip Git hooks setup
    --force                 Force reinstall of existing tools
    --dry-run               Preview actions without executing them
    --non-interactive       Run without user interaction
    --debug                 Enable debug output
    -h, --help              Show this help message
    --version               Show version information

DEVELOPMENT TOOLS:
    ShellCheck      Lints shell scripts for common issues
    BATS            Bash Automated Testing System
    shfmt           Formats shell scripts consistently

GIT HOOKS:
    pre-commit      Runs linting and syntax checks before commits
    post-commit     Updates documentation timestamps

EXAMPLES:
    # Install all development tools
    $SCRIPT_NAME --all

    # Install specific tools
    $SCRIPT_NAME --shellcheck --bats

    # Setup without Git hooks
    $SCRIPT_NAME --all --no-git-hooks

    # Preview what would be done
    $SCRIPT_NAME --all --dry-run --debug

The script creates development utility scripts in the scripts/ directory:
  - scripts/lint.sh      - Run all linting tools
  - scripts/run-tests.sh - Run test suite
  - scripts/format.sh    - Format all shell scripts

For best development experience, install all tools with --all flag.
EOF
}

# Zeige Versionsinformation
show_version() {
    echo "$SCRIPT_NAME version $VERSION"
    echo "Claude Auto-Resume Development Environment Setup"
}

# Parse Kommandozeilen-Argumente
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all)
                INSTALL_ALL_TOOLS=true
                INSTALL_SHELLCHECK=true
                INSTALL_BATS=true
                INSTALL_SHFMT=true
                shift
                ;;
            --shellcheck)
                INSTALL_SHELLCHECK=true
                shift
                ;;
            --bats)
                INSTALL_BATS=true
                shift
                ;;
            --shfmt)
                INSTALL_SHFMT=true
                shift
                ;;
            --no-git-hooks)
                SKIP_GIT_HOOKS=true
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
    log_debug "  INSTALL_ALL_TOOLS=$INSTALL_ALL_TOOLS"
    log_debug "  INSTALL_SHELLCHECK=$INSTALL_SHELLCHECK"
    log_debug "  INSTALL_BATS=$INSTALL_BATS"
    log_debug "  INSTALL_SHFMT=$INSTALL_SHFMT"
    log_debug "  SKIP_GIT_HOOKS=$SKIP_GIT_HOOKS"
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
    echo "│          Claude Auto-Resume Development Setup              │"
    echo "│                     Version $VERSION                        │"
    echo "╰─────────────────────────────────────────────────────────────╯"
    echo
    log_info "Setting up development environment for Claude Auto-Resume"
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
    echo "│              Development Setup Completed!                  │"
    echo "╰─────────────────────────────────────────────────────────────╯"
    echo
    log_success "Development environment has been successfully set up!"
    echo
    log_info "Available development commands:"
    log_info "  scripts/lint.sh           - Run all linting tools"
    log_info "  scripts/run-tests.sh      - Run test suite"  
    log_info "  scripts/format.sh         - Format shell scripts"
    echo
    log_info "Git hooks installed:"
    log_info "  pre-commit                - Automatic code quality checks"
    log_info "  post-commit               - Documentation updates"
    echo
    log_info "Development workflow:"
    log_info "  1. Edit code with your favorite editor"
    log_info "  2. Run ./scripts/lint.sh to check code quality"
    log_info "  3. Run ./scripts/run-tests.sh to run tests"
    log_info "  4. Format with ./scripts/format.sh if needed"
    log_info "  5. Commit - hooks will run automatically"
    echo
    if has_command shellcheck && has_command bats; then
        log_success "All development tools are available! 🎉"
    else
        log_warn "Some development tools are missing - install for full experience"
    fi
    echo
}

main() {
    # Parse Argumente
    parse_arguments "$@"
    
    # Header anzeigen
    show_header
    
    # Interaktive Tool-Auswahl falls nicht spezifiziert
    if [[ "$INTERACTIVE_MODE" == "true" ]] && \
       [[ "$INSTALL_ALL_TOOLS" != "true" ]] && \
       [[ "$INSTALL_SHELLCHECK" != "true" ]] && \
       [[ "$INSTALL_BATS" != "true" ]] && \
       [[ "$INSTALL_SHFMT" != "true" ]]; then
        
        echo "Development tools to install:"
        echo
        
        if ask_yes_no "Install ShellCheck (shell script linter)?" "y"; then
            INSTALL_SHELLCHECK=true
        fi
        
        if ask_yes_no "Install BATS (testing framework)?" "y"; then
            INSTALL_BATS=true
        fi
        
        if ask_yes_no "Install shfmt (shell formatter)?" "y"; then
            INSTALL_SHFMT=true
        fi
        
        echo
    fi
    
    # Setup-Schritte ausführen
    local failed_steps=0
    
    # Schritt 1: Development Tools installieren
    if [[ "$INSTALL_SHELLCHECK" == "true" ]] || [[ "$INSTALL_ALL_TOOLS" == "true" ]]; then
        if ! install_shellcheck; then
            ((failed_steps++))
            log_error "ShellCheck installation failed"
        fi
    fi
    
    if [[ "$INSTALL_BATS" == "true" ]] || [[ "$INSTALL_ALL_TOOLS" == "true" ]]; then
        if ! install_bats; then
            ((failed_steps++))
            log_error "BATS installation failed"
        fi
    fi
    
    if [[ "$INSTALL_SHFMT" == "true" ]] || [[ "$INSTALL_ALL_TOOLS" == "true" ]]; then
        if ! install_shfmt; then
            ((failed_steps++))
            log_error "shfmt installation failed"
        fi
    fi
    
    # Schritt 2: Development Scripts erstellen
    if ! create_dev_scripts; then
        ((failed_steps++))
        log_error "Development scripts creation failed"
    fi
    
    # Schritt 3: Konfigurationsdateien erstellen
    if ! create_editorconfig; then
        log_warn "EditorConfig creation had issues"
    fi
    
    if ! create_dev_config; then
        log_warn "Development configuration creation had issues"
    fi
    
    # Schritt 4: Git Hooks (falls nicht übersprungen)
    if [[ "$SKIP_GIT_HOOKS" != "true" ]]; then
        if ! create_precommit_hook; then
            log_warn "Pre-commit hook creation had issues"
        fi
        
        if ! create_postcommit_hook; then
            log_warn "Post-commit hook creation had issues"
        fi
    fi
    
    # Zusammenfassung
    if [[ $failed_steps -eq 0 ]]; then
        show_summary
        exit 0
    else
        echo
        log_error "Development setup completed with $failed_steps failed step(s)"
        log_error "Please check the error messages above and re-run setup if needed"
        exit 1
    fi
}

# Führe main nur aus wenn Skript direkt aufgerufen wird
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi