<?php
declare(strict_types=1);
header('Content-Type: application/json');
if (parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH) === '/healthz') exit('{"status":"ok"}');
try {
  $autoloader = require '/opt/drupal/vendor/autoload.php';
  $request = \Symfony\Component\HttpFoundation\Request::create(getenv('DRUPAL_ORIGIN').'/readyz');
  $kernel = \Drupal\Core\DrupalKernel::createFromRequest($request, $autoloader, 'prod', FALSE, '/opt/drupal/web');
  $kernel->boot();
  \Drupal::database()->query('SELECT 1')->fetchField();
  if (!\Drupal::state()->get('demo_portal.seeded')) throw new \RuntimeException('Bootstrap incomplete');
  if (!is_readable('/run/demo-readable/tls/idp-signing.crt') || !is_readable('/run/demo-readable/tls/drupal.key')) throw new \RuntimeException('SAML keys absent');
  exit('{"status":"ready"}');
} catch (\Throwable $e) {
  http_response_code(503); error_log($e->getMessage()); exit('{"status":"notReady"}');
}
