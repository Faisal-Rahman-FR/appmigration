<?php
$databases['default']['default'] = [
  'driver'=>'mysql', 'database'=>'drupal', 'username'=>'demo',
  'password'=>getenv('DB_PASSWORD'), 'host'=>'db', 'port'=>3306,
  'prefix'=>'', 'namespace'=>'Drupal\\mysql\\Driver\\Database\\mysql',
  'autoload'=>'core/modules/mysql/src/Driver/Database/mysql/',
];
require '/run/demo-readable/settings.secrets.php';
$settings['config_sync_directory'] = '/opt/demo/config-sync';
$settings['trusted_host_patterns'] = ['^'.preg_quote(parse_url(getenv('DRUPAL_ORIGIN'), PHP_URL_HOST), '/').'$'];
$settings['reverse_proxy'] = TRUE;
$settings['reverse_proxy_addresses'] = [gethostbyname('gateway')];
$settings['reverse_proxy_trusted_headers'] = \Symfony\Component\HttpFoundation\Request::HEADER_X_FORWARDED_FOR | \Symfony\Component\HttpFoundation\Request::HEADER_X_FORWARDED_HOST | \Symfony\Component\HttpFoundation\Request::HEADER_X_FORWARDED_PORT | \Symfony\Component\HttpFoundation\Request::HEADER_X_FORWARDED_PROTO;
$settings['file_public_path'] = 'sites/default/files';
$settings['update_free_access'] = FALSE;
$settings['container_yamls'][] = '/opt/demo/services.yml';
$config['system.site']['page']['front'] = '/demo';
$config['samlauth.authentication']['sp_entity_id'] = getenv('DRUPAL_ORIGIN').'/saml/metadata';
$config['samlauth.authentication']['sp_x509_certificate'] = file_get_contents('/run/demo-readable/tls/drupal.crt');
$config['samlauth.authentication']['sp_private_key'] = file_get_contents('/run/demo-readable/tls/drupal.key');
$drupalAuth = getenv('DRUPAL_AUTH') ?: 'shibboleth';
if (!in_array($drupalAuth, ['shibboleth', 'entra'], true)) throw new RuntimeException('DRUPAL_AUTH must be shibboleth or entra.');
if ($drupalAuth === 'entra') {
  $tenant = (string)getenv('ENTRA_TENANT_ID');
  if (!preg_match('/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i', $tenant)) throw new RuntimeException('ENTRA_TENANT_ID must be the tenant GUID.');
  $config['samlauth.authentication']['idp_entity_id'] = "https://sts.windows.net/$tenant/";
  $config['samlauth.authentication']['idp_single_sign_on_service'] = "https://login.microsoftonline.com/$tenant/saml2";
  $config['samlauth.authentication']['idp_single_log_out_service'] = "https://login.microsoftonline.com/$tenant/saml2";
  $config['samlauth.authentication']['idp_certs'] = [file_get_contents('/run/demo-readable/tls/entra-idp-signing.crt')];
  $config['samlauth.authentication']['login_link_title'] = 'Sign in with Microsoft Entra ID';
  // Entra signs the assertion (not the response) by default, does not encrypt without Token encryption, and rejects a requested AuthnContext it did not perform.
  $config['samlauth.authentication']['security_messages_sign'] = FALSE;
  $config['samlauth.authentication']['security_assertions_encrypt'] = FALSE;
  $config['samlauth.authentication']['security_request_authn_context'] = FALSE;
} else {
  $config['samlauth.authentication']['idp_entity_id'] = getenv('IDP_ORIGIN').'/idp/shibboleth';
  $config['samlauth.authentication']['idp_single_sign_on_service'] = getenv('IDP_ORIGIN').'/idp/profile/SAML2/Redirect/SSO';
  $config['samlauth.authentication']['idp_single_log_out_service'] = getenv('IDP_ORIGIN').'/idp/profile/SAML2/Redirect/SLO';
  $config['samlauth.authentication']['idp_certs'] = [file_get_contents('/run/demo-readable/tls/idp-signing.crt')];
}
