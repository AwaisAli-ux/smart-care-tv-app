-- ─────────────────────────────────────────────────────────────────────────
--  Smart Care TV — Device Binding & Remote Lock System
--  Database schema (MySQL / MariaDB, InnoDB, utf8mb4)
-- ─────────────────────────────────────────────────────────────────────────
-- Import this once via phpMyAdmin / `mysql -u user -p dbname < schema.sql`.
-- Safe to re-run on an empty database only (tables are created, not altered).

SET NAMES utf8mb4;
SET FOREIGN_KEY_CHECKS = 0;

-- ── users ────────────────────────────────────────────────────────────────
-- One row per Smart Care TV customer account (the credentials the customer
-- types into the app). These are NOT the Xtream/IPTV panel credentials —
-- xtream_username/xtream_password below are the *real* portal credentials,
-- only ever handed to the app after a device passes the binding check.
CREATE TABLE IF NOT EXISTS users (
  id INT AUTO_INCREMENT PRIMARY KEY,
  username VARCHAR(100) UNIQUE NOT NULL,
  password_hash VARCHAR(255) NOT NULL,        -- bcrypt via password_hash()
  max_devices INT NOT NULL DEFAULT 1,
  status ENUM('active','locked','expired') NOT NULL DEFAULT 'active',
  expiry_date DATE NULL,                      -- subscription expiry
  xtream_host VARCHAR(255) NULL,              -- e.g. http://panel.example.com:8080
  xtream_username VARCHAR(100) NULL,          -- delivered only to authorized devices
  xtream_password VARCHAR(100) NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ── devices ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS devices (
  id INT AUTO_INCREMENT PRIMARY KEY,
  user_id INT NOT NULL,
  device_id VARCHAR(128) NOT NULL,            -- ANDROID_ID (Settings.Secure.ANDROID_ID)
  device_model VARCHAR(150) NULL,
  device_brand VARCHAR(100) NULL,
  status ENUM('active','locked') NOT NULL DEFAULT 'active',
  first_seen TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  last_seen TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  UNIQUE KEY uniq_user_device (user_id, device_id),
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ── sessions ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS sessions (
  id INT AUTO_INCREMENT PRIMARY KEY,
  user_id INT NOT NULL,
  device_id VARCHAR(128) NOT NULL,
  token CHAR(64) NOT NULL UNIQUE,             -- bin2hex(random_bytes(32))
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  expires_at TIMESTAMP NOT NULL,
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ── login_attempts ───────────────────────────────────────────────────────
-- Backs the login rate limiter (max 10 attempts / IP / 10 minutes).
CREATE TABLE IF NOT EXISTS login_attempts (
  id INT AUTO_INCREMENT PRIMARY KEY,
  ip_address VARCHAR(45) NOT NULL,
  attempted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  INDEX idx_ip_time (ip_address, attempted_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ── admin_users ──────────────────────────────────────────────────────────
-- Accounts for the admin panel (separate from customer `users`).
CREATE TABLE IF NOT EXISTS admin_users (
  id INT AUTO_INCREMENT PRIMARY KEY,
  username VARCHAR(100) UNIQUE NOT NULL,
  password_hash VARCHAR(255) NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

SET FOREIGN_KEY_CHECKS = 1;
