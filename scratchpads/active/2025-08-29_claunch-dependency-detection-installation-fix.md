# Claunch Dependency Detection and Installation Fix

**Erstellt**: 2025-08-29
**Typ**: Bug/Enhancement
**Geschätzter Aufwand**: Mittel
**Verwandtes Issue**: GitHub #77 - Missing Claunch Dependency Detection and Installation

## Kontext & Ziel

GitHub Issue #77 beschreibt kritische Probleme mit der claunch-Dependency-Erkennung und Installation im Claude Auto-Resume System. Das System erwartet claunch unter `/usr/local/bin/claunch`, kann aber den Binary nicht finden, was zur Fehlermeldung `/usr/local/bin/claunch: No such file or directory` führt.

**Kern-Problem**: Das System scheitert bei der claunch-Erkennung und bietet keine robuste Fallback-Mechanismen oder benutzerfreundliche Leitfäden für die Installation.

## Anforderungen

- [ ] Verbesserte claunch-Detection-Logic mit mehreren Suchstrategien
- [ ] Robuste Installationsverifizierung mit Retry-Logic
- [ ] Intelligente PATH-Management für verschiedene Installationsorte
- [ ] Graceful Fallback auf direkten Claude CLI Modus wenn claunch nicht verfügbar
- [ ] Benutzerfreundliche Fehlermeldungen und Installationsanleitungen
- [ ] Integration der vorhandenen robusten Installation aus Scratchpad 2025-08-27_claunch-installation-enhancement.md
- [ ] Umfassende Tests für verschiedene Installationsszenarien

## Untersuchung & Analyse

### Prior Art Recherche

**Verwandte abgeschlossene Arbeiten:**
1. **2025-08-27_claunch-installation-enhancement.md** (completed) - Umfangreiche Verbesserungen der claunch-Installation mit official installer method, enhanced PATH-Management und 5-stufiger Verifikation
2. **2025-08-06_review-issue-4-claunch-verification.md** (active) - Behandelt PATH- und Verifikationsprobleme
3. **2025-08-05_claunch-claude-auto-resume-implementation.md** (completed) - Ursprüngliche claunch-Integration

**Erkannte Lücken:**
- Das abgeschlossene Enhancement-Work aus 2025-08-27 behandelt bereits viele der in Issue #77 genannten Probleme
- Es fehlt die Integration der verbesserten Detection-Logic in `src/claunch-integration.sh`
- Die Setup-Scripts nutzen noch nicht vollständig die enhanced verification
- Fehlende Fallback-Mechanismen bei claunch-Detection-Failure

### Aktuelle Code-Analyse

**Problematische Bereiche in `src/claunch-integration.sh`:**
- Zeile 60-89: `detect_claunch()` - Zu simple Detection-Logic
- Zeile 92-114: `validate_claunch()` - Fehlende Retry-Mechanismen
- Hardcoded Paths und fehlende Fallback-Strategien

**Problematische Bereiche in `scripts/setup.sh`:**
- Zeile 587-605: `verify_claunch_installation()` - Zu basic für robuste Verifikation
- Fehlende Integration mit enhanced claunch installer von 2025-08-27

**Verfügbare Lösungen aus 2025-08-27:**
- Enhanced PATH-Management mit `refresh_shell_path()`
- 5-stufige Verifikation mit mehreren Detection-Methoden
- Comprehensive network resilience und retry-logic
- Official installer integration als primäre Methode

## Implementierungsplan

### Phase 1: Enhanced Detection Integration
- [ ] **1.1**: Integration der enhanced detection logic aus 2025-08-27 in `src/claunch-integration.sh`
  - Multi-method claunch detection (PATH, common directories, functional tests)
  - Enhanced `refresh_shell_path()` Function 
  - 5-round verification mit verschiedenen Strategien
- [ ] **1.2**: Fallback-Mechanismen implementieren
  - Graceful degradation auf direct Claude CLI mode
  - Clear user guidance bei claunch-nicht-verfügbar
  - Runtime-Detection mit automatic mode switching

### Phase 2: Robuste Installation und Verifikation
- [ ] **2.1**: Integration des enhanced installers in setup process
  - `scripts/setup.sh` um comprehensive claunch verification erweitern
  - Official installer method als Standard (aus 2025-08-27 work)
  - Network resilience und retry-logic für Installation
- [ ] **2.2**: PATH-Management verbessern
  - Automatisches PATH-Update für verschiedene Shell-Konfigurationen
  - Detection von verschiedenen Installation-Locations
  - Shell-restart-guidance bei PATH-changes

### Phase 3: Benutzerfreundliche Fehlermeldungen
- [ ] **3.1**: Enhanced error reporting implementieren
  - Detaillierte Diagnose bei claunch-detection-failure
  - Schritt-für-Schritt Installation-guidance
  - System-spezifische Empfehlungen (macOS vs Linux)
- [ ] **3.2**: Interactive installation prompts
  - Automatic installation offer bei detection failure
  - Choice zwischen installation methods (official, npm, source)
  - Progress feedback während installation

### Phase 4: Fallback und Degradation
- [ ] **4.1**: Intelligent fallback system implementieren
  - Automatic switch zu direct Claude CLI mode
  - Session management ohne claunch (simplified mode)
  - Clear user notification über mode-switch
- [ ] **4.2**: Runtime claunch availability checking
  - Periodic re-checking für claunch availability
  - Automatic upgrade zu claunch mode wenn verfügbar
  - Configuration persistence für user preferences

### Phase 5: Tests und Validierung
- [ ] **5.1**: Comprehensive test scenarios erstellen
  - claunch not installed scenario
  - claunch installed but not in PATH
  - claunch installed but not functional
  - Various installation paths testing
- [ ] **5.2**: Integration tests erweitern
  - End-to-end testing mit installation process
  - Fallback mechanism validation
  - Cross-platform compatibility (macOS, Linux)
- [ ] **5.3**: User experience testing
  - Fresh system setup testing
  - Error message clarity validation
  - Installation guidance effectiveness

## Fortschrittsnotizen

[Laufende Notizen über Fortschritt, Blocker und Entscheidungen werden hier dokumentiert]

## Ressourcen & Referenzen

### Verwandte Issues und PRs
- **GitHub #77**: Missing Claunch Dependency Detection and Installation (primary)
- **GitHub #38**: claunch installation (addressed in 2025-08-27 work)
- **GitHub #4**: PATH und Verifikation (referenced in 2025-08-27 work)

### Abgeschlossene Arbeiten
- **2025-08-27_claunch-installation-enhancement.md**: Comprehensive claunch installation improvements
- **scripts/install-claunch.sh**: Enhanced installer mit official method, network resilience
- **Existing detection logic**: `src/claunch-integration.sh` detect_claunch(), validate_claunch()

### Technische Dokumentation
- **claunch GitHub**: https://github.com/0xkaz/claunch
- **Official installer**: https://raw.githubusercontent.com/0xkaz/claunch/main/install.sh
- **Project configuration**: /CLAUDE.md

### Fehlermeldung aus Issue #77
```bash
/usr/local/bin/claunch: No such file or directory
Failed to start claunch session (exit code: 127)
```

### Betroffene Dateien
- `src/claunch-integration.sh` (primary detection logic)
- `scripts/install-claunch.sh` (installation, bereits enhanced)
- `scripts/setup.sh` (setup integration)
- `src/session-manager.sh` (fallback integration)
- `config/default.conf` (configuration options)

## Abschluss-Checkliste

- [ ] Enhanced claunch detection mit 5 verschiedenen Methoden implementiert
- [ ] Fallback auf direct Claude CLI mode funktional
- [ ] Setup-Script integration mit comprehensive verification
- [ ] Benutzerfreundliche Fehlermeldungen und Installation-guidance
- [ ] PATH-Management für verschiedene Installation-Szenarien
- [ ] Comprehensive test coverage für alle scenarios
- [ ] Cross-platform compatibility validiert (macOS, Linux)
- [ ] Integration mit existing enhanced installer (2025-08-27 work)
- [ ] Runtime claunch availability checking implementiert
- [ ] Dokumentation aktualisiert (README, Setup-Guides)

---
**Status**: Aktiv
**Zuletzt aktualisiert**: 2025-08-29

## Implementation Strategy Notes

### Integration mit 2025-08-27 Enhancement Work
Das abgeschlossene Scratchpad 2025-08-27_claunch-installation-enhancement.md enthält bereits viele der benötigten Lösungen:
- ✅ Official installer method (GitHub #38)
- ✅ Enhanced PATH-Management mit `refresh_shell_path()`
- ✅ 5-round comprehensive verification
- ✅ Network resilience mit retry-logic
- ✅ Multiple installation method fallbacks

**Strategie**: Statt Doppelarbeit zu leisten, diese bereits implementierten Lösungen in die core detection und session management Logik integrieren.

### Priorität der Detection-Methoden (nach 2025-08-27 Enhancement):
1. **PATH lookup**: Standard `command -v claunch`
2. **Install target check**: `$INSTALL_TARGET/claunch`
3. **Common paths**: ~/.local/bin, ~/bin, /usr/local/bin, etc.
4. **NVM paths**: Node version manager locations
5. **which/whereis commands**: Fallback detection tools

### Fallback-Chain bei Detection-Failure:
1. **Try automatic installation**: Offer user to install claunch
2. **Official installer method**: Use enhanced installer from 2025-08-27
3. **Alternative methods**: npm, source installation als fallback
4. **Direct Claude mode**: Graceful degradation ohne claunch
5. **User guidance**: Clear instructions für manual installation

### Error Message Enhancement Strategy:
- **Diagnostic information**: System, PATH, available tools
- **Specific guidance**: Based on detected system configuration
- **Installation options**: Multiple paths mit user choice
- **Fallback notification**: Clear explanation of direct mode