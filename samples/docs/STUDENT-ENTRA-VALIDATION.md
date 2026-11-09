# Student Records (ASP.NET Framework 4.8 + native IIS Shibboleth SP) with Entra ID as the IdP: tenant validation

## Verdict

**Validated by manual browser test, page-observed; automated authenticated tests remain MFA-blocked.** On 2026-11-06 the Student pilot (UC-03) was switched on the existing Windows VM from the demo Shibboleth IdP to Entra ID (option 1 of the [recipe](../../.github/skills/migrate-app-to-entra-id/references/recipe-shibboleth-sp-iis.md): keep the SP, replace only the IdP). The assistant read the rendered pages in the integrated browser while the operator completed password and MFA, so the values below are page-observed. Carol's first sign-in needed no prompt because the browser already held her Entra session; that is a genuine SAML round trip (the SP showed `uid`, UPN and role from the assertion) but it was not a fresh password sign-in.

The recipe was not executable as written; corrections are below and in the recipe.

## Environment and approved changes

| Item | Value |
|---|---|
| Test tenant | `9b6ae5da-be43-463a-807f-c2cf9ec887db` |
| App | <https://student.chris.securitylabworks.com/> on `vm-idpdemo-kiv1-win` (IIS site `StudentDemo`, ID 2) |
| Enterprise application | `demo-student-saml-validation` |
| Application (client) ID | `00660fb4-c09d-4cbd-9829-a50d0214edc1` |
| Application object ID / service principal ID | `6f0f90b0-8b7d-4b47-b2bf-20031e07b35f` / `9e0e9cce-6e8a-401e-bb56-6db73740165c` |
| Identifier (SP entity ID) | `https://student.chris.securitylabworks.com/shibboleth` |
| Reply URL / logout URL | `.../Shibboleth.sso/SAML2/POST` / `.../Shibboleth.sso/SLO/Redirect` |
| Assignment | Required |
| Token-signing certificate | Self-signed, preferred key, expires **2028-11-01** (thumbprint `0CBDC574DD5F67C7A9124C648DEBA63D595639B3`) |
| Claims mapping policy | `demo-student-saml-claims` (`954cff96-856a-495d-a119-abf2be02966c`), this app only: adds `uid` (= `mailnickname`) to the basic claim set |
| App roles | `student`, `staff` (IDs in the ignored `samples/.local/entra-student-validation.json`) |
| Assignments | `hr-recipe-member` (uid `carol`) = `student`; `hr-recipe-admin` (uid `alice`) = `staff`, standing in for the registrar `bob`. No user, password or MFA changes |
| Final deployed mode | `AuthMode=entra` |

The Windows VM and the Linux VM were deallocated by the daily auto-shutdown and were started for this work. No secret exists in this pattern; the SP's own key and certificate are unchanged.

## What changed

- `Identity/TrustedSpIdentity.cs`: `AuthMode` (`shibboleth` default, `entra`; any other value is a 500). In Entra mode it still trusts only SP server variables and the issuer, then requires exactly one `upn` in `TenantDomain`, exactly one `uid` matching `^[a-z0-9._-]+$`, and takes roles from `roles`. The record key stays the legacy `uid@DemoScope` (so `student-records.json` is unchanged); the real UPN is shown as `upn` on the profile page.
- `shibboleth/shibboleth2.entra.xml.template` and `shibboleth/attribute-map.entra.xml`: the SSO issuer is `https://sts.windows.net/<tenantId>/`, metadata comes from the app's federation metadata URL, `encryption="false"`, `REMOTE_USER="upn"`, `redirectLimit="exact"`; attribute IDs are `upn`, `uid`, `displayName`, `roles`.
- `scripts/Set-StudentAuth.ps1`: switches the installed site between modes (`-Mode entra|shibboleth`), validates with `shibd -check -config`, restarts `shibd` and the pool.
- `tests/specs/student-entra.spec.ts` and test helper updates.

## Corrections found by running the recipe

1. **The documented `shibd.exe -t -c <file>` is not a valid command.** It prints usage and exits 0, so `Install-IisDemo.ps1` never validated anything (and appears to try to start the service). The working form is `shibd.exe -check -config <file>`: exit 0 for a good file, -2 for a broken one (verified). `Install-IisDemo.ps1` and the new script now use it.
2. **A non-gallery SAML app starts with default app roles**, as in the Drupal pilot; disable them before replacing `appRoles`.
3. **Keep the legacy record key.** Keying records by UPN would tie `student-records.json` to one tenant domain. The `uid` claim (mailNickname) preserves the link, as in the HR, Alumni and Drupal pilots.
4. **`redirectLimit` was unset**, so `shibd` warned that it "will operate as an open redirector". `redirectLimit="exact"` is set for Entra mode and sign-in still completes.
5. **`encryption="true"` must be `false`** for Entra unless Token encryption is configured with the SP certificate.
6. **Entra metadata has no `shibmd:Scope`**, so the attribute IDs must not be `eppn` or `affiliation` (the stock policy deletes them). `upn` and `roles` pass.
7. **A backup trap in the script.** The first version suppressed its legacy backup whenever the backup folder already existed (my staging step had created it). The check is now per file; this run seeded the baseline from `C:\idpdemo\generated` and the rollback was proven afterwards.
8. **Global logout now ends the Entra session.** The SP's `SAML2 Local` logout sends a LogoutRequest to Entra, which returns to `/Shibboleth.sso/SLO/Redirect` ("Logout completed successfully."). Revisiting a protected page then shows Entra's account picker instead of silently signing in. This resolves the legacy limitation recorded in the app README, where local SP logout left the demo IdP session alive.

## Measured results

| Check | Result |
|---|---|
| `tsc --noEmit` (tests, on the Linux VM) | Passed |
| MSBuild Release build (local, VS2022) | Succeeded; DLL SHA-256 `8163C33B...A04E1` matches the deployed file |
| `/healthz`, `/readyz` in Entra mode | 200, 200 |
| `shibd` log | Entra metadata loaded from the federation URL; four attribute mappings created |
| Playwright, Entra mode (`student-entra.spec.ts`) | **2 passed** (readiness, anonymous challenge, `/Shibboleth.sso/Status` 403; header-spoof), **2 skipped** by design (MFA); legacy `student.spec.ts` skipped (not applicable) |
| Header-spoof requests (`upn`, `uid`, `roles`, `Shib-*`, `HTTP_*`) to `/Student/Profile`, `/Registrar`, `/Records` | 302 to Entra each time; no record data in the response |
| Rollback run (`AuthMode` back to Shibboleth, legacy spec) | **2 passed, 1 failed**: the failure is the final logout assertion that was already documented as failing before this work |

### Manual acceptance (page-observed, 2026-11-06 about 16:15 to 16:30 UTC)

| Account | Observed |
|---|---|
| `hr-recipe-member` (carol) | Profile: record key `carol@demo.test`, UPN `hr-recipe-member@...`, display name `HR Recipe carol`, affiliation `student`, student number `S10003`. `/Student/Records` showed only `S10003`. `/Student/Registrar` returned **403** |
| carol, sign out | `/Shibboleth.sso/Logout` ended on "Logout completed successfully."; the next `/Student/Profile` went to Entra's account picker (no silent sign-in) |
| `hr-recipe-admin` (alice) | Profile: `alice@demo.test`, affiliation `staff`, no student number. `/Student/Records` showed `S10003` and `S10004`; `/Student/Registrar` loaded |

## Not proven

1. Alice's sign-out, and any replay of a pre-logout SP cookie.
2. An unassigned user (for example the operator) being blocked by Entra's assignment-required check.
3. Any automated authenticated test; MFA blocks it.
4. SAML request-signature validation and assertion encryption by Entra (neither is configured).
5. Metadata trust beyond TLS: the federation metadata is fetched over HTTPS without a signature filter. Certificate rollover is handled by the 7200-second refresh, not exercised.
6. A reinstall: `Install-IisDemo.ps1` lays down the legacy configuration, so rerun `Set-StudentAuth.ps1 -Mode entra` afterwards.

## Rollback and cleanup

On the Windows VM, as administrator (the baseline is in `C:\idpdemo\backup-legacy-auth`):

```powershell
& C:\idpdemo\app\scripts\Set-StudentAuth.ps1 -Mode shibboleth -HostName student.chris.securitylabworks.com
```

The rebuilt DLL stays in place: with no `AuthMode` setting it behaves as before. Original DLL and view are in `C:\idpdemo\backup-legacy-auth\code`. Test logs are `student-entra-final.log` and `student-shibboleth-rollback.log` in `.local/entra-evidence` on the Linux VM.

Nothing in the tenant was cleaned up. After approval, delete only `demo-student-saml-validation` and the claims policy `demo-student-saml-claims`; keep the dedicated users while other pilots use them. Both VMs auto-shut down at 00:00 Central; they were left running after this work.
