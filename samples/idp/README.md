# Shared authentication services

Seven synthetic users in `ldap/users.json` become real LDAP entries with uid, mail, displayName, employeeNumber, eduPersonAffiliation, eduPersonPrincipalName, givenName, sn and memberOf DNs. Matching groupOfUniqueNames entries contain uniqueMember DNs. The image's actual memberOf overlay computes reverse memberships from these groups. Per-user random passwords and SSHA hashes are generated locally. LDAP and MariaDB have no published ports.

CAS 7.1.6 is built as an actual Apereo Gradle WAR overlay; JSON registry contains just HR and alumni. Attribute release is allowlisted per service, CAS3 validation is used, and back-channel SLO is enabled. Never mount `config/ingest` as the service registry.

Shibboleth IdP 5.1.3 is built from its upstream distribution on Java21/Jetty12 EE10, not an invented official image. The installed default password authentication configuration binds to the same LDAP. All replaced surfaces are supplied: idp/LDAP/nameid properties, attribute resolver, per-RP filter, relying-party policies, filesystem metadata provider, locally generated SP metadata and credentials. Default templates/views/authn flows come from the upstream installation. The local IdP signs responses/assertions, encrypts assertions using each SP key, and supports SAML logout. No remote metadata lookup occurs. Review pinned releases against security advisories before publishing.

Generated metadata is based on locally generated SP certificates and matches the clients exactly. Public origins must use HTTPS on443 with no base path. Regenerate configuration **before first use**, not against existing DB/IdP volumes. TLS terminates at the sole gateway; backends are on a private Compose network. HTTPS browser trust and server trust are real, not bypassed. IdP cookies need SameSite=None for SAML cross-site POST, configured in the IdP container.

SLO is protocol-scoped: CAS global logout notifies participating CAS sessions, while SAML global logout attempts participating SP sessions. CAS logout does not end a Shibboleth session and vice versa. A Shibboleth local SP logout need not end IdP SSO; use the configured global SLO handler when demonstrating federation logout.

The Windows SP metadata advertises **front-channel Redirect SLO only**. The private IdP container deliberately has no outbound Internet route and cannot perform SOAP callbacks to a separate Windows host. Browser-mediated SAML logout traverses the approved HTTPS origins instead. Do not advertise a SOAP endpoint without separately arranging private backend connectivity.
