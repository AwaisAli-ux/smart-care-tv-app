import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/focus/focus_utils.dart';
import '../theme/app_theme.dart';
import '../services/app_state.dart';
import '../services/device_lock_service.dart';
import '../services/search_state.dart';
import '../widgets/common_widgets.dart';
import '../models/content_model.dart';
import 'login_screen.dart';
import 'favorites_screen.dart';
import 'detail_screen.dart';
import 'channel_player_screen.dart';
import 'movie_player_screen.dart';
import '../utils/player_navigation.dart';

class MoreScreen extends StatelessWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final favs = appState.favorites;

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: const Text('More'),
        backgroundColor: AppColors.bg2,
      ),
      body: ListView(
        children: [
          // ── Favourites Section ─────────────────────────────────────────────
          if (favs.isEmpty) ...[
            _sectionHeader('MY FAVOURITES (0)'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: AppColors.bg2,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.border),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: AppColors.bg3,
                        shape: BoxShape.circle,
                        border: Border.all(color: AppColors.border),
                      ),
                      child: const Icon(Icons.favorite_border,
                          color: AppColors.textTertiary, size: 20),
                    ),
                    const SizedBox(width: 14),
                    const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('No favourites yet',
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textSecondary)),
                        SizedBox(height: 3),
                        Text('Tap ♡ on any channel, movie or series',
                            style: TextStyle(
                                fontSize: 12,
                                color: AppColors.textTertiary)),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ] else ...[
            // Separate favorite channels
            if (appState.favoriteChannels.isNotEmpty) ...[
              _sectionHeader('FAVOURITE CHANNELS (${appState.favoriteChannels.length})'),
              SizedBox(
                height: 140,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: appState.favoriteChannels.length,
                  itemBuilder: (ctx, i) {
                    final item = appState.favoriteChannels[i];
                    return _FavCard(item: item);
                  },
                ),
              ),
            ],
            // Separate favorite movies
            if (appState.favoriteMovies.isNotEmpty) ...[
              _sectionHeader('FAVOURITE MOVIES (${appState.favoriteMovies.length})'),
              SizedBox(
                height: 140,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: appState.favoriteMovies.length,
                  itemBuilder: (ctx, i) {
                    final item = appState.favoriteMovies[i];
                    return _FavCard(item: item);
                  },
                ),
              ),
            ],
            // Separate favorite series
            if (appState.favoriteSeries.isNotEmpty) ...[
              _sectionHeader('FAVOURITE SERIES (${appState.favoriteSeries.length})'),
              SizedBox(
                height: 140,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: appState.favoriteSeries.length,
                  itemBuilder: (ctx, i) {
                    final item = appState.favoriteSeries[i];
                    return _FavCard(item: item);
                  },
                ),
              ),
            ],
            // ── See All Favourites tile ────────────────────────────────────────
            _tile(
              context,
              icon: Icons.favorite,
              iconColor: AppColors.accent,
              title: 'See All Favourites (${favs.length})',
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const FavoritesScreen(),
                  ),
                );
              },
            ),
          ],

          const SizedBox(height: 8),
          Divider(color: AppColors.border, thickness: 1,
              indent: 16, endIndent: 16),
          const SizedBox(height: 8),

          // ── Sign Out ───────────────────────────────────────────────────────
          _tile(context,
              icon: Icons.logout,
              iconColor: Colors.red,
              title: 'Sign Out',
              titleColor: Colors.red,
              onTap: () async {
                final prefs = await SharedPreferences.getInstance();
                await prefs.remove(AuthPrefsKeys.loggedIn);
                await prefs.remove(AuthPrefsKeys.username);
                await prefs.remove(AuthPrefsKeys.password);
                await prefs.remove(AuthPrefsKeys.serverUrl);
                await prefs.remove(AuthPrefsKeys.scToken);
                await prefs.remove(AuthPrefsKeys.scLastCheck);
                if (!context.mounted) return;
                Provider.of<AppState>(context, listen: false).logout();
                // FIX #5 — a search must not survive into the next account.
                Provider.of<SearchState>(context, listen: false).clearOnLogout();
                // FIX #7 — nor may remembered scroll/focus positions.
                TvFocusRegistry.instance.clearAll();
                Navigator.of(context).pushAndRemoveUntil(
                  MaterialPageRoute(builder: (_) => const LoginScreen()),
                  (_) => false,
                );
              }),
        ],
      ),
    );
  }

  Widget _sectionHeader(String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: AppColors.accent,
          letterSpacing: 1.0,
        ),
      ),
    );
  }

  Widget _tile(
    BuildContext context, {
    required IconData icon,
    Color? iconColor,
    required String title,
    Color? titleColor,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: tvFocusWrapper(
        onActivate: onTap,
        child: Builder(
          builder: (focusCtx) {
            final hasFocus = Focus.of(focusCtx).hasFocus;
            return ListTile(
              leading: Icon(icon,
                  color: hasFocus
                      ? Colors.white
                      : (iconColor ?? AppColors.textTertiary),
                  size: 22),
              title: Text(
                title,
                style: TextStyle(
                  fontSize: 14,
                  color: hasFocus
                      ? Colors.white
                      : (titleColor ?? AppColors.textPrimary),
                  fontWeight: FontWeight.w500,
                ),
              ),
              trailing: Icon(
                Icons.chevron_right,
                color: hasFocus
                    ? Colors.white
                    : (titleColor ?? AppColors.textTertiary),
                size: 18,
              ),
              onTap: onTap,
            );
          },
        ),
      ),
    );
  }
}

// ── Favourite Card ────────────────────────────────────────────────────────────
class _FavCard extends StatelessWidget {
  final ContentItem item;
  const _FavCard({required this.item});

  Future<void> _open(BuildContext context) async {
    if (item.isLive) {
      await preRotateForPlayer();
      if (!context.mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChannelPlayerScreen(item: item),
        ),
      );
    } else if (item.isMovie) {
      await preRotateForPlayer();
      if (!context.mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => MoviePlayerScreen(item: item),
        ),
      );
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => DetailScreen(item: item),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final isFav = appState.isFavorite(item.id);

    return GestureDetector(
      onTap: () => _open(context),
      child: Container(
        width: 96,
        margin: const EdgeInsets.only(right: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Thumbnail
            Stack(
              children: [
                Container(
                  width: 96,
                  height: 96,
                  decoration: BoxDecoration(
                    color: AppColors.bg3,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: item.imageUrl.isNotEmpty
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Image.network(
                            item.imageUrl,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => _placeholder(),
                          ),
                        )
                      : _placeholder(),
                ),
                 // Remove favourite button
                Positioned(
                  top: 4,
                  right: 4,
                  child: GestureDetector(
                    onTap: () =>
                        context.read<AppState>().toggleFavorite(item),
                    child: Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        isFav ? Icons.favorite : Icons.favorite_border,
                        color: isFav ? Colors.red : Colors.white70,
                        size: 12,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 5),
            Text(
              item.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ),
    );
  }

  Widget _placeholder() {
    return Center(
      child: Icon(
        item.isLive ? Icons.live_tv : Icons.movie_outlined,
        color: AppColors.textTertiary,
        size: 28,
      ),
    );
  }
}
