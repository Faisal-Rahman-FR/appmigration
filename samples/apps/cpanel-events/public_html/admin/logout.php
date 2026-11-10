<?php
declare(strict_types=1);
require_once __DIR__ . '/../../src/Events.php';
Events::headers();
$uid = Events::uid();
if ($_SERVER['REQUEST_METHOD'] !== 'POST') { http_response_code(405); header('Allow: POST'); exit; }
Events::checkCsrf($uid, $_POST['csrf'] ?? null);
$home = Events::env('EVENTS_ORIGIN') . '/';

if (Events::mode() === 'entra') {
    // The guard started the session; destroy it, then end the Entra session (front-channel) and return home.
    $idToken = is_string($_SESSION['id_token'] ?? null) ? $_SESSION['id_token'] : '';
    $_SESSION = [];
    session_destroy();
    setcookie(session_name(), '', ['expires' => time() - 3600, 'path' => '/', 'secure' => true, 'httponly' => true, 'samesite' => 'Lax']);
    if ($idToken === '') { header('Location: ' . $home, true, 303); exit; }
    require_once dirname(__DIR__, 2) . '/vendor/autoload.php';
    $client = new Jumbojett\OpenIDConnectClient('https://login.microsoftonline.com/' . Events::env('ENTRA_TENANT_ID') . '/v2.0', Events::env('ENTRA_CLIENT_ID'));
    $client->signOut($idToken, $home);
    exit;
}

// mod_auth_cas keeps its own cookies, scoped to the protected directory: drop them, then end the CAS single sign-on session.
foreach (['MOD_AUTH_CAS', 'MOD_AUTH_CAS_S'] as $cookie) {
    setcookie($cookie, '', ['expires' => time() - 3600, 'path' => '/admin/', 'secure' => true, 'httponly' => true]);
}
header('Location: ' . Events::env('CAS_ORIGIN') . '/cas/logout?service=' . rawurlencode($home), true, 303);
