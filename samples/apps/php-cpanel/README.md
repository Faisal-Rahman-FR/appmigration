# UC-05 — Alumni Directory — cPanel-like PHP-FPM

Plain PHP 8.3, MariaDB and **real phpCAS 1.6.1**, manually uploaded under `vendor/` with Apache-2.0 LICENSE/NOTICE. PSR Log 3.0.2 is vendored with its MIT license; the small autoloader loads the real library, not a CAS replacement. No Composer, runtime downloads, Apache auth module, or root access is required for application upload. `IdentitySession.php` is the only CAS/session integration and role helper. CAS certificate validation remains enabled.

The Compose Apache frontend uses `.htaccess` rewrites, PHP-FPM and `/home/alumni/public_html`; FPM receives the exact same filesystem path. On actual cPanel upload `public_html/`, `src/`, `vendor/` beneath `/home/alumni`, configure PHP-FPM environment through the hosting provider, set `DB_HOST`, `DB_PASSWORD`, `CAS_ORIGIN`, `ALUMNI_ORIGIN`, `CAS_CA_FILE`, and the trusted reverse proxy hostname `SLO_PROXY_HOST`. Private code/vendor stay outside document root. Grant the DB account SELECT on the seeded alumni schema. Shared-host providers must support curl, DOM, PDO MySQL and HTTPS CAS callbacks. Hosting-provider support may be required to set environment and restrict `/slo`; do not expose unrestricted SLO or disable source checks to make it work.

`/login` validates tickets with phpCAS; `/profile` shows released attributes and a uid-linked DB profile; `/directory` requires `alum`. Logout is a CSRF-protected POST and redirects to CAS global logout. CAS back-channel SLO is accepted only through the dedicated gateway route from CAS's internal address, and phpCAS additionally restricts the proxy source. Logout payloads on other paths are rejected. Public identity headers are never consumed. Anonymous `/healthz`; readiness actually checks DB and trusted HTTPS CAS.

The helper retains PHP strict session mode and regenerates the session ID after the real phpCAS post-authentication callback. phpCAS's default ticket-derived session renaming is deliberately disabled because it conflicts with strict-mode session ID validation. Its supported signout callback instead revokes a SHA256 ticket hash in `alumni.cas_sessions`; every authenticated request checks that persisted revocation/expiry before granting access. No raw ticket or session ID is stored in SQL. The DB account needs INSERT/UPDATE/DELETE on that table in addition to SELECT on profiles; the supplied grant script provides exactly those alumni privileges. This is application session management, not a substitute for phpCAS protocol validation.

From `samples`: `docker compose --env-file .local/demo.env up -d alumni apache`. Full suite start is recommended because nginx needs all upstreams.

## Entra OIDC pilot and CAS rollback

`ALUMNI_AUTH=cas` is the default and keeps the phpCAS path above unchanged. `ALUMNI_AUTH=entra` switches `IdentitySession` to OpenID Connect (authorization code + S256 PKCE) using the vendored `jumbojett/openid-connect-php` 1.0.2, `phpseclib` 3.0.58 and `paragonie/constant_time_encoding` 3.1.3 (pinned by SHA-256 in `vendor/PROVENANCE.json`; hand-vendored, no Composer). An unknown value fails startup.

- **PKCE must be forced.** Entra's discovery document does not list `code_challenge_methods_supported`, so the library silently sends no PKCE unless `providerConfigParam` supplies it. `tests/run.php` asserts the S256 challenge.
- **Identity.** After the ID token is verified (signature, issuer, audience, expiry, nonce, state) the app also requires `tid` to equal the configured tenant, then reads `id, mailNickname, mail, displayName` from Graph `/me` using the delegated `User.Read` token. The Graph `id` must equal the token's `oid`. `uid` is `mailNickname`, **never** the UPN local part, so it keeps matching `profiles.uid`. `roles` becomes `eduPersonAffiliation`, so `isAlum()` and the templates are unchanged.
- **Failures** end on a 401 "Sign-in failed" page with a non-secret code; they never redirect back into the authorization flow.
- **Secret** lives in `/home/alumni/.config/alumni-entra.php` (mode 0600, above `public_html`). The file is refused if world-accessible. In Compose it is bind-mounted from `ALUMNI_ENTRA_SECRET_FILE` (default `/dev/null`, so CAS mode needs no file) and installed by `entrypoint.sh`.
- **Network.** The container joins the existing `edge` network for outbound HTTPS to `login.microsoftonline.com` and `graph.microsoft.com`; no host port is published. Entra mode uses public CAs and skips the CAS CA import.
- **Logout** destroys the PHP session, then redirects to Entra's end-session endpoint. `/slo` returns 403: Entra has no back-channel logout.
- **Environment:** `ALUMNI_AUTH`, `ENTRA_TENANT_ID`, `ALUMNI_ENTRA_CLIENT_ID` (Compose variable name, passed to the app as `ENTRA_CLIENT_ID`), `ALUMNI_ENTRA_SECRET_FILE`.

Checks: `docker run --rm --entrypoint php -v "$PWD/apps/php-cpanel/tests:/home/alumni/tests:ro" <alumni-image> /home/alumni/tests/run.php` (20 assertions). Browser: `npx playwright test specs/alumni-entra.spec.ts` with the Entra variables loaded; the authenticated cases are skipped unless `ENTRA_AUTOMATED_LOGIN=1` because MFA-enrolled users cannot sign in unattended.

Rollback: recreate only `alumni` without the Entra environment (`docker compose --env-file .local/demo.env up -d --no-deps alumni`). See the [validation report](../../docs/ALUMNI-ENTRA-VALIDATION.md) for what was and was not proven.
