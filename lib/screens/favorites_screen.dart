import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme/app_theme.dart';
import '../services/app_state.dart';
import '../widgets/common_widgets.dart';

class FavoritesScreen extends StatelessWidget {
  const FavoritesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final favs = context.watch<AppState>().favorites;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: Text('My Favorites (${favs.length})'),
        backgroundColor: AppColors.bg2,
      ),
      body: favs.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      color: AppColors.bg3,
                      shape: BoxShape.circle,
                      border: Border.all(color: AppColors.border),
                    ),
                    child: const Icon(Icons.favorite_border,
                        color: AppColors.textTertiary, size: 36),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'No favorites yet',
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Tap ♡ on any content to save it here',
                    style:
                        TextStyle(fontSize: 13, color: AppColors.textTertiary),
                  ),
                ],
              ),
            )
          : ContentGrid(items: favs),
    );
  }
}
