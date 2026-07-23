import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_theme.dart';
import '../services/auth_config.dart';
import '../widgets/tv_focus.dart';

/// Full-screen, non-dismissible gate shown when the backend reports the
/// account's subscription as expired (login.php / check_status.php
/// `status: "expired"`).
class ExpiredScreen extends StatelessWidget {
  final String? expiryDate;
  const ExpiredScreen({super.key, this.expiryDate});

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: AppColors.bg,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.asset(
                  'assets/images/app_logo.png',
                  width: 88,
                  height: 88,
                  filterQuality: FilterQuality.high,
                ),
                const SizedBox(height: 28),
                const Icon(Icons.event_busy_rounded, color: AppColors.gold, size: 56),
                const SizedBox(height: 20),
                const Text(
                  'Subscription Expired',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                    fontFamily: 'Inter',
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  expiryDate != null && expiryDate!.isNotEmpty
                      ? 'Your subscription expired on $expiryDate. '
                          'Renew to keep watching Smart Care TV.'
                      : 'Your subscription has expired. Renew to keep watching Smart Care TV.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 15,
                    color: AppColors.textSecondary,
                    fontFamily: 'Inter',
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 28),
                TvFocusable(
                  borderRadius: 8,
                  onActivate: () {},
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                    decoration: BoxDecoration(
                      color: AppColors.bg2,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'To renew, contact',
                          style: TextStyle(fontSize: 11, color: AppColors.textTertiary, letterSpacing: 0.4),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          AuthConfig.supportContact,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: AppColors.gold,
                            fontFamily: 'Inter',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 32),
                TvFocusable(
                  autofocus: true,
                  borderRadius: 8,
                  onActivate: () => SystemNavigator.pop(),
                  child: SizedBox(
                    width: 220,
                    height: 44,
                    child: OutlinedButton(
                      onPressed: () => SystemNavigator.pop(),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.textSecondary,
                        side: const BorderSide(color: AppColors.border),
                      ),
                      child: const Text('Exit'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
