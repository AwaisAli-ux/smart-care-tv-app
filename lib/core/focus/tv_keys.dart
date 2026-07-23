// ============================================================
// TV REMOTE KEY DEFINITIONS   (Fix #1)
// ============================================================
//
// Every focusable widget in the app had its own hand-written list of "which
// keys mean OK". They had drifted apart badly — TvFocusable accepted 13
// variants, TvListItem 11, and the filter chips only 6, so a filter chip
// simply did not respond on a Rockchip or Panasonic remote while the tile
// next to it did.
//
// One definition, used everywhere, so a remote that works on one control
// works on all of them.
// ============================================================

import 'package:flutter/services.dart';

/// Raw Android keycodes that arrive as bare key ids from various OEM builds.
///   13  — HID Enter
///   23  — DPAD_CENTER (Amlogic S905, Mi Box)
///   66  — KEYCODE_ENTER (TCL, Hisense OEM)
///   96  — KEYCODE_BUTTON_A (Rockchip RK3328/RK3399)
///   107 — KEYCODE_BUTTON_START (Panasonic, Philips EU)
///   160 — KEYCODE_NUMPAD_ENTER (USB remotes)
const Set<int> _kConfirmRawIds = {
  13, 23, 66, 96, 107, 160,
  0x10000017, 0x100000017, 0x1100000017, // DPAD_CENTER variants
  0x10000042, 0x100000042, // ENTER variants
};

const Set<int> _kBackRawIds = {8, 27, 166, 0x1000000a6};

/// True for every key any TV remote might send to mean "OK / select".
bool isConfirmKey(LogicalKeyboardKey key) =>
    key == LogicalKeyboardKey.select ||
    key == LogicalKeyboardKey.enter ||
    key == LogicalKeyboardKey.space ||
    key == LogicalKeyboardKey.numpadEnter ||
    key == LogicalKeyboardKey.gameButtonA ||
    _kConfirmRawIds.contains(key.keyId);

/// True for every key any TV remote might send to mean "back".
bool isBackKey(LogicalKeyboardKey key) =>
    key == LogicalKeyboardKey.goBack ||
    key == LogicalKeyboardKey.escape ||
    key == LogicalKeyboardKey.gameButtonB ||
    _kBackRawIds.contains(key.keyId);
