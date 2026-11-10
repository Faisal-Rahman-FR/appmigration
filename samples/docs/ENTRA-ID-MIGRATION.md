# Using Microsoft Entra ID as the authentication provider for the demos

What it takes to make each demo application authenticate against Entra ID instead of CAS, the Shibboleth IdP and LDAP. The reusable procedure is the agent skill [`migrate-app-to-entra-id`](../../.github/skills/migrate-app-to-entra-id/SKILL.md); this document is the demo-specific change list.

> **Status: HR, Alumni, Drupal and Student pilots implemented; Campus Events (UC-06) deployed.** The Spring Boot HR app (UC-01) was validated manually in a test tenant ([evidence](./HR-ENTRA-VALIDATION.md)). The PHP Alumni app (UC-05) is deployed and **partially** validated: member/directory-403 and rendered-profile checks are still unobserved ([evidence](./ALUMNI-ENTRA-VALIDATION.md)). The Drupal app (UC-04) is deployed with Entra as its SAML IdP and was validated by manual, page-observed browser test; automated authenticated tests remain MFA-blocked ([evidence](./DRUPAL-ENTRA-VALIDATION.md)). The Student app (UC-03) keeps the native Shibboleth SP and uses Entra as its IdP; it was validated by manual, page-observed browser test, with automated authenticated tests MFA-blocked ([evidence](./STUDENT-ENTRA-VALIDATION.md)). The Campus Events app (UC-06, Apache `mod_auth_cas`) runs in both modes on the demo VM and was validated by page-observed browser test in the Entra tenant; automated authenticated tests remain MFA-blocked ([evidence](./EVENTS-ENTRA-VALIDATION.md)). The other demos and the infrastructure-wide identity-provider proposal below remain design/documentation only. Items marked *verify* still need confirmation.

## 1. Choose a strategy

| | A. Direct re-integration (target) | B. Bridge (transition) |
|---|---|---|
| Idea | Each app talks to Entra (OIDC or SAML) | CAS and the Shibboleth IdP delegate sign-in to Entra; apps keep CAS/SAML |
| App code changes | Yes, per app (below) | None |
| Retires CAS / Shibboleth IdP / LDAP | Yes | No (two identity systems to run) |
| Effort | Medium to high | Low to medium |
| Matches the recorded expected answers (`samples/expected/*.json`) | Yes (OIDC re-integration, custom SAML, gallery app) | Partly |

**Recommendation:** do A, app by app, with a configuration switch to fall back to the legacy path. Use B only as a stopgap while apps are changed. For apps that do not look like these demos (other languages, `mod_auth_cas`, LDAP binds, custom forms, Shibboleth headers, no authentication), classify them first with the [integration scenarios guide](../../.github/skills/migrate-app-to-entra-id/references/integration-scenarios.md), which also adds edge-swap (C), front-door (D) and keep-for-federation (E) strategies.

## 2. What changes per demo (Strategy A)

| Demo | Today | With Entra | Change size | Details |
|---|---|---|---|---|
| **UC-01 HR** (`apps/java-cas`) | Spring Boot + Apereo CAS client, CAS back-channel SLO | OIDC via Spring Security, `roles` claim for `/admin`, Entra logout | Medium | [Spring Boot recipe](../../.github/skills/migrate-app-to-entra-id/references/recipe-spring-boot.md) |
| **UC-02 Zoom** (`config/shibboleth/zoom`) | Old IdP relying-party and attribute filter, no app | Entra gallery app, SAML, claims mapped; old entries retired | Low (configuration only) | [SaaS recipe](../../.github/skills/migrate-app-to-entra-id/references/recipe-saas-gallery.md) |
| **UC-03 Student** (`apps/dotnet-shibsp`) | ASP.NET 4.8, native Shibboleth SP, `eppn` + affiliation server variables | Keep the SP, Entra becomes its IdP; identity helper reads `upn` and `roles` | Medium | [Shibboleth SP recipe](../../.github/skills/migrate-app-to-entra-id/references/recipe-shibboleth-sp-iis.md) |
| **UC-04 Drupal** (`apps/drupal-samlauth`) | samlauth to Shibboleth IdP, username link, role sync from affiliation | samlauth to Entra, same link, role sync from `roles` | Low to medium | [Drupal recipe](../../.github/skills/migrate-app-to-entra-id/references/recipe-drupal-samlauth.md) |
| **UC-05 Alumni** (`apps/php-cpanel`) | phpCAS on cPanel-style hosting, back-channel SLO | OIDC client vendored in `vendor/`, secrets above the web root | High | [PHP recipe](../../.github/skills/migrate-app-to-entra-id/references/recipe-php-shared-hosting.md) |
| **UC-06 Campus Events** (`apps/cpanel-events`) | Apache `mod_auth_cas` in `.htaccess`, `REMOTE_USER`, local role table; no sign-in code in PHP | OIDC guard via `auto_prepend_file` sets `REMOTE_USER`; static files moved behind PHP or denied | Medium | [PHP recipe, mod_auth_cas variant](../../.github/skills/migrate-app-to-entra-id/references/recipe-php-shared-hosting.md) |

Key code touch points:

- **HR pilot (implemented):** retain CAS behind `DEMO_AUTH=cas` for rollback; activate Spring Security OAuth2 client for `DEMO_AUTH=entra`, deny `/slo`, map ID-token roles to authorities, and read required employee attributes from Graph. Keep `memberOf`/`employeeNumber` selectors. Delete CAS code only after final cutover and the rollback window.
- **Student:** `shibboleth2.xml` (`SSO entityID`, metadata URL), `attribute-map.xml` (Entra claim URIs; use IDs `upn`/`roles`, **not** `eppn`/`affiliation`, see section 5), `TrustedSpIdentity.cs` (issuer, UPN suffix, roles), `Web.Demo.config.template`, and drop the metadata-Scope migration from `Install-IisDemo.ps1`.
- **Student pilot (implemented):** `AuthMode=shibboleth|entra` in `TrustedSpIdentity.cs` (still server variables only; Entra mode requires a tenant-domain `upn`, a single `uid` and the `roles` claim; record key stays `uid@DemoScope`), `shibboleth2.entra.xml.template` (Entra issuer, federation-metadata URL, `encryption="false"`, `redirectLimit="exact"`), `attribute-map.entra.xml` (IDs `upn`, `uid`, `displayName`, `roles`, never `eppn`/`affiliation`), and `scripts/Set-StudentAuth.ps1` to switch or roll back an installed site. The shibd validation command is `-check -config` (the old `-t -c` was a no-op).
- **Drupal pilot (implemented):** `DRUPAL_AUTH=shibboleth|entra` in `settings.php` (Entra IdP entity ID, SSO/SLO URLs, signing certificate from `.local/drupal/entra-idp-signing.crt`, and overrides that turn off response-signing, assertion-encryption and AuthnContext requirements), `RoleSync.php` (reads `appRoles` in Entra mode only), link text, `entrypoint.sh`, and Compose variables. Claims come from a claims mapping policy (`uid`, `mail`, `displayName`, `appRoles`). The Shibboleth path stays for rollback.
- **Alumni pilot (implemented):** `ALUMNI_AUTH=cas|entra` in `IdentitySession.php` (OIDC + forced S256 PKCE, Graph `mailNickname` as `uid`, Entra logout), `EntraProfile.php`, `index.php` (CSP `form-action` per mode, `readyz` per mode, `/slo` 403 in Entra mode), hand-vendored `vendor/`, hosting environment and a 0600 secret file above the web root. phpCAS stays for rollback.
- **Campus Events (UC-06, implemented):** `EVENTS_AUTH=cas|entra`; `htaccess/admin.{cas,entra}` and `exports.{cas,entra}` select between `AuthType CAS` and `php_value auto_prepend_file`; `src/entra_guard.php` (OIDC, S256 PKCE, Graph `mailNickname` as `uid`) sets `REMOTE_USER`; static `exports/` is denied in Entra mode and served by the guarded `download.php`; secret in a 0600 file above the web root. The pages and the `event_staff` role table are the same in both modes.

## 3. Entra objects to create

One tenant, one test-user set, **one application per demo** (HR, Alumni: OIDC app registrations; Drupal, Student: SAML enterprise applications; Zoom: gallery app).

### Users (from `samples/idp/ldap/users.json`)

| User (`mailNickname`) | employeeId | Old affiliations | Old groups |
|---|---|---|---|
| alice | 10001 | faculty, member, alum | research, hr-admins, alumni |
| bob | 10002 | staff, member | hr-admins, registrar, vpn-users |
| carol | 10003 | student, member | students |
| dave | 10004 | student, employee, member | students, research |
| erin | 10005 | alum | alumni |
| frank | 10006 | staff, member | admissions |
| grace | 10007 | affiliate | guests |

Keep `mailNickname` equal to the old `uid`, and set `mail`, `givenName`, `surname`, `displayName`, `employeeId` on each user.

### App roles and assignments (values reuse the old names so app code stays the same)

| App | Role values | Assignments needed by the demo tests |
|---|---|---|
| HR | `member` (base), `hr-admins` | alice, bob: `hr-admins`; carol: `member` (signs in, denied `/admin`) |
| Alumni | `member` (base), `alum` | alice, erin: `alum`; carol: `member` (signs in, denied directory) |
| Drupal | `member` (base), `faculty`, `staff` | alice: `faculty`; bob: `staff`; carol: `member` (not editor) |
| Student | `student`, `staff` | carol: `student`; bob: `staff` (registrar) |
| Zoom | n/a (claims only) | pilot user(s) |

With **assignment required** on, a user without any role cannot sign in, which is why the base role exists. Assigning groups instead of users needs Entra ID P1 or higher; user assignment works on any tier.

### Claims each app needs

| Claim | HR (OIDC) | Alumni (OIDC) | Drupal (SAML) | Student (SAML) |
|---|---|---|---|---|
| `uid` (= mailNickname) | custom claim or derive from UPN | custom claim (joins `profiles.uid`) | custom claim (account link) | not needed |
| `mail` | `email` | `email` | `user.mail` | optional |
| displayName | `name` | `name` | optional | `displayName` |
| `employeeNumber` (= employeeId) | custom claim or Graph | not shown | not shown | not shown |
| roles | `roles` | `roles` | role attribute | role attribute (`roles`) |
| principal | n/a | n/a | n/a | `upn` |

Full mapping and the Entra rules behind it: [claims-and-attributes](../../.github/skills/migrate-app-to-entra-id/references/claims-and-attributes.md).

## 4. Infrastructure and deployment impact

- **Deployment script.** `infra/Deploy-Demo.ps1` and `environment.json` have no identity-provider setting today. A natural extension is `identityProvider: legacy | entra` plus `entra: { tenantId, applications: {...} }`, with client secrets supplied through environment variables or a secret store, not the JSON file. *Not implemented.*
- **Compose/hosting.** HR and Alumni receive `ENTRA_TENANT_ID`, `ENTRA_CLIENT_ID` and a secret instead of `CAS_ORIGIN`/`CAS_CA_FILE`/`SLO_PROXY_HOST`. The private CA mount is not needed for Entra (public CAs). The apps and the Windows VM need **outbound HTTPS** to `login.microsoftonline.com` (and the Windows SP to refresh federation metadata); the current NSGs only restrict inbound.
- **Legacy components.** In Strategy A, CAS, the Shibboleth IdP and LDAP can be removed from Compose after the last app moves; keep them until the rollback window ends.
- **Tests.** `samples/tests/support/browser.ts`: new `entraLogin`, allow-list for Entra hosts, rewritten attribute assertions, removed or redefined cross-app logout checks. [Details](../../.github/skills/migrate-app-to-entra-id/references/testing-and-cutover.md).
- **Domain/UPN.** Users sign in as `alice@<tenant domain>`, not `alice@demo.test`. Either use the tenant's default domain or verify a domain you own. The Student app's scope check and `student-records.json` keys must follow.
- **Licensing (*verify*).** Group-to-app assignment needs Entra ID P1 or higher; SAML token encryption and signed-request verification certificates have their own requirements.

## 5. Differences users and operators will notice

1. **Logout.** Entra supports front-channel logout only. The back-channel SLO that HR and Alumni receive from CAS (`/slo`) has no Entra equivalent. Signing out of one app no longer signs out the others through a server callback, and Entra may sign a user straight back in if its session is still valid.
2. **MFA and Conditional Access** apply. Automated browser tests need dedicated test users in a tenant that permits password-only sign-in, or an approved, narrowly scoped exemption.
3. **Attribute availability.** `employeeNumber` and any custom attribute exist in tokens only if populated on the user and added as a claim. `groups` is capped (150 SAML, 200 JWT) and holds GUIDs, which is why app roles are used.
4. **The scope trap.** Entra metadata carries no `shibmd:Scope`; the Shibboleth SP's default attribute policy deletes `eppn` and `affiliation` values without it. This demo hit that exact failure against its own IdP. Using the attribute IDs `upn` and `roles` in the SP avoids it.
5. **Secrets and certificates expire.** Client secrets (at most 24 months), SAML signing certificates, and (for Alumni) the secret file outside `public_html` need an owner and a renewal date.
6. **Tenant policy can interfere.** In this project's managed tenant, Microsoft Graph calls required an interactive re-login (`TokenCreatedWithOutdatedPolicies`), user creation may be restricted, and tenant policies forced Storage and Key Vault private. Prefer a developer tenant for the Entra work.

## 6. Suggested order

1. **Drupal** (done as a pilot, see the [evidence](./DRUPAL-ENTRA-VALIDATION.md)): create the test users, one app, and its role assignments (smallest change, same protocol): prove claims, role sync and the account link.
2. **Student** (done as a pilot, see the [evidence](./STUDENT-ENTRA-VALIDATION.md)): Entra as the SP's IdP; fix the attribute map and identity helper; run the browser tests.
3. **HR**: Spring OIDC.
4. **Alumni**: PHP OIDC and the hosting constraints.
5. **Zoom**: only if a real tenant exists.
6. Remove CAS/Shibboleth/LDAP from the stack, update the manifest and expected answers, and update the deployment script.

## 7. Using the skill

In Copilot chat, invoke it by name or describe the task:

- `/migrate-app-to-entra-id migrate samples/apps/drupal-samlauth to Entra ID, strategy direct`
- "Replace phpCAS in the Alumni app with Entra OIDC"
- "Set up Entra app roles and claims for the Student portal's Shibboleth SP"

The skill asks before it creates anything in a tenant, never prints secrets, and reports what was verified and what was not.
