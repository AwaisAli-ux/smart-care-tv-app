import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';

class SeriesScreen extends StatefulWidget {
  const SeriesScreen({super.key});
  @override
  State<SeriesScreen> createState() => _SeriesScreenState();
}

class _SeriesScreenState extends State<SeriesScreen> {


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



    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: const Text('Series'),
        backgroundColor: AppColors.bg2,
      ),
      body: Column(
        children: [
          const SizedBox(height: 8),
          Expanded(
            child: ContentGrid(items: series, autoFocusFirst: true),
          ),
        ],
      ),
    );
  }
}
