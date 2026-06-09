# ISPConfig remote API setup

ISPConfig's SOAP API requires a dedicated remote user. The API user is separate
from the admin panel login. This guide explains how to create one.

## Option 1: via the ISPConfig panel

1. Log in to ISPConfig at `https://yourserver:8080`
2. Go to **System → Remote Users**
3. Click **Add new remote user**
4. Set username and password
5. Under **Functions**, enable the functions you need:
   - `sites_web_domain_add`, `sites_web_domain_get`
   - `client_add`, `client_get`, `client_get_by_username`
   - `sites_database_add`, `sites_database_user_add`
6. Save

## Option 2: directly in the database

If the panel is not yet accessible, insert the remote user directly:

```sql
USE dbispconfig;

INSERT INTO remote_user
  (sys_userid, sys_groupid, sys_perm_user, sys_perm_group, sys_perm_other,
   remote_username, remote_password, remote_access, remote_ips, remote_functions)
VALUES
  (1, 1, 'riud', 'riud', '',
   'remoteapi',
   MD5('your_password_here'),
   'y',
   '',
   'server_get,client_add,client_get,client_get_by_username,sites_web_domain_add,sites_web_domain_get,sites_database_add,sites_database_user_add');
```

Note: ISPConfig stores remote user passwords as plain MD5. Use a strong password
and restrict it to the remote API user only — not the same as your admin password.

## Creating client accounts via SQL

The `client_add` API call requires an exact schema match that varies between
ISPConfig versions. The most reliable approach is to insert clients directly:

```sql
USE dbispconfig;

INSERT INTO client
  (company_name, contact_name, username, password, language, usertheme, country,
   email, internet, locked, canceled, default_webserver, web_servers,
   default_mailserver, default_dnsserver, default_dbserver,
   limit_web_domain, limit_database, limit_database_user, limit_ftp_user,
   limit_shell_user, limit_mailbox, limit_maildomain,
   limit_web_aliasdomain, limit_web_subdomain, limit_dns_zone, limit_dns_record,
   limit_cron, limit_cron_type, limit_cron_frequency, limit_ssl, limit_ssl_letsencrypt,
   sys_userid, sys_groupid, sys_perm_user, sys_perm_group, sys_perm_other)
VALUES
  ('clientname','clientname','clientname', ENCRYPT('password'),
   'nl','default','NL','client@example.com','y','n','n',
   1,'1',1,1,1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
   0,'url',5,'y','y',1,1,'riud','riud','');

-- Also create the required sys_user and sys_group records:
INSERT INTO sys_group (name, description, client_id)
SELECT username, CONCAT('Group for ', username), client_id
FROM client WHERE username='clientname';

INSERT INTO sys_user (username, passwort, modules, startmodule, app_theme,
  typ, active, language, groups, default_group, client_id)
SELECT c.username, c.password,
  'dashboard,sites,mail,dns,tools', 'dashboard', 'default',
  'user', 1, 'nl',
  sg.groupid, sg.groupid, c.client_id
FROM client c
JOIN sys_group sg ON sg.client_id = c.client_id
WHERE c.username = 'clientname';
```
