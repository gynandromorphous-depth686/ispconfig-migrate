#!/usr/bin/env bash
# ==============================================================
# 00-install.sh
# Universal LAMP + ISPConfig installer with hardening
#
# Supported distributions:
#   - Debian 11 (Bullseye), 12 (Bookworm), 13 (Trixie)
#   - Ubuntu 22.04 (Jammy), 24.04 (Noble)
#   - RHEL / AlmaLinux / Rocky Linux 8, 9
#   - openSUSE Leap 15.x
#
# What this script does:
#   1. Detects the OS and version
#   2. Installs Apache, MariaDB, PHP (7.4 + 8.1) via the right package manager
#   3. Installs ISPConfig via the official auto-installer
#   4. Hardens with CSF (Debian/Ubuntu), firewalld (RHEL/SUSE), Maldet + ClamAV, Fail2ban
#
# Usage:
#   bash 00-install.sh [--no-ispconfig] [--php-versions "7.4 8.1 8.4"]
#
# Options:
#   --no-ispconfig    Skip ISPConfig installation (LAMP + hardening only)
#   --php-versions    Space-separated list of PHP versions to install (default: "7.4 8.1")
#
# Requirements:
#   - Fresh server (minimal install recommended)
#   - Root access
#   - Internet connectivity
# ==============================================================

set -euo pipefail

# ----------------------------------------------------------------
# Defaults
# ----------------------------------------------------------------
INSTALL_ISPCONFIG=true
PHP_VERSIONS="7.4 8.1"
LOG_FILE="/var/log/ispconfig-install.log"

# ----------------------------------------------------------------
# Argument parsing
# ----------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-ispconfig)   INSTALL_ISPCONFIG=false ;;
    --php-versions)   PHP_VERSIONS="$2"; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
  shift
done

# ----------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------
log()  { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
ok()   { echo "   OK  $*" | tee -a "$LOG_FILE"; }
warn() { echo "  WARN $*" | tee -a "$LOG_FILE"; }
die()  { echo " ERROR $*" | tee -a "$LOG_FILE"; exit 1; }

require_root() {
  [[ $EUID -eq 0 ]] || die "Run as root."
}

# ----------------------------------------------------------------
# OS detection
# ----------------------------------------------------------------
detect_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    OS_ID="${ID,,}"            # debian, ubuntu, rhel, almalinux, rocky, opensuse-leap
    OS_VERSION="${VERSION_ID}" # 11, 12, 22.04, 9, etc.
    # FIX: ${ID_LIKE,,:-} is invalid; use separate default
    OS_LIKE="${ID_LIKE:-}"
    OS_LIKE="${OS_LIKE,,}"
  else
    die "Cannot detect OS: /etc/os-release not found."
  fi

  case "$OS_ID" in
    debian)
      DISTRO_FAMILY="debian"
      PKG_MANAGER="apt"
      ;;
    ubuntu)
      DISTRO_FAMILY="debian"
      PKG_MANAGER="apt"
      ;;
    rhel|almalinux|rocky|centos)
      DISTRO_FAMILY="rhel"
      PKG_MANAGER="dnf"
      ;;
    opensuse-leap|opensuse-tumbleweed|sles)
      DISTRO_FAMILY="suse"
      PKG_MANAGER="zypper"
      ;;
    *)
      # Fallback: check ID_LIKE
      if [[ "$OS_LIKE" == *debian* ]]; then
        DISTRO_FAMILY="debian"; PKG_MANAGER="apt"
      elif [[ "$OS_LIKE" == *rhel* ]] || [[ "$OS_LIKE" == *fedora* ]]; then
        DISTRO_FAMILY="rhel"; PKG_MANAGER="dnf"
      elif [[ "$OS_LIKE" == *suse* ]]; then
        DISTRO_FAMILY="suse"; PKG_MANAGER="zypper"
      else
        die "Unsupported OS: $OS_ID $OS_VERSION"
      fi
      ;;
  esac

  log "Detected: $OS_ID $OS_VERSION (family: $DISTRO_FAMILY)"
}

# ----------------------------------------------------------------
# Package manager wrappers
# ----------------------------------------------------------------
pkg_update() {
  case "$PKG_MANAGER" in
    apt)    apt-get update -q ;;
    dnf)    dnf makecache -q ;;
    zypper) zypper --non-interactive refresh ;;
  esac
}

pkg_install() {
  case "$PKG_MANAGER" in
    apt)    DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$@" ;;
    dnf)    dnf install -y -q "$@" ;;
    zypper) zypper --non-interactive install -y "$@" ;;
  esac
}

# ----------------------------------------------------------------
# PHP repo setup per distro
# Must be called before install_php
# ----------------------------------------------------------------
setup_php_repo() {
  case "$DISTRO_FAMILY" in
    debian)
      if ! grep -rq "sury" /etc/apt/sources.list.d/ 2>/dev/null; then
        log "Adding Ondrej Sury PHP repo..."
        pkg_install curl gnupg2 lsb-release ca-certificates
        curl -sSLo /tmp/php.gpg https://packages.sury.org/php/apt.gpg
        gpg --dearmor < /tmp/php.gpg > /usr/share/keyrings/sury-php.gpg
        echo "deb [signed-by=/usr/share/keyrings/sury-php.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" \
          > /etc/apt/sources.list.d/sury-php.list
        pkg_update
        ok "Sury PHP repo added"
      fi
      ;;
    rhel)
      if ! rpm -q epel-release &>/dev/null; then
        log "Adding EPEL + Remi repo..."
        dnf install -y epel-release
        dnf install -y "https://rpms.remirepo.net/enterprise/remi-release-$(rpm -E '%{rhel}').rpm"
        dnf module reset php -y 2>/dev/null || true
        ok "EPEL + Remi repo added"
      fi
      ;;
    suse)
      if ! zypper repos | grep -q "Packman" 2>/dev/null; then
        log "Adding Packman repo..."
        LEAP_VER=$(echo "$OS_VERSION" | cut -d. -f1,2)
        zypper --non-interactive addrepo -cfp 90 \
          "https://ftp.gwdg.de/pub/linux/misc/packman/suse/openSUSE_Leap_${LEAP_VER}/" packman || true
        zypper --non-interactive refresh || true
        ok "Packman repo added"
      fi
      ;;
  esac
}

# ----------------------------------------------------------------
# Install Apache
# Note: proxy_fcgi requires libapache2-mod-fcgid on Debian
# ----------------------------------------------------------------
install_apache() {
  log "Installing Apache..."
  case "$DISTRO_FAMILY" in
    debian)
      pkg_install apache2 libapache2-mod-fcgid
      a2enmod proxy_fcgi setenvif headers rewrite ssl 2>/dev/null || true
      a2dissite 000-default.conf 2>/dev/null || true
      sed -i 's/^ServerTokens.*/ServerTokens Prod/' /etc/apache2/conf-available/security.conf 2>/dev/null || true
      sed -i 's/^ServerSignature.*/ServerSignature Off/' /etc/apache2/conf-available/security.conf 2>/dev/null || true
      systemctl enable apache2 && systemctl start apache2
      ;;
    rhel)
      pkg_install httpd mod_ssl mod_fcgid
      sed -i 's/^ServerTokens.*/ServerTokens Prod/' /etc/httpd/conf/httpd.conf 2>/dev/null || true
      sed -i 's/^ServerSignature.*/ServerSignature Off/' /etc/httpd/conf/httpd.conf 2>/dev/null || true
      systemctl enable httpd && systemctl start httpd
      ;;
    suse)
      pkg_install apache2 apache2-mod_fcgid
      systemctl enable apache2 && systemctl start apache2
      ;;
  esac
  ok "Apache installed"
}

# ----------------------------------------------------------------
# Install MariaDB
# ----------------------------------------------------------------
install_mariadb() {
  log "Installing MariaDB..."
  case "$DISTRO_FAMILY" in
    debian) pkg_install mariadb-server mariadb-client ;;
    rhel)   pkg_install mariadb-server mariadb ;;
    suse)   pkg_install mariadb mariadb-client ;;
  esac

  systemctl enable mariadb && systemctl start mariadb

  # Secure install (non-interactive equivalent)
  mysql -uroot << 'EOSQL' 2>/dev/null || true
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOSQL
  ok "MariaDB installed and secured"
}

# ----------------------------------------------------------------
# Install PHP (multi-version)
# setup_php_repo must be called first
# ----------------------------------------------------------------
install_php() {
  log "Installing PHP versions: $PHP_VERSIONS"

  PHP_EXTENSIONS="fpm mysql curl gd mbstring xml zip intl bcmath opcache"

  for VER in $PHP_VERSIONS; do
    log "  Installing PHP $VER..."
    case "$DISTRO_FAMILY" in
      debian)
        # FIX: install each package individually so one missing package
        # does not silently skip the entire install under set -e
        for EXT in $PHP_EXTENSIONS; do
          pkg_install "php${VER}-${EXT}" || warn "php${VER}-${EXT} not available"
        done
        pkg_install "php${VER}-imagick" 2>/dev/null || warn "imagick not available for PHP $VER"
        systemctl enable "php${VER}-fpm" && systemctl start "php${VER}-fpm"
        ;;
      rhel)
        # Remi packages are named php74, php81, php84, etc.
        REMI_VER=$(echo "$VER" | tr -d '.')
        for PKG in "php${REMI_VER}" "php${REMI_VER}-php-fpm" "php${REMI_VER}-php-mysqlnd" \
                   "php${REMI_VER}-php-gd" "php${REMI_VER}-php-mbstring" "php${REMI_VER}-php-xml" \
                   "php${REMI_VER}-php-zip" "php${REMI_VER}-php-intl" "php${REMI_VER}-php-bcmath" \
                   "php${REMI_VER}-php-opcache"; do
          dnf install -y "$PKG" 2>/dev/null || warn "$PKG not available"
        done
        systemctl enable "php${REMI_VER}-php-fpm" 2>/dev/null && \
          systemctl start "php${REMI_VER}-php-fpm" 2>/dev/null || true
        ;;
      suse)
        SUSE_VER=$(echo "$VER" | tr -d '.')
        for PKG in "php${SUSE_VER}" "php${SUSE_VER}-fpm" "php${SUSE_VER}-mysql" \
                   "php${SUSE_VER}-curl" "php${SUSE_VER}-gd" "php${SUSE_VER}-mbstring" \
                   "php${SUSE_VER}-xml" "php${SUSE_VER}-zip" "php${SUSE_VER}-bcmath"; do
          zypper --non-interactive install -y "$PKG" 2>/dev/null || warn "$PKG not available"
        done
        systemctl enable php-fpm 2>/dev/null && systemctl start php-fpm 2>/dev/null || true
        ;;
    esac
    ok "PHP $VER installed"
  done
}

# ----------------------------------------------------------------
# Install Certbot
# ----------------------------------------------------------------
install_certbot() {
  log "Installing Certbot..."
  case "$DISTRO_FAMILY" in
    debian)
      pkg_install certbot python3-certbot-apache
      systemctl enable certbot.timer && systemctl start certbot.timer
      ;;
    rhel)
      pkg_install certbot python3-certbot-apache
      systemctl enable certbot-renew.timer && systemctl start certbot-renew.timer
      ;;
    suse)
      pkg_install certbot python3-certbot-apache 2>/dev/null || \
        pkg_install python3-certbot 2>/dev/null || warn "Certbot not available, install manually"
      ;;
  esac
  ok "Certbot installed"
}

# ----------------------------------------------------------------
# ISPConfig auto-installer
# Run BEFORE firewall so outbound HTTPS is not blocked during install
# ----------------------------------------------------------------
install_ispconfig() {
  if [[ "$INSTALL_ISPCONFIG" != true ]]; then
    log "Skipping ISPConfig (--no-ispconfig)"
    return
  fi

  # ISPConfig auto-installer is officially supported on Debian/Ubuntu only
  if [[ "$DISTRO_FAMILY" == "suse" ]]; then
    warn "ISPConfig auto-installer is not officially supported on openSUSE. Skipping."
    warn "See https://www.ispconfig.org/documentation/ for manual install."
    return
  fi

  log "Installing ISPConfig..."
  pkg_install wget curl php-cli php-soap

  # FIX: use the correct URL and a single consistent filename
  local INSTALLER="/tmp/ispconfig_autoinstall.php"
  if [[ ! -f "$INSTALLER" ]]; then
    wget -q -O "$INSTALLER" "https://get.ispconfig.org" \
      || die "Could not download ISPConfig installer from https://get.ispconfig.org"
  fi

  # FIX: quote $PHP_VERSIONS expansion
  php "$INSTALLER" \
    --no-interaction \
    --use-ftp-ports=0 \
    --use-nginx=0 \
    --use-apache=1 \
    --use-php-versions="$(echo "$PHP_VERSIONS" | tr ' ' ',')" \
    2>&1 | tee -a "$LOG_FILE" || \
    warn "ISPConfig installer exited with errors — check $LOG_FILE"

  ok "ISPConfig installed. Panel: https://$(hostname -I | awk '{print $1}'):8080"
}

# ----------------------------------------------------------------
# Firewall: CSF (Debian/Ubuntu), firewalld (RHEL/SUSE)
# Run AFTER ISPConfig so downloads are not blocked
# ----------------------------------------------------------------
install_firewall() {
  log "Installing firewall..."

  case "$DISTRO_FAMILY" in
    debian)
      if ! command -v csf &>/dev/null; then
        pkg_install wget perl libwww-perl libio-socket-ssl-perl
        cd /tmp
        wget -q https://download.configserver.dev/csf.tgz
        tar xzf csf.tgz
        # FIX: use absolute path to avoid issues with symlinked /tmp
        bash /tmp/csf/install.sh
      fi

      TCP_IN="20,21,22,25,53,80,110,143,443,465,587,993,995,8080,8081,4500:4600"
      TCP_OUT="20,21,22,25,53,80,443,3306"

      sed -i "s/^TCP_IN =.*/TCP_IN = \"${TCP_IN}\"/" /etc/csf/csf.conf
      sed -i "s/^TCP_OUT =.*/TCP_OUT = \"${TCP_OUT}\"/" /etc/csf/csf.conf
      sed -i 's/^TESTING =.*/TESTING = "0"/' /etc/csf/csf.conf
      sed -i 's/^LF_SSHD_PERM =.*/LF_SSHD_PERM = "0"/' /etc/csf/csf.conf
      sed -i 's/^LF_SSHD =.*/LF_SSHD = "10"/' /etc/csf/csf.conf

      csf -r
      systemctl enable csf lfd 2>/dev/null || true
      ok "CSF firewall installed"
      ;;

    rhel|suse)
      pkg_install firewalld
      systemctl enable firewalld && systemctl start firewalld

      for PORT in 20 21 22 25 53 80 110 143 443 465 587 993 995 8080 8081; do
        firewall-cmd --permanent --add-port="${PORT}/tcp" 2>/dev/null || true
      done
      firewall-cmd --permanent --add-port=4500-4600/tcp 2>/dev/null || true
      firewall-cmd --reload
      ok "firewalld installed"
      ;;
  esac
}

# ----------------------------------------------------------------
# Maldet + ClamAV
# ----------------------------------------------------------------
install_maldet() {
  log "Installing Maldet + ClamAV..."

  case "$DISTRO_FAMILY" in
    debian) pkg_install clamav clamav-daemon ;;
    rhel)   pkg_install clamav clamav-update clamd ;;
    suse)   pkg_install clamav ;;
  esac

  # Update ClamAV signatures
  systemctl stop clamav-freshclam 2>/dev/null || true
  freshclam 2>/dev/null || true
  systemctl start clamav-freshclam 2>/dev/null || true

  if ! command -v maldet &>/dev/null; then
    cd /tmp
    wget -q https://www.rfxn.com/downloads/maldetect-current.tar.gz
    MALDIR=$(tar tzf maldetect-current.tar.gz | head -1 | cut -d/ -f1)
    tar xzf maldetect-current.tar.gz
    bash "/tmp/${MALDIR}/install.sh"
  fi

  sed -i 's/^email_alert=.*/email_alert="0"/' /usr/local/maldetect/conf.maldet
  sed -i 's/^quarantine_hits=.*/quarantine_hits="0"/' /usr/local/maldetect/conf.maldet
  sed -i 's/^autoupdate_signatures=.*/autoupdate_signatures="1"/' /usr/local/maldetect/conf.maldet
  sed -i 's/^scan_clamscan=.*/scan_clamscan="1"/' /usr/local/maldetect/conf.maldet

  ok "Maldet + ClamAV installed"
}

# ----------------------------------------------------------------
# Fail2ban (Debian/Ubuntu only — RHEL/SUSE rely on firewalld)
# ----------------------------------------------------------------
install_fail2ban() {
  if [[ "$DISTRO_FAMILY" != "debian" ]]; then
    return
  fi

  log "Installing Fail2ban..."
  pkg_install fail2ban

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

  systemctl enable fail2ban && systemctl restart fail2ban
  ok "Fail2ban installed"
}

# ----------------------------------------------------------------
# Apache security headers
# ----------------------------------------------------------------
configure_security_headers() {
  log "Configuring Apache security headers..."
  case "$DISTRO_FAMILY" in
    debian)
      cat > /etc/apache2/conf-available/security-headers.conf << 'EOF'
Header always set X-Frame-Options "SAMEORIGIN"
Header always set X-Content-Type-Options "nosniff"
Header always set Referrer-Policy "strict-origin-when-cross-origin"
Header always set Permissions-Policy "geolocation=(), microphone=(), camera=()"
EOF
      a2enconf security-headers 2>/dev/null || true
      systemctl reload apache2
      ;;
    rhel)
      cat > /etc/httpd/conf.d/security-headers.conf << 'EOF'
Header always set X-Frame-Options "SAMEORIGIN"
Header always set X-Content-Type-Options "nosniff"
Header always set Referrer-Policy "strict-origin-when-cross-origin"
EOF
      systemctl reload httpd
      ;;
    suse)
      cat > /etc/apache2/conf.d/security-headers.conf << 'EOF'
Header always set X-Frame-Options "SAMEORIGIN"
Header always set X-Content-Type-Options "nosniff"
Header always set Referrer-Policy "strict-origin-when-cross-origin"
EOF
      systemctl reload apache2
      ;;
  esac
  ok "Security headers configured"
}

# ----------------------------------------------------------------
# Summary
# ----------------------------------------------------------------
print_summary() {
  echo ""
  echo "================================================================"
  echo " Installation complete!"
  echo " Log: $LOG_FILE"
  echo "----------------------------------------------------------------"
  echo " Distro:   $OS_ID $OS_VERSION"
  echo " Apache:   $(apache2 -v 2>/dev/null | head -1 || httpd -v 2>/dev/null | head -1 || echo 'installed')"
  echo " MariaDB:  $(mysql --version 2>/dev/null || echo 'installed')"
  echo " PHP:      $PHP_VERSIONS"
  if [[ "$INSTALL_ISPCONFIG" == true ]]; then
    echo " ISPConfig: https://$(hostname -I | awk '{print $1}'):8080"
  fi
  echo "================================================================"
}

# ----------------------------------------------------------------
# Main — order matters:
#   1. LAMP stack first (Apache, MariaDB, PHP)
#   2. ISPConfig before firewall (needs outbound HTTPS during install)
#   3. Firewall last (locks down the server)
# ----------------------------------------------------------------
require_root
detect_os
pkg_update

setup_php_repo      # must be before install_php
install_apache
install_mariadb
install_php
install_certbot
install_ispconfig   # before firewall
install_maldet
install_fail2ban
configure_security_headers
install_firewall    # last — locks down outbound after all downloads done
print_summary
