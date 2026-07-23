import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/content_model.dart';
import 'iptv_service.dart';
import 'device_profile_service.dart';

// ── Top-level so compute() can invoke it on a background isolate ───────────
// Must be top-level (not a class method) for Flutter's compute() to work.
List<ContentItem> _buildFeaturedChannelListIsolate(List<ContentItem> raw) {
  const brandKeywords = [
    'cnn', 'bbc', 'espn', 'animal planet', 'fox news', 'al jazeera',
    'sky news', 'bloomberg', 'discovery', 'national geographic', 'nat geo',
    'cnbc', 'msnbc', 'eurosport', 'sky sports', 'fox sports', 'nfl network',
    'nba tv', 'beinsport', 'bein sport', 'mtv', 'vh1', 'cartoon network',
    'disney channel', 'nickelodeon', 'hbo', 'showtime', 'history', 'tlc',
    'dazn', 'nbc', 'abc news', 'cbs',
  ];

  bool isEmptyOrBlank(ContentItem item) {
    final title = item.title.trim();
    final img = item.imageUrl.trim();
    return title.isEmpty || img.isEmpty || img == 'null';
  }

  final nonEmptyRaw = raw.where((ch) => !isEmptyOrBlank(ch)).toList();
  final emptyRaw = raw.where(isEmptyOrBlank).toList();

  final used = <String>{};
  final featured = <ContentItem>[];
  final remaining = <ContentItem>[];
  for (final brand in brandKeywords) {
    for (final ch in nonEmptyRaw) {
      if (used.contains(ch.id)) continue;
      if (ch.title.toLowerCase().contains(brand)) {
        featured.add(ch);
        used.add(ch.id);
        break;
      }
    }
  }
  for (final ch in nonEmptyRaw) {
    if (!used.contains(ch.id)) remaining.add(ch);
  }
  return [...featured, ...remaining, ...emptyRaw];
}

class SortedContentResult {
  final List<ContentItem> sortedMovies;
  final List<ContentItem> sortedSeries;
  final List<ContentItem> englishMovies;
  final List<ContentItem> englishSeries;

  SortedContentResult({
    required this.sortedMovies,
    required this.sortedSeries,
    required this.englishMovies,
    required this.englishSeries,
  });
}

SortedContentResult _processAndSortContentIsolate(Map<String, dynamic> params) {
  final rawMovies = params['movies'] as List<ContentItem>;
  final rawSeries = params['series'] as List<ContentItem>;

  // --- Reject Lists (expanded) ---
  const reject = [
    'hindi', 'bollywood', 'tamil', 'telugu', 'malayalam', 'kannada',
    'marathi', 'gujarati', 'punjabi', 'bengali', 'urdu', 'south asian',
    'desi', 'zee', 'star bharat', 'sony liv', 'hotstar', 'alt balaji',
    'mx player', 'discovery jeet', 'india', 'pakistan',
    'arabic', 'arab', 'عربي', 'مسلسل', 'افلام', 'مصري',
    'khaliji', 'gulf', 'lebanese', 'lebanon', 'egyptian', 'egypt', 'syrian', 'syria', 'iraqi', 'iraq',
    'saudi', 'emirati', 'emirates', 'kuwaiti', 'kuwait', 'jordanian', 'jordan', 'moroccan', 'morocco',
    'tunisian', 'tunisia', 'algerian', 'algeria', 'libyan', 'libya', 'yemeni', 'yemen', 'omani', 'oman',
    'qatari', 'qatar', 'bahraini', 'bahrain', 'ramadan', 'khaleej', 'pan arab',
    'turkish', 'türk', 'turkey', 'persian', 'farsi', 'iranian',
    'kurdish', 'pashto', 'dari',
    'french', 'spanish', 'portuguese', 'german', 'italian',
    'russian', 'chinese', 'korean', 'japanese', 'thai',
  ];

  bool isEnglish(ContentItem item) {
    final cat = (item.category ?? '').toLowerCase();
    final gen = (item.genre ?? '').toLowerCase();
    final title = item.title.toLowerCase();

    for (final kw in reject) {
      if (cat.contains(kw) || gen.contains(kw) || title.contains(kw)) {
        return false;
      }
    }
    // Reject titles containing Arabic/RTL script characters
    if (RegExp(r'[\u0600-\u06FF\u0750-\u077F\u08A0-\u08FF]').hasMatch(item.title)) {
      return false;
    }
    return true;
  }

  bool isEmptyOrBlank(ContentItem item) {
    final title = item.title.trim();
    final img = item.imageUrl.trim();
    return title.isEmpty || img.isEmpty || img == 'null';
  }

  // 1. Process Movies Screen List
  final nonEmptyMovies = rawMovies.where((m) => !isEmptyOrBlank(m)).toList();
  final emptyMovies = rawMovies.where(isEmptyOrBlank).toList();

  final engMovies = nonEmptyMovies.where(isEnglish).toList();
  final nonEngMovies = nonEmptyMovies.where((m) => !isEnglish(m)).toList();
  engMovies.sort((a, b) => (b.year ?? 0).compareTo(a.year ?? 0));
  nonEngMovies.sort((a, b) => (b.year ?? 0).compareTo(a.year ?? 0));

  final engEmptyMovies = emptyMovies.where(isEnglish).toList();
  final nonEngEmptyMovies = emptyMovies.where((m) => !isEnglish(m)).toList();
  engEmptyMovies.sort((a, b) => (b.year ?? 0).compareTo(a.year ?? 0));
  nonEngEmptyMovies.sort((a, b) => (b.year ?? 0).compareTo(a.year ?? 0));

  final sortedMovies = [...engMovies, ...nonEngMovies, ...engEmptyMovies, ...nonEngEmptyMovies];
  final finalEnglishMovies = [...engMovies, ...engEmptyMovies];

  // 2. Process Series Screen List
  final nonEmptySeries = rawSeries.where((s) => !isEmptyOrBlank(s)).toList();
  final emptySeries = rawSeries.where(isEmptyOrBlank).toList();

  final engSeries = nonEmptySeries.where(isEnglish).toList();
  final nonEngSeries = nonEmptySeries.where((s) => !isEnglish(s)).toList();
  engSeries.sort((a, b) => (b.year ?? 0).compareTo(a.year ?? 0));
  nonEngSeries.sort((a, b) => (b.year ?? 0).compareTo(a.year ?? 0));

  final engEmptySeries = emptySeries.where(isEnglish).toList();
  final nonEngEmptySeries = emptySeries.where((s) => !isEnglish(s)).toList();
  engEmptySeries.sort((a, b) => (b.year ?? 0).compareTo(a.year ?? 0));
  nonEngEmptySeries.sort((a, b) => (b.year ?? 0).compareTo(a.year ?? 0));

  final sortedSeries = [...engSeries, ...nonEngSeries, ...engEmptySeries, ...nonEngEmptySeries];
  final finalEnglishSeries = [...engSeries, ...engEmptySeries];

  return SortedContentResult(
    sortedMovies: sortedMovies,
    sortedSeries: sortedSeries,
    englishMovies: finalEnglishMovies,
    englishSeries: finalEnglishSeries,
  );
}



class AppState extends ChangeNotifier {
  Set<String> _favoriteIds = {};
  /// Full ContentItem data for favorites — persisted so they show even
  /// before the server content finishes loading on app restart.
  List<ContentItem> _favoritesCache = [];

  bool _isLoggedIn = false;
  String _username = '';
  String _password = '';
  String _serverUrl = '';
  int _selectedNavIndex = 0;

  List<ContentItem> _channels = [];
  List<ContentItem> _movies = [];
  List<ContentItem> _series = [];

  List<ContentItem> _sortedMovies = [];
  List<ContentItem> _sortedSeries = [];
  List<ContentItem> _englishMovies = [];
  List<ContentItem> _englishSeries = [];

  bool _isContentLoading = false;
  bool _sortingScheduled = false;
  String? _contentError;

  // ── Player Settings ─────────────────────────────────────────────────────
  // Default: hardware acceleration ON for smooth hardware decoding across all TV devices.
  // mpv auto-safe mode automatically falls back to software decoding if needed.
  bool _hardwareAccelEnabled = true;
  String _bufferSize = 'medium'; // 'small' | 'medium' | 'large'
  String _selectedQuality = 'Auto (Recommended)';

  // ── Device Profile ───────────────────────────────────────────────────────
  DeviceProfile? _deviceProfile;
  DeviceProfile? get deviceProfile => _deviceProfile;

  void setDeviceProfile(DeviceProfile profile) {
    _deviceProfile = profile;
    notifyListeners();
    debugPrint('[AppState] DeviceProfile set: $profile');
  }

  // ── Getters ─────────────────────────────────────────────────────────────
  bool get isLoggedIn => _isLoggedIn;
  String get username => _username;
  String get password => _password;
  String get serverUrl => _serverUrl;
  int get selectedNavIndex => _selectedNavIndex;

  List<ContentItem> get channels => _channels;
  List<ContentItem> get movies => _movies;
  List<ContentItem> get series => _series;

  List<ContentItem> get sortedMovies => _sortedMovies;
  List<ContentItem> get sortedSeries => _sortedSeries;
  List<ContentItem> get englishMovies => _englishMovies;
  List<ContentItem> get englishSeries => _englishSeries;

  bool get isContentLoading => _isContentLoading;
  String? get contentError => _contentError;
  bool get hasContent =>
      _channels.isNotEmpty || _movies.isNotEmpty;

  List<ContentItem> get favorites {
    // Merge live data with cached favorites so items show even before
    // channels/movies/series finish loading from the server.
    final liveIds = {
      ..._channels.map((c) => c.id),
      ..._movies.map((m) => m.id),
      ..._series.map((s) => s.id),
    };
    final live = [
      ..._channels.where((c) => _favoriteIds.contains(c.id)),
      ..._movies.where((m) => _favoriteIds.contains(m.id)),
      ..._series.where((s) => _favoriteIds.contains(s.id)),
    ];
    // Add cached items that haven't loaded from server yet
    final cached = _favoritesCache
        .where((f) => _favoriteIds.contains(f.id) && !liveIds.contains(f.id))
        .toList();
    return [...live, ...cached];
  }

  List<ContentItem> get favoriteChannels {
    final live = _channels.where((c) => _favoriteIds.contains(c.id)).toList();
    final cached = _favoritesCache
        .where((f) => f.isLive && _favoriteIds.contains(f.id) && !_channels.any((c) => c.id == f.id))
        .toList();
    return [...live, ...cached];
  }

  List<ContentItem> get favoriteMovies {
    final live = _movies.where((m) => _favoriteIds.contains(m.id)).toList();
    final cached = _favoritesCache
        .where((f) => f.isMovie && _favoriteIds.contains(f.id) && !_movies.any((m) => m.id == f.id))
        .toList();
    return [...live, ...cached];
  }

  List<ContentItem> get favoriteSeries {
    final live = _series.where((s) => _favoriteIds.contains(s.id)).toList();
    final cached = _favoritesCache
        .where((f) => f.isSeries && _favoriteIds.contains(f.id) && !_series.any((s) => s.id == f.id))
        .toList();
    return [...live, ...cached];
  }

  bool isFavorite(String id) => _favoriteIds.contains(id);

  // Player settings getters
  bool get hardwareAccelEnabled => _hardwareAccelEnabled;
  String get bufferSize => _bufferSize;
  String get selectedQuality => _selectedQuality;

  /// Active quality tier — derived from the Settings quality selection string.
  QualityTier get qualityTier =>
      DeviceProfileService.qualityTierFromSetting(_selectedQuality);

  /// Returns buffer size in bytes for use in PlayerConfiguration.
  /// If a DeviceProfile is available and the device has insufficient RAM for
  /// the user-selected buffer size, the RAM-safe value takes priority.
  int get bufferBytes {
    // Static value from user's Settings selection
    final userBytes = _staticBufferBytes;
    // RAM-safe value from detected hardware
    final deviceBytes = _deviceProfile?.optimalBufferBytes;
    // Use the smaller of the two — protect low-RAM devices from OOM
    if (deviceBytes != null && deviceBytes < userBytes) return deviceBytes;
    return userBytes;
  }

  /// User-selected buffer bytes (ignoring RAM constraints).
  int get _staticBufferBytes {
    switch (_bufferSize) {
      case 'small':  return 32  * 1024 * 1024;  // 32 MB
      case 'large':  return 128 * 1024 * 1024;  // 128 MB
      case 'medium':
      default:       return 64  * 1024 * 1024;  // 64 MB
    }
  }

  // ── Player Settings Persistence ─────────────────────────────────────────
  Future<void> loadPlayerSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Key is versioned (_v2): earlier builds defaulted this OFF and could
      // have persisted `false`, which survives an app update and would keep
      // forcing slow software decoding even after the default was flipped to
      // ON. Reading a fresh key guarantees the ON default actually applies.
      _hardwareAccelEnabled = prefs.getBool('player_hw_accel_v2') ?? true;
      _bufferSize = prefs.getString('player_buffer_size') ?? 'medium';
      _selectedQuality = prefs.getString('player_quality') ?? 'Auto (Recommended)';
      debugPrint('[PlayerSettings] hwAccel=$_hardwareAccelEnabled bufferSize=$_bufferSize quality=$_selectedQuality');
      notifyListeners();
    } catch (e) {
      debugPrint('[PlayerSettings] Failed to load: $e');
    }
  }

  Future<void> _savePlayerSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('player_hw_accel_v2', _hardwareAccelEnabled);
      await prefs.setString('player_buffer_size', _bufferSize);
      await prefs.setString('player_quality', _selectedQuality);
    } catch (e) {
      debugPrint('[PlayerSettings] Failed to save: $e');
    }
  }

  void setHardwareAccel(bool enabled) {
    _hardwareAccelEnabled = enabled;
    notifyListeners();
    _savePlayerSettings();
  }

  void setBufferSize(String size) {
    assert(size == 'small' || size == 'medium' || size == 'large');
    _bufferSize = size;
    notifyListeners();
    _savePlayerSettings();
  }

  void setSelectedQuality(String quality) {
    _selectedQuality = quality;
    notifyListeners();
    _savePlayerSettings();
  }

  // ── Favorites key — scoped per username so each account has its own list ──
  String _favKey(String username) =>
      username.isNotEmpty ? 'favorites_$username' : 'favorites_guest';
  String _favItemsKey(String username) =>
      username.isNotEmpty ? 'fav_items_$username' : 'fav_items_guest';

  // ── Favorites ───────────────────────────────────────────────────────────
  void toggleFavorite(ContentItem item) {
    if (_favoriteIds.contains(item.id)) {
      _favoriteIds.remove(item.id);
      _favoritesCache.removeWhere((f) => f.id == item.id);
    } else {
      _favoriteIds.add(item.id);
      // Update or add to cache
      _favoritesCache.removeWhere((f) => f.id == item.id);
      _favoritesCache.add(item);
    }
    notifyListeners();
    _persistFavorites();
  }

  Future<void> _persistFavorites() async {
    final keyUser = _username.isNotEmpty ? _username : null;
    if (keyUser == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      // Persist IDs
      await prefs.setStringList(_favKey(keyUser), _favoriteIds.toList());
      // Persist full item data as JSON
      final itemsJson = _favoritesCache.map((item) => jsonEncode({
        'id': item.id,
        'type': item.type.index,
        'title': item.title,
        'description': item.description,
        'imageUrl': item.imageUrl,
        'backdropUrl': item.backdropUrl,
        'genre': item.genre,
        'category': item.category,
        'year': item.year,
        'rating': item.rating,
        'duration': item.duration,
        'channelNumber': item.channelNumber,
        'nowPlaying': item.nowPlaying,
        'nextUp': item.nextUp,
        'videoUrl': item.videoUrl,
        'containerExtension': item.containerExtension,
      })).toList();
      await prefs.setStringList(_favItemsKey(keyUser), itemsJson);
      debugPrint('[Favorites] Saved ${_favoriteIds.length} items for "$keyUser"');
    } catch (e) {
      debugPrint('Failed to persist favorites: $e');
    }
  }

  /// Loads favorites for the given username (or _username if not provided).
  Future<void> loadFavorites({String? username}) async {
    final targetUser = username ?? _username;
    try {
      final prefs = await SharedPreferences.getInstance();
      final ids = prefs.getStringList(_favKey(targetUser)) ?? [];
      _favoriteIds = ids.toSet();
      // Restore full item cache
      final itemsJson = prefs.getStringList(_favItemsKey(targetUser)) ?? [];
      _favoritesCache = itemsJson.map((json) {
        try {
          final m = jsonDecode(json) as Map<String, dynamic>;
          return ContentItem(
            id: m['id'] as String,
            type: ContentType.values[m['type'] as int],
            title: m['title'] as String,
            description: m['description'] as String?,
            imageUrl: m['imageUrl'] as String? ?? '',
            backdropUrl: m['backdropUrl'] as String?,
            genre: m['genre'] as String?,
            category: m['category'] as String?,
            year: m['year'] as int?,
            rating: (m['rating'] as num?)?.toDouble(),
            duration: m['duration'] as String?,
            channelNumber: m['channelNumber'] as int?,
            nowPlaying: m['nowPlaying'] as String?,
            nextUp: m['nextUp'] as String?,
            videoUrl: m['videoUrl'] as String?,
            containerExtension: m['containerExtension'] as String?,
          );
        } catch (_) {
          return null;
        }
      }).whereType<ContentItem>().toList();
      debugPrint('[Favorites] Loaded ${_favoriteIds.length} ids, ${_favoritesCache.length} cached items for "$targetUser"');
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

  void setServerUrl(String url) {
    _serverUrl = url;
    IptvService.setBaseUrl(url);
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

  /// Sets all content — channel sorting runs on a background isolate
  /// via compute() to avoid UI jank with large channel lists (1000+ items).
  Future<void> setContent(
      List<ContentItem> channels,
      List<ContentItem> movies,
      List<ContentItem> series) async {
    final entered = DateTime.now();
    debugPrint('[AppState] setContent() ENTER @$entered channels=${channels.length} '
        'movies=${movies.length} series=${series.length}');
    // Sort channels on a background isolate — O(brands × channels) can be
    // slow on large IPTV providers (5000+ channels) and would stutter the UI.
    _channels = await compute(_buildFeaturedChannelListIsolate, channels);
    _movies = movies;
    _series = series;

    // Process and sort movies and series on a background isolate
    final sortedResult = await compute(_processAndSortContentIsolate, {
      'movies': movies,
      'series': series,
    });
    _sortedMovies = sortedResult.sortedMovies;
    _sortedSeries = sortedResult.sortedSeries;
    _englishMovies = sortedResult.englishMovies;
    _englishSeries = sortedResult.englishSeries;

    _isContentLoading = false;
    _contentError = null;
    debugPrint('[AppState] setContent() notifyListeners() @${DateTime.now()} — took '
        '${DateTime.now().difference(entered).inMilliseconds}ms total');
    notifyListeners();
    debugPrint('[AppState] setContent() EXIT @${DateTime.now()}');
  }

  /// Updates channels only — sorting runs on a background isolate.
  Future<void> setChannels(List<ContentItem> channels) async {
    _channels = await compute(_buildFeaturedChannelListIsolate, channels);
    notifyListeners();
  }

  void setMovies(List<ContentItem> movies) {
    _movies = movies;
    _updateSortedContent();
  }

  void setSeries(List<ContentItem> series) {
    _series = series;
    _updateSortedContent();
  }

  Future<void> _updateSortedContent() async {
    if (_movies.isEmpty && _series.isEmpty) return;
    if (_sortingScheduled) return;
    _sortingScheduled = true;

    // Debounce to group movies and series updates when loaded in parallel
    await Future.delayed(const Duration(milliseconds: 50));
    _sortingScheduled = false;

    final entered = DateTime.now();
    debugPrint('[AppState] _updateSortedContent() ENTER @$entered');
    final sortedResult = await compute(_processAndSortContentIsolate, {
      'movies': _movies,
      'series': _series,
    });
    _sortedMovies = sortedResult.sortedMovies;
    _sortedSeries = sortedResult.sortedSeries;
    _englishMovies = sortedResult.englishMovies;
    _englishSeries = sortedResult.englishSeries;
    debugPrint('[AppState] _updateSortedContent() notifyListeners() — took '
        '${DateTime.now().difference(entered).inMilliseconds}ms');
    notifyListeners();
  }

  // ── Content refresh ─────────────────────────────────────────────────────
  bool _isRefreshing = false;
  bool get isRefreshing => _isRefreshing;

  /// Re-fetches ALL content (channels, movies, series) from the server using
  /// the currently stored credentials. Call from the Device > Refresh Content button.
  Future<void> refreshContent() async {
    if (_isRefreshing || !_isLoggedIn || _username.isEmpty) return;
    _isRefreshing = true;
    _isContentLoading = true;
    _contentError = null;
    notifyListeners();
    debugPrint('[AppState] refreshContent() — reloading all content for $_username');
    try {
      // Reset category cache so fresh categories are fetched too
      IptvService.resetCache();

      final results = await Future.wait([
        IptvService.getLiveChannels(_username, _password),
        IptvService.getMovies(_username, _password),
        IptvService.getSeries(_username, _password),
      ]);
      await setContent(results[0], results[1], results[2]);
      debugPrint('[AppState] refreshContent() ✅ '
          '${results[0].length} channels, ${results[1].length} movies, ${results[2].length} series');
    } catch (e) {
      debugPrint('[AppState] refreshContent() ❌ $e');
      setContentError('Refresh failed: $e');
    } finally {
      _isRefreshing = false;
      notifyListeners();
    }
  }

  void logout() {
    _isLoggedIn = false;
    _username = '';
    _password = '';
    _serverUrl = '';
    _channels = [];
    _movies = [];
    _series = [];
    _favoriteIds = {};
    _favoritesCache = []; // clear in-memory only — disk copy stays for re-login
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

}
// The featured-channel sorting logic lives at the top of this file
// as _buildFeaturedChannelListIsolate() so compute() can call it.
