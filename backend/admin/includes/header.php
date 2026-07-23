<?php
/** Shared page chrome. Include AFTER require_admin_login() has run.
 *  Set $activeNav to 'dashboard' | 'users' | 'devices' before including. */
$activeNav = $activeNav ?? '';
$flashMsg = pop_flash();
?>
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Smart Care TV — Admin</title>
<link rel="stylesheet" href="assets/style.css">
</head>
<body>
<div class="topbar">
  <div class="brand">Smart Care TV — Admin</div>
  <nav>
    <a href="index.php" class="<?= $activeNav === 'dashboard' ? 'active' : '' ?>">Dashboard</a>
    <a href="users.php" class="<?= $activeNav === 'users' ? 'active' : '' ?>">Users</a>
    <a href="devices.php" class="<?= $activeNav === 'devices' ? 'active' : '' ?>">Devices</a>
    <a href="logout.php">Logout</a>
    <span class="who"><?= h(current_admin_username()) ?></span>
  </nav>
</div>
<div class="container">
<?php if ($flashMsg): ?>
  <div class="flash <?= h($flashMsg['type']) ?>"><?= h($flashMsg['message']) ?></div>
<?php endif; ?>
