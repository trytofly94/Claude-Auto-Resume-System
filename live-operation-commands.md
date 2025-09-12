# Claude Auto-Resume Live Operation Commands

## Quick Start

```bash
# Start the system
./start-claude-auto-resume.sh

# Attach to monitor
tmux attach -t claude-auto-resume-live
```

## System Management

### Start System
```bash
./start-claude-auto-resume.sh                # Interactive startup with health checks
```

### Monitor Status
```bash
./src/task-queue.sh status                    # Task queue status and counts
tmux capture-pane -t claude-auto-resume-live -p  # Current live output
tail -f logs/hybrid-monitor.log               # Detailed logs with timestamps
watch -n 30 "./src/task-queue.sh status"      # Auto-refreshing status
```

### Control System
```bash
tmux attach -t claude-auto-resume-live        # Attach to live session
tmux kill-session -t claude-auto-resume-live  # Stop system gracefully
```

### View Task Details
```bash
./src/task-queue.sh list                      # List all tasks with details
./src/task-queue.sh list --pending            # Only pending tasks
./src/task-queue.sh list --completed          # Only completed tasks
```

## Debugging & Troubleshooting

### System Diagnostics
```bash
ps aux | grep hybrid-monitor                  # Check running processes
tmux list-sessions | grep claude              # List Claude-related sessions  
./scripts/debug-environment.sh               # Comprehensive system check
make debug                                    # Project-specific diagnostics
```

### Log Analysis
```bash
# Real-time monitoring with filtering
tail -f logs/hybrid-monitor.log | grep -E "(ERROR|WARN|task|usage.limit)"

# Recent errors only
tail -n 100 logs/hybrid-monitor.log | grep ERROR

# Usage limit detection
grep -E "blocked until|try again at|usage.limit" logs/hybrid-monitor.log

# Task processing activity
grep -E "processing task|task completed|task failed" logs/hybrid-monitor.log
```

### Session Management
```bash
# List all Claude sessions
./src/session-manager.sh --list-sessions

# Clean up orphaned sessions  
./src/session-manager.sh --cleanup-sessions

# Check session health
./src/session-manager.sh --system-status
```

## Emergency Procedures

### Force Stop System
```bash
# Graceful shutdown
tmux kill-session -t claude-auto-resume-live

# Force kill if needed
pkill -f hybrid-monitor.sh
pkill -f claunch

# Check for stuck processes
ps aux | grep -E "(hybrid-monitor|claunch)" | grep -v grep
```

### Reset System State
```bash
# Clear any stale locks
./src/task-queue.sh clear-locks

# Reset task queue if needed (CAUTION: loses task history)
./src/task-queue.sh backup-queue              # Backup first
./src/task-queue.sh clear-queue               # Then clear

# Clean up session artifacts
rm -rf /tmp/claunch-*
rm -rf /tmp/claude-*
```

### Recovery from Errors
```bash
# Check system health
./scripts/debug-environment.sh

# Validate core scripts
make validate

# Test task queue functionality
./src/task-queue.sh status
./src/task-queue.sh test-operations

# Test hybrid monitor
./src/hybrid-monitor.sh --help
./src/hybrid-monitor.sh --dry-run --debug
```

## Performance Monitoring

### Resource Usage
```bash
# Monitor process resources
ps aux | grep hybrid-monitor | awk '{print $3,$4,$11}'  # CPU, MEM, CMD

# Monitor tmux sessions
tmux list-sessions -F "#{session_name}: #{session_windows} windows, created #{session_created}"

# Monitor log file growth
ls -lh logs/hybrid-monitor*
```

### Task Processing Metrics
```bash
# Task completion rate
echo "Completed: $(./src/task-queue.sh status | jq '.completed')"
echo "Pending: $(./src/task-queue.sh status | jq '.pending')"

# Processing history
grep "task completed" logs/hybrid-monitor.log | wc -l
grep "task failed" logs/hybrid-monitor.log | wc -l
```

## Advanced Operations

### Custom Task Management
```bash
# Add tasks while system is running
./src/task-queue.sh add-custom "Custom task description"
./src/task-queue.sh add-issue 123

# Pause/resume task processing
./src/task-queue.sh pause-queue
./src/task-queue.sh resume-queue
```

### Configuration Tuning
```bash
# View current configuration
cat config/default.conf

# Test with different settings (create temporary config)
cp config/default.conf config/test.conf
# Edit config/test.conf as needed
./src/hybrid-monitor.sh --config config/test.conf --dry-run
```

## Success Indicators

### System is Working When:
- ✅ Task counts decrease over time
- ✅ "task completed" messages in logs
- ✅ No repeated ERROR messages
- ✅ Session stays alive continuously
- ✅ Usage limits handled gracefully with waiting

### Common Issues:
- ❌ Session exits immediately → Check dependencies and logs
- ❌ Tasks not processing → Verify claunch integration
- ❌ Repeated errors → Check network and API limits
- ❌ High resource usage → Monitor log file growth

## Quick Reference

```bash
# Start system
./start-claude-auto-resume.sh

# Monitor progress  
watch -n 30 "./src/task-queue.sh status"

# Check activity
tail -f logs/hybrid-monitor.log

# Emergency stop
tmux kill-session -t claude-auto-resume-live
```

---
**Created**: 2025-09-12  
**For**: Claude Auto-Resume System v1.0.0-alpha  
**Live Session**: claude-auto-resume-live