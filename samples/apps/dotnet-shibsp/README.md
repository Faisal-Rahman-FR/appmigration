# UC-03 — Student Records Portal — Windows only

ASP.NET **Framework4.8** MVC5.2.9, not .NET Core. Build/run needs Windows, VS2022 MSBuild, Framework4.8 developer pack, IIS ASP.NET4.8/ISAPI features and **x64 Shibboleth SP3 native IIS module**. No macOS/Linux runtime or build success is claimed.

The sole identity helper is `Identity/TrustedSpIdentity.cs`. It reads only native SP `Shib-Session-ID`, `Shib-Identity-Provider`, `eppn`, `unscoped-affiliation`, `displayName` server variables. It never uses request headers, `HTTP_*`, cookies, query strings or a development identity bypass. Native SP/IIS must export variables, not headers. A missing/misconfigured SP fails closed. RequestMapper protects `/Student`, not health or landing pages. `student` affiliation permits own records; `staff` permits registrar and all records. JSON in App_Data contains persistent synthetic records only. No app identity session is retained, so SP logout cannot leave a parallel app login alive.

## Separate Windows setup

1. Enable IIS Web-Server, Web-Asp-Net45, Web-Net-Ext45, Web-ISAPI-Ext, Web-ISAPI-Filter, Web-Mgmt-Console using Windows Features/ServerManager. Install a supported verified Shibboleth SP3 x64 MSI from shibboleth.net, selecting native IIS integration. Installer/module registration is a prerequisite, **not fabricated by this source script**. Configure native IIS module `useVariables=true`, `useHeaders=false` according to the installed SP version; do not enable legacy ISAPI header export.
2. After validation consent, restore/build:
   ```powershell
   & 'C:\Program Files\Microsoft Visual Studio\2022\Enterprise\MSBuild\Current\Bin\MSBuild.exe' .\StudentRecords.csproj /restore /p:Configuration=Release
   ```
3. Copy the protected generated `.local` bundle to Windows; configure DNS/hosts for the Linux IdP origin and Windows student origin. Import the generated demo CA. Install a server TLS certificate into LocalMachine\My for the student hostname, e.g. import a password-protected PFX derived locally from gateway.crt/key, or use a properly issued external certificate. No private-key/PFX material is committed.
4. As admin:
   ```powershell
   .\scripts\Install-IisDemo.ps1 -GeneratedDirectory C:\protected\demo\.local -SiteCertificateThumbprint YOUR_LOCAL_CERT_THUMBPRINT
   ```
   Dedicated site ID2 is intentional and matches the SP config. Script refuses conflicts and requires existing native module. Preserve upstream installed `attribute-policy.xml`, `protocols.xml`, `security-policy.xml` and native module mappings. Protect `student.key` with ACLs readable only by Administrators/SYSTEM and the installed shibd service identity; **do not** give application code access. Configure IdP/Windows network access only within the restricted demo network.
5. In native SP IIS settings confirm server-variable export only. The supplied `InProcess/ISAPI` element explicitly sets `useVariables=true`, `useHeaders=false`; despite its historical name, the official SP3 documentation defines these settings for the native IIS7+ module. Verify with `sbin64\shibd.exe -check -config <shibboleth2.xml>` (exit 0 when loadable). The earlier `-t -c` form printed usage and validated nothing. The Azure bootstrap registers the native module with the MSI's appcmd mechanism if installation omitted it, refreshes the install-time process PATH, and configures the StudentDemo pool to find the verified Shibboleth 3.6 shared x64 runtime. Review handler mappings for `/Shibboleth.sso/*` installed by MSI.
6. `/healthz` returns direct200 anonymous. `/readyz` checks persistent records and the locally accessible SP Status handler. Status ACL allows only loopback: configure local DNS for student hostname to resolve to loopback on IIS, or readiness fails503. Never open the diagnostic Status handler publicly.

## Truthful testing

The Shibboleth-IdP results below predate the Entra pilot; the Entra mode is covered in the next section.
Restore and the Release build passed on Windows using VS2022 MSBuild and Framework4.8 reference assemblies. Azure Windows Server setup, native x64 SP configuration validation and IIS readiness passed. After repairing the IdP metadata scope, the targeted Student suite records **2 passed, 1 failed, 0 skipped**. Student profile attributes, own-record isolation, denied student registrar access, staff registrar access and HTTP-header spoof resistance pass their assertions. The student flow fails only at its final logout assertion: local SP logout does not end IdP SSO, so revisiting a protected page signs the user back in. Full Student logout acceptance remains incomplete. The ePPN mapping uses `ScopedAttributeDecoder`; the unscoped affiliation uses the installed policy's `unscoped-affiliation` rule. Generated metadata declares literal `demo.test` using the Shibboleth metadata Scope extension. Setup migrates older unsigned generated metadata only when the issuer matches configuration and scope is missing; mismatched scopes and signed metadata requiring modification fail explicitly. Signature/encryption validation and native attribute policy remain intact. Set `RUN_DOTNET_TESTS=1` and `STUDENT_ORIGIN` to run Playwright. Without that explicit opt-in, tests report skipped with a reason, never passed. Tests include spoofed HTTP identity headers against a fresh protected request, student/registrar roles and SP logout. Confirm SP variable export via a local controlled inspection, without publishing diagnostic attributes.

`/Shibboleth.sso/Logout` invokes SAML2 then Local logout through the actual SP. Global SLO is best effort across participating SAML SP sessions and does not terminate CAS SSO. There is deliberately no custom "logout" pretending to invalidate IdP sessions.

## Identity provider: demo Shibboleth IdP (default) or Microsoft Entra ID

`AuthMode=shibboleth` (the default when the setting is absent) keeps everything above unchanged. `AuthMode=entra` keeps the native SP and the trusted-server-variable model but points the SP at Entra: `TrustedSpIdentity` then requires the tenant-bound issuer (`IdpEntityId` = `https://sts.windows.net/<tenantId>/`), exactly one `upn` in `TenantDomain`, exactly one `uid` (mailNickname) and roles from the `roles` variable. The student-record key stays `uid@DemoScope`, so `student-records.json` is unchanged. An unknown `AuthMode` fails with HTTP 500.

- **Entra application:** SAML enterprise app with Identifier `<STUDENT_ORIGIN>/shibboleth`, reply URL `<STUDENT_ORIGIN>/Shibboleth.sso/SAML2/POST`, logout URL `<STUDENT_ORIGIN>/Shibboleth.sso/SLO/Redirect`, assignment required, app roles `student` and `staff`, and a `uid` claim from `mailnickname`.
- **Switch (Windows, as administrator, after `Install-IisDemo.ps1`):** `scripts\Set-StudentAuth.ps1 -Mode entra -TenantId <guid> -AppId <guid> -TenantDomain <domain> -HostName <student host>` backs up the legacy files, renders `shibboleth/shibboleth2.entra.xml.template`, installs `attribute-map.entra.xml`, sets the three Web.Demo.config keys, validates with `shibd -check`, and restarts `shibd` and the pool. `-Mode shibboleth` restores the backup. Re-running the install script restores the legacy configuration.
- **Rebuild:** `TrustedSpIdentity.cs` changed, so rebuild `StudentRecords.dll` with MSBuild before first use.
- **Tests:** `tests/specs/student-entra.spec.ts` with `RUN_DOTNET_TESTS=1 STUDENT_AUTH=entra ENTRA_TENANT_ID=<guid>`; the authenticated cases need `ENTRA_AUTOMATED_LOGIN=1` and users without MFA.

See the [validation report](../../docs/STUDENT-ENTRA-VALIDATION.md) for what was and was not proven.
