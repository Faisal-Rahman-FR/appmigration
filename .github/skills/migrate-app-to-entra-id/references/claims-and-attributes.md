# Claims and attributes: legacy to Entra

Entra is a cloud directory with its own schema. Every attribute an app reads from CAS or Shibboleth needs an explicit source and an explicit delivery path.

## Mapping for the demo identity model

| Legacy attribute (LDAP / CAS / SAML) | Entra source | OIDC delivery | SAML delivery | Notes |
|---|---|---|---|---|
| `uid` | `mailNickname` (or UPN local part) | custom claim `uid`, or derive from `preferred_username` | claim named `uid` from `user.mailnickname` | The account-link key for Drupal (`map_users_name`) and the Alumni `profiles.uid` join. Keep it identical to the old value |
| `mail` | `mail` | `email` claim (scope `email`; **verify** it is populated, cloud users often have no `mail`) | `user.mail` | Set `mail` explicitly when creating users |
| `displayName` | `displayName` | `name` claim | `user.displayname` | |
| `givenName`, `sn` | `givenName`, `surname` | `given_name`, `family_name` (optional claims, **verify**) | `user.givenname`, `user.surname` | |
| `employeeNumber` | `employeeId` | custom claim (claims policy) or Graph `GET /me?$select=employeeId` | `user.employeeid` | Not in the default ID token. Must be populated on the user |
| `eduPersonPrincipalName` | `userPrincipalName` | `preferred_username` (usually the UPN) or `upn` optional claim | `user.userprincipalname` | Scope changes from `@demo.test` to a verified tenant domain |
| `eduPersonAffiliation` (multi-valued) | **App roles** (`faculty`, `student`, `staff`, `alum`, ...) | `roles` claim | role attribute `http://schemas.microsoft.com/ws/2008/06/identity/claims/role` (multi-valued) | One role assignment per value. Alternative: `extensionAttribute1-15` (single value per attribute) |
| `memberOf` / groups (`hr-admins`, `registrar`) | App roles with the same values (recommended) | `roles` claim | role attribute | Or `groups` claim with object IDs, which needs GUID to name lookups |
| `eduPersonScopedAffiliation` | not native | derive in app: role + tenant domain | custom claim | |

## Why app roles, not groups

- The `groups` claim lists at most **150 groups in SAML and 200 in JWT**; above that Entra omits it and sends an overage pointer to Microsoft Graph.
- By default it contains **object IDs (GUIDs)**, not names; names only for cloud-only groups with an explicit setting, and group display names can collide.
- App roles are defined on the application, appear as readable values, are assignable to users (any license) or groups (**Entra ID P1 or higher for group assignment**), and are the documented indirection between directory groups and app authorization.

## Entra specifics that break ported code

1. **`eppn` scope.** Entra's federation metadata has **no `shibmd:Scope`**. Shibboleth SP's stock `attribute-policy.xml` applies `ScopeMatchesShibMDScope` to attribute IDs `eppn`, `affiliation`, `subject-id`, `pairwise-id`, `targeted-id` and silently deletes the values when metadata has no scope. In the SP's `attribute-map.xml` give Entra's claims **other IDs** (`upn`, `roles`) so the default policy does not filter them, or write an explicit policy. (The demo hit exactly this failure on its own IdP: logs show `removed value ... of attribute (eppn)`.)
2. **Single tenant, exact issuer.** Issuer for OIDC v2 is `https://login.microsoftonline.com/<tenantId>/v2.0`; SAML IdP entity ID is `https://sts.windows.net/<tenantId>/`. Never use `common`/`organizations` authorities for an internal app. Validate `iss`, `aud` and `tid`.
3. **UPN vs email vs preferred_username.** They can differ and can be changed. Link accounts on an immutable identifier (`oid`, or a SAML `NameID` in persistent format) once the first link is made, not on mutable text.
4. **Claim names are configurable** in SAML (`Attributes & Claims`): rename claims to short names (`uid`, `roles`) to avoid editing app code. Check the `NameFormat` Entra emits in a captured assertion and match it in `attribute-map.xml` (**verify**: mismatched `nameFormat` makes the SP ignore the attribute).
5. **SAML NameID.** Entra can emit `persistent`, `emailAddress`, `unspecified` or `transient`. Choose the format the SP expects (`sp_name_id_format` in samlauth, `NameIDFormat` in Shibboleth) and keep them identical.
6. **Claims customization for OIDC/OAuth** uses a *Custom Claims Policy (preview)* or a *Claims Mapping Policy* attached to the service principal; the admin-center claims blade is the simple path for SAML. Claims Mapping Policy supersedes the other two for that app (**verify** current status, the Custom Claims Policy is in preview).

## SAML claim URIs Entra emits by default

| Claim | Attribute `Name` |
|---|---|
| UPN | `http://schemas.xmlsoap.org/ws/2005/05/identity/claims/name` |
| Email | `http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress` |
| Given name | `http://schemas.xmlsoap.org/ws/2005/05/identity/claims/givenname` |
| Surname | `http://schemas.xmlsoap.org/ws/2005/05/identity/claims/surname` |
| Display name | `http://schemas.microsoft.com/identity/claims/displayname` |
| Object ID | `http://schemas.microsoft.com/identity/claims/objectidentifier` |
| Tenant ID | `http://schemas.microsoft.com/identity/claims/tenantid` |
| Roles | `http://schemas.microsoft.com/ws/2008/06/identity/claims/role` |
| Groups | `http://schemas.microsoft.com/ws/2008/06/identity/claims/groups` |

Confirm against a real captured assertion (browser SAML tracer, or enable SAML debug logging in the SP) before writing mappings.

## OIDC claims you can rely on

`iss`, `aud`, `sub` (pairwise per app), `oid` (stable per user across apps), `tid`, `preferred_username`, `name`, `roles` (app roles, when assigned), `groups` (if configured), `sid` (session id, when requested). Use `oid` or `sub` as the key, not `preferred_username`.
