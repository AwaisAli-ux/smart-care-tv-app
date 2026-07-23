// ============================================================
// LIVE TV SCREEN
// ============================================================
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';

class LiveTvScreen extends StatelessWidget {
  final bool sidebarFocused;
  const LiveTvScreen({super.key, this.sidebarFocused = true});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final channels = appState.channels;
    final isLoading = appState.isContentLoading;

    if (isLoading && channels.isEmpty) {
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

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(
        children: [
          const SizedBox(height: 8),
          Expanded(
            // autoFocusFirst is intentionally false — focus only enters
            // the grid when the user presses Right/Enter on the sidebar.
            child: ChannelGrid(
              items: channels,
              autoFocusFirst: false,
              restorationKey: 'live_tv', // FIX #7
            ),
          ),
        ],
      ),
    );
  }
}
