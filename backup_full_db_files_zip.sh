#!/bin/bash
basename=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
set -o pipefail
umask 077

# Farbdefinitionen für interaktive Terminalausgabe (wird für Log-Dateien automatisch bereinigt)
if [ -t 1 ] && [ -z "${CLR_RESET+x}" ]; then
    CLR_RESET=$'\033[0m'
    CLR_BOLD=$'\033[1m'
    CLR_GREEN=$'\033[0;32m'
    CLR_RED=$'\033[0;31m'
    CLR_YELLOW=$'\033[0;33m'
    CLR_BLUE=$'\033[0;34m'
    CLR_CYAN=$'\033[0;36m'
    CLR_GRAY=$'\033[0;90m'
elif [ -z "${CLR_RESET+x}" ]; then
    CLR_RESET=''
    CLR_BOLD=''
    CLR_GREEN=''
    CLR_RED=''
    CLR_YELLOW=''
    CLR_BLUE=''
    CLR_CYAN=''
    CLR_GRAY=''
fi

before=$(date +%s)

###
# BackupScript zum Backup von Websites
# Version: 2.2.0
#
# - Dateien einer Website
# - - optional können Dateien ausgeschlossen werden (SOURCE_FILES_DIR_IGNORE)
# - Datenbank(en) einer Website
# - Automatische WordPress-Erkennung & wp-config-Import
# - Automatische Integritäts- und Strukturselbstprüfung (verify_backup)
# - Maschinenlesbare Statusdateien (<scriptordner>/status/<PROJEKT>.last.json)
# - Healthchecks.io Alarmierung (HEALTHCHECK_URL) bei Laufbeginn (/start) und Ende (/<exitcode>)
# - Backup-Dateien können an entfernten Server via sftp oder rsync übertragen werden
#
# Dieses eine Skript kann für beliebig viele Projekte im selben Ordner verwendet werden.
# Jedes Projekt bekommt seine eigene Konfigurationsdatei nach dem Muster .env.<projektname>
# (z.B. .env.kundeA, .env.kundeB, ...). Eine alte einzelne .env-Datei (ohne Projektnamen)
# wird weiterhin als "default"-Projekt unterstützt.
#
# Exit-Codes:
#   0 = Alles erfolgreich (Backups erstellt, geprüft und ggf. übertragen)
#   1 = Warnungen (z.B. Übertragung fehlgeschlagen, Backups lokal aber vorhanden; Größenabweichung > 30 %)
#   2 = Fehler (ein DB-Dump oder das Datei-ZIP fehlt/ist defekt; mysqldump/zip fehlgeschlagen)
#   Bei --project=alle gilt der schlechteste Status aller Projekte.
#
# (c) Gregor Wendland 2017-2026 /// free to use, free to change, do what you want with this file, no warranty
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
#   ./backup_full_db_files_zip.sh --project=kundeA --json
#       -> sichert "kundeA", gibt Ausgaben nach stderr und das Status-JSON auf stdout aus
#   ./backup_full_db_files_zip.sh --restore --project=kundeA
#       -> stellt interaktiv eine Datenbank des Projekts "kundeA" aus einem vorhandenen Backup wieder her
#
# Wird das Skript ohne jegliche Parameter in einem Terminal aufgerufen, erscheint immer
# das interaktive Hauptmenü. Werden Parameter übergeben (z.B. --project/--scope/--restore/--json),
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
check_mode='false'
cli_scan_wp='false'
cli_scan_wp_path=''
cli_json='false'
cli_quiet='false'
retention_dry_run='false'
cli_source_only='false'

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
        --retention-dry-run)
            retention_dry_run='true'
            ;;
        --check|--pre-check)
            check_mode='true'
            ;;
        --scan-wp)
            cli_scan_wp='true'
            cli_scan_wp_path='..'
            ;;
        --scan-wp=*)
            cli_scan_wp='true'
            cli_scan_wp_path="${cli_arg#*=}"
            ;;
        --discover-wp)
            cli_scan_wp='true'
            cli_scan_wp_path='..'
            ;;
        --discover-wp=*)
            cli_scan_wp='true'
            cli_scan_wp_path="${cli_arg#*=}"
            ;;
        --json)
            cli_json='true'
            ;;
        --quiet|-q)
            cli_quiet='true'
            ;;
        --source-only)
            cli_source_only='true'
            ;;
        --help|-h)
            echo "Verwendung: $0 [OPTIONEN]"
            echo
            echo "Optionen:"
            echo "  --project=<name>|alle   Projekt-Konfiguration (.env.<name>), die verwendet werden soll."
            echo "                          'alle' verarbeitet nacheinander alle gefundenen Projekte."
            echo "  --scope=alles|db|dateien Was gesichert werden soll: alles (Standard), db oder dateien."
            echo "  --retention-dry-run     Prüft Aufbewahrungsregeln (Staffel/GVS) und zeigt Tabellenvorschau."
            echo "  --restore               Datenbank aus vorhandenem Backup wiederherstellen (interaktiv)."
            echo "  --check|--pre-check     Pre-Backup & Sicherheitsprüfungen für das Projekt durchführen."
            echo "  --scan-wp[=<ordner>]    Sucht nach WordPress-Installationen (Standard: ..) und richtet .env ein."
            echo "  --json                  Gibt am Ende den Laufstatus als JSON auf stdout aus."
            echo "                          Fortschritts- und Logausgaben werden nach stderr umgeleitet."
            echo "  --quiet, -q             Unterdrückt normale Informationsausgaben (nur Fehler/Zusammenfassung)."
            echo "  --help, -h              Zeigt diesen Hilfetext an."
            echo
            echo "Exit-Codes:"
            echo "  0 = Alles in Ordnung (Backups erfolgreich erstellt und verifiziert)"
            echo "  1 = Warnungen (z. B. Übertragung fehlgeschlagen, aber lokale Backups vorhanden)"
            echo "  2 = Fehler (ein DB-Dump oder Datei-ZIP fehlt, ist beschädigt oder Abbruch)"
            echo
            echo "Ohne Parameter im Terminal wird das interaktive Hauptmenü angezeigt."
            exit 0
            ;;
        *)
            echo "Unbekannter Parameter '$cli_arg' wird ignoriert (siehe --help)." >&2
            ;;
    esac
done

# Wenn --json aktiv ist, leiten wir alle normalen Ausgaben (stdout) nach stderr um,
# damit stdout sauber für das finale JSON-Objekt / -Array reserviert bleibt.
if [ "$cli_json" == "true" ]; then
    exec 3>&1
    exec 1>&2
fi

# Wenn --quiet aktiv ist (und nicht --json), unterdrücken wir Standardausgaben
if [ "$cli_quiet" == "true" ] && [ "$cli_json" != "true" ]; then
    exec 4>&1
    exec 1>/dev/null
fi

# Escaped einen String sicher für JSON ohne externe Abhängigkeiten wie jq
function json_escape() {
    local input="$1"
    local output=""
    # Backslash, Anführungszeichen und Steuerzeichen maskieren
    output="${input//\\/\\\\}"
    output="${output//\"/\\\"}"
    output="${output//$'\n'/\\n}"
    output="${output//$'\r'/\\r}"
    output="${output//$'\t'/\\t}"
    output="${output//$'\b'/\\b}"
    output="${output//$'\f'/\\f}"
    printf '%s' "$output"
}

# Erzeugt ein JSON-String-Array aus den übergebenen Argumenten
function json_string_array() {
    [ $# -eq 0 ] && { printf "[]"; return 0; }
    local items=("$@")
    local out="["
    local first=1
    for item in "${items[@]}"; do
        [ -z "$item" ] && continue
        if [ "$first" -eq 1 ]; then
            first=0
        else
            out+=", "
        fi
        out+="\"$(json_escape "$item")\""
    done
    out+="]"
    printf '%s' "$out"
}

# Ermittelt die Dateigröße in Bytes portabel (stat / wc)
function get_file_size_bytes() {
    local file="$1"
    if [ ! -f "$file" ]; then
        echo 0
        return 0
    fi
    local size=0
    # GNU stat (-c %s), BSD/macOS stat (-f %z) oder wc -c als Fallback
    if size=$(stat -c%s "$file" 2>/dev/null); then
        echo "$size"
    elif size=$(stat -f%z "$file" 2>/dev/null); then
        echo "$size"
    else
        size=$(wc -c < "$file" 2>/dev/null || echo 0)
        echo "${size// /}"
    fi
}

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

function quote_shell_value() {
    local value="$1"
    value=${value//\'/\'\\\'\'}
    printf '%s' "$value"
}

function is_valid_project_selection() {
    local choice="$1"
    local count="$2"
    [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] 2>/dev/null && [ "$choice" -le "$count" ] 2>/dev/null
}

function reset_project_config_variables() {
    local config_var
    for config_var in PROJECT_NAME PROJEKT_BASIS_DATEINAME DEFAULT_SCOPE DB_COUNT SOURCE_FILES_DIR SFTP_HOST SFTP_PORT SFTP_KEY SFTP_USER SFTP_DIRECTORY SFTP_PATH_TO_SSH_BINARY RSYNC_HOST RSYNC_USER RSYNC_DIRECTORY RSYNC_KEY RETENTION_MODE KEEP_DAILY_DAYS KEEP_WEEKLY_DAYS KEEP_MONTHLY_DAYS KEEP_MIN_SETS RETENTION_REMOTE DELETE_IF_TRANSMITTED HEALTHCHECK_URL STATUS_EMAIL_ADDRESS ALERT_EMAIL_ADDRESS; do
        printf -v "$config_var" '%s' ''
    done
    unset SOURCE_FILES_DIR_IGNORE

    for config_var in ${!DB_@}; do
        if [[ "$config_var" =~ ^DB_[0-9]+_(HOST|NAME|USER|PASSWORD)$ ]]; then
            printf -v "$config_var" '%s' ''
        fi
    done
}

function normalize_nonnegative_integer() {
    local value="$1"
    local fallback="$2"
    if [[ "$value" =~ ^[0-9]+$ ]]; then
        printf '%s' "$value"
    else
        printf '%s' "$fallback"
    fi
}

# Formatiert Byte-Werte lesbar (z.B. "142.50 MB", "1.20 GB")
function format_bytes_human() {
    local b="${1:-0}"
    if ! [[ "$b" =~ ^[0-9]+$ ]]; then
        echo "0 B"
        return
    fi
    if [ "$b" -ge 1073741824 ]; then
        awk "BEGIN {printf \"%.2f GB\", $b / 1073741824}"
    elif [ "$b" -ge 1048576 ]; then
        awk "BEGIN {printf \"%.2f MB\", $b / 1048576}"
    elif [ "$b" -ge 1024 ]; then
        awk "BEGIN {printf \"%.2f KB\", $b / 1024}"
    else
        echo "${b} B"
    fi
}

# Parst einen Backup-Dateinamen und extrahiert Metadaten
# Rückgabe via globale Variablen:
#   PARSED_BACKUP_VALID (1=gültig, 0=ungültig/fremd)
#   PARSED_BACKUP_TS (YYYY-MM-DD_HH-MM-SS)
#   PARSED_BACKUP_TYPE ("db" / "files")
#   PARSED_BACKUP_DBNAME (Name der Datenbank bei Typ "db")
function parse_backup_filename() {
    local filename="$1"
    local project_basis="$2"

    filename="$(basename "$filename")"
    PARSED_BACKUP_VALID=0
    PARSED_BACKUP_TS=""
    PARSED_BACKUP_TYPE=""
    PARSED_BACKUP_DBNAME=""

    # Muss zwingend mit dem Projekt-Basisdateinamen + "_" beginnen
    local prefix="${project_basis}_"
    if [[ "$filename" != "$prefix"* ]]; then
        return 1
    fi

    local rest="${filename#$prefix}"
    # Zeitstempel YYYY-MM-DD_HH-MM-SS prüfen
    if [[ "$rest" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2})_(.*)$ ]]; then
        local ts="${BASH_REMATCH[1]}"
        local suffix="${BASH_REMATCH[2]}"

        if [ "$suffix" = "files.zip" ] || [ "$suffix" = "files" ]; then
            PARSED_BACKUP_VALID=1
            PARSED_BACKUP_TS="$ts"
            PARSED_BACKUP_TYPE="files"
            PARSED_BACKUP_DBNAME=""
            return 0
        elif [[ "$suffix" == *.sql.zip ]]; then
            PARSED_BACKUP_VALID=1
            PARSED_BACKUP_TS="$ts"
            PARSED_BACKUP_TYPE="db"
            PARSED_BACKUP_DBNAME="${suffix%.sql.zip}"
            return 0
        elif [[ "$suffix" == *.sql ]]; then
            PARSED_BACKUP_VALID=1
            PARSED_BACKUP_TS="$ts"
            PARSED_BACKUP_TYPE="db"
            PARSED_BACKUP_DBNAME="${suffix%.sql}"
            return 0
        fi
    fi

    return 1
}

# Ermittelt Portabel (macOS & Linux) Epoch, Alter in Tagen, ISO-Woche und Monat eines Zeitstempels
# Rückgabe via globale Variablen:
#   PARSED_TS_EPOCH, PARSED_TS_AGE_DAYS, PARSED_TS_ISO_WEEK, PARSED_TS_MONTH
function parse_timestamp_date_info() {
    local ts="$1"
    local now_epoch="${2:-$(date +%s)}"
    local epoch=""
    local iso_week=""
    local cal_month=""

    # BSD date (macOS)
    local out
    out="$(date -j -f "%Y-%m-%d_%H-%M-%S" "$ts" "+%s %G-W%V %Y-%m" 2>/dev/null || true)"
    if [ -z "$out" ]; then
        # GNU date (Linux)
        local formatted_dt="${ts:0:10} ${ts:11:2}:${ts:14:2}:${ts:17:2}"
        out="$(date -d "$formatted_dt" "+%s %G-W%V %Y-%m" 2>/dev/null || true)"
    fi

    if [ -n "$out" ]; then
        read -r epoch iso_week cal_month <<< "$out"
    else
        epoch=0
        iso_week="${ts:0:4}-W00"
        cal_month="${ts:0:7}"
    fi

    local age_s=$((now_epoch - epoch))
    local age_days=0
    if [ "$age_s" -gt 0 ]; then
        age_days=$((age_s / 86400))
    fi

    PARSED_TS_EPOCH="$epoch"
    PARSED_TS_AGE_DAYS="$age_days"
    PARSED_TS_ISO_WEEK="$iso_week"
    PARSED_TS_MONTH="$cal_month"
}

# Fasst gefundene Dateien zu atomaren Backup-Sätzen nach Zeitstempel zusammen
# Eingabe:
#   $1: project_basis
#   $2: expect_files (true/false)
#   $3..$N: expected_db_names
# Liest globale Arrays RAW_FILES und RAW_SIZES
# Füllt globale Ergebnis-Arrays (sortiert absteigend nach Zeitstempel):
#   SET_TIMESTAMPS, SET_IS_COMPLETE, SET_BYTES, SET_FILES_COUNT, SET_FILE_LIST, SET_SCOPE_DESC
function group_backup_sets() {
    local project_basis="$1"
    local expect_files="$2"
    shift 2
    local expected_dbs=("$@")

    SET_TIMESTAMPS=()
    SET_IS_COMPLETE=()
    SET_BYTES=()
    SET_FILES_COUNT=()
    SET_FILE_LIST=()
    SET_SCOPE_DESC=()

    local raw_count="${#RAW_FILES[@]}"
    [ "$raw_count" -eq 0 ] && return 0

    local parsed_lines=()
    local i
    for ((i=0; i<raw_count; i++)); do
        local fname="${RAW_FILES[$i]}"
        local fsize="${RAW_SIZES[$i]:-0}"
        if parse_backup_filename "$fname" "$project_basis"; then
            local dbname_clean="${PARSED_BACKUP_DBNAME:--}"
            parsed_lines+=("$PARSED_BACKUP_TS|$PARSED_BACKUP_TYPE|$dbname_clean|$fsize|$(basename "$fname")")
        fi
    done

    [ "${#parsed_lines[@]}" -eq 0 ] && return 0

    local sorted_records
    sorted_records="$(printf "%s\n" "${parsed_lines[@]}" | sort -r -t'|' -k1,1)"

    local current_ts=""
    local set_bytes=0
    local set_files_count=0
    local set_file_list=()
    local set_dbs=()
    local set_has_files=0

    _finalize_set() {
        [ -z "$current_ts" ] && return 0

        local is_complete=1
        local missing_items=()

        if [ "$expect_files" = "true" ] && [ "$set_has_files" -ne 1 ]; then
            is_complete=0
            missing_items+=("files")
        fi

        local exp_db
        for exp_db in "${expected_dbs[@]}"; do
            [ -z "$exp_db" ] && continue
            local found_db=0
            local s_db
            for s_db in "${set_dbs[@]}"; do
                if [ "$s_db" = "$exp_db" ]; then
                    found_db=1
                    break
                fi
            done
            if [ "$found_db" -ne 1 ]; then
                is_complete=0
                missing_items+=("DB:$exp_db")
            fi
        done

        local scope_desc=""
        if [ "${#set_dbs[@]}" -gt 0 ] && [ "$set_has_files" -eq 1 ]; then
            scope_desc="${#set_dbs[@]} DBs + files"
        elif [ "${#set_dbs[@]}" -gt 0 ]; then
            scope_desc="${#set_dbs[@]} DB(s)"
        elif [ "$set_has_files" -eq 1 ]; then
            scope_desc="files"
        else
            scope_desc="leer"
        fi

        if [ "$is_complete" -ne 1 ] && [ "${#missing_items[@]}" -gt 0 ]; then
            scope_desc="$scope_desc (unvollständig: fehlt ${missing_items[*]})"
        fi

        SET_TIMESTAMPS+=("$current_ts")
        SET_IS_COMPLETE+=("$is_complete")
        SET_BYTES+=("$set_bytes")
        SET_FILES_COUNT+=("$set_files_count")
        SET_FILE_LIST+=("${set_file_list[*]}")
        SET_SCOPE_DESC+=("$scope_desc")
    }

    while IFS='|' read -r r_ts r_type r_dbname r_size r_fname; do
        [ -z "$r_ts" ] && continue
        if [ "$r_ts" != "$current_ts" ]; then
            _finalize_set
            current_ts="$r_ts"
            set_bytes=0
            set_files_count=0
            set_file_list=()
            set_dbs=()
            set_has_files=0
        fi

        set_bytes=$((set_bytes + r_size))
        set_files_count=$((set_files_count + 1))
        set_file_list+=("$r_fname")
        if [ "$r_type" = "db" ]; then
            [ "$r_dbname" != "-" ] && set_dbs+=("$r_dbname")
        elif [ "$r_type" = "files" ]; then
            set_has_files=1
        fi
    done <<< "$sorted_records"
    _finalize_set
}

# Wendet Aufbewahrungsregeln (Großvater-Vater-Sohn / Staffel, Tage oder Aus) auf gruppierte Sätze an
# Parameter:
#   $1: mode ('staffel', 'tage', 'aus')
#   $2: daily_days (Standard: 30)
#   $3: weekly_days (Standard: 90)
#   $4: monthly_days (Standard: 365, 0 = unbegrenzt)
#   $5: min_sets (Standard: 3)
#   $6: now_epoch (Standard: aktuelle Zeit)
# Füllt globale Ergebnis-Arrays:
#   SET_DECISIONS ("BEHALTEN" / "LOESCHEN")
#   SET_REASONS ("taeglich", "woechentlich", "monatlich", "minimum", "unvollstaendig_alt", "unvollstaendig_neu", "tage_abgelaufen", "zu_alt", "retention_aus")
#   SET_AGE_DAYS, SET_ISO_WEEKS, SET_MONTHS
function evaluate_retention_sets() {
    local mode="${1:-staffel}"
    local daily_days="${2:-30}"
    local weekly_days="${3:-90}"
    local monthly_days="${4:-365}"
    local min_sets="${5:-3}"
    local now_epoch="${6:-$(date +%s)}"

    local count="${#SET_TIMESTAMPS[@]}"
    SET_DECISIONS=()
    SET_REASONS=()
    SET_AGE_DAYS=()
    SET_ISO_WEEKS=()
    SET_MONTHS=()

    local i
    for ((i=0; i<count; i++)); do
        local ts="${SET_TIMESTAMPS[$i]}"
        parse_timestamp_date_info "$ts" "$now_epoch"
        SET_AGE_DAYS[$i]="$PARSED_TS_AGE_DAYS"
        SET_ISO_WEEKS[$i]="$PARSED_TS_ISO_WEEK"
        SET_MONTHS[$i]="$PARSED_TS_MONTH"
    done

    if [ "$mode" = "aus" ]; then
        for ((i=0; i<count; i++)); do
            SET_DECISIONS[$i]="BEHALTEN"
            SET_REASONS[$i]="retention_aus"
        done
        return 0
    fi

    if [ "$mode" = "tage" ]; then
        local succ_rank=0
        local has_newer_complete=0
        for ((i=0; i<count; i++)); do
            local is_comp="${SET_IS_COMPLETE[$i]}"
            local age="${SET_AGE_DAYS[$i]}"

            if [ "$is_comp" = "1" ] || [ "$is_comp" = "true" ]; then
                succ_rank=$((succ_rank + 1))
                has_newer_complete=1
                if [ "$succ_rank" -le "$min_sets" ]; then
                    SET_DECISIONS[$i]="BEHALTEN"
                    SET_REASONS[$i]="minimum"
                elif [ "$daily_days" -eq 0 ] || [ "$age" -le "$daily_days" ]; then
                    SET_DECISIONS[$i]="BEHALTEN"
                    SET_REASONS[$i]="taeglich"
                else
                    SET_DECISIONS[$i]="LOESCHEN"
                    SET_REASONS[$i]="tage_abgelaufen"
                fi
            else
                if [ "$age" -le 7 ]; then
                    SET_DECISIONS[$i]="BEHALTEN"
                    SET_REASONS[$i]="unvollstaendig_neu"
                elif [ "$has_newer_complete" -eq 1 ]; then
                    SET_DECISIONS[$i]="LOESCHEN"
                    SET_REASONS[$i]="unvollstaendig_alt"
                else
                    SET_DECISIONS[$i]="BEHALTEN"
                    SET_REASONS[$i]="minimum"
                fi
            fi
        done
        return 0
    fi

    # mode == "staffel"
    local seen_weeks=" "
    local seen_months=" "
    local succ_rank=0
    local has_newer_complete=0

    for ((i=0; i<count; i++)); do
        local is_comp="${SET_IS_COMPLETE[$i]}"
        local age="${SET_AGE_DAYS[$i]}"
        local week="${SET_ISO_WEEKS[$i]}"
        local month="${SET_MONTHS[$i]}"

        if [ "$is_comp" != "1" ] && [ "$is_comp" != "true" ]; then
            if [ "$age" -le 7 ]; then
                SET_DECISIONS[$i]="BEHALTEN"
                SET_REASONS[$i]="unvollstaendig_neu"
            elif [ "$has_newer_complete" -eq 1 ]; then
                SET_DECISIONS[$i]="LOESCHEN"
                SET_REASONS[$i]="unvollstaendig_alt"
            else
                SET_DECISIONS[$i]="BEHALTEN"
                SET_REASONS[$i]="minimum"
            fi
            continue
        fi

        # Vollständiger Satz
        succ_rank=$((succ_rank + 1))
        has_newer_complete=1

        # 1. Tägliche Staffel (alle Sätze bis daily_days)
        if [ "$age" -le "$daily_days" ]; then
            SET_DECISIONS[$i]="BEHALTEN"
            SET_REASONS[$i]="taeglich"
            seen_weeks="${seen_weeks}${week} "
            seen_months="${seen_months}${month} "

        # 2. Wöchentliche Staffel (bis weekly_days: jüngster Satz der ISO-Woche)
        elif [ "$age" -le "$weekly_days" ]; then
            if [[ "$seen_weeks" != *" $week "* ]]; then
                SET_DECISIONS[$i]="BEHALTEN"
                SET_REASONS[$i]="woechentlich"
                seen_weeks="${seen_weeks}${week} "
                seen_months="${seen_months}${month} "
            elif [ "$succ_rank" -le "$min_sets" ]; then
                SET_DECISIONS[$i]="BEHALTEN"
                SET_REASONS[$i]="minimum"
            else
                SET_DECISIONS[$i]="LOESCHEN"
                SET_REASONS[$i]="zu_alt"
            fi

        # 3. Monatliche Staffel (bis monthly_days oder unbegrenzt wenn 0: jüngster Satz des Kalendermonats)
        elif [ "$monthly_days" -eq 0 ] || [ "$age" -le "$monthly_days" ]; then
            if [[ "$seen_months" != *" $month "* ]]; then
                SET_DECISIONS[$i]="BEHALTEN"
                SET_REASONS[$i]="monatlich"
                seen_months="${seen_months}${month} "
            elif [ "$succ_rank" -le "$min_sets" ]; then
                SET_DECISIONS[$i]="BEHALTEN"
                SET_REASONS[$i]="minimum"
            else
                SET_DECISIONS[$i]="LOESCHEN"
                SET_REASONS[$i]="zu_alt"
            fi

        # 4. Älter als monatliche Grenze
        else
            if [ "$succ_rank" -le "$min_sets" ]; then
                SET_DECISIONS[$i]="BEHALTEN"
                SET_REASONS[$i]="minimum"
            else
                SET_DECISIONS[$i]="LOESCHEN"
                SET_REASONS[$i]="zu_alt"
            fi
        fi
    done
}

# Führt die lokale Aufbewahrungsbereinigung für ein Projekt durch
# Parameter:
#   $1: project_env_file
#   $2: is_dry_run ("true"/"false")
#   $3: log_target (Standard: /dev/null)
#   $4: allow_delete ("true"/"false", Standard: "true")
function apply_retention_local() {
    local p_env="$1"
    local is_dry_run="${2:-false}"
    local log_target="${3:-/dev/null}"
    local allow_delete="${4:-true}"

    RETENTION_LOCAL_KEPT=0
    RETENTION_LOCAL_DELETED=0
    RETENTION_LOCAL_FREED_BYTES=0

    [ -f "$p_env" ] || return 0
    local p_name
    p_name="$(project_name_from_env_file "$p_env")"

    local PROJEKT_BASIS_DATEINAME=""
    local RETENTION_MODE=""
    local KEEP_DAILY_DAYS=""
    local KEEP_WEEKLY_DAYS=""
    local KEEP_MONTHLY_DAYS=""
    local KEEP_MIN_SETS=""
    local SOURCE_FILES_DIR=""
    local DB_COUNT=""

    reset_project_config_variables
    # shellcheck source=/dev/null
    source "$p_env"

    local p_env_dir
    p_env_dir="$(cd "$(dirname "$p_env")" && pwd)"
    local p_basis="${PROJEKT_BASIS_DATEINAME:-$p_name}"
    local backup_dir="$p_env_dir/$p_basis/"
    [ -d "$backup_dir" ] || return 0

    local ret_mode="${RETENTION_MODE:-aus}"

    local daily_days="${KEEP_DAILY_DAYS:-30}"
    local weekly_days="${KEEP_WEEKLY_DAYS:-90}"
    local monthly_days="${KEEP_MONTHLY_DAYS:-365}"
    local min_sets="${KEEP_MIN_SETS:-3}"

    local expect_files="false"
    [ -n "$SOURCE_FILES_DIR" ] && expect_files="true"

    local exp_dbs=()
    if [ -n "$DB_COUNT" ] && [ "$DB_COUNT" -gt 0 ] 2>/dev/null; then
        local d_i
        for ((d_i=1; d_i<=DB_COUNT; d_i++)); do
            local d_var="DB_${d_i}_NAME"
            [ -n "${!d_var:-}" ] && exp_dbs+=("${!d_var}")
        done
    fi

    RAW_FILES=()
    RAW_SIZES=()
    local f
    for f in "$backup_dir"*; do
        [ -f "$f" ] || continue
        local fname
        fname="$(basename "$f")"
        if parse_backup_filename "$fname" "$p_basis"; then
            RAW_FILES+=("$fname")
            RAW_SIZES+=("$(get_file_size_bytes "$f")")
        fi
    done

    [ "${#RAW_FILES[@]}" -eq 0 ] && return 0

    group_backup_sets "$p_basis" "$expect_files" "${exp_dbs[@]}"
    evaluate_retention_sets "$ret_mode" "$daily_days" "$weekly_days" "$monthly_days" "$min_sets"

    local s_idx
    for ((s_idx=0; s_idx<${#SET_TIMESTAMPS[@]}; s_idx++)); do
        local ts="${SET_TIMESTAMPS[$s_idx]}"
        local dec="${SET_DECISIONS[$s_idx]}"
        local rsn="${SET_REASONS[$s_idx]}"
        local s_bytes="${SET_BYTES[$s_idx]}"
        local s_fcount="${SET_FILES_COUNT[$s_idx]}"
        local s_flist="${SET_FILE_LIST[$s_idx]}"

        if [ "$dec" = "BEHALTEN" ]; then
            RETENTION_LOCAL_KEPT=$((RETENTION_LOCAL_KEPT + 1))
        else
            RETENTION_LOCAL_DELETED=$((RETENTION_LOCAL_DELETED + 1))
            RETENTION_LOCAL_FREED_BYTES=$((RETENTION_LOCAL_FREED_BYTES + s_bytes))

            if [ "$is_dry_run" != "true" ] && [ "$allow_delete" = "true" ]; then
                echo "[RETENTION][LOKAL] Lösche Satz $ts (Grund: $rsn, $s_fcount Dateien, $(format_bytes_human "$s_bytes"))" | tee -a "$log_target"
                local del_f
                for del_f in $s_flist; do
                    if parse_backup_filename "$del_f" "$p_basis"; then
                        rm -f "$backup_dir$del_f"
                        echo "  [LOKAL] gelöscht: $del_f" | tee -a "$log_target"
                    fi
                done
            fi
        fi
    done

    # Alte Logs bereinigen, wenn im Staffel-Modus
    if [ "$is_dry_run" != "true" ] && [ "$allow_delete" = "true" ]; then
        local log_clean_days="$daily_days"
        [ "$log_clean_days" -lt 30 ] && log_clean_days=30
        find "$basename/log" -maxdepth 1 -type f -name "${p_basis}_*.log" -mtime +"$log_clean_days" -delete 2>/dev/null || true
    fi

    return 0
}

# Führt die entfernte Aufbewahrungsbereinigung via SFTP-Batch durch
# Parameter:
#   $1: project_env_file
#   $2: is_dry_run ("true"/"false")
#   $3: log_target (Standard: /dev/null)
#   $4: allow_delete ("true"/"false", Standard: "true")
function apply_retention_remote() {
    local p_env="$1"
    local is_dry_run="${2:-false}"
    local log_target="${3:-/dev/null}"
    local allow_delete="${4:-true}"

    RETENTION_REMOTE_KEPT=0
    RETENTION_REMOTE_DELETED=0
    RETENTION_REMOTE_FREED_BYTES=0
    RETENTION_REMOTE_ERROR=""

    [ -f "$p_env" ] || return 0
    local p_name
    p_name="$(project_name_from_env_file "$p_env")"

    local PROJEKT_BASIS_DATEINAME=""
    local RETENTION_MODE=""
    local KEEP_DAILY_DAYS=""
    local KEEP_WEEKLY_DAYS=""
    local KEEP_MONTHLY_DAYS=""
    local KEEP_MIN_SETS=""
    local RETENTION_REMOTE="yes"
    local SOURCE_FILES_DIR=""
    local DB_COUNT=""

    local SFTP_HOST=""
    local SFTP_PORT="22"
    local SFTP_USER=""
    local SFTP_KEY=""
    local SFTP_DIRECTORY=""
    local SFTP_PATH_TO_SSH_BINARY=""

    local RSYNC_HOST=""
    local RSYNC_USER=""
    local RSYNC_KEY=""
    local RSYNC_DIRECTORY=""

    reset_project_config_variables
    # shellcheck source=/dev/null
    source "$p_env"

    local p_basis="${PROJEKT_BASIS_DATEINAME:-$p_name}"

    # Prüfen, ob RETENTION_REMOTE auf 'no' steht
    if [ "$RETENTION_REMOTE" = "no" ] || [ "$RETENTION_REMOTE" = "false" ]; then
        return 0
    fi

    # Remote-Zugangsdaten identifizieren
    local r_host=""
    local r_user=""
    local r_port="22"
    local r_key=""
    local r_dir=""
    local r_ssh="${SFTP_PATH_TO_SSH_BINARY:-$(command -v ssh)}"

    if [ -n "$SFTP_HOST" ]; then
        r_host="$SFTP_HOST"
        r_user="$SFTP_USER"
        r_port="${SFTP_PORT:-22}"
        r_key="$SFTP_KEY"
        r_dir="$SFTP_DIRECTORY"
    elif [ -n "$RSYNC_HOST" ]; then
        r_host="$RSYNC_HOST"
        r_user="$RSYNC_USER"
        r_port="22"
        r_key="$RSYNC_KEY"
        r_dir="$RSYNC_DIRECTORY"
        r_ssh="$(command -v ssh)"
    else
        # Kein Remote-Ziel konfiguriert
        return 0
    fi

    local ret_mode="${RETENTION_MODE:-aus}"

    local daily_days="${KEEP_DAILY_DAYS:-30}"
    local weekly_days="${KEEP_WEEKLY_DAYS:-90}"
    local monthly_days="${KEEP_MONTHLY_DAYS:-365}"
    local min_sets="${KEEP_MIN_SETS:-3}"

    local expect_files="false"
    [ -n "$SOURCE_FILES_DIR" ] && expect_files="true"

    local exp_dbs=()
    if [ -n "$DB_COUNT" ] && [ "$DB_COUNT" -gt 0 ] 2>/dev/null; then
        local d_i
        for ((d_i=1; d_i<=DB_COUNT; d_i++)); do
            local d_var="DB_${d_i}_NAME"
            [ -n "${!d_var:-}" ] && exp_dbs+=("${!d_var}")
        done
    fi

    # SFTP Batch zur Dateiliste erstellen
    local sftp_ls_batch="$basename/.${p_basis}_sftp_ls_$$"
    if [ -n "$r_dir" ]; then
        echo "cd \"$r_dir\"" > "$sftp_ls_batch"
    else
        : > "$sftp_ls_batch"
    fi
    echo "ls -l" >> "$sftp_ls_batch"
    echo "exit" >> "$sftp_ls_batch"

    local ssh_opts=(-o "PubkeyAuthentication=yes" -o "Port=$r_port" -o "ConnectTimeout=15" -o "BatchMode=yes" -o "StrictHostKeyChecking=accept-new")
    if [ -n "$r_key" ]; then
        ssh_opts+=(-o "IdentityFile=$r_key")
    fi

    local sftp_out
    sftp_out=$(sftp -S "$r_ssh" "${ssh_opts[@]}" -b "$sftp_ls_batch" "$r_user@$r_host" 2>&1)
    local sftp_rc=$?
    rm -f "$sftp_ls_batch"

    if [ "$sftp_rc" -ne 0 ]; then
        RETENTION_REMOTE_ERROR="SFTP-Verbindungsfehler beim Auflisten (Status: $sftp_rc)"
        echo "Warnung: Remote-Dateiliste für '$p_name' konnte nicht per SFTP abgefragt werden (Status: $sftp_rc)." | tee -a "$log_target" >&2
        return 1
    fi

    RAW_FILES=()
    RAW_SIZES=()
    while IFS= read -r line; do
        [[ "$line" =~ ^[-l] ]] || continue
        local f_size
        local f_name
        f_size=$(echo "$line" | awk '{print $5}')
        f_name=$(echo "$line" | awk '{for(i=9;i<=NF;++i) printf "%s%s", $i, (i==NF?"":" ")}')
        [ -z "$f_name" ] && continue
        if parse_backup_filename "$f_name" "$p_basis"; then
            RAW_FILES+=("$f_name")
            RAW_SIZES+=("${f_size:-0}")
        fi
    done <<< "$sftp_out"

    [ "${#RAW_FILES[@]}" -eq 0 ] && return 0

    group_backup_sets "$p_basis" "$expect_files" "${exp_dbs[@]}"
    evaluate_retention_sets "$ret_mode" "$daily_days" "$weekly_days" "$monthly_days" "$min_sets"

    local files_to_delete_remote=()
    local s_idx
    for ((s_idx=0; s_idx<${#SET_TIMESTAMPS[@]}; s_idx++)); do
        local ts="${SET_TIMESTAMPS[$s_idx]}"
        local dec="${SET_DECISIONS[$s_idx]}"
        local rsn="${SET_REASONS[$s_idx]}"
        local s_bytes="${SET_BYTES[$s_idx]}"
        local s_fcount="${SET_FILES_COUNT[$s_idx]}"
        local s_flist="${SET_FILE_LIST[$s_idx]}"

        if [ "$dec" = "BEHALTEN" ]; then
            RETENTION_REMOTE_KEPT=$((RETENTION_REMOTE_KEPT + 1))
        else
            RETENTION_REMOTE_DELETED=$((RETENTION_REMOTE_DELETED + 1))
            RETENTION_REMOTE_FREED_BYTES=$((RETENTION_REMOTE_FREED_BYTES + s_bytes))

            if [ "$is_dry_run" != "true" ] && [ "$allow_delete" = "true" ]; then
                echo "[RETENTION][REMOTE] Lösche Satz $ts (Grund: $rsn, $s_fcount Dateien, $(format_bytes_human "$s_bytes"))" | tee -a "$log_target"
                local del_f
                for del_f in $s_flist; do
                    if parse_backup_filename "$del_f" "$p_basis"; then
                        files_to_delete_remote+=("$del_f")
                    fi
                done
            fi
        fi
    done

    # Löschungen per SFTP-Batch ausführen
    if [ "$is_dry_run" != "true" ] && [ "$allow_delete" = "true" ] && [ "${#files_to_delete_remote[@]}" -gt 0 ]; then
        local sftp_rm_batch="$basename/.${p_basis}_sftp_rm_$$"
        if [ -n "$r_dir" ]; then
            echo "cd \"$r_dir\"" > "$sftp_rm_batch"
        else
            : > "$sftp_rm_batch"
        fi
        local rf
        for rf in "${files_to_delete_remote[@]}"; do
            echo "rm \"$rf\"" >> "$sftp_rm_batch"
        done
        echo "exit" >> "$sftp_rm_batch"

        local rm_out
        rm_out=$(sftp -S "$r_ssh" "${ssh_opts[@]}" -b "$sftp_rm_batch" "$r_user@$r_host" 2>&1)
        local rm_rc=$?
        rm -f "$sftp_rm_batch"

        if [ "$rm_rc" -ne 0 ]; then
            RETENTION_REMOTE_ERROR="SFTP-Löschfehler (Status: $rm_rc)"
            echo "Warnung: Fehler beim Remote-Löschen per SFTP (Status: $rm_rc): $rm_out" | tee -a "$log_target" >&2
            return 1
        else
            for rf in "${files_to_delete_remote[@]}"; do
                echo "  [REMOTE] gelöscht: $rf" | tee -a "$log_target"
            done
        fi
    fi

    return 0
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
<FilesMatch "^(\.env.*|\.update.*|\.gotenberg.*|\.git.*|.*\.log|.*\.sh|.*\.json|.*\.lock)$">
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

# Sendet Pings an Healthchecks.io (Laufbeginn: /start, Laufende: /<exitcode>, Test: ohne Suffix)
# Timeout 10s. Netzwerkfehler beeinträchtigen das Backup nicht.
function send_healthcheck_ping() {
    local hc_url="$1"
    local endpoint_suffix="${2:-}"
    local log_target="${3:-/dev/null}"

    [ -z "$hc_url" ] && return 0
    local ping_url="${hc_url%/}"
    [ -n "$endpoint_suffix" ] && ping_url="${ping_url}/${endpoint_suffix#/}"

    if command -v curl >/dev/null 2>&1; then
        curl -fsS -m 10 --retry 1 "$ping_url" >/dev/null 2>&1 || true
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O /dev/null --timeout=10 --tries=1 --no-check-certificate "$ping_url" >/dev/null 2>&1 || true
    fi
}

# Formatiert und gibt eine Prüfzeile für Pre-Checks / Statusanzeigen aus
# Ausgabe auf dem Terminal farbig (grün / gelb / rot / cyan), in Log-Dateien sauber als Text
function log_check_item() {
    local status="$1"    # "OK", "WARN", "ALERT", "INFO"
    local message="$2"
    local log_file="${3:-}"
    local details="${4:-}"

    local symbol=""
    local color=""
    case "$status" in
        OK)
            symbol="[✓ OK]"
            color="${CLR_GREEN}"
            ;;
        WARN)
            symbol="[⚠ WARNUNG]"
            color="${CLR_YELLOW}"
            ;;
        ALERT|ERROR)
            symbol="[✖ ACHTUNG]"
            color="${CLR_RED}"
            ;;
        INFO)
            symbol="[ℹ INFO]"
            color="${CLR_CYAN}"
            ;;
        *)
            symbol="[•]"
            color="${CLR_GRAY}"
            ;;
    esac

    # Terminal-Ausgabe mit Farbe
    printf "  %b%-12s%b %s\n" "${color}${CLR_BOLD}" "$symbol" "${CLR_RESET}" "$message"
    if [ -n "$details" ]; then
        printf "               %b%s%b\n" "${CLR_GRAY}" "$details" "${CLR_RESET}"
    fi

    # Saubere Log-Ausgabe ohne ANSI-Steuerzeichen
    if [ -n "$log_file" ] && [ -f "$log_file" ]; then
        printf "  %-12s %s\n" "$symbol" "$message" >> "$log_file"
        if [ -n "$details" ]; then
            printf "               %s\n" "$details" >> "$log_file"
        fi
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
                log_check_item "ALERT" "Geringer freier Speicherplatz auf Ziellaufwerk ($avail_mb MB verbleibend)!" "$log_target"
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
## Hilfsfunktionen für Pfad-Auflösung, WordPress-Erkennung & wp-config-Parsing

# Löst relative Pfade (relativ zu $basename) oder absolute Pfade inklusive ~ auf
function resolve_dir_path() {
    local input_path="$1"
    local base_ref="${2:-$basename}"
    [ -z "$input_path" ] && echo "" && return 1

    if [[ "$input_path" == ~* ]]; then
        input_path="${input_path/#\~/$HOME}"
    fi

    if [[ "$input_path" = /* ]]; then
        if [ -d "$input_path" ]; then
            (cd "$input_path" 2>/dev/null && pwd)
        else
            echo "$input_path"
        fi
    else
        if [ -d "$base_ref/$input_path" ]; then
            (cd "$base_ref/$input_path" 2>/dev/null && pwd)
        else
            echo "$base_ref/$input_path"
        fi
    fi
}

# Regex-Fallback zum Auslesen von Konstanten aus wp-config.php via sed (POSIX-kompatibel)
function extract_wp_constant_sed() {
    local file="$1"
    local const_name="$2"
    local val
    # Format mit Anführungszeichen: define('NAME', 'wert');
    val=$(sed -n "s/^[[:space:]]*define([[:space:]]*['\"]${const_name}['\"][[:space:]]*,[[:space:]]*['\"]\([^'\"]*\)['\"][[:space:]]*);.*/\1/p" "$file" | head -n 1)
    if [ -z "$val" ]; then
        # Format ohne Anführungszeichen (z.B. booleans/zahlen): define('NAME', true);
        val=$(sed -n "s/^[[:space:]]*define([[:space:]]*['\"]${const_name}['\"][[:space:]]*,[[:space:]]*\([a-zA-Z0-9_]*\)[[:space:]]*);.*/\1/p" "$file" | head -n 1)
    fi
    echo "$val"
}

# Liest Datenbank-, Website- und Debug-Parameter aus einer wp-config.php aus
function parse_wp_config_file() {
    local wp_config_file="$1"
    [ -f "$wp_config_file" ] || return 1

    WP_PARSED_DB_NAME=""
    WP_PARSED_DB_USER=""
    WP_PARSED_DB_PASSWORD=""
    WP_PARSED_DB_HOST="localhost"
    WP_PARSED_SITEURL=""
    WP_PARSED_HOME=""
    WP_PARSED_PREFIX="wp_"
    WP_PARSED_DEBUG="false"
    WP_PARSED_DEBUG_LOG="false"
    WP_PARSED_DEBUG_DISPLAY="false"
    WP_PARSED_SCRIPT_DEBUG="false"

    # Bevorzugt: PHP Token-Parsing (für 100% PHP-Syntax- und String-Kompatibilität)
    if command -v php >/dev/null 2>&1; then
        local parsed_output
        parsed_output=$(php -r '
        $file = $argv[1];
        $content = @file_get_contents($file);
        if ($content === false) exit(1);
        $tokens = @token_get_all($content);
        $count = count($tokens);
        $data = [
            "DB_NAME" => "",
            "DB_USER" => "",
            "DB_PASSWORD" => "",
            "DB_HOST" => "localhost",
            "WP_SITEURL" => "",
            "WP_HOME" => "",
            "table_prefix" => "wp_",
            "WP_DEBUG" => "false",
            "WP_DEBUG_LOG" => "false",
            "WP_DEBUG_DISPLAY" => "false",
            "SCRIPT_DEBUG" => "false"
        ];
        for ($i = 0; $i < $count; $i++) {
            if (is_array($tokens[$i])) {
                if ($tokens[$i][0] === T_STRING && strtolower($tokens[$i][1]) === "define") {
                    $name = null;
                    $val = null;
                    $j = $i + 1;
                    while ($j < $count && $tokens[$j] !== ";") {
                        if (is_array($tokens[$j])) {
                            $tok_type = $tokens[$j][0];
                            $raw = $tokens[$j][1];
                            if ($tok_type === T_CONSTANT_ENCAPSED_STRING) {
                                $quote = $raw[0];
                                $inner = substr($raw, 1, -1);
                                if ($quote === "\x27") {
                                    $unescaped = str_replace(["\\\\", "\\\x27"], ["\\", "\x27"], $inner);
                                } else {
                                    $unescaped = stripcslashes($inner);
                                }
                                if ($name === null) {
                                    $name = $unescaped;
                                } else if ($val === null) {
                                    $val = $unescaped;
                                    break;
                                }
                            } elseif ($tok_type === T_STRING) {
                                $lower = strtolower($raw);
                                if ($name === null) {
                                    $name = $raw;
                                } else if ($val === null) {
                                    if ($lower === "true") $val = "true";
                                    elseif ($lower === "false") $val = "false";
                                    elseif ($lower === "null") $val = "null";
                                    else $val = $raw;
                                    break;
                                }
                            } elseif ($tok_type === T_LNUMBER || $tok_type === T_DNUMBER) {
                                if ($val === null && $name !== null) {
                                    $val = $raw;
                                    break;
                                }
                            }
                        }
                        $j++;
                    }
                    if ($name !== null && $val !== null && array_key_exists($name, $data)) {
                        $data[$name] = $val;
                    }
                } elseif ($tokens[$i][0] === T_VARIABLE && $tokens[$i][1] === "\$table_prefix") {
                    $j = $i + 1;
                    while ($j < $count && $tokens[$j] !== ";") {
                        if (is_array($tokens[$j]) && $tokens[$j][0] === T_CONSTANT_ENCAPSED_STRING) {
                            $raw = $tokens[$j][1];
                            $quote = $raw[0];
                            $inner = substr($raw, 1, -1);
                            if ($quote === "\x27") {
                                $data["table_prefix"] = str_replace(["\\\\", "\\\x27"], ["\\", "\x27"], $inner);
                            } else {
                                $data["table_prefix"] = stripcslashes($inner);
                            }
                            break;
                        }
                        $j++;
                    }
                }
            }
        }
        foreach ($data as $k => $v) {
            echo $k . "\t" . $v . "\n";
        }
        ' "$wp_config_file" 2>/dev/null)

        if [ -n "$parsed_output" ]; then
            while IFS=$'\t' read -r k v; do
                case "$k" in
                    DB_NAME) WP_PARSED_DB_NAME="$v" ;;
                    DB_USER) WP_PARSED_DB_USER="$v" ;;
                    DB_PASSWORD) WP_PARSED_DB_PASSWORD="$v" ;;
                    DB_HOST) WP_PARSED_DB_HOST="${v:-localhost}" ;;
                    WP_SITEURL) WP_PARSED_SITEURL="$v" ;;
                    WP_HOME) WP_PARSED_HOME="$v" ;;
                    table_prefix) WP_PARSED_PREFIX="${v:-wp_}" ;;
                    WP_DEBUG) WP_PARSED_DEBUG="$v" ;;
                    WP_DEBUG_LOG) WP_PARSED_DEBUG_LOG="$v" ;;
                    WP_DEBUG_DISPLAY) WP_PARSED_DEBUG_DISPLAY="$v" ;;
                    SCRIPT_DEBUG) WP_PARSED_SCRIPT_DEBUG="$v" ;;
                esac
            done <<< "$parsed_output"
            return 0
        fi
    fi

    # Fallback: sed / regex
    WP_PARSED_DB_NAME="$(extract_wp_constant_sed "$wp_config_file" DB_NAME)"
    WP_PARSED_DB_USER="$(extract_wp_constant_sed "$wp_config_file" DB_USER)"
    WP_PARSED_DB_PASSWORD="$(extract_wp_constant_sed "$wp_config_file" DB_PASSWORD)"
    WP_PARSED_DB_HOST="$(extract_wp_constant_sed "$wp_config_file" DB_HOST)"
    WP_PARSED_DB_HOST="${WP_PARSED_DB_HOST:-localhost}"
    WP_PARSED_SITEURL="$(extract_wp_constant_sed "$wp_config_file" WP_SITEURL)"
    WP_PARSED_HOME="$(extract_wp_constant_sed "$wp_config_file" WP_HOME)"
    WP_PARSED_DEBUG="$(extract_wp_constant_sed "$wp_config_file" WP_DEBUG)"
    WP_PARSED_DEBUG_LOG="$(extract_wp_constant_sed "$wp_config_file" WP_DEBUG_LOG)"
    WP_PARSED_DEBUG_DISPLAY="$(extract_wp_constant_sed "$wp_config_file" WP_DEBUG_DISPLAY)"
    WP_PARSED_SCRIPT_DEBUG="$(extract_wp_constant_sed "$wp_config_file" SCRIPT_DEBUG)"
}

# Sucht in einem Ordner, dessen Unterordnern (bis 2. Ebene) oder übergeordnetem Ordner nach wp-config.php
function find_wp_config_in_path() {
    local base_dir="$1"
    [ -d "$base_dir" ] || return 1

    local candidates=(
        "$base_dir/wp-config.php"
        "$base_dir/public_html/wp-config.php"
        "$base_dir/htdocs/wp-config.php"
        "$base_dir/web/wp-config.php"
        "$base_dir/wordpress/wp-config.php"
        "$base_dir/wp/wp-config.php"
    )

    for cand in "${candidates[@]}"; do
        if [ -f "$cand" ]; then
            echo "$cand"
            return 0
        fi
    done

    # Auch in weiteren Unterordnern bis zur zweiten Ebene suchen (z.B. <base>/<ebene1>/<ebene2>/wp-config.php)
    local found_nested=""
    found_nested=$(find "$base_dir" -maxdepth 3 -name "wp-config.php" ! -path "*/node_modules/*" ! -path "*/vendor/*" ! -path "*/.*/*" ! -path "*/log/*" 2>/dev/null | head -n 1)
    if [ -n "$found_nested" ] && [ -f "$found_nested" ]; then
        echo "$found_nested"
        return 0
    fi

    if [ -f "$(dirname "$base_dir")/wp-config.php" ]; then
        echo "$(dirname "$base_dir")/wp-config.php"
        return 0
    fi
    return 1
}

# Erstellt einen sauberen Namensvorschlag für das Projekt anhand URL / Blogname / Ordnername
function suggest_project_name_from_wp() {
    local wp_dir="$1"
    local site_url="${2:-$WP_PARSED_HOME}"
    site_url="${site_url:-$WP_PARSED_SITEURL}"
    local db_name="${3:-$WP_PARSED_DB_NAME}"
    local db_user="${4:-$WP_PARSED_DB_USER}"
    local db_pass="${5:-$WP_PARSED_DB_PASSWORD}"
    local db_host="${6:-$WP_PARSED_DB_HOST}"
    local prefix="${7:-$WP_PARSED_PREFIX}"

    local raw_name=""

    # Optional: MySQL-Schnellabfrage für SiteURL / Blogname, falls Client installiert und erreichbar
    if [ -z "$site_url" ] && [ -n "$db_name" ] && [ -n "$db_user" ] && command -v mysql >/dev/null 2>&1; then
        local db_host_clean="${db_host%%:*}"
        local db_port="${db_host#*:}"
        local port_arg=""
        [ "$db_port" != "$db_host" ] && port_arg="-P$db_port"
        local query_res
        query_res=$(MYSQL_PWD="$db_pass" mysql -h"$db_host_clean" $port_arg -u"$db_user" "$db_name" --connect-timeout=2 -s -N -e "SELECT option_value FROM ${prefix}options WHERE option_name IN ('blogname', 'siteurl') ORDER BY option_name DESC LIMIT 2;" 2>/dev/null)
        if [ -n "$query_res" ]; then
            raw_name=$(echo "$query_res" | head -n 1)
        fi
    fi

    if [ -z "$raw_name" ] && [ -n "$site_url" ]; then
        raw_name="$site_url"
    fi

    if [ -z "$raw_name" ]; then
        raw_name="$(basename "$wp_dir")"
    fi

    # Bereinigung: Schema, www, Pfade und Sonderzeichen entfernen
    raw_name="${raw_name#http://}"
    raw_name="${raw_name#https://}"
    raw_name="${raw_name#www.}"
    raw_name="${raw_name%%/*}"
    raw_name="${raw_name%%:*}"

    local clean_name
    clean_name=$(echo "$raw_name" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9_.-]/_/g' -e 's/^[._-]*//' -e 's/[._-]*$//')
    echo "${clean_name:-wordpress}"
}

# Schreibt eine vollständige .env.<projektname> Konfigurationsdatei mit Umask 077 und chmod 600
function write_project_env_file() {
    local target_file="$1"
    local proj_name="$2"
    local basis_name="$3"
    local def_scope="$4"
    local src_dir="$5"
    local ignore_literal="$6"
    local del_transmitted="$7"
    local s_host="$8"
    local s_port="$9"
    local s_user="${10}"
    local s_key="${11}"
    local s_dir="${12}"
    local s_ssh_bin="${13}"
    local r_host="${14}"
    local r_user="${15}"
    local r_dir="${16}"
    local r_key="${17}"
    local healthcheck_url="${18:-}"
    local ret_mode="${19:-staffel}"
    local k_daily="${20:-30}"
    local k_weekly="${21:-90}"
    local k_monthly="${22:-365}"
    local k_min="${23:-3}"
    local ret_remote="${24:-yes}"
    shift 24 2>/dev/null || shift $#
    local dbs=("$@")

    local count=${#dbs[@]}
    if [ $((count % 4)) -ne 0 ]; then
        echo "FEHLER: Datenbank-Argumente für '$proj_name' müssen in Vierergruppen (Host, Name, User, Passwort) übergeben werden." >&2
        return 1
    fi
    if ! [[ "$ret_mode" =~ ^(staffel|tage|aus)$ ]]; then
        echo "FEHLER: Ungültiger Aufbewahrungsmodus '$ret_mode' für '$proj_name' (erlaubt: staffel, tage, aus)." >&2
        return 1
    fi
    for retention_value in "$k_daily" "$k_weekly" "$k_monthly" "$k_min"; do
        if ! [[ "$retention_value" =~ ^[0-9]+$ ]]; then
            echo "FEHLER: Aufbewahrungswerte für '$proj_name' müssen nichtnegative Ganzzahlen sein." >&2
            return 1
        fi
    done

    local quoted_proj_name="$(quote_shell_value "$proj_name")"
    local quoted_basis_name="$(quote_shell_value "$basis_name")"
    local quoted_def_scope="$(quote_shell_value "$def_scope")"
    local quoted_src_dir="$(quote_shell_value "$src_dir")"
    local quoted_s_host="$(quote_shell_value "$s_host")"
    local quoted_s_port="$(quote_shell_value "$s_port")"
    local quoted_s_user="$(quote_shell_value "$s_user")"
    local quoted_s_key="$(quote_shell_value "$s_key")"
    local quoted_s_dir="$(quote_shell_value "$s_dir")"
    local quoted_s_ssh_bin="$(quote_shell_value "${s_ssh_bin:-/usr/bin/ssh}")"
    local quoted_r_host="$(quote_shell_value "$r_host")"
    local quoted_r_user="$(quote_shell_value "$r_user")"
    local quoted_r_dir="$(quote_shell_value "$r_dir")"
    local quoted_r_key="$(quote_shell_value "$r_key")"
    local quoted_ret_mode="$(quote_shell_value "$ret_mode")"
    local quoted_ret_remote="$(quote_shell_value "$ret_remote")"
    local quoted_del_transmitted="$(quote_shell_value "$del_transmitted")"
    local quoted_healthcheck_url="$(quote_shell_value "$healthcheck_url")"
    local num_dbs=$((count / 4))

    cat > "$target_file" <<EOF
# Zugangsdaten & Konfiguration für ein Projekt
# automatisch erstellt am $(date) durch das Backup-Skript
# Diese Datei enthält Zugangsdaten und sollte NICHT ins Git-Repository eingecheckt werden (siehe .gitignore).

PROJECT_NAME='$quoted_proj_name'
PROJEKT_BASIS_DATEINAME='$quoted_basis_name'

# Was soll standardmäßig gesichert werden, wenn nicht per --scope angegeben: alles / db / dateien
DEFAULT_SCOPE='$quoted_def_scope'

# Datenbank-Konfiguration
# Bei mehreren Datenbanken wird DB_COUNT sowie DB_1_*, DB_2_*, etc. verwendet.
DB_COUNT='$num_dbs'
EOF

    local db_idx=1
    for ((i=0; i<count; i+=4)); do
        local h="$(quote_shell_value "${dbs[i]}")"
        local n="$(quote_shell_value "${dbs[i+1]}")"
        local u="$(quote_shell_value "${dbs[i+2]}")"
        local p="$(quote_shell_value "${dbs[i+3]}")"
        cat >> "$target_file" <<EOF
DB_${db_idx}_HOST='$h'
DB_${db_idx}_NAME='$n'
DB_${db_idx}_USER='$u'
DB_${db_idx}_PASSWORD='$p'
EOF
        db_idx=$((db_idx + 1))
    done

    cat >> "$target_file" <<EOF

SOURCE_FILES_DIR='$quoted_src_dir'
# Auszuschließende Muster als Bash-Array - je Element ein Muster.
# Beispiel: SOURCE_FILES_DIR_IGNORE=('*/cache/*' '*/backups/*')
SOURCE_FILES_DIR_IGNORE=($ignore_literal)

SFTP_HOST='$quoted_s_host'
SFTP_PORT='$quoted_s_port'
SFTP_KEY='$quoted_s_key'
SFTP_USER='$quoted_s_user'
SFTP_DIRECTORY='$quoted_s_dir'
SFTP_PATH_TO_SSH_BINARY='$quoted_s_ssh_bin'

RSYNC_HOST='$quoted_r_host'
RSYNC_USER='$quoted_r_user'
RSYNC_DIRECTORY='$quoted_r_dir'
RSYNC_KEY='$quoted_r_key'

# Aufbewahrungsregeln (Retention / Großvater-Vater-Sohn)
RETENTION_MODE='$quoted_ret_mode'
KEEP_DAILY_DAYS=$k_daily
KEEP_WEEKLY_DAYS=$k_weekly
KEEP_MONTHLY_DAYS=$k_monthly
KEEP_MIN_SETS=$k_min
RETENTION_REMOTE='$quoted_ret_remote'

DELETE_IF_TRANSMITTED='$quoted_del_transmitted'

# Healthchecks.io Alarmierung (Ping bei Start mit /start, bei Ende mit /<exitcode>)
# Leer lassen, um Healthchecks-Ping zu deaktivieren
HEALTHCHECK_URL='$quoted_healthcheck_url'

# E-Mail-Benachrichtigung (aktuell noch nicht implementiert)
STATUS_EMAIL_ADDRESS=''
ALERT_EMAIL_ADDRESS=''
EOF
    chmod 600 "$target_file" 2>/dev/null || true
}

# Sucht in einem angegebenen Verzeichnis nach WordPress-Installationen und richtet diese ein
function scan_and_setup_wordpress_sites() {
    local default_scan_dir="${1:-..}"
    echo
    echo "======================================"
    echo "WordPress-Erkennung & Auto-Import"
    echo "======================================"
    echo "Das Skript sucht in einem Ordner nach vorhandenen WordPress-Installationen,"
    echo "liest Datenbank-Zugangsdaten aus der wp-config.php aus und schlägt"
    echo "Projekt-Namen und Dateipfade automatisch vor."
    echo

    read -rp "Suchordner für WordPress-Installationen (relativ oder absolut) [$default_scan_dir]: " input_scan_dir
    input_scan_dir=${input_scan_dir:-$default_scan_dir}

    local resolved_scan_dir
    resolved_scan_dir="$(resolve_dir_path "$input_scan_dir")"

    if [ -z "$resolved_scan_dir" ] || [ ! -d "$resolved_scan_dir" ]; then
        echo "Fehler: Ordner '$input_scan_dir' existiert nicht oder ist kein Verzeichnis." >&2
        return 1
    fi

    echo "Durchsuche '$resolved_scan_dir' nach WordPress-Installationen (wp-config.php) ..."
    local found_configs=()
    while IFS= read -r -d '' cfg; do
        found_configs+=("$cfg")
    done < <(find "$resolved_scan_dir" -maxdepth 4 -name "wp-config.php" ! -path "*/node_modules/*" ! -path "*/vendor/*" ! -path "*/.*/*" ! -path "*/log/*" -print0 2>/dev/null)

    if [ "${#found_configs[@]}" -eq 0 ]; then
        echo "Keine WordPress-Installationen in '$resolved_scan_dir' gefunden."
        return 1
    fi

    echo
    echo "Es wurden ${#found_configs[@]} WordPress-Installation(en) gefunden:"
    echo "--------------------------------------------------"
    local site_dirs=()
    local suggested_names=()
    local idx=1
    for cfg in "${found_configs[@]}"; do
        local cur_site_dir
        cur_site_dir="$(dirname "$cfg")"
        parse_wp_config_file "$cfg"
        local cur_suggested_name
        cur_suggested_name="$(suggest_project_name_from_wp "$cur_site_dir")"
        site_dirs+=("$cur_site_dir")
        suggested_names+=("$cur_suggested_name")
        echo "  [$idx] Pfad: $cur_site_dir"
        echo "      Projektname-Vorschlag: '$cur_suggested_name' | DB: '${WP_PARSED_DB_NAME:-keine}' (${WP_PARSED_DB_HOST:-localhost})"
        idx=$((idx + 1))
    done
    echo "--------------------------------------------------"

    read -rp "Welche Installationen sollen eingerichtet werden? (z.B. 'alle', '1,2' oder '1-3') [alle]: " selection_input
    selection_input=${selection_input:-alle}

    local selected_indices=()
    if [[ "$selection_input" =~ ^(alle|all|a)$ ]]; then
        for ((i=1; i<=${#found_configs[@]}; i++)); do
            selected_indices+=("$i")
        done
    else
        local clean_selection="${selection_input//,/ }"
        for part in $clean_selection; do
            if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                local start="${BASH_REMATCH[1]}"
                local end="${BASH_REMATCH[2]}"
                for ((k=start; k<=end; k++)); do
                    if [ "$k" -ge 1 ] && [ "$k" -le "${#found_configs[@]}" ]; then
                        selected_indices+=("$k")
                    fi
                done
            elif [[ "$part" =~ ^[0-9]+$ ]]; then
                if [ "$part" -ge 1 ] && [ "$part" -le "${#found_configs[@]}" ]; then
                    selected_indices+=("$part")
                fi
            fi
        done
    fi

    if [ "${#selected_indices[@]}" -eq 0 ]; then
        echo "Keine gültige Auswahl getroffen."
        return 1
    fi

    local created_count=0
    local prev_remote_configured="false"
    local prev_sftp_host=""
    local prev_sftp_port="22"
    local prev_sftp_user=""
    local prev_sftp_key="$HOME/.ssh/id_rsa_backup"
    local prev_sftp_directory=""
    local prev_sftp_ssh_bin="/usr/bin/ssh"
    local prev_rsync_host=""
    local prev_rsync_user=""
    local prev_rsync_directory=""
    local prev_rsync_key="$HOME/.ssh/id_rsa_backup"
    local prev_delete_if_transmitted="false"

    for sel_idx in "${selected_indices[@]}"; do
        local arr_idx=$((sel_idx - 1))
        local cur_cfg="${found_configs[$arr_idx]}"
        local cur_site_dir="${site_dirs[$arr_idx]}"
        local cur_suggested_name="${suggested_names[$arr_idx]}"

        parse_wp_config_file "$cur_cfg"

        echo
        echo "======================================"
        echo "Einrichtung für [$sel_idx]: $cur_site_dir"
        echo "======================================"

        read -rp "Projektname (für .env.<name>) [$cur_suggested_name]: " input_project_name
        local project_name="${input_project_name:-$cur_suggested_name}"
        project_name="${project_name// /_}"

        read -rp "Projekt-Basisdateiname für Backups [$project_name]: " input_basis_name
        local basis_name="${input_basis_name:-$project_name}"

        # DB-Parameter aus WP-Config
        local wp_db_host="${WP_PARSED_DB_HOST:-localhost}"
        local wp_db_name="${WP_PARSED_DB_NAME}"
        local wp_db_user="${WP_PARSED_DB_USER}"
        local wp_db_pass="${WP_PARSED_DB_PASSWORD}"

        echo
        echo "--- Datenbankzugangsdaten (aus wp-config.php) ---"
        read -rp "DB 1 Host [$wp_db_host]: " input_db_host
        local db_host="${input_db_host:-$wp_db_host}"

        read -rp "DB 1 Name [$wp_db_name]: " input_db_name
        local db_name="${input_db_name:-$wp_db_name}"

        read -rp "DB 1 User [$wp_db_user]: " input_db_user
        local db_user="${input_db_user:-$wp_db_user}"

        local db_pass=""
        if [ -n "$wp_db_pass" ]; then
            read -rsp "DB 1 Passwort [Enter = aus wp-config.php übernehmen]: " input_db_pass
            echo
            db_pass="${input_db_pass:-$wp_db_pass}"
        else
            read -rsp "DB 1 Passwort: " db_pass
            echo
        fi

        echo
        read -rp "Website-Ordner, der gesichert werden soll [$cur_site_dir]: " input_source_files_dir
        local source_files_dir="${input_source_files_dir:-$cur_site_dir}"

        echo
        read -rp "Standard-Ausschlussmuster für WordPress (Cache, Backups, Logs, .DS_Store) verwenden? (J/n) [J]: " wp_ignore_choice
        wp_ignore_choice=${wp_ignore_choice:-J}
        local source_files_dir_ignore_literal=""
        if [[ "$wp_ignore_choice" =~ ^[jJyY]$ ]]; then
            source_files_dir_ignore_literal="'*/wp-content/cache/*' '*/wp-content/uploads/cache/*' '*/wp-content/updraft/*' '*/wp-content/backups/*' '*/wp-content/ai1wm-backups/*' '*/wp-content/uploads/wp-clone/*' '*/wp-content/uploads/backupbuddy_backups/*' '*/wp-content/uploads/snapshots/*' '*/wp-content/wflogs/*' '*/wp-content/debug.log' '*/error_log' '*/*.log' '*/.git/*' '*/.svn/*' '*/node_modules/*' '*/.DS_Store' '*/Thumbs.db'"
            echo " -> Ausschlüsse gesetzt: Cache, Upload-Caches, Backup-Plugins, Debug-/Error-Logs, .git, .DS_Store"
        fi

        echo
        read -rp "Standard-Umfang - alles/db/dateien [alles]: " default_scope
        default_scope=${default_scope:-alles}
        default_scope="$(normalize_scope "$default_scope")"
        default_scope="${default_scope:-alles}"

        local sftp_host=""
        local sftp_port=""
        local sftp_user=""
        local sftp_key=""
        local sftp_directory=""
        local sftp_path_to_ssh_binary="/usr/bin/ssh"
        local rsync_host=""
        local rsync_user=""
        local rsync_directory=""
        local rsync_key=""
        local delete_if_transmitted="false"

        echo
        local sync_choice="N"
        if [ "$prev_remote_configured" = "true" ]; then
            read -rp "Sollen die Backup-Dateien extern gesichert/gesynct werden (SFTP/rsync)? (J/n) [J]: " sync_choice
            sync_choice=${sync_choice:-J}
        else
            read -rp "Sollen die Backup-Dateien extern gesichert/gesynct werden (SFTP/rsync)? (j/N) [N]: " sync_choice
            sync_choice=${sync_choice:-N}
        fi

        if [[ "$sync_choice" =~ ^[jJyY]$ ]]; then
            echo
            echo "--- sftp-Übertragung (optional, leer oder '-' lassen zum Überspringen) ---"
            if [ -n "$prev_sftp_host" ]; then
                read -rp "sftp Host [$prev_sftp_host]: " input_sftp_host
                sftp_host="${input_sftp_host:-$prev_sftp_host}"
                [ "$sftp_host" = "-" ] && sftp_host=""
            else
                read -rp "sftp Host (leer = kein SFTP): " sftp_host
                [ "$sftp_host" = "-" ] && sftp_host=""
            fi
            if [ -n "$sftp_host" ]; then
                read -rp "sftp Port [${prev_sftp_port:-22}]: " input_sftp_port
                sftp_port="${input_sftp_port:-${prev_sftp_port:-22}}"
                if [ -n "$prev_sftp_user" ]; then
                    read -rp "sftp User [$prev_sftp_user]: " input_sftp_user
                    sftp_user="${input_sftp_user:-$prev_sftp_user}"
                else
                    read -rp "sftp User: " sftp_user
                fi
                read -rp "Pfad zum privaten SSH-Key [${prev_sftp_key:-$HOME/.ssh/id_rsa_backup}]: " input_sftp_key
                sftp_key="${input_sftp_key:-${prev_sftp_key:-$HOME/.ssh/id_rsa_backup}}"
                if [ -n "$prev_sftp_directory" ]; then
                    read -rp "sftp Zielverzeichnis (optional, '-' = leer) [$prev_sftp_directory]: " input_sftp_dir
                    sftp_directory="${input_sftp_dir:-$prev_sftp_directory}"
                    [ "$sftp_directory" = "-" ] && sftp_directory=""
                else
                    read -rp "sftp Zielverzeichnis (optional): " sftp_directory
                fi
                read -rp "Pfad zum lokalen ssh-Binary [${prev_sftp_ssh_bin:-/usr/bin/ssh}]: " input_sftp_ssh_bin
                sftp_path_to_ssh_binary="${input_sftp_ssh_bin:-${prev_sftp_ssh_bin:-/usr/bin/ssh}}"
            fi

            echo
            echo "--- rsync-Übertragung (optional, leer oder '-' lassen zum Überspringen) ---"
            if [ -n "$prev_rsync_host" ]; then
                read -rp "rsync Host [$prev_rsync_host]: " input_rsync_host
                rsync_host="${input_rsync_host:-$prev_rsync_host}"
                [ "$rsync_host" = "-" ] && rsync_host=""
            else
                read -rp "rsync Host (leer = kein rsync): " rsync_host
                [ "$rsync_host" = "-" ] && rsync_host=""
            fi
            if [ -n "$rsync_host" ]; then
                if [ -n "$prev_rsync_user" ]; then
                    read -rp "rsync User [$prev_rsync_user]: " input_rsync_user
                    rsync_user="${input_rsync_user:-$prev_rsync_user}"
                else
                    read -rp "rsync User: " rsync_user
                fi
                if [ -n "$prev_rsync_directory" ]; then
                    read -rp "rsync Zielverzeichnis (relativ zum rsync-User-Homeverzeichnis) [$prev_rsync_directory]: " input_rsync_dir
                    rsync_directory="${input_rsync_dir:-$prev_rsync_directory}"
                else
                    read -rp "rsync Zielverzeichnis (relativ zum rsync-User-Homeverzeichnis): " rsync_directory
                fi
                read -rp "Pfad zum privaten SSH-Key [${prev_rsync_key:-$HOME/.ssh/id_rsa_backup}]: " input_rsync_key
                rsync_key="${input_rsync_key:-${prev_rsync_key:-$HOME/.ssh/id_rsa_backup}}"
            fi

            if [ -n "$sftp_host" ] || [ -n "$rsync_host" ]; then
                echo
                read -rp "Lokale Backup-Dateien nach erfolgreicher Übertragung löschen? (true/false) [$prev_delete_if_transmitted]: " input_del_transmitted
                delete_if_transmitted="${input_del_transmitted:-$prev_delete_if_transmitted}"
                if [ "$delete_if_transmitted" != "true" ] && [ "$delete_if_transmitted" != "false" ]; then
                    delete_if_transmitted="false"
                fi
                prev_remote_configured="true"
                prev_sftp_host="$sftp_host"
                prev_sftp_port="${sftp_port:-22}"
                prev_sftp_user="$sftp_user"
                prev_sftp_key="${sftp_key:-$HOME/.ssh/id_rsa_backup}"
                prev_sftp_directory="$sftp_directory"
                prev_sftp_ssh_bin="${sftp_path_to_ssh_binary:-/usr/bin/ssh}"
                prev_rsync_host="$rsync_host"
                prev_rsync_user="$rsync_user"
                prev_rsync_directory="$rsync_directory"
                prev_rsync_key="${rsync_key:-$HOME/.ssh/id_rsa_backup}"
                prev_delete_if_transmitted="$delete_if_transmitted"
            fi
        fi

        local target_env_file="$basename/.env.$project_name"
        if [ -e "$target_env_file" ]; then
            read -rp "Konfiguration '$target_env_file' existiert bereits. Überschreiben? (j/N): " overwrite_choice
            if [[ ! "$overwrite_choice" =~ ^[jJyY]$ ]]; then
                echo "-> Bestehende Konfiguration '$target_env_file' bleibt unverändert."
                continue
            fi
        fi
        if ! write_project_env_file "$target_env_file" "$project_name" "$basis_name" "$default_scope" "$source_files_dir" "$source_files_dir_ignore_literal" "$delete_if_transmitted" "$sftp_host" "$sftp_port" "$sftp_user" "$sftp_key" "$sftp_directory" "$sftp_path_to_ssh_binary" "$rsync_host" "$rsync_user" "$rsync_directory" "$rsync_key" "" "staffel" "30" "90" "365" "3" "yes" "$db_host" "$db_name" "$db_user" "$db_pass"; then
            continue
        fi

        echo "-> Projekt '$project_name' erfolgreich als $target_env_file gespeichert."
        created_count=$((created_count + 1))
    done

    echo
    echo "======================================"
    echo "$created_count Projekt-Konfiguration(en) erfolgreich angelegt."
    echo "======================================"
    return 0
}

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
    read -rp "Website-Ordner des Projekts (relativ oder absolut, z.B. '../$project_name') [leer = überspringen]: " input_source_files_dir
    local source_files_dir=""
    local source_files_dir_ignore_patterns=()

    local db_hosts=()
    local db_names=()
    local db_users=()
    local db_passwords=()

    if [ -n "$input_source_files_dir" ]; then
        source_files_dir="$(resolve_dir_path "$input_source_files_dir")"
        if [ -d "$source_files_dir" ]; then
            # Suche nach wp-config.php im Ordner oder Unterordnern (bis 2. Ebene)
            local found_wp_config=""
            found_wp_config="$(find_wp_config_in_path "$source_files_dir")"

            if [ -n "$found_wp_config" ]; then
                echo
                echo "WordPress-Konfiguration (wp-config.php) in '$found_wp_config' erkannt!"
                parse_wp_config_file "$found_wp_config"
                echo "Ausgelesene Datenbank: Name='${WP_PARSED_DB_NAME:-keine}', Host='${WP_PARSED_DB_HOST:-localhost}', User='${WP_PARSED_DB_USER:-keiner}'"

                if [ -n "$WP_PARSED_DB_NAME" ]; then
                    read -rp "Ausgelesene WordPress-Datenbankzugangsdaten übernehmen? (J/n) [J]: " use_wp_db
                    use_wp_db=${use_wp_db:-J}
                    if [[ "$use_wp_db" =~ ^[jJyY]$ ]]; then
                        read -rp "DB 1 Host [${WP_PARSED_DB_HOST:-localhost}]: " current_db_host
                        current_db_host=${current_db_host:-${WP_PARSED_DB_HOST:-localhost}}

                        read -rp "DB 1 Name [${WP_PARSED_DB_NAME}]: " current_db_name
                        current_db_name=${current_db_name:-${WP_PARSED_DB_NAME}}

                        read -rp "DB 1 User [${WP_PARSED_DB_USER}]: " current_db_user
                        current_db_user=${current_db_user:-${WP_PARSED_DB_USER}}

                        local current_db_password=""
                        if [ -n "$WP_PARSED_DB_PASSWORD" ]; then
                            read -rsp "DB 1 Passwort [Enter = aus wp-config.php übernehmen]: " input_wp_db_password
                            echo
                            current_db_password=${input_wp_db_password:-$WP_PARSED_DB_PASSWORD}
                        else
                            read -rsp "DB 1 Passwort: " current_db_password
                            echo
                        fi

                        db_names+=("$current_db_name")
                        db_hosts+=("$current_db_host")
                        db_users+=("$current_db_user")
                        db_passwords+=("$current_db_password")

                        read -rp "Standard-Ausschlussmuster für WordPress (Cache, Backups, Logs, .DS_Store) anwenden? (J/n) [J]: " wp_ignore_choice
                        wp_ignore_choice=${wp_ignore_choice:-J}
                        if [[ "$wp_ignore_choice" =~ ^[jJyY]$ ]]; then
                            source_files_dir_ignore_patterns=(
                                '*/wp-content/cache/*'
                                '*/wp-content/uploads/cache/*'
                                '*/wp-content/updraft/*'
                                '*/wp-content/backups/*'
                                '*/wp-content/ai1wm-backups/*'
                                '*/wp-content/uploads/wp-clone/*'
                                '*/wp-content/uploads/backupbuddy_backups/*'
                                '*/wp-content/uploads/snapshots/*'
                                '*/wp-content/wflogs/*'
                                '*/wp-content/debug.log'
                                '*/error_log'
                                '*/*.log'
                                '*/.git/*'
                                '*/.svn/*'
                                '*/node_modules/*'
                                '*/.DS_Store'
                                '*/Thumbs.db'
                            )
                        fi
                    fi
                fi
            fi
        fi
    fi

    # Wenn keine DBs vorhanden (oder manuell mehr hinzufügen)
    if [ "${#db_names[@]}" -eq 0 ]; then
        echo
        echo "--- Datenbanken (beliebig viele, Nur-Lesezugriff-Benutzer empfohlen) ---"
        echo "Datenbanknamen einfach leer lassen, um keine (weitere) Datenbank hinzuzufügen."
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
    else
        read -rp "Weitere Datenbank hinzufügen? (j/N) [N]: " add_more_db
        if [[ "$add_more_db" =~ ^[jJyY]$ ]]; then
            local db_index=$((${#db_names[@]} + 1))
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
        fi
    fi

    if [ -z "$source_files_dir" ]; then
        echo
        read -rp "Website-Ordner, der gesichert werden soll (relativ oder absolut): " input_source_files_dir
        source_files_dir="$(resolve_dir_path "$input_source_files_dir")"
    fi

    if [ -n "$source_files_dir" ] && [ -d "$source_files_dir" ]; then
        read -rp "Größe dieses Ordners anzeigen? Kann bei großen Ordnern etwas dauern (j/N): " show_folder_size
        if [[ "$show_folder_size" =~ ^[jJyY]$ ]]; then
            echo "Ermittle Ordnergröße ..."
            du -sh "$source_files_dir" 2>/dev/null
        fi
    fi

    if [ "${#source_files_dir_ignore_patterns[@]}" -eq 0 ]; then
        echo
        echo "--- Auszuschließende Ordner/Dateien (optional) ---"
        echo "Jedes Muster einzeln eingeben (z.B. */cache/* oder */backups/*)."
        echo "OHNE Anführungszeichen eintippen - jede Zeile ist ein Muster."
        echo "Leer lassen und Enter drücken, um die Eingabe zu beenden."
        local ignore_index=1
        while true; do
            read -rp "Auszuschließendes Muster $ignore_index (leer = fertig): " current_ignore_pattern
            if [ -z "$current_ignore_pattern" ]; then
                break
            fi
            source_files_dir_ignore_patterns+=("$current_ignore_pattern")
            ignore_index=$((ignore_index + 1))
        done
    fi

    # Muster als sicher gequotetes Bash-Array-Literal aufbereiten
    local source_files_dir_ignore_literal=''
    local single_ignore_pattern
    for single_ignore_pattern in "${source_files_dir_ignore_patterns[@]}"; do
        local escaped_ignore_pattern=${single_ignore_pattern//\'/\'\\\'\'}
        source_files_dir_ignore_literal+=" '$escaped_ignore_pattern'"
    done
    source_files_dir_ignore_literal="${source_files_dir_ignore_literal# }"

    echo
    echo "--- sftp-Übertragung (optional, leer lassen zum Überspringen) ---"
    read -rp "sftp Host: " sftp_host
    local sftp_port=''
    local sftp_user=''
    local sftp_key=''
    local sftp_directory=''
    local sftp_path_to_ssh_binary='/usr/bin/ssh'
    if [ "$sftp_host" != "" ]; then
        read -rp "sftp Port [22]: " sftp_port
        sftp_port=${sftp_port:-22}
        read -rp "sftp User: " sftp_user
        read -rp "Pfad zum privaten SSH-Key [$HOME/.ssh/id_rsa_backup]: " sftp_key
        sftp_key=${sftp_key:-$HOME/.ssh/id_rsa_backup}
        read -rp "sftp Zielverzeichnis (optional): " sftp_directory
        read -rp "Pfad zum lokalen ssh-Binary [/usr/bin/ssh]: " input_sftp_ssh_bin
        sftp_path_to_ssh_binary=${input_sftp_ssh_bin:-/usr/bin/ssh}
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
    echo "--- Healthchecks.io Alarmierung (optional, leer lassen zum Überspringen) ---"
    read -rp "Healthchecks Ping-URL (z.B. https://hc-ping.com/uuid): " input_healthcheck_url
    local healthcheck_url="${input_healthcheck_url:-}"
    if [ -n "$healthcheck_url" ]; then
        echo "Sende Test-Ping an Healthchecks ..."
        send_healthcheck_ping "$healthcheck_url" ""
    fi

    echo
    echo
    echo "--- Aufbewahrungsregeln (Retention / Großvater-Vater-Sohn) ---"
    read -rp "Aufbewahrungsmodus (staffel/tage/aus) [staffel]: " input_retention_mode
    local retention_mode="${input_retention_mode:-staffel}"
    case "$retention_mode" in
        staffel|tage|aus) ;;
        *)
            echo "Ungültiger Aufbewahrungsmodus '$retention_mode'; verwende 'staffel'."
            retention_mode="staffel"
            ;;
    esac
    local keep_daily_days=30
    local keep_weekly_days=90
    local keep_monthly_days=365
    local keep_min_sets=3
    local retention_remote="yes"

    if [ "$retention_mode" = "staffel" ]; then
        read -rp "Tägliche Backups behalten (Tage) [30]: " input_k_daily
        keep_daily_days="$(normalize_nonnegative_integer "${input_k_daily:-30}" 30)"
        read -rp "Wöchentliche Backups danach behalten (bis Tag) [90]: " input_k_weekly
        keep_weekly_days="$(normalize_nonnegative_integer "${input_k_weekly:-90}" 90)"
        read -rp "Monatliche Backups danach behalten (bis Tag, 0=unbegrenzt) [365]: " input_k_monthly
        keep_monthly_days="$(normalize_nonnegative_integer "${input_k_monthly:-365}" 365)"
        read -rp "Mindestanzahl geschützter Backup-Sätze [3]: " input_k_min
        keep_min_sets="$(normalize_nonnegative_integer "${input_k_min:-3}" 3)"
        read -rp "Aufbewahrungsregel auch auf dem Fernziel anwenden? (yes/no) [yes]: " input_ret_remote
        retention_remote="${input_ret_remote:-yes}"
    elif [ "$retention_mode" = "tage" ]; then
        read -rp "Backup-Lebenszeit in Tagen (0 = unendlich) [30]: " input_live_time
        keep_daily_days="$(normalize_nonnegative_integer "${input_live_time:-30}" 30)"
        read -rp "Aufbewahrungsregel auch auf dem Fernziel anwenden? (yes/no) [yes]: " input_ret_remote
        retention_remote="${input_ret_remote:-yes}"
    fi

    read -rp "Lokale Backup-Dateien nach erfolgreicher Übertragung löschen? (true/false) [false]: " delete_if_transmitted
    delete_if_transmitted=${delete_if_transmitted:-false}

    echo
    read -rp "Was soll standardmäßig gesichert werden - alles/db/dateien [alles]: " input_default_scope
    local default_scope
    default_scope="$(normalize_scope "${input_default_scope:-alles}")"
    if [ -z "$default_scope" ]; then
        default_scope="alles"
    fi

    local db_args=()
    for ((i=0; i<${#db_names[@]}; i++)); do
        db_args+=("${db_hosts[$i]}" "${db_names[$i]}" "${db_users[$i]}" "${db_passwords[$i]}")
    done

    if ! write_project_env_file "$target_env_file" "$project_name" "$projekt_basis_dateiname" "$default_scope" "$source_files_dir" "$source_files_dir_ignore_literal" "$delete_if_transmitted" "$sftp_host" "$sftp_port" "$sftp_user" "$sftp_key" "$sftp_directory" "$sftp_path_to_ssh_binary" "$rsync_host" "$rsync_user" "$rsync_directory" "$rsync_key" "$healthcheck_url" "$retention_mode" "$keep_daily_days" "$keep_weekly_days" "$keep_monthly_days" "$keep_min_sets" "$retention_remote" "${db_args[@]}"; then
        echo "FEHLER: Projekt-Konfiguration wurde nicht geschrieben." >&2
        return 1
    fi

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

function refresh_env_files() {
    shopt -s nullglob
    discovered_env_files=("$basename"/.env.*)
    shopt -u nullglob

    env_files=()
    for candidate_env_file in "${discovered_env_files[@]}"; do
        if [ "$(basename "$candidate_env_file")" != ".env.example" ]; then
            env_files+=("$candidate_env_file")
        fi
    done
}

refresh_env_files

# Hilfsfunktion: liest den Projektnamen aus einer .env-Datei-Pfadangabe ab
function project_name_from_env_file() {
    local file="$1"
    local file_basename
    file_basename="$(basename "$file")"
    echo "${file_basename#.env.}"
}

# Datenbank aus einem vorhandenen Backup wiederherstellen
#  parameter1: Pfad zur .env-Datei des Projekts
function run_restore_for_project() {
    local project_env_file="$1"
    local project_name
    project_name="$(project_name_from_env_file "$project_env_file")"

    reset_project_config_variables
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

        reset_project_config_variables
        # shellcheck source=/dev/null
        source "$overview_env_file"

        local overview_db_count="${DB_COUNT:-0}"

        local overview_basis="${PROJEKT_BASIS_DATEINAME:-$overview_project_name}"
        local overview_backup_dir="$basename/$overview_basis/"
        local overview_last_backup='keine Backups vorhanden'
        if [ -d "$overview_backup_dir" ]; then
            local overview_latest_file
            overview_latest_file="$(ls -t "$overview_backup_dir" 2>/dev/null | grep -v '.htaccess' | head -n 1)"
            [ -n "$overview_latest_file" ] && overview_last_backup="$overview_backup_dir$overview_latest_file"
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
        if ! is_valid_project_selection "$size_choice" "${#env_files[@]}"; then
            echo "Ungültige Auswahl." >&2
            return 1
        fi
        size_env_file="${env_files[$((10#$size_choice - 1))]}"
    fi

    if [ -z "$size_env_file" ]; then
        echo "Ungültige Auswahl." >&2
        return 1
    fi

    local size_project_name
    size_project_name="$(project_name_from_env_file "$size_env_file")"

    reset_project_config_variables
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

# Führt umfassende Pre-Backup & Sicherheitsprüfungen für ein Projekt durch
# Prüft WordPress Debug-Status, Debug-Logs, PHP-Logs, Upload-Sicherheit/Webshells und DB-Erreichbarkeit
function run_pre_backup_checks() {
    local project_env_file="$1"
    local log_target="${2:-}"
    local p_name
    p_name="$(project_name_from_env_file "$project_env_file")"

    reset_project_config_variables
    # shellcheck source=/dev/null
    source "$project_env_file"

    local p_basis="${PROJEKT_BASIS_DATEINAME:-$p_name}"
    local p_src="$SOURCE_FILES_DIR"

    local check_ok_count=0
    local check_warn_count=0
    local check_alert_count=0

    echo
    echo "=================================================="
    echo "Pre-Backup & System-Status Check: '$p_name'"
    echo "=================================================="
    if [ -n "$log_target" ] && [ -f "$log_target" ]; then
        echo >> "$log_target"
        echo "==================================================" >> "$log_target"
        echo "Pre-Backup & System-Status Check: '$p_name'" >> "$log_target"
        echo "==================================================" >> "$log_target"
    fi

    # 1. Festplattenspeicher-Prüfung
    if command -v df >/dev/null 2>&1; then
        local available_kb
        available_kb=$(df -Pk "$basename" 2>/dev/null | awk 'NR==2 {print $4}')
        if [ -n "$available_kb" ] && [ "$available_kb" -eq "$available_kb" ] 2>/dev/null; then
            local avail_mb=$((available_kb / 1024))
            if [ "$avail_mb" -lt 500 ]; then
                log_check_item "ALERT" "Speicherplatz kritisch: nur noch ${avail_mb} MB frei auf Ziellaufwerk!" "$log_target" "Festplatte könnte während der Sicherung volllaufen."
                check_alert_count=$((check_alert_count + 1))
            elif [ "$avail_mb" -lt 2048 ]; then
                log_check_item "WARN" "Speicherplatz knapp: ${avail_mb} MB frei auf Ziellaufwerk." "$log_target" "Ausreichend für kleine Backups, bei großen Medienordnern überwachen."
                check_warn_count=$((check_warn_count + 1))
            else
                local avail_gb
                avail_gb=$(awk "BEGIN {printf \"%.1f\", $avail_mb/1024}")
                log_check_item "OK" "Festplattenspeicher ausreichend (${avail_gb} GB frei auf Ziellaufwerk)" "$log_target"
                check_ok_count=$((check_ok_count + 1))
            fi
        fi
    fi

    # 2. Website-Quellordner Prüfung
    if [ -n "$p_src" ]; then
        if [ ! -d "$p_src" ]; then
            log_check_item "ALERT" "Website-Quellordner nicht gefunden: '$p_src'" "$log_target" "Pfad in .env.$p_name existiert nicht."
            check_alert_count=$((check_alert_count + 1))
        elif [ ! -r "$p_src" ]; then
            log_check_item "ALERT" "Website-Quellordner nicht lesbar (fehlende Dateirechte): '$p_src'" "$log_target"
            check_alert_count=$((check_alert_count + 1))
        else
            log_check_item "OK" "Website-Quellordner existiert und ist lesbar: '$p_src'" "$log_target"
            check_ok_count=$((check_ok_count + 1))
        fi
    fi

    # 3. WordPress-Prüfung (falls WordPress vorhanden)
    local wp_config_candidate=""
    if [ -n "$p_src" ] && [ -d "$p_src" ]; then
        for wp_cand in "$p_src/wp-config.php" "$p_src/public_html/wp-config.php" "$p_src/htdocs/wp-config.php" "$p_src/wordpress/wp-config.php" "$(dirname "$p_src")/wp-config.php"; do
            if [ -f "$wp_cand" ]; then
                wp_config_candidate="$wp_cand"
                break
            fi
        done
    fi

    if [ -n "$wp_config_candidate" ] && [ -f "$wp_config_candidate" ]; then
        parse_wp_config_file "$wp_config_candidate"
        local wp_root_dir
        wp_root_dir="$(dirname "$wp_config_candidate")"
        [ ! -d "$wp_root_dir/wp-content" ] && [ -d "$p_src/wp-content" ] && wp_root_dir="$p_src"

        # WordPress Version
        local wp_version_file="$wp_root_dir/wp-includes/version.php"
        local wp_ver=""
        if [ -f "$wp_version_file" ]; then
            wp_ver=$(sed -n "s/^[[:space:]]*\$wp_version[[:space:]]*=[[:space:]]*['\"]\([^'\"]*\)['\"].*/\1/p" "$wp_version_file" 2>/dev/null | head -n 1)
        fi
        log_check_item "INFO" "WordPress erkannt in '$wp_root_dir'${wp_ver:+ (Version: $wp_ver)}" "$log_target"

        # a) WP_DEBUG
        local is_debug="${WP_PARSED_DEBUG:-false}"
        if [ "$is_debug" == "true" ] || [ "$is_debug" == "1" ]; then
            log_check_item "WARN" "WP_DEBUG ist in '$wp_config_candidate' AKTIVIERT (nicht empfohlen für den Produktivbetrieb)" "$log_target" "Vor Updates und im laufenden Betrieb deaktivieren, um Log-Überlauf zu vermeiden."
            check_warn_count=$((check_warn_count + 1))
        else
            log_check_item "OK" "WP_DEBUG ist in '$wp_config_candidate' deaktiviert (Produktionsmodus aktiv)" "$log_target"
            check_ok_count=$((check_ok_count + 1))
        fi

        # b) WP_DEBUG_DISPLAY
        local is_display="${WP_PARSED_DEBUG_DISPLAY:-false}"
        if [ "$is_display" == "true" ] || [ "$is_display" == "1" ]; then
            log_check_item "ALERT" "WP_DEBUG_DISPLAY ist in '$wp_config_candidate' AKTIVIERT!" "$log_target" "PHP-Fehlermeldungen und interne Pfade werden öffentlich im Browser für Besucher angezeigt!"
            check_alert_count=$((check_alert_count + 1))
        else
            log_check_item "OK" "WP_DEBUG_DISPLAY ist in '$wp_config_candidate' deaktiviert (keine Fehlerausgabe an Besucher)" "$log_target"
            check_ok_count=$((check_ok_count + 1))
        fi

        # c) WP_DEBUG_LOG & debug.log Datei
        local is_debug_log="${WP_PARSED_DEBUG_LOG:-false}"
        local debug_log_path="$wp_root_dir/wp-content/debug.log"
        if [ "$is_debug_log" != "false" ] && [ "$is_debug_log" != "0" ] && [ -n "$is_debug_log" ] && [ "$is_debug_log" != "true" ] && [ "$is_debug_log" != "1" ]; then
            debug_log_path="$is_debug_log"
        fi

        if [ -f "$debug_log_path" ]; then
            local dlog_size
            dlog_size=$(du -h "$debug_log_path" 2>/dev/null | awk '{print $1}')
            local dlog_kb
            dlog_kb=$(du -k "$debug_log_path" 2>/dev/null | awk '{print $1}')
            dlog_kb=${dlog_kb:-0}

            if [ "$dlog_kb" -gt 10240 ]; then # > 10 MB
                log_check_item "ALERT" "Debug-Log '$debug_log_path' existiert und ist SEHR GROSS (${dlog_size:-${dlog_kb}KB})!" "$log_target" "Enthält viele akkumulierte PHP-Fehler; sollte vor/nach Updates geprüft und geleert werden."
                check_alert_count=$((check_alert_count + 1))
            else
                log_check_item "WARN" "Debug-Log '$debug_log_path' existiert (${dlog_size:-${dlog_kb}KB})" "$log_target" "Fehlerprotokolle vor Updates kurz sichten."
                check_warn_count=$((check_warn_count + 1))
            fi
        else
            log_check_item "OK" "Keine Debug-Log-Datei ('$debug_log_path') vorhanden (sauber)" "$log_target"
            check_ok_count=$((check_ok_count + 1))
        fi

        # d) PHP error_log Dateien
        local found_error_logs=()
        for elog in "$wp_root_dir/error_log" "$wp_root_dir/wp-admin/error_log" "$wp_root_dir/php_error.log"; do
            if [ -f "$elog" ] && [ -s "$elog" ]; then
                local el_size
                el_size=$(du -h "$elog" 2>/dev/null | awk '{print $1}')
                found_error_logs+=("'$elog' (${el_size})")
            fi
        done
        if [ "${#found_error_logs[@]}" -gt 0 ]; then
            log_check_item "WARN" "PHP error_log Datei(en) gefunden: ${found_error_logs[*]}" "$log_target" "Enthält Server- oder Script-Fehler."
            check_warn_count=$((check_warn_count + 1))
        else
            log_check_item "OK" "Keine PHP error_log Dateien in '$wp_root_dir' gefunden" "$log_target"
            check_ok_count=$((check_ok_count + 1))
        fi

        # e) Wartungsmodus (.maintenance)
        if [ -f "$wp_root_dir/.maintenance" ]; then
            log_check_item "WARN" "Wartungsmodus aktiv: '$wp_root_dir/.maintenance' ist vorhanden!" "$log_target" "Website zeigt aktuell 'Briefly unavailable for scheduled maintenance'."
            check_warn_count=$((check_warn_count + 1))
        else
            log_check_item "OK" "Kein aktiver Wartungsmodus ('$wp_root_dir/.maintenance' nicht vorhanden)" "$log_target"
            check_ok_count=$((check_ok_count + 1))
        fi

        # f) Rudimentärer Sicherheits- / Hack-Check
        # 1. PHP-Dateien im Upload-Ordner
        local uploads_dir="$wp_root_dir/wp-content/uploads"
        if [ -d "$uploads_dir" ]; then
            local raw_susp_php_files=()
            while IFS= read -r f; do
                [ -n "$f" ] && raw_susp_php_files+=("$f")
            done < <(find "$uploads_dir" -maxdepth 5 -type f \( -name "*.php" -o -name "*.phtml" -o -name "*.php5" -o -name "*.php7" -o -name "*.phps" -o -name "*.suspected" \) 2>/dev/null | head -n 30)

            local susp_php_files=()
            local ignored_placeholder_count=0
            for f in "${raw_susp_php_files[@]}"; do
                local f_name
                f_name="$(basename "$f")"
                local f_name_lower
                f_name_lower="$(echo "$f_name" | tr '[:upper:]' '[:lower:]')"
                local f_size
                f_size=$(get_file_size_bytes "$f")

                # Wenn es sich um eine Standard WordPress Platzhalter index.php handelt (<= 350 Bytes)
                # und kein verdächtiger ausführbarer Code / Webshell-Muster darin enthalten ist
                if [ "$f_name_lower" == "index.php" ] && [ "$f_size" -le 350 ]; then
                    if grep -Eq 'Silence is golden' "$f" 2>/dev/null; then
                        ignored_placeholder_count=$((ignored_placeholder_count + 1))
                        continue
                    fi
                    # Falls kein 'Silence is golden', aber nur harmloser Header/Kommentar ohne bösartige Aufrufe
                    if ! grep -Eiq '(eval|assert|base64_decode|gzinflate|system|exec|shell_exec|passthru|\$_POST|\$_GET|\$_REQUEST|\$_COOKIE|file_get_contents|curl_exec|include|require)' "$f" 2>/dev/null; then
                        ignored_placeholder_count=$((ignored_placeholder_count + 1))
                        continue
                    fi
                fi
                susp_php_files+=("$f")
            done

            if [ "${#susp_php_files[@]}" -gt 0 ]; then
                local num_susp=${#susp_php_files[@]}
                local sample_names=""
                for sf in "${susp_php_files[@]:0:3}"; do
                    sample_names+="'$sf', "
                done
                sample_names="${sample_names%, }"
                if [ "$num_susp" -gt 3 ]; then
                    sample_names+=" (und $((num_susp - 3)) weitere)"
                fi
                log_check_item "ALERT" "Verdächtige PHP-Dateien in '$uploads_dir' gefunden (${num_susp} Datei(en): ${sample_names})!" "$log_target" "Uploads sollten keine PHP-Dateien enthalten (Malware / Webshell-Gefahr!)."
                check_alert_count=$((check_alert_count + 1))
            else
                if [ "$ignored_placeholder_count" -gt 0 ]; then
                    log_check_item "OK" "Upload-Ordner ('$uploads_dir') ist frei von verdächtigen PHP-Skripten ($ignored_placeholder_count Standard-Platzhalter index.php ignoriert)" "$log_target"
                else
                    log_check_item "OK" "Upload-Ordner ('$uploads_dir') ist frei von verdächtigen PHP-Skripten" "$log_target"
                fi
                check_ok_count=$((check_ok_count + 1))
            fi
        fi

        # 2. Obfuskierter Code in Kern-Dateien (wp-config.php / index.php)
        local susp_code_found=0
        for core_file in "$wp_config_candidate" "$wp_root_dir/index.php"; do
            if [ -f "$core_file" ]; then
                if grep -Eiq '(eval|assert)[[:space:]]*\([[:space:]]*(base64_decode|gzinflate|gzuncompress|str_rot13|\$_POST|\$_GET|\$_COOKIE|\$_REQUEST)' "$core_file" 2>/dev/null; then
                    log_check_item "ALERT" "Verdächtiges Verschleierungsmuster (eval/base64/assert) in '$core_file' gefunden!" "$log_target" "Hoher Verdacht auf Backdoor / Schadcode."
                    susp_code_found=1
                    check_alert_count=$((check_alert_count + 1))
                fi
            fi
        done
        if [ "$susp_code_found" -eq 0 ]; then
            log_check_item "OK" "Kern-Dateien ('$wp_config_candidate', '$wp_root_dir/index.php') zeigen keine auffälligen Verschleierungsmuster" "$log_target"
            check_ok_count=$((check_ok_count + 1))
        fi

        # 3. Versteckte PHP-Dateien im Webroot
        local hidden_php_files=()
        while IFS= read -r hf; do
            [ -n "$hf" ] && hidden_php_files+=("'$hf'")
        done < <(find "$wp_root_dir" -maxdepth 2 -type f -name ".*.php" 2>/dev/null | head -n 5)
        if [ "${#hidden_php_files[@]}" -gt 0 ]; then
            log_check_item "WARN" "Versteckte PHP-Dateien im Webroot gefunden: ${hidden_php_files[*]}" "$log_target" "Versteckte Skripte sollten auf Legitimität geprüft werden."
            check_warn_count=$((check_warn_count + 1))
        else
            log_check_item "OK" "Keine versteckten PHP-Dateien (.*.php) im Webroot '$wp_root_dir' gefunden" "$log_target"
            check_ok_count=$((check_ok_count + 1))
        fi
    fi

    # 4. Datenbank-Verbindungsprüfung
    local check_db_hosts=()
    local check_db_names=()
    local check_db_users=()
    local check_db_passwords=()
    if [ -n "$DB_COUNT" ]; then
        for ((chk_i=1; chk_i<=DB_COUNT; chk_i++)); do
            local h_var="DB_${chk_i}_HOST"
            local n_var="DB_${chk_i}_NAME"
            local u_var="DB_${chk_i}_USER"
            local p_var="DB_${chk_i}_PASSWORD"
            check_db_hosts+=("${!h_var:-}")
            check_db_names+=("${!n_var:-}")
            check_db_users+=("${!u_var:-}")
            check_db_passwords+=("${!p_var:-}")
        done
    elif [ -n "${DB_NAME:-}" ]; then
        check_db_hosts+=("${DB_HOST:-localhost}")
        check_db_names+=("${DB_NAME:-}")
        check_db_users+=("${DB_USER:-}")
        check_db_passwords+=("${DB_PASSWORD:-}")
    fi

    if [ "${#check_db_names[@]}" -gt 0 ] && command -v mysql >/dev/null 2>&1; then
        for ((chk_d=0; chk_d<${#check_db_names[@]}; chk_d++)); do
            local cur_h="${check_db_hosts[$chk_d]}"
            local cur_n="${check_db_names[$chk_d]}"
            local cur_u="${check_db_users[$chk_d]}"
            local cur_p="${check_db_passwords[$chk_d]}"

            local cur_h_clean="${cur_h%%:*}"
            local cur_port="${cur_h#*:}"
            local cur_port_arg=""
            [ "$cur_port" != "$cur_h" ] && [ -n "$cur_port" ] && cur_port_arg="-P$cur_port"

            local tbl_count
            tbl_count=$(MYSQL_PWD="$cur_p" mysql -h"$cur_h_clean" $cur_port_arg -u"$cur_u" "$cur_n" --connect-timeout=3 -s -N -e "SELECT count(*) FROM information_schema.tables WHERE table_schema = '$cur_n';" 2>/dev/null)
            local mysql_ping_status=$?

            if [ "$mysql_ping_status" -eq 0 ] && [ -n "$tbl_count" ]; then
                log_check_item "OK" "Datenbank '$cur_n' auf '$cur_h' erreichbar ($tbl_count Tabellen vorhanden)" "$log_target"
                check_ok_count=$((check_ok_count + 1))
            else
                log_check_item "ALERT" "Datenbank-Verbindung zu '$cur_n' ($cur_h) FEHLGESCHLAGEN!" "$log_target" "Zugangsdaten in .env prüfen oder MySQL-Server nicht erreichbar."
                check_alert_count=$((check_alert_count + 1))
            fi
        done
    fi

    echo "--------------------------------------------------"
    if [ -n "$log_target" ] && [ -f "$log_target" ]; then
        echo "--------------------------------------------------" >> "$log_target"
    fi

    # Zusammenfassungs-Meldung
    if [ "$check_alert_count" -gt 0 ]; then
        printf "  %bFazit: %d kritische Warnung(en)%b, %d Hinweis(e), %d OK.\n" "${CLR_RED}${CLR_BOLD}" "$check_alert_count" "${CLR_RESET}" "$check_warn_count" "$check_ok_count"
        printf "  %b-> Bitte die rot markierten Punkte vor dem Update oder Backup prüfen!%b\n" "${CLR_RED}" "${CLR_RESET}"
        if [ -n "$log_target" ] && [ -f "$log_target" ]; then
            printf "  Fazit: %d kritische Warnung(en), %d Hinweis(e), %d OK.\n" "$check_alert_count" "$check_warn_count" "$check_ok_count" >> "$log_target"
        fi
    elif [ "$check_warn_count" -gt 0 ]; then
        printf "  %bFazit: %d Hinweis(e)/Warnung(en)%b, %d OK.\n" "${CLR_YELLOW}${CLR_BOLD}" "$check_warn_count" "${CLR_RESET}" "$check_ok_count"
        printf "  %b-> Alles bereit, aber gelbe Hinweise vor Updates beachten.%b\n" "${CLR_YELLOW}" "${CLR_RESET}"
        if [ -n "$log_target" ] && [ -f "$log_target" ]; then
            printf "  Fazit: %d Hinweis(e)/Warnung(en), %d OK.\n" "$check_warn_count" "$check_ok_count" >> "$log_target"
        fi
    else
        printf "  %bFazit: Alle %d Prüfungen bestanden! Alles im grünen Bereich.%b\n" "${CLR_GREEN}${CLR_BOLD}" "$check_ok_count" "${CLR_RESET}"
        if [ -n "$log_target" ] && [ -f "$log_target" ]; then
            printf "  Fazit: Alle %d Prüfungen bestanden! Alles im grünen Bereich.\n" "$check_ok_count" >> "$log_target"
        fi
    fi
    echo "=================================================="
    echo
    if [ -n "$log_target" ] && [ -f "$log_target" ]; then
        echo "==================================================" >> "$log_target"
        echo >> "$log_target"
    fi
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

# Konvertiert eine bestehende Projektkonfiguration auf das Staffel-Prinzip (mit automatischer .bak Sicherung)
function convert_project_env_to_staffel() {
    local env_f="$1"
    [ -f "$env_f" ] || return 1

    local bak_f="${env_f}.bak"
    cp -p "$env_f" "$bak_f"

    local PROJEKT_BASIS_DATEINAME=""
    local RETENTION_MODE=""
    local KEEP_DAILY_DAYS=""
    local KEEP_WEEKLY_DAYS=""
    local KEEP_MONTHLY_DAYS=""
    local KEEP_MIN_SETS=""
    local RETENTION_REMOTE=""

    reset_project_config_variables
    # shellcheck source=/dev/null
    source "$env_f"

    local current_k_daily="${KEEP_DAILY_DAYS:-30}"
    [ "$current_k_daily" -eq 0 ] 2>/dev/null && current_k_daily=30
    local current_k_weekly="${KEEP_WEEKLY_DAYS:-90}"
    local current_k_monthly="${KEEP_MONTHLY_DAYS:-365}"
    local current_k_min="${KEEP_MIN_SETS:-3}"
    local current_ret_remote="${RETENTION_REMOTE:-yes}"

    local tmp_f="${env_f}.tmp.$$"
    grep -vE "^(RETENTION_MODE|KEEP_DAILY_DAYS|KEEP_WEEKLY_DAYS|KEEP_MONTHLY_DAYS|KEEP_MIN_SETS|RETENTION_REMOTE)=" "$env_f" > "$tmp_f" || true

    cat >> "$tmp_f" <<EOF

# Aufbewahrungsregeln (Retention / Großvater-Vater-Sohn)
RETENTION_MODE='staffel'
KEEP_DAILY_DAYS=$current_k_daily
KEEP_WEEKLY_DAYS=$current_k_weekly
KEEP_MONTHLY_DAYS=$current_k_monthly
KEEP_MIN_SETS=$current_k_min
RETENTION_REMOTE='$current_ret_remote'
EOF

    mv "$tmp_f" "$env_f"
    chmod 600 "$env_f" 2>/dev/null || true
    return 0
}

# Zeigt eine tabellarische Vorschau (Dry-Run) der lokalen und entfernten Backup-Sätze eines Projekts an
function show_retention_dry_run() {
    local p_env="$1"
    [ -f "$p_env" ] || return 1

    local p_name
    p_name="$(project_name_from_env_file "$p_env")"

    local PROJEKT_BASIS_DATEINAME=""
    local RETENTION_MODE=""
    local KEEP_DAILY_DAYS=""
    local KEEP_WEEKLY_DAYS=""
    local KEEP_MONTHLY_DAYS=""
    local KEEP_MIN_SETS=""
    local RETENTION_REMOTE="yes"
    local SOURCE_FILES_DIR=""
    local DB_COUNT=""

    reset_project_config_variables
    # shellcheck source=/dev/null
    source "$p_env"

    local p_env_dir
    p_env_dir="$(cd "$(dirname "$p_env")" && pwd)"
    local p_basis="${PROJEKT_BASIS_DATEINAME:-$p_name}"
    local backup_dir="$p_env_dir/$p_basis/"

    local ret_mode="${RETENTION_MODE:-aus}"

    local daily_days="${KEEP_DAILY_DAYS:-30}"
    local weekly_days="${KEEP_WEEKLY_DAYS:-90}"
    local monthly_days="${KEEP_MONTHLY_DAYS:-365}"
    local min_sets="${KEEP_MIN_SETS:-3}"

    local expect_files="false"
    [ -n "$SOURCE_FILES_DIR" ] && expect_files="true"

    local exp_dbs=()
    if [ -n "$DB_COUNT" ] && [ "$DB_COUNT" -gt 0 ] 2>/dev/null; then
        local d_i
        for ((d_i=1; d_i<=DB_COUNT; d_i++)); do
            local d_var="DB_${d_i}_NAME"
            [ -n "${!d_var:-}" ] && exp_dbs+=("${!d_var}")
        done
    fi

    echo "========================================================================================================================"
    echo "Aufbewahrungs-Vorschau (Dry-Run) für Projekt '$p_name' (Basis: $p_basis | Modus: $ret_mode)"
    echo "Regeln: Täglich=$daily_days Tage | Wöchentlich=$weekly_days Tage | Monatlich=$monthly_days Tage | Mindestbestand=$min_sets Sätze"
    echo "========================================================================================================================"

    printf "%-8s | %-19s | %-18s | %-7s | %-10s | %-14s | %-12s | %s\n" "Ort" "Zeitstempel" "Umfang" "Dateien" "Größe" "Status" "Entscheidung" "Grund"
    echo "---------+---------------------+--------------------+---------+------------+----------------+--------------+----------------"

    local local_found=0
    local local_kept=0
    local local_del=0
    local local_freed=0

    # 1. Lokale Sätze
    if [ -d "$backup_dir" ]; then
        RAW_FILES=()
        RAW_SIZES=()
        local f
        for f in "$backup_dir"*; do
            [ -f "$f" ] || continue
            local fname
            fname="$(basename "$f")"
            if parse_backup_filename "$fname" "$p_basis"; then
                RAW_FILES+=("$fname")
                RAW_SIZES+=("$(get_file_size_bytes "$f")")
            fi
        done

        if [ "${#RAW_FILES[@]}" -gt 0 ]; then
            local_found=1
            group_backup_sets "$p_basis" "$expect_files" "${exp_dbs[@]}"
            evaluate_retention_sets "$ret_mode" "$daily_days" "$weekly_days" "$monthly_days" "$min_sets"

            local s_idx
            for ((s_idx=0; s_idx<${#SET_TIMESTAMPS[@]}; s_idx++)); do
                local ts="${SET_TIMESTAMPS[$s_idx]}"
                local dec="${SET_DECISIONS[$s_idx]}"
                local rsn="${SET_REASONS[$s_idx]}"
                local s_bytes="${SET_BYTES[$s_idx]}"
                local s_fcount="${SET_FILES_COUNT[$s_idx]}"
                local s_desc="${SET_SCOPE_DESC[$s_idx]}"
                local s_comp="${SET_IS_COMPLETE[$s_idx]}"
                local comp_str="vollständig"
                [ "$s_comp" != "1" ] && comp_str="unvollständig"

                local color="${CLR_GREEN}"
                [ "$dec" = "LOESCHEN" ] && color="${CLR_YELLOW}"

                printf "%-8s | %-19s | %-18s | %-7s | %-10s | %-14s | %b%-12s%b | %s\n" \
                    "lokal" "$ts" "${s_desc:0:18}" "$s_fcount" "$(format_bytes_human "$s_bytes")" "$comp_str" \
                    "$color" "$dec" "$CLR_RESET" "$rsn"

                if [ "$dec" = "BEHALTEN" ]; then
                    local_kept=$((local_kept + 1))
                else
                    local_del=$((local_del + 1))
                    local_freed=$((local_freed + s_bytes))
                fi
            done
        fi
    fi

    if [ "$local_found" -eq 0 ]; then
        printf "%-8s | %-19s | %-18s | %-7s | %-10s | %-14s | %-12s | %s\n" "lokal" "-" "keine Backups" "0" "0 B" "-" "-" "-"
    fi

    # 2. Remote Sätze (wenn konfiguriert)
    local remote_found=0
    local remote_kept=0
    local remote_del=0
    local remote_freed=0

    if [ "$RETENTION_REMOTE" != "no" ] && [ "$RETENTION_REMOTE" != "false" ]; then
        apply_retention_remote "$p_env" "true" "/dev/null" "false"
        remote_kept="$RETENTION_REMOTE_KEPT"
        remote_del="$RETENTION_REMOTE_DELETED"
        remote_freed="$RETENTION_REMOTE_FREED_BYTES"

        if [ -n "$RETENTION_REMOTE_ERROR" ]; then
            printf "%-8s | %-19s | %-18s | %-7s | %-10s | %-14s | %b%-12s%b | %s\n" "remote" "FEHLER" "$RETENTION_REMOTE_ERROR" "-" "-" "-" "${CLR_RED}" "FEHLER" "$CLR_RESET" "-"
        elif [ "${#SET_TIMESTAMPS[@]}" -gt 0 ]; then
            remote_found=1
            local s_idx
            for ((s_idx=0; s_idx<${#SET_TIMESTAMPS[@]}; s_idx++)); do
                local ts="${SET_TIMESTAMPS[$s_idx]}"
                local dec="${SET_DECISIONS[$s_idx]}"
                local rsn="${SET_REASONS[$s_idx]}"
                local s_bytes="${SET_BYTES[$s_idx]}"
                local s_fcount="${SET_FILES_COUNT[$s_idx]}"
                local s_desc="${SET_SCOPE_DESC[$s_idx]}"
                local s_comp="${SET_IS_COMPLETE[$s_idx]}"
                local comp_str="vollständig"
                [ "$s_comp" != "1" ] && comp_str="unvollständig"

                local color="${CLR_GREEN}"
                [ "$dec" = "LOESCHEN" ] && color="${CLR_YELLOW}"

                printf "%-8s | %-19s | %-18s | %-7s | %-10s | %-14s | %b%-12s%b | %s\n" \
                    "remote" "$ts" "${s_desc:0:18}" "$s_fcount" "$(format_bytes_human "$s_bytes")" "$comp_str" \
                    "$color" "$dec" "$CLR_RESET" "$rsn"
            done
        fi
    fi

    echo "------------------------------------------------------------------------------------------------------------------------"
    echo "Zusammenfassung lokal:  $local_kept Sätze behalten, $local_del Sätze zu löschen ($(format_bytes_human "$local_freed") freizugeben)"
    if [ "$RETENTION_REMOTE" != "no" ] && [ "$RETENTION_REMOTE" != "false" ] && [ -z "$RETENTION_REMOTE_ERROR" ] && [ "$remote_found" -eq 1 ]; then
        echo "Zusammenfassung remote: $remote_kept Sätze behalten, $remote_del Sätze zu löschen ($(format_bytes_human "$remote_freed") freizugeben)"
    elif [ -n "$RETENTION_REMOTE_ERROR" ]; then
        echo "Zusammenfassung remote: Nicht verfügbar ($RETENTION_REMOTE_ERROR)"
    fi
    echo "========================================================================================================================"
    echo
}

# Menüfunktion zur Prüfung und Umstellung der Aufbewahrungsregeln
function manage_project_retention() {
    refresh_env_files
    if [ "${#env_files[@]}" -eq 0 ]; then
        echo "Keine Projekte vorhanden." >&2
        return 0
    fi

    echo "======================================"
    echo "Aufbewahrung prüfen / einstellen (Staffel/GVS)"
    echo "======================================"
    local sel_env=""
    if [ "${#env_files[@]}" -eq 1 ]; then
        sel_env="${env_files[0]}"
    else
        echo "Für welches Projekt soll die Aufbewahrung geprüft/eingestellt werden?"
        local r_idx=1
        local ef
        for ef in "${env_files[@]}"; do
            echo "  $r_idx) $(project_name_from_env_file "$ef")"
            r_idx=$((r_idx + 1))
        done
        echo "  a) alle Projekte"
        echo "  0) Zurück"
        echo "======================================"
        read -rp "Auswahl: " r_choice
        if [ "$r_choice" = "0" ]; then
            return 0
        elif [ "$r_choice" = "a" ]; then
            for ef in "${env_files[@]}"; do
                show_retention_dry_run "$ef"
            done
            echo
            read -rp "Möchten Sie alle Projekte auf das Großvater-Vater-Sohn-Prinzip ('staffel') umstellen? (j/N): " conv_all
            if [[ "$conv_all" =~ ^[jJyY]$ ]]; then
                for ef in "${env_files[@]}"; do
                    convert_project_env_to_staffel "$ef"
                    echo "-> $(project_name_from_env_file "$ef"): erfolgreich auf 'staffel' umgestellt (Backup: ${ef}.bak)"
                done
            fi
            return 0
        elif [ -n "$r_choice" ] && [ "$r_choice" -ge 1 ] 2>/dev/null && [ "$r_choice" -le "${#env_files[@]}" ] 2>/dev/null; then
            sel_env="${env_files[$((r_choice - 1))]}"
        else
            echo "Ungültige Auswahl." >&2
            return 0
        fi
    fi

    if [ -n "$sel_env" ]; then
        show_retention_dry_run "$sel_env"
        local p_name
        p_name="$(project_name_from_env_file "$sel_env")"
        read -rp "Möchten Sie das Projekt '$p_name' auf das Großvater-Vater-Sohn-Prinzip ('staffel') umstellen? (j/N): " conv_one
        if [[ "$conv_one" =~ ^[jJyY]$ ]]; then
            convert_project_env_to_staffel "$sel_env"
            echo "-> Projekt '$p_name' erfolgreich auf 'staffel' umgestellt (Sicherungskopie in ${sel_env}.bak erstellt)."
        fi
    fi
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
        echo "  4) WordPress-Installationen suchen & einrichten"
        echo "  5) Pre-Check & Sicherheitsstatus prüfen"
        echo "  6) Datenbank wiederherstellen"
        echo "  7) Projekt-Datengröße anzeigen"
        echo "  8) Projektübersicht anzeigen"
        echo "  9) Aufbewahrung prüfen / einstellen (Staffel/GVS)"
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
                scan_and_setup_wordpress_sites
                refresh_env_files
                ;;
            5)
                if [ "${#env_files[@]}" -eq 1 ]; then
                    run_pre_backup_checks "${env_files[0]}"
                else
                    echo "======================================"
                    echo "Für welches Projekt sollen die Pre-Checks durchgeführt werden?"
                    local chk_idx=1
                    local existing_env_file
                    for existing_env_file in "${env_files[@]}"; do
                        echo "  $chk_idx) $(project_name_from_env_file "$existing_env_file")"
                        chk_idx=$((chk_idx + 1))
                    done
                    echo "  a) alle Projekte"
                    echo "======================================"
                    read -rp "Projekt auswählen (Nummer oder 'a'): " chk_choice
                    if [ "$chk_choice" == "a" ]; then
                        for existing_env_file in "${env_files[@]}"; do
                            run_pre_backup_checks "$existing_env_file"
                        done
                    elif [ -n "$chk_choice" ] && [ "$chk_choice" -ge 1 ] 2>/dev/null && [ "$chk_choice" -le "${#env_files[@]}" ] 2>/dev/null; then
                        run_pre_backup_checks "${env_files[$((chk_choice - 1))]}"
                    else
                        echo "Ungültige Auswahl." >&2
                    fi
                fi
                ;;
            6)
                restore_mode='true'
                return 0
                ;;
            7)
                show_project_data_size
                ;;
            8)
                show_project_overview
                ;;
            9)
                manage_project_retention
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

# Führt eine umfassende Selbstprüfung eines erzeugten Backups durch
#  parameter1: Pfad zur Backup-Datei
#  parameter2: Typ ("db" oder "files")
#  parameter3: DB-Name (nur bei Typ "db")
#  parameter4: WordPress Tabellen-Präfix (falls vorhanden, z.B. "wp_")
#  parameter5: Pfad zu einem vorherigen Backup (für Größenvergleich)
#  parameter6: Log-Zieldatei
function verify_backup() {
    local target_file="$1"
    local file_type="$2"
    local db_name="${3:-}"
    local wp_prefix="${4:-}"
    local prev_file="${5:-}"
    local log_target="${6:-/dev/null}"

    if [ ! -f "$target_file" ] || [ ! -s "$target_file" ]; then
        echo "FEHLER: Backup-Datei '$target_file' existiert nicht oder ist leer!" | tee -a "$log_target" >&2
        return 2
    fi

    # 1. ZIP-Integrität prüfen
    if [[ "$target_file" == *.zip ]]; then
        if ! unzip -tq "$target_file" >> "$log_target" 2>&1; then
            echo "FEHLER: ZIP-Integritätsprüfung für '$target_file' fehlgeschlagen (unzip -tq)!" | tee -a "$log_target" >&2
            return 2
        fi
    fi

    # 2. Spezifische DB-Dump-Prüfungen
    if [ "$file_type" == "db" ]; then
        local dump_head=""
        local dump_tail=""
        if [[ "$target_file" == *.zip ]]; then
            dump_head=$(unzip -p "$target_file" 2>/dev/null | head -n 40)
            dump_tail=$(unzip -p "$target_file" 2>/dev/null | tail -n 40)
        else
            dump_head=$(head -n 40 "$target_file" 2>/dev/null)
            dump_tail=$(tail -n 40 "$target_file" 2>/dev/null)
        fi

        # mysqldump Kopfzeile prüfen
        if ! echo "$dump_head" | grep -qE -- "(-- MySQL dump|-- MariaDB dump|mysqldump|-- Host:)"; then
            echo "FEHLER: Datenbankdump '$target_file' enthält keine gültige mysqldump-Kopfzeile!" | tee -a "$log_target" >&2
            return 2
        fi

        # Abschlusszeile prüfen
        if ! echo "$dump_tail" | grep -q -- "-- Dump completed"; then
            echo "FEHLER: Datenbankdump '$target_file' ist unvollständig (kein '-- Dump completed' am Ende)!" | tee -a "$log_target" >&2
            return 2
        fi

        # Falls WordPress erkannt: Prüfen auf <prefix>options und <prefix>posts
        if [ -n "$wp_prefix" ]; then
            local has_options=""
            local has_posts=""
            if [[ "$target_file" == *.zip ]]; then
                has_options=$(unzip -p "$target_file" 2>/dev/null | grep -E "(CREATE TABLE|INSERT INTO)[[:space:]]+\`?${wp_prefix}options\`?" | head -n 1)
                has_posts=$(unzip -p "$target_file" 2>/dev/null | grep -E "(CREATE TABLE|INSERT INTO)[[:space:]]+\`?${wp_prefix}posts\`?" | head -n 1)
            else
                has_options=$(grep -E "(CREATE TABLE|INSERT INTO)[[:space:]]+\`?${wp_prefix}options\`?" "$target_file" 2>/dev/null | head -n 1)
                has_posts=$(grep -E "(CREATE TABLE|INSERT INTO)[[:space:]]+\`?${wp_prefix}posts\`?" "$target_file" 2>/dev/null | head -n 1)
            fi

            if [ -z "$has_options" ] || [ -z "$has_posts" ]; then
                echo "FEHLER: WordPress-Tabellen '${wp_prefix}options' oder '${wp_prefix}posts' im Dump '$target_file' nicht gefunden!" | tee -a "$log_target" >&2
                return 2
            fi
        fi
    fi

    # 3. Größenvergleich mit vorherigem Backup desselben Projekts
    if [ -n "$prev_file" ] && [ -f "$prev_file" ]; then
        local curr_size
        local prev_size
        curr_size=$(get_file_size_bytes "$target_file")
        prev_size=$(get_file_size_bytes "$prev_file")

        if [ "$prev_size" -gt 0 ]; then
            local diff_bytes=$(( curr_size > prev_size ? curr_size - prev_size : prev_size - curr_size ))
            local diff_pct=$(( diff_bytes * 100 / prev_size ))
            if [ "$diff_pct" -gt 30 ]; then
                echo "Warnung: Dateigröße von $(basename "$target_file") ($curr_size Bytes) weicht um $diff_pct% vom vorherigen Backup $(basename "$prev_file") ($prev_size Bytes) ab (> 30%)." | tee -a "$log_target" >&2
                return 1
            fi
        fi
    fi

    return 0
}

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
    local run_ts="${5:-${backup_run_timestamp:-$(date +%Y-%m-%d_%H-%M-%S)}}"
    local db_dateiname="$backup_destiantion$projekt_basis_dateiname"'_'"$run_ts"'_'"$db_name"
    local sql_file="$db_dateiname$db_dateiendung"

    created_db_dump_file=""

    # Datenbanken sichern
    if [ "$db_name" != "" ]
    then
        echo "Sichern der Datenbank '$db_name' in Datei $sql_file ..." | tee -a "$log_file_name"
        
        local mysqldump_opts=(
            "--single-transaction"
            "--quick"
            "--routines"
            "--triggers"
            "--skip-lock-tables"
            "--max_allowed_packet=512M"
            "--default-character-set=utf8mb4"
        )

        # Optionale Flags prüfen (MySQL 8 / Cloud DB Kompatibilität)
        local mysqldump_help
        mysqldump_help="$(mysqldump --help 2>&1 || true)"
        if [[ "$mysqldump_help" == *"--column-statistics"* ]]; then
            mysqldump_opts+=("--column-statistics=0")
        fi
        if [[ "$mysqldump_help" == *"--set-gtid-purged"* ]]; then
            mysqldump_opts+=("--set-gtid-purged=OFF")
        fi

        local db_host_clean="${db_host%%:*}"
        local db_port="${db_host#*:}"
        local port_arg=""
        if [ "$db_port" != "$db_host" ] && [ -n "$db_port" ]; then
            port_arg="-P$db_port"
        fi

        MYSQL_PWD="$db_password" mysqldump \
            "${mysqldump_opts[@]}" \
            -h"$db_host_clean" \
            $port_arg \
            -u"$db_user" \
            "$db_name" > "$sql_file" 2>> "$log_file_name"
        local dump_status=$?

        if [ "$dump_status" -ne 0 ] || [ ! -s "$sql_file" ]; then
            echo "FEHLER: mysqldump für '$db_name' auf '$db_host' fehlgeschlagen (Exit-Code: $dump_status)!" | tee -a "$log_file_name" >&2
            rm -f "$sql_file"
            return 2
        fi

        echo "Datenbankdump erfolgreich erstellt: $sql_file" | tee -a "$log_file_name"
        echo

        echo "Nachbearbeiten der Sicherung von $sql_file ..." | tee -a "$log_file_name"
        # DEFINER bereinigen (portabel via temporärer Datei)
        local temp_sql="$sql_file.tmp.$$"
        sed -e 's/DEFINER=[^ *]*@[^ *]*/DEFINER=CURRENT_USER/g' "$sql_file" > "$temp_sql" && mv "$temp_sql" "$sql_file"
        rm -f "$temp_sql"
        echo "erledigt." | tee -a "$log_file_name"
        echo | tee -a "$log_file_name"

        created_db_dump_file="$sql_file"

        # zip
        if ! [ -x "$(command -v zip)" ]; then
            echo 'Warnung: zip ist nicht installiert.' | tee -a "$log_file_name" >&2
            echo "SQL-Datei $sql_file bleibt unkomprimiert erhalten." | tee -a "$log_file_name"
            return_value=1
        else
            local zip_file="$db_dateiname$db_dateiendung$dateiendung_zip"
            echo "ZIP-Datei von Sicherung erstellen $zip_file ..." | tee -a "$log_file_name"
            zip -q "$zip_file" "$sql_file" 2>> "$log_file_name"
            local zip_status=$?

            if [ "$zip_status" -eq 0 ] && [ -s "$zip_file" ]; then
                # sql-datei löschen
                echo "Unkomprimierte Datei löschen $sql_file ..." | tee -a "$log_file_name"
                rm -f "$sql_file"
                created_db_dump_file="$zip_file"
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

    local backup_run_timestamp="${BACKUP_RUN_TIMESTAMP:-$(date +%Y-%m-%d_%H-%M-%S)}"

    local project_started_time
    project_started_time="$(date +"%Y-%m-%d %H:%M:%S")"
    local project_started_s
    project_started_s="$(date +%s)"

    local project_status="ok"
    local project_exitcode=0
    local project_warnings=()
    local project_errors=()

    local created_files_paths=()
    local created_files_types=()
    local created_files_dbnames=()
    local created_files_bytes=()
    local created_files_verified=()

    local transmitted_method=""
    local transmitted_ok="false"
    local local_deleted="false"

    # Alte Werte aus einem zuvor gesicherten Projekt entfernen, damit nichts
    # (insbesondere die Ausschluss-Muster) fälschlich übernommen wird, wenn die
    # aktuelle .env-Datei die Variable nicht selbst setzt.
    reset_project_config_variables

    # .env laden
    # shellcheck source=/dev/null
    source "$project_env_file"

    for retention_var in KEEP_DAILY_DAYS KEEP_WEEKLY_DAYS KEEP_MONTHLY_DAYS KEEP_MIN_SETS; do
        retention_value="${!retention_var:-}"
        if [ -n "$retention_value" ] && ! [[ "$retention_value" =~ ^[0-9]+$ ]]; then
            echo "FEHLER: Aufbewahrungswert '$retention_var=$retention_value' in '$project_env_file' ist ungültig. Bitte die Konfiguration prüfen; fehlerhafte bestehende .env-Dateien werden nicht automatisch repariert." >&2
            overall_exitcode=2
            return 2
        fi
    done

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

    # Datenbanken einlesen (beliebig viele über DB_COUNT / DB_<n>_*)
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
            db_hosts+=("${!host_var:-}")
            db_names+=("${!name_var:-}")
            db_users+=("${!user_var:-}")
            db_passwords+=("${!password_var:-}")
        done
    fi

    source_files_dir="${SOURCE_FILES_DIR:-}"

    # Auszuschließende Muster laden
    source_files_dir_ignore=()
    if declare -p SOURCE_FILES_DIR_IGNORE 2>/dev/null | grep -q '^declare -a'; then
        source_files_dir_ignore=("${SOURCE_FILES_DIR_IGNORE[@]}")
    elif [ -n "${SOURCE_FILES_DIR_IGNORE:-}" ]; then
        local raw_ignore="$SOURCE_FILES_DIR_IGNORE"
        raw_ignore="${raw_ignore#(}"
        raw_ignore="${raw_ignore%)}"
        read -ra source_files_dir_ignore <<< "$raw_ignore"
        local ignore_fix_i
        for ((ignore_fix_i=0; ignore_fix_i<${#source_files_dir_ignore[@]}; ignore_fix_i++)); do
            local ignore_pattern="${source_files_dir_ignore[$ignore_fix_i]}"
            ignore_pattern="${ignore_pattern#\'}"; ignore_pattern="${ignore_pattern%\'}"
            ignore_pattern="${ignore_pattern#\"}"; ignore_pattern="${ignore_pattern%\"}"
            source_files_dir_ignore[$ignore_fix_i]="$ignore_pattern"
        done
    fi

    sftp_host="${SFTP_HOST:-}"
    sftp_port="${SFTP_PORT:-22}"
    sftp_key="${SFTP_KEY:-}"
    sftp_user="${SFTP_USER:-}"
    sftp_directory="${SFTP_DIRECTORY:-}"
    sftp_batchfile="$projekt_basis_dateiname"'_sftp_upload_batchfile'
    sftp_path_to_ssh_binary="${SFTP_PATH_TO_SSH_BINARY:-$(command -v ssh)}"

    rysnc_host="${RSYNC_HOST:-}"
    rsync_user="${RSYNC_USER:-}"
    rsync_directory="${RSYNC_DIRECTORY:-}"
    rsync_key="${RSYNC_KEY:-}"

    delete_if_transmitted="${DELETE_IF_TRANSMITTED:-false}"

    status_email_address="${STATUS_EMAIL_ADDRESS:-}"
    alert_email_address="${ALERT_EMAIL_ADDRESS:-}"
    healthcheck_url="${HEALTHCHECK_URL:-}"

    # Backup Zielordner & Logs sicher anlegen (Webroot-Schutz für Apache 2.4/2.2)
    backup_destiantion="$basename/$projekt_basis_dateiname/"
    ensure_webroot_protection "$backup_destiantion" "deny_all"
    ensure_webroot_protection "$basename/log" "deny_all"
    ensure_webroot_protection "$basename/status" "deny_all"

    # Dateien
    dateien_dateiname="$backup_destiantion$projekt_basis_dateiname"'_'"${backup_run_timestamp}"'_'files
    log_file_name="$basename/log/$projekt_basis_dateiname"'_'"${backup_run_timestamp}"'.log'
    touch "$log_file_name"
    chmod 600 "$log_file_name" 2>/dev/null || true

    # Healthchecks.io Start-Ping senden
    if [ -n "$healthcheck_url" ]; then
        send_healthcheck_ping "$healthcheck_url" "start" "$log_file_name"
    fi

    # Dateiendungen
    dateiendung_zip='.zip'
    db_dateiendung='.sql'

    # Kontrollvariablen
    transmitted=''

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

    # Pre-Backup Prüfungen & Sicherheits-Check ausführen
    run_pre_backup_checks "$project_env_file" "$log_file_name"

    # WordPress-Tabellenpräfix ermitteln (falls WordPress-Ordner vorhanden)
    local wp_table_prefix=""
    if [ -n "$source_files_dir" ] && [ -d "$source_files_dir" ]; then
        local found_wp_config=""
        found_wp_config="$(find_wp_config_in_path "$source_files_dir")"
        if [ -n "$found_wp_config" ] && [ -f "$found_wp_config" ]; then
            parse_wp_config_file "$found_wp_config"
            wp_table_prefix="${WP_PARSED_PREFIX:-wp_}"
        fi
    fi

    # Datenbanken sichern (beliebig viele), nur wenn Umfang alles oder db
    if [ "$run_scope" == "alles" ] || [ "$run_scope" == "db" ]; then
        if [ "${#db_names[@]}" -gt 0 ]; then
            for ((db_backup_i=0; db_backup_i<${#db_names[@]}; db_backup_i++))
            do
                local current_db_name="${db_names[$db_backup_i]}"
                backup_db "${db_hosts[$db_backup_i]}" "$current_db_name" "${db_users[$db_backup_i]}" "${db_passwords[$db_backup_i]}" "$backup_run_timestamp"
                local db_backup_status=$?

                if [ "$db_backup_status" -eq 2 ] || [ -z "$created_db_dump_file" ] || [ ! -f "$created_db_dump_file" ]; then
                    echo "FEHLER: Datenbank '$current_db_name' konnte nicht gesichert werden!" | tee -a "$log_file_name" >&2
                    project_errors+=("Datenbankdump für '$current_db_name' fehlgeschlagen")
                    project_status="fehler"
                    project_exitcode=2
                else
                    if [ "$db_backup_status" -eq 1 ]; then
                        project_warnings+=("Datenbankdump für '$current_db_name' unkomprimiert (zip fehlgeschlagen oder nicht installiert)")
                        [ "$project_exitcode" -lt 1 ] && project_exitcode=1
                        [ "$project_status" == "ok" ] && project_status="warnung"
                    fi

                    # Vorheriges Backup für Größenvergleich ermitteln
                    local prev_db_file=""
                    prev_db_file=$(ls -t "$backup_destiantion"${projekt_basis_dateiname}_*_"${current_db_name}".sql.zip 2>/dev/null | grep -v "$created_db_dump_file" | head -n 1)
                    [ -z "$prev_db_file" ] && prev_db_file=$(ls -t "$backup_destiantion"${projekt_basis_dateiname}_*_"${current_db_name}".sql 2>/dev/null | grep -v "$created_db_dump_file" | head -n 1)

                    # Selbstprüfung des DB-Backups durchführen
                    verify_backup "$created_db_dump_file" "db" "$current_db_name" "$wp_table_prefix" "$prev_db_file" "$log_file_name"
                    local v_db_status=$?
                    local file_bytes
                    file_bytes="$(get_file_size_bytes "$created_db_dump_file")"

                    created_files_paths+=("$created_db_dump_file")
                    created_files_types+=("db")
                    created_files_dbnames+=("$current_db_name")
                    created_files_bytes+=("$file_bytes")

                    if [ "$v_db_status" -eq 0 ]; then
                        created_files_verified+=("true")
                        echo "Selbstprüfung für '$created_db_dump_file': ERFOLGREICH" | tee -a "$log_file_name"
                    elif [ "$v_db_status" -eq 1 ]; then
                        created_files_verified+=("true")
                        echo "Selbstprüfung für '$created_db_dump_file': MIT WARNUNG BESTANDEN" | tee -a "$log_file_name"
                        project_warnings+=("Größenabweichung zu vorherigem Backup bei '$current_db_name' > 30%")
                        [ "$project_exitcode" -lt 1 ] && project_exitcode=1
                        [ "$project_status" == "ok" ] && project_status="warnung"
                    else
                        created_files_verified+=("false")
                        echo "Selbstprüfung für '$created_db_dump_file': FEHLGESCHLAGEN" | tee -a "$log_file_name" >&2
                        project_errors+=("Selbstprüfung für Datenbankdump '$current_db_name' fehlgeschlagen")
                        project_status="fehler"
                        project_exitcode=2
                    fi
                fi
            done
        fi
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
                project_errors+=("Website-Verzeichnis '$source_files_dir' existiert nicht")
                project_status="fehler"
                project_exitcode=2
            elif ! [ -x "$(command -v zip)" ]; then
                echo 'Fehler: zip ist nicht installiert.' | tee -a "$log_file_name" >&2
                echo 'Website-Dateien konnten nicht gesichert werden.' | tee -a "$log_file_name"
                project_errors+=("zip ist nicht installiert, Datei-Sicherung nicht möglich")
                project_status="fehler"
                project_exitcode=2
            else
                local zip_target="$dateien_dateiname$dateiendung_zip"
                echo "ZIP-Datei von Dateien im Website-Verzeichnis ($source_files_dir) erstellen: $zip_target ..." | tee -a "$log_file_name"
                local zip_files_status=0
                if [ "${#source_files_dir_ignore[@]}" -gt "0" ] && [ "${source_files_dir_ignore[0]}" != "" ]
                then
                    echo " ausgeschlossene(r) Ordner: ${source_files_dir_ignore[*]}" | tee -a "$log_file_name"
                    zip -rq -y "$zip_target" "$source_files_dir" -x "${source_files_dir_ignore[@]}" 2>> "$log_file_name"
                    zip_files_status=$?
                else
                    zip -rq -y "$zip_target" "$source_files_dir" 2>> "$log_file_name"
                    zip_files_status=$?
                fi

                if [ "$zip_files_status" -eq 0 ] || [ "$zip_files_status" -eq 12 ]; then
                    echo "erledigt: $zip_target" | tee -a "$log_file_name"

                    # Vorheriges Backup für Größenvergleich ermitteln
                    local prev_files_file=""
                    prev_files_file=$(ls -t "$backup_destiantion"${projekt_basis_dateiname}_*_files.zip 2>/dev/null | grep -v "$zip_target" | head -n 1)

                    # Selbstprüfung des Datei-ZIPs durchführen
                    verify_backup "$zip_target" "files" "" "" "$prev_files_file" "$log_file_name"
                    local v_files_status=$?
                    local files_bytes
                    files_bytes="$(get_file_size_bytes "$zip_target")"

                    created_files_paths+=("$zip_target")
                    created_files_types+=("files")
                    created_files_dbnames+=("")
                    created_files_bytes+=("$files_bytes")

                    if [ "$v_files_status" -eq 0 ]; then
                        created_files_verified+=("true")
                        echo "Selbstprüfung für '$zip_target': ERFOLGREICH" | tee -a "$log_file_name"
                    elif [ "$v_files_status" -eq 1 ]; then
                        created_files_verified+=("true")
                        echo "Selbstprüfung für '$zip_target': MIT WARNUNG BESTANDEN" | tee -a "$log_file_name"
                        project_warnings+=("Größenabweichung zu vorherigem Datei-Backup > 30%")
                        [ "$project_exitcode" -lt 1 ] && project_exitcode=1
                        [ "$project_status" == "ok" ] && project_status="warnung"
                    else
                        created_files_verified+=("false")
                        echo "Selbstprüfung für '$zip_target': FEHLGESCHLAGEN" | tee -a "$log_file_name" >&2
                        project_errors+=("Selbstprüfung für Datei-ZIP fehlgeschlagen")
                        project_status="fehler"
                        project_exitcode=2
                    fi
                else
                    echo "Warnung: zip beendete mit Exit-Code $zip_files_status" | tee -a "$log_file_name" >&2
                    project_errors+=("ZIP-Erstellung für Website-Dateien fehlgeschlagen (Exit-Code: $zip_files_status)")
                    project_status="fehler"
                    project_exitcode=2
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
        transmitted_method="rsync"
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
          transmitted_ok='true'
          echo "rsync-Synchronisation erfolgreich abgeschlossen." | tee -a "$log_file_name"
        else
          transmitted=''
          transmitted_ok='false'
          echo "Fehler bei der rsync-Synchronisation (Status: $rsync_status)" | tee -a "$log_file_name" >&2
          project_warnings+=("rsync-Übertragung fehlgeschlagen (Status: $rsync_status)")
          [ "$project_exitcode" -lt 1 ] && project_exitcode=1
          [ "$project_status" == "ok" ] && project_status="warnung"
        fi
    fi
    echo | tee -a "$log_file_name"

    # Dateien per sftp kopieren sftp
    if [ "$sftp_host" != "" ]
    then
        transmitted_method="sftp"
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
          transmitted_ok='true'
          echo "sftp-Übertragung erfolgreich abgeschlossen." | tee -a "$log_file_name"
        else
          transmitted=''
          transmitted_ok='false'
          echo "Fehler bei der sftp-Übertragung (Status: $sftp_status)" | tee -a "$log_file_name" >&2
          project_warnings+=("sftp-Übertragung fehlgeschlagen (Status: $sftp_status)")
          [ "$project_exitcode" -lt 1 ] && project_exitcode=1
          [ "$project_status" == "ok" ] && project_status="warnung"
        fi

        # Dokumentation in logfile
        echo "sftp batchfile content:" >> "$log_file_name"
        echo "-----" >> "$log_file_name"
        cat "$sftp_batchfile" >> "$log_file_name" 2>/dev/null || true
        echo "-----" >> "$log_file_name"

        # batch file löschen
        rm -f "$sftp_batchfile"
        echo | tee -a "$log_file_name"
    fi

    # Dateien löschen, wenn erfolgreich übermittelt wurde (Prüfung lief vorher)
    if [ "$delete_if_transmitted" == "true" ] && [ "$transmitted" == "true" ] && [ "$transmitted_ok" == "true" ] && [ "$project_exitcode" -lt 2 ]
    then
        echo "Dateien in $backup_destiantion werden nach erfolgreicher Übertragung gelöscht ..." | tee -a "$log_file_name"
        if [ -n "$backup_destiantion" ] && [ -d "$backup_destiantion" ]; then
            find "$backup_destiantion" -maxdepth 1 -type f ! -name '.htaccess' -delete -print | tee -a "$log_file_name"
            local_deleted="true"
        fi
        echo "erledigt." | tee -a "$log_file_name"
        echo | tee -a "$log_file_name"
        echo
    fi

    # Aufbewahrungsregeln (Retention / Großvater-Vater-Sohn) ausführen
    local ret_mode="${RETENTION_MODE:-aus}"

    if [ "$ret_mode" != "staffel" ]; then
        echo "Hinweis: Aufbewahrungsmodus steht auf '$ret_mode'. Die Großvater-Vater-Sohn-Staffelung (RETENTION_MODE='staffel') ist verfügbar." | tee -a "$log_file_name"
        echo | tee -a "$log_file_name"
    fi

    local ret_lokal_behalten=0
    local ret_lokal_geloescht=0
    local ret_lokal_frei_bytes=0
    local ret_remote_behalten=0
    local ret_remote_geloescht=0
    local ret_remote_frei_bytes=0
    local ret_remote_fehler_json="null"

    if [ "$project_exitcode" -ge 2 ] || [ "$project_status" == "fehler" ]; then
        echo "Sicherheitshinweis: Backup-Lauf fehlerhaft (Exit-Code: $project_exitcode) - Aufbewahrungsbereinigung (Retention) wird aus Sicherheitsgründen übersprungen." | tee -a "$log_file_name"
        echo | tee -a "$log_file_name"
    else
        # 1. Lokale Bereinigung (nur wenn DELETE_IF_TRANSMITTED nicht aktiv war)
        if [ "$local_deleted" != "true" ]; then
            echo "Aufbewahrungsbereinigung (Retention: Modus '$ret_mode') für lokale Backups ausführen ..." | tee -a "$log_file_name"
            apply_retention_local "$project_env_file" "false" "$log_file_name" "true"
            ret_lokal_behalten="$RETENTION_LOCAL_KEPT"
            ret_lokal_geloescht="$RETENTION_LOCAL_DELETED"
            ret_lokal_frei_bytes="$RETENTION_LOCAL_FREED_BYTES"
            echo "Lokale Retention abgeschlossen: $ret_lokal_behalten behalten, $ret_lokal_geloescht gelöscht ($(format_bytes_human "$ret_lokal_frei_bytes") freigegeben)." | tee -a "$log_file_name"
            echo | tee -a "$log_file_name"
        fi

        # 2. Remote Bereinigung (falls konfiguriert und RETENTION_REMOTE != 'no')
        if [ -n "$sftp_host" ] || [ -n "$rysnc_host" ]; then
            echo "Aufbewahrungsbereinigung (Retention: Modus '$ret_mode') für entfernte Backups ausführen ..." | tee -a "$log_file_name"
            if ! apply_retention_remote "$project_env_file" "false" "$log_file_name" "true"; then
                project_warnings+=("Remote-Aufbewahrungsbereinigung fehlgeschlagen: $RETENTION_REMOTE_ERROR")
                [ "$project_exitcode" -lt 1 ] && project_exitcode=1
                [ "$project_status" == "ok" ] && project_status="warnung"
                [ -n "$RETENTION_REMOTE_ERROR" ] && ret_remote_fehler_json="\"$(json_escape "$RETENTION_REMOTE_ERROR")\""
            fi
            ret_remote_behalten="$RETENTION_REMOTE_KEPT"
            ret_remote_geloescht="$RETENTION_REMOTE_DELETED"
            ret_remote_frei_bytes="$RETENTION_REMOTE_FREED_BYTES"
            echo "Remote Retention abgeschlossen: $ret_remote_behalten behalten, $ret_remote_geloescht gelöscht ($(format_bytes_human "$ret_remote_frei_bytes") freigegeben)." | tee -a "$log_file_name"
            echo | tee -a "$log_file_name"
        fi
    fi

    local project_ended_time
    project_ended_time="$(date +"%Y-%m-%d %H:%M:%S")"
    local project_ended_s
    project_ended_s="$(date +%s)"
    local project_duration_s=$((project_ended_s - project_started_s))

    # Maschinenlesbaren Status schreiben (<scriptordner>/status/<PROJEKT_BASIS_DATEINAME>.last.json)
    local status_dir="$basename/status"
    ensure_webroot_protection "$status_dir" "deny_all"
    local status_file="$status_dir/${projekt_basis_dateiname}.last.json"

    local dateien_json="["
    local df_first=1
    local df_i
    for ((df_i=0; df_i<${#created_files_paths[@]}; df_i++)); do
        if [ "$df_first" -eq 1 ]; then
            df_first=0
        else
            dateien_json+=", "
        fi
        local f_path="${created_files_paths[$df_i]}"
        local f_typ="${created_files_types[$df_i]}"
        local f_dbname="${created_files_dbnames[$df_i]}"
        local f_bytes="${created_files_bytes[$df_i]}"
        local f_geprueft="${created_files_verified[$df_i]}"

        local db_name_val="null"
        [ -n "$f_dbname" ] && db_name_val="\"$(json_escape "$f_dbname")\""

        dateien_json+="{\"pfad\": \"$(json_escape "$f_path")\", \"typ\": \"$f_typ\", \"db_name\": $db_name_val, \"bytes\": $f_bytes, \"geprueft\": $f_geprueft}"
    done
    dateien_json+="]"

    local warnungen_json
    warnungen_json="$(json_string_array ${project_warnings[@]+"${project_warnings[@]}"})"
    local fehler_json
    fehler_json="$(json_string_array ${project_errors[@]+"${project_errors[@]}"})"

    local uebertragen_methode_val="null"
    [ -n "$transmitted_method" ] && uebertragen_methode_val="\"$transmitted_method\""
    local uebertragen_ok_val="false"
    [ "$transmitted_ok" == "true" ] && uebertragen_ok_val="true"

    local lokal_geloescht_val="false"
    [ "$local_deleted" == "true" ] && lokal_geloescht_val="true"

    local current_project_json
    current_project_json=$(cat <<EOF
{
  "projekt": "$(json_escape "$project_name")",
  "gestartet": "$project_started_time",
  "beendet": "$project_ended_time",
  "dauer_s": $project_duration_s,
  "scope": "$run_scope",
  "status": "$project_status",
  "exitcode": $project_exitcode,
  "dateien": $dateien_json,
  "uebertragen": {
    "methode": $uebertragen_methode_val,
    "ok": $uebertragen_ok_val
  },
  "retention": {
    "modus": "$ret_mode",
    "lokal": {
      "behalten": $ret_lokal_behalten,
      "geloescht": $ret_lokal_geloescht,
      "frei_bytes": $ret_lokal_frei_bytes
    },
    "remote": {
      "behalten": $ret_remote_behalten,
      "geloescht": $ret_remote_geloescht,
      "frei_bytes": $ret_remote_frei_bytes,
      "fehler": $ret_remote_fehler_json
    }
  },
  "lokal_geloescht": $lokal_geloescht_val,
  "warnungen": $warnungen_json,
  "fehler": $fehler_json,
  "logdatei": "$(json_escape "$log_file_name")"
}
EOF
)
    echo "$current_project_json" > "$status_file"
    chmod 600 "$status_file" 2>/dev/null || true

    all_project_json_results+=("$current_project_json")

    local cur_overall="${overall_exitcode:-0}"
    if [ "$project_exitcode" -gt "$cur_overall" ]; then
        overall_exitcode="$project_exitcode"
    fi

    # Healthchecks.io Status-Ping (/<exitcode>) senden
    if [ -n "$healthcheck_url" ]; then
        send_healthcheck_ping "$healthcheck_url" "$project_exitcode" "$log_file_name"
    fi

    echo | tee -a "$log_file_name"
    return "$project_exitcode"
}
# Wenn das Skript nur zur Einbindung von Funktionen (z.B. in Testsuites) gesourct wird, hier stoppen
if [ "$cli_source_only" == "true" ]; then
    return 0 2>/dev/null || exit 0
fi

# Direkter Aufruf via --retention-dry-run CLI-Parameter
if [ "$retention_dry_run" == "true" ]; then
    refresh_env_files
    if [ "${#env_files[@]}" -eq 0 ]; then
        echo "Keine Projekt-Konfiguration (.env.<projektname>) gefunden." >&2
        exit 1
    fi
    if [ "$cli_project" == "alle" ]; then
        for env_f in "${env_files[@]}"; do
            show_retention_dry_run "$env_f"
        done
    elif [ -n "$cli_project" ]; then
        match_env_file="$basename/.env.$cli_project"
        if [ -f "$match_env_file" ]; then
            show_retention_dry_run "$match_env_file"
        else
            echo "Kein Projekt '$cli_project' gefunden." >&2
            exit 1
        fi
    elif [ "${#env_files[@]}" -eq 1 ]; then
        show_retention_dry_run "${env_files[0]}"
    else
        for env_f in "${env_files[@]}"; do
            show_retention_dry_run "$env_f"
        done
    fi
    exit 0
fi

# Direkter Aufruf via --scan-wp CLI-Parameter
if [ "$cli_scan_wp" == "true" ]; then
    scan_and_setup_wordpress_sites "$cli_scan_wp_path"
    exit $?
fi

# Kein Projekt vorhanden -> Setup-Assistent für ein neues Projekt starten
if [ "${#env_files[@]}" -eq 0 ]; then
    if [ -n "$cli_project" ] && [ "$cli_project" != "alle" ]; then
        if [ ! -t 0 ]; then
            echo "Kein Projekt '$cli_project' gefunden; im nicht-interaktiven Modus wird kein Setup-Assistent gestartet." >&2
            exit 2
        fi
        echo "======================================"
        echo "Projekt '$cli_project' existiert noch nicht - Setup-Assistent wird gestartet ..."
        echo "======================================"
        echo
        run_setup_assistant "$cli_project"
        refresh_env_files
    else
        echo "======================================"
        echo "Willkommen beim Backup-Skript!"
        echo "Keine Projekt-Konfiguration (.env.<projektname>) gefunden."
        echo "======================================"
        echo "Wie möchten Sie beginnen?"
        echo "  1) Nach vorhandenen WordPress-Installationen suchen & automatisch einrichten (empfohlen)"
        echo "  2) Manuell ein neues Projekt einrichten"
        echo
        read -rp "Auswahl [1]: " initial_setup_choice
        initial_setup_choice=${initial_setup_choice:-1}

        if [ "$initial_setup_choice" == "1" ]; then
            scan_and_setup_wordpress_sites
            refresh_env_files
            if [ "${#env_files[@]}" -eq 0 ]; then
                echo "Es wurde kein Projekt angelegt. Starte manuellen Setup-Assistenten ..."
                read -rp "Name für das neue Projekt (wird für Dateinamen verwendet, z.B. 'kundeA'): " new_project_name
                new_project_name=${new_project_name// /_}
                new_project_name=${new_project_name:-projekt1}
                run_setup_assistant "$new_project_name"
                refresh_env_files
            fi
        else
            read -rp "Name für das neue Projekt (wird für Dateinamen verwendet, z.B. 'kundeA'): " new_project_name
            new_project_name=${new_project_name// /_}
            new_project_name=${new_project_name:-projekt1}
            run_setup_assistant "$new_project_name"
            refresh_env_files
        fi
    fi
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
        if [ -f "$match_env_file" ]; then
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
        if ! is_valid_project_selection "$project_choice" "${#env_files[@]}"; then
            echo "Ungültige Auswahl." >&2
            exit 1
        fi
        selected_index=$((10#$project_choice - 1))
        restore_target_env_file="${env_files[$selected_index]}"
    fi

    run_restore_for_project "$restore_target_env_file"
    exit $?
fi

# Check-Modus (--check / --pre-check): Pre-Checks & Sicherheitsstatus für Projekt(e) ausführen
if [ "$check_mode" == "true" ]; then
    if [ "$cli_project" == "alle" ]; then
        for chk_env in "${env_files[@]}"; do
            run_pre_backup_checks "$chk_env"
        done
    else
        chk_target_env=''
        if [ -n "$cli_project" ]; then
            match_env_file="$basename/.env.$cli_project"
            if [ -f "$match_env_file" ]; then
                chk_target_env="$match_env_file"
            else
                echo "Kein Projekt '$cli_project' gefunden." >&2
                exit 1
            fi
        elif [ "${#env_files[@]}" -eq 1 ]; then
            chk_target_env="${env_files[0]}"
        else
            echo "======================================"
            echo "Für welches Projekt sollen Pre-Checks durchgeführt werden?"
            project_index=1
            for existing_env_file in "${env_files[@]}"; do
                echo "  $project_index) $(project_name_from_env_file "$existing_env_file")"
                project_index=$((project_index + 1))
            done
            echo "  a) alle Projekte"
            echo "======================================"
            read -rp "Projekt auswählen (Nummer oder 'a' für alle): " chk_choice
            if [ "$chk_choice" == "a" ]; then
                for existing_env_file in "${env_files[@]}"; do
                    run_pre_backup_checks "$existing_env_file"
                done
                exit 0
            else
                if ! is_valid_project_selection "$chk_choice" "${#env_files[@]}"; then
                    echo "Ungültige Auswahl." >&2
                    exit 1
                fi
                selected_index=$((10#$chk_choice - 1))
                chk_target_env="${env_files[$selected_index]}"
            fi
        fi

        [ -n "$chk_target_env" ] && run_pre_backup_checks "$chk_target_env"
    fi
    exit 0
fi

# Projekt(e) auswählen, die in diesem Lauf verarbeitet werden sollen
selected_env_files=()
if [ "$cli_project" == "alle" ]; then
    selected_env_files=("${env_files[@]}")
elif [ -n "$cli_project" ]; then
    match_env_file="$basename/.env.$cli_project"
    if [ -f "$match_env_file" ]; then
        selected_env_files=("$match_env_file")
    else
        if [ ! -t 0 ]; then
            echo "Kein Projekt '$cli_project' gefunden; im nicht-interaktiven Modus wird kein Setup-Assistent gestartet." >&2
            exit 2
        fi
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
        if ! is_valid_project_selection "$project_choice" "${#env_files[@]}"; then
            echo "Ungültige Auswahl." >&2
            exit 1
        fi
        selected_index=$((10#$project_choice - 1))
        selected_env_files=("${env_files[$selected_index]}")
    fi
fi

################################
################################
################################
## Ausgewählte Projekte nacheinander sichern

overall_exitcode=0
all_project_json_results=()

for selected_env_file in "${selected_env_files[@]}"; do
    run_backup_for_project "$selected_env_file"
done

## Vergangene Zeit
after=$(date +%s)
echo "Dauer des gesamten Backup-Vorgangs: " $((after - before)) " Sekunden"
echo

# Falls --json angegeben wurde, geben wir das finale JSON auf stdout aus
if [ "$cli_json" == "true" ]; then
    if [ "${#all_project_json_results[@]}" -eq 1 ] && [ "$cli_project" != "alle" ]; then
        echo "${all_project_json_results[0]}" >&3
    else
        out_json=$'[\n'
        out_first=1
        for res_item in "${all_project_json_results[@]}"; do
            if [ "$out_first" -eq 1 ]; then
                out_first=0
            else
                out_json+=$',\n'
            fi
            out_json+="  $res_item"
        done
        out_json+=$'\n]'
        printf '%s\n' "$out_json" >&3
    fi
fi

exit "$overall_exitcode"
