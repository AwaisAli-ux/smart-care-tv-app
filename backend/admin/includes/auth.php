<?php
/** Admin session helpers — session-based login, CSRF token, flash messages. */

require_once __DIR__ . '/../../config.php';

function admin_session_start(): void
{
    if (session_status() !== PHP_SESSION_ACTIVE) {
        session_set_cookie_params([
            'httponly' => true,
            'samesite' => 'Lax',
            // 'secure' => true, // uncomment once served over HTTPS
        ]);
        session_start();
    }
}

/** Call at the top of every protected admin page. */
function require_admin_login(): void
{
    admin_session_start();
    if (empty($_SESSION['admin_id'])) {
        header('Location: login.php');
        exit;
    }
}

function current_admin_username(): string
{
    return $_SESSION['admin_username'] ?? '';
}

// ── CSRF token — one per session, embedded in every mutating form ──────────
function csrf_token(): string
{
    admin_session_start();
    if (empty($_SESSION['csrf_token'])) {
        $_SESSION['csrf_token'] = bin2hex(random_bytes(32));
    }
    return $_SESSION['csrf_token'];
}

function require_csrf(): void
{
    admin_session_start();
    $sent = $_POST['csrf_token'] ?? '';
    if (empty($_SESSION['csrf_token']) || !hash_equals($_SESSION['csrf_token'], $sent)) {
        http_response_code(403);
        die('Invalid CSRF token. Go back and try again.');
    }
}

// ── One-shot flash message shown after a redirect ──────────────────────────
function flash(string $message, string $type = 'success'): void
{
    admin_session_start();
    $_SESSION['flash'] = ['message' => $message, 'type' => $type];
}

function pop_flash(): ?array
{
    admin_session_start();
    if (empty($_SESSION['flash'])) {
        return null;
    }
    $f = $_SESSION['flash'];
    unset($_SESSION['flash']);
    return $f;
}

function h(?string $s): string
{
    return htmlspecialchars($s ?? '', ENT_QUOTES, 'UTF-8');
}
