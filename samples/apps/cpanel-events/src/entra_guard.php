<?php
declare(strict_types=1);
// auto_prepend_file for /admin when EVENTS_AUTH=entra. Replaces mod_auth_cas: sign in with Entra ID, then expose REMOTE_USER.
// A closure keeps the guard's variables out of the page's scope.
(static function (): void {
    $root = dirname(__DIR__);
    require_once $root . '/vendor/autoload.php';
    require_once __DIR__ . '/Events.php';
    require_once __DIR__ . '/EntraProfile.php';

    $tenant = Events::env('ENTRA_TENANT_ID');
    if (!preg_match('/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i', $tenant)) {
        throw new RuntimeException('ENTRA_TENANT_ID must be a single-tenant GUID, never common or organizations.');
    }
    ini_set('session.use_strict_mode', '1');
    session_name('EVENTS_SESSION');
    session_set_cookie_params(['secure' => true, 'httponly' => true, 'samesite' => 'Lax', 'path' => '/']);
    session_start();

    if (isset($_SESSION['identity']['uid']) && is_string($_SESSION['identity']['uid'])) {
        $_SERVER['REMOTE_USER'] = $_SESSION['identity']['uid'];
        return;
    }

    $path = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH) ?: '/';
    if ($path !== '/admin/callback.php') {
        $_SESSION['return_to'] = Events::safeReturnTo($_SERVER['REQUEST_URI'] ?? '/admin/');
    }
    $secretFile = $root . '/.config/events-entra.php';
    if (!is_file($secretFile) || (fileperms($secretFile) & 0007) !== 0) throw new RuntimeException('Entra secret file is missing or world-accessible.');
    $config = require $secretFile;
    $secret = is_array($config) ? ($config['client_secret'] ?? '') : '';
    if (!is_string($secret) || $secret === '') throw new RuntimeException('Entra secret file has no client_secret.');

    $client = new Jumbojett\OpenIDConnectClient('https://login.microsoftonline.com/' . $tenant . '/v2.0', Events::env('ENTRA_CLIENT_ID'), $secret);
    $client->setRedirectURL(Events::env('EVENTS_ORIGIN') . '/admin/callback.php');
    $client->addScope(['profile', 'email', 'https://graph.microsoft.com/User.Read']);
    // Entra's discovery document omits code_challenge_methods_supported; without this the library silently sends no PKCE.
    $client->providerConfigParam(['code_challenge_methods_supported' => ['S256']]);
    $client->setCodeChallengeMethod('S256');
    $client->setTimeout(10);
    try {
        $client->authenticate(); // redirects to Entra and exits unless this request carries the callback
        $identity = EntraProfile::identity($client->getVerifiedClaims(), EntraProfile::fetchGraphProfile($client->getAccessToken()), $tenant);
    } catch (Throwable $exception) {
        error_log('Entra sign-in failed: ' . $exception->getMessage());
        http_response_code(401);
        header('Content-Type: text/plain; charset=utf-8');
        exit('Sign-in failed: ' . ($exception instanceof SignInRejected ? $exception->reason : 'authentication_failed'));
    }
    $target = Events::safeReturnTo(is_string($_SESSION['return_to'] ?? null) ? $_SESSION['return_to'] : '/admin/');
    session_regenerate_id(true);
    $_SESSION['identity'] = $identity;
    $_SESSION['id_token'] = $client->getIdToken();
    header('Location: ' . $target, true, 303);
    exit;
})();
