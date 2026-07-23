import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';

class SeriesScreen extends StatelessWidget {
  final bool sidebarFocused;
  const SeriesScreen({super.key, this.sidebarFocused = true});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final series = appState.series;
    final isLoading = appState.isContentLoading;

    if (isLoading && series.isEmpty) {
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
              Text(
                'Loading series…',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
              ),
              SizedBox(height: 6),
              Text(
                'This may take a moment',
                style: TextStyle(color: AppColors.textTertiary, fontSize: 11),
              ),
            ],
          ),
        ),
      );
    }

    if (!isLoading && series.isEmpty) {
      return Scaffold(
        backgroundColor: AppColors.bg,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.tv, color: AppColors.textTertiary, size: 64),
              const SizedBox(height: 20),
              const Text(
                'No Series Found',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Series will appear here once loaded.\nCheck your connection or try refreshing.',
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

    final sorted = appState.sortedSeries;

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(
        children: [
          const SizedBox(height: 8),
          Expanded(
            child: ContentGrid(
              items: sorted,
              autoFocusFirst: !sidebarFocused,
              restorationKey: 'series', // FIX #7
            ),
          ),
        ],
      ),
    );
  }
}
