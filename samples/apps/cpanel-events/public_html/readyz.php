<?php
declare(strict_types=1);
require_once __DIR__ . '/../src/Events.php';
header('Content-Type: application/json');
try {
    Events::pdo()->query('SELECT 1 FROM event_staff LIMIT 1')->fetchColumn();
    if (Events::mode() === 'cas') {
        $loaded = array_intersect(['mod_auth_cas', 'mod_auth_cas.c'], apache_get_modules());
        if (!is_readable('/run/events-cas-ca.pem') || !$loaded) throw new RuntimeException('CAS module or CA bundle missing');
    } else {
        $secret = '/var/www/events/.config/events-entra.php';
        if (!is_file($secret) || (fileperms($secret) & 0007) !== 0) throw new RuntimeException('Entra secret missing');
        $curl = curl_init('https://login.microsoftonline.com/' . Events::env('ENTRA_TENANT_ID') . '/v2.0/.well-known/openid-configuration');
        curl_setopt_array($curl, [CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 4, CURLOPT_FOLLOWLOCATION => false]);
        curl_exec($curl);
        $status = curl_getinfo($curl, CURLINFO_RESPONSE_CODE);
        curl_close($curl);
        if ($status !== 200) throw new RuntimeException('Entra discovery unreachable');
    }
    echo '{"status":"ready"}';
} catch (Throwable $exception) {
    error_log('readyz: ' . $exception->getMessage());
    http_response_code(503);
    echo '{"status":"notReady"}';
}
