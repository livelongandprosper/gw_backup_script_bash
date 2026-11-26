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
# Version: 1.1.0
#
# Zweck:
#   Führt WordPress Core-, Plugin-, Theme- und Sprachdateien-Updates kontrolliert
#   und sicher durch. Vor jedem Update wird die Website auf Funktionsfähigkeit
#   geprüft, ein Backup erstellt/verifiziert, visuelle Screenshots über den
#   zentralen Gotenberg 9 Dienst aufgenommen und nach dem Update ein umfassender
#   Post-Check (HTTP-Status, Logfehler, Checksummen, Visual Diff) durchgeführt.
#
# Exit-Codes:
#   0 = GRÜN (Alle Updates und Prüfungen erfolgreich)
#   1 = GELB (Updates mit Warnungen, einzelne übersprungen, Antwortzeit verlangsamt, Optik-Warnung)
#   2 = ROT  (Kritischer Fehler, Vorprüfung/Backup/Checksummen fehlgeschlagen, Layout-Bruch)
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
cli_no_screenshots='false'
cli_only=''
cli_only_set='false'
cli_setup='false'
cli_update_wpcli='false'
cli_test_screenshot='false'
cli_test_screenshot_url=''
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
        --no-screenshots|--skip-screenshots)
            cli_no_screenshots='true'
            ;;
        --only=*)
            cli_only="${cli_arg#*=}"
            cli_only_set='true'
            ;;
        --setup)
            cli_setup='true'
            ;;
        --update-wpcli)
            cli_update_wpcli='true'
            ;;
        --test-screenshot=*)
            cli_test_screenshot='true'
            cli_test_screenshot_url="${cli_arg#*=}"
            ;;
        --test-screenshot)
            cli_test_screenshot='true'
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
    echo "  --no-screenshots        Überspringt den visuellen Screenshot-Vergleich (Regression-Testing)."
    echo "  --only=<bereich>        Nur bestimmte Updates ausführen: core | plugins | themes | languages"
    echo "  --setup                 Startet den interaktiven Einrichtungsassistenten für .update-Dateien & Gotenberg."
    echo "  --update-wpcli          Aktualisiert die lokale WP-CLI (./bin/wp-cli.phar) auf die neueste Version."
    echo "  --test-screenshot[=URL] Testet die Verbindung zum zentralen Gotenberg 9 Screenshot-Dienst."
    echo "  --json                  Gibt am Ende den Status als JSON auf stdout aus (übrige Ausgabe auf stderr)."
    echo "  --help, -h              Zeigt diesen Hilfetext an."
    echo
    echo "Exit-Codes:"
    echo "  0 = GRÜN (Alles erfolgreich, Prüfungen bestanden, visuelle Abweichung < 1 %)"
    echo "  1 = GELB (Warnungen, einzelne Updates übersprungen, Antwortzeit verdoppelt, visuelle Abweichung 1-5 %)"
    echo "  2 = ROT  (Kritischer Fehler, Vorprüfung defekt, Checksummen-Fehler, Fatal Error, visuelle Abweichung > 5 %)"
    echo
    echo "Ohne Parameter im Terminal wird das interaktive Hauptmenü angezeigt."
    exit 0
fi

if [ "$cli_only_set" == "true" ]; then
    case "$cli_only" in
        core|plugins|themes|languages) ;;
        *)
            echo "FEHLER: Unbekannter --only Wert '$cli_only'. Erlaubt: core, plugins, themes, languages." >&2
            exit 2
            ;;
    esac
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
        # Nur sensible Dateien (.env, .update, .gotenberg, .sh, .log, .json, .lock) im Skript-Wurzelordner sperren
        if [ ! -f "$htaccess_file" ] || ! grep -q "\.env" "$htaccess_file" 2>/dev/null; then
            cat <<'EOF' > "$htaccess_file"
# Schutz für sensible Skript- und Konfigurationsdateien
<FilesMatch "^(\.env|\.update|\.gotenberg|\.htaccess|.*\.sh|.*\.log|.*\.json|.*\.lock)$">
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

function load_gotenberg_config() {
    local gotenberg_cfg="$basename/.gotenberg"
    GOTENBERG_URL="${GOTENBERG_URL:-https://gotenberg.gregor-wendland.com}"
    GOTENBERG_USER="${GOTENBERG_USER:-}"
    GOTENBERG_PASS="${GOTENBERG_PASS:-}"
    GOTENBERG_TIMEOUT="${GOTENBERG_TIMEOUT:-60}"

    if [ -f "$gotenberg_cfg" ]; then
        # shellcheck source=/dev/null
        source "$gotenberg_cfg"
    fi
}

function quote_shell_value() {
    local value="$1"
    value=${value//\'/\'\\\'\'}
    printf '%s' "$value"
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
    local enable_screenshots="${10:-yes}"
    local screenshot_paths="${11:-}"
    local screenshot_widths="${12:-1440 390}"
    local screenshot_wait="${13:-5s}"
    local screenshot_cookies="${14:-}"
    local screenshot_ignore_rects="${15:-}"
    local quoted_wp_path="$(quote_shell_value "$wp_path")"
    local quoted_site_url="$(quote_shell_value "$site_url")"
    local quoted_must_contain="$(quote_shell_value "$must_contain")"
    local quoted_check_paths="$(quote_shell_value "$check_paths")"
    local quoted_skip_plugins="$(quote_shell_value "$skip_plugins")"
    local quoted_max_age="$(quote_shell_value "$max_age")"
    local quoted_backup_first="$(quote_shell_value "$backup_first")"
    local quoted_enable_screenshots="$(quote_shell_value "$enable_screenshots")"
    local quoted_screenshot_paths="$(quote_shell_value "${screenshot_paths:-/ $check_paths}")"
    local quoted_screenshot_widths="$(quote_shell_value "$screenshot_widths")"
    local quoted_screenshot_wait="$(quote_shell_value "$screenshot_wait")"
    local quoted_screenshot_cookies="$(quote_shell_value "$screenshot_cookies")"
    local quoted_screenshot_ignore_rects="$(quote_shell_value "$screenshot_ignore_rects")"

    cat <<EOF > "$target_file"
# update_wp.sh Projekt-Konfigurationsdatei
# Automatisch angelegt am $(date +"%Y-%m-%d %H:%M:%S")

# Absoluter oder relativer Pfad zum WordPress-Wurzelverzeichnis
WP_PATH='$quoted_wp_path'

# Öffentliche URL der Website (für HTTP- und Screenshot-Prüfungen)
SITE_URL='$quoted_site_url'

# Text / Schlagwort, das auf der Startseite zwingend vorhanden sein muss (z. B. Blogname / Firmentitel)
MUST_CONTAIN='$quoted_must_contain'

# Pfade, die vor und nach dem Update per HTTP geprüft werden müssen (durch Leerzeichen getrennt)
CHECK_PATHS='$quoted_check_paths'

# Plugins, die beim automatischen Update ausgeschlossen werden sollen (optional, durch Leerzeichen getrennt)
SKIP_PLUGINS='$quoted_skip_plugins'

# Maximales Alter eines vorhandenen Backups in Minuten, falls kein neues erstellt wird (Standard: 60)
BACKUP_MAX_AGE_MIN='$quoted_max_age'

# Vor dem Update automatisch ein vollständiges Backup via backup_full_db_files_zip.sh ausführen (yes/no)
RUN_BACKUP_FIRST='$quoted_backup_first'

# Visuellen Screenshot-Vergleich vor und nach dem Update durchführen (yes/no)
ENABLE_SCREENSHOTS='$quoted_enable_screenshots'

# Zu prüfende Pfade für Screenshots (Standard: "/" + CHECK_PATHS)
SCREENSHOT_PATHS='$quoted_screenshot_paths'

# Viewport-Breiten für Screenshots in CSS-Pixeln (Standard: "1440 390")
SCREENSHOT_WIDTHS='$quoted_screenshot_widths'

# Wartezeit vor Screenshot-Aufnahme in Gotenberg (Standard: "5s")
SCREENSHOT_WAIT='$quoted_screenshot_wait'

# Optionale Cookies im JSON-Format (z. B. für Cookie-Consent / Banner)
# SCREENSHOT_COOKIES='[{"name":"cookie_consent","value":"accepted","domain":"example.com"}]'
SCREENSHOT_COOKIES='$quoted_screenshot_cookies'

# Optionale Ignore-Bereiche vor dem Bildvergleich (Format: "x,y,w,h;..." z. B. für dynamische Slider/Ticker)
SCREENSHOT_IGNORE_RECTS='$quoted_screenshot_ignore_rects'

# Warn- und Fehlerschwellen für visuelle Differenz in Prozent (<1% GRÜN, 1-5% GELB, >5% ROT)
SCREENSHOT_DIFF_THRESHOLD_WARN="1.0"
SCREENSHOT_DIFF_THRESHOLD_FAIL="5.0"
EOF
    chmod 600 "$target_file" 2>/dev/null || true
}

# Richtet die zentrale Gotenberg-Konfiguration (.gotenberg) interaktiv ein
function setup_gotenberg_wizard() {
    load_gotenberg_config
    local gotenberg_cfg="$basename/.gotenberg"

    echo "--------------------------------------------------"
    echo "Gotenberg 9 Screenshot-Dienst konfigurieren"
    echo "--------------------------------------------------"
    echo "Für visuelle Vorher-/Nachher-Prüfungen nutzt update_wp.sh"
    echo "den Gotenberg 9 Screenshot-Dienst."
    echo

    read -rp "Gotenberg URL [$GOTENBERG_URL]: " in_url
    GOTENBERG_URL="${in_url:-$GOTENBERG_URL}"

    read -rp "Gotenberg Basic Auth Benutzer [$GOTENBERG_USER]: " in_user
    GOTENBERG_USER="${in_user:-$GOTENBERG_USER}"

    read -rsp "Gotenberg Basic Auth Passwort (Eingabe unsichtbar) [$([ -n "$GOTENBERG_PASS" ] && echo "***")]: " in_pass
    echo
    if [ -n "$in_pass" ]; then
        GOTENBERG_PASS="$in_pass"
    fi

    read -rp "Gotenberg Timeout in Sekunden [$GOTENBERG_TIMEOUT]: " in_timeout
    GOTENBERG_TIMEOUT="${in_timeout:-$GOTENBERG_TIMEOUT}"

    local quoted_gotenberg_url="$(quote_shell_value "$GOTENBERG_URL")"
    local quoted_gotenberg_user="$(quote_shell_value "$GOTENBERG_USER")"
    local quoted_gotenberg_pass="$(quote_shell_value "$GOTENBERG_PASS")"
    local quoted_gotenberg_timeout="$(quote_shell_value "$GOTENBERG_TIMEOUT")"

    cat <<EOF > "$gotenberg_cfg"
# Gotenberg 9 Konfiguration für update_wp.sh
# Angelegt am $(date +"%Y-%m-%d %H:%M:%S")

GOTENBERG_URL='$quoted_gotenberg_url'
GOTENBERG_USER='$quoted_gotenberg_user'
GOTENBERG_PASS='$quoted_gotenberg_pass'
GOTENBERG_TIMEOUT='$quoted_gotenberg_timeout'
EOF
    chmod 600 "$gotenberg_cfg" 2>/dev/null || true
    echo "-> Gespeichert als $gotenberg_cfg (chmod 600)"
    echo
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
    check_screenshot_tools

    # Webroot-Schutz für update-runs und bin sicherstellen
    ensure_webroot_protection "$basename/update-runs" "deny_all"
    ensure_webroot_protection "$basename/bin" "deny_all"
    ensure_webroot_protection "$basename/status" "deny_all"
    ensure_webroot_protection "$basename" "sensitive_only"

    # Hinweis für Nginx-Umgebungen ausgeben
    echo "Hinweis zur Webroot-Sicherheit:"
    echo "  .htaccess-Schutzregeln wurden für Apache eingerichtet."
    echo "  Bei Nginx bitte sicherstellen, dass Verzeichnisse wie './bin/',"
    echo "  './update-runs/', './status/' und Dateien wie '.update.*', '.env.*' sowie '.gotenberg'"
    echo "  über die Nginx-Konfiguration ('deny all;') vor Webzugriff geschützt sind."
    echo

    # Gotenberg-Konfiguration abfragen
    if [ ! -f "$basename/.gotenberg" ]; then
        setup_gotenberg_wizard
    else
        read -rp "Zentrale Gotenberg 9 Konfiguration anpassen? (y/N): " change_gotenberg
        if [[ "$change_gotenberg" =~ ^[yYjJ] ]]; then
            setup_gotenberg_wizard
        fi
    fi

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
    local first_configured_url=""

    for proj in "${available_projects[@]}"; do
        local update_cfg="$basename/.update.$proj"
        local env_cfg="$basename/.env.$proj"
        echo
        echo "--------------------------------------------------"
        echo "Konfiguration für Projekt: '$proj'"
        echo "--------------------------------------------------"

        local current_wp_path=""
        local current_site_url=""
        local current_must_contain=""
        local current_check_paths=""
        local current_skip_plugins=""
        local current_max_age="60"
        local current_backup_first="yes"
        local current_enable_screenshots="yes"
        local current_screenshot_paths=""
        local current_screenshot_widths="1440 390"
        local current_screenshot_wait="5s"
        local current_screenshot_cookies=""
        local current_screenshot_ignore_rects=""

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
            current_enable_screenshots="${ENABLE_SCREENSHOTS:-$current_enable_screenshots}"
            current_screenshot_paths="${SCREENSHOT_PATHS:-$current_check_paths}"
            current_screenshot_widths="${SCREENSHOT_WIDTHS:-$current_screenshot_widths}"
            current_screenshot_wait="${SCREENSHOT_WAIT:-$current_screenshot_wait}"
            current_screenshot_cookies="${SCREENSHOT_COOKIES:-$current_screenshot_cookies}"
            current_screenshot_ignore_rects="${SCREENSHOT_IGNORE_RECTS:-$current_screenshot_ignore_rects}"
        fi

        read -rp "WordPress-Pfad (WP_PATH) [${current_wp_path:-../$proj}]: " in_wp_path
        current_wp_path="${in_wp_path:-${current_wp_path:-../$proj}}"
        current_wp_path="$(resolve_dir_path "$current_wp_path" "$basename")"

        # Falls WordPress-Pfad existiert, Werte per WP-CLI / wp-config ermitteln
        local detected_siteurl=""
        local detected_blogname=""
        if [ -d "$current_wp_path" ]; then
            detected_siteurl=$(run_wp option get siteurl --path="$current_wp_path" --skip-plugins --skip-themes 2>/dev/null)
            detected_blogname=$(run_wp option get blogname --path="$current_wp_path" --skip-plugins --skip-themes 2>/dev/null)

            if [ -n "$detected_siteurl" ]; then
                current_site_url="${current_site_url:-$detected_siteurl}"
            fi
        fi

        read -rp "Website-URL (SITE_URL) [${current_site_url:-https://$proj.de}]: " in_site_url
        current_site_url="${in_site_url:-${current_site_url:-https://$proj.de}}"
        [ -z "$first_configured_url" ] && first_configured_url="$current_site_url"

        if [ -z "$current_must_contain" ]; then
            echo "  Ermittle Textvorschlag (MUST_CONTAIN) von '$current_site_url' ..."
            local detected_must_contain
            detected_must_contain=$(detect_must_contain_from_url "$current_site_url" "$detected_blogname")
            if [ -n "$detected_must_contain" ]; then
                current_must_contain="$detected_must_contain"
                echo "  -> Ermittelter Text: $current_must_contain"
            elif [ -n "$detected_blogname" ]; then
                current_must_contain="$detected_blogname"
            fi
        fi

        if [ -z "$current_check_paths" ]; then
            echo "  Suche Prüfseiten in der Sitemap von '$current_site_url' ..."
            local detected_sitemap_paths
            detected_sitemap_paths=$(detect_check_paths_from_sitemap "$current_site_url")
            if [ -n "$detected_sitemap_paths" ]; then
                current_check_paths="$detected_sitemap_paths"
                echo "  -> Aus Sitemap ermittelt: $current_check_paths"
            else
                current_check_paths="/"
                echo "  -> Keine Sitemap gefunden, nutze Standardpfad: $current_check_paths"
            fi
        fi

        if [ -z "$current_screenshot_paths" ]; then
            current_screenshot_paths="$current_check_paths"
        fi

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

        read -rp "Visuellen Screenshot-Vergleich aktivieren? (yes/no) [$current_enable_screenshots]: " in_enable_screenshots
        current_enable_screenshots="${in_enable_screenshots:-$current_enable_screenshots}"

        if [ "$current_enable_screenshots" == "yes" ]; then
            read -rp "Screenshot-Pfade (SCREENSHOT_PATHS) [${current_screenshot_paths:-/ $current_check_paths}]: " in_screenshot_paths
            current_screenshot_paths="${in_screenshot_paths:-${current_screenshot_paths:-/ $current_check_paths}}"

            read -rp "Screenshot-Breiten (SCREENSHOT_WIDTHS) [$current_screenshot_widths]: " in_screenshot_widths
            current_screenshot_widths="${in_screenshot_widths:-$current_screenshot_widths}"

            read -rp "Wartezeit vor Aufnahme (SCREENSHOT_WAIT) [$current_screenshot_wait]: " in_screenshot_wait
            current_screenshot_wait="${in_screenshot_wait:-$current_screenshot_wait}"
        fi

        write_project_update_file "$update_cfg" "$proj" "$current_wp_path" "$current_site_url" "$current_must_contain" "$current_check_paths" "$current_skip_plugins" "$current_max_age" "$current_backup_first" "$current_enable_screenshots" "$current_screenshot_paths" "$current_screenshot_widths" "$current_screenshot_wait" "$current_screenshot_cookies" "$current_screenshot_ignore_rects"
        echo "-> Gespeichert als $update_cfg"
        configured_count=$((configured_count + 1))
    done

    echo
    echo "======================================"
    echo "$configured_count Konfiguration(en) eingerichtet."
    echo "======================================"
    echo

    if [ -n "$first_configured_url" ]; then
        echo "Teste Gotenberg-Screenshot mit Startseite '$first_configured_url' ..."
        test_gotenberg_connection "$first_configured_url"
    fi

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
    if [[ "$status_code" =~ ^[0-9]+$ ]]; then
        status_code=$((10#$status_code))
    else
        status_code=0
    fi
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

# Lädt eine beliebige URL (z. B. Sitemap) bei HTTP 200 herunter und gibt den Body auf stdout aus
function fetch_url_body() {
    local target_url="$1"
    local temp_body
    temp_body="$(mktemp "/tmp/wp_update_fetch_XXXXXX" 2>/dev/null || echo "/tmp/wp_update_fetch_$$.tmp")"
    local status_code="000"

    if command -v curl >/dev/null 2>&1; then
        status_code=$(curl -s -S -L -k --max-time 15 -w "%{http_code}" -o "$temp_body" "$target_url" 2>/dev/null)
    elif command -v wget >/dev/null 2>&1; then
        status_code=$(wget -q --server-response --no-check-certificate -O "$temp_body" "$target_url" 2>&1 | awk '/^  HTTP/{print $2}' | tail -n 1)
    fi

    if [ "$status_code" = "200" ] && [ -s "$temp_body" ]; then
        cat "$temp_body" 2>/dev/null
        rm -f "$temp_body"
        return 0
    fi

    rm -f "$temp_body"
    return 1
}

# Ermittelt aus dem HTML einer Website einen zuverlässig im Quelltext vorhandenen Text für MUST_CONTAIN
function detect_must_contain_from_html() {
    local html_file="$1"
    local fallback_blogname="${2:-}"

    [ -f "$html_file" ] && [ -s "$html_file" ] || return 1

    if command -v php >/dev/null 2>&1; then
        local php_script='
            $html = @file_get_contents($argv[1]);
            $blogname = trim($argv[2] ?? "");
            if ($html === false || $html === "") { exit(1); }

            $is_valid = function($candidate) use ($html) {
                $candidate = trim($candidate);
                $len = function_exists("mb_strlen") ? mb_strlen($candidate, "UTF-8") : strlen($candidate);
                if ($len < 3 || $len > 80) return false;
                if (preg_match("/[\r\n\t<>]/", $candidate)) return false;
                return strpos($html, $candidate) !== false;
            };

            // 1. Falls blogname exakt im HTML vorkommt, direkt übernehmen
            if ($blogname !== "" && $is_valid($blogname)) {
                echo $blogname;
                exit(0);
            }

            // 2. Erste passende <h1>-Überschrift prüfen
            if (preg_match_all("/<h1\b[^>]*>(.*?)<\/h1>/is", $html, $h1_matches)) {
                foreach ($h1_matches[1] as $raw_h1) {
                    $clean_h1 = trim(preg_replace("/\s+/u", " ", strip_tags($raw_h1)));
                    if ($is_valid($clean_h1)) {
                        echo $clean_h1;
                        exit(0);
                    }
                }
            }

            // 3. <title>-Tag (oder sauberes Segment daraus) prüfen
            if (preg_match("/<title\b[^>]*>(.*?)<\/title>/is", $html, $title_match)) {
                $raw_title = trim(preg_replace("/\s+/u", " ", $title_match[1]));
                if ($is_valid($raw_title)) {
                    echo $raw_title;
                    exit(0);
                }
                foreach (preg_split("/\s*(?:\||–|—|-|&[a-zA-Z0-9#]+;)\s*/u", $raw_title) as $part) {
                    if ($is_valid($part)) {
                        echo $part;
                        exit(0);
                    }
                }
            }

            // 4. og:site_name / application-name Meta-Tags prüfen
            if (preg_match_all("/<meta\b[^>]+(?:property=[\"\x27]og:site_name[\"\x27]|name=[\"\x27]application-name[\"\x27])[^>]*content=[\"\x27]([^\"\x27]+)[\"\x27]/is", $html, $meta_matches)) {
                foreach ($meta_matches[1] as $mval) {
                    if ($is_valid($mval)) {
                        echo $mval;
                        exit(0);
                    }
                }
            }

            // 5. Sichtbare Textzeilen aus dem <body> prüfen
            $body = $html;
            if (preg_match("/<body\b[^>]*>(.*)<\/body>/is", $html, $bm)) {
                $body = $bm[1];
            }
            $body = preg_replace("/<(script|style|noscript|svg|template)\b[^>]*>.*?<\/\1>/is", "\n", $body);
            $body = preg_replace("/<!--.*?-->/s", "\n", $body);
            $body = preg_replace("/<\/(?:p|div|h[1-6]|li|a|span|footer|header|section|article|main)>/i", "\n", $body);
            $text = strip_tags($body);
            foreach (preg_split("/\r?\n/", $text) as $line) {
                $line = trim(preg_replace("/[ \t]+/", " ", $line));
                if (preg_match("/[a-zA-ZäöüÄÖÜß]{3,}/u", $line) && $is_valid($line)) {
                    echo $line;
                    exit(0);
                }
            }

            exit(1);
        '
        php -r "$php_script" "$html_file" "$fallback_blogname" 2>/dev/null
        return $?
    fi

    return 1
}

function detect_must_contain_from_url() {
    local site_url="$1"
    local fallback_blogname="${2:-}"
    local temp_html
    temp_html="$(mktemp "/tmp/wp_update_home_XXXXXX" 2>/dev/null || echo "/tmp/wp_update_home_$$.tmp")"

    if fetch_url_body "${site_url%/}/" > "$temp_html"; then
        local detected_text
        detected_text=$(detect_must_contain_from_html "$temp_html" "$fallback_blogname")
        rm -f "$temp_html"
        if [ -n "$detected_text" ]; then
            printf '%s' "$detected_text"
            return 0
        fi
    fi

    rm -f "$temp_html"
    return 1
}

# Extrahiert <loc>-URLs aus einem Sitemap-XML (URL-Set oder Sitemap-Index)
function parse_sitemap_locs() {
    local xml_file="$1"
    [ -f "$xml_file" ] && [ -s "$xml_file" ] || return 1

    if command -v php >/dev/null 2>&1; then
        local php_script='
            $xml = @file_get_contents($argv[1]);
            if ($xml === false || $xml === "") exit(1);
            $type = "unknown";
            if (stripos($xml, "<sitemapindex") !== false) {
                $type = "index";
            } elseif (stripos($xml, "<urlset") !== false) {
                $type = "urlset";
            } else {
                exit(1);
            }
            if (!preg_match_all("/<loc>\s*(?:<!\[CDATA\[)?\s*(.*?)\s*(?:\]\]>)?\s*<\/loc>/is", $xml, $m)) {
                exit(1);
            }
            echo $type . "\n";
            foreach ($m[1] as $loc) {
                $loc = trim(html_entity_decode($loc, ENT_QUOTES | ENT_XML1, "UTF-8"));
                if ($loc !== "") echo $loc . "\n";
            }
        '
        php -r "$php_script" "$xml_file" 2>/dev/null
        return $?
    fi
    return 1
}

# Ermittelt bis zu 5 sinnvolle HTTP-Prüfpfade (inkl. '/') aus der Sitemap der Website
function detect_check_paths_from_sitemap() {
    local site_url="$1"
    local base="${site_url%/}"
    local candidate_sitemaps=()

    # 1. robots.txt nach Sitemap-Einträgen durchsuchen
    local robots_body
    robots_body=$(fetch_url_body "$base/robots.txt" 2>/dev/null || true)
    if [ -n "$robots_body" ]; then
        while IFS= read -r sm_url; do
            sm_url=$(echo "$sm_url" | tr -d '\r' | xargs 2>/dev/null || true)
            [ -n "$sm_url" ] && candidate_sitemaps+=("$sm_url")
        done < <(echo "$robots_body" | sed -n 's/^[Ss][Ii][Tt][Ee][Mm][Aa][Pp]:[[:space:]]*\([^[:space:]]*\).*/\1/p' 2>/dev/null)
    fi

    # 2. Typische WordPress- und SEO-Sitemap-Pfade ergänzen
    local std_sm
    for std_sm in "$base/wp-sitemap.xml" "$base/sitemap_index.xml" "$base/sitemap.xml"; do
        local already="false"
        local existing
        for existing in "${candidate_sitemaps[@]}"; do
            if [ "$existing" = "$std_sm" ]; then
                already="true"
                break
            fi
        done
        [ "$already" = "false" ] && candidate_sitemaps+=("$std_sm")
    done

    local collected_urls=()
    local tmp_xml
    tmp_xml="$(mktemp "/tmp/wp_update_sm_XXXXXX" 2>/dev/null || echo "/tmp/wp_update_sm_$$.tmp")"

    for sm in "${candidate_sitemaps[@]}"; do
        if fetch_url_body "$sm" > "$tmp_xml" 2>/dev/null; then
            local parsed
            parsed=$(parse_sitemap_locs "$tmp_xml" 2>/dev/null || true)
            if [ -n "$parsed" ]; then
                local sm_type
                sm_type=$(echo "$parsed" | head -n 1)
                if [ "$sm_type" = "urlset" ]; then
                    while IFS= read -r u; do
                        [ -n "$u" ] && collected_urls+=("$u")
                    done < <(echo "$parsed" | tail -n +2)
                    break
                elif [ "$sm_type" = "index" ]; then
                    # Bei Sitemap-Index bevorzugt Seiten-Sitemaps (page) laden, max. 3 Kind-Sitemaps
                    local child_sitemaps_priority=()
                    local child_sitemaps_other=()
                    while IFS= read -r child_u; do
                        [ -z "$child_u" ] && continue
                        if echo "$child_u" | grep -qi "page"; then
                            child_sitemaps_priority+=("$child_u")
                        else
                            child_sitemaps_other+=("$child_u")
                        fi
                    done < <(echo "$parsed" | tail -n +2)

                    local ordered_children=("${child_sitemaps_priority[@]}" "${child_sitemaps_other[@]}")
                    local fetched_children=0
                    local child
                    for child in "${ordered_children[@]}"; do
                        [ "$fetched_children" -ge 3 ] && break
                        if fetch_url_body "$child" > "$tmp_xml" 2>/dev/null; then
                            local child_parsed
                            child_parsed=$(parse_sitemap_locs "$tmp_xml" 2>/dev/null || true)
                            if [ -n "$child_parsed" ] && [ "$(echo "$child_parsed" | head -n 1)" = "urlset" ]; then
                                while IFS= read -r u; do
                                    [ -n "$u" ] && collected_urls+=("$u")
                                done < <(echo "$child_parsed" | tail -n +2)
                                fetched_children=$((fetched_children + 1))
                            fi
                        fi
                    done
                    [ "${#collected_urls[@]}" -gt 0 ] && break
                fi
            fi
        fi
    done

    rm -f "$tmp_xml"

    [ "${#collected_urls[@]}" -eq 0 ] && return 1

    if command -v php >/dev/null 2>&1; then
        local php_filter='
            $baseUrl = $argv[1];
            $baseHost = strtolower(preg_replace("/^www\./i", "", parse_url($baseUrl, PHP_URL_HOST) ?? ""));
            $urls = array_slice($argv, 2);
            $paths = ["/"];
            $seen = ["/" => true];
            foreach ($urls as $u) {
                $p = parse_url(trim($u));
                if (!$p) continue;
                $h = strtolower(preg_replace("/^www\./i", "", $p["host"] ?? ""));
                if ($baseHost !== "" && $h !== "" && $h !== $baseHost) continue;
                $path = $p["path"] ?? "/";
                if ($path === "" || $path[0] !== "/") $path = "/" . $path;
                if ($path === "/" || $path === "") continue;
                if (preg_match("/\.(xml|jpg|jpeg|png|gif|webp|svg|pdf|zip)$/i", $path)) continue;
                if (preg_match("#^/(wp-content|wp-includes|wp-json|feed)/#i", $path)) continue;
                if (!isset($seen[$path])) {
                    $seen[$path] = true;
                    $paths[] = $path;
                    if (count($paths) >= 5) break;
                }
            }
            if (count($paths) <= 1) exit(1);
            echo implode(" ", $paths);
        '
        php -r "$php_filter" "$site_url" "${collected_urls[@]}" 2>/dev/null
        return $?
    fi
    return 1
}

# Erzeugt aus einem relativen URL-Pfad einen sicheren Dateinamen-Slug
function path_to_slug() {
    local raw_path="$1"
    local clean_p="${raw_path#/}"
    clean_p="${clean_p%/}"
    if [ -z "$clean_p" ]; then
        echo "home"
    else
        echo "$clean_p" | sed -e 's/[^a-zA-Z0-9_-]/_/g'
    fi
}

# Vergleicht zwei HTML-Dateien (vorher/nachher) normalisiert anhand des sichtbaren Inhalts,
# <title> und <h1>, und schreibt bei Abweichungen ein Diff.
# Ausgabe auf stdout: "STATUS|REASON|LEN_BEFORE|LEN_AFTER" (STATUS: gruen | gelb | rot)
function compare_html_files() {
    local before_file="$1"
    local after_file="$2"
    local diff_file="$3"

    if [ ! -f "$before_file" ] || [ ! -f "$after_file" ]; then
        echo "gelb|HTML-Vergleichsdatei fehlt|0|0"
        return 0
    fi

    if command -v php >/dev/null 2>&1; then
        local php_cmp='
            $beforeFile = $argv[1];
            $afterFile  = $argv[2];
            $diffFile   = $argv[3];

            $rawBefore = @file_get_contents($beforeFile);
            $rawAfter  = @file_get_contents($afterFile);
            if ($rawBefore === false || $rawAfter === false) {
                echo "gelb|HTML-Dateien konnten nicht gelesen werden|0|0";
                exit(0);
            }

            $analyze = function($html) {
                $title = "";
                if (preg_match("/<title\b[^>]*>(.*?)<\/title>/is", $html, $tm)) {
                    $title = trim(preg_replace("/\s+/u", " ", html_entity_decode(strip_tags($tm[1]), ENT_QUOTES | ENT_HTML5, "UTF-8")));
                }

                $h1List = [];
                if (preg_match_all("/<h1\b[^>]*>(.*?)<\/h1>/is", $html, $hm)) {
                    foreach ($hm[1] as $rawH1) {
                        $cleanH1 = trim(preg_replace("/\s+/u", " ", html_entity_decode(strip_tags($rawH1), ENT_QUOTES | ENT_HTML5, "UTF-8")));
                        if ($cleanH1 !== "") {
                            $h1List[] = $cleanH1;
                        }
                    }
                }

                $clean = preg_replace("/<!--.*?-->/s", "", $html);
                $clean = preg_replace("/<script\b[^>]*>.*?<\/script>/is", "", $clean);
                $clean = preg_replace("/<style\b[^>]*>.*?<\/style>/is", "", $clean);
                $clean = preg_replace("/<noscript\b[^>]*>.*?<\/noscript>/is", "", $clean);
                $clean = preg_replace("/<\/?(p|div|section|article|header|footer|main|aside|nav|li|ul|ol|h[1-6]|tr|td|th|blockquote|pre|br|hr)\b[^>]*>/i", "\n", $clean);
                $text = html_entity_decode(strip_tags($clean), ENT_QUOTES | ENT_HTML5, "UTF-8");

                $lines = preg_split("/\r\n|\r|\n/", $text);
                $normLines = [];
                foreach ($lines as $line) {
                    $line = trim(preg_replace("/\s+/u", " ", $line));
                    if ($line !== "") {
                        $normLines[] = $line;
                    }
                }
                $normText = implode("\n", $normLines);
                $len = function_exists("mb_strlen") ? mb_strlen($normText, "UTF-8") : strlen($normText);

                return [
                    "title"   => $title,
                    "h1"      => $h1List,
                    "text"    => $normText,
                    "len"     => $len
                ];
            };

            $b = $analyze($rawBefore);
            $a = $analyze($rawAfter);

            $status = "gruen";
            $reason = "Sichtbarer Seiteninhalt unverändert (" . $a["len"] . " Zeichen)";

            if ($b["len"] >= 100 && $a["len"] < ($b["len"] * 0.5)) {
                $status = "rot";
                $reason = "Sichtbarer Text um mehr als 50% geschrumpft (" . $b["len"] . " -> " . $a["len"] . " Zeichen)";
            } elseif ($b["title"] !== "" && $a["title"] === "") {
                $status = "rot";
                $reason = "<title>-Tag nach Update leer/verschwunden";
            } elseif (count($b["h1"]) > 0 && count($a["h1"]) === 0) {
                $status = "rot";
                $reason = "<h1>-Überschrift nach Update verschwunden";
            } elseif ($b["text"] !== $a["text"]) {
                $status = "gelb";
                $reason = "Sichtbarer Seiteninhalt weicht ab (" . $b["len"] . " -> " . $a["len"] . " Zeichen)";
            }

            if ($status !== "gruen" && $diffFile !== "") {
                $tmpB = tempnam(sys_get_temp_dir(), "wph_b_");
                $tmpA = tempnam(sys_get_temp_dir(), "wph_a_");
                if ($tmpB !== false && $tmpA !== false) {
                    file_put_contents($tmpB, $b["text"] . "\n");
                    file_put_contents($tmpA, $a["text"] . "\n");
                    $cmd = "diff -u --label " . escapeshellarg("vorher (normalisierter Text)") . " --label " . escapeshellarg("nachher (normalisierter Text)") . " " . escapeshellarg($tmpB) . " " . escapeshellarg($tmpA) . " 2>/dev/null";
                    $diffOut = shell_exec($cmd);
                    if ($diffOut !== null && $diffOut !== "") {
                        @file_put_contents($diffFile, $diffOut);
                    } else {
                        @file_put_contents($diffFile, "Status: $status\nGrund: $reason\nVorher-Zeichen: {$b["len"]}\nNachher-Zeichen: {$a["len"]}\n");
                    }
                    @unlink($tmpB);
                    @unlink($tmpA);
                }
            } elseif ($diffFile !== "" && file_exists($diffFile)) {
                @unlink($diffFile);
            }

            $reason = str_replace(["|", "\r", "\n"], ["/", " ", " "], $reason);
            echo $status . "|" . $reason . "|" . $b["len"] . "|" . $a["len"];
        '
        local res
        res=$(php -r "$php_cmp" "$before_file" "$after_file" "$diff_file" 2>/dev/null || true)
        if [ -n "$res" ]; then
            echo "$res"
            return 0
        fi
    fi

    # Fallback ohne PHP
    local len_b len_a
    len_b=$(wc -c < "$before_file" 2>/dev/null | tr -d ' ' || echo 0)
    len_a=$(wc -c < "$after_file" 2>/dev/null | tr -d ' ' || echo 0)
    if cmp -s "$before_file" "$after_file" 2>/dev/null; then
        echo "gruen|HTML unverändert (${len_a} Bytes)|${len_b}|${len_a}"
    else
        diff -u "$before_file" "$after_file" > "$diff_file" 2>/dev/null || true
        echo "gelb|HTML weicht ab (${len_b} -> ${len_a} Bytes)|${len_b}|${len_a}"
    fi
}

################################
################################
################################
## Visuelle Regression & Gotenberg 9 Screenshot-Dienst

# Prüft die Verfügbarkeit von Werkzeugen für den visuellen Bildvergleich (ImageMagick / PHP-GD)
function check_screenshot_tools() {
    local log_target="${1:-/dev/null}"
    local has_imagemagick=0
    local has_php_gd=0

    if command -v compare >/dev/null 2>&1 || command -v magick >/dev/null 2>&1; then
        has_imagemagick=1
    fi

    if command -v php >/dev/null 2>&1 && php -r 'exit(extension_loaded("gd") ? 0 : 1);' >/dev/null 2>&1; then
        has_php_gd=1
    fi

    if [ "$has_imagemagick" -eq 1 ]; then
        log_check_item "OK" "ImageMagick ('compare'/'magick') für präzisen Bildvergleich verfügbar" "$log_target"
        return 0
    elif [ "$has_php_gd" -eq 1 ]; then
        log_check_item "OK" "PHP-GD Erweiterung für visuellen Pixel-Vergleich verfügbar" "$log_target"
        return 0
    else
        log_check_item "WARN" "Weder ImageMagick noch PHP-GD für visuellen Bildvergleich gefunden" "$log_target" "Für pixelgenaue Differenzbilder wird ImageMagick ('compare') oder die PHP-GD-Erweiterung empfohlen. Ohne diese Tools wird auf Dateigrößen-Heuristik zurückgegriffen."
        return 1
    fi
}

# Erstellt einen Screenshot einer Website-URL über den zentralen Gotenberg 9 Dienst
# Verwendet Basic Auth via stdin ('curl -K -'), sodass Zugangsdaten nicht in der Prozessliste erscheinen.
function capture_screenshot() {
    local target_url="$1"
    local output_file="$2"
    local width="${3:-1440}"
    local wait_delay="${4:-5s}"
    local cookies_json="${5:-}"
    local log_target="${6:-/dev/null}"

    [ -z "$target_url" ] || [ -z "$output_file" ] && return 1
    mkdir -p "$(dirname "$output_file")" 2>/dev/null || true

    load_gotenberg_config

    local base_url="${GOTENBERG_URL%/}"
    local endpoint="${base_url}/forms/chromium/screenshot/url"
    local timeout="${GOTENBERG_TIMEOUT:-60}"

    local curl_auth_cfg=""
    if [ -n "$GOTENBERG_USER" ] || [ -n "$GOTENBERG_PASS" ]; then
        curl_auth_cfg="user = \"${GOTENBERG_USER}:${GOTENBERG_PASS}\""
    fi

    local temp_out
    temp_out="$(mktemp "${output_file}.tmp_XXXXXX" 2>/dev/null || echo "${output_file}.tmp_$$")"

    local curl_cmd=(
        curl -s -S -k --max-time "$timeout"
    )

    if [ -n "$curl_auth_cfg" ]; then
        curl_cmd+=(-K -)
    fi

    curl_cmd+=(
        --request POST "$endpoint"
        --form "url=$target_url"
        --form "format=png"
        --form "width=$width"
        --form "waitDelay=$wait_delay"
    )

    if [ -n "$cookies_json" ]; then
        curl_cmd+=(--form "cookies=$cookies_json")
    fi

    curl_cmd+=(-o "$temp_out")

    local curl_err=""
    if [ -n "$curl_auth_cfg" ]; then
        curl_err=$(printf "%s" "$curl_auth_cfg" | "${curl_cmd[@]}" 2>&1)
    else
        curl_err=$("${curl_cmd[@]}" 2>&1)
    fi

    local curl_status=$?

    # Validierung: Datei vorhanden, Größe > 100 Bytes, PNG-Magic-Bytes (89 50 4E 47 / \x89PNG)
    local is_png=0
    if [ $curl_status -eq 0 ] && [ -f "$temp_out" ] && [ -s "$temp_out" ]; then
        local first_bytes
        first_bytes=$(head -c 4 "$temp_out" 2>/dev/null)
        if [ "$first_bytes" = $'\x89PNG' ]; then
            is_png=1
        elif command -v file >/dev/null 2>&1 && file "$temp_out" | grep -qi "PNG image"; then
            is_png=1
        elif command -v od >/dev/null 2>&1 && [ "$(od -A n -N 4 -t x1 "$temp_out" 2>/dev/null | tr -d ' ')" = "89504e47" ]; then
            is_png=1
        fi
    fi

    if [ $is_png -eq 1 ]; then
        mv -f "$temp_out" "$output_file"
        chmod 600 "$output_file" 2>/dev/null || true
        return 0
    else
        local err_preview=""
        if [ -f "$temp_out" ]; then
            err_preview=$(head -n 2 "$temp_out" 2>/dev/null)
            rm -f "$temp_out"
        fi
        if [ -n "$log_target" ] && [ "$log_target" != "/dev/null" ]; then
            if [ -n "$err_preview" ]; then
                echo "    [Gotenberg Fehler]: $err_preview" >> "$log_target"
            elif [ -n "$curl_err" ]; then
                echo "    [Curl Fehler]: $curl_err" >> "$log_target"
            fi
        fi
        return 1
    fi
}

# Testet die Verbindung zum Gotenberg 9 Dienst
function test_gotenberg_connection() {
    local test_url="${1:-https://example.com}"
    echo "======================================"
    echo "Gotenberg 9 Screenshot-Verbindungstest"
    echo "======================================"
    load_gotenberg_config

    echo "Endpunkt: ${GOTENBERG_URL%/}/forms/chromium/screenshot/url"
    echo "Benutzer: ${GOTENBERG_USER:-<keiner>}"
    echo "Timeout:  ${GOTENBERG_TIMEOUT:-60}s"
    echo "Test-URL: $test_url"
    echo

    local temp_file
    temp_file="$(mktemp "/tmp/gotenberg_test_XXXXXX.png" 2>/dev/null || echo "/tmp/gotenberg_test_$$.png")"

    echo "Sende Screenshot-Anfrage ..."
    if capture_screenshot "$test_url" "$temp_file" "1440" "5s" "" "/dev/stderr"; then
        local sz
        sz=$(get_file_size_bytes "$temp_file")
        log_check_item "OK" "Verbindung zu Gotenberg 9 erfolgreich! Screenshot empfangen ($sz Bytes, PNG)."
        rm -f "$temp_file"
        return 0
    else
        log_check_item "ALERT" "Verbindung zu Gotenberg 9 fehlgeschlagen oder ungültiges Bild empfangen."
        echo
        echo "Tipps zur Fehlerbehebung:"
        echo "  1. Ist Gotenberg unter '$GOTENBERG_URL' erreichbar?"
        echo "  2. Stimmen Benutzername und Passwort in .gotenberg?"
        echo "  3. Kann Gotenberg die Ziel-URL '$test_url' erreichen?"
        rm -f "$temp_file"
        return 1
    fi
}

# Maskiert Ignore-Rechtecke vor dem Bildvergleich
function apply_ignore_rectangles() {
    local img_file="$1"
    local rects_str="$2"
    local target_width="$3"

    [ ! -f "$img_file" ] || [ -z "$rects_str" ] && return 0

    local IFS=';'
    read -ra rect_list <<< "$rects_str"
    for r_entry in "${rect_list[@]}"; do
        r_entry=$(echo "$r_entry" | tr -d ' ')
        [ -z "$r_entry" ] && continue

        local r_w=""
        local r_coords="$r_entry"
        if [[ "$r_entry" == *:* ]]; then
            r_w="${r_entry%%:*}"
            r_coords="${r_entry#*:}"
            if [ -n "$target_width" ] && [ -n "$r_w" ] && [ "$r_w" != "$target_width" ]; then
                continue
            fi
        fi

        local rx ry rw rh
        IFS=',' read -r rx ry rw rh <<< "$r_coords"
        if [ -n "$rx" ] && [ -n "$ry" ] && [ -n "$rw" ] && [ -n "$rh" ]; then
            local rx2=$((rx + rw))
            local ry2=$((ry + rh))

            if command -v mogrify >/dev/null 2>&1; then
                mogrify -fill black -draw "rectangle $rx,$ry $rx2,$ry2" "$img_file" 2>/dev/null || true
            elif command -v magick >/dev/null 2>&1; then
                magick mogrify -fill black -draw "rectangle $rx,$ry $rx2,$ry2" "$img_file" 2>/dev/null || true
            elif command -v php >/dev/null 2>&1 && php -r 'exit(extension_loaded("gd") ? 0 : 1);' >/dev/null 2>&1; then
                local php_mask='
                    $f = $argv[1]; $x = (int)$argv[2]; $y = (int)$argv[3]; $w = (int)$argv[4]; $h = (int)$argv[5];
                    $im = @imagecreatefrompng($f);
                    if ($im) {
                        $black = imagecolorallocate($im, 0, 0, 0);
                        imagefilledrectangle($im, $x, $y, $x + $w, $y + $h, $black);
                        imagepng($im, $f);
                        imagedestroy($im);
                    }
                '
                php -r "$php_mask" "$img_file" "$rx" "$ry" "$rw" "$rh" 2>/dev/null || true
            fi
        fi
    done
}

# Vergleicht zwei Screenshots und berechnet die Abweichung in Prozent (0.00 bis 100.00)
# Erzeugt optional ein Differenzbild (diff_file)
function compare_screenshots() {
    local file_before="$1"
    local file_after="$2"
    local diff_file="${3:-}"

    if [ ! -f "$file_before" ] || [ ! -f "$file_after" ]; then
        echo "100.00"
        return 1
    fi

    # 1. Bevorzugt: ImageMagick (compare oder magick compare)
    local im_bin=""
    if command -v compare >/dev/null 2>&1; then
        im_bin="compare"
    elif command -v magick >/dev/null 2>&1; then
        im_bin="magick compare"
    fi

    if [ -n "$im_bin" ]; then
        local target_diff="${diff_file:-/dev/null}"
        [ "$target_diff" == "/dev/null" ] && target_diff="null:"

        local raw_rmse
        raw_rmse=$($im_bin -metric RMSE -fuzz 5% "$file_before" "$file_after" "$target_diff" 2>&1 || true)
        # Typische Ausgabe: "1234.5 (0.0188382)" -> 0.0188382 entspricht 1.88%
        local norm_val
        norm_val=$(echo "$raw_rmse" | grep -oE '\([0-9.]+\)' | tr -d '()')
        if [ -n "$norm_val" ]; then
            local pct
            pct=$(awk "BEGIN {printf \"%.2f\", ($norm_val * 100)}" 2>/dev/null || echo 0.00)
            echo "$pct"
            return 0
        fi
    fi

    # 2. Zweite Wahl: PHP mit GD-Erweiterung
    if command -v php >/dev/null 2>&1 && php -r 'exit(extension_loaded("gd") ? 0 : 1);' >/dev/null 2>&1; then
        local php_diff_script='
            $f1 = $argv[1]; $f2 = $argv[2]; $fd = $argv[3] ?? "";
            $im1 = @imagecreatefromstring(@file_get_contents($f1));
            $im2 = @imagecreatefromstring(@file_get_contents($f2));
            if (!$im1 || !$im2) { echo "100.00\n"; exit(1); }
            $w1 = imagesx($im1); $h1 = imagesy($im1);
            $w2 = imagesx($im2); $h2 = imagesy($im2);
            $w = min($w1, $w2); $h = min($h1, $h2);
            $diff_img = imagecreatetruecolor($w, $h);
            $red = imagecolorallocate($diff_img, 255, 0, 0);
            $diff_count = 0;
            $step = 2; // Schneller 2-Pixel-Raster
            $total_samples = 0;
            for ($y = 0; $y < $h; $y += $step) {
                for ($x = 0; $x < $w; $x += $step) {
                    $total_samples++;
                    $c1 = imagecolorat($im1, $x, $y);
                    $c2 = imagecolorat($im2, $x, $y);
                    $r1 = ($c1 >> 16) & 0xFF; $g1 = ($c1 >> 8) & 0xFF; $b1 = $c1 & 0xFF;
                    $r2 = ($c2 >> 16) & 0xFF; $g2 = ($c2 >> 8) & 0xFF; $b2 = $c2 & 0xFF;
                    $dist = sqrt(($r1 - $r2)**2 + ($g1 - $g2)**2 + ($b1 - $b2)**2);
                    if ($dist > 25) { // ~5.5% RGB-Distanz
                        $diff_count++;
                        imagesetpixel($diff_img, $x, $y, $red);
                    } else {
                        $gv = (int)(($r1 + $g1 + $b1) / 3 * 0.35);
                        $gray = imagecolorallocate($diff_img, $gv, $gv, $gv);
                        imagesetpixel($diff_img, $x, $y, $gray);
                    }
                }
            }
            if ($fd && $fd !== "/dev/null") {
                @imagepng($diff_img, $fd);
            }
            $pct = round(($diff_count / max(1, $total_samples)) * 100, 2);
            echo number_format($pct, 2, ".", "") . "\n";
            imagedestroy($im1); imagedestroy($im2); imagedestroy($diff_img);
        '
        local php_pct
        php_pct=$(php -r "$php_diff_script" "$file_before" "$file_after" "${diff_file:-/dev/null}" 2>/dev/null)
        if [ -n "$php_pct" ]; then
            echo "$php_pct"
            return 0
        fi
    fi

    # 3. Fallback: Dateigrößen-Heuristik
    local sz1 sz2
    sz1=$(get_file_size_bytes "$file_before")
    sz2=$(get_file_size_bytes "$file_after")
    if [ "$sz1" -le 1000 ] || [ "$sz2" -le 1000 ]; then
        echo "100.00"
        return 0
    fi
    local diff_sz=$(( sz1 > sz2 ? sz1 - sz2 : sz2 - sz1 ))
    local sz_pct
    sz_pct=$(awk "BEGIN {printf \"%.2f\", (($diff_sz / $sz1) * 100)}" 2>/dev/null || echo 0.00)
    echo "$sz_pct"
    return 0
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
    ENABLE_SCREENSHOTS="yes"
    SCREENSHOT_PATHS=""
    SCREENSHOT_WIDTHS="1440 390"
    SCREENSHOT_WAIT="5s"
    SCREENSHOT_COOKIES=""
    SCREENSHOT_IGNORE_RECTS=""
    SCREENSHOT_DIFF_THRESHOLD_WARN="1.0"
    SCREENSHOT_DIFF_THRESHOLD_FAIL="5.0"

    local old_method="${SCREENSHOT_METHOD:-}"
    local old_pages="${SCREENSHOT_PAGES_COUNT:-}"
    unset SCREENSHOT_METHOD SCREENSHOT_PAGES_COUNT

    # Konfiguration laden
    # shellcheck source=/dev/null
    source "$update_cfg_file"

    if [ -n "${SCREENSHOT_METHOD:-}" ] || [ -n "$old_method" ]; then
        log_check_item "INFO" "Veraltete Option 'SCREENSHOT_METHOD' in $(basename "$update_cfg_file") wird ignoriert (Screenshots nutzen jetzt zentral Gotenberg 9)" "$run_log"
        unset SCREENSHOT_METHOD
    fi
    if [ -n "${SCREENSHOT_PAGES_COUNT:-}" ] || [ -n "$old_pages" ]; then
        log_check_item "INFO" "Veraltete Option 'SCREENSHOT_PAGES_COUNT' in $(basename "$update_cfg_file") wird ignoriert (Pfade werden über SCREENSHOT_PATHS definiert)" "$run_log"
        unset SCREENSHOT_PAGES_COUNT
    fi

    local final_status="gruen"
    local final_exitcode=0
    local status_reasons=()
    local changes_list=()
    local failed_list=()
    local skipped_list=()
    local http_results=()
    local html_results=()
    local screenshot_results=()
    local new_log_lines_count=0
    local fatal_errors_count=0

    local backup_status_info="nicht_ausgefuehrt"
    local backup_dateien_json="[]"
    local backup_uebertragen_json="null"

    echo
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
    local html_dir="$run_dir/html"
    mkdir -p "$html_dir"
    chmod 700 "$html_dir" 2>/dev/null || true
    ensure_webroot_protection "$html_dir" "deny_all"

    for p in "${paths_array[@]}"; do
        check_http_endpoint "$SITE_URL" "$p" "$run_log"
        local cur_st="$HTTP_CHECK_STATUS"
        local cur_ms="$HTTP_CHECK_MS"
        http_status_vorher+=("$cur_st")
        http_ms_vorher+=("$cur_ms")

        local p_slug
        p_slug="$(path_to_slug "$p")"
        if [ -n "$HTTP_CHECK_BODY" ]; then
            printf '%s' "$HTTP_CHECK_BODY" > "$html_dir/vorher_${p_slug}.html"
        fi

        if [ "$cur_st" != "200" ]; then
            log_check_item "ROT" "Vorprüfung HTTP-Seite '$p' liefert Status $cur_st (erwartet: 200)" "$run_log"
            pre_http_failed="true"
            status_reasons+=("Schon vorher defekt: Prüfseite '$p' liefert HTTP $cur_st")
        else
            log_check_item "OK" "Vorprüfung HTTP-Seite '$p' erreichbar (Status 200, ${cur_ms}ms)" "$run_log"
        fi

        # Startseite auf MUST_CONTAIN prüfen
        if [ "$p" == "/" ] || [ "$p" == "" ]; then
            if [ -n "$MUST_CONTAIN" ] && [[ "$HTTP_CHECK_BODY" != *"$MUST_CONTAIN"* ]]; then
                log_check_item "ROT" "Vorprüfung Startseite enthält erforderlichen Text '$MUST_CONTAIN' nicht!" "$run_log"
                pre_http_failed="true"
                status_reasons+=("Schon vorher defekt: Startseite enthält MUST_CONTAIN ('$MUST_CONTAIN') nicht")
            fi
        fi
    done

    if [ "$pre_http_failed" == "true" ]; then
        log_check_item "ROT" "ABBRUCH: Website war schon vor dem Update defekt! Keine Updates durchgeführt." "$run_log"
        echo
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
        if [ ! -f "$basename/.env.$project_name" ]; then
            log_check_item "ROT" "ABBRUCH: Backup-Konfiguration '$basename/.env.$project_name' fehlt; der Backup-Assistent wird nicht gestartet." "$run_log"
            final_status="rot"
            final_exitcode=2
            write_and_output_result
            rm -f "$lock_file"
            return 2
        fi
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

    # Screenshots vor Update erfassen (Visuelle Regression via Gotenberg 9)
    local do_screenshots="false"
    local screenshot_tasks=() # Format: "URL|SLUG|LABEL|WIDTH"
    local screenshots_dir="$run_dir/screenshots"
    local gotenberg_error_occurred="false"

    if [ "$ENABLE_SCREENSHOTS" == "yes" ] && [ "$cli_no_screenshots" != "true" ] && [ "$cli_dry_run" != "true" ]; then
        do_screenshots="true"
        mkdir -p "$screenshots_dir"
        chmod 700 "$screenshots_dir" 2>/dev/null || true
        ensure_webroot_protection "$screenshots_dir" "deny_all"

        echo
        echo "Erfasse Vorher-Screenshots über Gotenberg 9 für visuelle Regressionsprüfung ..." | tee -a "$run_log"

        local norm_site_url="${SITE_URL%/}"
        local shot_paths=()
        if [ -n "$SCREENSHOT_PATHS" ]; then
            read -ra shot_paths <<< "$SCREENSHOT_PATHS"
        else
            shot_paths=("/")
            for cp in "${paths_array[@]}"; do
                [ "$cp" == "/" ] || [ -z "$cp" ] && continue
                shot_paths+=("$cp")
            done
        fi

        local shot_widths=()
        read -ra shot_widths <<< "${SCREENSHOT_WIDTHS:-1440 390}"
        [ "${#shot_widths[@]}" -eq 0 ] && shot_widths=("1440" "390")

        for p_item in "${shot_paths[@]}"; do
            local clean_p="${p_item#/}"
            clean_p="${clean_p%/}"
            local full_shot_url="$norm_site_url"
            [ -n "$clean_p" ] && full_shot_url="$norm_site_url/$clean_p"
            [ -z "$clean_p" ] && full_shot_url="$norm_site_url/"

            local p_slug
            if [ -z "$clean_p" ]; then
                p_slug="home"
            else
                p_slug=$(echo "$clean_p" | sed -e 's/[^a-zA-Z0-9_-]/_/g')
            fi

            local p_label="$p_item"
            [ "$p_item" == "/" ] && p_label="Startseite"

            for w_val in "${shot_widths[@]}"; do
                w_val="${w_val// /}"
                [ -z "$w_val" ] && continue
                screenshot_tasks+=("$full_shot_url|$p_slug|$p_label|$w_val")
            done
        done

        for s_task in "${screenshot_tasks[@]}"; do
            IFS='|' read -r s_url s_slug s_label s_width <<< "$s_task"
            local file_vorher="$screenshots_dir/vorher_${s_slug}_${s_width}.png"
            echo "  Erstelle Vorher-Screenshot für $s_label ($s_width px) ..." | tee -a "$run_log"
            if capture_screenshot "$s_url" "$file_vorher" "$s_width" "${SCREENSHOT_WAIT:-5s}" "$SCREENSHOT_COOKIES" "$run_log"; then
                log_check_item "OK" "Vorher-Screenshot für $s_label ($s_width px) erstellt ($(get_file_size_bytes "$file_vorher") Bytes)" "$run_log"
            else
                log_check_item "WARN" "Vorher-Screenshot für $s_label ($s_width px) fehlgeschlagen (Gotenberg nicht erreichbar oder ungültig)" "$run_log"
                gotenberg_error_occurred="true"
            fi
        done
    fi

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
                log_check_item "ROT" "ABBRUCH: Unbekannter --only Wert '$cli_only'." "$run_log"
                final_status="rot"
                final_exitcode=2
                write_and_output_result
                rm -f "$lock_file"
                return 2
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
            local skipped_plugins=()
            read -ra skipped_plugins <<< "$SKIP_PLUGINS"
            local skipped_plugins_csv
            skipped_plugins_csv="$(IFS=,; printf '%s' "${skipped_plugins[*]}")"
            plugin_update_args+=("--exclude=$skipped_plugins_csv")
            skipped_list+=("${skipped_plugins[@]}")
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

            fatal_errors_count=$(echo "$new_entries" | grep -ciE '(Fatal error|E_COMPILE_ERROR|E_CORE_ERROR|E_PARSE)' || true)
            fatal_errors_count="${fatal_errors_count:-0}"
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
        if grep -qiE -q '(Fatal error|kritischer Fehler|critical error)' <<< "$HTTP_CHECK_BODY"; then
            log_check_item "ROT" "Post-Check HTTP-Seite '$p' enthält Fehlermeldung ('Fatal error' / 'kritischer Fehler')!" "$run_log"
            status_reasons+=("Fehlermeldung im HTML-Quelltext von '$p'")
            final_status="rot"
            final_exitcode=2
        fi

        # Startseite auf MUST_CONTAIN prüfen
        if [ "$p" == "/" ] || [ "$p" == "" ]; then
            if [ -n "$MUST_CONTAIN" ] && [[ "$HTTP_CHECK_BODY" != *"$MUST_CONTAIN"* ]]; then
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

        # HTML-Kopie nach Update sichern und normalisiert vergleichen
        local p_slug
        p_slug="$(path_to_slug "$p")"
        local html_vorher="$html_dir/vorher_${p_slug}.html"
        local html_nachher="$html_dir/nachher_${p_slug}.html"
        local html_diff="$html_dir/diff_${p_slug}.diff"
        local html_vorher_rel="html/vorher_${p_slug}.html"
        local html_nachher_rel="html/nachher_${p_slug}.html"
        local html_diff_rel="html/diff_${p_slug}.diff"

        if [ -n "$HTTP_CHECK_BODY" ]; then
            printf '%s' "$HTTP_CHECK_BODY" > "$html_nachher"
        fi

        if [ "$st_after" == "200" ] && [ -f "$html_vorher" ] && [ -f "$html_nachher" ]; then
            local cmp_out cmp_status cmp_reason cmp_len_b cmp_len_a
            cmp_out=$(compare_html_files "$html_vorher" "$html_nachher" "$html_diff")
            IFS='|' read -r cmp_status cmp_reason cmp_len_b cmp_len_a <<< "$cmp_out"

            local diff_json_val="null"
            [ -f "$html_diff" ] && diff_json_val="\"$(json_escape "$html_diff_rel")\""

            if [ "$cmp_status" == "rot" ]; then
                log_check_item "ROT" "HTML-Vergleich für '$p': $cmp_reason" "$run_log" "Diff prüfen: $html_diff"
                status_reasons+=("HTML-Vergleich '$p': $cmp_reason")
                final_status="rot"
                final_exitcode=2
            elif [ "$cmp_status" == "gelb" ]; then
                log_check_item "WARN" "HTML-Vergleich für '$p': $cmp_reason" "$run_log" "Diff prüfen: $html_diff"
                status_reasons+=("HTML-Vergleich '$p': $cmp_reason")
                [ "$final_exitcode" -lt 1 ] && final_exitcode=1
                [ "$final_status" == "gruen" ] && final_status="gelb"
            else
                log_check_item "OK" "HTML-Vergleich für '$p' unauffällig ($cmp_reason)" "$run_log"
            fi

            html_results+=("{\"pfad\": \"$(json_escape "$p")\", \"vorher\": \"$(json_escape "$html_vorher_rel")\", \"nachher\": \"$(json_escape "$html_nachher_rel")\", \"diff\": $diff_json_val, \"textlaenge_vorher\": ${cmp_len_b:-0}, \"textlaenge_nachher\": ${cmp_len_a:-0}, \"status\": \"$(json_escape "$cmp_status")\"}")
        fi
    done

    # Visueller Screenshot-Vergleich nach Update
    if [ "$do_screenshots" == "true" ]; then
        echo
        echo "==================================================" | tee -a "$run_log"
        echo "Führe visuellen Screenshot-Vergleich nach Update durch (Gotenberg 9) ..." | tee -a "$run_log"
        echo "==================================================" | tee -a "$run_log"

        local thresh_warn="${SCREENSHOT_DIFF_THRESHOLD_WARN:-1.0}"
        local thresh_fail="${SCREENSHOT_DIFF_THRESHOLD_FAIL:-5.0}"

        for s_task in "${screenshot_tasks[@]}"; do
            IFS='|' read -r s_url s_slug s_label s_width <<< "$s_task"
            local file_vorher="$screenshots_dir/vorher_${s_slug}_${s_width}.png"
            local file_nachher="$screenshots_dir/nachher_${s_slug}_${s_width}.png"
            local file_diff="$screenshots_dir/diff_${s_slug}_${s_width}.png"
            local vorher_rel_path="screenshots/vorher_${s_slug}_${s_width}.png"
            local nachher_rel_path="screenshots/nachher_${s_slug}_${s_width}.png"
            local diff_rel_path="screenshots/diff_${s_slug}_${s_width}.png"

            if [ -f "$file_vorher" ]; then
                echo "  Erstelle Nachher-Screenshot für $s_label ($s_width px) ..." | tee -a "$run_log"
                if capture_screenshot "$s_url" "$file_nachher" "$s_width" "${SCREENSHOT_WAIT:-5s}" "$SCREENSHOT_COOKIES" "$run_log"; then
                    local tmp_before tmp_after
                    tmp_before="$(mktemp "/tmp/wp_s_bef_XXXXXX.png" 2>/dev/null || echo "/tmp/wp_s_bef_$$.png")"
                    tmp_after="$(mktemp "/tmp/wp_s_aft_XXXXXX.png" 2>/dev/null || echo "/tmp/wp_s_aft_$$.png")"
                    cp -f "$file_vorher" "$tmp_before" 2>/dev/null || true
                    cp -f "$file_nachher" "$tmp_after" 2>/dev/null || true

                    if [ -n "$SCREENSHOT_IGNORE_RECTS" ]; then
                        apply_ignore_rectangles "$tmp_before" "$SCREENSHOT_IGNORE_RECTS" "$s_width"
                        apply_ignore_rectangles "$tmp_after" "$SCREENSHOT_IGNORE_RECTS" "$s_width"
                    fi

                    local diff_pct
                    diff_pct=$(compare_screenshots "$tmp_before" "$tmp_after" "$file_diff")
                    rm -f "$tmp_before" "$tmp_after" 2>/dev/null || true

                    local diff_float="${diff_pct:-0.00}"
                    local is_fail=0
                    local is_warn=0

                    if awk "BEGIN {exit ($diff_float > $thresh_fail ? 0 : 1)}" 2>/dev/null; then
                        is_fail=1
                    elif awk "BEGIN {exit ($diff_float >= $thresh_warn ? 0 : 1)}" 2>/dev/null; then
                        is_warn=1
                    fi

                    if [ "$is_fail" -eq 1 ]; then
                        log_check_item "ROT" "Visuelle Abweichung auf $s_label ($s_width px) beträgt ${diff_float}% (Grenzwert: ${thresh_fail}%)!" "$run_log" "Differenzbild prüfen: $file_diff"
                        status_reasons+=("Visuelle Abweichung auf $s_label ($s_width px) beträgt ${diff_float}%")
                        final_status="rot"
                        final_exitcode=2
                        screenshot_results+=("{\"url\": \"$(json_escape "$s_url")\", \"label\": \"$(json_escape "$s_label")\", \"width\": $s_width, \"vorher\": \"$vorher_rel_path\", \"nachher\": \"$nachher_rel_path\", \"diff\": \"$diff_rel_path\", \"abweichung_prozent\": $diff_float, \"status\": \"rot\"}")
                    elif [ "$is_warn" -eq 1 ]; then
                        log_check_item "WARN" "Visuelle Abweichung auf $s_label ($s_width px) beträgt ${diff_float}% (Grenzwert: ${thresh_warn}%)" "$run_log" "Differenzbild prüfen: $file_diff"
                        status_reasons+=("Visuelle Abweichung auf $s_label ($s_width px) beträgt ${diff_float}%")
                        [ "$final_exitcode" -lt 1 ] && final_exitcode=1
                        [ "$final_status" == "gruen" ] && final_status="gelb"
                        screenshot_results+=("{\"url\": \"$(json_escape "$s_url")\", \"label\": \"$(json_escape "$s_label")\", \"width\": $s_width, \"vorher\": \"$vorher_rel_path\", \"nachher\": \"$nachher_rel_path\", \"diff\": \"$diff_rel_path\", \"abweichung_prozent\": $diff_float, \"status\": \"gelb\"}")
                    else
                        log_check_item "OK" "Visuelle Prüfung für $s_label ($s_width px) erfolgreich (Abweichung: ${diff_float}%)" "$run_log"
                        screenshot_results+=("{\"url\": \"$(json_escape "$s_url")\", \"label\": \"$(json_escape "$s_label")\", \"width\": $s_width, \"vorher\": \"$vorher_rel_path\", \"nachher\": \"$nachher_rel_path\", \"diff\": \"$diff_rel_path\", \"abweichung_prozent\": $diff_float, \"status\": \"gruen\"}")
                    fi
                else
                    log_check_item "WARN" "Nachher-Screenshot für $s_label ($s_width px) konnte nicht geladen werden" "$run_log"
                    gotenberg_error_occurred="true"
                    screenshot_results+=("{\"url\": \"$(json_escape "$s_url")\", \"label\": \"$(json_escape "$s_label")\", \"width\": $s_width, \"vorher\": \"$vorher_rel_path\", \"nachher\": null, \"diff\": null, \"abweichung_prozent\": null, \"status\": \"fehler\"}")
                fi
            else
                log_check_item "WARN" "Vorher-Screenshot für $s_label ($s_width px) fehlt - Vergleich übersprungen" "$run_log"
                gotenberg_error_occurred="true"
            fi
        done

        if [ "$gotenberg_error_occurred" == "true" ]; then
            log_check_item "WARN" "Optik-Prüfung unvollständig: Screenshot-Dienst (Gotenberg) nicht erreichbar oder Antwort fehlerhaft" "$run_log"
            status_reasons+=("Screenshot-Dienst nicht erreichbar")
            [ "$final_exitcode" -lt 1 ] && final_exitcode=1
            [ "$final_status" == "gruen" ] && final_status="gelb"
        fi
    fi

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

    local screenshots_json="["
    local sc_first=1
    for sc_res in "${screenshot_results[@]}"; do
        [ "$sc_first" -eq 1 ] && sc_first=0 || screenshots_json+=", "
        screenshots_json+="$sc_res"
    done
    screenshots_json+="]"

    local html_vergleiche_json="["
    local hv_first=1
    for hv_res in "${html_results[@]}"; do
        [ "$hv_first" -eq 1 ] && hv_first=0 || html_vergleiche_json+=", "
        html_vergleiche_json+="$hv_res"
    done
    html_vergleiche_json+="]"

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
  "html_vergleiche": $html_vergleiche_json,
  "screenshots": $screenshots_json,
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
        echo "  5) Gotenberg Screenshot-Verbindung testen"
        echo "  6) Letzte Läufe anzeigen"
        echo "  7) Rollback-Befehle des letzten Laufs"
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
                local test_u="https://example.com"
                if [ "${#update_files[@]}" -gt 0 ]; then
                    local site_url_preview=""
                    local SITE_URL=""
                    # shellcheck source=/dev/null
                    source "${update_files[0]}"
                    site_url_preview="$SITE_URL"
                    [ -n "$site_url_preview" ] && test_u="$site_url_preview"
                fi
                read -rp "Zu testende URL [$test_u]: " in_t_url
                test_gotenberg_connection "${in_t_url:-$test_u}"
                ;;
            6)
                show_last_runs
                ;;
            7)
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

# Selbstinstallation beim ersten Aufruf oder bei --setup / --test-screenshot
if [ "$cli_test_screenshot" == "true" ]; then
    test_target="${cli_test_screenshot_url:-}"
    if [ -z "$test_target" ] && [ -n "$cli_project" ] && [ "$cli_project" != "alle" ]; then
        match_file="$basename/.update.$cli_project"
        if [ -f "$match_file" ]; then
            # shellcheck source=/dev/null
            source "$match_file"
            test_target="$SITE_URL"
        fi
    fi
    if [ -z "$test_target" ]; then
        refresh_update_configs
        if [ "${#update_files[@]}" -gt 0 ]; then
            # shellcheck source=/dev/null
            source "${update_files[0]}"
            test_target="$SITE_URL"
        fi
    fi
    test_target="${test_target:-https://example.com}"
    test_gotenberg_connection "$test_target"
    exit $?
fi

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
    update_project_exitcode=$?
    if [ "$update_project_exitcode" -gt "$overall_update_exitcode" ]; then
        overall_update_exitcode="$update_project_exitcode"
    fi
done

# Wenn --json aktiv ist, geben wir das finale JSON auf stdout (fd 3) aus
if [ "$cli_json" == "true" ]; then
    if [ "${#all_update_json_results[@]}" -eq 1 ] && [ "$cli_project" != "alle" ]; then
        echo "${all_update_json_results[0]}" >&3
    else
        out_json=$'[\n'
        out_first=1
        for res_item in "${all_update_json_results[@]}"; do
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

exit "$overall_update_exitcode"
