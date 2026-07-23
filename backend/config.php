<?php
/**
 * Smart Care TV — Device Binding Backend
 * Shared configuration: DB connection, app key, JSON helpers, rate limiting.
 *
 * EDIT THE VALUES IN THE "SETTINGS" BLOCK BELOW before deploying.
 * Required by every file in api/ and admin/.
 */

// ── Error handling: never leak PHP warnings/HTML into JSON responses ───────
error_reporting(E_ALL);
ini_set('display_errors', '0');
ini_set('log_errors', '1');

// ── SETTINGS — edit these for your environment ──────────────────────────────
const DB_HOST = 'localhost';
const DB_NAME = 'smartcaretv';
const DB_USER = 'smartcaretv_user';
const DB_PASS = 'CHANGE_ME_DB_PASSWORD';

// Static key the Flutter app must send as the "X-App-Key" header on every
// API request. Change this to a long random string and update
// lib/services/auth_config.dart in the Flutter app to match.
const APP_KEY = 'CHANGE_ME_APP_KEY';

// Session token lifetime (days) issued at login / renewed is NOT auto-extended
// by check_status — the app re-logs in once the token expires.
const SESSION_LIFETIME_DAYS = 30;

// Rate limiting: max login attempts per IP within the window below.
const LOGIN_RATE_LIMIT_MAX = 10;
const LOGIN_RATE_LIMIT_WINDOW_MINUTES = 10;

// Timezone used for expiry_date comparisons — set to your server/customer timezone.
date_default_timezone_set('UTC');

// ── PDO connection (singleton) ──────────────────────────────────────────────
function get_pdo(): PDO
{
    static $pdo = null;
    if ($pdo !== null) {
        return $pdo;
    }
    $dsn = 'mysql:host=' . DB_HOST . ';dbname=' . DB_NAME . ';charset=utf8mb4';
    try {
        $pdo = new PDO($dsn, DB_USER, DB_PASS, [
            PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
            PDO::ATTR_EMULATE_PREPARES   => false,
        ]);
    } catch (PDOException $e) {
        error_log('[DB] Connection failed: ' . $e->getMessage());
        json_response(['status' => 'error', 'message' => 'Server error'], 500);
    }
    return $pdo;
}

// ── JSON response helper — always used instead of echo/print ───────────────
function json_response(array $data, int $httpCode = 200): void
{
    http_response_code($httpCode);
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode($data);
    exit;
}

// ── CORS + common API headers ───────────────────────────────────────────────
function apply_api_headers(): void
{
    header('Access-Control-Allow-Origin: *');
    header('Access-Control-Allow-Methods: POST, OPTIONS');
    header('Access-Control-Allow-Headers: Content-Type, X-App-Key');
    if (($_SERVER['REQUEST_METHOD'] ?? '') === 'OPTIONS') {
        http_response_code(204);
        exit;
    }
}

// ── App key gate — every api/ endpoint calls this first ────────────────────
function require_app_key(): void
{
    $key = $_SERVER['HTTP_X_APP_KEY'] ?? '';
    if (!hash_equals(APP_KEY, $key)) {
        json_response(['status' => 'error', 'message' => 'Forbidden'], 403);
    }
}

// ── Read + decode a JSON POST body into an assoc array ──────────────────────
function read_json_body(): array
{
    $raw = file_get_contents('php://input');
    $data = json_decode($raw, true);
    return is_array($data) ? $data : [];
}

// ── Client IP (respects shared-hosting reverse proxies where present) ──────
function client_ip(): string
{
    foreach (['HTTP_X_FORWARDED_FOR', 'HTTP_CLIENT_IP', 'REMOTE_ADDR'] as $key) {
        if (!empty($_SERVER[$key])) {
            $ip = trim(explode(',', $_SERVER[$key])[0]);
            if (filter_var($ip, FILTER_VALIDATE_IP)) {
                return $ip;
            }
        }
    }
    return '0.0.0.0';
}

// ── Login rate limiter — max LOGIN_RATE_LIMIT_MAX attempts / IP / window ───
// Records every call (successful or not) and returns false once the caller
// has exceeded the limit within the trailing window.
function check_and_record_login_attempt(PDO $pdo): bool
{
    $ip = client_ip();

    $stmt = $pdo->prepare(
        'SELECT COUNT(*) FROM login_attempts
         WHERE ip_address = :ip
           AND attempted_at > (NOW() - INTERVAL :minutes MINUTE)'
    );
    $stmt->bindValue(':ip', $ip);
    $stmt->bindValue(':minutes', LOGIN_RATE_LIMIT_WINDOW_MINUTES, PDO::PARAM_INT);
    $stmt->execute();
    $count = (int) $stmt->fetchColumn();

    if ($count >= LOGIN_RATE_LIMIT_MAX) {
        return false;
    }

    $insert = $pdo->prepare('INSERT INTO login_attempts (ip_address) VALUES (:ip)');
    $insert->execute([':ip' => $ip]);

    // Opportunistic cleanup so the table doesn't grow forever on busy servers.
    if (random_int(1, 50) === 1) {
        $pdo->prepare(
            'DELETE FROM login_attempts WHERE attempted_at < (NOW() - INTERVAL 1 DAY)'
        )->execute();
    }

    return true;
}

// ── Shared: build the xtream credential block returned by login/check_status ─
function xtream_block(array $user): array
{
    return [
        'host'     => $user['xtream_host'] ?? '',
        'username' => $user['xtream_username'] ?? '',
        'password' => $user['xtream_password'] ?? '',
    ];
}
