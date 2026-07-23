import 'package:flutter/services.dart';

/// Locks landscape orientation + immersive system UI and waits for that
/// transition to settle BEFORE a player screen is pushed, instead of
/// leaving it to the player screen's own initState().
///
/// Confirmed via device testing (with a rotation-only build that skipped
/// all playback code) that Android's own orientation+immersive-mode
/// transition can take 5+ seconds to complete and can fail to acknowledge
/// a pending window-focus event within Android's 5s ANR budget — this is a
/// platform-side stall, not something any amount of Dart-side sequencing
/// inside the destination screen can avoid. Doing this on the CALLING
/// screen, before the destination screen's window even exists, means the
/// transition isn't racing a freshly-pushed screen's own focus-ack
/// deadline.
Future<void> preRotateForPlayer() async {
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
}
