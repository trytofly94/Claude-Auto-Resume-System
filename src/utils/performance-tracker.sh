#!/bin/bash

# Performance Tracker - Lightweight performance monitoring for module loading and script execution
# Part of Issue #111 performance optimization

# Strict error handling
set -euo pipefail

# Avoid self-loading
if [[ -n "${PERFORMANCE_TRACKER_LOADED:-}" ]]; then
    return 0
fi

# Performance tracking globals
declare -A PERF_TIMERS=()
declare -A PERF_COUNTERS=()
declare -A PERF_MEMORY=()

# Get current timestamp in microseconds
get_timestamp_us() {
    date +%s%6N
}

# Get current memory usage in KB (if available)
get_memory_usage() {
    if command -v ps >/dev/null 2>&1; then
        # Get RSS memory for current process
        ps -o rss= -p $$ 2>/dev/null | tr -d ' ' || echo "0"
    else
        echo "0"
    fi
}

# Start a performance timer
perf_timer_start() {
    local timer_name="$1"
    local current_time
    current_time=$(get_timestamp_us)
    
    PERF_TIMERS["${timer_name}_start"]=$current_time
    PERF_MEMORY["${timer_name}_start"]=$(get_memory_usage)
    
    echo "[PERF] Started timer: $timer_name at ${current_time}μs" >&2
}

# Stop a performance timer and return duration
perf_timer_stop() {
    local timer_name="$1"
    local start_key="${timer_name}_start"
    local current_time
    current_time=$(get_timestamp_us)
    
    if [[ -z "${PERF_TIMERS[$start_key]:-}" ]]; then
        echo "[PERF] ERROR: Timer '$timer_name' was not started" >&2
        return 1
    fi
    
    local start_time="${PERF_TIMERS[$start_key]}"
    local duration=$((current_time - start_time))
    local start_memory="${PERF_MEMORY[$start_key]}"
    local current_memory
    current_memory=$(get_memory_usage)
    local memory_diff=$((current_memory - start_memory))
    
    # Store results
    PERF_TIMERS["${timer_name}_duration"]=$duration
    PERF_MEMORY["${timer_name}_memory_diff"]=$memory_diff
    
    echo "[PERF] Timer '$timer_name' completed: ${duration}μs, memory: ${memory_diff}KB" >&2
    
    # Clean up start entries
    unset "PERF_TIMERS[$start_key]"
    unset "PERF_MEMORY[$start_key]"
    
    # Return duration for use in scripts
    echo "$duration"
}

# Get timer duration (without stopping)
perf_timer_get() {
    local timer_name="$1"
    local duration_key="${timer_name}_duration"
    
    if [[ -n "${PERF_TIMERS[$duration_key]:-}" ]]; then
        echo "${PERF_TIMERS[$duration_key]}"
    else
        echo "0"
    fi
}

# Increment a performance counter
perf_counter_inc() {
    local counter_name="$1"
    local increment="${2:-1}"
    
    local current_value="${PERF_COUNTERS[$counter_name]:-0}"
    PERF_COUNTERS["$counter_name"]=$((current_value + increment))
}

# Get counter value
perf_counter_get() {
    local counter_name="$1"
    echo "${PERF_COUNTERS[$counter_name]:-0}"
}

# Measure script execution time
measure_script_execution() {
    local script_name="$1"
    shift
    local start_time end_time duration
    
    echo "[PERF] Measuring execution of: $script_name" >&2
    
    start_time=$(get_timestamp_us)
    
    # Execute the script with arguments
    "$script_name" "$@"
    local exit_code=$?
    
    end_time=$(get_timestamp_us)
    duration=$((end_time - start_time))
    
    echo "[PERF] Script '$script_name' executed in ${duration}μs (exit code: $exit_code)" >&2
    
    # Store the measurement
    PERF_TIMERS["script_${script_name##*/}_last"]=$duration
    
    return $exit_code
}

# Benchmark a function call
benchmark_function() {
    local function_name="$1"
    local iterations="${2:-1}"
    shift 2
    
    echo "[PERF] Benchmarking function '$function_name' for $iterations iteration(s)" >&2
    
    local total_time=0
    local min_time=999999999999
    local max_time=0
    local i
    
    for ((i=1; i<=iterations; i++)); do
        local start_time end_time duration
        start_time=$(get_timestamp_us)
        
        # Call the function with remaining arguments
        "$function_name" "$@"
        
        end_time=$(get_timestamp_us)
        duration=$((end_time - start_time))
        
        total_time=$((total_time + duration))
        
        if [[ $duration -lt $min_time ]]; then
            min_time=$duration
        fi
        
        if [[ $duration -gt $max_time ]]; then
            max_time=$duration
        fi
        
        echo "[PERF] Iteration $i: ${duration}μs" >&2
    done
    
    local avg_time=$((total_time / iterations))
    
    echo "[PERF] Benchmark results for '$function_name':" >&2
    echo "[PERF]   Iterations: $iterations" >&2
    echo "[PERF]   Total time: ${total_time}μs" >&2
    echo "[PERF]   Average time: ${avg_time}μs" >&2
    echo "[PERF]   Min time: ${min_time}μs" >&2
    echo "[PERF]   Max time: ${max_time}μs" >&2
    
    # Store benchmark results
    PERF_TIMERS["bench_${function_name}_avg"]=$avg_time
    PERF_TIMERS["bench_${function_name}_min"]=$min_time
    PERF_TIMERS["bench_${function_name}_max"]=$max_time
}

# Profile a script or function for hotspots
profile_execution() {
    local target="$1"
    shift
    
    echo "[PERF] Profiling execution of: $target" >&2
    
    # Enable bash execution tracing with timing
    export PS4='+ $(date +%s%6N) ${BASH_SOURCE}:${LINENO}: ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
    
    set -x
    "$target" "$@"
    local exit_code=$?
    set +x
    
    unset PS4
    
    echo "[PERF] Profiling completed (exit code: $exit_code)" >&2
    return $exit_code
}

# Generate performance report
generate_performance_report() {
    echo "========================================="
    echo "Performance Tracker Report"
    echo "Generated: $(date)"
    echo "========================================="
    
    if [[ ${#PERF_TIMERS[@]} -gt 0 ]]; then
        echo ""
        echo "Timing Results:"
        echo "---------------"
        local timer
        for timer in $(printf '%s\n' "${!PERF_TIMERS[@]}" | sort); do
            local value="${PERF_TIMERS[$timer]}"
            printf "  %-40s %15s μs\n" "$timer" "$value"
        done
    fi
    
    if [[ ${#PERF_COUNTERS[@]} -gt 0 ]]; then
        echo ""
        echo "Counters:"
        echo "---------"
        local counter
        for counter in $(printf '%s\n' "${!PERF_COUNTERS[@]}" | sort); do
            printf "  %-40s %15s\n" "$counter" "${PERF_COUNTERS[$counter]}"
        done
    fi
    
    if [[ ${#PERF_MEMORY[@]} -gt 0 ]]; then
        echo ""
        echo "Memory Usage:"
        echo "-------------"
        local mem
        for mem in $(printf '%s\n' "${!PERF_MEMORY[@]}" | sort); do
            local value="${PERF_MEMORY[$mem]}"
            printf "  %-40s %15s KB\n" "$mem" "$value"
        done
    fi
    
    echo ""
    echo "========================================="
}

# Reset all performance data
reset_performance_data() {
    PERF_TIMERS=()
    PERF_COUNTERS=()
    PERF_MEMORY=()
    echo "[PERF] Performance data reset" >&2
}

# Export performance data to JSON
export_performance_json() {
    local output_file="${1:-performance_data.json}"
    
    cat > "$output_file" << EOF
{
    "timestamp": "$(date -Iseconds)",
    "pid": "$$",
    "timers": {
EOF
    
    local first=true
    local timer
    for timer in $(printf '%s\n' "${!PERF_TIMERS[@]}" | sort); do
        if [[ "$first" == "true" ]]; then
            first=false
        else
            echo "," >> "$output_file"
        fi
        printf '        "%s": %s' "$timer" "${PERF_TIMERS[$timer]}" >> "$output_file"
    done
    
    cat >> "$output_file" << EOF

    },
    "counters": {
EOF
    
    first=true
    local counter
    for counter in $(printf '%s\n' "${!PERF_COUNTERS[@]}" | sort); do
        if [[ "$first" == "true" ]]; then
            first=false
        else
            echo "," >> "$output_file"
        fi
        printf '        "%s": %s' "$counter" "${PERF_COUNTERS[$counter]}" >> "$output_file"
    done
    
    cat >> "$output_file" << EOF

    },
    "memory": {
EOF
    
    first=true
    local mem
    for mem in $(printf '%s\n' "${!PERF_MEMORY[@]}" | sort); do
        if [[ "$first" == "true" ]]; then
            first=false
        else
            echo "," >> "$output_file"
        fi
        printf '        "%s": %s' "$mem" "${PERF_MEMORY[$mem]}" >> "$output_file"
    done
    
    cat >> "$output_file" << EOF

    }
}
EOF
    
    echo "[PERF] Performance data exported to: $output_file" >&2
}

# Auto cleanup on script exit
cleanup_performance_tracker() {
    if [[ "${PERF_SHOW_REPORT_ON_EXIT:-}" == "true" ]]; then
        generate_performance_report >&2
    fi
}

# Set up cleanup trap
trap cleanup_performance_tracker EXIT

# Main execution check
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Script is being run directly - provide CLI interface
    case "${1:-}" in
        "start")
            if [[ -z "${2:-}" ]]; then
                echo "Usage: $0 start <timer_name>"
                exit 1
            fi
            perf_timer_start "$2"
            ;;
        "stop")
            if [[ -z "${2:-}" ]]; then
                echo "Usage: $0 stop <timer_name>"
                exit 1
            fi
            perf_timer_stop "$2"
            ;;
        "measure")
            if [[ -z "${2:-}" ]]; then
                echo "Usage: $0 measure <script_path> [args...]"
                exit 1
            fi
            shift
            measure_script_execution "$@"
            ;;
        "benchmark")
            if [[ -z "${2:-}" ]]; then
                echo "Usage: $0 benchmark <function_name> [iterations] [args...]"
                exit 1
            fi
            shift
            benchmark_function "$@"
            ;;
        "profile")
            if [[ -z "${2:-}" ]]; then
                echo "Usage: $0 profile <script_path> [args...]"
                exit 1
            fi
            shift
            profile_execution "$@"
            ;;
        "report")
            generate_performance_report
            ;;
        "reset")
            reset_performance_data
            ;;
        "export")
            export_performance_json "${2:-}"
            ;;
        *)
            echo "Performance Tracker - Lightweight performance monitoring"
            echo "Usage: $0 {start|stop|measure|benchmark|profile|report|reset|export} [args...]"
            echo ""
            echo "Commands:"
            echo "  start <timer>              - Start a named timer"
            echo "  stop <timer>               - Stop a named timer"
            echo "  measure <script> [args]    - Measure script execution time"
            echo "  benchmark <func> [iter]    - Benchmark function calls"
            echo "  profile <script> [args]    - Profile execution with tracing"
            echo "  report                     - Generate performance report"
            echo "  reset                      - Reset all performance data"
            echo "  export [file]              - Export data to JSON"
            exit 1
            ;;
    esac
fi

# Mark this module as loaded
export PERFORMANCE_TRACKER_LOADED=1