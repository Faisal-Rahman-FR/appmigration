# Recipe: Drupal samlauth with Entra ID as the SAML IdP

Demo: `samples/apps/drupal-samlauth` (Research Publishing, UC-04). Pattern: **custom SAML**, complexity medium. The protocol is unchanged (SAML 2.0), so this is mostly configuration, plus one code change for role mapping.

## Validation status

Run against a real tenant on 2026-11-05: **validated by manual browser test, page-observed**. Admin (`faculty`) sign-in with `uid=alice`, `editor` and a 200 editor page; SAML logout; base member (`member`) sign-in with `uid=carol`, no `editor` and a 403 editor page; and the Shibboleth rollback were exercised. Automated authenticated tests (MFA), an unassigned-user rejection, assertion encryption and cert rollover were **not**. See the [evidence report](../../../../samples/docs/DRUPAL-ENTRA-VALIDATION.md). The steps below include the corrections it found.

The sample implements this as `DRUPAL_AUTH=shibboleth|entra` (default `shibboleth`, the rollback path). In `entra` mode `settings.php` overrides the IdP values and `RoleSync` reads the Entra role claim.

## What exists today

- `settings.php` overrides the IdP values: `idp_entity_id`, `idp_single_sign_on_service`, `idp_single_log_out_service`, `idp_certs`, and the SP certificate and key from files.
- `config-sync/samlauth.authentication.yml`: `unique_id_attribute: uid`, `user_name_attribute: uid`, `user_mail_attribute: mail`, `map_users: true`, `map_users_name: true`, `create_users: false`, `sync_mail: true`, `sp_name_id_format: transient`, signed requests/logout, `security_assertions_signed: true`, `security_assertions_encrypt: true`, `strict: true`.
- `bootstrap/seed.php`: pre-creates local accounts named after `uid` (no auto-creation).
- `modules/demo_portal/src/EventSubscriber/RoleSync.php`: on `SamlauthEvents::USER_SYNC`, grants the `editor` role when `eduPersonAffiliation` contains `staff` or `faculty`, removes it otherwise.
- `PortalController`: shows attributes and roles from the session; sign-out link goes through samlauth logout.

## Steps

### 1. Entra side

SAML enterprise application ([entra-setup 3b](./entra-setup.md)):

| Setting | Value |
|---|---|
| Identifier | `https://drupal.<domain>/saml/metadata` (`sp_entity_id`) |
| Reply URL (ACS) | `https://drupal.<domain>/saml/acs` |
| Logout URL | `https://drupal.<domain>/saml/sls` |
| NameID | `transient` (matches `sp_name_id_format`) or persistent with the same value in samlauth |
| Claims | `uid` = `user.mailnickname`; `mail` = `user.mail`; **role** attribute from app roles `faculty`, `staff` |
| Assignment required | yes; assign `alice` faculty, `bob` staff; `carol` (student) gets no editor role |

Importing the SP metadata (`/saml/metadata`) into the Entra SAML blade fills the first three rows. `/saml/metadata` needs a permission (anonymous gets 403 in the demo), so fetch it as an administrator or set the values by hand.

Creating the app with Graph (non-gallery template, see [entra-setup 3b](./entra-setup.md)) has three traps found in the pilot:

- The new application already has default app roles (`User`, `msiam_access`). Disable them in one PATCH before a second PATCH replaces `appRoles`, or Graph returns `CannotDeleteOrUpdateEnabledEntitlement`. Include a base `member` role.
- `addTokenSigningCertificate` does not make the new certificate active: also PATCH `preferredTokenSigningKeyThumbprint`.
- Custom claims need a claims mapping policy assigned to the service principal (`POST /servicePrincipals/{id}/claimsMappingPolicies/$ref`). The pilot used `IncludeBasicClaimSet: true` and `ClaimsSchema` entries for `mailnickname` as `uid`, `mail`, `displayname`, and `assignedroles` as `appRoles`. Do **not** name the role claim `roles` in the demo: its profile page already renders Drupal's own roles under that name.

### 2. samlauth settings (`settings.php` overrides)

```php
$config['samlauth.authentication']['idp_entity_id'] = 'https://sts.windows.net/<tenantId>/';
$config['samlauth.authentication']['idp_single_sign_on_service'] = 'https://login.microsoftonline.com/<tenantId>/saml2';
$config['samlauth.authentication']['idp_single_log_out_service'] = 'https://login.microsoftonline.com/<tenantId>/saml2';
$config['samlauth.authentication']['idp_certs'] = [ /* signing cert(s) from the app's federation metadata */ ];
```

- Take the signing certificate from `https://login.microsoftonline.com/<tenantId>/federationmetadata/2007-06/federationmetadata.xml?appid=<appId>`. Certificates **roll over**: list the new certificate in `idp_certs` before the old one expires (samlauth accepts several).
- `unique_id_attribute: uid` is acceptable while `uid` = `mailNickname` never changes. For a stable key use the object ID attribute `http://schemas.microsoft.com/identity/claims/objectidentifier` as `unique_id_attribute` and keep `uid` for `user_name_attribute`; samlauth records the link on first login.
- Keep `create_users: false` and `map_users_name: true` so the pre-seeded local accounts link by username; otherwise every user lands in a new empty account.
- `security_assertions_encrypt: true` requires the Entra application's **Token encryption** to use the Drupal SP certificate (`drupal.crt`); set `false` if you do not configure it (TLS still protects transport; Entra always signs). The pilot overrides it to `false`.
- `security_messages_sign: true` makes samlauth require a signed **response**. Entra's default signing option signs the assertion only, so override it to `false` (keep `security_assertions_signed: true`) or change the signing option in the portal to sign the response and assertion.
- `security_request_authn_context` should be `false` for Entra (see `AADSTS75011` below).
- `security_authn_requests_sign: true`: Entra validates signed AuthnRequests only if you upload the SP certificate as a verification certificate (**verify** licensing); otherwise the signature is ignored. The pilot left it on and Entra accepted the request. `strict: true` stays.
- Update the link text from "Sign in with Shibboleth" (`login_link_title`, `PortalController`).

### 3. Role mapping (`RoleSync.php`)

Read the Entra role attribute instead of `eduPersonAffiliation`:

Use the claim name you configured in Entra. The pilot's `RoleSync` reads `appRoles`, then `roles`, then the default role URI, and only in Entra mode (the legacy path trusts only `eduPersonAffiliation`):

```php
$claims = getenv('DRUPAL_AUTH') === 'entra'
  ? ['appRoles', 'roles', 'http://schemas.microsoft.com/ws/2008/06/identity/claims/role']
  : ['eduPersonAffiliation'];
```

Because the app roles are multi-valued, samlauth hands them over as an array.

The user's mail is overwritten on every login when `sync_mail: true`: the seeded `alice@demo.test` became the Entra mail. The username link (`uid`) is unaffected.

### 4. Logout

samlauth `logout_drupal_idp: true` sends a signed LogoutRequest to the IdP. Entra supports SAML Single Logout and ends its session (page "You signed out of your account", response posted to `/saml/sls`), but it logs out other apps only via **front-channel** redirects. Tests that expect another app to be signed out must change. When testing a second user, Entra's account picker remembers the previous account and signs it in with one click; choose **Use another account**.

## Verification

1. `drush config:get samlauth.authentication` shows the Entra values; `/saml/metadata` imports cleanly in Entra.
2. Browser: `/saml/login` goes to `login.microsoftonline.com`; after sign-in (landing on `/demo/profile?check_logged_in=1`) the profile shows `uid`, `mail`, and Drupal roles containing `editor` for alice and not for carol; `/demo/editor` is 200 for alice and **403 for carol**.
3. Enable samlauth debug logging temporarily if an attribute is missing. Never leave SAML message logging on.

## Pitfalls

- `AADSTS75011` / "authentication method mismatch": the AuthnContext requested by samlauth (`security_request_authn_context`) is not what Entra performed (MFA); relax or remove the request.
- Mail on login (`sync_mail: true`) overwrites the Drupal email with Entra's `mail`: ensure it is populated.
- A user without an assigned app role is blocked at Entra when assignment is required; a user with no role mapping signs in but gets no editor rights.
- Reverse proxy settings (`reverse_proxy`, trusted headers) must make Drupal build the ACS/metadata URLs with HTTPS; a mismatch fails Entra's reply URL check.
