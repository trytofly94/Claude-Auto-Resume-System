# Claude Auto-Resume System - Development Makefile
# Standardisierte Befehle für Entwicklung, Testing und Wartung
# Version: 1.0.0

.PHONY: help test lint clean validate debug setup wizard-test install deps

# Default target
all: validate test

##@ Help
help: ## Display this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Development
validate: ## Run syntax validation on all shell scripts
	@echo "🔍 Running syntax validation..."
	@find src/ -name "*.sh" -exec bash -n {} + && echo "✅ All scripts have valid syntax" || echo "❌ Syntax errors found"

lint: ## Run ShellCheck linting on all shell scripts
	@echo "🔍 Running ShellCheck..."
	@if command -v shellcheck >/dev/null 2>&1; then \
		find src/ scripts/ -name "*.sh" -exec shellcheck {} + && echo "✅ ShellCheck passed"; \
	else \
		echo "⚠️ ShellCheck not installed. Install with: brew install shellcheck"; \
	fi

debug: ## Run environment debug script
	@echo "🔧 Running environment diagnostics..."
	@scripts/debug-environment.sh

##@ Testing  
test: ## Run all tests
	@echo "🧪 Running all tests..."
	@scripts/run-tests.sh

test-unit: ## Run only unit tests
	@echo "🧪 Running unit tests..."
	@scripts/run-tests.sh unit

test-integration: ## Run only integration tests  
	@echo "🧪 Running integration tests..."
	@scripts/run-tests.sh integration

test-wizard: ## Test setup wizard specifically
	@echo "🧙‍♂️ Testing setup wizard..."
	@bats tests/unit/test-setup-wizard*.bats tests/integration/test-setup-wizard*.bats

wizard-test: ## Test wizard modular architecture
	@echo "🏗️ Testing wizard modular vs monolithic..."
	@scripts/test-wizard-modules.sh

##@ Maintenance
clean: ## Clean temporary files and logs
	@echo "🧹 Cleaning temporary files..."
	@rm -rf logs/*.log tmp/ .tmp/ || true
	@rm -rf queue/backups/*.json || true
	@find . -name "*.tmp" -delete || true
	@find . -name "*.temp" -delete || true
	@echo "✅ Cleanup complete"

deep-clean: ## Deep clean: remove all test artifacts and reports from root
	@echo "🗑️ Deep cleaning project root..."
	@rm -f test-*.sh test_*.sh benchmark-*.sh debug_*.sh deploy-*.sh production-*.sh || true
	@rm -f *TEST_REPORT*.md *COVERAGE*.md *COMPATIBILITY*.md *CHECKLIST*.md || true
	@rm -f test-*.json test-*.log test-*.txt *-test-*.* hanging-*.txt || true
	@rm -f *.log monitor-*.log || true
	@echo "✅ Deep cleanup complete"

auto-clean: ## Auto-clean after each development session
	@make clean
	@make git-unstage-logs
	@make deep-clean

setup: ## Run initial project setup
	@echo "⚙️ Running project setup..."
	@scripts/setup.sh

install-deps: ## Install development dependencies
	@echo "📦 Installing dependencies..."
	@scripts/dev-setup.sh

##@ Wizard Operations
wizard: ## Run the setup wizard
	@echo "🧙‍♂️ Starting setup wizard..."
	@src/setup-wizard.sh --setup-wizard

wizard-help: ## Show wizard help
	@src/setup-wizard.sh --help

##@ Git Operations  
git-clean: ## Clean git working directory (careful!)
	@echo "🗑️ Cleaning git working directory..."
	@git status --porcelain | grep -E "^(\?\?|M )" | cut -c4- | grep -E "\.(log|tmp|temp)$$" | xargs rm -f || true
	@echo "✅ Git workspace cleaned"

git-unstage-logs: ## Unstage any accidentally staged log files
	@echo "🔄 Unstaging log files..."
	@git reset HEAD logs/ 2>/dev/null || true
	@git reset HEAD "\"logs/"* 2>/dev/null || true
	@git reset HEAD queue/task-queue.json 2>/dev/null || true
	@echo "✅ Log files unstaged"

##@ Monitoring
monitor: ## Start hybrid monitoring
	@echo "🔄 Starting hybrid monitoring..."
	@src/hybrid-monitor.sh --continuous

monitor-test: ## Test monitoring in test mode
	@echo "🧪 Starting monitoring test mode..."
	@src/hybrid-monitor.sh --test-mode 30

status: ## Show system status
	@echo "📊 System status..."
	@src/hybrid-monitor.sh --system-status

##@ Documentation
docs: ## Generate/update documentation
	@echo "📚 Updating documentation..."
	@echo "README and docs are maintained manually"

##@ Quick Commands
quick-test: validate test-unit ## Quick development test cycle
	@echo "🚀 Quick test cycle complete"

dev-cycle: clean validate lint test ## Full development cycle
	@echo "🔄 Full development cycle complete"

pre-commit: git-unstage-logs validate lint test-unit ## Pre-commit validation
	@echo "✅ Pre-commit checks passed"