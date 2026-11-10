# Identity migration demo: one-command Azure deployment

Deploys the whole demo into **any Azure tenant and subscription** from one JSON file:

| Component | Where | What |
|---|---|---|
| Apereo CAS 7 + Shibboleth IdP 5 + OpenLDAP (7 synthetic users) + MariaDB | Linux VM (Docker Compose) | Identity providers and shared directory |
| UC-01 HR Self-Service (Spring Boot, CAS) · UC-04 Drupal 10 (samlauth) · UC-05 Alumni Directory (PHP, phpCAS) · UC-06 Campus Events Admin (PHP, Apache `mod_auth_cas`) | Linux VM | Sample apps to migrate |
| UC-03 Student Records (ASP.NET Framework 4.8 behind the native Shibboleth SP) | Windows Server 2022 VM (IIS) | Windows sample |
| Storage, Key Vault (only with `artifactTransfer: storage`), Log Analytics, App Insights, VNet/NSGs, 2 static public IPs | Azure | Supporting resources |

Apps are served at `https://<app>.<your-domain>` (`cas`, `idp`, `hr`, `drupal`, `alumni`, `events`, `student`) behind a Let's Encrypt wildcard certificate.

## Quick start

```powershell
Copy-Item .\infra\environment.sample.json .\infra\environment.json   # then edit it
pwsh -File .\infra\Deploy-Demo.ps1 -Stage Validate                    # optional dry run: checks + ARM what-if, creates nothing
pwsh -File .\infra\Deploy-Demo.ps1                                    # full deployment
```

The full run typically takes an hour or more, mostly Linux image builds and DNS propagation. It asks for approval before creating billable resources (type the resource group name), or pass `-AutoApprove`. If it stops (DNS not ready yet, a transient Azure error, Ctrl+C), **run the same command again**: completed stages are recorded and skipped (`-Force` reruns them).

### Prerequisites

* **Workstation:** Windows, PowerShell 7.2+, Azure CLI, `tar` and `ssh-keygen` (both ship with Windows 10/11), and **MSBuild** (free "Build Tools for Visual Studio 2022" with the *.NET desktop build tools* workload) to compile the Framework 4.8 Student app. Internet access (NuGet, GitHub, Docker Hub, Let's Encrypt, shibboleth.net).
* **Azure:** Contributor on the subscription is enough in the default `direct` mode (no role assignments are created). `artifactTransfer: storage` additionally needs permission to create role assignments (Owner, or Contributor + User Access Administrator); Preflight checks this up front. About 6 vCPUs of quota for the two VM sizes in your region, in a region where your subscription is allowed to use those sizes. The script registers missing resource providers and checks size access and quota first.

### Artifact transfer: `direct` (default) or `storage`

| Mode | How build artifacts and secrets move | When to use |
|---|---|---|
| `direct` | The workstation sends the source and Windows binaries to the Linux VM in 90 KB chunks through the Azure VM command channel (SHA-256 verified). The Windows VM then pulls its package from the Linux VM over the private network on TCP 8443 with verified TLS and a one-time secret path, only while the Windows stage runs; the staged copy is deleted afterwards. No Storage account, no Key Vault, no role assignments. Test-user passwords stay on the Linux VM (`-Stage Credentials` reads them); the Windows admin password stays in the protected `.state` folder | Default. Works in tenants whose policy forces Storage and Key Vault private (for example `MCAPSGovDeployPolicies`), and with Contributor only. Uploads take a few minutes longer |
| `storage` | A Storage account and a Key Vault carry the artifacts and secrets, accessed with Entra RBAC | Tenants that allow public Storage/Key Vault endpoints and where you can create role assignments |
* **DNS:** a domain you control. Either create the records yourself (`dns.mode: manual`) or let the script write them to an Azure DNS zone you can edit (`dns.mode: azureDns`).
* **Let's Encrypt:** you must set `tls.acceptLetsEncryptTerms` to `true`, accepting the [Subscriber Agreement](https://letsencrypt.org/repository/) for the certificate requested on your behalf.

## Configuration (`infra/environment.json`)

`environment.sample.json` is the template and `environment.schema.json` gives editor IntelliSense. `environment.json` and `.state/` are git-ignored and never uploaded.

| Setting | Required | Meaning |
|---|---|---|
| `tenantId`, `subscriptionId` | yes | Target tenant and subscription. The script signs in with `az login --tenant` if needed and refuses a mismatch. It never changes your default `az` subscription. |
| `location` | yes | Azure region, e.g. `eastus`. Must offer both VM sizes. |
| `resourceGroupName` | yes | Created if missing. An existing group must be in the same region. |
| `domain` | yes | A registered domain or subdomain **you control**, e.g. `demo.contoso.com`. A wildcard certificate is issued for `*.<domain>`. Microsoft-owned names such as `*.onmicrosoft.com` are rejected: you cannot create DNS records or get a public certificate for them. |
| `tls.acceptLetsEncryptTerms` | yes | Must be `true`. `tls.contactEmail` is optional (expiry notices). |
| `network.allowedHttpsSources` | yes | IPv4 addresses/CIDRs allowed to browse the demo, e.g. `["203.0.113.7/32"]`. `["0.0.0.0/0"]` means anyone. |
| `artifactTransfer` | no (`direct`) | `direct` or `storage`; see above. Cannot change after deployment. |
| `network.dataServiceDefaultAction` | no (`Allow`) | `storage` mode only. Network default for Storage and Key Vault. Entra RBAC and TLS are required either way. `Deny` needs `dataServiceAllowedCidrs` listing your public IP(s), including the machine running the script. |
| `network.vnetPrefix` | no (`10.87`) | First two octets of the private /16. |
| `namePrefix`, `uniqueSuffix` | no | Every resource name derives from `<namePrefix>-<suffix>` (storage and Key Vault names are global). The suffix is generated once and remembered. |
| `dns.mode` | no (`manual`) | `manual` prints the records and waits; `azureDns` creates them in `dns.azureDnsZone` (`zoneName`, `resourceGroup`, optional `subscriptionId`). Existing records are never overwritten. `dns.waitMinutes` limits each wait. |
| `compute.*` | no | `linuxVmSize` (D4s_v5), `windowsVmSize` (D2s_v5), `linuxDataDiskGb` (256), image versions (`latest`), `adminUsername`. |
| `options.runBrowserTests` / `failOnTestFailure` | no (`true` / `false`) | Run the Playwright suite; by default failures are reported as warnings after a successful deployment. |
| `tags`, `deployedBy`, `operatorObjectId`, `operatorPrincipalType` | no | Extra tags; tag value; Entra object ID to receive data roles (defaults to the signed-in user) and its type (`User` default, or `ServicePrincipal` / `Group`, which require `operatorObjectId`). |

## What the stages do

`-Stage All` (default) runs these in order and records each one under `infra\.state\<subscription>-<resource group>\`:

| Stage | Action |
|---|---|
| Preflight (always) | Tools, tenant/subscription sign-in, provider registration, VM size availability and quota, resource group, global name availability, Azure DNS zone access |
| Provision | ARM what-if, then subscription-scope Bicep (`main.bicep`): group, VNet/NSGs, 2 VMs with managed identities, disks, IPs, telemetry (plus Storage, Key Vault and RBAC in `storage` mode) |
| Dns | Creates the six A records (Azure DNS) or prints them so you can create them while the build runs |
| Build | Compiles the Student app locally, uploads source and binaries, builds all Linux images and runs unit/fixture checks on the Linux VM |
| CertificateRequest | Starts the Let's Encrypt DNS-01 order and publishes (or prints) the `_acme-challenge` TXT record |
| DnsWait | Waits until the A and TXT records resolve publicly |
| CertificateComplete | Issues the certificate, starts every service, hands the Windows package to the Windows VM |
| Windows | Installs IIS and the native Shibboleth SP (restarting the VM automatically if the installer requires it), then deploys the Student app |
| Verify | Checks all six `/readyz` endpoints, then runs the browser tests |

Single stages: `-Stage Validate | Preflight | Provision | Dns | Build | CertificateRequest | DnsWait | CertificateComplete | Windows | Verify`.
Operations: `-Stage Status` (VM power state and public readiness), `Credentials` (prints the test-user passwords, and the Windows admin password in `direct` mode), `Stop` / `Start` (deallocate / start both VMs), `Destroy` (typed confirmation; deletes the group and purges a soft-deleted Key Vault if there was one).

## Using the demo

Sign in with the **short user name** (`alice`, not `alice@demo.test`). Passwords are random per deployment: `-Stage Credentials` (or, in `storage` mode, Key Vault secret `synthetic-test-users`).

| App | Try | Expected |
|---|---|---|
| HR Self-Service | `alice` or `bob` | Profile with employee number and groups; admin page works |
| HR Self-Service | `carol` | Admin page denied |
| Alumni Directory | `erin` or `alice` | Profile and alumni directory |
| Campus Events (`/admin/`) | `alice` / `bob` / `carol` | Admin / organizer (own events only) / signs in but is not staff (403) |
| Student Records | `carol` / `bob` | Own records / registrar access |
| Drupal | `alice` / `carol` | Editor / non-editor |

CAS lives at `/cas`; open `https://cas.<domain>/cas/login`. The bare hosts redirect there (`cas.<domain>/` → `/cas/login`, `idp.<domain>/` → `/idp/`). The Shibboleth IdP has no sign-in page of its own: its landing page says "No services are available at this location" (normal), and login always starts from an application (for example Drupal at `/saml/login` or the Student portal). The IdP's SAML metadata is at `https://idp.<domain>/idp/shibboleth`. Use separate InPrivate windows when switching users.

## Security and operating notes

* **Public exposure:** only TCP 443 is open on the NSGs, to `network.allowedHttpsSources` (plus private VM-to-VM HTTPS). There is no public SSH, RDP, LDAP or database port; management uses Azure VM Run Command.
* **Storage and Key Vault** keep Entra RBAC, TLS 1.2, no shared keys and no anonymous blobs. With `Allow` their network default is open to any source IP; use `Deny` plus `dataServiceAllowedCidrs` to restrict it.
* **Secrets:** the Windows admin password, SSH key and deployment parameters live only in the ACL-protected `.state` folder (in `storage` mode the passwords are also in Key Vault). In `direct` mode the test-user passwords exist only on the Linux VM. The source archive excludes `.state`, `.local` and `environment*.json` and is checked before upload. The Windows handoff package, which holds the SP private key, is served for minutes at most and then deleted.
* **Certificates** are not renewed automatically (90-day Let's Encrypt lifetime), and renewal is not automated or tested here. Plan a manual re-issue (a new TXT challenge) before expiry.
* **Not included:** high availability, automated backups, guest-level telemetry agents. Deleting the group or disks destroys the demo state.
* **Cost:** two always-on VMs, disks, public IPs and telemetry bill continuously (plus Storage/Key Vault in `storage` mode). `Stop` deallocates the VMs only; disks and IPs still incur charges. `Destroy` removes everything.
* **Synthetic data only.** Do not load real identities or data.

## Verification status (be aware)

**Verified end to end in a real tenant that forces Storage/Key Vault private (direct mode):** provisioning on an existing resource group, chunked artifact upload with SHA-256 checks, the Linux image build and unit/fixture checks, DNS wait, Let's Encrypt wildcard issuance, all services healthy, the private Windows handoff and its cleanup, automatic restart during the Shibboleth SP install, IIS configuration, all six public `/readyz` endpoints over valid TLS, and the browser suite (8 passed, 3 failed: the known issues below). Also: Bicep compilation, seven infrastructure tests (`test-infra.mjs`), and offline package tests (`test-deployment.ps1`: configuration validation, guest-script variable contracts and `bash -n`, archive hygiene, the upload round trip executed in bash, resume and permission logic).

**Not verified:** `artifactTransfer: storage` in a tenant that allows it (it was verified only in the previous subscription-specific version), and the `azureDns` automatic record path.

**Known application issues** (Verify reports the live result): two Drupal browser checks fail after a successful SAML login, and Student single logout ends the local session but not the IdP session. HR and Alumni pass, including CAS logout propagation. These do not block deployment by default.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Insufficient ... quota` | Request a quota increase, or pick another region/size, then rerun |
| `VM size ... is blocked for your subscription in <region>` | An access restriction on the subscription (common for sponsored/managed subscriptions), not a quota issue. Set another `location` or size; list open regions with the Azure SKU API (`az rest` on `.../providers/Microsoft.Compute/skus?$filter=location eq '<region>'`, look for a `Location` restriction), or ask the subscription owner to lift it |
| `Public network access is DISABLED on: Key Vault ..., Storage account ...` (`storage` mode) | A tenant Azure Policy with a Modify effect forces public access off, and re-enabling it by hand is reverted instantly. Switch to the default `artifactTransfer: direct` (needs no Storage or Key Vault), or ask the policy owner for an exemption |
| `You lack permission 'Microsoft.Authorization/roleAssignments/write'` (`storage` mode) | Use `direct` mode, or ask an owner for User Access Administrator |
| Storage/Key Vault name taken or soft-deleted (`storage` mode) | Change `namePrefix`/`uniqueSuffix` (before first deploy) or purge the deleted vault |
| MSBuild not found | Install Build Tools for Visual Studio 2022 (.NET desktop build tools) |
| DNS wait times out | Create the printed records, then rerun the same command |
| `Cannot resolve your Entra object ID` / `TokenCreatedWithOutdatedPolicies` | Only matters in `storage` mode: run `az login` again, or set `operatorObjectId`. Ignored in `direct` mode |
| Browser shows `ERR_CONNECTION_RESET` | Your IP is not in `network.allowedHttpsSources`; update the config and rerun `-Stage Provision` |
| Windows stage ends with a restart request | Handled automatically: the VM is restarted and the stage repeats |
| A guest stage fails | The error shows the tail of the output; the full restricted response is in `.state\...\<stage>-<vm>-result.json`; rerun after fixing |

## Files

`Deploy-Demo.ps1` (orchestrator) · `main.bicep` / `resources.bicep` (infrastructure) · `scripts/` (Linux and Windows guest bootstrap, receive configuration as a validated preamble) · `environment.sample.json`, `environment.schema.json` · `test-infra.mjs`, `test-deployment.ps1` (tests: `az bicep build --file infra/main.bicep --outfile <json>`, then `COMPILED_TEMPLATE=<json> node --test infra/test-infra.mjs`).
