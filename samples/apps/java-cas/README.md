# UC-01 — HR Self-Service

Java 21 / Spring Boot 3.3.3 using the actual Apereo Java CAS client 4.0.4, CAS3 validation and its back-channel SLO session listener. All identity comes from the validated CAS assertion, never request headers. `employeeNumber` and multivalued groups are displayed; exact group membership gates `/admin`. Local POST logout invalidates this session and then terminates CAS SSO, causing registered back-channel SLO callbacks.

From `samples`, initialize then `docker compose --env-file .local/demo.env up -d hr`. Gateway is required for public URLs. Maven unit command: `mvn -f apps\java-cas\pom.xml test`. For host runs import the generated CA into a Java truststore and set `CAS_ORIGIN`, `HR_ORIGIN`, `PORT`; use `mvn spring-boot:run` for development only. Production is `java -jar target/hr-self-service-1.0.0.jar`.

## Entra OIDC pilot and CAS rollback

`DEMO_AUTH=cas` is the default. `DEMO_AUTH=entra` activates Spring Security OIDC instead of the CAS filters, controller and back-channel listener. The CAS dependency and tests intentionally remain for configuration-only rollback. Invalid mode names fail startup.

Supply `ENTRA_TENANT_ID`, `ENTRA_CLIENT_ID` and `ENTRA_CLIENT_SECRET` through a protected ignored file or secret store. Register the exact `HR_ORIGIN/login/oauth2/code/entra` web callback and `HR_ORIGIN/` return URI. Implicit grants are not needed. The client requests `openid profile email https://graph.microsoft.com/User.Read`, uses authorization code + explicit S256 PKCE, and validates tokens through Spring's OIDC implementation plus an explicit `tid` check.

Use the principal attribute `sub`, **not** `preferred_username`: Graph's OIDC user-info response does not supply `preferred_username`. After token validation, the app reads `/me?$select=id,mailNickname,employeeId,mail,displayName` using the delegated access token. The Graph object ID must match the validated token's `oid`; all four profile fields must be populated. Only the identity allow-list is rendered, never raw tokens or the full claims map.

| Profile/role | HR value |
|---|---|
| `mailNickname` | `uid` (explicitly keep existing CAS account keys) |
| `employeeId` | `employeeNumber` |
| `mail`, `displayName` | Same attribute names |
| ID-token `roles` | `memberOf` display; `hr-admins` maps to the `/admin` authority |

`member` permits sign-in but not `/admin` (403). `/slo` is denied in Entra mode. OAuth failures terminate at `/login-error` (401) rather than re-entering the authorization endpoint in a redirect loop. Operators get non-secret error codes and missing-field diagnostics in the application log.

The HR container also uses the existing `edge` network for outbound Entra/Graph HTTPS; it still publishes no host ports. Entra startup uses the normal public-CA truststore and does not import the private CAS CA. Readiness probes Entra discovery in Entra mode and CAS in CAS mode.

```powershell
# Run from samples. Never put actual secret values in tracked files.
docker compose --env-file .local/demo.env --env-file .local/entra-hr.env build hr
docker compose --env-file .local/demo.env --env-file .local/entra-hr.env up -d --no-deps hr
```

In Entra mode, POST `/logout` requires Spring CSRF, invalidates the local session and redirects through Entra's discovered end-session endpoint. The application session cookie remains `SameSite=Lax; Secure; HttpOnly`, with a 30-minute inactivity timeout. No front-channel iframe endpoint is configured and CAS back-channel cross-app logout is not emulated.

For rollback, remove exported `DEMO_AUTH`/`ENTRA_*` overrides and recreate only HR with `.local/demo.env` (or explicitly export `DEMO_AUTH=cas` before the command). Keep CAS, its CA mount and service registration. Do not run a full stack redeploy for this pilot.

Java tests: `mvn test` in this directory. Browser tests: from `samples/tests`, run `npx playwright test specs/hr.spec.ts` in CAS mode or `npx playwright test specs/hr-entra.spec.ts` with the Entra environment loaded. The latter reads dedicated credentials from protected `samples/.local/entra-test-users.json` (`alice`/`carol`, each with `upn`/`password`). Never reuse legacy CAS passwords or commit this file. MFA/enrollment produces an explicit blocker, not a bypass; use an interactive shared browser when tenant policy requires it.

Sign in with the dedicated `hr-recipe-admin` (alice) or `hr-recipe-member` (carol) users. Accounts missing `employeeId`, `mail` or `mailNickname` are rejected with `invalid_employee_profile` by design.

See the [tenant validation report](../../docs/HR-ENTRA-VALIDATION.md) for measured results and remaining gaps. Unit tests alone are not proof of a real-tenant migration.
