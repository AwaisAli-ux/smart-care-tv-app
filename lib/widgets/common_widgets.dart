import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../core/focus/dpad_scroll_helper.dart';
import '../core/focus/tv_keys.dart';
import '../core/widgets/focusable_tile.dart';
import '../core/focus/focus_utils.dart';
import '../models/content_model.dart';
import '../theme/app_theme.dart';
import '../screens/detail_screen.dart';
import '../screens/channel_player_screen.dart';
import '../screens/movie_player_screen.dart';
import '../utils/player_navigation.dart';
import 'tv_focus.dart';

// ─────────────────────────────────────────────────────────────────────────────
// tvFocusWrapper  (kept for backward compat with callers in more_screen, etc.)
// Now delegates to TvFocusable so the focus node is owned correctly.
// ─────────────────────────────────────────────────────────────────────────────
Widget tvFocusWrapper({
  required Widget child,
  required VoidCallback onActivate,
  bool autofocus = false,
}) {
  return TvFocusable(
    onActivate: onActivate,
    autofocus: autofocus,
    child: child,
  );
}

// ─── Live Badge ───────────────────────────────────────────────────────────────
class LiveBadge extends StatelessWidget {
  const LiveBadge({super.key});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.live,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
              width: 6,
              height: 6,
              decoration: const BoxDecoration(
                  color: Colors.white, shape: BoxShape.circle)),
          const SizedBox(width: 4),
          const Text('LIVE',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5)),
        ],
      ),
    );
  }
}

// ─── Rating Badge ─────────────────────────────────────────────────────────────
class RatingBadge extends StatelessWidget {
  final double rating;
  const RatingBadge({super.key, required this.rating});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.gold.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: AppColors.gold.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.star, color: AppColors.gold, size: 10),
          const SizedBox(width: 3),
          Text(rating.toStringAsFixed(1),
              style: const TextStyle(
                  color: AppColors.gold,
                  fontSize: 11,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

// ─── Channel Card ─────────────────────────────────────────────────────────────
class ChannelCard extends StatelessWidget {
  final ContentItem item;
  final VoidCallback? onTap;
  final bool autofocus;
  final FocusNode? focusNode;

  /// FIX #7 — invoked once the pushed player route has been popped, so the
  /// grid can put focus back on this tile.
  final VoidCallback? onReturn;

  const ChannelCard({
    super.key,
    required this.item,
    this.onTap,
    this.autofocus = false,
    this.focusNode,
    this.onReturn,
  });

  @override
  Widget build(BuildContext context) {
    final tap = onTap ?? () => _openDetail(context);
    return FocusableTile(
      focusNode: focusNode,
      autofocus: autofocus,
      onActivate: tap,
      borderRadius: 12,
      child: Container(
        width: 150,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF1B2234), Color(0xFF101422)],
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Container(
                      color: const Color(0xFF0D111A),
                      child: item.imageUrl.isNotEmpty
                          ? CachedNetworkImage(
                              imageUrl: item.imageUrl,
                              fit: BoxFit.contain,
                              memCacheWidth: 300,
                              placeholder: (_, __) => const Center(
                                child: SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: AppColors.accent,
                                  ),
                                ),
                              ),
                              errorWidget: (_, __, ___) => _channelFallback(item),
                            )
                          : _channelFallback(item),
                    ),
                  ),
                  // Dark gradient overlay at bottom
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          stops: const [0.6, 1.0],
                          colors: [
                            Colors.transparent,
                            Colors.black.withValues(alpha: 0.75),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // Top right channel badge
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.65),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: AppColors.accent.withValues(alpha: 0.4),
                          width: 0.8,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 5,
                            height: 5,
                            decoration: const BoxDecoration(
                              color: AppColors.live,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 3),
                          Text(
                            item.channelNumber != null ? 'Ch ${item.channelNumber}' : 'LIVE',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.3,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
              child: Text(
                item.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                  letterSpacing: 0.2,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: Text(
                item.channelNumber != null
                    ? 'Ch. ${item.channelNumber} • ${item.category ?? "Live TV"}'
                    : item.category ?? 'Live TV',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w400,
                  color: AppColors.accent.withValues(alpha: 0.85),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Widget _channelFallback(ContentItem item) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF261D42), Color(0xFF111628)],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.accent.withValues(alpha: 0.15),
                border: Border.all(color: AppColors.accent.withValues(alpha: 0.3)),
              ),
              child: Center(
                child: Text(
                  item.title.isNotEmpty ? item.title.substring(0, 1).toUpperCase() : '?',
                  style: const TextStyle(
                    color: AppColors.accent,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(
                item.title,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 9,
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openDetail(BuildContext context) async {
    await preRotateForPlayer();
    if (!context.mounted) return;
    await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => ChannelPlayerScreen(item: item)));
    onReturn?.call();
  }
}

// ─── Media Card (Movie / Series) ─────────────────────────────────────────────
class MediaCard extends StatelessWidget {
  final ContentItem item;
  final double width;
  final bool autofocus;
  final VoidCallback? onTap;
  final FocusNode? focusNode;

  /// FIX #7 — invoked once the pushed route has been popped, so the grid can
  /// put focus back on this tile.
  final VoidCallback? onReturn;

  const MediaCard({
    super.key,
    required this.item,
    this.width = 110,
    this.autofocus = false,
    this.onTap,
    this.focusNode,
    this.onReturn,
  });

  @override
  Widget build(BuildContext context) {
    final tap = onTap ?? () async {
      if (item.isLive) {
        await preRotateForPlayer();
        if (!context.mounted) return;
        await Navigator.push(
            context, MaterialPageRoute(builder: (_) => ChannelPlayerScreen(item: item)));
      } else if (item.isSeries) {
        await Navigator.push(
            context, MaterialPageRoute(builder: (_) => DetailScreen(item: item)));
      } else {
        await preRotateForPlayer();
        if (!context.mounted) return;
        await Navigator.push(
            context, MaterialPageRoute(builder: (_) => MoviePlayerScreen(item: item)));
      }
      onReturn?.call();
    };
    return FocusableTile(
      focusNode: focusNode,
      onActivate: tap,
      autofocus: autofocus,
      borderRadius: 12,
      child: SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: AppColors.bg3,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.35),
                      blurRadius: 8,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: item.imageUrl.isNotEmpty
                          ? CachedNetworkImage(
                              imageUrl: item.imageUrl,
                              fit: BoxFit.cover,
                              memCacheWidth: (width * 2).round(),
                              placeholder: (_, __) => Container(
                                color: AppColors.bg4,
                                child: const Center(
                                  child: SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: AppColors.accent,
                                    ),
                                  ),
                                ),
                              ),
                              errorWidget: (_, __, ___) => _mediaFallback(item),
                            )
                          : _mediaFallback(item),
                    ),
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            stops: const [0.5, 1.0],
                            colors: [
                              Colors.transparent,
                              Colors.black.withValues(alpha: 0.85),
                            ],
                          ),
                        ),
                      ),
                    ),
                    // Rating / Year bottom overlay badge inside poster
                    if (item.rating != null && item.rating! > 0)
                      Positioned(
                        bottom: 6,
                        left: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.75),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.star_rounded, color: AppColors.gold, size: 10),
                              const SizedBox(width: 2),
                              Text(
                                item.rating!.toStringAsFixed(1),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 9,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
                letterSpacing: 0.1,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              item.year != null
                  ? '${item.year} • ${item.genre ?? item.category ?? "HD"}'
                  : item.genre ?? item.category ?? 'HD',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w400,
                color: AppColors.textTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Widget _mediaFallback(ContentItem item) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF1E2235), Color(0xFF0F121C)],
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.accent.withValues(alpha: 0.12),
            ),
            child: Icon(
              item.isSeries ? Icons.video_library_rounded : Icons.movie_rounded,
              color: AppColors.accent,
              size: 24,
            ),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(
              item.title,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 9,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Section Header ───────────────────────────────────────────────────────────
class SectionHeader extends StatelessWidget {
  final String title;
  final VoidCallback? onSeeAll;
  const SectionHeader({super.key, required this.title, this.onSeeAll});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const Spacer(),
        if (onSeeAll != null)
          TvFocusable(
            onActivate: onSeeAll!,
            borderRadius: 4,
            child: InkWell(
              onTap: onSeeAll,
              borderRadius: BorderRadius.circular(4),
              focusColor: AppColors.accent.withValues(alpha: 0.2),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Text('View all →',
                    style: TextStyle(
                        fontSize: 12,
                        color: AppColors.accent,
                        fontWeight: FontWeight.w500)),
              ),
            ),
          ),
      ],
    );
  }
}

// ─── Filter Chips Row ─────────────────────────────────────────────────────────
class FilterChipsRow extends StatefulWidget {
  final List<String> categories;
  final String selected;
  final ValueChanged<String> onSelect;
  const FilterChipsRow(
      {super.key,
      required this.categories,
      required this.selected,
      required this.onSelect});

  @override
  State<FilterChipsRow> createState() => _FilterChipsRowState();
}

class _FilterChipsRowState extends State<FilterChipsRow> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: ListView.separated(
        controller: _scroll,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: widget.categories.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final cat = widget.categories[i];
          final isActive = cat == widget.selected;
          return _FilterChip(
            label: cat,
            isActive: isActive,
            autofocus: isActive && i == 0,
            onSelect: () => widget.onSelect(cat),
          );
        },
      ),
    );
  }
}

class _FilterChip extends StatefulWidget {
  final String label;
  final bool isActive;
  final bool autofocus;
  final VoidCallback onSelect;

  const _FilterChip({
    required this.label,
    required this.isActive,
    required this.autofocus,
    required this.onSelect,
  });

  @override
  State<_FilterChip> createState() => _FilterChipState();
}

class _FilterChipState extends State<_FilterChip> {
  final FocusNode _node = FocusNode();
  bool _hasFocus = false;

  @override
  void initState() {
    super.initState();
    _node.addListener(_onFocus);
  }

  void _onFocus() {
    if (!mounted) return;
    setState(() => _hasFocus = _node.hasFocus);
    if (_node.hasFocus) tvEnsureVisible(context);
  }

  @override
  void dispose() {
    _node.removeListener(_onFocus);
    _node.dispose();
    super.dispose();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    // FIX #1 — this was the worst offender: it accepted only 6 of the 11 key
    // variants the tiles accept, so filter chips silently ignored OK on
    // Rockchip (BUTTON_A), Panasonic (BUTTON_START) and USB remotes.
    if (isConfirmKey(event.logicalKey)) {
      widget.onSelect();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _node,
      autofocus: widget.autofocus,
      onKeyEvent: _handleKey,
      child: InkWell(
        onTap: widget.onSelect,
        borderRadius: BorderRadius.circular(20),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: widget.isActive
                ? AppColors.accent
                : (_hasFocus
                    ? AppColors.accent.withValues(alpha: 0.15)
                    : Colors.transparent),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: _hasFocus
                  ? Colors.white
                  : (widget.isActive ? AppColors.accent : AppColors.border),
              width: _hasFocus ? 2.0 : 1.0,
            ),
            boxShadow: _hasFocus
                ? [
                    BoxShadow(
                      color: AppColors.accent.withValues(alpha: 0.35),
                      blurRadius: 8,
                      spreadRadius: 1,
                    )
                  ]
                : null,
          ),
          child: Text(cat,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: widget.isActive || _hasFocus
                    ? Colors.white
                    : AppColors.textTertiary,
              )),
        ),
      ),
    );
  }

  String get cat => widget.label;
}

// ─── D-pad Grid ───────────────────────────────────────────────────────────────
// FIX #4 — shared grid body for ContentGrid and ChannelGrid.
//
// Horizontal movement is resolved explicitly by index instead of being left to
// the traversal policy's geometric resolution, which mis-resolves while a
// scroll animation is still running. LEFT and RIGHT go through the exact same
// code path (see dpadHorizontal) so they can never behave differently again.
class _DpadGrid extends StatefulWidget {
  final int itemCount;
  final int crossAxisCount;
  final double childAspectRatio;
  final double mainAxisSpacing;
  final bool autoFocusFirst;
  final FocusNode? firstItemFocusNode;

  /// FIX #7 — identifies this list in the focus registry, e.g. 'movies'.
  /// Null disables save/restore (used for grids that are not a launch point).
  final String? restorationKey;

  /// Stable id of the item at [index], used to find the same tile again after
  /// the list may have refreshed.
  final String? Function(int index)? itemIdAt;

  /// FIX #3 — invoked when UP is pressed from the first row, so a screen can
  /// hand focus back to whatever sits above the grid (e.g. the search input).
  final VoidCallback? onExitTop;

  final Widget Function(
    int index,
    FocusNode node,
    bool autofocus,
    VoidCallback onReturn,
  ) itemBuilder;

  const _DpadGrid({
    required this.itemCount,
    required this.crossAxisCount,
    required this.childAspectRatio,
    required this.mainAxisSpacing,
    required this.autoFocusFirst,
    required this.firstItemFocusNode,
    required this.itemBuilder,
    this.restorationKey,
    this.itemIdAt,
    this.onExitTop,
  });

  @override
  State<_DpadGrid> createState() => _DpadGridState();
}

class _DpadGridState extends State<_DpadGrid> {
  // Nodes are created once per index and reused for the lifetime of the grid —
  // never rebuilt inside build(). Created lazily so a 5000-item movie list does
  // not allocate 5000 FocusNodes up front on a low-RAM box.
  final Map<int, FocusNode> _nodes = {};
  final DpadThrottle _throttle = DpadThrottle();
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    // Index 0 may use a caller-owned node, which _nodeFor never wraps — without
    // this, focusing the very first tile would not be recorded.
    widget.firstItemFocusNode?.addListener(_onFirstItemFocus);
    // FIX #7 — a screen rebuilt by main_shell's tab switch starts from
    // scratch, so restore whatever the registry remembers for it.
    WidgetsBinding.instance.addPostFrameCallback((_) => _restore());
  }

  void _onFirstItemFocus() {
    if (widget.firstItemFocusNode?.hasFocus ?? false) _remember(0);
  }

  FocusNode _nodeFor(int i) {
    if (i == 0 && widget.firstItemFocusNode != null) {
      return widget.firstItemFocusNode!;
    }
    return _nodes.putIfAbsent(i, () {
      final node = FocusNode(debugLabel: 'DpadGrid_$i');
      node.addListener(() {
        if (node.hasFocus) _remember(i);
      });
      return node;
    });
  }

  // ── FIX #7: save / restore ──────────────────────────────────────────────
  void _remember(int index) {
    final key = widget.restorationKey;
    if (key == null) return;
    TvFocusRegistry.instance.save(
      key,
      itemId: widget.itemIdAt?.call(index),
      itemIndex: index,
      scrollOffset: _scroll.hasClients ? _scroll.offset : 0,
    );
  }

  /// Puts the user back exactly where they were: scroll position first with an
  /// instant jump (animating here reads as sluggish), then focus.
  void _restore() {
    final key = widget.restorationKey;
    if (key == null || !mounted || widget.itemCount == 0) return;

    final memory = TvFocusRegistry.instance.read(key);
    if (memory == null) return;

    final ids = List<String?>.generate(
      widget.itemCount,
      (i) => widget.itemIdAt?.call(i),
    );
    final index = TvFocusRegistry.instance.resolveIndex(key, ids);
    if (index == null) return;

    if (_scroll.hasClients) {
      _scroll.jumpTo(
        memory.scrollOffset.clamp(0.0, _scroll.position.maxScrollExtent),
      );
    }

    // The target tile only exists after the jump has been laid out.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusIndex(index);
    });
  }

  void _focusIndex(int index) {
    if (index < 0 || index >= widget.itemCount) return;
    final node = _nodeFor(index);

    // A tile one row below the viewport may not be built yet, and requesting
    // focus on an unattached node silently does nothing — that is what made
    // DOWN feel like it "sometimes" worked. Bring the row in first, then focus.
    if (node.context == null) {
      _scrollToIndex(index);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final n = _nodeFor(index);
        n.requestFocus();
        final c = n.context;
        if (c != null) DpadScroll.ensureVisible(c);
      });
      return;
    }

    node.requestFocus();
    DpadScroll.ensureVisible(node.context!);
  }

  /// Jumps the grid so the row holding [index] is inside the viewport. Geometry
  /// is derived from the delegate's own numbers, so it stays correct whatever
  /// column count / aspect ratio the caller picked.
  void _scrollToIndex(int index) {
    if (!_scroll.hasClients) return;
    final width = context.size?.width;
    if (width == null || width <= 0) return;

    final cols = widget.crossAxisCount;
    final cellW = (width - 32 - (cols - 1) * 12) / cols;
    if (cellW <= 0) return;
    final rowExtent = cellW / widget.childAspectRatio + widget.mainAxisSpacing;

    final rowTop = 16 + (index ~/ cols) * rowExtent; // 16 = grid padding
    final rowBottom = rowTop + rowExtent;
    final viewport = _scroll.position.viewportDimension;

    double offset = _scroll.offset;
    if (rowTop < offset) {
      offset = rowTop;
    } else if (rowBottom > offset + viewport) {
      offset = rowBottom - viewport;
    } else {
      return;
    }
    _scroll.jumpTo(offset.clamp(0.0, _scroll.position.maxScrollExtent));
  }

  @override
  void dispose() {
    widget.firstItemFocusNode?.removeListener(_onFirstItemFocus);
    // Only nodes we created — firstItemFocusNode is owned by the caller.
    for (final n in _nodes.values) {
      n.dispose();
    }
    _scroll.dispose();
    super.dispose();
  }

  int get _focusedIndex {
    if (widget.firstItemFocusNode?.hasFocus ?? false) return 0;
    for (final e in _nodes.entries) {
      if (e.value.hasFocus) return e.key;
    }
    return -1;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    // Only act on down and repeat — reacting to KeyUpEvent as well would
    // double every movement.
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final current = _focusedIndex;
    if (current < 0) return KeyEventResult.ignored;

    // FIX #3 — UP from the first row leaves the grid upward, so the screen
    // above (the search input) can take focus back.
    if (widget.onExitTop != null &&
        (event.logicalKey == LogicalKeyboardKey.arrowUp ||
            event.logicalKey.keyId == 38) &&
        current < widget.crossAxisCount) {
      widget.onExitTop!();
      return KeyEventResult.handled;
    }

    // UP / DOWN are resolved by index arithmetic, exactly like LEFT / RIGHT.
    // They used to fall through to Flutter's spatial traversal, which measures
    // the tiles on screen — with the focused tile scaled up 1.08 and the next
    // row only half built, it regularly landed a column off or nowhere at all.
    final key = event.logicalKey;
    final isUp = key == LogicalKeyboardKey.arrowUp || key.keyId == 38;
    final isDown = key == LogicalKeyboardKey.arrowDown || key.keyId == 40;
    if (isUp || isDown) {
      final cols = widget.crossAxisCount;
      final lastRow = (widget.itemCount - 1) ~/ cols;
      int vTarget = current + (isDown ? cols : -cols);

      if (isUp && vTarget < 0) return KeyEventResult.ignored;
      if (isDown && vTarget >= widget.itemCount) {
        // Already on the bottom row → let the key go. Otherwise the last row is
        // short, so land on its final tile rather than refusing to move.
        if (current ~/ cols == lastRow) return KeyEventResult.ignored;
        vTarget = widget.itemCount - 1;
      }

      if (!_throttle.allow()) return KeyEventResult.handled;
      _focusIndex(vTarget);
      return KeyEventResult.handled;
    }

    final delta = dpadHorizontal(key);
    if (delta == null) return KeyEventResult.ignored; // other keys

    final target = current + delta;

    // At either end of the list we do not act, so the event stays available
    // for the shell (LEFT at index 0 returns to the sidebar). Symmetric for
    // both directions.
    if (target < 0 || target >= widget.itemCount) return KeyEventResult.ignored;

    // Swallow key-repeat that arrives faster than we can render, so a held
    // direction cannot outrun the frame budget on Amlogic devices.
    if (!_throttle.allow()) return KeyEventResult.handled;

    // Horizontal stays a plain focus request: the row is already on screen, and
    // running ensureVisible here would re-centre it on every step.
    _nodeFor(target).requestFocus();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      onKeyEvent: _onKey,
      canRequestFocus: false,
      child: GridView.builder(
        controller: _scroll,
        padding: const EdgeInsets.all(16),
        physics: const ClampingScrollPhysics(),
        // FIX #11 — conservative cacheExtent: enough to keep the next row
        // ready for D-pad movement, not so much that a weak box decodes
        // several screens of posters it will never show.
        cacheExtent: 400,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: widget.crossAxisCount,
          childAspectRatio: widget.childAspectRatio,
          crossAxisSpacing: 12,
          mainAxisSpacing: widget.mainAxisSpacing,
        ),
        itemCount: widget.itemCount,
        itemBuilder: (_, i) => widget.itemBuilder(
          i,
          _nodeFor(i),
          widget.autoFocusFirst && i == 0,
          // FIX #7 — the card awaits its player route and calls this on the
          // way back, so focus lands on the tile it was launched from.
          () => _focusIndex(i),
        ),
      ),
    );
  }
}

// ─── Content Grid ─────────────────────────────────────────────────────────────
class ContentGrid extends StatelessWidget {
  final List<ContentItem> items;
  final bool autoFocusFirst;
  final FocusNode? firstItemFocusNode;

  /// FIX #7 — identifies this list in the focus registry, e.g. 'movies'.
  final String? restorationKey;

  /// FIX #3 — UP from the first row hands focus back to the caller.
  final VoidCallback? onExitTop;

  const ContentGrid({
    super.key,
    required this.items,
    this.autoFocusFirst = false,
    this.firstItemFocusNode,
    this.restorationKey,
    this.onExitTop,
  });

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    final isTablet = w >= 600;
    final cols = isTablet
        ? (w / 150).floor().clamp(4, 8)
        : (w / 120).floor().clamp(3, 5);
    final cellW = (w - 32 - (cols - 1) * 12) / cols;

    return _DpadGrid(
      itemCount: items.length,
      crossAxisCount: cols,
      childAspectRatio: cellW / (cellW * 1.6),
      mainAxisSpacing: 16,
      autoFocusFirst: autoFocusFirst,
      firstItemFocusNode: firstItemFocusNode,
      restorationKey: restorationKey,
      itemIdAt: (i) => items[i].id,
      onExitTop: onExitTop,
      itemBuilder: (i, node, autofocus, onReturn) => MediaCard(
        item: items[i],
        width: cellW,
        autofocus: autofocus,
        focusNode: node,
        onReturn: onReturn,
      ),
    );
  }
}

// ─── Channel Grid ─────────────────────────────────────────────────────────────
class ChannelGrid extends StatelessWidget {
  final List<ContentItem> items;
  final bool autoFocusFirst;
  final FocusNode? firstItemFocusNode;

  /// FIX #7 — identifies this list in the focus registry, e.g. 'live_tv'.
  final String? restorationKey;

  const ChannelGrid({
    super.key,
    required this.items,
    this.autoFocusFirst = false,
    this.firstItemFocusNode,
    this.restorationKey,
  });

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    final isTablet = w >= 600;
    final cols = isTablet ? (w / 170).floor().clamp(3, 7) : 2;

    return _DpadGrid(
      itemCount: items.length,
      crossAxisCount: cols,
      childAspectRatio: 1.25,
      mainAxisSpacing: 12,
      autoFocusFirst: autoFocusFirst,
      firstItemFocusNode: firstItemFocusNode,
      restorationKey: restorationKey,
      itemIdAt: (i) => items[i].id,
      itemBuilder: (i, node, autofocus, onReturn) => ChannelCard(
        item: items[i],
        autofocus: autofocus,
        focusNode: node,
        onReturn: onReturn,
      ),
    );
  }
}
