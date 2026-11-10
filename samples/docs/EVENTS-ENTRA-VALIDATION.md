# Campus Events Admin (cPanel-style PHP, Apache `mod_auth_cas`) to Entra OIDC: tenant validation

## Verdict

**Validated by manual browser test, page-observed; automated authenticated tests remain MFA-blocked.** UC-06 was built, deployed to the existing Linux VM and exercised against the real CAS on 2026-11-10, then switched to Entra in the approved test tenant. After the DNS record for `events.chris.securitylabworks.com` was added, the assistant read the pages in the integrated browser while the operator completed sign-in (about 19:14 to 19:20 UTC). Proven: the legacy path (4 browser tests), the rollback, the Entra challenge, the OIDC callback with Graph profile lookup, the admin dashboard for alice, the staff page, the refused static export, Entra logout, re-authentication after logout, and the non-staff 403 for the second user. **Not observed:** the attendee download for alice, an unassigned user being blocked at Entra, a replay of a pre-logout cookie, and any automated authenticated test (MFA). Carol's identity is inferred, not read: the page only says "not event staff", and only alice (who shows admin) and carol are assigned to the app.

## Environment and approved changes

| Item | Value |
|---|---|
| Test tenant | `9b6ae5da-be43-463a-807f-c2cf9ec887db` |
| App | `https://events.chris.securitylabworks.com/` on `vm-idpdemo-kiv1-linux`, Compose service `events` |
| Legacy sign-in | Apache `mod_auth_cas` 1.2 (Debian), CAS 2 validation, CAS service id 103 (`logoutType NONE`) |
| App registration / enterprise app | `demo-events-oidc` |
| Client ID | `dae6d18a-f60a-4579-8b7b-f17659d1fc87` |
| Application object ID / service principal ID | `e0e68d1d-8e7d-479b-8287-ced5fa3a7b12` / `033e5084-b814-440a-a073-e230764e5d1f` |
| Redirect / post-logout | `.../admin/callback.php` / `.../` |
| Audience / assignment | Single tenant; assignment required; implicit flows off |
| Role and assignments | `member`; `hr-recipe-admin` (uid `alice`) and `hr-recipe-member` (uid `carol`). No user, password or MFA change |
| Permissions | OIDC `openid profile email`; delegated Graph `User.Read` with one admin consent grant for this app |
| Credential | One 7-day client secret, expires **2026-11-17 16:42 UTC** |
| Final deployed mode | `EVENTS_AUTH=entra` |

Authorization is the local table `events.event_staff` (alice `admin`, bob `organizer`), seeded by `database/03-events.sql`. It was applied to the existing database by hand because the volume was already initialised.

### Credential handling

The secret was created in memory, encrypted with RSA-OAEP-SHA256 to a one-time public key generated on the VM, and decrypted there into a root-only `0600` file (`.local/events-entra-secret.php`). The VM key pair and ciphertext were deleted. In the container it is a `0600 www-data` file above the web root (`/var/www/events/.config/events-entra.php`). The secret was never written locally, printed or committed. Non-secret IDs are in the ignored `samples/.local/entra-events-validation.json`.

## Findings from running it

1. **`CASValidateServer` does not exist** in `mod_auth_cas` 1.2; setting `CASCertificatePath` turns certificate validation on. `CASScrubRequestHeaders` is allowed only in a `<Directory>` section.
2. **The module's cookie has no `Secure` flag and its path is the protected directory** (`/admin/`). A `Header edit` in Apache did not add the flag; `proxy_cookie_flags ~ secure` at the gateway did. The first logout attempt failed silently because the cookie was cleared on path `/`.
3. **`Require user` failures return 401**, not 403.
4. **A new CAS service is not picked up** until CAS is restarted (the JSON registry logged `Loaded [2]` every minute for the 25 minutes between staging the file and the restart); the login page said "Application Not Authorized".
5. **Edge authentication is not authorization.** `valid-user` would let `carol` fetch the static export; only a hand-kept user list in `exports/.htaccess` prevents that. In Entra mode the export is denied statically and served by `download.php`, which checks the role.
6. **A PHP prepend never runs for static files**; the design relies on `Require all denied` in `exports/` rather than the guard.
7. **No back-channel logout** with `mod_auth_cas` here, so the CAS service registers none.
8. **Shared code:** the Entra libraries and `EntraProfile.php` are reused from the Alumni sample through a named Compose build context instead of being copied.
9. **A bug only the live sign-in found.** The OIDC callback succeeded (303 to `/admin/`) and the first page then died with `Cannot declare class Events`: the guard loaded the helper with `require_once` and the pages with plain `require`. The anonymous tests could not reach this. All pages now use `require_once`.
10. **Entra logout shows an account picker** (as in the Alumni pilot); the app session is already destroyed before the redirect, and the next `/admin/` visit went back to Entra.

## Measured results

| Check | Result |
|---|---|
| `php tests/run.php` in the image | **11 ok, 0 failed** (return-URL allow-list, CSRF binding, mode validation, escaping) |
| `tsc --noEmit`; fixture tests (21 apps, UC-06 registered) | Passed; 7 passed |
| CAS mode, `events.spec.ts` | **4 passed**: anonymous `/admin/`, download and static export all 302 to CAS with no data; admin alice (dashboard, staff page, export 200, CSRF-less POST 403, logout ends CAS SSO); organizer bob (own events, staff page and download 403, static 401/403); carol signs in, "not event staff", static 401/403 |
| CAS cookie after the fix | `MOD_AUTH_CAS`, path `/admin/`, `Secure` true; cleared at logout |
| Entra mode `/readyz` | 200 `ready` (DB, secret file, live Entra discovery) |
| Entra anonymous challenge (`events-entra.spec.ts`) | **1 passed**: `/admin/`, `/admin/callback.php`, `download.php` redirect to Entra; static export 403 with no content |
| Entra authenticated cases | **2 skipped** by design (MFA); not run |

## Not proven

1. The attendee download as alice (the link exists; not clicked), and its refusal for carol and bob in Entra mode.
2. An unassigned user being blocked by Entra's assignment-required check.
3. A replay of a pre-logout session cookie, and any automated authenticated test (MFA).
4. Any behaviour on a real cPanel host (the container imitates one).
5. Carol's uid on the page (the app shows nothing for a non-staff user).

## Rollback and cleanup

```bash
cd /srv/idpdemo/source/samples
docker compose --env-file .local/demo.env up -d --no-deps --force-recreate events   # without EVENTS_AUTH: back to mod_auth_cas
```

The pre-change source archive is `.local/entra-evidence/pre-events-source.tgz`. Nothing in the tenant was cleaned up. After approval delete only `demo-events-oidc` (removes its consent grant and assignments) and the protected VM files `.local/events-entra-secret.php` and `.local/entra-events.env`; keep the dedicated users. The VMs auto-shut-down at 00:00 Central.
