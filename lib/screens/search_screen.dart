import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../core/focus/dpad_scroll_helper.dart';
import '../core/focus/tv_keys.dart';
import '../models/content_model.dart';
import '../services/app_state.dart';
import '../services/search_state.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';

class SearchScreen extends StatefulWidget {
  final bool sidebarFocused;
  const SearchScreen({super.key, this.sidebarFocused = true});
  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _ctrl = TextEditingController();

  // FIX #3 — the search input and the first result tile, so focus can be
  // handed between them explicitly rather than left to geometric traversal.
  //
  // Two nodes on purpose:
  //  • _searchFocus — the resting state. A plain (non-text) focusable, so its
  //    onKeyEvent is guaranteed to fire. When it was a readOnly TextField,
  //    EditableText re-attached the node and wiped our OK handler, so pressing
  //    OK on the bar a second time did nothing.
  //  • _editFocus — attached to the real TextField only while typing.
  final FocusNode _searchFocus = FocusNode(debugLabel: 'SearchInput');
  final FocusNode _editFocus = FocusNode(debugLabel: 'SearchEdit');
  final FocusNode _firstResultFocus = FocusNode(debugLabel: 'SearchFirstResult');
  final FocusNode _clearFocus = FocusNode(debugLabel: 'SearchClear');
  late final List<FocusNode> _tabNodes =
      List.generate(_tabs.length, (i) => FocusNode(debugLabel: 'SearchTab_$i'));
  // The popular-search chips had no nodes of their own, so DOWN from the
  // filter row had nowhere to go and they were unreachable by remote.
  late final List<FocusNode> _suggestionNodes = List.generate(
      _suggestions.length, (i) => FocusNode(debugLabel: 'SearchSuggestion_$i'));

  int get _activeTabIndex {
    final i = _tabs.indexOf(_tab);
    return i < 0 ? 0 : i;
  }

  /// Focus the filter row, landing on whichever filter is currently active.
  void _focusTabs() => _tabNodes[_activeTabIndex].requestFocus();

  // FIX #3 (item 4) — live search is debounced so a weak box does not rebuild
  // the whole grid on every keystroke.
  Timer? _debounce;
  static const _debounceDelay = Duration(milliseconds: 400);

  String _query = '';
  String _tab = 'All';
  final _tabs = ['All', 'Live TV', 'Movies', 'Series'];
  final _suggestions = [
    'Sports',
    'News',
    'Action',
    'Comedy',
    'Drama',
    'Kids',
    'Thriller',
    'HBO',
    'Documentary',
    'Sci-Fi',
  ];

  @override
  void initState() {
    super.initState();
    // FIX #3 (item 1) — repaint the input's focus ring as focus comes and goes.
    _searchFocus.addListener(_onSearchFocusChange);
    _editFocus.addListener(_onSearchFocusChange);

    // FIX #5 — restore the previous search. The text field is repopulated from
    // the provider so it reads exactly as the user left it, and the cached
    // results are reused rather than re-filtered.
    final saved = context.read<SearchState>();
    _query = saved.query;
    _tab = saved.activeFilter;
    _ctrl.text = saved.query;
  }

  void _onSearchFocusChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchFocus.removeListener(_onSearchFocusChange);
    _editFocus.removeListener(_onSearchFocusChange);
    _searchFocus.dispose();
    _editFocus.dispose();
    _firstResultFocus.dispose();
    _clearFocus.dispose();
    for (final n in _tabNodes) {
      n.dispose();
    }
    for (final n in _suggestionNodes) {
      n.dispose();
    }
    _ctrl.dispose();
    super.dispose();
  }

  // ── FIX #3 / #5: query handling ───────────────────────────────────────────
  /// Runs the filter once and stores the outcome in the app-scoped provider.
  /// Results are never recomputed during build, so returning to this screen
  /// renders straight from the cache.
  void _commit(String query, {String? filter}) {
    if (!mounted) return;
    final appState = context.read<AppState>();
    final searchState = context.read<SearchState>();
    final tab = filter ?? _tab;

    setState(() {
      _query = query;
      _tab = tab;
    });

    searchState.setSearch(
      query: query,
      activeFilter: tab,
      results: query.isEmpty ? const [] : _filter(appState, query, tab),
    );
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(_debounceDelay, () => _commit(value));
  }

  /// Runs the search immediately, closes the keyboard, and moves focus to the
  /// first result once it has rendered. With no results, focus stays in the
  /// input so the user can just keep typing.
  void _submit() {
    _debounce?.cancel();
    _commit(_ctrl.text);

    // Must go through _stopEditing, not just hide the IME: leaving _editing
    // true kept the field in typing mode, and _onSearchKey ignores every arrow
    // while typing — so after searching, the D-pad went dead.
    _stopEditing(); // FIX #3 (item 2)

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (context.read<SearchState>().results.isEmpty) {
        _searchFocus.requestFocus(); // FIX #3 (item 3)
        return;
      }
      _firstResultFocus.requestFocus();
      final ctx = _firstResultFocus.context;
      if (ctx != null) DpadScroll.ensureVisible(ctx);
    });
  }

  /// FIX #5 (item 3) — the only thing that wipes a search.
  void _clear() {
    _debounce?.cancel();
    _ctrl.clear();
    context.read<SearchState>().clear();
    setState(() => _query = '');
    _searchFocus.requestFocus();
  }

  /// Whether the on-screen keyboard is open for the search input.
  bool _editing = false;

  void _startEditing() {
    _searchFocus.unfocus();
    _editFocus.unfocus();
    setState(() => _editing = true);
    // Caret at the end so an existing query can be corrected, not overwritten.
    _ctrl.selection = TextSelection.collapsed(offset: _ctrl.text.length);
    // The TextField only exists after this frame; focus it then, which mounts
    // a fresh IME connection and pops the on-screen keyboard.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _editFocus.requestFocus();
      SystemChannels.textInput.invokeMethod('TextInput.show');
    });
  }

  void _stopEditing() {
    if (!_editing) return;
    setState(() => _editing = false);
    SystemChannels.textInput.invokeMethod('TextInput.hide');
    // Hand focus back to the resting (non-text) bar so OK can start editing
    // again.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  /// DOWN from the input goes to the first result. (UP from the first row
  /// comes back via ContentGrid's onExitTop.)
  KeyEventResult _onSearchKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;

    // While typing, the arrows belong to the keyboard / text cursor.
    if (_editing) {
      if (isBackKey(key)) {
        _stopEditing();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowLeft || key.keyId == 37 ||
          key == LogicalKeyboardKey.arrowRight || key.keyId == 39) {
        return KeyEventResult.handled; // Traversal block while in edit mode
      }
      return KeyEventResult.ignored;
    }

    if (isConfirmKey(key)) {
      _startEditing();
      return KeyEventResult.handled;
    }

    // Every direction is resolved explicitly. A focused EditableText consumes
    // arrow keys for caret movement, so the default traversal never fires from
    // here — that is why Clear and the filter chips were unreachable.
    if (key == LogicalKeyboardKey.arrowRight || key.keyId == 39) {
      if (_clearFocus.canRequestFocus && _query.isNotEmpty) {
        _clearFocus.requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.handled; // nothing to the right; don't fall through
    }
    if (key == LogicalKeyboardKey.arrowDown || key.keyId == 40) {
      _focusTabs();
      return KeyEventResult.handled;
    }
    // LEFT is left unhandled on purpose when not editing so the shell can return to the sidebar.
    return KeyEventResult.ignored;
  }

  /// Clear button: LEFT returns to the input, DOWN drops into the filters.
  KeyEventResult _onClearKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (isConfirmKey(key)) {
      _clear();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft || key.keyId == 37) {
      _searchFocus.requestFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown || key.keyId == 40) {
      _focusTabs();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Filter chips: LEFT/RIGHT between them, UP to the input, DOWN to results.
  KeyEventResult _onTabKey(FocusNode node, KeyEvent event, int index) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;

    if (isConfirmKey(key)) {
      _commit(_query, filter: _tabs[index]);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight || key.keyId == 39) {
      if (index < _tabs.length - 1) {
        _tabNodes[index + 1].requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.handled; // stop at the last chip
    }
    if (key == LogicalKeyboardKey.arrowLeft || key.keyId == 37) {
      if (index > 0) {
        _tabNodes[index - 1].requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored; // leftmost → let the shell take over
    }
    if (key == LogicalKeyboardKey.arrowUp || key.keyId == 38) {
      _searchFocus.requestFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown || key.keyId == 40) {
      if (_query.isNotEmpty) {
        _firstResultFocus.requestFocus();
      } else {
        // No query yet: the suggestion chips are what is on screen below.
        _suggestionNodes.first.requestFocus();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Popular-search chips: LEFT/RIGHT walks the list (crossing wrapped rows),
  /// UP returns to the filter chips, SELECT runs that search.
  KeyEventResult _onSuggestionKey(FocusNode node, KeyEvent event, int index) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;

    if (isConfirmKey(key)) {
      _ctrl.text = _suggestions[index];
      _commit(_suggestions[index]);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight || key.keyId == 39) {
      if (index < _suggestions.length - 1) {
        _suggestionNodes[index + 1].requestFocus();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft || key.keyId == 37) {
      if (index > 0) {
        _suggestionNodes[index - 1].requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored; // first chip → let the shell take over
    }
    if (key == LogicalKeyboardKey.arrowUp || key.keyId == 38) {
      _focusTabs();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown || key.keyId == 40) {
      return KeyEventResult.handled; // nothing below the chips
    }
    return KeyEventResult.ignored;
  }

  List<ContentItem> _filter(AppState appState, String query, String tab) {
    final q = query.toLowerCase();
    if (q.isEmpty) return [];
    List<ContentItem> pool;
    switch (tab) {
      case 'Live TV':
        pool = appState.channels;
        break;
      case 'Movies':
        pool = appState.sortedMovies;
        break;
      case 'Series':
        pool = appState.sortedSeries;
        break;
      default:
        pool = [
          ...appState.channels,
          ...appState.sortedMovies,
          ...appState.sortedSeries,
        ];
    }
    return pool
        .where((x) =>
            x.title.toLowerCase().contains(q) ||
            (x.genre ?? x.category ?? '').toLowerCase().contains(q) ||
            (x.description ?? '').toLowerCase().contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final searchState = context.watch<SearchState>();
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            // Search bar
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Row(
                children: [
                  if (Navigator.canPop(context))
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: IconButton(
                        icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ),
                  // FIX #3 (item 1) — a strong, unmistakable focused state:
                  // accent border plus a single soft glow. No blur.
                  Expanded(
                    child: Focus(
                      // The resting focus target. When NOT editing this holds a
                      // plain display row (no EditableText), so its onKeyEvent
                      // reliably fires and OK can (re)start editing. While the
                      // TextField is mounted it steps aside (_editFocus owns
                      // focus) but still handles bubbled keys like BACK.
                      focusNode: _searchFocus,
                      canRequestFocus: !_editing,
                      onKeyEvent: _onSearchKey,
                      child: Builder(builder: (ctx) {
                        final focused =
                            _searchFocus.hasFocus || _editFocus.hasFocus;
                        return AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          curve: Curves.easeOutCubic,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: focused ? AppColors.accent : AppColors.border,
                              width: focused ? 2.0 : 1.0,
                            ),
                            boxShadow: focused
                                ? [
                                    BoxShadow(
                                      color: AppColors.accent
                                          .withValues(alpha: _editing ? 0.40 : 0.30),
                                      blurRadius: _editing ? 14 : 10,
                                      spreadRadius: 1,
                                    )
                                  ]
                                : null,
                          ),
                          child: _editing
                              ? Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 4),
                                  child: Row(
                                    children: [
                                      const Icon(Icons.search,
                                          color: AppColors.accent, size: 20),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Focus(
                                          onKeyEvent: (node, event) {
                                            if (event is KeyDownEvent || event is KeyRepeatEvent) {
                                              final key = event.logicalKey;
                                              if (key == LogicalKeyboardKey.arrowLeft || key.keyId == 37 ||
                                                  key == LogicalKeyboardKey.arrowRight || key.keyId == 39) {
                                                return KeyEventResult.handled;
                                              }
                                              if (isBackKey(key)) {
                                                _stopEditing();
                                                return KeyEventResult.handled;
                                              }
                                            }
                                            return KeyEventResult.ignored;
                                          },
                                          child: TextField(
                                            controller: _ctrl,
                                            focusNode: _editFocus,
                                            showCursor: true,
                                            cursorColor: AppColors.accent,
                                            textInputAction: TextInputAction.search,
                                            style: const TextStyle(
                                                color: AppColors.textPrimary,
                                                fontFamily: 'Inter'),
                                            onChanged: _onQueryChanged,
                                            onSubmitted: (_) => _submit(),
                                            decoration: const InputDecoration(
                                              hintText:
                                                  'Search channels, movies, series...',
                                              hintStyle: TextStyle(
                                                  color: AppColors.textTertiary),
                                              border: InputBorder.none,
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 8, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: AppColors.accent
                                              .withValues(alpha: 0.15),
                                          borderRadius:
                                              BorderRadius.circular(6),
                                        ),
                                        child: const Text(
                                          'Press BACK when done',
                                          style: TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.w600,
                                            color: AppColors.accent,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                )
                              : GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: _startEditing,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 14),
                                    child: Row(
                                      children: [
                                        Icon(Icons.search,
                                            color: focused
                                                ? AppColors.accent
                                                : AppColors.textTertiary,
                                            size: 20),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            _ctrl.text.isEmpty
                                                ? 'Search channels, movies, series...'
                                                : _ctrl.text,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontFamily: 'Inter',
                                              color: _ctrl.text.isEmpty
                                                  ? AppColors.textTertiary
                                                  : AppColors.textPrimary,
                                            ),
                                          ),
                                        ),
                                        if (focused) ...[
                                          const SizedBox(width: 8),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 8, vertical: 4),
                                            decoration: BoxDecoration(
                                              color: AppColors.accent
                                                  .withValues(alpha: 0.15),
                                              borderRadius:
                                                  BorderRadius.circular(6),
                                            ),
                                            child: const Text(
                                              'Press OK to type',
                                              style: TextStyle(
                                                fontSize: 10,
                                                fontWeight: FontWeight.w600,
                                                color: AppColors.accent,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ),
                        );
                      }),
                    ),
                  ),

                  // FIX #5 (item 3) — a visible, focusable Clear control. The
                  // search now survives everything else, so there has to be an
                  // obvious way to end it.
                  if (searchState.hasQuery) ...[
                    const SizedBox(width: 8),
                    Focus(
                      focusNode: _clearFocus,
                      onKeyEvent: _onClearKey,
                      child: Builder(builder: (ctx) {
                        final focused = Focus.of(ctx).hasFocus;
                        return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _clear,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          curve: Curves.easeOutCubic,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                            color: focused
                                ? AppColors.accent.withValues(alpha: 0.22)
                                : AppColors.bg3,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color:
                                  focused ? AppColors.accent : AppColors.border,
                              width: focused ? 2.5 : 1,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.close,
                                  color: focused
                                      ? AppColors.accent
                                      : AppColors.textSecondary,
                                  size: 16),
                              const SizedBox(width: 6),
                              Text('Clear',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: focused
                                          ? AppColors.accent
                                          : AppColors.textSecondary)),
                            ],
                          ),
                        ),
                        );
                      }),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Type tabs
            SizedBox(
              height: 36,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: _tabs.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, i) {
                  final tab = _tabs[i];
                  final active = tab == _tab;
                  // Own focus node + explicit key handling, so the chips are
                  // reachable from the search input and from each other.
                  return Focus(
                    focusNode: _tabNodes[i],
                    onKeyEvent: (n, e) => _onTabKey(n, e, i),
                    onFocusChange: (f) {
                      if (f) DpadScroll.ensureVisible(_tabNodes[i].context!);
                    },
                    child: Builder(builder: (ctx) {
                      final focused = Focus.of(ctx).hasFocus;
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _commit(_query, filter: tab),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          curve: Curves.easeOutCubic,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 6),
                          decoration: BoxDecoration(
                            color: active
                                ? AppColors.accent
                                : (focused
                                    ? AppColors.accent.withValues(alpha: 0.20)
                                    : Colors.transparent),
                            borderRadius: BorderRadius.circular(8),
                            // Selected and focused are told apart: the active
                            // chip is filled, the focused one gets the ring.
                            border: Border.all(
                              color: focused
                                  ? Colors.white
                                  : (active
                                      ? AppColors.accent
                                      : AppColors.border),
                              width: focused ? 2.5 : 1,
                            ),
                          ),
                          child: Text(
                            tab,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: active || focused
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              color: active || focused
                                  ? Colors.white
                                  : AppColors.textTertiary,
                            ),
                          ),
                        ),
                      );
                    }),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),

            Expanded(
              child: searchState.hasQuery
                  ? _resultsView(searchState)
                  : _suggestionsView(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _suggestionsView() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Popular searches',
            style: TextStyle(fontSize: 13, color: AppColors.textTertiary),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: List.generate(_suggestions.length, (i) {
              final s = _suggestions[i];
              return Focus(
                focusNode: _suggestionNodes[i],
                onKeyEvent: (n, e) => _onSuggestionKey(n, e, i),
                onFocusChange: (f) {
                  final ctx = _suggestionNodes[i].context;
                  if (f && ctx != null) DpadScroll.ensureVisible(ctx);
                },
                child: Builder(builder: (ctx) {
                  final focused = Focus.of(ctx).hasFocus;
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      _ctrl.text = s;
                      _commit(s);
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOutCubic,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 7),
                      decoration: BoxDecoration(
                        color: focused
                            ? AppColors.accent.withValues(alpha: 0.25)
                            : AppColors.bg3,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: focused ? Colors.white : AppColors.border,
                          width: focused ? 2.5 : 1,
                        ),
                      ),
                      child: Text(s,
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight:
                                  focused ? FontWeight.w600 : FontWeight.w400,
                              color: focused
                                  ? Colors.white
                                  : AppColors.textSecondary)),
                    ),
                  );
                }),
              );
            }),
          ),
        ],
      ),
    );
  }

  Widget _resultsView(SearchState searchState) {
    // FIX #5 (item 5) — read straight from the cache, never re-filter here.
    final results = searchState.results;
    if (results.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.search_off,
                color: AppColors.textTertiary, size: 56),
            const SizedBox(height: 14),
            Text(
              'No results for "$_query"',
              style:
                  const TextStyle(color: AppColors.textTertiary, fontSize: 15),
            ),
            const SizedBox(height: 6),
            const Text(
              'Try a different keyword',
              style: TextStyle(color: AppColors.textTertiary, fontSize: 12),
            ),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // FIX #3 (item 6) — tell the user how many results they got.
        Padding(
          padding: const EdgeInsets.only(left: 16, bottom: 6),
          child: Text(
            results.length == 1 ? '1 result' : '${results.length} results',
            style: const TextStyle(
                color: AppColors.textTertiary, fontSize: 12),
          ),
        ),
        Expanded(
          child: ContentGrid(
            items: results,
            restorationKey: 'search', // FIX #7
            firstItemFocusNode: _firstResultFocus, // FIX #3 (item 2)
            // UP from the first row goes to the filters, which sit directly
            // above the grid — then UP again reaches the input.
            onExitTop: _focusTabs,
          ),
        ),
      ],
    );
  }
}
