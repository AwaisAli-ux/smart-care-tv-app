import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/content_model.dart';
import '../theme/app_theme.dart';
import '../screens/detail_screen.dart';
import '../screens/channel_player_screen.dart';
import '../screens/movie_player_screen.dart';
import 'tv_focus.dart';

// TV remote key codes
const _kSelect = LogicalKeyboardKey.select;
const _kEnter  = LogicalKeyboardKey.enter;

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

  const ChannelCard({
    super.key,
    required this.item,
    this.onTap,
    this.autofocus = false,
    this.focusNode,
  });

  @override
  Widget build(BuildContext context) {
    final tap = onTap ?? () => _openDetail(context);
    return TvFocusable(
      focusNode: focusNode,
      autofocus: autofocus,
      onActivate: tap,
      scaleOnFocus: true,
      ensureVisible: true,
      child: InkWell(
        onTap: tap,
        borderRadius: BorderRadius.circular(10),
        focusColor: AppColors.accent.withValues(alpha: 0.25),
        hoverColor: AppColors.accent.withValues(alpha: 0.08),
        child: Container(
          width: 150,
          decoration: BoxDecoration(
            color: AppColors.bg3,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Stack(
                  children: [
                    Container(
                      width: double.infinity,
                      color: const Color(0xFF1A1A2E),
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


                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 5, 8, 1),
                child: Text(item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: AppColors.textSecondary)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                child: Text(
                    item.channelNumber != null
                        ? 'Ch. ${item.channelNumber}'
                        : item.category ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 10, color: AppColors.textTertiary)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static Widget _channelFallback(ContentItem item) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            item.title.isNotEmpty ? item.title.substring(0, 1).toUpperCase() : '?',
            style: const TextStyle(
              color: AppColors.accent,
              fontSize: 24,
              fontWeight: FontWeight.w800,
            ),
          ),
          Text(
            item.title,
            style: const TextStyle(
              color: AppColors.textTertiary,
              fontSize: 8,
              fontWeight: FontWeight.w500,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  void _openDetail(BuildContext context) {
    Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => ChannelPlayerScreen(item: item)));
  }
}

// ─── Media Card (Movie / Series) ─────────────────────────────────────────────
class MediaCard extends StatelessWidget {
  final ContentItem item;
  final double width;
  final bool autofocus;
  final VoidCallback? onTap;
  final FocusNode? focusNode;

  const MediaCard({
    super.key,
    required this.item,
    this.width = 110,
    this.autofocus = false,
    this.onTap,
    this.focusNode,
  });

  @override
  Widget build(BuildContext context) {
    final tap = onTap ?? () {
      if (item.isLive) {
        Navigator.push(
            context, MaterialPageRoute(builder: (_) => ChannelPlayerScreen(item: item)));
      } else if (item.isSeries) {
        Navigator.push(
            context, MaterialPageRoute(builder: (_) => DetailScreen(item: item)));
      } else {
        Navigator.push(
            context, MaterialPageRoute(builder: (_) => MoviePlayerScreen(item: item)));
      }
    };
    return TvFocusable(
      focusNode: focusNode,
      onActivate: tap,
      autofocus: autofocus,
      scaleOnFocus: true,
      ensureVisible: true,
      child: InkWell(
        onTap: tap,
        borderRadius: BorderRadius.circular(8),
        focusColor: AppColors.accent.withValues(alpha: 0.25),
        hoverColor: AppColors.accent.withValues(alpha: 0.08),
        child: SizedBox(
          width: width,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: width,
                    child: item.imageUrl.isNotEmpty
                        ? CachedNetworkImage(
                            imageUrl: item.imageUrl,
                            fit: BoxFit.cover,
                            memCacheWidth: 300,
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
                            errorWidget: (_, __, ___) =>
                                _mediaFallback(item),
                          )
                        : _mediaFallback(item),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: AppColors.textSecondary)),
              const SizedBox(height: 2),
              Text(
                item.isSeries && item.episodeCount != null
                    ? '${item.episodeCount} Episode${(item.episodeCount ?? 1) > 1 ? 's' : ''}'
                    : item.year != null
                        ? '${item.year}'
                        : item.genre ?? item.category ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 10, color: AppColors.textTertiary),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static Widget _mediaFallback(ContentItem item) {
    return Container(
      color: AppColors.bg4,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            item.isSeries ? Icons.video_library : Icons.movie,
            color: AppColors.textTertiary,
            size: 28,
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              item.title,
              style: const TextStyle(
                color: AppColors.textTertiary,
                fontSize: 9,
                fontWeight: FontWeight.w500,
              ),
              textAlign: TextAlign.center,
              maxLines: 3,
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
    if (event.logicalKey == _kSelect || event.logicalKey == _kEnter) {
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

// ─── Content Grid ─────────────────────────────────────────────────────────────
class ContentGrid extends StatelessWidget {
  final List<ContentItem> items;
  final bool autoFocusFirst;
  final FocusNode? firstItemFocusNode;

  const ContentGrid({
    super.key,
    required this.items,
    this.autoFocusFirst = false,
    this.firstItemFocusNode,
  });

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    final isTablet = w >= 600;
    final cols = isTablet
        ? (w / 150).floor().clamp(4, 8)
        : (w / 120).floor().clamp(3, 5);
    final cellW = (w - 32 - (cols - 1) * 12) / cols;

    return GridView.builder(
      padding: const EdgeInsets.all(16),
      physics: const ClampingScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: cols,
        childAspectRatio: cellW / (cellW * 1.6),
        crossAxisSpacing: 12,
        mainAxisSpacing: 16,
      ),
      itemCount: items.length,
      itemBuilder: (_, i) => MediaCard(
        item: items[i],
        width: cellW,
        autofocus: autoFocusFirst && i == 0,
        focusNode: i == 0 ? firstItemFocusNode : null,
      ),
    );
  }
}

// ─── Channel Grid ─────────────────────────────────────────────────────────────
class ChannelGrid extends StatelessWidget {
  final List<ContentItem> items;
  final bool autoFocusFirst;
  final FocusNode? firstItemFocusNode;

  const ChannelGrid({
    super.key,
    required this.items,
    this.autoFocusFirst = false,
    this.firstItemFocusNode,
  });

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    final isTablet = w >= 600;
    final cols = isTablet ? (w / 170).floor().clamp(3, 7) : 2;

    return GridView.builder(
      padding: const EdgeInsets.all(16),
      physics: const ClampingScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: cols,
        childAspectRatio: 1.25,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: items.length,
      itemBuilder: (_, i) => ChannelCard(
        item: items[i],
        autofocus: autoFocusFirst && i == 0,
        focusNode: i == 0 ? firstItemFocusNode : null,
      ),
    );
  }
}
