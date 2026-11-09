<?php
declare(strict_types=1);
// Minimal hand-written autoloader: no Composer is available on shared hosting.
// Package versions and hashes are recorded in PROVENANCE.json.
spl_autoload_register(static function (string $class): void {
    $psr4 = [
        'Psr\\Log\\' => __DIR__ . '/psr/log/src/',
        'phpseclib3\\' => __DIR__ . '/phpseclib/phpseclib-3.0.58/phpseclib/',
        'ParagonIE\\ConstantTime\\' => __DIR__ . '/paragonie/constant_time_encoding-3.1.3/src/',
    ];
    foreach ($psr4 as $prefix => $directory) {
        if (str_starts_with($class, $prefix)) {
            $file = $directory . str_replace('\\', '/', substr($class, strlen($prefix))) . '.php';
            if (is_file($file)) require_once $file;
            return;
        }
    }
    // One upstream file declares both classes (classmap autoloading in Composer).
    if ($class === 'Jumbojett\\OpenIDConnectClient' || $class === 'Jumbojett\\OpenIDConnectClientException') {
        require_once __DIR__ . '/jumbojett/openid-connect-php-1.0.2/src/OpenIDConnectClient.php';
    }
});
require_once __DIR__ . '/phpseclib/phpseclib-3.0.58/phpseclib/bootstrap.php';
require_once __DIR__ . '/apereo/phpCAS-1.6.1/source/CAS.php';
