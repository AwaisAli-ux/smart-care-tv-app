import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../core/focus/dpad_scroll_helper.dart';
import '../core/player/safe_dispose.dart';
import '../core/widgets/tv_safe_area.dart';
import '../models/content_model.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';
import '../widgets/tv_focus.dart';
import '../services/app_state.dart';
import '../services/iptv_service.dart';
import '../services/device_profile_service.dart';
import '../services/player_factory.dart';
import 'episode_player_screen.dart';
import '../utils/player_navigation.dart';

/// Native method channel to control Android AudioManager.
/// Requests audio focus and raises media volume before any stream plays.
const _audioChannel = MethodChannel('com.smartcaretv.app/audio');

class DetailScreen extends StatefulWidget {
  final ContentItem item;
  const DetailScreen({super.key, required this.item});

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  // ── Player state ─────────────────────────────────────────────
  bool _playing = false;
  bool _playerLoading = false;
  bool _autoRetrying = false;     // true while auto-retry is in progress
  int  _retryCount = 0;           // how many auto-retries attempted
  Timer? _retryTimer;             // countdown timer for next retry
  int  _retryCountdown = 0;       // seconds until next retry
  Timer? _volumeTimer;            // repeating timer to enforce unmuted audio
  String? _playerError;
  bool _startingPlay = false;     // guards against overlapping _startPlay() calls
  Player? _player;
  VideoController? _videoController;

  StreamSubscription? _completedSub;
  StreamSubscription? _positionSub;
  StreamSubscription? _durationSub;
  StreamSubscription? _playingSub;

  // ── Focus ──────────────────────────────────────────────────────
  final FocusNode _screenFocus = FocusNode(debugLabel: 'DetailScreen');
  final FocusNode _playPauseFocus = FocusNode(debugLabel: 'DetailPlayPause');

  // ── Overlay controls state ──────────────────────────────────────
  bool _showControls = true;
  Timer? _hideControlsTimer;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _volume = 100.0;
  bool _showVolumeBar = false;
  Timer? _hideVolumeTimer;
  bool _isFullscreen = false;
  // Seek-drag state (finger scrubbing)
  bool _draggingProgress = false;
  Duration _dragPosition = Duration.zero;
  // Suggestions auto-hide
  bool _showSuggestions = true;
  Timer? _hideSuggestionsTimer;

  // ── Episodes state ────────────────────────────────────────────
  bool _episodesLoading = false;
  List<SeasonInfo> _seasons = [];
  int _selectedSeason = 0;
  EpisodeInfo? _currentEpisode;

  // FIX #7 (step 6) — one node per episode, keyed by streamId so it survives
  // the season list being rebuilt. Lets us put focus back on the exact
  // episode the user played when they come back from the episode player.
  final Map<String, FocusNode> _episodeNodes = {};

  FocusNode _episodeNodeFor(EpisodeInfo ep) => _episodeNodes.putIfAbsent(
        ep.streamId,
        () => FocusNode(debugLabel: 'Episode_${ep.streamId}'),
      );

  /// Index of the season containing [ep], or null if it isn't found.
  int? _seasonIndexOf(EpisodeInfo ep) {
    for (int i = 0; i < _seasons.length; i++) {
      if (_seasons[i].episodes.any((e) => e.streamId == ep.streamId)) return i;
    }
    return null;
  }


  static const _ua =
      'Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  @override
  void initState() {
    super.initState();
    if (widget.item.isSeries) {
      _loadEpisodes();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _screenFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    _volumeTimer?.cancel();
    _hideControlsTimer?.cancel();
    _hideVolumeTimer?.cancel();
    _hideSuggestionsTimer?.cancel();
    _completedSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _playingSub?.cancel();
    _screenFocus.dispose();
    _playPauseFocus.dispose();
    for (final n in _episodeNodes.values) {
      n.dispose(); // FIX #7 (step 6)
    }
    // Ordered teardown — a bare dispose() can delete the FFI callbacks while
    // mpv is still delivering events, which aborts the process.
    final p = _player;
    _player = null;
    if (p != null) Future.microtask(() => safeDisposePlayer(p));
    super.dispose();
  }



  void _startVolumeEnforcement() {
    _volumeTimer?.cancel();
    int ticks = 0;
    _volumeTimer = Timer.periodic(const Duration(milliseconds: 300), (t) {
      ticks++;
      if (!mounted || _player == null) { t.cancel(); return; }
      _player!.setVolume(100.0).catchError((_) {});
      _audioChannel.invokeMethod('setMaxVolume').catchError((_) {});
      if (ticks >= 17) {
        t.cancel();
        _startVolumeEnforcementPhase2();
      }
    });
  }

  void _startVolumeEnforcementPhase2() {
    int ticks = 0;
    _volumeTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      ticks++;
      if (!mounted || _player == null) { t.cancel(); return; }
      _player!.setVolume(100.0).catchError((_) {});
      if (ticks % 3 == 0) {
        _audioChannel.invokeMethod('setMaxVolume').catchError((_) {});
      }
      if (ticks >= 15) t.cancel();
    });
  }

  void _scheduleAutoRetry() {
    if (!mounted) return;
    _retryTimer?.cancel();
    const delaySecs = 4;
    setState(() {
      _autoRetrying = true;
      _playing = false;
      _playerError = null;
      _retryCountdown = delaySecs;
    });
    _retryTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      setState(() => _retryCountdown--);
      if (_retryCountdown <= 0) {
        t.cancel();
        setState(() => _autoRetrying = false);
        _retryCount++;
        _startPlay();
      }
    });
  }

  Future<void> _loadEpisodes() async {
    setState(() => _episodesLoading = true);
    try {
      final state = context.read<AppState>();
      final seasons = await IptvService.getAllEpisodes(
          state.username, state.password, widget.item.id);
      if (!mounted) return;
      setState(() {
        _seasons = seasons;
        _selectedSeason = 0;
        _episodesLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _episodesLoading = false);
    }
  }

  /// Returns true if the error string is a non-fatal libmpv warning
  /// that should NOT cause us to abandon a URL.
  bool _isNonFatalError(String err) {
    // Only whitelist truly harmless warnings — do NOT broadly match
    // 'demux', 'track', or 'cache' as those also appear in fatal errors
    // like 'Failed to open demuxer' or 'demux_open failed'.
    final lower = err.toLowerCase();
    if (lower.contains('subtitle')) return true;
    if (lower.contains('unsupported tag')) return true;
    if (lower.contains('skipping')) return true;
    if (lower.contains('matroska/webm: skipping')) return true;
    if (lower.contains('audio track selection')) return true;
    if (lower.contains('no audio') && lower.contains('available')) return true;
    if (lower.startsWith('warning:')) return true;
    if (lower.contains('[warning]')) return true;
    return false;
  }

  Future<List<String>> _candidateUrls(AppState state,
      {EpisodeInfo? episode}) async {
    final u = state.username;
    final p = state.password;
    final id = widget.item.id;

    if (widget.item.videoUrl != null && widget.item.videoUrl!.isNotEmpty) {
      return [widget.item.videoUrl!];
    }

    if (widget.item.isLive) {
      return IptvService.getLiveStreamUrlCandidates(u, p, id);
    }

    if (widget.item.isMovie) {
      final declaredExt = (widget.item.containerExtension ?? 'mp4').toLowerCase();
      final exts = <String>[declaredExt];
      for (final e in ['mp4', 'mkv', 'ts', 'm3u8', 'avi']) {
        if (!exts.contains(e)) exts.add(e);
      }
      return [
        ...exts.map((e) => IptvService.getMovieStreamUrl(u, p, id, e)),
        '${IptvService.baseUrl}/movie/$u/$p/$id',
      ];
    }

    final ep = episode ?? _currentEpisode;
    if (ep != null) {
      final u2 = state.username;
      final p2 = state.password;
      return [
        if (ep.directSource != null && ep.directSource!.isNotEmpty)
          ep.directSource!,
        IptvService.getSeriesStreamUrl(u2, p2, ep.streamPath),
        '${IptvService.baseUrl}/movie/$u2/$p2/${ep.streamId}.${ep.ext}',
        if (ep.ext != 'mp4') '${IptvService.baseUrl}/movie/$u2/$p2/${ep.streamId}.mp4',
        if (ep.ext != 'mkv') '${IptvService.baseUrl}/movie/$u2/$p2/${ep.streamId}.mkv',
        if (ep.ext != 'ts') '${IptvService.baseUrl}/movie/$u2/$p2/${ep.streamId}.ts',
        '${IptvService.baseUrl}/series/$u2/$p2/${ep.streamId}',
      ];
    }
    throw Exception('No episode selected. Tap an episode from the list below.');
  }

  Future<void> _playEpisode(EpisodeInfo ep) async {
    // Collect ALL episodes across all seasons for the suggestions list
    final allEps = _seasons.expand((s) => s.episodes).toList();

    await preRotateForPlayer();
    if (!mounted) return;

    // Navigate to the dedicated full-screen episode player
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => EpisodePlayerScreen(
          series: widget.item,
          episode: ep,
          allEpisodes: allEps,
        ),
      ),
    );
    // Restore orientation when returning to the detail screen
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual,
        overlays: SystemUiOverlay.values);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    // FIX #7 (step 6) — land back on the episode that was just played, with
    // its season selected. The player may have advanced to a later episode in
    // a different season, so resolve the season from the episode itself.
    if (!mounted) return;
    final seasonIdx = _seasonIndexOf(ep);
    if (seasonIdx != null && seasonIdx != _selectedSeason) {
      setState(() => _selectedSeason = seasonIdx);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final node = _episodeNodes[ep.streamId];
      if (node == null) return;
      node.requestFocus();
      final ctx = node.context;
      if (ctx != null) DpadScroll.ensureVisible(ctx);
    });
  }

  Future<void> _startPlay({EpisodeInfo? episode}) async {
    if (!mounted || _startingPlay) return;
    _startingPlay = true;
    EpisodeInfo? ep = episode;

    if (widget.item.isSeries && ep == null && _currentEpisode == null) {
      if (_episodesLoading) {
        setState(() {
          _playerLoading = true;
          _playing = true;
          _playerError = null;
        });
        int waited = 0;
        while (_episodesLoading && waited < 15000) {
          await Future.delayed(const Duration(milliseconds: 300));
          waited += 300;
        }
      }
      if (_seasons.isNotEmpty && _seasons.first.episodes.isNotEmpty) {
        ep = _seasons.first.episodes.first;
        if (mounted) setState(() => _currentEpisode = ep);
      }
    } else if (ep == null) {
      ep = _currentEpisode;
    }

    if (!mounted) return;
    setState(() {
      _playerLoading = true;
      _playing = true;
      _playerError = null;
      _position = Duration.zero;
      _duration = Duration.zero;
      _isFullscreen = true;
    });

    _completedSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _playingSub?.cancel();
    // Ordered teardown, same reason as in dispose().
    final oldPlayer = _player;
    _videoController = null;
    _player = null;
    if (oldPlayer != null) {
      Future.microtask(() => safeDisposePlayer(oldPlayer));
    }

    try {
      try {
        await _audioChannel.invokeMethod('requestAudioFocus');
        await _audioChannel.invokeMethod('setMaxVolume');
      } catch (_) {}

      final state = context.read<AppState>();
      final urls = await _candidateUrls(state, episode: ep);

      final hwAccel  = state.hardwareAccelEnabled;
      final bufBytes = state.bufferBytes;
      final profile  = DeviceProfileService.instance.currentProfile;
      final isLive   = widget.item.isLive;

      debugPrint('▶ [Detail] hwAccel=$hwAccel bufferBytes=${bufBytes ~/ (1024 * 1024)}MB isLive=$isLive');

      final streamHeaders = <String, String>{
        'User-Agent' : _ua,
        'Accept'     : '*/*',
        'Connection' : 'keep-alive',
        'Referer'    : '${IptvService.baseUrl}/',
        'Icy-MetaData': '1',
      };

      // PlayerFactory fires all mpv properties concurrently (Future.wait)
      // instead of 20+ sequential awaits — eliminates the ANR on Android.
      final probeResult = await PlayerFactory.probe(
        urls: urls,
        bufBytes: bufBytes,
        hwAccel: hwAccel,
        profile: profile,
        streamHeaders: streamHeaders,
        isLive: isLive,
        probeTimeout: const Duration(seconds: 15),
      );

      if (probeResult == null) {
        throw Exception('Stream unavailable. All URL formats failed.');
      }

      _player           = probeResult.player;
      _videoController  = probeResult.controller;

      _completedSub = probeResult.player.stream.completed.listen((done) {
        if (done && mounted) {
          if (widget.item.isLive) {
            Future.delayed(const Duration(seconds: 2), _startPlay);
          } else {
            _showControlsTemporarily();
          }
        }
      });

      _positionSub = probeResult.player.stream.position.listen((p) {
        if (mounted) setState(() => _position = p);
      });
      _durationSub = probeResult.player.stream.duration.listen((d) {
        if (mounted) setState(() => _duration = d);
      });
      _playingSub = probeResult.player.stream.playing.listen((p) {
        if (mounted) setState(() => _playing = p);
      });

      if (!mounted) return;
      setState(() => _playerLoading = false);
      _showControlsTemporarily();

      for (final ms in [0, 100, 250, 500, 800, 1200, 1800, 2500]) {
        Future.delayed(Duration(milliseconds: ms), () {
          if (mounted) _player?.setVolume(100.0).catchError((_) {});
        });
      }

      Future.delayed(const Duration(milliseconds: 200), () async {
        try { await _audioChannel.invokeMethod('requestAudioFocus'); } catch (_) {}
        _player?.setVolume(100.0).catchError((_) {});
      });

      _startVolumeEnforcement();
      _startingPlay = false;
    } catch (e) {
      _startingPlay = false;
      if (!mounted) return;
      _scheduleAutoRetry();
    }
  }



  /// Skip to the next episode in the series.
  void _playNextEpisode() {
    if (_seasons.isEmpty || _currentEpisode == null) return;
    for (int sIdx = 0; sIdx < _seasons.length; sIdx++) {
      final season = _seasons[sIdx];
      final eps = season.episodes;
      final epIdx = eps.indexWhere((e) => e.streamId == _currentEpisode!.streamId);
      if (epIdx != -1) {
        if (epIdx < eps.length - 1) {
          _playEpisode(eps[epIdx + 1]);
          return;
        }
        if (sIdx < _seasons.length - 1) {
          final nextSeason = _seasons[sIdx + 1];
          if (nextSeason.episodes.isNotEmpty) {
            setState(() => _selectedSeason = sIdx + 1);
            _playEpisode(nextSeason.episodes.first);
            return;
          }
        }
      }
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('This is the last episode'),
        backgroundColor: Colors.black54,
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _playNext() {
    final state = context.read<AppState>();
    final List<ContentItem> list = widget.item.isLive
        ? state.channels
        : widget.item.isMovie
            ? state.movies
            : state.series;
    final idx = list.indexWhere((i) => i.id == widget.item.id);
    if (idx >= 0 && idx < list.length - 1) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => DetailScreen(item: list[idx + 1])),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('You are at the last item'),
          backgroundColor: Colors.black54,
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  void _togglePlay() {
    if (_player == null) return;
    if (_player!.state.playing) {
      _player!.pause();
    } else {
      _player!.play();
    }
    _showControlsTemporarily();
  }

  void _seekRelative(Duration delta) {
    if (_player == null) return;
    final newPos = _player!.state.position + delta;
    final duration = _player!.state.duration;
    Duration target = newPos;
    if (newPos < Duration.zero) {
      target = Duration.zero;
    } else if (newPos > duration) {
      target = duration;
    }
    _player!.seek(target);
    _showControlsTemporarily();
  }

  void _volumeUp() {
    final newVol = (_volume + 10).clamp(0.0, 100.0);
    _volume = newVol;
    _player?.setVolume(newVol);
    _showVolumeBarBriefly();
  }

  void _volumeDown() {
    final newVol = (_volume - 10).clamp(0.0, 100.0);
    _volume = newVol;
    _player?.setVolume(newVol);
    _showVolumeBarBriefly();
  }

  void _showVolumeBarBriefly() {
    if (!mounted) return;
    setState(() => _showVolumeBar = true);
    _hideVolumeTimer?.cancel();
    _hideVolumeTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showVolumeBar = false);
    });
    _showControlsTemporarily();
  }

  void _showControlsTemporarily() {
    if (!mounted) return;
    setState(() {
      _showControls = true;
      _showSuggestions = true;
    });
    Future.microtask(() {
      if (mounted && !_playPauseFocus.hasFocus) {
        _playPauseFocus.requestFocus();
      }
    });
    _resetHideControlsTimer();
    _resetSuggestionsTimer();
  }

  void _resetSuggestionsTimer() {
    _hideSuggestionsTimer?.cancel();
    _hideSuggestionsTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _showSuggestions = false);
    });
  }

  void _resetHideControlsTimer() {
    _hideControlsTimer?.cancel();
    _hideControlsTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && !_playerLoading && !_autoRetrying) {
        setState(() {
          _showControls = false;
          _showSuggestions = false;
        });
        _screenFocus.requestFocus();
      }
    });
  }

  void _toggleFullscreen() {
    setState(() {
      _isFullscreen = !_isFullscreen;
    });
    if (_isFullscreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: SystemUiOverlay.values);
    }
    _showControlsTemporarily();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.audioVolumeUp) {
      _volumeUp();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.audioVolumeDown) {
      _volumeDown();
      return KeyEventResult.handled;
    }

    if (_showControls) {
      _resetHideControlsTimer();
    }

    if (key == LogicalKeyboardKey.goBack || key == LogicalKeyboardKey.escape) {
      if (_isFullscreen) {
        _toggleFullscreen();
        return KeyEventResult.handled;
      }
      if (_showControls) {
        setState(() => _showControls = false);
        _screenFocus.requestFocus();
        return KeyEventResult.handled;
      } else {
        _player?.pause();
        Navigator.of(context).pop();
        return KeyEventResult.handled;
      }
    }

    if (key == LogicalKeyboardKey.mediaPlayPause ||
        key == LogicalKeyboardKey.mediaPlay ||
        key == LogicalKeyboardKey.mediaPause) {
      _togglePlay();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.mediaFastForward) {
      _seekRelative(const Duration(seconds: 10));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaRewind) {
      _seekRelative(const Duration(seconds: -10));
      return KeyEventResult.handled;
    }

    if (!_showControls) {
      if (key == LogicalKeyboardKey.select ||
          key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.arrowUp ||
          key == LogicalKeyboardKey.arrowDown ||
          key == LogicalKeyboardKey.arrowLeft ||
          key == LogicalKeyboardKey.arrowRight) {
        _showControlsTemporarily();
        return KeyEventResult.handled;
      }
    }

    if (_showControls) {
      if (key == LogicalKeyboardKey.arrowUp ||
          key == LogicalKeyboardKey.arrowDown ||
          key == LogicalKeyboardKey.arrowLeft ||
          key == LogicalKeyboardKey.arrowRight) {
        return KeyEventResult.ignored;
      }
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final state = context.watch<AppState>();
    final isFav = state.isFavorite(item.id);
    final screenW = MediaQuery.of(context).size.width;

    if (_isFullscreen && _playing && _videoController != null) {
      return Focus(
        focusNode: _screenFocus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _showControlsTemporarily,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Video(controller: _videoController!, controls: NoVideoControls),
                _playerOverlay(item: item, isFav: isFav, state: state, isFullscreen: true),
              ],
            ),
          ),
        ),
      );
    }

    if (item.isSeries) {
      return _buildSeriesDetailScreen(context, item, state, isFav, screenW);
    }

    return _buildDefaultDetailScreen(context, item, state, isFav, screenW);
  }

  Widget _buildSeriesDetailScreen(
    BuildContext context,
    ContentItem item,
    AppState state,
    bool isFav,
    double screenW,
  ) {
    final currentEp = _currentEpisode ??
        (_seasons.isNotEmpty && _seasons[_selectedSeason].episodes.isNotEmpty
            ? _seasons[_selectedSeason].episodes.first
            : null);

    return LayoutBuilder(builder: (context, constraints) {
      final isWide = constraints.maxWidth >= 600;
      // FIX #12 — TvSafeArea now adds no inset (the target panels have no
      // overscan), so this screen keeps its own breathing room.
      final hPad = isWide ? 32.0 : 16.0;
      final vPad = isWide ? 20.0 : 12.0;

      return Scaffold(
        backgroundColor: AppColors.bg,
        body: SafeArea(
          child: TvSafeArea(
          child: SingleChildScrollView(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: hPad, vertical: vPad),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // ── TOP BAR ─────────────────────────────────────────────
                  Row(
                    children: [
                      TvFocusable(
                        scaleOnFocus: true,
                        borderRadius: 20,
                        onActivate: () {
                          _player?.pause();
                          Navigator.pop(context);
                        },
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: const BoxDecoration(
                            color: AppColors.bg3,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.arrow_back, color: Colors.white, size: 22),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          '${item.title}${item.year != null ? "  (${item.year})" : ""}',
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: isWide ? 20 : 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // FIX #8 — the 3-dots overflow icon that used to sit to
                      // the right of this was removed. It was a bare Icon with
                      // no menu and no handler, so it did nothing but take up
                      // space. Favourite is now the last item in the row.
                      TvFocusable(
                        scaleOnFocus: true,
                        onActivate: () => state.toggleFavorite(item),
                        child: Icon(
                          isFav ? Icons.favorite : Icons.favorite_border,
                          color: isFav ? AppColors.accent : Colors.white54,
                          size: 22,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 16),

                  // ── CONTENT: Responsive poster + plot section ────────────
                  if (isWide)
                    // WIDE: side-by-side
                    _buildWidePosterPlot(context, item, currentEp, isWide)
                  else
                    // PORTRAIT: stacked
                    _buildPortraitPosterPlot(context, item, currentEp),

                  const SizedBox(height: 16),

                  // ── EPISODES HEADER ──────────────────────────────────────
                  Text(
                    'Episodes',
                    style: const TextStyle(
                      color: AppColors.accent,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Container(height: 1, width: double.infinity, color: AppColors.border),
                  const SizedBox(height: 12),

                  // ── EPISODES CONTENT ─────────────────────────────────────
                  _buildEpisodesTabContent(),
                ],
              ),
            ),
          ),
          ),
        ),
      );
    });
  }

  // Wide layout: poster on left, plot + actions on right
  Widget _buildWidePosterPlot(BuildContext context, ContentItem item, EpisodeInfo? currentEp, bool isWide) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildPoster(item, width: 140, height: 190),
        const SizedBox(width: 20),
        Expanded(
          child: SizedBox(
            height: 190,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Plot:', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                const SizedBox(height: 6),
                Expanded(
                  child: _buildPlotText(item),
                ),
                const SizedBox(height: 12),
                _buildActionButtons(context, currentEp, wrapButtons: false),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // Portrait layout: poster + rating + plot stacked, then action buttons
  Widget _buildPortraitPosterPlot(BuildContext context, ContentItem item, EpisodeInfo? currentEp) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildPoster(item, width: 110, height: 150),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Plot:', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                  const SizedBox(height: 6),
                  Text(
                    item.description ?? 'No description available.',
                    maxLines: 5,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppColors.textSecondary, fontSize: 12, height: 1.5),
                  ),
                  if (item.description != null && item.description!.length > 150) ...[
                    const SizedBox(height: 4),
                    GestureDetector(
                      onTap: _showFullPlotDialog,
                      child: const Text('Read more', style: TextStyle(color: AppColors.accent, fontWeight: FontWeight.bold, fontSize: 12)),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        // Action buttons in portrait — wrap to next line if needed
        _buildActionButtons(context, currentEp, wrapButtons: true),
      ],
    );
  }

  Widget _buildPoster(ContentItem item, {required double width, required double height}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: item.imageUrl.isNotEmpty
              ? CachedNetworkImage(
                  imageUrl: item.imageUrl,
                  width: width,
                  height: height,
                  fit: BoxFit.cover,
                  errorWidget: (_, __, ___) => _posterPlaceholder(width, height),
                )
              : _posterPlaceholder(width, height),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: List.generate(5, (index) {
            final rating = item.rating ?? 0.0;
            final starValue = rating > 5.0 ? rating / 2.0 : rating;
            final isFilled = index < starValue.round();
            return Icon(
              isFilled ? Icons.star : Icons.star_border,
              color: isFilled ? AppColors.gold : Colors.white24,
              size: 15,
            );
          }),
        ),
      ],
    );
  }

  Widget _posterPlaceholder(double w, double h) => Container(
        width: w, height: h,
        decoration: BoxDecoration(color: AppColors.bg3, borderRadius: BorderRadius.circular(10)),
        child: const Icon(Icons.movie, color: Colors.white30, size: 48),
      );

  Widget _buildPlotText(ContentItem item) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            item.description ?? 'No description available for this series.',
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: AppColors.textSecondary, fontSize: 13, height: 1.5),
          ),
          if (item.description != null && item.description!.length > 180) ...[
            const SizedBox(height: 4),
            TvFocusable(
              scaleOnFocus: true,
              onActivate: _showFullPlotDialog,
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 2),
                child: Text('Read more', style: TextStyle(color: AppColors.accent, fontWeight: FontWeight.bold, fontSize: 12)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildActionButtons(BuildContext context, EpisodeInfo? currentEp, {required bool wrapButtons}) {
    final playBtn = TvFocusable(
      scaleOnFocus: true,
      onActivate: () {
        if (currentEp != null) {
          _playEpisode(currentEp);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('No episodes found for this series.'),
            backgroundColor: Colors.red,
          ));
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
        decoration: BoxDecoration(color: AppColors.accent, borderRadius: BorderRadius.circular(8)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.play_arrow, color: Colors.white, size: 18),
            const SizedBox(width: 6),
            Text(
              currentEp != null ? 'Play  S${currentEp.seasonNum}:E${currentEp.episodeNum}' : 'Play',
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
            ),
          ],
        ),
      ),
    );

    final seasonBtn = TvFocusable(
      scaleOnFocus: true,
      onActivate: _showSeasonPickerDialog,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: AppColors.bg3,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.accent.withValues(alpha: 0.5)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _seasons.isNotEmpty ? _seasons[_selectedSeason].label : 'Season 1',
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
            const SizedBox(width: 6),
            const Icon(Icons.keyboard_arrow_down, color: AppColors.accent, size: 18),
          ],
        ),
      ),
    );

    // FIX #8 — the "Watch Trailer" button is gone. It only ever opened a
    // dialog saying no trailer was available, so removing it also removes a
    // dead stop in the traversal order between Play and the episode list.

    if (wrapButtons) {
      return Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [playBtn, seasonBtn],
      );
    }

    return Row(
      children: [
        playBtn,
        const SizedBox(width: 10),
        seasonBtn,
      ],
    );
  }



  Widget _buildEpisodesTabContent() {
    if (_episodesLoading) {
      return const Center(
        child: CircularProgressIndicator(valueColor: AlwaysStoppedAnimation<Color>(AppColors.accent)),
      );
    }
    if (_seasons.isEmpty) {
      return const Center(
        child: Text('No episodes available for this season.', style: TextStyle(color: AppColors.textTertiary)),
      );
    }
    final episodes = _seasons[_selectedSeason].episodes;
    return ListView.separated(
      scrollDirection: Axis.vertical,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: episodes.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (ctx, i) {
        final ep = episodes[i];
        final isPlaying = _currentEpisode?.streamId == ep.streamId;
        return _episodeRowItem(ep, isPlaying);
      },
    );
  }

  Widget _episodeRowItem(EpisodeInfo ep, bool isPlaying) {
    return TvFocusable(
      focusNode: _episodeNodeFor(ep), // FIX #7 (step 6)
      scaleOnFocus: true,
      onActivate: () => _playEpisode(ep),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: isPlaying ? AppColors.accent.withValues(alpha: 0.1) : AppColors.bg3,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isPlaying ? AppColors.accent : AppColors.border,
            width: isPlaying ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            // Left Thumbnail with Play overlay
            Stack(
              alignment: Alignment.center,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: ep.thumbnail != null && ep.thumbnail!.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: ep.thumbnail!,
                          width: 110,
                          height: 65,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) => Container(
                            width: 110, height: 65,
                            color: AppColors.bg4,
                            child: const Icon(Icons.movie_outlined, color: Colors.white24, size: 24),
                          ),
                        )
                      : Container(
                          width: 110, height: 65,
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              colors: [Color(0xFF2C194D), Color(0xFF0F0721)],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                          ),
                          child: const Center(
                            child: Icon(Icons.tv, color: Colors.white24, size: 24),
                          ),
                        ),
                ),
                // Circular play button overlay
                Container(
                  width: 28, height: 28,
                  decoration: const BoxDecoration(
                    color: Colors.white30,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.play_arrow, color: Colors.white, size: 16),
                ),
              ],
            ),
            const SizedBox(width: 16),

            // Middle Details Column
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    ep.title.isNotEmpty ? ep.title : '${widget.item.title} - S${ep.seasonNum.toString().padLeft(2, '0')}E${ep.episodeNum.toString().padLeft(2, '0')}',
                    style: TextStyle(
                      color: isPlaying ? AppColors.accent : Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 4),
                  // Star ratings row
                  Row(
                    children: List.generate(5, (index) => const Icon(Icons.star, color: Colors.white24, size: 13)),
                  ),
                  const SizedBox(height: 4),
                  // Length
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppColors.bg4,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      ep.duration != null && ep.duration!.isNotEmpty ? ep.duration! : '0m',
                      style: const TextStyle(color: Colors.white70, fontSize: 10),
                    ),
                  ),
                ],
              ),
            ),

          ],
        ),
      ),
    );
  }



  void _showFullPlotDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bg3,
        title: const Text('Plot Summary', style: TextStyle(color: Colors.white)),
        content: Text(
          widget.item.description ?? 'No description available.',
          style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close', style: TextStyle(color: AppColors.accent)),
          ),
        ],
      ),
    );
  }

  // FIX #8 — _showTrailerUnavailableDialog removed along with its button.

  Widget _buildDefaultDetailScreen(
    BuildContext context,
    ContentItem item,
    AppState state,
    bool isFav,
    double screenW,
  ) {
    return Focus(
      focusNode: _screenFocus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          _player?.pause();
          Navigator.of(context).pop();
        },
        child: Scaffold(
          backgroundColor: AppColors.bg,
          body: CustomScrollView(
            slivers: [
              SliverAppBar(
                expandedHeight: screenW > 600 ? 320 : 260,
                pinned: true,
                backgroundColor: AppColors.bg2,
                iconTheme: const IconThemeData(color: AppColors.textPrimary),
                flexibleSpace: FlexibleSpaceBar(
                  background: _playerArea(item),
                ),
              ),

              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_autoRetrying)
                        _retryingBanner()
                      else if (_playerError != null)
                        _errorBanner(_playerError!, onRetry: _startPlay),

                      Wrap(spacing: 8, runSpacing: 8, children: [
                        if (item.isLive) const LiveBadge(),
                        if (item.rating != null)
                          RatingBadge(rating: item.rating!),
                        if (item.genre != null || item.category != null)
                          _chip(item.genre ?? item.category ?? ''),
                        if (item.year != null) _chip('${item.year}'),
                      ]),
                      const SizedBox(height: 14),

                      Text(item.title,
                          style: const TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textPrimary,
                            letterSpacing: -0.5,
                          )),
                      const SizedBox(height: 8),

                      Wrap(spacing: 16, runSpacing: 4, children: [
                        if (item.duration != null && item.duration!.isNotEmpty)
                          _metaItem(Icons.access_time, item.duration!),
                        if (item.episodeCount != null)
                          _metaItem(Icons.video_library_outlined,
                              '${item.episodeCount} Episode${(item.episodeCount ?? 1) > 1 ? "s" : ""}'),
                        if (item.channelNumber != null)
                          _metaItem(
                              Icons.live_tv, 'Ch. ${item.channelNumber}'),
                      ]),
                      const SizedBox(height: 16),

                      if (item.description != null &&
                          item.description!.isNotEmpty)
                        Text(item.description!,
                            style: const TextStyle(
                                fontSize: 14,
                                color: AppColors.textSecondary,
                                height: 1.65)),
                      const SizedBox(height: 24),

                      Row(children: [
                        Expanded(
                          child: TvFocusable(
                            scaleOnFocus: true,
                            onActivate: (_playerLoading || _autoRetrying) ? null : _startPlay,
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 13),
                              decoration: BoxDecoration(
                                color: (_playerLoading || _autoRetrying)
                                    ? AppColors.bg3
                                    : AppColors.accent,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  if (_playerLoading)
                                    const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2, color: Colors.white))
                                  else
                                    const Icon(Icons.play_arrow, size: 20, color: Colors.white),
                                  const SizedBox(width: 8),
                                  Text(
                                    _playerLoading
                                        ? 'Loading…'
                                        : _autoRetrying
                                            ? 'Retrying in ${_retryCountdown}s…'
                                            : item.isLive
                                                ? 'Watch Live'
                                                : item.isSeries
                                                    ? 'Play S1 E1'
                                                    : 'Play',
                                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        TvFocusable(
                          scaleOnFocus: true,
                          onActivate: () {
                            state.toggleFavorite(item);
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text(state.isFavorite(item.id)
                                  ? 'Added to My List'
                                  : 'Removed from My List'),
                              backgroundColor: AppColors.bg4,
                              duration: const Duration(seconds: 2),
                            ));
                          },
                          child: Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: isFav
                                  ? AppColors.accent.withValues(alpha: 0.15)
                                  : AppColors.bg3,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                  color: isFav ? AppColors.accent : AppColors.border),
                            ),
                            child: Icon(
                              isFav ? Icons.favorite : Icons.favorite_border,
                              color: isFav ? AppColors.accent : AppColors.textTertiary,
                              size: 22,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        TvFocusable(
                          scaleOnFocus: true,
                          onActivate: _playNext,
                          child: Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: AppColors.bg3,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: AppColors.border),
                            ),
                            child: const Icon(Icons.skip_next,
                                color: AppColors.textTertiary, size: 22),
                          ),
                        ),
                      ]),

                      if (item.isSeries) ...[
                        const SizedBox(height: 28),
                        _episodeSection(),
                      ],

                      if (item.isLive) ...[
                        const SizedBox(height: 28),
                        const Text('Schedule',
                            style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textPrimary)),
                        const SizedBox(height: 12),
                        if (item.nowPlaying != null)
                          _scheduleRow('Now', item.nowPlaying!, true),
                        if (item.nextUp != null)
                          _scheduleRow('Next', item.nextUp!, false),
                        Builder(builder: (ctx) {
                          final channels = context.read<AppState>().channels;
                          final idx =
                              channels.indexWhere((c) => c.id == item.id);
                          final nextChannel =
                              (idx >= 0 && idx < channels.length - 1)
                                  ? channels[idx + 1]
                                  : null;
                          return _scheduleRow(
                            'Later',
                            nextChannel != null
                                ? nextChannel.title
                                : 'Programming',
                            false,
                            onTap: nextChannel != null
                                ? () => Navigator.pushReplacement(
                                      ctx,
                                      MaterialPageRoute(
                                        builder: (_) =>
                                            DetailScreen(item: nextChannel),
                                      ),
                                    )
                                : null,
                          );
                        }),
                      ],

                      const SizedBox(height: 28),
                      const Text('More Like This',
                          style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary)),
                      const SizedBox(height: 12),
                      _relatedRow(item),
                      const SizedBox(height: 40),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _episodeSection() {
    if (_episodesLoading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 20),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: AppColors.accent)),
            SizedBox(width: 12),
            Text('Loading episodes…',
                style:
                    TextStyle(color: AppColors.textTertiary, fontSize: 13)),
          ]),
        ),
      );
    }

    if (_seasons.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.bg3,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(children: [
          const Icon(Icons.info_outline,
              color: AppColors.textTertiary, size: 18),
          const SizedBox(width: 10),
          const Expanded(
              child: Text('Episode list unavailable — tap Play to watch',
                  style: TextStyle(
                      color: AppColors.textTertiary, fontSize: 13))),
          TextButton(
              onPressed: _loadEpisodes,
              child: const Text('Retry',
                  style:
                      TextStyle(color: AppColors.accent, fontSize: 12))),
        ]),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          const Text('Episodes',
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary)),
          const Spacer(),
          if (_seasons.length > 1)
            _seasonDropdown(),
        ]),
        const SizedBox(height: 12),

        ..._seasons[_selectedSeason].episodes.map((ep) {
          final isPlaying = _currentEpisode?.streamId == ep.streamId;
          return Padding(
            padding: const EdgeInsets.only(bottom: 8.0),
            child: _episodeTile(ep, isPlaying),
          );
        }),
      ],
    );
  }

  Widget _seasonDropdown() {
    return TvFocusable(
      scaleOnFocus: true,
      onActivate: _showSeasonPickerDialog,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.bg3,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_seasons[_selectedSeason].label, style: const TextStyle(color: AppColors.textPrimary, fontSize: 13)),
            const SizedBox(width: 6),
            const Icon(Icons.arrow_drop_down, color: AppColors.textPrimary, size: 18),
          ],
        ),
      ),
    );
  }

  void _showSeasonPickerDialog() {
    showDialog(
      context: context,
      builder: (ctx) => FocusScope(
        autofocus: true,
        child: AlertDialog(
          backgroundColor: AppColors.bg3,
          title: const Text('Select Season', style: TextStyle(color: Colors.white)),
          content: SizedBox(
            width: 250,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _seasons.length,
              itemBuilder: (context, index) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: TvFocusable(
                  scaleOnFocus: true,
                  autofocus: index == _selectedSeason,
                  onActivate: () {
                    setState(() => _selectedSeason = index);
                    Navigator.of(ctx).pop();
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                    decoration: BoxDecoration(
                      color: _selectedSeason == index
                          ? AppColors.accent.withValues(alpha: 0.15)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _seasons[index].label,
                      style: TextStyle(
                        color: _selectedSeason == index ? AppColors.accent : Colors.white,
                        fontWeight: _selectedSeason == index ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _episodeTile(EpisodeInfo ep, bool isPlaying) {
    return TvFocusable(
      focusNode: _episodeNodeFor(ep), // FIX #7 (step 6)
      scaleOnFocus: true,
      onActivate: () => _playEpisode(ep),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: isPlaying
              ? AppColors.accent.withValues(alpha: 0.12)
              : AppColors.bg3,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isPlaying ? AppColors.accent : AppColors.border,
            width: isPlaying ? 1.5 : 1,
          ),
        ),
        child: Row(children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: isPlaying ? AppColors.accent : AppColors.bg4,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: isPlaying && (_playerLoading || _playing)
                  ? const Icon(Icons.pause,
                      color: Colors.white, size: 16)
                  : Text(
                      '${ep.episodeNum}',
                      style: TextStyle(
                        color: isPlaying
                            ? Colors.white
                            : AppColors.textSecondary,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
            ),
          ),
          const SizedBox(width: 12),

          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ep.title.isNotEmpty ? ep.title : 'Episode ${ep.episodeNum}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: isPlaying
                        ? FontWeight.w600
                        : FontWeight.w400,
                    color: isPlaying
                        ? AppColors.accent
                        : AppColors.textPrimary,
                  ),
                ),
                if (ep.duration != null && ep.duration!.isNotEmpty)
                  Text(
                    ep.duration!,
                    style: const TextStyle(
                        fontSize: 11, color: AppColors.textTertiary),
                  ),
              ],
            ),
          ),

          Icon(
            isPlaying && _playing && !_playerLoading
                ? Icons.pause_circle_filled
                : Icons.play_circle_outline,
            color: isPlaying ? AppColors.accent : AppColors.textTertiary,
            size: 28,
          ),
        ]),
      ),
    );
  }

  Widget _playerArea(ContentItem item) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (item.imageUrl.isNotEmpty)
          CachedNetworkImage(
            imageUrl: item.imageUrl,
            fit: BoxFit.cover,
            errorWidget: (_, __, ___) => Container(color: AppColors.bg4),
          )
        else
          Container(color: AppColors.bg4),

        if (!_playing || _playerLoading)
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [
                  AppColors.bg,
                  AppColors.bg.withValues(alpha: 0.25),
                ],
              ),
            ),
          ),

        if (_playing && _videoController != null && !_playerLoading)
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _showControlsTemporarily,
            child: Video(controller: _videoController!, controls: NoVideoControls),
          ),

        if (_playing && _videoController != null && !_playerLoading)
          _playerOverlay(
            item: item,
            isFav: context.watch<AppState>().isFavorite(item.id),
            state: context.watch<AppState>(),
            isFullscreen: false,
          ),

        if (_playerLoading)
          Container(
            color: Colors.black54,
            child: const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(
                    valueColor:
                        AlwaysStoppedAnimation<Color>(AppColors.accent),
                    strokeWidth: 3,
                  ),
                  SizedBox(height: 12),
                  Text('Loading stream…',
                      style:
                          TextStyle(color: Colors.white70, fontSize: 12)),
                ],
              ),
            ),
          ),

        if (!_playing && !_playerLoading && _playerError == null)
          Center(
            child: TvFocusable(
              autofocus: true,
              scaleOnFocus: true,
              isCircle: true,
              onActivate: _startPlay,
              child: Container(
                width: 68,
                height: 68,
                decoration: BoxDecoration(
                  color: AppColors.accent.withValues(alpha: 0.9),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.accent.withValues(alpha: 0.4),
                      blurRadius: 20,
                      spreadRadius: 4,
                    ),
                  ],
                ),
                child: const Icon(Icons.play_arrow,
                    color: Colors.white, size: 38),
              ),
            ),
          ),

        if (_playerError != null && !_playerLoading)
          Container(
            color: Colors.black87,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline,
                      color: Colors.redAccent, size: 36),
                  const SizedBox(height: 8),
                  const Text('Stream unavailable',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 12),
                  TvFocusable(
                    scaleOnFocus: true,
                    onActivate: _startPlay,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                      decoration: BoxDecoration(
                        color: AppColors.accent,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.refresh, size: 16, color: Colors.white),
                          SizedBox(width: 8),
                          Text('Retry', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _playerOverlay({
    required ContentItem item,
    required bool isFav,
    required AppState state,
    required bool isFullscreen,
  }) {
    final displayPos = _draggingProgress ? _dragPosition : _position;
    final prog = _duration.inMilliseconds > 0
        ? (displayPos.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    return AnimatedOpacity(
      opacity: _showControls ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 300),
      child: ExcludeFocus(
        excluding: !_showControls,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Full-area tap to show controls
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _showControlsTemporarily,
              ),
            ),

            // Column: top / center / bottom — guaranteed no overlap
            Column(
              children: [
                // ── TOP BAR
                Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0xDD000000), Colors.transparent],
                    ),
                  ),
                  child: SafeArea(
                    bottom: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 6, 8, 20),
                      child: Row(
                        children: [
                          _overlayBtn(
                            icon: Icons.arrow_back,
                            onTap: () {
                              if (isFullscreen) {
                                _toggleFullscreen();
                              } else {
                                _player?.pause();
                                Navigator.of(context).pop();
                              }
                            },
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  item.title,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                if (item.genre != null || item.year != null)
                                  Text(
                                    '${item.year ?? ''} • ${item.genre ?? ''}'.trim(),
                                    style: const TextStyle(
                                        color: Colors.white70, fontSize: 11),
                                  ),
                              ],
                            ),
                          ),
                          if (item.isSeries) ...[
                            const SizedBox(width: 6),
                            _overlayBtn(
                              icon: Icons.skip_next,
                              onTap: _playNextEpisode,
                            ),
                          ],
                          const SizedBox(width: 6),
                          _overlayBtn(
                            icon: isFav ? Icons.favorite : Icons.favorite_border,
                            color: isFav ? AppColors.accent : Colors.white,
                            onTap: () {
                              state.toggleFavorite(item);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(state.isFavorite(item.id)
                                      ? 'Added to My List'
                                      : 'Removed from My List'),
                                  duration: const Duration(seconds: 2),
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

                // ── CENTER CONTROLS (in remaining space above seek bar)
                Expanded(
                  child: Center(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        // -10s
                        GestureDetector(
                          onTap: () {
                            _seekRelative(const Duration(seconds: -10));
                            _showControlsTemporarily();
                          },
                          child: Container(
                            width: 56, height: 56,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.white.withValues(alpha: 0.15),
                              border: Border.all(color: Colors.white30, width: 1),
                            ),
                            child: const Icon(Icons.replay_10,
                                color: Colors.white, size: 30),
                          ),
                        ),
                        const SizedBox(width: 32),
                        // Play/Pause
                        GestureDetector(
                          onTap: () {
                            _togglePlay();
                            _showControlsTemporarily();
                          },
                          child: Container(
                            width: 72, height: 72,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: AppColors.accent,
                              boxShadow: [
                                BoxShadow(
                                  color: AppColors.accent.withValues(alpha: 0.55),
                                  blurRadius: 22,
                                  spreadRadius: 3,
                                ),
                              ],
                            ),
                            child: Icon(
                              _playing ? Icons.pause : Icons.play_arrow,
                              color: Colors.white,
                              size: 40,
                            ),
                          ),
                        ),
                        const SizedBox(width: 32),
                        // +10s
                        GestureDetector(
                          onTap: () {
                            _seekRelative(const Duration(seconds: 10));
                            _showControlsTemporarily();
                          },
                          child: Container(
                            width: 56, height: 56,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.white.withValues(alpha: 0.15),
                              border: Border.all(color: Colors.white30, width: 1),
                            ),
                            child: const Icon(Icons.forward_10,
                                color: Colors.white, size: 30),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // ── BOTTOM: seek bar + optional suggestions
                Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Color(0xF0000000), Colors.transparent],
                    ),
                  ),
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Seek bar row
                      Row(
                        children: [
                          Text(
                            _formatDuration(displayPos),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 10),
                              child: LayoutBuilder(
                                builder: (ctx, box) => GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onHorizontalDragStart: (_) {
                                    setState(() => _draggingProgress = true);
                                    _hideControlsTimer?.cancel();
                                    _hideSuggestionsTimer?.cancel();
                                  },
                                  onHorizontalDragUpdate: (d) {
                                    if (_duration.inMilliseconds <= 0) return;
                                    final f = (d.localPosition.dx / box.maxWidth)
                                        .clamp(0.0, 1.0);
                                    setState(() => _dragPosition = Duration(
                                        milliseconds:
                                            (f * _duration.inMilliseconds).round()));
                                  },
                                  onHorizontalDragEnd: (_) {
                                    _player?.seek(_dragPosition);
                                    setState(() => _draggingProgress = false);
                                    _showControlsTemporarily();
                                  },
                                  onTapDown: (d) {
                                    if (_duration.inMilliseconds <= 0) return;
                                    final f = (d.localPosition.dx / box.maxWidth)
                                        .clamp(0.0, 1.0);
                                    _player?.seek(Duration(
                                        milliseconds:
                                            (f * _duration.inMilliseconds).round()));
                                    _showControlsTemporarily();
                                  },
                                  child: Container(
                                    height: 32,
                                    alignment: Alignment.center,
                                    child: Stack(
                                      alignment: Alignment.centerLeft,
                                      children: [
                                        // Track background
                                        Container(
                                          height: _draggingProgress ? 6 : 4,
                                          width: double.infinity,
                                          decoration: BoxDecoration(
                                            color: Colors.white24,
                                            borderRadius: BorderRadius.circular(4),
                                          ),
                                        ),
                                        // Filled progress
                                        FractionallySizedBox(
                                          widthFactor: prog,
                                          child: Container(
                                            height: _draggingProgress ? 6 : 4,
                                            decoration: BoxDecoration(
                                              color: AppColors.accent,
                                              borderRadius: BorderRadius.circular(4),
                                            ),
                                          ),
                                        ),
                                        // Thumb
                                        if (prog > 0)
                                          Align(
                                            alignment: FractionalOffset(prog, 0.5),
                                            child: Container(
                                              width: _draggingProgress ? 18 : 14,
                                              height: _draggingProgress ? 18 : 14,
                                              decoration: BoxDecoration(
                                                shape: BoxShape.circle,
                                                color: Colors.white,
                                                boxShadow: [
                                                  BoxShadow(
                                                    color: AppColors.accent,
                                                    blurRadius: 6,
                                                    spreadRadius: 1,
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Text(
                            item.isLive && _duration.inMilliseconds == 0
                                ? 'LIVE'
                                : _formatDuration(_duration),
                            style: TextStyle(
                              color: item.isLive && _duration.inMilliseconds == 0
                                  ? AppColors.live
                                  : Colors.white,
                              fontSize: 12,
                              fontWeight:
                                  item.isLive && _duration.inMilliseconds == 0
                                      ? FontWeight.bold
                                      : FontWeight.w500,
                            ),
                          ),
                          const SizedBox(width: 8),
                          GestureDetector(
                            onTap: _toggleFullscreen,
                            child: Container(
                              width: 36, height: 36,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.black.withValues(alpha: 0.55),
                                border: Border.all(
                                    color: Colors.white30, width: 1.5),
                              ),
                              child: Icon(
                                isFullscreen
                                    ? Icons.fullscreen_exit
                                    : Icons.fullscreen,
                                color: Colors.white,
                                size: 18,
                              ),
                            ),
                          ),
                        ],
                      ),
                      // Suggestions (fullscreen only, auto-hide)
                      if (isFullscreen)
                        AnimatedOpacity(
                          opacity: _showSuggestions ? 1.0 : 0.0,
                          duration: const Duration(milliseconds: 400),
                          child: IgnorePointer(
                            ignoring: !_showSuggestions,
                            child: Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: _overlaySuggestions(item),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),

            // Volume indicator (right side)
            Positioned(
              right: 24, top: 0, bottom: 0,
              child: IgnorePointer(
                child: AnimatedOpacity(
                  opacity: _showVolumeBar ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 250),
                  child: Center(
                    child: Container(
                      width: 48, height: 180,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.75),
                        borderRadius: BorderRadius.circular(24),
                      ),
                      padding: const EdgeInsets.all(10),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: RotatedBox(
                                quarterTurns: -1,
                                child: LinearProgressIndicator(
                                  value: (_volume / 100.0).clamp(0.0, 1.0),
                                  backgroundColor: Colors.white24,
                                  valueColor:
                                      const AlwaysStoppedAnimation<Color>(
                                          AppColors.accent),
                                  minHeight: 8,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Icon(
                            _volume == 0 ? Icons.volume_off : Icons.volume_up,
                            color: Colors.white,
                            size: 18,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _overlayBtn({
    required IconData icon,
    required VoidCallback onTap,
    Color color = Colors.white,
  }) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          width: 40, height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.black.withValues(alpha: 0.55),
          ),
          child: Icon(icon, color: color, size: 22),
        ),
      );

  Widget _errorBanner(String msg, {VoidCallback? onRetry}) => Container(
        padding: const EdgeInsets.all(12),
        margin: const EdgeInsets.only(bottom: 16),
        decoration: BoxDecoration(
          color: Colors.red.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.red.withValues(alpha: 0.4)),
        ),
        child: Row(children: [
          const Icon(Icons.error_outline, color: Colors.redAccent, size: 18),
          const SizedBox(width: 10),
          Expanded(
              child: Text(msg,
                  style: const TextStyle(
                      color: Colors.redAccent, fontSize: 12))),
          if (onRetry != null)
            TextButton(
                onPressed: onRetry,
                child: const Text('Retry',
                    style: TextStyle(
                        color: AppColors.accent, fontSize: 12))),
        ]),
      );

  Widget _retryingBanner() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        margin: const EdgeInsets.only(bottom: 16),
        decoration: BoxDecoration(
          color: AppColors.accent.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.accent.withValues(alpha: 0.3)),
        ),
        child: Row(children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(AppColors.accent),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Connecting… retrying in ${_retryCountdown}s (attempt #${_retryCount + 1})',
              style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
            ),
          ),
          TextButton(
            onPressed: () {
              _retryTimer?.cancel();
              setState(() {
                _autoRetrying = false;
                _retryCount = 0;
              });
              _startPlay();
            },
            child: const Text('Now',
                style: TextStyle(color: AppColors.accent, fontSize: 12)),
          ),
        ]),
      );

  Widget _chip(String label) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: AppColors.bg4,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: AppColors.border),
        ),
        child: Text(label,
            style: const TextStyle(
                fontSize: 11, color: AppColors.textSecondary)),
      );

  Widget _metaItem(IconData icon, String text) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: AppColors.textTertiary),
          const SizedBox(width: 4),
          Text(text,
              style: const TextStyle(
                  fontSize: 12, color: AppColors.textTertiary)),
        ],
      );

  Widget _scheduleRow(String label, String title, bool isNow, {VoidCallback? onTap}) {
    if (onTap == null) {
      return Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: isNow ? AppColors.accent.withValues(alpha: 0.1) : AppColors.bg3,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isNow ? AppColors.accent.withValues(alpha: 0.4) : AppColors.border,
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: isNow ? AppColors.accent : AppColors.bg4,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: isNow ? Colors.white : AppColors.textTertiary,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(title, style: const TextStyle(fontSize: 13, color: AppColors.textPrimary))),
          ],
        ),
      );
    }

    return TvFocusable(
      scaleOnFocus: true,
      onActivate: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: isNow ? AppColors.accent.withValues(alpha: 0.1) : AppColors.bg3,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isNow ? AppColors.accent.withValues(alpha: 0.4) : AppColors.border,
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: isNow ? AppColors.accent : AppColors.bg4,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: isNow ? Colors.white : AppColors.textTertiary,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(title, style: const TextStyle(fontSize: 13, color: AppColors.textPrimary))),
            const Icon(Icons.play_circle_outline, color: AppColors.accent, size: 20),
          ],
        ),
      ),
    );
  }

  Widget _relatedRow(ContentItem current) {
    final state = context.read<AppState>();
    List<ContentItem> related;
    if (current.isLive) {
      related = state.channels
          .where(
              (c) => c.id != current.id && c.category == current.category)
          .take(10)
          .toList();
      if (related.length < 3) {
        related = state.channels
            .where((c) => c.id != current.id)
            .take(10)
            .toList();
      }
    } else if (current.isMovie) {
      related = state.movies
          .where(
              (m) => m.id != current.id && m.category == current.category)
          .take(10)
          .toList();
      if (related.length < 3) {
        related = state.movies
            .where((m) => m.id != current.id)
            .take(10)
            .toList();
      }
    } else {
      // Fallback: show more movies
      related = state.movies
          .where((m) => m.id != current.id)
          .take(10)
          .toList();
    }

    if (related.isEmpty) {
      return const SizedBox(
        height: 80,
        child: Center(
          child: Text('No related content',
              style: TextStyle(
                  color: AppColors.textTertiary, fontSize: 12)),
        ),
      );
    }

    return SizedBox(
      height: 190,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: related.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (_, i) => current.isLive
            ? ChannelCard(item: related[i])
            : MediaCard(item: related[i]),
      ),
    );
  }

  Widget _overlaySuggestions(ContentItem current) {
    final state = context.read<AppState>();
    List<ContentItem> related;
    if (current.isLive) {
      related = state.channels
          .where((c) => c.id != current.id && c.category == current.category)
          .take(12)
          .toList();
      if (related.length < 3) {
        related = state.channels
            .where((c) => c.id != current.id)
            .take(12)
            .toList();
      }
    } else if (current.isMovie) {
      related = state.movies
          .where((m) => m.id != current.id && m.category == current.category)
          .take(12)
          .toList();
      if (related.length < 3) {
        related = state.movies
            .where((m) => m.id != current.id)
            .take(12)
            .toList();
      }
    } else {
      // Fallback: show more movies
      related = state.movies
          .where((m) => m.id != current.id)
          .take(12)
          .toList();
    }

    if (related.isEmpty) return const SizedBox.shrink();

    final isLive = current.isLive;
    final listHeight = isLive ? 122.0 : 160.0;
    final titleText = isLive
        ? 'Suggested Channels'
        : current.isMovie
            ? 'More Movies'
            : 'More Like This';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            titleText,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.bold,
              fontFamily: 'Inter',
            ),
          ),
        ),
        SizedBox(
          height: listHeight,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: related.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (ctx, i) {
              final item = related[i];
              if (isLive) {
                return SizedBox(
                  width: 145,
                  child: ChannelCard(
                    item: item,
                    onTap: () {
                      _player?.pause();
                      Navigator.pushReplacement(
                        context,
                        MaterialPageRoute(builder: (_) => DetailScreen(item: item)),
                      );
                    },
                  ),
                );
              } else {
                return SizedBox(
                  width: 95,
                  child: MediaCard(
                    item: item,
                    onTap: () {
                      _player?.pause();
                      Navigator.pushReplacement(
                        context,
                        MaterialPageRoute(builder: (_) => DetailScreen(item: item)),
                      );
                    },
                  ),
                );
              }
            },
          ),
        ),
      ],
    );
  }

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}
