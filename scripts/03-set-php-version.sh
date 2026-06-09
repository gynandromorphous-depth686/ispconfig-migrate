#!/usr/bin/env bash
# ==============================================================
# 03-set-php-version.sh
# Set PHP version per ISPConfig web site
#
# ISPConfig defaults to the highest installed PHP version.
# This script moves the FPM pool config to the correct PHP
# version directory and updates the Apache vhost socket path.
#
# Usage:
#   Edit the SITES array below, then run as root:
#   bash 03-set-php-version.sh
#
# Format: "domain_id:php_version"
#   domain_id   = ISPConfig web_domain.domain_id
#   php_version = e.g. 7.4, 8.1, 5.6
# ==============================================================

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Run as root."
  exit 1
fi

# ----------------------------------------------------------------
# Edit this array for your sites
# ----------------------------------------------------------------
declare -A SITES=(
  # [domain_id]="php_version"
  ["1"]="7.4"
  ["2"]="7.4"
  # ["8"]="5.6"   # example: old CakePHP needs PHP 5.6
)

# ----------------------------------------------------------------
# Process each site
# ----------------------------------------------------------------
for DOMAIN_ID in "${!SITES[@]}"; do
  PHP_VER="${SITES[$DOMAIN_ID]}"
  POOL_FILE="/etc/php/${PHP_VER}/fpm/pool.d/web${DOMAIN_ID}.conf"
  SOCKET_DIR="/var/lib/php${PHP_VER}-fpm"
  SOCK="${SOCKET_DIR}/web${DOMAIN_ID}.sock"

  echo "=== web${DOMAIN_ID} -> PHP ${PHP_VER} ==="

  # Find current pool file
  CURRENT_POOL=$(find /etc/php/*/fpm/pool.d/ -name "web${DOMAIN_ID}.conf" 2>/dev/null | head -1)
  if [[ -z "$CURRENT_POOL" ]]; then
    echo "  WARN: No FPM pool found for web${DOMAIN_ID}, skipping."
    continue
  fi

  CURRENT_PHP=$(echo "$CURRENT_POOL" | grep -oP '(?<=/etc/php/)[\d.]+')
  if [[ "$CURRENT_PHP" == "$PHP_VER" ]]; then
    echo "  Already on PHP ${PHP_VER}, skipping."
    continue
  fi

  # Move pool config
  cp "$CURRENT_POOL" "$POOL_FILE"
  mkdir -p "$SOCKET_DIR"
  sed -i "s|/var/lib/php${CURRENT_PHP}-fpm/|${SOCKET_DIR}/|g" "$POOL_FILE"
  rm "$CURRENT_POOL"
  echo "  Moved pool: php${CURRENT_PHP} -> php${PHP_VER}"

  # Update vhost socket reference
  VHOST=$(grep -rl "php${CURRENT_PHP}-fpm/web${DOMAIN_ID}.sock" \
    /etc/apache2/sites-enabled/ 2>/dev/null | head -1)
  if [[ -n "$VHOST" ]]; then
    sed -i "s|/var/lib/php${CURRENT_PHP}-fpm/web${DOMAIN_ID}.sock|${SOCK}|g" "$VHOST"
    echo "  Updated vhost: $VHOST"
  fi

  # Restart affected FPM versions
  systemctl restart "php${CURRENT_PHP}-fpm" 2>/dev/null || true
  systemctl restart "php${PHP_VER}-fpm"
  echo "  DONE"
done

# Reload Apache
apache2ctl configtest && systemctl reload apache2
echo ""
echo "All PHP versions set. Verify sockets:"
ls /var/lib/php*-fpm/ 2>/dev/null
