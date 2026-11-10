#!/bin/sh
set -eu
mode="${EVENTS_AUTH:-cas}"
case "$mode" in cas|entra) ;; *) echo "EVENTS_AUTH must be cas or entra" >&2; exit 1;; esac
web=/var/www/events/public_html
# Used for the logout form token; regenerated at every start, which signs everyone out of the CSRF token only.
EVENTS_CSRF_KEY="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
export EVENTS_CSRF_KEY

install -m 644 -o www-data -g www-data "/opt/events/admin.$mode" "$web/admin/.htaccess"
install -m 644 -o www-data -g www-data "/opt/events/exports.$mode" "$web/admin/exports/.htaccess"

if [ "$mode" = entra ]; then
    # Mirror shared hosting: the secret lives in a 0600 file above the web root, never in public_html.
    test -s /run/events-entra-secret.php
    install -d -m 700 -o www-data -g www-data /var/www/events/.config
    install -m 600 -o www-data -g www-data /run/events-entra-secret.php /var/www/events/.config/events-entra.php
else
    # System roots plus the demo CA when one exists (generated certificates in a local run).
    cat /etc/ssl/certs/ca-certificates.crt > /run/events-cas-ca.pem
    if [ -s /tls/ca.crt ]; then cat /tls/ca.crt >> /run/events-cas-ca.pem; fi
    chmod 644 /run/events-cas-ca.pem
fi
exec docker-php-entrypoint "$@"
