#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAIN_SCRIPT="$SCRIPT_DIR/backup_full_db_files_zip.sh"

echo "======================================"
echo "Starte Testsuite für Retention (GVS / Staffel)"
echo "======================================"

TEST_TMP="$(mktemp -d /tmp/backup_retention_test.XXXXXX)"
trap 'rm -rf "$TEST_TMP"' EXIT

# Hilfsfunktion zum Erstellen synthetischer Backup-Sätze
create_synthetic_set() {
    local dir="$1"
    local basis="$2"
    local ts="$3"
    local has_db="$4"
    local has_files="$5"

    mkdir -p "$dir"
    if [ "$has_db" = "1" ]; then
        touch "$dir/${basis}_${ts}_maindb.sql.zip"
    fi
    if [ "$has_files" = "1" ]; then
        touch "$dir/${basis}_${ts}_files.zip"
    fi
}

# -------------------------------------------------------------
# Test 1: Großvater-Vater-Sohn 400-Tage-Staffelung
# -------------------------------------------------------------
echo -n "[Test 1] 400-Tage GVS-Staffelung ... "
T1_DIR="$TEST_TMP/t1_project"
mkdir -p "$T1_DIR/proj1" "$T1_DIR/log" "$T1_DIR/status"
cp "$MAIN_SCRIPT" "$T1_DIR/backup_full_db_files_zip.sh"

cat << 'EOF' > "$T1_DIR/.env.proj1"
PROJECT_NAME='proj1'
PROJEKT_BASIS_DATEINAME='proj1'
DEFAULT_SCOPE='alles'
DB_COUNT='1'
DB_1_NAME='maindb'
SOURCE_FILES_DIR='/tmp'
RETENTION_MODE='staffel'
KEEP_DAILY_DAYS=30
KEEP_WEEKLY_DAYS=90
KEEP_MONTHLY_DAYS=365
KEEP_MIN_SETS=3
RETENTION_REMOTE='no'
BACKUP_LIVE_TIME='0'
DELETE_IF_TRANSMITTED='false'
EOF

now_epoch=$(date +%s)
for ((d=0; d<=400; d++)); do
    day_epoch=$((now_epoch - d * 86400))
    ts="$(date -r "$day_epoch" "+%Y-%m-%d_03-00-00" 2>/dev/null || date -d "@$day_epoch" "+%Y-%m-%d_03-00-00" 2>/dev/null)"
    create_synthetic_set "$T1_DIR/proj1" "proj1" "$ts" 1 1
done

# Dry-run aufrufen
dry_out="$("$T1_DIR/backup_full_db_files_zip.sh" --retention-dry-run --project=proj1)"
echo "$dry_out" | grep -q "Zusammenfassung lokal:" || { echo "FAILED: dry-run summary missing"; exit 1; }

# Echte Bereinigung via Subshell / Helper
(
    cd "$T1_DIR"
    source "$T1_DIR/backup_full_db_files_zip.sh" --source-only
    apply_retention_local "$T1_DIR/.env.proj1" "false" "/dev/null" "true"
)

# Prüfen: Mindestens die letzten 30 Tage müssen noch da sein
for ((d=0; d<=30; d++)); do
    day_epoch=$((now_epoch - d * 86400))
    ts="$(date -r "$day_epoch" "+%Y-%m-%d_03-00-00" 2>/dev/null || date -d "@$day_epoch" "+%Y-%m-%d_03-00-00" 2>/dev/null)"
    [ -f "$T1_DIR/proj1/proj1_${ts}_maindb.sql.zip" ] || { echo "FAILED: Day $d ($ts) was deleted!"; exit 1; }
done

# Älter als 365 Tage muss gelöscht sein
day_old_epoch=$((now_epoch - 380 * 86400))
ts_old="$(date -r "$day_old_epoch" "+%Y-%m-%d_03-00-00" 2>/dev/null || date -d "@$day_old_epoch" "+%Y-%m-%d_03-00-00" 2>/dev/null)"
[ ! -f "$T1_DIR/proj1/proj1_${ts_old}_maindb.sql.zip" ] || { echo "FAILED: Day 380 ($ts_old) was NOT deleted!"; exit 1; }

echo "OK"

# -------------------------------------------------------------
# Test 2: Mindestbestandsschutz (KEEP_MIN_SETS)
# -------------------------------------------------------------
echo -n "[Test 2] Mindestbestandsschutz (KEEP_MIN_SETS=3) bei alten Backups ... "
T2_DIR="$TEST_TMP/t2_project"
mkdir -p "$T2_DIR/proj2" "$T2_DIR/log" "$T2_DIR/status"
cp "$MAIN_SCRIPT" "$T2_DIR/backup_full_db_files_zip.sh"

cat << 'EOF' > "$T2_DIR/.env.proj2"
PROJECT_NAME='proj2'
PROJEKT_BASIS_DATEINAME='proj2'
DEFAULT_SCOPE='alles'
DB_COUNT='1'
DB_1_NAME='maindb'
SOURCE_FILES_DIR='/tmp'
RETENTION_MODE='staffel'
KEEP_DAILY_DAYS=30
KEEP_WEEKLY_DAYS=90
KEEP_MONTHLY_DAYS=365
KEEP_MIN_SETS=3
RETENTION_REMOTE='no'
EOF

# Erstelle nur 2 Sätze mit Alter 500 und 510 Tage
ts1="2024-01-01_03-00-00"
ts2="2024-01-10_03-00-00"
create_synthetic_set "$T2_DIR/proj2" "proj2" "$ts1" 1 1
create_synthetic_set "$T2_DIR/proj2" "proj2" "$ts2" 1 1

(
    cd "$T2_DIR"
    source "$T2_DIR/backup_full_db_files_zip.sh" --source-only
    apply_retention_local "$T2_DIR/.env.proj2" "false" "/dev/null" "true"
)

[ -f "$T2_DIR/proj2/proj2_${ts1}_maindb.sql.zip" ] || { echo "FAILED: Minimum set 1 was deleted!"; exit 1; }
[ -f "$T2_DIR/proj2/proj2_${ts2}_maindb.sql.zip" ] || { echo "FAILED: Minimum set 2 was deleted!"; exit 1; }
echo "OK"

# -------------------------------------------------------------
# Test 3: Behandlung unvollständiger Sätze (< 7d vs > 7d)
# -------------------------------------------------------------
echo -n "[Test 3] Behandlung unvollständiger Sätze ... "
T3_DIR="$TEST_TMP/t3_project"
mkdir -p "$T3_DIR/proj3" "$T3_DIR/log" "$T3_DIR/status"
cp "$MAIN_SCRIPT" "$T3_DIR/backup_full_db_files_zip.sh"

cat << 'EOF' > "$T3_DIR/.env.proj3"
PROJECT_NAME='proj3'
PROJEKT_BASIS_DATEINAME='proj3'
DEFAULT_SCOPE='alles'
DB_COUNT='1'
DB_1_NAME='maindb'
SOURCE_FILES_DIR='/tmp'
RETENTION_MODE='staffel'
KEEP_DAILY_DAYS=30
KEEP_WEEKLY_DAYS=90
KEEP_MONTHLY_DAYS=365
KEEP_MIN_SETS=1
RETENTION_REMOTE='no'
EOF

# 1. Neuer vollständiger Satz heute
ts_today="$(date "+%Y-%m-%d_03-00-00")"
create_synthetic_set "$T3_DIR/proj3" "proj3" "$ts_today" 1 1

# 2. Unvollständiger Satz vor 2 Tagen (nur DB, ohne files) -> muss behalten werden
ts_recent="$(date -r $((now_epoch - 2 * 86400)) "+%Y-%m-%d_03-00-00" 2>/dev/null || date -d "@$((now_epoch - 2 * 86400))" "+%Y-%m-%d_03-00-00" 2>/dev/null)"
create_synthetic_set "$T3_DIR/proj3" "proj3" "$ts_recent" 1 0

# 3. Unvollständiger Satz vor 20 Tagen (nur DB, ohne files) -> muss gelöscht werden (unvollstaendig_alt)
ts_incomp_old="$(date -r $((now_epoch - 20 * 86400)) "+%Y-%m-%d_03-00-00" 2>/dev/null || date -d "@$((now_epoch - 20 * 86400))" "+%Y-%m-%d_03-00-00" 2>/dev/null)"
create_synthetic_set "$T3_DIR/proj3" "proj3" "$ts_incomp_old" 1 0

(
    cd "$T3_DIR"
    source "$T3_DIR/backup_full_db_files_zip.sh" --source-only
    apply_retention_local "$T3_DIR/.env.proj3" "false" "/dev/null" "true"
)

[ -f "$T3_DIR/proj3/proj3_${ts_today}_maindb.sql.zip" ] || { echo "FAILED: Complete set deleted!"; exit 1; }
[ -f "$T3_DIR/proj3/proj3_${ts_recent}_maindb.sql.zip" ] || { echo "FAILED: Recent incomplete set deleted!"; exit 1; }
[ ! -f "$T3_DIR/proj3/proj3_${ts_incomp_old}_maindb.sql.zip" ] || { echo "FAILED: Old incomplete set was NOT deleted!"; exit 1; }
echo "OK"

# -------------------------------------------------------------
# Test 4: Schutz fremder Dateien
# -------------------------------------------------------------
echo -n "[Test 4] Schutz fremder Dateien und Verzeichnisse ... "
touch "$T3_DIR/proj3/.htaccess"
touch "$T3_DIR/proj3/custom.sh"
touch "$T3_DIR/proj3/andere_datei.txt"
touch "$T3_DIR/proj3/fremdprojekt_2020-01-01_03-00-00_files.zip"

(
    cd "$T3_DIR"
    source "$T3_DIR/backup_full_db_files_zip.sh" --source-only
    apply_retention_local "$T3_DIR/.env.proj3" "false" "/dev/null" "true"
)

[ -f "$T3_DIR/proj3/.htaccess" ] || { echo "FAILED: .htaccess was deleted!"; exit 1; }
[ -f "$T3_DIR/proj3/custom.sh" ] || { echo "FAILED: custom.sh was deleted!"; exit 1; }
[ -f "$T3_DIR/proj3/andere_datei.txt" ] || { echo "FAILED: andere_datei.txt was deleted!"; exit 1; }
[ -f "$T3_DIR/proj3/fremdprojekt_2020-01-01_03-00-00_files.zip" ] || { echo "FAILED: foreign project backup was deleted!"; exit 1; }
echo "OK"

# -------------------------------------------------------------
# Test 5: Abwärtskompatibilität bestehender .env
# -------------------------------------------------------------
echo -n "[Test 5] Abwärtskompatibilität (.env ohne RETENTION_MODE) ... "
T5_DIR="$TEST_TMP/t5_project"
mkdir -p "$T5_DIR/proj5a" "$T5_DIR/log" "$T5_DIR/status"

# Fall A: BACKUP_LIVE_TIME=0 -> Modus 'aus'
cat << 'EOF' > "$T5_DIR/.env.proj5a"
PROJECT_NAME='proj5a'
PROJEKT_BASIS_DATEINAME='proj5a'
DEFAULT_SCOPE='alles'
DB_COUNT='1'
DB_1_NAME='maindb'
SOURCE_FILES_DIR='/tmp'
BACKUP_LIVE_TIME='0'
EOF

ts_old1="2020-01-01_03-00-00"
create_synthetic_set "$T5_DIR/proj5a" "proj5a" "$ts_old1" 1 1

(
    cd "$T5_DIR"
    source "$MAIN_SCRIPT" --source-only
    apply_retention_local "$T5_DIR/.env.proj5a" "false" "/dev/null" "true"
)

[ -f "$T5_DIR/proj5a/proj5a_${ts_old1}_maindb.sql.zip" ] || { echo "FAILED: Modus 'aus' deleted old backup!"; exit 1; }

# Fall B: BACKUP_LIVE_TIME=14 -> Modus 'tage' mit 14 Tagen
cat << 'EOF' > "$T5_DIR/.env.proj5b"
PROJECT_NAME='proj5b'
PROJEKT_BASIS_DATEINAME='proj5b'
DEFAULT_SCOPE='alles'
DB_COUNT='1'
DB_1_NAME='maindb'
SOURCE_FILES_DIR='/tmp'
BACKUP_LIVE_TIME='14'
KEEP_MIN_SETS=1
EOF

mkdir -p "$T5_DIR/proj5b"
ts_new="2026-11-26_03-00-00"
ts_old_20d="$(date -r $((now_epoch - 20 * 86400)) "+%Y-%m-%d_03-00-00" 2>/dev/null || date -d "@$((now_epoch - 20 * 86400))" "+%Y-%m-%d_03-00-00" 2>/dev/null)"
create_synthetic_set "$T5_DIR/proj5b" "proj5b" "$ts_new" 1 1
create_synthetic_set "$T5_DIR/proj5b" "proj5b" "$ts_old_20d" 1 1

(
    cd "$T5_DIR"
    source "$MAIN_SCRIPT" --source-only
    apply_retention_local "$T5_DIR/.env.proj5b" "false" "/dev/null" "true"
)

[ -f "$T5_DIR/proj5b/proj5b_${ts_new}_maindb.sql.zip" ] || { echo "FAILED: New set in tage mode deleted!"; exit 1; }
[ ! -f "$T5_DIR/proj5b/proj5b_${ts_old_20d}_maindb.sql.zip" ] || { echo "FAILED: 20-day old set in 14-day tage mode was NOT deleted!"; exit 1; }

echo "OK"

# -------------------------------------------------------------
# Test 6: Konvertierung nach 'staffel' mit .bak Sicherung
# -------------------------------------------------------------
echo -n "[Test 6] Konvertierung nach 'staffel' mit .bak Sicherung ... "
T6_DIR="$TEST_TMP/t6_project"
mkdir -p "$T6_DIR"

cat << 'EOF' > "$T6_DIR/.env.legacy"
PROJECT_NAME='legacy'
PROJEKT_BASIS_DATEINAME='legacy'
DEFAULT_SCOPE='alles'
BACKUP_LIVE_TIME='14'
EOF

(
    cd "$T6_DIR"
    source "$MAIN_SCRIPT" --source-only
    convert_project_env_to_staffel "$T6_DIR/.env.legacy"
)

[ -f "$T6_DIR/.env.legacy.bak" ] || { echo "FAILED: .bak file not created!"; exit 1; }
grep -q "BACKUP_LIVE_TIME='14'" "$T6_DIR/.env.legacy.bak" || { echo "FAILED: .bak content incorrect!"; exit 1; }
grep -q "RETENTION_MODE='staffel'" "$T6_DIR/.env.legacy" || { echo "FAILED: RETENTION_MODE not added to converted file!"; exit 1; }
grep -q "KEEP_DAILY_DAYS=14" "$T6_DIR/.env.legacy" || { echo "FAILED: KEEP_DAILY_DAYS not preserved from BACKUP_LIVE_TIME!"; exit 1; }

echo "OK"

# -------------------------------------------------------------
# Test 7: Sicherheitsbarriere bei fehlerhaftem Backup-Lauf
# -------------------------------------------------------------
echo -n "[Test 7] Sicherheitsbarriere bei Backup-Fehlschlag ... "
T7_DIR="$TEST_TMP/t7_project"
mkdir -p "$T7_DIR/proj7" "$T7_DIR/log" "$T7_DIR/status" "$T7_DIR/source"
echo "test data" > "$T7_DIR/source/test.txt"

cat << EOF > "$T7_DIR/.env.proj7"
PROJECT_NAME='proj7'
PROJEKT_BASIS_DATEINAME='proj7'
DEFAULT_SCOPE='alles'
DB_COUNT='1'
DB_1_NAME='maindb'
DB_1_HOST='nonexistent_db_host_for_test'
SOURCE_FILES_DIR='$T7_DIR/source'
RETENTION_MODE='staffel'
KEEP_DAILY_DAYS=30
KEEP_MIN_SETS=1
RETENTION_REMOTE='no'
EOF

# Alten Backup-Satz erstellen (Alter 50 Tage -> müsste bei erfolgreichem Lauf gelöscht werden)
ts_old50="$(date -r $((now_epoch - 50 * 86400)) "+%Y-%m-%d_03-00-00" 2>/dev/null || date -d "@$((now_epoch - 50 * 86400))" "+%Y-%m-%d_03-00-00" 2>/dev/null)"
create_synthetic_set "$T7_DIR/proj7" "proj7" "$ts_old50" 1 1

# Ausführen des Backup-Laufs mit fehlerhaftem DB-Host (sollte scheitern mit Exitcode 2)
set +e
(
    cd "$T7_DIR"
    source "$MAIN_SCRIPT" --source-only
    run_backup_for_project "$T7_DIR/.env.proj7"
) >/dev/null 2>&1
run_rc=$?
set -e

[ "$run_rc" -eq 2 ] || { echo "FAILED: Backup run should have failed with exitcode 2, got $run_rc"; exit 1; }
# Alter Satz MUSS weiterhin existieren, da Retention bei Fehler übersprungen werden muss
[ -f "$T7_DIR/proj7/proj7_${ts_old50}_maindb.sql.zip" ] || { echo "FAILED: Old set was deleted despite backup failure!"; exit 1; }

echo "OK"

# -------------------------------------------------------------
# Test 8: Remote-Fehlertoleranz bei unerreichbarem SFTP-Ziel
# -------------------------------------------------------------
echo -n "[Test 8] Remote-Fehlertoleranz bei SFTP-Fehlern ... "
T8_DIR="$TEST_TMP/t8_project"
mkdir -p "$T8_DIR/proj8" "$T8_DIR/log" "$T8_DIR/status"

cat << 'EOF' > "$T8_DIR/.env.proj8"
PROJECT_NAME='proj8'
PROJEKT_BASIS_DATEINAME='proj8'
DEFAULT_SCOPE='alles'
RETENTION_MODE='staffel'
RETENTION_REMOTE='yes'
SFTP_HOST='127.0.0.1'
SFTP_PORT='65534'
SFTP_USER='dummy'
SFTP_KEY='/nonexistent_key'
EOF

(
    cd "$T8_DIR"
    source "$MAIN_SCRIPT" --source-only
    set +e
    apply_retention_remote "$T8_DIR/.env.proj8" "false" "/dev/null" "true"
    rem_rc=$?
    set -e
    [ "$rem_rc" -ne 0 ] || { echo "FAILED: Remote retention should return non-zero on SFTP connection error"; exit 1; }
    [ -n "$RETENTION_REMOTE_ERROR" ] || { echo "FAILED: RETENTION_REMOTE_ERROR should be populated"; exit 1; }
)

echo "OK"

echo "======================================"
echo "Alle Retention-Tests ERFOLGREICH BESTANDEN!"
echo "======================================"
