# ispconfig-migrate

Scripts for migrating a LAMP shared hosting server to Debian 13 + ISPConfig,
including server hardening, multi-version PHP setup, and site provisioning via
the ISPConfig SOAP API.

Originally developed by [123Helpdesk](https://www.123helpdesk.nl) during a
real-world migration from Ubuntu 18.04 (Apache / MySQL 5.7 / PHP 7.4) to
Debian 13 (ISPConfig / MariaDB 11 / PHP 7.4 + 8.1).

---

## What this does

| Script | What it does |
|---|---|
| `01-hardening.sh` | Apache security headers, PHP 7.4 + 8.1 via Sury, MariaDB secure install, CSF firewall, Maldet, Fail2ban |
| `02-ispconfig-provision.php` | Creates web domains in ISPConfig via SOAP API |
| `03-set-php-version.sh` | Assigns the correct PHP version per site (moves FPM pool config) |
| `04-migrate-files.sh` | Rsyncs web files from old server to ISPConfig document roots |
| `05-migrate-databases.sh` | Dumps databases from old server and imports on new server |

---

## Requirements

- New server: Debian 13 (trixie) with ISPConfig 3.x pre-installed
- Old server: any Linux with SSH access
- PHP CLI with SOAP extension on the new server
- Root access on both servers

---

## Quick start

```bash
# 1. Clone
git clone https://github.com/yourusername/ispconfig-migrate.git
cd ispconfig-migrate

# 2. Configure
cp config.env.example config.env
nano config.env

# 3. Harden the new server
bash scripts/01-hardening.sh

# 4. Create ISPConfig clients and sites
#    See docs/ispconfig-api-setup.md first
php scripts/02-ispconfig-provision.php

# 5. Set PHP version per site
nano scripts/03-set-php-version.sh   # edit SITES array
bash scripts/03-set-php-version.sh

# 6. Migrate files
nano scripts/04-migrate-files.sh     # edit OLD_PATHS array
bash scripts/04-migrate-files.sh

# 7. Migrate databases
nano scripts/05-migrate-databases.sh # edit DATABASES array
bash scripts/05-migrate-databases.sh
```

---

## ISPConfig API gotchas

The ISPConfig SOAP API has some quirks that took time to figure out:

- **`client_add` schema varies by ISPConfig version.** The `limit_cron_type`
  field is an enum (`url`, `chrooted`, `full`) that the API doesn't document.
  We found direct SQL insertion more reliable for initial client creation.
  See `docs/ispconfig-api-setup.md`.

- **Remote API user must be created separately** from the admin panel login.
  It is NOT the same as the ISPConfig admin user.

- **`pm` field is required and must be `ondemand`, `dynamic`, or `static`.**
  The API returns a cryptic validation error if omitted.

- **PHP version is NOT controlled by `server_php_id` in the API call alone.**
  ISPConfig generates FPM pool configs in the highest installed PHP version's
  directory. Use `03-set-php-version.sh` to move pools after provisioning.

- **`subdomain='www'` with a domain that starts with `www.` creates a
  `www.www.domain.com` alias.** Set `subdomain='none'` for www-prefixed domains.

---

## CSF note

The original ConfigServer Security & Firewall (CSF) was discontinued in
August 2025. The project continues at a new domain:

```
https://download.configserver.dev/csf.tgz
```

The scripts use this new URL. See also the fork maintained by the community:
https://github.com/Aetherinox/csf-firewall

---

## Tested on

- Old server: Ubuntu 18.04 LTS, Apache 2.4, MySQL 5.7, PHP 7.4
- New server: Debian 13 (trixie), ISPConfig 3.2.x, MariaDB 11.8, Apache 2.4.67

---

## License

MIT — use freely, contributions welcome.

---

## About

Made by [123Helpdesk](https://www.123helpdesk.nl), a Dutch web hosting provider
that has been running LAMP servers since 2008.
