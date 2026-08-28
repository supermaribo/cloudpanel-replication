<?php
declare(strict_types=1);

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    http_response_code(405);
    header('Allow: POST');
    echo 'POST only';
    exit;
}

$token = preg_replace('/[^a-f0-9]/', '', (string) ($_POST['token'] ?? ''));
$rawOp = $_POST['clp_op'] ?? $_POST['action'] ?? '';
if (is_array($rawOp)) {
    $rawOp = in_array('live', $rawOp, true) ? 'live' : (string) end($rawOp);
}
$action = (string) $rawOp;
$confirm = (string) ($_POST['confirm'] ?? '');
if ($confirm === 'LIVE') {
    $action = 'live';
} elseif ($action !== 'live' && $action !== 'now' && $action !== 'sync' && isset($_POST['interval'])) {
    $action = 'frequency';
}
$bin = '/opt/clp-sync/bin/clp-sync-ui';

function clp_sync_redirect(): void
{
    $ref = (string) ($_SERVER['HTTP_REFERER'] ?? '/');
    $host = (string) ($_SERVER['HTTP_HOST'] ?? '');
    $ok = false;
    $p = parse_url($ref);
    if ($host !== '' && !empty($p['host'])) {
        $refHost = $p['host'];
        if (isset($p['port'])) {
            $refHost .= ':' . $p['port'];
        }
        if (strcasecmp($refHost, $host) === 0 || strcasecmp((string) $p['host'], explode(':', $host)[0]) === 0) {
            $ok = true;
        }
    }
    header('Location: ' . ($ok ? $ref : '/'), true, 303);
    exit;
}

function clp_sync_run(array $args): int
{
    global $bin;
    $cmd = 'sudo -n ' . escapeshellarg($bin);
    foreach ($args as $a) {
        $cmd .= ' ' . escapeshellarg((string) $a);
    }
    $out = [];
    $rc = 0;
    exec($cmd . ' 2>&1', $out, $rc);
    if ($rc !== 0) {
        error_log('clp-sync-ui: ' . implode("\n", $out));
    }
    return $rc;
}

if (strlen($token) !== 32) {
    http_response_code(403);
    echo 'Forbidden';
    exit;
}

if ($action === 'frequency') {
    $interval = (string) ($_POST['interval'] ?? '');
    $allowed = ['1h' => true, '2h' => true, '4h' => true, '6h' => true, '12h' => true, '24h' => true, 'off' => true];
    if (!isset($allowed[$interval])) {
        http_response_code(400);
        echo 'Invalid interval';
        exit;
    }
    if (clp_sync_run([$token, 'frequency', $interval]) !== 0) {
        http_response_code(500);
        echo 'Could not set replication frequency';
        exit;
    }
    clp_sync_redirect();
}

if ($action === 'now' || $action === 'sync') {
    if (clp_sync_run([$token, 'now']) !== 0) {
        http_response_code(500);
        echo 'Could not start sync (already running?)';
        exit;
    }
    clp_sync_redirect();
}

if ($action === 'live') {
    $confirm = (string) ($_POST['confirm'] ?? '');
    if ($confirm !== 'LIVE') {
        http_response_code(400);
        echo 'Confirmation required';
        exit;
    }
    if (clp_sync_run([$token, 'live', 'LIVE']) !== 0) {
        http_response_code(500);
        echo 'Could not promote replica';
        exit;
    }
    clp_sync_redirect();
}

http_response_code(400);
echo 'Unknown action';
