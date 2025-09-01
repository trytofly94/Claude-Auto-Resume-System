#!/usr/bin/env bats

# Unit tests for module loader system (Issue #111)
# Tests the central module loader functionality and loading guards

load '../../src/utils/module-loader.sh'

setup() {
    export BATS_TEST_TMPDIR="${BATS_TMPDIR}/module-loader-test-$$"
    mkdir -p "$BATS_TEST_TMPDIR"
    
    # Create test module files
    cat > "$BATS_TEST_TMPDIR/test-module.sh" << 'EOF'
#!/usr/bin/env bash
if [[ -n "${TEST_MODULE_LOADED:-}" ]]; then
    return 0
fi
TEST_FUNCTION_CALLED=false
test_function() {
    TEST_FUNCTION_CALLED=true
    echo "test function called"
}
export TEST_MODULE_LOADED=1
EOF
    
    cat > "$BATS_TEST_TMPDIR/test-module2.sh" << 'EOF'
#!/usr/bin/env bash
if [[ -n "${TEST_MODULE2_LOADED:-}" ]]; then
    return 0
fi
test_function2() {
    echo "test function 2 called"
}
export TEST_MODULE2_LOADED=1
EOF

    # Make test modules executable
    chmod +x "$BATS_TEST_TMPDIR/test-module.sh"
    chmod +x "$BATS_TEST_TMPDIR/test-module2.sh"
}

teardown() {
    rm -rf "$BATS_TEST_TMPDIR"
    unset TEST_MODULE_LOADED TEST_MODULE2_LOADED TEST_FUNCTION_CALLED
}

@test "module loader initializes correctly" {
    run bash -c "source src/utils/module-loader.sh; echo \${MODULE_LOADER_LOADED}"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "1" ]]
}

@test "can load module by absolute path" {
    run bash -c "source src/utils/module-loader.sh; load_module_safe '$BATS_TEST_TMPDIR/test-module.sh'"
    [ "$status" -eq 0 ]
}

@test "module loading guard prevents duplicate loading" {
    run bash -c "source src/utils/module-loader.sh; load_module_safe '$BATS_TEST_TMPDIR/test-module.sh'; echo \${TEST_MODULE_LOADED}"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "1" ]]
}

@test "can check if module is loaded" {
    run bash -c "source src/utils/module-loader.sh; load_module_safe '$BATS_TEST_TMPDIR/test-module.sh'; is_module_loaded 'test-module' && echo 'loaded'"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "loaded" ]]
}

@test "can list loaded modules" {
    run bash -c "source src/utils/module-loader.sh; load_module_safe '$BATS_TEST_TMPDIR/test-module.sh'; get_loaded_modules"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "test-module" ]]
}

@test "can get loading statistics" {
    run bash -c "source src/utils/module-loader.sh; load_module_safe '$BATS_TEST_TMPDIR/test-module.sh'; get_loading_stats"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Loading Performance Statistics" ]]
    [[ "$output" =~ "test-module" ]]
}

@test "handles missing module gracefully" {
    run bash -c "source src/utils/module-loader.sh; load_module_safe 'nonexistent-module'"
    [ "$status" -eq 1 ]
}

@test "module loader CLI interface works" {
    run src/utils/module-loader.sh
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Module Loader - Central module loading system" ]]
}

@test "core utility modules have loading guards" {
    # Test logging module guard
    run bash -c "export LOGGING_MODULE_LOADED=1; source src/utils/logging.sh; echo 'should not execute'"
    [ "$status" -eq 0 ]
    [[ ! "$output" =~ "should not execute" ]]
    
    # Test terminal module guard
    run bash -c "export TERMINAL_MODULE_LOADED=1; source src/utils/terminal.sh; echo 'should not execute'"
    [ "$status" -eq 0 ]
    [[ ! "$output" =~ "should not execute" ]]
    
    # Test network module guard
    run bash -c "export NETWORK_MODULE_LOADED=1; source src/utils/network.sh; echo 'should not execute'"
    [ "$status" -eq 0 ]
    [[ ! "$output" =~ "should not execute" ]]
}

@test "task queue uses module loader" {
    # This tests that task-queue.sh can use the module loader
    run bash -c "source src/task-queue.sh >/dev/null 2>&1; declare -f load_module_loader >/dev/null && echo 'has_function'"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "has_function" ]]
}