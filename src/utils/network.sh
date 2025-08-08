#!/usr/bin/env bash

# Claude Auto-Resume - Network Utilities
# Netzwerk-Utilities für das claunch-basierte Session-Management
# Version: 1.0.0-alpha
# Letzte Aktualisierung: 2025-08-05

set -euo pipefail

# ===============================================================================
# GLOBALE VARIABLEN UND KONSTANTEN
# ===============================================================================

# Standard-Konfiguration (wird von config/default.conf überschrieben)
NETWORK_TIMEOUT="${NETWORK_TIMEOUT:-10}"
NETWORK_RETRY_COUNT="${NETWORK_RETRY_COUNT:-3}"
NETWORK_RETRY_DELAY="${NETWORK_RETRY_DELAY:-5}"
CONNECTIVITY_TEST_URL="${CONNECTIVITY_TEST_URL:-https://api.anthropic.com/v1/health}"

# Zusätzliche Test-URLs für Redundanz - only declare as readonly if not already set
if [[ -z "${FALLBACK_URLS:-}" ]]; then
    readonly FALLBACK_URLS=(
        "https://www.google.com"
        "https://1.1.1.1"
        "https://8.8.8.8"
    )
fi

# DNS-Server für Tests - only declare as readonly if not already set
if [[ -z "${DNS_SERVERS:-}" ]]; then
    readonly DNS_SERVERS=(
        "8.8.8.8"
        "1.1.1.1"
        "9.9.9.9"
    )
fi

# ===============================================================================
# HILFSFUNKTIONEN
# ===============================================================================

# Lade Logging-Utilities falls verfügbar
if [[ -f "$(dirname "${BASH_SOURCE[0]}")/logging.sh" ]]; then
    # shellcheck source=./logging.sh
    source "$(dirname "${BASH_SOURCE[0]}")/logging.sh"
else
    # Fallback-Logging
    log_debug() { echo "[DEBUG] $*" >&2; }
    log_info() { echo "[INFO] $*" >&2; }
    log_warn() { echo "[WARN] $*" >&2; }
    log_error() { echo "[ERROR] $*" >&2; }
fi

# Prüfe ob Kommando verfügbar ist
has_command() {
    command -v "$1" >/dev/null 2>&1
}

# Warte mit exponential backoff
wait_with_backoff() {
    local attempt="$1"
    local base_delay="$2"
    local max_delay="${3:-60}"
    
    local delay=$((base_delay * (2 ** (attempt - 1))))
    [[ $delay -gt $max_delay ]] && delay=$max_delay
    
    log_debug "Waiting ${delay}s before retry (attempt $attempt)"
    sleep "$delay"
}

# ===============================================================================
# NETZWERK-CONNECTIVITY-TESTS
# ===============================================================================

# Teste Internetverbindung mit ping
test_ping_connectivity() {
    local host="${1:-8.8.8.8}"
    local timeout="${2:-$NETWORK_TIMEOUT}"
    local count="${3:-1}"
    
    log_debug "Testing ping connectivity to $host"
    
    if has_command ping; then
        # macOS und Linux haben unterschiedliche ping-Syntax
        if ping -c "$count" -W "$timeout" "$host" >/dev/null 2>&1 || \
           ping -c "$count" -w "$timeout" "$host" >/dev/null 2>&1; then
            log_debug "Ping to $host successful"
            return 0
        else
            log_debug "Ping to $host failed"
            return 1
        fi
    else
        log_warn "ping command not available"
        return 1
    fi
}

# Teste HTTP-Connectivity mit curl
test_http_connectivity() {
    local url="${1:-$CONNECTIVITY_TEST_URL}"
    local timeout="${2:-$NETWORK_TIMEOUT}"
    
    log_debug "Testing HTTP connectivity to $url"
    
    if has_command curl; then
        if curl -s --max-time "$timeout" --connect-timeout "$timeout" \
               --fail --location "$url" >/dev/null 2>&1; then
            log_debug "HTTP test to $url successful"
            return 0
        else
            log_debug "HTTP test to $url failed"
            return 1
        fi
    elif has_command wget; then
        if wget -q --timeout="$timeout" --tries=1 -O /dev/null "$url" 2>/dev/null; then
            log_debug "HTTP test to $url successful"
            return 0
        else
            log_debug "HTTP test to $url failed"
            return 1
        fi
    else
        log_warn "Neither curl nor wget available for HTTP test"
        return 1
    fi
}

# Teste DNS-Auflösung
test_dns_resolution() {
    local hostname="${1:-api.anthropic.com}"
    local dns_server="${2:-}"
    
    log_debug "Testing DNS resolution for $hostname"
    
    if has_command nslookup; then
        local cmd="nslookup $hostname"
        [[ -n "$dns_server" ]] && cmd="$cmd $dns_server"
        
        if $cmd >/dev/null 2>&1; then
            log_debug "DNS resolution for $hostname successful"
            return 0
        else
            log_debug "DNS resolution for $hostname failed"
            return 1
        fi
    elif has_command dig; then
        local cmd="dig +short $hostname"
        [[ -n "$dns_server" ]] && cmd="dig +short @$dns_server $hostname"
        
        if $cmd >/dev/null 2>&1; then
            log_debug "DNS resolution for $hostname successful"
            return 0
        else
            log_debug "DNS resolution for $hostname failed"
            return 1
        fi
    elif has_command host; then
        if host "$hostname" >/dev/null 2>&1; then
            log_debug "DNS resolution for $hostname successful"
            return 0
        else
            log_debug "DNS resolution for $hostname failed"
            return 1
        fi
    else
        log_warn "No DNS resolution tool available"
        return 1
    fi
}

# ===============================================================================
# ÖFFENTLICHE FUNKTIONEN
# ===============================================================================

# Umfassender Connectivity-Check
check_network_connectivity() {
    local test_ping="${1:-true}"
    local test_http="${2:-true}"
    local test_dns="${3:-true}"
    
    log_info "Starting comprehensive network connectivity check"
    
    local tests_passed=0
    local total_tests=0
    
    # Test 1: Ping-Connectivity
    if [[ "$test_ping" == "true" ]]; then
        ((total_tests++))
        log_debug "Running ping connectivity tests"
        
        for host in "8.8.8.8" "1.1.1.1"; do
            if test_ping_connectivity "$host"; then
                ((tests_passed++))
                break
            fi
        done
    fi
    
    # Test 2: HTTP-Connectivity
    if [[ "$test_http" == "true" ]]; then
        ((total_tests++))
        log_debug "Running HTTP connectivity tests"
        
        # Teste primäre URL
        if test_http_connectivity "$CONNECTIVITY_TEST_URL"; then
            ((tests_passed++))
        else
            # Teste Fallback-URLs
            for url in "${FALLBACK_URLS[@]}"; do
                if test_http_connectivity "$url"; then
                    ((tests_passed++))
                    break
                fi
            done
        fi
    fi
    
    # Test 3: DNS-Resolution
    if [[ "$test_dns" == "true" ]]; then
        ((total_tests++))
        log_debug "Running DNS resolution tests"
        
        if test_dns_resolution "api.anthropic.com"; then
            ((tests_passed++))
        else
            # Teste mit anderen DNS-Servern
            for dns_server in "${DNS_SERVERS[@]}"; do
                if test_dns_resolution "google.com" "$dns_server"; then
                    ((tests_passed++))
                    break
                fi
            done
        fi
    fi
    
    # Bewerte Ergebnisse
    if [[ $tests_passed -eq $total_tests ]]; then
        log_info "All network connectivity tests passed ($tests_passed/$total_tests)"
        return 0
    elif [[ $tests_passed -gt 0 ]]; then
        log_warn "Partial network connectivity ($tests_passed/$total_tests tests passed)"
        return 1
    else
        log_error "All network connectivity tests failed (0/$total_tests)"
        return 2
    fi
}

# Robuster Connectivity-Check mit Retries
check_network_connectivity_with_retry() {
    local max_attempts="${1:-$NETWORK_RETRY_COUNT}"
    local base_delay="${2:-$NETWORK_RETRY_DELAY}"
    
    log_info "Starting network connectivity check with up to $max_attempts attempts"
    
    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        log_debug "Network connectivity attempt $attempt/$max_attempts"
        
        if check_network_connectivity; then
            log_info "Network connectivity confirmed on attempt $attempt"
            return 0
        fi
        
        if [[ $attempt -lt $max_attempts ]]; then
            log_warn "Network connectivity check failed, retrying..."
            wait_with_backoff "$attempt" "$base_delay"
        fi
    done
    
    log_error "Network connectivity check failed after $max_attempts attempts"
    return 1
}

# Teste spezifische Claude API Connectivity
check_claude_api_connectivity() {
    local api_endpoint="${1:-https://api.anthropic.com/v1/health}"
    local timeout="${2:-$NETWORK_TIMEOUT}"
    
    log_info "Testing Claude API connectivity: $api_endpoint"
    
    if has_command curl; then
        local response
        local http_code
        
        response=$(curl -s --max-time "$timeout" --connect-timeout "$timeout" \
                       --write-out "HTTPSTATUS:%{http_code}" "$api_endpoint" 2>/dev/null || echo "HTTPSTATUS:000")
        
        http_code=$(echo "$response" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
        
        case "$http_code" in
            200|204) 
                log_info "Claude API is accessible (HTTP $http_code)"
                return 0 ;;
            000) 
                log_error "Claude API is not reachable (connection failed)"
                return 2 ;;
            *) 
                log_warn "Claude API returned HTTP $http_code"
                return 1 ;;
        esac
    else
        log_warn "curl not available for Claude API test, falling back to basic HTTP test"
        test_http_connectivity "$api_endpoint" "$timeout"
    fi
}

# ===============================================================================
# NETZWERK-DIAGNOSE-FUNKTIONEN
# ===============================================================================

# Sammle Netzwerk-Informationen
get_network_info() {
    log_info "Collecting network information"
    
    echo "=== Network Interface Information ==="
    if has_command ip; then
        ip addr show 2>/dev/null || echo "ip command failed"
    elif has_command ifconfig; then
        ifconfig 2>/dev/null || echo "ifconfig command failed"
    else
        echo "No network interface tool available"
    fi
    
    echo
    echo "=== Default Gateway ==="
    if has_command ip; then
        ip route show default 2>/dev/null || echo "No default route found"
    elif has_command route; then
        route -n get default 2>/dev/null || route print 2>/dev/null || echo "route command failed"
    elif has_command netstat; then
        netstat -rn | grep default 2>/dev/null || echo "No default route found"
    else
        echo "No routing tool available"
    fi
    
    echo
    echo "=== DNS Configuration ==="
    if [[ -f /etc/resolv.conf ]]; then
        cat /etc/resolv.conf 2>/dev/null || echo "Cannot read /etc/resolv.conf"
    else
        echo "/etc/resolv.conf not found"
    fi
}

# Führe Netzwerk-Diagnose durch
diagnose_network_issues() {
    log_info "Starting network diagnostics"
    
    echo "=== Network Connectivity Diagnosis ==="
    
    # Test 1: Lokale Connectivity
    echo "1. Testing local connectivity..."
    if test_ping_connectivity "127.0.0.1" 5 1; then
        echo "   ✓ Localhost connectivity OK"
    else
        echo "   ✗ Localhost connectivity FAILED"
    fi
    
    # Test 2: Gateway Connectivity
    echo "2. Testing gateway connectivity..."
    local gateway
    if has_command ip; then
        gateway=$(ip route show default | awk '/default/ {print $3}' | head -1)
    elif has_command route; then
        gateway=$(route -n get default 2>/dev/null | awk '/gateway:/ {print $2}' || echo "")
    fi
    
    if [[ -n "$gateway" ]]; then
        if test_ping_connectivity "$gateway" 5 1; then
            echo "   ✓ Gateway ($gateway) connectivity OK"
        else
            echo "   ✗ Gateway ($gateway) connectivity FAILED"
        fi
    else
        echo "   ? Gateway not found"
    fi
    
    # Test 3: DNS Resolution
    echo "3. Testing DNS resolution..."
    if test_dns_resolution "google.com"; then
        echo "   ✓ DNS resolution OK"
    else
        echo "   ✗ DNS resolution FAILED"
    fi
    
    # Test 4: External Connectivity
    echo "4. Testing external connectivity..."
    if test_ping_connectivity "8.8.8.8" 10 1; then
        echo "   ✓ External ping OK"
    else
        echo "   ✗ External ping FAILED"
    fi
    
    # Test 5: HTTP Connectivity
    echo "5. Testing HTTP connectivity..."
    if test_http_connectivity "https://www.google.com" 10; then
        echo "   ✓ HTTP connectivity OK"
    else
        echo "   ✗ HTTP connectivity FAILED"
    fi
    
    # Test 6: Claude API
    echo "6. Testing Claude API..."
    case $(check_claude_api_connectivity 2>/dev/null; echo $?) in
        0) echo "   ✓ Claude API accessible" ;;
        1) echo "   ⚠ Claude API accessible but returned error" ;;
        2) echo "   ✗ Claude API not accessible" ;;
    esac
}

# ===============================================================================
# UTILITY-FUNKTIONEN
# ===============================================================================

# Initialisiere Netzwerk-Utilities
init_network_utils() {
    local config_file="${1:-config/default.conf}"
    
    # Lade Konfiguration falls vorhanden
    if [[ -f "$config_file" ]]; then
        while IFS='=' read -r key value; do
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$key" ]] && continue
            
            value=$(echo "$value" | sed 's/^["'\'']\|["'\'']$//g')
            
            case "$key" in
                NETWORK_TIMEOUT|NETWORK_RETRY_COUNT|NETWORK_RETRY_DELAY|CONNECTIVITY_TEST_URL)
                    eval "$key='$value'"
                    ;;
            esac
        done < <(grep -E '^[^#]*=' "$config_file" || true)
        
        log_debug "Network utilities initialized with config: $config_file"
    else
        log_debug "Network utilities initialized with default configuration"
    fi
}

# Warte auf Netzwerk-Verfügbarkeit
wait_for_network() {
    local timeout="${1:-60}"
    local check_interval="${2:-5}"
    
    log_info "Waiting for network connectivity (timeout: ${timeout}s)"
    
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        if check_network_connectivity >/dev/null 2>&1; then
            log_info "Network connectivity established after ${elapsed}s"
            return 0
        fi
        
        log_debug "Network not available, waiting ${check_interval}s..."
        sleep "$check_interval"
        elapsed=$((elapsed + check_interval))
    done
    
    log_error "Network connectivity not established within ${timeout}s"
    return 1
}

# ===============================================================================
# MAIN ENTRY POINT (für Testing)
# ===============================================================================

# Nur ausführen wenn Skript direkt aufgerufen wird
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    init_network_utils
    
    echo "=== Network Utilities Test ==="
    check_network_connectivity_with_retry
    echo
    
    echo "=== Network Diagnostics ==="
    diagnose_network_issues
    echo
    
    echo "=== Network Information ==="
    get_network_info
fi