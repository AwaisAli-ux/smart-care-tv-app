import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/content_model.dart';

/// These brand keywords define "featured" channels.
/// Each brand gets ONE representative at the front, interleaved randomly.
const _kFeaturedBrands = [
  'cnn',
  'bbc',
  'espn',
  'animal planet',
  'fox news',
  'al jazeera',
  'sky news',
  'bloomberg',
  'discovery',
  'national geographic',
  'nat geo',
  'cnbc',
  'msnbc',
  'eurosport',
  'sky sports',
  'fox sports',
  'nfl network',
  'nba tv',
  'beinsport',
  'bein sport',
  'mtv',
  'vh1',
  'cartoon network',
  'disney channel',
  'nickelodeon',
  'hbo',
  'showtime',
  'history',
  'tlc',
  'dazn',
  'nbc',
  'abc news',
  'cbs',
];

class AppState extends ChangeNotifier {
  Set<String> _favoriteIds = {};

  bool _isLoggedIn = false;
  String _username = '';
  String _password = '';
  int _selectedNavIndex = 0;

  List<ContentItem> _channels = [];
  List<ContentItem> _movies = [];
  List<ContentItem> _series = [];

  bool _isContentLoading = false;
  String? _contentError;

  // ── Getters ─────────────────────────────────────────────────────────────
  bool get isLoggedIn => _isLoggedIn;
  String get username => _username;
  String get password => _password;
  int get selectedNavIndex => _selectedNavIndex;

  List<ContentItem> get channels => _channels;
  List<ContentItem> get movies => _movies;
  List<ContentItem> get series => _series;

  bool get isContentLoading => _isContentLoading;
  String? get contentError => _contentError;
  bool get hasContent =>
      _channels.isNotEmpty || _movies.isNotEmpty || _series.isNotEmpty;

  List<ContentItem> get favorites => [
        ..._channels.where((c) => _favoriteIds.contains(c.id)),
        ..._movies.where((m) => _favoriteIds.contains(m.id)),
        ..._series.where((s) => _favoriteIds.contains(s.id)),
      ];

  bool isFavorite(String id) => _favoriteIds.contains(id);

  // ── Favorites key — scoped per username so each account has its own list ──
  String _favKey(String username) =>
      username.isNotEmpty ? 'favorites_$username' : 'favorites_guest';

  // ── Favorites ───────────────────────────────────────────────────────────
  void toggleFavorite(ContentItem item) {
    if (_favoriteIds.contains(item.id)) {
      _favoriteIds.remove(item.id);
    } else {
      _favoriteIds.add(item.id);
    }
    notifyListeners();
    _persistFavorites();
  }

  Future<void> _persistFavorites() async {
    // Guard: never write to guest key if a real user is logged in.
    // This prevents accidental data loss if _persistFavorites is somehow
    // called during a login/logout transition.
    final keyUser = _username.isNotEmpty ? _username : null;
    if (keyUser == null) return; // nothing to persist for guest
    try {
      final prefs = await SharedPreferences.getInstance();
      // Store under the per-user key so favorites survive app restart
      await prefs.setStringList(_favKey(keyUser), _favoriteIds.toList());
      debugPrint('[Favorites] Saved ${_favoriteIds.length} items for "$keyUser"');
    } catch (e) {
      debugPrint('Failed to persist favorites: $e');
    }
  }

  /// Loads favorites for the given username (or _username if not provided).
  /// Always pass [username] explicitly to avoid race conditions where
  /// _username might not yet be set when this is called.
  Future<void> loadFavorites({String? username}) async {
    final targetUser = username ?? _username;
    try {
      final prefs = await SharedPreferences.getInstance();
      final ids = prefs.getStringList(_favKey(targetUser)) ?? [];
      _favoriteIds = ids.toSet();
      debugPrint('[Favorites] Loaded ${_favoriteIds.length} items for "$targetUser"');
      notifyListeners();
    } catch (e) {
      debugPrint('Failed to load favorites: $e');
    }
  }

  // ── Auth ────────────────────────────────────────────────────────────────
  void login(String username, String password) {
    _isLoggedIn = true;
    _username = username;
    _password = password;
    notifyListeners();
  }

  /// Convenience: login then immediately restore favorites from disk.
  /// Returns a Future so the caller can await before navigating.
  Future<void> loginAndRestoreFavorites(String username, String password) async {
    login(username, password);
    await loadFavorites(username: username);
  }

  // ── Content management ─────────────────────────────────────────────────
  void setContentLoading(bool loading) {
    _isContentLoading = loading;
    if (loading) _contentError = null;
    notifyListeners();
  }

  void setContentError(String error) {
    _contentError = error;
    _isContentLoading = false;
    notifyListeners();
  }

  void setContent(
      List<ContentItem> channels,
      List<ContentItem> movies,
      List<ContentItem> series) {
    _channels = _buildFeaturedChannelList(channels);
    _movies = movies;
    _series = series;
    _isContentLoading = false;
    _contentError = null;
    notifyListeners();
  }

  void setChannels(List<ContentItem> channels) {
    _channels = _buildFeaturedChannelList(channels);
    notifyListeners();
  }

  void setMovies(List<ContentItem> movies) {
    _movies = movies;
    notifyListeners();
  }

  void setSeries(List<ContentItem> series) {
    _series = series;
    notifyListeners();
  }

  void logout() {
    _isLoggedIn = false;
    _username = '';
    _password = '';
    _channels = [];
    _movies = [];
    _series = [];
    _favoriteIds = {}; // clear in-memory only — disk copy stays for re-login
    _isContentLoading = false;
    _contentError = null;
    notifyListeners();
  }

  /// Permanently removes this user's favorites from disk and memory.
  /// Call ONLY on explicit user action (e.g. "Delete account" or "Clear data").
  /// Do NOT call on normal sign-out — favourites should restore on re-login.
  void clearFavorites() {
    _favoriteIds.clear();
    _persistFavorites();
    notifyListeners();
  }

  void setNavIndex(int index) {
    _selectedNavIndex = index;
    notifyListeners();
  }

  // ── Channel ordering: diversified featured list ──────────────────────────
  /// Builds a channel list where:
  ///  - ONE representative of each famous brand (CNN, BBC, ESPN, etc.) is
  ///    picked first and placed at the front in a mixed/interleaved order.
  ///  - All remaining channels follow after.
  ///
  /// This ensures variety: the user sees CNN, then BBC, then ESPN, then
  /// Animal Planet — NOT all CNN channels grouped together first.
  static List<ContentItem> _buildFeaturedChannelList(List<ContentItem> raw) {
    final used = <String>{};      // IDs already placed in the featured section
    final featured = <ContentItem>[];
    final remaining = <ContentItem>[];

    // For each brand keyword, find ONE matching channel not yet selected
    for (final brand in _kFeaturedBrands) {
      for (final ch in raw) {
        if (used.contains(ch.id)) continue;
        if (ch.title.toLowerCase().contains(brand)) {
          featured.add(ch);
          used.add(ch.id);
          break; // only ONE per brand keyword
        }
      }
    }

    // All channels not in the featured list go to remaining
    for (final ch in raw) {
      if (!used.contains(ch.id)) remaining.add(ch);
    }

    return [...featured, ...remaining];
  }
}
