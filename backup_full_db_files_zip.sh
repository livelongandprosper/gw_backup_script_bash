#!/bin/bash
basename=$(cd "$(dirname "$0")" && pwd)
set -o pipefail
umask 077

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
# Wieder-einspielen der Datenbank:
# ./backup_full_db_files_zip.sh --restore [--project=<name>]
# (fragt interaktiv nach Datenbank und Backup-Datei, entpackt .zip-Backups automatisch)
#
# Dateien müssen bei einer Wiederherstellung mit unzip entpackt werden.
#
###
#
# Aufruf-Beispiele:
#   ./backup_full_db_files_zip.sh
#       -> interaktiv: zeigt ein Hauptmenü an (Projekt sichern, alle sichern, neues Projekt
#          einrichten, Datenbank wiederherstellen, Datengröße/Übersicht anzeigen, Beenden)
#   ./backup_full_db_files_zip.sh --project=kundeA
#       -> sichert nur das Projekt "kundeA" ohne Menü (existiert keine .env.kundeA, wird der Setup-Assistent dafür gestartet)
#   ./backup_full_db_files_zip.sh --project=alle --scope=db
#       -> sichert bei allen konfigurierten Projekten nur die Datenbank(en) (z.B. für Cronjobs)
#   ./backup_full_db_files_zip.sh --restore --project=kundeA
#       -> stellt interaktiv eine Datenbank des Projekts "kundeA" aus einem vorhandenen Backup wieder her
#
# Wird das Skript ohne jegliche Parameter in einem Terminal aufgerufen, erscheint immer
# das interaktive Hauptmenü. Werden Parameter übergeben (z.B. --project/--scope/--restore),
# wird das Menü übersprungen und direkt wie angegeben verfahren - das hält Cronjobs unangetastet.
#
###

################################
################################
################################
## CLI-Parameter einlesen (optional, für nicht-interaktive Aufrufe z.B. per Cron)

cli_project=''
cli_scope=''
restore_mode='false'

for cli_arg in "$@"; do
    case "$cli_arg" in
        --project=*)
            cli_project="${cli_arg#*=}"
            ;;
        --scope=*)
            cli_scope="${cli_arg#*=}"
            ;;
        --restore)
            restore_mode='true'
            ;;
        --help|-h)
            echo "Verwendung: $0 [--project=<name>|alle] [--scope=alles|db|dateien] [--restore]"
            echo "  --project   Projekt-Konfiguration (.env.<name>), die verwendet werden soll. 'alle' verarbeitet alle gefundenen Projekte."
            echo "  --scope     Was gesichert werden soll: alles (Standard), db (nur Datenbank(en)) oder dateien (nur Website-Dateien)."
            echo "  --restore   Datenbank aus einem vorhandenen Backup wiederherstellen (interaktiv), statt ein Backup zu erstellen."
            echo "Ohne Parameter wird im Terminal das interaktive Hauptmenü angezeigt."
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

# Erstellt/aktualisiert Apache-Schutzregeln (.htaccess) für Verzeichnisse (Webroot-Sicherheit für Apache 2.4 & 2.2)
function ensure_webroot_protection() {
    local target_dir="$1"
    local mode="${2:-deny_all}" # 'deny_all' für Backup-/Log-Ordner, 'sensitive_only' für Skript-Wurzelordner
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

# Prüft den freien Festplattenspeicher und warnt bei Knappheit (< 500 MB)
function check_disk_space() {
    local target_dir="$1"
    local log_target="${2:-/dev/null}"
    if command -v df >/dev/null 2>&1; then
        local available_kb
        available_kb=$(df -Pk "$target_dir" 2>/dev/null | awk 'NR==2 {print $4}')
        if [ -n "$available_kb" ] && [ "$available_kb" -eq "$available_kb" ] 2>/dev/null; then
            if [ "$available_kb" -lt 512000 ]; then
                local avail_mb=$((available_kb / 1024))
                echo "WARNUNG: Geringer freier Speicherplatz auf dem Ziellaufwerk ($avail_mb MB verbleibend)!" | tee -a "$log_target" >&2
            fi
        fi
    fi
}

# Basisverzeichnisse für Webroot-Betrieb absichern
ensure_webroot_protection "$basename" "sensitive_only"
ensure_webroot_protection "$basename/log" "deny_all"

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
    if [ -n "$source_files_dir" ] && [ -d "$source_files_dir" ]; then
        read -rp "Größe dieses Ordners anzeigen? Kann bei großen Ordnern etwas dauern (j/N): " show_folder_size
        if [[ "$show_folder_size" =~ ^[jJyY]$ ]]; then
            echo "Ermittle Ordnergröße ..."
            du -sh "$source_files_dir" 2>/dev/null
        fi
    fi
    echo
    echo "--- Auszuschließende Ordner/Dateien (optional) ---"
    echo "Jedes Muster einzeln eingeben (z.B. */cache/* oder */backups/*)."
    echo "OHNE Anführungszeichen eintippen - jede Zeile ist ein Muster."
    echo "Leer lassen und Enter drücken, um die Eingabe zu beenden."
    local source_files_dir_ignore_patterns=()
    local ignore_index=1
    while true; do
        read -rp "Auszuschließendes Muster $ignore_index (leer = fertig): " current_ignore_pattern
        if [ -z "$current_ignore_pattern" ]; then
            break
        fi
        source_files_dir_ignore_patterns+=("$current_ignore_pattern")
        ignore_index=$((ignore_index + 1))
    done

    # Muster als sicher gequotetes Bash-Array-Literal aufbereiten, damit sie beim
    # erneuten Einlesen (source) unverändert und vollständig erhalten bleiben.
    local source_files_dir_ignore_literal=''
    local single_ignore_pattern
    for single_ignore_pattern in "${source_files_dir_ignore_patterns[@]}"; do
        # jedes einzelne Anführungszeichen im Muster sicher escapen ('  ->  '\'')
        local escaped_ignore_pattern=${single_ignore_pattern//\'/\'\\\'\'}
        source_files_dir_ignore_literal+=" '$escaped_ignore_pattern'"
    done
    # führendes Leerzeichen entfernen
    source_files_dir_ignore_literal="${source_files_dir_ignore_literal# }"

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
# Auszuschließende Muster als Bash-Array - je Element ein Muster.
# Beispiel: SOURCE_FILES_DIR_IGNORE=('*/cache/*' '*/backups/*')
SOURCE_FILES_DIR_IGNORE=($source_files_dir_ignore_literal)

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

# Datenbank aus einem vorhandenen Backup wiederherstellen
#  parameter1: Pfad zur .env-Datei des Projekts
function run_restore_for_project() {
    local project_env_file="$1"
    local project_name
    project_name="$(project_name_from_env_file "$project_env_file")"

    # shellcheck source=/dev/null
    source "$project_env_file"

    local projekt_basis_dateiname="${PROJEKT_BASIS_DATEINAME:-$project_name}"
    local backup_destiantion="$basename/$projekt_basis_dateiname/"

    # Datenbanken einlesen (gleiche Logik wie beim Backup)
    local db_hosts=()
    local db_names=()
    local db_users=()
    local db_passwords=()
    if [ -n "$DB_COUNT" ]; then
        local db_read_i
        for ((db_read_i=1; db_read_i<=DB_COUNT; db_read_i++)); do
            local host_var="DB_${db_read_i}_HOST"
            local name_var="DB_${db_read_i}_NAME"
            local user_var="DB_${db_read_i}_USER"
            local password_var="DB_${db_read_i}_PASSWORD"
            db_hosts+=("${!host_var}")
            db_names+=("${!name_var}")
            db_users+=("${!user_var}")
            db_passwords+=("${!password_var}")
        done
    else
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

    if [ "${#db_names[@]}" -eq 0 ]; then
        echo "Für Projekt '$project_name' ist keine Datenbank konfiguriert." >&2
        return 1
    fi

    echo "======================================"
    echo "Datenbank-Wiederherstellung für Projekt '$project_name'"
    echo "======================================"

    local restore_db_index=0
    if [ "${#db_names[@]}" -gt 1 ]; then
        echo "Welche Datenbank soll wiederhergestellt werden?"
        local i
        for ((i=0; i<${#db_names[@]}; i++)); do
            echo "  $((i + 1))) ${db_names[$i]} (Host: ${db_hosts[$i]})"
        done
        read -rp "Datenbank auswählen (Nummer): " db_choice
        restore_db_index=$((db_choice - 1))
    fi

    local restore_db_host="${db_hosts[$restore_db_index]}"
    local restore_db_name="${db_names[$restore_db_index]}"
    local restore_db_user="${db_users[$restore_db_index]}"
    local restore_db_password="${db_passwords[$restore_db_index]}"

    if [ -z "$restore_db_name" ]; then
        echo "Ungültige Auswahl." >&2
        return 1
    fi

    echo
    echo "Verfügbare Backup-Dateien für '$restore_db_name' in $backup_destiantion:"
    shopt -s nullglob
    local available_backups=("$backup_destiantion"*"_${restore_db_name}.sql" "$backup_destiantion"*"_${restore_db_name}.sql.zip")
    shopt -u nullglob

    local backup_file_to_restore=''
    if [ "${#available_backups[@]}" -gt 0 ]; then
        local avail_i
        for ((avail_i=0; avail_i<${#available_backups[@]}; avail_i++)); do
            echo "  $((avail_i + 1))) $(basename "${available_backups[$avail_i]}")"
        done
        echo "  m) manuell Pfad angeben"
        read -rp "Backup-Datei auswählen (Nummer oder 'm'): " backup_choice
        if [ "$backup_choice" == "m" ]; then
            read -rp "Pfad zur Backup-Datei (.sql oder .zip): " backup_file_to_restore
        else
            backup_file_to_restore="${available_backups[$((backup_choice - 1))]}"
        fi
    else
        echo "  (keine automatisch gefundenen Backups)"
        read -rp "Pfad zur Backup-Datei (.sql oder .zip): " backup_file_to_restore
    fi

    if [ ! -f "$backup_file_to_restore" ]; then
        echo "Datei '$backup_file_to_restore' nicht gefunden." >&2
        return 1
    fi

    local sql_file_to_import="$backup_file_to_restore"
    local temp_extract_dir=''
    if [[ "$backup_file_to_restore" == *.zip ]]; then
        if ! [ -x "$(command -v unzip)" ]; then
            echo "Error: unzip ist nicht installiert." >&2
            return 1
        fi
        temp_extract_dir="$(mktemp -d)"
        unzip -q "$backup_file_to_restore" -d "$temp_extract_dir"
        sql_file_to_import="$(find "$temp_extract_dir" -name '*.sql' -type f | head -n 1)"
        if [ -z "$sql_file_to_import" ]; then
            echo "Keine .sql-Datei im Zip-Archiv gefunden." >&2
            rm -rf "$temp_extract_dir"
            return 1
        fi
    fi

    echo
    echo "ACHTUNG: Die Datenbank '$restore_db_name' auf Host '$restore_db_host' wird mit dem Inhalt von"
    echo "  $sql_file_to_import"
    echo "überschrieben. Bestehende Daten in dieser Datenbank können dabei verloren gehen!"
    read -rp "Fortfahren? (ja/NEIN): " restore_confirm
    if [ "$restore_confirm" != "ja" ]; then
        echo "Abgebrochen."
        [ -n "$temp_extract_dir" ] && rm -rf "$temp_extract_dir"
        return 1
    fi

    echo "Importiere $sql_file_to_import in Datenbank $restore_db_name ..."
    MYSQL_PWD="$restore_db_password" mysql -h"$restore_db_host" -u"$restore_db_user" "$restore_db_name" < "$sql_file_to_import"
    local restore_result=$?

    [ -n "$temp_extract_dir" ] && rm -rf "$temp_extract_dir"

    if [ "$restore_result" -eq 0 ]; then
        echo "Datenbank '$restore_db_name' wurde erfolgreich wiederhergestellt."
    else
        echo "Fehler beim Wiederherstellen der Datenbank '$restore_db_name'." >&2
    fi

    return $restore_result
}

# Zeigt eine Übersicht aller konfigurierten Projekte (Datenbanken, Website-Ordner, Standard-Umfang, letztes Backup)
function show_project_overview() {
    echo "======================================"
    echo "Projektübersicht"
    echo "======================================"
    local overview_env_file
    for overview_env_file in "${env_files[@]}"; do
        local overview_project_name
        overview_project_name="$(project_name_from_env_file "$overview_env_file")"

        # shellcheck source=/dev/null
        source "$overview_env_file"

        local overview_db_count="${DB_COUNT:-0}"
        if [ "$overview_db_count" -eq 0 ] 2>/dev/null; then
            [ -n "$DB_NAME" ] && overview_db_count=$((overview_db_count + 1))
            [ -n "$DB2_NAME" ] && overview_db_count=$((overview_db_count + 1))
        fi

        local overview_basis="${PROJEKT_BASIS_DATEINAME:-$overview_project_name}"
        local overview_backup_dir="$basename/$overview_basis/"
        local overview_last_backup='keine Backups vorhanden'
        if [ -d "$overview_backup_dir" ]; then
            local overview_latest_file
            overview_latest_file="$(ls -t "$overview_backup_dir" 2>/dev/null | grep -v '.htaccess' | head -n 1)"
            [ -n "$overview_latest_file" ] && overview_last_backup="$overview_latest_file"
        fi

        echo
        echo "Projekt: $overview_project_name"
        echo "  Datenbanken: $overview_db_count"
        echo "  Website-Ordner: ${SOURCE_FILES_DIR:-(nicht konfiguriert)}"
        echo "  Standard-Umfang: ${DEFAULT_SCOPE:-alles}"
        echo "  Letztes Backup: $overview_last_backup"
    done
    echo
    echo "======================================"
    echo
}

# Zeigt die Größe des Website-Ordners sowie der bisherigen Backups eines Projekts an
function show_project_data_size() {
    local size_env_file
    if [ "${#env_files[@]}" -eq 1 ]; then
        size_env_file="${env_files[0]}"
    else
        echo "======================================"
        echo "Für welches Projekt soll die Datengröße angezeigt werden?"
        local size_index=1
        local existing_env_file
        for existing_env_file in "${env_files[@]}"; do
            echo "  $size_index) $(project_name_from_env_file "$existing_env_file")"
            size_index=$((size_index + 1))
        done
        echo "======================================"
        read -rp "Projekt auswählen (Nummer): " size_choice
        size_env_file="${env_files[$((size_choice - 1))]}"
    fi

    if [ -z "$size_env_file" ]; then
        echo "Ungültige Auswahl." >&2
        return 1
    fi

    local size_project_name
    size_project_name="$(project_name_from_env_file "$size_env_file")"

    # shellcheck source=/dev/null
    source "$size_env_file"

    echo
    echo "======================================"
    echo "Datengröße für Projekt '$size_project_name'"
    echo "======================================"
    if [ -n "$SOURCE_FILES_DIR" ] && [ -d "$SOURCE_FILES_DIR" ]; then
        echo "Website-Ordner ($SOURCE_FILES_DIR):"
        du -sh "$SOURCE_FILES_DIR" 2>/dev/null
    else
        echo "Website-Ordner ist nicht konfiguriert oder existiert nicht."
    fi

    local size_basis="${PROJEKT_BASIS_DATEINAME:-$size_project_name}"
    local size_backup_dir="$basename/$size_basis/"
    if [ -d "$size_backup_dir" ]; then
        echo "Bisherige Backups ($size_backup_dir):"
        du -sh "$size_backup_dir" 2>/dev/null
    fi
    echo "======================================"
    echo
}

# Fragt interaktiv ab, was gesichert werden soll (Standard/db/dateien/alles) und setzt cli_scope entsprechend.
# Wird vom Hauptmenü vor dem eigentlichen Backup aufgerufen, damit der Umfang bei jedem
# manuellen Lauf bewusst gewählt werden kann, statt stillschweigend den gespeicherten
# DEFAULT_SCOPE aus der .env-Datei zu verwenden.
function prompt_scope_choice() {
    echo
    echo "Was soll gesichert werden?"
    echo "  1) Standard (wie im Projekt konfiguriert)"
    echo "  2) Nur Datenbank(en)"
    echo "  3) Nur Dateien"
    echo "  4) Alles (Datenbank(en) + Dateien)"
    read -rp "Auswahl [1]: " scope_menu_choice
    case "$scope_menu_choice" in
        2)
            cli_scope="db"
            ;;
        3)
            cli_scope="dateien"
            ;;
        4)
            cli_scope="alles"
            ;;
        *)
            # leer = Standard: verwendet den gespeicherten DEFAULT_SCOPE bzw. fragt sonst nach
            cli_scope=""
            ;;
    esac
}

# Interaktives Hauptmenü, das beim Aufruf ohne Parameter angezeigt wird
# Setzt bei Bedarf cli_project/cli_scope/restore_mode und kehrt zurück, damit der übrige
# Skript-Ablauf unverändert weiterläuft, oder führt reine Info-Aktionen direkt aus.
function run_main_menu() {
    while true; do
        echo
        echo "======================================"
        echo "BackupScript - Hauptmenü"
        echo "======================================"
        echo "  1) Ein Projekt sichern"
        echo "  2) Alle Projekte sichern"
        echo "  3) Neues Projekt einrichten"
        echo "  4) Datenbank wiederherstellen"
        echo "  5) Projekt-Datengröße anzeigen"
        echo "  6) Projektübersicht anzeigen"
        echo "  0) Beenden"
        echo "======================================"
        read -rp "Auswahl: " menu_choice

        case "$menu_choice" in
            1)
                prompt_scope_choice
                return 0
                ;;
            2)
                cli_project='alle'
                prompt_scope_choice
                return 0
                ;;
            3)
                read -rp "Name für das neue Projekt (wird für Dateinamen verwendet, z.B. 'kundeA'): " menu_new_project_name
                menu_new_project_name=${menu_new_project_name// /_}
                if [ -z "$menu_new_project_name" ]; then
                    echo "Kein Projektname angegeben." >&2
                    continue
                fi
                cli_project="$menu_new_project_name"
                return 0
                ;;
            4)
                restore_mode='true'
                return 0
                ;;
            5)
                show_project_data_size
                ;;
            6)
                show_project_overview
                ;;
            0)
                echo "Beendet."
                exit 0
                ;;
            *)
                echo "Ungültige Auswahl." >&2
                ;;
        esac
    done
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

# Interaktives Hauptmenü anzeigen, wenn das Skript ohne Parameter aufgerufen wird
# (z.B. manueller Aufruf im Terminal). Bei Aufrufen mit Parametern (z.B. per Cron)
# wird das Menü übersprungen und wie bisher direkt mit den Parametern gearbeitet.
if [ $# -eq 0 ] && [ -t 0 ]; then
    run_main_menu
fi

# Restore-Modus (--restore): statt eines Backups wird eine Datenbank wiederhergestellt
if [ "$restore_mode" == "true" ]; then
    if [ "$cli_project" == "alle" ]; then
        echo "Restore kann nur für ein einzelnes Projekt durchgeführt werden. Bitte --project=<name> verwenden." >&2
        exit 1
    fi

    restore_target_env_file=''
    if [ -n "$cli_project" ]; then
        match_env_file="$basename/.env.$cli_project"
        if [ "$cli_project" == "default" ] && [ -f "$legacy_env_file" ]; then
            restore_target_env_file="$legacy_env_file"
        elif [ -f "$match_env_file" ]; then
            restore_target_env_file="$match_env_file"
        else
            echo "Kein Projekt '$cli_project' gefunden." >&2
            exit 1
        fi
    elif [ "${#env_files[@]}" -eq 1 ]; then
        restore_target_env_file="${env_files[0]}"
    else
        echo "======================================"
        echo "Für welches Projekt soll eine Datenbank wiederhergestellt werden?"
        project_index=1
        for existing_env_file in "${env_files[@]}"; do
            echo "  $project_index) $(project_name_from_env_file "$existing_env_file")"
            project_index=$((project_index + 1))
        done
        echo "======================================"
        read -rp "Projekt auswählen (Nummer): " project_choice
        selected_index=$((project_choice - 1))
        restore_target_env_file="${env_files[$selected_index]}"
    fi

    run_restore_for_project "$restore_target_env_file"
    exit $?
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
    local sql_file="$db_dateiname$db_dateiendung"

    # Datenbanken sichern
    if [ "$db_name" != "" ]
    then
        echo "Sichern der Datenbank '$db_name' in Datei $sql_file ..." | tee -a "$log_file_name"
        MYSQL_PWD="$db_password" mysqldump \
            --single-transaction \
            --quick \
            --routines \
            --triggers \
            --skip-lock-tables \
            -h"$db_host" \
            -u"$db_user" \
            "$db_name" > "$sql_file" 2>> "$log_file_name"
        local dump_status=$?

        if [ "$dump_status" -ne 0 ] || [ ! -s "$sql_file" ]; then
            echo "FEHLER: mysqldump für '$db_name' auf '$db_host' fehlgeschlagen (Exit-Code: $dump_status)!" | tee -a "$log_file_name" >&2
            rm -f "$sql_file"
            return 1
        fi

        echo "Datenbankdump erfolgreich erstellt." | tee -a "$log_file_name"
        echo

        echo "Nachbearbeiten der Sicherung von $sql_file ..." | tee -a "$log_file_name"
        # DEFINER bereinigen (portabel via temporärer Datei)
        local temp_sql="$sql_file.tmp.$$"
        sed -E 's/DEFINER=(`[^`]+`|"[^"]+"|[a-zA-Z0-9_.-]+)@(`[^`]+`|"[^"]+"|[a-zA-Z0-9_.-]+)/DEFINER=CURRENT_USER/g' "$sql_file" > "$temp_sql" && mv "$temp_sql" "$sql_file"
        rm -f "$temp_sql"
        echo "erledigt." | tee -a "$log_file_name"
        echo | tee -a "$log_file_name"

        # zip
        if ! [ -x "$(command -v zip)" ]; then
            echo 'Warnung: zip ist nicht installiert.' | tee -a "$log_file_name" >&2
            echo "SQL-Datei $sql_file bleibt unkomprimiert erhalten." | tee -a "$log_file_name"
        else
            local zip_file="$db_dateiname$db_dateiendung$dateiendung_zip"
            echo "ZIP-Datei von Sicherung erstellen $zip_file ..." | tee -a "$log_file_name"
            zip -q "$zip_file" "$sql_file" 2>> "$log_file_name"
            local zip_status=$?

            if [ "$zip_status" -eq 0 ] && [ -s "$zip_file" ]; then
                # sql-datei löschen
                echo "Unkomprimierte Datei löschen $sql_file ..." | tee -a "$log_file_name"
                rm -f "$sql_file"
            else
                echo "Warnung: ZIP-Erstellung fehlgeschlagen (Status: $zip_status). $sql_file bleibt erhalten." | tee -a "$log_file_name" >&2
                return_value=1
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

    # Alte Werte aus einem zuvor gesicherten Projekt entfernen, damit nichts
    # (insbesondere die Ausschluss-Muster) fälschlich übernommen wird, wenn die
    # aktuelle .env-Datei die Variable nicht selbst setzt.
    unset SOURCE_FILES_DIR_IGNORE

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

    # Auszuschließende Muster laden.
    # Bevorzugt wird das neue, robuste Bash-Array-Format
    #   SOURCE_FILES_DIR_IGNORE=('*/cache/*' '*/backups/*')
    # Aeltere Konfigurationen mit einem einfachen String werden weiterhin
    # unterstuetzt und tolerant (inkl. versehentlicher Klammern/Anfuehrungszeichen)
    # in ein Array umgewandelt.
    source_files_dir_ignore=()
    if declare -p SOURCE_FILES_DIR_IGNORE 2>/dev/null | grep -q '^declare -a'; then
        source_files_dir_ignore=("${SOURCE_FILES_DIR_IGNORE[@]}")
    elif [ -n "$SOURCE_FILES_DIR_IGNORE" ]; then
        local raw_ignore="$SOURCE_FILES_DIR_IGNORE"
        # versehentlich umschliessende Klammern eines kaputten alten Werts entfernen
        raw_ignore="${raw_ignore#(}"
        raw_ignore="${raw_ignore%)}"
        read -ra source_files_dir_ignore <<< "$raw_ignore"
        # evtl. je Muster verbliebene umschliessende Anfuehrungszeichen entfernen
        local ignore_fix_i
        for ((ignore_fix_i=0; ignore_fix_i<${#source_files_dir_ignore[@]}; ignore_fix_i++)); do
            local ignore_pattern="${source_files_dir_ignore[$ignore_fix_i]}"
            ignore_pattern="${ignore_pattern#\'}"; ignore_pattern="${ignore_pattern%\'}"
            ignore_pattern="${ignore_pattern#\"}"; ignore_pattern="${ignore_pattern%\"}"
            source_files_dir_ignore[$ignore_fix_i]="$ignore_pattern"
        done
    fi

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

    # Backup Zielordner & Logs sicher anlegen (Webroot-Schutz für Apache 2.4/2.2)
    backup_destiantion="$basename/$projekt_basis_dateiname/"
    ensure_webroot_protection "$backup_destiantion" "deny_all"
    ensure_webroot_protection "$basename/log" "deny_all"

    # Dateien
    dateien_dateiname="$backup_destiantion$projekt_basis_dateiname"'_'"$(date +%Y-%m-%d_%H-%M-%S)"'_'files
    log_file_name="$basename/log/$projekt_basis_dateiname"'_'"$(date +%Y-%m-%d_%H-%M-%S)"'.log'
    touch "$log_file_name"
    chmod 600 "$log_file_name" 2>/dev/null || true

    # Dateiendungen
    dateiendung_zip='.zip'
    db_dateiendung='.sql'

    # Kontrollvariablen
    transmitted=''

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

    # Freien Festplattenspeicher prüfen
    check_disk_space "$backup_destiantion" "$log_file_name"

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
            if [ ! -d "$source_files_dir" ]; then
                echo "Warnung: Website-Verzeichnis '$source_files_dir' existiert nicht oder ist kein Verzeichnis." | tee -a "$log_file_name" >&2
            elif ! [ -x "$(command -v zip)" ]; then
                echo 'Fehler: zip ist nicht installiert.' | tee -a "$log_file_name" >&2
                echo 'Website-Dateien konnten nicht gesichert werden.' | tee -a "$log_file_name"
            else
                local zip_target="$dateien_dateiname$dateiendung_zip"
                echo "ZIP-Datei von Dateien im Website-Verzeichnis ($source_files_dir) erstellen ..." | tee -a "$log_file_name"
                local zip_files_status=0
                if [ "${#source_files_dir_ignore[@]}" -gt "0" ] && [ "${source_files_dir_ignore[0]}" != "" ]
                then
                    echo " ausgeschlossene(r) Ordner: ${source_files_dir_ignore[*]}" | tee -a "$log_file_name"
                    zip -rq "$zip_target" "$source_files_dir" -x "${source_files_dir_ignore[@]}" 2>> "$log_file_name"
                    zip_files_status=$?
                else
                    zip -rq "$zip_target" "$source_files_dir" 2>> "$log_file_name"
                    zip_files_status=$?
                fi
                if [ "$zip_files_status" -eq 0 ] || [ "$zip_files_status" -eq 12 ]; then
                    echo "erledigt." | tee -a "$log_file_name"
                else
                    echo "Warnung: zip beendete mit Exit-Code $zip_files_status" | tee -a "$log_file_name" >&2
                fi
                echo | tee -a "$log_file_name"
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
            rsync -rltDvzre "ssh -i $rsync_key" --exclude='.htaccess' --progress "$backup_destiantion" "$rsync_user@$rysnc_host:$rsync_directory" 2>&1 | tee -a "$log_file_name"
        else
            rsync -rltDvzre "ssh" --exclude='.htaccess' --progress "$backup_destiantion" "$rsync_user@$rysnc_host:$rsync_directory" 2>&1 | tee -a "$log_file_name"
        fi
        local rsync_status="${PIPESTATUS[0]}"

        # Wurden die Daten übertragen?
        if [ "$rsync_status" -eq 0 ]
        then
          transmitted='true'
          echo "rsync-Synchronisation erfolgreich abgeschlossen." | tee -a "$log_file_name"
        else
          transmitted=''
          echo "Fehler bei der rsync-Synchronisation (Status: $rsync_status)" | tee -a "$log_file_name" >&2
        fi
    fi
    echo | tee -a "$log_file_name"

    # Dateien per sftp kopieren sftp
    if [ "$sftp_host" != "" ]
    then
        echo "Dateien auf entfernten Server kopieren (sftp)..." | tee -a "$log_file_name"
        # batchfile für sftp erstellen
        local sftp_batchfile="$basename/.${projekt_basis_dateiname}_sftp_upload_batchfile_$$"
        touch "$sftp_batchfile"
        chmod 600 "$sftp_batchfile" 2>/dev/null || true

        if [ "$sftp_directory" != "" ]
        then
            echo "cd \"$sftp_directory\"" > "$sftp_batchfile"
        else
            : > "$sftp_batchfile"
        fi

        local file_path
        local filename
        for file_path in "$backup_destiantion"*; do
            [ -f "$file_path" ] || continue
            filename="$(basename "$file_path")"
            [ "$filename" = ".htaccess" ] && continue
            echo "put \"$file_path\"" >> "$sftp_batchfile"
        done
        echo "exit" >> "$sftp_batchfile"

        # hier ist der eigentliche upload auf den backup-server
        sftp -S "$sftp_path_to_ssh_binary" -b "$sftp_batchfile" -o PubkeyAuthentication=yes -o IdentityFile="$sftp_key" -o Port="$sftp_port" "$sftp_user@$sftp_host" 2>&1 | tee -a "$log_file_name"
        local sftp_status="${PIPESTATUS[0]}"

        # Wurden die Daten übertragen?
        if [ "$sftp_status" -eq 0 ]
        then
          transmitted='true'
          echo "sftp-Übertragung erfolgreich abgeschlossen." | tee -a "$log_file_name"
        else
          transmitted=''
          echo "Fehler bei der sftp-Übertragung (Status: $sftp_status)" | tee -a "$log_file_name" >&2
        fi

        # Dokumenation in logfile
        echo "sftp batchfile content:" >> "$log_file_name"
        echo "-----" >> "$log_file_name"
        cat "$sftp_batchfile" >> "$log_file_name" 2>/dev/null || true
        echo "-----" >> "$log_file_name"

        # batch file löschen
        rm -f "$sftp_batchfile"
        echo | tee -a "$log_file_name"
    fi

    # Dateien löschen, wenn erfolgreich übermittelt wurde
    if [ "$delete_if_transmitted" == "true" ] && [ "$transmitted" == "true" ]
    then
        echo "Dateien in $backup_destiantion werden nach erfolgreicher Übertragung gelöscht ..." | tee -a "$log_file_name"
        if [ -n "$backup_destiantion" ] && [ -d "$backup_destiantion" ]; then
            find "$backup_destiantion" -maxdepth 1 -type f ! -name '.htaccess' -delete -print | tee -a "$log_file_name"
        fi
        echo "erledigt." | tee -a "$log_file_name"
        echo | tee -a "$log_file_name"
        echo
    fi

    # Dateien, die älter als $backup_live_time Tage sind löschen
    if [ -n "$backup_destiantion" ] && [ -d "$backup_destiantion" ] && [ "$backup_live_time" != "0" ] && [ "$backup_live_time" -gt 0 ] 2>/dev/null
    then
        echo "Dateien in $backup_destiantion älter als $backup_live_time Tage löschen ..." | tee -a "$log_file_name"
        find "$backup_destiantion" -maxdepth 1 -type f ! -name '.htaccess' ! -name '*.sh' -mtime +"$backup_live_time" -delete -print | tee -a "$log_file_name"
        echo "erledigt." | tee -a "$log_file_name"
        echo | tee -a "$log_file_name"
    fi

    # Alte Logs bereinigen, wenn backup_live_time konfiguriert ist
    if [ "$backup_live_time" != "0" ] && [ "$backup_live_time" -gt 0 ] 2>/dev/null; then
        find "$basename/log" -maxdepth 1 -type f -name '*.log' -mtime +"$backup_live_time" -delete 2>/dev/null || true
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
