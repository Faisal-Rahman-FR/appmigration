#!/bin/bash
set -eu
# The generated password uses base64url characters only.
[[ "$DB_PASSWORD" =~ ^[A-Za-z0-9_-]+$ ]] || exit 1
mariadb --protocol=socket -uroot -p"$MARIADB_ROOT_PASSWORD" <<SQL
CREATE USER IF NOT EXISTS 'demo'@'%' IDENTIFIED BY '$DB_PASSWORD';
GRANT SELECT ON alumni.* TO 'demo'@'%';
GRANT INSERT, UPDATE, DELETE ON alumni.cas_sessions TO 'demo'@'%';
GRANT ALL PRIVILEGES ON drupal.* TO 'demo'@'%';
SQL
