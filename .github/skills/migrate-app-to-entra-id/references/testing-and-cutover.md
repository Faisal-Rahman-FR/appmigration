# Testing and cutover

## What the demo's tests do today

`samples/tests/support/browser.ts` provides `casLogin` (`#username`/`#password`) and `samlLogin` (`input[name=j_username]`), blocks every origin except the demo hosts (`context.route` aborts others), and each spec asserts the attributes the app shows, a protected page, a role-denied page and logout. Results are JSON per run. Keep that shape; change the login helper, the allow-list and the assertions.

## `entraLogin` helper

```ts
const entraHost = 'https://login.microsoftonline.com';
export async function entraLogin(page: Page, upn: string): Promise<void> {
  await expect(page).toHaveURL(new RegExp('^' + entraHost.replace(/\./g, '\\.') + '/'));
  await page.locator('input[name=loginfmt]').fill(upn);
  await page.locator('#idSIButton9').click();                        // Next
  await page.locator('input[name=passwd]').fill(password(upn));
  await page.locator('#idSIButton9').click();                        // Sign in
  const stay = page.locator('#idBtn_Back');                          // "Stay signed in?" -> No
  if (await stay.isVisible({ timeout: 5000 }).catch(() => false)) await stay.click();
  const consent = page.locator('input[value="Accept"]');             // first-use consent, if any
  if (await consent.isVisible({ timeout: 2000 }).catch(() => false)) await consent.click();
}
```

Selectors are stable today but Microsoft changes sign-in UI without notice: treat them as **verify**, and fail with a clear message (not a bare timeout) when a step is not found. Never save traces, videos or screenshots of these pages (they contain credentials); the demo already disables them.

The demo's current helper (`samples/tests/support/entra.ts`) differs from the sketch in three ways: it takes the app (`HR_ORIGIN`, `ALUMNI_ORIGIN`, `DRUPAL_ORIGIN`, `STUDENT_ORIGIN`, `EVENTS_ORIGIN`) and waits for that app's exact landing URL; it reads dedicated credentials from the protected `.local/entra-test-users.json`; and it polls, failing with a specific message for wrong password, MFA enrollment ("Let's keep your account secure"), or an application callback error page, instead of a bare timeout.

## Per-app mode switches and gating

Each pilot runs in either legacy or Entra mode, selected by an environment variable on the host or container: `DEMO_AUTH` (HR), `ALUMNI_AUTH`, `DRUPAL_AUTH`, `STUDENT_AUTH`, `EVENTS_AUTH`; value `entra` selects Entra. The legacy specs apply when the variable is unset and the Entra specs skip themselves, so one suite validates both states and the rollback run. Entra specs also read `ENTRA_TENANT_ID` and the app's `*_ENTRA_CLIENT_ID`. Tests that need a real password sign-in are additionally gated by `ENTRA_AUTOMATED_LOGIN=1`; leave it unset when MFA applies and validate that path interactively instead. `browser.ts` adds the Entra hosts to the allow-list only when one of the `*_AUTH` variables is `entra`.

Anonymous tests (readiness, redirect to the correct tenant and client ID, header-spoof rejection) are necessary but cannot catch post-callback faults. The Events pilot passed all of them and still failed on the first real sign-in (`Cannot declare class Events`, a `require` that should have been `require_once`). Require at least one observed authenticated page per app before calling it validated.

## Network allow-list

`browser.ts` aborts requests to non-demo origins. Add Entra's sign-in hosts or login will hang: `login.microsoftonline.com` plus the static asset CDNs the sign-in page loads (observe the requests; commonly `aadcdn.msauth.net`, `aadcdn.msftauth.net`, `logincdn.msauth.net`). Keep the allow-list explicit rather than permitting `*`.

## Test identities

- Use dedicated **test users** with randomly generated passwords stored outside the repo, same discipline as `.local/test-users.json`.
- Automated password sign-in fails when **MFA, Conditional Access or security defaults** apply. Options: a developer tenant without those policies; Conditional Access exclusion for the test users (a security exception, get approval, scope it narrowly); or TOTP in the test. Do not use the resource-owner password flow to dodge the browser.
- First sign-in may show password-change, consent or "keep me signed in" prompts; sign in once manually per user first.
- Entra's account picker lists the last account and one click signs it in silently. To test a second user choose **Use another account**, and confirm from the page or the application log which identity actually arrived; a user's report of having signed in is not evidence.
- Stage scripts that switch modes must not pre-create the backup folder they later check for, or the first backup is skipped (found in `Set-StudentAuth.ps1`).

## Assertions to rewrite

| Demo assertion today | Becomes |
|---|---|
| `uid` equals `alice` | `uid` claim/derived value equals `alice` |
| `employeeNumber` = `10001` | custom claim or Graph value; user must have `employeeId` set |
| `memberOf` contains `cn=hr-admins,...` | `roles` contains `hr-admins` |
| `eduPersonAffiliation` contains `faculty`/`alum` | `roles` contains `faculty`/`alum` |
| Student `eppn` = `carol@demo.test` | UPN `carol@<verified-domain>` |
| `carol` forbidden on HR `/admin`, Drupal `/demo/editor`, Alumni `/directory`, Student `/Student/Registrar` | unchanged (403) |
| Logout lands on `/`, next visit prompts for login | Entra may sign the user in silently: use a fresh context or `prompt=login`; assert the **app** session ended |
| HR logout also ends Alumni session (CAS back-channel) | **Remove or redefine**: Entra has no back-channel logout |
| Header spoofing against the Student SP cannot create identity | unchanged; keep it |

Update `healthy()` consumers: Alumni `readyz` checked CAS reachability; point it at Entra discovery or drop that check.

## Order of work

1. Entra objects and one pilot user ([entra-setup](./entra-setup.md)).
2. Change one app behind a configuration switch (legacy vs Entra) on a non-production hostname or path.
3. Pilot user passes login, role-allowed page, role-denied page, logout.
4. Update the automated suite; run all five demos; compare to the baseline results JSON from the legacy run.
5. Cutover app by app. Keep the legacy configuration and the legacy IdP registration until the last app and the rollback window have passed.

## Rollback

The switch returns the app to CAS/SAML by configuration. Keep the legacy IdP, service registrations, certificates and the old environment variables until the rollback window closes. For database-linked apps (Alumni `profiles.uid`, Drupal username links) do not migrate keys in the same step as the protocol, so rollback does not need a data migration.

## Evidence to report

Per app: Entra object IDs and redirect URIs (no secrets), the claim mapping used, test results JSON path, and the list of behavior differences (logout, silent re-sign-in, session length, MFA). State plainly which checks ran against a real tenant and which did not.
