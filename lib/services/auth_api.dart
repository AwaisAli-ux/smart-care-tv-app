import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'auth_config.dart';

/// Mirrors the `status` values returned by backend/api/login.php and
/// backend/api/check_status.php.
enum AuthStatus {
  ok,
  locked,
  expired,
  deviceLimit,
  invalidToken,
  invalidCredentials,
  error,
  networkError,
}

class XtreamCreds {
  final String host;
  final String username;
  final String password;
  const XtreamCreds({required this.host, required this.username, required this.password});

  factory XtreamCreds.fromJson(Map<String, dynamic> json) => XtreamCreds(
        host: json['host']?.toString() ?? '',
        username: json['username']?.toString() ?? '',
        password: json['password']?.toString() ?? '',
      );
}

class AuthResult {
  final AuthStatus status;
  final String message;
  final String? token;
  final XtreamCreds? xtream;
  final String? expiryDate;

  const AuthResult({
    required this.status,
    this.message = '',
    this.token,
    this.xtream,
    this.expiryDate,
  });

  factory AuthResult.networkError([String msg = 'Could not reach the server. Check your connection.']) =>
      AuthResult(status: AuthStatus.networkError, message: msg);

  factory AuthResult.fromJson(Map<String, dynamic> json) {
    final statusStr = json['status']?.toString() ?? 'error';
    AuthStatus status;
    switch (statusStr) {
      case 'ok': status = AuthStatus.ok; break;
      case 'locked': status = AuthStatus.locked; break;
      case 'expired': status = AuthStatus.expired; break;
      case 'device_limit': status = AuthStatus.deviceLimit; break;
      case 'invalid_token': status = AuthStatus.invalidToken; break;
      default: status = AuthStatus.error;
    }
    final xtreamJson = json['xtream'];
    return AuthResult(
      status: status,
      message: json['message']?.toString() ?? '',
      token: json['token']?.toString(),
      xtream: xtreamJson is Map<String, dynamic> ? XtreamCreds.fromJson(xtreamJson) : null,
      expiryDate: json['expiry_date']?.toString(),
    );
  }
}

/// Talks to the device-binding backend (backend/api/*.php).
class AuthApi {
  static Uri _u(String path) => Uri.parse('${AuthConfig.baseUrl}/$path');

  static Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'X-App-Key': AuthConfig.appKey,
      };

  static Future<AuthResult> login({
    required String username,
    required String password,
    required String deviceId,
    required String deviceModel,
    required String deviceBrand,
  }) async {
    try {
      final res = await http
          .post(
            _u('login.php'),
            headers: _headers,
            body: jsonEncode({
              'username': username,
              'password': password,
              'device_id': deviceId,
              'device_model': deviceModel,
              'device_brand': deviceBrand,
            }),
          )
          .timeout(const Duration(seconds: 20));
      return _parse(res);
    } catch (e) {
      debugPrint('[AuthApi] login() network error: $e');
      return AuthResult.networkError();
    }
  }

  /// Reports a successful direct-IPTV login to the admin backend so it shows
  /// up under Devices (view + remote-lock), without gating the real login —
  /// any outcome besides an explicit "locked" is safe to ignore.
  static Future<AuthResult> trackDevice({
    required String username,
    required String serverUrl,
    required String deviceId,
    required String deviceModel,
    required String deviceBrand,
  }) async {
    try {
      final res = await http
          .post(
            _u('track.php'),
            headers: _headers,
            body: jsonEncode({
              'username': username,
              'server_url': serverUrl,
              'device_id': deviceId,
              'device_model': deviceModel,
              'device_brand': deviceBrand,
            }),
          )
          .timeout(const Duration(seconds: 10));
      return _parse(res);
    } catch (e) {
      debugPrint('[AuthApi] trackDevice() network error: $e');
      return AuthResult.networkError();
    }
  }

  static Future<AuthResult> checkStatus({
    required String token,
    required String deviceId,
  }) async {
    try {
      final res = await http
          .post(
            _u('check_status.php'),
            headers: _headers,
            body: jsonEncode({'token': token, 'device_id': deviceId}),
          )
          .timeout(const Duration(seconds: 15));
      return _parse(res);
    } catch (e) {
      debugPrint('[AuthApi] checkStatus() network error: $e');
      return AuthResult.networkError();
    }
  }

  static AuthResult _parse(http.Response res) {
    if (res.statusCode == 401) {
      try {
        final json = jsonDecode(res.body) as Map<String, dynamic>;
        return AuthResult(status: AuthStatus.invalidCredentials, message: json['message']?.toString() ?? 'Invalid credentials');
      } catch (_) {
        return const AuthResult(status: AuthStatus.invalidCredentials, message: 'Invalid credentials');
      }
    }
    if (res.statusCode == 429) {
      return const AuthResult(status: AuthStatus.error, message: 'Too many attempts. Please try again later.');
    }
    if (res.statusCode == 403) {
      return const AuthResult(status: AuthStatus.error, message: 'Server rejected this app build. Contact support.');
    }
    try {
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      return AuthResult.fromJson(json);
    } catch (e) {
      debugPrint('[AuthApi] Failed to parse response: $e — body: ${res.body}');
      return AuthResult.networkError('Unexpected server response.');
    }
  }
}
