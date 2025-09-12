# Claude Auto-Resume System - Live Deployment Checklist

## Pre-Deployment Validation

### System Prerequisites
- [ ] **Claude CLI** - Verify installation: `claude --version`
- [ ] **claunch v0.0.4+** - Verify installation: `claunch --version`  
- [ ] **tmux** - Verify installation: `tmux -V`
- [ ] **Git repository** - Ensure clean working directory: `git status`

### Environment Check
```bash
# Run comprehensive environment validation
make debug

# Check task queue status
./src/task-queue.sh status

# Verify no critical errors
./src/hybrid-monitor.sh --test-basic
```

### Safety Verification
- [ ] **Document existing tmux sessions**: `tmux list-sessions | tee pre-deployment-sessions.txt`
- [ ] **Backup critical session data** if needed
- [ ] **Ensure user is aware** of new tmux sessions that will be created

## Live Deployment Process

### Step 1: Single Command Deployment
```bash
# Deploy for live operation
./scripts/deploy-live.sh start
```

**Expected Output:**
- ✅ System validation completed
- ✅ 19+ pending tasks detected
- ✅ Hybrid monitor started with PID
- ✅ Process health confirmed

### Step 2: Immediate Monitoring (First 10 minutes)
```bash
# Check deployment status
./scripts/deploy-live.sh status

# Monitor live logs
tail -f logs/hybrid-monitor-live.log

# Watch task progression
./src/task-queue.sh monitor 0 60
```

**Success Indicators:**
- [ ] Process running steadily (PID active)
- [ ] Tasks transitioning from pending → in_progress → completed
- [ ] No critical errors in logs
- [ ] Memory usage reasonable (<50MB)

### Step 3: Validate Core Functionality
```bash
# Check task processing
./src/task-queue.sh status

# Verify session management
tmux list-sessions | grep claude

# Test usage limit detection (if triggered)
grep -i "usage limit" logs/hybrid-monitor-live.log
```

## Monitoring & Maintenance

### Regular Health Checks
```bash
# Quick status check
./scripts/deploy-live.sh status

# Task queue monitoring
./src/task-queue.sh list | head -20

# Performance monitoring
ps aux | grep hybrid-monitor
```

### Log Management
```bash
# View recent activity
tail -n 50 logs/hybrid-monitor-live.log

# Monitor for errors
grep -i error logs/hybrid-monitor-live.log | tail -10

# Check usage limit handling
grep -i "usage limit\|blocked until" logs/hybrid-monitor-live.log
```

## Troubleshooting

### Common Issues & Solutions

#### Process Not Starting
```bash
# Check for port conflicts
lsof -i :8000-8100

# Verify permissions
ls -la scripts/deploy-live.sh

# Check dependencies
make debug
```

#### Tasks Not Processing
```bash
# Check task queue integrity
./src/task-queue.sh status

# Verify claunch sessions
claunch list

# Test session management
./src/session-manager.sh --test
```

#### Usage Limit Detection Issues
```bash
# Test pattern recognition
./src/usage-limit-recovery.sh test-patterns

# Check Claude CLI response
claude --help | head -5
```

### Emergency Procedures

#### Graceful Shutdown
```bash
# Stop deployment safely
./scripts/deploy-live.sh stop

# Verify clean shutdown
ps aux | grep hybrid-monitor
```

#### Force Cleanup
```bash
# If graceful shutdown fails
pkill -f hybrid-monitor

# Remove stale files
rm -f logs/hybrid-monitor.pid

# Clean up tmux sessions (CAREFUL!)
# Only remove claude-auto-* sessions, NOT user sessions
tmux list-sessions | grep claude-auto- | cut -d: -f1 | xargs -I {} tmux kill-session -t {}
```

#### System Recovery
```bash
# Full system reset
make clean
make git-unstage-logs

# Restart from clean state
./scripts/deploy-live.sh start
```

## Performance Baselines

### Expected Metrics
- **Startup Time**: <30 seconds to full operation
- **Memory Usage**: <50MB steady state
- **Task Processing**: 1-5 tasks per minute (varies by complexity)
- **Usage Limit Detection**: <30 seconds when triggered
- **Recovery Time**: <5 minutes from usage limit to resumed operation

### Success Criteria
- [ ] **System Uptime**: 99%+ during extended operation
- [ ] **Task Completion Rate**: >95% of tasks process successfully  
- [ ] **Error Recovery**: All recoverable errors handled automatically
- [ ] **Resource Efficiency**: Minimal system impact
- [ ] **Session Safety**: No interference with existing user tmux sessions

## Post-Deployment Validation

### 1-Hour Validation
- [ ] Process still running with same PID
- [ ] At least 10+ tasks completed successfully
- [ ] No critical errors in logs
- [ ] Memory usage stable
- [ ] User tmux sessions unaffected

### 24-Hour Validation  
- [ ] Continuous operation achieved
- [ ] All 19 initial tasks processed
- [ ] Usage limit detection/recovery tested (if applicable)
- [ ] Log rotation functioning properly
- [ ] System remains responsive

## Quick Reference Commands

```bash
# Essential Commands for Live Operation

# Deploy
./scripts/deploy-live.sh start

# Monitor  
./scripts/deploy-live.sh status
tail -f logs/hybrid-monitor-live.log

# Stop
./scripts/deploy-live.sh stop

# Emergency stop
pkill -f hybrid-monitor && rm -f logs/hybrid-monitor.pid

# Health check
./src/task-queue.sh status
tmux list-sessions | grep claude
```

---

**Generated**: 2025-09-12  
**System Version**: v1.0.0-alpha  
**Tested On**: macOS with 19 existing tmux sessions