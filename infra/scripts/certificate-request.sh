#!/bin/bash
set -euo pipefail
umask 077
trap 'echo "DEMO_STAGE_FAILED: certificate request" >&2' ERR
: "${DEMO_DOMAIN:?}"
cd /srv/idpdemo
test -f build-status.txt
if ! test -d acme; then
  git clone --quiet --depth 1 --branch 3.1.3 https://github.com/acmesh-official/acme.sh.git acme
fi
account_args=()
if test -n "${DEMO_ACME_EMAIL:-}"; then account_args=(--accountemail "$DEMO_ACME_EMAIL"); fi
trap - ERR
set +e
sh acme/acme.sh --home /srv/idpdemo/acme-state --server letsencrypt --issue --dns "${account_args[@]}" \
  --yes-I-know-dns-manual-mode-enough-go-ahead-please --keylength 2048 -d "*.$DEMO_DOMAIN" \
  > /srv/idpdemo/acme-request.log 2>&1
result=$?
set -e
trap 'echo "DEMO_STAGE_FAILED: certificate request" >&2' ERR
if test "$result" -ne 0 && ! grep -q 'TXT value' /srv/idpdemo/acme-request.log; then
  echo 'DEMO_STAGE_FAILED: ACME did not produce a DNS challenge; inspect the restricted ACME log.' >&2
  exit 1
fi
grep -E 'Domain:|TXT value:' /srv/idpdemo/acme-request.log || test "$result" -eq 0
echo 'DEMO_STAGE_OK: create the displayed DNS TXT record, then run CertificateComplete; no trusted certificate is claimed yet.'
