// ============================================================
// SAFE PLAYER TEARDOWN
// ============================================================
//
// Fixes a native crash seen on channel switching:
//
//   Abort message: 'Callback invoked after it has been deleted.'
//   thread: mpv/mpv core   →  SIGABRT, whole process dies
//
// media_kit registers Dart FFI callbacks that libmpv's core thread invokes
// for player events. Player.dispose() deletes those callbacks. If mpv fires
// an event after that, Dart aborts the entire process — it is not catchable.
//
// The old teardown was:
//
//   try { await p.stop().timeout(3s); } catch (_) {}
//   try { await p.dispose().timeout(3s); } catch (_) {}
//
// When stop() timed out, the catch swallowed it and dispose() ran anyway —
// deleting the callbacks while the native stop was still in flight. That is
// exactly the race that aborts.
//
// Two rules here:
//   1. Never dispose a player whose stop() did not actually complete.
//      Leaking one player instance is bad; killing the app is worse.
//   2. Even after a clean stop, give mpv a moment to drain events it has
//      already queued before tearing the callbacks down.
//
// Nothing in here touches decoder settings, buffer size, hardware
// acceleration, or any mpv property — it is purely lifecycle ordering.
// ============================================================

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

/// How long mpv gets to drain queued events between stop() and dispose().
const Duration _kDrainDelay = Duration(milliseconds: 250);

const Duration _kStopTimeout = Duration(seconds: 3);
const Duration _kDisposeTimeout = Duration(seconds: 3);

/// Stops and disposes [player] in an order that cannot trigger the
/// "Callback invoked after it has been deleted" abort.
///
/// Safe to call with null, and safe to call on a player that is already gone.
Future<void> safeDisposePlayer(Player? player) async {
  if (player == null) return;

  bool stoppedCleanly = false;
  try {
    await player.stop().timeout(_kStopTimeout);
    stoppedCleanly = true;
  } catch (e) {
    debugPrint('[SafeDispose] stop() did not complete: $e');
  }

  if (!stoppedCleanly) {
    // The native stop is still running. Disposing now would delete the FFI
    // callbacks mpv is about to invoke. Leave the instance alone — the OS
    // reclaims it when the process ends.
    debugPrint('[SafeDispose] skipping dispose() — stop() never settled, '
        'disposing now would abort the process');
    return;
  }

  await Future.delayed(_kDrainDelay);

  try {
    await player.dispose().timeout(_kDisposeTimeout);
  } catch (e) {
    debugPrint('[SafeDispose] dispose() failed: $e');
  }
}
