#!/bin/bash
basename=$(cd "$(dirname "$0")" && pwd)
set -o pipefail
umask 077

before=$(date +%s)

###
# Backup File Sync Proxy Script
# Version: 2.0.0
#
# Put this file to a server that should fetch backuped data and put to another server
#
# (c) Gregor Wendland 2018-2026 /// free to use, free to change, do what you want with this file, no warranty
###

################################
################################
################################
## Variablen - anpassen

# Dateiname von Backup-Dateien, die angelegt werden (ohne Suffix)
projekt_basis_dateiname='backup'

# rsync source server
rysnc_source_host=''
rsync_source_user=''
rsync_source_directory='/backup' # relative to rynch users root directory
rsync_source_ssh_key_path='/.ssh/id_rsa_backup.pub' # create key with | ssh-keygen -t rsa -b 4096

# rsync destination server
rysnc_destination_host=''
rsync_destination_user=''
rsync_destination_directory='/users/xyz' # relative to rynch users root directory
rsync_destination_ssh_key_path='/.ssh/id_rsa_backup.pub' # create key with | ssh-keygen -t rsa -b 4096

# lokale Backup-Dateien löschen, wenn übertragung funktioniert hat
delete_if_transmitted=false

# Backup Lebenszeit
backup_live_time=0

# Backup Cache Lebenszeit (lokal gespeicherte Backups)
backup_localcache_time=7

# E-Mail-Benachrichtigung
status_email_address=''
alert_email_address=''

# Backup Zielordner
backup_cache_folder="$basename/../backup_files/$projekt_basis_dateiname/" # better use absolute path / should be outside of backup script folder

# .
# .
# .
# .
# .
# .
# .
# .
# .
# .
# .
# .
# .
# .
# .
# .
# .
# .
# .
# .
# .
# .
# .
# .
# .
# .
# .
# .
# .
# .
# .
################################
################################
################################
## ab hier ist alles automatisch – es braucht nichts mehr angepasst werden

# Erstellt/aktualisiert Apache-Schutzregeln (.htaccess) für Verzeichnisse (Webroot-Sicherheit für Apache 2.4 & 2.2)
function ensure_webroot_protection() {
    local target_dir="$1"
    local mode="${2:-deny_all}"
    [ -d "$target_dir" ] || mkdir -p "$target_dir"
    chmod 700 "$target_dir" 2>/dev/null || true

    local htaccess_path="${target_dir%/}/.htaccess"
    if [ ! -f "$htaccess_path" ]; then
        if [ "$mode" == "sensitive_only" ]; then
            cat > "$htaccess_path" <<'EOF'
# Schutz sensibler Dateien vor direktem Web-Aufruf (Apache 2.4 & 2.2)
<FilesMatch "^(\.env.*|\.git.*|.*\.log|.*\.sh)$">
    <IfModule mod_authz_core.c>
        Require all denied
    </IfModule>
    <IfModule !mod_authz_core.c>
        Order allow,deny
        Deny from all
    </IfModule>
</FilesMatch>
EOF
        else
            cat > "$htaccess_path" <<'EOF'
# Vollständigen Zugriff auf Backups/Logs verweigern (Apache 2.4 & 2.2)
<IfModule mod_authz_core.c>
    Require all denied
</IfModule>
<IfModule !mod_authz_core.c>
    Order allow,deny
    Deny from all
</IfModule>
EOF
        fi
        chmod 644 "$htaccess_path" 2>/dev/null || true
    fi
}

# Basis- und Zielordner erstellen & absichern
ensure_webroot_protection "$basename" "sensitive_only"
ensure_webroot_protection "$basename/log" "deny_all"
ensure_webroot_protection "$backup_cache_folder" "deny_all"

# Dateien
log_file_name="$basename/log/${projekt_basis_dateiname}_$(date +%Y-%m-%d_%H-%M-%S).log"
touch "$log_file_name"
chmod 600 "$log_file_name" 2>/dev/null || true

# Kontrollvariablen
transmitted=''

################################
################################
################################
# Let the show begin...
echo "======================================" | tee -a "$log_file_name"
echo "Backup Sync $projekt_basis_dateiname" | tee -a "$log_file_name"
echo "$(date)" | tee -a "$log_file_name"
echo "Quelle: $rysnc_source_host | Ziel: $rysnc_destination_host" | tee -a "$log_file_name"
echo "======================================" | tee -a "$log_file_name"
echo | tee -a "$log_file_name"

if [ -n "$rysnc_source_host" ] && [ -n "$rysnc_destination_host" ]; then
    # Dateien holen (rsync)
    echo
    echo "======================================"
    echo "Dateien von entferntem Server laden (rsync)..." | tee -a "$log_file_name"
    echo " entfernter Ordner: $rsync_source_directory" | tee -a "$log_file_name"
    echo " lokaler Ordner: $backup_cache_folder" | tee -a "$log_file_name"
    echo " $rsync_source_directory > $backup_cache_folder" | tee -a "$log_file_name"
    if [ -n "$rsync_source_ssh_key_path" ] && [ -f "$rsync_source_ssh_key_path" ]; then
        rsync -rltDvzre "ssh -i $rsync_source_ssh_key_path" --exclude='.htaccess' --progress "$rsync_source_user@$rysnc_source_host:$rsync_source_directory" "$backup_cache_folder" 2>&1 | tee -a "$log_file_name"
    else
        rsync -rltDvzre "ssh" --exclude='.htaccess' --progress "$rsync_source_user@$rysnc_source_host:$rsync_source_directory" "$backup_cache_folder" 2>&1 | tee -a "$log_file_name"
    fi
    source_rsync_status="${PIPESTATUS[0]}"

    # Wurden die Daten übertragen?
    if [ "$source_rsync_status" -eq 0 ]; then
      transmitted='true'
      echo "Dateien erfolgreich von Quelle geladen." | tee -a "$log_file_name"
    else
      transmitted=''
      echo "Error while fetching data from remote backup (Status: $source_rsync_status)" | tee -a "$log_file_name" >&2
    fi

    echo
    echo "======================================"

    # Dateien sichern (rsync)
    echo "Dateien zum Zielserver übertragen (rsync)..." | tee -a "$log_file_name"
    echo " lokaler Ordner: $backup_cache_folder" | tee -a "$log_file_name"
    echo " entfernter Ordner: $rsync_destination_directory" | tee -a "$log_file_name"
    echo " $backup_cache_folder > $rsync_destination_directory" | tee -a "$log_file_name"
    if [ -n "$rsync_destination_ssh_key_path" ] && [ -f "$rsync_destination_ssh_key_path" ]; then
        rsync -rltDvzre "ssh -i $rsync_destination_ssh_key_path" --exclude='.htaccess' --progress "$backup_cache_folder" "$rsync_destination_user@$rysnc_destination_host:$rsync_destination_directory" 2>&1 | tee -a "$log_file_name"
    else
        rsync -rltDvzre "ssh" --exclude='.htaccess' --progress "$backup_cache_folder" "$rsync_destination_user@$rysnc_destination_host:$rsync_destination_directory" 2>&1 | tee -a "$log_file_name"
    fi
    dest_rsync_status="${PIPESTATUS[0]}"

    # Wurden die Daten übertragen?
    if [ "$dest_rsync_status" -eq 0 ]; then
      echo "Dateien erfolgreich an Ziel übertragen." | tee -a "$log_file_name"
    else
      transmitted=''
      echo "Error while putting data to remote backup (Status: $dest_rsync_status)" | tee -a "$log_file_name" >&2
    fi
else
    echo "Source host or destination host were not defined" | tee -a "$log_file_name" >&2
fi
echo | tee -a "$log_file_name"

# Lokale Dateien löschen, wenn Übertragung erfolgreich war
if [ "$delete_if_transmitted" == "true" ] && [ "$transmitted" == "true" ]; then
    echo "Lokale Cache-Dateien nach erfolgreicher Übertragung löschen..." | tee -a "$log_file_name"
    if [ -n "$backup_cache_folder" ] && [ -d "$backup_cache_folder" ]; then
        find "$backup_cache_folder" -maxdepth 1 -type f ! -name '.htaccess' -delete -print | tee -a "$log_file_name"
    fi
    echo "erledigt." | tee -a "$log_file_name"
fi

# Dateien, die älter als $backup_localcache_time Tage sind löschen
if [ -n "$backup_cache_folder" ] && [ -d "$backup_cache_folder" ] && [ "$backup_localcache_time" != "0" ] && [ "$backup_localcache_time" -gt 0 ] 2>/dev/null; then
    echo "Dateien in $backup_cache_folder älter als $backup_localcache_time Tage löschen ..." | tee -a "$log_file_name"
    find "$backup_cache_folder" -maxdepth 1 -type f ! -name '.htaccess' ! -name '*.sh' -mtime +"$backup_localcache_time" -delete -print | tee -a "$log_file_name"
    echo "erledigt." | tee -a "$log_file_name"
    echo | tee -a "$log_file_name"
fi

# Alte Backups, älter als $backup_live_time von Backup-Ziel-Speicher löschen
# TODO: implement delete of remote feil server files after $backup_live_time is over


# Status per E-Mail senden
# TODO: implement mail status
# echo '' | mail -s "Backup $projekt_basis_dateiname $(date +%s)" "$status_email_address"

## Vergangene Zeit
after=$(date +%s)
echo "Dauer der Backup-Synchronisation: " $((after - $before)) " Sekunden" | tee -a $log_file_name
echo | tee -a $log_file_name
