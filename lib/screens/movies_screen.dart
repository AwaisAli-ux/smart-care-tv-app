import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';

class MoviesScreen extends StatelessWidget {
  final bool sidebarFocused;
  const MoviesScreen({super.key, this.sidebarFocused = true});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final movies = appState.movies;
    final isLoading = appState.isContentLoading;

    if (isLoading && movies.isEmpty) {
      return Scaffold(
        backgroundColor: AppColors.bg,
        body: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(
                valueColor: AlwaysStoppedAnimation<Color>(AppColors.accent),
                strokeWidth: 3,
              ),
              SizedBox(height: 16),
              Text('Loading movies...',
                  style:
                      TextStyle(color: AppColors.textSecondary, fontSize: 13)),
            ],
          ),
        ),
      );
    }

    if (!isLoading && movies.isEmpty) {
      return Scaffold(
        backgroundColor: AppColors.bg,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.movie_outlined, color: AppColors.textTertiary, size: 64),
              const SizedBox(height: 20),
              const Text(
                'No Movies Found',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Movies will appear here once loaded.\nCheck your connection or try refreshing.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textSecondary, fontSize: 13, height: 1.5),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: () => appState.refreshContent(),
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Refresh Content'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final sorted = appState.sortedMovies;

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(
        children: [
          const SizedBox(height: 8),
          Expanded(
            // autoFocusFirst is intentionally false — focus only enters
            // the grid when the user presses Right/Enter on the sidebar.
            child: ContentGrid(
              items: sorted,
              autoFocusFirst: false,
              restorationKey: 'movies', // FIX #7
            ),
          ),
        ],
      ),
    );
  }
}
