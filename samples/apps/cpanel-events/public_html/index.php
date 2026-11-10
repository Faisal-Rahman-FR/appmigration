<?php
declare(strict_types=1);
require_once __DIR__ . '/../src/Events.php';
Events::headers();
$events = Events::pdo()->query("SELECT title, starts_on, venue FROM events WHERE status = 'approved' ORDER BY starts_on")->fetchAll();
?><!doctype html><html lang="en"><head><meta charset="utf-8"><title>Campus Events</title></head><body>
<h1>Campus Events</h1>
<p>Public calendar. <a href="/admin/">Staff sign in</a></p>
<ul data-testid="public-events">
<?php foreach ($events as $event): ?>
  <li><?= Events::e($event['title']) ?> — <?= Events::e($event['starts_on']) ?>, <?= Events::e($event['venue']) ?></li>
<?php endforeach; ?>
</ul>
</body></html>
