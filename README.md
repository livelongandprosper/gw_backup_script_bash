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

### Projekt- und Umfang-Auswahl beim Backup ###
Beim Aufruf ohne Parameter fragt das Skript interaktiv nach, welches Projekt
gesichert werden soll (sofern mehrere `.env.*`-Dateien vorhanden sind) und was
gesichert werden soll (alles / nur Datenbank(en) / nur Dateien) – letzteres nur,
falls im Projekt kein `DEFAULT_SCOPE` hinterlegt ist. Für nicht-interaktive Aufrufe
(z.B. per Cronjob) stehen zwei Parameter zur Verfügung:

```
./backup_full_db_files_zip.sh                          # interaktiv
./backup_full_db_files_zip.sh --project=kundeA          # nur Projekt "kundeA"
./backup_full_db_files_zip.sh --project=alle            # alle Projekte
./backup_full_db_files_zip.sh --project=alle --scope=db # bei allen Projekten nur die Datenbank(en)
./backup_full_db_files_zip.sh --scope=dateien           # nur Dateien (Projekt ggf. interaktiv wählen)
```

Wird `--project=<name>` mit einem noch unbekannten Namen angegeben, startet
automatisch der Setup-Assistent für dieses neue Projekt.

## backup_sync_proxy_\[projectname\].sh ##

- Dateien werden aus dem Backup-Verzeichnis eines Serves auf einen Vermittler-Server geladen
- Vom Vermittler-Server werden die Daten auf einen dritten Server synchronisiert
- Jeder Sync-Vorgang wird in einer Log-Datei dokumentiert
