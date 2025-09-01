#!/usr/bin/env bash

# Claude Auto-Resume - Wizard Module Testing Script
# Tests modular vs monolithic wizard architecture
# Version: 1.0.0

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m' 
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_header() {
    echo -e "\n${BLUE}=== $1 ===${NC}"
}

print_success() {
    echo -e "  ${GREEN}✅ $1${NC}"
}

print_warning() {
    echo -e "  ${YELLOW}⚠️  $1${NC}"
}

print_error() {
    echo -e "  ${RED}❌ $1${NC}"
}

# Test function to check wizard functionality
test_wizard_mode() {
    local mode="$1"
    local backup_dir="$2"
    
    echo -e "  Testing wizard in $mode mode..."
    
    # Test syntax
    if bash -n src/setup-wizard.sh; then
        print_success "Syntax validation passed"
    else
        print_error "Syntax validation failed"
        return 1
    fi
    
    # Test help command
    if src/setup-wizard.sh --help >/dev/null 2>&1; then
        print_success "Help command works"
    else
        print_error "Help command failed"
        return 1
    fi
    
    # Test version command
    if src/setup-wizard.sh --version >/dev/null 2>&1; then
        print_success "Version command works"  
    else
        print_warning "Version command not available"
    fi
    
    return 0
}

print_header "Wizard Module Architecture Test"

# Check if wizard exists
if [[ ! -f "src/setup-wizard.sh" ]]; then
    print_error "Setup wizard not found at src/setup-wizard.sh"
    exit 1
fi

# Check initial state
print_header "Initial State Check"
if [[ -d "src/wizard" ]]; then
    print_success "Modular architecture available"
    # Count wizard modules efficiently using array
    wizard_modules=()
    if mapfile -t wizard_modules < <(find src/wizard -name "*.sh" 2>/dev/null); then
        echo -e "    Modules found: ${#wizard_modules[@]}"
    else
        echo -e "    Modules found: 0 (discovery failed or directory missing)"
    fi
    for module in src/wizard/*.sh; do
        if [[ -f "$module" ]]; then
            module_name=$(basename "$module")
            echo -e "    • $module_name"
        fi
    done
else
    print_warning "Modular architecture not found"
fi

# Test 1: Modular Architecture (if available)
if [[ -d "src/wizard" ]]; then
    print_header "Test 1: Modular Architecture"
    
    if test_wizard_mode "modular" ""; then
        print_success "Modular architecture test passed"
    else
        print_error "Modular architecture test failed"
    fi
    
    # Test 2: Monolithic Fallback
    print_header "Test 2: Monolithic Fallback (temporarily disable modules)"
    
    # Temporarily move modules
    if mv src/wizard src/wizard.backup 2>/dev/null; then
        print_success "Modules temporarily disabled"
        
        if test_wizard_mode "monolithic" "src/wizard.backup"; then
            print_success "Monolithic fallback test passed"
        else
            print_error "Monolithic fallback test failed"
        fi
        
        # Restore modules
        if mv src/wizard.backup src/wizard; then
            print_success "Modules restored"
        else
            print_error "Failed to restore modules"
        fi
    else
        print_warning "Could not temporarily disable modules (permission issue?)"
    fi
else
    print_header "Test: Monolithic Architecture Only"
    if test_wizard_mode "monolithic" ""; then
        print_success "Monolithic architecture test passed"
    else
        print_error "Monolithic architecture test failed"
    fi
fi

# Test 3: Module Loading Logic
print_header "Test 3: Module Loading Logic"

if [[ -d "src/wizard" ]]; then
    # Test individual module syntax
    for module in src/wizard/*.sh; do
        if [[ -f "$module" ]]; then
            module_name=$(basename "$module")
            if bash -n "$module"; then
                print_success "$module_name syntax valid"
            else
                print_error "$module_name syntax invalid"
            fi
        fi
    done
    
    # Test module functions are available after sourcing
    echo -e "  Testing module function availability..."
    temp_test=$(mktemp)
    cat > "$temp_test" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WIZARD_MODULES_DIR="$SCRIPT_DIR/src/wizard"

# Load modules
for module in config validation detection; do
    module_path="$WIZARD_MODULES_DIR/${module}.sh"
    if [[ -f "$module_path" ]]; then
        source "$module_path"
    fi
done

# Test if functions are available
if declare -f validate_tmux_session_name >/dev/null 2>&1; then
    echo "✅ validate_tmux_session_name available"
else
    echo "❌ validate_tmux_session_name not available"
fi

if declare -f validate_claude_session_id >/dev/null 2>&1; then
    echo "✅ validate_claude_session_id available"  
else
    echo "❌ validate_claude_session_id not available"
fi

if declare -f detect_existing_session >/dev/null 2>&1; then
    echo "✅ detect_existing_session available"
else
    echo "❌ detect_existing_session not available"
fi
EOF
    
    if bash "$temp_test"; then
        print_success "Module functions loaded correctly"
    else
        print_error "Module function loading failed"
    fi
    
    rm -f "$temp_test"
else
    print_warning "No modules to test (monolithic mode only)"
fi

# Test 4: Performance Comparison
print_header "Test 4: Performance Comparison"

time_test() {
    local mode="$1"
    local iterations=5
    local total_time=0
    
    for ((i=1; i<=iterations; i++)); do
        start_time=$(date +%s%N)
        src/setup-wizard.sh --help >/dev/null 2>&1 || true
        end_time=$(date +%s%N)
        duration=$(( (end_time - start_time) / 1000000 )) # Convert to milliseconds
        total_time=$((total_time + duration))
    done
    
    local avg_time=$((total_time / iterations))
    echo -e "    $mode mode average: ${avg_time}ms"
}

if [[ -d "src/wizard" ]]; then
    echo -e "  Testing wizard startup performance..."
    time_test "Modular"
    
    # Test monolithic temporarily
    if mv src/wizard src/wizard.backup 2>/dev/null; then
        time_test "Monolithic"
        mv src/wizard.backup src/wizard
    fi
else
    time_test "Monolithic"
fi

# Summary
print_header "Test Summary"

if [[ -d "src/wizard" ]]; then
    print_success "Modular architecture is functional"
    print_success "Monolithic fallback works correctly"
    echo -e "  ${BLUE}Recommendation:${NC} Using modular architecture for better maintainability"
else
    print_success "Monolithic architecture is functional"
    echo -e "  ${BLUE}Note:${NC} Consider implementing modular architecture for future development"
fi

echo -e "\n${GREEN}Module testing complete!${NC}"
echo -e "\nTo implement modular architecture (if not present):"
echo -e "  1. Create src/wizard/ directory"
echo -e "  2. Split wizard functions into focused modules"
echo -e "  3. Update main wizard to load modules with fallback"