<?php
/** Central POST handler for every mutating admin action (users.php + devices.php forms). */
require_once __DIR__ . '/includes/auth.php';
require_admin_login();

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    header('Location: users.php');
    exit;
}
require_csrf();

$pdo = get_pdo();
$action = (string) ($_POST['action'] ?? '');

function redirect_back(string $fallback): void
{
    header('Location: ' . $fallback);
    exit;
}

switch ($action) {
    case 'add_user': {
        $username    = trim((string) ($_POST['username'] ?? ''));
        $password    = (string) ($_POST['password'] ?? '');
        $maxDevices  = max(1, (int) ($_POST['max_devices'] ?? 1));
        $expiry      = trim((string) ($_POST['expiry_date'] ?? '')) ?: null;
        $xHost       = trim((string) ($_POST['xtream_host'] ?? ''));
        $xUser       = trim((string) ($_POST['xtream_username'] ?? ''));
        $xPass       = trim((string) ($_POST['xtream_password'] ?? ''));

        if ($username === '' || $password === '') {
            flash('Username and password are required.', 'error');
            redirect_back('users.php');
        }

        $exists = $pdo->prepare('SELECT COUNT(*) FROM users WHERE username = :u');
        $exists->execute([':u' => $username]);
        if ((int) $exists->fetchColumn() > 0) {
            flash('That username already exists.', 'error');
            redirect_back('users.php');
        }

        $stmt = $pdo->prepare(
            'INSERT INTO users (username, password_hash, max_devices, expiry_date, xtream_host, xtream_username, xtream_password)
             VALUES (:u, :p, :m, :e, :xh, :xu, :xp)'
        );
        $stmt->execute([
            ':u'  => $username,
            ':p'  => password_hash($password, PASSWORD_BCRYPT),
            ':m'  => $maxDevices,
            ':e'  => $expiry,
            ':xh' => $xHost,
            ':xu' => $xUser,
            ':xp' => $xPass,
        ]);
        flash("User \"$username\" created.");
        redirect_back('users.php');
    }

    case 'lock_user':
    case 'unlock_user': {
        $userId = (int) ($_POST['user_id'] ?? 0);
        $status = $action === 'lock_user' ? 'locked' : 'active';
        $stmt = $pdo->prepare('UPDATE users SET status = :s WHERE id = :id');
        $stmt->execute([':s' => $status, ':id' => $userId]);
        flash($status === 'locked' ? 'User locked.' : 'User unlocked.');
        redirect_back('users.php');
    }

    case 'set_max_devices': {
        $userId = (int) ($_POST['user_id'] ?? 0);
        $max    = max(1, (int) ($_POST['max_devices'] ?? 1));
        $stmt = $pdo->prepare('UPDATE users SET max_devices = :m WHERE id = :id');
        $stmt->execute([':m' => $max, ':id' => $userId]);
        flash('Device limit updated.');
        redirect_back('users.php');
    }

    case 'set_expiry': {
        $userId = (int) ($_POST['user_id'] ?? 0);
        $expiry = trim((string) ($_POST['expiry_date'] ?? '')) ?: null;
        $stmt = $pdo->prepare('UPDATE users SET expiry_date = :e WHERE id = :id');
        $stmt->execute([':e' => $expiry, ':id' => $userId]);
        flash('Expiry date updated.');
        redirect_back('users.php');
    }

    case 'set_xtream': {
        $userId = (int) ($_POST['user_id'] ?? 0);
        $xHost  = trim((string) ($_POST['xtream_host'] ?? ''));
        $xUser  = trim((string) ($_POST['xtream_username'] ?? ''));
        $xPass  = trim((string) ($_POST['xtream_password'] ?? ''));
        $stmt = $pdo->prepare(
            'UPDATE users SET xtream_host = :h, xtream_username = :u, xtream_password = :p WHERE id = :id'
        );
        $stmt->execute([':h' => $xHost, ':u' => $xUser, ':p' => $xPass, ':id' => $userId]);
        flash('Xtream credentials updated.');
        redirect_back('users.php');
    }

    case 'reset_devices': {
        $userId = (int) ($_POST['user_id'] ?? 0);
        $stmt = $pdo->prepare('DELETE FROM devices WHERE user_id = :id');
        $stmt->execute([':id' => $userId]);
        // Old session tokens were bound to now-deleted devices — invalidate them too.
        $pdo->prepare('DELETE FROM sessions WHERE user_id = :id')->execute([':id' => $userId]);
        flash('All devices reset. The user can register a new device on next login.');
        redirect_back('users.php');
    }

    case 'lock_device':
    case 'unlock_device': {
        $id = (int) ($_POST['device_id_pk'] ?? 0);
        $status = $action === 'lock_device' ? 'locked' : 'active';
        $stmt = $pdo->prepare('UPDATE devices SET status = :s WHERE id = :id');
        $stmt->execute([':s' => $status, ':id' => $id]);
        flash($status === 'locked' ? 'Device locked.' : 'Device unlocked.');
        redirect_back('devices.php');
    }

    default:
        flash('Unknown action.', 'error');
        redirect_back('users.php');
}
