# Princeton synthetic identity migration sample suite

Five canonical migration use cases: **UC-01 HR Self-Service**, **UC-02 Zoom-like SaaS**, **UC-03 Student Records Portal**, **UC-04 Drupal Research Publishing**, and **UC-05 Alumni Directory**. These identifiers and application names are not interchangeable. Fifteen additional synthetic integration exports, separately identified S01–S15, make **twenty total inventory applications**. The approved two-VM Azure deployment is documented in [infra/README.md](../infra/README.md) and referenced by the shared manifest.

## Azure deployment

The [deployment script](../infra/Deploy-Demo.ps1) is driven by one JSON file (tenant, subscription, region, resource group, domain, access sources; see [infra/README.md](../infra/README.md)). One command runs preflight checks, provisions the resource group, builds the Linux stack remotely, handles DNS and public TLS, configures the native Windows SP and runs the acceptance tests; rerunning resumes after a failure or DNS pause. It uses Azure CLI authentication and protected, reusable deployment state; do not copy workstation `.local` into cloud artifacts. Public HTTPS (TCP443) is open only to the sources listed in the configuration; SSH/RDP, LDAP and database ports remain closed. The ACME DNS-01 workflow uses acme.sh 3.1.3 (GPL-3.0); no unattended certificate renewal is configured. Two VMs and supporting resources incur recurring charges. No HA or automated backups are configured. Provisioning alone is not functional acceptance.

## Status and prerequisites

**Partially deployed; full acceptance incomplete.** Public DNS/TLS, Azure Linux images, Compose health, native Windows SP configuration validation and IIS readiness passed. All six HTTPS `/readyz` endpoints returned 200. The last full browser run recorded **7 passed, 4 failed, 0 skipped** before the Student scope repair. After that repair, a targeted Student run records **2 passed, 1 failed, 0 skipped**: profile/record/role assertions and spoof resistance pass; logout does not end IdP SSO. These are separate runs, not a new combined full-suite result. HR and Alumni tests (including CAS logout propagation) pass. Drupal's two acceptance failures remain paused and were not retested. Seven fixture tests, remote Java/unit/type-check tests and the Windows Framework 4.8 Release build passed. Test dependencies are locked; an earlier npm audit reported zero known vulnerabilities, not an audit of all packages/images. Both VMs remain running. No complete end-to-end acceptance is claimed.

Requirements after approval:
* Linux Docker engine + Compose v2+ (or Docker Desktop Linux mode), approximately 12GiB available memory and 15GiB image/cache space for CAS/IdP/Drupal builds.
* Node24+ for configuration generation and Playwright. Windows initialization uses PowerShell7.2+/.NET certificate APIs; Linux initialization needs OpenSSL3 plus Node24. No host Java/Composer/PHP needed for image builds.
* A separate Windows host for Framework4.8, IIS and verified native Shibboleth SP3 x64 installer. See `apps/dotnet-shibsp/README.md`.
* Build-time network access for official base images, Maven/Gradle, apt, Composer and browser packages. **Runtime is designed to require no Internet metadata lookup, package install or CDN download; this still needs runtime verification.** The test npm lockfile is generated. Drupal's Composer lockfile and image digests remain unresolved until Linux image builds can run.
* Before initialization, exclude **`samples/.local/`**, `samples/tests/node_modules/`, `samples/tests/results/`, Java target/build outputs and .NET bin/obj from source control. The source generator was explicitly not allowed to modify the root `.gitignore`. Keep the committed `apps/php-cpanel/vendor/` source and licenses tracked. Operational passwords/private keys are generated locally, not committed. Restrict `.local` to the operator and required services, and transfer it securely.

## Start (only after build-validation consent)

From `samples`, Windows one-command Linux stack start:
```powershell
pwsh -File .\scripts\Start-Demo.ps1
```
On a Linux host:
```sh
sh scripts/start.sh
```
These scripts **build images**; do not execute before approval. They do not install/start Docker, provision cloud resources, configure public ingress or install IIS. Linux `initialize.mjs` and Windows `Initialize-Demo.ps1` generate actual local CA/leaf keys, LDAP password hashes, per-user random credentials, service configs and metadata under `.local` first. `.local/demo.env` is the Compose environment. Do not reinitialize against existing persistent volumes: credentials and DB/IdP state must be preserved together.

For custom public HTTPS origins, copy `.env.sample` to a protected operator file and set all six `*_ORIGIN` values before first initialization. Windows: `Initialize-Demo.ps1 -EnvironmentFile C:\protected\demo-origins.env`; Linux: `node scripts/initialize.mjs /protected/demo-origins.env`. Origins must be HTTPS port443, no base paths; generated certificates, CAS regexes, SAML entity IDs/ACS and DNS aliases derive from them. Set DNS/hosts for all Linux origins to the Linux host and student origin to Windows. The same hostnames must resolve from browsers and server backends. Restarting with a different environment alone does not rewrite existing registrations.

Default hostnames on the workstation:
```
127.0.0.1 cas.demo.test idp.demo.test hr.demo.test drupal.demo.test alumni.demo.test
```
`student.demo.test` points to the separate Windows IIS host. **Trust `.local/tls/ca.crt` in browsers/OS**. On Windows as the operator:
```powershell
Import-Certificate -FilePath .\.local\tls\ca.crt -CertStoreLocation Cert:\CurrentUser\Root
```
Use a trusted external server certificate instead of demo TLS for approved public HTTPS. The locally generated SAML signing/encryption certs stay separate from transport TLS. Java/phpCAS verify their HTTPS backend connection with the generated CA; do not disable certificate checks. If replacing gateway.crt/key, ensure server trust matches the issuing CA.

Only gateway TCP443 is published, bound to **loopback by default**. LDAP389, MariaDB3306, Java8080, Jetty8080, Apache80 and FPM9000 are private-only. CAS and gateway use fixed172.30.87.10/.2 on private172.30.87.0/24 for SLO source restriction; if that subnet conflicts, change all three together in Compose/nginx. The gateway is the only service with an edge network. No SSH/RDP is exposed or configured.

## Pages, users and health

| Use case | Sample | Default origin / routes | Login source | Test cohort |
|---|---|---|---|---|
| UC-01 | HR Self-Service | `https://hr.demo.test` `/profile` `/admin` | CAS3 `/cas/login` | alice, bob; carol denied admin |
| UC-02 | Zoom-like SaaS | `config/shibboleth/zoom` | configuration only | notApplicable |
| UC-03 | Student Records Portal | `https://student.demo.test` `/Student/Profile` `/Student/Records` `/Student/Registrar` | Windows Shibboleth SP → same IdP | carol student, bob registrar |
| UC-04 | Drupal Research Publishing | `https://drupal.demo.test` `/demo/profile` `/demo/editor` | Shibboleth `/idp/profile/SAML2/Redirect/SSO` | alice editor, carol noneditor |
| UC-05 | Alumni Directory | `https://alumni.demo.test` `/profile` `/directory` | real vendored phpCAS/CAS3 | erin/alice alum; carol denied directory |

All runnable applications expose anonymous direct `/healthz` returning200 JSON `{"status":"ok"}` and dependency-aware `/readyz` returning200 or503. Compose readiness uses LDAP search, MariaDB's image health script, CAS dependency readiness, IdP's own status and each application as appropriate. FPM uses a direct socket health probe; Apache proves an actual PHP HTTP response. `/readyz` on alumni additionally checks CAS and its SQL table. IdP built-in status is private; never publish diagnostic attributes.

Seven shared LDAP users (all synthetic): alice faculty/alum; bob staff; carol student; dave student/employee; erin alum; frank staff/admissions; grace affiliate. `idp/ldap/users.json` has full attributes/groups. **Passwords are random per initialization** in `.local/test-users.json`, never a shared hardcoded password. `employeeNumber`10001–10007. Read the protected file locally; do not paste it into reports. Operational LDAP/DB binds, Drupal recovery admin and IdP sealer keys are generated too.

The Drupal bootstrap is a real installer/Drush sequence and seeds users/articles. Composer happens only at image build time. Its config-sync is an intentional valid **partial import**, not fake complete exported site configuration. phpCAS and PSR logging sources/licenses are already committed under vendor with archive hashes in PROVENANCE.json; no runtime/root Composer invocation. Alumni data uses actual shared MariaDB schema seeds. Student App_Data has persistent synthetic records.

## Manifest and ingest contract

Start with **`manifest.yaml` only**. Every sample names its operational/config path, ingest evidence, directly related dependencies, startup, IdP URLs, test users, Playwright spec or explicit notApplicable, and structured expected answer. `pathBase` is `samples`. Shared paths explicitly name bootstrap, Compose, LDAP, IdPs, gateway, database, config, tests, licenses and the complete generated source inventory `source-files.json`. The fixture corpus is under `config/ingest`, **never operationally mounted**. XML Export wrappers intentionally aggregate one application's evidence. `expected/*.json` records protocol, identifier, attributes, account link, authorization, a curated assigned-user cohort, complexity and one of the requested Entra target patterns with reasons.

Exactly one intentionally malformed fixture: `config/ingest/broken.json`. Advanced cases include ScriptedAttribute, per-RP release, signed+encrypted assertions, SLO, regex CAS services, MFA, gallery candidates, a retired app and an active pilot with zero matching users. Fake LDAP password/private-key text/client secret exist **only in ingest fixtures** to exercise stripping. No actual operational key is seeded in source. No migration engine or inventory importer is invented here; expected answers are ground truth for a separately supplied consumer.

## Entra ID as the authentication provider

[`docs/ENTRA-ID-MIGRATION.md`](docs/ENTRA-ID-MIGRATION.md) lists what each demo needs to authenticate against Microsoft Entra ID instead of CAS or the Shibboleth IdP. It is design and documentation only, not run against a tenant. The reusable procedure is the workspace skill `.github/skills/migrate-app-to-entra-id`.

## Validation commands (proposed, not run)

After separate consent and Docker readiness, from `samples`:
```powershell
pwsh -File .\scripts\Initialize-Demo.ps1
docker compose --env-file .local\demo.env config --quiet
docker compose --env-file .local\demo.env build
docker compose --env-file .local\demo.env up -d
docker compose --env-file .local\demo.env ps
docker compose --env-file .local\demo.env logs drupal-bootstrap
docker compose --env-file .local\demo.env run --rm --no-deps --entrypoint sh hr -c 'java -version'
docker run --rm -v "${PWD}\apps\java-cas:/work" -w /work maven:3.9.9-eclipse-temurin-21 mvn -B test
```
The final command executes real Java unit tests with the build tool image; it is not part of Docker package's `-DskipTests`. Windows Framework build, in its app directory:
```powershell
& 'C:\Program Files\Microsoft Visual Studio\2022\Enterprise\MSBuild\Current\Bin\MSBuild.exe' .\StudentRecords.csproj /restore /p:Configuration=Release
```
Playwright in `samples\tests`:
```powershell
npm install
npm run typecheck
npm test
npx playwright install chromium
$env:NODE_EXTRA_CA_CERTS=(Resolve-Path ..\.local\tls\ca.crt)
npm run test:e2e
# Only once real Windows IIS/SP is configured:
$env:RUN_DOTNET_TESTS='1'
npm run test:e2e -- student.spec.ts
```
Per-run JSON under `tests/results/<timestamp>/results.json`; no report is pre-generated. Gated Windows tests report skipped with reasons, **not passed**. See `tests/README.md` for local-only networking/TLS policy.

## Logout, maintenance and deployment boundaries

App logout, IdP session logout and global SLO are different. Java/phpCAS first end their app session and then request CAS logout; registered CAS back-channel SLO should invalidate the other participating CAS session. Drupal/Windows use SAML logout through actual libraries/SP, with Shibboleth session tracking. SAML SLO is best effort; CAS and SAML SSO are independent. There is no misleading "logout" link that just deletes an arbitrary browser cookie and claims global termination.

Persistent volumes retain users/config/database/session state across restarts. Stop with `docker compose --env-file .local/demo.env down`; do not use `down -v` unless intentionally destroying all demo data. Restart/credential rotation requires deliberate DB/LDAP/IdP/client coordination. Preserve protected `.local` with encrypted backups if keeping volumes.

All package/image pins are demo compatibility baselines, **not a security certification or current-patch claim**. See `licenses.json` and authentic vendored LICENSE/NOTICE. Obtain consent to resolve dependencies, commit lockfiles, audit CVEs and update unsupported patch levels before public/always-on use. Shibboleth image is built from its actual distribution; no fictional official image/digest is supplied. Image-layer SBOM and exact installed Windows SP patch remain unverified.

The Azure deployment uses a Linux VM for Compose plus a separate Windows VM for IIS/SP; its IaC and the config-driven deployment script are under [infra](../infra/README.md). Public HTTPS is limited to the CIDRs in `network.allowedHttpsSources` of the environment configuration (set deliberately; `0.0.0.0/0` means anyone). LDAP/DB stay private and SSH/RDP are not publicly exposed. No cloud resources are created without the interactive approval step or an explicit `-AutoApprove`.
