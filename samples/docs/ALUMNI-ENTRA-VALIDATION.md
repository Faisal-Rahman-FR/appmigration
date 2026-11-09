# Alumni PHP + phpCAS to Entra OIDC: tenant validation

## Verdict

**Partially validated.** The Alumni pilot (UC-05) was vendored, built, unit-tested, deployed and exercised in the approved non-production tenant on 2026-11-05. Implementation, deployment, the live OIDC challenge, a successful admin sign-in and logout, and fail-closed rejection of an unprovisioned account are evidenced below. **Not yet proven:** the member (`carol`) sign-in with the 403 directory denial, the admin directory listing and rendered profile values, and any automated authenticated browser test (MFA). Do not describe the recipe as fully working until those are observed.

Evidence quality matters here. The assistant could not see the user's authenticated sessions. Its own claims rest on the application's request log (paths and status codes only) and on pages it drove itself. Two form answers from the user matched the assistant's suggested defaults word for word and the log did not corroborate the member run, so they are **not** counted as evidence.

The recipe was not executable as written. Corrections are in the [recipe](../../.github/skills/migrate-app-to-entra-id/references/recipe-php-shared-hosting.md).

## Environment and approved changes

| Item | Value |
|---|---|
| Test tenant | `9b6ae5da-be43-463a-807f-c2cf9ec887db` |
| App | <https://alumni.chris.securitylabworks.com/> on the existing Linux VM (`vm-idpdemo-kiv1-linux`, `rg-faisal-idpdemo`) |
| App registration / enterprise app | `demo-alumni-oidc-validation` |
| Client ID | `9c1b9cf8-6f50-4294-93e9-1d08d7cf60c6` |
| Application object ID / service principal ID | `6261a58d-a967-4a79-9b87-a85a7bd69124` / `74c5adc2-a5e4-4454-8a77-66e1b8f2570d` |
| Callback / post-logout return | `https://alumni.chris.securitylabworks.com/login` and `https://alumni.chris.securitylabworks.com/` |
| Audience / assignment | Single tenant; assignment required; implicit flows off |
| Permissions | OIDC `openid profile email`; delegated Graph `User.Read` |
| Credential | One 7-day client secret, expires **2026-11-11 22:50 UTC** |
| Final deployed mode | `ALUMNI_AUTH=entra`; HR remains in Entra mode from the earlier pilot |

Role assignments (existing dedicated users, no attribute, password or MFA change): `hr-recipe-admin` (uid `alice`) holds `alum`; `hr-recipe-member` (uid `carol`) holds `member`. The operator account also holds a default-access assignment on the new enterprise app, created automatically as the owner; it has no role and is correctly rejected by the app.

**Additional tenant change (separately approved):** the tenant blocks user consent ("Need admin approval"), so a single `oauth2PermissionGrant` was created: Graph `User.Read`, `AllPrincipals`, for this one app only. It is removed when the app is deleted.

### Credential handling

Same discipline as the HR pilot: the secret is only in ACL-protected ignored files (`samples/.local/alumni-entra-secret.php`, `entra-alumni.env`) and, on the VM, root-only `0600` files installed through an RSA-OAEP envelope whose private key was deleted after use. In the container the secret is a `0600 www-data` file above the web root; `public_html` contains only `index.php`. No secret, token or authorization code is recorded here.

## Recipe corrections found by running it

1. **PKCE was silently not sent.** Entra's discovery document has no `code_challenge_methods_supported`, and the library only adds PKCE when the provider advertises S256. Run against this tenant, the recipe's client sent **no** `code_challenge`; the corrected client does (`providerConfigParam`). This is the most important finding.
2. **UID derivation would have broken account linking.** The recipe's fallback (UPN local part) yields `hr-recipe-admin`, not `alice`, so nobody matches `profiles.uid`. The app now takes `uid` from Graph `mailNickname`, requires the Graph `id` to equal the token's `oid`, and requires `mail` and `displayName`.
3. **Vendoring:** Composer was not available, so the three packages were vendored by hand from pinned archives (hashes in `vendor/PROVENANCE.json`) with a small autoloader. `paragonie/random_compat` is a no-op stub on PHP 8 and was omitted.
4. **Networking:** the container was on an internal-only network; it now joins `edge` for Entra and Graph. Entra mode skips the CAS CA import.
5. **Secret placement:** a mounted 0600 file above the web root, refused if world-accessible. The Compose mount defaults to `/dev/null` so CAS mode is unaffected (a missing host path would otherwise become a directory).
6. **CSP and readiness:** `form-action` now allows the identity provider for the selected mode; `/readyz` probes Entra discovery in Entra mode; `/slo` returns 403.
7. **Fail-closed rejection:** unprovisioned accounts end on a 401 page with `invalid_employee_profile`, never a redirect loop.
8. **Consent policy:** a tenant that blocks user consent needs an admin grant for `User.Read` (or "Consent on behalf of your organization" by an admin).
9. **Graph CLI token:** tenant writes needed an interactive `az login` (continuous access evaluation) mid-run.
10. **Logout behavior:** when more than one account is signed in at Entra, the end-session endpoint shows an account picker and, after you pick, a "You signed out" page instead of returning to `post_logout_redirect_uri`. The app session was already destroyed before the redirect. Providing a `logout_hint` would avoid the picker (requires the `login_hint` optional claim; **verify**, not tested).

## Measured results

| Check | Result |
|---|---|
| PHP checks (`tests/run.php`, built image on the VM) | **20 passed, 0 failed** |
| Defect proof: recipe-as-written against live discovery | Sent **no** `code_challenge` |
| Original deployed CAS Alumni suite after the change (CAS mode) | **2 passed** (`alumni.spec.ts`, 2026-11-04 22:52 UTC) |
| Live Entra mode: `/healthz`, `/readyz` | 200 `ok`, 200 `ready` |
| Entra anonymous challenge test | **1 passed**: tenant-specific authorize URL, exact callback, `S256`, state, nonce, `User.Read`; `/slo` 403 |
| Authenticated Playwright cases | **2 skipped** by design (MFA); not run, not passed |
| TypeScript `tsc --noEmit` | Passed |
| Secret file in the container | `600 www-data`, above web root |

CAS cross-app logout (`slo.spec.ts`) was not rerun for Alumni: HR is currently in Entra mode, which that suite depends on being CAS.

### Interactive evidence (application request log, paths and statuses only)

All times 2026-11-05 UTC. The requests came from the integrated browser the assistant opened.

| Time | Request | Status | Meaning |
|---|---|---|---|
| 15:09:00 | `GET /login` | 302 | Redirect to Entra |
| 15:09:04 | `GET /login` (callback) | 303 | Code exchanged; ID token, tenant and Graph profile verified |
| 15:09:05 | `GET /profile` | 200 | A valid identity reached the app (the dedicated admin: Entra's sign-out picker later listed `hr-recipe-admin`) |
| 15:09:50 | `POST /logout` | 302 | CSRF-checked logout, session destroyed, redirect to Entra |
| 15:11:34 | `GET /profile` | 302 | Re-authentication required after logout |
| 15:11:35 | `GET /login` | 401 | Operator account (silent SSO) rejected: `invalid_employee_profile`, no loop |

Because `/profile` only returns 200 after the token and profile checks pass, the 15:09:05 request is real evidence that signature/issuer/audience/nonce/state, the `tid` check, Graph egress and the `mailNickname` mapping work end to end. What it does **not** show is the rendered uid, roles or biography.

## Still to prove

1. Admin: rendered `uid=alice`, `eduPersonAffiliation=alum`, biography; `/directory` returns 200 with Alice Avery (2010) and Erin Ellis (2018).
2. Member: sign in as `hr-recipe-member`; `/profile` shows `uid=carol`, role `member`; `/directory` returns **403**.
3. Replay of a pre-logout session cookie returns 302 to Entra (covered by the skipped automated test).
4. An automated run, if tenant policy ever permits unattended sign-in.

To finish 1 and 2 safely: use a clean browser profile or InPrivate window (a signed-in `farahm` session will silently complete the sign-in and be rejected), start at the app home page, sign in as the dedicated user, and let an observer record the profile values and `/directory` status. Do not paste credentials into chat.

## Rollback and cleanup

```bash
cd /srv/idpdemo/source/samples
unset ALUMNI_AUTH ALUMNI_ENTRA_SECRET_FILE ALUMNI_ENTRA_CLIENT_ID ENTRA_TENANT_ID
docker compose --env-file .local/demo.env up -d --no-deps alumni
```

Rollback was exercised on the final image (CAS Alumni suite: 2 passed). A pre-change source backup and image tag (`alumni-cas-rollback:20261104`) are on the VM; the backup is in `.local/entra-evidence/alumni-cas-source.tgz`.

Nothing in the tenant was cleaned up. After approval, remove only `demo-alumni-oidc-validation` (which also removes its consent grant and assignments) and the protected local/VM credential files; keep the dedicated users while HR still uses them. **The Linux VM has a daily auto-shutdown at 00:00 Central and was found deallocated twice; restart it before testing.** The app returns to the legacy path on any recreate that omits the Entra environment.
