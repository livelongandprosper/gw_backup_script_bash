# Requirements

### Overview & Goals
Erweiterung und Härtung der Wartungs-Toolchain:
- Vollständige Umstellung der visuellen Regressionsprüfung in `update_wp.sh` von `mshots`/Headless-Browser auf den zentralen Gotenberg-9-Dienst (`https://gotenberg.gregor-wendland.com`) mit Basic-Auth über sichere stdin-Konfiguration (`curl -K -`), Multi-Viewport-Unterstützung (1440px / 390px), Ignore-Rectangles und neuen Warnschwellen (<1% GRÜN, 1-5% GELB, >5% ROT).
- Healthchecks.io Ping-Alarmierung (`/start`, `/<exitcode>`) im Backup-Skript `backup_full_db_files_zip.sh`.
- Korrekturen und Ergänzungen in `ROADMAP.md` (Abnahmezeilen, Gotenberg-Dokumentation, Hetzner Storage Box Port-Klarstellung 22/23, Übungsetappe für Wiederherstellung `RESTORE.md`, Ausschlussgründe für age-Verschlüsselung, Schutz vor Überschreiben bei Deployments).
- Aktualisierung von `README.md`, `CHANGELOG.md`, `.update.example` und Erhöhung der Skript-Versionen.

# Delivery Steps

### ✓ Step 1: Gotenberg-9-Integration und Entfernen alter Screenshot-Methoden in update_wp.sh
- Alte `mshots`- und lokale Browser-Routinen vollständig entfernen.
- Zentrale Konfiguration `.gotenberg` (chmod 600, Webroot-Schutz) einbinden.
- `capture_screenshot` auf Gotenberg 9 (`POST /forms/chromium/screenshot/url`) mit Basic Auth via `curl -K -` umstellen.
- Unterstützung für Multi-Viewports (`SCREENSHOT_WIDTHS`), `waitDelay`, Cookies und Ignore-Rectangles (`SCREENSHOT_IGNORE_RECTS`).
- Gotenberg-Fehlertoleranz (Update läuft weiter, Optik-Prüfung = GELB bei Unerreichbarkeit).
- Setup-Assistent und neuer Parameter `--test-screenshot` implementieren.
- `.update.example` aktualisieren.

### ✓ Step 2: Healthchecks-Alarmierung in backup_full_db_files_zip.sh implementieren
- `.env.<projekt>` um `HEALTHCHECK_URL` erweitern.
- Start-Ping (`<url>/start`) zu Beginn des Backups und Status-Ping (`<url>/<exitcode>`) am Ende mit 10s Timeout.
- Setup-Assistent (`run_interactive_wizard`) um interaktive Abfrage und Test-Ping erweitern.
- Webroot-Schutz `.htaccess` auf `.update.*` und `.gotenberg.*` erweitern.

### ✓ Step 3: ROADMAP.md vollständig überarbeiten und anpassen
- Etappe 1 & 3: Status auf "umgesetzt, Abnahme offen" setzen, Abnahmezeile "Abgenommen von Gregor am: ___" hinzufügen.
- Tabelle 1.4 und Etappe 3 auf Gotenberg 9 aktualisieren.
- Etappe 4 (Mac-Tool) als optional kennzeichnen; Schutzregeln für `--deploy-scripts` definieren.
- Etappe 2: Port 22 (RFC4716) vs. Port 23 (OpenSSH) korrigieren, Testfall für `/.zfs`-Schreibschutz ergänzen, `DELETE_IF_TRANSMITTED="true"` vereinheitlichen, Nginx-Hinweis zu `keys/`.
- Neue Etappe 2b "Wiederherstellung üben" (`RESTORE.md`) ergänzen.
- Abschnitt 5 (Offene Entscheidungen) und Abschnitt 6 (Nicht im Umfang: age/GPG) anpassen.

### ✓ Step 4: Dokumentation (README.md, CHANGELOG.md) und Versionserhöhung
- Versionsnummern erhöhen: `backup_full_db_files_zip.sh` -> v2.2.0, `update_wp.sh` -> v1.1.0.
- `CHANGELOG.md` mit detaillierten Release-Notes für beide Skripte aktualisieren.
- `README.md` um Gotenberg-Konfiguration und Healthchecks-Einrichtung erweitern.

### ✓ Step 5: Validierung und Testdurchlauf
- Syntaxprüfung aller Bash-Skripte (`bash -n`).
- Verbindungstests, Fehlerbehandlungsprüfungen und Validierung der Statusausgaben.
