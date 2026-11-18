# Backup scripts #

Free to use. Feedback is welcome: Gregor Wendland, hello@gregor-wendland.com, https://gregor-wendland.com/anfrage-an-webentwickler/

Eine Übersicht aller Versionsänderungen und Neuerungen befindet sich im [CHANGELOG.md](CHANGELOG.md).

## backup_full_db_files_zip.sh ##
- Dateien werden gezipt, Datenbankdump mit mysqldump erstellt und gezipt
    - beim packen der Dateien ist es möglich Ordner auszuschließen
- es können beliebig viele Datenbanken gesichert werden (nicht auf eine feste Anzahl begrenzt)
- **ein Skript für beliebig viele Projekte**: jedes Projekt (z.B. jede Website) bekommt seine
  eigene Konfigurationsdatei, es muss keine eigene Skript-Kopie pro Projekt angelegt werden
- **automatische WordPress-Erkennung & Konfigurations-Import**:
  - durchsucht Verzeichnisse (z.B. `..` oder Unterordner) automatisch nach WordPress-Installationen
  - liest Datenbankzugangsdaten (DB_NAME, DB_USER, DB_PASSWORD, DB_HOST) direkt aus der `wp-config.php` aus
  - schlägt Projektnamen / Basisdateinamen anhand von Domain (`WP_HOME`/`WP_SITEURL`) oder Ordnernamen vor
  - richtet auf Wunsch automatisch empfohlene WordPress-Ausschlussregeln (Cache, Backups, .git) ein
- pro Lauf frei wählbar: alle Projekte oder nur ein bestimmtes, und alles/nur Datenbank(en)/nur Dateien
- Backup-Dateien werden in ein Projekt-Verzeichnis gespeichert
- Speichern der Backup-Dateien via sftp oder rsync möglich
- Jeder backup-Vorgang wird in einer Log-Datei dokumentiert
- eine gesicherte Datenbank kann interaktiv wieder eingespielt werden (`--restore`)
- beim Einrichten eines Projekts kann optional die Größe des zu sichernden Datenordners angezeigt werden
- beim Aufruf ohne Parameter im Terminal erscheint ein interaktives Hauptmenü mit allen Aktionen

### Einrichtung / Zugangsdaten ###
Das Skript kann für beliebig viele Projekte im selben Ordner verwendet werden. Jedes
Projekt bekommt eine eigene Konfigurationsdatei nach dem Muster `.env.<projektname>`
(z.B. `.env.kundeA`, `.env.kundeB`). Existiert für ein Projekt noch keine solche Datei,
startet automatisch ein interaktiver Setup-Assistent, der nach den nötigen Zugangsdaten
fragt (Datenbank(en), Zielordner, optional sftp/rsync, Standard-Umfang) und daraus die
`.env.<projektname>`-Datei anlegt (Zugriffsrechte 600). Bei jedem weiteren Aufruf wird
diese Datei einfach eingelesen, es muss nichts mehr manuell im Skript eingetragen werden.

Eine bereits bestehende einzelne `.env`-Datei (ohne Projektnamen, aus einer älteren
Skript-Version) wird weiterhin automatisch als Projekt `default` unterstützt.

Beim Datenbank-Setup wird so lange nach weiteren Datenbanken gefragt, bis der
Datenbankname leer gelassen wird – es können also beliebig viele Datenbanken pro
Projekt konfiguriert werden (in der `.env`-Datei als `DB_COUNT` und `DB_1_*`, `DB_2_*`,
... gespeichert). Ältere `.env`-Dateien im bisherigen `DB_*`/`DB2_*`-Format werden
weiterhin automatisch unterstützt, ohne dass der Setup-Assistent erneut
durchlaufen werden muss.

Eine `.env.example` liegt als Referenz bei, welche Werte konfiguriert werden können.
`.env`- und `.env.<projektname>`-Dateien enthalten Zugangsdaten und sind über
`.gitignore` von der Versionsverwaltung ausgeschlossen – sie sollten niemals
eingecheckt werden.

### Interaktives Hauptmenü ###
Wird das Skript in einem Terminal ohne jegliche Parameter aufgerufen, erscheint
ein Hauptmenü, über das sich alle Funktionen bequem auswählen lassen – ohne
dass man sich die einzelnen CLI-Parameter merken muss:

```
======================================
BackupScript - Hauptmenü
======================================
  1) Ein Projekt sichern
  2) Alle Projekte sichern
  3) Neues Projekt einrichten
  4) WordPress-Installationen suchen & einrichten
  5) Pre-Check & Sicherheitsstatus prüfen
  6) Datenbank wiederherstellen
  7) Projekt-Datengröße anzeigen
  8) Projektübersicht anzeigen
  0) Beenden
======================================
```

- **Ein Projekt sichern**: sichert ein einzelnes Projekt (Auswahl, falls mehrere vorhanden
  sind); führt vorab einen automatischen Pre-Check durch und fragt, was gesichert werden soll (Standard/nur Datenbank(en)/nur Dateien/alles).
- **Alle Projekte sichern**: sichert nacheinander alle konfigurierten Projekte; führt für jedes Projekt Pre-Checks durch und fragt vorher nach dem gewünschten Umfang.
- **Neues Projekt einrichten**: startet den Setup-Assistenten für ein neues Projekt (erkennt
  einen angegebenen WordPress-Ordner automatisch und übernimmt dessen Zugangsdaten).
- **WordPress-Installationen suchen & einrichten**: scannt ein übergeordnetes oder
  angegebenes Verzeichnis nach allen vorhandenen `wp-config.php`-Dateien, extrahiert
  die Datenbank-Zugangsdaten, schlägt Projektnamen/Domains vor und legt die `.env`-Dateien
  im Batch oder einzeln an.
- **Pre-Check & Sicherheitsstatus prüfen**: führt gezielte Diagnose- und Sicherheitsprüfungen (WordPress Debug-Status, Debug-Logs, Upload-Sicherheit/Webshells, DB-Erreichbarkeit) mit farblicher Hervorhebung durch, ohne ein Backup zu starten.
- **Datenbank wiederherstellen**: entspricht `--restore` (siehe unten).
- **Projekt-Datengröße anzeigen**: zeigt die Größe des Website-Ordners sowie der
  bisherigen Backups eines Projekts an (`du -sh`).
- **Projektübersicht anzeigen**: listet alle konfigurierten Projekte mit Anzahl der
  Datenbanken, Website-Ordner, Standard-Umfang und dem letzten Backup auf.

Das Menü wird nur angezeigt, wenn das Skript interaktiv (in einem Terminal) und
komplett ohne Parameter aufgerufen wird. Sobald ein Parameter übergeben wird
(z.B. `--project=`, `--scope=`, `--restore` oder `--scan-wp`), wird das Menü übersprungen und
direkt wie angegeben verfahren – dadurch bleiben bestehende Cronjobs unverändert
lauffähig.

### Automatische WordPress-Erkennung (`--scan-wp`) ###
Das Skript kann selbstständig WordPress-Installationen suchen und vollständig einrichten:

```
./backup_full_db_files_zip.sh --scan-wp              # sucht im übergeordneten Ordner (..)
./backup_full_db_files_zip.sh --scan-wp=/var/www     # sucht in einem spezifischen Ordner
```

- **Pfad-Erkennung:** Unterstützt relative Pfadangaben (z.B. `..`, `.`, `../sites`) relativ zum Skript-Verzeichnis sowie absolute Pfade.
- **Automatisches Auslesen:** `DB_NAME`, `DB_USER`, `DB_PASSWORD`, `DB_HOST` und Tabellen-Präfixe werden direkt und sicher aus `wp-config.php` ausgelesen.
- **Intelligente Vorschläge:** Aus `WP_HOME`, `WP_SITEURL` oder dem Ordnernamen wird automatisch ein passender Projektname vorgeschlagen.
- **Ausschlussmuster:** Typische WordPress-Cache- und Backup-Verzeichnisse (`*/wp-content/cache/*`, `*/wp-content/uploads/cache/*`, `*/wp-content/updraft/*`, etc.) werden auf Wunsch direkt als Ausschluss hinterlegt.
- **Manuelle Ergänzung:** Sollten Zugangsdaten fehlen oder abweichen, können alle Werte während des Assistenten bestätigt, angepasst oder manuell eingegeben werden.

### Projekt- und Umfang-Auswahl beim Backup ###
Für nicht-interaktive Aufrufe (z.B. per Cronjob) stehen zwei Parameter zur
Verfügung, die auch weiterhin ohne Menü direkt funktionieren:

```
./backup_full_db_files_zip.sh                          # interaktiv: zeigt das Hauptmenü
./backup_full_db_files_zip.sh --scan-wp                # WordPress-Installationen scannen & importieren
./backup_full_db_files_zip.sh --project=kundeA          # nur Projekt "kundeA"
./backup_full_db_files_zip.sh --project=alle            # alle Projekte
./backup_full_db_files_zip.sh --project=alle --scope=db # bei allen Projekten nur die Datenbank(en)
./backup_full_db_files_zip.sh --scope=dateien           # nur Dateien (Projekt ggf. interaktiv wählen)
```

Wird `--project=<name>` mit einem noch unbekannten Namen angegeben, startet
automatisch der Setup-Assistent für dieses neue Projekt. Fehlt der `--scope`-Parameter
und ist im Projekt kein `DEFAULT_SCOPE` hinterlegt, wird interaktiv danach gefragt
(alles / nur Datenbank(en) / nur Dateien).

### Datenbank wiederherstellen (`--restore`) ###
Um eine gesicherte Datenbank wieder einzuspielen, steht der Parameter `--restore`
zur Verfügung:

```
./backup_full_db_files_zip.sh --restore                    # Projekt ggf. interaktiv wählen
./backup_full_db_files_zip.sh --restore --project=kundeA    # Restore für Projekt "kundeA"
```

Das Skript fragt (falls das Projekt mehr als eine Datenbank hat) nach der
gewünschten Datenbank, schlägt automatisch gefundene Backup-Dateien im
Projekt-Verzeichnis zur Auswahl vor (`.sql` und `.sql.zip`, alternativ ist auch
die manuelle Angabe eines Pfads möglich) und entpackt gezippte Backups bei
Bedarf automatisch. Vor dem eigentlichen Import mit `mysql` muss der Vorgang
noch einmal ausdrücklich mit `ja` bestätigt werden, da die Zieldatenbank dabei
überschrieben wird. `--restore` funktioniert immer nur für ein einzelnes
Projekt (kein `--project=alle`).

### Größe des Datenordners anzeigen ###
Beim Einrichten eines Projekts (Setup-Assistent) wird nach dem Website-Ordner
gefragt, der gesichert werden soll. Existiert dieser Ordner bereits, kann
optional dessen Größe (`du -sh`) angezeigt werden – praktisch, um vorab
abzuschätzen, wie groß das Datei-Backup ungefähr wird. Bei sehr großen Ordnern
kann die Ermittlung der Größe etwas dauern.

### Pre-Backup & Sicherheitsprüfung (`--check` / Menüpunkt 5) ###
Vor Backups (besonders vor CMS-/Plugin-Updates) führt das Skript automatische Pre-Checks durch. Diese können auch jederzeit separat aufgerufen werden:

```
./backup_full_db_files_zip.sh --check                  # Pre-Check für alle bzw. ausgewählte Projekte
./backup_full_db_files_zip.sh --check --project=kundeA  # Pre-Check gezielt für "kundeA"
```

**Was wird geprüft? (mit übersichtlicher Farbcodierung `[✓ OK]`, `[⚠ WARNUNG]`, `[✖ ACHTUNG]`):**
- **Festplattenspeicher:** Verfügbarer Speicherplatz auf dem Zielmedium (Warnung bei < 2 GB, Alarm bei < 500 MB).
- **WordPress Debug-Modus:**
  - Status von `WP_DEBUG` (Warnung, falls im Produktivbetrieb noch aktiv).
  - Status von `WP_DEBUG_DISPLAY` (kritische Warnung, falls Fehler im Browser für Besucher sichtbar ausgegeben werden).
  - Prüfung auf vorhandene `wp-content/debug.log` inklusive Größenermittlung und Warnung bei übermäßigem Datenvolumen (> 10 MB).
- **PHP Error-Logs:** Auffinden von `error_log`-Dateien in Haupt- und Admin-Verzeichnissen.
- **Wartungsmodus:** Erkennung von aktiven `.maintenance`-Dateien.
- **Sicherheits- & Malware-Heuristik (Hacks):**
  - **Uploads-Ordner:** Aufspüren verdächtiger PHP-Skripte (`*.php`, `*.phtml`, `*.suspected`) in `wp-content/uploads/` (häufiges Indiz für eingeschleuste Webshells).
  - **Kern-Dateien:** Prüfung von `wp-config.php` und `index.php` auf verdächtige Code-Verschleierungsmuster (`eval(base64_decode...)`).
  - **Versteckte Skripte:** Suche nach versteckten PHP-Dateien (`.*.php`).
- **Datenbank-Erreichbarkeit:** Live-Verbindungstest und Ermittlung der vorhandenen Tabellenanzahl vor Beginn des Dumps.

### Sicherheit & Robustheit (Einsatz innerhalb & außerhalb des Webroots) ###

Das Skript ist so konzipiert, dass es sowohl **außerhalb des Webroots** (empfohlene Best Practice) als auch **innerhalb des Webroots** sicher und stabil betrieben werden kann:

1. **Webroot-Schutz (.htaccess für Apache 2.4 & 2.2):**
   - Das Skript erzeugt in allen Backup-Verzeichnissen sowie im `log/`-Ordner automatisch moderne Schutzregeln (`Require all denied` für Apache 2.4 mit Fallback auf `Deny from all` für Apache 2.2).
   - Im Hauptverzeichnis des Skripts werden sensible Konfigurationsdateien (`.env.*`), Logs (`*.log`), Shellskripte (`*.sh`) und Git-Dateien (`.git*`) vor direktem Webaufruf geschützt, ohne normale Webdateien (z. B. falls das Skript im Webroot liegt) zu blockieren.
2. **Nginx-Konfiguration (falls im Webroot unter Nginx betrieben):**
   - Da Nginx keine `.htaccess`-Dateien liest, empfiehlt sich in der Server-Konfiguration:
     ```nginx
     location ~ /\.(env|git|htaccess) { deny all; return 404; }
     location ~ /(log|.*_files)/.*\.(sql|zip|log)$ { deny all; return 404; }
     ```
3. **Dateirechte & Umask (`umask 077`):**
   - Alle neu angelegten Verzeichnisse, Backups, temporären Dateien und Logs werden mit restriktiven Rechten (nur für den ausführenden Benutzer les-/schreibbar) erzeugt. `.env.*`-Dateien werden standardmäßig auf `chmod 600` gesetzt.
4. **Fehlerbehandlung & Verlässlichkeit bei Datenbank-Dumps:**
   - Exit-Codes von `mysqldump` und `zip` werden explizit geprüft. Sollte ein Dump fehlschlagen, wird der Vorgang abgebrochen und keine unvollständige oder leere Backup-Datei erstellt.
   - Standardmäßig werden Tabellenstrukturen, Daten, Routines (`--routines`), Triggers (`--triggers`), `--quick`, `--max_allowed_packet=512M` und `--default-character-set=utf8mb4` verwendet.
   - Kompatibilität mit MySQL 8.0 und Managed Cloud DBs wird automatisch sichergestellt (`--column-statistics=0` und `--set-gtid-purged=OFF`, sofern vom Client unterstützt).
   - `DEFINER`-Deklarationen werden automatisch und portabel bereinigt (`CURRENT_USER`), um Restores auf anderen Servern zu vereinfachen.
5. **Robustes Dateihandling & Bereinigung:**
   - Archivierung via `zip -y` (symbolische Links werden als Symlinks erhalten und führen nicht zu Endlosschleifen oder doppeltem Packen).
   - Umfassende Standard-Ausschlüsse für WordPress (Caches, Updraft-/Ai1wm-/BackupBuddy-Archive, Debug-/Error-Logs, Wordfence-Logs, `.DS_Store`, `node_modules`).
   - Dateilisten für sftp werden sicher per Shell-Globbing verarbeitet (kein fehleranfälliges `ls`-Parsing bei Leer- oder Sonderzeichen).
   - Bereinigungen nach erfolgreicher Übertragung (`delete_if_transmitted`) sowie das Löschen veralteter Backups (`backup_live_time`) erfolgen gezielt über `find` unter Ausschluss der Schutzdateien (`.htaccess`).

## backup_sync_proxy_\[projectname\].sh ##

- Dateien werden aus dem Backup-Verzeichnis eines Serves auf einen Vermittler-Server geladen
- Vom Vermittler-Server werden die Daten auf einen dritten Server synchronisiert
- Jeder Sync-Vorgang wird in einer Log-Datei dokumentiert
