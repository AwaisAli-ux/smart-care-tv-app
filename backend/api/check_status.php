<?php
/**
 * POST /api/check_status.php
 * Body: { token, device_id }
 * Header: X-App-Key: <APP_KEY>
 *
 * Called on every app launch, every 6h while running, and on app resume.
 * Returns the same shape as login.php so the app can reuse one handler.
 */

require_once __DIR__ . '/../config.php';

apply_api_headers();

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    json_response(['status' => 'error', 'message' => 'Method not allowed'], 405);
}

require_app_key();

$pdo = get_pdo();
$body = read_json_body();

$token    = trim((string) ($body['token'] ?? ''));
$deviceId = trim((string) ($body['device_id'] ?? ''));

if ($token === '' || $deviceId === '') {
    json_response(['status' => 'error', 'message' => 'Missing required fields'], 400);
}

// ── 1. Validate session token ───────────────────────────────────────────────
$stmt = $pdo->prepare('SELECT * FROM sessions WHERE token = :tok LIMIT 1');
$stmt->execute([':tok' => $token]);
$session = $stmt->fetch();

if (!$session || strtotime($session['expires_at']) < time()) {
    json_response(['status' => 'invalid_token', 'message' => 'Session expired, please log in again.']);
}

// Token must have been issued for this exact device — a token replayed from
// a different device is treated as invalid rather than silently trusted.
if (!hash_equals($session['device_id'], $deviceId)) {
    json_response(['status' => 'invalid_token', 'message' => 'Session does not match this device.']);
}

// ── 2. Re-check user status ─────────────────────────────────────────────────
$stmt = $pdo->prepare('SELECT * FROM users WHERE id = :uid LIMIT 1');
$stmt->execute([':uid' => $session['user_id']]);
$user = $stmt->fetch();

if (!$user) {
    json_response(['status' => 'invalid_token', 'message' => 'Account no longer exists.']);
}

if ($user['status'] === 'locked') {
    json_response(['status' => 'locked', 'message' => 'Your account is locked. Contact support.']);
}

if ($user['status'] === 'expired' ||
    ($user['expiry_date'] !== null && strtotime($user['expiry_date']) < strtotime(date('Y-m-d')))) {
    json_response(['status' => 'expired', 'message' => 'Subscription expired']);
}

// ── 3. Re-check device status ───────────────────────────────────────────────
$stmt = $pdo->prepare(
    'SELECT * FROM devices WHERE user_id = :uid AND device_id = :did LIMIT 1'
);
$stmt->execute([':uid' => $user['id'], ':did' => $deviceId]);
$device = $stmt->fetch();

if (!$device) {
    // Device was reset/removed by the admin — force a fresh login/re-registration.
    json_response(['status' => 'invalid_token', 'message' => 'Device no longer registered.']);
}

if ($device['status'] === 'locked') {
    json_response(['status' => 'locked', 'message' => 'Your account is locked. Contact support.']);
}

$pdo->prepare('UPDATE devices SET last_seen = NOW() WHERE id = :id')
    ->execute([':id' => $device['id']]);

json_response([
    'status'      => 'ok',
    'xtream'      => xtream_block($user),
    'expiry_date' => $user['expiry_date'],
]);
