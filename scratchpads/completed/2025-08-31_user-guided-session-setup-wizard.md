# User-Guided Session Setup Wizard Implementation

**Erstellt**: 2025-08-31
**Typ**: Enhancement - Core Functionality 
**Geschätzter Aufwand**: Groß
**Verwandtes Issue**: GitHub #87 - Implement User-Guided Session Setup Wizard for Claude Auto-Resume
**Status**: Planning Phase

## Kontext & Ziel

### Problem Statement
Currently the hybrid-monitor.sh fails during terminal detection and cannot automatically establish connection to Claude sessions. Users need to manually set up tmux sessions and session IDs without proper guidance or validation.

### Solution Overview
Implement a semi-automated setup wizard that:
1. Checks for existing Claude+tmux session
2. Shows step-by-step setup instructions if no session found  
3. Validates each setup step with user confirmation
4. Automatically starts monitoring once session is established

### Benefits
- Eliminates terminal detection failures
- Provides full user control and transparency
- Works across different terminal configurations
- Maintains automation after initial setup
- Improves user onboarding experience

## Current State Analysis

### Existing Codebase Components
Based on analysis of the current implementation:

1. **hybrid-monitor.sh**: Main monitoring script with terminal detection issues
   - Line 594-641: `start_or_continue_claude_session()` with fallback logic
   - Line 288-359: `validate_system_requirements()` with enhanced claunch detection
   - Contains graceful fallback mechanisms but no guided setup

2. **session-manager.sh**: Session lifecycle management
   - Line 661-709: `init_session_manager()` with array initialization
   - Line 712-743: `start_managed_session()` with session registration
   - Line 345-394: `perform_health_check()` for session validation
   - Solid foundation for session tracking

3. **claunch-integration.sh**: claunch wrapper and detection
   - Line 100-200: Enhanced multi-method claunch detection
   - Line 59-97: PATH environment refresh functionality
   - Comprehensive fallback detection mechanisms

4. **utils/terminal.sh**: Terminal detection utilities
   - Line 76-100: `detect_current_terminal()` function
   - Cross-platform terminal identification capabilities

### Key Integration Points
- Session detection logic already exists in session-manager.sh
- Terminal detection utilities available but problematic
- claunch integration has sophisticated fallback mechanisms
- Configuration system supports dynamic path generation

## Anforderungen

### Core Functional Requirements

#### Setup Wizard Flow
- [ ] **Initial Session Detection**: Check for existing Claude+tmux sessions before starting wizard
- [ ] **Dynamic Path Generation**: Generate session paths for current working directory
- [ ] **Step-by-Step Instructions**: Clear, actionable setup instructions with visual formatting
- [ ] **User Confirmation**: Wait for user confirmation between each step
- [ ] **Session ID Management**: Handle session ID input with automatic "sess-" prefix addition
- [ ] **Step Validation**: Validate each setup step before proceeding
- [ ] **Seamless Transition**: Automatically start monitoring once session is established

#### Technical Requirements
- [ ] **Enhanced Session Detection**: Improve session-manager.sh detection capabilities
- [ ] **Proven Command Execution**: Use tmux send-keys + C-m method for reliability
- [ ] **Input Validation**: Robust user input validation and error handling
- [ ] **Configuration Integration**: Work with existing config system
- [ ] **Cross-Platform Support**: Function across different terminal environments

### User Experience Requirements

#### Wizard Interface
- [ ] **Clear Visual Formatting**: Use consistent formatting for instructions and prompts
- [ ] **Progress Indicators**: Show current step and total steps
- [ ] **Error Messages**: Provide helpful error messages with recovery suggestions
- [ ] **Skip Options**: Allow users to skip optional steps
- [ ] **Help System**: Contextual help for each step

#### Setup Instructions
- [ ] **Prerequisites Check**: Verify required dependencies (tmux, claude, claunch)
- [ ] **Session Creation**: Guide user through tmux session creation
- [ ] **Claude Initialization**: Help user start Claude within the session
- [ ] **Session ID Capture**: Assist with session ID identification and input
- [ ] **Validation Steps**: Verify each component is working correctly

## Detaillierte Implementierung

### Phase 1: Core Wizard Infrastructure

#### 1.1 Wizard Framework (src/setup-wizard.sh)
```bash
# New module: src/setup-wizard.sh
setup_wizard_main() {
    log_info "Starting Claude Auto-Resume Setup Wizard"
    
    if detect_existing_session; then
        log_info "Existing session detected - starting monitoring"
        return 0
    fi
    
    show_wizard_introduction
    run_setup_steps
    validate_complete_setup
    start_monitoring_mode
}

show_wizard_introduction() {
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════════════╗
║                    Claude Auto-Resume Setup Wizard                  ║
║                                                                      ║
║ This wizard will guide you through setting up automated Claude      ║
║ session management with tmux integration.                           ║
║                                                                      ║
║ Steps: 1) Check dependencies  2) Create tmux session                ║
║        3) Start Claude        4) Configure session ID               ║
║        5) Validate setup      6) Begin monitoring                   ║
╚══════════════════════════════════════════════════════════════════════╝
EOF
    
    echo ""
    read -p "Press Enter to begin setup or Ctrl+C to exit..."
}

run_setup_steps() {
    local steps=(
        "check_dependencies"
        "create_tmux_session"
        "start_claude_in_session"
        "configure_session_id"
        "validate_session_health"
    )
    
    local current_step=1
    local total_steps=${#steps[@]}
    
    for step in "${steps[@]}"; do
        echo "=== Step $current_step/$total_steps: $(format_step_name "$step") ==="
        
        if ! "$step"; then
            log_error "Setup step failed: $step"
            handle_step_failure "$step"
            return 1
        fi
        
        ((current_step++))
        echo ""
    done
}
```

#### 1.2 Enhanced Session Detection (session-manager.sh modifications)
```bash
# Enhancement to session-manager.sh
detect_existing_claude_session() {
    log_debug "Comprehensive session detection starting"
    
    local detection_methods=(
        "check_tmux_sessions"
        "check_session_files"
        "check_process_tree"
        "check_socket_connections"
    )
    
    for method in "${detection_methods[@]}"; do
        log_debug "Trying detection method: $method"
        
        if "$method"; then
            log_info "Session detected via $method"
            return 0
        fi
    done
    
    log_info "No existing Claude session detected"
    return 1
}

check_tmux_sessions() {
    local project_name=$(basename "$(pwd)")
    local session_pattern="${TMUX_SESSION_PREFIX}-${project_name}"
    
    # Check for exact match
    if tmux has-session -t "$session_pattern" 2>/dev/null; then
        DETECTED_SESSION_NAME="$session_pattern"
        return 0
    fi
    
    # Check for pattern matches
    local matching_sessions
    matching_sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -E "claude|auto-resume" || true)
    
    if [[ -n "$matching_sessions" ]]; then
        log_info "Found potential Claude sessions: $matching_sessions"
        return 0
    fi
    
    return 1
}

check_session_files() {
    local project_name=$(basename "$(pwd)")
    local session_files=(
        "$HOME/.claude_session_${project_name}"
        "$HOME/.claude_auto_resume_${project_name}"
        "$(pwd)/.claude_session"
    )
    
    for file in "${session_files[@]}"; do
        if [[ -f "$file" && -s "$file" ]]; then
            local session_id
            session_id=$(cat "$file" 2>/dev/null || echo "")
            if [[ -n "$session_id" ]]; then
                log_info "Found session file: $file with ID: $session_id"
                DETECTED_SESSION_ID="$session_id"
                return 0
            fi
        fi
    done
    
    return 1
}
```

### Phase 2: Interactive Setup Steps

#### 2.1 Dependency Checking
```bash
check_dependencies() {
    echo "Checking system dependencies..."
    
    local required_commands=("tmux" "claude")
    local optional_commands=("claunch" "jq")
    local missing_required=()
    local missing_optional=()
    
    for cmd in "${required_commands[@]}"; do
        if ! has_command "$cmd"; then
            missing_required+=("$cmd")
        else
            echo "✓ $cmd found: $(command -v "$cmd")"
        fi
    done
    
    for cmd in "${optional_commands[@]}"; do
        if ! has_command "$cmd"; then
            missing_optional+=("$cmd")
        else
            echo "✓ $cmd found: $(command -v "$cmd")"
        fi
    done
    
    if [[ ${#missing_required[@]} -gt 0 ]]; then
        echo ""
        echo "❌ Missing required dependencies: ${missing_required[*]}"
        show_dependency_installation_help "${missing_required[@]}"
        return 1
    fi
    
    if [[ ${#missing_optional[@]} -gt 0 ]]; then
        echo ""
        echo "⚠️  Optional dependencies missing: ${missing_optional[*]}"
        echo "   (These provide enhanced functionality but are not required)"
    fi
    
    echo ""
    read -p "Dependencies check complete. Press Enter to continue..."
    return 0
}

show_dependency_installation_help() {
    local missing_deps=("$@")
    
    echo ""
    echo "Installation instructions:"
    
    for dep in "${missing_deps[@]}"; do
        case "$dep" in
            "tmux")
                echo "  tmux: brew install tmux (macOS) or apt install tmux (Ubuntu)"
                ;;
            "claude")
                echo "  claude: Install Claude CLI from https://claude.ai/code"
                ;;
            "claunch")
                echo "  claunch (optional): ./scripts/install-claunch.sh"
                ;;
        esac
    done
    
    echo ""
    echo "Please install the missing dependencies and run the wizard again."
}
```

#### 2.2 Tmux Session Creation
```bash
create_tmux_session() {
    local project_name=$(basename "$(pwd)")
    local session_name="${TMUX_SESSION_PREFIX}-${project_name}"
    
    echo "Creating tmux session for project: $project_name"
    echo "Session name: $session_name"
    echo "Working directory: $(pwd)"
    echo ""
    
    # Check if session already exists
    if tmux has-session -t "$session_name" 2>/dev/null; then
        echo "⚠️  Session '$session_name' already exists."
        echo ""
        echo "Options:"
        echo "  1) Use existing session (recommended)"
        echo "  2) Kill existing and create new session"
        echo "  3) Create session with different name"
        echo ""
        
        while true; do
            read -p "Choose option (1-3): " choice
            case $choice in
                1)
                    TMUX_SESSION_NAME="$session_name"
                    echo "✓ Using existing session: $session_name"
                    return 0
                    ;;
                2)
                    tmux kill-session -t "$session_name" 2>/dev/null || true
                    break
                    ;;
                3)
                    read -p "Enter new session name: " custom_name
                    if [[ -n "$custom_name" ]]; then
                        session_name="$custom_name"
                        break
                    fi
                    ;;
                *)
                    echo "Please enter 1, 2, or 3"
                    ;;
            esac
        done
    fi
    
    echo "Creating new tmux session..."
    echo "Command: tmux new-session -d -s '$session_name' -c '$(pwd)'"
    
    if tmux new-session -d -s "$session_name" -c "$(pwd)"; then
        echo "✓ tmux session created successfully"
        TMUX_SESSION_NAME="$session_name"
        
        # Wait a moment for session to initialize
        sleep 2
        
        # Verify session is running
        if tmux has-session -t "$session_name" 2>/dev/null; then
            echo "✓ Session verification passed"
        else
            echo "❌ Session verification failed"
            return 1
        fi
    else
        echo "❌ Failed to create tmux session"
        return 1
    fi
    
    echo ""
    read -p "Press Enter to continue to Claude setup..."
    return 0
}
```

#### 2.3 Claude Session Initialization
```bash
start_claude_in_session() {
    echo "Starting Claude in tmux session: $TMUX_SESSION_NAME"
    echo ""
    echo "This step will:"
    echo "  1. Send 'claude continue' command to your tmux session"
    echo "  2. Wait for Claude to initialize"
    echo "  3. Check for successful startup"
    echo ""
    
    read -p "Press Enter to start Claude..."
    
    # Use proven tmux send-keys method
    local claude_command="claude continue"
    echo "Sending command: $claude_command"
    
    if tmux send-keys -t "$TMUX_SESSION_NAME" "$claude_command" C-m; then
        echo "✓ Command sent successfully"
    else
        echo "❌ Failed to send command to tmux session"
        return 1
    fi
    
    echo ""
    echo "Claude is starting up..."
    echo "This may take 10-30 seconds depending on your connection."
    echo ""
    
    # Wait for Claude initialization
    local wait_time=30
    local check_interval=2
    local elapsed=0
    
    echo "Waiting for Claude to initialize..."
    while [[ $elapsed -lt $wait_time ]]; do
        printf "."
        sleep $check_interval
        elapsed=$((elapsed + check_interval))
        
        # Check if Claude has started by looking for session output
        local session_output
        session_output=$(tmux capture-pane -t "$TMUX_SESSION_NAME" -p 2>/dev/null || echo "")
        
        if echo "$session_output" | grep -q "claude\|Claude\|session\|sess-"; then
            echo ""
            echo "✓ Claude appears to be running"
            break
        fi
    done
    
    echo ""
    echo "Current session status:"
    tmux capture-pane -t "$TMUX_SESSION_NAME" -p | tail -10
    
    echo ""
    echo "Please verify that Claude is running properly in your tmux session."
    echo "You can check by running: tmux attach -t $TMUX_SESSION_NAME"
    echo ""
    
    while true; do
        read -p "Is Claude running successfully? (y/n): " response
        case $response in
            [Yy]*)
                echo "✓ Claude startup confirmed"
                return 0
                ;;
            [Nn]*)
                echo "❌ Claude startup failed"
                echo ""
                echo "Troubleshooting steps:"
                echo "  1. Check Claude CLI installation: claude --version"
                echo "  2. Verify internet connection"
                echo "  3. Check Claude authentication status"
                echo "  4. Review tmux session: tmux attach -t $TMUX_SESSION_NAME"
                return 1
                ;;
            *)
                echo "Please answer y or n"
                ;;
        esac
    done
}
```

#### 2.4 Session ID Configuration
```bash
configure_session_id() {
    echo "Configuring Claude session ID..."
    echo ""
    echo "Claude generates a unique session ID when it starts."
    echo "This ID typically looks like: sess-xxxxxxxxxxxxxxxxxx"
    echo ""
    echo "To find your session ID:"
    echo "  1. Look at the current Claude output in your tmux session"
    echo "  2. Or ask Claude: 'What is my session ID?'"
    echo "  3. Or check Claude's startup messages"
    echo ""
    
    # Try to detect session ID automatically first
    local detected_session_id=""
    local session_output
    session_output=$(tmux capture-pane -t "$TMUX_SESSION_NAME" -p 2>/dev/null || echo "")
    
    # Look for session ID patterns in the output
    detected_session_id=$(echo "$session_output" | grep -o "sess-[a-zA-Z0-9]\{20\}" | head -1 || echo "")
    
    if [[ -n "$detected_session_id" ]]; then
        echo "✓ Detected session ID automatically: $detected_session_id"
        echo ""
        while true; do
            read -p "Use this detected session ID? (y/n): " response
            case $response in
                [Yy]*)
                    SESSION_ID="$detected_session_id"
                    break
                    ;;
                [Nn]*)
                    detected_session_id=""
                    break
                    ;;
                *)
                    echo "Please answer y or n"
                    ;;
            esac
        done
    fi
    
    # Manual session ID input if not detected or not accepted
    if [[ -z "$detected_session_id" ]]; then
        echo "Manual session ID entry required."
        echo ""
        echo "Please check your tmux session to find the session ID:"
        echo "  tmux attach -t $TMUX_SESSION_NAME"
        echo ""
        echo "You can detach from tmux with: Ctrl+b, then d"
        echo ""
        
        while true; do
            read -p "Enter session ID (with or without 'sess-' prefix): " input_session_id
            
            # Validate session ID format
            if [[ -z "$input_session_id" ]]; then
                echo "Session ID cannot be empty. Please try again."
                continue
            fi
            
            # Auto-add sess- prefix if not present
            if [[ "$input_session_id" =~ ^sess- ]]; then
                SESSION_ID="$input_session_id"
            else
                SESSION_ID="sess-$input_session_id"
            fi
            
            # Basic validation
            if [[ ${#SESSION_ID} -ge 10 ]]; then
                echo "✓ Session ID set: $SESSION_ID"
                break
            else
                echo "Session ID seems too short. Please check and try again."
            fi
        done
    fi
    
    # Store session ID for persistence
    local project_name=$(basename "$(pwd)")
    local session_file="$HOME/.claude_session_${project_name}"
    
    echo "$SESSION_ID" > "$session_file"
    echo "✓ Session ID saved to: $session_file"
    
    echo ""
    read -p "Press Enter to continue to validation..."
    return 0
}
```

### Phase 3: Validation and Integration

#### 3.1 Session Health Validation
```bash
validate_session_health() {
    echo "Validating complete setup..."
    echo ""
    
    local validation_steps=(
        "validate_tmux_session"
        "validate_claude_process" 
        "validate_session_id"
        "validate_connectivity"
    )
    
    local failed_validations=()
    
    for step in "${validation_steps[@]}"; do
        echo -n "$(format_validation_name "$step")... "
        
        if "$step"; then
            echo "✓"
        else
            echo "❌"
            failed_validations+=("$step")
        fi
    done
    
    echo ""
    
    if [[ ${#failed_validations[@]} -eq 0 ]]; then
        echo "🎉 All validations passed! Setup is complete."
        return 0
    else
        echo "⚠️  Some validations failed: ${failed_validations[*]}"
        echo ""
        echo "You can:"
        echo "  1. Continue anyway (monitoring may have issues)"
        echo "  2. Retry failed validations"
        echo "  3. Restart setup wizard"
        echo ""
        
        while true; do
            read -p "Choose option (1-3): " choice
            case $choice in
                1)
                    echo "⚠️  Continuing with failed validations..."
                    return 0
                    ;;
                2)
                    retry_failed_validations "${failed_validations[@]}"
                    return $?
                    ;;
                3)
                    return 1
                    ;;
                *)
                    echo "Please enter 1, 2, or 3"
                    ;;
            esac
        done
    fi
}

validate_tmux_session() {
    if [[ -z "$TMUX_SESSION_NAME" ]]; then
        return 1
    fi
    
    tmux has-session -t "$TMUX_SESSION_NAME" 2>/dev/null
}

validate_claude_process() {
    if [[ -z "$TMUX_SESSION_NAME" ]]; then
        return 1
    fi
    
    local session_output
    session_output=$(tmux capture-pane -t "$TMUX_SESSION_NAME" -p 2>/dev/null || echo "")
    
    # Look for Claude indicators
    if echo "$session_output" | grep -q "claude\|Claude\|session\|sess-"; then
        return 0
    fi
    
    return 1
}

validate_session_id() {
    if [[ -z "$SESSION_ID" ]]; then
        return 1
    fi
    
    # Check format
    if [[ ! "$SESSION_ID" =~ ^sess- ]]; then
        return 1
    fi
    
    # Check length
    if [[ ${#SESSION_ID} -lt 10 ]]; then
        return 1
    fi
    
    return 0
}

validate_connectivity() {
    # Simple connectivity test
    if timeout 10 claude --help >/dev/null 2>&1; then
        return 0
    fi
    
    return 1
}
```

### Phase 4: Integration with hybrid-monitor.sh

#### 4.1 Wizard Integration Points
```bash
# Modifications to hybrid-monitor.sh main() function
main() {
    log_info "Hybrid Claude Monitor v$VERSION starting up"
    
    # ... existing initialization code ...
    
    # NEW: Check if wizard should be triggered
    if [[ "$CONTINUOUS_MODE" == "true" && "$SKIP_WIZARD" != "true" ]]; then
        if ! detect_existing_claude_session; then
            log_info "No existing session detected - starting setup wizard"
            
            # Load setup wizard module
            if [[ -f "$SCRIPT_DIR/setup-wizard.sh" ]]; then
                source "$SCRIPT_DIR/setup-wizard.sh"
                
                if setup_wizard_main; then
                    log_info "Setup wizard completed successfully"
                else
                    log_error "Setup wizard failed - exiting"
                    exit 1
                fi
            else
                log_error "Setup wizard module not found"
                exit 1
            fi
        fi
    fi
    
    # ... rest of existing main function ...
}
```

#### 4.2 Command Line Options
```bash
# New CLI options for wizard control
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --setup-wizard)
                FORCE_WIZARD=true
                shift
                ;;
            --skip-wizard)
                SKIP_WIZARD=true
                shift
                ;;
            # ... existing argument parsing ...
        esac
    done
}

# Updated help text
show_help() {
    cat << EOF
# ... existing help content ...

SETUP OPTIONS:
    --setup-wizard           Force run setup wizard even if session detected
    --skip-wizard           Skip automatic wizard trigger

# ... rest of help content ...
EOF
}
```

## Testplan

### Einheit-Tests
- [ ] **Setup wizard module tests**: Test individual setup functions
- [ ] **Session detection tests**: Verify detection logic across scenarios
- [ ] **Input validation tests**: Test session ID validation and user input
- [ ] **Integration tests**: Test wizard flow with mocked dependencies

### Integrations-Tests
- [ ] **End-to-end wizard flow**: Complete setup from start to monitoring
- [ ] **Error recovery tests**: Test failure handling and recovery options
- [ ] **Cross-platform tests**: Verify functionality on macOS/Linux
- [ ] **Terminal compatibility**: Test with different terminal applications

### Benutzer-Tests
- [ ] **First-time user experience**: New user completes setup successfully
- [ ] **Error scenarios**: Users can recover from common setup failures
- [ ] **Advanced scenarios**: Power users can customize setup options
- [ ] **Documentation validation**: Instructions are clear and accurate

## Risiken und Mitigationen

### Technische Risiken

#### Risk: Terminal compatibility issues
**Mitigation**: Use proven tmux commands only, provide fallback options

#### Risk: Session detection false positives/negatives
**Mitigation**: Multiple detection methods, user confirmation steps

#### Risk: User input validation complexity
**Mitigation**: Simple validation rules, clear error messages

### Benutzer-Risiken

#### Risk: Users skip important setup steps
**Mitigation**: Clear progress indicators, validation checkpoints

#### Risk: Complex instructions overwhelm users
**Mitigation**: Step-by-step approach, contextual help

#### Risk: Recovery from failed setup is unclear
**Mitigation**: Clear error messages with next steps

## Erfolgskriterien

### Functional Success Criteria
- [ ] **95%+ successful setup rate** for new users
- [ ] **Zero terminal detection failures** after wizard completion
- [ ] **Automatic monitoring startup** after successful setup
- [ ] **Clear error recovery paths** for all failure scenarios

### User Experience Success Criteria
- [ ] **<5 minutes** average setup time for experienced users
- [ ] **<15 minutes** average setup time for new users
- [ ] **Clear progress feedback** throughout wizard process
- [ ] **Self-service problem resolution** for common issues

### Technical Success Criteria
- [ ] **Backward compatibility** with existing configurations
- [ ] **Cross-platform functionality** (macOS, Linux)
- [ ] **Integration** with existing session management
- [ ] **Maintainable code** following project standards

## Rollout-Plan

### Phase 1: Core Wizard Framework (Week 1)
- Implement basic wizard structure
- Add session detection enhancements
- Create foundation CLI integration

### Phase 2: Interactive Setup Steps (Week 2)  
- Implement guided setup flow
- Add input validation and error handling
- Create user interface components

### Phase 3: Integration & Testing (Week 3)
- Integrate with hybrid-monitor.sh
- Complete test suite implementation
- Performance optimization

### Phase 4: Documentation & Polish (Week 4)
- Update documentation
- User experience refinements
- Final testing and validation

---

**Nächste Schritte**: 
1. Begin Phase 1 implementation with core wizard framework
2. Create comprehensive test plan for session detection
3. Design user interface mockups for setup steps
4. Validate integration approach with existing codebase