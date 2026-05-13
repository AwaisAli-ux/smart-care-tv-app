import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

enum SettingsTab {
  parentalControl,
  videoQuality,
  notifications,
  device,
  about,
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  SettingsTab _selectedTab = SettingsTab.videoQuality;

  // Parental Control state
  bool _parentalEnabled = false;
  bool _blockAdult = true;
  final List<TextEditingController> _pinControllers = List.generate(4, (_) => TextEditingController());
  final List<FocusNode> _pinNodes = List.generate(4, (_) => FocusNode());

  @override
  void dispose() {
    for (var controller in _pinControllers) {
      controller.dispose();
    }
    for (var node in _pinNodes) {
      node.dispose();
    }
    super.dispose();
  }

  // Video Quality state
  String _selectedQuality = 'Auto (Recommended)';
  final _qualities = ['Auto (Recommended)', '4K Ultra HD', '1080p Full HD', '720p HD', '480p SD'];
  bool _hwAccel = true;

  // Notifications state
  bool _notifContent = true;
  bool _notifLive = true;
  bool _notifSystem = false;
  bool _notifPromos = false;

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
                      _navItem(SettingsTab.parentalControl, Icons.shield_outlined, 'Parental Control'),
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
      case SettingsTab.parentalControl:
        return 'Parental Control';
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
      case SettingsTab.parentalControl:
        return Icons.shield_outlined;
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
    );
  }

  Widget _buildCurrentTab({required bool isPhone}) {
    switch (_selectedTab) {
      case SettingsTab.parentalControl:
        return _buildParentalControlTab(isPhone);
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



  // ── Parental Control Tab ────────────────────────────────────────────────
  Widget _buildParentalControlTab(bool isPhone) {
    final padding = isPhone
        ? const EdgeInsets.all(16)
        : const EdgeInsets.all(40);
    return ListView(
      padding: padding,
      children: [
        _buildHeader('Parental Control', 'Restrict access to content with a PIN'),
        _buildSwitchRow(
          title: 'Enable Parental Control',
          subtitle: 'Require PIN to access restricted content',
          value: _parentalEnabled,
          onChanged: (v) => setState(() => _parentalEnabled = v),
        ),
        const SizedBox(height: 24),
        const Text(
          'Set your 4-digit PIN',
          style: TextStyle(fontSize: 15, color: AppColors.textPrimary, fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 16),
        Row(
          children: List.generate(
            4,
            (index) => Container(
              width: isPhone ? 44 : 50,
              height: isPhone ? 52 : 60,
              margin: const EdgeInsets.only(right: 12),
              decoration: BoxDecoration(
                color: AppColors.bg3,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.border),
              ),
              child: Center(
                child: TextField(
                  controller: _pinControllers[index],
                  focusNode: _pinNodes[index],
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  maxLength: 1,
                  obscureText: true,
                  style: TextStyle(
                    fontSize: isPhone ? 20 : 24,
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                  decoration: const InputDecoration(
                    counterText: '',
                    border: InputBorder.none,
                  ),
                  onChanged: (value) {
                    if (value.isNotEmpty && index < 3) {
                      _pinNodes[index + 1].requestFocus();
                    } else if (value.isEmpty && index > 0) {
                      _pinNodes[index - 1].requestFocus();
                    }
                  },
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 32),
        _buildSwitchRow(
          title: 'Block Adult Content',
          value: _blockAdult,
          onChanged: (v) => setState(() => _blockAdult = v),
        ),
        const SizedBox(height: 24),
        Align(
          alignment: Alignment.centerLeft,
          child: ElevatedButton(
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('PIN saved'), backgroundColor: AppColors.bg4),
              );
            },
            child: const Text('Save PIN'),
          ),
        ),
      ],
    );
  }

  // ── Video Quality Tab ───────────────────────────────────────────────────
  Widget _buildVideoQualityTab(bool isPhone) {
    final padding = isPhone
        ? const EdgeInsets.all(16)
        : const EdgeInsets.all(40);
    return ListView(
      padding: padding,
      children: [
        _buildHeader('Video Quality', 'Adjust playback quality based on your connection'),
        ..._qualities.map((q) {
          final isSelected = _selectedQuality == q;
          return InkWell(
            onTap: () => setState(() => _selectedQuality = q),
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
          );
        }),
        const SizedBox(height: 16),
        _buildSwitchRow(
          title: 'Hardware Acceleration',
          value: _hwAccel,
          onChanged: (v) => setState(() => _hwAccel = v),
        ),
        const SizedBox(height: 24),
        Align(
          alignment: Alignment.centerLeft,
          child: ElevatedButton(
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Quality saved'), backgroundColor: AppColors.bg4),
              );
            },
            child: const Text('Save'),
          ),
        ),
      ],
    );
  }

  // ── Notifications Tab ───────────────────────────────────────────────────
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

  // ── Device Tab ──────────────────────────────────────────────────────────
  Widget _buildDeviceTab(bool isPhone) {
    final padding = isPhone
        ? const EdgeInsets.all(16)
        : const EdgeInsets.all(40);
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
          subtitle: 'Smart Care TV v2.1.0',
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
        _buildActionRow(
          title: 'Refresh Content',
          subtitle: 'Reload all channels and metadata',
          actionText: 'Refresh',
          onTap: () {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Content refreshed'), backgroundColor: AppColors.bg4),
            );
          },
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

  // ── About Tab ───────────────────────────────────────────────────────────
  Widget _buildAboutTab(bool isPhone) {
    return Center(
      child: Padding(
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
              'Version 2.1.0',
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
          ],
        ),
      ),
    );
  }

  // ── Shared UI Helpers ───────────────────────────────────────────────────
  Widget _buildSwitchRow({
    required String title,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
    bool hasDivider = false,
  }) {
    return Column(
      children: [
        Padding(
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
                OutlinedButton(
                  onPressed: onTap,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textPrimary,
                    side: const BorderSide(color: AppColors.border),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                  ),
                  child: Text(actionText),
                ),
            ],
          ),
        ),
        const Divider(color: AppColors.border, height: 1),
      ],
    );
  }
}
