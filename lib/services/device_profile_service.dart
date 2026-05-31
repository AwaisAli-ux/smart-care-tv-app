import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'iptv_service.dart';

// ── Device class enum ─────────────────────────────────────────────────────────
// Covers every major worldwide TV brand + generic fallback.
enum DeviceClass {
  samsung,
  lg,
  sony,
  mi,            // Xiaomi / Mi Box / Mi TV Stick
  haier,
  hisense,
  tcl,
  philips,
  panasonic,
  sharp,
  skyworth,
  toshiba,
  roku,
  fireTv,        // Amazon Fire TV / Fire Stick
  appleTV,
  androidTv,     // Generic certified Android TV
  nvidia,        // Nvidia Shield
  generic,       // Any other Android device / box
}

// ── Quality tier enum ─────────────────────────────────────────────────────────
enum QualityTier { auto, uhd4k, fhd1080, hd720, sd480, low360 }

// ── DeviceProfile ─────────────────────────────────────────────────────────────
/// Immutable snapshot of a device's capabilities and the optimal playback
/// configuration derived from them. Created once at app startup.
class DeviceProfile {
  final DeviceClass deviceClass;
  final String brand;
  final String manufacturer;
  final String model;
  final String osVersion;
  final int sdkInt;
  final int totalRamMb;

  // Codec flags
  final bool supportsHevc;
  final bool supportsHdr;
  final bool supportsAv1;
  final bool supportsVp9;
  final bool supportsH264;
  final bool supportsAac;
  final bool supportsAc3;
  final bool supportsEac3;
  final List<String> supportedVideoCodecs;

  // Derived playback config
  /// When true, set vd-lavc-vcodec=h264 to block HEVC decoding attempt
  final bool forceH264;
  /// When true, disable HDR tone-mapping (clip) to avoid black-screen on SDR displays
  final bool disableHdr;
  /// When true, set video-latency-hacks=yes (needed for Amlogic S905/S912/S922X live streams)
  final bool enableLatencyHacks;
  /// When true, use hardware decoding (only safe on Qualcomm/Tegra flagships)
  final bool useHardwareAccel;
  /// Optimal buffer size in bytes, capped by actual device RAM
  final int optimalBufferBytes;
  /// Device-appropriate User-Agent string
  final String userAgent;
  /// Full HTTP headers map (UA + Referer + Origin + extras)
  final Map<String, String> streamHeaders;

  const DeviceProfile({
    required this.deviceClass,
    required this.brand,
    required this.manufacturer,
    required this.model,
    required this.osVersion,
    required this.sdkInt,
    required this.totalRamMb,
    required this.supportsHevc,
    required this.supportsHdr,
    required this.supportsAv1,
    required this.supportsVp9,
    required this.supportsH264,
    required this.supportsAac,
    required this.supportsAc3,
    required this.supportsEac3,
    required this.supportedVideoCodecs,
    required this.forceH264,
    required this.disableHdr,
    required this.enableLatencyHacks,
    required this.useHardwareAccel,
    required this.optimalBufferBytes,
    required this.userAgent,
    required this.streamHeaders,
  });

  @override
  String toString() => 'DeviceProfile('
      'class=$deviceClass, brand=$brand, model=$model, '
      'ram=${totalRamMb}MB, hevc=$supportsHevc, hdr=$supportsHdr, '
      'buf=${optimalBufferBytes ~/ (1024 * 1024)}MB, '
      'hwAccel=$useHardwareAccel, forceH264=$forceH264)';
}

// ── DeviceProfileService ──────────────────────────────────────────────────────
/// Singleton service. Call [detect()] once during app startup, then access
/// the result any time via [currentProfile].
class DeviceProfileService {
  DeviceProfileService._();
  static final DeviceProfileService instance = DeviceProfileService._();

  static const _ch = MethodChannel('com.example.mbapp/device_info');

  DeviceProfile? _profile;
  DeviceProfile get currentProfile => _profile ?? _genericFallbackProfile();

  // ── Public API ──────────────────────────────────────────────────────────────

  /// Queries the native Android channel for device capabilities and builds a
  /// [DeviceProfile]. Safe to call multiple times — returns cached result.
  Future<DeviceProfile> detect() async {
    if (_profile != null) return _profile!;
    try {
      final raw = await _ch.invokeMapMethod<String, dynamic>('getDeviceInfo');
      if (raw != null) {
        _profile = _build(raw);
        debugPrint('[DeviceProfile] Detected: $_profile');
        return _profile!;
      }
    } catch (e) {
      debugPrint('[DeviceProfile] Native channel error: $e — using generic fallback');
    }
    _profile = _genericFallbackProfile();
    debugPrint('[DeviceProfile] Using fallback: $_profile');
    return _profile!;
  }

  // ── Builder ─────────────────────────────────────────────────────────────────

  DeviceProfile _build(Map<String, dynamic> raw) {
    final brand        = (raw['brand']        as String? ?? '').toLowerCase();
    final manufacturer = (raw['manufacturer'] as String? ?? '').toLowerCase();
    final model        = raw['model']        as String? ?? '';
    final osVersion    = raw['osVersion']    as String? ?? '';
    final sdkInt       = raw['sdkInt']       as int?    ?? 21;
    final totalRamMb   = raw['totalRamMb']   as int?    ?? 512;

    final supportsHevc = raw['supportsHevc']  as bool? ?? false;
    final supportsHdr  = raw['supportsHdr']   as bool? ?? false;
    final supportsAv1  = raw['supportsAv1']   as bool? ?? false;
    final supportsVp9  = raw['supportsVp9']   as bool? ?? false;
    final supportsH264 = raw['supportsH264']  as bool? ?? true;
    final supportsAac  = raw['supportsAac']   as bool? ?? true;
    final supportsAc3  = raw['supportsAc3']   as bool? ?? false;
    final supportsEac3 = raw['supportsEac3']  as bool? ?? false;
    final supportedVideoCodecs = (raw['supportedVideoCodecs'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        [];

    // ── Classify device ────────────────────────────────────────────────────
    final cls = _classifyDevice(brand, manufacturer, model);

    // ── Derive optimal settings from hardware ──────────────────────────────

    // Force H.264 if device cannot decode HEVC
    final forceH264 = !supportsHevc;

    // Disable HDR tone-mapping on SDR-only displays
    final disableHdr = !supportsHdr;

    // Amlogic latency hacks: Amlogic SoCs are used in: Xiaomi Mi Box,
    // most generic Chinese boxes, many Hisense/Skyworth/Haier internal chips.
    final enableLatencyHacks = _isAmlogicLikely(cls, brand, manufacturer, model);

    // Hardware acceleration: only safe on Qualcomm (Snapdragon) and Nvidia Tegra.
    // Amlogic, Rockchip, MediaTek, Mali GPU cause scrambled/green video with HW decoding.
    final useHardwareAccel = _isHwAccelSafe(cls, brand, manufacturer);

    // RAM-adaptive buffer: protect low-RAM devices from OOM.
    // These values override the user's Settings selection if RAM is insufficient.
    final optimalBufferBytes = _bufferFromRam(totalRamMb);

    // Device-specific User-Agent
    final ua = _buildUserAgent(cls, model, osVersion, sdkInt);

    // Stream headers — UA + Referer for this device
    final headers = _buildHeaders(ua);

    return DeviceProfile(
      deviceClass: cls,
      brand: brand,
      manufacturer: manufacturer,
      model: model,
      osVersion: osVersion,
      sdkInt: sdkInt,
      totalRamMb: totalRamMb,
      supportsHevc: supportsHevc,
      supportsHdr: supportsHdr,
      supportsAv1: supportsAv1,
      supportsVp9: supportsVp9,
      supportsH264: supportsH264,
      supportsAac: supportsAac,
      supportsAc3: supportsAc3,
      supportsEac3: supportsEac3,
      supportedVideoCodecs: supportedVideoCodecs,
      forceH264: forceH264,
      disableHdr: disableHdr,
      enableLatencyHacks: enableLatencyHacks,
      useHardwareAccel: useHardwareAccel,
      optimalBufferBytes: optimalBufferBytes,
      userAgent: ua,
      streamHeaders: headers,
    );
  }

  // ── Classification ──────────────────────────────────────────────────────────

  DeviceClass _classifyDevice(String brand, String manufacturer, String model) {
    final m = model.toLowerCase();
    final b = brand;
    final mfr = manufacturer;

    if (b.contains('samsung') || mfr.contains('samsung')) return DeviceClass.samsung;
    if (b.contains('lg') || mfr.contains('lg')) return DeviceClass.lg;
    if (b.contains('sony') || mfr.contains('sony')) return DeviceClass.sony;

    // Xiaomi / Mi — covers Mi Box S, Mi TV Stick, Poco, Redmi
    if (b.contains('xiaomi') || b.contains('mi') || mfr.contains('xiaomi') ||
        m.contains('mi box') || m.contains('mi tv') || m.contains('mibox') ||
        m.contains('mi stick')) {
      return DeviceClass.mi;
    }

    if (b.contains('haier') || mfr.contains('haier')) return DeviceClass.haier;
    if (b.contains('hisense') || mfr.contains('hisense')) return DeviceClass.hisense;
    if (b.contains('tcl') || mfr.contains('tcl')) return DeviceClass.tcl;
    if (b.contains('philips') || mfr.contains('philips') || mfr.contains('tp vision')) {
      return DeviceClass.philips;
    }
    if (b.contains('panasonic') || mfr.contains('panasonic')) return DeviceClass.panasonic;
    if (b.contains('sharp') || mfr.contains('sharp')) return DeviceClass.sharp;
    if (b.contains('skyworth') || mfr.contains('skyworth')) return DeviceClass.skyworth;
    if (b.contains('toshiba') || mfr.contains('toshiba')) return DeviceClass.toshiba;

    // Roku — their Android builds report "Roku" as brand
    if (b.contains('roku') || mfr.contains('roku')) return DeviceClass.roku;

    // Amazon Fire TV — brand="Amazon" or model contains "AFTT","AFTN","AFTM","AFTB"
    if (b.contains('amazon') || mfr.contains('amazon') ||
        m.contains('aft') || m.contains('fire tv') || m.contains('firetv')) {
      return DeviceClass.fireTv;
    }

    // Apple TV — would only appear in a non-Flutter path; included for completeness
    if (b.contains('apple') || mfr.contains('apple')) return DeviceClass.appleTV;

    // Nvidia Shield
    if (b.contains('nvidia') || mfr.contains('nvidia') || m.contains('shield')) {
      return DeviceClass.nvidia;
    }

    // Google/ADT/Chromecast = Android TV
    if (b.contains('google') || mfr.contains('google') ||
        m.contains('android tv') || m.contains('chromecast') ||
        m.contains('adt-') || b.contains('adt')) {
      return DeviceClass.androidTv;
    }

    return DeviceClass.generic;
  }

  // ── Amlogic detection ───────────────────────────────────────────────────────
  bool _isAmlogicLikely(DeviceClass cls, String brand, String manufacturer, String model) {
    // Classes whose mainstream products use Amlogic SoCs
    if (cls == DeviceClass.mi || cls == DeviceClass.generic ||
        cls == DeviceClass.hisense || cls == DeviceClass.skyworth ||
        cls == DeviceClass.haier) {
      return true;
    }
    final m = model.toLowerCase();
    // Common Amlogic model strings
    return m.contains('s905') || m.contains('s912') || m.contains('s922') ||
        m.contains('s928') || m.contains('amlogic') ||
        m.contains('x96') || m.contains('h96') || m.contains('mxq') ||
        manufacturer.contains('amlogic');
  }

  // ── HW accel safety ─────────────────────────────────────────────────────────
  bool _isHwAccelSafe(DeviceClass cls, String brand, String manufacturer) {
    // Qualcomm Snapdragon (Samsung flagship, Sony) and Nvidia Tegra are
    // safe for hardware decoding. Everything else risks scrambled video.
    if (cls == DeviceClass.nvidia) return true;
    if (cls == DeviceClass.samsung || cls == DeviceClass.sony) {
      // Only flagship Samsung/Sony use Snapdragon — mid/low range use Exynos/MediaTek
      // Conservative: leave HW accel OFF by default; user can enable in Settings
      return false;
    }
    return false; // Safe universal default: always SW decode
  }

  // ── Buffer from RAM ─────────────────────────────────────────────────────────
  int _bufferFromRam(int totalRamMb) {
    if (totalRamMb <= 1024) return  24 * 1024 * 1024; //  24 MB — ≤1 GB RAM
    if (totalRamMb <= 2048) return  48 * 1024 * 1024; //  48 MB — 1–2 GB RAM
    if (totalRamMb <= 4096) return  96 * 1024 * 1024; //  96 MB — 2–4 GB RAM
    return                         128 * 1024 * 1024;  // 128 MB — >4 GB RAM
  }

  // ── User-Agent builder ──────────────────────────────────────────────────────
  /// Builds a device-class-appropriate UA string.
  /// Correct UAs are critical: CDN proxies and IPTV servers often enforce UA whitelists.
  String _buildUserAgent(DeviceClass cls, String model, String osVersion, int sdkInt) {
    switch (cls) {
      case DeviceClass.samsung:
        // Samsung Tizen Smart TV — accepted by most Korean content CDNs
        return 'Mozilla/5.0 (SMART-TV; Linux; Tizen 6.5) AppleWebKit/538.1 '
            '(KHTML, like Gecko) Version/6.5 TV Safari/538.1';

      case DeviceClass.lg:
        // LG webOS Smart TV
        return 'Mozilla/5.0 (Web0S; Linux/SmartTV) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/87.0.4280.88 Safari/537.36 WebAppManager';

      case DeviceClass.sony:
        // Sony Bravia — Android TV variant
        return 'Mozilla/5.0 (Linux; Android $osVersion; $model Build/STB-G5) '
            'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/109.0.0.0 Safari/537.36 '
            'SonyCEBrowser/3.0 (BraviaAndroidTV)';

      case DeviceClass.roku:
        // Roku DVP UA — required by Roku channel servers
        return 'Roku/DVP-12.5 (641.12.5E04185A)';

      case DeviceClass.fireTv:
        // Amazon Fire TV / Fire Stick UA
        return 'Mozilla/5.0 (Linux; Android $osVersion; $model Build/PS7233) '
            'AppleWebKit/537.36 (KHTML, like Gecko) Silk/3.68 like Chrome/39.0.2171.93 '
            'Safari/537.36 AmazonWebAppPlatform/3.5;2.0';

      case DeviceClass.appleTV:
        // Apple TV / tvOS UA
        return 'AppleCoreMedia/1.0.0.21J353 (Apple TV; U; CPU OS 17_0 like Mac OS X; en_us)';

      case DeviceClass.nvidia:
        // Nvidia Shield — standard Android TV Chrome UA works well
        return 'Mozilla/5.0 (Linux; Android $osVersion; $model) '
            'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 '
            'NvidiaShieldTV/1.0';

      case DeviceClass.mi:
        // Xiaomi Mi Box / Mi TV Stick — uses standard Android TV UA
        return 'Mozilla/5.0 (Linux; Android $osVersion; $model Build/QRD-N) '
            'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/115.0.0.0 Mobile Safari/537.36';

      case DeviceClass.tcl:
        return 'Mozilla/5.0 (Linux; Android $osVersion; $model) '
            'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/110.0.0.0 Safari/537.36 TCL/Android-TV';

      case DeviceClass.philips:
        return 'Mozilla/5.0 (Linux; Android $osVersion; $model) '
            'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/108.0.0.0 Safari/537.36 Philips-AndroidTV';

      case DeviceClass.hisense:
        return 'Mozilla/5.0 (Linux; Android $osVersion; $model) '
            'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/112.0.0.0 Safari/537.36 HiSenseAndroidTV';

      case DeviceClass.haier:
      case DeviceClass.panasonic:
      case DeviceClass.sharp:
      case DeviceClass.skyworth:
      case DeviceClass.toshiba:
      case DeviceClass.androidTv:
        // Generic Android TV UA — safe for all other brands
        return 'Mozilla/5.0 (Linux; Android $osVersion; $model) '
            'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

      case DeviceClass.generic:
        // Most compatible generic Mobile Chrome UA — broadest CDN acceptance
        return 'Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';
    }
  }

  // ── Headers builder ─────────────────────────────────────────────────────────
  Map<String, String> _buildHeaders(String ua) {
    return {
      'User-Agent': ua,
      'Accept': '*/*',
      'Accept-Language': 'en-US,en;q=0.9',
      'Accept-Encoding': 'identity', // Avoid gzip/br for raw TS/HLS streams
      'Connection': 'keep-alive',
      'Referer': '${IptvService.baseUrl}/',
      'Origin': IptvService.baseUrl,
      'Icy-MetaData': '1',
      'X-Forwarded-For': '0.0.0.0', // Some geo-locked CDNs need this
    };
  }

  // ── Generic fallback ────────────────────────────────────────────────────────
  DeviceProfile _genericFallbackProfile() {
    const ua = 'Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';
    return const DeviceProfile(
      deviceClass: DeviceClass.generic,
      brand: 'generic',
      manufacturer: 'generic',
      model: 'Unknown',
      osVersion: '13',
      sdkInt: 33,
      totalRamMb: 1024,
      supportsHevc: false,   // Conservative: assume no HEVC support
      supportsHdr: false,
      supportsAv1: false,
      supportsVp9: true,
      supportsH264: true,
      supportsAac: true,
      supportsAc3: false,
      supportsEac3: false,
      supportedVideoCodecs: [],
      forceH264: true,       // Force H.264 — safest universal codec
      disableHdr: true,
      enableLatencyHacks: true,
      useHardwareAccel: false,
      optimalBufferBytes: 32 * 1024 * 1024, // 32 MB — safe for unknown RAM
      userAgent: ua,
      streamHeaders: {
        'User-Agent': ua,
        'Accept': '*/*',
        'Accept-Language': 'en-US,en;q=0.9',
        'Accept-Encoding': 'identity',
        'Connection': 'keep-alive',
        'Referer': '${IptvService.baseUrl}/',
        'Origin': IptvService.baseUrl,
        'Icy-MetaData': '1',
      },
    );
  }

  // ── Quality-tier helpers ────────────────────────────────────────────────────

  /// Maps the user-facing quality string from Settings to a [QualityTier].
  static QualityTier qualityTierFromSetting(String setting) {
    switch (setting) {
      case '4K Ultra HD': return QualityTier.uhd4k;
      case '1080p Full HD': return QualityTier.fhd1080;
      case '720p HD': return QualityTier.hd720;
      case '480p SD': return QualityTier.sd480;
      case 'Auto (Recommended)':
      default: return QualityTier.auto;
    }
  }

  /// Returns the mpv property value for `video-params/video-output-levels`
  /// based on the selected quality tier. Also drives max-resolution capping.
  static String? mpvMaxResolutionForTier(QualityTier tier) {
    switch (tier) {
      case QualityTier.sd480:  return '854x480';
      case QualityTier.hd720:  return '1280x720';
      case QualityTier.fhd1080: return '1920x1080';
      case QualityTier.uhd4k:  return '3840x2160';
      case QualityTier.low360: return '640x360';
      case QualityTier.auto:   return null; // no cap
    }
  }
}
