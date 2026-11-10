#!/bin/bash
set -euo pipefail
umask 077
trap 'echo "DEMO_STAGE_FAILED: Linux bootstrap; inspect /srv/idpdemo/bootstrap.log without exposing credentials." >&2' ERR
: "${DEMO_DOMAIN:?}" "${DEMO_ARTIFACT_TRANSFER:?}"
if [ "$DEMO_ARTIFACT_TRANSFER" = storage ]; then : "${DEMO_STORAGE:?}" "${DEMO_VAULT:?}"; fi
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends ca-certificates curl gnupg jq openssl xz-utils git
disk=/dev/disk/azure/scsi1/lun0
test -b "$disk"
if ! blkid "$disk" >/dev/null 2>&1; then
  test "$(lsblk --noheadings --output TYPE "$disk" | wc -l)" -eq 1
  mkfs.ext4 -q "$disk"
fi
test "$(blkid -s TYPE -o value "$disk")" = ext4
mkdir -p /srv/idpdemo
uuid=$(blkid -s UUID -o value "$disk")
if ! grep -q "UUID=$uuid " /etc/fstab; then
  printf 'UUID=%s /srv/idpdemo ext4 defaults,nofail 0 2\n' "$uuid" >> /etc/fstab
fi
mountpoint -q /srv/idpdemo || mount /srv/idpdemo
chmod 700 /srv/idpdemo
exec 3>&1
exec >>/srv/idpdemo/bootstrap.log 2>&1
if ! command -v docker >/dev/null; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod 644 /etc/apt/keyrings/docker.asc
  echo 'deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu jammy stable' > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl stop docker
  printf '{"data-root":"/srv/idpdemo/docker"}\n' > /etc/docker/daemon.json
  systemctl enable --now docker
fi
if ! command -v node >/dev/null || ! node --version | grep -q '^v24\.'; then
  mkdir -p /srv/idpdemo/tools
  cd /srv/idpdemo/tools
  curl -fsSLO https://nodejs.org/dist/v24.10.0/node-v24.10.0-linux-x64.tar.xz
  curl -fsSLO https://nodejs.org/dist/v24.10.0/SHASUMS256.txt
  grep ' node-v24.10.0-linux-x64.tar.xz$' SHASUMS256.txt | sha256sum --check -
  tar xJf node-v24.10.0-linux-x64.tar.xz --strip-components=1 -C /usr/local
fi
if [ "$DEMO_ARTIFACT_TRANSFER" = storage ]; then
storage_token=$(curl --noproxy '*' -fsS --get -H Metadata:true \
  'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01' \
  --data-urlencode 'resource=https://storage.azure.com/' | jq -er .access_token)
mkdir -p /srv/idpdemo/source
# A new managed identity's blob role can take several minutes to propagate.
for attempt in $(seq 1 60); do
  status=$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' -I -H "Authorization: Bearer $storage_token" -H 'x-ms-version: 2023-11-03' \
    "https://$DEMO_STORAGE.blob.core.windows.net/artifacts/source.tgz" || true)
  test "$status" = 200 && break
  sleep 15
done
test "$status" = 200
curl -fsS --retry 5 --retry-all-errors -H "Authorization: Bearer $storage_token" -H 'x-ms-version: 2023-11-03' \
  https://$DEMO_STORAGE.blob.core.windows.net/artifacts/source.tgz -o /srv/idpdemo/source.tgz
unset storage_token
else
  # Direct mode: the workstation delivered the archive through the VM command channel (hash verified by the orchestrator).
  mkdir -p /srv/idpdemo/source
  test -s /var/tmp/idpdemo-upload/source.tgz
  cp /var/tmp/idpdemo-upload/source.tgz /srv/idpdemo/source.tgz
fi
tar xzf /srv/idpdemo/source.tgz -C /srv/idpdemo/source
cd /srv/idpdemo/source/samples
sed -i 's/\r$//' database/02-grants.sh
if ! test -f .local/demo.env; then
  for app in cas idp hr drupal alumni events student; do
    printf '%s_ORIGIN=https://%s.%s\n' "$(echo "$app" | tr '[:lower:]' '[:upper:]')" "$app" "$DEMO_DOMAIN"
  done > /srv/idpdemo/cloud.env
  printf 'PUBLIC_BIND_IP=0.0.0.0\n' >> /srv/idpdemo/cloud.env
  node scripts/initialize.mjs /srv/idpdemo/cloud.env
fi
cat > /srv/idpdemo/cloud-compose.yaml <<'YAML'
services:
  alumni:
    environment:
      CAS_CA_FILE: /etc/ssl/certs/public-roots.crt
    volumes:
      - /etc/ssl/certs/ca-certificates.crt:/etc/ssl/certs/public-roots.crt:ro
YAML
docker compose --env-file .local/demo.env -f compose.yaml -f /srv/idpdemo/cloud-compose.yaml config --quiet
docker compose --env-file .local/demo.env -f compose.yaml -f /srv/idpdemo/cloud-compose.yaml build
docker run --rm -v "$PWD/apps/java-cas:/work" -w /work maven:3.9.9-eclipse-temurin-21 mvn -B test
cd tests
npm ci
npm run typecheck
npm test
cd ..
if [ "$DEMO_ARTIFACT_TRANSFER" = storage ]; then
vault_token=$(curl --noproxy '*' -fsS --get -H Metadata:true \
  'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01' \
  --data-urlencode 'resource=https://vault.azure.net' | jq -er .access_token)
jq -n --rawfile value .local/test-users.json '{value:$value}' > /srv/idpdemo/test-users-secret.json
curl -fsS --retry 5 --retry-all-errors -X PUT -H "Authorization: Bearer $vault_token" -H 'Content-Type: application/json' \
  --data-binary @/srv/idpdemo/test-users-secret.json \
  "https://$DEMO_VAULT.vault.azure.net/secrets/synthetic-test-users?api-version=7.4" -o /dev/null
rm /srv/idpdemo/test-users-secret.json
unset vault_token
fi
echo 'DEMO_STAGE_OK: images built, Java/unit/fixture checks passed; services await DNS and public TLS.' > /srv/idpdemo/build-status.txt
cat /srv/idpdemo/build-status.txt >&3
