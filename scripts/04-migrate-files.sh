#!/usr/bin/env bash
# ==============================================================
# 04-migrate-files.sh
# Rsync web files from old server to ISPConfig document roots
#
# Pulls files from the old server to the new server's ISPConfig
# document roots. Run as root on the NEW server.
#
# Usage:
#   1. Fill in config.env
#   2. Edit the SITES array below
#   3. bash 04-migrate-files.sh
# ==============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${SCRIPT_DIR}/../config.env"
source "$CONFIG"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Run as root."
  exit 1
fi

DB_PASS="${NEW_MYSQL_ROOT_PASS}"

# ----------------------------------------------------------------
# Edit: map each domain to its OLD document root path
# ----------------------------------------------------------------
declare -A OLD_PATHS=(
  # ["www.example.com"]="/var/www/e/www.example.com/html/"
  ["www.example.com"]="/var/www/e/www.example.com/html/"
)

# ----------------------------------------------------------------
# Migrate each site
# ----------------------------------------------------------------
for DOMAIN in "${!OLD_PATHS[@]}"; do
  OLD_PATH="${OLD_PATHS[$DOMAIN]}"

  # Get ISPConfig document root from DB
  NEW_ROOT=$(mysql -uroot -p"${DB_PASS}" dbispconfig -se \
    "SELECT document_root FROM web_domain WHERE domain='${DOMAIN}';" 2>/dev/null)
  SYS_USER=$(mysql -uroot -p"${DB_PASS}" dbispconfig -se \
    "SELECT system_user FROM web_domain WHERE domain='${DOMAIN}';" 2>/dev/null)
  SYS_GROUP=$(mysql -uroot -p"${DB_PASS}" dbispconfig -se \
    "SELECT system_group FROM web_domain WHERE domain='${DOMAIN}';" 2>/dev/null)

  if [[ -z "$NEW_ROOT" ]]; then
    echo "WARN: $DOMAIN not found in ISPConfig DB, skipping."
    continue
  fi

  NEW_PATH="${NEW_ROOT}/web/"
  echo "=== $DOMAIN ==="
  echo "    FROM: ${OLD_SERVER_USER}@${OLD_SERVER_HOST}:${OLD_PATH}"
  echo "    TO:   ${NEW_PATH}"

  rsync -az --delete \
    --exclude='.git/' \
    --exclude='wp-content/cache/' \
    --exclude='var/cache/' \
    --exclude='tmp/' \
    --exclude='.ftpquota' \
    -e "ssh -p ${OLD_SERVER_PORT} -o StrictHostKeyChecking=no" \
    "${OLD_SERVER_USER}@${OLD_SERVER_HOST}:${OLD_PATH}" \
    "${NEW_PATH}" 2>&1 | grep -v "^$" || true

  # Fix ownership
  chown -R "${SYS_USER}:${SYS_GROUP}" "${NEW_PATH}" 2>/dev/null || true
  find "${NEW_PATH}" -type d -exec chmod 755 {} \; 2>/dev/null || true
  find "${NEW_PATH}" -type f -exec chmod 644 {} \; 2>/dev/null || true

  COUNT=$(find "${NEW_PATH}" -type f 2>/dev/null | wc -l)
  echo "    files synced: ${COUNT}"
  echo ""
done

echo "File migration complete."
