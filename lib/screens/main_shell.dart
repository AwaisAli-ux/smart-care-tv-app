import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import '../theme/app_theme.dart';
import 'home_screen.dart';
import 'search_screen.dart';
import 'live_tv_screen.dart';
import 'movies_screen.dart';
import 'series_screen.dart';
import 'favorites_screen.dart';
import 'settings_screen.dart';
import 'more_screen.dart';

// TV remote D-pad / Enter key codes
const _kDpadCenter = LogicalKeyboardKey.select;
const _kEnter = LogicalKeyboardKey.enter;
const _kDpadUp = LogicalKeyboardKey.arrowUp;
const _kDpadDown = LogicalKeyboardKey.arrowDown;
const _kDpadLeft = LogicalKeyboardKey.arrowLeft;
const _kDpadRight = LogicalKeyboardKey.arrowRight;
const _kBack = LogicalKeyboardKey.goBack;
const _kEscape = LogicalKeyboardKey.escape;

class MainShell extends StatefulWidget {
  const MainShell({super.key});
  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _selectedIndex = 0;

  // Whether focus is currently on the sidebar (true) or the content area (false)
  bool _sidebarFocused = true;

  // Cached screen-width flag, updated in build() — used by the key handler
  // so it doesn’t need to call MediaQuery from a non-build context.
  bool _isWide = true;

  // Focus nodes for the two logical zones
  final FocusNode _sidebarFocusScope = FocusNode(debugLabel: 'SidebarScope');
  // FocusScopeNode (not plain FocusNode) is required for TV: when the scope
  // receives focus it automatically forwards to its first focusable child,
  // enabling D-pad traversal through grids / lists in every content screen.
  final FocusScopeNode _contentFocusScopeNode = FocusScopeNode(debugLabel: 'ContentScope');

  final List<_NavItem> _navItems = const [
    _NavItem(icon: Icons.home_outlined, activeIcon: Icons.home, label: 'Home'),
    _NavItem(icon: Icons.search, activeIcon: Icons.search, label: 'Search'),
    _NavItem(
        icon: Icons.live_tv_outlined,
        activeIcon: Icons.live_tv,
        label: 'Live TV'),
    _NavItem(
        icon: Icons.movie_outlined, activeIcon: Icons.movie, label: 'Movies'),
    _NavItem(
        icon: Icons.video_library_outlined,
        activeIcon: Icons.video_library,
        label: 'Series'),
    _NavItem(
        icon: Icons.favorite_border,
        activeIcon: Icons.favorite,
        label: 'Favorites'),
    _NavItem(
        icon: Icons.settings_outlined,
        activeIcon: Icons.settings,
        label: 'Settings'),
    _NavItem(
        icon: Icons.menu_outlined,
        activeIcon: Icons.menu,
        label: 'More'),
  ];

  // Bottom nav visible indices
  static const _bottomIndices = [0, 1, 2, 3, 7];

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
    // Give the sidebar initial focus so the TV remote works from the first
    // frame — without this, no FocusNode owns focus and remote keys are lost.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _sidebarFocusScope.requestFocus();
    });
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    _sidebarFocusScope.dispose();
    _contentFocusScopeNode.dispose();
    super.dispose();
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    final key = event.logicalKey;

    if (kDebugMode) {
      debugPrint('[TV Remote] Key: $key  sidebarFocused=$_sidebarFocused  isWide=$_isWide');
    }

    // Use the cached _isWide flag — safe to read from a key-event callback
    // (no BuildContext / MediaQuery needed).
    final isWide = _isWide;

    try {
      // Handle back/escape to go back to sidebar from content
      if (isWide && !_sidebarFocused) {
        if (key == _kBack || key == _kEscape) {
          setState(() => _sidebarFocused = true);
          _sidebarFocusScope.requestFocus();
          return true;
        }
      }

      // On wide (TV/tablet) sidebar layout:
      if (isWide) {
        if (_sidebarFocused) {
          // Navigate sidebar Up/Down
          if (key == _kDpadUp) {
            final next = (_selectedIndex - 1 + _navItems.length) % _navItems.length;
            setState(() => _selectedIndex = next);
            return true;
          }
          if (key == _kDpadDown) {
            final next = (_selectedIndex + 1) % _navItems.length;
            setState(() => _selectedIndex = next);
            return true;
          }
          // Enter/OK/Right on sidebar → move focus to content
          if (key == _kDpadCenter || key == _kEnter || key == _kDpadRight) {
            setState(() => _sidebarFocused = false);
            _contentFocusScopeNode.requestFocus();
            return true;
          }
        } else {
          // In content — Left key returns focus to sidebar
          if (key == _kDpadLeft) {
            setState(() => _sidebarFocused = true);
            _sidebarFocusScope.requestFocus();
            return true;
          }
          // All other keys (Up/Down/Right/Enter) — let the content widget handle them
          return false;
        }
      } else {
        // On narrow (phone/mobile): Left/Right cycle bottom bar items
        final pos = _bottomIndices.indexOf(_selectedIndex);
        if (key == _kDpadLeft && pos > 0) {
          setState(() => _selectedIndex = _bottomIndices[pos - 1]);
          return true;
        }
        if (key == _kDpadRight && pos >= 0 && pos < _bottomIndices.length - 1) {
          setState(() => _selectedIndex = _bottomIndices[pos + 1]);
          return true;
        }
      }
    } catch (e) {
      debugPrint('[TV Remote] Key handler error: $e');
    }
    return false;
  }

  Widget get _currentScreen {
    switch (_selectedIndex) {
      case 0: return const HomeScreen();
      case 1: return const SearchScreen();
      case 2: return const LiveTvScreen();
      case 3: return const MoviesScreen();
      case 4: return const SeriesScreen();
      case 5: return const FavoritesScreen();
      case 6: return const SettingsScreen();
      case 7: return const MoreScreen();
      default: return const HomeScreen();
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isWide = size.width >= 600;
    // Cache for the key handler (safe to read outside build)
    _isWide = isWide;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        // If in content on TV, back goes to sidebar first
        if (isWide && !_sidebarFocused) {
          setState(() => _sidebarFocused = true);
          _sidebarFocusScope.requestFocus();
          return;
        }
        final shouldExit = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            backgroundColor: AppColors.bg2,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            title: const Row(children: [
              Icon(Icons.exit_to_app, color: AppColors.accent, size: 22),
              SizedBox(width: 10),
              Text('Exit App',
                  style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w600)),
            ]),
            content: const Text(
              'Are you sure you want to exit Smart Care TV?',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 14),
            ),
            actions: [
              TextButton(
                autofocus: true,
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel',
                    style: TextStyle(color: AppColors.textTertiary)),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('OK'),
              ),
            ],
          ),
        );
        if (shouldExit == true && context.mounted) {
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
        backgroundColor: AppColors.bg,
        body: isWide ? _wideLayout() : _narrowLayout(),
      ),
    );
  }

  Widget _wideLayout() {
    return Row(
      children: [
        _SidebarNav(
          items: _navItems,
          selectedIndex: _selectedIndex,
          isFocused: _sidebarFocused,
          focusNode: _sidebarFocusScope,
          onTap: (i) {
            setState(() {
              _selectedIndex = i;
              _sidebarFocused = false;
            });
            _contentFocusScopeNode.requestFocus();
          },
          onNavigateToContent: () {
            setState(() => _sidebarFocused = false);
            _contentFocusScopeNode.requestFocus();
          },
        ),
        Expanded(
          // FocusScope forwards focus to the first focusable child in
          // the current screen — critical for TV D-pad grid/list navigation.
          child: FocusScope(
            node: _contentFocusScopeNode,
            child: _currentScreen,
          ),
        ),
      ],
    );
  }

  Widget _narrowLayout() {
    return Column(
      children: [
        Expanded(child: _currentScreen),
        _BottomNav(
          items: _navItems,
          selectedIndex: _selectedIndex,
          onTap: (i) => setState(() => _selectedIndex = i),
        ),
      ],
    );
  }
}

// ─── Side Navigation ─────────────────────────────────────────────────────────

class _SidebarNav extends StatelessWidget {
  final List<_NavItem> items;
  final int selectedIndex;
  final bool isFocused;
  final FocusNode focusNode;
  final ValueChanged<int> onTap;
  final VoidCallback onNavigateToContent;

  const _SidebarNav({
    required this.items,
    required this.selectedIndex,
    required this.isFocused,
    required this.focusNode,
    required this.onTap,
    required this.onNavigateToContent,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 72,
      decoration: const BoxDecoration(
        color: AppColors.bg2,
        border: Border(right: BorderSide(color: AppColors.border, width: 1)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 16),
          // App logo
          Image.asset(
            'assets/images/app_logo.png',
            width: 52,
            height: 52,
            filterQuality: FilterQuality.high,
          ),
          const SizedBox(height: 20),
          ...items.asMap().entries.map((e) {
            final i = e.key;
            final item = e.value;
            final isActive = selectedIndex == i;
            // Highlight the selected item with extra emphasis when sidebar has focus
            final isHighlighted = isActive && isFocused;
            return Tooltip(
              message: item.label,
              preferBelow: false,
              child: InkWell(
                onTap: () => onTap(i),
                borderRadius: BorderRadius.circular(10),
                focusColor: AppColors.accent.withValues(alpha: 0.2),
                hoverColor: AppColors.bg4,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: 46,
                  height: 46,
                  margin: const EdgeInsets.symmetric(vertical: 2),
                  decoration: BoxDecoration(
                    color: isActive
                        ? AppColors.bg4
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                    border: isHighlighted
                        ? Border.all(
                            color: AppColors.accent.withValues(alpha: 0.8),
                            width: 2)
                        : null,
                  ),
                  child: Stack(
                    children: [
                      Center(
                        child: Icon(
                          isActive ? item.activeIcon : item.icon,
                          color: isActive
                              ? AppColors.accent
                              : AppColors.textTertiary,
                          size: 22,
                        ),
                      ),
                      if (isActive)
                        Positioned(
                          left: 0,
                          top: 10,
                          bottom: 10,
                          child: Container(
                            width: 3,
                            decoration: BoxDecoration(
                              color: AppColors.accent,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          }).toList(),
        ],
      ),
    );
  }
}

// ─── Bottom Navigation ────────────────────────────────────────────────────────

class _BottomNav extends StatelessWidget {
  final List<_NavItem> items;
  final int selectedIndex;
  final ValueChanged<int> onTap;
  const _BottomNav(
      {required this.items,
      required this.selectedIndex,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    const bottomIndices = [0, 1, 2, 3, 7];
    final visibleItems = bottomIndices
        .where((i) => i < items.length)
        .map((i) => _BottomNavEntry(item: items[i], realIndex: i))
        .toList();
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.bg2,
        border: Border(top: BorderSide(color: AppColors.border, width: 1)),
      ),
      child: Row(
        children: visibleItems.map((entry) {
          final isActive = selectedIndex == entry.realIndex;
          return Expanded(
            child: Focus(
              autofocus: entry.realIndex == 0,
              onKeyEvent: (node, event) {
                if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
                  return KeyEventResult.ignored;
                }
                if (event.logicalKey == _kDpadCenter ||
                    event.logicalKey == _kEnter) {
                  onTap(entry.realIndex);
                  return KeyEventResult.handled;
                }
                // Left/Right navigate bottom bar
                if (event.logicalKey == _kDpadLeft) {
                  node.previousFocus();
                  return KeyEventResult.handled;
                }
                if (event.logicalKey == _kDpadRight) {
                  node.nextFocus();
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: Builder(
                builder: (focusCtx) {
                  final hasFocus = Focus.of(focusCtx).hasFocus;
                  return InkWell(
                    onTap: () => onTap(entry.realIndex),
                    focusColor: AppColors.accent.withValues(alpha: 0.15),
                    hoverColor: AppColors.bg4,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 100),
                      decoration: BoxDecoration(
                        border: hasFocus
                            ? const Border(
                                top: BorderSide(
                                    color: AppColors.accent, width: 2))
                            : null,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              isActive
                                  ? entry.item.activeIcon
                                  : entry.item.icon,
                              color: isActive || hasFocus
                                  ? AppColors.accent
                                  : AppColors.textTertiary,
                              size: 22,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              entry.item.label,
                              style: TextStyle(
                                fontSize: 10,
                                color: isActive || hasFocus
                                    ? AppColors.accent
                                    : AppColors.textTertiary,
                                fontWeight: isActive
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _NavItem {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  const _NavItem(
      {required this.icon, required this.activeIcon, required this.label});
}

class _BottomNavEntry {
  final _NavItem item;
  final int realIndex;
  const _BottomNavEntry({required this.item, required this.realIndex});
}
