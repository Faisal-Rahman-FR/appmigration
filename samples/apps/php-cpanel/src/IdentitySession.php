<?php
declare(strict_types=1);
require_once dirname(__DIR__) . '/vendor/autoload.php';
require_once __DIR__ . '/Database.php';
require_once __DIR__ . '/EntraProfile.php';

final class IdentitySession
{
    private static bool $initialized = false;

    /** ALUMNI_AUTH selects the protocol: cas (default, rollback path) or entra. */
    public static function mode(): string
    {
        $mode = getenv('ALUMNI_AUTH');
        if ($mode === false || $mode === '') return 'cas';
        if (!in_array($mode, ['cas', 'entra'], true)) throw new RuntimeException('ALUMNI_AUTH must be cas or entra.');
        return $mode;
    }
    public static function formActionOrigin(): string
    {
        return self::mode() === 'entra' ? 'https://login.microsoftonline.com' : self::env('CAS_ORIGIN');
    }
    public static function initialize(): void
    {
        if (self::$initialized) return;
        $mode = self::mode();
        if ($mode === 'cas' && isset($_POST['logoutRequest']) && parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH) !== '/slo') {
            http_response_code(403); exit('Logout callback must use the dedicated protected endpoint.');
        }
        ini_set('session.use_strict_mode', '1');
        session_name('ALUMNI_SESSION');
        session_set_cookie_params(['secure'=>true, 'httponly'=>true, 'samesite'=>'Lax', 'path'=>'/']);
        session_start();
        if ($mode === 'cas') self::initializeCas();
        self::$initialized = true;
    }
    private static function initializeCas(): void
    {
        $cas = parse_url(self::env('CAS_ORIGIN'));
        if (!$cas || ($cas['scheme'] ?? '') !== 'https') throw new RuntimeException('CAS must use HTTPS.');
        // Keep strict PHP session IDs; phpCAS validates CAS and invokes its real callbacks.
        // Its default ticket-derived session rename is incompatible with strict_mode.
        phpCAS::client(CAS_VERSION_3_0, $cas['host'], $cas['port'] ?? 443, '/cas', self::env('ALUMNI_ORIGIN'), false);
        phpCAS::setCasServerCACert(self::env('CAS_CA_FILE'));
        phpCAS::setFixedServiceURL(self::env('ALUMNI_ORIGIN') . '/login');
        phpCAS::setPostAuthenticateCallback([self::class, 'authenticated']);
        phpCAS::setSingleSignoutCallback([self::class, 'revoked']);
        // nginx admits /slo only from the fixed CAS backend address.
        // PHP receives the proxy's REMOTE_ADDR, never trusts X-Forwarded-For.
        $proxyIp = gethostbyname(self::env('SLO_PROXY_HOST'));
        if (!filter_var($proxyIp, FILTER_VALIDATE_IP)) throw new RuntimeException('Cannot resolve trusted SLO proxy.');
        phpCAS::handleLogoutRequests(true, [$proxyIp]);
    }
    public static function authenticated(string $ticket): void
    {
        session_regenerate_id(true);
        $hash = hash('sha256', $ticket);
        $db = Database::connect();
        $db->exec('DELETE FROM cas_sessions WHERE expires_at < CURRENT_TIMESTAMP');
        $query = $db->prepare('INSERT INTO cas_sessions (ticket_hash, revoked, expires_at) VALUES (:hash, FALSE, DATE_ADD(CURRENT_TIMESTAMP, INTERVAL 8 HOUR)) ON DUPLICATE KEY UPDATE expires_at = VALUES(expires_at)');
        $query->execute(['hash'=>$hash]);
        $_SESSION['cas_ticket_hash'] = $hash;
        unset($_SESSION['csrf']);
    }
    public static function revoked(string $ticket): void
    {
        $query = Database::connect()->prepare('INSERT INTO cas_sessions (ticket_hash, revoked, expires_at) VALUES (:hash, TRUE, DATE_ADD(CURRENT_TIMESTAMP, INTERVAL 8 HOUR)) ON DUPLICATE KEY UPDATE revoked = TRUE');
        $query->execute(['hash'=>hash('sha256', $ticket)]);
    }
    /** @return array{uid:string,attributes:array<string,mixed>} */
    public static function requireUser(): array
    {
        self::initialize();
        if (self::mode() === 'entra') return self::requireEntraUser();
        phpCAS::forceAuthentication();
        $query=Database::connect()->prepare('SELECT 1 FROM cas_sessions WHERE ticket_hash = :hash AND revoked = FALSE AND expires_at > CURRENT_TIMESTAMP');
        $query->execute(['hash'=>$_SESSION['cas_ticket_hash'] ?? '']);
        if (!$query->fetchColumn()) {
            $_SESSION=[];
            session_destroy();
            setcookie(session_name(), '', ['expires'=>time()-3600, 'path'=>'/', 'secure'=>true, 'httponly'=>true, 'samesite'=>'Lax']);
            header('Location: /login',true,303);
            exit;
        }
        return ['uid'=>phpCAS::getUser(), 'attributes'=>phpCAS::getAttributes()];
    }
    /** @return array{uid:string,attributes:array<string,mixed>} */
    private static function requireEntraUser(): array
    {
        // Only set below, after the ID token and the employee profile were both verified.
        if (isset($_SESSION['identity']) && is_array($_SESSION['identity'])) return $_SESSION['identity'];
        $client = self::oidcClient();
        try {
            $client->authenticate(); // redirects to Entra and exits unless this request carries the callback
            $identity = EntraProfile::identity(
                $client->getVerifiedClaims(),
                EntraProfile::fetchGraphProfile($client->getAccessToken()),
                self::env('ENTRA_TENANT_ID')
            );
        } catch (Jumbojett\OpenIDConnectClientException $exception) {
            error_log('Entra sign-in failed: ' . $exception->getMessage());
            throw new SignInRejected('authentication_failed');
        }
        session_regenerate_id(true);
        $_SESSION['identity'] = $identity;
        $_SESSION['id_token'] = $client->getIdToken();
        unset($_SESSION['csrf']);
        return $identity;
    }
    /** @param array<string,mixed> $providerConfig overrides discovery values (tests only) */
    public static function oidcClient(string $class = Jumbojett\OpenIDConnectClient::class, array $providerConfig = []): Jumbojett\OpenIDConnectClient
    {
        $tenant = self::env('ENTRA_TENANT_ID');
        if (!preg_match('/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i', $tenant)) {
            throw new RuntimeException('ENTRA_TENANT_ID must be a single-tenant GUID, never common or organizations.');
        }
        $client = new $class('https://login.microsoftonline.com/' . $tenant . '/v2.0', self::env('ENTRA_CLIENT_ID'), self::secret());
        $client->setRedirectURL(self::env('ALUMNI_ORIGIN') . '/login');
        $client->addScope(['profile', 'email', 'https://graph.microsoft.com/User.Read']);
        // Entra's discovery document omits code_challenge_methods_supported, and the library then silently sends no PKCE.
        $client->providerConfigParam(array_merge(['code_challenge_methods_supported' => ['S256']], $providerConfig));
        $client->setCodeChallengeMethod('S256');
        $client->setTimeout(10);
        return $client;
    }
    /** @param array{uid:string,attributes:array<string,mixed>} $identity */
    public static function isAlum(array $identity): bool
    {
        return in_array('alum', (array)($identity['attributes']['eduPersonAffiliation'] ?? []), true);
    }
    public static function csrf(): string
    {
        self::initialize();
        if (!isset($_SESSION['csrf'])) $_SESSION['csrf'] = bin2hex(random_bytes(32));
        return $_SESSION['csrf'];
    }
    public static function logout(string $token): never
    {
        self::initialize();
        if (!hash_equals(self::csrf(), $token)) { http_response_code(403); exit('Invalid form token'); }
        if (self::mode() === 'entra') self::logoutEntra();
        if (isset($_SESSION['cas_ticket_hash'])) {
            $query=Database::connect()->prepare('UPDATE cas_sessions SET revoked = TRUE WHERE ticket_hash = :hash');
            $query->execute(['hash'=>$_SESSION['cas_ticket_hash']]);
        }
        phpCAS::logoutWithRedirectService(self::env('ALUMNI_ORIGIN') . '/');
        exit;
    }
    private static function logoutEntra(): never
    {
        $idToken = is_string($_SESSION['id_token'] ?? null) ? $_SESSION['id_token'] : '';
        $_SESSION = [];
        session_destroy();
        setcookie(session_name(), '', ['expires'=>time()-3600, 'path'=>'/', 'secure'=>true, 'httponly'=>true, 'samesite'=>'Lax']);
        $home = self::env('ALUMNI_ORIGIN') . '/';
        if ($idToken === '') { header('Location: ' . $home, true, 303); exit; }
        // The app session is already destroyed; now end the Entra session and return to the home page.
        self::oidcClient()->signOut($idToken, $home);
        exit;
    }
    /** Shared-hosting layout: a 0600 file above the web root returning ['client_secret' => '...']. */
    private static function secret(): string
    {
        $path = getenv('ALUMNI_SECRET_FILE') ?: dirname(__DIR__) . '/.config/alumni-entra.php';
        if (!is_file($path) || (fileperms($path) & 0007) !== 0) throw new RuntimeException('Entra secret file is missing or world-accessible.');
        $config = require $path;
        $secret = is_array($config) ? ($config['client_secret'] ?? null) : null;
        if (!is_string($secret) || $secret === '') throw new RuntimeException('Entra secret file has no client_secret.');
        return $secret;
    }
    public static function env(string $key): string
    {
        $value = getenv($key);
        if ($value === false || $value === '') throw new RuntimeException("Missing environment: $key");
        return $value;
    }
}
