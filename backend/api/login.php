<?php
/**
 * POST /api/login.php
 * Body: { username, password, device_id, device_model, device_brand }
 * Header: X-App-Key: <APP_KEY>
 *
 * Validates the customer's Smart Care TV account + binds/checks the
 * requesting device, then returns the real Xtream/IPTV credentials.
 * See backend/README.md for the full response-status contract.
 */

require_once __DIR__ . '/../config.php';

apply_api_headers();

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    json_response(['status' => 'error', 'message' => 'Method not allowed'], 405);
}

require_app_key();

$pdo = get_pdo();

if (!check_and_record_login_attempt($pdo)) {
    json_response([
        'status'  => 'error',
        'message' => 'Too many login attempts. Please try again later.',
    ], 429);
}

$body = read_json_body();

$username     = trim((string) ($body['username'] ?? ''));
$password     = (string) ($body['password'] ?? '');
$deviceId     = trim((string) ($body['device_id'] ?? ''));
$deviceModel  = trim((string) ($body['device_model'] ?? ''));
$deviceBrand  = trim((string) ($body['device_brand'] ?? ''));

if ($username === '' || $password === '' || $deviceId === '') {
    json_response(['status' => 'error', 'message' => 'Missing required fields'], 400);
}

// ── 1. Find user + verify password ─────────────────────────────────────────
$stmt = $pdo->prepare('SELECT * FROM users WHERE username = :u LIMIT 1');
$stmt->execute([':u' => $username]);
$user = $stmt->fetch();

if (!$user || !password_verify($password, $user['password_hash'])) {
    json_response(['status' => 'error', 'message' => 'Invalid credentials'], 401);
}

// ── 2. Account status checks ────────────────────────────────────────────────
if ($user['status'] === 'locked') {
    json_response(['status' => 'locked', 'message' => 'Your account is locked. Contact support.']);
}

if ($user['status'] === 'expired' ||
    ($user['expiry_date'] !== null && strtotime($user['expiry_date']) < strtotime(date('Y-m-d')))) {
    json_response(['status' => 'expired', 'message' => 'Subscription expired']);
}

// ── 3. Device binding ───────────────────────────────────────────────────────
$stmt = $pdo->prepare(
    'SELECT * FROM devices WHERE user_id = :uid AND device_id = :did LIMIT 1'
);
$stmt->execute([':uid' => $user['id'], ':did' => $deviceId]);
$device = $stmt->fetch();

if ($device) {
    if ($device['status'] === 'locked') {
        json_response(['status' => 'locked', 'message' => 'Your account is locked. Contact support.']);
    }
    // Known, active device — refresh last_seen + reported model/brand.
    $upd = $pdo->prepare(
        'UPDATE devices SET last_seen = NOW(), device_model = :m, device_brand = :b WHERE id = :id'
    );
    $upd->execute([':m' => $deviceModel, ':b' => $deviceBrand, ':id' => $device['id']]);
} else {
    // New device — enforce the per-account device limit before auto-registering.
    $countStmt = $pdo->prepare(
        "SELECT COUNT(*) FROM devices WHERE user_id = :uid AND status = 'active'"
    );
    $countStmt->execute([':uid' => $user['id']]);
    $activeCount = (int) $countStmt->fetchColumn();

    if ($activeCount >= (int) $user['max_devices']) {
        json_response([
            'status'  => 'device_limit',
            'message' => 'Device limit reached. Contact support to add this device.',
        ]);
    }

    $ins = $pdo->prepare(
        'INSERT INTO devices (user_id, device_id, device_model, device_brand, status)
         VALUES (:uid, :did, :m, :b, "active")'
    );
    $ins->execute([
        ':uid' => $user['id'],
        ':did' => $deviceId,
        ':m'   => $deviceModel,
        ':b'   => $deviceBrand,
    ]);
}

// ── 4. Issue session token ──────────────────────────────────────────────────
$token = bin2hex(random_bytes(32));
$expiresAt = date('Y-m-d H:i:s', strtotime('+' . SESSION_LIFETIME_DAYS . ' days'));

$sess = $pdo->prepare(
    'INSERT INTO sessions (user_id, device_id, token, expires_at) VALUES (:uid, :did, :tok, :exp)'
);
$sess->execute([
    ':uid' => $user['id'],
    ':did' => $deviceId,
    ':tok' => $token,
    ':exp' => $expiresAt,
]);

json_response([
    'status'      => 'ok',
    'token'       => $token,
    'xtream'      => xtream_block($user),
    'expiry_date' => $user['expiry_date'],
]);
