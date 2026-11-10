<?php
declare(strict_types=1);
require_once __DIR__ . '/../../src/Events.php';
Events::requireStaff('admin');
$file = $_GET['file'] ?? '';
if (!is_string($file) || !preg_match('/^[a-z0-9_-]+\.csv$/', $file) || !is_file(__DIR__ . '/exports/' . $file)) { http_response_code(404); exit('Not found'); }
header('Content-Type: text/csv; charset=utf-8');
header('Content-Disposition: attachment; filename="' . $file . '"');
readfile(__DIR__ . '/exports/' . $file);
