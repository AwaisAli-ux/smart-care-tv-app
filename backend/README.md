# Smart Care TV — Device Binding & Remote Lock Backend

PHP 8 + MySQL/MariaDB backend and admin panel that enforces a per-account
device limit for the Smart Care TV Flutter app, and lets you lock/unlock any
user or device remotely. No Composer / third-party PHP dependencies — runs
on any standard shared hosting (cPanel, etc.).

```
backend/
  schema.sql          ← import this first
  config.php          ← edit DB + app key here
  seed.php            ← optional: creates 1 admin + 2 test users
  api/
    login.php
    check_status.php
  admin/
    login.php, index.php, users.php, devices.php, actions.php, ...
```

## 1. Deploy

1. Upload the whole `backend/` folder to your host (e.g. `public_html/backend/`).
2. Create a MySQL database + user in your host's control panel, and import
   the schema:
   ```
   mysql -u <db_user> -p <db_name> < schema.sql
   ```
   (or use phpMyAdmin → Import → select `schema.sql`).
3. Open `config.php` and set:
   - `DB_HOST`, `DB_NAME`, `DB_USER`, `DB_PASS` — your database credentials.
   - `APP_KEY` — generate a long random string (e.g. `openssl rand -hex 32`).
     This must match `AuthConfig.appKey` in the Flutter app
     (`lib/services/auth_config.dart`).
4. **Use HTTPS in production.** The app sends the account password and,
   on success, real Xtream/IPTV credentials over this API — plain HTTP
   exposes both to anyone on the network path. Most shared hosts provide a
   free Let's Encrypt certificate; enable it and only ever point the app at
   the `https://` URL.
5. Run the seed script once (creates an admin login + 2 sample users):
   ```
   php seed.php
   ```
   or visit `https://your-domain.com/backend/seed.php` once in a browser.
   **Delete or rename `seed.php` afterwards** — it prints plaintext
   passwords and has no auth guard of its own.
6. Log into the admin panel at `https://your-domain.com/backend/admin/`
   with the printed admin credentials, then change that password by editing
   the row in `admin_users` (or add a "change password" flow — out of scope
   here since it's a single-operator panel) — simplest is to re-run
   `password_hash()` via a one-off PHP snippet and UPDATE the row.
7. Point the Flutter app at your API:
   `lib/services/auth_config.dart` → `AuthConfig.baseUrl = 'https://your-domain.com/backend/api'`.

## 2. Creating a customer

In **Admin → Users → Add New User**, fill in:
- **Username / Password** — what the customer types into the Smart Care TV
  app's login screen. This is *not* their Xtream panel login.
- **Max Devices** — how many phones/TVs can be signed in at once (default 1).
- **Expiry Date** — subscription end date; leave blank for no expiry.
- **Xtream Host / Username / Password** — the *real* IPTV panel credentials.
  These are only ever sent to the app after a device passes the binding
  check (see "Why this is the real enforcement" below) — they are never
  bundled into the APK.

The first device to log in with those credentials is auto-registered. Any
additional device is rejected with "Device limit reached" until you either
raise `max_devices` or use **Reset Devices** to clear the slot.

## 3. Locking / unlocking

- **Users → Lock/Unlock** — locks the whole account; every device on it
  will see the App Locked screen on its next check (≤ 6h, or immediately on
  app resume).
- **Devices → Lock/Unlock** — locks a single device without affecting the
  user's other devices.
- **Users → Reset Devices** — deletes all registered devices (and
  invalidates their session tokens) so the customer can register fresh
  device(s), e.g. after replacing their box.

## 4. API contract (for reference)

Both endpoints require header `X-App-Key: <APP_KEY>` and return JSON.

**POST `/api/login.php`**
```json
// request
{ "username": "...", "password": "...", "device_id": "...", "device_model": "...", "device_brand": "..." }
```
Responses (`status` field): `ok` (+ `token`, `xtream{host,username,password}`, `expiry_date`),
`locked`, `expired`, `device_limit`, `error` (invalid credentials / bad request),
HTTP 429 for rate limiting, HTTP 403 for a missing/wrong app key.

**POST `/api/check_status.php`**
```json
{ "token": "...", "device_id": "..." }
```
Responses: `ok` (+ `xtream`, `expiry_date`), `locked`, `expired`, `invalid_token`.

## 5. Security notes

- All queries use PDO prepared statements — no string-interpolated SQL.
- Passwords are hashed with `password_hash()` (bcrypt) / verified with
  `password_verify()` — plaintext passwords are never stored.
- Login is rate-limited to 10 attempts / IP / 10 minutes (`login_attempts`
  table, see `config.php::check_and_record_login_attempt`).
- `display_errors` is off; PHP warnings/notices never leak into the JSON
  responses or admin HTML.
- The admin panel is session-based with CSRF tokens on every mutating form.
- `check_status.php` re-validates the account, the subscription expiry, and
  the specific device on every call — a token issued to a device that gets
  locked or reset stops working on the very next check.

## 6. Design defaults (documented per the task brief)

- **Device ID**: the Flutter app does **not** add the `device_info_plus`
  package. It already has a native Android channel
  (`com.smartcaretv.app/device_info`) that reads
  `Settings.Secure.ANDROID_ID` for `DeviceProfileService` (used for
  hardware-aware playback tuning). This backend/app reuses that exact same
  ID as the device-binding identifier — functionally identical to what the
  brief asked for, with one fewer dependency and no risk of hitting a
  plugin API that later deprecates `androidId` (Google has tightened access
  to it in recent `device_info_plus` releases).
- **Xtream host** is now server-controlled per user (`users.xtream_host`)
  rather than typed into the app — the login screen only asks for the
  Smart Care TV account's username/password. See the Flutter README section
  for how this changes `login_screen.dart`.
- Rate limiting uses a DB table (`login_attempts`) instead of files, since
  file locking is unreliable across shared-hosting PHP-FPM pools.
