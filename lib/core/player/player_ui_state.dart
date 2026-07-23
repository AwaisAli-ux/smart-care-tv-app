// ============================================================
// PLAYER UI STATE   (Fix #6)
// ============================================================
//
// One enum describing what the play/pause button should be showing, derived
// from media_kit's streams rather than from a scatter of independent booleans.
//
// The players previously only knew about their own initial `_loading` flag, so
// a mid-playback stall (the common case on a weak box with a slow stream) left
// a play or pause icon sitting there while nothing happened. Nothing ever
// subscribed to `player.stream.buffering`.
// ============================================================

import 'package:flutter/material.dart';

enum PlayerUiState { loading, playing, paused, buffering, error }

/// Combines the player's flags into a single state.
///
/// [hasFirstFrame] must be satisfied by ANY sign of life — a decoded frame, a
/// known duration, or the player reporting that it is playing.
///
/// An earlier version gated purely on `player.stream.width`. When that stream
/// never emitted (it does not for every source), the state stayed `loading`
/// forever: a permanent spinner over a video that was actually playing, with
/// a play/pause button that refused to respond. Never gate the whole UI on a
/// single optional signal.
PlayerUiState resolvePlayerUiState({
  required bool hasError,
  required bool isLoading,
  required bool hasFirstFrame,
  required bool isBuffering,
  required bool isPlaying,
}) {
  if (hasError) return PlayerUiState.error;
  // isLoading is the player's own "still setting up" flag and is authoritative.
  if (isLoading) return PlayerUiState.loading;
  if (isBuffering) return PlayerUiState.buffering;
  // Past setup with no sign of life yet — still starting, but the button
  // stays usable (see isBusyState).
  if (!hasFirstFrame && !isPlaying) return PlayerUiState.loading;
  return isPlaying ? PlayerUiState.playing : PlayerUiState.paused;
}

/// Whether SELECT should do nothing.
///
/// Deliberately narrow: only a real mid-playback stall. It used to include
/// `loading`, which combined with the bug above left the user unable to press
/// play at all. Being able to hit play must never depend on the UI state
/// machine being right.
bool isBusyState(PlayerUiState s) => s == PlayerUiState.buffering;

/// The glyph inside the play/pause button.
///
/// The spinner is laid out at exactly [iconSize] like the icons it replaces,
/// so swapping between them cannot shift or resize the button.
Widget playPauseGlyph(
  PlayerUiState state, {
  double iconSize = 40,
  double strokeWidth = 3,
  Color color = Colors.white,
}) {
  final Widget child;
  switch (state) {
    case PlayerUiState.loading:
    case PlayerUiState.buffering:
      child = SizedBox(
        key: const ValueKey('spinner'),
        width: iconSize,
        height: iconSize,
        child: Padding(
          padding: EdgeInsets.all(iconSize * 0.12),
          child: CircularProgressIndicator(
            strokeWidth: strokeWidth,
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        ),
      );
      break;
    case PlayerUiState.playing:
      child = Icon(Icons.pause,
          key: const ValueKey('pause'), color: color, size: iconSize);
      break;
    case PlayerUiState.paused:
      child = Icon(Icons.play_arrow,
          key: const ValueKey('play'), color: color, size: iconSize);
      break;
    case PlayerUiState.error:
      child = Icon(Icons.refresh,
          key: const ValueKey('retry'), color: color, size: iconSize);
      break;
  }

  return AnimatedSwitcher(
    duration: const Duration(milliseconds: 150), // Fix #6 (item 4)
    switchInCurve: Curves.easeOutCubic,
    switchOutCurve: Curves.easeOutCubic,
    child: child,
  );
}
