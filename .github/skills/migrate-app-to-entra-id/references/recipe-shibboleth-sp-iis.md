# Recipe: ASP.NET Framework behind the native Shibboleth SP, with Entra ID as the IdP

Demo: `samples/apps/dotnet-shibsp` (Student Records, UC-03). The recorded expected pattern is *App Proxy or Private Access* (the app depends on trusted SP server variables). For "Entra as the authentication provider" the lowest-risk route keeps the Shibboleth SP and replaces **only the IdP**.

## Validation status

Run against a real tenant on 2026-11-06: **validated by manual, page-observed browser test**. Student (`student` role) saw only its own record and a 403 on the registrar page; staff saw all records and the registrar page; global logout ended the Entra session; header spoofing was rejected; rollback to the demo IdP was exercised. Automated authenticated tests (MFA), an unassigned-user rejection and metadata signature checks were **not** observed. See the [evidence report](../../../../samples/docs/STUDENT-ENTRA-VALIDATION.md). The steps below include the corrections it found.

The sample implements option 1 as `AuthMode=shibboleth|entra` (default `shibboleth`, the rollback path) plus `scripts/Set-StudentAuth.ps1`, which switches an installed site without rebuilding.

## Options

| Option | App change | Result |
|---|---|---|
| **1. Keep the SP, point it at Entra (recommended)** | Identity helper + attribute map + config values | App code stays on trusted server variables; federation is Entra |
| 2. Replace the SP with OWIN OpenID Connect | Remove the native module, add `Microsoft.Owin.Security.OpenIdConnect` + cookie auth, rewrite `TrustedSpIdentity` | App speaks OIDC directly; no Shibboleth runtime |
| 3. Application Proxy | None in the app | Only for apps that stay private/on-prem; pre-authentication, header-based or Kerberos SSO |

Option 1 is described below. Option 2 is a rewrite of the trust boundary; do it only deliberately.

## What exists today (relevant files)

- `shibboleth/shibboleth2.xml.template`: `<SSO entityID="@@IDP_ORIGIN@@/idp/shibboleth">`, `<MetadataProvider type="XML" path="idp-metadata.xml"/>`, `useVariables="true" useHeaders="false"`, `signing="true" encryption="true"`, RequestMap protecting `/Student`.
- `shibboleth/attribute-map.xml`: `eduPersonPrincipalName` to `eppn` (`ScopedAttributeDecoder`), `eduPersonAffiliation` to `unscoped-affiliation`, `displayName`.
- `Identity/TrustedSpIdentity.cs`: trusts only server variables; requires `Shib-Session-ID`, `Shib-Identity-Provider` equal to `IdpEntityId`, `eppn` ending with `@DemoScope`; roles from `unscoped-affiliation`.
- `Web.Demo.config.template`: `IdpEntityId`, `DemoScope`, `SpStatusUrl`.
- `scripts/Install-IisDemo.ps1`: copies config, sets key ACLs, restarts `shibd` and the pool; includes a metadata Scope migration specific to the demo IdP (not needed for Entra, which has no scope).

## Steps

### 1. Entra side

Create a **SAML enterprise application** ([entra-setup 3b](./entra-setup.md)) with:

| Setting | Value |
|---|---|
| Identifier (Entity ID) | `https://student.<domain>/shibboleth` (the SP `entityID`) |
| Reply URL (ACS) | `https://student.<domain>/Shibboleth.sso/SAML2/POST` |
| Logout URL | `https://student.<domain>/Shibboleth.sso/SLO/Redirect` |
| NameID | `persistent` (or `transient` if you keep the current format) |
| Claims | `upn` (default name claim), `displayName` (default), `uid` (= `user.mailnickname`, custom), **roles** (default role claim, from app roles `student`, `staff`) |
| Assignment required | yes; assign `carol` = student, `bob` = staff (and any other test users) |

Alternative: upload the SP metadata (`/Shibboleth.sso/Metadata`) in the SAML blade.

Graph traps (same as the [Drupal recipe](./recipe-drupal-samlauth.md)): a new non-gallery app already has default app roles that must be disabled before `appRoles` is replaced; the new signing certificate is only used after PATCHing `preferredTokenSigningKeyThumbprint`; the `uid` claim needs a claims mapping policy assigned to the service principal.

### 2. Shibboleth SP configuration (`shibboleth2.xml`)

```xml
<SSO entityID="https://sts.windows.net/<tenantId>/">SAML2</SSO>
<Logout>SAML2 Local</Logout>
<MetadataProvider type="XML" validate="false"
    url="https://login.microsoftonline.com/<tenantId>/federationmetadata/2007-06/federationmetadata.xml?appid=<appId>"
    backingFilePath="entra-metadata.xml" maxRefreshDelay="7200"/>
```

- Keep `signing="true"`; set `encryption="false"` unless the Entra app's Token encryption uses the SP certificate (the pilot did not configure it). Entra always signs assertions with the per-app certificate; the pilot's signed AuthnRequests were accepted. Mismatches show up as failed validation in `shibd.log`.
- Set `redirectLimit="exact"` on `<Sessions>`; without it `shibd` warns that it operates as an open redirector. Sign-in still completed with `exact`.
- Use `REMOTE_USER="upn"` (there is no `eppn`).
- The federation metadata signing certificate rolls over; refreshing the metadata URL handles it. A static file will break at rollover. The metadata is trusted through TLS only (no signature filter in the pilot).
- `/Shibboleth.sso/Metadata` and `Status` handlers are unchanged; `Status` must stay loopback-only (the pilot returned 403 from outside).

### 3. Attribute map (`attribute-map.xml`)

Match Entra's claim names (confirm `nameFormat` in a captured assertion; Entra's URI-style claims typically carry no `NameFormat`, so omit it or use `unspecified`).

```xml
<Attribute name="http://schemas.xmlsoap.org/ws/2005/05/identity/claims/name" id="upn"/>
<Attribute name="uid" id="uid"/>
<Attribute name="http://schemas.microsoft.com/identity/claims/displayname" id="displayName"/>
<Attribute name="http://schemas.microsoft.com/ws/2008/06/identity/claims/role" id="roles"/>
```

**Do not use the IDs `eppn` or `affiliation`.** The stock `attribute-policy.xml` applies `ScopeMatchesShibMDScope` to those IDs, and Entra's metadata has no `shibmd:Scope`, so the values are removed (`removed value at position 0 of attribute (eppn)`). Using `upn` and `roles` bypasses that rule through the catch-all, while still checking the issuer, signature and audience.

### 4. Identity helper (`TrustedSpIdentity.cs`)

Keep the trust model (server variables only, no headers, fail closed). Change the values:

```csharp
// Web.Demo.config: AuthMode=entra ; IdpEntityId=https://sts.windows.net/<tenantId>/ ; TenantDomain=<verified-domain>
variables["Shib-Identity-Provider"] != AppSettings["IdpEntityId"]          // issuer check unchanged in shape (binds the tenant)
var upn = Split(variables["upn"]);                                           // was eppn
if (upn.Count != 1 || !upn[0].EndsWith("@" + AppSettings["TenantDomain"], OrdinalIgnoreCase)) throw 403;
var uid = Split(variables["uid"]);                                           // mailNickname; single value, ^[a-z0-9._-]+$
Affiliations = Split(variables["roles"]);          // reuse the old values: 'student', 'staff'
// IsStudent / IsRegistrar ("student" / "staff") stay exactly as they are
```

`StudentController` selects records by `identity.Eppn`. The pilot keeps that as the **legacy record key `uid@DemoScope`**, so `student-records.json` does not change and is not tied to one tenant's UPN domain; the real UPN is a separate `Upn` property. Keying by UPN also works if the JSON keys are changed to match.

### 5. Deployment script

`Install-IisDemo.ps1` lays down the **legacy** configuration. Run `scripts/Set-StudentAuth.ps1 -Mode entra -TenantId ... -AppId ... -TenantDomain ... -HostName ...` afterwards (it backs up the legacy files, renders the Entra templates, validates, and restarts `shibd` and the pool); `-Mode shibboleth` restores them. The metadata Scope migration in the install script is irrelevant to Entra.

**Validate with `shibd.exe -check -config <file>`.** The documented `shibd.exe -t -c <file>` is not a valid command: it prints usage and returns 0, so it validates nothing. `-check -config` returns 0 for a loadable file and -2 for a broken one.

### 6. Logout

`/Shibboleth.sso/Logout` does `SAML2 Local`: the SP sends a SAML LogoutRequest to Entra and also ends the local session. In the pilot Entra answered at `/Shibboleth.sso/SLO/Redirect` with "Logout completed successfully", and the next protected request showed Entra's account picker instead of signing in silently. This fixed the legacy gap where SP logout left the IdP session alive. Entra single logout is still **front-channel**: other apps' server sessions end only if the browser reaches their logout URLs.

## Verification

1. `shibd.exe -check -config shibboleth2.xml` returns 0; `shibd.log` shows the Entra metadata loaded and one mapping created per attribute. `/Shibboleth.sso/Status` is reachable from loopback only.
2. `/Shibboleth.sso/Session` (attribute values off in production) or controlled logging shows `upn` and `roles` after login. If an attribute is missing, check `shibd.log` for `removed value` / `missing scope` lines.
3. Browser: student sees own records and is denied the registrar page; registrar sees all; HTTP header spoofing still cannot create identity.

## Pitfalls

- Missing role: user not assigned an app role, or the `roles` claim was not added to the SAML claims.
- Wrong `NameFormat` in `attribute-map.xml`: attributes arrive but are not mapped.
- Encrypted assertions require uploading the SP's public certificate to Entra token encryption; the SP private key must be readable by `shibd` only.
- Clock skew: Entra assertions are time-bound; the Windows VM must be time-synced.
