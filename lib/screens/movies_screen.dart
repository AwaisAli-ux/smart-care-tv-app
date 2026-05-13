import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/content_model.dart';
import '../services/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';

class MoviesScreen extends StatefulWidget {
  const MoviesScreen({super.key});
  @override
  State<MoviesScreen> createState() => _MoviesScreenState();
}

class _MoviesScreenState extends State<MoviesScreen> {
  String _selectedGenre = 'All';

  List<String> _genres(List<ContentItem> movies) {
    final genreSet = <String>{};
    for (final m in movies) {
      genreSet.add(m.genre ?? m.category ?? 'Uncategorized');
    }
    final sorted = genreSet.toList()..sort();
    return ['All', ...sorted];
  }

  List<ContentItem> _filtered(List<ContentItem> movies) {
    if (_selectedGenre == 'All') return movies;
    return movies
        .where((m) =>
            (m.genre ?? m.category ?? 'Uncategorized') == _selectedGenre)
        .toList();
  }

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

    final genres = _genres(movies);
    final filtered = _filtered(movies);

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: Text('Movies (${movies.length})'),
        backgroundColor: AppColors.bg2,
      ),
      body: Column(
        children: [
          const SizedBox(height: 8),
          FilterChipsRow(
            categories: genres,
            selected: _selectedGenre,
            onSelect: (g) => setState(() => _selectedGenre = g),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '${filtered.length} movies',
                style: const TextStyle(
                    color: AppColors.textTertiary, fontSize: 11),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: ContentGrid(items: filtered),
          ),
        ],
      ),
    );
  }
}
