<?php
/**
 * POST /api/track.php
 * Body: { username, server_url, device_id, device_model, device_brand }
 * Header: X-App-Key: <APP_KEY>
 *
 * Records every direct-IPTV login (any username, whether or not it was
 * pre-provisioned in `users`) so it shows up in the admin Devices list and
 * can be remotely locked. Never blocks the real IPTV login except when the
 * account or device has been explicitly locked from the admin panel.
 */

require_once __DIR__ . '/../config.php';

apply_api_headers();

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    json_response(['status' => 'error', 'message' => 'Method not allowed'], 405);
}

require_app_key();

$pdo = get_pdo();
$body = read_json_body();

$username    = trim((string) ($body['username'] ?? ''));
$serverUrl   = trim((string) ($body['server_url'] ?? ''));
$deviceId    = trim((string) ($body['device_id'] ?? ''));
$deviceModel = trim((string) ($body['device_model'] ?? ''));
$deviceBrand = trim((string) ($body['device_brand'] ?? ''));

if ($username === '' || $deviceId === '') {
    json_response(['status' => 'error', 'message' => 'Missing required fields'], 400);
}

// ── Find or auto-create the shadow user row (tracking only — the real
//    credential check already happened against the customer's own IPTV
//    panel; this row exists purely so the account/device can be viewed
//    and locked from the admin panel). ───────────────────────────────────
$stmt = $pdo->prepare('SELECT * FROM users WHERE username = :u LIMIT 1');
$stmt->execute([':u' => $username]);
$user = $stmt->fetch();

if (!$user) {
    $ins = $pdo->prepare(
        'INSERT INTO users (username, password_hash, max_devices, xtream_host)
         VALUES (:u, :p, 999, :h)'
    );
    $ins->execute([
        ':u' => $username,
        ':p' => password_hash(bin2hex(random_bytes(16)), PASSWORD_BCRYPT),
        ':h' => $serverUrl,
    ]);
    $userId = (int) $pdo->lastInsertId();
} else {
    $userId = (int) $user['id'];
    if ($user['status'] === 'locked') {
        json_response(['status' => 'locked', 'message' => 'This account has been blocked. Contact support.']);
    }
    $pdo->prepare('UPDATE users SET xtream_host = :h WHERE id = :id')
        ->execute([':h' => $serverUrl, ':id' => $userId]);
}

// ── Device: track + allow explicit lock, no device-count limit here ────────
$stmt = $pdo->prepare('SELECT * FROM devices WHERE user_id = :uid AND device_id = :did LIMIT 1');
$stmt->execute([':uid' => $userId, ':did' => $deviceId]);
$device = $stmt->fetch();

if ($device) {
    if ($device['status'] === 'locked') {
        json_response(['status' => 'locked', 'message' => 'This device has been blocked. Contact support.']);
    }
    $pdo->prepare(
        'UPDATE devices SET last_seen = NOW(), device_model = :m, device_brand = :b WHERE id = :id'
    )->execute([':m' => $deviceModel, ':b' => $deviceBrand, ':id' => $device['id']]);
} else {
    $pdo->prepare(
        'INSERT INTO devices (user_id, device_id, device_model, device_brand, status)
         VALUES (:uid, :did, :m, :b, "active")'
    )->execute([':uid' => $userId, ':did' => $deviceId, ':m' => $deviceModel, ':b' => $deviceBrand]);
}

json_response(['status' => 'ok']);
