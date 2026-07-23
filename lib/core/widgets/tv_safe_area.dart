// ============================================================
// TV SAFE AREA   (Phase 0.3 / Fix #12)
// ============================================================
//
// TVs overscan: the panel crops roughly the outer 5% of the signal, so
// anything drawn to the very edge — the first sidebar icon, the top row of a
// grid, the last row of tiles — gets cut off on real hardware even though it
// looks fine in an emulator.
//
// This applies the standard leanback 5% margin on the TV/wide layout and
// passes straight through on phones, where there is no overscan and the space
// would just be wasted.
//
// The TV/wide test lives here so there is one place that answers "are we on
// the leanback layout?", matching the width rule main_shell already uses.
// ============================================================

import 'package:flutter/material.dart';

/// Overscan margin as a fraction of each axis.
///
/// Originally 5% (the old leanback guideline). On real hardware that was
/// wrong: the Mi Box 4 reports a clean 1920x1080 viewport with no overscan
/// compensation, so a 5% margin cut 96px off each side and 54px off the top
/// and bottom — the app visibly did not fill the screen.
///
/// Modern TV panels display 1:1, so the margin is now zero and the app runs
/// edge to edge. If a genuinely overscanning panel ever turns up, raise this
/// to about 0.02 rather than back to 0.05.
const double kOverscanFraction = 0.0;

/// Width at or above which the app uses its TV/tablet layout.
/// Kept identical to main_shell's own breakpoint on purpose.
const double kWideLayoutBreakpoint = 600;

class TvSafeArea extends StatelessWidget {
  const TvSafeArea({
    super.key,
    required this.child,
    this.horizontal = true,
    this.vertical = true,
  });

  final Widget child;

  /// Lets a screen opt out of one axis when something else already provides
  /// that inset (e.g. a full-bleed hero that must reach the edges).
  final bool horizontal;
  final bool vertical;

  /// True when the app is showing its wide (TV/tablet) layout.
  static bool isWideLayout(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= kWideLayoutBreakpoint;

  @override
  Widget build(BuildContext context) {
    if (!isWideLayout(context) || kOverscanFraction <= 0) return child;

    final size = MediaQuery.sizeOf(context);
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: horizontal ? size.width * kOverscanFraction : 0,
        vertical: vertical ? size.height * kOverscanFraction : 0,
      ),
      child: child,
    );
  }
}

/// Clamps the device font scale so a user's system-level "huge text" setting
/// cannot overflow a layout that has already given up 10% of each axis to
/// overscan. Applied once, app-wide, in MaterialApp's builder.
Widget clampTextScale(BuildContext context, Widget? child) {
  final media = MediaQuery.of(context);
  final clamped = media.textScaler.clamp(
    minScaleFactor: 1.0,
    maxScaleFactor: TvSafeArea.isWideLayout(context) ? 1.15 : 1.3,
  );
  return MediaQuery(
    data: media.copyWith(textScaler: clamped),
    child: child ?? const SizedBox.shrink(),
  );
}
