# Backup scripts #

Free to use. Feedback is welcome: Gregor Wendland, hello@gregor-wendland.com, https://gregor-wendland.com/anfrage-an-webentwickler/

## backup_full_db_files_zip.sh ##
- Dateien werden gezipt, Datenbankdump mit mysqldump erstellt und gezipt
    - beim packen der Dateien ist es möglich Ordner auszuschließen
- es können beliebig viele Datenbanken gesichert werden (nicht auf eine feste Anzahl begrenzt)
- **ein Skript für beliebig viele Projekte**: jedes Projekt (z.B. jede Website) bekommt seine
  eigene Konfigurationsdatei, es muss keine eigene Skript-Kopie pro Projekt angelegt werden
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
  4) Datenbank wiederherstellen
  5) Projekt-Datengröße anzeigen
  6) Projektübersicht anzeigen
  0) Beenden
======================================
```

- **Ein Projekt sichern**: sichert ein einzelnes Projekt (Auswahl, falls mehrere vorhanden
  sind); fragt dabei immer, was gesichert werden soll (Standard/nur Datenbank(en)/nur
  Dateien/alles).
- **Alle Projekte sichern**: sichert nacheinander alle konfigurierten Projekte; fragt
  vorher ebenfalls nach dem gewünschten Umfang (Standard/nur Datenbank(en)/nur
  Dateien/alles), der dann für alle Projekte verwendet wird.
- **Neues Projekt einrichten**: fragt einen Projektnamen ab und startet direkt den
  Setup-Assistenten für dieses neue Projekt (inkl. anschließendem ersten Backup).
- **Datenbank wiederherstellen**: entspricht `--restore` (siehe unten).
- **Projekt-Datengröße anzeigen**: zeigt die Größe des Website-Ordners sowie der
  bisherigen Backups eines Projekts an (`du -sh`).
- **Projektübersicht anzeigen**: listet alle konfigurierten Projekte mit Anzahl der
  Datenbanken, Website-Ordner, Standard-Umfang und dem letzten Backup auf.

Das Menü wird nur angezeigt, wenn das Skript interaktiv (in einem Terminal) und
komplett ohne Parameter aufgerufen wird. Sobald ein Parameter übergeben wird
(z.B. `--project=`, `--scope=` oder `--restore`), wird das Menü übersprungen und
direkt wie angegeben verfahren – dadurch bleiben bestehende Cronjobs unverändert
lauffähig.

### Projekt- und Umfang-Auswahl beim Backup ###
Für nicht-interaktive Aufrufe (z.B. per Cronjob) stehen zwei Parameter zur
Verfügung, die auch weiterhin ohne Menü direkt funktionieren:

```
./backup_full_db_files_zip.sh                          # interaktiv: zeigt das Hauptmenü
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
   - Standardmäßig werden Tabellenstrukturen, Daten, Routines (`--routines`), Triggers (`--triggers`) und `--quick` gesichert. `DEFINER`-Deklarationen werden automatisch und portabel bereinigt (`CURRENT_USER`), um Restores auf anderen Servern zu vereinfachen.
5. **Robustes Dateihandling & Bereinigung:**
   - Dateilisten für sftp werden sicher per Shell-Globbing verarbeitet (kein fehleranfälliges `ls`-Parsing bei Leer- oder Sonderzeichen).
   - Bereinigungen nach erfolgreicher Übertragung (`delete_if_transmitted`) sowie das Löschen veralteter Backups (`backup_live_time`) erfolgen gezielt über `find` unter Ausschluss der Schutzdateien (`.htaccess`).
   - Vor jedem Backup-Lauf wird der freie Festplattenspeicher geprüft und bei drohendem Engpass (< 500 MB) eine Warnung ausgegeben.

## backup_sync_proxy_\[projectname\].sh ##

- Dateien werden aus dem Backup-Verzeichnis eines Serves auf einen Vermittler-Server geladen
- Vom Vermittler-Server werden die Daten auf einen dritten Server synchronisiert
- Jeder Sync-Vorgang wird in einer Log-Datei dokumentiert
