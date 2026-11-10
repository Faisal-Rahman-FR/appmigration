<?php
declare(strict_types=1);
// Run inside the image: docker run --rm --entrypoint php <image> /var/www/events/tests/run.php
require __DIR__ . '/../src/Events.php';
$failures = 0;
function check(string $name, bool $ok): void { global $failures; echo ($ok ? 'ok   ' : 'FAIL ') . $name . "\n"; if (!$ok) $failures++; }

check('post-login target keeps an admin path', Events::safeReturnTo('/admin/staff.php') === '/admin/staff.php');
check('post-login target keeps a query string', Events::safeReturnTo('/admin/download.php?file=attendees.csv') === '/admin/download.php?file=attendees.csv');
check('absolute URL is replaced', Events::safeReturnTo('https://evil.example/admin/') === '/admin/');
check('scheme-relative URL is replaced', Events::safeReturnTo('//evil.example/admin/') === '/admin/');
check('path outside /admin is replaced', Events::safeReturnTo('/index.php') === '/admin/');
check('traversal is replaced', Events::safeReturnTo('/admin/../index.php') === '/admin/');
check('CRLF is replaced', Events::safeReturnTo("/admin/\r\nSet-Cookie: x=1") === '/admin/');

putenv('EVENTS_CSRF_KEY=test-key');
check('csrf token is bound to the user', Events::csrf('alice') !== Events::csrf('bob'));
check('csrf token is stable', Events::csrf('alice') === Events::csrf('alice'));
putenv('EVENTS_AUTH=bogus');
$rejected = false;
try { Events::mode(); } catch (RuntimeException) { $rejected = true; }
check('an unknown EVENTS_AUTH fails startup', $rejected);
check('output escaping', Events::e('<b>"x"</b>') === '&lt;b&gt;&quot;x&quot;&lt;/b&gt;');
exit($failures === 0 ? 0 : 1);
