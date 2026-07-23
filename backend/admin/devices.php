<?php
require_once __DIR__ . '/includes/auth.php';
require_admin_login();
$pdo = get_pdo();

$search = trim((string) ($_GET['q'] ?? ''));
$sql = "SELECT d.*, u.username FROM devices d JOIN users u ON u.id = d.user_id";
if ($search !== '') {
    $sql .= " WHERE u.username LIKE :q";
}
$sql .= " ORDER BY d.last_seen DESC";
$stmt = $pdo->prepare($sql);
if ($search !== '') {
    $stmt->execute([':q' => '%' . $search . '%']);
} else {
    $stmt->execute();
}
$devices = $stmt->fetchAll();

$activeNav = 'devices';
require __DIR__ . '/includes/header.php';
?>
<h1>Devices</h1>
<p class="subtitle">Every device that has ever logged into a Smart Care TV account.</p>

<div class="card">
  <div class="search-bar">
    <form method="get">
      <input type="text" name="q" value="<?= h($search) ?>" placeholder="Search by username…">
    </form>
  </div>
  <table>
    <thead>
      <tr>
        <th>User</th><th>Brand / Model</th><th>Device ID</th>
        <th>First Seen</th><th>Last Seen</th><th>Status</th><th>Actions</th>
      </tr>
    </thead>
    <tbody>
      <?php if (!$devices): ?>
        <tr><td colspan="7" class="muted">No devices found.</td></tr>
      <?php endif; ?>
      <?php foreach ($devices as $d): ?>
        <?php $shortId = substr($d['device_id'], 0, 10) . '…'; ?>
        <tr>
          <td><?= h($d['username']) ?></td>
          <td><?= h(trim(($d['device_brand'] ?? '') . ' ' . ($d['device_model'] ?? '')) ?: 'Unknown') ?></td>
          <td>
            <span class="device-id" title="<?= h($d['device_id']) ?>"><?= h($shortId) ?></span>
            <button class="btn small secondary" type="button"
                    onclick="navigator.clipboard.writeText('<?= h($d['device_id']) ?>'); this.textContent='Copied!'; setTimeout(()=>this.textContent='Copy', 1500);">Copy</button>
          </td>
          <td><?= h($d['first_seen']) ?></td>
          <td><?= h($d['last_seen']) ?></td>
          <td><span class="badge <?= $d['status'] === 'locked' ? 'locked' : 'active' ?>"><?= h($d['status']) ?></span></td>
          <td>
            <form method="post" action="actions.php">
              <input type="hidden" name="csrf_token" value="<?= h(csrf_token()) ?>">
              <input type="hidden" name="device_id_pk" value="<?= (int) $d['id'] ?>">
              <?php if ($d['status'] === 'locked'): ?>
                <input type="hidden" name="action" value="unlock_device">
                <button class="btn small" type="submit">Unlock</button>
              <?php else: ?>
                <input type="hidden" name="action" value="lock_device">
                <button class="btn small danger" type="submit">Lock</button>
              <?php endif; ?>
            </form>
          </td>
        </tr>
      <?php endforeach; ?>
    </tbody>
  </table>
</div>

<?php require __DIR__ . '/includes/footer.php'; ?>
