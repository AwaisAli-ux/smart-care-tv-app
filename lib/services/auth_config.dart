// ─── Device-binding backend configuration ──────────────────────────────────
// Points the app at the PHP backend in /backend (see backend/README.md for
// deployment steps). Update these two values after you deploy the backend.
class AuthConfig {
  /// Base URL of the backend's api/ folder — NO trailing slash.
  /// e.g. 'https://your-domain.com/backend/api'
  static const String baseUrl = 'http://192.168.1.12/backend/api';

  /// Must exactly match APP_KEY in backend/config.php.
  static const String appKey = 'a3f9c2e7b1d84f6098a5c3e2b7d1f409c8e6a2b5d7f1093c4e8b2a6d9f3c1e70';

  /// How often the app silently re-validates the device while running.
  static const Duration recheckInterval = Duration(hours: 6);

  /// Max time allowed offline (no successful check_status) before the app
  /// blocks access and requires a fresh successful check.
  static const Duration offlineGracePeriod = Duration(hours: 24);

  /// Support contact shown on the Locked / Expired / Device-limit screens.
  static const String supportContact = '+1 (555) 010-0100';
  static const String supportContactLabel = 'Contact Support';
}
