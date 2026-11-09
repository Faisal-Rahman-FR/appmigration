# Ingest-only fixtures

These are synthetic exported configurations, **never** mounted into operational CAS or Shibboleth. There are exactly twenty application entries in `../../manifest.yaml`. XML Export envelopes deliberately aggregate configuration surfaces for one application; they are well-formed evidence documents, not deployable IdP files. `broken.json` is the only intentionally malformed file. The LDAP credential, key-looking block, and OIDC secret are conspicuously fake stripping fixtures, never working credentials. Expected inventory must redact them, not copy them into output.

Canonical identities are fixed: hr=UC-01, zoom=UC-02, student=UC-03, drupal=UC-04, alumni=UC-05. Their ingest fixtures carry `useCase` evidence matching the manifest and expected answers. S01–S15 remain additional synthetic integrations, not aliases for the canonical use cases.
