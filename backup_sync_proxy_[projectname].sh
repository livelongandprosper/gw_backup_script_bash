#!/bin/
script="$0"
basename="$(dirname $script)"

before=$(date +%s)

###
# Backup File Sync Proxy Script
#
# (c) Gregor Wendland 2018 /// free to use, free to change, do what you want with this file, no warranty
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

# E-Mail-Benachrichtigung
status_email_address=''
alert_email_address=''

# Backup Zielordner
backup_cache_folder="$basename/../backup_files/$projekt_basis_dateiname/" # better use absolute path / should be outside of backup script folder

################################
################################
################################
## ab hier ist alles automatisch – es braucht nichts mehr angepasst werden

# Backup Zielordner erstellen
mkdir -p $backup_cache_folder
mkdir -p $basename'/log/'

# TODO: create .htaccess with deny from all statement

# Dateien
log_file_name=$basename'/log/'$projekt_basis_dateiname'_'$(date +%Y-%m-%d_%H-%M-%S)'.log'

# Kontrollvariablen
transmitted=''


################################
################################
################################
# Let the show begin...
echo "======================================" | tee -a $log_file_name
echo "Backup Sync $projekt_basis_dateiname" | tee -a $log_file_name
echo "$(date)" | tee -a $log_file_name
echo "Quelle: $rysnc_source_host | Ziel: $rysnc_destination_host" | tee -a $log_file_name
echo "======================================" | tee -a $log_file_name
echo | tee -a $log_file_name

if [ \( "$rysnc_source_host" != "" \) -a \( "$rysnc_destination_host" != "" \) ]
then
    # Dateien holen (rsync)
    echo
    echo "======================================"
    echo "Dateien von entferntem Server laden (rsync)..." | tee -a $log_file_name
    echo " entfernter Ordner: "$rsync_source_directory | tee -a $log_file_name
    if [ "$rsync_source_key" != "" ]
    then
        rsync -rltDvzre "ssh -i $rsync_source_ssh_key_path" --progress $rsync_source_user@$rysnc_source_host:$rsync_source_directory $backup_cache_folder | tee -a $log_file_name
    else
        rsync -rltDvzre "ssh" --progress $rsync_source_user@$rysnc_source_host:$rsync_source_directory $backup_cache_folder | tee -a $log_file_name
    fi

    # Wurden die Daten übertragen?
    if [ "$?" -eq "0" ]
    then
      transmitted='true'
    else
      transmitted=''
      echo "Error while fetching data from remote backup" | tee -a $log_file_name
    fi

    echo
    echo "======================================"

    # Dateien sichern (rsync)
    echo "Dateien zum Zielserver übertragen (rsync)..." | tee -a $log_file_name
    echo " entfernter Ordner: "$rsync_destination_directory | tee -a $log_file_name
    if [ "$rsync_destination_key" != "" ]
    then
        rsync -rltDvzre "ssh -i $rsync_destination_ssh_key_path" --progress $backup_cache_folder $rsync_destination_user@$rysnc_destination_host:$rsync_destination_directory  | tee -a $log_file_name
    else
        rsync -rltDvzre "ssh" --progress $backup_cache_folder $rsync_destination_user@$rysnc_destination_host:$rsync_destination_directory | tee -a $log_file_name
    fi

    # Wurden die Daten übertragen?
    if [ "$?" -eq "0" ]
    then
      transmitted='true'
    else
      transmitted=''
      echo "Error while putting data to remote backup" | tee -a $log_file_name
    fi
else
    echo "Source hosst or destination host were not defined" | tee -a $log_file_name
fi
echo | tee -a $log_file_name

# TODO: implement delete of files if files were transmitted and if delete_if_transmitted is true

# Status per E-Mail senden
# TODO: implement mail status
# echo '' | mail -s "Backup $projekt_basis_dateiname $(date +%s)" "$status_email_address"

## Vergangene Zeit
after=$(date +%s)
echo "Dauer der Backup-Synchronisation: " $((after - $before)) " Sekunden" | tee -a $log_file_name
echo | tee -a $log_file_name
