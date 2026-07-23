<?php
require_once __DIR__ . '/includes/auth.php';
require_admin_login();
$pdo = get_pdo();

$totalUsers    = (int) $pdo->query('SELECT COUNT(*) FROM users')->fetchColumn();
$activeDevices = (int) $pdo->query("SELECT COUNT(*) FROM devices WHERE status = 'active'")->fetchColumn();
$lockedDevices = (int) $pdo->query("SELECT COUNT(*) FROM devices WHERE status = 'locked'")->fetchColumn();
$lockedUsers   = (int) $pdo->query("SELECT COUNT(*) FROM users WHERE status = 'locked'")->fetchColumn();
$onlineUsers   = (int) $pdo->query(
    "SELECT COUNT(DISTINCT user_id) FROM devices WHERE last_seen > (NOW() - INTERVAL 24 HOUR)"
)->fetchColumn();

$recentDevices = $pdo->query(
    "SELECT d.*, u.username FROM devices d
     JOIN users u ON u.id = d.user_id
     ORDER BY d.last_seen DESC LIMIT 8"
)->fetchAll();

$activeNav = 'dashboard';
require __DIR__ . '/includes/header.php';
?>
<h1>Dashboard</h1>
<p class="subtitle">Overview of Smart Care TV accounts and connected devices.</p>

<div class="stats-grid">
  <div class="stat-card accent">
    <div class="value"><?= $totalUsers ?></div>
    <div class="label">Total Users</div>
  </div>
  <div class="stat-card ok">
    <div class="value"><?= $activeDevices ?></div>
    <div class="label">Active Devices</div>
  </div>
  <div class="stat-card warn">
    <div class="value"><?= $lockedDevices ?></div>
    <div class="label">Locked Devices</div>
  </div>
  <div class="stat-card">
    <div class="value"><?= $lockedUsers ?></div>
    <div class="label">Locked Accounts</div>
  </div>
  <div class="stat-card">
    <div class="value"><?= $onlineUsers ?></div>
    <div class="label">Users Online (24h)</div>
  </div>
</div>

<div class="card">
  <h2>Recently Active Devices</h2>
  <table>
    <thead>
      <tr><th>User</th><th>Device</th><th>Status</th><th>Last Seen</th></tr>
    </thead>
    <tbody>
      <?php if (!$recentDevices): ?>
        <tr><td colspan="4" class="muted">No devices yet.</td></tr>
      <?php endif; ?>
      <?php foreach ($recentDevices as $d): ?>
        <tr>
          <td><?= h($d['username']) ?></td>
          <td><?= h(trim(($d['device_brand'] ?? '') . ' ' . ($d['device_model'] ?? '')) ?: 'Unknown') ?></td>
          <td><span class="badge <?= $d['status'] === 'locked' ? 'locked' : 'active' ?>"><?= h($d['status']) ?></span></td>
          <td><?= h($d['last_seen']) ?></td>
        </tr>
      <?php endforeach; ?>
    </tbody>
  </table>
</div>

<?php require __DIR__ . '/includes/footer.php'; ?>
