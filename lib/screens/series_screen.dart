import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/content_model.dart';
import '../services/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';

class SeriesScreen extends StatefulWidget {
  const SeriesScreen({super.key});
  @override
  State<SeriesScreen> createState() => _SeriesScreenState();
}

class _SeriesScreenState extends State<SeriesScreen> {
  String _selectedGenre = 'All';

  List<String> _genres(List<ContentItem> series) {
    final genreSet = <String>{};
    for (final s in series) {
      genreSet.add(s.genre ?? s.category ?? 'Uncategorized');
    }
    final sorted = genreSet.toList()..sort();
    return ['All', ...sorted];
  }

  List<ContentItem> _filtered(List<ContentItem> series) {
    if (_selectedGenre == 'All') return series;
    return series
        .where((s) =>
            (s.genre ?? s.category ?? 'Uncategorized') == _selectedGenre)
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final series = appState.series;
    final isLoading = appState.isContentLoading;

    if (isLoading && series.isEmpty) {
      return Scaffold(
        backgroundColor: AppColors.bg,
        appBar: AppBar(
          title: const Text('Series'),
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
              Text('Loading series...',
                  style:
                      TextStyle(color: AppColors.textSecondary, fontSize: 13)),
            ],
          ),
        ),
      );
    }

    if (series.isEmpty) {
      return Scaffold(
        backgroundColor: AppColors.bg,
        appBar: AppBar(
          title: const Text('Series'),
          backgroundColor: AppColors.bg2,
        ),
        body: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.video_library,
                  color: AppColors.textTertiary, size: 48),
              SizedBox(height: 16),
              Text('No series available',
                  style:
                      TextStyle(color: AppColors.textSecondary, fontSize: 14)),
            ],
          ),
        ),
      );
    }

    final genres = _genres(series);
    final filtered = _filtered(series);

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: Text('Series (${series.length})'),
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
                '${filtered.length} series',
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
