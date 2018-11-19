#!/bin/bash
before=$(date +%s)

###
# BackupScript zum Backup von Websites
# - Dateien einer Website
# - - optional können Dateien ausgeschlossen werden (files_dir_ignore)
# - Datenbank einer Website
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
## Variablen - anpassen

# Dateiname von Backup-Dateien, die angelegt werden (ohne Suffix)
projekt_basis_dateiname='backup'

# Datenbank Zugangsdaten (es empfiehlt sich einen Nur-Lesezugriff-Datenbankbenutzer dafür zu verwenden)
db_password='myVerySecurePassword'
db_name='my_db_name'
db_user='my_db_user'
db_host='localhost'

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
rsync_key='/.ssh/id_rsa_backup.pub' # create key with  | ssh-keygen -t rsa -b 4096

################################
################################
################################
## ab hier ist alles automatisch – es braucht nichts mehr angepasst werden

# Backup Zielordner
backup_destiantion="./$projekt_basis_dateiname/"
mkdir -p $backup_destiantion
mkdir -p './log/'

# Dateien
dateien_dateiname=$backup_destiantion$projekt_basis_dateiname'_'$(date +%Y-%m-%d_%H-%M-%S)'_'files
db_dateiname=$backup_destiantion$projekt_basis_dateiname'_'$(date +%Y-%m-%d_%H-%M-%S)'_'$db_name
log_file_name='log/'$projekt_basis_dateiname'_'$(date +%Y-%m-%d_%H-%M-%S)'.log'

# Dateiendungen
dateiendung_zip='.zip'
db_dateiendung='.sql'


################################
################################
################################
# Let the show begin...

## Leerzeile
clear
echo
date | tee -a $log_file_name
echo "Sichern der Datenbank in Datei "$db_dateiname$dateiendung_zip" ..." | tee -a $log_file_name
mysqldump --replace --skip-lock-tables -h$db_host -u$db_user -p$db_password $db_name > $db_dateiname$db_dateiendung | tee -a $log_file_name
echo "erledigt." | tee -a $log_file_name
echo

echo "Nachbearbeiten der Sicherung ..." | tee -a $log_file_name
# DEFINER=`xyz` mit CURRENT_USER ersetzen
sed -ri 's/DEFINER=`[^`]+`@`[^`]+`/DEFINER=CURRENT_USER/g' $db_dateiname$db_dateiendung | tee -a $log_file_name
echo "erledigt." | tee -a $log_file_name
echo | tee -a $log_file_name

# zip
echo "ZIP-Datei von Sicherung erstellen $dateiname_converted$dateiendung$dateiendung_zip ..." | tee -a $log_file_name
zip $db_dateiname$db_dateiendung$dateiendung_zip $db_dateiname$db_dateiendung | tee -a $log_file_name
echo "erledigt." | tee -a $log_file_name
echo | tee -a $log_file_name

# sql-datei löschen
echo "Unkomprimierte Datei löschen $dateiname$dateiendung ..." | tee -a $log_file_name
rm -v $db_dateiname$db_dateiendung | tee -a $log_file_name
echo | tee -a $log_file_name

# Dateien zippen 
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

# Dateien per rsync synchronisieren (rsync)
echo "Dateien auf entfernten Server synchronisieren (rsync)..." | tee -a $log_file_name
if [ "$rysnc_host" != "" ]
then
    echo " entfernter Ordner: "$rsync_directory | tee -a $log_file_name
    if [ "$rsync_key" != "" ]
    then
        rsync -rltDvzre "ssh -i $rsync_key" $backup_destiantion $rsync_user@$rysnc_host:$rsync_directory | tee -a $log_file_name
    else
        rsync -rltDvzre "ssh" $backup_destiantion $rsync_user@$rysnc_host:$rsync_directory | tee -a $log_file_name
    fi
else
    echo " wird ausgelassen. (keine Zugangsdaten hinterlegt)" | tee -a $log_file_name
fi
echo | tee -a $log_file_name

# Dateien per sftp kopieren sftp
echo "Dateien auf entfernten Server kopieren (sftp)..." | tee -a $log_file_name
if [ "$sftp_host" != "" ]
then
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

    # Dokumenation in logfile
    echo "logfile content:" >> $log_file_name
    echo "-----" >> $log_file_name
    cat $sftp_batchfile >> $log_file_name
    echo "-----" >> $log_file_name

    # batch file löschen
    rm -v $sftp_batchfile | tee -a $log_file_name
    echo | tee -a $log_file_name
else
    echo " wird ausgelassen. (keine Zugangsdaten hinterlegt)" | tee -a $log_file_name
    echo | tee -a $log_file_name
fi



## Dateien, die älter als 14 Tage sind löschen
#echo "ZIP-Dateien die älter als 14 Tage sind löschen ..."
#find *.zip -mtime +14 -type f -delete
#echo "erledigt."
#echo


## Vergangene Zeit
after=$(date +%s)
echo "Dauer des Backup-Vorgangs: " $((after - $before)) " Sekunden" | tee -a $log_file_name
echo | tee -a $log_file_name
