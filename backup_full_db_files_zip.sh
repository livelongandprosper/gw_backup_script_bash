#!/bin/bash
basename=$(cd "$(dirname "$0")" && pwd)
set -o pipefail

before=$(date +%s)

###
# BackupScript zum Backup von Websites
# - Dateien einer Website
# - - optional können Dateien ausgeschlossen werden (files_dir_ignore)
# - Datenbank einer Website
# - Backup dateien können an entfernten Server via sftp oder rsync übertragen werden
#
# Dieses eine Skript kann für beliebig viele Projekte im selben Ordner verwendet werden.
# Jedes Projekt bekommt seine eigene Konfigurationsdatei nach dem Muster .env.<projektname>
# (z.B. .env.kundeA, .env.kundeB, ...). Eine alte einzelne .env-Datei (ohne Projektnamen)
# wird weiterhin als "default"-Projekt unterstützt.
#
# (c) Gregor Wendland 2017-2025 /// free to use, free to change, do what you want with this file, no warranty
###
#
# Wieder-einspielen der Datenbank (Beispiele):
# mysql -h'localhost' -p'myVerySecurePassword' -u'my_db_user' 'my_db_name' < db_backup.sql
# mysql -h$db_host -u$db_user -p$db_password $db_name < db_backup.sql
#
# Dateien müssen bei einer Wiederherstellung mit unzip entpackt werden.
#
###
#
# Aufruf-Beispiele:
#   ./backup_full_db_files_zip.sh
#       -> interaktiv: fragt Projekt (falls mehrere vorhanden) und Umfang (alles/db/dateien) ab
#   ./backup_full_db_files_zip.sh --project=kundeA
#       -> sichert nur das Projekt "kundeA" (existiert keine .env.kundeA, wird der Setup-Assistent dafür gestartet)
#   ./backup_full_db_files_zip.sh --project=alle --scope=db
#       -> sichert bei allen konfigurierten Projekten nur die Datenbank(en) (z.B. für Cronjobs)
#
###

################################
################################
################################
## CLI-Parameter einlesen (optional, für nicht-interaktive Aufrufe z.B. per Cron)

cli_project=''
cli_scope=''

for cli_arg in "$@"; do
    case "$cli_arg" in
        --project=*)
            cli_project="${cli_arg#*=}"
            ;;
        --scope=*)
            cli_scope="${cli_arg#*=}"
            ;;
        --help|-h)
            echo "Verwendung: $0 [--project=<name>|alle] [--scope=alles|db|dateien]"
            echo "  --project   Projekt-Konfiguration (.env.<name>), die verwendet werden soll. 'alle' verarbeitet alle gefundenen Projekte."
            echo "  --scope     Was gesichert werden soll: alles (Standard), db (nur Datenbank(en)) oder dateien (nur Website-Dateien)."
            echo "Ohne Parameter wird interaktiv nachgefragt, sofern nötig."
            exit 0
            ;;
        *)
            echo "Unbekannter Parameter '$cli_arg' wird ignoriert (siehe --help)." >&2
            ;;
    esac
done

# normalisiert Eingaben für den Umfang auf 'alles' / 'db' / 'dateien'
function normalize_scope() {
    case "$1" in
        alles|all|"")
            echo "alles"
            ;;
        db|datenbank|nurdb)
            echo "db"
            ;;
        dateien|files|nurdateien)
            echo "dateien"
            ;;
        *)
            echo ""
            ;;
    esac
}

if [ -n "$cli_scope" ]; then
    normalized_cli_scope="$(normalize_scope "$cli_scope")"
    if [ -z "$normalized_cli_scope" ]; then
        echo "Ungültiger --scope Wert '$cli_scope'. Erlaubt: alles, db, dateien" >&2
        exit 1
    fi
    cli_scope="$normalized_cli_scope"
fi

if [ "$cli_project" == "all" ]; then
    cli_project="alle"
fi

################################
################################
################################
## Setup-Assistent - fragt Zugangsdaten für ein (neues) Projekt ab und legt .env.<projektname> an
#  parameter1: Projektname (wird für den Dateinamen der .env-Datei verwendet)
function run_setup_assistant() {
    local project_name="$1"
    local target_env_file="$basename/.env.$project_name"

    echo "======================================"
    echo "Setup-Assistent für Projekt '$project_name'"
    echo "Die Angaben werden anschließend in $target_env_file gespeichert."
    echo "Enter ohne Eingabe übernimmt den vorgeschlagenen Standard bzw. lässt das Feld leer."
    echo "======================================"
    echo

    read -rp "Projekt-Basisdateiname für Backups [$project_name]: " input_projekt_basis_dateiname
    local projekt_basis_dateiname=${input_projekt_basis_dateiname:-$project_name}

    echo
    echo "--- Datenbanken (beliebig viele, Nur-Lesezugriff-Benutzer empfohlen) ---"
    echo "Datenbanknamen einfach leer lassen, um keine (weitere) Datenbank hinzuzufügen."
    local db_hosts=()
    local db_names=()
    local db_users=()
    local db_passwords=()
    local db_index=1
    while true; do
        echo
        read -rp "DB $db_index Name (leer = fertig): " current_db_name
        if [ "$current_db_name" == "" ]; then
            break
        fi
        read -rp "DB $db_index Host [localhost]: " current_db_host
        current_db_host=${current_db_host:-localhost}
        read -rp "DB $db_index User: " current_db_user
        read -rsp "DB $db_index Passwort: " current_db_password
        echo
        db_names+=("$current_db_name")
        db_hosts+=("$current_db_host")
        db_users+=("$current_db_user")
        db_passwords+=("$current_db_password")
        db_index=$((db_index + 1))
    done
    local db_count=${#db_names[@]}

    echo
    read -rp "Website-Ordner, der gesichert werden soll (absoluter Pfad): " source_files_dir
    read -rp "Auszuschließende Ordner-Muster, Leerzeichen-getrennt (z.B. '*/media/*' '*/cache/*'), optional: " source_files_dir_ignore

    echo
    echo "--- sftp-Übertragung (optional, leer lassen zum Überspringen) ---"
    read -rp "sftp Host: " sftp_host
    local sftp_port=''
    local sftp_user=''
    local sftp_key=''
    local sftp_directory=''
    if [ "$sftp_host" != "" ]; then
        read -rp "sftp Port [22]: " sftp_port
        sftp_port=${sftp_port:-22}
        read -rp "sftp User: " sftp_user
        read -rp "Pfad zum privaten SSH-Key [$HOME/.ssh/id_rsa_backup]: " sftp_key
        sftp_key=${sftp_key:-$HOME/.ssh/id_rsa_backup}
        read -rp "sftp Zielverzeichnis (optional): " sftp_directory
    fi

    echo
    echo "--- rsync-Übertragung (optional, leer lassen zum Überspringen) ---"
    read -rp "rsync Host: " rsync_host
    local rsync_user=''
    local rsync_directory=''
    local rsync_key=''
    if [ "$rsync_host" != "" ]; then
        read -rp "rsync User: " rsync_user
        read -rp "rsync Zielverzeichnis (relativ zum rsync-User-Homeverzeichnis): " rsync_directory
        read -rp "Pfad zum privaten SSH-Key [$HOME/.ssh/id_rsa_backup]: " rsync_key
        rsync_key=${rsync_key:-$HOME/.ssh/id_rsa_backup}
    fi

    echo
    read -rp "Backup-Lebenszeit in Tagen (0 = unendlich) [0]: " backup_live_time
    backup_live_time=${backup_live_time:-0}
    read -rp "Lokale Backup-Dateien nach erfolgreicher Übertragung löschen? (true/false) [false]: " delete_if_transmitted
    delete_if_transmitted=${delete_if_transmitted:-false}

    echo
    read -rp "Was soll standardmäßig gesichert werden - alles/db/dateien [alles]: " input_default_scope
    local default_scope
    default_scope="$(normalize_scope "${input_default_scope:-alles}")"
    if [ -z "$default_scope" ]; then
        default_scope="alles"
    fi

    local ssh_binary_path
    ssh_binary_path="$(command -v ssh || echo /usr/bin/ssh)"

    cat > "$target_env_file" <<EOF
# Zugangsdaten & Konfiguration für Projekt '$project_name'
# automatisch erstellt am $(date) durch den Setup-Assistenten
# Diese Datei enthält Zugangsdaten und sollte NICHT ins Git-Repository eingecheckt werden (siehe .gitignore).

PROJECT_NAME='$project_name'
PROJEKT_BASIS_DATEINAME='$projekt_basis_dateiname'

# Was soll standardmäßig gesichert werden, wenn nicht per --scope angegeben: alles / db / dateien
DEFAULT_SCOPE='$default_scope'

DB_COUNT='$db_count'
EOF

    local db_write_i
    for ((db_write_i=0; db_write_i<db_count; db_write_i++)); do
        local db_write_idx=$((db_write_i + 1))
        cat >> "$target_env_file" <<EOF
DB_${db_write_idx}_HOST='${db_hosts[$db_write_i]}'
DB_${db_write_idx}_NAME='${db_names[$db_write_i]}'
DB_${db_write_idx}_USER='${db_users[$db_write_i]}'
DB_${db_write_idx}_PASSWORD='${db_passwords[$db_write_i]}'
EOF
    done

    cat >> "$target_env_file" <<EOF

SOURCE_FILES_DIR='$source_files_dir'
SOURCE_FILES_DIR_IGNORE='$source_files_dir_ignore'

SFTP_HOST='$sftp_host'
SFTP_PORT='$sftp_port'
SFTP_KEY='$sftp_key'
SFTP_USER='$sftp_user'
SFTP_DIRECTORY='$sftp_directory'
SFTP_PATH_TO_SSH_BINARY='$ssh_binary_path'

RSYNC_HOST='$rsync_host'
RSYNC_USER='$rsync_user'
RSYNC_DIRECTORY='$rsync_directory'
RSYNC_KEY='$rsync_key'

BACKUP_LIVE_TIME='$backup_live_time'
DELETE_IF_TRANSMITTED='$delete_if_transmitted'

# E-Mail-Benachrichtigung (aktuell noch nicht implementiert)
STATUS_EMAIL_ADDRESS=''
ALERT_EMAIL_ADDRESS=''
EOF

    chmod 600 "$target_env_file"

    echo
    echo "======================================"
    echo ".env-Datei wurde unter $target_env_file angelegt (Zugriffsrechte auf 600 gesetzt)."
    echo "Zugangsdaten können dort jederzeit angepasst werden."
    echo "======================================"
    echo
}

################################
################################
################################
## Projekt-Konfigurationsdateien ermitteln

shopt -s nullglob
discovered_env_files=("$basename"/.env.*)
shopt -u nullglob

env_files=()
for candidate_env_file in "${discovered_env_files[@]}"; do
    if [ "$(basename "$candidate_env_file")" != ".env.example" ]; then
        env_files+=("$candidate_env_file")
    fi
done

# Abwärtskompatibilität: eine einzelne alte .env-Datei (ohne Projektnamen) wird als "default"-Projekt behandelt
legacy_env_file="$basename/.env"
if [ -f "$legacy_env_file" ]; then
    env_files+=("$legacy_env_file")
fi

# Hilfsfunktion: liest den Projektnamen aus einer .env-Datei-Pfadangabe ab
function project_name_from_env_file() {
    local file="$1"
    if [ "$file" == "$legacy_env_file" ]; then
        echo "default"
    else
        local file_basename
        file_basename="$(basename "$file")"
        echo "${file_basename#.env.}"
    fi
}

# Kein Projekt vorhanden -> Setup-Assistent für ein neues Projekt starten
if [ "${#env_files[@]}" -eq 0 ]; then
    echo "======================================"
    echo "Keine Projekt-Konfiguration (.env.<projektname>) gefunden - Setup-Assistent wird gestartet ..."
    echo "======================================"
    echo
    if [ -n "$cli_project" ] && [ "$cli_project" != "alle" ]; then
        new_project_name="$cli_project"
    else
        read -rp "Name für das neue Projekt (wird für Dateinamen verwendet, z.B. 'kundeA'): " new_project_name
        new_project_name=${new_project_name// /_}
        new_project_name=${new_project_name:-projekt1}
    fi
    run_setup_assistant "$new_project_name"
    env_files=("$basename/.env.$new_project_name")
fi

# Projekt(e) auswählen, die in diesem Lauf verarbeitet werden sollen
selected_env_files=()
if [ "$cli_project" == "alle" ]; then
    selected_env_files=("${env_files[@]}")
elif [ -n "$cli_project" ]; then
    match_env_file="$basename/.env.$cli_project"
    if [ "$cli_project" == "default" ] && [ -f "$legacy_env_file" ]; then
        selected_env_files=("$legacy_env_file")
    elif [ -f "$match_env_file" ]; then
        selected_env_files=("$match_env_file")
    else
        echo "Kein Projekt '$cli_project' gefunden - Setup-Assistent dafür wird gestartet ..."
        run_setup_assistant "$cli_project"
        selected_env_files=("$match_env_file")
    fi
elif [ "${#env_files[@]}" -eq 1 ]; then
    selected_env_files=("${env_files[@]}")
else
    echo "======================================"
    echo "Mehrere Projekte gefunden:"
    project_index=1
    for existing_env_file in "${env_files[@]}"; do
        echo "  $project_index) $(project_name_from_env_file "$existing_env_file")"
        project_index=$((project_index + 1))
    done
    echo "  a) alle Projekte"
    echo "======================================"
    read -rp "Projekt auswählen (Nummer oder 'a' für alle): " project_choice
    if [ "$project_choice" == "a" ]; then
        selected_env_files=("${env_files[@]}")
    else
        selected_index=$((project_choice - 1))
        selected_env_files=("${env_files[$selected_index]}")
    fi
fi

################################
################################
################################
## Funktionen für den eigentlichen Backup-Ablauf

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
    local db_dateiname="$backup_destiantion$projekt_basis_dateiname"'_'"$(date +%Y-%m-%d_%H-%M-%S)"'_'"$db_name"

    # Datenbanken sichern
    if [ "$db_name" != "" ]
    then
        echo "Sichern der Datenbank in Datei $db_dateiname$db_dateiendung ..." | tee -a "$log_file_name"
        MYSQL_PWD="$db_password" mysqldump --single-transaction --replace --skip-lock-tables -h"$db_host" -u"$db_user" "$db_name" > "$db_dateiname$db_dateiendung"
        echo "erledigt." | tee -a "$log_file_name"
        echo

        echo "Nachbearbeiten der Sicherung von $db_dateiname$db_dateiendung ..." | tee -a "$log_file_name"
        # DEFINER=`xyz` mit CURRENT_USER ersetzen
        sed -ri 's/DEFINER=`[^`]+`@`[^`]+`/DEFINER=CURRENT_USER/g' "$db_dateiname$db_dateiendung" | tee -a "$log_file_name"
        echo "erledigt." | tee -a "$log_file_name"
        echo | tee -a "$log_file_name"

        # zip
        if ! [ -x "$(command -v zip)" ]; then
            echo 'Error: zip is not installed.' | tee -a "$log_file_name" >&2
            echo 'sql file is not compressed' | tee -a "$log_file_name"
        else
            echo "ZIP-Datei von Sicherung erstellen $db_dateiname$db_dateiendung$dateiendung_zip ..." | tee -a "$log_file_name"
            zip "$db_dateiname$db_dateiendung$dateiendung_zip" "$db_dateiname$db_dateiendung" | tee -a "$log_file_name"
            if [ "${PIPESTATUS[0]}" -eq "0" ]
            then
                # sql-datei löschen
                echo "Unkomprimierte Datei löschen $db_dateiname$db_dateiendung ..." | tee -a "$log_file_name"
                rm -v "$db_dateiname$db_dateiendung" | tee -a "$log_file_name"
                echo | tee -a "$log_file_name"
            else
                echo "Zip-Datei konnte nicht erstellt werden. $db_dateiname$db_dateiendung bleibt erhalten." | tee -a "$log_file_name"
            fi
            echo | tee -a "$log_file_name"
        fi
    fi

    return ${return_value}
}

# Führt den kompletten Backup-Ablauf für ein Projekt (eine .env-Datei) aus
#  parameter1: Pfad zur .env-Datei des Projekts
function run_backup_for_project() {
    local project_env_file="$1"
    local project_name
    project_name="$(project_name_from_env_file "$project_env_file")"

    # .env laden
    # shellcheck source=/dev/null
    source "$project_env_file"

    # Zuordnung auf die im Skript verwendeten Variablennamen
    projekt_basis_dateiname="${PROJEKT_BASIS_DATEINAME:-$project_name}"

    # Umfang für diesen Lauf bestimmen: CLI-Parameter > gespeicherter Standard > interaktive Abfrage > alles
    local run_scope="$cli_scope"
    if [ -z "$run_scope" ] && [ -n "$DEFAULT_SCOPE" ]; then
        run_scope="$(normalize_scope "$DEFAULT_SCOPE")"
    fi
    if [ -z "$run_scope" ]; then
        if [ -t 0 ]; then
            read -rp "[$project_name] Was soll gesichert werden - alles/db/dateien [alles]: " input_run_scope
            run_scope="$(normalize_scope "${input_run_scope:-alles}")"
        else
            run_scope="alles"
        fi
    fi
    if [ -z "$run_scope" ]; then
        run_scope="alles"
    fi

    # Datenbanken einlesen (beliebig viele über DB_COUNT / DB_<n>_* oder altes DB_*/DB2_*-Format)
    db_hosts=()
    db_names=()
    db_users=()
    db_passwords=()
    if [ -n "$DB_COUNT" ]; then
        for ((db_read_i=1; db_read_i<=DB_COUNT; db_read_i++)); do
            host_var="DB_${db_read_i}_HOST"
            name_var="DB_${db_read_i}_NAME"
            user_var="DB_${db_read_i}_USER"
            password_var="DB_${db_read_i}_PASSWORD"
            db_hosts+=("${!host_var}")
            db_names+=("${!name_var}")
            db_users+=("${!user_var}")
            db_passwords+=("${!password_var}")
        done
    else
        # Abwärtskompatibilität zu älteren .env-Dateien mit DB_*/DB2_*
        if [ -n "$DB_NAME" ]; then
            db_hosts+=("${DB_HOST:-localhost}")
            db_names+=("$DB_NAME")
            db_users+=("$DB_USER")
            db_passwords+=("$DB_PASSWORD")
        fi
        if [ -n "$DB2_NAME" ]; then
            db_hosts+=("${DB2_HOST:-localhost}")
            db_names+=("$DB2_NAME")
            db_users+=("$DB2_USER")
            db_passwords+=("$DB2_PASSWORD")
        fi
    fi

    source_files_dir="$SOURCE_FILES_DIR"
    read -ra source_files_dir_ignore <<< "$SOURCE_FILES_DIR_IGNORE"

    sftp_host="$SFTP_HOST"
    sftp_port="${SFTP_PORT:-22}"
    sftp_key="$SFTP_KEY"
    sftp_user="$SFTP_USER"
    sftp_directory="$SFTP_DIRECTORY"
    sftp_batchfile="$projekt_basis_dateiname"'_sftp_upload_batchfile'
    sftp_path_to_ssh_binary="${SFTP_PATH_TO_SSH_BINARY:-$(command -v ssh)}"

    rysnc_host="$RSYNC_HOST"
    rsync_user="$RSYNC_USER"
    rsync_directory="$RSYNC_DIRECTORY"
    rsync_key="$RSYNC_KEY"

    backup_live_time="${BACKUP_LIVE_TIME:-0}"
    delete_if_transmitted="${DELETE_IF_TRANSMITTED:-false}"

    status_email_address="$STATUS_EMAIL_ADDRESS"
    alert_email_address="$ALERT_EMAIL_ADDRESS"

    # Backup Zielordner
    backup_destiantion="$basename/$projekt_basis_dateiname/"
    mkdir -p "$backup_destiantion"
    mkdir -p "$basename/log/"

    # Dateien
    dateien_dateiname="$backup_destiantion$projekt_basis_dateiname"'_'"$(date +%Y-%m-%d_%H-%M-%S)"'_'files
    log_file_name="$basename/log/$projekt_basis_dateiname"'_'"$(date +%Y-%m-%d_%H-%M-%S)"'.log'

    # Dateiendungen
    dateiendung_zip='.zip'
    db_dateiendung='.sql'

    # Kontrollvariablen
    transmitted=''

    # .htaccess generieren, falls noch nicht vorhanden
    htaccess_file="$backup_destiantion.htaccess"
    if [ ! -f "$htaccess_file" ]; then
        echo "deny from all" > "$htaccess_file"
        echo ".htaccess-Datei wurde erstellt, um den Zugriff zu verweigern." | tee -a "$log_file_name"
    else
        echo ".htaccess-Datei existiert" | tee -a "$log_file_name"
    fi

    ################################
    ################################
    ################################
    # Let the show begin...

    echo "======================================" | tee -a "$log_file_name"
    echo "Backup Projekt: $project_name ($projekt_basis_dateiname) | Umfang: $run_scope" | tee -a "$log_file_name"
    echo "$(date)" | tee -a "$log_file_name"
    echo "Script is located"
    echo "$basename"
    echo "======================================" | tee -a "$log_file_name"
    echo "backup files will be saved here $backup_destiantion" | tee -a "$log_file_name"
    echo "======================================" | tee -a "$log_file_name"
    echo | tee -a "$log_file_name"
    echo

    # Datenbanken sichern (beliebig viele), nur wenn Umfang alles oder db
    if [ "$run_scope" == "alles" ] || [ "$run_scope" == "db" ]; then
        for ((db_backup_i=0; db_backup_i<${#db_names[@]}; db_backup_i++))
        do
            backup_db "${db_hosts[$db_backup_i]}" "${db_names[$db_backup_i]}" "${db_users[$db_backup_i]}" "${db_passwords[$db_backup_i]}"
        done
    else
        echo "Umfang '$run_scope' - Datenbank-Sicherung wird übersprungen." | tee -a "$log_file_name"
        echo | tee -a "$log_file_name"
    fi

    # Dateien zippen, nur wenn Umfang alles oder dateien
    if [ "$run_scope" == "alles" ] || [ "$run_scope" == "dateien" ]; then
        if [ "$source_files_dir" != "" ]
        then
            if ! [ -x "$(command -v zip)" ]; then
                echo 'Error: zip is not installed.' | tee -a "$log_file_name" >&2
                echo 'files could not be packed into zip file' | tee -a "$log_file_name"
            else
                echo "ZIP-Datei von Dateien im Website-Verzeichnis ($source_files_dir) erstellen ..." | tee -a "$log_file_name"
                if [ "${#source_files_dir_ignore[@]}" -gt "0" ] && [ "${source_files_dir_ignore[0]}" != "" ]
                then
                    echo " ausgeschlossene(r) Ordner: ${source_files_dir_ignore[*]}" | tee -a "$log_file_name"
                    zip -rq "$dateien_dateiname$dateiendung_zip" "$source_files_dir" -x "${source_files_dir_ignore[@]}" | tee -a "$log_file_name"
                else
                    zip -rq "$dateien_dateiname$dateiendung_zip" "$source_files_dir" | tee -a "$log_file_name"
                fi
                echo "erledigt."
                echo
            fi
        fi
    else
        echo "Umfang '$run_scope' - Datei-Sicherung wird übersprungen." | tee -a "$log_file_name"
        echo | tee -a "$log_file_name"
    fi

    # Dateien per rsync synchronisieren (rsync)
    if [ "$rysnc_host" != "" ]
    then
        echo "Dateien zu entferntem Server synchronisieren (rsync)..." | tee -a "$log_file_name"
        echo " lokaler Ordner: $backup_destiantion" | tee -a "$log_file_name"
        echo " entfernter Ordner: $rsync_directory" | tee -a "$log_file_name"
        if [ "$rsync_key" != "" ]
        then
            rsync -rltDvzre "ssh -i $rsync_key" --progress "$backup_destiantion" "$rsync_user@$rysnc_host:$rsync_directory" | tee -a "$log_file_name"
        else
            rsync -rltDvzre "ssh" --progress "$backup_destiantion" "$rsync_user@$rysnc_host:$rsync_directory" | tee -a "$log_file_name"
        fi

        # Wurden die Daten übertragen?
        if [ "${PIPESTATUS[0]}" -eq "0" ]
        then
          transmitted='true'
        else
          transmitted=''
          echo "Error while running rsync" | tee -a "$log_file_name"
        fi
    fi
    echo | tee -a "$log_file_name"

    # Dateien per sftp kopieren sftp
    if [ "$sftp_host" != "" ]
    then
        echo "Dateien auf entfernten Server kopieren (sftp)..." | tee -a "$log_file_name"
        # batchfile für sftp erstellen
        if [ "$sftp_directory" != "" ]
        then
            echo "cd $sftp_directory" >> "$sftp_batchfile"
        fi

        for i in $(ls -x -1 "$backup_destiantion")
        do
            echo "put $backup_destiantion/$i" >> "$sftp_batchfile"
        done
        echo "exit" >> "$sftp_batchfile"

        # hier ist der eigentliche upload auf den backup-server
        sftp -S "$sftp_path_to_ssh_binary" -b "$sftp_batchfile" -o PubkeyAuthentication=yes -o IdentityFile="$sftp_key" -o Port="$sftp_port" "$sftp_user@$sftp_host" | tee -a "$log_file_name"

        # Wurden die Daten übertragen?
        if [ "${PIPESTATUS[0]}" -eq "0" ]
        then
          transmitted='true'
        else
          transmitted=''
          echo "Error while running sftp" | tee -a "$log_file_name"
        fi

        # Dokumenation in logfile
        echo "logfile content:" >> "$log_file_name"
        echo "-----" >> "$log_file_name"
        cat "$sftp_batchfile" >> "$log_file_name"
        echo "-----" >> "$log_file_name"

        # batch file löschen
        rm -v "$sftp_batchfile" | tee -a "$log_file_name"
        echo | tee -a "$log_file_name"
    fi

    # Dateien löschen, wenn erfolgreich übermittelt wurde
    if [ \( "$delete_if_transmitted" == "true" \) -a \( "$transmitted" == "true" \) ]
    then
        echo "Dateien in $backup_destiantion werden nach erfolgreicher Übertragung gelöscht ..." | tee -a "$log_file_name"
        rm -v "$backup_destiantion"* | tee -a "$log_file_name"
        echo "erledigt." | tee -a "$log_file_name"
        echo | tee -a "$log_file_name"
        echo
    fi

    # Dateien, die älter als $backup_live_time Tage sind löschen
    if [ \( "$backup_destiantion" != "" \) -a \( "$backup_live_time" != "0" \) ]
    then
        echo "Dateien in $backup_destiantion älter als $backup_live_time Tage löschen ..." | tee -a "$log_file_name"
        find "$backup_destiantion" -mtime +"$backup_live_time" -type f ! -regex '.*\.sh' -delete -print | tee -a "$log_file_name"
        echo "erledigt." | tee -a "$log_file_name"
        echo | tee -a "$log_file_name"
    fi

    echo | tee -a "$log_file_name"
}

################################
################################
################################
## Ausgewählte Projekte nacheinander sichern

for selected_env_file in "${selected_env_files[@]}"; do
    run_backup_for_project "$selected_env_file"
done

## Vergangene Zeit
after=$(date +%s)
echo "Dauer des gesamten Backup-Vorgangs: " $((after - before)) " Sekunden"
echo
