import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/focus/tv_keys.dart';
import '../core/widgets/tv_safe_area.dart';
import 'package:flutter/foundation.dart';
import '../theme/app_theme.dart';
import '../utils/tv_remote_normalizer.dart';
import 'home_screen.dart';
import 'search_screen.dart';
import 'live_tv_screen.dart';
import 'movies_screen.dart';
import 'series_screen.dart';
import 'favorites_screen.dart';
import 'settings_screen.dart';
import 'more_screen.dart';

// TV remote D-pad / Media key codes.
// Confirm and back keys now come from core/focus/tv_keys.dart (Fix #1).
const _kDpadUp      = LogicalKeyboardKey.arrowUp;
const _kDpadDown    = LogicalKeyboardKey.arrowDown;
const _kDpadLeft    = LogicalKeyboardKey.arrowLeft;
const _kDpadRight   = LogicalKeyboardKey.arrowRight;
const _kMediaPlay   = LogicalKeyboardKey.mediaPlayPause;
const _kMediaStop   = LogicalKeyboardKey.mediaStop;
const _kMediaNext   = LogicalKeyboardKey.mediaTrackNext;
const _kMediaPrev   = LogicalKeyboardKey.mediaTrackPrevious;

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
        icon: Icons.tv_outlined, activeIcon: Icons.tv, label: 'Series'),
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

  // Bottom nav visible indices (0=Home,1=Search,2=LiveTV,3=Movies,4=Series,7=More)
  static const _bottomIndices = [0, 1, 2, 3, 4, 7];

  late final List<FocusNode> _sidebarFocusNodes;

  /// Which sidebar item the D-pad is currently ON — deliberately separate from
  /// _selectedIndex, which is the screen actually being shown.
  ///
  /// These used to be the same thing: arriving on an item immediately switched
  /// the screen, so running from Home to Settings built and tore down five
  /// screens on the way. Now moving only highlights; RIGHT or OK commits.
  int _sidebarFocusedIndex = 0;

  @override
  void initState() {
    super.initState();
    _sidebarFocusNodes = List.generate(_navItems.length, (index) => FocusNode(debugLabel: 'SidebarItem_$index'));
    for (int i = 0; i < _sidebarFocusNodes.length; i++) {
      _sidebarFocusNodes[i].addListener(() {
        if (_sidebarFocusNodes[i].hasFocus && _sidebarFocusedIndex != i) {
          setState(() => _sidebarFocusedIndex = i);
        }
      });
    }
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

  // FIX #1 — shared back-key definition, plus backspace which this screen
  // additionally treats as back when not typing.
  bool _isBackKey(LogicalKeyboardKey key) =>
      isBackKey(key) || key == LogicalKeyboardKey.backspace;

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
          // Enter/OK/Right on sidebar → commit the highlighted item and enter
          // the content area. This is the ONLY thing that changes the screen;
          // moving up/down the menu just highlights.
          if (isConfirmKey(key) || key == _kDpadRight || key.keyId == 39) {
            setState(() {
              _selectedIndex = _sidebarFocusedIndex;
              _sidebarFocused = false;
            });
            _contentFocusScopeNode.requestFocus();
            return true;
          }
          return false; // let sidebar's own FocusNode handle Up/Down
        } else {
          // TV NAV — Left arrow from content area → return to sidebar
          //
          // FIX #4: this handler must NOT move focus itself.
          //
          // It is registered on HardwareKeyboard, which sits outside the focus
          // tree. Returning true here only reports "handled" back to the
          // engine — it does not stop KeyEventManager from ALSO dispatching
          // the same event into the focus tree, where DirectionalFocusAction
          // moves focus a second time. The old code called
          // focusInDirection(left) here, so every LEFT press moved focus twice
          // while RIGHT (which fell through to `return false`) moved once.
          // That asymmetry is the "LEFT skips every other tile" bug.
          //
          // Now LEFT returns false exactly like RIGHT does, letting the
          // content own horizontal movement. The sidebar fallback still works:
          // we snapshot the focused node, let the frame resolve, and only jump
          // to the sidebar if nothing consumed the key.
          if (key == _kDpadLeft || key.keyId == 37) { // TV NAV
            final primaryFocus = FocusManager.instance.primaryFocus;
            final isTextField = primaryFocus?.context?.widget is EditableText ||
                                primaryFocus?.debugLabel?.contains('EditableText') == true;
            if (isTextField) return false;

            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted || _sidebarFocused) return;
              // Focus did not move → nothing to the left of us → sidebar.
              if (identical(FocusManager.instance.primaryFocus, primaryFocus)) {
                setState(() => _sidebarFocused = true); // TV NAV
                _sidebarFocusNodes[_selectedIndex].requestFocus(); // TV NAV
              }
            });
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
      // Note: _bottomIndices now = [0,1,2,3,4,7] where 4=Series and 7=More
    } catch (e) {
      debugPrint('[TV Remote] Key handler error: $e');
    }
    return false;
  }

  // Moving the D-pad up/down the menu calls setState (to slide the pill), and
  // that used to rebuild the whole content screen on every step. Favorites
  // builds all of its cards eagerly, so the menu stuttered there while the
  // lazy grids on the other tabs kept up. Handing back the *identical* widget
  // when neither the screen nor the sidebar/content split changed lets Flutter
  // skip that subtree entirely.
  Widget? _screenCache;
  int? _screenCacheIndex;
  bool? _screenCacheSidebarFocused;

  Widget get _currentScreen {
    if (_screenCache != null &&
        _screenCacheIndex == _selectedIndex &&
        _screenCacheSidebarFocused == _sidebarFocused) {
      return _screenCache!;
    }
    final screen = _buildScreen();
    _screenCache = screen;
    _screenCacheIndex = _selectedIndex;
    _screenCacheSidebarFocused = _sidebarFocused;
    return screen;
  }

  Widget _buildScreen() {
    switch (_selectedIndex) {
      case 0: return HomeScreen(sidebarFocused: _sidebarFocused);
      case 1: return SearchScreen(sidebarFocused: _sidebarFocused);
      case 2: return LiveTvScreen(sidebarFocused: _sidebarFocused);
      case 3: return MoviesScreen(sidebarFocused: _sidebarFocused);
      case 4: return SeriesScreen(sidebarFocused: _sidebarFocused);
      case 5: return FavoritesScreen(sidebarFocused: _sidebarFocused);
      case 6: return SettingsScreen(sidebarFocused: _sidebarFocused);
      case 7: return const MoreScreen();
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
    // FIX #12 — applied once here rather than per screen: this wraps the
    // sidebar AND the content area, so the side menu, the top row and the
    // bottom-most row of every tab all sit inside the overscan margin.
    return TvSafeArea(
      child: Row(
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
            focusedIndex: _sidebarFocusedIndex,
            isFocused: _sidebarFocused,
            focusNode: _sidebarFocusScope,
            sidebarFocusNodes: _sidebarFocusNodes,
            onTap: (i) {
              setState(() {
                _selectedIndex = i;
              });
              if (i >= 0 && i < _sidebarFocusNodes.length) {
                _sidebarFocusNodes[i].requestFocus();
              }
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
      ),
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

  /// Where the D-pad is, which is not necessarily what is on screen.
  final int focusedIndex;
  final bool isFocused;
  final FocusNode focusNode;
  final List<FocusNode> sidebarFocusNodes;
  final ValueChanged<int> onTap;
  final VoidCallback onNavigateToContent;

  const _SidebarNav({
    required this.items,
    required this.selectedIndex,
    required this.focusedIndex,
    required this.isFocused,
    required this.focusNode,
    required this.sidebarFocusNodes,
    required this.onTap,
    required this.onNavigateToContent,
  });

  // FIX #13 — fixed geometry so the sliding indicator can be positioned by
  // index arithmetic instead of measuring widgets every frame.
  static const double _itemHeight = 48;
  static const double _itemGap = 6;
  static const double _slot = _itemHeight + _itemGap;
  static const double _collapsedWidth = 72;
  static const double _expandedWidth = 200;

  static const Duration _fast = Duration(milliseconds: 200);
  static const Duration _slide = Duration(milliseconds: 220);
  static const Duration _expand = Duration(milliseconds: 250);
  static const Curve _curve = Curves.easeOutCubic;

  @override
  Widget build(BuildContext context) {
    // FIX #1 — the side menu is one logical traversal region with an explicit
    // order, instead of relying on the default reading-order policy.
    return FocusTraversalGroup(
      policy: OrderedTraversalPolicy(),
      // FIX #13 (item 4) — the rail expands when the menu has focus and
      // collapses back to icons when focus moves into the content area.
      child: AnimatedContainer(
        duration: _expand,
        curve: _curve,
        width: isFocused ? _expandedWidth : _collapsedWidth,
        decoration: const BoxDecoration(
          color: AppColors.bg2,
          border: Border(right: BorderSide(color: AppColors.border, width: 1)),
        ),
        child: ClipRect(
          child: Column(
            children: [
              const SizedBox(height: 16),
              Image.asset(
                'assets/images/app_logo.png',
                width: 52,
                height: 52,
                filterQuality: FilterQuality.high,
              ),
              const SizedBox(height: 20),
              Expanded(
                child: Stack(
                  children: [
                    // FIX #13 (item 1) — ONE pill that slides between items,
                    // instead of every item toggling its own background.
                    AnimatedPositioned(
                      duration: _slide,
                      curve: _curve,
                      // Follows the D-pad while the menu has focus; parks on
                      // the active screen when focus is in the content area.
                      top: (isFocused ? focusedIndex : selectedIndex) * _slot,
                      left: 8,
                      right: 8,
                      height: _itemHeight,
                      child: AnimatedContainer(
                        duration: _fast,
                        curve: _curve,
                        decoration: BoxDecoration(
                          color: AppColors.accent
                              .withValues(alpha: isFocused ? 0.25 : 0.10),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: isFocused
                                ? AppColors.accent
                                : AppColors.accent.withValues(alpha: 0.35),
                            width: isFocused ? 2.5 : 1.5,
                          ),
                          // Single soft shadow, and only while focused.
                          boxShadow: isFocused
                              ? [
                                  BoxShadow(
                                    color: AppColors.accent
                                        .withValues(alpha: 0.30),
                                    blurRadius: 14,
                                    spreadRadius: 1,
                                  ),
                                ]
                              : null,
                        ),
                      ),
                    ),
                    Column(
                      children: List.generate(items.length, (i) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: _itemGap),
                          child: _item(i),
                        );
                      }),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _item(int i) {
    final item = items[i];
    final isActive = selectedIndex == i;

    return FocusTraversalOrder(
      // FIX #1 — explicit menu order.
      order: NumericFocusOrder(i.toDouble()),
      child: Tooltip(
        message: item.label,
        preferBelow: false,
        child: Focus(
          focusNode: sidebarFocusNodes[i],
          // No onFocusChange handler on purpose. It used to call onTap(i),
          // so simply moving the D-pad past an item loaded that whole screen —
          // going Home → Settings built and destroyed five screens on the way,
          // which is painfully slow on a low-end box.
          onKeyEvent: (node, event) {
            if (event is! KeyDownEvent) return KeyEventResult.ignored;
            final key = event.logicalKey;
            // OK or RIGHT is what commits the highlighted item and enters it.
            if (isConfirmKey(key) ||
                key == LogicalKeyboardKey.arrowRight ||
                key.keyId == 39) {
              onTap(i);
              onNavigateToContent();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Builder(builder: (ctx) {
            final hasFocus = Focus.of(ctx).hasFocus;
            // FIX #13 (item 3) — fake depth: perspective + a small rotateY
            // plus scale. Transform only; no blur, no shader.
            final matrix = Matrix4.identity()
              ..setEntry(3, 2, 0.0012)
              ..rotateY(hasFocus ? 0.04 : 0.0)
              ..scaleByDouble(
                hasFocus ? 1.06 : 1.0,
                hasFocus ? 1.06 : 1.0,
                1.0,
                1.0,
              );

            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onTap(i),
              child: AnimatedContainer(
                duration: _fast,
                curve: _curve,
                transform: matrix,
                transformAlignment: Alignment.centerLeft,
                height: _itemHeight,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: 46,
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
                          // FIX #13 (item 6) — the persistent "you are here"
                          // marker, deliberately different from the sliding
                          // focus pill so the two can be told apart.
                          if (isActive)
                            Positioned(
                              left: 0,
                              top: 12,
                              bottom: 12,
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
                    // FIX #13 (item 2) — labels fade in only once the menu
                    // itself has focus; the collapsed rail is icons only.
                    Expanded(
                      child: AnimatedOpacity(
                        duration: _fast,
                        curve: _curve,
                        opacity: isFocused ? 1.0 : 0.0,
                        child: Text(
                          item.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight:
                                isActive ? FontWeight.w600 : FontWeight.w400,
                            color: (isActive || hasFocus)
                                ? AppColors.accent
                                : AppColors.textSecondary,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
        ),
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
    const bottomIndices = [0, 1, 2, 3, 4, 7];
    final visibleItems = bottomIndices
        .where((i) => i < items.length)
        .map((i) => _BottomNavEntry(item: items[i], realIndex: i))
        .toList();
    // FIX #13 (item 7) — one indicator that slides to the active tab, rather
    // than each tab drawing its own top border. Kept light: an AnimatedAlign
    // and a colour/scale tween, no blur and no ripple.
    final activePos = visibleItems.indexWhere((e) => e.realIndex == selectedIndex);
    final slots = visibleItems.length;

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.bg2,
        border: Border(top: BorderSide(color: AppColors.border, width: 1)),
      ),
      child: Stack(
        children: [
          if (activePos >= 0 && slots > 1)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: 3,
              child: AnimatedAlign(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                // -1..1 across the bar, one step per slot.
                alignment: Alignment(-1 + 2 * activePos / (slots - 1), 0),
                child: FractionallySizedBox(
                  widthFactor: 1 / slots,
                  child: Container(
                    decoration: BoxDecoration(
                      color: AppColors.accent,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            ),
          Row(
        children: visibleItems.map((entry) {
          final isActive = selectedIndex == entry.realIndex;
          return Expanded(
            child: Focus(
              autofocus: entry.realIndex == 0,
              onKeyEvent: (node, event) {
                if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
                  return KeyEventResult.ignored;
                }
                final k2 = event.logicalKey;
                if (isConfirmKey(k2)) { // FIX #1
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
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOutCubic,
                      decoration: BoxDecoration(
                        // The sliding indicator marks the active tab; this
                        // only has to show where focus is.
                        color: hasFocus
                            ? AppColors.accent.withValues(alpha: 0.12)
                            : Colors.transparent,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // FIX #13 (item 7) — icon scales up on the active
                            // tab, 200ms, matching the indicator slide.
                            AnimatedScale(
                              scale: isActive ? 1.15 : 1.0,
                              duration: const Duration(milliseconds: 200),
                              curve: Curves.easeOutCubic,
                              child: Icon(
                                isActive
                                    ? entry.item.activeIcon
                                    : entry.item.icon,
                                color: isActive || hasFocus
                                    ? AppColors.accent
                                    : AppColors.textTertiary,
                                size: 22,
                              ),
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
        ],
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
    // Left arrow or Shift+Tab → move to Cancel button
    if (k == LogicalKeyboardKey.arrowLeft) {
      _cancelFocus.requestFocus();
      return KeyEventResult.handled;
    }
    // Enter / Select / D-pad Center → activate focused button
    // Extended to cover ALL worldwide TV remote OK/Enter variants.
    if (k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter ||
        k == LogicalKeyboardKey.gameButtonA ||
        k.keyId == 13 ||   // HID Enter
        k.keyId == 23 ||   // DPAD_CENTER raw (Amlogic, Rockchip, Mi Box)
        k.keyId == 66 ||   // KEYCODE_ENTER raw (TCL, Hisense OEM)
        k.keyId == 96 ||   // BUTTON_A (Rockchip)
        k.keyId == 107 ||  // BUTTON_START (Panasonic, Philips EU)
        k.keyId == 160 ||  // NUMPAD_ENTER (USB remotes)
        k.keyId == 0x10000017 ||   // D-pad Center logical key ID (32-bit)
        k.keyId == 0x100000017 ||  // D-pad Center logical key ID (64-bit)
        k.keyId == 0x1100000017 || // Alternative D-pad Center logical key ID
        k.keyId == 0x100000042 ||  // Standard Enter logical key ID (64-bit)
        k.keyId == 0x10000042) {  // Standard Enter logical key ID (32-bit)
      if (_focusedBtn == 1) {
        Navigator.pop(context, true);  // Exit
      } else {
        Navigator.pop(context, false); // Cancel
      }
      return KeyEventResult.handled;
    }
    // Back / Escape → cancel
    if (k == LogicalKeyboardKey.goBack ||
        k == LogicalKeyboardKey.escape ||
        k.keyId == 0x1000000a6 || k.keyId == 166 || k.keyId == 8) {
      Navigator.pop(context, false);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
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
