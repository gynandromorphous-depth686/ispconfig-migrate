#!/usr/bin/env bash
# ==============================================================
# collect-inventory.sh
# Gather Apache vhosts, databases, PHP versions, users, and
# cron jobs from an existing server and produce a config.env
# ready for use with the ispconfig-migrate scripts.
#
# Run as root on the OLD server.
#
# What it collects automatically:
#   - Apache vhosts (ServerName, ServerAlias, DocumentRoot, SSL)
#   - PHP version per vhost (from FPM pool, .htaccess, or php_flag)
#   - All MySQL/MariaDB database names (not passwords)
#   - Database credentials auto-detected from wp-config.php,
#     Joomla configuration.php, and .env files in document roots
#   - System users with home dirs that look like web roots
#   - Cron jobs per user
#   - Server software versions
#
# What it leaves as FIXME:
#   - Database passwords it could not find automatically
#   - MySQL root password
#   - New server details (IP, SSH user)
#
# Usage:
#   bash collect-inventory.sh [--output /path/to/config.env]
#   bash collect-inventory.sh [--mysql-root-pass yourpassword]
#
# Output:
#   config.env          — ready for ispconfig-migrate scripts
#   inventory.md        — human-readable full inventory report
# ==============================================================

set -euo pipefail

# ----------------------------------------------------------------
# Defaults
# ----------------------------------------------------------------
OUTPUT_ENV="./config.env"
OUTPUT_MD="./inventory.md"
MYSQL_ROOT_PASS=""

# ----------------------------------------------------------------
# Argument parsing
# ----------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)           OUTPUT_ENV="$2"; shift ;;
    --mysql-root-pass)  MYSQL_ROOT_PASS="$2"; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
  shift
done

# ----------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------
log()  { echo "[$(date '+%H:%M:%S')] $*"; }
warn() { echo "  WARN $*"; }

require_root() {
  [[ $EUID -eq 0 ]] || { echo "ERROR: Run as root."; exit 1; }
}

# Try to run mysql; use password if provided
mysql_cmd() {
  if [[ -n "$MYSQL_ROOT_PASS" ]]; then
    mysql -uroot -p"${MYSQL_ROOT_PASS}" --batch --silent "$@" 2>/dev/null
  else
    # Try without password first (works on fresh installs / unix_socket auth)
    mysql -uroot --batch --silent "$@" 2>/dev/null || \
    mysql -uroot -p --batch --silent "$@" 2>/dev/null || true
  fi
}

# ----------------------------------------------------------------
# Detect Apache config root
# ----------------------------------------------------------------
detect_apache() {
  if command -v apache2 &>/dev/null; then
    APACHE_CMD="apache2"
    APACHE_CTL="apache2ctl"
    VHOST_DIR="/etc/apache2/sites-enabled"
  elif command -v httpd &>/dev/null; then
    APACHE_CMD="httpd"
    APACHE_CTL="httpd"
    VHOST_DIR="/etc/httpd/conf.d"
  else
    warn "Apache not found — skipping vhost detection"
    APACHE_CMD=""
    VHOST_DIR=""
  fi
}

# ----------------------------------------------------------------
# Extract PHP version for a document root
# Checks (in order):
#   1. PHP-FPM pool config referencing this docroot's socket
#   2. .htaccess SetHandler or php_value directives
#   3. .user.ini PHP version hints
# ----------------------------------------------------------------
detect_php_version() {
  local DOCROOT="$1"
  local PHP_VER=""

  # Method 1: look for a PHP-FPM pool whose chdir matches this docroot
  for POOL_DIR in /etc/php/*/fpm/pool.d/ /etc/php-fpm.d/; do
    [[ -d "$POOL_DIR" ]] || continue
    for POOL in "$POOL_DIR"*.conf; do
      [[ -f "$POOL" ]] || continue
      if grep -q "chdir.*${DOCROOT}" "$POOL" 2>/dev/null || \
         grep -q "^; Site:.*$(basename "$DOCROOT")" "$POOL" 2>/dev/null; then
        # Extract version from pool path e.g. /etc/php/7.4/fpm/pool.d/
        PHP_VER=$(echo "$POOL" | grep -oP '(?<=/php/)\d+\.\d+' || true)
        [[ -n "$PHP_VER" ]] && echo "$PHP_VER" && return
      fi
    done
  done

  # Method 2: check .htaccess for SetHandler or FCGIWrapper lines
  local HTACCESS="${DOCROOT}/.htaccess"
  if [[ -f "$HTACCESS" ]]; then
    PHP_VER=$(grep -oP 'php\K\d+\.\d+' "$HTACCESS" 2>/dev/null | head -1 || true)
    [[ -n "$PHP_VER" ]] && echo "$PHP_VER" && return

    # e.g. AddHandler application/x-httpd-php74
    PHP_VER=$(grep -oP 'php\K\d{2}' "$HTACCESS" 2>/dev/null | head -1 || true)
    if [[ -n "$PHP_VER" ]]; then
      echo "${PHP_VER:0:1}.${PHP_VER:1:1}" && return
    fi
  fi

  # Method 3: check active PHP-FPM socket names in vhost config
  # (ISPConfig uses /var/lib/phpX.Y-fpm/webN.sock)
  if [[ -n "$VHOST_DIR" ]]; then
    local MATCH
    MATCH=$(grep -r "$DOCROOT" "$VHOST_DIR" 2>/dev/null | \
            grep -oP 'php\K\d+\.\d+(?=-fpm)' | head -1 || true)
    [[ -n "$MATCH" ]] && echo "$MATCH" && return
  fi

  # Default: system PHP
  php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "unknown"
}

# ----------------------------------------------------------------
# Try to find DB credentials in common CMS config files
# ----------------------------------------------------------------
find_db_credentials() {
  local DOCROOT="$1"
  local DB_NAME="" DB_USER="" DB_PASS=""

  # WordPress
  # FIX: use tail -1 — the regex matches both the key ('DB_NAME') and value ('wordpress_db');
  # head -1 returns the key, tail -1 returns the value we actually want
  local WP_CONFIG="${DOCROOT}/wp-config.php"
  if [[ -f "$WP_CONFIG" ]]; then
    DB_NAME=$(grep "define('DB_NAME'"     "$WP_CONFIG" | grep -oP "(?<=')[^']+(?=')" | tail -1 || true)
    DB_USER=$(grep "define('DB_USER',"    "$WP_CONFIG" | grep -oP "(?<=')[^']+(?=')" | tail -1 || true)
    DB_PASS=$(grep "define('DB_PASSWORD'" "$WP_CONFIG" | grep -oP "(?<=')[^']+(?=')" | tail -1 || true)
    [[ -n "$DB_NAME" ]] && echo "${DB_NAME}:${DB_USER}:${DB_PASS}" && return
  fi

  # Joomla
  local JOOMLA_CONFIG="${DOCROOT}/configuration.php"
  if [[ -f "$JOOMLA_CONFIG" ]]; then
    DB_NAME=$(grep "db ="     "$JOOMLA_CONFIG" | grep -oP "(?<=')[^']+(?=')" | head -1 || true)
    DB_USER=$(grep "user ="   "$JOOMLA_CONFIG" | grep -oP "(?<=')[^']+(?=')" | head -1 || true)
    DB_PASS=$(grep "password =" "$JOOMLA_CONFIG" | grep -oP "(?<=')[^']+(?=')" | head -1 || true)
    [[ -n "$DB_NAME" ]] && echo "${DB_NAME}:${DB_USER}:${DB_PASS}" && return
  fi

  # Laravel / generic .env
  local ENV_FILE="${DOCROOT}/.env"
  if [[ -f "$ENV_FILE" ]]; then
    DB_NAME=$(grep "^DB_DATABASE=" "$ENV_FILE" | cut -d= -f2 | tr -d '"' || true)
    DB_USER=$(grep "^DB_USERNAME=" "$ENV_FILE" | cut -d= -f2 | tr -d '"' || true)
    DB_PASS=$(grep "^DB_PASSWORD=" "$ENV_FILE" | cut -d= -f2 | tr -d '"' || true)
    [[ -n "$DB_NAME" ]] && echo "${DB_NAME}:${DB_USER}:${DB_PASS}" && return
  fi

  # CakePHP app/Config/database.php
  # CakePHP app/Config/database.php
  # FIX: use tail -1 for all fields — key is first match, value is last
  local CAKE_CONFIG="${DOCROOT}/app/Config/database.php"
  if [[ -f "$CAKE_CONFIG" ]]; then
    DB_NAME=$(grep "'database'" "$CAKE_CONFIG" | grep -oP "(?<=')[^']+(?=')" | tail -1 || true)
    DB_USER=$(grep "'login'"    "$CAKE_CONFIG" | grep -oP "(?<=')[^']+(?=')" | tail -1 || true)
    DB_PASS=$(grep "'password'" "$CAKE_CONFIG" | grep -oP "(?<=')[^']+(?=')" | tail -1 || true)
    [[ -n "$DB_NAME" ]] && echo "${DB_NAME}:${DB_USER}:${DB_PASS}" && return
  fi

  echo "::"
}

# ----------------------------------------------------------------
# Collect vhosts
# ----------------------------------------------------------------
collect_vhosts() {
  log "Collecting Apache vhosts..."

  declare -gA VHOST_DOCROOT
  declare -gA VHOST_ALIASES
  declare -gA VHOST_SSL
  declare -gA VHOST_PHP
  declare -gA VHOST_DB_NAME
  declare -gA VHOST_DB_USER
  declare -gA VHOST_DB_PASS
  declare -ga VHOST_DOMAINS

  [[ -z "$VHOST_DIR" ]] && return

  local CURRENT_VHOST=""
  local CURRENT_DOCROOT=""
  local IN_SSL_BLOCK=false

  while IFS= read -r LINE; do
    # ServerName
    if echo "$LINE" | grep -qi "^\s*ServerName "; then
      CURRENT_VHOST=$(echo "$LINE" | awk '{print $2}' | tr '[:upper:]' '[:lower:]')
      # Start port 80 vhosts fresh; skip *:443 duplicates (handled by SSL flag)
      continue
    fi

    # VirtualHost *:443 — mark SSL for current vhost
    if echo "$LINE" | grep -qi "<VirtualHost.*:443>"; then
      IN_SSL_BLOCK=true
      continue
    fi
    if echo "$LINE" | grep -qi "</VirtualHost>"; then
      IN_SSL_BLOCK=false
      CURRENT_VHOST=""
      CURRENT_DOCROOT=""
      continue
    fi

    [[ -z "$CURRENT_VHOST" ]] && continue

    # DocumentRoot
    if echo "$LINE" | grep -qi "^\s*DocumentRoot "; then
      CURRENT_DOCROOT=$(echo "$LINE" | awk '{print $2}' | tr -d '"')
      VHOST_DOCROOT["$CURRENT_VHOST"]="$CURRENT_DOCROOT"
      if [[ ! " ${VHOST_DOMAINS[*]:-} " =~ " ${CURRENT_VHOST} " ]]; then
        VHOST_DOMAINS+=("$CURRENT_VHOST")
      fi
    fi

    # ServerAlias
    if echo "$LINE" | grep -qi "^\s*ServerAlias "; then
      local ALIASES
      ALIASES=$(echo "$LINE" | sed 's/^\s*ServerAlias\s*//' | tr -d '\r')
      VHOST_ALIASES["$CURRENT_VHOST"]="${VHOST_ALIASES[$CURRENT_VHOST]:-} $ALIASES"
    fi

    # SSL
    if $IN_SSL_BLOCK && echo "$LINE" | grep -qi "SSLEngine on"; then
      VHOST_SSL["$CURRENT_VHOST"]="y"
    fi

  done < <(grep -rh "" "$VHOST_DIR" 2>/dev/null | grep -v "^#" | grep -v "^$")

  # Now detect PHP version and DB credentials per vhost
  for DOMAIN in "${VHOST_DOMAINS[@]:-}"; do
    [[ -z "$DOMAIN" ]] && continue
    local DOCROOT="${VHOST_DOCROOT[$DOMAIN]:-}"
    [[ -z "$DOCROOT" ]] && continue

    VHOST_PHP["$DOMAIN"]=$(detect_php_version "$DOCROOT")

    local CREDS
    CREDS=$(find_db_credentials "$DOCROOT")
    VHOST_DB_NAME["$DOMAIN"]=$(echo "$CREDS" | cut -d: -f1)
    VHOST_DB_USER["$DOMAIN"]=$(echo "$CREDS" | cut -d: -f2)
    # FIX: use f3- not f3 so passwords containing colons are preserved in full
    VHOST_DB_PASS["$DOMAIN"]=$(echo "$CREDS" | cut -d: -f3-)
  done

  log "Found ${#VHOST_DOMAINS[@]} vhosts"
}

# ----------------------------------------------------------------
# Collect databases
# ----------------------------------------------------------------
collect_databases() {
  log "Collecting databases..."
  SYSTEM_DBS="information_schema|performance_schema|mysql|sys|phpmyadmin|roundcube|dbispconfig"
  ALL_DBS=$(mysql_cmd -e "SHOW DATABASES;" 2>/dev/null | grep -vE "^($SYSTEM_DBS)$" || true)
  log "Found $(echo "$ALL_DBS" | grep -c . || echo 0) user databases"
}

# ----------------------------------------------------------------
# Collect system info
# ----------------------------------------------------------------
collect_system() {
  log "Collecting system info..."
  SERVER_IP=$(hostname -I | awk '{print $1}')
  SERVER_HOSTNAME=$(hostname -f 2>/dev/null || hostname)
  OS_INFO=$(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '"' || uname -a)
  # FIX: guard against empty APACHE_CMD (apache not found)
  if [[ -n "$APACHE_CMD" ]]; then
    APACHE_VERSION=$("$APACHE_CMD" -v 2>/dev/null | head -1 || echo "unknown")
  else
    APACHE_VERSION="not found"
  fi
  MYSQL_VERSION=$(mysql_cmd -e "SELECT VERSION();" 2>/dev/null || echo "unknown")
  PHP_DEFAULT=$(php -r 'echo PHP_VERSION;' 2>/dev/null || echo "unknown")

  # Installed PHP versions
  PHP_INSTALLED=$(find /etc/php -maxdepth 1 -mindepth 1 -type d 2>/dev/null | \
                  grep -oP '\d+\.\d+' | sort -V | tr '\n' ' ' || echo "$PHP_DEFAULT")
}

# ----------------------------------------------------------------
# Collect cron jobs
# ----------------------------------------------------------------
collect_crons() {
  log "Collecting cron jobs..."
  CRON_OUTPUT=""
  # System crontab
  if [[ -f /etc/crontab ]]; then
    CRON_OUTPUT+="### /etc/crontab ###\n"
    CRON_OUTPUT+=$(grep -v "^#" /etc/crontab | grep -v "^$" || true)
    CRON_OUTPUT+="\n"
  fi
  # User crontabs
  for USER_CRON in /var/spool/cron/crontabs/* /var/spool/cron/*; do
    [[ -f "$USER_CRON" ]] || continue
    local CRON_USER
    CRON_USER=$(basename "$USER_CRON")
    CRON_OUTPUT+="### crontab: $CRON_USER ###\n"
    CRON_OUTPUT+=$(grep -v "^#" "$USER_CRON" | grep -v "^$" || true)
    CRON_OUTPUT+="\n"
  done
}

# ----------------------------------------------------------------
# Write config.env
# ----------------------------------------------------------------
write_config_env() {
  log "Writing $OUTPUT_ENV ..."

  cat > "$OUTPUT_ENV" << ENVEOF
# ==============================================================
# config.env — generated by collect-inventory.sh
# Generated: $(date)
# Old server: ${SERVER_HOSTNAME} (${SERVER_IP})
# ==============================================================
# Instructions:
#   1. Fill in all FIXME: values
#   2. Copy this file to the NEW server as config.env
#   3. Run the ispconfig-migrate scripts
# ==============================================================

# ---- Old server connection ----
OLD_SERVER_HOST="${SERVER_IP}"
OLD_SERVER_PORT="22"
OLD_SERVER_USER="root"

# ---- MySQL / MariaDB ----
# Old server root password — FIXME: fill this in
OLD_MYSQL_ROOT_PASS="FIXME:old_mysql_root_password"

# New server root password — FIXME: fill this in after provisioning
NEW_MYSQL_ROOT_PASS="FIXME:new_mysql_root_password"

# ---- New server ----
# FIXME: set to new server IP or hostname
NEW_SERVER_HOST="FIXME:new_server_ip"

# ---- PHP versions to install on new server ----
PHP_VERSIONS="${PHP_INSTALLED}"

ENVEOF

  # SITES array
  echo "" >> "$OUTPUT_ENV"
  echo "# ---- Sites (auto-detected from Apache vhosts) ----" >> "$OUTPUT_ENV"
  echo "# Format: SITE_<N>_DOMAIN, SITE_<N>_DOCROOT, SITE_<N>_PHP, SITE_<N>_SSL" >> "$OUTPUT_ENV"

  local N=1
  for DOMAIN in "${VHOST_DOMAINS[@]:-}"; do
    [[ -z "$DOMAIN" ]] && continue
    local DOCROOT="${VHOST_DOCROOT[$DOMAIN]:-}"
    local ALIASES="${VHOST_ALIASES[$DOMAIN]:-}"
    local SSL="${VHOST_SSL[$DOMAIN]:-n}"
    local PHP="${VHOST_PHP[$DOMAIN]:-unknown}"
    local DB_NAME="${VHOST_DB_NAME[$DOMAIN]:-}"
    local DB_USER="${VHOST_DB_USER[$DOMAIN]:-}"
    local DB_PASS="${VHOST_DB_PASS[$DOMAIN]:-}"

    cat >> "$OUTPUT_ENV" << SITEEOF

SITE_${N}_DOMAIN="${DOMAIN}"
SITE_${N}_ALIASES="${ALIASES# }"
SITE_${N}_DOCROOT="${DOCROOT}"
SITE_${N}_PHP="${PHP}"
SITE_${N}_SSL="${SSL}"
SITE_${N}_DB_NAME="${DB_NAME:-FIXME:db_name_for_${DOMAIN}}"
SITE_${N}_DB_USER="${DB_USER:-FIXME:db_user_for_${DOMAIN}}"
SITE_${N}_DB_PASS="${DB_PASS:-FIXME:db_password_for_${DOMAIN}}"
SITEEOF

    N=$((N + 1))
  done

  # All databases section
  echo "" >> "$OUTPUT_ENV"
  echo "# ---- All databases on old server ----" >> "$OUTPUT_ENV"
  echo "# Cross-reference with SITE_N_DB_NAME above to verify all are covered" >> "$OUTPUT_ENV"
  while IFS= read -r DB; do
    [[ -z "$DB" ]] && continue
    echo "# DB: $DB" >> "$OUTPUT_ENV"
  done <<< "${ALL_DBS:-}"

  log "Written: $OUTPUT_ENV"
}

# ----------------------------------------------------------------
# Write inventory.md — human-readable report
# ----------------------------------------------------------------
write_inventory_md() {
  log "Writing $OUTPUT_MD ..."

  cat > "$OUTPUT_MD" << MDEOF
# Server inventory report
Generated: $(date)
Host: ${SERVER_HOSTNAME} (${SERVER_IP})

## System
- OS: ${OS_INFO}
- Apache: ${APACHE_VERSION}
- MariaDB/MySQL: ${MYSQL_VERSION}
- PHP (default): ${PHP_DEFAULT}
- PHP (installed): ${PHP_INSTALLED}

## Apache vhosts (${#VHOST_DOMAINS[@]})

| Domain | Document root | Aliases | PHP | SSL | DB name | DB user | DB pass |
|--------|--------------|---------|-----|-----|---------|---------|---------|
MDEOF

  for DOMAIN in "${VHOST_DOMAINS[@]:-}"; do
    [[ -z "$DOMAIN" ]] && continue
    local DOCROOT="${VHOST_DOCROOT[$DOMAIN]:-}"
    local ALIASES="${VHOST_ALIASES[$DOMAIN]:--}"
    local SSL="${VHOST_SSL[$DOMAIN]:-n}"
    local PHP="${VHOST_PHP[$DOMAIN]:-?}"
    local DB_NAME="${VHOST_DB_NAME[$DOMAIN]:--}"
    local DB_USER="${VHOST_DB_USER[$DOMAIN]:--}"
    local DB_PASS="${VHOST_DB_PASS[$DOMAIN]:-FIXME}"
    # Mask password in report: show first 2 chars only
    local DB_PASS_MASKED="${DB_PASS:0:2}****"
    [[ "$DB_PASS" == "FIXME" ]] && DB_PASS_MASKED="FIXME"

    echo "| \`${DOMAIN}\` | \`${DOCROOT}\` | ${ALIASES# } | ${PHP} | ${SSL} | ${DB_NAME} | ${DB_USER} | ${DB_PASS_MASKED} |" \
      >> "$OUTPUT_MD"
  done

  cat >> "$OUTPUT_MD" << MDEOF

## Databases (user databases only)

\`\`\`
${ALL_DBS:-none found}
\`\`\`

## Cron jobs

\`\`\`
$(echo -e "${CRON_OUTPUT:-none}")
\`\`\`

## Review needed

MDEOF

  # Flag any FIXME items
  local FIXME_COUNT=0
  for DOMAIN in "${VHOST_DOMAINS[@]:-}"; do
    [[ -z "$DOMAIN" ]] && continue
    if [[ -z "${VHOST_DB_NAME[$DOMAIN]:-}" ]]; then
      echo "- **${DOMAIN}**: database name not auto-detected — check manually" >> "$OUTPUT_MD"
      FIXME_COUNT=$((FIXME_COUNT + 1))
    fi
    if [[ -z "${VHOST_DB_PASS[$DOMAIN]:-}" ]]; then
      echo "- **${DOMAIN}**: database password not found in config files" >> "$OUTPUT_MD"
      FIXME_COUNT=$((FIXME_COUNT + 1))
    fi
  done

  [[ $FIXME_COUNT -eq 0 ]] && echo "None — all credentials auto-detected." >> "$OUTPUT_MD"

  log "Written: $OUTPUT_MD"
}

# ----------------------------------------------------------------
# Main
# ----------------------------------------------------------------
require_root
detect_apache
collect_system
collect_vhosts
collect_databases
collect_crons
write_config_env
write_inventory_md

echo ""
echo "================================================================"
echo " Inventory complete."
echo " config.env:    $OUTPUT_ENV"
echo " inventory.md:  $OUTPUT_MD"
echo ""
echo " Next steps:"
echo "   1. Open $OUTPUT_ENV and fill in all FIXME: values"
echo "   2. Review $OUTPUT_MD for any missing credentials"
echo "   3. Copy config.env to the new server"
echo "   4. Run the ispconfig-migrate scripts"
echo "================================================================"
