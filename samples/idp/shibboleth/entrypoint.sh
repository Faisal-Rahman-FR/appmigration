#!/bin/bash
set -euo pipefail
if [ ! -f /opt/shibboleth-idp/.demo-installed ]; then
  cd /opt/idp-dist
  ./bin/install.sh --targetDir /opt/shibboleth-idp \
    --hostName "$IDP_HOST" --entityID "$IDP_ORIGIN/idp/shibboleth" \
    --scope demo.test --sealerPassword "$IDP_SEALER_PASSWORD" --keystorePassword "$IDP_SEALER_PASSWORD" --noPrompt
  touch /opt/shibboleth-idp/.demo-installed
fi
cp /run/demo/conf/* /opt/shibboleth-idp/conf/
# The resolver supplies short-name encoders; default OID rules would duplicate them.
sed -i '\|<value>%{idp.home}/conf/attributes/default-rules.xml</value>|d' /opt/shibboleth-idp/conf/services.xml
cp /run/demo/metadata/sp-metadata.xml /opt/shibboleth-idp/metadata/sp-metadata.xml
cp /run/idp-metadata.xml /opt/shibboleth-idp/metadata/idp-metadata.xml
for type in signing encryption; do
  cp "/tls/idp-${type}.crt" "/opt/shibboleth-idp/credentials/idp-${type}.crt"
  cp "/tls/idp-${type}.key" "/opt/shibboleth-idp/credentials/idp-${type}.key"
done
cd "$JETTY_BASE"
exec java -Xmx1024m -Didp.home=/opt/shibboleth-idp -jar "$JETTY_HOME/start.jar" jetty.http.host=0.0.0.0 jetty.http.port=8080
