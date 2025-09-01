#!/usr/bin/env bash

# Claude Auto-Resume - Environment Debug Script
# Comprehensive environment validation and diagnostics
# Version: 1.0.0

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m' 
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
print_header() {
    echo -e "\n${BLUE}=== $1 ===${NC}"
}

print_success() {
    echo -e "  ${GREEN}✅ $1${NC}"
}

print_warning() {
    echo -e "  ${YELLOW}⚠️  $1${NC}"
}

print_error() {
    echo -e "  ${RED}❌ $1${NC}"
}

check_command() {
    local cmd="$1"
    local description="$2"
    local version_flag="${3:-}"
    
    if command -v "$cmd" >/dev/null 2>&1; then
        location=$(command -v "$cmd")
        if [[ -n "$version_flag" ]]; then
            version=$($cmd $version_flag 2>&1 | head -1 || echo "Unknown")
            print_success "$description: $location ($version)"
        else
            print_success "$description: $location"
        fi
        return 0
    else
        print_error "$description: NOT FOUND"
        return 1
    fi
}

print_header "Environment Diagnostics - $(date)"

# System Information
print_header "System Information"
echo -e "  OS: $(uname -s) $(uname -r)"
echo -e "  Architecture: $(uname -m)"
echo -e "  Shell: $SHELL"
echo -e "  User: $USER"
echo -e "  Hostname: $(hostname)"
echo -e "  Working Directory: $(pwd)"

# Core Dependencies
print_header "Core Dependencies"
check_command "bash" "Bash" "--version"
check_command "git" "Git" "--version" 
check_command "gh" "GitHub CLI" "--version"
check_command "tmux" "tmux" "-V"
check_command "claude" "Claude CLI" "--version"

# Optional Dependencies  
print_header "Optional Dependencies"
check_command "claunch" "claunch" "--version" || print_warning "claunch not found (optional)"
check_command "jq" "jq" "--version" || print_warning "jq not found (optional)"
check_command "curl" "curl" "--version" || print_warning "curl not found (optional)"

# Development Tools
print_header "Development Tools"
check_command "shellcheck" "ShellCheck" "--version" || print_warning "ShellCheck not found (recommended for development)"
check_command "bats" "Bats" "--version" || print_error "Bats not found (required for testing)"
check_command "make" "Make" "--version" || print_warning "Make not found (optional, for Makefile targets)"

# Git Repository Status
print_header "Git Repository Status"
if git rev-parse --git-dir >/dev/null 2>&1; then
    print_success "Git repository detected"
    echo -e "  Current branch: $(git branch --show-current)"
    echo -e "  Repository root: $(git rev-parse --show-toplevel)"
    
    modified_files=$(git status --porcelain | wc -l)
    if [[ $modified_files -gt 0 ]]; then
        print_warning "$modified_files modified files in working directory"
        echo -e "    Staged files: $(git diff --cached --name-only | wc -l)"
        echo -e "    Unstaged files: $(git diff --name-only | wc -l)"
        echo -e "    Untracked files: $(git ls-files --others --exclude-standard | wc -l)"
    else
        print_success "Clean working directory"
    fi
    
    # Check for problematic files
    log_files=$(git status --porcelain | grep -E "logs/.*\.log|task-queue\.json" | wc -l || echo 0)
    if [[ $log_files -gt 0 ]]; then
        print_warning "$log_files log/runtime files in git status (should be ignored)"
        echo -e "    Run: make git-unstage-logs"
    fi
else
    print_error "Not in a git repository"
fi

# Project Structure
print_header "Project Structure"
for dir in src scripts tests logs queue; do
    if [[ -d "$dir" ]]; then
        print_success "$dir/ directory exists"
        # Use array to count files without subprocess overhead
        if ! mapfile -t dir_files < <(find "$dir" -type f 2>&1); then
            local find_error="$?"
            print_warning "File discovery failed in $dir: exit code $find_error"
            dir_files=()  # Initialize empty array on failure
        fi
        echo -e "    Files: ${#dir_files[@]}"
    else
        print_error "$dir/ directory missing"
    fi
done

# Key Files
print_header "Key Configuration Files"
for file in CLAUDE.md Makefile .gitignore; do
    if [[ -f "$file" ]]; then
        print_success "$file exists"
        echo -e "    Size: $(wc -l < "$file") lines"
    else
        print_warning "$file missing"
    fi
done

# Setup Wizard
print_header "Setup Wizard Status"
if [[ -f "src/setup-wizard.sh" ]]; then
    print_success "Setup wizard found"
    
    # Check syntax
    if bash -n src/setup-wizard.sh 2>/dev/null; then
        print_success "Setup wizard syntax valid"
    else
        print_error "Setup wizard has syntax errors"
    fi
    
    # Check modular architecture
    if [[ -d "src/wizard" ]]; then
        # Use array to avoid subprocess overhead
        if ! mapfile -t wizard_modules < <(find src/wizard -name "*.sh" -type f 2>&1); then
            local find_error="$?"
            print_warning "Wizard module discovery failed: exit code $find_error"
            wizard_modules=()  # Initialize empty array on failure
        fi
        module_count=${#wizard_modules[@]}
        print_success "Modular architecture available ($module_count modules)"
        for module in src/wizard/*.sh; do
            if [[ -f "$module" ]]; then
                module_name=$(basename "$module")
                if bash -n "$module" 2>/dev/null; then
                    echo -e "    ✓ $module_name (syntax OK)"
                else
                    echo -e "    ❌ $module_name (syntax error)"
                fi
            fi
        done
    else
        print_warning "Modular architecture not available (will use monolithic mode)"
    fi
else
    print_error "Setup wizard not found"
fi

# Testing Environment
print_header "Testing Environment"
if [[ -f "scripts/run-tests.sh" ]]; then
    print_success "Test runner found"
    
    # Check test structure - use arrays to avoid multiple subprocess calls
    # Discover test files with robust error handling
    if ! mapfile -t unit_test_files < <(find tests/unit -name "*.bats" -type f 2>&1); then
        print_warning "Unit test discovery failed - directory may not exist"
        unit_test_files=()
    fi
    
    if ! mapfile -t integration_test_files < <(find tests/integration -name "*.bats" -type f 2>&1); then
        print_warning "Integration test discovery failed - directory may not exist"  
        integration_test_files=()
    fi
    unit_tests=${#unit_test_files[@]}
    integration_tests=${#integration_test_files[@]}
    
    echo -e "    Unit tests: $unit_tests"
    echo -e "    Integration tests: $integration_tests"
    
    if [[ $unit_tests -eq 0 && $integration_tests -eq 0 ]]; then
        print_warning "No test files found"
    fi
else
    print_error "Test runner not found"
fi

# Network Connectivity (for Claude CLI)
print_header "Network Connectivity"
if command -v curl >/dev/null 2>&1; then
    if curl -s --max-time 5 https://api.anthropic.com >/dev/null 2>&1; then
        print_success "Anthropic API reachable"
    else
        print_warning "Anthropic API not reachable (check network/firewall)"
    fi
else
    print_warning "Cannot test network (curl not available)"
fi

# tmux Sessions
print_header "tmux Sessions"
if command -v tmux >/dev/null 2>&1; then
    session_count=$(tmux list-sessions 2>/dev/null | wc -l || echo 0)
    if [[ $session_count -gt 0 ]]; then
        print_success "$session_count active tmux sessions"
        tmux list-sessions 2>/dev/null | while read -r line; do
            echo -e "    • $line"
        done
    else
        echo -e "  ${BLUE}ℹ️  No active tmux sessions${NC}"
    fi
else
    print_error "tmux not available"
fi

# Disk Space
print_header "Disk Space"
echo -e "  Project directory usage:"
du -sh . 2>/dev/null | sed 's/^/    /'
echo -e "  Available space:"
df -h . 2>/dev/null | tail -1 | awk '{print "    " $4 " available (" $5 " used)"}' || echo "    Cannot determine disk space"

# Permissions
print_header "Permissions"
for script in src/*.sh scripts/*.sh; do
    if [[ -f "$script" ]]; then
        if [[ -x "$script" ]]; then
            echo -e "  ${GREEN}✓${NC} $script (executable)"
        else
            print_warning "$script (not executable - may need: chmod +x $script)"
        fi
    fi
done

# Summary
print_header "Environment Summary"
echo -e "  ${BLUE}Environment Status:${NC}"

# Count issues
critical_issues=0
warnings=0

# Critical: missing core dependencies
command -v bash >/dev/null 2>&1 || ((critical_issues++))
command -v git >/dev/null 2>&1 || ((critical_issues++))
command -v tmux >/dev/null 2>&1 || ((critical_issues++))
command -v claude >/dev/null 2>&1 || ((critical_issues++))
command -v bats >/dev/null 2>&1 || ((critical_issues++))

# Warnings: missing optional tools
command -v shellcheck >/dev/null 2>&1 || ((warnings++))
command -v jq >/dev/null 2>&1 || ((warnings++))
command -v claunch >/dev/null 2>&1 || ((warnings++))

if [[ $critical_issues -eq 0 ]]; then
    print_success "Environment ready for development"
else
    print_error "$critical_issues critical issues found"
fi

if [[ $warnings -gt 0 ]]; then
    print_warning "$warnings optional tools missing (development experience may be limited)"
fi

echo -e "\n${BLUE}Next steps:${NC}"
if [[ $critical_issues -gt 0 ]]; then
    echo -e "  1. Install missing critical dependencies"
    echo -e "  2. Run: make setup"
fi

if [[ $warnings -gt 0 ]]; then
    echo -e "  • Consider installing optional tools for better development experience"
fi

echo -e "  • Run: make test  # to test the environment"
echo -e "  • Run: make help  # to see all available commands"

echo -e "\n${GREEN}Diagnostics complete!${NC}"