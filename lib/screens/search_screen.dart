import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/content_model.dart';
import '../services/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});
  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _ctrl = TextEditingController();
  String _query = '';
  String _tab = 'All';
  final _tabs = ['All', 'Live TV', 'Movies', 'Series'];
  final _suggestions = [
    'Sports',
    'News',
    'Action',
    'Comedy',
    'Drama',
    'Kids',
    'Thriller',
    'HBO',
    'Documentary',
    'Sci-Fi',
  ];

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  List<ContentItem> _getResults(AppState appState) {
    final q = _query.toLowerCase();
    if (q.isEmpty) return [];
    List<ContentItem> pool;
    switch (_tab) {
      case 'Live TV':
        pool = appState.channels;
        break;
      case 'Movies':
        pool = appState.movies;
        break;
      case 'Series':
        pool = appState.series;
        break;
      default:
        pool = [
          ...appState.channels,
          ...appState.movies,
          ...appState.series,
        ];
    }
    return pool
        .where((x) =>
            x.title.toLowerCase().contains(q) ||
            (x.genre ?? x.category ?? '').toLowerCase().contains(q) ||
            (x.description ?? '').toLowerCase().contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            // Search bar
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Row(
                children: [
                  if (Navigator.canPop(context))
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: IconButton(
                        icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ),
                  Expanded(
                    child: TextField(
                      controller: _ctrl,
                      style: const TextStyle(
                          color: AppColors.textPrimary, fontFamily: 'Inter'),
                      onChanged: (v) => setState(() => _query = v),
                      decoration: InputDecoration(
                        hintText: 'Search channels, movies, series...',
                        prefixIcon: const Icon(Icons.search,
                            color: AppColors.textTertiary, size: 20),
                        suffixIcon: _query.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.close,
                                    color: AppColors.textTertiary, size: 18),
                                onPressed: () {
                                  _ctrl.clear();
                                  setState(() => _query = '');
                                },
                              )
                            : null,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Type tabs
            SizedBox(
              height: 36,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: _tabs.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, i) {
                  final tab = _tabs[i];
                  final active = tab == _tab;
                  return InkWell(
                    onTap: () => setState(() => _tab = tab),
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
                        tab,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight:
                              active ? FontWeight.w600 : FontWeight.w400,
                          color: active ? Colors.white : AppColors.textTertiary,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),

            Expanded(
              child: _query.isEmpty ? _suggestionsView() : _resultsView(appState),
            ),
          ],
        ),
      ),
    );
  }

  Widget _suggestionsView() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Popular searches',
            style: TextStyle(fontSize: 13, color: AppColors.textTertiary),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _suggestions
                .map((s) => InkWell(
                      onTap: () {
                        _ctrl.text = s;
                        setState(() => _query = s);
                      },
                      borderRadius: BorderRadius.circular(20),
                      focusColor: AppColors.accent.withValues(alpha: 0.25),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 7),
                        decoration: BoxDecoration(
                          color: AppColors.bg3,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: AppColors.border),
                        ),
                        child: Text(s,
                            style: const TextStyle(
                                fontSize: 12, color: AppColors.textSecondary)),
                      ),
                    ))
                .toList(),
          ),
        ],
      ),
    );
  }

  Widget _resultsView(AppState appState) {
    final results = _getResults(appState);
    if (results.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.search_off,
                color: AppColors.textTertiary, size: 56),
            const SizedBox(height: 14),
            Text(
              'No results for "$_query"',
              style:
                  const TextStyle(color: AppColors.textTertiary, fontSize: 15),
            ),
            const SizedBox(height: 6),
            const Text(
              'Try a different keyword or category',
              style: TextStyle(color: AppColors.textTertiary, fontSize: 12),
            ),
          ],
        ),
      );
    }
    return ContentGrid(items: results);
  }
}
