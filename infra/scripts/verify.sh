#!/bin/bash
set -euo pipefail
umask 077
trap 'echo "DEMO_STAGE_FAILED: runtime verification could not complete; inspect protected logs under /srv/idpdemo." >&2' ERR
: "${DEMO_DOMAIN:?}" "${DEMO_LINUX_IP:?}" "${DEMO_WINDOWS_IP:?}"
cd /srv/idpdemo/source/samples
if ! grep -q '# idpdemo-hosts' /etc/hosts; then
  echo "$DEMO_LINUX_IP cas.$DEMO_DOMAIN idp.$DEMO_DOMAIN hr.$DEMO_DOMAIN drupal.$DEMO_DOMAIN alumni.$DEMO_DOMAIN events.$DEMO_DOMAIN # idpdemo-hosts" >> /etc/hosts
  echo "$DEMO_WINDOWS_IP student.$DEMO_DOMAIN # idpdemo-hosts" >> /etc/hosts
fi
for app in cas idp hr drupal alumni events student; do
  curl --fail --silent --show-error --max-time 30 "https://$app.$DEMO_DOMAIN/readyz" > /dev/null
done
if test "${DEMO_RUN_BROWSER_TESTS:-1}" != 1; then
  echo 'DEMO_STAGE_OK: all seven readiness endpoints passed; browser tests were skipped by configuration.'
  exit 0
fi
set -a
source .local/demo.env
set +a
cd tests
npx playwright install --with-deps chromium > /srv/idpdemo/browser-install.log 2>&1
export RUN_DOTNET_TESTS=1
# Failing tests are reported, not fatal: the ERR trap fires on any non-zero command even with errexit off, so lift it around the run.
trap - ERR
set +e
npm run test:e2e > /srv/idpdemo/browser-tests.log 2>&1
tests_exit=$?
set -e
trap 'echo "DEMO_STAGE_FAILED: runtime verification could not complete; inspect protected logs under /srv/idpdemo." >&2' ERR
echo "DEMO_TESTS_EXIT=$tests_exit"
grep -E '^ +[0-9]+ (passed|failed|skipped|flaky|did not run)' /srv/idpdemo/browser-tests.log | sed 's/^ *//' | sed 's/^/DEMO_TESTS_SUMMARY: /' || true
sed -n '/^ *[0-9]* failed/,/^ *[0-9]* passed/p' /srv/idpdemo/browser-tests.log | grep -E '^ +(specs/|[0-9]+ failed)' | sed 's/^ *//' | sed 's/^/DEMO_TESTS_FAILED: /' || true
echo 'DEMO_STAGE_OK: all seven readiness endpoints passed; browser test results are reported in DEMO_TESTS lines. Per-run JSON is retained under tests/results.'
