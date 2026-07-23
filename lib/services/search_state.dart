// ============================================================
// SEARCH STATE   (Fix #5)
// ============================================================
//
// Search used to live entirely inside SearchScreen's State. main_shell builds
// the current screen from a switch, so every tab change destroyed that State
// and the user's query, results, scroll position and focus went with it.
//
// This holds the same data one level above the navigator, so switching to
// Movies and back leaves the search exactly as it was — and, critically,
// without re-running the query against the full channel + movie + series list.
//
// It is cleared only by an explicit Clear press or by logging out.
// ============================================================

import 'package:flutter/foundation.dart';
import '../models/content_model.dart';

class SearchState extends ChangeNotifier {
  String _query = '';
  String _activeFilter = 'All';
  List<ContentItem> _results = const [];
  double _scrollOffset = 0;
  int _focusedIndex = 0;

  String get query => _query;
  String get activeFilter => _activeFilter;
  List<ContentItem> get results => _results;
  double get scrollOffset => _scrollOffset;
  int get focusedIndex => _focusedIndex;

  bool get hasQuery => _query.isNotEmpty;

  /// Stores a completed search. [results] is kept as-is so returning to the
  /// screen can render instantly instead of re-filtering.
  void setSearch({
    required String query,
    required List<ContentItem> results,
    String? activeFilter,
  }) {
    _query = query;
    _results = results;
    if (activeFilter != null) _activeFilter = activeFilter;
    notifyListeners();
  }

  void setFilter(String filter) {
    if (_activeFilter == filter) return;
    _activeFilter = filter;
    notifyListeners();
  }

  /// Position updates are deliberately silent — they happen on every focus
  /// move, and rebuilding the grid on each one would defeat the point.
  void setPosition({double? scrollOffset, int? focusedIndex}) {
    if (scrollOffset != null) _scrollOffset = scrollOffset;
    if (focusedIndex != null) _focusedIndex = focusedIndex;
  }

  /// The only way a search goes away, other than [clearOnLogout].
  void clear() {
    _query = '';
    _results = const [];
    _scrollOffset = 0;
    _focusedIndex = 0;
    notifyListeners();
  }

  void clearOnLogout() {
    _activeFilter = 'All';
    clear();
  }
}
