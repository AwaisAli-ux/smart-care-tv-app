<?php
require_once __DIR__ . '/includes/auth.php';
require_admin_login();
$pdo = get_pdo();

$search = trim((string) ($_GET['q'] ?? ''));
if ($search !== '') {
    $stmt = $pdo->prepare(
        "SELECT u.*, (SELECT COUNT(*) FROM devices d WHERE d.user_id = u.id) AS device_count
         FROM users u WHERE u.username LIKE :q ORDER BY u.created_at DESC"
    );
    $stmt->execute([':q' => '%' . $search . '%']);
} else {
    $stmt = $pdo->query(
        "SELECT u.*, (SELECT COUNT(*) FROM devices d WHERE d.user_id = u.id) AS device_count
         FROM users u ORDER BY u.created_at DESC"
    );
}
$users = $stmt->fetchAll();

$activeNav = 'users';
require __DIR__ . '/includes/header.php';
?>
<h1>Users</h1>
<p class="subtitle">Smart Care TV customer accounts.</p>

<div class="card">
  <h2>Add New User</h2>
  <form method="post" action="actions.php">
    <input type="hidden" name="csrf_token" value="<?= h(csrf_token()) ?>">
    <input type="hidden" name="action" value="add_user">
    <div style="display:grid;grid-template-columns:1fr 1fr;gap:16px;">
      <div>
        <label>Username</label>
        <input type="text" name="username" required>
        <label>Password</label>
        <input type="text" name="password" required placeholder="Shown once — copy it now">
        <label>Max Devices</label>
        <input type="number" name="max_devices" value="1" min="1" required>
        <label>Expiry Date</label>
        <input type="date" name="expiry_date">
      </div>
      <div>
        <label>Xtream Host</label>
        <input type="text" name="xtream_host" placeholder="http://panel.example.com:8080">
        <label>Xtream Username</label>
        <input type="text" name="xtream_username">
        <label>Xtream Password</label>
        <input type="text" name="xtream_password">
      </div>
    </div>
    <button class="btn" style="margin-top:18px;" type="submit">Create User</button>
  </form>
</div>

<div class="card">
  <div class="search-bar">
    <form method="get">
      <input type="text" name="q" value="<?= h($search) ?>" placeholder="Search username…">
    </form>
  </div>
  <table>
    <thead>
      <tr>
        <th>Username</th><th>Status</th><th>Max Devices</th><th>Devices</th>
        <th>Expiry</th><th>Actions</th>
      </tr>
    </thead>
    <tbody>
      <?php if (!$users): ?>
        <tr><td colspan="6" class="muted">No users found.</td></tr>
      <?php endif; ?>
      <?php foreach ($users as $u): ?>
        <tr>
          <td><?= h($u['username']) ?></td>
          <td><span class="badge <?= h($u['status']) ?>"><?= h($u['status']) ?></span></td>
          <td>
            <form class="inline" method="post" action="actions.php">
              <input type="hidden" name="csrf_token" value="<?= h(csrf_token()) ?>">
              <input type="hidden" name="action" value="set_max_devices">
              <input type="hidden" name="user_id" value="<?= (int) $u['id'] ?>">
              <input type="number" name="max_devices" value="<?= (int) $u['max_devices'] ?>" min="1"
                     style="width:60px;display:inline-block;" onchange="this.form.submit()">
            </form>
          </td>
          <td><?= (int) $u['device_count'] ?></td>
          <td>
            <form class="inline" method="post" action="actions.php">
              <input type="hidden" name="csrf_token" value="<?= h(csrf_token()) ?>">
              <input type="hidden" name="action" value="set_expiry">
              <input type="hidden" name="user_id" value="<?= (int) $u['id'] ?>">
              <input type="date" name="expiry_date" value="<?= h($u['expiry_date']) ?>"
                     style="width:150px;display:inline-block;" onchange="this.form.submit()">
            </form>
          </td>
          <td class="actions-row">
            <form class="inline" method="post" action="actions.php">
              <input type="hidden" name="csrf_token" value="<?= h(csrf_token()) ?>">
              <input type="hidden" name="user_id" value="<?= (int) $u['id'] ?>">
              <?php if ($u['status'] === 'locked'): ?>
                <input type="hidden" name="action" value="unlock_user">
                <button class="btn small" type="submit">Unlock</button>
              <?php else: ?>
                <input type="hidden" name="action" value="lock_user">
                <button class="btn small danger" type="submit">Lock</button>
              <?php endif; ?>
            </form>
            <form class="inline" method="post" action="actions.php"
                  onsubmit="return confirm('Delete all registered devices for this user? They will need to log in again to re-register.');">
              <input type="hidden" name="csrf_token" value="<?= h(csrf_token()) ?>">
              <input type="hidden" name="action" value="reset_devices">
              <input type="hidden" name="user_id" value="<?= (int) $u['id'] ?>">
              <button class="btn small secondary" type="submit">Reset Devices</button>
            </form>
            <a class="btn small secondary" href="users.php?edit=<?= (int) $u['id'] ?>">Edit Xtream</a>
          </td>
        </tr>
        <?php if ((int) ($_GET['edit'] ?? 0) === (int) $u['id']): ?>
          <tr>
            <td colspan="6">
              <form method="post" action="actions.php" style="display:flex;gap:12px;align-items:flex-end;flex-wrap:wrap;">
                <input type="hidden" name="csrf_token" value="<?= h(csrf_token()) ?>">
                <input type="hidden" name="action" value="set_xtream">
                <input type="hidden" name="user_id" value="<?= (int) $u['id'] ?>">
                <div><label>Xtream Host</label><input type="text" name="xtream_host" value="<?= h($u['xtream_host']) ?>"></div>
                <div><label>Xtream Username</label><input type="text" name="xtream_username" value="<?= h($u['xtream_username']) ?>"></div>
                <div><label>Xtream Password</label><input type="text" name="xtream_password" value="<?= h($u['xtream_password']) ?>"></div>
                <button class="btn small" type="submit">Save</button>
              </form>
            </td>
          </tr>
        <?php endif; ?>
      <?php endforeach; ?>
    </tbody>
  </table>
</div>

<?php require __DIR__ . '/includes/footer.php'; ?>
