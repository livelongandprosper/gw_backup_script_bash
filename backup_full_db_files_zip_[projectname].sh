#!/bin/bash
basename=$(pwd)

before=$(date +%s)

###
# BackupScript zum Backup von Websites
# - Dateien einer Website
# - - optional können Dateien ausgeschlossen werden (files_dir_ignore)
# - Datenbank einer Website
# - Backup dateien können an entfernten Server via sftp oder rsync übertragen werden
#
# (c) Gregor Wendland 2017-2018 /// free to use, free to change, do what you want with this file, no warranty
###
#
# Wieder-einspielen der Datenbank (Beispiele):
# mysql -h'localhost' -p'myVerySecurePassword' -u'my_db_user' 'my_db_name' < db_backup.sql
# mysql -h$db_host -u$db_user -p$db_password $db_name < db_backup.sql
#
# Dateien müssen bei einer Wiederherstellung mit unzip entpackt werden.
#
###

################################
################################
################################
## Variablen - anpassen!

# Dateiname von Backup-Dateien, die angelegt werden (ohne Suffix)
projekt_basis_dateiname='backup'

# Datenbank Zugangsdaten (es empfiehlt sich einen Nur-Lesezugriff-Datenbankbenutzer dafür zu verwenden)
db_host='localhost'
db_name='my_db_name'
db_user='my_db_user'
db_password='myVerySecurePassword'
db2_host=''
db2_name=''
db2_user=''
db2_password=''


# Website-Ordner (wo liegen die zu sichernden Dateien)
source_files_dir='/pfad/zum/website/root/' # mehrere ordner mit leerzeichen trennen
source_files_dir_ignore='' # z.B. ('*/media/*' '*/other_dir_to_exlude/*') # files_dir_i3gnore=('*/media/*' '*/dmc2017g/*')

# sftp -oPort=custom_port sammy@your_server_ip_or_remote_hostname
sftp_host=''
sftp_port='22'
sftp_key='/.ssh/id_rsa_backup.pub' # create key with  | ssh-keygen -t rsa -b 4096
sftp_user='sftuser'
sftp_directory=''
sftp_batchfile=$projekt_basis_dateiname'_sftp_upload_batchfile'
sftp_path_to_ssh_binary='/usr/local/rsync/bin/ssh'

# rsync server
rysnc_host=''
rsync_user=''
rsync_directory='' # relative to rynch users root directory
rsync_key='/.ssh/id_rsa_backup' # private key on server; upload public key to remote server | create key with ssh-keygen -t rsa -b 4096

# Backup Lebenszeit (0 entspricht unendlich)
backup_live_time=0

# lokale Backup-Dateien löschen, wenn übertragung funktioniert hat
delete_if_transmitted=false

# E-Mail-Benachrichtigung
status_email_address=''
alert_email_address=''
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
## ab hier ist alles automatisch – es braucht nichts mehr angepasst werden

## Funktionen
# backup db
#  parameter1: db_host
#  parameter2: db_name
#  parameter3: db_user
#  parameter4: db_password
function backup_db() {
    local return_value=0
    local db_host=$1
    local db_name=$2
    local db_user=$3
    local db_password=$4
	local db_dateiname=$backup_destiantion$projekt_basis_dateiname'_'$(date +%Y-%m-%d_%H-%M-%S)'_'$db_name

    # Datenbanken sichern
    if [ "$db_name" != "" ]
    then
        echo "Sichern der Datenbank in Datei "$db_dateiname$dateiendung_zip" ..." | tee -a $log_file_name
        mysqldump --replace --skip-lock-tables -h$db_host -u$db_user -p$db_password $db_name > $db_dateiname$db_dateiendung | tee -a $log_file_name
        echo "erledigt." | tee -a $log_file_name
        echo

        echo "Nachbearbeiten der Sicherung von "$db_dateiname$dateiendung_zip" ..." | tee -a $log_file_name
        # DEFINER=`xyz` mit CURRENT_USER ersetzen
        sed -ri 's/DEFINER=`[^`]+`@`[^`]+`/DEFINER=CURRENT_USER/g' $db_dateiname$db_dateiendung | tee -a $log_file_name
        echo "erledigt." | tee -a $log_file_name
        echo | tee -a $log_file_name

        # zip
        if ! [ -x "$(command -v zip)" ]; then
            echo 'Error: zip is not installed.' | tee -a $log_file_name >&2
            echo 'sql file is not compressed' | tee -a $log_file_name
        else
            echo "ZIP-Datei von Sicherung erstellen $db_dateiname$db_dateiendung$dateiendung_zip ..." | tee -a $log_file_name
            zip $db_dateiname$db_dateiendung$dateiendung_zip $db_dateiname$db_dateiendung | tee -a $log_file_name
            if [ "$?" -eq "0" ]
            then
                # sql-datei löschen
                echo "Unkomprimierte Datei löschen $dateiname$dateiendung ..." | tee -a $log_file_name
                rm -v $db_dateiname$db_dateiendung | tee -a $log_file_name
                echo | tee -a $log_file_name
            else
                echo "Zip-Datei konnte nicht erstellt werden. $db_dateiname$db_dateiendung$db_dateiendung bleibt erhalt." | tee -a $log_file_name
            fi
            echo | tee -a $log_file_name
        fi
    fi

    return ${return_value}
}

# Backup Zielordner
backup_destiantion=$basename"/$projekt_basis_dateiname/"
mkdir -p $backup_destiantion
mkdir -p $basename'/log/'

# TODO: create .htaccess with deny from all statement

# Dateien
dateien_dateiname=$backup_destiantion$projekt_basis_dateiname'_'$(date +%Y-%m-%d_%H-%M-%S)'_'files
log_file_name=$basename'/log/'$projekt_basis_dateiname'_'$(date +%Y-%m-%d_%H-%M-%S)'.log'

# Dateiendungen
dateiendung_zip='.zip'
db_dateiendung='.sql'

# Kontrollvariablen
transmitted=''


################################
################################
################################
# Let the show begin...
clear

echo "======================================" | tee -a $log_file_name
echo "Backup $projekt_basis_dateiname" | tee -a $log_file_name
echo "$(date)" | tee -a $log_file_name
echo "Script is located"
echo "$basename"
echo "======================================" | tee -a $log_file_name
echo "backup files will be saved here $backup_destiantion"| tee -a $log_file_name
echo "======================================" | tee -a $log_file_name
echo | tee -a $log_file_name
echo

# Datenbanken sichern
if [ "$db_name" != "" ]
then
    backup_db "$db_host" "$db_name" "$db_user" "$db_password"
fi
if [ "$db2_name" != "" ]
then
    backup_db "$db2_host" "$db2_name" "$db2_user" "$db2_password"
fi


# Dateien zippen
if [ "$source_files_dir" != "" ]
then
    if ! [ -x "$(command -v zip)" ]; then
        echo 'Error: zip is not installed.' | tee -a $log_file_name >&2
        echo 'files could not be packed into zip file' | tee -a $log_file_name
    else
        echo "ZIP-Datei von Dateien im Website-Verzeichnis ("$source_files_dir") erstellen ..." | tee -a $log_file_name
        if [ "$source_files_dir_ignore" != "" ]
        then
            echo " ausgeschlossene(r) Ordner: ${source_files_dir_ignore[@]}" | tee -a $log_file_name
            zip -rq $dateien_dateiname$dateiendung_zip $source_files_dir -x ${source_files_dir_ignore[@]} | tee -a $log_file_name
        else
            zip -rq $dateien_dateiname$dateiendung_zip $source_files_dir | tee -a $log_file_name
        fi
        echo "erledigt."
        echo
    fi
fi

# Dateien per rsync synchronisieren (rsync)
if [ "$rysnc_host" != "" ]
then
    echo "Dateien von entferntem Server synchronisieren (rsync)..." | tee -a $log_file_name
    echo " lokaler Ordner: "$backup_destiantion | tee -a $log_file_name
    echo " entfernter Ordner: "$rsync_directory | tee -a $log_file_name
    if [ "$rsync_key" != "" ]
    then
        rsync -rltDvzre "ssh -i $rsync_key" --progress $backup_destiantion $rsync_user@$rysnc_host:$rsync_directory | tee -a $log_file_name
    else
        rsync -rltDvzre "ssh" --progress $backup_destiantion $rsync_user@$rysnc_host:$rsync_directory | tee -a $log_file_name
    fi

    # Wurden die Daten übertragen?
    if [ "$?" -eq "0" ]
    then
      transmitted='true'
    else
      transmitted=''
      echo "Error while running rsync" | tee -a $log_file_name
    fi
fi
echo | tee -a $log_file_name

# Dateien per sftp kopieren sftp
if [ "$sftp_host" != "" ]
then
    echo "Dateien auf entfernten Server kopieren (sftp)..." | tee -a $log_file_name
    # batchfile für sftp erstellen
    if [ "$sftp_directory" != "" ]
    then
        echo "cd $sftp_directory" >> $sftp_batchfile $log_file_name
    fi

    for i in `ls -x -1 $backup_destiantion`
    do
        echo "put $backup_destiantion/$i" >> $sftp_batchfile $log_file_name
    done
    echo "exit" >> $sftp_batchfile $log_file_name

    # hier ist der eigentliche upload auf den backup-server
    sftp -S $sftp_path_to_ssh_binary -b $sftp_batchfile -o PubkeyAuthentication=yes -o IdentityFile=$sftp_key -o Port=$sftp_port $sftp_user@$sftp_host | tee -a $log_file_name

    # Wurden die Daten übertragen?
    if [ "$?" -eq "0" ]
    then
      transmitted='true'
    else
      transmitted=''
      echo "Error while running sftp" | tee -a $log_file_name
    fi

    # Dokumenation in logfile
    echo "logfile content:" >> $log_file_name
    echo "-----" >> $log_file_name
    cat $sftp_batchfile >> $log_file_name
    echo "-----" >> $log_file_name

    # batch file löschen
    rm -v $sftp_batchfile | tee -a $log_file_name
    echo | tee -a $log_file_name
fi

# Dateien, die älter als $backup_live_time Tage sind löschen
if [ \( "$backup_destiantion" != "" \) -a \( "$backup_live_time" != "0" \) ]
then
    echo "Dateien in $backup_destiantion älter als $backup_live_time Tage löschen ..." | tee -a $log_file_name
    find $backup_destiantion* -mtime +$backup_live_time -type f -delete -print ! -regex '*.sh' | tee -a $log_file_name
    echo "erledigt." | tee -a $log_file_name
    echo | tee -a $log_file_name
fi

# Status per E-Mail senden
# TODO: implement mail status
# echo '' | mail -s "Backup $projekt_basis_dateiname $(date +%s)" "$status_email_address"

## Vergangene Zeit
after=$(date +%s)
echo "Dauer des Backup-Vorgangs: " $((after - $before)) " Sekunden" | tee -a $log_file_name
echo | tee -a $log_file_name
