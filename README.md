# Claude Auto-Resume System

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Shell](https://img.shields.io/badge/Shell-Bash_4.0+-blue.svg)](https://www.gnu.org/software/bash/)
[![Platform](https://img.shields.io/badge/Platform-macOS%20%7C%20Linux-lightgrey.svg)](#requirements)

Intelligentes Automatisierungssystem für robustes Claude CLI Session-Management mit automatischer Wiederherstellung nach Usage-Limits und Verbindungsfehlern.

## Features

- 🔄 **Automatische Session-Wiederherstellung** nach Usage-Limits
- ⏱️ **Intelligente Wartezeiten** mit exponentiellen Backoff-Strategien  
- 🖥️ **tmux-Integration** für persistente Terminal-Sessions
- 📊 **Präzise Usage-Limit-Detection** mit Live-Countdown
- 🛡️ **Fehlertolerante Wiederverbindung** bei Netzwerkproblemen
- 📝 **Strukturiertes Logging** für Debugging und Monitoring
- 📋 **Task Queue System** für GitHub Issue-Management
- 🔧 **Cross-Platform-Support** (macOS, Linux)

## Requirements

- **Claude CLI** - [Anthropic Claude CLI](https://claude.ai/code)
- **Bash 4.0+** - Shell-Environment
- **tmux** - Terminal-Multiplexer
- **jq** - JSON-Processor
- **claunch** - Session-Management (wird automatisch installiert)

**Unterstützte Plattformen**: macOS 10.14+, Linux (Ubuntu 18.04+)

## Installation

```bash
# Repository klonen
git clone https://github.com/trytofly94/Claude-Auto-Resume-System.git
cd Claude-Auto-Resume-System

# Automatische Installation mit Setup-Wizard
./scripts/setup.sh

# Oder manuelle Installation
chmod +x src/*.sh scripts/*.sh
./scripts/install-claunch.sh  # claunch installieren (optional)
```

## Quick Start

```bash
# Continuous Monitoring starten
./src/hybrid-monitor.sh --continuous

# Mit Konfiguration
./src/hybrid-monitor.sh --continuous --config config/user.conf

# Test-Modus (30 Sekunden)
./src/hybrid-monitor.sh --test-mode 30

# Hilfe anzeigen
./src/hybrid-monitor.sh --help
```

## Task Queue (Optional)

```bash
# Task hinzufügen
./src/task-queue.sh add-custom "Fix authentication bug"

# GitHub Issue als Task
./src/task-queue.sh add-issue 123

# Status anzeigen
./src/task-queue.sh status

# Interactive Mode
./src/task-queue.sh interactive
```

## Configuration

Konfigurationsdateien in `config/`:
- `default.conf` - Standardkonfiguration
- `user.conf` - Benutzerspezifische Einstellungen (optional)

Wichtige Parameter:
```bash
CHECK_INTERVAL_MINUTES=5      # Monitoring-Intervall
MAX_RESTARTS=50              # Maximale Neustarts
USAGE_LIMIT_COOLDOWN=300     # Wartezeit bei Usage-Limits (Sekunden)
LOG_LEVEL="INFO"             # Logging-Level
```

## Troubleshooting

```bash
# System-Diagnose
make debug

# Logs prüfen
tail -f logs/hybrid-monitor.log

# Test-Suite ausführen
make test
```

### Häufige Probleme

- **"declare -A: invalid option"**: Bash 4.0+ erforderlich - `brew install bash` (macOS)
- **claunch nicht gefunden**: Wird automatisch installiert, sonst `./scripts/install-claunch.sh`
- **flock Warnung**: Normal auf macOS, alternative Implementierung wird verwendet

## Documentation

- **[DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md)** - Detaillierte Installationsanleitung
- **[CLAUDE.md](CLAUDE.md)** - Projektspezifische Konfiguration
- **[docs/](docs/)** - Entwicklerdokumentation
- **[CHANGELOG.md](CHANGELOG.md)** - Versionshistorie

## Development

```bash
# Entwicklungsumgebung
make dev-setup

# Tests ausführen
make test

# Code-Qualität
make lint
make validate

# Development-Zyklus
make dev-cycle
```

## Contributing

1. Fork the repository
2. Create feature branch (`git checkout -b feature/amazing-feature`)
3. Commit changes (`git commit -m 'Add amazing feature'`)
4. Push to branch (`git push origin feature/amazing-feature`)
5. Open Pull Request

## License

MIT License - siehe [LICENSE](LICENSE) für Details.

## Credits

Basiert auf:
- [terryso/claude-auto-resume](https://github.com/terryso/claude-auto-resume) - Original Auto-Resume System
- [0xkaz/claunch](https://github.com/0xkaz/claunch) - Claude Launch Utility

---

**Version**: 1.1.0-stable | **Status**: Production Ready