<?php
declare(strict_types=1);
// Dependency-free checks. Run inside the built image:
//   docker run --rm --entrypoint php -v "$PWD/apps/php-cpanel/tests:/home/alumni/tests:ro" <alumni-image> /home/alumni/tests/run.php
putenv('ENTRA_TENANT_ID=11111111-2222-3333-4444-555555555555');
putenv('ENTRA_CLIENT_ID=test-client');
putenv('ALUMNI_ORIGIN=https://alumni.demo.test');
$secret = tempnam(sys_get_temp_dir(), 'alumni-secret');
file_put_contents($secret, "<?php return ['client_secret' => 'test-secret'];\n");
chmod($secret, 0600);
putenv('ALUMNI_SECRET_FILE=' . $secret);
ob_start();
require '/home/alumni/src/IdentitySession.php';

$failures = 0;
function check(string $name, bool $condition): void
{
    global $failures;
    echo ($condition ? 'PASS ' : 'FAIL ') . $name . "\n";
    if (!$condition) $failures++;
}
function rejects(callable $call): ?string
{
    try { $call(); } catch (SignInRejected $rejected) { return $rejected->reason; }
    return null;
}

$tenant = '11111111-2222-3333-4444-555555555555';
$claims = (object)['tid' => $tenant, 'oid' => 'object-1', 'roles' => ['alum']];
$graph = ['id' => 'object-1', 'mailNickname' => 'alice', 'mail' => 'alice@example.test', 'displayName' => 'Alice Avery'];

$identity = EntraProfile::identity($claims, $graph, $tenant);
check('uid comes from mailNickname, not the UPN', $identity['uid'] === 'alice');
check('roles map to eduPersonAffiliation', $identity['attributes']['eduPersonAffiliation'] === ['alum']);
check('only the allow-listed attributes are exposed', array_keys($identity['attributes']) === ['mail', 'displayName', 'eduPersonAffiliation']);
check('alum role is recognised', IdentitySession::isAlum($identity));
$member = EntraProfile::identity((object)['tid' => $tenant, 'oid' => 'object-1', 'roles' => ['member']], $graph, $tenant);
check('member role is not an alum', !IdentitySession::isAlum($member));
check('missing roles claim gives no affiliation', EntraProfile::identity((object)['tid' => $tenant, 'oid' => 'object-1'], $graph, $tenant)['attributes']['eduPersonAffiliation'] === []);
check('wrong tenant is rejected', rejects(fn() => EntraProfile::identity((object)['tid' => 'other', 'oid' => 'object-1'], $graph, $tenant)) === 'invalid_tenant');
check('Graph object id must match the token oid', rejects(fn() => EntraProfile::identity($claims, ['id' => 'someone-else'] + $graph, $tenant)) === 'invalid_employee_profile');
check('missing mailNickname is rejected', rejects(fn() => EntraProfile::identity($claims, ['mailNickname' => ''] + $graph, $tenant)) === 'invalid_employee_profile');
check('missing mail is rejected', rejects(fn() => EntraProfile::identity($claims, ['mail' => null] + $graph, $tenant)) === 'invalid_employee_profile');
check('missing Graph profile is rejected', rejects(fn() => EntraProfile::identity($claims, null, $tenant)) === 'invalid_employee_profile');

class CapturingClient extends Jumbojett\OpenIDConnectClient
{
    public string $url = '';
    public function redirect(string $url) { $this->url = $url; }
}
session_save_path(sys_get_temp_dir());
@session_start();
$client = IdentitySession::oidcClient(CapturingClient::class, [
    'authorization_endpoint' => 'https://login.microsoftonline.com/' . $tenant . '/oauth2/v2.0/authorize',
]);
$client->authenticate();
parse_str((string)parse_url($client->url, PHP_URL_QUERY), $query);
check('authorization request asks for S256 PKCE', ($query['code_challenge_method'] ?? '') === 'S256' && strlen($query['code_challenge'] ?? '') >= 43);
check('authorization request carries state and nonce', ($query['state'] ?? '') !== '' && ($query['nonce'] ?? '') !== '');
check('redirect_uri is the exact registered URI', ($query['redirect_uri'] ?? '') === 'https://alumni.demo.test/login');
check('scopes include openid and Graph User.Read', in_array('openid', explode(' ', $query['scope'] ?? ''), true) && str_contains($query['scope'] ?? '', 'https://graph.microsoft.com/User.Read'));
check('response type is the authorization code flow', ($query['response_type'] ?? '') === 'code');

chmod($secret, 0644);
$unsafe = null;
try { IdentitySession::oidcClient(); } catch (RuntimeException $exception) { $unsafe = $exception->getMessage(); }
check('a world-readable secret file is refused', $unsafe !== null && str_contains($unsafe, 'world-accessible'));
unlink($secret);

putenv('ENTRA_TENANT_ID=common');
$common = null;
try { IdentitySession::oidcClient(); } catch (RuntimeException $exception) { $common = $exception->getMessage(); }
check('the common authority is refused', $common !== null && str_contains($common, 'single-tenant'));

putenv('ALUMNI_AUTH=bogus');
$bad = null;
try { IdentitySession::mode(); } catch (RuntimeException $exception) { $bad = $exception->getMessage(); }
check('an unknown ALUMNI_AUTH fails startup', $bad !== null);
putenv('ALUMNI_AUTH');
check('CAS is the default mode', IdentitySession::mode() === 'cas');

ob_end_flush();
echo $failures === 0 ? "ALL PASSED\n" : "$failures FAILED\n";
exit($failures === 0 ? 0 : 1);
