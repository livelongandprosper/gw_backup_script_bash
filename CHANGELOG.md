# Changelog

Alle relevanten Änderungen an diesem Projekt werden in dieser Datei dokumentiert.

Das Format basiert auf [Keep a Changelog](https://keepachangelog.com/de/1.0.0/)
und das Projekt folgt den Grundsätzen des [Semantic Versioning](https://semver.org/lang/de/).

---

## [2.1.0] - 2026-11-25

### Hinzugefügt
- **Neues WordPress-Update-Skript (`update_wp.sh`):**
  - Automatisierte und sichere Aktualisierung von WordPress Core, Datenbank-Schema, Plugins, Themes und Sprachdateien.
  - **Selbstinstallation & WP-CLI:** Automatische Erkennung oder Download von WP-CLI nach `./bin/wp-cli.phar` mit SHA-512 Hash-Prüfung und `--update-wpcli`.
  - **Vorprüfungen (Pre-Check):** Verifikation von `wp core is-installed`, Abwesenheit von `.maintenance`, HTTP-Status 200 und Vorhandensein von `MUST_CONTAIN` auf der Startseite. Bricht bei Vorschäden sofort sicher ab (ROT).
  - **Backup-Sicherheitsnetz:** Automatischer Aufruf von `backup_full_db_files_zip.sh` vor jedem Update. Fortsetzung nur bei erfolgreichem, verifiziertem Backup.
  - **Umfassender Post-Check:** Prüfung von `wp core verify-checksums`, Versions-Diffs, Log-Analyse auf Fatal Errors, HTTP-Status 200 und Antwortzeitvergleich.
  - **Ampel-System & Exit-Codes:** 0 = GRÜN (Erfolg), 1 = GELB (Warnungen/Verlangsamung), 2 = ROT (Fehler/Abbruch).
  - **Automatisches Rollback-Skript:** Generierung von `update-runs/<projekt>/<datum>/rollback.sh` mit gezielten Downgrade-Befehlen und Restore-Anleitung.
  - **Interaktives Menü & CLI-Parameter:** `--project=`, `--dry-run`, `--no-backup`, `--only=`, `--setup`, `--update-wpcli`, `--json`, `--help`.
- **Selbstprüfung für Backups (`verify_backup` in `backup_full_db_files_zip.sh`):**
  - Jede erzeugte ZIP-Datei wird vor der Übertragung oder Löschung mit `unzip -tq` getestet.
  - Datenbank-Dumps werden auf mysqldump-Header, `-- Dump completed`-Abschluss und (bei WordPress) auf die Tabellen `<prefix>options` und `<prefix>posts` validiert.
  - Automatischer Größenvergleich mit vorherigen Backups desselben Projekts (> 30 % Abweichung erzeugt eine Warnung).
- **Maschinenlesbarer Status & JSON-Export:**
  - Speicherung von `status/<PROJEKT_BASIS_DATEINAME>.last.json` nach jedem Backup-Lauf.
  - Neuer Parameter `--json` zur reinen JSON-Ausgabe auf `stdout` (Logs und Banner auf `stderr`).
- **Ehrliche Exit-Codes im Backup-Skript:**
  - `0` = Alles in Ordnung.
  - `1` = Warnungen (z.B. Remote-Transfer fehlgeschlagen, Backups lokal intakt; Größenabweichung > 30 %).
  - `2` = Fehler (Dump oder Datei-ZIP fehlt/defekt; mysqldump/zip fehlgeschlagen).
  - Bei `--project=alle` gilt der schlechteste Status aller Projekte.
- **Autarke Skripte (100% self-contained):**
  - Beide Skripte (`backup_full_db_files_zip.sh` und `update_wp.sh`) sind vollständig eigenständig und unabhängig voneinander ohne externe Bibliotheksdatei (`lib_common.sh`) lauffähig.
  - Das Update-Skript interagiert direkt mit dem Backup-Skript (erstellt vor Updates ein Backup und führt das Update nur bei erfolgreichem Backup aus).
- **Verfeinerte Malware-Erkennung im Upload-Ordner:**
  - Standardmäßige, harmlose WordPress-Platzhalter (`index.php` mit "Silence is golden" bzw. ohne ausführbaren Schadcode und <= 350 Bytes) im Upload-Verzeichnis lösen keinen Fehlalarm mehr aus.
- **Neuer Parameter `--quiet` / `-q`:**
  - Unterdrückt normale Informationsausgaben und gibt nur Fehler und die Zusammenfassung aus.

---

## [2.0.0] - 2026-11-18

### Hinzugefügt
- **Pre-Backup & System-/Sicherheitsprüfungen (`--check` / Menüpunkt 5):**
  - Automatischer Vorab-Check vor jedem Backup sowie manuell über das Hauptmenü oder CLI-Parameter `--check` / `--pre-check`.
  - Vollständige und transparente Pfadangaben: Bei allen Diagnosen, Warnungen, erkannten Log-Dateien, Webshells und Konfigurationsdateien wird stets der vollständige absolute Pfad angegeben.
  - Farbcodierte visuelle Auswertung (`[✓ OK]` grün, `[⚠ WARNUNG]` gelb, `[✖ ACHTUNG]` rot, `[ℹ INFO]` cyan) mit Zusammenfassungsfazit im Terminal und sauberer Klartext-Dokumentation im Logfile.
  - **WordPress-Diagnose:** Erkennung und Warnung bei aktivem `WP_DEBUG` und gefährlichem `WP_DEBUG_DISPLAY` (Frontend-Fehlerausgabe an Besucher).
  - **Log-Überwachung:** Aufspüren von `wp-content/debug.log` mit Größenwarnung (> 10 MB) sowie Standard-PHP-`error_log`-Dateien.
  - **Wartungsmodus:** Erkennung aktiver `.maintenance`-Dateien vor Updates.
  - **Rudimentäre Sicherheits- & Malware-Heuristik:**
    - Auffinden von verdächtigen PHP-Skripten im Upload-Verzeichnis (`wp-content/uploads/`) zur frühzeitigen Erkennung von Webshells/Backdoors.
    - Prüfung von `wp-config.php` und `index.php` auf verschleierte Code-Muster (`eval(base64_decode...)`).
    - Erkennung versteckter PHP-Dateien (`.*.php`) im Webroot.
  - **Datenbank-Live-Check:** Verbindungstest vor Dump-Beginn mit Ermittlung der Tabellenanzahl.
- **Automatische WordPress-Erkennung & Auto-Import (`--scan-wp` / Menüpunkt 4):**
  - Selbstständiger Suchlauf nach WordPress-Installationen in relativen (z. B. `..`) oder absoluten Verzeichnissen.
  - Sicheres und portables Auslesen von Datenbank-Zugangsdaten (`DB_NAME`, `DB_USER`, `DB_PASSWORD`, `DB_HOST`) aus `wp-config.php` via PHP-Token-Parser (inkl. Regex-Fallback).
  - Intelligente Erkennung und Vorschläge für Projektnamen anhand von `WP_HOME`, `WP_SITEURL`, Blog-Optionen oder Verzeichnisnamen.
  - Vorkonfigurierte WordPress-Ausschlussregeln (Cache-Ordner, Upload-Caches, Updraft-/Ai1wm-Backups, `.git`).
  - Integration in das Hauptmenü, automatische Nachfrage beim ersten Start ohne `.env`-Dateien sowie als CLI-Parameter `--scan-wp[=<ordner>]`.
- **Webroot- und Zugriffsschutz (.htaccess):**
  - Automatische Generierung moderner Apache 2.4 (`Require all denied`) und Apache 2.2 (`Deny from all`) Schutzregeln für alle Backup- und Log-Verzeichnisse.
  - Gezielter Zugriffsschutz für sensible Dateien (`.env.*`, `*.log`, `*.sh`, `.git*`) im Basisordner des Skripts, um sicheren Betrieb innerhalb des Webroots zu ermöglichen.
  - Dokumentation empfohlener Nginx-Schutzregeln im `README.md`.
- **Festplattenspeicher-Prüfung:**
  - Automatische Vorabprüfung des verfügbaren Speicherplatzes vor Backup-Läufen mit Warnmeldung bei drohender Speicherknappheit (< 500 MB).

### Geändert
- **Berechtigungen & Umask gehärtet:**
  - Standard-Umask `077` und restriktive Zugriffsrechte (`chmod 700` für Verzeichnisse, `chmod 600` für Konfigurationsdateien, temporäre SFTP-Batchdateien und Logs) sichergestellt.
  - Bereinigung der Konfigurationsdateien: Redundante Abwärtskompatibilitäts-Variablen (`DB_HOST`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`) werden in neu erstellten `.env`-Dateien nicht mehr geschrieben; es wird ausschließlich die klare Multi-Datenbank-Struktur (`DB_COUNT`, `DB_1_*`, etc.) genutzt.
- **Zuverlässigkeit bei Datenbank-Dumps & Archivierung:**
  - Explizite Exit-Code- und Nicht-Leer-Prüfung bei `mysqldump` und `zip`; fehlerhafte oder unvollständige Dump-Dateien brechen den Vorgang sofort sauber ab und werden bereinigt.
  - Standardmäßiger Export mit `--routines`, `--triggers`, `--quick`, `--max_allowed_packet=512M` und `--default-character-set=utf8mb4` für maximale Datenintegrität und zuverlässigen Export großer Tabellen/BLOBs.
  - Automatische Unterstützung moderner MySQL- und Cloud-DB-Optionen (`--column-statistics=0` und `--set-gtid-purged=OFF`, sofern unterstützt) und saubere Port-Trennung (`-P`).
  - Plattformunabhängige und verlässliche `DEFINER`-Bereinigung (`DEFINER=CURRENT_USER`) zur Erleichterung von Server-Restores.
  - Symbolische Links werden beim Zippen von Website-Dateien (`zip -y`) als Symlinks erhalten, um doppeltes Einpacken und Endlosschleifen zu verhindern.
- **Erweiterte Standard-Ausschlussregeln:**
  - Vorkonfigurierte Ausschlussmuster umfassen nun neben Caches auch Wordfence-Logs (`wflogs`), `debug.log`, `error_log`, diverse Backup-Plugin-Verzeichnisse (Updraft, Ai1wm, BackupBuddy, Snapshots, WP Clone), `.DS_Store`, `Thumbs.db` und `node_modules`.
- **Dateihandling & Bereinigung:**
  - Ersetzung des fehleranfälligen `ls`-Parsings bei SFTP-Übertragungen durch direktes Shell-Globbing.
  - Vollständige Portabilität bei `sed`-Operationen (POSIX-konform ohne proprietäre `-E`-Flags) zur fehlerfreien Ausführung auf allen GNU- und BSD/macOS-Systemen.
  - Absicherung aller Löschvorgänge (`delete_if_transmitted`, `backup_live_time`) über `find -maxdepth 1` mit Pfadvalidierung und Beibehaltung von `.htaccess`-Schutzdateien.
  - Garantierter Schreib- und Löschschutz für das Website-Quellverzeichnis (`SOURCE_FILES_DIR` wird ausschließlich lesend verarbeitet).
- **Versions- & Urheberrechtsangaben:**
  - Kopfkommentare in `backup_full_db_files_zip.sh` und `backup_sync_proxy_[projectname].sh` auf Version `2.0.0` und Copyright `2017-2026` aktualisiert.

---

## [1.5.0]

### Geändert
- **Array-Format für Ausschlussmuster:**
  - Umstellung der Variable `SOURCE_FILES_DIR_IGNORE` auf native Bash-Arrays zur präzisen und fehlerfreien Übergabe von Ausschlussmustern an `zip -x`.

---

## [1.4.0]

### Hinzugefügt
- **Interaktives Hauptmenü:**
  - Menügesteuerte Benutzerführung beim Start ohne CLI-Parameter im interaktiven Terminal.
  - Direkte Auswahlmöglichkeiten für Einzel-Backups, Multi-Projekt-Sicherungen, Neuanlage, Restore, Datengrößenanzeige und Übersicht.

---

## [1.3.0]

### Hinzugefügt
- **Datenbank-Wiederherstellung (`--restore`):**
  - Interaktiver Assistent zur Wiederherstellung von MySQL-Datenbanken aus unkomprimierten oder gezippten SQL-Backups inklusive automatischer Entpackung und Sicherheitsabfrage.
- **Größenermittlung:**
  - Optionale Anzeige des belegten Speicherplatzes des Quellordners (`du -sh`) im Einrichtungsassistenten.

---

## [1.2.0]

### Hinzugefügt
- **Multi-Projekt-Unterstützung:**
  - Verwaltung mehrerer unabhängiger Websites/Projekte über dedizierte `.env.<projektname>`-Dateien im selben Skriptordner.
  - Abwärtskompatibilität für bestehende `.env`-Dateien als Projekt `default`.
- **Interaktiver Setup-Assistent:**
  - Geführte Abfrage und automatische Erstellung von Projektkonfigurationen.
- **CLI-Steuerung:**
  - Unterstützung für `--project=<name>|alle` und `--scope=alles|db|dateien` für die nahtlose Einbindung in Cronjobs.

---

## [1.1.0]

### Hinzugefügt
- **Multi-Datenbank-Fähigkeit:**
  - Unterstützung für die Sicherung beliebig mehrerer Datenbanken pro Projekt via `DB_COUNT` und `DB_n_*`.
- **Sicherheitsoptimierung:**
  - Automatische Erstellung von `.htaccess`-Zugriffssperren in Backup-Ordnern und Auslagerung sensibler Zugangsdaten in `.env`.

---

## [1.0.0]

### Hinzugefügt
- **Initiales Release:**
  - Sicherung von Website-Dateien als ZIP-Archiv mit Ordnerausschlüssen.
  - Erstellung komprimierter MySQL-Datenbank-Dumps via `mysqldump`.
  - Optionaler Remote-Transfer via SFTP oder Rsync.
  - Automatische Bereinigung übertragener Backups und Verwaltung der Backup-Lebenszeit.
  - Detailliertes Logging aller Backup-Aktivitäten.
