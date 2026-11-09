#!/bin/sh
set -eu
mkdir -p /run/demo-readable/tls
cp /run/demo/settings.secrets.php /run/demo-readable/settings.secrets.php
for file in drupal.crt drupal.key idp-signing.crt; do cp "/tls/$file" "/run/demo-readable/tls/$file"; done
if [ "${DRUPAL_AUTH:-shibboleth}" = entra ]; then cp /run/demo/entra-idp-signing.crt /run/demo-readable/tls/entra-idp-signing.crt; fi
chown -R www-data:www-data /run/demo-readable
chmod 700 /run/demo-readable /run/demo-readable/tls
chmod 600 /run/demo-readable/settings.secrets.php /run/demo-readable/tls/*
if [ "${DEMO_BOOTSTRAP:-0}" = "1" ]; then
  # Composer packages and Drush are already in the image. No runtime download.
  if ! vendor/bin/drush status --field=bootstrap 2>/dev/null | grep -q Successful; then
    vendor/bin/drush site:install standard --yes \
      --db-url="mysql://demo:${DB_PASSWORD}@db/drupal" \
      --site-name="Research Publishing" --account-name=local-admin \
      --account-pass="$DRUPAL_ADMIN_PASSWORD" --account-mail=local-admin@demo.test
  fi
  vendor/bin/drush pm:enable samlauth demo_portal --yes
  vendor/bin/drush config:import --partial --source=/opt/demo/config-sync --yes
  vendor/bin/drush php:script /opt/demo/bootstrap/seed.php
  vendor/bin/drush cache:rebuild
  exit 0
fi
exec docker-php-entrypoint "$@"
