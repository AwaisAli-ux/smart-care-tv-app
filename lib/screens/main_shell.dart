import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import '../theme/app_theme.dart';
import '../utils/tv_remote_normalizer.dart';
import 'home_screen.dart';
import 'search_screen.dart';
import 'live_tv_screen.dart';
import 'movies_screen.dart';

import 'favorites_screen.dart';
import 'settings_screen.dart';
import 'more_screen.dart';


class MainShell extends StatefulWidget {
  const MainShell({super.key});
  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _selectedIndex = 0;

  // Whether focus is currently on the sidebar (true) or the content area (false)
  bool _sidebarFocused = true;

  // ── Double-back-press exit ─────────────────────────────────────
  // Track last time back was pressed; require two presses within 2 seconds.
  DateTime? _lastBackPress;

  // Cached screen-width flag, updated in build() — used by the key handler
  // so it doesn't need to call MediaQuery from a non-build context.
  bool _isWide = true;

  // Focus nodes for the two logical zones
  final FocusScopeNode _sidebarFocusScope = FocusScopeNode(debugLabel: 'SidebarScope');
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

  // Bottom nav visible indices (0=Home,1=Search,2=LiveTV,3=Movies,6=More)
  static const _bottomIndices = [0, 1, 2, 3, 6];

  late final List<FocusNode> _sidebarFocusNodes;

  @override
  void initState() {
    super.initState();
    _sidebarFocusNodes = List.generate(_navItems.length, (index) => FocusNode(debugLabel: 'SidebarItem_$index'));
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
    // TV NAV — give sidebar first focus so remote works from frame 1
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _sidebarFocused = true; // TV NAV
        _sidebarFocusNodes[_selectedIndex].requestFocus(); // TV NAV
      }
    });
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    for (final node in _sidebarFocusNodes) {
      node.dispose();
    }
    _sidebarFocusScope.dispose();
    _contentFocusScopeNode.dispose();
    super.dispose();
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (!mounted) return false;
    try {
      final route = ModalRoute.of(context);
      if (route != null && !route.isCurrent) return false;
    } catch (_) {}

    final action = TvRemoteNormalizer.normalize(event);
    if (action == TvNavAction.none) return false;

    if (kDebugMode) {
      debugPrint('[TV Remote] action=$action  sidebarFocused=$_sidebarFocused  isWide=$_isWide');
    }

    final isWide = _isWide;

    try {
      // Media keys — always pass through so player screens handle them.
      if (action == TvNavAction.play    ||
          action == TvNavAction.pause   ||
          action == TvNavAction.playPause ||
          action == TvNavAction.mediaStop ||
          action == TvNavAction.mediaNext ||
          action == TvNavAction.mediaPrev) {
        return false;
      }

      // Volume — let the system handle it (most Android TVs do this natively).
      if (action == TvNavAction.volumeUp   ||
          action == TvNavAction.volumeDown ||
          action == TvNavAction.mute) {
        return false;
      }

      // Back from content → return focus to sidebar.
      if (isWide && !_sidebarFocused && action == TvNavAction.back) {
        // If a text field has focus, backspace should erase text, not navigate.
        final primaryFocus = FocusManager.instance.primaryFocus;
        final ctx = primaryFocus?.context;
        final isTextField = ctx != null &&
            (ctx.findAncestorWidgetOfExactType<EditableText>() != null ||
             ctx.findAncestorWidgetOfExactType<TextField>() != null);
        final isBackspace = event.logicalKey == LogicalKeyboardKey.backspace ||
            event.logicalKey.keyId == 8;
        if (isTextField && isBackspace) return false;

        setState(() => _sidebarFocused = true);
        _sidebarFocusNodes[_selectedIndex].requestFocus();
        return true;
      }

      if (isWide) {
        if (_sidebarFocused) {
          // Select or Right on sidebar → move focus into content area.
          if (action == TvNavAction.select || action == TvNavAction.right) {
            setState(() => _sidebarFocused = false);
            _contentFocusScopeNode.requestFocus();
            return true;
          }
          return false; // let sidebar's own FocusNode handle Up/Down
        } else {
          // Left from content area → try spatial traversal, then fall back to sidebar.
          if (action == TvNavAction.left) {
            final primaryFocus = FocusManager.instance.primaryFocus;
            final isTextField =
                primaryFocus?.context?.widget is EditableText ||
                primaryFocus?.debugLabel?.contains('EditableText') == true;
            if (!isTextField) {
              final moved =
                  primaryFocus?.focusInDirection(TraversalDirection.left) ?? false;
              if (!moved) {
                setState(() => _sidebarFocused = true);
                _sidebarFocusNodes[_selectedIndex].requestFocus();
              }
              return true;
            }
            return false;
          }
          return false; // spatial traversal handles Up/Down/Right in content
        }
      } else {
        // Narrow (phone/mobile): D-pad cycles through bottom-bar tabs.
        final pos = _bottomIndices.indexOf(_selectedIndex);
        if ((action == TvNavAction.left || action == TvNavAction.up) && pos > 0) {
          setState(() => _selectedIndex = _bottomIndices[pos - 1]);
          return true;
        }
        if ((action == TvNavAction.right || action == TvNavAction.down) &&
            pos >= 0 && pos < _bottomIndices.length - 1) {
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
      case 0: return HomeScreen(sidebarFocused: _sidebarFocused);
      case 1: return SearchScreen(sidebarFocused: _sidebarFocused);
      case 2: return LiveTvScreen(sidebarFocused: _sidebarFocused);
      case 3: return MoviesScreen(sidebarFocused: _sidebarFocused);
      case 4: return FavoritesScreen(sidebarFocused: _sidebarFocused);
      case 5: return SettingsScreen(sidebarFocused: _sidebarFocused);
      case 6: return const MoreScreen();
      default: return HomeScreen(sidebarFocused: _sidebarFocused);
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

        // ── Double-back-press guard ─────────────────────────────
        final now = DateTime.now();
        final lastPress = _lastBackPress;
        if (lastPress == null ||
            now.difference(lastPress) > const Duration(seconds: 2)) {
          // First press — show hint snackbar, DO NOT exit
          _lastBackPress = now;
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Press back again to exit'),
                duration: Duration(seconds: 2),
                backgroundColor: Colors.black87,
              ),
            );
          }
          return;
        }

        // Second press within 2 s → show exit dialog
        _lastBackPress = null;
        final shouldExit = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => const _ExitDialog(),
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
        FocusScope(
          node: _sidebarFocusScope,
          onFocusChange: (value) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                final hasFocus = _sidebarFocusScope.hasFocus;
                if (hasFocus != _sidebarFocused) {
                  setState(() => _sidebarFocused = hasFocus);
                }
              }
            });
          },
          child: _SidebarNav(
            items: _navItems,
            selectedIndex: _selectedIndex,
            isFocused: _sidebarFocused,
            focusNode: _sidebarFocusScope,
            sidebarFocusNodes: _sidebarFocusNodes,
            onTap: (i) {
              setState(() {
                _selectedIndex = i;
              });
            },
            onNavigateToContent: () {
              setState(() => _sidebarFocused = false);
              _contentFocusScopeNode.requestFocus();
            },
          ),
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
  final List<FocusNode> sidebarFocusNodes;
  final ValueChanged<int> onTap;
  final VoidCallback onNavigateToContent;

  const _SidebarNav({
    required this.items,
    required this.selectedIndex,
    required this.isFocused,
    required this.focusNode,
    required this.sidebarFocusNodes,
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
            return Tooltip(
              message: item.label,
              preferBelow: false,
              child: Focus(
                focusNode: sidebarFocusNodes[i],
                onFocusChange: (focused) {
                  // TV NAV — only change screen when this item gains *primary* focus
                  // (i.e. actual D-pad arrival), not on ancestor scope focus events.
                  if (focused) {
                    // Use a microtask so the focus tree settles before calling onTap
                    Future.microtask(() => onTap(i)); // TV NAV
                  }
                },
                onKeyEvent: (node, event) {
                  final action = TvRemoteNormalizer.normalize(event);
                  if (action == TvNavAction.select || action == TvNavAction.right) {
                    onNavigateToContent();
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: Builder(
                  builder: (ctx) {
                    final hasFocus = Focus.of(ctx).hasFocus;
                    return InkWell(
                      onTap: () => onTap(i),
                      borderRadius: BorderRadius.circular(10),
                      focusColor: AppColors.accent.withValues(alpha: 0.2),
                      hoverColor: AppColors.bg4,
                      child: AnimatedScale(
                        scale: hasFocus ? 1.12 : 1.0,
                        duration: const Duration(milliseconds: 150),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          width: 46,
                          height: 46,
                          margin: const EdgeInsets.symmetric(vertical: 2),
                          decoration: BoxDecoration(
                            color: hasFocus
                                ? AppColors.accent.withValues(alpha: 0.25)
                                : (isActive ? AppColors.bg4 : Colors.transparent),
                            borderRadius: BorderRadius.circular(10),
                            border: hasFocus
                                ? Border.all(
                                    color: AppColors.accent,
                                    width: 2.5)
                                : (isActive
                                    ? Border.all(
                                        color: AppColors.accent.withValues(alpha: 0.4),
                                        width: 1.5)
                                    : null),
                          ),
                          child: Stack(
                            children: [
                              Center(
                                child: Icon(
                                  isActive ? item.activeIcon : item.icon,
                                  color: (isActive || hasFocus)
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
                  }
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
    const bottomIndices = [0, 1, 2, 3, 6];
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
                final action = TvRemoteNormalizer.normalize(event);
                if (action == TvNavAction.select) {
                  onTap(entry.realIndex);
                  return KeyEventResult.handled;
                }
                if (action == TvNavAction.left) {
                  node.previousFocus();
                  return KeyEventResult.handled;
                }
                if (action == TvNavAction.right) {
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

// ─── Exit Confirmation Dialog ─────────────────────────────────────────────────
// Custom stateful dialog so we can track which button has focus and apply
// a solid bright-orange highlight to it while dimming the other button.
class _ExitDialog extends StatefulWidget {
  const _ExitDialog();
  @override
  State<_ExitDialog> createState() => _ExitDialogState();
}

class _ExitDialogState extends State<_ExitDialog> {
  // 0 = Cancel focused, 1 = Exit focused
  int _focusedBtn = 0;
  final FocusNode _cancelFocus = FocusNode(debugLabel: 'ExitDlg_Cancel');
  final FocusNode _exitFocus   = FocusNode(debugLabel: 'ExitDlg_Exit');

  @override
  void initState() {
    super.initState();
    _cancelFocus.addListener(_onFocusChange);
    _exitFocus.addListener(_onFocusChange);
    // Default focus: Cancel (safe default so user doesn't accidentally exit)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _cancelFocus.requestFocus();

      // Fallback delays to guarantee focus grabs during route transitions
      Future.delayed(const Duration(milliseconds: 100), () {
        if (mounted && !_cancelFocus.hasFocus && !_exitFocus.hasFocus) {
          _cancelFocus.requestFocus();
        }
      });
      Future.delayed(const Duration(milliseconds: 300), () {
        if (mounted && !_cancelFocus.hasFocus && !_exitFocus.hasFocus) {
          _cancelFocus.requestFocus();
        }
      });
    });
  }

  void _onFocusChange() {
    if (!mounted) return;
    setState(() {
      if (_exitFocus.hasFocus) {
        _focusedBtn = 1;
      } else {
        _focusedBtn = 0;
      }
    });
  }

  @override
  void dispose() {
    _cancelFocus.removeListener(_onFocusChange);
    _exitFocus.removeListener(_onFocusChange);
    _cancelFocus.dispose();
    _exitFocus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final action = TvRemoteNormalizer.normalize(event);
    switch (action) {
      case TvNavAction.right:
        // Tab key also moves right — handle it separately since normalizer
        // doesn't include Tab (Tab is a focus-traversal key, not a D-pad key).
        _exitFocus.requestFocus();
        return KeyEventResult.handled;
      case TvNavAction.left:
        _cancelFocus.requestFocus();
        return KeyEventResult.handled;
      case TvNavAction.select:
        if (_focusedBtn == 1) {
          Navigator.pop(context, true);
        } else {
          Navigator.pop(context, false);
        }
        return KeyEventResult.handled;
      case TvNavAction.back:
        Navigator.pop(context, false);
        return KeyEventResult.handled;
      default:
        // Also handle Tab (not a TvNavAction) for keyboard users.
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.tab) {
          _exitFocus.requestFocus();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
    }
  }

  Widget _buildBtn({
    required String label,
    required bool isFocused,
    required FocusNode focusNode,
    required VoidCallback onPressed,
    bool autofocus = false,
  }) {
    return Focus(
      focusNode: focusNode,
      autofocus: autofocus,
      onKeyEvent: _onKey,
      child: GestureDetector(
        onTap: onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
          decoration: BoxDecoration(
            // Focused button: solid bright orange fill
            // Unfocused button: dim dark background with subtle border
            color: isFocused
                ? AppColors.accent
                : AppColors.bg.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isFocused ? AppColors.accent : Colors.white24,
              width: isFocused ? 2 : 1,
            ),
            boxShadow: isFocused
                ? [
                    BoxShadow(
                      color: AppColors.accent.withValues(alpha: 0.5),
                      blurRadius: 14,
                      spreadRadius: 2,
                    ),
                  ]
                : null,
          ),
          child: Text(
            label,
            style: TextStyle(
              color: isFocused ? Colors.white : Colors.white38,
              fontSize: 15,
              fontWeight: isFocused ? FontWeight.w700 : FontWeight.w400,
              letterSpacing: 0.3,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FocusScope(
      autofocus: true,
      child: Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: Container(
          width: 360,
          padding: const EdgeInsets.fromLTRB(28, 28, 28, 24),
          decoration: BoxDecoration(
            color: AppColors.bg2,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.white12, width: 1),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.6),
                blurRadius: 40,
                spreadRadius: 8,
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Title row
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.accent.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.exit_to_app,
                        color: AppColors.accent, size: 22),
                  ),
                  const SizedBox(width: 12),
                  const Text(
                    'Exit App',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Text(
                'Are you sure you want to exit Smart Care TV?',
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 14,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 28),
              // Buttons row
              Row(
                children: [
                  Expanded(
                    child: _buildBtn(
                      label: 'Cancel',
                      isFocused: _focusedBtn == 0,
                      focusNode: _cancelFocus,
                      autofocus: true,
                      onPressed: () => Navigator.pop(context, false),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildBtn(
                      label: 'Exit',
                      isFocused: _focusedBtn == 1,
                      focusNode: _exitFocus,
                      onPressed: () => Navigator.pop(context, true),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
