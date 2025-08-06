# Claude Auto-Resume Continuous - Version 4 mit Claude-Flag-Weiterleitung

## Übersicht

Das `claude-auto-resume-continuous-v4` Skript dient als Wrapper für die Claude CLI. Es ermöglicht eine kontinuierliche Überwachung von Claude-Sitzungen mit periodischen Limit-Checks und leitet **alle Standard-Claude-CLI-Flags** direkt an den `claude`-Befehl weiter.

Diese Version kombiniert robuste Automatisierung mit der vollen Flexibilität der nativen Claude CLI.

## 🚀 Was ist Neu?

**Volle Claude-Flag-Unterstützung:** Das Skript wurde überarbeitet, um nahtlos alle Kommandozeilenargumente zu akzeptieren, die nicht zu den Wrapper-Optionen gehören, und sie direkt an die `claude` CLI durchzureichen.

- Verwenden Sie Flags wie `--model`, `--verbose`, `-p` (print), `--max-turns` etc. wie gewohnt.
- Der Wrapper kümmert sich um die Automatisierung, Claude um die Ausführung.

## Kernfunktionen

### ✅ Intelligente Weiterleitung & Robuste Überwachung
- **Nahtlose Flag-Weiterleitung**: Alle unbekannten Argumente werden direkt an `claude` weitergeleitet.
- **Periodische Limit-Checks**: Überprüft in konfigurierbaren Intervallen, ob ein Usage Limit erreicht ist.
- **Zuverlässiger Neustart**: Startet Claude nur dann in einem neuen Terminal, wenn **kein** Limit besteht.

### 🖥️ Flexibles Terminal-Management
- **Öffnet Claude in separaten Terminal-Fenstern** für maximale Isolation.
- **Korrekte Verzeichnis-Konsistenz**: Neue Terminals starten immer im ursprünglichen Arbeitsverzeichnis.
- **Breite Terminal-Unterstützung**:
  - **macOS**: Terminal.app, iTerm2
  - **Linux**: gnome-terminal, konsole, xterm

## Installation

```bash
# Skript ausführbar machen
chmod +x claude-auto-resume-continuous-v4

# Optional: In ein PATH-Verzeichnis kopieren
cp claude-auto-resume-continuous-v4 /usr/local/bin/
```

## Verwendung

### Grundlegende Verwendung

```bash
# Startet die kontinuierliche Überwachung mit einem Prompt und einem spezifischen Modell
./claude-auto-resume-continuous-v4 --continuous --new-terminal "implement feature" --model claude-3-opus-20240229
```

### Erweiterte Optionen

```bash
# Fortsetzung der letzten Konversation mit 10-Minuten-Intervall und Claude's verbose mode
./claude-auto-resume-continuous-v4 --continuous --new-terminal --check-interval 10 -c "continue previous task" --verbose

# Eine nicht-interaktive Anfrage mit JSON-Ausgabe ausführen (ohne continuous mode)
./claude-auto-resume-continuous-v4 -p "list files in current dir" --output-format json

# Mit spezifischer Terminal-App und Debug-Ausgabe des Wrappers
./claude-auto-resume-continuous-v4 --continuous --new-terminal --terminal-app iterm --debug "task"
```

### Test-Modus

```bash
# Simuliert ein Usage Limit mit 30 Sekunden Wartezeit für Tests
./claude-auto-resume-continuous-v4 --test-mode 30 --continuous --new-terminal --debug "test"
```

## Kommandozeilen-Optionen

Das Skript unterscheidet zwischen **Wrapper-Optionen** (zur Steuerung des Skripts) und **Claude-Argumenten** (die weitergeleitet werden).

### Wrapper-Optionen
| Option | Beschreibung | Standard |
|--------|-------------|----------|
| `--continuous` | Aktiviert die kontinuierliche Überwachung. | Deaktiviert |
| `--new-terminal` | Öffnet Claude in neuen Terminal-Fenstern. | Deaktiviert |
| `--check-interval N` | Intervall für die Limit-Prüfung in Minuten. | 5 |
| `--max-restarts N` | Maximale Anzahl von Prüfzyklen. | 50 |
| `--terminal-app APP` | Spezifiziert die Terminal-Anwendung (z.B. `iterm`, `terminal`). | Auto-Detect |
| `--debug` | Aktiviert detaillierte Debug-Ausgaben für den Wrapper. | Deaktiviert |
| `--test-mode SECONDS` | Simuliert ein Usage Limit für Tests. | Deaktiviert |
| `--claudetest` | Überspringt den ersten Limit-Check zum Testen. | Deaktiviert |
| `-h, --help` | Zeigt die Hilfe für den Wrapper an. | |
| `-v, --version` | Zeigt die Versionsnummer des Wrappers an. | |

### Claude-Argumente (werden weitergeleitet)
Alle anderen Argumente werden direkt an die `claude` CLI weitergereicht.

**Beispiele:**
- Ein Prompt: `"Implementiere eine neue Funktion"`
- Claude-Flags: `-c`, `--continue`, `-p`, `--print`, `--model <name>`, `--verbose`, `--allowedTools "Bash(*)"` usw.

Wenn keine Claude-Argumente übergeben werden, wird standardmäßig `"continue"` als Prompt verwendet.


## Funktionsweise (Vereinfachtes Modell v4)

Das Skript folgt einem einfachen, robusten Zyklus:

```
┌──────────────────────────┐
│        Start Skript      │
└────────────┬─────────────┘
             │
             ▼
┌──────────────────────────┐
│  Beginn Überwachungs-    │
│  schleife (Cycle 1/N)    │
└────────────┬─────────────┘
             │
             ▼
┌──────────────────────────┐
│  Prüfe Claude           │
│  Usage Limit            │
└────────────┬─────────────┘
             │
             │
┌────────────▼───────────┐   Ja   ┌──────────────────────────┐
│    Limit erreicht?     ├───────▶│ Warte bis Limit abgelaufen│
└────────────┬───────────┘        └──────────────────────────┘
             │ Nein
             │
             ▼
┌──────────────────────────┐
│ Öffne Claude in NEUEM,   │
│ unabhängigem Terminal    │
└────────────┬─────────────┘
             │
             ▼
┌──────────────────────────┐
│  Warte N Minuten bis zum │
│  nächsten Check          │
└────────────┬─────────────┘
             │
             └─────────────┐
                           │ (nächster Zyklus)
                           ▼
```
**Wichtiger Hinweis:** Das Skript startet ein Terminal und läuft dann im Hintergrund weiter, um nach dem festgelegten Intervall erneut zu prüfen. Das geöffnete Terminal ist für Sie zur normalen Arbeit mit Claude.


## Architektur-Entscheidung: Trennung von Überwachung und Interaktion

Das Kernkonzept des Skripts im `--continuous`-Modus basiert auf einer fundamentalen Notwendigkeit: **Die Trennung des Überwachungsprozesses von der interaktiven Claude-Sitzung.**

### Das Problem
Ein einzelnes Terminal kann nicht gleichzeitig zwei Dinge tun:
1.  Eine **Endlos-Schleife** ausführen, die alle paar Minuten die Claude-API auf Nutzungs-Limits prüft.
2.  Dem Benutzer einen **interaktiven Prompt** zur Verfügung stellen, um mit Claude zu arbeiten.

Würde man beides in einem Terminal versuchen, würde die Schleife den Prompt blockieren oder umgekehrt.

### Die Lösungsarchitektur
Die einzig saubere Lösung besteht darin, zwei getrennte Prozesse zu verwenden:
- **Prozess A (Der Monitor):** Dieses Skript (`claude-auto-resume-continuous-v4`), das im Hintergrund läuft, die Limits prüft und bei Bedarf den Neustart auslöst.
- **Prozess B (Die interaktive Sitzung):** Eine normale `claude`-CLI-Sitzung, in der der Benutzer arbeitet.

Die Aufgabe des Monitors ist es also, Prozess B in einem **neuen, unabhängigen Terminal-Fenster** zu starten. Dies ist der Hauptzweck der `--new-terminal` Option.

### Die technische Herausforderung der Umsetzung
Genau hier liegt die technische Hürde, die je nach Terminal-Anwendung unterschiedlich gemeistert wird: Wie kann Prozess A zuverlässig Prozess B im korrekten Arbeitsverzeichnis starten?

- **Für iTerm2 (der Idealfall):** iTerm2 erlaubt es, Befehle (`cd ...` und dann `claude ...`) nacheinander in dieselbe neue Shell zu "schreiben". Dies ist einfach und robust.

- **Für Apples Terminal.app (die Herausforderung):** `Terminal.app` ist restriktiver.
    - Es ist **nicht möglich**, Befehle nacheinander in dieselbe Shell zu schreiben (getrennte `do script`-Aufrufe erzeugen neue, isolierte Shells).
    - Die Simulation von Tastatureingaben (`keystroke`) **scheitert an den Sicherheitseinstellungen von macOS** und ist keine praktikable Option.

- **Die einzig robuste Lösung für Terminal.app:** Aus diesen Gründen ist die einzige sichere und funktionierende Methode, beide Befehle zu einer einzigen Anweisung zu verketten: `cd '/pfad/...' && claude ...`. Dies garantiert, dass die neue interaktive Sitzung im richtigen Verzeichnis startet, ohne die Systemsicherheit zu kompromittieren. Diese Methode ist kein "Workaround", sondern die technisch korrekte Lösung für die von `Terminal.app` gesetzten Rahmenbedingungen.
## Vergleich der Versionen

| Feature | v3 (Komplex) | v4 (Vereinfacht & Robust) |
|---------|--------------------------|-----------------------------------------|
| Kontinuierliche Überwachung | ✓ | ✓ (Zuverlässiger) |
| Periodische Limit-Checks | ✓ (60s) | ✓ (Standard 5 Min, konfigurierbar) |
| Prozess-Monitoring | ✓ ( Fehleranfällig) | ✗ (Entfernt für Stabilität) |
| **`-c` Continue-Flag** | ✗ (Unzuverlässig) | **✓ (Behoben & Zuverlässig)** |
| Neue Terminal-Fenster | ✓ | ✓ |
| Tmux-Support | ✓ | ✗ (Entfernt zur Vereinfachung) |
| Komplexität | Hoch | **Niedrig** |
| Zuverlässigkeit | Mittel | **Hoch** |


## 🔧 Entwicklungsstatus

### ✅ Gelöste Probleme
1. **`-c` (continue) Flag Unzuverlässigkeit**: Durch getrennte `cd` und `claude` Befehle in v4 behoben.
2. **Limitierte Funktionalität**: Durch die **Flag-Weiterleitung** vollständig behoben. Das Skript schränkt die Claude CLI nicht mehr ein.
3. **Komplexität**: Die Kernlogik bleibt einfach, indem Wrapper-Aufgaben von Claude-Aufgaben getrennt werden.

### 🎯 Kernfokus dieser Version
- **Flexibilität**: Ermöglicht die Nutzung **aller** Claude-CLI-Features.
- **Automatisierung**: Behält die robuste, kontinuierliche Überwachung bei.
- **Einfachheit**: Die Bedienung bleibt intuitiv: Wrapper-Flags + Standard-Claude-Befehl.

## Sicherheitshinweise

⚠️ **Wichtige Sicherheitshinweise:**

1. **`--dangerously-skip-permissions`**: Das Skript verwendet diesen Flag für eine automatisierte Ausführung. Verwenden Sie es nur in vertrauenswürdigen Umgebungen und mit Projekten, denen Sie vertrauen.
2. **Netzwerk-Zugriff**: Das Skript führt Netzwerk-Konnektivitätsprüfungen durch, um die Funktion sicherzustellen.

## Fehlerbehebung

### Problem: Das Fortsetzen mit `-c` startet eine neue Sitzung
- **Status**: **BEHOBEN in v4.0.0.** Stellen Sie sicher, dass Sie die neueste Version verwenden.

### Problem: Terminal wird nicht erkannt
```bash
# Lösung: Spezifizieren Sie die Terminal-App manuell
./claude-auto-resume-continuous-v4 --terminal-app terminal --new-terminal "task"
```

### Problem: Claude CLI nicht gefunden
```bash
# Lösung: Stellen Sie sicher, dass Claude CLI installiert und im PATH ist.
# Besuchen Sie https://claude.ai/code für Installationsanweisungen.
which claude
```