# Backup scripts #

Free to use. Feedback is welcome: Gregor Wendland, hello@gregor-wendland.com, https://gregor-wendland.com/anfrage-an-webentwickler/

## backup_full_db_files_zip.sh ##
- Dateien werden gezipt, Datenbankdump mit mysqldump erstellt und gezipt
    - beim packen der Dateien ist es möglich Ordner auszuschließen
- es können beliebig viele Datenbanken gesichert werden (nicht auf eine feste Anzahl begrenzt)
- Backup-Dateien werden in ein Projekt-Verzeichnis gespeichert
- Speichern der Backup-Dateien via sftp oder rsync möglich
- Jeder backup-Vorgang wird in einer Log-Datei dokumentiert

### Einrichtung / Zugangsdaten ###
Beim ersten Ausführen des Skripts wird automatisch geprüft, ob im selben Verzeichnis
eine `.env`-Datei existiert. Ist das nicht der Fall, startet ein interaktiver
Setup-Assistent, der nach den nötigen Zugangsdaten fragt (Datenbank(en), Zielordner,
optional sftp/rsync) und daraus die `.env`-Datei anlegt (Zugriffsrechte 600).
Bei jedem weiteren Aufruf wird diese `.env`-Datei einfach eingelesen, es muss
nichts mehr manuell im Skript eingetragen werden.

Beim Datenbank-Setup wird so lange nach weiteren Datenbanken gefragt, bis der
Datenbankname leer gelassen wird – es können also beliebig viele Datenbanken
konfiguriert werden (in der `.env` als `DB_COUNT` und `DB_1_*`, `DB_2_*`, ...
gespeichert). Ältere `.env`-Dateien im bisherigen `DB_*`/`DB2_*`-Format werden
weiterhin automatisch unterstützt, ohne dass der Setup-Assistent erneut
durchlaufen werden muss.

Eine `.env.example` liegt als Referenz bei, welche Werte konfiguriert werden können.
Die `.env`-Datei enthält Zugangsdaten und ist über `.gitignore` von der
Versionsverwaltung ausgeschlossen – sie sollte niemals eingecheckt werden.

## backup_sync_proxy_\[projectname\].sh ##

- Dateien werden aus dem Backup-Verzeichnis eines Serves auf einen Vermittler-Server geladen
- Vom Vermittler-Server werden die Daten auf einen dritten Server synchronisiert
- Jeder Sync-Vorgang wird in einer Log-Datei dokumentiert
