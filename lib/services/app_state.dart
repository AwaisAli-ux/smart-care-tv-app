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
  final used = <String>{};
  final featured = <ContentItem>[];
  final remaining = <ContentItem>[];
  for (final brand in brandKeywords) {
    for (final ch in raw) {
      if (used.contains(ch.id)) continue;
      if (ch.title.toLowerCase().contains(brand)) {
        featured.add(ch);
        used.add(ch.id);
        break;
      }
    }
  }
  for (final ch in raw) {
    if (!used.contains(ch.id)) remaining.add(ch);
  }
  return [...featured, ...remaining];
}



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

  // ── Player Settings ─────────────────────────────────────────────────────
  // Default: hardware acceleration OFF for universal TV compatibility.
  // Software decoding works correctly on ALL chipsets (Amlogic, MediaTek,
  // Qualcomm, Tegra) — hardware decoding causes scrambled video on many boxes.
  bool _hardwareAccelEnabled = false;
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
  int get selectedNavIndex => _selectedNavIndex;

  List<ContentItem> get channels => _channels;
  List<ContentItem> get movies => _movies;
  List<ContentItem> get series => _series;

  bool get isContentLoading => _isContentLoading;
  String? get contentError => _contentError;
  bool get hasContent =>
      _channels.isNotEmpty || _movies.isNotEmpty;

  List<ContentItem> get favorites => [
        ..._channels.where((c) => _favoriteIds.contains(c.id)),
        ..._movies.where((m) => _favoriteIds.contains(m.id)),
      ];

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
      _hardwareAccelEnabled = prefs.getBool('player_hw_accel') ?? false;
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
      await prefs.setBool('player_hw_accel', _hardwareAccelEnabled);
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

  /// Sets all content — channel sorting runs on a background isolate
  /// via compute() to avoid UI jank with large channel lists (1000+ items).
  Future<void> setContent(
      List<ContentItem> channels,
      List<ContentItem> movies,
      List<ContentItem> series) async {
    // Sort channels on a background isolate — O(brands × channels) can be
    // slow on large IPTV providers (5000+ channels) and would stutter the UI.
    _channels = await compute(_buildFeaturedChannelListIsolate, channels);
    _movies = movies;
    _series = series;
    _isContentLoading = false;
    _contentError = null;
    notifyListeners();
  }

  /// Updates channels only — sorting runs on a background isolate.
  Future<void> setChannels(List<ContentItem> channels) async {
    _channels = await compute(_buildFeaturedChannelListIsolate, channels);
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

}
// The featured-channel sorting logic lives at the top of this file
// as _buildFeaturedChannelListIsolate() so compute() can call it.
