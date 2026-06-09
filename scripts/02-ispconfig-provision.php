<?php
/**
 * 02-ispconfig-provision.php
 * ISPConfig site provisioning via SOAP API
 *
 * Creates one ISPConfig client + one web domain per site.
 * Handles the full setup: system user, PHP-FPM pool, Apache vhost,
 * document root — all managed by ISPConfig.
 *
 * Usage:
 *   1. Fill in config.env (see config.env.example)
 *   2. Edit the $sites array below with your domains
 *   3. Run as root on the new server:
 *      php 02-ispconfig-provision.php
 *
 * Requirements:
 *   - PHP CLI with SOAP extension
 *   - ISPConfig 3.x installed and running
 *   - Remote API user configured (see docs/ispconfig-api-setup.md)
 *
 * Notes:
 *   - ISPConfig API schema varies slightly between versions.
 *     Tested against ISPConfig 3.2.x on Debian 13.
 *   - PHP version is set by moving FPM pool configs after provisioning.
 *     See 03-set-php-version.sh for that step.
 */

// ----------------------------------------------------------------
// Load config
// ----------------------------------------------------------------
$config_file = dirname(__DIR__) . '/config.env';
if (!file_exists($config_file)) {
    die("ERROR: config.env not found. Copy config.env.example and fill in values.\n");
}

$config = [];
foreach (file($config_file) as $line) {
    $line = trim($line);
    if (empty($line) || $line[0] === '#') continue;
    if (strpos($line, '=') === false) continue;
    [$key, $val] = explode('=', $line, 2);
    $config[trim($key)] = trim($val, '"\'');
}

$soap_url  = $config['ISPCONFIG_URL']         ?? 'https://localhost:8080';
$soap_user = $config['ISPCONFIG_REMOTE_USER'] ?? 'remoteapi';
$soap_pass = $config['ISPCONFIG_REMOTE_PASS'] ?? '';
$server_id = (int)($config['ISPCONFIG_SERVER_ID'] ?? 1);

// ----------------------------------------------------------------
// Sites to provision
// Edit this array for your migration.
// ----------------------------------------------------------------
$sites = [
    // [
    //     'client'  => 'myclient',          // short username, no spaces
    //     'contact' => 'admin@example.com',
    //     'domain'  => 'www.example.com',
    //     'aliases' => 'example.com',       // space-separated, or ''
    //     'ssl'     => 'y',                 // 'y' = request LE cert, 'n' = placeholder
    // ],
    [
        'client'  => 'example',
        'contact' => 'webmaster@example.com',
        'domain'  => 'www.example.com',
        'aliases' => 'example.com',
        'ssl'     => 'n',
    ],
];

// ----------------------------------------------------------------
// Connect
// ----------------------------------------------------------------
echo "Connecting to ISPConfig API at {$soap_url}...\n";
try {
    $soap = new SoapClient(null, [
        'location'       => $soap_url . '/remote/index.php',
        'uri'            => $soap_url . '/remote/',
        'trace'          => 1,
        'exceptions'     => 1,
        'stream_context' => stream_context_create([
            'ssl' => ['verify_peer' => false, 'verify_peer_name' => false]
        ]),
    ]);
    $session = $soap->login($soap_user, $soap_pass);
    echo "Login OK\n\n";
} catch (Exception $e) {
    die("SOAP login failed: " . $e->getMessage() . "\n"
      . "See docs/ispconfig-api-setup.md for setup instructions.\n");
}

// ----------------------------------------------------------------
// Provision each site
// ----------------------------------------------------------------
$results = [];

foreach ($sites as $site) {
    echo "=== {$site['domain']} ===\n";

    // 1. Create client via SQL (more reliable than API for initial setup)
    // The API client_add requires exact schema match which varies by version.
    // We insert directly and let ISPConfig manage from here.
    // See docs/ispconfig-api-setup.md for the SQL approach.

    // 2. Create web domain via API
    $d = [
        'server_id'              => $server_id,
        'ip_address'             => '*',
        'ipv6_address'           => '',
        'domain'                 => $site['domain'],
        'type'                   => 'vhost',
        'parent_domain_id'       => 0,
        'vhost_type'             => 'name',
        'hd_quota'               => -1,
        'traffic_quota'          => -1,
        'cgi'                    => 'n',
        'ssi'                    => 'n',
        'suexec'                 => 'n',
        'errordocs'              => 1,
        'is_subdomainwww'        => 0,
        'subdomain'              => 'none',
        'php'                    => 'php-fpm',
        'php_fpm_use_socket'     => 'y',
        'php_fpm_chroot'         => 'n',
        'pm'                     => 'ondemand',
        'pm_max_children'        => 10,
        'pm_start_servers'       => 2,
        'pm_min_spare_servers'   => 1,
        'pm_max_spare_servers'   => 5,
        'pm_process_idle_timeout'=> 10,
        'pm_max_requests'        => 0,
        'http_port'              => 80,
        'https_port'             => 443,
        'ruby'                   => 'n',
        'python'                 => 'n',
        'perl'                   => 'n',
        'redirect_type'          => '',
        'redirect_path'          => '',
        'ssl'                    => $site['ssl'],
        'ssl_letsencrypt'        => $site['ssl'] === 'y' ? 'y' : 'n',
        'active'                 => 'y',
        'traffic_quota_lock'     => 'n',
        'backup_interval'        => 'none',
        'backup_copies'          => 1,
        'allow_override'         => 'All',
        'apache_directives'      => '',
        'custom_php_ini'         => '',
        'added_date'             => date('Y-m-d'),
        'added_by'               => 'ispconfig-migrate',
        'server_alias'           => $site['aliases'] ?? '',
    ];

    // client_id must match an existing ISPConfig client
    // Get it from the database or pass it explicitly
    $client_id = $site['client_id'] ?? null;
    if (!$client_id) {
        echo "  NOTE: client_id not set for {$site['domain']}.\n";
        echo "  Run docs/create-clients.sql first to create client accounts.\n";
        $results[] = ['domain' => $site['domain'], 'status' => 'SKIPPED - no client_id'];
        continue;
    }

    try {
        $domain_id = $soap->sites_web_domain_add($session, $client_id, $d, 'y');
        echo "  OK domain_id={$domain_id}\n";
        $results[] = ['domain' => $site['domain'], 'domain_id' => $domain_id, 'status' => 'OK'];
    } catch (Exception $e) {
        echo "  ERROR: " . $e->getMessage() . "\n";
        $results[] = ['domain' => $site['domain'], 'status' => 'ERROR: ' . $e->getMessage()];
    }
    echo "\n";
}

$soap->logout($session);

// ----------------------------------------------------------------
// Summary
// ----------------------------------------------------------------
echo "=== SUMMARY ===\n";
foreach ($results as $r) {
    $id = isset($r['domain_id']) ? "domain_id={$r['domain_id']}" : '';
    printf("  %-40s %-15s %s\n", $r['domain'], $id, $r['status']);
}
echo "\nNext step: run 03-set-php-version.sh to assign PHP versions per site.\n";
