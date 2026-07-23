import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'auth_api.dart';
import 'auth_config.dart';
import 'device_service.dart';
import 'iptv_service.dart';
import '../screens/locked_screen.dart';
import '../screens/expired_screen.dart';
import '../screens/login_screen.dart';
import '../screens/main_shell.dart';

/// Prefs keys shared with login_screen.dart / splash_screen.dart.
/// 'username' / 'password' / 'serverUrl' are reused for the *Xtream*
/// credentials (kept as-is so IptvService/AppState/content loading needs no
/// changes); 'sc_token' + 'sc_last_check' are new, for the Smart Care TV
/// account session and the offline-grace-period clock.
class AuthPrefsKeys {
  static const loggedIn = 'loggedIn';
  static const username = 'username';
  static const password = 'password';
  static const serverUrl = 'serverUrl';
  static const scToken = 'sc_token';
  static const scLastCheck = 'sc_last_check';
}

/// App-wide watchdog: periodically (and on resume) re-validates this device
/// against the backend, and — the moment it's told to — replaces the entire
/// navigation stack with [LockedScreen] / [ExpiredScreen] / [LoginScreen].
///
/// Started once from main.dart via [DeviceLockService.instance.start] with
/// the app's [GlobalKey<NavigatorState>]. Every call is a no-op if the user
/// isn't logged in yet (checked via SharedPreferences each time), so it's
/// safe to have this running for the whole app lifetime.
class DeviceLockService {
  DeviceLockService._();
  static final DeviceLockService instance = DeviceLockService._();

  GlobalKey<NavigatorState>? _navigatorKey;
  Timer? _timer;
  bool _uiBlocked = false;
  bool _checking = false;

  void start(GlobalKey<NavigatorState> navigatorKey) {
    _navigatorKey = navigatorKey;
    _timer?.cancel();
    _timer = Timer.periodic(AuthConfig.recheckInterval, (_) => checkNow());
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }

  /// Called on app resume (see main.dart's WidgetsBindingObserver) and by
  /// the periodic timer. Safe to call anytime — no-ops if not logged in.
  Future<void> checkNow() async {
    if (_checking) return; // avoid overlapping checks from resume + timer
    _checking = true;
    try {
      final nav = _navigatorKey;
      if (nav == null) return;

      final prefs = await SharedPreferences.getInstance();
      final loggedIn = prefs.getBool(AuthPrefsKeys.loggedIn) ?? false;
      final token = prefs.getString(AuthPrefsKeys.scToken);
      if (!loggedIn || token == null || token.isEmpty) return;

      final device = await DeviceService.get();
      final result = await AuthApi.checkStatus(token: token, deviceId: device.deviceId);

      switch (result.status) {
        case AuthStatus.ok:
          await prefs.setInt(AuthPrefsKeys.scLastCheck, DateTime.now().millisecondsSinceEpoch);
          final xtream = result.xtream;
          if (xtream != null && xtream.host.isNotEmpty) {
            await prefs.setString(AuthPrefsKeys.serverUrl, xtream.host);
            await prefs.setString(AuthPrefsKeys.username, xtream.username);
            await prefs.setString(AuthPrefsKeys.password, xtream.password);
            IptvService.setBaseUrl(xtream.host);
          }
          if (_uiBlocked) {
            debugPrint('[DeviceLockService] Access restored — returning to app');
            _uiBlocked = false;
            nav.currentState?.pushAndRemoveUntil(
              MaterialPageRoute(builder: (_) => const MainShell()),
              (route) => false,
            );
          }
          break;

        case AuthStatus.locked:
          _block(nav, const LockedScreen(reason: LockReason.locked));
          break;

        case AuthStatus.expired:
          _block(nav, ExpiredScreen(expiryDate: result.expiryDate));
          break;

        case AuthStatus.invalidToken:
          await _forceLogout(prefs, nav);
          break;

        case AuthStatus.networkError:
        case AuthStatus.error:
        case AuthStatus.deviceLimit:
        case AuthStatus.invalidCredentials:
          final lastCheck = prefs.getInt(AuthPrefsKeys.scLastCheck) ?? 0;
          final elapsed = DateTime.now().millisecondsSinceEpoch - lastCheck;
          final graceExpired = lastCheck == 0 || elapsed > AuthConfig.offlineGracePeriod.inMilliseconds;
          if (graceExpired) {
            _block(
              nav,
              LockedScreen(reason: LockReason.offline, onRetry: checkNow),
            );
          } else {
            debugPrint('[DeviceLockService] Check failed but within grace period — ignoring');
          }
          break;
      }
    } finally {
      _checking = false;
    }
  }

  void _block(GlobalKey<NavigatorState> nav, Widget screen) {
    _uiBlocked = true;
    nav.currentState?.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => screen),
      (route) => false,
    );
  }

  Future<void> _forceLogout(SharedPreferences prefs, GlobalKey<NavigatorState> nav) async {
    debugPrint('[DeviceLockService] Invalid/expired session — forcing re-login');
    _uiBlocked = false;
    await prefs.setBool(AuthPrefsKeys.loggedIn, false);
    await prefs.remove(AuthPrefsKeys.scToken);
    await prefs.remove(AuthPrefsKeys.scLastCheck);
    nav.currentState?.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }
}
