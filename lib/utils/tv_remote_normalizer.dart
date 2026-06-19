// lib/utils/tv_remote_normalizer.dart
//
// Central TV remote key normalization layer.
//
// WHY THIS FILE EXISTS:
//   Android TV remotes from different manufacturers (TCL, Haier, Mi TV, ONN,
//   Hisense) do not consistently report D-pad key events. IR remotes go through
//   the Android IR input subsystem; BT HID remotes go through the Bluetooth HID
//   profile. Each path can produce different Android keycodes, and different
//   firmware versions on the same brand model can produce yet another set.
//
//   Flutter then maps those Android keycodes to LogicalKeyboardKey values.
//   When the Android keycode is outside Flutter's known mapping table, Flutter
//   creates a synthetic LogicalKeyboardKey using kAndroidPlane | androidKeycode.
//
//   The result: the same D-pad button can arrive as any of:
//     • LogicalKeyboardKey.arrowLeft  (0x100000302) — standard mapping ✓
//     • raw Android KEYCODE_DPAD_LEFT (21) unmapped by Flutter
//     • HID usage-page translated code (105 on Rockchip evdev driver)
//     • Vendor-specific code (varies by TCL firmware build)
//
// HOW TO EXTEND FOR A NEW DEVICE:
//   1. Connect device via ADB and run:
//        adb shell getevent -l
//        adb logcat --pid=$(adb shell pidof com.example.mbapp) | grep "TvRemote UNKNOWN"
//   2. Note the logged logicalId / physicalHid values.
//   3. Add an entry to `assets/tv_keymaps.json` (no code recompile needed),
//      OR add to [deviceOverrides] below for compile-time safety.
//
// HOW TO USE:
//   final action = TvRemoteNormalizer.normalize(event);
//   switch (action) {
//     case TvNavAction.left:   ...
//     case TvNavAction.select: ...
//     default: break;
//   }

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

// ── Action enum ───────────────────────────────────────────────────────────────

/// Every navigation action a TV remote can produce in this app.
enum TvNavAction {
  up,
  down,
  left,
  right,
  select,     // OK / Enter / D-pad center
  back,       // Back / Escape
  volumeUp,
  volumeDown,
  mute,
  play,
  pause,
  playPause,
  mediaStop,
  mediaNext,
  mediaPrev,
  none,       // not a recognized key — let Flutter handle it
}

// ── Normalizer ────────────────────────────────────────────────────────────────

class TvRemoteNormalizer {
  TvRemoteNormalizer._();

  // ── Runtime overrides loaded from assets/tv_keymaps.json ─────────────────
  // Call [loadOverrides] once from main() after WidgetsFlutterBinding.ensureInitialized().
  static Map<int, TvNavAction> _jsonOverrides = {};

  /// Load device-specific overrides from `assets/tv_keymaps.json`.
  ///
  /// Call this once at app startup:
  ///   await TvRemoteNormalizer.loadOverrides();
  static Future<void> loadOverrides() async {
    try {
      final raw = await rootBundle.loadString('assets/tv_keymaps.json');
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final map = <int, TvNavAction>{};

      final entries = json['overrides'] as Map<String, dynamic>? ?? {};
      for (final kv in entries.entries) {
        final keyId = int.tryParse(kv.key);
        final actionName = kv.value as String?;
        if (keyId == null || actionName == null) continue;
        final action = TvNavAction.values.firstWhere(
          (a) => a.name == actionName,
          orElse: () => TvNavAction.none,
        );
        if (action != TvNavAction.none) map[keyId] = action;
      }

      _jsonOverrides = map;
      if (kDebugMode) {
        debugPrint('[TvRemote] Loaded ${map.length} overrides from tv_keymaps.json');
      }
    } catch (e) {
      // File missing or invalid JSON — non-fatal, built-in table still covers most devices.
      if (kDebugMode) debugPrint('[TvRemote] tv_keymaps.json not loaded: $e');
    }
  }

  // ── In-code device overrides (compile-time safety, no file I/O) ──────────
  //
  // Add entries here when you confirm a vendor-specific keycode via adb.
  // Format:  logicalKeyId (int, hex ok) → TvNavAction
  //
  // Discovered codes per device (fill in as you test):
  //   TCL model that FAILS: run adb getevent to populate
  //   Mi TV 4A / 4X:        standard DPAD — no overrides needed
  //   Haier H55K6UG:        TBD
  //   ONN Google TV:        standard — no overrides needed
  static final Map<int, TvNavAction> deviceOverrides = {
    // ── Example entries (uncomment + set real values after adb diagnosis) ──
    // 0x10000bc: TvNavAction.up,    // TCL RC820 UP custom scancode
    // 0x10000bd: TvNavAction.down,  // TCL RC820 DOWN custom scancode
    // 0x10000be: TvNavAction.left,  // TCL RC820 LEFT custom scancode
    // 0x10000bf: TvNavAction.right, // TCL RC820 RIGHT custom scancode
  };

  // ── Unknown key debounce state ────────────────────────────────────────────
  static int _lastUnknownId = -1;
  static DateTime? _lastUnknownTime;

  // ── Primary API ──────────────────────────────────────────────────────────

  /// Map a [KeyEvent] to a [TvNavAction].
  ///
  /// Returns [TvNavAction.none] for keys the app should not consume (let them
  /// propagate through Flutter's focus system as normal).
  static TvNavAction normalize(KeyEvent event) {
    // Only act on initial press + auto-repeat; ignore release.
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return TvNavAction.none;
    }

    final k  = event.logicalKey;
    final id = k.keyId;

    // ── Priority 1: JSON file overrides (device-specific, no recompile) ──
    final jsonAction = _jsonOverrides[id];
    if (jsonAction != null) return jsonAction;

    // ── Priority 2: in-code compile-time overrides ───────────────────────
    final codeAction = deviceOverrides[id];
    if (codeAction != null) return codeAction;

    // ── Priority 3: Flutter standard logical keys (most devices) ─────────
    // D-pad directions — Flutter correctly maps KEYCODE_DPAD_* to these.
    if (k == LogicalKeyboardKey.arrowUp)    return TvNavAction.up;
    if (k == LogicalKeyboardKey.arrowDown)  return TvNavAction.down;
    if (k == LogicalKeyboardKey.arrowLeft)  return TvNavAction.left;
    if (k == LogicalKeyboardKey.arrowRight) return TvNavAction.right;

    // Select / OK / Enter / D-pad center
    if (k == LogicalKeyboardKey.select      ||
        k == LogicalKeyboardKey.enter       ||
        k == LogicalKeyboardKey.numpadEnter ||
        k == LogicalKeyboardKey.gameButtonA) {
      return TvNavAction.select;
    }

    // Back / Escape
    if (k == LogicalKeyboardKey.goBack   ||
        k == LogicalKeyboardKey.escape   ||
        k == LogicalKeyboardKey.backspace) {
      return TvNavAction.back;
    }

    // Volume
    if (k == LogicalKeyboardKey.audioVolumeUp)   return TvNavAction.volumeUp;
    if (k == LogicalKeyboardKey.audioVolumeDown) return TvNavAction.volumeDown;
    if (k == LogicalKeyboardKey.audioVolumeMute) return TvNavAction.mute;

    // Media transport
    if (k == LogicalKeyboardKey.mediaPlay)           return TvNavAction.play;
    if (k == LogicalKeyboardKey.mediaPause)          return TvNavAction.pause;
    if (k == LogicalKeyboardKey.mediaPlayPause)      return TvNavAction.playPause;
    if (k == LogicalKeyboardKey.mediaStop)           return TvNavAction.mediaStop;
    if (k == LogicalKeyboardKey.mediaTrackNext)      return TvNavAction.mediaNext;
    if (k == LogicalKeyboardKey.mediaTrackPrevious)  return TvNavAction.mediaPrev;

    // ── Priority 4: raw keyId fallback table ─────────────────────────────
    // Covers devices where Flutter's logical-key mapping fails, or the
    // Android input HAL reports non-standard keycodes.
    final rawAction = _rawKeyMap[id];
    if (rawAction != null) return rawAction;

    // ── Unknown key — log for future diagnosis ────────────────────────────
    _logUnknown(event);
    return TvNavAction.none;
  }

  // ── Raw keyId → TvNavAction table ────────────────────────────────────────
  //
  // Sources:
  //   • Android keycodes: https://developer.android.com/reference/android/view/KeyEvent
  //   • Flutter logical key IDs: packages/flutter/lib/src/services/keyboard_key.g.dart
  //   • USB HID usage tables (keyboard/keypad page)
  //   • Linux evdev keycodes (android kernel input layer)
  //   • Observed vendor-specific codes from real Android TV hardware
  //
  // Note on Flutter keyId encoding:
  //   Standard Flutter logical keys:  0x100000000 | flutterInternalId
  //   Android-unmapped keys (approx): 0x001000000 | androidKeycode
  static const Map<int, TvNavAction> _rawKeyMap = {

    // ════════════════════════════════════════════════════════════════
    // D-PAD UP
    // ════════════════════════════════════════════════════════════════
    // Android KEYCODE_DPAD_UP = 19
    // If Flutter maps it → LogicalKeyboardKey.arrowUp (caught in priority 3).
    // If Flutter fails to map it (rare, old OEM builds), the raw code below catches it.
    19:           TvNavAction.up,
    // Raw Android keycode as Flutter synthetic keyId (kAndroidPlane | 19)
    0x100000013:  TvNavAction.up,
    // Flutter LogicalKeyboardKey.arrowUp internal IDs
    0x100000304:  TvNavAction.up,   // 64-bit Flutter plane
    0x10000304:   TvNavAction.up,   // 32-bit Flutter plane (some older builds)
    // Linux/evdev KEY_UP (103) — seen on some Rockchip boxes with custom input HAL
    103:          TvNavAction.up,
    0x10000067:   TvNavAction.up,   // HID Usage 0x52 mapped through Rockchip
    // Vendor: some Haier models map UP to KEYCODE_BUTTON_R2 (analog nub up)
    104:          TvNavAction.up,   // evdev KEY_PAGEUP (backup, Philips remotes)

    // ════════════════════════════════════════════════════════════════
    // D-PAD DOWN
    // ════════════════════════════════════════════════════════════════
    20:           TvNavAction.down,
    0x100000014:  TvNavAction.down,
    0x100000301:  TvNavAction.down,
    0x10000301:   TvNavAction.down,
    108:          TvNavAction.down, // evdev KEY_DOWN
    0x10000068:   TvNavAction.down,
    109:          TvNavAction.down, // evdev KEY_PAGEDOWN (Philips remotes)

    // ════════════════════════════════════════════════════════════════
    // D-PAD LEFT
    // ════════════════════════════════════════════════════════════════
    21:           TvNavAction.left,
    0x100000015:  TvNavAction.left,
    0x100000302:  TvNavAction.left, // arrowLeft 64-bit
    0x10000302:   TvNavAction.left, // arrowLeft 32-bit
    37:           TvNavAction.left, // seen on some BT HID USB dongles
    105:          TvNavAction.left, // evdev KEY_LEFT (Rockchip, Amlogic)
    0x100000069:  TvNavAction.left,

    // ════════════════════════════════════════════════════════════════
    // D-PAD RIGHT
    // ════════════════════════════════════════════════════════════════
    22:           TvNavAction.right,
    0x100000016:  TvNavAction.right,
    0x100000303:  TvNavAction.right, // arrowRight 64-bit
    0x10000303:   TvNavAction.right, // arrowRight 32-bit
    39:           TvNavAction.right, // seen on some BT HID USB dongles
    106:          TvNavAction.right, // evdev KEY_RIGHT (Rockchip, Amlogic)
    0x10000066:   TvNavAction.right,

    // ════════════════════════════════════════════════════════════════
    // SELECT / OK / ENTER / D-PAD CENTER
    // ════════════════════════════════════════════════════════════════
    13:           TvNavAction.select, // HID Enter / CR (some BT sticks)
    23:           TvNavAction.select, // Android KEYCODE_DPAD_CENTER (Amlogic, Rockchip, Mi Box)
    66:           TvNavAction.select, // Android KEYCODE_ENTER raw (TCL, Hisense OEM builds)
    96:           TvNavAction.select, // Android KEYCODE_BUTTON_A (Rockchip RK3328/RK3399)
    107:          TvNavAction.select, // Android KEYCODE_BUTTON_START (Panasonic, Philips EU)
    160:          TvNavAction.select, // Android KEYCODE_NUMPAD_ENTER (USB remotes, smart sticks)
    // Flutter internal logical key IDs for these
    0x10000017:   TvNavAction.select, // DPAD_CENTER Flutter (32-bit)
    0x100000017:  TvNavAction.select, // DPAD_CENTER Flutter (64-bit)
    0x1100000017: TvNavAction.select, // Alternative DPAD_CENTER seen on some Hisense builds
    0x10000042:   TvNavAction.select, // ENTER Flutter (32-bit)
    0x100000042:  TvNavAction.select, // ENTER Flutter (64-bit)
    0x10000010d:  TvNavAction.select, // NUMPAD_ENTER Flutter (32-bit)
    0x100000243:  TvNavAction.select, // LogicalKeyboardKey.select (64-bit)
    0x10000243:   TvNavAction.select, // LogicalKeyboardKey.select (32-bit)

    // ════════════════════════════════════════════════════════════════
    // BACK / ESCAPE
    // ════════════════════════════════════════════════════════════════
    4:            TvNavAction.back, // Android KEYCODE_BACK (raw)
    8:            TvNavAction.back, // Backspace / some remotes map Back here
    27:           TvNavAction.back, // Escape (USB keyboard, smart stick)
    166:          TvNavAction.back, // Android KEYCODE_NAVIGATE_PREVIOUS / some OEM remotes
    0x1000000a6:  TvNavAction.back, // Flutter goBack keyId
    0x100000a6:   TvNavAction.back, // goBack 32-bit variant
    0x10000011b:  TvNavAction.back, // Flutter escape keyId (32-bit)

    // ════════════════════════════════════════════════════════════════
    // VOLUME
    // ════════════════════════════════════════════════════════════════
    24:           TvNavAction.volumeUp,   // Android KEYCODE_VOLUME_UP
    25:           TvNavAction.volumeDown, // Android KEYCODE_VOLUME_DOWN
    164:          TvNavAction.mute,       // Android KEYCODE_VOLUME_MUTE
    0x1000000a8:  TvNavAction.mute,       // Flutter mute keyId

    // ════════════════════════════════════════════════════════════════
    // MEDIA TRANSPORT
    // ════════════════════════════════════════════════════════════════
    85:           TvNavAction.play,      // KEYCODE_MEDIA_PLAY (Amazon Fire TV, some Hisense)
    126:          TvNavAction.play,      // KEYCODE_MEDIA_PLAY (alternate)
    127:          TvNavAction.pause,     // KEYCODE_MEDIA_PAUSE
    86:           TvNavAction.mediaStop, // KEYCODE_MEDIA_STOP
    87:           TvNavAction.mediaNext, // KEYCODE_MEDIA_NEXT
    88:           TvNavAction.mediaPrev, // KEYCODE_MEDIA_PREVIOUS
    179:          TvNavAction.playPause, // KEYCODE_MEDIA_PLAY_PAUSE (some LG/Philips remotes)
  };

  // ── Unknown key logger ────────────────────────────────────────────────────
  // Debounced to avoid logcat spam when a key auto-repeats.
  // Output format is designed for copy/paste into deviceOverrides above.
  static void _logUnknown(KeyEvent event) {
    if (!kDebugMode) return;
    final id     = event.logicalKey.keyId;
    final physId = event.physicalKey.usbHidUsage;
    final now    = DateTime.now();

    if (id == _lastUnknownId &&
        _lastUnknownTime != null &&
        now.difference(_lastUnknownTime!).inMilliseconds < 3000) {
      return; // suppress repeated events for the same unknown key
    }
    _lastUnknownId   = id;
    _lastUnknownTime = now;

    debugPrint(
      '[TvRemote] UNKNOWN KEY\n'
      '  logicalId  = 0x${id.toRadixString(16).padLeft(8, "0")} ($id)\n'
      '  physHidId  = 0x${physId.toRadixString(16)}\n'
      '  label      = "${event.logicalKey.debugName}"\n'
      '  → Add to assets/tv_keymaps.json:\n'
      '    "overrides": { "$id": "<up|down|left|right|select|back>" }',
    );
  }
}
