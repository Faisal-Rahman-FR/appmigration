<?php
declare(strict_types=1);

/** Shared helpers. Identity comes only from REMOTE_USER, set by mod_auth_cas or by the Entra guard (src/entra_guard.php). */
final class Events
{
    public static function env(string $key): string
    {
        $value = getenv($key);
        if ($value === false || $value === '') throw new RuntimeException("Missing environment: $key");
        return $value;
    }
    public static function mode(): string
    {
        $mode = getenv('EVENTS_AUTH') ?: 'cas';
        if (!in_array($mode, ['cas', 'entra'], true)) throw new RuntimeException('EVENTS_AUTH must be cas or entra.');
        return $mode;
    }
    public static function idpOrigin(): string
    {
        return self::mode() === 'entra' ? 'https://login.microsoftonline.com' : self::env('CAS_ORIGIN');
    }
    public static function pdo(): PDO
    {
        return new PDO(
            'mysql:host=' . self::env('DB_HOST') . ';dbname=events;charset=utf8mb4', 'demo', self::env('DB_PASSWORD'),
            [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_EMULATE_PREPARES => false, PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC]
        );
    }
    public static function headers(): void
    {
        header("Content-Security-Policy: default-src 'self'; style-src 'unsafe-inline'; form-action 'self' " . self::idpOrigin());
        header('X-Content-Type-Options: nosniff');
        header('Referrer-Policy: same-origin');
        header('Cache-Control: no-store');
    }
    /** The signed-in principal. Fails closed when no sign-in mechanism ran. */
    public static function uid(): string
    {
        $uid = $_SERVER['REMOTE_USER'] ?? '';
        if (!is_string($uid) || !preg_match('/^[a-z0-9._-]{1,64}$/', $uid)) {
            http_response_code(401);
            exit('A signed-in principal is required.');
        }
        return $uid;
    }
    /** @return array{uid:string,role:string,name:string} */
    public static function requireStaff(?string $only = null): array
    {
        self::headers();
        $uid = self::uid();
        $query = self::pdo()->prepare('SELECT role, display_name FROM event_staff WHERE uid = :uid');
        $query->execute(['uid' => $uid]);
        $row = $query->fetch();
        if (!$row || ($only !== null && $row['role'] !== $only)) {
            http_response_code(403);
            exit('Forbidden: your account is not event staff' . ($only !== null ? " ($only required)" : '') . '.');
        }
        return ['uid' => $uid, 'role' => $row['role'], 'name' => $row['display_name']];
    }
    public static function csrf(string $uid): string
    {
        return hash_hmac('sha256', 'events-csrf:' . $uid, self::env('EVENTS_CSRF_KEY'));
    }
    public static function checkCsrf(string $uid, mixed $token): void
    {
        if (!is_string($token) || !hash_equals(self::csrf($uid), $token)) {
            http_response_code(403);
            exit('Invalid form token');
        }
    }
    public static function e(mixed $value): string
    {
        return htmlspecialchars((string)$value, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
    }
    /** Only same-site paths under /admin/ may be a post-login target. */
    public static function safeReturnTo(string $target): string
    {
        return preg_match('#^/admin/[A-Za-z0-9_./?=&%-]*$#', $target) && !str_contains($target, '//') && !str_contains($target, '..')
            ? $target : '/admin/';
    }
}
