#!/bin/bash
basename=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
set -o pipefail
umask 077

# Gemeinsame Bibliothek einbinden (falls vorhanden)
if [ -f "$basename/lib_common.sh" ]; then
    # shellcheck source=/dev/null
    source "$basename/lib_common.sh"
fi

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
# Version: 2.1.0
#
# - Dateien einer Website
# - - optional können Dateien ausgeschlossen werden (SOURCE_FILES_DIR_IGNORE)
# - Datenbank(en) einer Website
# - Automatische WordPress-Erkennung & wp-config-Import
# - Automatische Integritäts- und Strukturselbstprüfung (verify_backup)
# - Maschinenlesbare Statusdateien (<scriptordner>/status/<PROJEKT>.last.json)
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
        --help|-h)
            echo "Verwendung: $0 [OPTIONEN]"
            echo
            echo "Optionen:"
            echo "  --project=<name>|alle   Projekt-Konfiguration (.env.<name>), die verwendet werden soll."
            echo "                          'alle' verarbeitet nacheinander alle gefundenen Projekte."
            echo "  --scope=alles|db|dateien Was gesichert werden soll: alles (Standard), db oder dateien."
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
    local b_live_time="$7"
    local del_transmitted="$8"
    local s_host="$9"
    local s_port="${10}"
    local s_user="${11}"
    local s_key="${12}"
    local s_dir="${13}"
    local s_ssh_bin="${14}"
    local r_host="${15}"
    local r_user="${16}"
    local r_dir="${17}"
    local r_key="${18}"
    shift 18
    local dbs=("$@")

    local count=${#dbs[@]}
    local num_dbs=$((count / 4))

    cat > "$target_file" <<EOF
# Zugangsdaten & Konfiguration für Projekt '$proj_name'
# automatisch erstellt am $(date) durch das Backup-Skript
# Diese Datei enthält Zugangsdaten und sollte NICHT ins Git-Repository eingecheckt werden (siehe .gitignore).

PROJECT_NAME='$proj_name'
PROJEKT_BASIS_DATEINAME='$basis_name'

# Was soll standardmäßig gesichert werden, wenn nicht per --scope angegeben: alles / db / dateien
DEFAULT_SCOPE='$def_scope'

# Datenbank-Konfiguration
# Bei mehreren Datenbanken wird DB_COUNT sowie DB_1_*, DB_2_*, etc. verwendet.
DB_COUNT='$num_dbs'
EOF

    local db_idx=1
    for ((i=0; i<count; i+=4)); do
        local h="${dbs[i]}"
        local n="${dbs[i+1]}"
        local u="${dbs[i+2]}"
        local p="${dbs[i+3]}"
        local esc_p=${p//\'/\'\\\'\'}
        cat >> "$target_file" <<EOF
DB_${db_idx}_HOST='$h'
DB_${db_idx}_NAME='$n'
DB_${db_idx}_USER='$u'
DB_${db_idx}_PASSWORD='$esc_p'
EOF
        db_idx=$((db_idx + 1))
    done

    cat >> "$target_file" <<EOF

SOURCE_FILES_DIR='$src_dir'
# Auszuschließende Muster als Bash-Array - je Element ein Muster.
# Beispiel: SOURCE_FILES_DIR_IGNORE=('*/cache/*' '*/backups/*')
SOURCE_FILES_DIR_IGNORE=($ignore_literal)

SFTP_HOST='$s_host'
SFTP_PORT='$s_port'
SFTP_KEY='$s_key'
SFTP_USER='$s_user'
SFTP_DIRECTORY='$s_dir'
SFTP_PATH_TO_SSH_BINARY='${s_ssh_bin:-/usr/bin/ssh}'

RSYNC_HOST='$r_host'
RSYNC_USER='$r_user'
RSYNC_DIRECTORY='$r_dir'
RSYNC_KEY='$r_key'

BACKUP_LIVE_TIME='$b_live_time'
DELETE_IF_TRANSMITTED='$del_transmitted'

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

        read -rp "Backup-Lebenszeit in Tagen (0 = unendlich) [0]: " backup_live_time
        backup_live_time=${backup_live_time:-0}

        local target_env_file="$basename/.env.$project_name"
        write_project_env_file "$target_env_file" "$project_name" "$basis_name" "$default_scope" "$source_files_dir" "$source_files_dir_ignore_literal" "$backup_live_time" "false" "" "" "" "" "" "/usr/bin/ssh" "" "" "" "" "$db_host" "$db_name" "$db_user" "$db_pass"

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
            # Suche nach wp-config.php im Ordner oder gängigen Unterordnern
            local found_wp_config=""
            for wp_candidate in "$source_files_dir/wp-config.php" "$source_files_dir/public_html/wp-config.php" "$source_files_dir/htdocs/wp-config.php" "$source_files_dir/wordpress/wp-config.php" "$source_files_dir/wp/wp-config.php" "$(dirname "$source_files_dir")/wp-config.php"; do
                if [ -f "$wp_candidate" ]; then
                    found_wp_config="$wp_candidate"
                    break
                fi
            done

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

    local db_args=()
    for ((i=0; i<${#db_names[@]}; i++)); do
        db_args+=("${db_hosts[$i]}" "${db_names[$i]}" "${db_users[$i]}" "${db_passwords[$i]}")
    done

    write_project_env_file "$target_env_file" "$project_name" "$projekt_basis_dateiname" "$default_scope" "$source_files_dir" "$source_files_dir_ignore_literal" "$backup_live_time" "$delete_if_transmitted" "$sftp_host" "$sftp_port" "$sftp_user" "$sftp_key" "$sftp_directory" "$sftp_path_to_ssh_binary" "$rsync_host" "$rsync_user" "$rsync_directory" "$rsync_key" "${db_args[@]}"

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

    # Abwärtskompatibilität: eine einzelne alte .env-Datei (ohne Projektnamen) wird als "default"-Projekt behandelt
    legacy_env_file="$basename/.env"
    if [ -f "$legacy_env_file" ]; then
        env_files+=("$legacy_env_file")
    fi
}

refresh_env_files

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

# Führt umfassende Pre-Backup & Sicherheitsprüfungen für ein Projekt durch
# Prüft WordPress Debug-Status, Debug-Logs, PHP-Logs, Upload-Sicherheit/Webshells und DB-Erreichbarkeit
function run_pre_backup_checks() {
    local project_env_file="$1"
    local log_target="${2:-}"
    local p_name
    p_name="$(project_name_from_env_file "$project_env_file")"

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
            local susp_php_files=()
            while IFS= read -r f; do
                [ -n "$f" ] && susp_php_files+=("$f")
            done < <(find "$uploads_dir" -maxdepth 5 -type f \( -name "*.php" -o -name "*.phtml" -o -name "*.php5" -o -name "*.php7" -o -name "*.phps" -o -name "*.suspected" \) 2>/dev/null | head -n 10)

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
                log_check_item "OK" "Upload-Ordner ('$uploads_dir') ist frei von verdächtigen PHP-Skripten" "$log_target"
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
            check_db_hosts+=("${!h_var}")
            check_db_names+=("${!n_var}")
            check_db_users+=("${!u_var}")
            check_db_passwords+=("${!p_var}")
        done
    elif [ -n "$DB_NAME" ]; then
        check_db_hosts+=("${DB_HOST:-localhost}")
        check_db_names+=("$DB_NAME")
        check_db_users+=("$DB_USER")
        check_db_passwords+=("$DB_PASSWORD")
    fi

    if [ "${#check_db_names[@]}" -gt 0 ] && command -v mysql >/dev/null 2>&1; then
        for ((chk_d=0; chk_d<${#check_db_names[@]}; chk_d++)); do
            local cur_h="${check_db_hosts[$chk_d]}"
            local cur_n="${check_db_names[$chk_d]}"
            local cur_u="${check_db_users[$chk_d]}"
            local cur_p="${check_db_passwords[$chk_d]}"

            local cur_h_clean="${cur_h%%:*}"
            local cur_port="${cur_h#*:}"
            local cur_port_arg=()
            [ "$cur_port" != "$cur_h" ] && [ -n "$cur_port" ] && cur_port_arg=("-P$cur_port")

            local tbl_count
            tbl_count=$(MYSQL_PWD="$cur_p" mysql -h"$cur_h_clean" "${cur_port_arg[@]}" -u"$cur_u" "$cur_n" --connect-timeout=3 -s -N -e "SELECT count(*) FROM information_schema.tables WHERE table_schema = '$cur_n';" 2>/dev/null)
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

# Direkter Aufruf via --scan-wp CLI-Parameter
if [ "$cli_scan_wp" == "true" ]; then
    scan_and_setup_wordpress_sites "$cli_scan_wp_path"
    exit $?
fi

# Kein Projekt vorhanden -> Setup-Assistent für ein neues Projekt starten
if [ "${#env_files[@]}" -eq 0 ]; then
    if [ -n "$cli_project" ] && [ "$cli_project" != "alle" ]; then
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
            if [ "$cli_project" == "default" ] && [ -f "$legacy_env_file" ]; then
                chk_target_env="$legacy_env_file"
            elif [ -f "$match_env_file" ]; then
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
                selected_index=$((chk_choice - 1))
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
    local db_dateiname="$backup_destiantion$projekt_basis_dateiname"'_'"$(date +%Y-%m-%d_%H-%M-%S)"'_'"$db_name"
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
        if mysqldump --help 2>&1 | grep -q -- "--column-statistics"; then
            mysqldump_opts+=("--column-statistics=0")
        fi
        if mysqldump --help 2>&1 | grep -q -- "--set-gtid-purged"; then
            mysqldump_opts+=("--set-gtid-purged=OFF")
        fi

        local db_host_clean="${db_host%%:*}"
        local db_port="${db_host#*:}"
        local port_args=()
        if [ "$db_port" != "$db_host" ] && [ -n "$db_port" ]; then
            port_args=("-P$db_port")
        fi

        MYSQL_PWD="$db_password" mysqldump \
            "${mysqldump_opts[@]}" \
            -h"$db_host_clean" \
            "${port_args[@]}" \
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

    # Auszuschließende Muster laden
    source_files_dir_ignore=()
    if declare -p SOURCE_FILES_DIR_IGNORE 2>/dev/null | grep -q '^declare -a'; then
        source_files_dir_ignore=("${SOURCE_FILES_DIR_IGNORE[@]}")
    elif [ -n "$SOURCE_FILES_DIR_IGNORE" ]; then
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
    ensure_webroot_protection "$basename/status" "deny_all"

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
            wp_table_prefix="${WP_PARSED_TABLE_PREFIX:-wp_}"
        fi
    fi

    # Datenbanken sichern (beliebig viele), nur wenn Umfang alles oder db
    if [ "$run_scope" == "alles" ] || [ "$run_scope" == "db" ]; then
        if [ "${#db_names[@]}" -gt 0 ]; then
            for ((db_backup_i=0; db_backup_i<${#db_names[@]}; db_backup_i++))
            do
                local current_db_name="${db_names[$db_backup_i]}"
                backup_db "${db_hosts[$db_backup_i]}" "$current_db_name" "${db_users[$db_backup_i]}" "${db_passwords[$db_backup_i]}"
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
    warnungen_json="$(json_string_array "${project_warnings[@]}")"
    local fehler_json
    fehler_json="$(json_string_array "${project_errors[@]}")"

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

    if [ "$project_exitcode" -gt "$overall_exitcode" ]; then
        overall_exitcode="$project_exitcode"
    fi

    echo | tee -a "$log_file_name"
    return "$project_exitcode"
}

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
        out_json="[\n"
        out_first=1
        for res_item in "${all_project_json_results[@]}"; do
            if [ "$out_first" -eq 1 ]; then
                out_first=0
            else
                out_json+=",\n"
            fi
            out_json+="  $res_item"
        done
        out_json+="\n]"
        printf '%b\n' "$out_json" >&3
    fi
fi

exit "$overall_exitcode"
