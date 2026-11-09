#!/bin/sh
set -eu
cp "$JAVA_HOME/lib/security/cacerts" /app/truststore
keytool -importcert -noprompt -alias demo-ca -file /tls/ca.crt -keystore /app/truststore -storepass changeit
cp /etc/cas/config/cas.properties /app/cas.properties
rm -rf /app/services
cp -R /etc/cas/services /app/services
chown -R cas:cas /app
chmod 600 /app/cas.properties
exec gosu cas java -Djavax.net.ssl.trustStore=/app/truststore -Djavax.net.ssl.trustStorePassword=changeit -Xmx1536m -jar /app/cas.war --server.port=8080 --server.ssl.enabled=false --server.tomcat.basedir=/app/tomcat --spring.config.additional-location=file:/app/cas.properties --cas.service-registry.json.location=file:/app/services
