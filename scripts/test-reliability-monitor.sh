#!/usr/bin/env bash

# Test Reliability Monitor
# Phase 4: Long-term test reliability improvements and monitoring
# Tracks test performance, success rates, and identifies reliability issues

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Configuration
MONITOR_LOG_DIR="$PROJECT_ROOT/logs/test-monitoring"
RELIABILITY_REPORT="$MONITOR_LOG_DIR/reliability-report.json"
PERFORMANCE_LOG="$MONITOR_LOG_DIR/performance.log"
SUCCESS_RATE_THRESHOLD=75  # Minimum acceptable success rate
TIMEOUT_THRESHOLD=120      # Maximum acceptable test suite duration (seconds)

# Logging functions
log_info() { echo "[MONITOR] [INFO] $*" | tee -a "$PERFORMANCE_LOG"; }
log_warn() { echo "[MONITOR] [WARN] $*" | tee -a "$PERFORMANCE_LOG"; }
log_error() { echo "[MONITOR] [ERROR] $*" | tee -a "$PERFORMANCE_LOG"; }

# Initialize monitoring
init_monitoring() {
    echo "[MONITOR] [INFO] Initializing test reliability monitoring"
    
    # Create monitoring directories
    mkdir -p "$MONITOR_LOG_DIR"
    
    # Initialize performance log
    if [[ ! -f "$PERFORMANCE_LOG" ]]; then
        cat > "$PERFORMANCE_LOG" << EOF
# Test Reliability Monitoring Log
# Started: $(date)
# Format: [MONITOR] [LEVEL] [TIMESTAMP] Message

EOF
    fi
    
    log_info "Monitoring initialized - logs: $MONITOR_LOG_DIR"
}

# Run tests with monitoring
run_monitored_tests() {
    local test_type="${1:-all}"
    local start_time=$(date +%s)
    local timestamp=$(date -Iseconds)
    
    log_info "Starting monitored test run: $test_type"
    
    # Create temporary results file
    local temp_results=$(mktemp)
    local test_output=$(mktemp)
    
    # Run tests with timeout and capture metrics
    local test_result=0
    local duration=0
    local tests_total=0
    local tests_passed=0
    local tests_failed=0
    local timeout_occurred=false
    
    if timeout "$TIMEOUT_THRESHOLD" "$PROJECT_ROOT/scripts/run-tests.sh" "$test_type" > "$test_output" 2>&1; then
        test_result=0
    else
        test_result=$?
        if [[ $test_result -eq 124 ]]; then
            timeout_occurred=true
            log_warn "Test suite timed out after ${TIMEOUT_THRESHOLD}s"
        fi
    fi
    
    local end_time=$(date +%s)
    duration=$((end_time - start_time))
    
    # Parse test output for metrics
    if [[ -f "$test_output" ]]; then
        # Extract test counts from BATS output
        tests_total=$(grep -o "^[0-9]\+\.\." "$test_output" | head -1 | sed 's/\.\.//' || echo "0")
        tests_passed=$(grep -c "^ok " "$test_output" || echo "0")
        tests_failed=$(grep -c "^not ok " "$test_output" || echo "0")
    fi
    
    # Calculate success rate
    local success_rate=0
    if [[ $tests_total -gt 0 ]]; then
        success_rate=$((tests_passed * 100 / tests_total))
    fi
    
    # Log performance metrics
    log_info "Test run completed: ${duration}s, ${tests_passed}/${tests_total} passed (${success_rate}%)"
    
    # Create detailed report entry
    cat > "$temp_results" << EOF
{
  "timestamp": "$timestamp",
  "test_type": "$test_type",
  "duration_seconds": $duration,
  "timeout_occurred": $timeout_occurred,
  "timeout_threshold": $TIMEOUT_THRESHOLD,
  "results": {
    "total_tests": $tests_total,
    "passed_tests": $tests_passed,
    "failed_tests": $tests_failed,
    "success_rate_percent": $success_rate
  },
  "status": {
    "overall_result": $test_result,
    "performance_acceptable": $([ $duration -le $TIMEOUT_THRESHOLD ] && echo "true" || echo "false"),
    "reliability_acceptable": $([ $success_rate -ge $SUCCESS_RATE_THRESHOLD ] && echo "true" || echo "false")
  },
  "environment": {
    "os": "$(uname -s)",
    "hostname": "$(hostname)",
    "bash_version": "${BASH_VERSION:-unknown}"
  }
}
EOF
    
    # Update reliability report
    update_reliability_report "$temp_results"
    
    # Check for alerts
    check_reliability_alerts "$success_rate" "$duration" "$timeout_occurred"
    
    # Cleanup
    rm -f "$temp_results" "$test_output"
    
    return $test_result
}

# Update reliability report with new data
update_reliability_report() {
    local new_data_file="$1"
    
    # Initialize report if it doesn't exist
    if [[ ! -f "$RELIABILITY_REPORT" ]]; then
        echo '{"test_runs": [], "summary": {"last_updated": "", "total_runs": 0}}' > "$RELIABILITY_REPORT"
    fi
    
    # Add new data to report using Python for JSON manipulation
    python3 -c "
import json
import sys
from datetime import datetime

# Read existing report
with open('$RELIABILITY_REPORT') as f:
    report = json.load(f)

# Read new data
with open('$new_data_file') as f:
    new_data = json.load(f)

# Add to test runs
report['test_runs'].append(new_data)

# Keep only last 100 runs
report['test_runs'] = report['test_runs'][-100:]

# Update summary
report['summary']['last_updated'] = datetime.now().isoformat()
report['summary']['total_runs'] = len(report['test_runs'])

# Calculate trends (last 10 runs)
recent_runs = report['test_runs'][-10:]
if recent_runs:
    success_rates = [run['results']['success_rate_percent'] for run in recent_runs]
    durations = [run['duration_seconds'] for run in recent_runs]
    
    report['summary']['recent_trends'] = {
        'average_success_rate': sum(success_rates) / len(success_rates),
        'average_duration': sum(durations) / len(durations),
        'trend_direction': 'improving' if success_rates[-1] >= success_rates[0] else 'declining'
    }

# Write back
with open('$RELIABILITY_REPORT', 'w') as f:
    json.dump(report, f, indent=2)
" 2>/dev/null || log_warn "Failed to update reliability report"
    
    log_info "Reliability report updated: $RELIABILITY_REPORT"
}

# Check for reliability alerts
check_reliability_alerts() {
    local success_rate="$1"
    local duration="$2"
    local timeout_occurred="$3"
    
    # Alert for low success rate
    if [[ $success_rate -lt $SUCCESS_RATE_THRESHOLD ]]; then
        log_warn "ALERT: Success rate below threshold: ${success_rate}% < ${SUCCESS_RATE_THRESHOLD}%"
    fi
    
    # Alert for timeout
    if [[ "$timeout_occurred" == "true" ]]; then
        log_error "ALERT: Test suite timeout occurred after ${TIMEOUT_THRESHOLD}s"
    fi
    
    # Alert for slow performance
    local performance_threshold=$((TIMEOUT_THRESHOLD * 75 / 100))  # 75% of timeout
    if [[ $duration -gt $performance_threshold ]]; then
        log_warn "ALERT: Slow test performance: ${duration}s > ${performance_threshold}s"
    fi
    
    # Success message
    if [[ $success_rate -ge $SUCCESS_RATE_THRESHOLD && $duration -le $performance_threshold ]]; then
        log_info "SUCCESS: Test reliability within acceptable parameters"
    fi
}

# Generate summary report
generate_summary_report() {
    log_info "Generating test reliability summary report"
    
    if [[ ! -f "$RELIABILITY_REPORT" ]]; then
        log_warn "No reliability data available for summary"
        return 1
    fi
    
    # Generate human-readable summary
    local summary_file="$MONITOR_LOG_DIR/summary-$(date +%Y%m%d-%H%M%S).txt"
    
    python3 -c "
import json
from datetime import datetime

with open('$RELIABILITY_REPORT') as f:
    data = json.load(f)

print('='*60)
print('TEST RELIABILITY SUMMARY REPORT')
print('='*60)
print(f'Generated: {datetime.now().strftime(\"%Y-%m-%d %H:%M:%S\")}')
print(f'Total Test Runs Monitored: {data[\"summary\"][\"total_runs\"]}')
print()

if 'recent_trends' in data['summary']:
    trends = data['summary']['recent_trends']
    print('RECENT PERFORMANCE (Last 10 Runs):')
    print(f'  Average Success Rate: {trends[\"average_success_rate\"]:.1f}%')
    print(f'  Average Duration: {trends[\"average_duration\"]:.1f}s') 
    print(f'  Trend Direction: {trends[\"trend_direction\"].title()}')
    print()

if data['test_runs']:
    latest = data['test_runs'][-1]
    print('LATEST TEST RUN:')
    print(f'  Timestamp: {latest[\"timestamp\"]}')
    print(f'  Success Rate: {latest[\"results\"][\"success_rate_percent\"]}%')
    print(f'  Duration: {latest[\"duration_seconds\"]}s')
    print(f'  Tests: {latest[\"results\"][\"passed_tests\"]}/{latest[\"results\"][\"total_tests\"]} passed')
    print(f'  Status: {\"✅ ACCEPTABLE\" if latest[\"status\"][\"reliability_acceptable\"] else \"⚠️ NEEDS ATTENTION\"}')
    print()

# Alert summary
recent_runs = data['test_runs'][-5:] if data['test_runs'] else []
alerts = []
for run in recent_runs:
    if not run['status']['reliability_acceptable']:
        alerts.append(f'Low success rate: {run[\"results\"][\"success_rate_percent\"]}%')
    if run['timeout_occurred']:
        alerts.append('Timeout occurred')
    if not run['status']['performance_acceptable']:
        alerts.append(f'Slow performance: {run[\"duration_seconds\"]}s')

if alerts:
    print('RECENT ALERTS:')
    for alert in set(alerts):
        print(f'  ⚠️ {alert}')
else:
    print('✅ NO RECENT ALERTS - Test suite performing within parameters')

print()
print('='*60)
" > "$summary_file" 2>/dev/null || {
        echo "Failed to generate detailed summary" > "$summary_file"
    }
    
    # Display summary
    cat "$summary_file"
    log_info "Summary report saved: $summary_file"
}

# Main function
main() {
    local action="${1:-monitor}"
    local test_type="${2:-unit}"
    
    case "$action" in
        "monitor")
            init_monitoring
            run_monitored_tests "$test_type"
            ;;
        "report") 
            generate_summary_report
            ;;
        "init")
            init_monitoring
            log_info "Monitoring system initialized"
            ;;
        *)
            echo "Usage: $0 {monitor|report|init} [test_type]"
            echo ""
            echo "Actions:"
            echo "  monitor - Run tests with monitoring (default)"
            echo "  report  - Generate summary report"
            echo "  init    - Initialize monitoring system"
            echo ""
            echo "Test types: unit, integration, all (default: unit)"
            exit 1
            ;;
    esac
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi