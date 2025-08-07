#!/bin/bash

# Claude Auto-Resume - Comprehensive Test Runner
# Führt alle Tests aus mit detaillierter Berichterstattung
# Version: 1.0.0-alpha
# Letzte Aktualisierung: 2025-08-05

set -euo pipefail

# ===============================================================================
# GLOBALE VARIABLEN UND KONSTANTEN
# ===============================================================================

readonly SCRIPT_NAME="run-tests"
readonly VERSION="1.0.0-alpha"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Test-Konfiguration
TEST_TYPE="all"
VERBOSE_OUTPUT=false
GENERATE_COVERAGE=false
STOP_ON_FAILURE=false
PARALLEL_TESTS=false
TEST_TIMEOUT=300
DRY_RUN=false
SKIP_BATS_TESTS=false

# Test-Statistiken
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
SKIPPED_TESTS=0
START_TIME=""
END_TIME=""

# ===============================================================================
# HILFSFUNKTIONEN
# ===============================================================================

# Logging-Funktionen
log_info() { echo -e "\e[32m[INFO]\e[0m $*"; }
log_warn() { echo -e "\e[33m[WARN]\e[0m $*" >&2; }
log_error() { echo -e "\e[31m[ERROR]\e[0m $*" >&2; }
log_debug() { [[ "$VERBOSE_OUTPUT" == "true" ]] && echo -e "\e[36m[DEBUG]\e[0m $*" >&2; }
log_success() { echo -e "\e[32m[SUCCESS]\e[0m $*"; }
log_step() { echo -e "\e[34m[STEP]\e[0m $*"; }

# Prüfe ob Kommando verfügbar ist
has_command() {
    command -v "$1" >/dev/null 2>&1
}

# Formatiere Zeitdauer
format_duration() {
    local duration="$1"
    local hours=$((duration / 3600))
    local minutes=$(((duration % 3600) / 60))
    local seconds=$((duration % 60))
    
    if [[ $hours -gt 0 ]]; then
        printf "%dh %dm %ds" "$hours" "$minutes" "$seconds"
    elif [[ $minutes -gt 0 ]]; then
        printf "%dm %ds" "$minutes" "$seconds"
    else
        printf "%ds" "$seconds"
    fi
}

# ===============================================================================
# TEST-DISCOVERY UND -VALIDIERUNG
# ===============================================================================

# Finde verfügbare Tests
discover_tests() {
    log_step "Discovering available tests"
    
    local test_dirs=()
    local test_files=()
    
    # Unit-Tests
    if [[ -d "$PROJECT_ROOT/tests/unit" ]]; then
        local unit_tests
        unit_tests=$(find "$PROJECT_ROOT/tests/unit" -name "*.bats" -type f 2>/dev/null || true)
        if [[ -n "$unit_tests" ]]; then
            test_dirs+=("unit")
            while IFS= read -r test_file; do
                test_files+=("$test_file")
            done <<< "$unit_tests"
        fi
    fi
    
    # Integration-Tests
    if [[ -d "$PROJECT_ROOT/tests/integration" ]]; then
        local integration_tests
        integration_tests=$(find "$PROJECT_ROOT/tests/integration" -name "*.bats" -type f 2>/dev/null || true)
        if [[ -n "$integration_tests" ]]; then
            test_dirs+=("integration")
            while IFS= read -r test_file; do
                test_files+=("$test_file")
            done <<< "$integration_tests"
        fi
    fi
    
    log_info "Found test directories: ${test_dirs[*]:-none}"
    log_info "Found ${#test_files[@]} test files"
    
    if [[ "$VERBOSE_OUTPUT" == "true" ]]; then
        for test_file in "${test_files[@]}"; do
            log_debug "  $(basename "$test_file")"
        done
    fi
    
    # Exportiere für andere Funktionen
    export TEST_DIRECTORIES="${test_dirs[*]}"
    export TEST_FILES_COUNT=${#test_files[@]}
}

# Validiere Test-Umgebung
validate_test_environment() {
    log_step "Validating test environment"
    
    local issues=0
    
    # Prüfe BATS
    if ! has_command bats; then
        log_error "BATS (Bash Automated Testing System) not found"
        log_error ""
        log_error "BATS is required for unit and integration tests."
        log_error "To install BATS:"
        log_error "  Quick setup:   ./scripts/setup.sh --dev"
        log_error "  macOS:         brew install bats-core"
        log_error "  Ubuntu:        sudo apt-get install bats"
        log_error "  CentOS:        sudo yum install bats"
        log_error "  Manual:        git clone https://github.com/bats-core/bats-core.git && ./bats-core/install.sh ~/.local"
        log_error ""
        log_info "Without BATS, only syntax and linting tests will run."
        log_info "This provides limited test coverage."
        ((issues++))
    else
        local bats_version
        bats_version=$(bats --version 2>/dev/null | head -1 || echo "unknown")
        log_info "BATS version: $bats_version"
        
        # Prüfe BATS-Funktionalität
        if ! bats --help >/dev/null 2>&1; then
            log_warn "BATS command found but not functioning properly"
            log_warn "Try reinstalling BATS: ./scripts/setup.sh --dev --force"
            ((issues++))
        else
            log_success "BATS is functional and ready for testing"
        fi
    fi
    
    # Prüfe Test-Verzeichnisse
    if [[ ! -d "$PROJECT_ROOT/tests" ]]; then
        log_error "Tests directory not found: $PROJECT_ROOT/tests"
        ((issues++))
    fi
    
    # Prüfe Test-Helper
    if [[ ! -f "$PROJECT_ROOT/tests/test_helper.bash" ]]; then
        log_warn "Test helper not found: $PROJECT_ROOT/tests/test_helper.bash"
        log_warn "Some tests may not work properly"
    fi
    
    # Prüfe Source-Dateien
    if [[ ! -d "$PROJECT_ROOT/src" ]]; then
        log_error "Source directory not found: $PROJECT_ROOT/src"
        ((issues++))
    fi
    
    # Prüfe Fixtures
    if [[ -d "$PROJECT_ROOT/tests/fixtures" ]]; then
        local fixture_count
        fixture_count=$(find "$PROJECT_ROOT/tests/fixtures" -type f 2>/dev/null | wc -l)
        log_info "Found $fixture_count test fixtures"
    else
        log_warn "Test fixtures directory not found"
    fi
    
    if [[ $issues -gt 0 ]]; then
        log_error "$issues issue(s) found in test environment"
        
        # Prüfe ob nur BATS fehlt
        if [[ $issues -eq 1 ]] && ! has_command bats; then
            log_warn "Only BATS is missing - will run available tests only"
            log_warn "BATS-based unit and integration tests will be skipped"
            return 2  # Special return code for partial test environment
        fi
        
        return 1
    fi
    
    log_success "Test environment validation passed"
    return 0
}

# ===============================================================================
# TEST-AUSFÜHRUNG
# ===============================================================================

# Führe Syntax-Tests durch
run_syntax_tests() {
    log_step "Running syntax tests"
    
    local syntax_errors=0
    local checked_files=0
    
    # Finde alle Shell-Skripte
    local shell_files
    shell_files=$(find "$PROJECT_ROOT" -name "*.sh" -type f 2>/dev/null | grep -v ".git" | sort)
    
    if [[ -z "$shell_files" ]]; then
        log_warn "No shell files found for syntax testing"
        return 0
    fi
    
    log_info "Checking syntax of shell scripts..."
    
    while IFS= read -r file; do
        if [[ "$VERBOSE_OUTPUT" == "true" ]]; then
            log_debug "Checking: $file"
        fi
        
        if bash -n "$file"; then
            ((checked_files++))
        else
            log_error "Syntax error in: $file"
            ((syntax_errors++))
            
            if [[ "$STOP_ON_FAILURE" == "true" ]]; then
                log_error "Stopping on first syntax error"
                return 1
            fi
        fi
    done <<< "$shell_files"
    
    if [[ $syntax_errors -eq 0 ]]; then
        log_success "All $checked_files shell scripts have valid syntax"
        return 0
    else
        log_error "$syntax_errors syntax error(s) found in $checked_files files"
        return 1
    fi
}

# Führe einfache Funktionstests durch (Fallback ohne BATS)
run_basic_functional_tests() {
    log_step "Running basic functional tests (BATS fallback)"
    
    local basic_errors=0
    local tested_scripts=0
    
    # Test 1: Hauptskript-Hilfe
    log_info "Testing main script help command"
    if [[ -f "$PROJECT_ROOT/src/hybrid-monitor.sh" ]]; then
        if "$PROJECT_ROOT/src/hybrid-monitor.sh" --help >/dev/null 2>&1; then
            log_success "Main script help command works"
            ((tested_scripts++))
        else
            log_error "Main script help command failed"
            ((basic_errors++))
        fi
    fi
    
    # Test 2: Konfigurationsdatei-Validierung
    log_info "Testing configuration file validity"
    if [[ -f "$PROJECT_ROOT/config/default.conf" ]]; then
        # Einfache Konfigurationsvalidierung
        if grep -q "CHECK_INTERVAL_MINUTES" "$PROJECT_ROOT/config/default.conf" && \
           grep -q "USE_CLAUNCH" "$PROJECT_ROOT/config/default.conf"; then
            log_success "Default configuration appears valid"
            ((tested_scripts++))
        else
            log_error "Default configuration missing required settings"
            ((basic_errors++))
        fi
    fi
    
    # Test 3: Utility-Funktionen
    log_info "Testing utility script loading"
    local utils_dir="$PROJECT_ROOT/src/utils"
    if [[ -d "$utils_dir" ]]; then
        local util_files=("logging.sh" "network.sh" "terminal.sh")
        for util in "${util_files[@]}"; do
            if [[ -f "$utils_dir/$util" ]]; then
                if bash -n "$utils_dir/$util"; then
                    log_debug "Utility script $util has valid syntax"
                    ((tested_scripts++))
                else
                    log_error "Utility script $util has syntax errors"
                    ((basic_errors++))
                fi
            fi
        done
    fi
    
    if [[ $basic_errors -eq 0 ]]; then
        log_success "All $tested_scripts basic functional tests passed"
        return 0
    else
        log_error "$basic_errors basic functional test(s) failed"
        return 1
    fi
}

# Führe Unit-Tests durch
run_unit_tests() {
    log_step "Running unit tests"
    
    # Prüfe ob BATS verfügbar ist
    if [[ "$SKIP_BATS_TESTS" == "true" ]] || ! has_command bats; then
        log_warn "BATS not available - running basic functional tests instead"
        log_info "For complete unit tests, install BATS: './scripts/setup.sh --dev'"
        
        # Führe einfache Funktionstests als Fallback aus
        if run_basic_functional_tests; then
            ((SKIPPED_TESTS++))  # Eigentliche Unit-Tests wurden übersprungen
            return 0
        else
            return 1
        fi
    fi
    
    local unit_test_dir="$PROJECT_ROOT/tests/unit"
    
    if [[ ! -d "$unit_test_dir" ]]; then
        log_warn "Unit tests directory not found: $unit_test_dir"
        return 0
    fi
    
    local unit_tests
    unit_tests=$(find "$unit_test_dir" -name "*.bats" -type f 2>/dev/null || true)
    
    if [[ -z "$unit_tests" ]]; then
        log_warn "No unit test files found"
        return 0
    fi
    
    log_info "Running unit tests..."
    
    local unit_start_time=$(date +%s)
    local unit_result=0
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would run unit tests: $unit_tests"
        return 0
    fi
    
    # Führe BATS mit spezifischen Optionen aus
    local bats_options=()
    
    if [[ "$VERBOSE_OUTPUT" == "true" ]]; then
        bats_options+=("--verbose-run")
    fi
    
    if [[ "$PARALLEL_TESTS" == "true" ]] && bats --help | grep -q -- "--jobs"; then
        bats_options+=("--jobs" "4")
    fi
    
    # Setze Test-Umgebung
    export BATS_TEST_TIMEOUT="$TEST_TIMEOUT"
    
    if timeout "$TEST_TIMEOUT" bats "${bats_options[@]}" "$unit_test_dir"/*.bats; then
        unit_result=0
    else
        unit_result=$?
        if [[ $unit_result -eq 124 ]]; then
            log_error "Unit tests timed out after $TEST_TIMEOUT seconds"
        else
            log_error "Unit tests failed with exit code: $unit_result"
        fi
    fi
    
    local unit_end_time=$(date +%s)
    local unit_duration=$((unit_end_time - unit_start_time))
    
    if [[ $unit_result -eq 0 ]]; then
        log_success "Unit tests passed in $(format_duration $unit_duration)"
    else
        log_error "Unit tests failed in $(format_duration $unit_duration)"
    fi
    
    return $unit_result
}

# Führe Integration-Tests durch
run_integration_tests() {
    log_step "Running integration tests"
    
    # Prüfe ob BATS verfügbar ist
    if [[ "$SKIP_BATS_TESTS" == "true" ]] || ! has_command bats; then
        log_warn "BATS not available - skipping integration tests"
        log_info "Integration tests require BATS framework - run './scripts/setup.sh --dev' to install"
        ((SKIPPED_TESTS++))
        return 0
    fi
    
    local integration_test_dir="$PROJECT_ROOT/tests/integration"
    
    if [[ ! -d "$integration_test_dir" ]]; then
        log_warn "Integration tests directory not found: $integration_test_dir"
        return 0
    fi
    
    local integration_tests
    integration_tests=$(find "$integration_test_dir" -name "*.bats" -type f 2>/dev/null || true)
    
    if [[ -z "$integration_tests" ]]; then
        log_warn "No integration test files found"
        return 0
    fi
    
    log_info "Running integration tests..."
    
    local integration_start_time=$(date +%s)
    local integration_result=0
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would run integration tests: $integration_tests"
        return 0
    fi
    
    # Integration-Tests benötigen möglicherweise längere Timeouts
    local integration_timeout=$((TEST_TIMEOUT * 2))
    
    # Führe BATS aus
    local bats_options=()
    
    if [[ "$VERBOSE_OUTPUT" == "true" ]]; then
        bats_options+=("--verbose-run")
    fi
    
    export BATS_TEST_TIMEOUT="$integration_timeout"
    
    if timeout "$integration_timeout" bats "${bats_options[@]}" "$integration_test_dir"/*.bats; then
        integration_result=0
    else
        integration_result=$?
        if [[ $integration_result -eq 124 ]]; then
            log_error "Integration tests timed out after $integration_timeout seconds"
        else
            log_error "Integration tests failed with exit code: $integration_result"
        fi
    fi
    
    local integration_end_time=$(date +%s)
    local integration_duration=$((integration_end_time - integration_start_time))
    
    if [[ $integration_result -eq 0 ]]; then
        log_success "Integration tests passed in $(format_duration $integration_duration)"
    else
        log_error "Integration tests failed in $(format_duration $integration_duration)"
    fi
    
    return $integration_result
}

# Führe Linting-Tests durch
run_lint_tests() {
    log_step "Running linting tests"
    
    local lint_issues=0
    
    # ShellCheck-Tests
    if has_command shellcheck; then
        log_info "Running ShellCheck..."
        
        local shell_files
        shell_files=$(find "$PROJECT_ROOT" -name "*.sh" -type f 2>/dev/null | grep -v ".git" | sort)
        
        if [[ -n "$shell_files" ]]; then
            if [[ "$DRY_RUN" == "true" ]]; then
                log_info "[DRY RUN] Would run ShellCheck on shell files"
            else
                local shellcheck_options=("-e" "SC1091")  # Ignore "sourced file not found"
                
                if [[ "$VERBOSE_OUTPUT" == "true" ]]; then
                    shellcheck_options+=("--format=gcc")
                fi
                
                while IFS= read -r file; do
                    if [[ "$VERBOSE_OUTPUT" == "true" ]]; then
                        log_debug "ShellCheck: $file"
                    fi
                    
                    if ! shellcheck "${shellcheck_options[@]}" "$file"; then
                        ((lint_issues++))
                        
                        if [[ "$STOP_ON_FAILURE" == "true" ]]; then
                            log_error "Stopping on first ShellCheck error"
                            return 1
                        fi
                    fi
                done <<< "$shell_files"
            fi
        fi
    else
        log_warn "ShellCheck not available - skipping shell script linting"
    fi
    
    # shfmt-Tests (falls verfügbar)
    if has_command shfmt; then
        log_info "Running shfmt format check..."
        
        local shell_files
        shell_files=$(find "$PROJECT_ROOT" -name "*.sh" -type f 2>/dev/null | grep -v ".git" | sort)
        
        if [[ -n "$shell_files" && "$DRY_RUN" != "true" ]]; then
            while IFS= read -r file; do
                if [[ "$VERBOSE_OUTPUT" == "true" ]]; then
                    log_debug "Format check: $file"
                fi
                
                if ! shfmt -d "$file" >/dev/null 2>&1; then
                    log_warn "File not properly formatted: $file"
                    ((lint_issues++))
                fi
            done <<< "$shell_files"
        fi
    else
        log_debug "shfmt not available - skipping format checks"
    fi
    
    if [[ $lint_issues -eq 0 ]]; then
        log_success "All linting checks passed"
        return 0
    else
        log_error "$lint_issues linting issue(s) found"
        return 1
    fi
}

# ===============================================================================
# TEST-BERICHTERSTATTUNG
# ===============================================================================

# Generiere Test-Bericht
generate_test_report() {
    log_step "Generating test report"
    
    local total_duration=0
    if [[ -n "$START_TIME" && -n "$END_TIME" ]]; then
        total_duration=$((END_TIME - START_TIME))
    fi
    
    echo
    echo "╭─────────────────────────────────────────────────────────────╮"
    echo "│                      Test Report                           │"
    echo "╰─────────────────────────────────────────────────────────────╯"
    echo
    echo "Test Type: $TEST_TYPE"
    echo "Total Duration: $(format_duration $total_duration)"
    echo "Timestamp: $(date)"
    echo
    echo "Test Results:"
    echo "  Total Tests:   $TOTAL_TESTS"
    echo "  Passed:        $PASSED_TESTS"
    echo "  Failed:        $FAILED_TESTS"
    echo "  Skipped:       $SKIPPED_TESTS"
    echo
    
    if [[ $FAILED_TESTS -eq 0 ]]; then
        echo "🎉 All tests passed!"
    else
        echo "❌ $FAILED_TESTS test(s) failed"
    fi
    
    echo
    echo "Environment:"
    echo "  OS: $(uname -s) $(uname -r)"
    echo "  Shell: $SHELL"
    echo "  Project: $(basename "$PROJECT_ROOT")"
    
    if has_command bats; then
        echo "  BATS: $(bats --version | head -1)"
    fi
    
    if has_command shellcheck; then
        echo "  ShellCheck: $(shellcheck --version | grep version | head -1)"
    fi
    
    echo
}

# Speichere Test-Ergebnisse
save_test_results() {
    local results_file="$PROJECT_ROOT/test-results.json"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would save test results to: $results_file"
        return 0
    fi
    
    log_debug "Saving test results to: $results_file"
    
    cat > "$results_file" << EOF
{
  "test_run": {
    "timestamp": "$(date -Iseconds)",
    "test_type": "$TEST_TYPE",
    "duration": $((END_TIME - START_TIME)),
    "results": {
      "total": $TOTAL_TESTS,
      "passed": $PASSED_TESTS,
      "failed": $FAILED_TESTS,
      "skipped": $SKIPPED_TESTS
    },
    "environment": {
      "os": "$(uname -s)",
      "shell": "$SHELL",
      "bats_available": $(has_command bats && echo "true" || echo "false"),
      "shellcheck_available": $(has_command shellcheck && echo "true" || echo "false")
    },
    "configuration": {
      "verbose": $VERBOSE_OUTPUT,
      "stop_on_failure": $STOP_ON_FAILURE,
      "parallel": $PARALLEL_TESTS,
      "timeout": $TEST_TIMEOUT
    }
  }
}
EOF
    
    log_debug "Test results saved to: $results_file"
}

# ===============================================================================
# COMMAND-LINE-INTERFACE
# ===============================================================================

# Zeige Hilfe
show_help() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS] [TEST_TYPE]

Run tests for the Claude Auto-Resume project.

TEST_TYPES:
    all             Run all available tests (default)
    unit            Run only unit tests
    integration     Run only integration tests
    syntax          Run only syntax/linting tests
    lint            Run only linting checks

OPTIONS:
    --verbose, -v       Enable verbose output
    --coverage          Generate code coverage report (if supported)
    --stop-on-failure   Stop running tests after first failure
    --parallel          Run tests in parallel (if supported)
    --timeout SECONDS   Set test timeout (default: $TEST_TIMEOUT)
    --dry-run           Preview what would be run without executing
    --help, -h          Show this help message
    --version           Show version information

EXAMPLES:
    # Run all tests
    $SCRIPT_NAME

    # Run only unit tests with verbose output
    $SCRIPT_NAME unit --verbose

    # Run tests in parallel with custom timeout
    $SCRIPT_NAME --parallel --timeout 600

    # Stop on first failure for faster debugging
    $SCRIPT_NAME --stop-on-failure

    # Preview what would be run
    $SCRIPT_NAME --dry-run --verbose

REQUIREMENTS:
    - BATS (Bash Automated Testing System)
    - ShellCheck (optional, for linting)
    - shfmt (optional, for format checking)

Install requirements:
    macOS: brew install bats-core shellcheck shfmt
    Ubuntu: apt-get install bats shellcheck
    
For more information, see README.md or run ./scripts/dev-setup.sh
EOF
}

# Zeige Versionsinformation
show_version() {
    echo "$SCRIPT_NAME version $VERSION"
    echo "Claude Auto-Resume Test Runner"
}

# Parse Kommandozeilen-Argumente
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --verbose|-v)
                VERBOSE_OUTPUT=true
                shift
                ;;
            --coverage)
                GENERATE_COVERAGE=true
                shift
                ;;
            --stop-on-failure)
                STOP_ON_FAILURE=true
                shift
                ;;
            --parallel)
                PARALLEL_TESTS=true
                shift
                ;;
            --timeout)
                if [[ -z "${2:-}" ]] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
                    log_error "Option $1 requires a valid number of seconds"
                    exit 1
                fi
                TEST_TIMEOUT="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --version)
                show_version
                exit 0
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            unit|integration|syntax|lint|all)
                TEST_TYPE="$1"
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                log_error "Use --help for usage information"
                exit 1
                ;;
        esac
    done
    
    log_debug "Configuration:"
    log_debug "  TEST_TYPE=$TEST_TYPE"
    log_debug "  VERBOSE_OUTPUT=$VERBOSE_OUTPUT"
    log_debug "  STOP_ON_FAILURE=$STOP_ON_FAILURE"
    log_debug "  PARALLEL_TESTS=$PARALLEL_TESTS"
    log_debug "  TEST_TIMEOUT=$TEST_TIMEOUT"
    log_debug "  DRY_RUN=$DRY_RUN"
}

# ===============================================================================
# MAIN ENTRY POINT
# ===============================================================================

# Zeige Test-Header
show_header() {
    echo
    echo "╭─────────────────────────────────────────────────────────────╮"
    echo "│                Claude Auto-Resume Tests                     │"
    echo "│                     Version $VERSION                        │"
    echo "╰─────────────────────────────────────────────────────────────╯"
    echo
    log_info "Starting test suite: $TEST_TYPE"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "DRY RUN MODE - Tests will not be executed"
    fi
    
    echo
}

main() {
    # Parse Argumente
    parse_arguments "$@"
    
    # Header anzeigen
    show_header
    
    # Initialisierung
    START_TIME=$(date +%s)
    
    # Validiere Test-Umgebung
    local env_result
    env_result=$(validate_test_environment; echo $?)
    case $env_result in
        0)
            log_debug "Full test environment available"
            ;;
        1)
            log_error "Test environment validation failed"
            exit 1
            ;;
        2)
            log_warn "Partial test environment - BATS tests will be skipped"
            SKIP_BATS_TESTS=true
            ;;
    esac
    
    # Entdecke verfügbare Tests
    discover_tests
    
    # Führe Tests basierend auf Typ aus
    local test_result=0
    local failed_suites=0
    
    case "$TEST_TYPE" in
        "syntax")
            if ! run_syntax_tests; then
                ((failed_suites++))
            fi
            ;;
        "lint")
            if ! run_lint_tests; then
                ((failed_suites++))
            fi
            ;;
        "unit")
            if ! run_unit_tests; then
                ((failed_suites++))
            fi
            ;;
        "integration")
            if ! run_integration_tests; then
                ((failed_suites++))
            fi
            ;;
        "all"|*)
            # Führe alle Test-Typen aus
            log_info "Running comprehensive test suite"
            
            if ! run_syntax_tests; then
                ((failed_suites++))
                if [[ "$STOP_ON_FAILURE" == "true" ]]; then
                    test_result=1
                fi
            fi
            
            if [[ $test_result -eq 0 ]] && ! run_lint_tests; then
                ((failed_suites++))
                if [[ "$STOP_ON_FAILURE" == "true" ]]; then
                    test_result=1
                fi
            fi
            
            if [[ $test_result -eq 0 ]] && ! run_unit_tests; then
                ((failed_suites++))
                if [[ "$STOP_ON_FAILURE" == "true" ]]; then
                    test_result=1
                fi
            fi
            
            if [[ $test_result -eq 0 ]] && ! run_integration_tests; then
                ((failed_suites++))
                if [[ "$STOP_ON_FAILURE" == "true" ]]; then
                    test_result=1
                fi
            fi
            ;;
    esac
    
    # Finalisierung
    END_TIME=$(date +%s)
    
    # Setze finale Statistiken (vereinfacht für diese Version)
    if [[ $failed_suites -eq 0 ]]; then
        PASSED_TESTS=1
        test_result=0
    else
        FAILED_TESTS=$failed_suites
        test_result=1
    fi
    TOTAL_TESTS=$((PASSED_TESTS + FAILED_TESTS + SKIPPED_TESTS))
    
    # Generiere Bericht
    generate_test_report
    
    # Speichere Ergebnisse
    save_test_results
    
    # Exit mit entsprechendem Code
    if [[ $test_result -eq 0 ]]; then
        log_success "All test suites passed! 🎉"
        exit 0
    else
        log_error "$failed_suites test suite(s) failed"
        exit 1
    fi
}

# Führe main nur aus wenn Skript direkt aufgerufen wird
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi