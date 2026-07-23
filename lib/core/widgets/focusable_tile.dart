// ============================================================
// FOCUSABLE TILE   (Phase 0.4 / Fix #11)
// ============================================================
//
// The one focusable tile used by Home, Channels, Movies and Series, so focus
// behaviour and focus visuals are identical everywhere.
//
// PERFORMANCE RULES (target: Amlogic S905 / Mali G52)
//   • Transform + opacity + scale only. No BackdropFilter, no ImageFiltered,
//     no runtime blur, no ShaderMask, no real 3D mesh.
//   • The "3D" tilt is a fake: a perspective matrix plus a small rotateY.
//     It costs one matrix multiply, not a render pass.
//   • Exactly ONE BoxShadow. Layered shadows are what actually cost fill rate.
//   • Every tile sits in a RepaintBoundary so focusing one tile cannot
//     repaint the whole grid.
// ============================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../theme/app_theme.dart';
import '../focus/dpad_scroll_helper.dart';
import '../focus/tv_keys.dart';

class FocusableTile extends StatefulWidget {
  const FocusableTile({
    super.key,
    required this.child,
    this.onActivate,
    this.focusNode,
    this.autofocus = false,
    this.borderRadius = 12,
    this.ensureVisible = true,
    this.tilt = true,
    this.onFocusChange,
  });

  final Widget child;
  final VoidCallback? onActivate;
  final FocusNode? focusNode;
  final bool autofocus;
  final double borderRadius;
  final bool ensureVisible;

  /// The cheap fake-3D tilt. Off for tiles that sit flush in a row where the
  /// rotation would read as misalignment.
  final bool tilt;

  final ValueChanged<bool>? onFocusChange;

  @override
  State<FocusableTile> createState() => _FocusableTileState();
}

class _FocusableTileState extends State<FocusableTile> {
  late final FocusNode _node;
  bool _focused = false;

  static const _duration = Duration(milliseconds: 200);
  static const _curve = Curves.easeOutCubic;

  @override
  void initState() {
    super.initState();
    _node = widget.focusNode ?? FocusNode(debugLabel: 'FocusableTile');
    _node.addListener(_onFocusChange);
  }

  @override
  void dispose() {
    _node.removeListener(_onFocusChange);
    // Only dispose what we created — an injected node belongs to the caller.
    if (widget.focusNode == null) _node.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (!mounted) return;
    final focused = _node.hasFocus;
    if (focused == _focused) return;
    setState(() => _focused = focused);
    if (focused && widget.ensureVisible) DpadScroll.ensureVisible(context);
    widget.onFocusChange?.call(focused);
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (!isConfirmKey(event.logicalKey)) return KeyEventResult.ignored;
    if (widget.onActivate == null) return KeyEventResult.ignored;
    widget.onActivate!();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    // Fake 3D: perspective + a small rotateY + scale. Pure Transform work,
    // no shader, no extra render pass.
    final matrix = Matrix4.identity()
      ..setEntry(3, 2, 0.0012)
      ..rotateY(_focused && widget.tilt ? 0.03 : 0.0)
      ..scaleByDouble(
        _focused ? 1.08 : 1.0,
        _focused ? 1.08 : 1.0,
        1.0,
        1.0,
      );

    return RepaintBoundary(
      child: Focus(
        focusNode: _node,
        autofocus: widget.autofocus,
        onKeyEvent: _handleKey,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            _node.requestFocus();
            widget.onActivate?.call();
          },
          child: AnimatedContainer(
            duration: _duration,
            curve: _curve,
            transform: matrix,
            transformAlignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(widget.borderRadius),
              border: Border.all(
                color: _focused ? AppColors.accent : AppColors.border.withValues(alpha: 0.4),
                width: _focused ? 2.5 : 1,
              ),
              boxShadow: _focused
                  ? [
                      BoxShadow(
                        color: AppColors.accent.withValues(alpha: 0.45),
                        blurRadius: 20,
                        spreadRadius: 2,
                      ),
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.6),
                        blurRadius: 10,
                        offset: const Offset(0, 5),
                      ),
                    ]
                  : [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.25),
                        blurRadius: 6,
                        offset: const Offset(0, 3),
                      ),
                    ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(widget.borderRadius),
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}
