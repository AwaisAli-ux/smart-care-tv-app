import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/content_model.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';
import '../widgets/tv_focus.dart';
import '../services/app_state.dart';
import 'detail_screen.dart';
import 'channel_player_screen.dart';
import 'movie_player_screen.dart';
import '../utils/player_navigation.dart';

class HomeScreen extends StatefulWidget {
  final bool sidebarFocused;
  const HomeScreen({super.key, this.sidebarFocused = true});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<ContentItem> _heroItems = [];
  final _rng = Random();

  /// Builds the hero items list once per session (random on every app open).
  List<ContentItem> _buildHeroItems(AppState appState) {
    if (_heroItems.isNotEmpty) return _heroItems;
    final pool = <ContentItem>[
      ...appState.channels.take(30),
      ...appState.englishMovies.take(50),
      ...appState.englishSeries.take(30),
    ];
    if (pool.isEmpty) return [];
    pool.shuffle(_rng);
    _heroItems = pool
        .where((x) => (x.backdropUrl ?? x.imageUrl).isNotEmpty)
        .take(8)
        .toList();
    if (_heroItems.length < 3) _heroItems = pool.take(6).toList();
    return _heroItems;
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final channels = appState.channels;
    final isLoading = appState.isContentLoading;

    if (isLoading && !appState.hasContent) {
      return Scaffold(
        backgroundColor: AppColors.bg,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(
                valueColor: AlwaysStoppedAnimation<Color>(AppColors.accent),
                strokeWidth: 3,
              ),
              const SizedBox(height: 20),
              Text(
                'Loading your content...',
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'This may take a moment',
                style: TextStyle(
                  color: AppColors.textTertiary,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (appState.contentError != null && !appState.hasContent) {
      return Scaffold(
        backgroundColor: AppColors.bg,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, color: AppColors.textTertiary, size: 48),
              const SizedBox(height: 16),
              Text(
                'Failed to load content',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 16),
              ),
              const SizedBox(height: 8),
              Text(
                appState.contentError!,
                style: TextStyle(color: AppColors.textTertiary, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    // Build random hero items once per session
    final heroItems = _buildHeroItems(appState);

    // ── English/US-first filter helpers ──────────────────────────────
    final englishSeries = appState.englishSeries;
    final englishMovies = appState.englishMovies;

    // Latest movies (alias for bottom section — same list)
    final latestMovies = englishMovies;

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: CustomScrollView(
        slivers: [
          // Hero Banner
          if (heroItems.isNotEmpty)
            SliverToBoxAdapter(
              child: _HeroBanner(
                items: heroItems,
                sidebarFocused: widget.sidebarFocused,
              ),
            ),

          // Loading indicator at top when refreshing in background
          if (isLoading && appState.hasContent)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(8),
                child: LinearProgressIndicator(
                  backgroundColor: AppColors.bg3,
                  valueColor: AlwaysStoppedAnimation<Color>(AppColors.accent),
                ),
              ),
            ),

          // Recent Channels — show up to 20
          if (channels.isNotEmpty) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
                child: SectionHeader(title: 'Live Channels'),
              ),
            ),
            SliverToBoxAdapter(
              child: SizedBox(
                height: 160,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: channels.length > 20 ? 20 : channels.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 12),
                  itemBuilder: (_, i) => ChannelCard(item: channels[i]),
                ),
              ),
            ),
          ],



          // Trending Movies — English only, newest first
          if (englishMovies.length > 20) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
                child: SectionHeader(title: 'Trending Movies'),
              ),
            ),
            SliverToBoxAdapter(
              child: SizedBox(
                height: 200,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: englishMovies.length > 40 ? 20 : englishMovies.length - 20,
                  separatorBuilder: (_, __) => const SizedBox(width: 12),
                  itemBuilder: (_, i) => MediaCard(item: englishMovies[i + 20]),
                ),
              ),
            ),
          ],

          // Popular Series — English/US only, newest first
          if (englishSeries.isNotEmpty) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
                child: SectionHeader(title: 'Popular Series'),
              ),
            ),
            SliverToBoxAdapter(
              child: SizedBox(
                height: 200,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: englishSeries.length > 20 ? 20 : englishSeries.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 12),
                  itemBuilder: (_, i) => MediaCard(item: englishSeries[i]),
                ),
              ),
            ),
          ],

          // Latest Movies — English only, newest first
          if (latestMovies.isNotEmpty) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
                child: SectionHeader(title: 'Latest Movies'),
              ),
            ),
            SliverToBoxAdapter(
              child: SizedBox(
                height: 200,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: latestMovies.length > 20 ? 20 : latestMovies.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 12),
                  itemBuilder: (_, i) => MediaCard(item: latestMovies[i]),
                ),
              ),
            ),
          ],

          // More Live TV
          if (channels.length > 20) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
                child: SectionHeader(title: 'More Live TV'),
              ),
            ),
            SliverToBoxAdapter(
              child: SizedBox(
                height: 160,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: channels.length > 40 ? 20 : channels.length - 20,
                  separatorBuilder: (_, __) => const SizedBox(width: 12),
                  itemBuilder: (_, i) => ChannelCard(item: channels[i + 20]),
                ),
              ),
            ),
          ],

          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }
}

// ─── Hero Banner ─────────────────────────────────────────────────────────────
class _HeroBanner extends StatefulWidget {
  final List<ContentItem> items;
  final bool sidebarFocused;

  const _HeroBanner({
    required this.items,
    required this.sidebarFocused,
  });

  @override
  State<_HeroBanner> createState() => _HeroBannerState();
}

class _HeroBannerState extends State<_HeroBanner> {
  int _heroIndex = 0;
  late final PageController _pageCtrl;
  final FocusNode _heroBtnFocusNode = FocusNode(debugLabel: 'HeroBtn');
  Timer? _heroTimer;

  // FIX #11 — the moment the user takes control the carousel stops advancing
  // on its own and never restarts; nothing should move under their thumb.
  bool _userTookControl = false;

  @override
  void initState() {
    super.initState();
    // viewportFraction < 1 lets the neighbouring slides peek in, which is what
    // the scale/rotation treatment needs in order to read as a carousel.
    _pageCtrl = PageController(viewportFraction: 0.88);
    _heroBtnFocusNode.addListener(_onHeroFocusChange);
    _startTimer();
  }

  void _onHeroFocusChange() {
    // FIX #11 — auto-advance only while the slider is NOT focused.
    if (_heroBtnFocusNode.hasFocus && !_userTookControl) {
      setState(() => _userTookControl = true);
      _heroTimer?.cancel();
    }
  }

  void _startTimer() {
    _heroTimer?.cancel();
    if (widget.items.isEmpty || _userTookControl) return;
    _heroTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted || widget.items.isEmpty || _userTookControl) return;
      final next = (_heroIndex + 1) % widget.items.length;
      if (_pageCtrl.hasClients) {
        _pageCtrl.animateToPage(
          next,
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeInOut,
        );
      }
    });
  }

  @override
  void didUpdateWidget(_HeroBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.items.length != oldWidget.items.length) {
      _startTimer();
    }
    if (oldWidget.sidebarFocused && !widget.sidebarFocused) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _heroBtnFocusNode.requestFocus();
        }
      });
    }
  }

  @override
  void dispose() {
    _heroTimer?.cancel();
    _pageCtrl.dispose();
    _heroBtnFocusNode.removeListener(_onHeroFocusChange);
    _heroBtnFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.width > 600 ? 300.0 : 240.0;
    return SizedBox(
      height: h,
      child: Stack(
        children: [
          PageView.builder(
            controller: _pageCtrl,
            onPageChanged: (i) {
              setState(() {
                _heroIndex = i;
              });
            },
            itemCount: widget.items.length,
            itemBuilder: (_, i) {
              // FIX #11 — centre slide is full size; neighbours shrink and
              // rotate away. Fake 3D via a perspective matrix only: no shader,
              // no real mesh, no blur.
              return AnimatedBuilder(
                animation: _pageCtrl,
                builder: (ctx, child) {
                  // How far this slide is from the centre, in pages.
                  double offset = i.toDouble() - _heroIndex;
                  if (_pageCtrl.hasClients && _pageCtrl.position.haveDimensions) {
                    offset = i - (_pageCtrl.page ?? _heroIndex.toDouble());
                  }
                  final clamped = offset.clamp(-1.0, 1.0);
                  final scale = 1.0 - (clamped.abs() * 0.12); // 1.0 → 0.88
                  final matrix = Matrix4.identity()
                    ..setEntry(3, 2, 0.0012) // perspective
                    ..rotateY(clamped * 0.25)
                    ..scaleByDouble(scale, scale, 1.0, 1.0);
                  return Transform(
                    transform: matrix,
                    alignment: Alignment.center,
                    child: child,
                  );
                },
                child: RepaintBoundary(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        // One shadow, not a stack of them.
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.45),
                            blurRadius: 18,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: _HeroSlide(
                          item: widget.items[i],
                          focusNode: i == _heroIndex ? _heroBtnFocusNode : null,
                          autofocus: !widget.sidebarFocused && i == _heroIndex,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          // Dots
          Positioned(
            bottom: 16,
            right: 20,
            child: Row(
              children: List.generate(widget.items.length, (i) {
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  width: i == _heroIndex ? 20 : 6,
                  height: 6,
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  decoration: BoxDecoration(
                    color: i == _heroIndex
                        ? AppColors.accent
                        : AppColors.textTertiary,
                    borderRadius: BorderRadius.circular(3),
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }
}

class _HeroSlide extends StatelessWidget {
  final ContentItem item;
  final FocusNode? focusNode;
  final bool autofocus;

  const _HeroSlide({
    required this.item,
    this.focusNode,
    this.autofocus = false,
  });

  Future<void> _open(BuildContext context) async {
    if (item.isLive) {
      await preRotateForPlayer();
      if (!context.mounted) return;
      Navigator.push(
          context, MaterialPageRoute(builder: (_) => ChannelPlayerScreen(item: item)));
    } else if (item.isMovie) {
      await preRotateForPlayer();
      if (!context.mounted) return;
      Navigator.push(
          context, MaterialPageRoute(builder: (_) => MoviePlayerScreen(item: item)));
    } else {
      Navigator.push(
          context, MaterialPageRoute(builder: (_) => DetailScreen(item: item)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _open(context),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Background image
          if ((item.backdropUrl ?? item.imageUrl).isNotEmpty)
            CachedNetworkImage(
                imageUrl: (item.backdropUrl != null && item.backdropUrl!.isNotEmpty)
                    ? item.backdropUrl!
                    : item.imageUrl,
                fit: BoxFit.cover,
                width: double.infinity,
                height: double.infinity,
                // FIX #11 — decode at roughly the width actually drawn (the
                // slide is ~88% of the viewport) instead of a flat 600px.
                memCacheWidth:
                    (MediaQuery.sizeOf(context).width * 0.9).round(),
                errorWidget: (_, __, ___) => Container(color: AppColors.bg4))
          else
            Container(color: AppColors.bg4),

          // Gradient overlays
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  AppColors.bg.withValues(alpha: 0.97),
                  AppColors.bg.withValues(alpha: 0.6),
                  AppColors.bg.withValues(alpha: 0.05),
                ],
              ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [AppColors.bg.withValues(alpha: 0.8), Colors.transparent],
              ),
            ),
          ),

          // Content overlay — title + buttons
          Positioned(
            left: 24,
            bottom: 32,
            right: MediaQuery.of(context).size.width * 0.4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(children: [
                  if (item.isLive) ...[
                    const LiveBadge(),
                    const SizedBox(width: 8)
                  ],
                  Text(item.genre ?? item.category ?? '',
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.textTertiary)),
                ]),
                const SizedBox(height: 6),
                Text(item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                        letterSpacing: -0.5,
                        shadows: [
                          Shadow(blurRadius: 8, color: Colors.black54)
                        ])),
                if (item.description != null && item.description!.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(item.description!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.textSecondary,
                          height: 1.4)),
                ],
                const SizedBox(height: 12),

                // ── TV-focusable action buttons ──────────────────────────
                Builder(
                  builder: (ctx) {
                    final appState = Provider.of<AppState>(ctx);
                    final isFav = appState.isFavorite(item.id);
                    return FocusTraversalGroup(
                      policy: OrderedTraversalPolicy(),
                      child: Row(children: [
                        // Watch Now — autofocus so D-pad lands here first
                        FocusTraversalOrder(
                          order: const NumericFocusOrder(1),
                          child: TvFocusable(
                            focusNode: focusNode,
                            autofocus: autofocus,
                            scaleOnFocus: true,
                            showFocusBorder: false,
                            onActivate: () => _open(ctx),
                            child: ElevatedButton.icon(
                              onPressed: () => _open(ctx),
                              icon: const Icon(Icons.play_arrow, size: 18),
                              label: const Text('Watch Now'),
                              style: ElevatedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 16, vertical: 10)),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        // My List
                        FocusTraversalOrder(
                          order: const NumericFocusOrder(2),
                          child: TvFocusable(
                            scaleOnFocus: true,
                            showFocusBorder: false,
                            onActivate: () {
                              appState.toggleFavorite(item);
                              ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                                content: Text(isFav
                                    ? 'Removed from My List'
                                    : 'Added to My List'),
                                backgroundColor: AppColors.bg4,
                                duration: const Duration(seconds: 2),
                              ));
                            },
                            child: OutlinedButton.icon(
                              onPressed: () {
                                appState.toggleFavorite(item);
                                ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                                  content: Text(isFav
                                      ? 'Removed from My List'
                                      : 'Added to My List'),
                                  backgroundColor: AppColors.bg4,
                                  duration: const Duration(seconds: 2),
                                ));
                              },
                              icon: Icon(
                                isFav ? Icons.check : Icons.add,
                                size: 16,
                              ),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.white,
                                side: BorderSide(
                                    color: isFav
                                        ? AppColors.accent
                                        : AppColors.border),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 10),
                              ),
                              label: Text(isFav ? 'Saved' : 'My List'),
                            ),
                          ),
                        ),
                      ]),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
