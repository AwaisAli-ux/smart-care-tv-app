// ============================================================
// D-PAD SCROLL / MOVEMENT HELPERS   (Phase 0.2)
// ============================================================
//
// Shared infrastructure for D-pad driven grids and lists:
//
//   • DpadScroll      – serialised Scrollable.ensureVisible. Only one
//                       scroll animation is ever in flight; a request that
//                       arrives while another is animating jumps instead.
//                       Overlapping animations shift hit-test geometry
//                       mid-flight, which makes the traversal policy
//                       resolve focus against stale positions.
//   • DpadThrottle    – per-instance rate limiter for directional keys, so
//                       a fast key-repeat stream from a TV remote cannot
//                       outrun the frame budget on Amlogic S905 boxes.
//   • dpadHorizontal  – decodes a KeyEvent into -1 / +1 / null, covering the
//                       raw key ids that different remote brands emit.
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// ═══════════════════════════════════════════════════════════════════════════════
// DpadScroll — serialised ensureVisible
// ═══════════════════════════════════════════════════════════════════════════════
class DpadScroll {
  DpadScroll._();

  static bool _inFlight = false;

  /// Scrolls [context] into view, guaranteeing that at most one animation is
  /// running at a time.
  ///
  /// If a previous animation is still running the target is reached with an
  /// instant jump instead. This keeps scroll geometry stable so the next
  /// focus resolution cannot land one tile off (Fix #4, cause 3).
  static void ensureVisible(
    BuildContext context, {
    double alignment = 0.5,
    Duration duration = const Duration(milliseconds: 200),
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.mounted) return;

      if (_inFlight) {
        try {
          Scrollable.ensureVisible(
            context,
            alignment: alignment,
            duration: Duration.zero,
          );
        } catch (_) {
          // Not inside a Scrollable — safe to ignore.
        }
        return;
      }

      _inFlight = true;
      try {
        Scrollable.ensureVisible(
          context,
          alignment: alignment,
          duration: duration,
          curve: Curves.easeOutCubic,
        ).whenComplete(() => _inFlight = false);
      } catch (_) {
        // Not inside a Scrollable — safe to ignore.
        _inFlight = false;
      }
    });
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// DpadThrottle — directional key rate limiter
// ═══════════════════════════════════════════════════════════════════════════════
class DpadThrottle {
  DpadThrottle({this.interval = const Duration(milliseconds: 70)});

  final Duration interval;
  DateTime? _last;

  /// Returns true if enough time has passed since the last accepted key.
  bool allow() {
    final now = DateTime.now();
    final last = _last;
    if (last != null && now.difference(last) < interval) return false;
    _last = now;
    return true;
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Horizontal key decoding
// ═══════════════════════════════════════════════════════════════════════════════
/// Returns -1 for LEFT, +1 for RIGHT, null for anything else.
///
/// Both directions are decoded through this single function so they can never
/// drift apart again — asymmetric left/right handling is what caused LEFT to
/// move two tiles per press (Fix #4, cause 1).
int? dpadHorizontal(LogicalKeyboardKey key) {
  if (key == LogicalKeyboardKey.arrowLeft || key.keyId == 37) return -1;
  if (key == LogicalKeyboardKey.arrowRight || key.keyId == 39) return 1;
  return null;
}
