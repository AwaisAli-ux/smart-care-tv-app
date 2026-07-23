// ============================================================
// FOCUS REGISTRY   (Phase 0.1)
// ============================================================
//
// An in-memory record of "where the user was" on each list screen:
// which item was focused and how far the list was scrolled.
//
// It is held by a singleton rather than by widget state because the whole
// point is to survive a Navigator push/pop — the list screen's State stays
// alive under the player route, but its focus does not, and a screen that is
// rebuilt (main_shell swaps screens on every tab change) loses everything.
//
// Entries are keyed per screen+list, e.g. 'movies', 'live_tv', 'favorites'.
// Memory only — nothing is written to disk here. Persisting across a process
// death is Fix #9's job, not this file's.
// ============================================================

/// Where the user was on one list screen.
class TvFocusMemory {
  const TvFocusMemory({
    required this.itemId,
    required this.itemIndex,
    required this.scrollOffset,
  });

  /// Preferred way to find the item again — survives the list being
  /// reordered or refreshed while the player was open.
  final String? itemId;

  /// Fallback when [itemId] is no longer present in the list.
  final int itemIndex;

  final double scrollOffset;
}

class TvFocusRegistry {
  TvFocusRegistry._();
  static final TvFocusRegistry instance = TvFocusRegistry._();

  final Map<String, TvFocusMemory> _entries = {};

  void save(
    String screenKey, {
    String? itemId,
    required int itemIndex,
    required double scrollOffset,
  }) {
    _entries[screenKey] = TvFocusMemory(
      itemId: itemId,
      itemIndex: itemIndex,
      scrollOffset: scrollOffset,
    );
  }

  TvFocusMemory? read(String screenKey) => _entries[screenKey];

  void clear(String screenKey) => _entries.remove(screenKey);

  /// Called on logout — nothing from the previous account should leak into
  /// the next one.
  void clearAll() => _entries.clear();

  /// Resolves a remembered position against the list as it exists *now*.
  ///
  /// Matches by id first so the restore still lands on the right tile if the
  /// list refreshed while the player was open; falls back to the raw index,
  /// clamped so a shrunken list cannot produce an out-of-range focus request.
  /// Returns null when the list is empty.
  int? resolveIndex(String screenKey, List<String?> currentIds) {
    final memory = _entries[screenKey];
    if (memory == null || currentIds.isEmpty) return null;

    final id = memory.itemId;
    if (id != null) {
      final byId = currentIds.indexOf(id);
      if (byId >= 0) return byId;
    }
    return memory.itemIndex.clamp(0, currentIds.length - 1);
  }
}
