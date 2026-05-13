import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/content_model.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';
import '../services/app_state.dart';
import 'detail_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _heroIndex = 0;
  late final PageController _pageCtrl;
  int _heroLength = 4;

  @override
  void initState() {
    super.initState();
    _pageCtrl = PageController();
    // Auto-rotate hero
    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 5));
      if (!mounted) return false;
      if (_heroLength == 0) return true; // wait for content
      final next = (_heroIndex + 1) % _heroLength;
      if (_pageCtrl.hasClients) {
        _pageCtrl.animateToPage(next,
            duration: const Duration(milliseconds: 600),
            curve: Curves.easeInOut);
      }
      return true;
    });
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final channels = appState.channels;
    final movies = appState.movies;
    final series = appState.series;
    final isLoading = appState.isContentLoading;

    // If still loading, show loading screen
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

    // Error state
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

    // Build hero items from actual content
    final heroItems = <ContentItem>[];
    if (movies.length > 1) heroItems.add(movies[1]);
    if (channels.isNotEmpty) heroItems.add(channels.first);
    if (series.isNotEmpty) heroItems.add(series.first);
    if (movies.length > 3) heroItems.add(movies[3]);
    if (movies.length > 5) heroItems.add(movies[5]);
    _heroLength = heroItems.length;

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: CustomScrollView(
        slivers: [
          // Hero Banner
          if (heroItems.isNotEmpty)
            SliverToBoxAdapter(
                child: _HeroBanner(
              items: heroItems,
              controller: _pageCtrl,
              onPageChanged: (i) => setState(() => _heroIndex = i),
              heroIndex: _heroIndex,
            )),

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

          // Latest Movies — show up to 20
          if (movies.isNotEmpty) ...[
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
                  itemCount: movies.length > 20 ? 20 : movies.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 12),
                  itemBuilder: (_, i) => MediaCard(item: movies[i]),
                ),
              ),
            ),
          ],

          // Popular Series — show up to 20
          if (series.isNotEmpty) ...[
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
                  itemCount: series.length > 20 ? 20 : series.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 12),
                  itemBuilder: (_, i) => MediaCard(item: series[i]),
                ),
              ),
            ),
          ],

          // Trending Movies (offset set for variety)
          if (movies.length > 20) ...[
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
                  itemCount: movies.length > 40 ? 20 : movies.length - 20,
                  separatorBuilder: (_, __) => const SizedBox(width: 12),
                  itemBuilder: (_, i) => MediaCard(item: movies[i + 20]),
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

          // More Series
          if (series.length > 20) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
                child: SectionHeader(title: 'Top Series'),
              ),
            ),
            SliverToBoxAdapter(
              child: SizedBox(
                height: 200,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: series.length > 40 ? 20 : series.length - 20,
                  separatorBuilder: (_, __) => const SizedBox(width: 12),
                  itemBuilder: (_, i) => MediaCard(item: series[i + 20]),
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
class _HeroBanner extends StatelessWidget {
  final List<ContentItem> items;
  final PageController controller;
  final ValueChanged<int> onPageChanged;
  final int heroIndex;
  const _HeroBanner(
      {required this.items,
      required this.controller,
      required this.onPageChanged,
      required this.heroIndex});

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.width > 600 ? 300.0 : 240.0;
    return SizedBox(
      height: h,
      child: Stack(
        children: [
          PageView.builder(
            controller: controller,
            onPageChanged: onPageChanged,
            itemCount: items.length,
            itemBuilder: (_, i) => _HeroSlide(item: items[i]),
          ),
          // Dots
          Positioned(
            bottom: 16,
            right: 20,
            child: Row(
              children: List.generate(items.length, (i) {
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  width: i == heroIndex ? 20 : 6,
                  height: 6,
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  decoration: BoxDecoration(
                    color: i == heroIndex
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
  const _HeroSlide({required this.item});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => Navigator.push(
          context, MaterialPageRoute(builder: (_) => DetailScreen(item: item))),
      focusColor: AppColors.accent.withValues(alpha: 0.15),
      hoverColor: Colors.transparent,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (item.imageUrl.isNotEmpty)
            CachedNetworkImage(
                imageUrl: item.imageUrl,
                fit: BoxFit.cover,
                width: double.infinity,
                height: double.infinity,
                memCacheWidth: 600,
                errorWidget: (_, __, ___) => Container(color: AppColors.bg4))
          else
            Container(color: AppColors.bg4),
          // Gradient overlay
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  AppColors.bg.withOpacity(0.97),
                  AppColors.bg.withOpacity(0.6),
                  AppColors.bg.withOpacity(0.05),
                ],
              ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [AppColors.bg.withOpacity(0.8), Colors.transparent],
              ),
            ),
          ),
          // Content
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
                if (item.description != null &&
                    item.description!.isNotEmpty) ...[
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
                Builder(
                  builder: (ctx) {
                    final appState = Provider.of<AppState>(ctx);
                    final isFav = appState.isFavorite(item.id);
                    return Row(children: [
                      ElevatedButton.icon(
                        onPressed: () => Navigator.push(
                            ctx,
                            MaterialPageRoute(
                                builder: (_) => DetailScreen(item: item))),
                        icon: const Icon(Icons.play_arrow, size: 18),
                        label: const Text('Watch Now'),
                        style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 10)),
                      ),
                      const SizedBox(width: 10),
                      OutlinedButton.icon(
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
                    ]);
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
