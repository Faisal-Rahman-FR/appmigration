---
name: migrate-app-to-entra-id
description: "Migrate an application from CAS, Shibboleth, SAML or phpCAS sign-in to Microsoft Entra ID (Azure AD) authentication. Use when asked to move an app to Entra ID, replace CAS or Shibboleth with Entra, re-integrate Spring Boot, ASP.NET, Drupal samlauth or PHP apps with OIDC or SAML, map LDAP/eduPerson attributes to Entra claims or app roles, set up an Entra app registration or enterprise app, move a SaaS app such as Zoom to the Entra gallery, federate CAS or Shibboleth IdP to Entra as a bridge, or update Playwright login tests for Entra. Also use to assess how an app authenticates (phpCAS, mod_auth_cas, mod_shib, Shibboleth headers, LDAP bind, custom login form, existing SAML/OIDC, no authentication) in any language and choose the refactoring approach."
argument-hint: "App path or name, current protocol (CAS/SAML/phpCAS), and strategy (direct or bridge)"
---

# Migrate an application to Microsoft Entra ID

Replace an application's existing authentication (Apereo CAS, Shibboleth SP/IdP, SAML via samlauth, phpCAS) with Microsoft Entra ID, keeping the same people able to do the same things, and prove it with the same kind of browser test.

Worked examples live in this repo's demo suite (`samples/apps/*`); the per-demo change list is [samples/docs/ENTRA-ID-MIGRATION.md](../../../samples/docs/ENTRA-ID-MIGRATION.md).

## Guardrails (read first)

- **Writes to a tenant are consequential.** Creating users, app registrations, secrets, role assignments and claims policies changes a real directory. Show the exact objects and **ask before creating them**; prefer a dedicated test/developer tenant. Never run these against a production tenant for a demo.
- **Never print, log or commit secrets** (client secrets, certificates, test-user passwords). Put them in environment variables, a secret store or an ignored local file.
- Do not weaken validation to make a login work: keep issuer/audience/tenant checks, signature validation, `state`/`nonce`/PKCE, and exact redirect URIs. If a flow fails, find the claim, URL or certificate that is wrong.
- Everything here is derived from Microsoft documentation and the demo code. Anything marked **verify** has not been proven in your tenant: confirm it before relying on it.

## Step 1: Classify and choose a strategy

First inventory **every way the app gets its identity** and decide where trust is terminated (app library, web-server/agent edge, password handling, none, existing SAML/OIDC, packaged product, service-to-service). The full catalog of CAS and Shibboleth modes, the decision questions, per-language patterns and a PHP/cPanel worked example are in [integration-scenarios](./references/integration-scenarios.md). Use it to pick among strategies A (direct), B (bridge), C (edge swap), D (front door) and E (keep for federation); the table below covers the common demo cases.

| App today | Strategy A: direct re-integration (target) | Strategy B: bridge (fastest, no app change) |
|---|---|---|
| Java/Spring + CAS client | OIDC with Spring Security: [recipe](./references/recipe-spring-boot.md) | CAS delegates to Entra: [recipe](./references/recipe-legacy-idp-bridge.md) |
| PHP + phpCAS (shared hosting) | OIDC client library: [recipe](./references/recipe-php-shared-hosting.md) | CAS delegates to Entra |
| Drupal + samlauth | Entra as SAML IdP: [recipe](./references/recipe-drupal-samlauth.md) | Shibboleth IdP proxies to Entra |
| ASP.NET Framework + Shibboleth SP (IIS) | Point the SP at Entra, adapt identity helper: [recipe](./references/recipe-shibboleth-sp-iis.md) | Shibboleth IdP proxies to Entra |
| SaaS (Zoom-like) with SAML | Entra gallery app: [recipe](./references/recipe-saas-gallery.md) | n/a |

Choose **A** when the goal is to retire CAS/Shibboleth. Choose **B** as a transitional step: users authenticate at Entra but the apps still speak CAS/SAML to the legacy IdP, so the legacy IdP stays in production. Many projects do B first, then A app by app.

## Step 2: Map identity data

Entra has no `eduPerson*` schema. Decide, per attribute the app uses, where it comes from and how it reaches the app. See [claims and attributes](./references/claims-and-attributes.md). The rules that matter most:

1. **Authorization uses app roles, not groups.** The `groups` claim is omitted when a user is in more than 150 groups (SAML) or 200 (JWT) and contains GUIDs by default. App roles arrive as the `roles` claim (OIDC) or a role attribute (SAML).
2. **Multi-valued affiliation becomes multiple app role assignments** (alice = faculty + alum).
3. **Reuse the old values as app role values** (`faculty`, `staff`, `student`, `alum`, `hr-admins`) so the app's authorization checks do not change.
4. **Give every user who may sign in a role.** With *assignment required* on, an unassigned user cannot sign in at all. A user who must sign in but be denied a protected page (demo: `carol` on HR admin, Alumni directory, Drupal editor) needs a base role such as `member` that grants nothing.
5. **The scoped principal name changes.** `eppn` was `user@demo.test`; Entra's UPN uses a domain verified in the tenant. Update every scope or suffix check.
6. **Account linking keys must survive the move.** If the app links on `uid`, emit a `uid` claim (from `mailNickname`) or map explicitly; otherwise existing local accounts and database rows are orphaned.

## Step 3: Set up Entra objects

Follow [Entra setup](./references/entra-setup.md): test users with the attributes the app needs, app roles, one app registration (OIDC) or one enterprise application (SAML) per app, redirect/logout URLs, credentials, user assignment, claims, and consent. Record the tenant ID, application (client) ID and where each secret lives; do not paste them into chat or source.

## Step 4: Change the app

Open the matching recipe and apply it. Common to all recipes:

- Replace protocol code, not business logic. Keep the identity helper as the single place that reads identity.
- Register **exact** HTTPS redirect URIs. Behind a reverse proxy, make the app honor `X-Forwarded-*` so generated redirect URIs are HTTPS and match.
- Add the Entra endpoints to any Content-Security-Policy `form-action`, and to any test-time network allow-list. A redirect after a form POST is checked against `form-action`.
- Remove assumptions about CAS-only features, especially **back-channel logout** (see Step 5).
- Keep the legacy path behind a switch until the new one passes tests, so rollback is a configuration change.

## Step 5: Handle logout deliberately

Entra supports **front-channel logout only** (browser redirects, SAML Single Logout, OIDC `end_session_endpoint` and front-channel logout URL). It does not call apps server to server. CAS back-channel logout (`/slo` endpoints in HR and Alumni) has no Entra equivalent. For each app decide: local logout plus redirect to Entra's end-session endpoint (recommended), front-channel logout URL (needs a session cookie that is sent in a cross-site frame, i.e. `SameSite=None; Secure`), or shorter session lifetimes. Document the behavior change; tests that assert "logging out of app A ends app B's session" must change.

## Step 6: Update and run the tests

See [testing and cutover](./references/testing-and-cutover.md): an `entraLogin` helper replacing the CAS/Shibboleth form helpers, the network allow-list, test users that are excluded from MFA, attribute assertions rewritten to Entra claims, and the cutover and rollback plan.

## Step 7: Report

State what changed per app, what was verified (and how), what was not, and the behavior differences users will notice (logout, session length, MFA prompts, attribute availability). Do not claim a migration works until the app's login, protected page, role-denied page and logout were exercised in a browser against the real tenant.

## References

| File | Use for |
|---|---|
| [integration-scenarios.md](./references/integration-scenarios.md) | Classifying how an app authenticates (CAS, Shibboleth modes, LDAP, forms, headers, none, SAML/OIDC), choosing the refactoring approach per scenario and language |
| [claims-and-attributes.md](./references/claims-and-attributes.md) | LDAP/CAS/Shibboleth attribute to Entra source and claim mapping, limits, scope, NameID |
| [entra-setup.md](./references/entra-setup.md) | Tenant objects with `az` and Microsoft Graph, permissions, MFA for test users |
| [recipe-spring-boot.md](./references/recipe-spring-boot.md) | Java/Spring Boot + CAS client to OIDC |
| [recipe-shibboleth-sp-iis.md](./references/recipe-shibboleth-sp-iis.md) | ASP.NET Framework behind the native Shibboleth SP |
| [recipe-drupal-samlauth.md](./references/recipe-drupal-samlauth.md) | Drupal samlauth to Entra SAML |
| [recipe-php-shared-hosting.md](./references/recipe-php-shared-hosting.md) | Plain PHP/phpCAS on cPanel-style hosting to OIDC |
| [recipe-saas-gallery.md](./references/recipe-saas-gallery.md) | Zoom-like SaaS via the Entra gallery |
| [recipe-legacy-idp-bridge.md](./references/recipe-legacy-idp-bridge.md) | CAS or Shibboleth IdP delegating to Entra |
| [testing-and-cutover.md](./references/testing-and-cutover.md) | Playwright changes, rollout, rollback |
