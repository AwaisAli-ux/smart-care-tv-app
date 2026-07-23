import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_theme.dart';
import '../services/auth_config.dart';
import '../widgets/tv_focus.dart';

/// Why [LockedScreen] is being shown — changes copy + whether Retry is offered.
enum LockReason {
  /// Admin locked the account or this specific device.
  locked,

  /// Device has been offline longer than [AuthConfig.offlineGracePeriod]
  /// without a successful status check.
  offline,
}

/// Full-screen, non-dismissible gate. Shown whenever the backend reports the
/// account/device as locked, or the offline grace period has been exceeded.
/// No back navigation — the only way out is a successful status check
/// (automatic retry via [DeviceLockService], or the Retry button below).
class LockedScreen extends StatelessWidget {
  final LockReason reason;
  final VoidCallback? onRetry;

  const LockedScreen({super.key, this.reason = LockReason.locked, this.onRetry});

  @override
  Widget build(BuildContext context) {
    final isOffline = reason == LockReason.offline;

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
                Icon(
                  isOffline ? Icons.wifi_off_rounded : Icons.lock_outline_rounded,
                  color: AppColors.accent,
                  size: 56,
                ),
                const SizedBox(height: 20),
                Text(
                  isOffline ? 'Connection Required' : 'App Locked',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                    fontFamily: 'Inter',
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  isOffline
                      ? 'We couldn\'t verify your device for too long. '
                          'Please connect to the internet to continue watching.'
                      : 'Please contact support to restore access.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 15,
                    color: AppColors.textSecondary,
                    fontFamily: 'Inter',
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 28),
                if (!isOffline) _SupportContact(),
                const SizedBox(height: 32),
                if (onRetry != null)
                  TvFocusable(
                    autofocus: true,
                    scaleOnFocus: true,
                    borderRadius: 8,
                    onActivate: onRetry,
                    child: SizedBox(
                      width: 220,
                      height: 48,
                      child: ElevatedButton.icon(
                        onPressed: onRetry,
                        icon: const Icon(Icons.refresh_rounded, size: 20),
                        label: const Text('Retry'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.accent,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 14),
                TvFocusable(
                  autofocus: onRetry == null,
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

class _SupportContact extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      borderRadius: 8,
      onActivate: () async {
        await Clipboard.setData(const ClipboardData(text: AuthConfig.supportContact));
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Support contact copied to clipboard')),
          );
        }
      },
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
              AuthConfig.supportContactLabel,
              style: TextStyle(fontSize: 11, color: AppColors.textTertiary, letterSpacing: 0.6),
            ),
            const SizedBox(height: 4),
            Text(
              AuthConfig.supportContact,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppColors.accent,
                fontFamily: 'Inter',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
