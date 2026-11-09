<?php
declare(strict_types=1);
require_once dirname(__DIR__) . '/src/IdentitySession.php';
require_once dirname(__DIR__) . '/src/Database.php';
$path = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH);
header("Content-Security-Policy: default-src 'self'; frame-ancestors 'none'; form-action 'self' " . IdentitySession::formActionOrigin());
header('X-Content-Type-Options: nosniff');
function e(mixed $v): string { return htmlspecialchars((string)$v, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8'); }
function page(string $title, string $body): never {
    header('Content-Type: text/html; charset=utf-8');
    echo '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="demo-use-case" content="UC-05"><title>'.e($title).'</title></head><body><h1>'.e($title).'</h1>'.$body.'</body></html>';
    exit;
}
try {
    if ($path === '/healthz') { header('Content-Type: application/json'); exit('{"status":"ok"}'); }
    if ($path === '/readyz') {
        Database::connect()->query('SELECT 1 FROM profiles LIMIT 1');
        $entra = IdentitySession::mode() === 'entra';
        $url = $entra
            ? 'https://login.microsoftonline.com/' . IdentitySession::env('ENTRA_TENANT_ID') . '/v2.0/.well-known/openid-configuration'
            : IdentitySession::env('CAS_ORIGIN') . '/cas/login';
        $ch = curl_init($url);
        $options = [CURLOPT_RETURNTRANSFER=>true,CURLOPT_TIMEOUT=>5];
        if (!$entra) $options[CURLOPT_CAINFO] = IdentitySession::env('CAS_CA_FILE');
        curl_setopt_array($ch,$options);
        $result=curl_exec($ch); $status=curl_getinfo($ch,CURLINFO_RESPONSE_CODE); curl_close($ch);
        if ($result === false || $status !== 200) throw new RuntimeException('Identity provider unavailable');
        header('Content-Type: application/json'); exit('{"status":"ready"}');
    }
    if ($path === '/slo') {
        if (IdentitySession::mode() === 'entra') { http_response_code(403); exit('Back-channel logout is not supported with Entra ID.'); }
        IdentitySession::initialize();
        http_response_code(400); exit('Expected valid CAS logout request');
    }
    if ($path === '/') page('Alumni Directory', '<p>Synthetic alumni community</p><a href="/login">'.(IdentitySession::mode() === 'entra' ? 'Sign in with Microsoft Entra ID' : 'Sign in with CAS').'</a>');
    if ($path === '/logout' && $_SERVER['REQUEST_METHOD'] === 'POST') IdentitySession::logout((string)($_POST['csrf'] ?? ''));
    if (!in_array($path,['/login','/profile','/directory'],true)) { http_response_code(404); page('Not found',''); }
    $identity=IdentitySession::requireUser();
    header('Cache-Control: no-store');
    if ($path === '/login') { header('Location: /profile',true,303); exit; }
    $db=Database::connect();
    if ($path === '/directory') {
        if (!IdentitySession::isAlum($identity)) { http_response_code(403); page('Forbidden','Alum affiliation is required.'); }
        $body='<ul>';
        foreach($db->query('SELECT display_name, graduation_year FROM profiles ORDER BY uid') as $row) $body.='<li>'.e($row['display_name']).' ('.e($row['graduation_year']).')</li>';
        page('Alumni members',$body.'</ul><a href="/profile">My profile</a>');
    }
    $stmt=$db->prepare('SELECT * FROM profiles WHERE uid = :uid');
    $stmt->execute(['uid'=>$identity['uid']]); $profile=$stmt->fetch();
    $body='<p data-testid="uid">'.e($identity['uid']).'</p><dl>';
    foreach($identity['attributes'] as $name=>$value) if ($name !== 'uid') $body.='<dt>'.e($name).'</dt><dd data-testid="'.e($name).'">'.e(implode('; ',(array)$value)).'</dd>';
    $body.='</dl>';
    if ($profile) $body.='<p data-testid="biography">'.e($profile['biography']).'</p><p>Class of '.e($profile['graduation_year']).'</p>';
    else $body.='<p>No alumni profile is linked to this uid.</p>';
    $body.='<a href="/directory">Alumni members</a><form method="post" action="/logout"><input type="hidden" name="csrf" value="'.e(IdentitySession::csrf()).'"><button type="submit">Sign out</button></form>';
    page('Alumni profile',$body);
} catch (SignInRejected $rejected) {
    // A failed sign-in ends here with a non-secret code; it never redirects back into the authorization flow.
    error_log('Sign-in rejected: ' . $rejected->reason);
    http_response_code(401);
    page('Sign-in failed', '<p>The identity provider did not return a valid employee profile. Contact the demo operator.</p><p data-testid="login-error">'.e($rejected->reason).'</p><a href="/login">Try sign-in again</a>');
} catch (Throwable $error) {
    error_log(get_class($error).': '.$error->getMessage());
    http_response_code($path === '/readyz' ? 503 : 500);
    if ($path === '/readyz') { header('Content-Type: application/json'); exit('{"status":"notReady"}'); }
    page('Service unavailable','An authentication or database dependency is unavailable. See the server log.');
}
