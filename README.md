# Backup scripts #

Free to use. Feedback is welcome: Gregor Wendland, hello@gregor-wendland.com, https://gregor-wendland.com/anfrage-an-webentwickler/

## backup_full_db_files_zip_\[projectname\].sh ##
- Dateien werden gezipt, Datenbankdump mit mysqldump erstellt und gezipt
    - beim packen der Dateien ist es möglich Ordner auszuschließen
- Backup-Dateien werden in ein Projekt-Verzeichnis gespeichert
- Speichern der Backup-Dateien via sftp oder rsync möglich
- Jeder backup-Vorgang wird in einer Log-Datei dokumentiert

## backup_sync_proxy_\[projectname\].sh ##

- Dateien werden aus dem Backup-Verzeichnis eines Serves auf einen Vermittler-Server geladen
- Vom Vermittler-Server werden die Daten auf einen dritten Server synchronisiert
- Jeder Sync-Vorgang wird in einer Log-Datei dokumentiert
