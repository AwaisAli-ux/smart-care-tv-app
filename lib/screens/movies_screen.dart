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
        appBar: AppBar(
          title: const Text('Movies'),
          backgroundColor: AppColors.bg2,
        ),
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

    if (movies.isEmpty) {
      return Scaffold(
        backgroundColor: AppColors.bg,
        appBar: AppBar(
          title: const Text('Movies'),
          backgroundColor: AppColors.bg2,
        ),
        body: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.movie, color: AppColors.textTertiary, size: 48),
              SizedBox(height: 16),
              Text('No movies available',
                  style:
                      TextStyle(color: AppColors.textSecondary, fontSize: 14)),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: const Text('Movies'),
        backgroundColor: AppColors.bg2,
      ),
      body: Column(
        children: [
          const SizedBox(height: 8),
          Expanded(
            // autoFocusFirst is intentionally false — focus only enters
            // the grid when the user presses Right/Enter on the sidebar.
            child: ContentGrid(
              items: movies,
              autoFocusFirst: false,
            ),
          ),
        ],
      ),
    );
  }
}
