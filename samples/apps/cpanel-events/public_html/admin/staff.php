<?php
declare(strict_types=1);
require_once __DIR__ . '/../../src/Events.php';
Events::requireStaff('admin');
$staff = Events::pdo()->query('SELECT uid, display_name, role FROM event_staff ORDER BY uid')->fetchAll();
?><!doctype html><html lang="en"><head><meta charset="utf-8"><title>Event staff</title></head><body>
<h1>Event staff</h1>
<table data-testid="staff"><tr><th>User</th><th>Name</th><th>Role</th></tr>
<?php foreach ($staff as $row): ?>
<tr><td><?= Events::e($row['uid']) ?></td><td><?= Events::e($row['display_name']) ?></td><td><?= Events::e($row['role']) ?></td></tr>
<?php endforeach; ?>
</table>
<p><a href="/admin/">Back</a></p>
</body></html>
