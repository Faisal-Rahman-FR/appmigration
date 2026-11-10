<?php
declare(strict_types=1);
require_once __DIR__ . '/../../src/Events.php';
$user = Events::requireStaff('admin');
if ($_SERVER['REQUEST_METHOD'] !== 'POST') { http_response_code(405); header('Allow: POST'); exit; }
Events::checkCsrf($user['uid'], $_POST['csrf'] ?? null);
$status = $_POST['status'] ?? '';
$id = filter_var($_POST['id'] ?? null, FILTER_VALIDATE_INT);
if (!in_array($status, ['approved', 'cancelled'], true) || $id === false) { http_response_code(400); exit('Invalid request'); }
$query = Events::pdo()->prepare('UPDATE events SET status = :status WHERE id = :id');
$query->execute(['status' => $status, 'id' => $id]);
header('Location: /admin/', true, 303);
