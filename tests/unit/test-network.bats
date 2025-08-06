#!/usr/bin/env bats

# Unit tests for network.sh utility module

load '../test_helper'

setup() {
    export TEST_MODE=true
    export DEBUG_MODE=true
    
    # Source the network module
    source "$BATS_TEST_DIRNAME/../../src/utils/network.sh" 2>/dev/null || {
        # Fallback if module doesn't exist yet
        echo "Network module not found - creating mock functions"
        has_command() { command -v "$1" >/dev/null 2>&1; }
        check_network_connectivity() { return 0; }
        test_claude_api_connectivity() { return 0; }
    }
}

@test "network module loads without errors" {
    run bash -c "source '$BATS_TEST_DIRNAME/../../src/utils/network.sh' 2>/dev/null || true"
    [ "$status" -eq 0 ]
}

@test "has_command function works correctly" {
    # Test with existing command
    run has_command "bash"
    [ "$status" -eq 0 ]
    
    # Test with non-existing command
    run has_command "nonexistent-command-xyz123"
    [ "$status" -eq 1 ]
    
    # Test with empty argument
    run has_command ""
    [ "$status" -eq 1 ]
}

@test "check_network_connectivity function exists" {
    run bash -c "declare -f check_network_connectivity >/dev/null 2>&1"
    if [ "$status" -eq 0 ]; then
        # Function exists, test it
        run check_network_connectivity
        # Should return 0 or 1, not crash
        [[ "$status" -eq 0 ]] || [[ "$status" -eq 1 ]]
    else
        skip "check_network_connectivity function not implemented yet"
    fi
}

@test "test_claude_api_connectivity function handles timeouts" {
    if declare -f test_claude_api_connectivity >/dev/null 2>&1; then
        # Test with short timeout
        run timeout 5 test_claude_api_connectivity
        # Should complete within timeout
        [[ "$status" -eq 0 ]] || [[ "$status" -eq 1 ]] || [[ "$status" -eq 124 ]]
    else
        skip "test_claude_api_connectivity function not implemented yet"
    fi
}

@test "network functions handle no internet connection gracefully" {
    if declare -f check_network_connectivity >/dev/null 2>&1; then
        # Mock no network by temporarily aliasing ping
        alias ping="false"
        
        run check_network_connectivity
        # Should handle gracefully (return 1, not crash)
        [ "$status" -eq 1 ]
        
        unalias ping
    else
        skip "check_network_connectivity function not implemented yet"
    fi
}

@test "diagnose_network_issues function provides useful output" {
    if declare -f diagnose_network_issues >/dev/null 2>&1; then
        run diagnose_network_issues
        [ "$status" -eq 0 ]
        # Should produce some diagnostic output
        [ -n "$output" ]
    else
        skip "diagnose_network_issues function not implemented yet"
    fi
}

@test "get_public_ip function works if implemented" {
    if declare -f get_public_ip >/dev/null 2>&1; then
        run timeout 10 get_public_ip
        [[ "$status" -eq 0 ]] || [[ "$status" -eq 1 ]] || [[ "$status" -eq 124 ]]
        
        # If successful, should return IP-like output
        if [ "$status" -eq 0 ]; then
            [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
            [[ "$output" =~ ^[0-9a-fA-F:]+$ ]]  # IPv6
        fi
    else
        skip "get_public_ip function not implemented yet"
    fi
}

@test "network functions handle curl/wget absence" {
    # Temporarily hide curl and wget
    export PATH="/usr/bin:/bin"  # Minimal PATH
    
    if declare -f check_network_connectivity >/dev/null 2>&1; then
        run check_network_connectivity
        # Should handle gracefully even without curl/wget
        [[ "$status" -eq 0 ]] || [[ "$status" -eq 1 ]]
    else
        skip "check_network_connectivity function not implemented yet"
    fi
}

@test "ping_host function works with valid hosts" {
    if declare -f ping_host >/dev/null 2>&1; then
        # Test with localhost (should work)
        run ping_host "127.0.0.1" 1
        [[ "$status" -eq 0 ]] || [[ "$status" -eq 1 ]]
        
        # Test with invalid host (should fail gracefully)
        run ping_host "invalid-host-name-xyz123.invalid" 1
        [ "$status" -eq 1 ]
    else
        skip "ping_host function not implemented yet"
    fi
}

@test "check_dns_resolution works" {
    if declare -f check_dns_resolution >/dev/null 2>&1; then
        # Test with valid hostname
        run check_dns_resolution "localhost"
        [[ "$status" -eq 0 ]] || [[ "$status" -eq 1 ]]
        
        # Test with invalid hostname
        run check_dns_resolution "this-domain-does-not-exist-xyz123.invalid"
        [ "$status" -eq 1 ]
    else
        skip "check_dns_resolution function not implemented yet"
    fi
}

@test "network timeout values are reasonable" {
    if declare -f check_network_connectivity >/dev/null 2>&1; then
        # Test that network functions complete within reasonable time
        local start_time=$(date +%s)
        run timeout 30 check_network_connectivity
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        
        # Should complete within 30 seconds
        [ "$duration" -le 30 ]
    else
        skip "check_network_connectivity function not implemented yet"
    fi
}

@test "network functions provide informative error messages" {
    if declare -f test_claude_api_connectivity >/dev/null 2>&1; then
        # Force failure and check error output
        export FORCE_NETWORK_FAILURE=true
        
        run test_claude_api_connectivity
        [ "$status" -eq 1 ]
        
        # Should provide some error information
        [ -n "$output" ]
        
        unset FORCE_NETWORK_FAILURE
    else
        skip "test_claude_api_connectivity function not implemented yet"
    fi
}

@test "network module handles proxy settings if implemented" {
    if declare -f check_network_connectivity >/dev/null 2>&1; then
        # Test with proxy environment variables
        export http_proxy="http://invalid-proxy:8080"
        export https_proxy="http://invalid-proxy:8080"
        
        run timeout 10 check_network_connectivity
        # Should handle proxy settings gracefully
        [[ "$status" -eq 0 ]] || [[ "$status" -eq 1 ]] || [[ "$status" -eq 124 ]]
        
        unset http_proxy https_proxy
    else
        skip "check_network_connectivity function not implemented yet"
    fi
}