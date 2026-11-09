# Validation plan (not execution results)

Dependencies were installed after explicit approval. TypeScript checks and all six fixture/manifest tests passed on Node 24.10.0. The dependency lockfile is retained, and npm audit reported zero known vulnerabilities after updating fast-xml-parser to 5.11.2. Browser tests have not run: the Linux Docker engine is unavailable. These fixture results do not prove CAS/SAML login, attribute release, authorization or logout integration.

After consent, from `samples\tests`:
```powershell
npm install
npm run typecheck
npm test
npx playwright install chromium
$env:NODE_EXTRA_CA_CERTS=(Resolve-Path ..\.local\tls\ca.crt)
npm run test:e2e
```

Trust the generated CA in the **browser/OS** store too; Node's extra CA setting does not configure Chromium trust. Never set `ignoreHTTPSErrors`, disable phpCAS certificate checks, or turn off Java trust validation. Default hostnames must resolve through local hosts/DNS to the demo host. API requests also verify TLS. Global setup rejects non-private DNS resolutions. Browser routes reject any origin outside the configured local suite. No CDNs are used.

The standard fixture tests consume the manifest and explicitly named evidence, require twenty unique applications, resolve every path, compare expected records/attribute evidence, verify seven user schemas, redact fake secret values, and require exactly one syntax failure. They are separate from runnable E2E and need no running app. `manifest.yaml` intentionally uses the JSON subset of YAML1.2.

A dedicated contract regression asserts the literal canonical mapping hr=UC-01, zoom=UC-02, student=UC-03, drupal=UC-04, alumni=UC-05 independently of manifest ordering, and requires the same identifiers in ingest evidence and expected answers. Additional integrations must retain synthetic S01–S15 identifiers. Browser report titles use the canonical IDs too.

E2E covers HR, Drupal and alumni login, attributes, positive and negative role pages, data and logout; an additional shared-context test exercises cross-app CAS back-channel SLO. Each test has a fresh browser context. `student.spec.ts` is explicitly **skipped** unless `RUN_DOTNET_TESTS=1`; enable only once Windows IIS/native SP is genuinely configured. Skips are preserved in per-run JSON, never described as passes.

Per-run results appear in `results/<UTC timestamp>/results.json` via the custom reporter. No success file is pre-generated. Authentication traces, video and screenshots are disabled to avoid persisting passwords/tickets/assertions. Restrict results ACLs anyway. Drupal/IdP logout confirmation behavior and upstream login page selectors still need real integration validation; failures are not suppressed.
