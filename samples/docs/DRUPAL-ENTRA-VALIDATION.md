# Drupal + samlauth with Entra ID as SAML IdP: tenant validation

## Verdict

**Validated by manual browser test, observed in the page itself; automated authenticated tests remain MFA-blocked.** On 2026-11-05 the Drupal pilot (UC-04) was deployed to the existing Linux VM and exercised in the approved non-production tenant. The assistant read the rendered pages in the integrated browser while the operator completed password and MFA, so the profile values below are page-observed, not user-reported. Two earlier "signed in as carol" answers were **not** counted: the first returned `alice` (Entra's account picker had silently reused her session), the second showed no ACS request in the application log. The carol result below comes from the third attempt, via **Use another account**, and was read from the page.

The protocol did not change (SAML 2.0), so the work was configuration plus a small role-mapping change. The recipe was not executable as written; corrections are in the [recipe](../../.github/skills/migrate-app-to-entra-id/references/recipe-drupal-samlauth.md).

## Environment and approved changes

| Item | Value |
|---|---|
| Test tenant | `9b6ae5da-be43-463a-807f-c2cf9ec887db` |
| App | <https://drupal.chris.securitylabworks.com/> on `vm-idpdemo-kiv1-linux` (`rg-faisal-idpdemo`) |
| Enterprise application | `demo-drupal-saml-validation` |
| Application (client) ID | `ebb3804a-19b8-4377-89eb-ef04987e9ba8` |
| Application object ID / service principal ID | `30cff4fa-119e-4cc0-be0f-c5ce49d955fd` / `c70b7e0f-221f-428c-b819-6bb5d7ae0165` |
| Identifier (SP entity ID) | `https://drupal.chris.securitylabworks.com/saml/metadata` |
| Reply URL (ACS) / logout URL | `https://drupal.chris.securitylabworks.com/saml/acs` / `.../saml/sls` |
| IdP entity ID / SSO / SLO | `https://sts.windows.net/<tenantId>/` / `https://login.microsoftonline.com/<tenantId>/saml2` (both) |
| Assignment | Required |
| Token-signing certificate | Self-signed, made the preferred key, expires **2028-11-01** (thumbprint `01FB0C86DDEDD045F9F537110BBFE81D53F5290A`) |
| Claims mapping policy | `demo-drupal-saml-claims` (`ecaa966b-7862-4d96-b0fd-116252e007c6`), assigned to this app only |
| Final deployed mode | `DRUPAL_AUTH=entra` |

App roles: `member` (`f8112002-c010-4e3d-a066-a1f48380c869`), `faculty` (`874463c0-db1e-43dd-b5f4-69aba9b175c3`), `staff` (`78974a5b-f187-47f0-ba7b-2ddbb4881863`).

Role assignments (existing dedicated cloud-only users; no user, password or MFA change): `hr-recipe-admin` (uid `alice`, object `887ecc72-e3c8-4810-b156-56b2447df984`) holds `faculty`; `hr-recipe-member` (uid `carol`, object `87407e10-82bd-46c4-8f79-9b2987f3c620`) holds `member`.

Claims emitted (from the policy plus the basic claim set): `uid` (= `mailnickname`), `mail`, `displayName`, `appRoles` (= `user.assignedroles`), and the default role URI `http://schemas.microsoft.com/ws/2008/06/identity/claims/role`.

### Credential handling

No secret exists in this pattern: SAML needs no client secret, and the only file shipped is Entra's **public** signing certificate. It is `samples/.local/entra-drupal-idp-signing.crt` locally and `.local/drupal/entra-idp-signing.crt` (0600) on the VM, copied into the container by `entrypoint.sh`. The Drupal SP key and certificate are unchanged. Non-secret object IDs are in the ignored `samples/.local/entra-drupal-validation.json`.

## Corrections found by running the recipe

1. **A non-gallery application comes with default app roles** (`User`, `msiam_access`). A PATCH that replaces `appRoles` fails with `CannotDeleteOrUpdateEnabledEntitlement` until the defaults are disabled in a first call.
2. **Entra signs the assertion, not the response, by default.** samlauth's `security_messages_sign: true` would reject the response; the Entra mode overrides it to `false` (`security_assertions_signed` stays `true`). The signing option is a portal setting.
3. **Assertion encryption is off.** `security_assertions_encrypt` is overridden to `false`; enabling it needs Token encryption configured in Entra with the Drupal SP certificate (not done, licensing **verify**).
4. **No requested AuthnContext.** `security_request_authn_context` is overridden to `false` to avoid `AADSTS75011`.
5. **Do not name the role claim `roles`.** The demo profile page renders every attribute with `data-testid=<name>` and already uses `roles` for Drupal's own roles, so the claim is named `appRoles`. `RoleSync` reads `appRoles`, `roles` or the default role URI.
6. **Signed AuthnRequests were accepted without extra setup.** Entra ignores the redirect-binding signature unless a verification certificate is configured; the sign-in page loaded with no AADSTS error.
7. **The mail attribute changes on first login.** `sync_mail: true` replaced the seeded `alice@demo.test` with the Entra mail (`hr-recipe-admin@...`). The account name and link stayed `alice`.
8. **The post-login URL is `/demo/profile?check_logged_in=1`.** The legacy `drupal.spec.ts` asserted the bare URL and failed on the rollback run; both specs now expect the query string.
9. **Account picker pitfall.** Entra's picker lists the last account and one click signs it in silently. To test a second user choose **Use another account**.
10. **Logout.** samlauth sends a signed LogoutRequest to Entra; Entra ends its session, shows "You signed out of your account", and posts the response to `/saml/sls` (HTTP 302 in the log). Drupal's session is destroyed.

## Measured results

| Check | Result |
|---|---|
| `tsc --noEmit` (tests, on the VM) | Passed |
| `/healthz`, `/readyz` | 200 `ok`, 200 `ready` |
| Anonymous challenge | `/saml/login` returned 302 to `login.microsoftonline.com/<tenantId>/saml2` with `SAMLRequest`, `RelayState`, `SigAlg`, `Signature`; decoded request has Issuer `https://drupal.../saml/metadata`, ACS `https://drupal.../saml/acs`, NameID format transient |
| Playwright, Entra mode (`drupal-entra.spec.ts`) | **1 passed** (readiness and anonymous challenge); **2 skipped** by design (MFA, `ENTRA_AUTOMATED_LOGIN` unset); legacy `drupal.spec.ts` 2 skipped (not applicable) |
| Rollback run (`DRUPAL_AUTH` unset, Shibboleth IdP) | `drupal.spec.ts` **2 passed**; Entra specs skipped; then restored to Entra mode |

### Manual acceptance (page-observed, 2026-11-05 21:09 to 21:12 UTC)

| Account | Observed |
|---|---|
| `hr-recipe-admin` | Redirected to Entra, back through `POST /saml/acs`; `/demo/profile` showed uid `alice`, Drupal roles `authenticated, editor`, `appRoles=faculty`, `mail=hr-recipe-admin@...`, `displayName=HR Recipe alice`; `/demo/editor` rendered the editor workspace |
| `hr-recipe-admin`, sign out | `/saml/logout` went to Entra, "You signed out of your account"; `/saml/sls` returned 302; `/demo/profile` then returned **403** |
| `hr-recipe-member` | `/demo/profile` showed uid `carol`, roles `authenticated` (no `editor`), `appRoles=member`; `/demo/editor` returned **403** |

Both users landed on the pre-seeded `alice` and `carol` accounts (`create_users` stays `false`, `map_users_name` links by username). The Drupal user list was not inspected for stray accounts.

## Not proven

1. Carol's sign-out and a replay of a pre-logout cookie (the admin's post-logout 403 is proven, the replay of a stolen cookie is not).
2. An unassigned user (for example the operator account) being blocked by Entra's assignment-required check.
3. Any automated authenticated browser test; MFA blocks it.
4. Assertion encryption and signature verification of AuthnRequests by Entra (neither is configured).
5. Signing-certificate rollover: only one certificate is trusted in `idp_certs`.

## Rollback and cleanup

Rollback is configuration only and was exercised:

```bash
cd /srv/idpdemo/source/samples
unset DRUPAL_AUTH ENTRA_TENANT_ID
docker compose --env-file .local/demo.env up -d --no-deps --force-recreate drupal
```

`ENTRA_TENANT_ID` is also used by HR and Alumni; unset it only in the shell used to recreate Drupal, so a later recreate of those services in the same shell does not lose it. A pre-change image (`drupal-shibboleth-rollback:20261105`) and source backup (`.local/entra-evidence/drupal-shibboleth-source.tgz`) are on the VM; the test logs are `drupal-entra-final.log` and `drupal-shibboleth-rollback.log` in the same directory.

Nothing in the tenant was cleaned up. After approval, delete only `demo-drupal-saml-validation` (removes the service principal, role assignments and policy assignment) and the claims policy `demo-drupal-saml-claims`; keep the dedicated users while HR and Alumni still use them. The Linux VM has a daily auto-shutdown at 00:00 Central; restart it before testing.
