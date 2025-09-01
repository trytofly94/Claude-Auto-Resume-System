#!/usr/bin/env bash
# Production readiness validation script for Claude Auto-Resume System
#
# This script performs comprehensive validation to ensure the system is ready for
# production deployment. It validates:
# - System dependencies and requirements
# - Security configuration and permissions
# - Performance requirements and benchmarks
# - Documentation completeness and accuracy
# - Test coverage and execution
# - Integration functionality and health
#
# The script follows a checklist-based approach with detailed reporting
# and actionable recommendations for any issues found.

set -euo pipefail

# Get project root directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source logging utilities
if [[ -f "$PROJECT_ROOT/src/utils/logging.sh" ]]; then
    source "$PROJECT_ROOT/src/utils/logging.sh"
else
    # Fallback logging functions
    log_debug() { [[ "${DEBUG_MODE:-false}" == "true" ]] && echo "[DEBUG] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; }
    log_info() { echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; }
    log_warn() { echo "[WARN] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; }
    log_error() { echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; }
    log_success() { echo "[SUCCESS] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; }
fi

# Configuration
REPORT_FILE="${1:-/tmp/production_readiness_report_$(date +%Y%m%d_%H%M%S).txt}"
VERBOSE="${VERBOSE:-false}"
SKIP_PERFORMANCE_TESTS="${SKIP_PERFORMANCE_TESTS:-false}"
SKIP_SECURITY_TESTS="${SKIP_SECURITY_TESTS:-false}"

# Counters for summary
CHECKS_TOTAL=0
CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_WARNINGS=0

# Initialize report file
initialize_report() {
    cat > "$REPORT_FILE" << EOF
================================================================
Claude Auto-Resume System - Production Readiness Report
================================================================

Generated: $(date)
System: $(uname -s) $(uname -r)
Project: $PROJECT_ROOT

EOF
}

# Add section to report
report_section() {
    local section_title="$1"
    echo "" >> "$REPORT_FILE"
    echo "================================================================" >> "$REPORT_FILE"
    echo "$section_title" >> "$REPORT_FILE"
    echo "================================================================" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
}

# Add check result to report
report_check() {
    local check_name="$1"
    local status="$2"
    local details="${3:-}"
    
    echo "[$status] $check_name" >> "$REPORT_FILE"
    if [[ -n "$details" ]]; then
        echo "    $details" >> "$REPORT_FILE"
    fi
    echo "" >> "$REPORT_FILE"
}

# Increment check counters
count_check() {
    local status="$1"
    ((CHECKS_TOTAL++))
    case "$status" in
        "PASS") ((CHECKS_PASSED++)) ;;
        "FAIL") ((CHECKS_FAILED++)) ;;
        "WARN") ((CHECKS_WARNINGS++)) ;;
    esac
}

# Execute a check and handle results
execute_check() {
    local check_name="$1"
    local check_function="$2"
    local is_critical="${3:-true}"  # If false, failure becomes warning
    
    log_info "Running check: $check_name"
    
    if $check_function; then
        log_success "✅ $check_name"
        report_check "$check_name" "PASS"
        count_check "PASS"
        return 0
    else
        if [[ "$is_critical" == "true" ]]; then
            log_error "❌ $check_name"
            report_check "$check_name" "FAIL" "Critical check failed"
            count_check "FAIL"
            return 1
        else
            log_warn "⚠️ $check_name"
            report_check "$check_name" "WARN" "Non-critical check failed"
            count_check "WARN"
            return 0
        fi
    fi
}

# ===============================================================================
# DEPENDENCY VALIDATION CHECKS
# ===============================================================================

validate_core_dependencies() {
    local required_commands=("git" "jq" "curl" "tmux")
    local optional_commands=("gh" "bc" "timeout")
    
    local missing_required=()
    local missing_optional=()
    
    # Check required dependencies
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_required+=("$cmd")
        fi
    done
    
    # Check optional dependencies
    for cmd in "${optional_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_optional+=("$cmd")
        fi
    done
    
    # Report results
    if [[ ${#missing_required[@]} -gt 0 ]]; then
        report_check "Core Dependencies" "FAIL" "Missing required commands: ${missing_required[*]}"
        return 1
    fi
    
    if [[ ${#missing_optional[@]} -gt 0 ]]; then
        report_check "Optional Dependencies" "WARN" "Missing optional commands: ${missing_optional[*]}"
    fi
    
    # Validate Claude CLI
    if ! claude --help >/dev/null 2>&1; then
        report_check "Claude CLI" "FAIL" "Claude CLI not available or not working"
        return 1
    fi
    
    # Validate claunch if enabled
    if [[ "${USE_CLAUNCH:-true}" == "true" ]]; then
        if ! command -v claunch >/dev/null 2>&1; then
            report_check "Claunch Integration" "WARN" "claunch not available but USE_CLAUNCH is enabled"
        fi
    fi
    
    return 0
}

validate_system_requirements() {
    local issues=()
    
    # Check available memory
    if command -v free >/dev/null; then
        # Linux
        local available_mb
        available_mb=$(free -m | awk 'NR==2{print $7}')
        if [[ $available_mb -lt 256 ]]; then
            issues+=("Insufficient available memory: ${available_mb}MB (minimum 256MB)")
        fi
    elif [[ "$(uname)" == "Darwin" ]]; then
        # macOS - basic check
        local total_memory_gb
        total_memory_gb=$(sysctl hw.memsize 2>/dev/null | awk '{print int($2/1024/1024/1024)}' || echo "0")
        if [[ $total_memory_gb -lt 2 ]]; then
            issues+=("Low total memory: ${total_memory_gb}GB")
        fi
    fi
    
    # Check available disk space
    if command -v df >/dev/null; then
        local available_space
        available_space=$(df "$PROJECT_ROOT" 2>/dev/null | awk 'NR==2 {print $4}' || echo "0")
        local available_mb=$((available_space / 1024))
        
        if [[ $available_mb -lt 100 ]]; then
            issues+=("Insufficient disk space: ${available_mb}MB (minimum 100MB)")
        fi
    fi
    
    # Check Bash version
    local bash_version
    bash_version=$(bash --version | head -1 | grep -o '[0-9]\.[0-9]' | head -1)
    if [[ -n "$bash_version" ]]; then
        if (( $(echo "$bash_version < 4.0" | bc -l 2>/dev/null || echo 1) )); then
            issues+=("Bash version too old: $bash_version (minimum 4.0)")
        fi
    fi
    
    # Report results
    if [[ ${#issues[@]} -gt 0 ]]; then
        local issue_details
        issue_details=$(printf '%s; ' "${issues[@]}")
        report_check "System Requirements" "FAIL" "$issue_details"
        return 1
    fi
    
    return 0
}

# ===============================================================================
# SECURITY VALIDATION CHECKS
# ===============================================================================

validate_security_configuration() {
    local issues=()
    
    # Check file permissions
    local sensitive_files=(
        "config/default.conf"
        "queue/"
        "logs/"
    )
    
    for file_path in "${sensitive_files[@]}"; do
        local full_path="$PROJECT_ROOT/$file_path"
        if [[ -e "$full_path" ]]; then
            local perms
            perms=$(stat -c "%a" "$full_path" 2>/dev/null || stat -f "%A" "$full_path" 2>/dev/null || echo "000")
            
            # Check if world-writable (dangerous)
            if [[ "$perms" =~ [2367].$ ]]; then
                issues+=("Insecure permissions on $file_path: $perms")
            fi
        fi
    done
    
    # Validate GitHub token handling
    if [[ -d "$PROJECT_ROOT/logs" ]]; then
        if grep -r "ghp_\|GITHUB_TOKEN" "$PROJECT_ROOT/logs/" 2>/dev/null | grep -v "REDACTED\|\*\*\*" | head -1 >/dev/null; then
            issues+=("GitHub token found in logs - potential security issue")
        fi
    fi
    
    # Check for hardcoded secrets in source code - optimized for Issue #110
    local source_files_array
    if ! mapfile -t source_files_array < <(find "$PROJECT_ROOT/src" -name "*.sh" -type f 2>&1); then
        local find_error="$?"
        log_error "Source file discovery failed: exit code $find_error"
        log_debug "Find command: find $PROJECT_ROOT/src -name '*.sh' -type f"
        return 1
    fi
    if [[ ${#source_files_array[@]} -gt 0 ]]; then
        if printf '%s\n' "${source_files_array[@]}" | xargs grep -l "ghp_\|password\s*=\|secret\s*=" 2>/dev/null | head -1 >/dev/null; then
            issues+=("Potential hardcoded secrets found in source code")
        fi
    fi
    
    # Report results
    if [[ ${#issues[@]} -gt 0 ]]; then
        local issue_details
        issue_details=$(printf '%s; ' "${issues[@]}")
        report_check "Security Configuration" "FAIL" "$issue_details"
        return 1
    fi
    
    return 0
}

validate_input_validation_implementation() {
    # Check if security validation functions exist
    local github_integration="$PROJECT_ROOT/src/github-integration.sh"
    
    if [[ ! -f "$github_integration" ]]; then
        report_check "Input Validation Implementation" "FAIL" "GitHub integration file not found"
        return 1
    fi
    
    # Check for presence of security functions
    local security_functions=(
        "validate_github_input"
        "sanitize_user_input"
        "validate_github_token"
    )
    
    local missing_functions=()
    for func in "${security_functions[@]}"; do
        if ! grep -q "^${func}()" "$github_integration" 2>/dev/null; then
            missing_functions+=("$func")
        fi
    done
    
    if [[ ${#missing_functions[@]} -gt 0 ]]; then
        report_check "Input Validation Implementation" "FAIL" "Missing security functions: ${missing_functions[*]}"
        return 1
    fi
    
    return 0
}

# ===============================================================================
# PERFORMANCE VALIDATION CHECKS
# ===============================================================================

validate_performance_requirements() {
    if [[ "$SKIP_PERFORMANCE_TESTS" == "true" ]]; then
        report_check "Performance Requirements" "WARN" "Performance tests skipped"
        return 0
    fi
    
    local issues=()
    
    # Test basic queue operations performance
    local temp_queue="/tmp/perf_test_queue_$$.json"
    echo '{"tasks": []}' > "$temp_queue"
    
    # Time queue operations
    local start_time end_time duration
    
    # Test adding tasks
    start_time=$(date +%s%N 2>/dev/null || date +%s)
    for i in {1..50}; do
        echo "{\"id\": \"test-$i\", \"status\": \"pending\"}" >> "$temp_queue" 2>/dev/null || true
    done
    end_time=$(date +%s%N 2>/dev/null || date +%s)
    
    if [[ "$start_time" != "$end_time" ]]; then
        duration=$(( (end_time - start_time) / 1000000 2>/dev/null || (end_time - start_time) * 1000 ))
        
        # Should be able to add 50 tasks in less than 2 seconds (2000ms)
        if [[ $duration -gt 2000 ]]; then
            issues+=("Queue operations too slow: ${duration}ms for 50 tasks")
        fi
    fi
    
    rm -f "$temp_queue"
    
    # Check memory usage capability
    local current_memory
    if command -v ps >/dev/null; then
        current_memory=$(ps -o rss= -p $$ 2>/dev/null | awk '{print $1/1024}' || echo "0")
        
        # Should use less than 50MB for basic operations
        if (( $(echo "$current_memory > 50" | bc -l 2>/dev/null || echo 0) )); then
            issues+=("Memory usage too high: ${current_memory}MB")
        fi
    fi
    
    # Report results
    if [[ ${#issues[@]} -gt 0 ]]; then
        local issue_details
        issue_details=$(printf '%s; ' "${issues[@]}")
        report_check "Performance Requirements" "FAIL" "$issue_details"
        return 1
    fi
    
    return 0
}

validate_performance_monitoring() {
    local perf_monitor="$PROJECT_ROOT/src/performance-monitor.sh"
    
    if [[ ! -f "$perf_monitor" ]]; then
        report_check "Performance Monitoring" "WARN" "Performance monitor script not found"
        return 0
    fi
    
    if [[ ! -x "$perf_monitor" ]]; then
        report_check "Performance Monitoring" "FAIL" "Performance monitor script not executable"
        return 1
    fi
    
    # Test basic functionality
    if ! "$perf_monitor" --help >/dev/null 2>&1; then
        report_check "Performance Monitoring" "FAIL" "Performance monitor help not working"
        return 1
    fi
    
    return 0
}

# ===============================================================================
# DOCUMENTATION VALIDATION CHECKS
# ===============================================================================

validate_documentation_completeness() {
    local required_docs=(
        "README.md"
        "CLAUDE.md"
        "config/default.conf"
    )
    
    local missing_docs=()
    
    for doc in "${required_docs[@]}"; do
        local doc_path="$PROJECT_ROOT/$doc"
        if [[ ! -f "$doc_path" ]]; then
            missing_docs+=("$doc")
        elif [[ ! -s "$doc_path" ]]; then
            missing_docs+=("$doc (empty)")
        fi
    done
    
    if [[ ${#missing_docs[@]} -gt 0 ]]; then
        report_check "Documentation Completeness" "FAIL" "Missing or empty: ${missing_docs[*]}"
        return 1
    fi
    
    # Check README has key sections
    local readme="$PROJECT_ROOT/README.md"
    local required_sections=(
        "Installation"
        "Usage"
        "Configuration"
        "Troubleshooting"
        "Task Queue"
        "Performance"
        "Security"
    )
    
    local missing_sections=()
    for section in "${required_sections[@]}"; do
        if ! grep -q "$section" "$readme" 2>/dev/null; then
            missing_sections+=("$section")
        fi
    done
    
    if [[ ${#missing_sections[@]} -gt 0 ]]; then
        report_check "README Sections" "FAIL" "Missing sections: ${missing_sections[*]}"
        return 1
    fi
    
    return 0
}

validate_cli_help_text() {
    local hybrid_monitor="$PROJECT_ROOT/src/hybrid-monitor.sh"
    
    if [[ ! -f "$hybrid_monitor" ]]; then
        report_check "CLI Help Text" "FAIL" "Hybrid monitor script not found"
        return 1
    fi
    
    # Test help functionality
    if ! "$hybrid_monitor" --help | grep -q "Claude Auto-Resume" 2>/dev/null; then
        report_check "CLI Help Text" "FAIL" "Help text not properly updated"
        return 1
    fi
    
    # Check for comprehensive sections
    local help_output
    help_output=$("$hybrid_monitor" --help 2>/dev/null || echo "")
    
    local required_help_sections=(
        "TASK QUEUE OPERATIONS"
        "CONFIGURATION"
        "EXAMPLES"
        "TROUBLESHOOTING"
    )
    
    local missing_help_sections=()
    for section in "${required_help_sections[@]}"; do
        if ! echo "$help_output" | grep -q "$section"; then
            missing_help_sections+=("$section")
        fi
    done
    
    if [[ ${#missing_help_sections[@]} -gt 0 ]]; then
        report_check "CLI Help Sections" "FAIL" "Missing help sections: ${missing_help_sections[*]}"
        return 1
    fi
    
    return 0
}

# ===============================================================================
# TEST COVERAGE VALIDATION CHECKS
# ===============================================================================

validate_test_coverage() {
    local test_dirs=("tests/unit" "tests/integration" "tests/security")
    
    local missing_test_dirs=()
    local empty_test_dirs=()
    
    for test_dir in "${test_dirs[@]}"; do
        local test_path="$PROJECT_ROOT/$test_dir"
        
        if [[ ! -d "$test_path" ]]; then
            missing_test_dirs+=("$test_dir")
        else
            # Use array to count test files efficiently (Issue #110 optimization)
            local test_files_array
            if ! mapfile -t test_files_array < <(find "$test_path" -name "*.bats" -type f 2>&1); then
                log_warn "Test file discovery failed in $test_path"
                test_files_array=()
            fi
            if [[ ${#test_files_array[@]} -eq 0 ]]; then
                empty_test_dirs+=("$test_dir")
            fi
        fi
    done
    
    local issues=()
    if [[ ${#missing_test_dirs[@]} -gt 0 ]]; then
        issues+=("Missing test directories: ${missing_test_dirs[*]}")
    fi
    
    if [[ ${#empty_test_dirs[@]} -gt 0 ]]; then
        issues+=("Empty test directories: ${empty_test_dirs[*]}")
    fi
    
    if [[ ${#issues[@]} -gt 0 ]]; then
        local issue_details
        issue_details=$(printf '%s; ' "${issues[@]}")
        report_check "Test Coverage" "FAIL" "$issue_details"
        return 1
    fi
    
    return 0
}

validate_test_execution() {
    # Check if BATS is available
    if ! command -v bats >/dev/null 2>&1; then
        report_check "Test Execution" "WARN" "BATS not available - cannot validate test execution"
        return 0
    fi
    
    # Try to run a basic test - optimized for Issue #110
    local test_files_array basic_test
    mapfile -t test_files_array < <(find "$PROJECT_ROOT/tests" -name "test-logging.bats" -o -name "test-*.bats" 2>/dev/null | head -1)
    basic_test="${test_files_array[0]:-}"
    
    if [[ -n "$basic_test" ]]; then
        if ! timeout 60 bats "$basic_test" >/dev/null 2>&1; then
            report_check "Test Execution" "FAIL" "Basic test execution failed"
            return 1
        fi
    else
        report_check "Test Execution" "WARN" "No basic tests found for validation"
        return 0
    fi
    
    return 0
}

# ===============================================================================
# INTEGRATION FUNCTIONALITY CHECKS
# ===============================================================================

validate_integration_functionality() {
    # Test basic task queue operations
    local test_queue_dir="/tmp/production_test_$$"
    mkdir -p "$test_queue_dir"
    
    export TASK_QUEUE_DIR="$test_queue_dir"
    
    local hybrid_monitor="$PROJECT_ROOT/src/hybrid-monitor.sh"
    
    # Test adding and listing tasks
    if ! "$hybrid_monitor" --add-custom "Production readiness test" --quiet >/dev/null 2>&1; then
        report_check "Integration Functionality" "FAIL" "Failed to add test task"
        rm -rf "$test_queue_dir"
        return 1
    fi
    
    if ! "$hybrid_monitor" --list-queue --quiet 2>/dev/null | grep -q "Production readiness test"; then
        report_check "Integration Functionality" "FAIL" "Failed to list added test task"
        rm -rf "$test_queue_dir"
        return 1
    fi
    
    # Cleanup
    rm -rf "$test_queue_dir"
    
    return 0
}

validate_github_integration() {
    # Test GitHub CLI integration if available
    if command -v gh >/dev/null 2>&1; then
        if ! gh auth status >/dev/null 2>&1; then
            report_check "GitHub Integration" "WARN" "GitHub CLI not authenticated - GitHub integration may not work"
            return 0
        fi
        
        # Test basic API access
        if ! gh api user >/dev/null 2>&1; then
            report_check "GitHub Integration" "WARN" "GitHub API access failed - check token permissions"
            return 0
        fi
    else
        report_check "GitHub Integration" "WARN" "GitHub CLI not available - GitHub integration disabled"
        return 0
    fi
    
    return 0
}

validate_session_management() {
    # Check tmux availability
    if ! command -v tmux >/dev/null 2>&1; then
        report_check "Session Management" "FAIL" "tmux not available but required for session management"
        return 1
    fi
    
    # Test basic tmux functionality
    if ! tmux list-sessions >/dev/null 2>&1 && ! tmux new-session -d -s test_session_$$ true 2>/dev/null; then
        report_check "Session Management" "WARN" "tmux functionality limited - check permissions"
        return 0
    fi
    
    # Cleanup test session
    tmux kill-session -t "test_session_$$" 2>/dev/null || true
    
    return 0
}

# ===============================================================================
# MAIN EXECUTION FUNCTION
# ===============================================================================

main() {
    echo "================================================================"
    echo "Claude Auto-Resume System - Production Readiness Check"
    echo "================================================================"
    echo ""
    
    initialize_report
    
    log_info "Starting production readiness validation"
    log_info "Report will be saved to: $REPORT_FILE"
    
    # Dependency and System Checks
    report_section "SYSTEM AND DEPENDENCY VALIDATION"
    execute_check "Core Dependencies" validate_core_dependencies true
    execute_check "System Requirements" validate_system_requirements true
    
    # Security Checks
    report_section "SECURITY VALIDATION"
    execute_check "Security Configuration" validate_security_configuration true
    execute_check "Input Validation Implementation" validate_input_validation_implementation false
    
    # Performance Checks  
    report_section "PERFORMANCE VALIDATION"
    execute_check "Performance Requirements" validate_performance_requirements true
    execute_check "Performance Monitoring" validate_performance_monitoring false
    
    # Documentation Checks
    report_section "DOCUMENTATION VALIDATION"
    execute_check "Documentation Completeness" validate_documentation_completeness true
    execute_check "CLI Help Text" validate_cli_help_text true
    
    # Test Coverage Checks
    report_section "TEST COVERAGE VALIDATION"
    execute_check "Test Coverage" validate_test_coverage true
    execute_check "Test Execution" validate_test_execution false
    
    # Integration Checks
    report_section "INTEGRATION FUNCTIONALITY"
    execute_check "Integration Functionality" validate_integration_functionality true
    execute_check "GitHub Integration" validate_github_integration false
    execute_check "Session Management" validate_session_management true
    
    # Generate Summary
    report_section "SUMMARY"
    
    local overall_status="READY"
    if [[ $CHECKS_FAILED -gt 0 ]]; then
        overall_status="NOT READY"
    elif [[ $CHECKS_WARNINGS -gt 5 ]]; then
        overall_status="READY WITH WARNINGS"
    fi
    
    # Console summary
    echo ""
    echo "================================================================"
    echo "PRODUCTION READINESS SUMMARY"
    echo "================================================================"
    echo "Total Checks: $CHECKS_TOTAL"
    echo "Passed: $CHECKS_PASSED"
    echo "Failed: $CHECKS_FAILED"
    echo "Warnings: $CHECKS_WARNINGS"
    echo ""
    echo "Overall Status: $overall_status"
    echo ""
    echo "Detailed report saved to: $REPORT_FILE"
    
    # Report summary
    cat >> "$REPORT_FILE" << EOF
PRODUCTION READINESS SUMMARY
============================

Total Checks: $CHECKS_TOTAL
Passed: $CHECKS_PASSED
Failed: $CHECKS_FAILED
Warnings: $CHECKS_WARNINGS

Overall Status: $overall_status

EOF
    
    if [[ $CHECKS_FAILED -gt 0 ]]; then
        cat >> "$REPORT_FILE" << EOF
CRITICAL ISSUES FOUND
=====================

The system is NOT production ready. Please address the failed checks
above before deploying to production. Critical issues must be resolved.

EOF
        log_error "❌ System is NOT production ready ($CHECKS_FAILED critical issues found)"
        return 1
    elif [[ $CHECKS_WARNINGS -gt 0 ]]; then
        cat >> "$REPORT_FILE" << EOF
WARNINGS FOUND
==============

The system is production ready but has $CHECKS_WARNINGS warnings.
Consider addressing these warnings for optimal performance and security.

EOF
        log_warn "⚠️ System is production ready but has $CHECKS_WARNINGS warnings"
        return 0
    else
        cat >> "$REPORT_FILE" << EOF
ALL CHECKS PASSED
=================

🎉 The Claude Auto-Resume System is PRODUCTION READY!

All critical checks have passed successfully. The system meets all
requirements for production deployment.

EOF
        log_success "🎉 System is PRODUCTION READY!"
        return 0
    fi
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --verbose)
            VERBOSE="true"
            shift
            ;;
        --skip-performance)
            SKIP_PERFORMANCE_TESTS="true"
            shift
            ;;
        --skip-security)
            SKIP_SECURITY_TESTS="true"
            shift
            ;;
        --report-file)
            REPORT_FILE="$2"
            shift 2
            ;;
        --help|-h)
            cat << EOF
Claude Auto-Resume Production Readiness Check

USAGE:
    $0 [OPTIONS] [REPORT_FILE]

OPTIONS:
    --verbose              Enable verbose output
    --skip-performance     Skip performance validation tests
    --skip-security        Skip security validation tests
    --report-file FILE     Specify custom report file location
    --help                 Show this help message

EXAMPLES:
    $0                                    # Basic readiness check
    $0 --verbose                          # Verbose output
    $0 --report-file prod-report.txt      # Custom report location
    $0 --skip-performance --skip-security # Skip intensive tests

EOF
            exit 0
            ;;
        -*)
            log_error "Unknown option: $1"
            exit 1
            ;;
        *)
            REPORT_FILE="$1"
            shift
            ;;
    esac
done

# Execute main function
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi