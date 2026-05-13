import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/content_model.dart';

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
    }
  } catch (_) {}
  return [];
}

Map<String, dynamic> _parseJsonMap(String body) {
  try {
    final decoded = json.decode(body);
    if (decoded is Map<String, dynamic>) return decoded;
  } catch (_) {}
  return {};
}

class IptvService {
  static const String baseUrl = 'http://fulltv.vip:25461';
  static const String _ua =
      'Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  // ── Cached category maps ──────────────────────────────────────────────────
  static Map<String, String> _liveCats = {};
  static Map<String, String> _vodCats = {};
  static Map<String, String> _seriesCats = {};
  static Future<void>? _categoriesFuture;

  // ── Persistent HTTP client for connection reuse (much faster on slow nets)
  static final http.Client _client = http.Client();
  static const Map<String, String> _headers = {
    'User-Agent': _ua,
    'Accept': '*/*',
    'Accept-Encoding': 'gzip',
    'Connection': 'keep-alive',
  };

  // ── HTTP helper with auto-retry ───────────────────────────────────────────
  static Future<http.Response> _get(Uri url,
      {Duration timeout = const Duration(seconds: 30)}) async {
    try {
      return await _client.get(url, headers: _headers).timeout(timeout);
    } catch (_) {
      await Future.delayed(const Duration(seconds: 2));
      return await _client.get(url, headers: _headers).timeout(timeout);
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
      // 45s — live stream lists can be very large on big providers
      final response = await _get(url, timeout: const Duration(seconds: 45));
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
      // 60s — VOD lists can have 10 000+ items (large JSON body)
      final response = await _get(url, timeout: const Duration(seconds: 60));
      if (response.statusCode == 200 && response.body.isNotEmpty) {
        await ensureCategoriesLoaded(username, password);
        final List<dynamic> data =
            await compute(_parseJsonList, response.body);
        final cats = Map<String, String>.from(_vodCats);
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
          return ContentItem(
            id: item['stream_id']?.toString() ?? '',
            type: ContentType.movie,
            title: item['name']?.toString() ?? 'Unknown',
            imageUrl: item['stream_icon']?.toString() ?? '',
            category: catName,
            genre: _cleanGenre(catName),
            rating: _parseRating(item['rating']),
            year: _parseYear(item['added']),
            description: item['plot']?.toString(),
            duration: item['duration']?.toString(),
            containerExtension: ext.isEmpty ? 'mp4' : ext,
          );
        }).toList();
      }
    } catch (e) {
      debugPrint('Error fetching movies: $e');
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
        final List<dynamic> data =
            await compute(_parseJsonList, response.body);
        final cats = Map<String, String>.from(_seriesCats);
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
          return ContentItem(
            id: item['series_id']?.toString() ?? '',
            type: ContentType.series,
            title: item['name']?.toString() ?? 'Unknown',
            imageUrl: item['cover']?.toString() ?? '',
            backdropUrl: item['backdrop_path'] is List &&
                    (item['backdrop_path'] as List).isNotEmpty
                ? item['backdrop_path'][0]?.toString()
                : null,
            category: catName,
            genre: _cleanGenre(catName),
            rating: _parseRating(item['rating']),
            year: _parseYear(item['releaseDate'] ?? item['last_modified']),
            description: item['plot']?.toString(),
            episodeCount: episodeCount,
          );
        }).toList();
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

  /// No-extension live URL — some servers prefer this over .m3u8
  static String getLiveStreamUrlNoExt(
          String username, String password, String streamId) =>
      '$baseUrl/live/$username/$password/$streamId';

  static String getMovieStreamUrl(
      String username, String password, String streamId,
      [String ext = 'mp4']) =>
      '$baseUrl/movie/$username/$password/$streamId.$ext';

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
