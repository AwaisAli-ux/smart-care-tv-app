// ============================================================
// LIVE TV SCREEN
// ============================================================
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/content_model.dart';
import '../services/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';

class LiveTvScreen extends StatefulWidget {
  const LiveTvScreen({super.key});
  @override
  State<LiveTvScreen> createState() => _LiveTvScreenState();
}

class _LiveTvScreenState extends State<LiveTvScreen> {
  String _selectedCat = 'All';

  List<String> _cats(List<ContentItem> channels) {
    final catSet = <String>{};
    for (final c in channels) {
      catSet.add(c.category ?? 'Uncategorized');
    }
    final sorted = catSet.toList()..sort();
    return ['All', ...sorted];
  }

  List<ContentItem> _filtered(List<ContentItem> channels) {
    if (_selectedCat == 'All') return channels;
    return channels
        .where((c) => (c.category ?? 'Uncategorized') == _selectedCat)
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final channels = appState.channels;
    final isLoading = appState.isContentLoading;

    if (isLoading && channels.isEmpty) {
      return Scaffold(
        backgroundColor: AppColors.bg,
        appBar: AppBar(
          title: const Text('Live TV'),
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
              Text('Loading live channels...',
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
            ],
          ),
        ),
      );
    }

    if (channels.isEmpty) {
      return Scaffold(
        backgroundColor: AppColors.bg,
        appBar: AppBar(
          title: const Text('Live TV'),
          backgroundColor: AppColors.bg2,
        ),
        body: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.live_tv, color: AppColors.textTertiary, size: 48),
              SizedBox(height: 16),
              Text('No live channels available',
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 14)),
            ],
          ),
        ),
      );
    }

    final cats = _cats(channels);
    final filtered = _filtered(channels);

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: Text('Live TV (${channels.length})'),
        backgroundColor: AppColors.bg2,
        actions: [
          IconButton(
              icon: const Icon(Icons.calendar_today_outlined),
              onPressed: () {}),
        ],
      ),
      body: Column(
        children: [
          const SizedBox(height: 8),
          FilterChipsRow(
              categories: cats,
              selected: _selectedCat,
              onSelect: (c) => setState(() => _selectedCat = c)),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '${filtered.length} channels',
                style: const TextStyle(
                    color: AppColors.textTertiary, fontSize: 11),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: ChannelGrid(items: filtered),
          ),
        ],
      ),
    );
  }
}
