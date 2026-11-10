FROM php:8.3.20-apache-bookworm
# libapache2-mod-auth-cas is the Debian build of Apereo's mod_auth_cas; a cPanel host would have to provide it (EasyApache or the host's support).
RUN apt-get update && apt-get install -y --no-install-recommends libapache2-mod-auth-cas ca-certificates \
 && docker-php-ext-install pdo_mysql \
 && a2enmod rewrite headers auth_cas \
 && rm -rf /var/lib/apt/lists/* \
 && test -d /var/cache/apache2/mod_auth_cas
ENV APACHE_DOCUMENT_ROOT=/var/www/events/public_html
WORKDIR /var/www/events
# Pinned, hash-verified libraries are reused from the Alumni sample instead of being duplicated (see vendor/PROVENANCE.json there).
COPY --from=alumni vendor vendor
COPY --from=alumni src/EntraProfile.php src/EntraProfile.php
COPY src src
COPY tests tests
COPY public_html public_html
COPY apache.conf /etc/apache2/conf-enabled/events.conf
COPY php.ini /usr/local/etc/php/conf.d/events.ini
COPY htaccess /opt/events/
COPY entrypoint.sh /opt/events/entrypoint.sh
RUN sed -ri 's!/var/www/html!/var/www/events/public_html!g' /etc/apache2/sites-available/*.conf \
 && sed -i 's/\r$//' /opt/events/entrypoint.sh && chmod +x /opt/events/entrypoint.sh \
 && mkdir -p /var/lib/php/sessions /var/www/events/.config \
 && chown -R www-data:www-data /var/lib/php/sessions /var/www/events/public_html /var/www/events/.config \
 && chmod 700 /var/lib/php/sessions
EXPOSE 80
ENTRYPOINT ["/opt/events/entrypoint.sh"]
CMD ["apache2-foreground"]
