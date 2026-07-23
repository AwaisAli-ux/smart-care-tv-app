// ============================================================
// PLAYBACK SPEED PICKER   (Fix #10)
// ============================================================
//
// The old speed menu was a showModalBottomSheet full of plain ListTiles.
// Nothing in it was focusable, and opening it took focus away from the
// player's own key handler — so on a TV remote the sheet appeared and then
// swallowed every key press. It could only ever be operated by touch.
//
// This replaces it with a dialog that:
//   • grabs focus on open, starting on the currently selected value
//   • moves with UP / DOWN (and wraps at both ends)
//   • applies on SELECT and closes
//   • closes on BACK without changing anything
//
// Shared by MoviePlayerScreen and EpisodePlayerScreen so the behaviour cannot
// drift apart between them.
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_theme.dart';

/// The speed steps offered to the user.
const List<double> kPlaybackSpeeds = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

String speedLabel(double s) => '${s}x${s == 1.0 ? ' (Normal)' : ''}';

/// Opens the picker. Resolves to the chosen speed, or null if the user backed
/// out — callers must treat null as "leave the current speed alone".
Future<double?> showSpeedPicker(
  BuildContext context, {
  required double current,
}) {
  return showDialog<double>(
    context: context,
    barrierColor: Colors.black54,
    builder: (_) => _SpeedPickerDialog(current: current),
  );
}

class _SpeedPickerDialog extends StatefulWidget {
  const _SpeedPickerDialog({required this.current});
  final double current;

  @override
  State<_SpeedPickerDialog> createState() => _SpeedPickerDialogState();
}

class _SpeedPickerDialogState extends State<_SpeedPickerDialog> {
  late int _index;
  final FocusNode _focus = FocusNode(debugLabel: 'SpeedPicker');
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    // Start on the current value, not at the top of the list.
    final found = kPlaybackSpeeds.indexOf(widget.current);
    _index = found >= 0 ? found : kPlaybackSpeeds.indexOf(1.0);
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool _isSelect(LogicalKeyboardKey k) =>
      k == LogicalKeyboardKey.select ||
      k == LogicalKeyboardKey.enter ||
      k == LogicalKeyboardKey.numpadEnter ||
      k == LogicalKeyboardKey.gameButtonA ||
      k.keyId == 13 ||
      k.keyId == 23 ||
      k.keyId == 66 ||
      k.keyId == 96 ||
      k.keyId == 107 ||
      k.keyId == 160;

  bool _isBack(LogicalKeyboardKey k) =>
      k == LogicalKeyboardKey.goBack ||
      k == LogicalKeyboardKey.escape ||
      k == LogicalKeyboardKey.gameButtonB ||
      k.keyId == 27 ||
      k.keyId == 166;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final k = event.logicalKey;

    if (_isBack(k)) {
      Navigator.pop(context); // null → caller keeps the current speed
      return KeyEventResult.handled;
    }
    if (_isSelect(k)) {
      Navigator.pop(context, kPlaybackSpeeds[_index]);
      return KeyEventResult.handled;
    }
    // UP/DOWN and LEFT/RIGHT both step through the values, since remotes vary
    // in which pair users reach for.
    if (k == LogicalKeyboardKey.arrowDown ||
        k.keyId == 40 ||
        k == LogicalKeyboardKey.arrowRight ||
        k.keyId == 39) {
      setState(() => _index = (_index + 1) % kPlaybackSpeeds.length);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp ||
        k.keyId == 38 ||
        k == LogicalKeyboardKey.arrowLeft ||
        k.keyId == 37) {
      setState(() => _index =
          (_index - 1 + kPlaybackSpeeds.length) % kPlaybackSpeeds.length);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
      child: Dialog(
        backgroundColor: AppColors.bg2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 18, 20, 10),
                child: Text(
                  'Playback Speed',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Flexible(
                child: ListView.builder(
                  controller: _scroll,
                  shrinkWrap: true,
                  itemCount: kPlaybackSpeeds.length,
                  itemBuilder: (_, i) {
                    final s = kPlaybackSpeeds[i];
                    final highlighted = i == _index;
                    final isCurrent = s == widget.current;
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => Navigator.pop(context, s),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        curve: Curves.easeOutCubic,
                        margin: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 3),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 11),
                        decoration: BoxDecoration(
                          color: highlighted
                              ? AppColors.accent.withValues(alpha: 0.20)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: highlighted
                                ? AppColors.accent
                                : Colors.transparent,
                            width: 2,
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              isCurrent
                                  ? Icons.check_circle
                                  : Icons.speed_outlined,
                              size: 18,
                              color: isCurrent
                                  ? AppColors.accent
                                  : AppColors.textTertiary,
                            ),
                            const SizedBox(width: 12),
                            Text(
                              speedLabel(s),
                              style: TextStyle(
                                color: highlighted || isCurrent
                                    ? AppColors.textPrimary
                                    : AppColors.textSecondary,
                                fontSize: 14,
                                fontWeight: highlighted
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 6, 20, 14),
                child: Text(
                  'UP / DOWN to choose  •  OK to apply  •  BACK to cancel',
                  style: TextStyle(
                      color: AppColors.textTertiary, fontSize: 11),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
