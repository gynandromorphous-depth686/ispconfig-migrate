#!/usr/bin/env bash
# ==============================================================
# 05-migrate-databases.sh
# Dump databases from old server and import on new server
#
# Run as root on the NEW server. Dumps are pulled from the old
# server via SSH and saved locally as backup copies.
#
# Usage:
#   1. Fill in config.env
#   2. Edit the DATABASES array below
#   3. bash 05-migrate-databases.sh
# ==============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${SCRIPT_DIR}/../config.env"
source "$CONFIG"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Run as root."
  exit 1
fi

DUMP_DIR="${SCRIPT_DIR}/../dumps"
mkdir -p "$DUMP_DIR"

# ----------------------------------------------------------------
# Edit: map each database to its user and password
# Format: ["db_name"]="db_user:db_password"
# ----------------------------------------------------------------
declare -A DATABASES=(
  # ["mydb"]="mydb_user:mysecretpassword"
  ["example_db"]="example_user:secretpassword"
)

# ----------------------------------------------------------------
# Migrate each database
# ----------------------------------------------------------------
for DB in "${!DATABASES[@]}"; do
  IFS=':' read -r DB_USER DB_PASS <<< "${DATABASES[$DB]}"
  DUMP_FILE="${DUMP_DIR}/${DB}.sql"

  echo "=== $DB ==="

  # Dump from old server
  echo "  Dumping from old server..."
  ssh -p "${OLD_SERVER_PORT}" -o StrictHostKeyChecking=no \
    "${OLD_SERVER_USER}@${OLD_SERVER_HOST}" \
    "mysqldump -uroot -p'${OLD_MYSQL_ROOT_PASS}' \
      --single-transaction --routines --triggers --events --hex-blob \
      '${DB}'" > "$DUMP_FILE" 2>/dev/null

  SIZE=$(du -sh "$DUMP_FILE" | cut -f1)
  echo "  Dump saved: ${DUMP_FILE} (${SIZE})"

  # Create database and user on new server
  mysql -uroot -p"${NEW_MYSQL_ROOT_PASS}" << EOSQL 2>/dev/null
CREATE DATABASE IF NOT EXISTS \`${DB}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT SELECT,INSERT,UPDATE,DELETE,CREATE,DROP,ALTER,INDEX,LOCK TABLES,
      CREATE ROUTINE,ALTER ROUTINE,EXECUTE,REFERENCES,TRIGGER
  ON \`${DB}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOSQL

  # Import
  mysql -uroot -p"${NEW_MYSQL_ROOT_PASS}" "$DB" < "$DUMP_FILE" 2>/dev/null

  # Spot check
  TABLES=$(mysql -uroot -p"${NEW_MYSQL_ROOT_PASS}" "$DB" -se \
    "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB}';" 2>/dev/null)
  echo "  Imported: ${TABLES} tables"
  echo ""
done

echo "Database migration complete. Dumps saved to: ${DUMP_DIR}"
