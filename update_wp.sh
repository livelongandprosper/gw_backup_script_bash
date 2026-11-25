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
# update_wp.sh - Sicheres WordPress-Update-Skript mit automatischer Prüfung & Rollback
# Version: 1.0.0
#
# Zweck:
#   Führt WordPress Core-, Plugin-, Theme- und Sprachdateien-Updates kontrolliert
#   und sicher durch. Vor jedem Update wird die Website auf Funktionsfähigkeit
#   geprüft, ein Backup erstellt/verifiziert und nach dem Update ein umfassender
#   Post-Check (HTTP-Status, Logfehler, Checksummen) durchgeführt.
#
# Exit-Codes:
#   0 = GRÜN (Alle Updates und Prüfungen erfolgreich)
#   1 = GELB (Updates mit Warnungen, einzelne übersprungen, Antwortzeit verlangsamt)
#   2 = ROT  (Kritischer Fehler, Vorprüfung/Backup/Checksummen fehlgeschlagen)
#   Bei --project=alle gilt der schlechteste Status aller Projekte.
#
# (c) Gregor Wendland 2017-2026 /// free to use, free to change, no warranty
###

################################
################################
################################
## CLI-Parameter einlesen

cli_project=''
cli_dry_run='false'
cli_no_backup='false'
cli_only=''
cli_setup='false'
cli_update_wpcli='false'
cli_json='false'
cli_help='false'

for cli_arg in "$@"; do
    case "$cli_arg" in
        --project=*)
            cli_project="${cli_arg#*=}"
            ;;
        --dry-run)
            cli_dry_run='true'
            ;;
        --no-backup)
            cli_no_backup='true'
            ;;
        --only=*)
            cli_only="${cli_arg#*=}"
            ;;
        --setup)
            cli_setup='true'
            ;;
        --update-wpcli)
            cli_update_wpcli='true'
            ;;
        --json)
            cli_json='true'
            ;;
        --help|-h)
            cli_help='true'
            ;;
        *)
            echo "Unbekannter Parameter '$cli_arg' wird ignoriert (siehe --help)." >&2
            ;;
    esac
done

if [ "$cli_help" == "true" ]; then
    echo "Verwendung: $0 [OPTIONEN]"
    echo
    echo "Optionen:"
    echo "  --project=<name>|alle   Aktualisiert das angegebene Projekt (.update.<name>) oder alle."
    echo "  --dry-run               Prüft verfügbare Updates und Vorbedingungen, ändert nichts."
    echo "  --no-backup             Überspringt das automatische Backup (nutzt letztes Backup aus status/)."
    echo "  --only=<bereich>        Nur bestimmte Updates ausführen: core | plugins | themes | languages"
    echo "  --setup                 Startet den interaktiven Einrichtungsassistenten für .update-Dateien."
    echo "  --update-wpcli          Aktualisiert die lokale WP-CLI (./bin/wp-cli.phar) auf die neueste Version."
    echo "  --json                  Gibt am Ende den Status als JSON auf stdout aus (übrige Ausgabe auf stderr)."
    echo "  --help, -h              Zeigt diesen Hilfetext an."
    echo
    echo "Exit-Codes:"
    echo "  0 = GRÜN (Alles erfolgreich, Prüfungen bestanden)"
    echo "  1 = GELB (Warnungen, einzelne Updates fehlgeschlagen/übersprungen oder Antwortzeit verdoppelt)"
    echo "  2 = ROT  (Kritischer Fehler, Vorprüfung defekt, Checksummen-Fehler oder Fatal Error)"
    echo
    echo "Ohne Parameter im Terminal wird das interaktive Hauptmenü angezeigt."
    exit 0
fi

# Wenn --json aktiv ist, leiten wir alle normalen Ausgaben (stdout) nach stderr um,
# damit stdout sauber für das finale JSON reserviert bleibt.
if [ "$cli_json" == "true" ]; then
    exec 3>&1
    exec 1>&2
fi

################################
################################
################################
## Hilfsfunktionen (JSON, Pfade, Apache-Schutz, Parser)

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

# Erstellt/aktualisiert Apache-Schutzregeln (.htaccess) für Verzeichnisse (Webroot-Sicherheit für Apache 2.4 & 2.2)
function ensure_webroot_protection() {
    local target_dir="$1"
    local mode="${2:-deny_all}" # 'deny_all' für Backup-/Log-/Status-Ordner, 'sensitive_only' für Skript-Wurzelordner

    [ -z "$target_dir" ] && return 0
    mkdir -p "$target_dir" 2>/dev/null || true
    chmod 700 "$target_dir" 2>/dev/null || true

    local htaccess_file="$target_dir/.htaccess"

    if [ "$mode" == "deny_all" ]; then
        # Vollständigen Zugriff via Webserver auf diesen Ordner sperren
        if [ ! -f "$htaccess_file" ] || ! grep -q "Require all denied" "$htaccess_file" 2>/dev/null; then
            cat <<'EOF' > "$htaccess_file"
# Schutz vor direktem HTTP(S)-Zugriff (Webroot-Sicherheit)
<IfModule mod_authz_core.c>
    Require all denied
</IfModule>
<IfModule !mod_authz_core.c>
    Order deny,allow
    Deny from all
</IfModule>
EOF
            chmod 600 "$htaccess_file" 2>/dev/null || true
        fi
    elif [ "$mode" == "sensitive_only" ]; then
        # Nur sensible Dateien (.env, .update, .sh, .log, .json, .lock) im Skript-Wurzelordner sperren
        if [ ! -f "$htaccess_file" ] || ! grep -q "\.env" "$htaccess_file" 2>/dev/null; then
            cat <<'EOF' > "$htaccess_file"
# Schutz für sensible Skript- und Konfigurationsdateien
<FilesMatch "^(\.env|\.update|\.htaccess|.*\.sh|.*\.log|.*\.json|.*\.lock)$">
    <IfModule mod_authz_core.c>
        Require all denied
    </IfModule>
    <IfModule !mod_authz_core.c>
        Order deny,allow
        Deny from all
    </IfModule>
</FilesMatch>
EOF
            chmod 600 "$htaccess_file" 2>/dev/null || true
        fi
    fi
}

# Formatiert und gibt eine Prüfzeile für Pre-Checks / Statusanzeigen aus
# Ausgabe auf dem Terminal farbig (grün / gelb / rot / cyan), in Log-Dateien sauber als Text
function log_check_item() {
    local status="$1"    # "OK", "WARN", "ALERT", "INFO", "GRUEN", "GELB", "ROT"
    local message="$2"
    local log_file="${3:-}"
    local hint="${4:-}"

    local badge_color=""
    local badge_text=""
    case "$status" in
        OK|GRUEN|gruen)
            badge_color="${CLR_GREEN}${CLR_BOLD}"
            badge_text="[  OK  ]"
            ;;
        WARN|GELB|gelb)
            badge_color="${CLR_YELLOW}${CLR_BOLD}"
            badge_text="[ WARN ]"
            ;;
        ALERT|ROT|rot)
            badge_color="${CLR_RED}${CLR_BOLD}"
            badge_text="[ALERT ]"
            ;;
        INFO)
            badge_color="${CLR_CYAN}${CLR_BOLD}"
            badge_text="[ INFO ]"
            ;;
        *)
            badge_color="${CLR_BOLD}"
            badge_text="[ ---- ]"
            ;;
    esac

    printf "  %b%s%b %s\n" "$badge_color" "$badge_text" "$CLR_RESET" "$message"
    if [ -n "$hint" ]; then
        printf "         %b-> Hinweis: %s%b\n" "${CLR_GRAY}" "$hint" "${CLR_RESET}"
    fi

    if [ -n "$log_file" ] && [ -f "$log_file" ]; then
        printf "  %s %s\n" "$badge_text" "$message" >> "$log_file"
        if [ -n "$hint" ]; then
            printf "         -> Hinweis: %s\n" "$hint" >> "$log_file"
        fi
    fi
}

# Prüft den freien Festplattenspeicher und warnt bei Knappheit (< 500 MB)
function check_disk_space() {
    local target_dir="$1"
    local log_target="${2:-/dev/null}"

    [ -d "$target_dir" ] || target_dir="."
    local avail_kb
    avail_kb=$(df -k "$target_dir" 2>/dev/null | awk 'NR>1 {print $(NF-2)}')

    if [ -n "$avail_kb" ] && [ "$avail_kb" -gt 0 ] 2>/dev/null; then
        local avail_mb=$((avail_kb / 1024))
        if [ "$avail_mb" -lt 500 ]; then
            log_check_item "WARN" "Geringer freier Speicherplatz auf Ziellaufwerk ($avail_mb MB verbleibend)" "$log_target" "Festplattenspeicher bereinigen, um Abbrüche bei großen Backups/Updates zu vermeiden."
            return 1
        else
            log_check_item "OK" "Festplattenspeicher ausreichend ($avail_mb MB frei auf $(df -h "$target_dir" 2>/dev/null | awk 'NR>1 {print $NF}' | head -n 1))" "$log_target"
            return 0
        fi
    fi
    return 0
}

# Löst relative Pfade (relativ zu $basename) oder absolute Pfade inklusive ~ auf
function resolve_dir_path() {
    local input_path="$1"
    local base_ref="${2:-$basename}"

    # ~ zu $HOME auflösen
    if [[ "$input_path" == "~"* ]]; then
        input_path="${HOME}${input_path:1}"
    fi

    if [[ "$input_path" == /* ]]; then
        # Absoluter Pfad
        echo "$input_path"
    else
        # Relativer Pfad: relativ zum Skript-Verzeichnis auflösen
        local resolved_abs
        resolved_abs="$(cd "$base_ref/$input_path" 2>/dev/null && pwd)"
        if [ -n "$resolved_abs" ]; then
            echo "$resolved_abs"
        else
            echo "$base_ref/$input_path"
        fi
    fi
}

# Regex-Fallback zum Auslesen von Konstanten aus wp-config.php via sed (POSIX-kompatibel)
function extract_wp_constant_sed() {
    local file="$1"
    local const_name="$2"
    sed -n -E "s/^[[:space:]]*define[[:space:]]*\([[:space:]]*['\"]${const_name}['\"][[:space:]]*,[[:space:]]*['\"]([^'\"]*)['\"][[:space:]]*\).*/\1/p" "$file" 2>/dev/null | head -n 1
}

# Liest Datenbank-, Website- und Debug-Parameter aus einer wp-config.php aus
function parse_wp_config_file() {
    local wp_config_file="$1"
    [ -f "$wp_config_file" ] || return 1

    WP_PARSED_DB_NAME=""
    WP_PARSED_DB_USER=""
    WP_PARSED_DB_PASSWORD=""
    WP_PARSED_DB_HOST=""
    WP_PARSED_TABLE_PREFIX=""
    WP_PARSED_HOME=""
    WP_PARSED_SITEURL=""
    WP_PARSED_WP_DEBUG=""
    WP_PARSED_WP_DEBUG_LOG=""

    if command -v php >/dev/null 2>&1; then
        local php_parser_script='
            $file = $argv[1] ?? "";
            if (!file_exists($file)) exit(1);
            $content = file_get_contents($file);
            $tokens = token_get_all($content);
            $defines = [];
            $table_prefix = "wp_";

            $count = count($tokens);
            for ($i = 0; $i < $count; $i++) {
                $t = $tokens[$i];
                if (is_array($t) && $t[0] === T_STRING && strtolower($t[1]) === "define") {
                    $j = $i + 1;
                    while ($j < $count && (is_array($tokens[$j]) && ($tokens[$j][0] === T_WHITESPACE || $tokens[$j][0] === T_COMMENT || $tokens[$j][0] === T_DOC_COMMENT) || $tokens[$j] === "(")) {
                        $j++;
                    }
                    $const_name = null;
                    if ($j < $count && is_array($tokens[$j]) && $tokens[$j][0] === T_CONSTANT_ENCAPSED_STRING) {
                        $const_name = trim($tokens[$j][1], "\x22\x27");
                    }
                    if ($const_name) {
                        while ($j < $count && $tokens[$j] !== ",") {
                            $j++;
                        }
                        $j++;
                        while ($j < $count && is_array($tokens[$j]) && ($tokens[$j][0] === T_WHITESPACE || $tokens[$j][0] === T_COMMENT || $tokens[$j][0] === T_DOC_COMMENT)) {
                            $j++;
                        }
                        if ($j < $count) {
                            $val = $tokens[$j];
                            if (is_array($val)) {
                                if ($val[0] === T_CONSTANT_ENCAPSED_STRING) {
                                    $defines[$const_name] = trim($val[1], "\x22\x27");
                                } elseif ($val[0] === T_STRING) {
                                    $defines[$const_name] = (strtolower($val[1]) === "true") ? "true" : ((strtolower($val[1]) === "false") ? "false" : $val[1]);
                                }
                            }
                        }
                    }
                }
                if (is_array($t) && $t[0] === T_VARIABLE && $t[1] === "$table_prefix") {
                    $j = $i + 1;
                    while ($j < $count && ($tokens[$j] === "=" || (is_array($tokens[$j]) && $tokens[$j][0] === T_WHITESPACE))) {
                        $j++;
                    }
                    if ($j < $count && is_array($tokens[$j]) && $tokens[$j][0] === T_CONSTANT_ENCAPSED_STRING) {
                        $table_prefix = trim($tokens[$j][1], "\x22\x27");
                    }
                }
            }

            echo "DB_NAME=" . ($defines["DB_NAME"] ?? "") . "\n";
            echo "DB_USER=" . ($defines["DB_USER"] ?? "") . "\n";
            echo "DB_PASSWORD=" . ($defines["DB_PASSWORD"] ?? "") . "\n";
            echo "DB_HOST=" . ($defines["DB_HOST"] ?? "") . "\n";
            echo "TABLE_PREFIX=" . $table_prefix . "\n";
            echo "WP_HOME=" . ($defines["WP_HOME"] ?? "") . "\n";
            echo "WP_SITEURL=" . ($defines["WP_SITEURL"] ?? "") . "\n";
            echo "WP_DEBUG=" . ($defines["WP_DEBUG"] ?? "") . "\n";
            echo "WP_DEBUG_LOG=" . ($defines["WP_DEBUG_LOG"] ?? "") . "\n";
        '

        local parsed_output
        parsed_output=$(php -r "$php_parser_script" "$wp_config_file" 2>/dev/null)
        if [ -n "$parsed_output" ]; then
            while IFS='=' read -r key val; do
                case "$key" in
                    DB_NAME) WP_PARSED_DB_NAME="$val" ;;
                    DB_USER) WP_PARSED_DB_USER="$val" ;;
                    DB_PASSWORD) WP_PARSED_DB_PASSWORD="$val" ;;
                    DB_HOST) WP_PARSED_DB_HOST="$val" ;;
                    TABLE_PREFIX) WP_PARSED_TABLE_PREFIX="$val" ;;
                    WP_HOME) WP_PARSED_HOME="$val" ;;
                    WP_SITEURL) WP_PARSED_SITEURL="$val" ;;
                    WP_DEBUG) WP_PARSED_WP_DEBUG="$val" ;;
                    WP_DEBUG_LOG) WP_PARSED_WP_DEBUG_LOG="$val" ;;
                esac
            done <<< "$parsed_output"
        fi
    fi

    # Fallback via sed, falls PHP nicht verfügbar ist oder Werte fehlen
    [ -z "$WP_PARSED_DB_NAME" ] && WP_PARSED_DB_NAME="$(extract_wp_constant_sed "$wp_config_file" "DB_NAME")"
    [ -z "$WP_PARSED_DB_USER" ] && WP_PARSED_DB_USER="$(extract_wp_constant_sed "$wp_config_file" "DB_USER")"
    [ -z "$WP_PARSED_DB_PASSWORD" ] && WP_PARSED_DB_PASSWORD="$(extract_wp_constant_sed "$wp_config_file" "DB_PASSWORD")"
    [ -z "$WP_PARSED_DB_HOST" ] && WP_PARSED_DB_HOST="$(extract_wp_constant_sed "$wp_config_file" "DB_HOST")"
    [ -z "$WP_PARSED_HOME" ] && WP_PARSED_HOME="$(extract_wp_constant_sed "$wp_config_file" "WP_HOME")"
    [ -z "$WP_PARSED_SITEURL" ] && WP_PARSED_SITEURL="$(extract_wp_constant_sed "$wp_config_file" "WP_SITEURL")"

    if [ -z "$WP_PARSED_TABLE_PREFIX" ]; then
        WP_PARSED_TABLE_PREFIX=$(sed -n -E 's/^[[:space:]]*\$table_prefix[[:space:]]*=[[:space:]]*['\''"]([^'\''"]*)['\''"][[:space:]]*;.*/\1/p' "$wp_config_file" 2>/dev/null | head -n 1)
        WP_PARSED_TABLE_PREFIX=${WP_PARSED_TABLE_PREFIX:-wp_}
    fi

    return 0
}

# Sucht in einem Ordner oder übergeordneten Ordnern nach wp-config.php
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
        "$(dirname "$base_dir")/wp-config.php"
    )

    for cand in "${candidates[@]}"; do
        if [ -f "$cand" ]; then
            echo "$cand"
            return 0
        fi
    done
    return 1
}

# Erstellt einen sauberen Namensvorschlag für das Projekt anhand URL / Blogname / Ordnername
function suggest_project_name_from_wp() {
    local wp_dir="$1"
    local site_url="${2:-$WP_PARSED_HOME}"

    local raw_name=""
    if [ -n "$site_url" ]; then
        raw_name="${site_url#*://}"
        raw_name="${raw_name%%/*}"
        raw_name="${raw_name#www.}"
        raw_name="${raw_name//[:.]/_}"
    fi

    if [ -z "$raw_name" ]; then
        raw_name="$(basename "$(cd "$wp_dir" 2>/dev/null && pwd)")"
        if [ "$raw_name" == "htdocs" ] || [ "$raw_name" == "public_html" ] || [ "$raw_name" == "web" ] || [ "$raw_name" == "wordpress" ] || [ "$raw_name" == "wp" ]; then
            local parent_dir
            parent_dir="$(basename "$(cd "$wp_dir/.." 2>/dev/null && pwd)")"
            [ -n "$parent_dir" ] && [ "$parent_dir" != "/" ] && raw_name="$parent_dir"
        fi
    fi

    # Bereinigung: nur Kleinbuchstaben, Zahlen, Bindestriche und Unterstriche
    raw_name=$(echo "$raw_name" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9_-' '_')
    raw_name="${raw_name#_}"
    raw_name="${raw_name%_}"
    echo "${raw_name:-projekt}"
}

# Hilfsfunktion: liest den Projektnamen aus einer .env-Datei-Pfadangabe ab
function project_name_from_env_file() {
    local file="$1"
    local legacy_env="${2:-$basename/.env}"
    if [ "$file" == "$legacy_env" ]; then
        echo "default"
    else
        local file_basename
        file_basename="$(basename "$file")"
        echo "${file_basename#.env.}"
    fi
}

# Projekt-Konfigurationsdateien des Backup-Skripts ermitteln
function refresh_env_files() {
    local script_dir="${1:-$basename}"
    shopt -s nullglob
    local discovered_env_files=("$script_dir"/.env.*)
    shopt -u nullglob

    env_files=()
    for candidate_env_file in "${discovered_env_files[@]}"; do
        local bname
        bname="$(basename "$candidate_env_file")"
        if [ "$bname" != ".env.example" ] && [ "$bname" != ".env.sample" ]; then
            env_files+=("$candidate_env_file")
        fi
    done

    # Abwärtskompatibilität: eine einzelne alte .env-Datei (ohne Projektnamen) wird als "default"-Projekt behandelt
    legacy_env_file="$script_dir/.env"
    if [ -f "$legacy_env_file" ]; then
        env_files+=("$legacy_env_file")
    fi
}

################################
################################
################################
## WP-CLI und Umgebung prüfen / installieren

WP_CLI_BIN=""

function check_required_tools() {
    local missing_tools=()
    local t
    for t in grep sed awk find unzip; do
        if ! command -v "$t" >/dev/null 2>&1; then
            missing_tools+=("$t")
        fi
    done

    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        missing_tools+=("curl/wget")
    fi

    if [ "${#missing_tools[@]}" -gt 0 ]; then
        echo "FEHLER: Erforderliche Standard-Tools fehlen: ${missing_tools[*]}" >&2
        return 1
    fi
    return 0
}

function check_php_cli() {
    if ! command -v php >/dev/null 2>&1; then
        echo "FEHLER: PHP-CLI ('php') wurde nicht gefunden. WP-CLI benötigt PHP." >&2
        return 1
    fi

    local php_version
    php_version=$(php -r 'echo PHP_VERSION;' 2>/dev/null)
    local php_major
    php_major=$(echo "$php_version" | cut -d. -f1)
    local php_minor
    php_minor=$(echo "$php_version" | cut -d. -f2)

    if [ -z "$php_version" ] || [ "$php_major" -lt 7 ] || { [ "$php_major" -eq 7 ] && [ "$php_minor" -lt 4 ]; }; then
        echo "WARNUNG: PHP-Version ist '$php_version'. WP-CLI empfiehlt mindestens PHP 7.4 oder höher." >&2
    fi
    return 0
}

function ensure_wp_cli() {
    local force_update="${1:-false}"

    # 1. Systemweites wp im PATH prüfen (außer bei force_update)
    if [ "$force_update" != "true" ] && command -v wp >/dev/null 2>&1; then
        if wp --info >/dev/null 2>&1; then
            WP_CLI_BIN="wp"
            return 0
        fi
    fi

    local bin_dir="$basename/bin"
    ensure_webroot_protection "$bin_dir" "deny_all"

    local local_phar="$bin_dir/wp-cli.phar"
    local sha_file="$bin_dir/wp-cli.phar.sha512"
    local phar_url="https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar"
    local sha_url="https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar.sha512"

    if [ "$force_update" == "true" ] || [ ! -f "$local_phar" ] || [ ! -s "$local_phar" ]; then
        echo "Lade WP-CLI von $phar_url herunter ..."
        if command -v curl >/dev/null 2>&1; then
            curl -s -S -L -o "$local_phar" "$phar_url"
            curl -s -S -L -o "$sha_file" "$sha_url"
        elif command -v wget >/dev/null 2>&1; then
            wget -q -O "$local_phar" "$phar_url"
            wget -q -O "$sha_file" "$sha_url"
        else
            echo "FEHLER: Weder curl noch wget verfügbar zum Download von WP-CLI." >&2
            return 1
        fi

        if [ -f "$sha_file" ] && [ -s "$sha_file" ]; then
            echo "Prüfe SHA-512 Prüfsumme von WP-CLI ..."
            local expected_hash
            expected_hash=$(awk '{print $1}' "$sha_file" | head -n 1)
            local actual_hash=""

            if command -v sha512sum >/dev/null 2>&1; then
                actual_hash=$(sha512sum "$local_phar" 2>/dev/null | awk '{print $1}')
            elif command -v shasum >/dev/null 2>&1; then
                actual_hash=$(shasum -a 512 "$local_phar" 2>/dev/null | awk '{print $1}')
            elif command -v openssl >/dev/null 2>&1; then
                actual_hash=$(openssl dgst -sha512 "$local_phar" 2>/dev/null | awk '{print $NF}')
            elif command -v php >/dev/null 2>&1; then
                actual_hash=$(php -r 'echo hash_file("sha512", $argv[1]);' "$local_phar" 2>/dev/null)
            fi

            if [ -n "$expected_hash" ] && [ -n "$actual_hash" ] && [ "$expected_hash" != "$actual_hash" ]; then
                echo "FEHLER: SHA-512 Prüfsumme von WP-CLI stimmt nicht überein! Download beschädigt." >&2
                rm -f "$local_phar" "$sha_file"
                return 1
            fi
            echo "SHA-512 Prüfsumme verifiziert."
        fi

        chmod 700 "$local_phar" 2>/dev/null || chmod +x "$local_phar" 2>/dev/null || true
    fi

    if [ -f "$local_phar" ]; then
        if php "$local_phar" --info >/dev/null 2>&1; then
            WP_CLI_BIN="php $local_phar"
            return 0
        fi
    fi

    echo "FEHLER: WP-CLI konnte nicht gestartet werden." >&2
    return 1
}

# Führt einen WP-CLI Befehl aus
function run_wp() {
    if [ -z "$WP_CLI_BIN" ]; then
        ensure_wp_cli || return 1
    fi
    $WP_CLI_BIN "$@"
}

################################
################################
################################
## Konfigurationsdateien verwalten

function refresh_update_configs() {
    shopt -s nullglob
    local discovered_update_files=("$basename"/.update.*)
    shopt -u nullglob

    update_files=()
    for candidate_file in "${discovered_update_files[@]}"; do
        local bname
        bname="$(basename "$candidate_file")"
        if [ "$bname" != ".update.example" ] && [ "$bname" != ".update.sample" ] && [[ "$bname" != *.lock ]]; then
            update_files+=("$candidate_file")
        fi
    done
}

function project_name_from_update_file() {
    local file="$1"
    local file_basename
    file_basename="$(basename "$file")"
    echo "${file_basename#.update.}"
}

# Schreibt eine .update.<projektname> Konfigurationsdatei
function write_project_update_file() {
    local target_file="$1"
    local p_name="$2"
    local wp_path="$3"
    local site_url="$4"
    local must_contain="$5"
    local check_paths="$6"
    local skip_plugins="$7"
    local max_age="${8:-60}"
    local backup_first="${9:-yes}"

    cat <<EOF > "$target_file"
# update_wp.sh Konfigurationsdatei für Projekt '$p_name'
# Automatisch angelegt am $(date +"%Y-%m-%d %H:%M:%S")

# Absoluter oder relativer Pfad zum WordPress-Wurzelverzeichnis
WP_PATH="$wp_path"

# Öffentliche URL der Website (für HTTP-Prüfungen)
SITE_URL="$site_url"

# Text / Schlagwort, das auf der Startseite zwingend vorhanden sein muss (z. B. Blogname / Firmentitel)
MUST_CONTAIN="$must_contain"

# Pfade, die vor und nach dem Update per HTTP geprüft werden müssen (durch Leerzeichen getrennt)
CHECK_PATHS="$check_paths"

# Plugins, die beim automatischen Update ausgeschlossen werden sollen (z. B. kommerzielle Plugins)
SKIP_PLUGINS="$skip_plugins"

# Maximales Alter eines vorhandenen Backups in Minuten, falls kein neues erstellt wird (Standard: 60)
BACKUP_MAX_AGE_MIN="$max_age"

# Vor dem Update automatisch ein vollständiges Backup via backup_full_db_files_zip.sh ausführen (yes/no)
RUN_BACKUP_FIRST="$backup_first"
EOF
    chmod 600 "$target_file" 2>/dev/null || true
}

# Interaktiver Setup-Assistent
function run_setup_wizard() {
    echo "======================================"
    echo "update_wp.sh - Einrichtungsassistent"
    echo "======================================"
    echo

    check_required_tools || return 1
    check_php_cli || return 1
    ensure_wp_cli || return 1

    # Webroot-Schutz für update-runs und bin sicherstellen
    ensure_webroot_protection "$basename/update-runs" "deny_all"
    ensure_webroot_protection "$basename/bin" "deny_all"
    ensure_webroot_protection "$basename/status" "deny_all"

    # Hinweis für Nginx-Umgebungen ausgeben
    echo "Hinweis zur Webroot-Sicherheit:"
    echo "  .htaccess-Schutzregeln wurden für Apache eingerichtet."
    echo "  Bei Nginx bitte sicherstellen, dass Verzeichnisse wie './bin/',"
    echo "  './update-runs/', './status/' und Dateien wie '.update.*' sowie '.env.*'"
    echo "  über die Nginx-Konfiguration ('deny all;') vor Webzugriff geschützt sind."
    echo

    refresh_env_files "$basename"
    local available_projects=()

    for ef in "${env_files[@]}"; do
        local p
        p="$(project_name_from_env_file "$ef")"
        [ "$p" != "default" ] && available_projects+=("$p")
    done

    if [ "${#available_projects[@]}" -eq 0 ]; then
        echo "Keine vorhandenen .env.<projekt>-Dateien gefunden."
        read -rp "Name des Projekts (z. B. 'kundeA'): " manual_project_name
        manual_project_name="${manual_project_name// /_}"
        [ -n "$manual_project_name" ] && available_projects+=("$manual_project_name")
    fi

    local configured_count=0
    for proj in "${available_projects[@]}"; do
        local update_cfg="$basename/.update.$proj"
        local env_cfg="$basename/.env.$proj"
        echo "--------------------------------------------------"
        echo "Konfiguration für Projekt: '$proj'"
        echo "--------------------------------------------------"

        local current_wp_path=""
        local current_site_url=""
        local current_must_contain=""
        local current_check_paths="/ /kontakt/ /impressum/"
        local current_skip_plugins=""
        local current_max_age="60"
        local current_backup_first="yes"

        # Falls .env vorhanden, SOURCE_FILES_DIR als Pfadvorschlag laden
        if [ -f "$env_cfg" ]; then
            # shellcheck source=/dev/null
            source "$env_cfg"
            current_wp_path="${SOURCE_FILES_DIR:-}"
        fi

        # Falls .update bereits existiert, bestehende Werte laden
        if [ -f "$update_cfg" ]; then
            # shellcheck source=/dev/null
            source "$update_cfg"
            current_wp_path="${WP_PATH:-$current_wp_path}"
            current_site_url="${SITE_URL:-$current_site_url}"
            current_must_contain="${MUST_CONTAIN:-$current_must_contain}"
            current_check_paths="${CHECK_PATHS:-$current_check_paths}"
            current_skip_plugins="${SKIP_PLUGINS:-$current_skip_plugins}"
            current_max_age="${BACKUP_MAX_AGE_MIN:-$current_max_age}"
            current_backup_first="${RUN_BACKUP_FIRST:-$current_backup_first}"
        fi

        read -rp "WordPress-Pfad (WP_PATH) [${current_wp_path:-../$proj}]: " in_wp_path
        current_wp_path="${in_wp_path:-${current_wp_path:-../$proj}}"
        current_wp_path="$(resolve_dir_path "$current_wp_path" "$basename")"

        # Falls WordPress-Pfad existiert, Werte per WP-CLI / wp-config ermitteln
        if [ -d "$current_wp_path" ]; then
            local detected_siteurl=""
            local detected_blogname=""

            detected_siteurl=$(run_wp option get siteurl --path="$current_wp_path" --skip-plugins --skip-themes 2>/dev/null)
            detected_blogname=$(run_wp option get blogname --path="$current_wp_path" --skip-plugins --skip-themes 2>/dev/null)

            if [ -n "$detected_siteurl" ]; then
                current_site_url="${current_site_url:-$detected_siteurl}"
            fi
            if [ -n "$detected_blogname" ]; then
                current_must_contain="${current_must_contain:-$detected_blogname}"
            fi

            # Vorschlag für SKIP_PLUGINS: Plugins ohne Update-Quelle / kommerziell
            if [ -z "$current_skip_plugins" ]; then
                local commercial_plugins
                commercial_plugins=$(run_wp plugin list --path="$current_wp_path" --skip-plugins --skip-themes --format=csv --fields=name,update 2>/dev/null | grep -iE '(none|custom|disabled)' | cut -d, -f1 | tr '\n' ' ')
                current_skip_plugins=$(echo "$commercial_plugins" | xargs 2>/dev/null || true)
            fi
        fi

        read -rp "Website-URL (SITE_URL) [${current_site_url:-https://$proj.de}]: " in_site_url
        current_site_url="${in_site_url:-${current_site_url:-https://$proj.de}}"

        read -rp "Erforderlicher Text auf der Startseite (MUST_CONTAIN) [${current_must_contain:-$proj}]: " in_must_contain
        current_must_contain="${in_must_contain:-${current_must_contain:-$proj}}"

        read -rp "HTTP-Prüfseiten (CHECK_PATHS) [$current_check_paths]: " in_check_paths
        current_check_paths="${in_check_paths:-$current_check_paths}"

        read -rp "Plugins ausschließen (SKIP_PLUGINS) [${current_skip_plugins:-keine}]: " in_skip_plugins
        if [ "$in_skip_plugins" != "keine" ] && [ -n "$in_skip_plugins" ]; then
            current_skip_plugins="$in_skip_plugins"
        elif [ "$in_skip_plugins" == "keine" ]; then
            current_skip_plugins=""
        fi

        read -rp "Max. Backup-Alter in Minuten (BACKUP_MAX_AGE_MIN) [$current_max_age]: " in_max_age
        current_max_age="${in_max_age:-$current_max_age}"

        read -rp "Vor Update immer frisches Backup erstellen? (yes/no) [$current_backup_first]: " in_backup_first
        current_backup_first="${in_backup_first:-$current_backup_first}"

        write_project_update_file "$update_cfg" "$proj" "$current_wp_path" "$current_site_url" "$current_must_contain" "$current_check_paths" "$current_skip_plugins" "$current_max_age" "$current_backup_first"
        echo "-> Gespeichert als $update_cfg"
        configured_count=$((configured_count + 1))
    done

    echo
    echo "======================================"
    echo "$configured_count Konfiguration(en) eingerichtet."
    echo "======================================"
    return 0
}

################################
################################
################################
## HTTP Endpoint Prüffunktion

function check_http_endpoint() {
    local base_url="$1"
    local rel_path="$2"
    local full_url="${base_url%/}/${rel_path#/}"

    local temp_body
    temp_body="$(mktemp "/tmp/wp_update_http_XXXXXX" 2>/dev/null || echo "/tmp/wp_update_http_body_$$.tmp")"
    local http_res=""

    if command -v curl >/dev/null 2>&1; then
        http_res=$(curl -s -S -L -k --max-time 20 -w "%{http_code} %{time_total}" -o "$temp_body" "$full_url" 2>/dev/null)
    elif command -v wget >/dev/null 2>&1; then
        local t_start
        t_start=$(date +%s%3N 2>/dev/null || date +%s)
        local wget_code
        wget_code=$(wget -q --spider --server-response --no-check-certificate "$full_url" 2>&1 | awk '/^  HTTP/{print $2}' | tail -n 1)
        wget -q --no-check-certificate -O "$temp_body" "$full_url" 2>/dev/null
        local t_end
        t_end=$(date +%s%3N 2>/dev/null || date +%s)
        local diff_ms=$(( (t_end - t_start) ))
        [ "$diff_ms" -le 0 ] && diff_ms=100
        http_res="${wget_code:-000} $(awk "BEGIN {print $diff_ms/1000}")"
    fi

    local status_code="${http_res%% *}"
    local time_sec="${http_res#* }"
    local time_ms=0
    if [ -n "$time_sec" ]; then
        time_ms=$(awk "BEGIN {printf \"%d\", (${time_sec:-0} * 1000)}" 2>/dev/null || echo 0)
    fi

    local body_content=""
    if [ -f "$temp_body" ]; then
        body_content=$(cat "$temp_body" 2>/dev/null)
        rm -f "$temp_body"
    fi

    HTTP_CHECK_STATUS="${status_code:-000}"
    HTTP_CHECK_MS="${time_ms:-0}"
    HTTP_CHECK_BODY="$body_content"
}

################################
################################
################################
## Update-Ablauf für ein einzelnes Projekt

function run_update_for_project() {
    local update_cfg_file="$1"
    local project_name
    project_name="$(project_name_from_update_file "$update_cfg_file")"

    local run_timestamp
    run_timestamp="$(date +"%Y-%m-%d_%H-%M-%S")"
    local run_dir="$basename/update-runs/$project_name/$run_timestamp"
    mkdir -p "$run_dir"
    chmod 700 "$run_dir" 2>/dev/null || true
    local run_log="$run_dir/update.log"
    touch "$run_log"
    chmod 600 "$run_log" 2>/dev/null || true

    # Webroot-Schutz für update-runs Ordner
    ensure_webroot_protection "$basename/update-runs" "deny_all"

    # Lock-Datei pro Projekt
    local lock_file="$basename/update-runs/.update_${project_name}.lock"
    if [ -f "$lock_file" ]; then
        local lock_pid
        lock_pid=$(cat "$lock_file" 2>/dev/null)
        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
            echo "FEHLER: Projekt '$project_name' wird derzeit bereits von Prozess PID $lock_pid bearbeitet!" | tee -a "$run_log" >&2
            return 2
        fi
    fi
    echo "$$" > "$lock_file"
    chmod 600 "$lock_file" 2>/dev/null || true

    # Variablen initialisieren
    WP_PATH=""
    SITE_URL=""
    MUST_CONTAIN=""
    CHECK_PATHS="/ /kontakt/ /impressum/"
    SKIP_PLUGINS=""
    BACKUP_MAX_AGE_MIN="60"
    RUN_BACKUP_FIRST="yes"

    # Konfiguration laden
    # shellcheck source=/dev/null
    source "$update_cfg_file"

    local final_status="gruen"
    local final_exitcode=0
    local status_reasons=()
    local changes_list=()
    local failed_list=()
    local skipped_list=()
    local http_results=()
    local new_log_lines_count=0
    local fatal_errors_count=0

    local backup_status_info="nicht_ausgefuehrt"
    local backup_dateien_json="[]"
    local backup_uebertragen_json="null"

    echo "==================================================" | tee -a "$run_log"
    echo "update_wp.sh Lauf für Projekt '$project_name'" | tee -a "$run_log"
    echo "Startzeit: $(date +"%Y-%m-%d %H:%M:%S") | Run-Dir: $run_dir" | tee -a "$run_log"
    echo "==================================================" | tee -a "$run_log"
    echo

    # 1. Vorprüfung: WP-Pfad
    local resolved_wp_path
    resolved_wp_path="$(resolve_dir_path "$WP_PATH" "$basename")"

    if [ ! -d "$resolved_wp_path" ]; then
        log_check_item "ROT" "WordPress-Verzeichnis '$resolved_wp_path' existiert nicht!" "$run_log"
        final_status="rot"
        final_exitcode=2
        status_reasons+=("WordPress-Verzeichnis '$resolved_wp_path' existiert nicht")
        write_and_output_result
        rm -f "$lock_file"
        return 2
    fi

    # 2. Vorprüfung: wp core is-installed
    if ! run_wp core is-installed --path="$resolved_wp_path" --skip-plugins --skip-themes 2>> "$run_log"; then
        log_check_item "ROT" "WordPress ist unter '$resolved_wp_path' nicht installiert ('wp core is-installed' fehlgeschlagen)!" "$run_log"
        final_status="rot"
        final_exitcode=2
        status_reasons+=("WordPress unter '$resolved_wp_path' nicht installiert")
        write_and_output_result
        rm -f "$lock_file"
        return 2
    fi
    log_check_item "OK" "WordPress Core Installation in '$resolved_wp_path' verifiziert" "$run_log"

    # 3. Vorprüfung: Wartungsmodus
    if [ -f "$resolved_wp_path/.maintenance" ]; then
        log_check_item "ROT" "Website befindet sich im Wartungsmodus (Datei .maintenance vorhanden)!" "$run_log"
        final_status="rot"
        final_exitcode=2
        status_reasons+=("Wartungsmodus aktiv (.maintenance)")
        write_and_output_result
        rm -f "$lock_file"
        return 2
    fi
    log_check_item "OK" "Kein aktiver Wartungsmodus (.maintenance nicht vorhanden)" "$run_log"

    # 4. Vorprüfung: HTTP Prüfseiten & MUST_CONTAIN
    read -ra paths_array <<< "$CHECK_PATHS"
    if [ "${#paths_array[@]}" -eq 0 ]; then
        paths_array=("/")
    fi

    local pre_http_failed="false"
    local http_status_vorher=()
    local http_ms_vorher=()

    for p in "${paths_array[@]}"; do
        check_http_endpoint "$SITE_URL" "$p" "$run_log"
        local cur_st="$HTTP_CHECK_STATUS"
        local cur_ms="$HTTP_CHECK_MS"
        http_status_vorher+=("$cur_st")
        http_ms_vorher+=("$cur_ms")

        if [ "$cur_st" != "200" ]; then
            log_check_item "ROT" "Vorprüfung HTTP-Seite '$p' liefert Status $cur_st (erwartet: 200)" "$run_log"
            pre_http_failed="true"
            status_reasons+=("Schon vorher defekt: Prüfseite '$p' liefert HTTP $cur_st")
        else
            log_check_item "OK" "Vorprüfung HTTP-Seite '$p' erreichbar (Status 200, ${cur_ms}ms)" "$run_log"
        fi

        # Startseite auf MUST_CONTAIN prüfen
        if [ "$p" == "/" ] || [ "$p" == "" ]; then
            if [ -n "$MUST_CONTAIN" ] && ! echo "$HTTP_CHECK_BODY" | grep -F -q "$MUST_CONTAIN"; then
                log_check_item "ROT" "Vorprüfung Startseite enthält erforderlichen Text '$MUST_CONTAIN' nicht!" "$run_log"
                pre_http_failed="true"
                status_reasons+=("Schon vorher defekt: Startseite enthält MUST_CONTAIN ('$MUST_CONTAIN') nicht")
            fi
        fi
    done

    if [ "$pre_http_failed" == "true" ]; then
        log_check_item "ROT" "ABBRUCH: Website war schon vor dem Update defekt! Keine Updates durchgeführt." "$run_log"
        final_status="rot"
        final_exitcode=2
        write_and_output_result
        rm -f "$lock_file"
        return 2
    fi

    # Dry-Run Modus
    if [ "$cli_dry_run" == "true" ]; then
        echo
        echo "==================================================" | tee -a "$run_log"
        echo "DRY-RUN: Verfügbare Updates für '$project_name'" | tee -a "$run_log"
        echo "==================================================" | tee -a "$run_log"
        echo "WordPress Core:" | tee -a "$run_log"
        run_wp core check-update --path="$resolved_wp_path" --skip-plugins --skip-themes 2>&1 | tee -a "$run_log" || true
        echo | tee -a "$run_log"
        echo "Plugins mit verfügbaren Updates:" | tee -a "$run_log"
        run_wp plugin list --path="$resolved_wp_path" --skip-plugins --skip-themes --update=available 2>&1 | tee -a "$run_log" || true
        echo | tee -a "$run_log"
        echo "Themes mit verfügbaren Updates:" | tee -a "$run_log"
        run_wp theme list --path="$resolved_wp_path" --skip-plugins --skip-themes --update=available 2>&1 | tee -a "$run_log" || true
        echo | tee -a "$run_log"
        echo "Dry-Run abgeschlossen (keine Änderungen vorgenommen)." | tee -a "$run_log"
        final_status="gruen"
        final_exitcode=0
        write_and_output_result
        rm -f "$lock_file"
        return 0
    fi

    # 5. Backup durchführen / prüfen
    local backup_ok="false"
    local backup_script="$basename/backup_full_db_files_zip.sh"

    if [ "$cli_no_backup" != "true" ] && [ "$RUN_BACKUP_FIRST" == "yes" ]; then
        echo
        echo "Erstelle vollständiges Backup vor dem Update ..." | tee -a "$run_log"
        local backup_json_raw=""
        if [ -f "$backup_script" ]; then
            backup_json_raw=$("$backup_script" --project="$project_name" --scope=alles --json 2>> "$run_log")
            local backup_exitcode=$?

            if [ -n "$backup_json_raw" ]; then
                # JSON Felder auslesen
                local b_status
                b_status=$(echo "$backup_json_raw" | grep -o '"status"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)
                backup_status_info="${b_status:-fehler}"

                if [ "$backup_exitcode" -eq 0 ] || { [ "$backup_exitcode" -eq 1 ] && ! echo "$backup_json_raw" | grep -q '"geprueft"[[:space:]]*:[[:space:]]*false'; }; then
                    backup_ok="true"
                    log_check_item "OK" "Automatisches Backup erfolgreich erstellt und geprüft" "$run_log"
                    if [ "$backup_exitcode" -eq 1 ]; then
                        log_check_item "WARN" "Backup mit Warnung abgeschlossen (z.B. Remote-Übertragung fehlgeschlagen, lokal aber intakt)" "$run_log"
                        status_reasons+=("Backup mit Warnung abgeschlossen")
                        [ "$final_exitcode" -lt 1 ] && final_exitcode=1
                        [ "$final_status" == "gruen" ] && final_status="gelb"
                    fi
                else
                    log_check_item "ROT" "Automatisches Backup fehlgeschlagen (Exit-Code: $backup_exitcode)!" "$run_log"
                    status_reasons+=("Backup vor Update fehlgeschlagen")
                fi
            else
                log_check_item "ROT" "Backup-Skript lieferte keine Status-Ausgabe!" "$run_log"
                status_reasons+=("Backup-Skript ohne Statusausgabe beendet")
            fi
        else
            log_check_item "ROT" "Backup-Skript '$backup_script' nicht gefunden!" "$run_log"
            status_reasons+=("Backup-Skript fehlt")
        fi
    else
        # Bestehendes Backup aus status/ prüfen
        echo "Prüfe vorhandenes Status-Backup (kein neues Backup angefordert) ..." | tee -a "$run_log"
        local status_json_file="$basename/status/${project_name}.last.json"
        if [ ! -f "$status_json_file" ]; then
            # Fallback mit PROJEKT_BASIS_DATEINAME aus .env
            local env_cfg_file="$basename/.env.$project_name"
            if [ -f "$env_cfg_file" ]; then
                local PROJEKT_BASIS_DATEINAME=""
                # shellcheck source=/dev/null
                source "$env_cfg_file"
                [ -n "$PROJEKT_BASIS_DATEINAME" ] && status_json_file="$basename/status/${PROJEKT_BASIS_DATEINAME}.last.json"
            fi
        fi

        if [ -f "$status_json_file" ]; then
            local last_status_raw
            last_status_raw=$(cat "$status_json_file" 2>/dev/null)
            local last_status
            last_status=$(echo "$last_status_raw" | grep -o '"status"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)
            local last_time_str
            last_time_str=$(echo "$last_status_raw" | grep -o '"beendet"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)

            backup_status_info="${last_status:-unbekannt}"

            local last_ts=0
            if [ -n "$last_time_str" ]; then
                if date -j -f "%Y-%m-%d %H:%M:%S" "$last_time_str" +%s >/dev/null 2>&1; then
                    last_ts=$(date -j -f "%Y-%m-%d %H:%M:%S" "$last_time_str" +%s)
                else
                    last_ts=$(date -d "$last_time_str" +%s 2>/dev/null || echo 0)
                fi
            fi

            local now_ts
            now_ts=$(date +%s)
            local age_min=$(( (now_ts - last_ts) / 60 ))
            local max_allowed_min="${BACKUP_MAX_AGE_MIN:-60}"

            if [ "$last_status" == "ok" ] && [ "$age_min" -le "$max_allowed_min" ]; then
                backup_ok="true"
                log_check_item "OK" "Gültiges Backup vorhanden (Alter: $age_min Min, Limit: $max_allowed_min Min)" "$run_log"
            else
                log_check_item "ROT" "Vorhandenes Backup ist unzureichend (Status: '$last_status', Alter: $age_min Min, Limit: $max_allowed_min Min)!" "$run_log"
                status_reasons+=("Vorhandenes Backup zu alt ($age_min Min > $max_allowed_min Min) oder Status nicht OK")
            fi
        else
            log_check_item "ROT" "Keine Status-Datei '$status_json_file' für vorhandenes Backup gefunden!" "$run_log"
            status_reasons+=("Kein vorheriges Backup in status/ gefunden")
        fi
    fi

    if [ "$backup_ok" != "true" ]; then
        log_check_item "ROT" "ABBRUCH: Backup-Voraussetzung nicht erfüllt! Keine Updates durchgeführt." "$run_log"
        final_status="rot"
        final_exitcode=2
        write_and_output_result
        rm -f "$lock_file"
        return 2
    fi

    # 6. Stand vorher sichern
    local core_ver_before
    core_ver_before=$(run_wp core version --path="$resolved_wp_path" --skip-plugins --skip-themes 2>/dev/null || echo "unbekannt")
    echo "$core_ver_before" > "$run_dir/core_version_before.txt"

    run_wp plugin list --path="$resolved_wp_path" --skip-plugins --skip-themes --format=json > "$run_dir/plugins_before.json" 2>/dev/null || echo "[]" > "$run_dir/plugins_before.json"
    run_wp theme list --path="$resolved_wp_path" --skip-plugins --skip-themes --format=json > "$run_dir/themes_before.json" 2>/dev/null || echo "[]" > "$run_dir/themes_before.json"

    # Fehler-Logs Zeilenanzahl vorher ermitteln
    local debug_log_file="$resolved_wp_path/wp-content/debug.log"
    local debug_log_lines_before=0
    [ -f "$debug_log_file" ] && debug_log_lines_before=$(wc -l < "$debug_log_file" 2>/dev/null || echo 0)

    # 7. Updates durchführen
    echo
    echo "==================================================" | tee -a "$run_log"
    echo "Führe WordPress-Updates durch ..." | tee -a "$run_log"
    echo "==================================================" | tee -a "$run_log"

    local do_core="true"
    local do_plugins="true"
    local do_themes="true"
    local do_languages="true"

    if [ -n "$cli_only" ]; then
        do_core="false"; do_plugins="false"; do_themes="false"; do_languages="false"
        case "$cli_only" in
            core) do_core="true" ;;
            plugins) do_plugins="true" ;;
            themes) do_themes="true" ;;
            languages) do_languages="true" ;;
            *)
                echo "WARNUNG: Unbekannter --only Wert '$cli_only'. Führe alle Updates aus." | tee -a "$run_log" >&2
                do_core="true"; do_plugins="true"; do_themes="true"; do_languages="true"
                ;;
        esac
    fi

    # Core Update
    if [ "$do_core" == "true" ]; then
        echo "1/6: WordPress Core aktualisieren ..." | tee -a "$run_log"
        if run_wp core update --path="$resolved_wp_path" 2>&1 | tee -a "$run_log"; then
            log_check_item "OK" "WordPress Core Update ausgeführt" "$run_log"
        else
            log_check_item "WARN" "WordPress Core Update meldete einen Fehler oder bereits aktuell" "$run_log"
            failed_list+=("core_update")
            [ "$final_exitcode" -lt 1 ] && final_exitcode=1
            [ "$final_status" == "gruen" ] && final_status="gelb"
        fi

        echo "2/6: WordPress Datenbank-Schema aktualisieren ..." | tee -a "$run_log"
        if run_wp core update-db --path="$resolved_wp_path" 2>&1 | tee -a "$run_log"; then
            log_check_item "OK" "WordPress Core DB-Update erfolgreich" "$run_log"
        else
            log_check_item "ROT" "WordPress Core DB-Update ('wp core update-db') FEHLGESCHLAGEN!" "$run_log"
            failed_list+=("core_update_db")
            status_reasons+=("wp core update-db fehlgeschlagen")
            final_status="rot"
            final_exitcode=2
        fi
    fi

    # Plugins Update
    if [ "$do_plugins" == "true" ]; then
        echo "3/6: Plugins aktualisieren ..." | tee -a "$run_log"
        local plugin_update_args=("--all")
        if [ -n "$SKIP_PLUGINS" ]; then
            plugin_update_args+=("--exclude=$SKIP_PLUGINS")
            skipped_list+=("$SKIP_PLUGINS")
            echo " Ausgeschlossene Plugins: $SKIP_PLUGINS" | tee -a "$run_log"
        fi

        if run_wp plugin update --path="$resolved_wp_path" "${plugin_update_args[@]}" 2>&1 | tee -a "$run_log"; then
            log_check_item "OK" "Plugin-Updates erfolgreich abgeschlossen" "$run_log"
        else
            log_check_item "WARN" "Ein oder mehrere Plugin-Updates fehlgeschlagen" "$run_log"
            failed_list+=("plugin_update")
            status_reasons+=("Ein oder mehrere Plugin-Updates fehlgeschlagen")
            [ "$final_exitcode" -lt 1 ] && final_exitcode=1
            [ "$final_status" == "gruen" ] && final_status="gelb"
        fi
    fi

    # Themes Update
    if [ "$do_themes" == "true" ]; then
        echo "4/6: Themes aktualisieren ..." | tee -a "$run_log"
        if run_wp theme update --all --path="$resolved_wp_path" 2>&1 | tee -a "$run_log"; then
            log_check_item "OK" "Theme-Updates erfolgreich abgeschlossen" "$run_log"
        else
            log_check_item "WARN" "Ein oder mehrere Theme-Updates fehlgeschlagen" "$run_log"
            failed_list+=("theme_update")
            status_reasons+=("Ein oder mehrere Theme-Updates fehlgeschlagen")
            [ "$final_exitcode" -lt 1 ] && final_exitcode=1
            [ "$final_status" == "gruen" ] && final_status="gelb"
        fi
    fi

    # Language Updates
    if [ "$do_languages" == "true" ]; then
        echo "5/6: Sprachdateien aktualisieren ..." | tee -a "$run_log"
        run_wp language core update --path="$resolved_wp_path" 2>&1 | tee -a "$run_log" || true
        run_wp language plugin update --all --path="$resolved_wp_path" 2>&1 | tee -a "$run_log" || true
        run_wp language theme update --all --path="$resolved_wp_path" 2>&1 | tee -a "$run_log" || true
        log_check_item "OK" "Sprachdateien aktualisiert" "$run_log"
    fi

    # Cache leeren
    echo "6/6: Objekt-Cache leeren ..." | tee -a "$run_log"
    run_wp cache flush --path="$resolved_wp_path" 2>&1 | tee -a "$run_log" || true
    log_check_item "OK" "Cache geleert" "$run_log"

    # 8. Prüfung nachher (Post-Check)
    echo
    echo "==================================================" | tee -a "$run_log"
    echo "Führe Post-Update Prüfungen durch ..." | tee -a "$run_log"
    echo "==================================================" | tee -a "$run_log"

    local core_ver_after
    core_ver_after=$(run_wp core version --path="$resolved_wp_path" --skip-plugins --skip-themes 2>/dev/null || echo "unbekannt")
    echo "$core_ver_after" > "$run_dir/core_version_after.txt"

    if [ "$core_ver_before" != "$core_ver_after" ] && [ "$core_ver_before" != "unbekannt" ]; then
        changes_list+=("core|$core_ver_before|$core_ver_after|core")
        log_check_item "INFO" "WordPress Core von $core_ver_before auf $core_ver_after aktualisiert" "$run_log"
    fi

    # Checksummen prüfen
    echo "Prüfe WordPress Core Checksummen ..." | tee -a "$run_log"
    if run_wp core verify-checksums --path="$resolved_wp_path" --skip-plugins --skip-themes 2>&1 | tee -a "$run_log"; then
        log_check_item "OK" "WordPress Core Checksummen intakt" "$run_log"
    else
        log_check_item "ROT" "WordPress Core Checksummen-Prüfung FEHLGESCHLAGEN!" "$run_log"
        status_reasons+=("Core Checksummen-Prüfung fehlgeschlagen")
        final_status="rot"
        final_exitcode=2
    fi

    # Diff der Plugins ermitteln
    run_wp plugin list --path="$resolved_wp_path" --skip-plugins --skip-themes --format=json > "$run_dir/plugins_after.json" 2>/dev/null || echo "[]" > "$run_dir/plugins_after.json"
    if command -v php >/dev/null 2>&1; then
        local plugin_diff_script='
            $b = json_decode(file_get_contents($argv[1]), true) ?: [];
            $a = json_decode(file_get_contents($argv[2]), true) ?: [];
            $mapB = [];
            foreach ($b as $p) { if (!empty($p["name"])) $mapB[$p["name"]] = $p["version"] ?? ""; }
            foreach ($a as $p) {
                $name = $p["name"] ?? "";
                $vAfter = $p["version"] ?? "";
                $vBefore = $mapB[$name] ?? "";
                if ($vBefore !== "" && $vAfter !== "" && $vBefore !== $vAfter) {
                    echo "plugin|" . $vBefore . "|" . $vAfter . "|" . $name . "\n";
                }
            }
        '
        local diff_output
        diff_output=$(php -r "$plugin_diff_script" "$run_dir/plugins_before.json" "$run_dir/plugins_after.json" 2>/dev/null)
        while IFS='|' read -r c_type c_old c_new c_name; do
            [ -n "$c_name" ] && changes_list+=("$c_type|$c_old|$c_new|$c_name")
        done <<< "$diff_output"
    fi

    # Diff der Themes ermitteln
    run_wp theme list --path="$resolved_wp_path" --skip-plugins --skip-themes --format=json > "$run_dir/themes_after.json" 2>/dev/null || echo "[]" > "$run_dir/themes_after.json"
    if command -v php >/dev/null 2>&1; then
        local theme_diff_script='
            $b = json_decode(file_get_contents($argv[1]), true) ?: [];
            $a = json_decode(file_get_contents($argv[2]), true) ?: [];
            $mapB = [];
            foreach ($b as $t) { if (!empty($t["name"])) $mapB[$t["name"]] = $t["version"] ?? ""; }
            foreach ($a as $t) {
                $name = $t["name"] ?? "";
                $vAfter = $t["version"] ?? "";
                $vBefore = $mapB[$name] ?? "";
                if ($vBefore !== "" && $vAfter !== "" && $vBefore !== $vAfter) {
                    echo "theme|" . $vBefore . "|" . $vAfter . "|" . $name . "\n";
                }
            }
        '
        local theme_diff_output
        theme_diff_output=$(php -r "$theme_diff_script" "$run_dir/themes_before.json" "$run_dir/themes_after.json" 2>/dev/null)
        while IFS='|' read -r c_type c_old c_new c_name; do
            [ -n "$c_name" ] && changes_list+=("$c_type|$c_old|$c_new|$c_name")
        done <<< "$theme_diff_output"
    fi

    # Neue Logzeilen und Fatal Errors ermitteln
    if [ -f "$debug_log_file" ]; then
        local debug_log_lines_after
        debug_log_lines_after=$(wc -l < "$debug_log_file" 2>/dev/null || echo 0)
        if [ "$debug_log_lines_after" -gt "$debug_log_lines_before" ]; then
            new_log_lines_count=$((debug_log_lines_after - debug_log_lines_before))
            local new_entries
            new_entries=$(tail -n "$new_log_lines_count" "$debug_log_file" 2>/dev/null)
            echo "$new_entries" | tail -n 20 > "$run_dir/new_log_entries.log"

            fatal_errors_count=$(echo "$new_entries" | grep -ciE '(Fatal error|E_COMPILE_ERROR|E_CORE_ERROR|E_PARSE)' || echo 0)
            if [ "$fatal_errors_count" -gt 0 ]; then
                log_check_item "ROT" "$fatal_errors_count Fatal Error(s) in $debug_log_file gefunden!" "$run_log"
                status_reasons+=("$fatal_errors_count Fatal Error(s) im Debug-Log")
                final_status="rot"
                final_exitcode=2
            else
                log_check_item "WARN" "$new_log_lines_count neue Log-Einträge im Debug-Log (keine Fatal Errors)" "$run_log"
                status_reasons+=("Neue Warnungen/Notices im Debug-Log")
                [ "$final_exitcode" -lt 1 ] && final_exitcode=1
                [ "$final_status" == "gruen" ] && final_status="gelb"
            fi
        fi
    fi

    # HTTP Prüfseiten nach dem Update testen
    local p_idx=0
    for p in "${paths_array[@]}"; do
        check_http_endpoint "$SITE_URL" "$p" "$run_log"
        local st_after="$HTTP_CHECK_STATUS"
        local ms_after="$HTTP_CHECK_MS"
        local st_before="${http_status_vorher[$p_idx]}"
        local ms_before="${http_ms_vorher[$p_idx]}"
        p_idx=$((p_idx + 1))

        http_results+=("{\"pfad\": \"$(json_escape "$p")\", \"status_vorher\": ${st_before:-200}, \"status_nachher\": ${st_after:-0}, \"ms_vorher\": ${ms_before:-0}, \"ms_nachher\": ${ms_after:-0}}")

        if [ "$st_after" != "200" ]; then
            log_check_item "ROT" "Post-Check HTTP-Seite '$p' liefert Status $st_after (vorher: $st_before)!" "$run_log"
            status_reasons+=("Prüfseite '$p' liefert nach Update HTTP $st_after")
            final_status="rot"
            final_exitcode=2
        else
            log_check_item "OK" "Post-Check HTTP-Seite '$p' erreichbar (Status 200, ${ms_after}ms, vorher: ${ms_before}ms)" "$run_log"
        fi

        # HTML auf Fatal Errors prüfen
        if echo "$HTTP_CHECK_BODY" | grep -qiE '(Fatal error|kritischer Fehler|critical error)'; then
            log_check_item "ROT" "Post-Check HTTP-Seite '$p' enthält Fehlermeldung ('Fatal error' / 'kritischer Fehler')!" "$run_log"
            status_reasons+=("Fehlermeldung im HTML-Quelltext von '$p'")
            final_status="rot"
            final_exitcode=2
        fi

        # Startseite auf MUST_CONTAIN prüfen
        if [ "$p" == "/" ] || [ "$p" == "" ]; then
            if [ -n "$MUST_CONTAIN" ] && ! echo "$HTTP_CHECK_BODY" | grep -F -q "$MUST_CONTAIN"; then
                log_check_item "ROT" "Post-Check Startseite enthält erforderlichen Text '$MUST_CONTAIN' nicht mehr!" "$run_log"
                status_reasons+=("MUST_CONTAIN ('$MUST_CONTAIN') fehlt auf Startseite nach Update")
                final_status="rot"
                final_exitcode=2
            fi
        fi

        # Antwortzeit vergleichen (> 2x verlangsamt)
        if [ "$ms_before" -gt 0 ] && [ "$ms_after" -gt "$((ms_before * 2))" ] && [ "$ms_after" -gt 500 ]; then
            log_check_item "WARN" "Antwortzeit von '$p' hat sich mehr als verdoppelt (${ms_after}ms vs. vorher ${ms_before}ms)" "$run_log"
            status_reasons+=("Antwortzeit für '$p' mehr als verdoppelt (${ms_after}ms)")
            [ "$final_exitcode" -lt 1 ] && final_exitcode=1
            [ "$final_status" == "gruen" ] && final_status="gelb"
        fi
    done

    # 9. rollback.sh erzeugen
    local rollback_file="$run_dir/rollback.sh"
    cat <<EOF > "$rollback_file"
#!/bin/bash
# rollback.sh - Generiertes Rollback-Skript für Lauf $run_timestamp (Projekt '$project_name')
# ACHTUNG: Nur bei Bedarf manuell ausführen!

basename=\$(cd "\$(dirname "\$0")/../../.." && pwd)
WP_PATH="$resolved_wp_path"

echo "======================================"
echo "Rollback für Projekt '$project_name' (Lauf $run_timestamp)"
echo "======================================"
echo

EOF

    for chg in "${changes_list[@]}"; do
        IFS='|' read -r c_typ c_alt c_neu c_name <<< "$chg"
        case "$c_typ" in
            core)
                echo "echo 'Setze WordPress Core auf Version $c_alt zurück ...'" >> "$rollback_file"
                echo "$WP_CLI_BIN core update --version=$c_alt --force --path=\"\$WP_PATH\"" >> "$rollback_file"
                ;;
            plugin)
                echo "echo 'Setze Plugin $c_name auf Version $c_alt zurück ...'" >> "$rollback_file"
                echo "$WP_CLI_BIN plugin install $c_name --version=$c_alt --force --path=\"\$WP_PATH\"" >> "$rollback_file"
                ;;
            theme)
                echo "echo 'Setze Theme $c_name auf Version $c_alt zurück ...'" >> "$rollback_file"
                echo "$WP_CLI_BIN theme install $c_name --version=$c_alt --force --path=\"\$WP_PATH\"" >> "$rollback_file"
                ;;
        esac
    done

    cat <<EOF >> "$rollback_file"

echo
echo "Objekt-Cache leeren ..."
$WP_CLI_BIN cache flush --path="\$WP_PATH" 2>/dev/null || true

echo
echo "======================================"
echo "Hinweis zur vollständigen Datenbank- & Datei-Wiederherstellung:"
echo "Falls das Downgrade der Komponenten nicht ausreicht, kann das vollständige"
echo "Backup über das Backup-Skript wiederhergestellt werden:"
echo "  \$basename/backup_full_db_files_zip.sh --restore --project=$project_name"
echo "======================================"
EOF
    chmod 700 "$rollback_file" 2>/dev/null || true

    # 10. Alte Run-Verzeichnisse bereinigen (> 90 Tage)
    find "$basename/update-runs/$project_name" -mindepth 1 -maxdepth 1 -type d -mtime +90 -exec rm -rf {} + 2>/dev/null || true

    # Zusammenfassung
    echo
    echo "==================================================" | tee -a "$run_log"
    case "$final_status" in
        gruen)
            printf "  %bAmpel: GRÜN - Alle Updates und Prüfungen erfolgreich bestanden!%b\n" "${CLR_GREEN}${CLR_BOLD}" "${CLR_RESET}" | tee -a "$run_log"
            ;;
        gelb)
            printf "  %bAmpel: GELB - Updates abgeschlossen, aber mit Warnungen / Verlangsamung.%b\n" "${CLR_YELLOW}${CLR_BOLD}" "${CLR_RESET}" | tee -a "$run_log"
            ;;
        rot)
            printf "  %bAmpel: ROT - Kritische Fehler oder Fehlfunktionen nach Update erkannt!%b\n" "${CLR_RED}${CLR_BOLD}" "${CLR_RESET}" | tee -a "$run_log"
            printf "  %b-> Rollback-Befehle befinden sich in: %s/rollback.sh%b\n" "${CLR_RED}" "$run_dir" "${CLR_RESET}" | tee -a "$run_log"
            ;;
    esac
    echo "==================================================" | tee -a "$run_log"
    echo

    write_and_output_result
    rm -f "$lock_file"
    return "$final_exitcode"
}

# Hilfsfunktion zum Schreiben und Sammeln des JSON-Ergebnisses
function write_and_output_result() {
    local gruende_json
    gruende_json="$(json_string_array "${status_reasons[@]}")"
    local fehlgeschlagen_json
    fehlgeschlagen_json="$(json_string_array "${failed_list[@]}")"
    local uebersprungen_json
    uebersprungen_json="$(json_string_array "${skipped_list[@]}")"

    local aenderungen_json="["
    local chg_first=1
    for chg in "${changes_list[@]}"; do
        [ "$chg_first" -eq 1 ] && chg_first=0 || aenderungen_json+=", "
        IFS='|' read -r c_typ c_alt c_neu c_name <<< "$chg"
        aenderungen_json+="{\"typ\": \"$(json_escape "$c_typ")\", \"name\": \"$(json_escape "$c_name")\", \"von\": \"$(json_escape "$c_alt")\", \"nach\": \"$(json_escape "$c_neu")\"}"
    done
    aenderungen_json+="]"

    local http_json="["
    local h_first=1
    for h_res in "${http_results[@]}"; do
        [ "$h_first" -eq 1 ] && h_first=0 || http_json+=", "
        http_json+="$h_res"
    done
    http_json+="]"

    local project_json
    project_json=$(cat <<EOF
{
  "projekt": "$(json_escape "$project_name")",
  "status": "$final_status",
  "gruende": $gruende_json,
  "backup": {
    "status": "$(json_escape "$backup_status_info")",
    "dateien": $backup_dateien_json,
    "uebertragen": $backup_uebertragen_json
  },
  "aenderungen": $aenderungen_json,
  "fehlgeschlagen": $fehlgeschlagen_json,
  "uebersprungen": $uebersprungen_json,
  "http": $http_json,
  "neue_logzeilen": $new_log_lines_count,
  "fatal_errors": $fatal_errors_count,
  "run_dir": "$(json_escape "$run_dir")"
}
EOF
)
    all_update_json_results+=("$project_json")
    if [ "$final_exitcode" -gt "$overall_update_exitcode" ]; then
        overall_update_exitcode="$final_exitcode"
    fi
}

################################
################################
################################
## Menü & Ausführungslogik

function show_last_runs() {
    echo "======================================"
    echo "Letzte Update-Läufe"
    echo "======================================"
    local runs_found=0
    for proj_dir in "$basename/update-runs"/*; do
        [ -d "$proj_dir" ] || continue
        local p_name
        p_name="$(basename "$proj_dir")"
        echo
        echo "Projekt: $p_name"
        for r_dir in "$proj_dir"/*; do
            [ -d "$r_dir" ] || continue
            runs_found=$((runs_found + 1))
            local r_name
            r_name="$(basename "$r_dir")"
            local log_path="$r_dir/update.log"
            local ampel_line=""
            if [ -f "$log_path" ]; then
                ampel_line=$(grep "Ampel:" "$log_path" 2>/dev/null | head -n 1)
            fi
            echo "  - $r_name: ${ampel_line:-Kein Ampel-Status gefunden}"
        done
    done
    if [ "$runs_found" -eq 0 ]; then
        echo "Keine bisherigen Update-Läufe vorhanden."
    fi
    echo "======================================"
    echo
}

function show_last_rollback_commands() {
    echo "======================================"
    echo "Rollback-Befehle des letzten Laufs"
    echo "======================================"
    local latest_rollback
    latest_rollback=$(find "$basename/update-runs" -type f -name "rollback.sh" 2>/dev/null | sort -r | head -n 1)

    if [ -n "$latest_rollback" ] && [ -f "$latest_rollback" ]; then
        echo "Datei: $latest_rollback"
        echo "--------------------------------------"
        cat "$latest_rollback"
        echo "--------------------------------------"
    else
        echo "Kein Rollback-Skript gefunden."
    fi
    echo "======================================"
    echo
}

function run_main_menu() {
    while true; do
        echo
        echo "======================================"
        echo "update_wp.sh - Hauptmenü"
        echo "======================================"
        echo "  1) Ein Projekt aktualisieren"
        echo "  2) Alle Projekte aktualisieren"
        echo "  3) Dry-Run (Verfügbare Updates prüfen)"
        echo "  4) Einrichtung / Setup-Assistent"
        echo "  5) Letzte Läufe anzeigen"
        echo "  6) Rollback-Befehle des letzten Laufs"
        echo "  0) Beenden"
        echo "======================================"
        read -rp "Auswahl: " menu_choice

        case "$menu_choice" in
            1)
                return 0
                ;;
            2)
                cli_project="alle"
                return 0
                ;;
            3)
                cli_dry_run="true"
                return 0
                ;;
            4)
                run_setup_wizard
                refresh_update_configs
                ;;
            5)
                show_last_runs
                ;;
            6)
                show_last_rollback_commands
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

# Selbstinstallation beim ersten Aufruf oder bei --setup
if [ "$cli_setup" == "true" ] || [ "$cli_update_wpcli" == "true" ]; then
    if [ "$cli_update_wpcli" == "true" ]; then
        echo "Aktualisiere WP-CLI ..."
        ensure_wp_cli "true"
        exit $?
    fi
    run_setup_wizard
    exit $?
fi

refresh_update_configs

if [ "${#update_files[@]}" -eq 0 ]; then
    echo "Keine Projekt-Konfiguration (.update.<projekt>) gefunden."
    echo "Starte automatischen Setup-Assistenten ..."
    echo
    run_setup_wizard
    refresh_update_configs
    if [ "${#update_files[@]}" -eq 0 ]; then
        echo "Es wurde keine Projekt-Konfiguration angelegt. Abbruch." >&2
        exit 1
    fi
fi

# Interaktives Hauptmenü, wenn keine Parameter im Terminal übergeben wurden
if [ $# -eq 0 ] && [ -t 0 ]; then
    run_main_menu
fi

# Ziel-Projekt(e) auswählen
selected_update_files=()
if [ "$cli_project" == "alle" ]; then
    selected_update_files=("${update_files[@]}")
elif [ -n "$cli_project" ]; then
    match_file="$basename/.update.$cli_project"
    if [ -f "$match_file" ]; then
        selected_update_files=("$match_file")
    else
        echo "Keine Konfiguration für Projekt '$cli_project' gefunden ($match_file existiert nicht)." >&2
        exit 1
    fi
elif [ "${#update_files[@]}" -eq 1 ]; then
    selected_update_files=("${update_files[@]}")
else
    echo "======================================"
    echo "Mehrere Projekte gefunden:"
    p_idx=1
    for uf in "${update_files[@]}"; do
        echo "  $p_idx) $(project_name_from_update_file "$uf")"
        p_idx=$((p_idx + 1))
    done
    echo "  a) alle Projekte"
    echo "======================================"
    read -rp "Projekt auswählen (Nummer oder 'a' für alle): " p_choice
    if [ "$p_choice" == "a" ]; then
        selected_update_files=("${update_files[@]}")
    else
        sel_idx=$((p_choice - 1))
        selected_update_files=("${update_files[$sel_idx]}")
    fi
fi

overall_update_exitcode=0
all_update_json_results=()

for target_update_file in "${selected_update_files[@]}"; do
    run_update_for_project "$target_update_file"
done

# Wenn --json aktiv ist, geben wir das finale JSON auf stdout (fd 3) aus
if [ "$cli_json" == "true" ]; then
    if [ "${#all_update_json_results[@]}" -eq 1 ] && [ "$cli_project" != "alle" ]; then
        echo "${all_update_json_results[0]}" >&3
    else
        out_json="[\n"
        out_first=1
        for res_item in "${all_update_json_results[@]}"; do
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

exit "$overall_update_exitcode"
