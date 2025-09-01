#!/usr/bin/env bash

# Simple benchmark script to measure module loading performance improvements
# Part of Issue #111 implementation

echo "=== Module Loading Performance Benchmark ==="
echo "Date: $(date)"
echo "System: $(uname -s) $(uname -r)"
echo

# Function to time a command
time_command() {
    local description="$1"
    shift
    echo -n "$description: "
    { time "$@" >/dev/null 2>/dev/null; } 2>&1 | grep real | awk '{print $2}'
}

# Test 1: Basic script startup time
echo "1. Script Startup Times"
echo "   Task Queue Help:"
time_command "     - Normal execution" src/task-queue.sh --help
time_command "     - Second execution" src/task-queue.sh --help

echo

# Test 2: Module loader functionality
echo "2. Module Loader Tests"
time_command "     - Load logging module" bash -c "source src/utils/module-loader.sh && load_module_safe logging"
time_command "     - Load multiple modules" bash -c "source src/utils/module-loader.sh && load_common_modules"

echo

# Test 3: Source operation count
echo "3. Source Operation Analysis"
echo "   Counting 'source' and '.' operations in codebase:"

# Count source operations
total_sources=$(grep -r "source\|^\." src/ --include="*.sh" | wc -l)
echo "   - Total source/dot operations: $total_sources"

# Count in specific problematic files
task_queue_sources=$(grep -E "source|^\." src/task-queue.sh | wc -l)
error_class_sources=$(grep -E "source|^\." src/error-classification.sh | wc -l)

echo "   - task-queue.sh sources: $task_queue_sources"
echo "   - error-classification.sh sources: $error_class_sources"

echo

# Test 4: Memory usage
echo "4. Memory Usage (approximate)"
echo "   Current bash process RSS: $(ps -o rss= -p $$) KB"

echo

# Test 5: Module loading guard effectiveness
echo "5. Module Loading Guards Test"
echo -n "   - Loading logging twice (should see only 1 load): "
result=$(bash -c "source src/utils/module-loader.sh && load_module_safe logging && load_module_safe logging" 2>&1 | grep -c "Successfully loaded module: logging")
echo "$result load(s)"

echo
echo "=== Benchmark Complete ==="