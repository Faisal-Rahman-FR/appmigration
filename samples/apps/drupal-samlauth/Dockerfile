FROM composer:2.8.8 AS composer
FROM php:8.3.20-apache-bookworm
RUN apt-get update && apt-get install -y --no-install-recommends libpng-dev libjpeg62-turbo-dev libfreetype6-dev libzip-dev libxml2-dev libcurl4-openssl-dev default-mysql-client unzip git curl && docker-php-ext-configure gd --with-freetype --with-jpeg && docker-php-ext-install gd zip pdo_mysql opcache dom curl && a2enmod rewrite headers && rm -rf /var/lib/apt/lists/*
COPY --from=composer /usr/bin/composer /usr/local/bin/composer
WORKDIR /opt/drupal
COPY composer.json .
RUN COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --no-interaction --prefer-dist --optimize-autoloader
COPY config-sync /opt/demo/config-sync
COPY bootstrap /opt/demo/bootstrap
COPY modules/demo_portal web/modules/custom/demo_portal
COPY settings.php web/sites/default/settings.php
COPY apache.conf /etc/apache2/conf-enabled/demo.conf
COPY health.php /opt/demo/health.php
COPY services.yml /opt/demo/services.yml
COPY entrypoint.sh /opt/demo/entrypoint.sh
RUN sed -i 's|/var/www/html|/opt/drupal/web|g' /etc/apache2/sites-available/000-default.conf && sed -i 's/\r$//' /opt/demo/entrypoint.sh && chmod +x /opt/demo/entrypoint.sh && mkdir -p web/sites/default/files && chown -R www-data:www-data web/sites/default/files
ENV APACHE_DOCUMENT_ROOT=/opt/drupal/web
EXPOSE 80
ENTRYPOINT ["/opt/demo/entrypoint.sh"]
CMD ["apache2-foreground"]
