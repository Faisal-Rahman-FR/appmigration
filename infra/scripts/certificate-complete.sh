#!/bin/bash
set -euo pipefail
umask 077
trap 'echo "DEMO_STAGE_FAILED: certificate completion; inspect restricted ACME/Compose logs." >&2' ERR
: "${DEMO_DOMAIN:?}" "${DEMO_ARTIFACT_TRANSFER:?}"
if [ "$DEMO_ARTIFACT_TRANSFER" = storage ]; then : "${DEMO_STORAGE:?}"; fi
cd /srv/idpdemo/source/samples
if ! openssl verify -verify_hostname "cas.$DEMO_DOMAIN" \
  -untrusted .local/tls/gateway.crt .local/tls/gateway.crt >/dev/null 2>&1 \
  || ! openssl x509 -in .local/tls/gateway.crt -noout -checkend 604800 >/dev/null 2>&1; then
  sh /srv/idpdemo/acme/acme.sh --home /srv/idpdemo/acme-state --server letsencrypt --renew \
    --yes-I-know-dns-manual-mode-enough-go-ahead-please -d "*.$DEMO_DOMAIN" > /srv/idpdemo/acme-complete.log 2>&1
  sh /srv/idpdemo/acme/acme.sh --home /srv/idpdemo/acme-state --install-cert -d "*.$DEMO_DOMAIN" \
    --key-file "$PWD/.local/tls/gateway.key" --fullchain-file "$PWD/.local/tls/gateway.crt" > /srv/idpdemo/acme-install.log 2>&1
fi
openssl x509 -in .local/tls/gateway.crt -noout -checkend 604800
for app in cas idp hr drupal alumni events; do
  addresses=$(getent ahostsv4 "$app.$DEMO_DOMAIN" | awk '{print $1}' | sort -u)
  test -n "$addresses"
done
docker compose --env-file .local/demo.env -f compose.yaml -f /srv/idpdemo/cloud-compose.yaml pull --ignore-buildable > /srv/idpdemo/compose-pull.log 2>&1
docker compose --env-file .local/demo.env -f compose.yaml -f /srv/idpdemo/cloud-compose.yaml up -d --no-build --pull never --wait --wait-timeout 900 > /srv/idpdemo/compose-start.log 2>&1
docker compose --env-file .local/demo.env -f compose.yaml -f /srv/idpdemo/cloud-compose.yaml exec -T gateway nginx -t
docker compose --env-file .local/demo.env -f compose.yaml -f /srv/idpdemo/cloud-compose.yaml exec -T gateway nginx -s reload
mkdir -p /srv/idpdemo/windows-package/generated/tls /srv/idpdemo/windows-package/generated/windows
cp .local/windows/* /srv/idpdemo/windows-package/generated/windows/
cp .local/tls/{student.key,student.crt,ca.crt} /srv/idpdemo/windows-package/generated/tls/
cp .local/idp-metadata.xml /srv/idpdemo/windows-package/generated/
mkdir -p /srv/idpdemo/windows-package/app
cp -R apps/dotnet-shibsp/. /srv/idpdemo/windows-package/app/
openssl pkcs12 -export -out /srv/idpdemo/windows-package/transport.pfx \
  -inkey .local/tls/gateway.key -in .local/tls/gateway.crt -passout pass:
tar czf /srv/idpdemo/windows-package.tgz -C /srv/idpdemo/windows-package .
if [ "$DEMO_ARTIFACT_TRANSFER" = storage ]; then
storage_token=$(curl --noproxy '*' -fsS --get -H Metadata:true \
  'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01' \
  --data-urlencode 'resource=https://storage.azure.com/' | jq -er .access_token)
curl -fsS --retry 5 --retry-all-errors -X PUT -H "Authorization: Bearer $storage_token" \
  -H 'x-ms-version: 2023-11-03' -H 'x-ms-blob-type: BlockBlob' --data-binary @/srv/idpdemo/windows-package.tgz \
  https://$DEMO_STORAGE.blob.core.windows.net/windows-handoff/windows-package.tgz -o /dev/null
unset storage_token
fi
echo 'DEMO_STAGE_OK: public TLS installed; Compose healthy; Windows handoff package prepared.'
