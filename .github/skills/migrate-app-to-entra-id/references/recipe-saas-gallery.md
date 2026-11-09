# Recipe: SaaS application via the Entra gallery (Zoom-like)

Demo: `samples/config/shibboleth/zoom` (UC-02, **configuration only**: no app, no tenant). Pattern: **gallery app**, complexity low. The existing artifacts are the *old IdP's* relying-party entry and attribute filter for a synthetic entity ID `example.zoom.us`; they are retired, not translated, when Entra becomes the IdP.

## What exists today

- `relying-party.xml`: a `RelyingPartyByName` for `example.zoom.us` with signed responses and assertions, assertions not encrypted.
- `attribute-filter.xml`: releases `mail`, `givenName`, `sn`, `eduPersonAffiliation` to that relying party.
- A gallery match is a **candidate**, not proof the organization owns a Zoom tenant.

## Steps

1. **Confirm ownership and scope.** Identify the real Zoom account, its vanity URL (`<company>.zoom.us`), the verified email domain Zoom requires, and who administers it. Users' email domains in Entra must match the domain verified in Zoom.
2. **Add the gallery app.** Entra admin center, Enterprise applications, New application, search **Zoom**, Add. Follow Microsoft's current tutorial for that gallery app for the exact Identifier, Reply URL, Sign-on URL and logout values for your vanity URL (they are app-specific; do not guess). Then **Single sign-on, SAML**.
3. **Map claims** (Attributes and Claims):

| Old release (Shibboleth) | Entra source | Notes |
|---|---|---|
| `mail` | `user.mail` | Must be unique and match the Zoom account email |
| `givenName` | `user.givenname` | |
| `sn` | `user.surname` | |
| `eduPersonAffiliation` | usually **drop**; or map `user.jobtitle`/department if Zoom attribute mapping needs one | Zoom has no concept of eduPerson affiliations; confirm the Zoom field before mapping |

   Use the claim names the gallery pre-populates and enter the same names in Zoom's SSO attribute mapping.
4. **Configure Zoom.** In the Zoom admin portal (Single Sign-On): Entra's sign-in URL, sign-out URL, IdP entity (issuer `https://sts.windows.net/<tenantId>/`) and the signing certificate (or the federation metadata). Set Zoom's attribute mapping fields to the claim names above.
5. **Assign users** to the enterprise application (users or, with P1, groups). Test with one pilot user before enabling for all.
6. **Provisioning (optional).** The Zoom gallery app supports automatic user provisioning (SCIM); decide whether Entra becomes the source of truth for Zoom accounts and who may create them.
7. **Retire the Shibboleth relying party.** Remove `example.zoom.us` from `shibboleth.RelyingPartyOverrides` and `attribute-filter.xml` only after the cutover is verified; keep the old entry available for rollback until then.

## Verification

- SP-initiated: browse to the Zoom vanity URL, choose SSO, land at Entra, return signed in with correct name and email.
- IdP-initiated from the Entra My Apps portal.
- A user without assignment is blocked at Entra; a user with a mismatched email domain is rejected by Zoom.
- Sign-out behavior: Zoom sign-out and Entra single logout are separate; confirm what each ends.

## Pitfalls

- Duplicate or non-matching emails create or fail accounts; clean the directory first.
- Domain verification at Zoom must exist before SSO can be enforced.
- Certificate expiry: the SAML signing certificate has an expiry date; set a reminder or notification email in the enterprise app.
- Do not make production changes from this demo: the synthetic `example.zoom.us` and the lack of a tenant mean there is nothing real to configure here.
