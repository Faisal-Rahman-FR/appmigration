# Recipe: plain PHP + phpCAS on shared hosting (cPanel) to Entra ID (OIDC)

Demo: `samples/apps/php-cpanel` (Alumni Directory, UC-05). Pattern: **OIDC re-integration**, complexity high: phpCAS is CAS-only, so the protocol client is replaced, while the app's own logic (profile lookup, alum-only directory, DB) stays.

## Validation status

Run against a real tenant on 2026-11-05: **partially validated**. Vendoring, build, 20 PHP checks, deployment, the live OIDC challenge, an admin sign-in reaching `/profile` (HTTP 200) with logout, re-authentication after logout, and fail-closed rejection of an unprovisioned account were all evidenced. The member sign-in with the `/directory` 403, the admin directory listing and any automated authenticated test were **not** observed. See the [evidence report](../../../../samples/docs/ALUMNI-ENTRA-VALIDATION.md). The example below is the corrected design; the original sample was **not** runnable as written.

### Defects the original recipe had (all corrected below)

1. **PKCE is silently not sent.** Entra's discovery document omits `code_challenge_methods_supported`, and `jumbojett/openid-connect-php` only adds PKCE when the provider advertises S256. `setCodeChallengeMethod('S256')` alone sent no `code_challenge` against a live tenant. Force it with `providerConfigParam(['code_challenge_methods_supported' => ['S256']])` and assert the challenge in a test.
2. **The UPN fallback for `uid` breaks account linking.** `strstr($claims->preferred_username, '@', true)` gave `hr-recipe-admin`, not `alice`. `mailNickname` is not an ID-token claim, so read it from Graph `/me` with the delegated `User.Read` token and require the Graph `id` to equal the token's `oid`.
3. **User consent may be blocked.** A tenant can answer "Need admin approval" for the `User.Read` scope; an admin must grant it for this one app (or tick "Consent on behalf of your organization").
4. **No Composer on shared hosting** and no `vendor/` for the OIDC stack: vendor `jumbojett/openid-connect-php` 1.0.2, `phpseclib` 3.0.58 and `paragonie/constant_time_encoding` 3.1.3 by hand from pinned archives, record hashes in `vendor/PROVENANCE.json`, and add a small PSR-4 autoloader. `paragonie/random_compat` is a no-op on PHP 8 and is not needed.
5. **Outbound HTTPS.** The sample container sat on an internal-only network; give it a route to `login.microsoftonline.com` and `graph.microsoft.com`.
6. **Logout shows an account picker** when several Entra accounts are signed in, and does not then return to `post_logout_redirect_uri`. Destroy the app session first, as below; consider `logout_hint` (requires the `login_hint` optional claim, **verify**).

## Constraints to respect (shared hosting)

No root, no Apache authentication modules, no Composer at runtime, files under `/home/<user>/public_html`, `.htaccess` for rewrites, MariaDB/MySQL on the host. So: **vendor the OIDC library in `vendor/` (committed, as phpCAS is today)**, keep secrets **outside** `public_html`, and do all verification in PHP.

## What exists today

- `src/IdentitySession.php`: the single identity helper. `initialize()` configures phpCAS (CAS 3.0, CA file, fixed service URL, post-auth callback, single-sign-out callback with a trusted proxy IP); `requireUser()` forces authentication and checks a `cas_sessions` table for revocation; `isAlum()` reads `eduPersonAffiliation`; `logout()` is POST with CSRF, revokes the ticket row, `phpCAS::logoutWithRedirectService`.
- `public_html/index.php`: routes `/healthz`, `/readyz` (checks DB **and** CAS reachability), `/slo` (back-channel), `/login`, `/profile`, `/directory`, `/logout`; sends `Content-Security-Policy` with `form-action 'self' <CAS_ORIGIN>`; profile joins `profiles.uid`; the page lists every attribute as `data-testid=<name>`.
- `src/Database.php`, `profiles` and `cas_sessions` tables on the existing MariaDB.

## Target design

OIDC authorization code flow with PKCE using `jumbojett/openid-connect-php` (pure PHP, needs `curl`, `json`, `openssl`; verifies the ID token signature against Entra's JWKS). `IdentitySession` keeps its public methods, so `index.php` barely changes.

```php
$oidc = new Jumbojett\OpenIDConnectClient(
  'https://login.microsoftonline.com/'.self::env('ENTRA_TENANT_ID').'/v2.0',   // single-tenant GUID, never common/organizations
  self::env('ENTRA_CLIENT_ID'), self::secret());
$oidc->setRedirectURL(self::env('ALUMNI_ORIGIN').'/login');
$oidc->addScope(['profile','email','https://graph.microsoft.com/User.Read']);   // 'openid' is added by the library
$oidc->providerConfigParam(['code_challenge_methods_supported' => ['S256']]);   // Entra does not advertise PKCE; without this none is sent
$oidc->setCodeChallengeMethod('S256');
$oidc->setTimeout(10);
$oidc->authenticate();             // redirects and exits, or on the callback verifies state, nonce, signature, iss, aud, exp
$claims = $oidc->getVerifiedClaims();                                           // never trust unverified claims
// Also require $claims->tid === the configured tenant, then read the employee profile from Graph:
//   GET https://graph.microsoft.com/v1.0/me?$select=id,mailNickname,mail,displayName   (Bearer $oidc->getAccessToken())
// and require Graph id === $claims->oid and non-empty mailNickname/mail/displayName; otherwise end on a 401 page.
session_regenerate_id(true);
$_SESSION['identity'] = [
  'uid' => $graph['mailNickname'],                                  // the old CAS uid; NOT the UPN local part
  'attributes' => ['mail'=>$graph['mail'], 'displayName'=>$graph['displayName'], 'eduPersonAffiliation'=>array_values((array)($claims->roles ?? []))],
];
$_SESSION['id_token'] = $oidc->getIdToken();
```

The worked implementation is `samples/apps/php-cpanel/src/IdentitySession.php` and `src/EntraProfile.php` (a `ALUMNI_AUTH=cas|entra` switch keeps phpCAS for rollback). Pin the library version you vendor (1.0.2 here, API verified by reading its source and by the 20 checks in `tests/run.php`).

### Changes by file

| File | Change |
|---|---|
| `src/IdentitySession.php` | Replace phpCAS setup, callbacks, `handleLogoutRequests`, ticket hashing with the OIDC flow above. Keep `requireUser()`, `isAlum()`, `csrf()`, `logout()` signatures. `isAlum()` checks `roles` contains `alum` |
| `src/IdentitySession.php` logout | Destroy the session, then redirect to Entra `end_session_endpoint` with `post_logout_redirect_uri` (`$oidc->signOut($idToken, $origin.'/')`) |
| `public_html/index.php` | Remove `/slo`. Change CSP `form-action` to `'self' https://login.microsoftonline.com` (the logout POST is followed by a redirect to Entra; a stale `CAS_ORIGIN` entry blocks it, exactly the bug the demo hit with CAS). `/readyz`: check DB and that the Entra discovery URL is reachable, not CAS. Text "Sign in with CAS" becomes "Sign in with Microsoft" (tests select it) |
| DB `cas_sessions` | Not needed (no back-channel revocation). Drop the table and its cleanup, or repurpose for `sid` revocation if you implement front-channel logout |
| `vendor/` | Add `jumbojett/openid-connect-php`, `phpseclib/phpseclib` and `paragonie/constant_time_encoding` (hand-vendored from pinned archives, no Composer; `random_compat` not needed on PHP 8), keep phpCAS for rollback, record SHA-256 hashes in `PROVENANCE.json`, update `samples/licenses.json` |
| Hosting env | Add `ALUMNI_AUTH` (`cas` default, `entra`), `ENTRA_TENANT_ID`, `ENTRA_CLIENT_ID` and the secret file location; keep the CAS variables during the rollback window. In Compose also join the `edge` network |
| `README.md` | Document the new flow and hosting constraints |

### Secrets on shared hosting

The client secret (or certificate) must not live in `public_html` or the repository. Put it in a file above the web root, readable only by the account (`chmod 600 /home/<user>/.config/alumni-entra.php`), loaded by `IdentitySession::secret()`. Entra secrets expire (at most 24 months): note the expiry date and rotate before it. A certificate credential is stronger if the library supports it.

### Redirect URIs and cookies

Register `https://alumni.<domain>/login` (exact) as a **web** redirect URI and `https://alumni.<domain>/` as post-logout redirect. The session cookie stays `Secure; HttpOnly; SameSite=Lax` (top-level redirects carry it). A front-channel logout URL would need `SameSite=None`; skip it unless required.

### Authorization and data mapping

`profiles.uid` joins on `uid`: take it from Graph `mailNickname` (the old CAS `uid`), **not** the UPN local part, which differs for real accounts (`hr-recipe-admin@…` vs `alice`). `/directory` stays alum-only through the `alum` app role; a user with only a base `member` role signs in but gets 403.

## Verification

1. Anonymous `/profile` redirects to `login.microsoftonline.com`; after sign-in returns to `/profile` with `uid`, `mail`, `roles`.
2. `/directory` 200 for erin and alice, **403 for carol**.
3. Sign out lands on `/`, and a new `/profile` visit goes back to Entra (Entra may sign you in silently if its session is still valid; test with a fresh window or `prompt=login`).
4. `readyz` stays 200 with Entra reachable and DB up.

## Variant: Apache `mod_auth_cas` (edge-terminated), UC-06

Demo: `samples/apps/cpanel-events` (Campus Events Admin). Here the PHP has **no sign-in code**: an `.htaccess` (`AuthType CAS`, `Require valid-user`) makes `mod_auth_cas` authenticate and set `REMOTE_USER`; authorization is a local table keyed by it. See [integration scenarios](./integration-scenarios.md) for why this is class T2.

### Validation status

Deployed 2026-11-10 on the demo VM. **Both paths validated by browser test** (Entra path page-observed with MFA done by the operator; automated authenticated tests remain MFA-blocked). Legacy: 4 browser tests against the real CAS (anonymous redirect for the page and the static export, admin, organizer, non-staff, logout ends CAS SSO). Entra: OIDC callback and Graph `mailNickname` link, admin dashboard, static export refused, Entra logout and re-authentication, non-staff 403; rollback to `mod_auth_cas` exercised. The live sign-in found a bug the anonymous tests could not (`require` vs `require_once` of the shared helper class, a fatal on the first page after the callback). Not observed: the export download as alice, an unassigned user. See the [evidence report](../../../../samples/docs/EVENTS-ENTRA-VALIDATION.md).

### Approach: replace the edge inside PHP, keep the contract

A cPanel user normally cannot install `mod_auth_openidc`. So `EVENTS_AUTH=entra` swaps `.htaccess` for

```apache
php_value auto_prepend_file /var/www/events/src/entra_guard.php
```

The guard runs before each PHP page under `/admin`, signs in with OIDC (code flow, S256 PKCE, state, nonce, exact HTTPS redirect `/admin/callback.php`, tenant check, `mailNickname` from Graph as `uid` as in the Alumni pilot) and sets `$_SERVER['REMOTE_USER']`. The application pages and the role table are unchanged, so migration is a deployment change, not a rewrite. If you control Apache, `mod_auth_openidc` is the closer swap.

### Traps found by running it

1. **A prepend does not run for static files.** Anything the old `AuthType CAS` directory protected that is not PHP becomes public. Deny direct access (`Require all denied` in `exports/.htaccess`) and deliver the file through a guarded PHP script that also checks the role. Test the anonymous static URL in both modes.
2. **Edge authentication is not authorization.** `valid-user` admits every CAS user to static files; the only fix at the edge is a user list in `.htaccess` that duplicates and drifts from the role table. Moving the file behind PHP removes the duplicate. `mod_auth_cas` answers **401**, not 403, when an authenticated user fails `Require user`.
3. **Module directive names differ by version.** The Debian build (1.2) has no `CASValidateServer`; setting `CASCertificatePath` enables server certificate validation. `CASScrubRequestHeaders` is valid only in a `<Directory>` section, not in `.htaccess` or server scope.
4. **Behind a TLS-terminating proxy** set `CASRootProxiedAs <https origin>` or the module builds `http://` service URLs. Its cookie is set without `Secure` and with the protected directory as its path (`/admin/`): add `Secure` at the gateway (`proxy_cookie_flags ~ secure`) and clear the cookie on that path at logout, or sign-out silently fails.
5. **No back-channel logout** in this setup: register the CAS service with `logoutType NONE` and document that other apps' sessions are not ended.
6. **A newly registered CAS service is not hot-loaded** in the demo's JSON registry: CAS keeps answering "Application Not Authorized" until it is restarted.
7. **Form-action CSP**: include the identity provider's origin (`login.microsoftonline.com` or the CAS origin) for the sign-out redirect.

### Entra objects

OIDC app registration (single tenant, implicit flows off, assignment required), redirect `https://<host>/admin/callback.php` and post-logout `https://<host>/`, a base `member` app role, a client secret in a `0600` file above the web root, and an admin consent grant for delegated Graph `User.Read` when the tenant blocks user consent. Authorization stays in `event_staff`; the app role only decides who may sign in.

## Pitfalls

- `AADSTS50011` redirect mismatch (path, trailing slash, `http` vs `https`).
- ID token has no `roles`: user unassigned or role not on the app registration.
- Library needs `ext-curl`/`openssl` and outbound HTTPS from the host; some shared hosts block outbound calls: test `curl https://login.microsoftonline.com/<tenant>/v2.0/.well-known/openid-configuration` from the account first.
- Never log tokens or claims; PHP error logs on shared hosts are often readable by other staff. Authorization codes also appear in web-server access-log query strings: strip `?...` before sharing logs.
- A signed-in operator (or any other) Entra session silently completes sign-in as that account. If it lacks the required profile it is rejected with 401 `invalid_employee_profile`; test with a clean profile or `prompt=login`.
- `AADSTS65001` / "Need admin approval": the tenant blocks user consent; grant `User.Read` for this app once as an admin.
- Mandatory MFA enrollment blocks unattended sign-in for the dedicated test users; observe the browser flow instead of weakening policy.
