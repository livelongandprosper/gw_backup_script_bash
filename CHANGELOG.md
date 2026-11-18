# Changelog

Alle relevanten Änderungen an diesem Projekt werden in dieser Datei dokumentiert.

Das Format basiert auf [Keep a Changelog](https://keepachangelog.com/de/1.0.0/)
und das Projekt folgt den Grundsätzen des [Semantic Versioning](https://semver.org/lang/de/).

---

## [2.0.0] - 2026-11-18

### Hinzugefügt
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
- **Zuverlässigkeit bei Datenbank-Dumps & Archivierung:**
  - Explizite Exit-Code- und Nicht-Leer-Prüfung bei `mysqldump` und `zip`; fehlerhafte oder unvollständige Dump-Dateien brechen den Vorgang sofort sauber ab und werden bereinigt.
  - Standardmäßiger Export mit `--routines`, `--triggers` und `--quick` zur vollständigen Sicherung von Stored Procedures und Triggern.
  - Plattformunabhängige und verlässliche `DEFINER`-Bereinigung (`DEFINER=CURRENT_USER`) zur Erleichterung von Server-Restores.
- **Dateihandling & Bereinigung:**
  - Ersetzung des fehleranfälligen `ls`-Parsings bei SFTP-Übertragungen durch direktes Shell-Globbing.
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
