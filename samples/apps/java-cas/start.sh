#!/bin/sh
set -eu
if [ "${DEMO_AUTH:-cas}" = entra ]; then
    exec gosu hr java -jar /app/app.jar
fi
cp "$JAVA_HOME/lib/security/cacerts" /app/truststore
keytool -importcert -noprompt -alias demo-ca -file /tls/ca.crt -keystore /app/truststore -storepass changeit
chown hr:hr /app/truststore
exec gosu hr java -Djavax.net.ssl.trustStore=/app/truststore -Djavax.net.ssl.trustStorePassword=changeit -jar /app/app.jar
