# Changelog

Alle relevanten Änderungen an diesem Projekt werden in dieser Datei dokumentiert.

Das Format basiert auf [Keep a Changelog](https://keepachangelog.com/de/1.0.0/)
und das Projekt folgt den Grundsätzen des [Semantic Versioning](https://semver.org/lang/de/).

---

## [2.3.0] - 2026-11-26

### Hinzugefügt
- **Intelligente Aufbewahrungsrichtlinie (Großvater-Vater-Sohn / Staffel-Prinzip):**
  - Neuer Aufbewahrungsmodus `RETENTION_MODE='staffel'` in `.env.<projekt>` für abgestufte Vorhaltezeiten:
    - `KEEP_DAILY_DAYS=30`: Tägliche Backups der letzten N Tage vollständig aufbewahren.
    - `KEEP_WEEKLY_DAYS=90`: Danach bis N Tage genau das jüngste Backup je ISO-Kalenderwoche (`YYYY-Www`) behalten.
    - `KEEP_MONTHLY_DAYS=365`: Danach bis N Tage genau das jüngste Backup je Kalendermonat (`YYYY-MM`) behalten (`0` = unbegrenzt).
    - `KEEP_MIN_SETS=3`: Schutzgarantie für mindestens N jüngste erfolgreiche Sätze unabhängig vom Alter.
    - `RETENTION_REMOTE='yes'`: Anwendung der Regeln auf das Remote-Ziel (SFTP / Rsync via SFTP-Batch).
- **Atomare Satzbildung & Auswertung:**
  - Einheitlicher Laufzeitstempel `BACKUP_RUN_TIMESTAMP` für alle Datenbank-Dumps und Datei-Archive eines Projektlaufs.
  - Zeitstempel-Parser `parse_backup_filename` und Satzgruppierung `group_backup_sets` direkt aus Dateinamen (unabhängig von Dateisystem-`mtime`).
  - Bereinigung unvollständiger Sätze älter als 7 Tage, wenn neuere vollständige Sätze existieren.
- **Sicherheitsbarrieren:**
  - Striktes Löschverbot lokal und remote bei fehlerhaftem Backup (`exitcode == 2`) oder fehlgeschlagener Verifikation (`verify_backup`).
  - Schutz fremder Dateien (`.htaccess`, Skripte, andere Projekte) und Begrenzung auf das projekteigene Verzeichnis.
  - Robuste SFTP-Fehlertoleranz: Remote-Löschfehler erzeugen Warnungen (Exitcode maximal 1) und gefährden niemals das erfolgreiche Backup.
- **Vorschau-Modus (Dry-Run) & Hauptmenü:**
  - CLI-Option `--retention-dry-run [--project=<name>|alle]` zur übersichtlichen tabellarischen Vorschau aller behaltenen/gelöschten Sätze und des freigegebenen Speichers ohne Dateisystemänderungen.
  - Neuer Hauptmenüpunkt "Aufbewahrung prüfen / einstellen (Staffel/GVS)" mit interaktiver Vorschau und Konvertierungsfunktion bestehender Projekte nach `staffel` inkl. automatischer Sicherung als `.env.<projekt>.bak`.
- **Status-JSON Erweiterung:**
  - `status/<PROJEKT>.last.json` um den Schlüssel `retention` mit Modus, Behalte-/Löschzählern und Byte-Angaben für lokal und remote erweitert.
- **Abwärtskompatibilität:**
  - Bestehende Projekte ohne `RETENTION_MODE` fallen automatisch auf `tage` (wenn `BACKUP_LIVE_TIME > 0`) oder `aus` zurück; kein stilles Umstellen.
  - Setup-Assistent schlägt für neue Projekte standardmäßig `staffel` mit empfohlenen Werten vor.
- **Testsuite:**
  - Synthetische Testsuite `test_retention_suite.sh` mit 8 Testfällen (400-Tage-Staffelung, Mindestbestand, unvollständige Sätze, Dateischutz, Abwärtskompatibilität, Konvertierung, Sicherheitsbarriere, SFTP-Fehlertoleranz).

### Entfernt
- **Veraltetes Hilfsskript `backup_sync_proxy_[projectname].sh`:**
  - Entfernung des nicht mehr benötigten Proxy-Sync-Skripts, da Remote-Übertragung und Bereinigung direkt und nativ über SFTP/Rsync im Hauptskript abgebildet werden.

---

## [2.2.0] - 2026-11-25

### Hinzugefügt
- **Healthchecks.io Alarmierung im Backup-Skript (`backup_full_db_files_zip.sh` v2.2.0):**
  - Parameter `HEALTHCHECK_URL` in `.env.<projekt>` zur zentralen Überwachung von Backup-Läufen.
  - Automatischer Start-Ping (`<url>/start`) bei Laufbeginn und Status-Ping (`<url>/<exitcode>`, z. B. `/0`, `/1`, `/2`) am Ende.
  - Timeout auf 10s begrenzt; Verbindungs- oder Netzwerkfehler beeinträchtigen das Backup nicht.
  - Setup-Assistent fragt die URL optional ab und sendet direkt einen Test-Ping.
- **Gotenberg 9 Screenshot-Dienst in `update_wp.sh` (v1.1.0):**
  - Umstellung auf den zentralen Gotenberg 9 Dienst (`https://gotenberg.gregor-wendland.com`) mit Basic-Auth über sichere stdin-Konfiguration (`curl -K -` / kein Passwort in CLI-Prozessliste).
  - Zentrale Konfigurationsdatei `.gotenberg` (chmod 600, Webroot-Schutz `.htaccess`).
  - Unterstützung für Multi-Viewports (`SCREENSHOT_WIDTHS="1440 390"`), Wartezeiten (`SCREENSHOT_WAIT="2s"`), Cookie-Consent (`SCREENSHOT_COOKIES`) und benutzerdefinierte Ignore-Bereiche (`SCREENSHOT_IGNORE_RECTS`).
  - Geschärfte Schwellenwerte: $< 1.0\,\%$ GRÜN, $1.0 - 5.0\,\%$ GELB, $> 5.0\,\%$ ROT.
  - Fehlertoleranz: Ist Gotenberg offline oder liefert ein ungültiges Bild, bricht das Update nicht ab, sondern stuft die Optik-Prüfung kontrolliert auf GELB ("Screenshot-Dienst nicht erreichbar") ein.
  - Neuer CLI-Parameter `--test-screenshot[=<URL>]` zum schnellen Testen der Gotenberg-Verbindung.
  - Menüpunkt 5 zum Verbindungstest im interaktiven Hauptmenü.
- **Erweiterter Webroot-Schutz:**
  - `.htaccess` sperrt jetzt standardmäßig `.env*`, `.update*`, `.gotenberg*`, `.git*`, `*.log`, `*.sh`, `*.json` und `*.lock`.

### Entfernt
- **Alte Screenshot-Methoden (mshots & lokale Headless-Browser):**
  - Vollständige Entfernung von Automattic `mshots` (da mshots veraltete Cache-Bilder liefern konnte, was zu falschem GRÜN führte, und Kunden-URLs an externe Drittanbieter übermittelte).
  - Vollständige Entfernung lokaler Headless-Browser-Aufrufe (da Chromium/shot-scraper auf Shared-Hosting-Servern nicht verlässlich verfügbar sind).
  - Veraltete Konfigurationsoptionen (`SCREENSHOT_METHOD`, `SCREENSHOT_PAGES_COUNT`) werden beim Einlesen bestehender `.update.<projekt>`-Dateien ignoriert und mit einem einmaligen Hinweis im Log dokumentiert.

---

## [2.1.0] - 2026-11-25

### Hinzugefügt
- **Neues WordPress-Update-Skript (`update_wp.sh`):**
  - Automatisierte und sichere Aktualisierung von WordPress Core, Datenbank-Schema, Plugins, Themes und Sprachdateien.
  - **Selbstinstallation & WP-CLI:** Automatische Erkennung oder Download von WP-CLI nach `./bin/wp-cli.phar` mit SHA-512 Hash-Prüfung und `--update-wpcli`.
  - **Vorprüfungen (Pre-Check):** Verifikation von `wp core is-installed`, Abwesenheit von `.maintenance`, HTTP-Status 200 und Vorhandensein von `MUST_CONTAIN` auf der Startseite. Bricht bei Vorschäden sofort sicher ab (ROT).
  - **Backup-Sicherheitsnetz:** Automatischer Aufruf von `backup_full_db_files_zip.sh` vor jedem Update. Fortsetzung nur bei erfolgreichem, verifiziertem Backup.
  - **Visuelle Regressionsprüfung (Screenshot-Vergleich):**
    - Vorher- und Nachher-Screenshots der Startseite, der konfigurierten `CHECK_PATHS` und zufälliger Seiten aus XML-Sitemaps (`/wp-sitemap.xml`, `/sitemap_index.xml`).
    - Automatischer Bildvergleich mit ImageMagick (`compare`), PHP-GD oder Dateigrößen-Heuristik inkl. Generierung von visuellen Differenzbildern in `update-runs/<projekt>/<datum>/screenshots/`.
    - Ampel-Kriterien: $< 5\,\%$ = GRÜN, $5 - 20\,\%$ = GELB, $> 20\,\%$ / Fehler = ROT.
    - Vollständig konfigurierbar und überspringbar (`ENABLE_SCREENSHOTS="no"` oder `--no-screenshots`).
    - Tool-Erkennung beim Setup mit Hinweisen zur Installation von ImageMagick / `php-gd`.
  - **Umfassender Post-Check:** Prüfung von `wp core verify-checksums`, Versions-Diffs, Log-Analyse auf Fatal Errors, HTTP-Status 200 und Antwortzeitvergleich.
  - **Ampel-System & Exit-Codes:** 0 = GRÜN (Erfolg), 1 = GELB (Warnungen/Verlangsamung), 2 = ROT (Fehler/Abbruch).
  - **Automatisches Rollback-Skript:** Generierung von `update-runs/<projekt>/<datum>/rollback.sh` mit gezielten Downgrade-Befehlen und Restore-Anleitung.
  - **Interaktives Menü & CLI-Parameter:** `--project=`, `--dry-run`, `--no-backup`, `--no-screenshots`, `--only=`, `--setup`, `--update-wpcli`, `--json`, `--help`.
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
