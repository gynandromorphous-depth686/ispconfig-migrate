#!/usr/bin/env bash
# ==============================================================
# 01-hardening.sh
# LAMP stack hardening for Debian 13 + ISPConfig
#
# What this script does:
#   - Apache: security headers, ServerTokens Prod, disable default site
#   - PHP: installs PHP 7.4 and 8.1 via Ondrej Sury repo with all
#     extensions needed for WordPress / CakePHP / Joomla stacks
#   - MariaDB: secure install equivalent (non-interactive)
#   - CSF: installs from configserver.dev, applies port rules
#   - Maldet: installs from rfxn.com, applies settings
#   - Fail2ban: configures for CSF coexistence with Apache jails
#   - Certbot timer: enables auto-renewal
#
# Usage:
#   1. Copy config.env.example to config.env and fill in values
#   2. Run as root on the NEW server: bash 01-hardening.sh
#
# Requirements:
#   - Debian 13 (trixie)
#   - ISPConfig already installed
#   - Apache 2.4, MariaDB, Certbot already present (ISPConfig provides these)
# ==============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${SCRIPT_DIR}/../config.env"

if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: config.env not found. Copy config.env.example to config.env and fill in values."
  exit 1
fi

source "$CONFIG"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Run as root."
  exit 1
fi

echo "================================================================"
echo " ispconfig-migrate: LAMP hardening"
echo " Server: $(hostname)"
echo "================================================================"

# ----------------------------------------------------------------
# Apache hardening
# ----------------------------------------------------------------
echo "[1/6] Apache hardening..."

a2enmod proxy_fcgi setenvif headers rewrite ssl 2>/dev/null || true
a2dissite 000-default.conf 2>/dev/null || true

sed -i 's/^ServerTokens.*/ServerTokens Prod/' /etc/apache2/conf-available/security.conf
sed -i 's/^ServerSignature.*/ServerSignature Off/' /etc/apache2/conf-available/security.conf

cat > /etc/apache2/conf-available/security-headers.conf << 'EOF'
Header always set X-Frame-Options "SAMEORIGIN"
Header always set X-Content-Type-Options "nosniff"
Header always set Referrer-Policy "strict-origin-when-cross-origin"
Header always set Permissions-Policy "geolocation=(), microphone=(), camera=()"
EOF

a2enconf security-headers 2>/dev/null || true
apache2ctl configtest && systemctl reload apache2
echo "   DONE Apache hardening"

# ----------------------------------------------------------------
# PHP via Ondrej Sury repo
# ----------------------------------------------------------------
echo "[2/6] PHP 7.4 + 8.1 installation..."

# Verify Sury repo is present
if ! grep -r "sury" /etc/apt/sources.list.d/ &>/dev/null; then
  curl -sSLo /tmp/php.gpg https://packages.sury.org/php/apt.gpg
  gpg --dearmor < /tmp/php.gpg > /usr/share/keyrings/sury-php.gpg
  echo "deb [signed-by=/usr/share/keyrings/sury-php.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" \
    > /etc/apt/sources.list.d/sury-php.list
  apt update -q
fi

PHP_EXTENSIONS="fpm mysql curl gd mbstring xml zip intl bcmath imagick opcache"

for VER in 7.4 8.1; do
  PKGS=""
  for EXT in $PHP_EXTENSIONS; do
    PKGS="$PKGS php${VER}-${EXT}"
  done
  apt install -y $PKGS
  systemctl enable php${VER}-fpm
  systemctl start php${VER}-fpm
  echo "   DONE PHP ${VER}"
done

# ----------------------------------------------------------------
# MariaDB secure install
# ----------------------------------------------------------------
echo "[3/6] MariaDB secure install..."

mysql -uroot -p"${NEW_MYSQL_ROOT_PASS}" << 'EOSQL'
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOSQL
echo "   DONE MariaDB"

# ----------------------------------------------------------------
# CSF firewall
# ----------------------------------------------------------------
echo "[4/6] CSF install..."

# TCP port lists — 8080/8081 are required for ISPConfig panel access
TCP_IN="${CSF_TCP_IN:-"20,21,22,25,53,80,110,143,443,465,587,993,995,8080,8081,4500:4600"}"
TCP_OUT="${CSF_TCP_OUT:-"20,21,22,25,53,80,443,3306"}"

if ! command -v csf &>/dev/null; then
  cd /tmp
  wget -q https://download.configserver.dev/csf.tgz
  tar xzf csf.tgz
  cd /tmp/csf && sh install.sh
fi

sed -i "s/^TCP_IN =.*/TCP_IN = \"${TCP_IN}\"/" /etc/csf/csf.conf
sed -i "s/^TCP_OUT =.*/TCP_OUT = \"${TCP_OUT}\"/" /etc/csf/csf.conf
sed -i 's/^TESTING =.*/TESTING = "0"/' /etc/csf/csf.conf
# Safer SSH ban: temp instead of permanent
sed -i 's/^LF_SSHD_PERM =.*/LF_SSHD_PERM = "0"/' /etc/csf/csf.conf
sed -i 's/^LF_SSHD =.*/LF_SSHD = "10"/' /etc/csf/csf.conf

csf -r
systemctl enable csf lfd 2>/dev/null || true
echo "   DONE CSF"

# ----------------------------------------------------------------
# Maldet
# ----------------------------------------------------------------
echo "[5/6] Maldet install..."

if ! command -v maldet &>/dev/null; then
  cd /tmp
  wget -q https://www.rfxn.com/downloads/maldetect-current.tar.gz
  MALDIR=$(tar tzf maldetect-current.tar.gz | head -1 | cut -d/ -f1)
  tar xzf maldetect-current.tar.gz
  cd /tmp/${MALDIR} && sh install.sh
fi

sed -i 's/^email_alert=.*/email_alert="0"/' /usr/local/maldetect/conf.maldet
sed -i 's/^quarantine_hits=.*/quarantine_hits="0"/' /usr/local/maldetect/conf.maldet
sed -i 's/^autoupdate_signatures=.*/autoupdate_signatures="1"/' /usr/local/maldetect/conf.maldet
sed -i 's/^scan_clamscan=.*/scan_clamscan="1"/' /usr/local/maldetect/conf.maldet
echo "   DONE Maldet"

# ----------------------------------------------------------------
# Fail2ban
# ----------------------------------------------------------------
echo "[6/6] Fail2ban configuration..."

cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
backend = systemd
bantime  = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
port    = ssh
filter  = sshd

[apache-auth]
enabled  = true
port     = http,https
filter   = apache-auth
logpath  = /var/log/ispconfig/httpd/*/error*.log
           /var/log/apache2/error.log

[apache-badbots]
enabled  = true
port     = http,https
filter   = apache-badbots
logpath  = /var/log/ispconfig/httpd/*/access*.log
           /var/log/apache2/access.log
maxretry = 1
EOF

# Disable iptables actions that conflict with CSF
cat > /etc/fail2ban/action.d/iptables-allports.local << 'EOF'
[Definition]
actionban =
actionunban =
EOF

systemctl restart fail2ban
echo "   DONE Fail2ban"

# ----------------------------------------------------------------
# Certbot auto-renewal
# ----------------------------------------------------------------
systemctl enable certbot.timer && systemctl start certbot.timer

echo ""
echo "================================================================"
echo " Hardening complete."
echo " Verify with: csf -v && fail2ban-client status && maldet -v"
echo "================================================================"
