import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/content_model.dart';
import 'device_profile_service.dart';

// ── Top-level helpers for compute() (must be top-level) ──────────────────
List<dynamic> _parseJsonList(String body) {
  try {
    final decoded = json.decode(body);
    if (decoded is List) return decoded;
    if (decoded is Map && decoded.isEmpty) return [];
    if (decoded is Map) {
      for (final value in decoded.values) {
        if (value is List) return value;
      }
      return decoded.values.toList();
    }
  } catch (e) {
    debugPrint('[JSON Parser] Error decoding: $e');
  }
  return [];
}

Map<String, dynamic> _parseJsonMap(String body) {
  try {
    final decoded = json.decode(body);
    if (decoded is Map<String, dynamic>) return decoded;
  } catch (_) {}
  return {};
}

/// Parses the raw VOD JSON AND maps it straight to [ContentItem]s, all on
/// the background isolate compute() spins up. Previously only the JSON
/// decode ran in compute() and the .map().toList() into ContentItem objects
/// (100k+ items on large catalogues) ran synchronously back on the main
/// isolate right as the app starts — real, non-trivial CPU work landing on
/// the same merged UI/platform thread Android needs to ack window-focus
/// events on, contributing to "Waited Xms for FocusEvent" ANRs if a channel
/// tap lands while this is still running.
List<ContentItem> _parseAndMapMovies(Map<String, dynamic> args) {
  final body = args['body'] as String;
  final cats = args['cats'] as Map<String, String>;
  final data = _parseJsonList(body);
  return data
      .where((item) =>
          item is Map &&
          item['stream_id'] != null &&
          item['stream_id'].toString().isNotEmpty)
      .map<ContentItem>((item) {
    final catId = item['category_id']?.toString() ?? '';
    final catName = cats[catId] ?? catId;
    final ext =
        (item['container_extension']?.toString() ?? 'mp4').toLowerCase();
    final title = item['name']?.toString() ?? 'Unknown';

    int? parsedYear;
    final match = RegExp(r'\((\d{4})\)').firstMatch(title);
    if (match != null) {
      parsedYear = int.tryParse(match.group(1)!);
    }
    if (parsedYear == null) {
      final match2 = RegExp(r'\b(19\d{2}|20\d{2})\b').firstMatch(title);
      if (match2 != null) {
        parsedYear = int.tryParse(match2.group(1)!);
      }
    }
    parsedYear ??=
        IptvService._parseYear(item['year'] ?? item['releaseDate'] ?? item['added']);

    return ContentItem(
      id: item['stream_id']?.toString() ?? '',
      type: ContentType.movie,
      title: title,
      imageUrl: item['stream_icon']?.toString() ?? '',
      category: catName,
      genre: IptvService._cleanGenre(catName),
      rating: IptvService._parseRating(item['rating']),
      year: parsedYear,
      description: item['plot']?.toString(),
      duration: item['duration']?.toString(),
      containerExtension: ext.isEmpty ? 'mp4' : ext,
    );
  }).toList();
}

/// Same rationale as [_parseAndMapMovies] — parses AND maps series JSON
/// entirely on the background isolate instead of leaving the .map().toList()
/// into ContentItem objects to run on the main isolate.
List<ContentItem> _parseAndMapSeries(Map<String, dynamic> args) {
  final body = args['body'] as String;
  final cats = args['cats'] as Map<String, String>;
  final data = _parseJsonList(body);
  return data
      .where((item) =>
          item is Map &&
          item['series_id'] != null &&
          item['series_id'].toString().isNotEmpty)
      .map<ContentItem>((item) {
    final catId = item['category_id']?.toString() ?? '';
    final catName = cats[catId] ?? catId;
    final episodeCount = item['num'] is int
        ? item['num'] as int
        : int.tryParse(item['num']?.toString() ?? '');
    final title = item['name']?.toString() ?? 'Unknown';
    int? parsedYear;
    final match = RegExp(r'\((\d{4})\)').firstMatch(title);
    if (match != null) {
      parsedYear = int.tryParse(match.group(1)!);
    }
    if (parsedYear == null) {
      final match2 = RegExp(r'\b(19\d{2}|20\d{2})\b').firstMatch(title);
      if (match2 != null) {
        parsedYear = int.tryParse(match2.group(1)!);
      }
    }
    parsedYear ??= IptvService._parseYear(
        item['releaseDate'] ?? item['last_modified'] ?? item['year']);

    return ContentItem(
      id: item['series_id']?.toString() ?? '',
      type: ContentType.series,
      title: title,
      imageUrl: item['cover']?.toString() ?? '',
      backdropUrl: item['backdrop_path'] is List &&
              (item['backdrop_path'] as List).isNotEmpty
          ? item['backdrop_path'][0]?.toString()
          : null,
      category: catName,
      genre: IptvService._cleanGenre(catName),
      rating: IptvService._parseRating(item['rating']),
      year: parsedYear,
      description: item['plot']?.toString(),
      episodeCount: episodeCount,
    );
  }).toList();
}

class IptvService {
  /// Runtime-configurable server URL. Starts empty — must be set via
  /// setBaseUrl() from the user's login input before any API calls are made.
  static String baseUrl = '';

  /// Update the base URL (call before authenticate() when the user provides a
  /// custom server). Trailing slashes are stripped for consistency.
  static void setBaseUrl(String url) {
    String sanitized = url.trim();
    if (!sanitized.startsWith('http://') && !sanitized.startsWith('https://')) {
      sanitized = 'http://$sanitized';
    }
    baseUrl = sanitized.replaceAll(RegExp(r'/+$'), '');
    debugPrint('[IptvService] baseUrl updated → $baseUrl');
  }

  static const String _ua =
      'Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  /// Standard HTTP headers sent with EVERY stream request.
  /// Covers Xtream-compatible servers, HLS proxies, and CDN-backed streams.
  /// Uses getters so they always reflect the current baseUrl.
  static Map<String, String> get streamHeaders => {
    'User-Agent': _ua,
    'Accept': '*/*',
    'Accept-Language': 'en-US,en;q=0.9',
    'Connection': 'keep-alive',
    'Referer': '$baseUrl/',
    'Origin': baseUrl,
    'Icy-MetaData': '1',                // Request ICY metadata for radio/audio streams
    'X-Requested-With': 'XMLHttpRequest',
  };

  // ── Cached category maps ──────────────────────────────────────────────────
  static Map<String, String> _liveCats = {};
  static Map<String, String> _vodCats = {};
  static Map<String, String> _seriesCats = {};
  static Future<void>? _categoriesFuture;

  /// Reset all cached data (call on logout/re-login to prevent stale data)
  static void resetCache() {
    _liveCats = {};
    _vodCats = {};
    _seriesCats = {};
    _categoriesFuture = null;
    debugPrint('[IptvService] Cache reset');
  }

  // ── Persistent HTTP client for connection reuse (much faster on slow nets)
  static final http.Client _client = http.Client();
  static const Map<String, String> _headers = {
    'User-Agent': _ua,
    'Accept': '*/*',
    'Accept-Encoding': 'gzip',
    'Connection': 'keep-alive',
  };

  // ── HTTP helper with auto-retry (exponential back-off) ────────────────────
  static Future<http.Response> _get(Uri url,
      {Duration timeout = const Duration(seconds: 30)}) async {
    try {
      return await _client.get(url, headers: _headers).timeout(timeout);
    } catch (e) {
      debugPrint('[HTTP] First attempt failed ($url): $e — retrying in 3s');
      await Future.delayed(const Duration(seconds: 3));
      try {
        return await _client.get(url, headers: _headers).timeout(timeout);
      } catch (e2) {
        debugPrint('[HTTP] Second attempt failed ($url): $e2 — retrying in 5s');
        await Future.delayed(const Duration(seconds: 5));
        return await _client.get(url, headers: _headers).timeout(timeout);
      }
    }
  }

  // ── Fast stream health check ───────────────────────────────────────────────
  /// Sends a HEAD (falling back to GET with a tiny range) to [url] and returns
  /// true if the server responds with a non-4xx, non-5xx status code.
  /// Timeout is 5 seconds — just enough to skip clearly dead URLs before
  /// the media player spends 20s waiting on them.
  /// TEMPORARY diagnostic bypass — when true, streamHealthCheck() always
  /// returns true immediately without sending a HEAD request. Used to test
  /// whether the HEAD request itself (many Xtream panels mishandle HEAD on
  /// live endpoints) is the source of the main-isolate freeze.
  static bool debugBypassHealthCheck = false;

  static Future<bool> streamHealthCheck(String url) async {
    final entered = DateTime.now();
    debugPrint('[HealthCheck] ENTER @$entered url=$url bypass=$debugBypassHealthCheck');
    if (debugBypassHealthCheck) {
      debugPrint('[HealthCheck] BYPASS — skipping HEAD request');
      return true;
    }
    try {
      final uri = Uri.parse(url);
      final beforeHead = DateTime.now();
      debugPrint('[HealthCheck] before _client.head() @$beforeHead url=$url');
      // Try HEAD first (no body downloaded)
      final head = await _client
          .head(uri, headers: {
            ..._headers,
            'User-Agent': _ua,
            'Referer': '$baseUrl/',
            'Range': 'bytes=0-1023', // request tiny range
          })
          .timeout(const Duration(seconds: 5));
      debugPrint('[HealthCheck] after _client.head() — took '
          '${DateTime.now().difference(beforeHead).inMilliseconds}ms url=$url');
      final code = head.statusCode;
      if (code == 403 || code == 404 || code >= 500) {
        debugPrint('[HealthCheck] ❌ $code for $url');
        return false;
      }
      debugPrint('[HealthCheck] ✅ $code for $url');
      return true;
    } catch (e) {
      debugPrint('[HealthCheck] ⚠ timeout/error for $url: $e — total elapsed '
          '${DateTime.now().difference(entered).inMilliseconds}ms');
      // Don't skip on timeout — server might accept player but not HEAD requests
      return true;
    } finally {
      debugPrint('[HealthCheck] EXIT — total elapsed '
          '${DateTime.now().difference(entered).inMilliseconds}ms url=$url');
    }
  }

  // ── Authentication ────────────────────────────────────────────────────────
  static Future<bool> authenticate(String username, String password) async {
    try {
      final url = Uri.parse(
          '$baseUrl/player_api.php?username=$username&password=$password');
      // 25s auth timeout — some IPTV servers can be slow to respond
      final response = await _get(url, timeout: const Duration(seconds: 25));
      if (response.statusCode == 200) {
        final data = await compute(_parseJsonMap, response.body);
        if (data['user_info'] != null && data['user_info']['auth'] == 1) {
          return true;
        }
      }
      return false;
    } catch (e) {
      throw Exception('Connection failed: $e');
    }
  }

  // ── Category loaders ──────────────────────────────────────────────────────
  static Future<Map<String, String>> _fetchCategories(
      String username, String password, String action) async {
    try {
      final url = Uri.parse(
          '$baseUrl/player_api.php?username=$username&password=$password&action=$action');
      final response = await _get(url, timeout: const Duration(seconds: 30));
      if (response.statusCode == 200) {
        final List<dynamic> data =
            await compute(_parseJsonList, response.body);
        return {
          for (var cat in data)
            (cat['category_id']?.toString() ?? ''):
                (cat['category_name']?.toString() ?? 'Unknown')
        };
      }
    } catch (e) {
      debugPrint('Error fetching categories ($action): $e');
    }
    return {};
  }

  static Future<void> loadCategories(String username, String password) async {
    final results = await Future.wait([
      _fetchCategories(username, password, 'get_live_categories'),
      _fetchCategories(username, password, 'get_vod_categories'),
      _fetchCategories(username, password, 'get_series_categories'),
    ]);
    _liveCats = results[0];
    _vodCats = results[1];
    _seriesCats = results[2];
  }

  static Future<void> ensureCategoriesLoaded(String username, String password) {
    _categoriesFuture ??= loadCategories(username, password);
    return _categoriesFuture!;
  }

  // ── Live Channels ─────────────────────────────────────────────────────────
  static Future<List<ContentItem>> getLiveChannels(
      String username, String password) async {
    try {
      final url = Uri.parse(
          '$baseUrl/player_api.php?username=$username&password=$password&action=get_live_streams');
      // 60s — live stream lists can be very large on big providers
      final response = await _get(url, timeout: const Duration(seconds: 60));
      if (response.statusCode == 200) {
        await ensureCategoriesLoaded(username, password);
        final List<dynamic> data =
            await compute(_parseJsonList, response.body);
        final cats = Map<String, String>.from(_liveCats);
        return data.where((item) => item is Map).map<ContentItem>((item) {
          final catId = item['category_id']?.toString() ?? '';
          return ContentItem(
            id: item['stream_id']?.toString() ?? '',
            type: ContentType.live,
            title: item['name']?.toString() ?? 'Unknown',
            imageUrl: item['stream_icon']?.toString() ?? '',
            category: cats[catId] ?? catId,
            channelNumber: item['num'] is int
                ? item['num']
                : int.tryParse(item['num']?.toString() ?? ''),
            nowPlaying: item['epg_channel_id']?.toString(),
          );
        }).toList();
      }
    } catch (e) {
      debugPrint('Error fetching live: $e');
    }
    return [];
  }

  // ── Movies (VOD) ──────────────────────────────────────────────────────────
  static Future<List<ContentItem>> getMovies(
      String username, String password) async {
    try {
      final url = Uri.parse(
          '$baseUrl/player_api.php?username=$username&password=$password&action=get_vod_streams');
      debugPrint('[IPTV Service] Fetching movies from: $url');
      // 90s — VOD catalogues can be extremely large (10k+ entries)
      final response = await _get(url, timeout: const Duration(seconds: 90));
      debugPrint('[IPTV Service] Movies response: statusCode=${response.statusCode}, bodyLength=${response.body.length}');
      if (response.statusCode == 200 && response.body.isNotEmpty) {
        if (response.body.length < 500) {
          debugPrint('[IPTV Service] Movies response body: ${response.body}');
        } else {
          debugPrint('[IPTV Service] Movies response body start: ${response.body.substring(0, 300)}');
        }
        await ensureCategoriesLoaded(username, password);
        final cats = Map<String, String>.from(_vodCats);
        final list = await compute(
            _parseAndMapMovies, {'body': response.body, 'cats': cats});
        debugPrint('[IPTV Service] Mapped movie ContentItems count: ${list.length}');
        return list;
      }
    } catch (e, stack) {
      debugPrint('Error fetching movies: $e\n$stack');
    }
    return [];
  }

  // ── Series ────────────────────────────────────────────────────────────────
  static Future<List<ContentItem>> getSeries(
      String username, String password) async {
    try {
      final url = Uri.parse(
          '$baseUrl/player_api.php?username=$username&password=$password&action=get_series');
      // 60s — series lists can be very large
      final response = await _get(url, timeout: const Duration(seconds: 60));
      if (response.statusCode == 200 && response.body.isNotEmpty) {
        await ensureCategoriesLoaded(username, password);
        final cats = Map<String, String>.from(_seriesCats);
        return await compute(
            _parseAndMapSeries, {'body': response.body, 'cats': cats});
      }
    } catch (e) {
      debugPrint('Error fetching series: $e');
    }
    return [];
  }

  // ── Series Info ───────────────────────────────────────────────────────────
  static Future<Map<String, dynamic>?> getSeriesInfo(
      String username, String password, String seriesId) async {
    try {
      final url = Uri.parse(
          '$baseUrl/player_api.php?username=$username&password=$password'
          '&action=get_series_info&series_id=$seriesId');
      // 60s — series info contains all episode data and can be a huge payload
      final response =
          await _get(url, timeout: const Duration(seconds: 60));
      if (response.statusCode == 200) {
        final body = response.body.trim();
        if (body.isNotEmpty &&
            body != '[]' &&
            body != 'null' &&
            body.startsWith('{')) {
          return await compute(_parseJsonMap, body);
        }
      }
    } catch (e) {
      debugPrint('Error fetching series info: $e');
    }
    return null;
  }

  // ── Get all episodes as structured seasons ────────────────────────────────
  static Future<List<SeasonInfo>> getAllEpisodes(
      String username, String password, String seriesId) async {
    final data = await getSeriesInfo(username, password, seriesId);
    if (data == null) return [];

    final episodesMap = data['episodes'];
    if (episodesMap is! Map || episodesMap.isEmpty) return [];

    final seasons = <SeasonInfo>[];
    final sortedSeasonKeys = episodesMap.keys.toList()
      ..sort((a, b) {
        final ai = int.tryParse(a.toString()) ?? 0;
        final bi = int.tryParse(b.toString()) ?? 0;
        return ai.compareTo(bi);
      });

    for (final seasonKey in sortedSeasonKeys) {
      final seasonNum = int.tryParse(seasonKey.toString()) ?? 1;
      final rawEps = episodesMap[seasonKey];
      if (rawEps is! List || rawEps.isEmpty) continue;

      final episodes = <EpisodeInfo>[];
      for (final ep in rawEps) {
        final id = ep['id']?.toString() ??
            ep['episode_id']?.toString() ??
            ep['stream_id']?.toString();
        if (id == null || id.isEmpty || id == '0') continue;

        final ext =
            (ep['container_extension']?.toString() ?? 'mp4').toLowerCase();
        final epNum = ep['episode_num'] is int
            ? ep['episode_num'] as int
            : int.tryParse(ep['episode_num']?.toString() ?? '') ?? 0;
        final title = ep['title']?.toString() ??
            ep['name']?.toString() ??
            'Episode $epNum';

        final directSrc = ep['direct_source']?.toString();

        episodes.add(EpisodeInfo(
          streamId: id,
          ext: ext.isEmpty ? 'mp4' : ext,
          title: title,
          episodeNum: epNum,
          seasonNum: seasonNum,
          plot: ep['plot']?.toString(),
          duration: ep['duration']?.toString() ??
              ep['duration_secs']?.toString(),
          thumbnail: ep['info']?['movie_image']?.toString(),
          directSource: (directSrc != null && directSrc.isNotEmpty) ? directSrc : null,
        ));
      }

      if (episodes.isNotEmpty) {
        episodes.sort((a, b) => a.episodeNum.compareTo(b.episodeNum));
        seasons.add(SeasonInfo(seasonNum: seasonNum, episodes: episodes));
      }
    }

    return seasons;
  }

  /// Convenience: first episode stream path "12345.mp4", null if none
  static Future<String?> getFirstEpisodeStreamId(
      String username, String password, String seriesId) async {
    final seasons = await getAllEpisodes(username, password, seriesId);
    if (seasons.isEmpty) return null;
    final ep = seasons.first.episodes.first;
    return ep.streamPath;
  }

  // ── Stream URL builders ───────────────────────────────────────────────────
  static String getLiveStreamUrl(
          String username, String password, String streamId) =>
      '$baseUrl/live/$username/$password/$streamId.m3u8';

  static String getLiveStreamUrlTs(
          String username, String password, String streamId) =>
      '$baseUrl/live/$username/$password/$streamId.ts';

  /// No-extension live URL — many Xtream servers serve via redirect from this form
  static String getLiveStreamUrlNoExt(
          String username, String password, String streamId) =>
      '$baseUrl/live/$username/$password/$streamId';

  /// Returns ALL live URL candidates in the most-likely-to-work order.
  ///
  /// Extended candidate list for maximum cross-device compatibility:
  ///   1. Bare URL (Xtream redirect) — most compatible, server picks best format
  ///   2. .m3u8 — HLS, works on Mi Box, Shield, TCL Android TV (API 16+)
  ///   3. .ts — MPEG-TS, required for old Amlogic S905 boxes running Android 5
  ///   4. .m3u8 with direct path variant — some IPTV panels use different paths
  ///   5. Explicit bare fallback — catches Xtream servers that don't auto-redirect
  ///
  /// The health-check will quickly skip dead URLs, so adding more candidates
  /// costs only a few hundred milliseconds when the first URL works.
  static List<String> getLiveStreamUrlCandidates(
          String username, String password, String streamId) =>
      [
        getLiveStreamUrl(username, password, streamId),      // .m3u8 — HLS (fastest to start & smoothest)
        getLiveStreamUrlTs(username, password, streamId),    // .ts   — MPEG-TS (direct stream)
        getLiveStreamUrlNoExt(username, password, streamId), // bare URL fallback
        '$baseUrl/hls/$username/$password/$streamId.m3u8',
      ];

  static String getMovieStreamUrl(
      String username, String password, String streamId,
      [String ext = 'mp4']) =>
      '$baseUrl/movie/$username/$password/$streamId.$ext';

  /// Returns ALL movie URL candidates in order of likelihood.
  ///
  /// Extended to include additional fallbacks for TV boxes that need specific container
  /// formats. Old Amlogic boxes may not decode MKV headers correctly, so MP4 is
  /// always the safest fallback. We also try the bare URL (server redirect) last.
  static List<String> getMovieStreamUrlCandidates(
      String username, String password, String streamId,
      [String declaredExt = 'mp4']) {
    final ext = declaredExt.toLowerCase().isEmpty ? 'mp4' : declaredExt.toLowerCase();
    // Declared extension first, then the two most common fallbacks
    final exts = <String>[ext];
    for (final e in ['mp4', 'mkv', 'avi']) {
      if (!exts.contains(e)) exts.add(e);
    }
    return [
      ...exts.map((e) => getMovieStreamUrl(username, password, streamId, e)),
      '$baseUrl/movie/$username/$password/$streamId', // bare fallback
    ];
  }

  // ── Quality-Tier URL Builders ────────────────────────────────────────────────

  /// Returns live stream URL candidates ordered for [tier].
  ///
  /// Tier mapping:
  ///  • auto / 4K / 1080p  → same as getLiveStreamUrlCandidates() (server auto-picks)
  ///  • 720p HD             → prioritise .m3u8 with q=720 hint
  ///  • 480p SD             → .m3u8 with q=480, then ts
  ///  • low360 (failover)   → lowest quality variants only
  static List<String> getLiveStreamUrlCandidatesByQuality(
      String username, String password, String streamId, QualityTier tier) {
    // All Xtream servers handle quality via adaptive HLS; we send quality hints
    // as URL parameters — servers that support them will honour them, others ignore.
    switch (tier) {
      case QualityTier.uhd4k:
      case QualityTier.fhd1080:
      case QualityTier.auto:
        // Full-quality candidate list (same as before)
        return getLiveStreamUrlCandidates(username, password, streamId);

      case QualityTier.hd720:
        return [
          '$baseUrl/live/$username/$password/$streamId.m3u8?quality=720p',
          '$baseUrl/live/$username/$password/$streamId.m3u8',   // fallback
          '$baseUrl/live/$username/$password/$streamId.ts',
          '$baseUrl/live/$username/$password/$streamId',
        ];

      case QualityTier.sd480:
        return [
          '$baseUrl/live/$username/$password/$streamId.m3u8?quality=480p',
          '$baseUrl/live/$username/$password/$streamId.m3u8?quality=sd',
          '$baseUrl/live/$username/$password/$streamId.m3u8',
          '$baseUrl/live/$username/$password/$streamId.ts',
          '$baseUrl/live/$username/$password/$streamId',
        ];

      case QualityTier.low360:
        // Level-3 failover — lowest possible quality
        return [
          '$baseUrl/live/$username/$password/$streamId.m3u8?quality=360p',
          '$baseUrl/live/$username/$password/$streamId.m3u8?quality=low',
          '$baseUrl/live/$username/$password/${streamId}_low.m3u8',
          '$baseUrl/live/$username/$password/$streamId.ts',
          '$baseUrl/live/$username/$password/$streamId',
        ];
    }
  }

  /// Returns movie URL candidates ordered for [tier].
  static List<String> getMovieStreamUrlCandidatesByQuality(
      String username, String password, String streamId, QualityTier tier,
      [String declaredExt = 'mp4']) {
    final ext = declaredExt.toLowerCase().isEmpty ? 'mp4' : declaredExt.toLowerCase();
    switch (tier) {
      case QualityTier.uhd4k:
      case QualityTier.fhd1080:
      case QualityTier.auto:
        return getMovieStreamUrlCandidates(username, password, streamId, ext);

      case QualityTier.hd720:
        return [
          '$baseUrl/movie/$username/$password/$streamId.mp4?quality=720p',
          getMovieStreamUrl(username, password, streamId, ext),
          getMovieStreamUrl(username, password, streamId, 'mp4'),
          '$baseUrl/movie/$username/$password/$streamId',
        ];

      case QualityTier.sd480:
        return [
          '$baseUrl/movie/$username/$password/$streamId.mp4?quality=480p',
          '$baseUrl/movie/$username/$password/$streamId.mp4?quality=sd',
          getMovieStreamUrl(username, password, streamId, 'mp4'),
          '$baseUrl/movie/$username/$password/$streamId',
        ];

      case QualityTier.low360:
        return [
          '$baseUrl/movie/$username/$password/$streamId.mp4?quality=360p',
          '$baseUrl/movie/$username/$password/$streamId.mp4?quality=low',
          getMovieStreamUrl(username, password, streamId, 'mp4'),
          '$baseUrl/movie/$username/$password/$streamId',
        ];
    }
  }

  static String getSeriesStreamUrl(
          String username, String password, String episodeIdWithExt) =>
      '$baseUrl/series/$username/$password/$episodeIdWithExt';

  // ── Helpers ───────────────────────────────────────────────────────────────
  static double? _parseRating(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    final d = double.tryParse(value.toString());
    if (d != null && d > 0) return d > 10 ? d / 10 : d;
    return null;
  }

  static int? _parseYear(dynamic value) {
    if (value == null) return null;
    final s = value.toString();
    final match = RegExp(r'(\d{4})').firstMatch(s);
    if (match != null) {
      final year = int.tryParse(match.group(1)!);
      if (year != null && year >= 1900 && year <= 2030) return year;
    }
    return null;
  }

  static String _cleanGenre(String catName) {
    return catName
        .replaceAll(
            RegExp(r'^(Movie|Movies|Series|VOD)[- ]+', caseSensitive: false),
            '')
        .trim();
  }
}
