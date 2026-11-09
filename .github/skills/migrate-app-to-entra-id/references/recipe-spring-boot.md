# Recipe: Spring Boot + Apereo CAS client to Entra ID (OIDC)

Demo: `samples/apps/java-cas` (HR Self-Service, UC-01). Pattern: **OIDC re-integration**, complexity medium.

## Validation status

The HR implementation was compiled, deployed and exercised in a dedicated tenant on
2026-11-04. The original recipe exposed runtime/configuration defects described
below; they are corrected here. Login, profile mapping, role allow (200) and deny
(403), and logout were **confirmed manually in a browser against the real tenant**
(user-observed, after MFA enrollment). The automated Playwright login test is still
blocked by tenant MFA. See [the evidence report](../../../../samples/docs/HR-ENTRA-VALIDATION.md)
for exact checks, object IDs, remaining gaps and rollback. Other application recipes
are not validated by this HR pilot.

Steps the original recipe omitted (all added below):

1. Attach HR to a network that can reach `login.microsoftonline.com` and `graph.microsoft.com`.
2. Use `sub`, not `preferred_username`, as the principal attribute.
3. Request `https://graph.microsoft.com/User.Read` and read `employeeId`/`mailNickname`/`mail` from Graph; require them.
4. Add S256 PKCE explicitly; add an explicit `tid` check.
5. Use `th:action` so Spring's CSRF field is rendered on the sign-out form.
6. Add a failure handler and `/login-error` page to avoid a redirect loop.
7. Check users are cloud-editable and complete MFA/security-info enrollment once.
8. Sign in as a **dedicated, fully populated** user; do not reuse an operator SSO session.

## What exists today

- `pom.xml`: `org.apereo.cas.client:cas-client-core` 4.0.4, Spring Boot 3.3.3, Java 21.
- `CasConfiguration.java`: servlet filters `AuthenticationFilter`, `Cas30ProxyReceivingTicketValidationFilter`, `SingleSignOutFilter`, a `logoutBoundary` filter, and a session listener.
- `PortalController.java`: reads the CAS `Assertion` from the session; `/logout` POST invalidates the session then redirects to CAS; `/slo` receives **back-channel** logout.
- `Identity.java`: `hrAdmin()` checks `memberOf` contains `cn=hr-admins,ou=groups,dc=demo,dc=test`.
- `profile.html` renders **every identity attribute** with `data-testid=<name>`; tests assert `employeeNumber` and `memberOf`.

## Target design

Spring Security's built-in OIDC login (authorization code + PKCE) against Entra. The identity record keeps the same attribute names so templates and tests change little.

### 1. Dependencies

For a final cutover, replace `cas-client-core` with the dependencies below. For a
pilot that must preserve configuration-only rollback, **retain** the CAS dependency,
filters, listener, controller and tests behind `demo.auth=cas` and activate the OIDC
chain/controller only for `demo.auth=entra`. The worked implementation uses
`DEMO_AUTH=cas|entra` (default CAS), not two simultaneous authentication paths.

```xml
<dependency><groupId>org.springframework.boot</groupId><artifactId>spring-boot-starter-security</artifactId></dependency>
<dependency><groupId>org.springframework.boot</groupId><artifactId>spring-boot-starter-oauth2-client</artifactId></dependency>
<dependency><groupId>org.springframework.security</groupId><artifactId>spring-security-test</artifactId><scope>test</scope></dependency>
```

(No Azure-specific starter is required; the generic OIDC client with Entra's issuer works. Microsoft's `spring-cloud-azure-starter-active-directory` is an alternative.)

### 2. Configuration (`application.properties`, values from the environment)

```properties
spring.security.oauth2.client.registration.entra.client-id=${ENTRA_CLIENT_ID}
spring.security.oauth2.client.registration.entra.client-secret=${ENTRA_CLIENT_SECRET}
spring.security.oauth2.client.registration.entra.scope=openid,profile,email,https://graph.microsoft.com/User.Read
spring.security.oauth2.client.registration.entra.redirect-uri={baseUrl}/login/oauth2/code/{registrationId}
spring.security.oauth2.client.provider.entra.issuer-uri=https://login.microsoftonline.com/${ENTRA_TENANT_ID}/v2.0
spring.security.oauth2.client.provider.entra.user-name-attribute=sub
# Already present: keeps {baseUrl} HTTPS behind the gateway.
server.forward-headers-strategy=native
```

Keep `demo.app-origin`. Supply the Entra values through a protected ignored file.
Retain `demo.cas-origin`, the CA mount and CAS variables during the rollback window.
The Entra startup branch must skip importing that private CA. The original HR
container was on an **internal-only** Compose network; attach it to the existing
`edge` network so discovery, token exchange and Graph can reach the Internet.
No new host port is needed.

**Observed correction:** `preferred_username` as `user-name-attribute` caused a
callback 500 (`Missing attribute 'preferred_username' in attributes`). Graph's
OIDC user-info response provides `sub`, not that claim. Use `sub` for the
principal; map human-facing identity separately.

### 3. Security configuration (replaces `CasConfiguration`)

```java
@Configuration
@EnableWebSecurity
class SecurityConfig {
  @Bean
  SecurityFilterChain chain(HttpSecurity http, ClientRegistrationRepository clients) throws Exception {
    var logout = new OidcClientInitiatedLogoutSuccessHandler(clients);
    logout.setPostLogoutRedirectUri("{baseUrl}/");
    http.authorizeHttpRequests(a -> a
          .requestMatchers("/", "/healthz", "/readyz").permitAll()
          .requestMatchers("/admin").hasAuthority("APPROLE_hr-admins")
          .anyRequest().authenticated())
        .oauth2Login(o -> o
            .authorizationEndpoint(a -> {
              var resolver = new DefaultOAuth2AuthorizationRequestResolver(clients, "/oauth2/authorization");
              resolver.setAuthorizationRequestCustomizer(OAuth2AuthorizationRequestCustomizers.withPkce());
              a.authorizationRequestResolver(resolver);
            }))
        .logout(l -> l.logoutSuccessHandler(logout));   // POST /logout with Spring's CSRF token
    return http.build();
  }

  @Bean   // picked up automatically by oauth2Login: maps the roles claim to authorities
  GrantedAuthoritiesMapper authorities() {
    return granted -> {
      var mapped = new HashSet<GrantedAuthority>(granted);
      for (var authority : granted) {
        if (authority instanceof OidcUserAuthority oidc) {
          var roles = oidc.getIdToken().getClaimAsStringList("roles");
          if (roles != null) roles.forEach(r -> mapped.add(new SimpleGrantedAuthority("APPROLE_" + r)));
        }
      }
      return mapped;
    };
  }
}
```

> The snippets are explanatory, not the complete switchable implementation. See
> `SecurityConfiguration.java`, `EntraPortalController.java` and `EntraUserService.java`
> in the demo. Those classes are built and tested; full real-tenant browser
> acceptance remains subject to the blockers in the evidence report.

- Set PKCE explicitly: adding a client secret does **not** make Spring's confidential-client flow use PKCE automatically.
- Keep CSRF enabled and use `th:action="@{/logout}"` so Thymeleaf emits Spring's hidden `_csrf` field. The old plain HTML `action` and manual `csrf` value are not sufficient.
- Use an explicit failure handler and a public `/login-error` page. A custom login page pointing at `/oauth2/authorization/entra` otherwise makes the default `?error` failure URL re-enter authentication, causing a redirect loop when Entra SSO is active.
- Preserve Spring's signature/issuer/audience/time/nonce validation; also require the ID token's `tid` to equal the configured tenant.

- `/admin` returns **403** for an authenticated user without the role (Spring does this), matching the existing student-denied test.
- The Entra end-session endpoint comes from the discovery document, so `OidcClientInitiatedLogoutSuccessHandler` works without hard-coding it. Register `https://hr.<domain>/` as a post-logout redirect URI.

### 4. Identity mapping (`Identity`, `PortalController`)

```java
Identity from(OidcUser u) {
  var a = new LinkedHashMap<String, Object>();
  a.put("mail", u.getClaimAsString("mail"));
  a.put("displayName", u.getClaimAsString("displayName"));
  a.put("employeeNumber", u.getClaimAsString("employeeNumber"));
  a.put("memberOf", u.getIdToken().getClaimAsStringList("roles"));
  return new Identity(u.getClaimAsString("uid"), a);
}
```

This example expects the OIDC user to have been enriched by the validated
Graph lookup in `EntraUserService`. The CAS `Identity.hrAdmin()` helper stays
CAS-specific during rollback; Entra route authorization belongs to the security
chain, not that LDAP-group helper.

Use `@AuthenticationPrincipal OidcUser` in `/profile` and `/admin`. `employeeid` is **not** in the default ID token: add a custom claim via a claims policy, or call Graph with the user's delegated token. The worked HR pilot uses
`GET /me?$select=id,mailNickname,employeeId,mail,displayName` with `User.Read`;
it requires `id` to match the ID token's `oid` and requires all mapped profile
fields. It derives no silent UPN fallback and renders no raw token claims.
Map authorization roles only from the validated ID token. See
[claims-and-attributes](./claims-and-attributes.md).

**Observed tenant constraint:** synchronized test users could not have `mail` and
`employeeId` updated together in Graph (on-premises mastered object rejection).
Verify profile editability **before** proposing user changes. Use approved
cloud-only test users or update the on-premises source, not a weakened app check.

### 5. Remove CAS-only code

For final retirement, delete the CAS-only code. During the pilot, conditionally
disable the filters/listener/controller in Entra mode and keep `LogoutBoundaryTest`
for CAS rollback. Deny `/slo` explicitly in Entra mode. The shared profile template
uses the legacy CSRF field only in CAS mode; Spring adds its own field in Entra mode.
Keep `healthz`; make `readyz` check the selected provider.

### 6. Logout behavior

Local session invalidation plus redirect to Entra's end-session endpoint. There is **no back-channel logout**: signing out of HR no longer signs out of Alumni through a server callback. Optional: register a front-channel logout URL (`/logout/frontchannel`, a GET that invalidates the session) and set the session cookie `SameSite=None; Secure` so the browser sends it from Entra's hidden frame. Otherwise keep `SameSite=Lax` and accept the difference.

### 7. Tests

Rewrite with `SecurityMockMvcRequestPostProcessors.oidcLogin().idToken(t -> t.claim("roles", List.of("hr-admins")))`; assert 403 without the role, 302 to the Entra authorization endpoint when anonymous, profile attributes, and logout. Browser test: see [testing and cutover](./testing-and-cutover.md).

## Pitfalls

- Redirect URI mismatch (`AADSTS50011`): the registered URI must equal `https://hr.<domain>/login/oauth2/code/entra` exactly; HTTP behind the proxy means `forward-headers-strategy` is not applied.
- Missing `roles`: user not assigned a role, or the app registration lacks app roles; `appRoleAssignmentRequired=true` blocks unassigned users entirely.
- `email` is null for cloud users with no `mail` property: set it when creating users.
- Clock skew and token validation use Spring defaults; do not disable issuer/audience checks.
- Mandatory MFA enrollment can block a dedicated test user's first login. Do not disable tenant policy or mark the recipe verified because a unit test passes. Use the **dedicated** assigned user, not an operator's existing SSO session.
