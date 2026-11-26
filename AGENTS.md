# AGENTS.md – Projektstandards & Entwicklungsrichtlinien

Dieses Dokument beschreibt die verbindlichen Konventionen, technischen Standards und Qualitätsregeln für die Arbeit an diesem Repository (`backup_full_db_files_zip.sh`, `update_wp.sh` und zugehörige Tests/Dokumentation).

---

## 1. Sprache & Dokumentation

- **Projektsprache:** Deutsch. Alle Code-Kommentare, CLI-Ausgaben, Log-Meldungen, Fehlermeldungen und Dokumentationen (`README.md`, `CHANGELOG.md`, `ROADMAP.md`, `AGENTS.md`) werden auf Deutsch verfasst.
- **Changelog-Pflicht:** Jede funktionale, sicherheitsrelevante oder konzeptionelle Änderung **muss** direkt in `CHANGELOG.md` unter der aktuellen bzw. nächsten Version dokumentiert werden (Format: [Keep a Changelog](https://keepachangelog.com/de/1.0.0/) mit Semantic Versioning; Kategorien: `Hinzugefügt`, `Geändert`, `Behoben`, `Entfernt`).
- **README-Pflege:** Änderungen an CLI-Optionen, Konfigurationsvariablen, Standardwerten oder dem Einrichtungsablauf müssen zusätzlich in `README.md` nachgeführt werden.

---

## 2. Architektur & Multi-Projekt-Design

- **Ein Skript für alle Projekte:** Weder `backup_full_db_files_zip.sh` noch `update_wp.sh` werden pro Kunde kopiert. Alle Projekte liegen über eigene Konfigurationsdateien im selben Verzeichnis:
  - Backup-Konfiguration: `.env.<projekt>`
  - Update-Konfiguration: `.update.<projekt>`
  - Zentrale Screenshot-Konfiguration: `.gotenberg`
- **Interaktiv vs. CLI/Cronjob:**
  - Aufruf ohne Parameter im Terminal öffnet das interaktive Hauptmenü.
  - Aufruf mit CLI-Parametern (`--project=`, `--scope=`, `--dry-run`, `--setup`, `--json`, `--quiet`, etc.) überspringt Menüs und läuft vollautomatisch (Cronjob-tauglich).
- **JSON-Ausgabe (`--json`):** Bei gesetztem `--json` muss reines, valides JSON auf `stdout` ausgegeben werden; alle menschlichen Status-, Fortschritts- und Hinweistexte gehen nach `stderr`.
- **Shared-Hosting-Kompatibilität:** Alle Skripte müssen ohne Root-Rechte auf typischen Shared-Hosting-Servern (Linux/GNU) sowie lokal auf macOS (BSD) lauffähig sein.

---

## 3. Bash- & Portabilitätsstandards

- **Skript-Header & Sicherheit:**
  - `#!/bin/bash`
  - `set -o pipefail`
  - `umask 077` (neu erzeugte Konfigurations-, Log- und Backup-Dateien sind standardmäßig nur für den Eigentümer lesbar; sensible Dateien explizit mit `chmod 600` absichern).
- **Plattformübergreifende Kommandos (macOS/BSD & GNU/Linux):**
  - `sed` POSIX-kompatibel einsetzen (z. B. `sed -n 's/.../\1/p'` statt GNU/BSD-spezifischem `-E`/`-r`).
  - `date`-Berechnungen sowohl für BSD (`date -r <epoch>`) als auch GNU (`date -d "@<epoch>"`) unterstützen.
  - `mktemp` mit sinnvollem Fallback verwenden und temporäre Dateien per `trap` oder explizit aufräumen.
- **Umgang mit `set -o pipefail`:**
  - Große Strings oder HTML-Antworten **nicht** per Pipe an `grep -q` übergeben (vorzeitiges Schließen von `grep -q` löst `SIGPIPE`/Exit-Code `141` aus). Stattdessen Bash-Substring-Vergleiche (`[[ "$body" != *"$needle"* ]]`) oder Here-Strings (`grep -q ... <<< "$body"`) verwenden.
- **Konfigurationsdateien & Variablenhygiene:**
  - Beim Schreiben von `.env.*`, `.update.*` oder `.gotenberg` Werte immer sauber für die Shell quoten/escapen (`quote_shell_value`).
  - Vor dem Einlesen eines neuen Projekts in Schleifen (`--project=alle`) müssen alle projektbezogenen Variablen auf definierte Standardwerte zurückgesetzt werden, damit keine Werte aus dem vorherigen Projekt durchschlagen.
- **Geheimnisse schützen:** Passwörter, API-Tokens oder Basic-Auth-Daten niemals als sichtbare CLI-Argumente übergeben (z. B. `curl -K -` über `stdin` nutzen).
- **Webroot-Schutz:** Sensible Dateien und Ordner (`.env*`, `.update*`, `.gotenberg*`, `.git*`, `*.log`, `*.sh`, `*.json`, `*.lock`, `log/`, `status/`, `update-runs/`, `bin/`) werden per `.htaccess` vor Webzugriff geschützt.

---

## 4. Fachliche & Sicherheits-Standards

- **Einheitliche Exit-Codes (Ampel-System):**
  - `0` = **GRÜN** (alles erfolgreich)
  - `1` = **GELB** (Warnungen, z. B. Remote-Übertragung fehlgeschlagen bei intaktem lokalem Backup, Gotenberg nicht erreichbar, Antwortzeit verlangsamt, inhaltliche HTML-Abweichung)
  - `2` = **ROT** (kritischer Fehler oder Abbruch, z. B. defektes Backup, fehlgeschlagene Vorprüfung, fehlgeschlagene Core-Checksummen, massiver Textverlust)
  - Bei `--project=alle` gilt immer der schlechteste Status aller geprüften Projekte.
- **Backup-Integrität & Aufbewahrung (`backup_full_db_files_zip.sh`):**
  - Jedes Backup wird vor Übertragung oder Bereinigung über `verify_backup` geprüft (`unzip -tq`, mysqldump-Header, `-- Dump completed`, WordPress-Tabellen, Größenvergleich).
  - Striktes Löschverbot (lokal und remote) bei fehlgeschlagenem Backup (`exitcode == 2`) oder fehlgeschlagener Verifikation.
  - Bereinigungsfunktionen dürfen niemals fremde Dateien außerhalb der projekteigenen Backup-Muster antasten.
- **Update-Sicherheit (`update_wp.sh`):**
  - **Vorprüfung:** Abbruch vor jedem Update, wenn die Website bereits defekt ist (`wp core is-installed`, `.maintenance`, HTTP `200`, `MUST_CONTAIN`).
  - **Pflicht-Backup:** Vor Updates wird ein frisches, verifiziertes Backup erstellt (bzw. bei `--no-backup` ein aktuelles verifiziertes Backup innerhalb `BACKUP_MAX_AGE_MIN` verlangt).
  - **HTML-Sicherung & Vergleich:** HTML-Antworten aller `CHECK_PATHS` werden vor und nach dem Update archiviert (`html/vorher_<slug>.html`, `html/nachher_<slug>.html`) und normalisiert (ohne Kommentare, `<script>`, `<style>`, `<noscript>`) verglichen.
  - **Visueller Vergleich:** Über den zentralen Gotenberg-9-Dienst (`SCREENSHOT_WAIT` Standard: `5s`); ein Ausfall von Gotenberg führt kontrolliert zu GELB, nicht zu einem harten Abbruch.
  - **Rollback:** Für jeden Lauf wird ein `rollback.sh` mit konkreten Downgrade-Befehlen erzeugt.
  - **`SKIP_PLUGINS`:** Bleibt bei der Einrichtung standardmäßig leer (`keine`) und dient ausschließlich bewussten manuellen Ausnahmen.
- **WordPress-Erkennung:**
  - `find_wp_config_in_path()` durchsucht nach den direkten Standard-Kandidaten auch Unterordner bis zur 2. Ebene (`-maxdepth 3`) und schließt `node_modules`, `vendor`, versteckte Ordner (`.*`) sowie `log` aus.

---

## 5. Verifikation & Tests

Nach Änderungen an den Skripten sind mindestens folgende Prüfungen durchzuführen:

1. **Syntax- & CLI-Prüfung:**
   - `bash -n backup_full_db_files_zip.sh` und/oder `bash -n update_wp.sh`
   - `./backup_full_db_files_zip.sh --help` bzw. `./update_wp.sh --help`
2. **Retention-Testsuite:**
   - Bei Änderungen an `backup_full_db_files_zip.sh` (insbesondere Retention, Satzgruppierung, Bereinigung, CLI/Status) immer `./test_retention_suite.sh` ausführen.
3. **Gezielte Funktionstests:**
   - Neue oder geänderte Hilfsfunktionen (z. B. HTML-Vergleich, Sitemap-Parser, `find_wp_config_in_path()`) isoliert gegen reproduzierbare Testdaten bzw. lokale Teststrukturen prüfen.
