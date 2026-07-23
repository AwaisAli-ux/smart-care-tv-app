import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Wraps any widget to make it focusable and navigable via TV remote D-pad.
/// Use this wrapper around buttons, cards, and list items in your app.
class TVFocusable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onSelect;
  final bool autofocus;

  const TVFocusable({
    Key? key,
    required this.child,
    this.onSelect,
    this.autofocus = false,
  }) : super(key: key);

  @override
  State<TVFocusable> createState() => _TVFocusableState();
}

class _TVFocusableState extends State<TVFocusable> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: widget.autofocus,
      onFocusChange: (focused) {
        setState(() => _isFocused = focused);
      },
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent) {
          if (event.logicalKey == LogicalKeyboardKey.select ||
              event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.gameButtonA ||
              event.logicalKey.keyId == 0x10000017 ||
              event.logicalKey.keyId == 0x100000017 ||
              event.logicalKey.keyId == 0x1100000017 ||
              event.logicalKey.keyId == 23) {
            widget.onSelect?.call();
            return KeyEventResult.handled;
          }
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

/// Call this at the top of any screen/page that should support D-pad navigation.
/// Wrap the Scaffold or top-level widget of the page with this.
class TVNavigationScope extends StatelessWidget {
  final Widget child;

  const TVNavigationScope({Key? key, required this.child}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return FocusTraversalGroup(
      policy: ReadingOrderTraversalPolicy(),
      child: child,
    );
  }
}
