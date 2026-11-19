<?php

// Installs Shopware or updates the database to the version in this image, once.
// Every Shopware container runs this on start. When the database already has this
// version, it exits after one query. Otherwise one container takes a database lock
// and runs the Deployment Helper, the others wait for it.

require '/var/www/html/vendor/autoload.php';

use Composer\InstalledVersions;

// Same version string the Deployment Helper writes to deployment.version
$version = InstalledVersions::isInstalled('shopware/platform')
    ? InstalledVersions::getVersion('shopware/platform')
    : InstalledVersions::getVersion('shopware/core');

$url = parse_url((string) getenv('DATABASE_URL'));
$dsn = sprintf('mysql:host=%s;port=%d;dbname=%s', $url['host'], $url['port'] ?? 3306, ltrim($url['path'], '/'));

for ($attempt = 1; ; ++$attempt) {
    try {
        $db = new PDO($dsn, rawurldecode($url['user']), rawurldecode($url['pass'] ?? ''), [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
        break;
    } catch (PDOException $e) {
        if ($attempt === 60) {
            throw $e;
        }
        fwrite(STDERR, "Waiting for the database: {$e->getMessage()}\n");
        sleep(2);
    }
}

$deployed = function () use ($db): ?string {
    try {
        $value = $db->query('SELECT configuration_value FROM system_config WHERE configuration_key = "deployment.version" AND sales_channel_id IS NULL')->fetchColumn();
    } catch (PDOException) {
        return null; // not installed yet
    }

    return $value === false ? null : json_decode($value, true)['_value'];
};

if ($deployed() === $version) {
    exit(0);
}

// Released when this process exits. MariaDB does not accept a negative timeout.
while ((int) $db->query("SELECT GET_LOCK('shopware_deployment', 3600)")->fetchColumn() !== 1) {
    fwrite(STDERR, "Waiting for another container to deploy Shopware\n");
}

if ($deployed() !== $version) {
    passthru('/setup', $code);
    exit($code);
}
