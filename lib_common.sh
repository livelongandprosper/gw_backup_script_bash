#!/bin/bash
# lib_common.sh - Gemeinsame Funktionen für BackupScript und update_wp.sh
# Version: 2.1.0
# (c) Gregor Wendland 2017-2026 /// free to use, free to change, no warranty

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

# Normalisiert Eingaben für den Umfang auf 'alles' / 'db' / 'dateien'
function normalize_scope() {
    case "$1" in
        alles|all|"")
            echo "alles"
            ;;
        db|database|datenbank|datenbanken)
            echo "db"
            ;;
        dateien|files|file)
            echo "dateien"
            ;;
        *)
            echo "$1"
            ;;
    esac
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
    local status="$1"    # "OK", "WARN", "ALERT", "INFO"
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

# Projekt-Konfigurationsdateien ermitteln
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
