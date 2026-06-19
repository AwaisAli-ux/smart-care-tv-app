import 'package:flutter/material.dart';
import 'tv_remote_normalizer.dart';

/// Wraps any widget to make it focusable and activatable via TV remote D-pad.
///
/// Uses [TvRemoteNormalizer] internally so it covers ALL worldwide TV brands.
class TVFocusable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onSelect;
  final bool autofocus;

  const TVFocusable({
    super.key,
    required this.child,
    this.onSelect,
    this.autofocus = false,
  });

  @override
  State<TVFocusable> createState() => _TVFocusableState();
}

class _TVFocusableState extends State<TVFocusable> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: widget.autofocus,
      onFocusChange: (focused) => setState(() => _isFocused = focused),
      onKeyEvent: (node, event) {
        if (TvRemoteNormalizer.normalize(event) == TvNavAction.select) {
          widget.onSelect?.call();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: AnimatedScale(
        scale: _isFocused ? 1.05 : 1.0,
        duration: const Duration(milliseconds: 150),
        child: widget.child,
      ),
    );
  }
}

/// Wraps a screen's top-level widget with a [FocusTraversalGroup] using
/// [ReadingOrderTraversalPolicy] so D-pad traversal follows visual layout order.
class TVNavigationScope extends StatelessWidget {
  final Widget child;

  const TVNavigationScope({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return FocusTraversalGroup(
      policy: ReadingOrderTraversalPolicy(),
      child: child,
    );
  }
}
