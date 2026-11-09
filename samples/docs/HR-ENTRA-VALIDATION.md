# HR Spring Boot CAS to Entra OIDC: tenant validation

## Verdict

**Validated end to end by manual browser test (user-observed); automated
authenticated tests remain MFA-blocked.** On 2026-11-04 the HR pilot was
implemented, compiled and deployed in the approved non-production tenant. After
the dedicated users completed the tenant's mandatory MFA/security-information
enrollment, the operator reported in an interactive browser that all four
acceptance categories passed (see "Manual acceptance" below). The assistant
could not see that browser session, so these results are user-reported rather
than captured by the automated suite. The two authenticated Playwright tests
still fail at MFA enrollment and have not been rerun against enrolled users.

**Which account to use:** the dedicated `hr-recipe-admin` (alice) and
`hr-recipe-member` (carol) users. An operator account without `employeeId`/`mail`
is rejected by design.

The original recipe was not executable as-is: runtime testing exposed a wrong
principal attribute. The pilot's direct-login adaptation also introduced an OAuth
failure redirect loop, which was corrected rather than left as a recipe workaround.
The deployment also needed explicit outbound networking, PKCE, Spring CSRF
integration, Graph profile mapping and a retained CAS rollback path.

This report covers **UC-01 HR only**, plus its existing CAS cross-app logout
regression tests. It does not certify the other demo migrations.

## Environment and approved changes

| Item | Value |
|---|---|
| Test tenant | `9b6ae5da-be43-463a-807f-c2cf9ec887db` |
| Subscription | `ca3d03e2-18bb-487f-b115-84b4378225ee` |
| Resource group / VM | `rg-faisal-idpdemo` / `vm-idpdemo-kiv1-linux` |
| App | <https://hr.chris.securitylabworks.com/> |
| App registration / enterprise app name | `demo-hr-oidc-validation` |
| Client ID | `7c08c2dc-c213-45d6-aa4c-e360729510d5` |
| Application object ID | `473db103-9374-4867-8e16-d227051e32fa` |
| Service principal ID | `9b49cdef-e5c9-4208-95a3-c9abde3c3382` |
| Callback | `https://hr.chris.securitylabworks.com/login/oauth2/code/entra` |
| Registered post-logout return | `https://hr.chris.securitylabworks.com/` |
| Audience / assignment | Single tenant (`AzureADMyOrg`); assignment required |
| Permissions | OIDC `openid profile email`; delegated Graph `User.Read` |
| Implicit access/ID token issuance | Both disabled; authorization code flow is used |
| Client credential expiry | **2026-11-11 17:12:06 UTC** (seven-day validation credential) |
| Final deployed mode | `DEMO_AUTH=entra`; Linux VM left running with approval |

Azure extension authentication originally targeted the Microsoft corporate tenant.
Azure CLI targeted the approved test tenant. Tenant writes used the CLI context;
no directory objects were created in the corporate tenant.

The existing Linux VM was initially stopped. Starting it restored valid HR HTTPS;
no certificate validation was bypassed, no new Azure resources were provisioned,
and the Windows VM was not started for this pilot. Linux VM runtime charges resume
while it is running.

### Identities and assignments

| Identity | Object ID | Legacy uid / employeeNumber | Role |
|---|---|---|---|
| `hr-recipe-admin@MngEnvMCAP536603.onmicrosoft.com` | `887ecc72-e3c8-4810-b156-56b2447df984` | `alice` / `10001` | `hr-admins` |
| `hr-recipe-member@MngEnvMCAP536603.onmicrosoft.com` | `87407e10-82bd-46c4-8f79-9b2987f3c620` | `carol` / `10003` | `member` |

Role IDs:

- `hr-admins`: `a7058051-b526-46d1-95ef-26509c74a481`
- `member`: `f3f63327-b4be-4b9f-a8e8-2b4e48061631`

The initially approved existing `testuser1`/`testuser2` accounts were synchronized
from on-premises. Graph rejected the combined `mail`/`employeeId` update as an
on-premises mastered-object change. After separate approval, two cloud-only
users were created; their aliases preserve `alice` and `carol` rather than
deriving different keys from their UPNs. Their Graph fields and role assignments
were read back successfully. The initial testuser assignments were removed
from this new enterprise app; no passwords or MFA policy were changed on those
existing accounts.

Final directory inspection also observed an operator default-access assignment
(`53f011a8-b98b-44ad-a353-f47b57b10881`, zero/default role ID), separate from
the two test-role assignments. It was not granted `hr-admins` by the migration
automation and was not removed without approval.

### Credential handling

- Local, ACL-protected, ignored files: `samples/.local/entra-hr.env` and
  `samples/.local/entra-test-users.json`. The latter contains dedicated
  `alice`/`carol` entries with `upn` and `password`.
- VM files: the corresponding files under
  `/srv/idpdemo/source/samples/.local/`, root-only mode `0600`.
- Credentials were transported in RSA-OAEP encrypted envelopes. The temporary
  VM-only private transport key and encrypted envelopes were removed after use.
- Non-secret object/credential-key metadata is in
  `samples/.local/entra-hr-validation.json`. No passwords, client secrets,
  tokens, MFA QR codes or recovery codes belong in this report.
- The client secret expires on the date above. Rotate through the same protected
  storage or remove the pilot; do not extend it silently.

## Implementation and recipe corrections

See the [application guide](../apps/java-cas/README.md) and
[corrected Spring Boot recipe](../../.github/skills/migrate-app-to-entra-id/references/recipe-spring-boot.md).

1. **Principal attribute:** `preferred_username` caused a callback 500 in
   `OidcUserService`: Graph's OIDC user-info response does not supply that
   attribute. Use `sub` for the OIDC principal. A regression test loads the real
   Entra property file and checks that setting.
2. **Required employee data:** after normal OIDC validation, call Graph
   `/me?$select=id,mailNickname,employeeId,mail,displayName` using the delegated
   access token. Require the Graph object ID to match the ID token's `oid`.
   Map `mailNickname` to `uid` and `employeeId` to `employeeNumber`. Missing
   fields fail explicitly; there is no UPN fallback that silently changes keys.
3. **Token/role boundaries:** retain Spring's signature, issuer, audience,
   timestamp, state and nonce validation; explicitly validate the ID token's
   `tid`. Use ID-token roles for `APPROLE_hr-admins`. Do not authorize on the
   profile's human-readable group display or request headers.
4. **PKCE:** explicitly add S256 PKCE for this confidential client. A client
   secret alone does not make Spring add PKCE.
5. **CSRF/logout:** retain Spring CSRF; use Thymeleaf `th:action` so `_csrf`
   is emitted. POST logout invalidates the app session and uses the discovered
   Entra end-session endpoint. The old manual token remains CAS-only.
6. **Failure handling:** an authorization-endpoint login page plus Spring's
   default `?error` failure URL caused repeated Entra SSO attempts. Failures
   now stop at a public `/login-error` page with HTTP 401 and a non-secret error
   code. Tests cover this instead of accepting a redirect loop.
7. **Networking/trust:** HR's existing internal-only Docker network blocked
   external providers. HR now also joins the existing `edge` network without
   publishing host ports. Entra startup uses public CAs and skips CAS's private
   CA import. Readiness follows the selected provider.
8. **Rollback:** CAS dependency, filters, listener, controller and tests remain
   conditional on CAS mode. They are inactive in Entra mode. `/slo` is denied
   in Entra mode; CAS cross-app logout tests explicitly skip there.
9. **Test safety:** explicit Entra/CDN network allow-list; traces, screenshots
   and video remain disabled. MFA/enrollment yields an explicit failure rather
   than a password-flow or tenant-policy bypass.

## Measured results

The final Java build finished at **2026-11-04 19:51:15 UTC**.
Final browser runs started at **19:52:24 UTC** (CAS) and **19:52:40 UTC** (Entra).

| Check | Result | What this proves |
|---|---|---|
| Java 21 / Maven build and tests | **15 passed, 0 failed** | MVC/security/CSRF/logout contracts, identity mapping, profile rejection, tenant check, PKCE request shape and legacy unit tests |
| TypeScript `tsc --noEmit` | **Passed**, local and VM | Updated browser helper/specs type-check |
| Original deployed CAS HR baseline | **2 passed** | Pre-change HR login, attributes, admin allow/deny and logout |
| Final updated CAS HR + SLO suite | **4 passed** | Configuration-only rollback preserves HR and both existing CAS cross-app logout directions |
| Final live Entra anonymous challenge | **1 passed** | HTTPS health/readiness, real discovery, tenant-specific authorization URL, exact callback, S256 challenge, state and nonce |
| Entra admin/member authenticated Playwright tests | **2 failed**, MFA/enrollment blocker (run before enrollment) | Automated proof still outstanding; see manual acceptance below |
| Manual browser acceptance (user-observed) | **Passed**: login/profile, admin 200, member 403, logout | Real-tenant callback, profile mapping, role allow/deny and end-session logout |
| CAS cross-app tests in Entra mode | **2 explicitly skipped** | They assert a legacy back-channel contract Entra does not provide |
| Final `/healthz`, `/readyz` | **200**: `ok`, `ready` | App running and Entra discovery reachable; not authenticated acceptance |
| App registration and assignments read-back | **Passed** | Persistent configuration, scopes, redirect URIs, role IDs and credential expiry |

The final automated Entra runner status is **failed**, not passed or skipped:
`1 passed / 2 failed / 2 skipped`, exit code **1**. That run happened before the
dedicated users enrolled in MFA. The automated authenticated checks are
classified as **blocked by MFA**; the manual acceptance below is separate evidence.
MockMvc uses simulated OIDC identities; it is not real-tenant role evidence.

Interactive testing reached the real callback and exposed the original
principal-attribute defect. A sign-in with the operator account
(`farahm@…`) was then correctly rejected with `invalid_employee_profile`
because that account has no `employeeId` or `mail`. The fix for that is to sign
in as the dedicated test users, not to relax the check.

### Manual acceptance (user-observed, 2026-11-04)

Signed in as the dedicated users after completing MFA/security-info enrollment:

| Account | Observed |
|---|---|
| `hr-recipe-admin@MngEnvMCAP536603.onmicrosoft.com` | `/profile` showed `uid=alice`, `employeeNumber=10001`, role `hr-admins`; `/admin` loaded (200) |
| `hr-recipe-member@MngEnvMCAP536603.onmicrosoft.com` | `/profile` showed `uid=carol`, `employeeNumber=10003`, role `member`; `/admin` denied (403) |
| Both | Sign out returned to the HR home page; `/profile` then required a new sign-in |

Not captured: timestamps, a replay of the old session cookie after logout, and
a `/slo` denial check in the real tenant. Those remain covered only by the
unit/MockMvc tests and the automated test once MFA permits it.

### Evidence locations

- [Sanitized result summary](./HR-ENTRA-VALIDATION.json) (no credentials).
- Persistent VM evidence directory:
  `/srv/idpdemo/source/samples/.local/entra-evidence/`.
- Full reporter JSON: `cas-final-results.json`, `entra-final-results.json`.
- Logs: `cas-baseline.log`, `cas-final.log`, `entra-final.log`,
  `maven-tests.log`; JUnit XML for the two Entra test classes.
- The normal per-run Playwright JSON remains in `samples/tests/results/`.
- Original CAS HR source/Compose backup: `hr-cas-source.tgz` in the protected
  evidence directory. Original image retained as `hr-cas-rollback:20261104`.

No full multi-app suite was rerun; unrelated Drupal/Windows deployment failures
are outside this validation.

## Reproduce and complete acceptance

On the existing Linux VM, run as an operator able to use Docker and read the
protected environment files. Do not enable shell tracing or print environment
variables.

```bash
cd /srv/idpdemo/source/samples
set -a
. .local/demo.env
. .local/entra-hr.env
set +a
docker compose --env-file .local/demo.env --env-file .local/entra-hr.env up -d --no-deps hr
cd tests
npm run typecheck
npx playwright test specs/hr-entra.spec.ts specs/slo.spec.ts
```

The existing browser harness restricts application DNS to private/loopback
addresses and Entra traffic to its explicit allow-list. Keep that protection.
The VM's existing hosts configuration meets the app-side requirement; these
commands are not instructions to enable unrestricted public test targets.

To clear the blocker without weakening tenant policy:

1. Use a separate/shared test browser, sign out the operator SSO account, and
   sign in **as the dedicated `hr-recipe-admin` account**, not the operator.
   Complete its required security-information registration/MFA and delegated
   `User.Read` consent. Do the same for `hr-recipe-member`.
2. Observe admin `/profile`: `uid=alice`, `employeeNumber=10001`, role
   `hr-admins`, and the dedicated admin's mail. Verify `/admin` returns 200.
3. In a separate user session, observe `uid=carol`, `employeeNumber=10003`,
   role `member`; verify `/admin` returns 403 and `/slo` is denied.
4. For each account, POST logout with the rendered CSRF token. Observe the
   Entra sign-out and return to `/`. Replay the old app-session cookie against
   `/profile` and verify it is unauthenticated. A later silent Entra SSO login
   is not evidence that the old app session survived.
5. Rerun the automated tests if policy permits unattended sign-in. If MFA
   remains interactive on every login, record observed browser assertions
   with timestamps and non-secret result JSON instead. Do not mark automated
   tests passed when only the manual path worked.
6. Update this report's verdict only after all four acceptance categories
   (login/profile, allowed page, denied page and logout) are actually observed.

## Rollback and cleanup

Configuration-only rollback was executed and browser-tested on the final image:

```bash
cd /srv/idpdemo/source/samples
unset ENTRA_TENANT_ID ENTRA_CLIENT_ID ENTRA_CLIENT_SECRET
export DEMO_AUTH=cas
docker compose --env-file .local/demo.env up -d --no-deps hr
```

After rollback, run `npx playwright test specs/hr.spec.ts specs/slo.spec.ts`
from `tests` with the legacy demo environment loaded. To return to the pilot,
reload the protected Entra environment and recreate only HR. A generic later
Compose command that omits the Entra environment returns HR to its CAS default;
operators must choose the mode explicitly.

Keep CAS, its CA material and service registration until final cutover and the
rollback window end. Entra has no CAS back-channel equivalent: signing out of HR
does not revoke Alumni's app session by server callback. No front-channel iframe
logout is configured. Cookies stay `Secure; HttpOnly; SameSite=Lax`; the app
inactivity timeout remains 30 minutes. MFA and consent prompts are tenant-driven.

No automatic cleanup was performed. After explicit approval, remove only this
pilot's app registration (and its enterprise app), the two dedicated cloud users,
and their protected local/VM credential files; do not delete the pre-existing
testuser/operator accounts. Review the observed operator app assignment as part
of cleanup. If keeping the pilot, rotate the seven-day credential before expiry.
Stop/deallocate the Linux VM when no longer needed, with operator approval.

## References

- [Microsoft identity platform OIDC](https://learn.microsoft.com/en-us/entra/identity-platform/v2-protocols-oidc)
- [Microsoft Graph: get user](https://learn.microsoft.com/en-us/graph/api/user-get?view=graph-rest-1.0)
- [Spring Security OIDC decoder API used by this Spring version](https://docs.spring.io/spring-security/site/docs/6.3.3/api/org/springframework/security/oauth2/client/oidc/authentication/OidcIdTokenDecoderFactory.html)
