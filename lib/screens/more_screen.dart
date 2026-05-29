import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/app_theme.dart';
import '../services/app_state.dart';
import '../widgets/common_widgets.dart';
import 'login_screen.dart';

class MoreScreen extends StatelessWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: const Text('More'),
        backgroundColor: AppColors.bg2,
      ),
      body: ListView(
        children: [
          _tile(context,
              icon: Icons.logout,
              iconColor: Colors.red,
              title: 'Sign Out',
              titleColor: Colors.red,
              onTap: () async {
                // Clear persisted login so splash won't auto-login next time
                final prefs = await SharedPreferences.getInstance();
                await prefs.remove('loggedIn');
                await prefs.remove('username');
                await prefs.remove('password');
                if (!context.mounted) return;
                // logout() clears in-memory data but does NOT delete the per-user
                // favorites from disk — they will be restored on next login.
                Provider.of<AppState>(context, listen: false).logout();
                Navigator.of(context).pushAndRemoveUntil(
                  MaterialPageRoute(builder: (_) => const LoginScreen()),
                  (_) => false,
                );
              }),
        ],
      ),
    );
  }

  Widget _tile(
    BuildContext context, {
    required IconData icon,
    Color? iconColor,
    required String title,
    Color? titleColor,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: tvFocusWrapper(
        onActivate: onTap,
        child: Builder(
          builder: (focusCtx) {
            final hasFocus = Focus.of(focusCtx).hasFocus;
            return ListTile(
              leading: Icon(icon, color: hasFocus ? Colors.white : (iconColor ?? AppColors.textTertiary), size: 22),
              title: Text(
                title,
                style: TextStyle(
                  fontSize: 14,
                  color: hasFocus ? Colors.white : (titleColor ?? AppColors.textPrimary),
                  fontWeight: FontWeight.w500,
                ),
              ),
              trailing: Icon(
                Icons.chevron_right,
                color: hasFocus ? Colors.white : (titleColor ?? AppColors.textTertiary),
                size: 18,
              ),
              onTap: onTap,
            );
          },
        ),
      ),
    );
  }

}

