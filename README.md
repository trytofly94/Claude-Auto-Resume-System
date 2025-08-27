# Claude Auto-Resume System

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Shell](https://img.shields.io/badge/Shell-Bash_4.0+-blue.svg)](https://www.gnu.org/software/bash/)
[![Platform](https://img.shields.io/badge/Platform-macOS%20%7C%20Linux-lightgrey.svg)](#system-requirements)
[![Version](https://img.shields.io/badge/Version-1.0.0--alpha-orange.svg)](#)

A robust automation system for intelligent Claude CLI session management with automatic recovery, usage limit handling, and intelligent task queue processing.

## 🚀 Quick Start

### Installation
```bash
git clone https://github.com/trytofly94/Claude-Auto-Resume-System.git
cd Claude-Auto-Resume-System
./scripts/setup.sh
```

### Basic Usage
```bash
# Start basic monitoring
./src/hybrid-monitor.sh --continuous

# Add tasks to queue and process automatically
./src/hybrid-monitor.sh --add-issue 123 --queue-mode --continuous
```

## ✨ Features

### Core Capabilities
- **Automatic Session Recovery**: Intelligent detection and recovery from Claude CLI failures
- **Usage Limit Handling**: Smart waiting and recovery when usage limits are hit  
- **Task Queue System**: Process multiple GitHub issues, PRs, and custom tasks sequentially
- **Error Recovery**: Comprehensive error handling with automatic retry logic
- **Cross-Platform**: Full support for macOS and Linux environments
- **Performance Optimized**: Efficient handling of large task queues (tested with 1000+ tasks)

### Task Queue System
- **GitHub Integration**: Automatically process GitHub issues and pull requests
- **Progress Tracking**: Real-time status updates and progress monitoring  
- **Backup & Recovery**: Automatic state preservation and recovery mechanisms
- **Concurrent Safe**: Robust file locking for safe concurrent operations
- **Security Hardened**: Comprehensive input validation and sanitization
- **Performance Monitoring**: Resource usage tracking and automatic optimization

## 📖 Documentation

### Task Queue Operations

#### Adding Tasks
```bash
# Add GitHub issue to queue
./src/hybrid-monitor.sh --add-issue 123

# Add GitHub pull request  
./src/hybrid-monitor.sh --add-pr 456

# Add custom task with description
./src/hybrid-monitor.sh --add-custom "Implement dark mode feature"

# Add task from GitHub URL
./src/hybrid-monitor.sh --add-github-url "https://github.com/owner/repo/issues/123"
```

#### Queue Management
```bash
# View current queue status
./src/hybrid-monitor.sh --list-queue

# Start queue processing
./src/hybrid-monitor.sh --queue-mode --continuous

# Pause/resume queue
./src/hybrid-monitor.sh --pause-queue
./src/hybrid-monitor.sh --resume-queue

# Clear all pending tasks
./src/hybrid-monitor.sh --clear-queue
```

#### Advanced Operations
```bash
# Process queue with custom timeout
./src/hybrid-monitor.sh --queue-mode --task-timeout 7200

# Enable test mode (faster cycles for testing)
./src/hybrid-monitor.sh --queue-mode --test-mode 30

# Run with enhanced error recovery
./src/hybrid-monitor.sh --queue-mode --recovery-mode

# Performance monitoring
./src/performance-monitor.sh start
```

### Configuration

#### Basic Configuration (`config/default.conf`)
```bash
# Task Queue Settings
TASK_QUEUE_ENABLED=true
TASK_DEFAULT_TIMEOUT=3600        # 1 hour per task
TASK_MAX_RETRIES=3
TASK_COMPLETION_PATTERN="###TASK_COMPLETE###"

# GitHub Integration  
GITHUB_AUTO_COMMENT=true
GITHUB_STATUS_UPDATES=true
GITHUB_COMPLETION_NOTIFICATIONS=true

# Performance Settings
QUEUE_PROCESSING_DELAY=30        # Seconds between queue checks
QUEUE_MAX_CONCURRENT=1           # Tasks processed simultaneously
TASK_BACKUP_RETENTION_DAYS=30    # Backup retention period

# Error Handling
ERROR_HANDLING_ENABLED=true
ERROR_AUTO_RECOVERY=true
ERROR_MAX_RETRIES=3
TIMEOUT_DETECTION_ENABLED=true
```

#### Advanced Configuration
```bash
# Session Management
USE_CLAUNCH=true
CLAUNCH_MODE="tmux"
SESSION_RECOVERY_TIMEOUT=300

# Usage Limit Handling  
USAGE_LIMIT_COOLDOWN=1800        # 30 minutes
BACKOFF_FACTOR=1.5
MAX_WAIT_TIME=7200               # 2 hours max

# Backup Configuration
BACKUP_ENABLED=true
BACKUP_RETENTION_HOURS=168       # 1 week
BACKUP_CHECKPOINT_FREQUENCY=1800 # 30 minutes

# Performance Tuning
MEMORY_LIMIT_MB=100
LARGE_QUEUE_OPTIMIZATION=true
AUTO_CLEANUP_COMPLETED_TASKS=true
PERFORMANCE_MONITORING=true

# Security Settings
INPUT_VALIDATION=true
SECURITY_AUDIT=true
GITHUB_TOKEN_VALIDATION=true
```

### Performance & Scalability

#### Benchmarks
- **Queue Operations**: < 1 second per operation for queues up to 1000 tasks
- **Memory Usage**: < 100MB for 1000 queued tasks
- **GitHub API**: Respects rate limits with intelligent backoff
- **Processing Speed**: ~10 second overhead per task
- **Error Recovery**: < 30 seconds for automatic recovery

#### Optimization Tips
```bash
# For large queues (100+ tasks)
export LARGE_QUEUE_MODE=true
export BATCH_PROCESSING=true

# For resource-constrained environments  
export CONSERVATIVE_MODE=true
export MEMORY_LIMIT_MB=50

# For high-performance processing
export QUEUE_PROCESSING_DELAY=10
export PARALLEL_OPERATIONS=true

# Enable performance monitoring
./src/performance-monitor.sh --memory-limit 200 start
```

### Troubleshooting

#### Common Issues

**Queue Not Processing**
```bash
# Check queue status
./src/hybrid-monitor.sh --list-queue --verbose

# Verify configuration
./src/hybrid-monitor.sh --check-config

# Check logs
tail -f logs/hybrid-monitor.log
```

**GitHub Integration Issues**
```bash  
# Verify GitHub authentication
gh auth status

# Test API access
gh api user

# Check repository permissions
gh repo view owner/repo
```

**Session Management Problems**
```bash
# Check active sessions
tmux list-sessions | grep claude

# Verify claunch installation
claunch --version

# Manual session recovery
./src/hybrid-monitor.sh --recover-session
```

**Performance Issues**
```bash
# Check memory usage
./src/hybrid-monitor.sh --system-status

# Enable performance monitoring
./src/performance-monitor.sh start

# Generate performance report
./src/performance-monitor.sh report

# Optimize large queues
./src/hybrid-monitor.sh --optimize-queue
```

#### Advanced Troubleshooting

**Debug Mode**
```bash
# Enable comprehensive debugging
export DEBUG_MODE=true
export LOG_LEVEL=DEBUG
./src/hybrid-monitor.sh --queue-mode --continuous
```

**Manual Recovery**
```bash
# Restore from backup
./src/hybrid-monitor.sh --restore-from-backup queue/backups/latest.json

# Reset queue state
./src/hybrid-monitor.sh --reset-queue

# Emergency cleanup
./src/hybrid-monitor.sh --emergency-cleanup
```

**Health Checks**
```bash
# System health validation
./src/hybrid-monitor.sh --check-health --verbose

# Production readiness check
./scripts/production-readiness-check.sh

# Generate diagnostic report
./src/hybrid-monitor.sh --diagnostic-report
```

## 🔒 Security

### Security Features
- **Input Validation**: All user inputs are sanitized and validated
- **Token Protection**: GitHub tokens are never logged or exposed
- **File Permissions**: Appropriate permissions on all queue files
- **Path Validation**: Protection against path traversal attacks
- **Rate Limiting**: Respects GitHub API rate limits
- **Command Injection Protection**: Prevents malicious command execution

### Security Best Practices
```bash
# Set secure file permissions
chmod 600 config/default.conf
chmod 700 queue/

# Use environment variables for sensitive data
export GITHUB_TOKEN="your-token-here"

# Enable security monitoring
export SECURITY_AUDIT=true

# Run security audit
./scripts/run-tests.sh security
```

### Security Validation
```bash
# Input validation testing
./tests/security/test-security-audit.bats

# Token handling verification
export GITHUB_TOKEN="test-token"
./src/hybrid-monitor.sh --add-custom "Security test" --dry-run

# Permission auditing
./scripts/production-readiness-check.sh
```

## 🧪 Testing

### Running Tests
```bash
# Full test suite
./scripts/run-tests.sh

# Unit tests only
./scripts/run-tests.sh unit

# Integration tests
./scripts/run-tests.sh integration

# Performance benchmarks
./scripts/run-tests.sh performance

# Security audit
./scripts/run-tests.sh security

# End-to-end tests
./scripts/run-tests.sh end-to-end
```

### Test Coverage
- **Unit Tests**: 900+ test cases covering all modules
- **Integration Tests**: End-to-end workflows with real GitHub integration
- **Performance Tests**: Load testing with 1000+ tasks
- **Security Tests**: Input validation and penetration testing
- **Error Recovery**: Comprehensive failure scenario testing

### Test Configuration
```bash
# Enable test mode for faster execution
export TEST_MODE=true
export TASK_TIMEOUT=30

# Test with real GitHub integration
export GITHUB_INTEGRATION_TEST=true
export TEST_GITHUB_REPO="owner/test-repo"

# Performance testing
export PERFORMANCE_TEST_LARGE_QUEUE=true
export PERFORMANCE_TEST_CONCURRENT=true
```

## 📋 Requirements

### System Requirements
- **OS**: macOS 10.14+ or Linux (Ubuntu 18.04+, CentOS 7+)
- **Bash**: Version 4.0 or later
- **Memory**: Minimum 256MB available RAM
- **Storage**: 100MB free space for logs and backups

### Dependencies
- **Required**: Git, Claude CLI, tmux, jq, curl
- **Recommended**: GitHub CLI (gh), claunch
- **Optional**: BATS (for testing), ShellCheck (for development)

### Installation Verification
```bash
# Check all dependencies
./scripts/setup.sh --check-deps

# Verify installation  
./src/hybrid-monitor.sh --version --check-health

# Validate production readiness
./scripts/production-readiness-check.sh
```

## 🏗️ Architecture

### System Components
```
Claude-Auto-Resume/
├── src/                                   # Core implementation
│   ├── hybrid-monitor.sh                  # Main monitoring script
│   ├── task-queue.sh                      # Task queue core module
│   ├── github-integration.sh              # GitHub API integration
│   ├── session-recovery.sh                # Session recovery system
│   ├── error-classification.sh            # Error handling engine
│   ├── performance-monitor.sh             # Performance monitoring
│   └── utils/                             # Utility functions
├── tests/                                 # Comprehensive test suite
│   ├── unit/                              # Unit tests
│   ├── integration/                       # Integration tests
│   ├── security/                          # Security audit tests
│   └── performance/                       # Performance benchmarks
├── config/                                # Configuration management
├── scripts/                               # Setup and utility scripts
└── docs/                                  # Documentation
```

### Task Processing Flow
```
1. Task Creation → 2. Validation → 3. Queue Storage → 4. Processing → 5. GitHub Update → 6. Completion
     ↓                  ↓              ↓               ↓               ↓                ↓
   Input           Security        JSON File       Claude CLI      API Comments     Archival
   Sanitization    Validation      Backup          Execution       Status Update    Cleanup
```

### Error Handling Strategy
```
Error Detection → Classification → Recovery Strategy → Implementation → Validation
      ↓                ↓                  ↓                 ↓              ↓
  Monitoring      Error Types     Retry/Restart      Auto-Recovery    Success Check
  Timeouts        Categories      Session Reset      Manual Steps     Failure Log
  API Failures    Severity        Backup Restore     Notification     Escalation
```

## 🤝 Contributing

### Development Setup
```bash
# Install development dependencies
./scripts/dev-setup.sh

# Run code quality checks
shellcheck src/**/*.sh
./scripts/run-tests.sh

# Create feature branch
git checkout -b feature/your-feature-name
```

### Code Standards
- **Shell Script**: ShellCheck compliant, `set -euo pipefail`
- **Testing**: BATS test framework, comprehensive coverage
- **Documentation**: Inline comments, updated README
- **Security**: Input validation, no secrets in logs

### Development Workflow
```bash
# 1. Setup development environment
./scripts/dev-setup.sh

# 2. Create feature branch
git checkout -b feature/new-functionality

# 3. Implement changes with tests
# ... develop ...

# 4. Run comprehensive tests
./scripts/run-tests.sh

# 5. Security and performance validation
./scripts/run-tests.sh security performance

# 6. Production readiness check
./scripts/production-readiness-check.sh

# 7. Create pull request with documentation
```

## 📊 Performance Monitoring

### Real-time Monitoring
```bash
# Start performance monitoring
./src/performance-monitor.sh start

# Check current status
./src/performance-monitor.sh status

# Generate performance report
./src/performance-monitor.sh report
```

### Performance Metrics
- **Memory Usage**: Real-time process and system memory tracking
- **Queue Performance**: Operation timing and throughput metrics
- **GitHub API**: Rate limit usage and response times
- **System Resources**: CPU, memory, and disk usage monitoring

### Performance Optimization
```bash
# Auto-optimization based on conditions
./src/performance-monitor.sh optimize

# Manual cleanup and optimization
./src/performance-monitor.sh cleanup

# Conservative mode for resource-constrained systems
./src/performance-monitor.sh --conservative start
```

## 🚀 Production Deployment

### Pre-deployment Checklist
```bash
# 1. Verify system requirements
./scripts/setup.sh --check-deps

# 2. Run production readiness check
./scripts/production-readiness-check.sh

# 3. Validate configuration
./src/hybrid-monitor.sh --check-config

# 4. Run comprehensive test suite
./scripts/run-tests.sh

# 5. Security audit
./scripts/run-tests.sh security

# 6. Performance validation
./scripts/run-tests.sh performance
```

### Production Configuration
```bash
# config/production.conf
TASK_QUEUE_ENABLED=true
PERFORMANCE_MONITORING=true
AUTO_CLEANUP=true
SECURITY_AUDIT=true
LOG_LEVEL=INFO
MEMORY_LIMIT_MB=200
GITHUB_AUTO_COMMENT=true
ERROR_HANDLING_ENABLED=true
BACKUP_ENABLED=true
```

### Monitoring and Maintenance
```bash
# System health monitoring
./src/hybrid-monitor.sh --system-status

# Performance monitoring
./src/performance-monitor.sh start

# Log monitoring
tail -f logs/hybrid-monitor.log

# Backup verification
ls -la queue/backups/

# Resource cleanup
./src/performance-monitor.sh cleanup
```

## 📞 Support

### Getting Help
- **Documentation**: This README and inline help (`--help`)
- **Troubleshooting**: See troubleshooting section above
- **Issues**: Report bugs on [GitHub Issues](https://github.com/trytofly94/Claude-Auto-Resume-System/issues)
- **Discussions**: Join [GitHub Discussions](https://github.com/trytofly94/Claude-Auto-Resume-System/discussions)

### Diagnostics
```bash
# Generate comprehensive diagnostic report
./src/hybrid-monitor.sh --diagnostic-report

# System health check with verbose output
./src/hybrid-monitor.sh --health-check --verbose

# Export current configuration
./src/hybrid-monitor.sh --export-config > my-config.conf

# Performance analysis
./src/performance-monitor.sh report /tmp/perf-report.txt
```

### Common Support Scenarios

**Installation Issues**
```bash
# Check system compatibility
./scripts/setup.sh --check-system

# Verify dependencies
./scripts/setup.sh --check-deps --verbose

# Manual installation
./scripts/setup.sh --manual
```

**Runtime Problems**
```bash
# Enable debug mode
export DEBUG_MODE=true LOG_LEVEL=DEBUG

# Monitor in real-time
./src/hybrid-monitor.sh --continuous --verbose

# Check system resources
./src/performance-monitor.sh status
```

**Performance Problems**
```bash
# Enable performance monitoring
./src/performance-monitor.sh --memory-limit 200 start

# Generate analysis report
./src/performance-monitor.sh report

# Apply optimizations
./src/performance-monitor.sh optimize
```

## 🎯 Roadmap

### Version 1.0.0 (Current)
- ✅ Core task queue system
- ✅ GitHub integration
- ✅ Performance monitoring
- ✅ Security hardening
- ✅ Comprehensive testing
- ✅ Production readiness

### Version 1.1.0 (Planned)
- [ ] Web UI for queue management
- [ ] Advanced scheduling capabilities
- [ ] Multi-repository support
- [ ] Enhanced reporting dashboards
- [ ] Plugin architecture

### Version 1.2.0 (Future)
- [ ] Distributed processing
- [ ] Cloud deployment support
- [ ] Advanced AI integration
- [ ] Real-time collaboration features

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- **Claude AI** for intelligent task processing capabilities
- **GitHub** for API integration and collaboration features  
- **[terryso/claude-auto-resume](https://github.com/terryso/claude-auto-resume)** for the original auto-resume concept
- **[0xkaz/claunch](https://github.com/0xkaz/claunch)** for project-based session management
- **The open-source community** for tools and inspiration

---

**Made with ❤️ for the Claude CLI community**

For detailed technical documentation, see the [docs/](docs/) directory.
For development guidelines, see [CONTRIBUTING.md](CONTRIBUTING.md).
For security information, see [SECURITY.md](SECURITY.md).