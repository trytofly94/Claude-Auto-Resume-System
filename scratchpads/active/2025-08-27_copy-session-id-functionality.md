# Session ID Kopier-Funktionalität

**Erstellt**: 2025-08-27
**Typ**: Enhancement
**Geschätzter Aufwand**: Mittel
**Verwandtes Issue**: GitHub #39

## Kontext & Ziel
Benutzer können aktuell Session-IDs nicht aus dem tmux-Terminal kopieren und daher Sessions nicht effektiv wiederverwenden. Dies ist ein kritisches Usability-Problem im Claude Auto-Resume-System, da die Session-Wiederverwendung ein Kernfeature ist.

## Anforderungen
- [ ] Session-IDs müssen leicht sichtbar und kopierbar sein
- [ ] Implementierung einer dedizierten Session-ID-Anzeige-Funktion
- [ ] Integration von Clipboard-Funktionalität (plattformübergreifend)
- [ ] Bereitstellung von Session-Reuse-Workflows
- [ ] Benutzerfreundliche Kommandos zum Session-Management
- [ ] Kompatibilität mit bestehender tmux-Integration
- [ ] Unterstützung für macOS und Linux Clipboard-Systeme

## Untersuchung & Analyse

### Existierende Session-ID-Behandlung
Das System verwendet bereits Session-IDs in mehreren Bereichen:

1. **Session-Manager (`session-manager.sh`)**:
   - Generiert Session-IDs: `${project_name}-${timestamp}-$$`
   - Speichert Session-Informationen in assoziativen Arrays
   - Bietet `get_session_info()` und `list_sessions()` Funktionen

2. **Hybrid-Monitor (`hybrid-monitor.sh`)**:
   - Variable `MAIN_SESSION_ID` für aktive Session-Verfolgung
   - Verwendet Session-IDs für Health-Checks und Recovery

3. **claunch-Integration (`claunch-integration.sh`)**:
   - Session-Dateien: `$HOME/.claude_session_${PROJECT_NAME}`
   - tmux-Session-Namen: `${TMUX_SESSION_PREFIX}-${PROJECT_NAME}`

### Problem-Identifikation
- Session-IDs werden intern verwaltet, aber nicht benutzerfreundlich angezeigt
- Keine direkten Kopiermechanismen implementiert
- tmux-Umgebung macht Textauswahl/Kopieren schwierig
- Fehlende Workflows für Session-Wiederverwendung

### Plattform-spezifische Clipboard-Unterstützung
- **macOS**: `pbcopy`, `pbpaste`
- **Linux**: `xclip`, `xsel`, oder `wl-clipboard` (Wayland)
- **Terminal-integriert**: tmux-eigene Clipboard-Integration

## Implementierungsplan
- [ ] Schritt 1: Session-Display-Modul erstellen (`src/utils/session-display.sh`)
- [ ] Schritt 2: Clipboard-Utility-Funktionen implementieren (`src/utils/clipboard.sh`)
- [ ] Schritt 3: Session-ID-Anzeige-Kommandos hinzufügen
- [ ] Schritt 4: Clipboard-Integration in Session-Manager einbauen
- [ ] Schritt 5: CLI-Parameter für Session-Management erweitern
- [ ] Schritt 6: tmux-spezifische Session-Display-Features implementieren
- [ ] Schritt 7: Session-Reuse-Workflows erstellen
- [ ] Schritt 8: Dokumentation und Hilfetexte erweitern
- [ ] Tests schreiben und Integration validieren
- [ ] Dokumentations-Updates

## Detaillierte Implementierungsschritte

### Schritt 1: Session-Display-Modul (`src/utils/session-display.sh`)
```bash
# Funktionen für benutzerfreundliche Session-Anzeige
show_current_session_id()
show_session_summary()
format_session_info()
display_copyable_session_id()
```

### Schritt 2: Clipboard-Utility (`src/utils/clipboard.sh`)
```bash
# Plattformübergreifende Clipboard-Funktionen
detect_clipboard_tool()
copy_to_clipboard()
paste_from_clipboard()
is_clipboard_available()
```

### Schritt 3: CLI-Parameter erweitern
```bash
# Neue Optionen für hybrid-monitor.sh
--show-session-id     # Aktuelle Session-ID anzeigen
--copy-session-id     # Session-ID in Clipboard kopieren
--list-sessions       # Alle Sessions mit kopierbaren IDs
--resume-session ID   # Session mit spezifischer ID fortsetzen
```

### Schritt 4: tmux-Integration
```bash
# tmux-spezifische Features
# Status-Bar-Integration für Session-ID-Anzeige
# Key-Bindings für Session-ID-Kopieren
# Session-Browser mit kopierbaren IDs
```

### Schritt 5: Session-Reuse-Workflows
```bash
# Workflow-Kommandos
save_session_for_reuse()
load_saved_session()
bookmark_session()
list_bookmarked_sessions()
```

## Technische Herausforderungen
1. **Plattform-Kompatibilität**: Unterschiedliche Clipboard-Tools
2. **tmux-Integration**: Seamless Copy-Paste innerhalb tmux
3. **Session-Persistenz**: Langfristige Session-Speicherung
4. **User Experience**: Intuitive Bedienung ohne komplexe Kommandos
5. **Security**: Session-IDs könnten sensitive Information enthalten

## Fortschrittsnotizen
- Issue #39 identifiziert das Kernproblem: Session-IDs nicht kopierbar in tmux
- Bestehende Infrastruktur bietet gute Grundlage für Erweiterung
- Session-Manager bereits vorhanden und funktional
- tmux-Integration ist bereits implementiert, muss nur erweitert werden

## Ressourcen & Referenzen
- GitHub Issue #39: "copy session id"
- Bestehende Session-Management-Implementierung in `src/session-manager.sh`
- tmux-Integration in `src/claunch-integration.sh`
- Clipboard-Tools-Dokumentation:
  - macOS: `man pbcopy`
  - Linux: `man xclip`, `man xsel`
  - tmux: `man tmux` (copy-mode, buffers)

## Abschluss-Checkliste
- [ ] Session-Display-Modul implementiert und getestet
- [ ] Clipboard-Funktionalität für macOS und Linux
- [ ] CLI-Parameter für Session-Management hinzugefügt
- [ ] tmux-spezifische Kopierfunktionen implementiert
- [ ] Session-Reuse-Workflows erstellt und dokumentiert
- [ ] Tests für alle neuen Funktionen geschrieben
- [ ] Benutzerhandbuch mit Copy-Paste-Workflows aktualisiert
- [ ] Cross-Platform-Tests auf macOS und Linux durchgeführt

---
**Status**: Aktiv
**Zuletzt aktualisiert**: 2025-08-27