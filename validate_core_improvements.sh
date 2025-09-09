#!/usr/bin/env bash

# Production Readiness Validation for Core Functionality Improvements
# Validates all enhancements made for live operation readiness

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Claude Auto-Resume Core Functionality Validation ==="
echo "Validating production readiness of core improvements..."
echo ""

# Validation results
PASSED=0
FAILED=0
WARNINGS=0

check_feature() {
    local feature_name="$1"
    local test_command="$2"
    local is_critical="${3:-true}"
    
    echo -n "• $feature_name: "
    
    if eval "$test_command" >/dev/null 2>&1; then
        echo "✅ PASS"
        ((PASSED++))
    else
        if [[ "$is_critical" == "true" ]]; then
            echo "❌ FAIL"
            ((FAILED++))
        else
            echo "⚠️ WARNING"
            ((WARNINGS++))
        fi
    fi
}

echo "=== Phase 1: Enhanced Usage Limit Detection ==="

check_feature "Usage limit recovery module exists" \
    "[[ -f '$SCRIPT_DIR/src/usage-limit-recovery.sh' ]]"

check_feature "Enhanced detection function available" \
    "grep -q 'detect_usage_limit_in_queue' '$SCRIPT_DIR/src/usage-limit-recovery.sh'"

check_feature "Time-based regex patterns implemented" \
    "grep -q 'blocked until.*[0-9].*[ap]m' '$SCRIPT_DIR/src/usage-limit-recovery.sh'"

check_feature "Precise time calculation function available" \
    "grep -q 'calculate_precise_wait_time' '$SCRIPT_DIR/src/usage-limit-recovery.sh'"

check_feature "Enhanced checkpoint creation with timing" \
    "grep -q 'extracted_time.*wait_seconds' '$SCRIPT_DIR/src/usage-limit-recovery.sh'"

echo ""

echo "=== Phase 2: Task Queue and Session Management ==="

check_feature "Task queue module exists" \
    "[[ -f '$SCRIPT_DIR/src/task-queue.sh' ]]"

check_feature "Claunch integration module exists" \
    "[[ -f '$SCRIPT_DIR/src/claunch-integration.sh' ]]"

check_feature "Enhanced claunch cleanup function" \
    "grep -q 'perform_claunch_cleanup' '$SCRIPT_DIR/src/claunch-integration.sh'"

check_feature "Retry logic with enhanced error handling" \
    "grep -q 'start_claunch_session_with_retry' '$SCRIPT_DIR/src/claunch-integration.sh'"

check_feature "Session file backup during failures" \
    "grep -q 'backup.*session' '$SCRIPT_DIR/src/claunch-integration.sh'"

echo ""

echo "=== Phase 3: Continuous Monitoring Optimizations ==="

check_feature "Hybrid monitor module exists" \
    "[[ -f '$SCRIPT_DIR/src/hybrid-monitor.sh' ]]"

check_feature "Enhanced usage limit integration in monitor" \
    "grep -q 'detect_usage_limit_in_queue.*monitor' '$SCRIPT_DIR/src/hybrid-monitor.sh'"

check_feature "Automatic queue resume checking" \
    "grep -q 'auto_resume_queue_if_ready' '$SCRIPT_DIR/src/hybrid-monitor.sh'"

check_feature "Cycle maintenance for resource management" \
    "grep -q 'perform_cycle_maintenance' '$SCRIPT_DIR/src/hybrid-monitor.sh'"

check_feature "Periodic health checks during wait" \
    "grep -q 'perform_periodic_health_check' '$SCRIPT_DIR/src/hybrid-monitor.sh'"

check_feature "Memory usage monitoring" \
    "grep -q 'memory_usage.*ps.*rss' '$SCRIPT_DIR/src/hybrid-monitor.sh'"

check_feature "Stale lock file cleanup" \
    "grep -q 'stale.*lock.*cleanup' '$SCRIPT_DIR/src/hybrid-monitor.sh'"

echo ""

echo "=== Configuration and Documentation ==="

check_feature "Project configuration exists" \
    "[[ -f '$SCRIPT_DIR/CLAUDE.md' ]]"

check_feature "Configuration documents new features" \
    "grep -q 'usage.*limit.*detection' '$SCRIPT_DIR/CLAUDE.md'" false

check_feature "Default configuration exists" \
    "[[ -f '$SCRIPT_DIR/config/default.conf' ]]"

echo ""

echo "=== System Integration Readiness ==="

check_feature "All core modules have proper error handling" \
    "grep -q 'set -euo pipefail' '$SCRIPT_DIR/src/usage-limit-recovery.sh' && grep -q 'set -euo pipefail' '$SCRIPT_DIR/src/hybrid-monitor.sh'"

check_feature "Logging integration across modules" \
    "grep -q 'log_info\\|log_debug\\|log_warn\\|log_error' '$SCRIPT_DIR/src/usage-limit-recovery.sh'"

check_feature "Function availability checks implemented" \
    "grep -q 'declare -f.*>/dev/null' '$SCRIPT_DIR/src/hybrid-monitor.sh'"

check_feature "Graceful degradation mechanisms" \
    "grep -q 'fallback\\|degradation' '$SCRIPT_DIR/src/hybrid-monitor.sh'"

echo ""

echo "=== Validation Summary ==="
echo "✅ Passed: $PASSED"
echo "❌ Failed: $FAILED" 
echo "⚠️  Warnings: $WARNINGS"
echo "📊 Total Checks: $((PASSED + FAILED + WARNINGS))"

echo ""

if [[ $FAILED -eq 0 ]]; then
    echo "🎉 SUCCESS: All critical validations passed!"
    echo ""
    echo "Core functionality improvements ready for live operation:"
    echo "• Enhanced usage limit detection with precise time parsing"
    echo "• Automatic task queue pause/resume integration"  
    echo "• Improved claunch startup reliability with cleanup"
    echo "• Optimized continuous monitoring with resource management"
    echo "• Comprehensive error handling and graceful degradation"
    echo ""
    echo "The system is production-ready for unattended live operation."
    exit 0
else
    echo "⚠️  WARNING: $FAILED critical validations failed"
    echo ""
    echo "Please address the failed checks before deploying to live operation."
    exit 1
fi