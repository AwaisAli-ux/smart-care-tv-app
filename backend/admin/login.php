<?php
require_once __DIR__ . '/includes/auth.php';
admin_session_start();

$error = '';

if (($_SERVER['REQUEST_METHOD'] ?? '') === 'POST') {
    $username = trim((string) ($_POST['username'] ?? ''));
    $password = (string) ($_POST['password'] ?? '');

    $stmt = get_pdo()->prepare('SELECT * FROM admin_users WHERE username = :u LIMIT 1');
    $stmt->execute([':u' => $username]);
    $admin = $stmt->fetch();

    if ($admin && password_verify($password, $admin['password_hash'])) {
        session_regenerate_id(true);
        $_SESSION['admin_id'] = $admin['id'];
        $_SESSION['admin_username'] = $admin['username'];
        header('Location: index.php');
        exit;
    }
    $error = 'Invalid username or password.';
}

if (!empty($_SESSION['admin_id'])) {
    header('Location: index.php');
    exit;
}
?>
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Admin Login — Smart Care TV</title>
<link rel="stylesheet" href="assets/style.css">
</head>
<body>
<div class="login-wrap">
  <div class="login-box">
    <h1>Smart Care TV</h1>
    <?php if ($error): ?><div class="flash error"><?= h($error) ?></div><?php endif; ?>
    <form method="post">
      <label>Username</label>
      <input type="text" name="username" required autofocus>
      <label>Password</label>
      <input type="password" name="password" required>
      <button class="btn" style="width:100%;margin-top:20px;" type="submit">Sign In</button>
    </form>
  </div>
</div>
</body>
</html>
