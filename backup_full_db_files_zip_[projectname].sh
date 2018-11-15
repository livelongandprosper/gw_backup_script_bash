#!/bin/bash

###
# BackupScript zum Backup von Website
# - Dateien einer Website
# - - optional können Dateien ausgeschlossen werden (files_dir_ignore)
# - Datenbank einer Website
#
# (c) Gregor Wendland 2017-2018 /// free to use, free to change, do what you want with this file, no warranty
###
#
# mysql -h'localhost' -p'myVerySecurePassword' -u'my_db_user' 'my_db_name' < db_backup.sql
# mysql -h$db_host -u$db_user -p$db_password $db_name < db_backup.sql
#
###

################################
################################
################################
## Variablen
before=$(date +%s)

# folgende Variablen anpassen:

# Dateiname von Backup-Dateien, die angelegt werden (ohne Suffix)
projekt_basis_dateiname=website_backup

# Datenbank Zugangsdaten (es empfiehlt sich einen Nur-Lesezugriff-Datenbankbenutzer dafür zu verwenden)
db_password='myVerySecurePassword'
db_name='my_db_name'
db_user='my_db_user'
db_host='localhost'

# Website-Ordner (wo liegen die zu sichernden Dateien)
files_dir='/pfad/zum/website/root/'
files_dir_ignore='' # z.B. ('*/media/*' '*/other_dir_to_exlude/*') # files_dir_ignore=('*/media/*' '*/dmc2017g/*')


################################
################################
################################
## ab hier ist alles automatisch – es braucht nichts mehr angepasst werden
# Dateien
dateien_dateiname=$projekt_basis_dateiname'_'$(date +%Y-%m-%d_%H-%M-%S)'_'files
db_dateiname=$projekt_basis_dateiname'_'$(date +%Y-%m-%d_%H-%M-%S)'_'$db_name

# Dateiendungen
dateiendung_zip=.zip
db_dateiendung=.sql



################################
################################
################################
# Let the show begin...

## Leerzeile
clear
echo

echo "Sichern der Datenbank in Datei "$db_dateiname$dateiendung_zip" ..."
mysqldump --replace --skip-lock-tables -h$db_host -u$db_user -p$db_password $db_name > ./$db_dateiname$db_dateiendung
echo "erledigt."
echo

echo "Nachbearbeiten der Sicherung ..."
# DEFINER=`xyz` mit CURRENT_USER ersetzen
sed -ri 's/DEFINER=`[^`]+`@`[^`]+`/DEFINER=CURRENT_USER/g' $db_dateiname$db_dateiendung
echo "erledigt."
echo

# zip
echo "ZIP-Datei von Sicherung erstellen $dateiname_converted$dateiendung$dateiendung_zip ..."
zip $db_dateiname$db_dateiendung$dateiendung_zip $db_dateiname$db_dateiendung
echo "erledigt."
echo


# sql-datei löschen
echo "Unkomprimierte Datei löschen $dateiname$dateiendung ..."
rm $db_dateiname$db_dateiendung
echo "erledigt."
echo

# Dateien zippen 
echo "ZIP-Datei von Dateien im Website-Verzeichnis ("$files_dir") erstellen ..."
if [ "$files_dir_ignore" != "" ]
then
	echo " ausgeschlossene(r) Ordner: ${files_dir_ignore[@]}"
	zip -rq $dateien_dateiname$dateiendung_zip $files_dir -x ${files_dir_ignore[@]}
else
	zip -rq $dateien_dateiname$dateiendung_zip $files_dir
fi
echo "erledigt."
echo

## Dateien, die älter als 14 Tage sind löschen
#echo "ZIP-Dateien die älter als 14 Tage sind löschen ..."
#find *.zip -mtime +14 -type f -delete
#echo "erledigt."
#echo


## Vergangene Zeit
after=$(date +%s)
echo "Dauer des Backup-Vorgangs: " $((after - $before)) " Sekunden"
echo