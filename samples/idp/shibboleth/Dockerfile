FROM eclipse-temurin:21-jdk-jammy
ARG IDP_VERSION=5.1.3
ARG JETTY_VERSION=12.0.16
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates unzip && rm -rf /var/lib/apt/lists/*
WORKDIR /opt
# Shibboleth has no assumed "official Docker image": build its published distribution.
RUN curl --fail --location --retry 3 "https://shibboleth.net/downloads/identity-provider/archive/${IDP_VERSION}/shibboleth-identity-provider-${IDP_VERSION}.tar.gz" -o idp.tar.gz \
 && echo "cc72f0b15fda49b43bdd38cef3bdc62cbe01684b59c3d024b5de1ffdba42206e  idp.tar.gz" | sha256sum -c - \
 && mkdir /opt/idp-dist && tar xzf idp.tar.gz -C /opt/idp-dist --strip-components=1 && rm idp.tar.gz \
 && curl --fail --location --retry 3 "https://repo.maven.apache.org/maven2/org/eclipse/jetty/jetty-home/${JETTY_VERSION}/jetty-home-${JETTY_VERSION}.tar.gz" -o jetty.tar.gz \
 && tar xzf jetty.tar.gz && mv "jetty-home-${JETTY_VERSION}" jetty-home && rm jetty.tar.gz
ENV JETTY_HOME=/opt/jetty-home JETTY_BASE=/opt/jetty-base
RUN mkdir -p /opt/jetty-base && cd /opt/jetty-base && java -jar /opt/jetty-home/start.jar --add-modules=server,http,http-forwarded,ee10-deploy,ee10-jsp,ee10-jstl,ee10-annotations,logging-jetty
COPY jetty/idp.xml /opt/jetty-base/webapps/idp.xml
COPY health-pages/ /opt/idp-dist/webapp/
COPY entrypoint.sh /opt/demo/entrypoint.sh
RUN sed -i 's/\r$//' /opt/demo/entrypoint.sh && chmod +x /opt/demo/entrypoint.sh
EXPOSE 8080
ENTRYPOINT ["/opt/demo/entrypoint.sh"]
