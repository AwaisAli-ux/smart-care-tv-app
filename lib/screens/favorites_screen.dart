import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme/app_theme.dart';
import '../services/app_state.dart';
import '../widgets/common_widgets.dart';
import '../widgets/tv_focus.dart';

class FavoritesScreen extends StatefulWidget {
  final bool sidebarFocused;
  const FavoritesScreen({super.key, this.sidebarFocused = true});

  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends State<FavoritesScreen> {
  String _selectedCategory = 'All';
  final List<String> _categories = const ['All', 'Live TV', 'Movies', 'Series'];

  Widget _sectionHeader(String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: AppColors.accent,
          letterSpacing: 1.0,
        ),
      ),
    );
  }

  Widget _buildEmptyState(String message) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: AppColors.bg3,
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.border),
            ),
            child: const Icon(Icons.favorite_border,
                color: AppColors.textTertiary, size: 36),
          ),
          const SizedBox(height: 20),
          Text(
            message,
            style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondary),
          ),
          const SizedBox(height: 8),
          const Text(
            'Tap ♡ on any content to save it here',
            style: TextStyle(fontSize: 13, color: AppColors.textTertiary),
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryContent(BuildContext context, AppState appState) {
    final channels = appState.favoriteChannels;
    final movies = appState.favoriteMovies;
    final series = appState.favoriteSeries;

    switch (_selectedCategory) {
      case 'Live TV':
        if (channels.isEmpty) return _buildEmptyState('No favorite channels');
        return ChannelGrid(
          items: channels,
          autoFocusFirst: false,
          restorationKey: 'favorites_channels', // FIX #7
        );
      case 'Movies':
        if (movies.isEmpty) return _buildEmptyState('No favorite movies');
        return ContentGrid(
          items: movies,
          autoFocusFirst: false,
          restorationKey: 'favorites_movies', // FIX #7
        );
      case 'Series':
        if (series.isEmpty) return _buildEmptyState('No favorite series');
        return ContentGrid(
          items: series,
          autoFocusFirst: false,
          restorationKey: 'favorites_series', // FIX #7
        );
      case 'All':
      default:
        return ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            if (channels.isNotEmpty) ...[
              _sectionHeader('FAVOURITE CHANNELS (${channels.length})'),
              TvScrollableRow(
                height: 160,
                children: channels.map((c) => ChannelCard(item: c)).toList(),
              ),
            ],
            if (movies.isNotEmpty) ...[
              _sectionHeader('FAVOURITE MOVIES (${movies.length})'),
              TvScrollableRow(
                height: 200,
                children: movies.map((m) => MediaCard(item: m)).toList(),
              ),
            ],
            if (series.isNotEmpty) ...[
              _sectionHeader('FAVOURITE SERIES (${series.length})'),
              TvScrollableRow(
                height: 200,
                children: series.map((s) => MediaCard(item: s)).toList(),
              ),
            ],
          ],
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final hasFavs = appState.favorites.isNotEmpty;

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: Text('My Favorites (${appState.favorites.length})'),
        backgroundColor: AppColors.bg2,
      ),
      body: !hasFavs
          ? _buildEmptyState('No favorites yet')
          : Column(
              children: [
                const SizedBox(height: 12),
                SizedBox(
                  height: 36,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: _categories.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (ctx, i) {
                      final cat = _categories[i];
                      final active = cat == _selectedCategory;
                      return TvFocusable(
                        autofocus: false,
                        onActivate: () => setState(() => _selectedCategory = cat),
                        borderRadius: 8,
                        child: InkWell(
                          onTap: () => setState(() => _selectedCategory = cat),
                          borderRadius: BorderRadius.circular(8),
                          focusColor: AppColors.accent.withValues(alpha: 0.25),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 6),
                            decoration: BoxDecoration(
                              color: active ? AppColors.accent : Colors.transparent,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: active ? AppColors.accent : AppColors.border,
                              ),
                            ),
                            child: Text(
                              cat,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: active ? Colors.white : AppColors.textSecondary,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: _buildCategoryContent(context, appState),
                ),
              ],
            ),
    );
  }
}
