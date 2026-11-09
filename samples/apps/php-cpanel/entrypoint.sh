#!/bin/sh
set -eu
if [ "${ALUMNI_AUTH:-cas}" = entra ]; then
    # Mirror shared hosting: the secret lives in a 0600 file above the web root, never in public_html.
    test -s /run/alumni-entra-secret.php
    install -d -m 700 -o www-data -g www-data /home/alumni/.config
    install -m 600 -o www-data -g www-data /run/alumni-entra-secret.php /home/alumni/.config/alumni-entra.php
else
    cp /tls/ca.crt /run/cas-ca.crt
    chmod 644 /run/cas-ca.crt
    export CAS_CA_FILE=/run/cas-ca.crt
fi
exec docker-php-entrypoint "$@"
