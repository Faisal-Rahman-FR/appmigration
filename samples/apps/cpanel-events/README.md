# UC-06 — Campus Events Admin (cPanel-style PHP behind `mod_auth_cas`)

A second shared-hosting PHP app, deliberately built on a **different legacy sign-in pattern from Alumni (UC-05)**. Alumni signs in with `phpCAS` inside the PHP code. This app has **no sign-in code at all**: Apache's `mod_auth_cas` protects `/admin` from an `.htaccess` file and hands the application a `REMOTE_USER` variable. That is the classic cPanel/Apache arrangement, and it is the "edge-terminated" class (T2) in the [integration scenarios guide](../../../.github/skills/migrate-app-to-entra-id/references/integration-scenarios.md).

## What it does

| Path | Who | Notes |
|---|---|---|
| `/` | anyone | Public calendar of approved events |
| `/admin/` | `event_staff` rows | Organizers see their own events, admins see all; admins can approve or cancel (POST + CSRF) |
| `/admin/staff.php` | admin | Staff table |
| `/admin/download.php?file=attendees.csv` | admin | The export, served through PHP |
| `/admin/exports/attendees.csv` | see below | The same file as a **static** file |
| `/healthz`, `/readyz` | anyone | Liveness; database plus the active sign-in mechanism |

Authorization is a local table, `events.event_staff(uid, role)` in MariaDB, keyed by `REMOTE_USER` (the CAS `uid`). Seeded users: `alice` admin, `bob` organizer. `carol` can sign in but is not staff and gets 403. Data is synthetic (`database/03-events.sql`).

## The legacy pattern and its two traps

`EVENTS_AUTH=cas` (default). `htaccess/admin.cas` is copied to `public_html/admin/.htaccess`:

```apache
AuthType CAS
Require valid-user
```

1. **Authentication is not authorization at the edge.** `valid-user` lets every CAS user (carol included) reach any file the PHP code would have refused her. Because the export is a static file, PHP never runs for it, so the only protection is a hand-maintained user list in `exports/.htaccess` (`Require user alice`). That list duplicates the role table and drifts from it.
2. **No back-channel logout.** `mod_auth_cas` does not implement CAS single logout in this setup, so the CAS service is registered with `logoutType NONE`. Sign-out drops the module's cookies and sends the browser to CAS `/cas/logout`.

## Entra ID pattern: a PHP guard, not a different module

`EVENTS_AUTH=entra` swaps the edge, not the application. A cPanel user usually cannot install `mod_auth_openidc`, so `htaccess/admin.entra` sets

```apache
php_value auto_prepend_file /var/www/events/src/entra_guard.php
```

`src/entra_guard.php` runs before every PHP page under `/admin`: authorization-code flow with S256 PKCE, state and nonce, an exact HTTPS redirect URI (`/admin/callback.php`), tenant check, and the Graph `mailNickname` as the `uid` (see the Alumni pilot for why). It then sets `$_SERVER['REMOTE_USER']`, the same variable `mod_auth_cas` set. **`public_html/admin/*.php` and the role table are unchanged.**

A PHP prepend never runs for static files, so `htaccess/exports.entra` denies everything under `exports/` and the export is delivered only by `download.php` (which the guard protects and which checks the admin role). That closes trap 1 by moving the decision into the application.

Secrets follow the shared-hosting layout: the OIDC client secret is a `0600` file above the web root (`/var/www/events/.config/events-entra.php`), installed by `entrypoint.sh` from a bind mount (`EVENTS_ENTRA_SECRET_FILE`, default `/dev/null` so CAS mode needs no file).

## Run

```powershell
docker compose --env-file .local/demo.env up -d --build events
```

Compose service `events` joins `private` (CAS through the gateway aliases) and `edge` (Entra and Graph egress). The gateway serves `EVENTS_HOST`. The build reuses the pinned, hash-verified `vendor/` and `src/EntraProfile.php` from `apps/php-cpanel` through a named build context, instead of copying them.

Existing database volumes do not re-run `docker-entrypoint-initdb.d`. Apply the schema once:

```bash
docker compose --env-file .local/demo.env exec -T db sh -c 'mariadb --protocol=socket -uroot -p"$MARIADB_ROOT_PASSWORD"' < database/03-events.sql
```

then grant `demo` `SELECT` on `events.*` and `UPDATE` on `events.events` (as in `database/02-grants.sh`). Register `config/ingest/events.json`'s service in the CAS service registry (`scripts/configure.mjs` generates it as service 103) and **restart CAS**: the JSON registry did not pick up the new file on its own.

## Environment

`EVENTS_AUTH` (`cas` or `entra`, anything else fails startup), `EVENTS_ORIGIN`, `CAS_ORIGIN`, `DB_HOST`, `DB_PASSWORD`; for Entra also `ENTRA_TENANT_ID`, `EVENTS_ENTRA_CLIENT_ID` (passed to the app as `ENTRA_CLIENT_ID`) and `EVENTS_ENTRA_SECRET_FILE`. `EVENTS_CSRF_KEY` is generated at every container start.

## Tests

`tests/run.php` (inside the image: `php /var/www/events/tests/run.php`) covers the return-URL allow-list, CSRF binding and mode validation. Playwright: `tests/specs/events.spec.ts` (CAS mode) and `tests/specs/events-entra.spec.ts` (`EVENTS_AUTH=entra`; authenticated cases need `ENTRA_AUTOMATED_LOGIN=1` and users without MFA). See the [validation report](../../docs/EVENTS-ENTRA-VALIDATION.md).
