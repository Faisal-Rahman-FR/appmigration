FROM httpd:2.4.63-bookworm
COPY httpd.conf /usr/local/apache2/conf/httpd.conf
COPY public_html /home/alumni/public_html
RUN chown -R www-data:www-data /home/alumni
