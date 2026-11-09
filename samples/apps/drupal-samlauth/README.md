# UC-04 — Drupal Research Publishing

Drupal **10.6.20**, samlauth **3.14.0**, Drush **12.5.3**, PHP 8.3. The image performs real Composer dependency resolution at build time. An offline one-shot Compose bootstrap installs the standard Drupal profile, enables samlauth/custom module, partially imports committed real config-sync YAML, then idempotently seeds all seven usernames and two articles. No fabricated site UUIDs or fake exported core configuration. The committed YAML is an intentional **partial configuration import**, not a portable complete site export. The installer generates core/site-specific config in MariaDB.

Identity matching is **username only**, not email. New account creation is disabled. User roles synchronize on every validated samlauth USER_SYNC event: faculty/staff gain editor; other users lose editor. SAML requests, responses and assertions are signed; in Shibboleth mode assertions must be encrypted to the generated Drupal key. Environment settings supply SP/IdP identifiers and certificates without exporting private keys to config-sync.

`docker compose --env-file .local/demo.env up -d --build` starts the installer before Drupal becomes ready. Inspect `docker compose --env-file .local/demo.env logs drupal-bootstrap` for failures. The generated `local-admin` credential is for recovery only; test accounts have randomized, unknown local passwords and use LDAP through SAML. Runtime does not fetch metadata or Composer packages. `/healthz` is direct anonymous liveness; `/readyz` checks DB/seed state and SAML credential availability.

`/demo/profile` shows identity/attributes; `/demo/editor` enforces the editor role. Logout uses samlauth's CSRF-aware logout route and Shibboleth SAML SLO. SLO is not proof every SP session on the Internet has ended. Browsers must trust the generated CA; cross-site SAML POST requires secure SameSite=None session cookies. Review pinned releases and advisories before public exposure. The Shibboleth path passed its Playwright specs on the VM during the Entra rollback check (2026-11-05); the Entra path below has been run against a real tenant.

## Identity provider: Shibboleth (default) or Microsoft Entra ID

`DRUPAL_AUTH=shibboleth` is the default and keeps everything above unchanged. `DRUPAL_AUTH=entra` (with `ENTRA_TENANT_ID`, the tenant GUID) makes `settings.php` point samlauth at Entra's SAML endpoints and trust the application's signing certificate. An unknown value or a malformed tenant ID fails startup.

- **Entra application:** a SAML enterprise application with Identifier `<DRUPAL_ORIGIN>/saml/metadata`, reply URL `<DRUPAL_ORIGIN>/saml/acs`, logout URL `<DRUPAL_ORIGIN>/saml/sls`, assignment required, and app roles `member`, `faculty`, `staff`.
- **Claims:** `uid` (= `mailnickname`, links the existing local account), `mail`, `displayName`, `appRoles` (= assigned roles). `RoleSync` grants `editor` for `faculty` or `staff` and removes it otherwise.
- **Certificate:** put the app's public signing certificate (from its federation metadata) at `.local/drupal/entra-idp-signing.crt`; `entrypoint.sh` copies it into the container. It is public, but keep it 0600 like the other files. No client secret exists in this pattern.
- **Overrides in Entra mode:** `security_messages_sign`, `security_assertions_encrypt` and `security_request_authn_context` are `false`; assertions must still be signed and `strict` stays on.
- **Rollback:** recreate only Drupal without the variables: `docker compose --env-file .local/demo.env up -d --no-deps --force-recreate drupal`.

See the [validation report](../../docs/DRUPAL-ENTRA-VALIDATION.md) for what was and was not proven. Run `tests/specs/drupal-entra.spec.ts` with `DRUPAL_AUTH=entra`; the authenticated cases need `ENTRA_AUTOMATED_LOGIN=1` and a user without MFA.
