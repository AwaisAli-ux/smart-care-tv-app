<?php
/**
 * One-time seed script: creates 1 admin + 2 test users + sample devices.
 *
 * Run once from the command line on your server:
 *   php seed.php
 *
 * Or once via browser (delete/rename this file afterwards — it prints
 * plaintext passwords and should not stay reachable in production):
 *   https://your-domain.com/backend/seed.php
 *
 * Safe to re-run: existing usernames are skipped, not duplicated.
 */

require_once __DIR__ . '/config.php';

$isCli = (php_sapi_name() === 'cli');
function out(string $line, bool $isCli): void
{
    echo $isCli ? $line . "\n" : nl2br(h_seed($line)) . "<br>";
}
function h_seed(string $s): string
{
    return htmlspecialchars($s, ENT_QUOTES, 'UTF-8');
}

$pdo = get_pdo();

if (!$isCli) {
    header('Content-Type: text/plain; charset=utf-8');
}

// ── 1. Admin account ────────────────────────────────────────────────────────
$adminUser = 'admin';
$adminPass = 'ChangeMe123!';

$exists = $pdo->prepare('SELECT COUNT(*) FROM admin_users WHERE username = :u');
$exists->execute([':u' => $adminUser]);
if ((int) $exists->fetchColumn() === 0) {
    $pdo->prepare('INSERT INTO admin_users (username, password_hash) VALUES (:u, :p)')
        ->execute([':u' => $adminUser, ':p' => password_hash($adminPass, PASSWORD_BCRYPT)]);
    out("Created admin user: $adminUser / $adminPass  (CHANGE THIS PASSWORD after first login)", $isCli);
} else {
    out("Admin user '$adminUser' already exists — skipped.", $isCli);
}

// ── 2. Test customer users ──────────────────────────────────────────────────
$testUsers = [
    [
        'username' => 'testuser1',
        'password' => 'test1234',
        'max_devices' => 1,
        'expiry_date' => date('Y-m-d', strtotime('+30 days')),
        'xtream_host' => 'http://demo.example.com:8080',
        'xtream_username' => 'xt_testuser1',
        'xtream_password' => 'xt_pass_1',
    ],
    [
        'username' => 'testuser2',
        'password' => 'test5678',
        'max_devices' => 2,
        'expiry_date' => date('Y-m-d', strtotime('+30 days')),
        'xtream_host' => 'http://demo.example.com:8080',
        'xtream_username' => 'xt_testuser2',
        'xtream_password' => 'xt_pass_2',
    ],
];

foreach ($testUsers as $u) {
    $exists = $pdo->prepare('SELECT id FROM users WHERE username = :u');
    $exists->execute([':u' => $u['username']]);
    $row = $exists->fetch();

    if ($row) {
        out("User '{$u['username']}' already exists — skipped.", $isCli);
        $userId = (int) $row['id'];
    } else {
        $pdo->prepare(
            'INSERT INTO users (username, password_hash, max_devices, expiry_date, xtream_host, xtream_username, xtream_password)
             VALUES (:u, :p, :m, :e, :xh, :xu, :xp)'
        )->execute([
            ':u'  => $u['username'],
            ':p'  => password_hash($u['password'], PASSWORD_BCRYPT),
            ':m'  => $u['max_devices'],
            ':e'  => $u['expiry_date'],
            ':xh' => $u['xtream_host'],
            ':xu' => $u['xtream_username'],
            ':xp' => $u['xtream_password'],
        ]);
        $userId = (int) $pdo->lastInsertId();
        out("Created user: {$u['username']} / {$u['password']}  (max_devices={$u['max_devices']})", $isCli);
    }

    // Sample device for this user, if none exist yet.
    $devCount = $pdo->prepare('SELECT COUNT(*) FROM devices WHERE user_id = :id');
    $devCount->execute([':id' => $userId]);
    if ((int) $devCount->fetchColumn() === 0) {
        $pdo->prepare(
            'INSERT INTO devices (user_id, device_id, device_model, device_brand, status)
             VALUES (:uid, :did, :m, :b, "active")'
        )->execute([
            ':uid' => $userId,
            ':did' => 'seed-sample-device-' . $userId,
            ':m'   => 'Mi Box S',
            ':b'   => 'xiaomi',
        ]);
        out("  → Added sample device for '{$u['username']}'.", $isCli);
    }
}

out('', $isCli);
out('Seed complete. Log into the admin panel with the admin credentials above.', $isCli);
