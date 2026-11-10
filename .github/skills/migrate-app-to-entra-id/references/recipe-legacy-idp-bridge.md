# Recipe: bridge, a legacy IdP delegating authentication to Entra ID

Strategy B in the skill. Users authenticate at Entra; applications keep their existing protocol (CAS, SAML) and do **not** change. Use it to move quickly, to reduce risk, or while apps are migrated one at a time. The legacy IdP stays in production, so this is a transition, not retirement.

Demo mapping: `samples/idp/cas` (CAS 7.1.6, Gradle WAR overlay) serves HR and Alumni; `samples/idp/shibboleth` (Shibboleth IdP 5) serves Drupal and the Student SP.

## Decide where attributes come from

| Model | How | Trade-off |
|---|---|---|
| **Entra authenticates, LDAP/attribute store enriches** | Entra proves who the user is; the IdP looks up `eduPerson*`, groups, `employeeNumber` in the existing directory by a key (uid) | Zero change for apps and attribute names; keeps LDAP alive; requires the Entra identity to carry the same key (`uid` from `mailNickname`) |
| **Entra supplies attributes** | The IdP maps Entra claims/roles to the attribute names apps expect | Retires the directory; needs claims, app roles and a mapping per service; more work, closer to Strategy A |

## CAS delegated authentication (HR, Alumni)

Add the CAS delegated-authentication modules to `samples/idp/cas/build.gradle` (CAS 7 uses `cas-server-support-pac4j-webflow`; **verify** module and property names against the CAS 7.1 documentation) and configure Entra as an OIDC client:

```properties
# Entra app registration: redirect URI https://cas.<domain>/cas/login (pac4j callback); secret from the environment
cas.authn.pac4j.oidc[0].generic.id=${ENTRA_CLIENT_ID}
cas.authn.pac4j.oidc[0].generic.secret=${ENTRA_CLIENT_SECRET}
cas.authn.pac4j.oidc[0].generic.discovery-uri=https://login.microsoftonline.com/${ENTRA_TENANT_ID}/v2.0/.well-known/openid-configuration
cas.authn.pac4j.oidc[0].generic.scope=openid profile email
cas.authn.pac4j.oidc[0].generic.client-name=Entra
cas.authn.pac4j.core.principal-attribute-id=preferred_username      # then normalise to uid
```

- Make the CAS principal the old `uid`: strip the domain from `preferred_username`, or emit a `uid` claim. If the principal changes, every downstream app (HR `uid` display, Alumni `profiles.uid`, Drupal username link) loses its link.
- Keep `cas.authn.ldap[0]` as an **attribute repository** (not an authentication handler) for the enrichment model, so releases (`ReturnAllowedAttributeReleasePolicy`, `allowedAttributes: uid, mail, displayName, employeeNumber, memberOf, eduPersonAffiliation`) stay unchanged.
- Per service, restrict or require delegation with the registered service's delegated-authentication policy so a test service can still use the local login while you validate.
- Redirect URI: pac4j appends a `client_name` query parameter on the callback. If Entra reports `AADSTS50011`, register the exact URI shown in the error message after confirming it is the CAS login endpoint and nothing broader.
- The CAS login page then offers or auto-redirects to "Entra"; the existing back-channel SLO to HR/Alumni still works between CAS and the apps, but CAS logout does not end the Entra session unless you also redirect to Entra's end-session endpoint.

## Shibboleth IdP proxying to Entra (Drupal, Student SP)

Shibboleth IdP 5 can delegate authentication upstream; the supported mechanisms are the SAML authentication flow (the IdP acts as a SAML SP to Entra, **verify** the flow name and configuration in the current IdP documentation) or the External flow with a front-end that sets the remote user. Sketch for the SAML proxy:

1. Entra SAML enterprise application for the **IdP-as-SP** (entity ID, ACS from the IdP's proxy metadata, claims `uid`/`upn`).
2. `idp.properties`: add the SAML authentication flow and make it the default (`idp.authn.flows=SAML` or equivalent).
3. Upstream metadata (Entra federation metadata URL) in `metadata-providers.xml`.
4. Map the upstream NameID/attribute to the IdP principal (`uid`) so `attribute-resolver.xml` (LDAP lookup) works unchanged.
5. Keep `relying-party.xml` signing/encryption for Drupal and Student as they are.

The Student SP and Drupal see the same IdP and the same attributes. Session policy (`favorSSO`, session timeout) and MFA now depend on Entra plus the IdP session; document both.

## Operational findings (validated while registering the Events app in the demo CAS)

- **Restart CAS after adding a service.** With the JSON service registry, a new file is not served until CAS is restarted: the registry kept logging `Loaded [2]` for 25 minutes after the file was staged, and the login page said "Application Not Authorized". Apply the same check to any new registered service (including the bridge's per-service delegation policy).
- Set `logoutType` explicitly per service. A `mod_auth_cas` client has no back-channel endpoint, so register it with `logoutType NONE` and expect CAS logout to leave that app's own session alive.
- Edge-only authentication (`valid-user`) is authentication, not authorization. Keep an explicit allow list or role check in front of protected files, or any account the bridge authenticates can reach them.

## What the bridge does not give you

- No retirement of CAS, Shibboleth or LDAP; you now operate two identity systems.
- Logout semantics are the union of both and are easy to get half-working. Test: sign out of an app, then visit another app; confirm whether Entra silently signs the user back in.
- Entra Conditional Access applies to the Entra sign-in only; the legacy IdP can still mint sessions if left reachable. Disable local password login once the bridge is verified, otherwise the bridge is optional rather than enforced.

## Exit to Strategy A

Migrate apps one at a time (recipes above), then remove the delegated flow, retire the legacy IdP and its directory, and delete the legacy service registrations only after the last app is cut over.
