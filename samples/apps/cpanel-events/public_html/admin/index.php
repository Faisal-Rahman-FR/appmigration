<?php
declare(strict_types=1);
require_once __DIR__ . '/../../src/Events.php';
$user = Events::requireStaff();
$pdo = Events::pdo();
if ($user['role'] === 'admin') {
    $events = $pdo->query('SELECT id, title, starts_on, venue, status, organizer_uid FROM events ORDER BY starts_on')->fetchAll();
} else {
    $query = $pdo->prepare('SELECT id, title, starts_on, venue, status, organizer_uid FROM events WHERE organizer_uid = :uid ORDER BY starts_on');
    $query->execute(['uid' => $user['uid']]);
    $events = $query->fetchAll();
}
$token = Events::csrf($user['uid']);
?><!doctype html><html lang="en"><head><meta charset="utf-8"><title>Events admin</title></head><body>
<h1>Events admin</h1>
<p data-testid="uid"><?= Events::e($user['uid']) ?></p>
<p data-testid="role"><?= Events::e($user['role']) ?></p>
<p data-testid="name"><?= Events::e($user['name']) ?></p>
<table data-testid="events"><tr><th>Event</th><th>Date</th><th>Organizer</th><th>Status</th><th></th></tr>
<?php foreach ($events as $event): ?>
<tr><td><?= Events::e($event['title']) ?></td><td><?= Events::e($event['starts_on']) ?></td><td><?= Events::e($event['organizer_uid']) ?></td><td><?= Events::e($event['status']) ?></td>
<td><?php if ($user['role'] === 'admin'): ?>
<form method="post" action="/admin/status.php"><input type="hidden" name="csrf" value="<?= Events::e($token) ?>"><input type="hidden" name="id" value="<?= (int)$event['id'] ?>">
<button name="status" value="<?= $event['status'] === 'approved' ? 'cancelled' : 'approved' ?>"><?= $event['status'] === 'approved' ? 'Cancel' : 'Approve' ?></button></form>
<?php endif; ?></td></tr>
<?php endforeach; ?>
</table>
<?php if ($user['role'] === 'admin'): ?>
<p><a href="/admin/staff.php">Event staff</a> · <a href="/admin/download.php?file=attendees.csv">Attendee export</a></p>
<?php endif; ?>
<form method="post" action="/admin/logout.php"><input type="hidden" name="csrf" value="<?= Events::e($token) ?>"><button>Sign out</button></form>
<p><a href="/">Public calendar</a></p>
</body></html>
