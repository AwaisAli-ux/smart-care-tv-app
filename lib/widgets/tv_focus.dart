// ============================================================
// TV FOCUS SYSTEM — Central reusable TV/D-pad navigation layer
// ============================================================
//
// This file provides:
//   • TvFocusable  – wraps any widget with a proper FocusNode,
//                    visual focus ring/glow, scale animation,
//                    and Enter/Select key handling.
//   • TvScrollableRow – horizontal ListView that auto-scrolls
//                       focused children into view.
//   • tvEnsureVisible – helper to scroll any widget into view
//                       when it gains focus.
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/focus/dpad_scroll_helper.dart';
import '../core/focus/tv_keys.dart';
import '../theme/app_theme.dart';

// ── Helper: scroll focused widget into view ───────────────────────────────────
// Delegates to DpadScroll so that only one scroll animation is ever in flight.
// Previously every focus gain started its own 280ms animation; overlapping
// animations shift hit-test geometry mid-flight and make focus resolution land
// on the wrong tile (Fix #4, cause 3).
void tvEnsureVisible(BuildContext context) => DpadScroll.ensureVisible(context);

// ═══════════════════════════════════════════════════════════════════════════════
// TvFocusable
// ═══════════════════════════════════════════════════════════════════════════════
/// A stateful widget that gives any [child] full Android TV D-pad support.
///
/// Features:
///   • Owns a dedicated [FocusNode] (no Builder anti-pattern).
///   • Draws a glowing orange border when focused.
///   • Optionally scales up slightly when focused (like Netflix cards).
///   • Intercepts Enter / Select / Space to call [onActivate].
///   • Calls [tvEnsureVisible] on focus gain to auto-scroll into view.
///   • Exposes [onFocusChange] for callers that need to react to focus.
class TvFocusable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onActivate;
  final bool autofocus;
  final bool scaleOnFocus;
  final double borderRadius;
  final ValueChanged<bool>? onFocusChange;
  final FocusNode? focusNode;           // optional external node
  final bool ensureVisible;             // set false for non-scrolling contexts
  final Color? focusBorderColor;
  final bool showFocusBorder;
  final bool isCircle;                  // TV NAV: circular border support

  const TvFocusable({
    super.key,
    required this.child,
    this.onActivate,
    this.autofocus = false,
    this.scaleOnFocus = false,
    this.borderRadius = 10,
    this.onFocusChange,
    this.focusNode,
    this.ensureVisible = true,
    this.focusBorderColor,
    this.showFocusBorder = true,
    this.isCircle = false,              // TV NAV: defaults to false
  });

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable>
    with SingleTickerProviderStateMixin {
  late final FocusNode _node;
  bool _hasFocus = false;
  late AnimationController _scaleCtrl;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _node = widget.focusNode ?? FocusNode(debugLabel: 'TvFocusable');
    _node.addListener(_onFocusChange);

    _scaleCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
    );
    _scale = Tween<double>(begin: 1.0, end: 1.05).animate(
      CurvedAnimation(parent: _scaleCtrl, curve: Curves.easeOut),
    );
  }

  @override
  void dispose() {
    _node.removeListener(_onFocusChange);
    // Only dispose if we created the node (not externally provided)
    if (widget.focusNode == null) {
      _node.dispose();
    }
    _scaleCtrl.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (!mounted) return;
    final focused = _node.hasFocus;
    setState(() => _hasFocus = focused);

    if (focused) {
      if (widget.scaleOnFocus) _scaleCtrl.forward();
      if (widget.ensureVisible) tvEnsureVisible(context);
    } else {
      if (widget.scaleOnFocus) _scaleCtrl.reverse();
    }

    widget.onFocusChange?.call(focused);
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    // FIX #1 — single shared definition, see core/focus/tv_keys.dart.
    if (isConfirmKey(event.logicalKey)) {
      widget.onActivate?.call();
      return widget.onActivate != null
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    Widget child = Focus(
      focusNode: _node,
      autofocus: widget.autofocus,
      onKeyEvent: _handleKey,
      child: GestureDetector(
        onTap: () {
          _node.requestFocus();
          widget.onActivate?.call();
        },
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 130),
          decoration: widget.showFocusBorder
              ? BoxDecoration(
                  shape: widget.isCircle ? BoxShape.circle : BoxShape.rectangle,
                  borderRadius: widget.isCircle
                      ? null
                      : BorderRadius.circular(widget.borderRadius),
                  border: Border.all(
                    color: _hasFocus
                        ? (widget.focusBorderColor ?? AppColors.accent)
                        : Colors.transparent,
                    width: 2.5,
                  ),
                  boxShadow: _hasFocus
                      ? [
                          BoxShadow(
                            color: (widget.focusBorderColor ?? AppColors.accent)
                                .withValues(alpha: 0.38),
                            blurRadius: 14,
                            spreadRadius: 1,
                          ),
                        ]
                      : null,
                )
              : null,
          child: widget.child,
        ),
      ),
    );

    if (widget.scaleOnFocus) {
      child = ScaleTransition(scale: _scale, child: child);
    }

    return child;
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// TvScrollableRow
// ═══════════════════════════════════════════════════════════════════════════════
/// A horizontal scrollable row optimised for TV D-pad navigation.
///
/// Each child should wrap its focusable widget with [TvFocusable] (with
/// [ensureVisible] = true). When focus moves to an off-screen item the
/// [Scrollable.ensureVisible] call inside [TvFocusable] will animate it
/// into view automatically.
///
/// Provides an optional [height] and [padding] for convenience.
class TvScrollableRow extends StatelessWidget {
  final List<Widget> children;
  final double? height;
  final EdgeInsetsGeometry padding;
  final double spacing;

  const TvScrollableRow({
    super.key,
    required this.children,
    this.height,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
    this.spacing = 12,
  });

  @override
  Widget build(BuildContext context) {
    Widget list = ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: padding,
      itemCount: children.length,
      separatorBuilder: (_, __) => SizedBox(width: spacing),
      itemBuilder: (_, i) => children[i],
    );
    if (height != null) {
      return SizedBox(height: height, child: list);
    }
    return list;
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// TvButton  — styled pill / rectangular focusable button
// ═══════════════════════════════════════════════════════════════════════════════
class TvButton extends StatelessWidget {
  final Widget child;
  final VoidCallback onPressed;
  final bool autofocus;
  final bool filled;
  final Color? color;

  const TvButton({
    super.key,
    required this.child,
    required this.onPressed,
    this.autofocus = false,
    this.filled = true,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      autofocus: autofocus,
      onActivate: onPressed,
      scaleOnFocus: true,
      showFocusBorder: false,
      child: _TvButtonBody(
        onPressed: onPressed,
        filled: filled,
        color: color,
        child: child,
      ),
    );
  }
}

class _TvButtonBody extends StatelessWidget {
  final Widget child;
  final VoidCallback onPressed;
  final bool filled;
  final Color? color;

  const _TvButtonBody({
    required this.child,
    required this.onPressed,
    required this.filled,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppColors.accent;
    if (filled) {
      return ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: c,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        ),
        child: child,
      );
    }
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white,
        side: BorderSide(color: c),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      ),
      child: child,
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// TvListItem  — for settings / more screen list tiles
// ═══════════════════════════════════════════════════════════════════════════════
class TvListItem extends StatefulWidget {
  final Widget child;
  final VoidCallback? onActivate;
  final bool autofocus;

  const TvListItem({
    super.key,
    required this.child,
    this.onActivate,
    this.autofocus = false,
  });

  @override
  State<TvListItem> createState() => _TvListItemState();
}

class _TvListItemState extends State<TvListItem> {
  final FocusNode _node = FocusNode();
  bool _hasFocus = false;

  @override
  void initState() {
    super.initState();
    _node.addListener(() {
      if (mounted) setState(() => _hasFocus = _node.hasFocus);
    });
  }

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    // FIX #1 — was missing the 0x1000.. DPAD_CENTER/ENTER variants that
    // TvFocusable already accepted, so settings and More rows ignored OK on
    // some remotes while the tiles above them responded.
    if (isConfirmKey(event.logicalKey)) {
      widget.onActivate?.call();
      return KeyEventResult.handled;
    }
    widget.onActivate?.call();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _node,
      autofocus: widget.autofocus,
      onKeyEvent: _handleKey,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 130),
        decoration: BoxDecoration(
          color: _hasFocus
              ? AppColors.accent.withValues(alpha: 0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: _hasFocus ? AppColors.accent : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: widget.child,
      ),
    );
  }
}
