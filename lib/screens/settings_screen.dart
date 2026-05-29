import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../theme/app_theme.dart';
import '../widgets/tv_focus.dart';
import '../services/app_state.dart';

enum SettingsTab {
  videoQuality,
  notifications,
  device,
  about,
}

class SettingsScreen extends StatefulWidget {
  final bool sidebarFocused;
  const SettingsScreen({super.key, this.sidebarFocused = true});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  SettingsTab _selectedTab = SettingsTab.videoQuality;
  final FocusNode _firstSubTabFocusNode = FocusNode(debugLabel: 'FirstSubTab');

  // Platform channel for native app restart
  static const _nativeCh = MethodChannel('com.example.mbapp/audio');

  // Notifications state
  bool _notifContent = true;
  bool _notifLive = true;
  bool _notifSystem = false;
  bool _notifPromos = false;

  @override
  void didUpdateWidget(SettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sidebarFocused && !widget.sidebarFocused) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _firstSubTabFocusNode.requestFocus();
        }
      });
    }
  }

  @override
  void dispose() {
    _firstSubTabFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isPhone = screenWidth < 600;

    return Scaffold(
      backgroundColor: AppColors.bg,
      // On phone: show a drawer-style navigation
      appBar: isPhone
          ? AppBar(
              backgroundColor: AppColors.bg2,
              title: Text(
                _tabLabel(_selectedTab),
                style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary),
              ),
              leading: Navigator.canPop(context)
                  ? IconButton(
                      icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
                      onPressed: () => Navigator.pop(context),
                    )
                  : null,
              actions: [
                PopupMenuButton<SettingsTab>(
                  icon: const Icon(Icons.menu, color: AppColors.textPrimary),
                  color: AppColors.bg3,
                  onSelected: (tab) => setState(() => _selectedTab = tab),
                  itemBuilder: (_) => SettingsTab.values.map((tab) {
                    return PopupMenuItem(
                      value: tab,
                      child: Row(
                        children: [
                          Icon(_tabIcon(tab),
                              size: 20,
                              color: _selectedTab == tab
                                  ? AppColors.accent
                                  : AppColors.textSecondary),
                          const SizedBox(width: 12),
                          Text(
                            _tabLabel(tab),
                            style: TextStyle(
                              color: _selectedTab == tab
                                  ? AppColors.accent
                                  : AppColors.textPrimary,
                              fontWeight: _selectedTab == tab
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              ],
            )
          : null,
      body: isPhone
          ? _buildCurrentTab(isPhone: true)
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Left Sidebar (tablet/desktop only)
                Container(
                  width: 250,
                  decoration: const BoxDecoration(
                    color: AppColors.bg2,
                    border: Border(right: BorderSide(color: AppColors.border, width: 1)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 24, 24, 8),
                        child: Row(
                          children: [
                            if (Navigator.canPop(context))
                              IconButton(
                                icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
                                onPressed: () => Navigator.pop(context),
                              )
                            else
                              const SizedBox(width: 16),
                            const Text(
                              'PREFERENCES',
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.textTertiary,
                                  letterSpacing: 1.2),
                            ),
                          ],
                        ),
                      ),
                      _navItem(SettingsTab.videoQuality, Icons.video_settings_outlined, 'Video Quality'),
                      _navItem(SettingsTab.notifications, Icons.notifications_outlined, 'Notifications'),
                      _navItem(SettingsTab.device, Icons.smartphone_outlined, 'Device'),
                      _navItem(SettingsTab.about, Icons.info_outline, 'About'),
                    ],
                  ),
                ),
                // Right Content Area
                Expanded(
                  child: Container(
                    color: AppColors.bg,
                    child: _buildCurrentTab(isPhone: false),
                  ),
                ),
              ],
            ),
    );
  }

  String _tabLabel(SettingsTab tab) {
    switch (tab) {
      case SettingsTab.videoQuality:
        return 'Video Quality';
      case SettingsTab.notifications:
        return 'Notifications';
      case SettingsTab.device:
        return 'Device';
      case SettingsTab.about:
        return 'About';
    }
  }

  IconData _tabIcon(SettingsTab tab) {
    switch (tab) {
      case SettingsTab.videoQuality:
        return Icons.video_settings_outlined;
      case SettingsTab.notifications:
        return Icons.notifications_outlined;
      case SettingsTab.device:
        return Icons.smartphone_outlined;
      case SettingsTab.about:
        return Icons.info_outline;
    }
  }

  Widget _navItem(SettingsTab tab, IconData icon, String label) {
    final isActive = _selectedTab == tab;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: TvFocusable(
        focusNode: isActive ? _firstSubTabFocusNode : null,
        autofocus: !widget.sidebarFocused && isActive,
        onActivate: () => setState(() => _selectedTab = tab),
        borderRadius: 8,
        child: InkWell(
          onTap: () => setState(() => _selectedTab = tab),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: isActive ? AppColors.bg4 : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(icon, size: 20, color: isActive ? AppColors.accent : AppColors.textSecondary),
                const SizedBox(width: 16),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                    color: isActive ? AppColors.accent : AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCurrentTab({required bool isPhone}) {
    switch (_selectedTab) {
      case SettingsTab.videoQuality:
        return _buildVideoQualityTab(isPhone);
      case SettingsTab.notifications:
        return _buildNotificationsTab(isPhone);
      case SettingsTab.device:
        return _buildDeviceTab(isPhone);
      case SettingsTab.about:
        return _buildAboutTab(isPhone);
    }
  }

  Widget _buildHeader(String title, String subtitle) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w600,
              color: AppColors.accent,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: const TextStyle(
              fontSize: 14,
              color: AppColors.textTertiary,
            ),
          ),
        ],
      ),
    );
  }


  // ── Video Quality Tab ─────────────────────────────────────────────────
  Widget _buildVideoQualityTab(bool isPhone) {
    final padding = isPhone
        ? const EdgeInsets.all(16)
        : const EdgeInsets.all(40);
    final appState = context.watch<AppState>();
    final bufferOptions = [
      ('small',  'Small (32 MB)',  'Best for slow connections / low-memory TVs'),
      ('medium', 'Medium (64 MB)', 'Recommended for most TVs'),
      ('large',  'Large (128 MB)', 'For fast connections and premium streaming'),
    ];

    return ListView(
      padding: padding,
      children: [
        _buildHeader('Video Quality', 'Adjust playback quality and decoder settings'),

        // ─── Compatibility Warning Banner ──────────────────────────────────
        // Shows a red WARNING when HW accel is ON (most common cause of
        // scrambled video on client TVs). Shows green confirmation when OFF.
        if (appState.hardwareAccelEnabled)
          Container(
            margin: const EdgeInsets.only(bottom: 16),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF2A1010),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.red.shade700, width: 2),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.warning_amber_rounded, color: Colors.red.shade400, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      '⚠  SCRAMBLED VIDEO RISK',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: Colors.red.shade400,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Hardware Acceleration is ON. This causes green/scrambled video on many TV brands '
                  '(Amlogic, Rockchip, MTK, Mali GPU). Turn it OFF for maximum compatibility.',
                  style: TextStyle(fontSize: 12, color: Colors.red.shade200, height: 1.5),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: TvFocusable(
                    onActivate: () {
                      context.read<AppState>().setHardwareAccel(false);
                      context.read<AppState>().setBufferSize('medium');
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('✅ Reset to safe defaults — software decoding active'),
                        backgroundColor: Color(0xFF1B5E20),
                        duration: Duration(seconds: 3),
                      ));
                    },
                    borderRadius: 8,
                    child: ElevatedButton.icon(
                      onPressed: () {
                        context.read<AppState>().setHardwareAccel(false);
                        context.read<AppState>().setBufferSize('medium');
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                          content: Text('✅ Reset to safe defaults — software decoding active'),
                          backgroundColor: Color(0xFF1B5E20),
                          duration: Duration(seconds: 3),
                        ));
                      },
                      icon: const Icon(Icons.shield_outlined, size: 18),
                      label: const Text('Reset to Safe Defaults'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red.shade800,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          )
        else
          Container(
            margin: const EdgeInsets.only(bottom: 16),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF0A1F10),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.green.shade800, width: 1),
            ),
            child: Row(
              children: [
                Icon(Icons.check_circle_outline, color: Colors.green.shade400, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Software decoding active ✓ — Maximum compatibility with all TV brands '
                    '(MI Box, TCL, Samsung, Sony, Hisense, Fire Stick, generic Android boxes).',
                    style: TextStyle(fontSize: 12, color: Colors.green.shade300, height: 1.5),
                  ),
                ),
              ],
            ),
          ),

        // ─── Hardware Acceleration ─────────────────────────────────────────
        _buildSwitchRow(
          title: 'Hardware Acceleration',
          subtitle: 'OFF = Software decode (recommended for ALL TVs)\nON = Hardware decode (may cause scrambled/green video on Amlogic, Rockchip, MTK, Mali GPU boxes)',
          value: appState.hardwareAccelEnabled,
          onChanged: (v) => context.read<AppState>().setHardwareAccel(v),
        ),

        const SizedBox(height: 28),
        const Text(
          'STREAM QUALITY',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: AppColors.textTertiary,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 12),
        ...['Auto (Recommended)', '4K Ultra HD', '1080p Full HD', '720p HD', '480p SD'].map((q) {
          final isSelected = appState.selectedQuality == q;
          return TvFocusable(
            onActivate: () => context.read<AppState>().setSelectedQuality(q),
            borderRadius: 8,
            child: InkWell(
              onTap: () => context.read<AppState>().setSelectedQuality(q),
              borderRadius: BorderRadius.circular(8),
              focusColor: AppColors.accent.withValues(alpha: 0.2),
              child: Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                decoration: BoxDecoration(
                  color: AppColors.bg2,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isSelected ? AppColors.accent : AppColors.border,
                    width: 1,
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        q,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                    Icon(
                      isSelected ? Icons.check_circle : Icons.circle_outlined,
                      color: isSelected ? AppColors.accent : AppColors.textTertiary,
                      size: 22,
                    ),
                  ],
                ),
              ),
            ),
          );
        }),

        const SizedBox(height: 28),
        const Text(
          'BUFFER SIZE',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: AppColors.textTertiary,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Controls how much video is pre-loaded. Larger buffers reduce stuttering but use more RAM.',
          style: TextStyle(fontSize: 12, color: AppColors.textTertiary, height: 1.5),
        ),
        const SizedBox(height: 14),
        ...bufferOptions.map((opt) {
          final (key, label, desc) = opt;
          final isSelected = appState.bufferSize == key;
          return TvFocusable(
            onActivate: () => context.read<AppState>().setBufferSize(key),
            borderRadius: 8,
            child: InkWell(
              onTap: () => context.read<AppState>().setBufferSize(key),
              borderRadius: BorderRadius.circular(8),
              focusColor: AppColors.accent.withValues(alpha: 0.2),
              child: Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                decoration: BoxDecoration(
                  color: AppColors.bg2,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isSelected ? AppColors.accent : AppColors.border,
                    width: 1,
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            label + (key == 'medium' ? '  —  Recommended' : ''),
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                              color: AppColors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            desc,
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppColors.textTertiary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      isSelected ? Icons.check_circle : Icons.circle_outlined,
                      color: isSelected ? AppColors.accent : AppColors.textTertiary,
                      size: 22,
                    ),
                  ],
                ),
              ),
            ),
          );
        }),

        const SizedBox(height: 24),
        // Settings are saved automatically on change — no Save button needed
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.green.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.green.withValues(alpha: 0.3)),
          ),
          child: const Row(
            children: [
              Icon(Icons.check_circle_outline, color: Colors.green, size: 16),
              SizedBox(width: 8),
              Text(
                'Settings are saved automatically',
                style: TextStyle(fontSize: 13, color: Colors.green),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── Notifications Tab ──────────────────────────────────────────────────
  Widget _buildNotificationsTab(bool isPhone) {
    final padding = isPhone
        ? const EdgeInsets.all(16)
        : const EdgeInsets.all(40);
    return ListView(
      padding: padding,
      children: [
        _buildHeader('Notifications', 'Manage your notification preferences'),
        _buildSwitchRow(
          title: 'New content alerts',
          subtitle: 'Get notified when new content is added',
          value: _notifContent,
          onChanged: (v) => setState(() => _notifContent = v),
          hasDivider: true,
        ),
        _buildSwitchRow(
          title: 'Live event reminders',
          subtitle: 'Reminders before live events start',
          value: _notifLive,
          onChanged: (v) => setState(() => _notifLive = v),
          hasDivider: true,
        ),
        _buildSwitchRow(
          title: 'System announcements',
          subtitle: 'Important updates from Smart Care TV',
          value: _notifSystem,
          onChanged: (v) => setState(() => _notifSystem = v),
          hasDivider: true,
        ),
        _buildSwitchRow(
          title: 'Promotions & offers',
          subtitle: 'Deals and special offers',
          value: _notifPromos,
          onChanged: (v) => setState(() => _notifPromos = v),
          hasDivider: true,
        ),
      ],
    );
  }

  // ── Device Tab ────────────────────────────────────────────────────────
  Widget _buildDeviceTab(bool isPhone) {
    final padding = isPhone
        ? const EdgeInsets.all(16)
        : const EdgeInsets.all(40);
    final appState = context.watch<AppState>();
    return ListView(
      padding: padding,
      children: [
        _buildHeader('Device', 'Device management and diagnostics'),
        _buildActionRow(
          title: 'Device Name',
          subtitle: 'Smart TV — Living Room',
          actionText: 'Edit',
          onTap: () {},
        ),
        _buildActionRow(
          title: 'App Version',
          subtitle: 'Smart Care TV v2.5.1',
        ),
        _buildActionRow(
          title: 'Clear Cache',
          subtitle: 'Free up storage space',
          actionText: 'Clear',
          onTap: () {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Cache cleared'), backgroundColor: AppColors.bg4),
            );
          },
        ),

        // ── Refresh Content — wired to actually reload from server ─────────
        Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Refresh Content',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          appState.isRefreshing
                              ? 'Reloading channels, movies & series…'
                              : 'Reload all channels and metadata from server',
                          style: const TextStyle(
                            fontSize: 13,
                            color: AppColors.textTertiary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  appState.isRefreshing
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            valueColor: AlwaysStoppedAnimation<Color>(AppColors.accent),
                          ),
                        )
                      : TvFocusable(
                          onActivate: () => context.read<AppState>().refreshContent(),
                          borderRadius: 6,
                          child: OutlinedButton(
                            onPressed: () => context.read<AppState>().refreshContent(),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppColors.accent,
                              side: const BorderSide(color: AppColors.accent),
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                            ),
                            child: const Text('Refresh'),
                          ),
                        ),
                ],
              ),
            ),
            const Divider(color: AppColors.border, height: 1),
          ],
        ),

        const SizedBox(height: 24),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: AppColors.accent),
              foregroundColor: AppColors.accent,
            ),
            onPressed: () {},
            child: const Text('Reset to Factory Defaults'),
          ),
        ),
      ],
    );
  }

  // ── About Tab ─────────────────────────────────────────────────────────
  Widget _buildAboutTab(bool isPhone) {
    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(isPhone ? 16 : 40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Image.asset(
              'assets/images/app_logo.png',
              width: 90,
              height: 90,
              filterQuality: FilterQuality.high,
            ),
            const SizedBox(height: 20),
            const Text(
              'Smart Care TV',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Version 2.5.1',
              style: TextStyle(
                fontSize: 14,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'Developed for the best viewing experience.\nAll rights reserved.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: AppColors.textTertiary,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 36),

            // ── Restart App card ────────────────────────────────────────────
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxWidth: 340),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: AppColors.accent.withValues(alpha: 0.4), width: 1),
                color: AppColors.bg2,
              ),
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.refresh_rounded,
                          color: AppColors.accent, size: 20),
                      SizedBox(width: 8),
                      Text(
                        'APP CONTROLS',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: AppColors.accent,
                          letterSpacing: 1.0,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Restart App',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Fully restarts the app and refreshes all content. '
                    'Use this if channels stop loading or the app feels sluggish.',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.textTertiary,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: TvFocusable(
                      onActivate: _doRestartApp,
                      borderRadius: 8,
                      child: ElevatedButton.icon(
                        onPressed: _doRestartApp,
                        icon: const Icon(Icons.restart_alt_rounded, size: 20),
                        label: const Text('Restart App'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.accent,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8)),
                          textStyle: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Invokes the native restartApp channel — fully relaunches the app process.
  /// Falls back to popping all routes to splash if native call fails.
  Future<void> _doRestartApp() async {
    try {
      await _nativeCh.invokeMethod('restartApp');
    } catch (e) {
      debugPrint('[Settings] restartApp failed: $e — falling back to route reset');
      if (mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    }
  }

  // ── Shared UI Helpers ─────────────────────────────────────────────────
  Widget _buildSwitchRow({
    required String title,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
    bool hasDivider = false,
  }) {
    return Column(
      children: [
        TvFocusable(
          onActivate: () => onChanged(!value),
          borderRadius: 4,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          subtitle,
                          style: const TextStyle(
                            fontSize: 13,
                            color: AppColors.textTertiary,
                          ),
                        ),
                      ]
                    ],
                  ),
                ),
                Switch(
                  value: value,
                  onChanged: onChanged,
                  activeTrackColor: AppColors.accent,
                  inactiveThumbColor: Colors.white,
                  inactiveTrackColor: AppColors.border,
                ),
              ],
            ),
          ),
        ),
        if (hasDivider) const Divider(color: AppColors.border, height: 1),
      ],
    );
  }

  Widget _buildActionRow({
    required String title,
    required String subtitle,
    String? actionText,
    VoidCallback? onTap,
  }) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        fontSize: 13,
                        color: AppColors.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
              if (actionText != null && onTap != null)
                TvFocusable(
                  onActivate: onTap,
                  borderRadius: 6,
                  child: OutlinedButton(
                    onPressed: onTap,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.textPrimary,
                      side: const BorderSide(color: AppColors.border),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                    ),
                    child: Text(actionText),
                  ),
                ),
            ],
          ),
        ),
        const Divider(color: AppColors.border, height: 1),
      ],
    );
  }
}
