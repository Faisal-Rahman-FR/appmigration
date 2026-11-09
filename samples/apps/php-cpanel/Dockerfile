FROM php:8.3.20-fpm-bookworm
RUN apt-get update && apt-get install -y --no-install-recommends libcurl4-openssl-dev libxml2-dev curl && docker-php-ext-install curl dom pdo_mysql && rm -rf /var/lib/apt/lists/*
WORKDIR /home/alumni
COPY vendor vendor
COPY src src
COPY public_html public_html
COPY fpm.conf /usr/local/etc/php-fpm.d/zz-demo.conf
COPY php.ini /usr/local/etc/php/conf.d/demo.ini
COPY entrypoint.sh /home/alumni/entrypoint.sh
RUN mkdir -p /var/lib/php/sessions && chown -R www-data:www-data /home/alumni /var/lib/php/sessions && chmod 700 /var/lib/php/sessions
RUN sed -i 's/\r$//' /home/alumni/entrypoint.sh && chmod +x /home/alumni/entrypoint.sh
EXPOSE 9000
ENTRYPOINT ["/home/alumni/entrypoint.sh"]
CMD ["php-fpm"]
