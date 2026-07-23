import 'device_profile_service.dart';

/// Identity info the device-binding backend needs: a stable per-device ID
/// plus brand/model for the admin panel's device list.
///
/// Reuses the native `com.smartcaretv.app/device_info` channel that
/// [DeviceProfileService] already queries at app startup (it reads
/// `Settings.Secure.ANDROID_ID` on the Android side) instead of adding the
/// `device_info_plus` package — same stable ID, one fewer dependency.
/// See backend/README.md ("Design defaults") for the rationale.
class DeviceIdentity {
  final String deviceId;
  final String model;
  final String brand;
  const DeviceIdentity({
    required this.deviceId,
    required this.model,
    required this.brand,
  });
}

class DeviceService {
  /// Resolves device identity, detecting hardware info on first call if it
  /// hasn't already run (e.g. in tests or if main() ordering changes).
  static Future<DeviceIdentity> get() async {
    final profile = await DeviceProfileService.instance.detect();
    return DeviceIdentity(
      deviceId: profile.deviceId,
      model: profile.model,
      brand: profile.brand,
    );
  }
}
