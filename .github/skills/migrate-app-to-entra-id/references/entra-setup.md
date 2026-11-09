# Entra setup: tenant objects

These are **templates**. They change a real directory: review, run them in a test tenant, and confirm each object with the user first. None of this was executed against a tenant while writing the skill; verify flags against your installed `az` version.

## Prerequisites and permissions

| Need | Typical role |
|---|---|
| Create users, set `employeeId`, `mailNickname` | User Administrator |
| Create app registrations, secrets, app roles | Application Developer (own apps) or Application Administrator |
| Enterprise (SAML) apps, claims, assignments | Cloud Application Administrator or Application Administrator |
| Assign **groups** to apps | Entra ID **P1 or higher** (user assignment works on Free) |
| Claims mapping policy | Application Administrator + policy permissions |

- Microsoft Graph calls need a fresh Graph token. If `az ad ...` fails with `TokenCreatedWithOutdatedPolicies` / `InteractionRequired`, run `az login` again (interactive); Azure Resource Manager access can keep working while Graph needs the challenge.
- Managed or sponsored tenants often restrict user creation, force MFA through Conditional Access or security defaults, and enforce tenant policies. Use a developer tenant for automated login tests.
- Custom domain: users get `@<tenant>.onmicrosoft.com` UPNs unless you verify a domain you control; verifying `demo.example.org` lets users be `alice@demo.example.org`.
- Check `onPremisesSyncEnabled` and the required fields before reusing a user. The HR pilot's Graph update of `mail`/`employeeId` was rejected for synchronized objects; change those at their authoritative source or obtain approval for cloud-only test users. Do not weaken the application's attribute requirements.

## 1. Test users

```powershell
# Per user (repeat for alice..grace). Password: generate randomly, store outside the repo.
az ad user create --display-name "Alice Avery" --user-principal-name "alice@<verified-domain>" `
  --mail-nickname alice --password "<generated>" --force-change-password-next-sign-in false

$id = az ad user show --id "alice@<verified-domain>" --query id -o tsv
az rest --method PATCH --url "https://graph.microsoft.com/v1.0/users/$id" --headers "Content-Type=application/json" `
  --body '{"givenName":"Alice","surname":"Avery","mail":"alice@<verified-domain>","employeeId":"10001"}'
```

Source values for the demo users: `samples/idp/ldap/users.json`. Keep `mailNickname` equal to the old `uid`.

## 2. App roles (one role set per application)

`roles.json` for `az ad app create --app-roles @roles.json` (every `id` must be a unique GUID: `[guid]::NewGuid()`):

```json
[
  {"allowedMemberTypes":["User"],"description":"HR administrators","displayName":"HR admins","id":"<guid>","isEnabled":true,"value":"hr-admins"},
  {"allowedMemberTypes":["User"],"description":"Faculty","displayName":"Faculty","id":"<guid>","isEnabled":true,"value":"faculty"}
]
```

Define only the roles an app uses (demo: HR `hr-admins`; Alumni `alum`; Drupal `faculty`, `staff`; Student `student`, `registrar`). `value` is what arrives in the `roles` claim.

## 3a. OIDC app registration (Spring Boot, PHP)

```powershell
$app = az ad app create --display-name "demo-hr" --sign-in-audience AzureADMyOrg `
  --web-redirect-uris "https://hr.<domain>/login/oauth2/code/entra" `
  --app-roles "@roles.json" | ConvertFrom-Json
az ad sp create --id $app.appId | Out-Null
$sp = az ad sp show --id $app.appId --query id -o tsv
az ad sp update --id $sp --set appRoleAssignmentRequired=true     # only assigned users can sign in
$secret = az ad app credential reset --id $app.appId --append --display-name demo --years 1 --query password -o tsv
# Store $secret in the app's secret store immediately; never echo it.
```

- For authorization-code OIDC, implicit ID/access-token issuance is not needed. The HR pilot keeps both implicit flags off and explicitly adds S256 PKCE in Spring.
- Register the exact post-logout return in `web.redirectUris` as well as the callback. `web.logoutUrl` is the **front-channel logout callback**, not the browser's post-logout return URI; do not confuse them.
- Prefer a **certificate** or federated credential over a client secret for production; secrets expire (maximum 24 months).
- If the tenant blocks user consent, delegated permissions such as Graph `User.Read` need an admin grant ("Need admin approval" at sign-in). Create one `oauth2PermissionGrants` entry (`consentType: AllPrincipals`, scope `User.Read`) for that app only. The Graph CLI token may first need an interactive `az login` (continuous access evaluation).
- Default delegated permission `User.Read` is enough for sign-in; add nothing else.

## 3b. SAML enterprise application (Shibboleth SP, samlauth, SaaS)

Custom (non-gallery) app via Graph. The global template ID for non-gallery apps is `8adf8e6e-67b2-4cf2-a259-e3dc5476c621`:

```powershell
$body = '{"displayName":"demo-student-sp"}'
$inst = az rest --method POST --url "https://graph.microsoft.com/v1.0/applicationTemplates/8adf8e6e-67b2-4cf2-a259-e3dc5476c621/instantiate" `
  --headers "Content-Type=application/json" --body $body | ConvertFrom-Json
$appObjectId = $inst.application.id; $spId = $inst.servicePrincipal.id; $appId = $inst.application.appId

az rest --method PATCH --url "https://graph.microsoft.com/v1.0/servicePrincipals/$spId" --headers "Content-Type=application/json" `
  --body '{"preferredSingleSignOnMode":"saml"}'
az rest --method PATCH --url "https://graph.microsoft.com/v1.0/applications/$appObjectId" --headers "Content-Type=application/json" `
  --body '{"identifierUris":["https://student.<domain>/shibboleth"],"web":{"redirectUris":["https://student.<domain>/Shibboleth.sso/SAML2/POST"],"logoutUrl":"https://student.<domain>/Shibboleth.sso/SLO/Redirect"}}'
az rest --method POST --url "https://graph.microsoft.com/v1.0/servicePrincipals/$spId/addTokenSigningCertificate" `
  --headers "Content-Type=application/json" --body '{"displayName":"CN=demo-student-sp","endDateTime":"2028-11-01T00:00:00Z"}'
```

- Easier alternative for the same result: portal, Enterprise applications, New application, Create your own, then **Single sign-on, SAML, Upload metadata file** with the SP's metadata (`/Shibboleth.sso/Metadata`, `/saml/metadata`).
- Set claims (Attributes and Claims) in the portal, or with a claims policy (see [claims-and-attributes](./claims-and-attributes.md)).
- IdP metadata for the SP: `https://login.microsoftonline.com/<tenantId>/federationmetadata/2007-06/federationmetadata.xml?appid=<appId>` (per-app signing certificate). IdP entity ID `https://sts.windows.net/<tenantId>/`.
- Token encryption (encrypted assertions): upload the SP's public certificate in the application's **Token encryption** setting (**verify** licensing; portal path is simplest).

## 4. Assign users to roles

```powershell
# For each user and each role value they should hold (alice on the Alumni app: alum).
$body = @{ principalId = $userId; resourceId = $spId; appRoleId = $roleGuid } | ConvertTo-Json -Compress
az rest --method POST --url "https://graph.microsoft.com/v1.0/servicePrincipals/$spId/appRoleAssignedTo" `
  --headers "Content-Type=application/json" --body $body
```

A user holding several affiliations needs one assignment per role. With P1 you can assign a **group** to a role instead.

## 5. Capture and verify

- Sign in once per test user in a private window to clear first-use consent and password prompts.
- Capture the tokens/assertions with a throwaway tool and compare claims to the mapping table. Do not store them.
- Record: tenant ID, client/application ID, redirect URIs, role GUID to value table, where secrets live. Not the secrets themselves.

## Cleanup

Delete what you created: `az ad app delete --id <appId>` (also removes the service principal), `az ad user delete --id <upn>`. App roles assigned to deleted users disappear with them.
