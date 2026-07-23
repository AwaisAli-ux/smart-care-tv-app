import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../core/player/player_ui_state.dart';
import '../core/player/safe_dispose.dart';
import '../core/widgets/tv_safe_area.dart';
import '../models/content_model.dart';
import '../theme/app_theme.dart';
import '../widgets/speed_picker.dart';
import '../services/app_state.dart';
import '../services/iptv_service.dart';
import '../services/device_profile_service.dart';
import '../services/player_factory.dart';

const _epAudioCh = MethodChannel('com.smartcaretv.app/audio');

enum _EZone {
  back,
  cast,
  lock,
  fav,
  settings,
  brightness,
  replay,
  play,
  forward,
  volume,
  progress,
  episodesList,
  aspectRatio,
  speed,
  subtitles,
  suggestions,
  nextEpisode,
  retry
}

/// Full-screen episode player — 100% identical UI to MoviePlayerScreen
/// but resolves episode stream URLs and shows series episodes as suggestions.
class EpisodePlayerScreen extends StatefulWidget {
  final ContentItem series;      // the parent series ContentItem
  final EpisodeInfo episode;     // the episode to play
  final List<EpisodeInfo> allEpisodes; // all episodes for suggestions

  const EpisodePlayerScreen({
    super.key,
    required this.series,
    required this.episode,
    required this.allEpisodes,
  });

  @override
  State<EpisodePlayerScreen> createState() => _EpisodePlayerScreenState();
}

class _EpisodePlayerScreenState extends State<EpisodePlayerScreen> {
  Player? _player;
  VideoController? _videoCtrl;
  BoxFit _videoFit = BoxFit.contain;
  bool _disposed = false;
  bool _exiting = false;

  bool _loading = true;
  bool _autoRetrying = false;
  bool _streamDead = false;
  int  _retryCountdown = 0;
  int  _attemptNumber  = 0;
  static const int _maxAttempts = 5;
  Timer? _retryTimer;

  late EpisodeInfo _currentEp;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;

  double _brightness = 1.0;
  bool _controlsLocked = false;
  double _playbackSpeed = 1.0;

  double _volume = 100.0;
  bool _showVolumeBar = false;
  Timer? _hideVolumeTimer;

  bool   _showOverlay = true;
  Timer? _hideTimer;

  bool     _draggingProgress = false;
  Duration _dragPosition     = Duration.zero;
  DateTime? _lastSeekTime;

  _EZone _zone = _EZone.play;
  int    _suggestionIdx = 0;
  List<EpisodeInfo> _suggestions = [];
  final ScrollController _suggScroll = ScrollController();

  StreamSubscription? _completedSub;
  StreamSubscription? _positionSub;
  StreamSubscription? _durationSub;
  StreamSubscription? _playingSub;
  StreamSubscription? _bufferingSub; // FIX #6
  StreamSubscription? _widthSub;     // FIX #6

  // ── FIX #6: play/pause button doubles as the loader ──────────────────────
  bool _buffering = false;
  bool _firstFrame = false;
  PlayerUiState _uiState = PlayerUiState.loading;

  /// Rebuilds only when the button state actually changed, so this never adds
  /// a rebuild to the position tick.
  void _syncUiState() {
    if (!mounted) return;
    final next = resolvePlayerUiState(
      hasError: _streamDead,
      isLoading: _loading || _autoRetrying,
      // Any sign of life counts, not just a decoded-frame report: some
      // sources never emit stream.width, and gating on it alone left the
      // spinner up forever.
      hasFirstFrame: _firstFrame ||
          _playing ||
          _duration.inMilliseconds > 0 ||
          _position.inMilliseconds > 0,
      isBuffering: _buffering,
      isPlaying: _playing,
    );
    if (next == _uiState) return;
    setState(() => _uiState = next);
  }

  // ── ANR watchdog — cancelled as soon as playback starts ──────────────────
  Timer? _watchdogTimer;

  // Prevents the watchdog/retry timers from firing a second, overlapping
  // _startPlay() while a previous probe is still in flight.
  bool _startingPlay = false;

  final FocusNode _focus = FocusNode(debugLabel: 'EpisodePlayer');

  int _failoverLevel = 0;

  DeviceProfile? _deviceProfile;
  DeviceProfile get _profile =>
      _deviceProfile ?? DeviceProfileService.instance.currentProfile;

  Map<String, String> get _streamHeaders => _profile.streamHeaders;

  @override
  void initState() {
    super.initState();
    _currentEp = widget.episode;
    _focus.addListener(_onFocusChange);
    // Fire-and-forget — see channel_player_screen.dart's initState() for why:
    // awaiting the orientation+immersive-mode transition before playback
    // doesn't avoid the ANR (confirmed the transition itself can take 5+
    // seconds on the Android side regardless), it just delays screen entry.
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _deviceProfile = context.read<AppState>().deviceProfile;
        _focus.requestFocus();
        _buildSuggestions();
        _startPlay();
      }
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _focus.removeListener(_onFocusChange);
    _hideTimer?.cancel();
    _retryTimer?.cancel();
    _hideVolumeTimer?.cancel();
    _watchdogTimer?.cancel();
    _suggScroll.dispose();
    _focus.dispose();
    _completedSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _playingSub?.cancel();
    _bufferingSub?.cancel(); // FIX #6
    _widthSub?.cancel();     // FIX #6
    final p = _player;
    _player = null;
    if (p != null) {
      // Ordered teardown — see core/player/safe_dispose.dart. Disposing while
      // stop() is still running natively aborts the whole process.
      Future.microtask(() => safeDisposePlayer(p));
    }
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual,
        overlays: SystemUiOverlay.values);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    super.dispose();
  }

  /// Safely stop player and exit screen — prevents crash from race conditions
  Future<void> _safeExit() async {
    if (_exiting) return;
    _exiting = true;
    if (mounted) {
      setState(() {
        _videoCtrl = null;
      });
    }
    await Future.delayed(const Duration(milliseconds: 100));
    try {
      _hideTimer?.cancel();
      _retryTimer?.cancel();
      _completedSub?.cancel();
      _positionSub?.cancel();
      _durationSub?.cancel();
      _playingSub?.cancel();
    _bufferingSub?.cancel(); // FIX #6
    _widthSub?.cancel();     // FIX #6
      final p = _player;
      _player = null;
      await safeDisposePlayer(p);
    } catch (_) {}
    if (mounted) Navigator.of(context).pop();
  }

  void _onFocusChange() {
    if (mounted && !_focus.hasFocus) {
      final route = ModalRoute.of(context);
      if (route != null && route.isCurrent) _focus.requestFocus();
    }
  }

  // ── Build episode suggestions ─────────────────────────────────────────────
  void _buildSuggestions() {
    final all = widget.allEpisodes;
    final curIdx = all.indexWhere((e) => e.streamId == _currentEp.streamId);
    final List<EpisodeInfo> sugg = [];
    // Show next episodes first, then wrap around
    if (curIdx != -1) {
      for (int i = 1; i <= all.length - 1 && sugg.length < 20; i++) {
        sugg.add(all[(curIdx + i) % all.length]);
      }
    } else {
      sugg.addAll(all.take(20));
    }
    setState(() => _suggestions = sugg);
  }

  // ── Audio ─────────────────────────────────────────────────────────────────
  Future<void> _requestAudio() async {
    try { await _epAudioCh.invokeMethod('requestAudioFocus'); } catch (_) {}
  }

  Future<void> _volumeUp() async {
    final v = (_volume + 10).clamp(0.0, 100.0);
    _volume = v;
    await _player?.setVolume(v);
    _showVolumeBarBriefly();
  }

  Future<void> _volumeDown() async {
    final v = (_volume - 10).clamp(0.0, 100.0);
    _volume = v;
    await _player?.setVolume(v);
    _showVolumeBarBriefly();
  }

  void _showVolumeBarBriefly() {
    if (!mounted) return;
    setState(() => _showVolumeBar = true);
    _hideVolumeTimer?.cancel();
    _hideVolumeTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showVolumeBar = false);
    });
    _showOverlayFor4s();
  }

  void _showOverlayFor4s({_EZone? zone}) {
    if (!mounted) return;
    setState(() {
      _showOverlay = true;
      _zone = zone ?? (_controlsLocked ? _EZone.lock : _EZone.play);
    });
    if (_player != null) {
      setState(() {
        final now = DateTime.now();
        if (_lastSeekTime == null || now.difference(_lastSeekTime!) > const Duration(milliseconds: 800)) {
          _position = _player!.state.position;
        }
        _duration = _player!.state.duration;
        _playing  = _player!.state.playing;
      });
    }
    _resetHideTimer();
  }

  void _resetHideTimer() {
    _hideTimer?.cancel();
    if (!_playing) return;
    _hideTimer = Timer(const Duration(seconds: 6), () {
      if (mounted && !_loading && !_autoRetrying) {
        setState(() => _showOverlay = false);
        _focus.requestFocus();
      }
    });
  }

  // ── Build episode stream URLs ─────────────────────────────────────────────
  List<String> _episodeUrls(AppState state) {
    final u  = state.username;
    final pw = state.password;
    final ep = _currentEp;
    return [
      if (ep.directSource != null && ep.directSource!.isNotEmpty) ep.directSource!,
      IptvService.getSeriesStreamUrl(u, pw, ep.streamPath),
      '${IptvService.baseUrl}/movie/$u/$pw/${ep.streamId}.${ep.ext}',
      if (ep.ext != 'mp4') '${IptvService.baseUrl}/movie/$u/$pw/${ep.streamId}.mp4',
      if (ep.ext != 'mkv') '${IptvService.baseUrl}/movie/$u/$pw/${ep.streamId}.mkv',
      if (ep.ext != 'ts')  '${IptvService.baseUrl}/movie/$u/$pw/${ep.streamId}.ts',
      '${IptvService.baseUrl}/series/$u/$pw/${ep.streamId}',
    ];
  }

  // ── Playback ──────────────────────────────────────────────────────────────
  Future<void> _startPlay() async {
    if (!mounted || _startingPlay) return;
    _startingPlay = true;

    final appState = context.read<AppState>();
    final hwAccel  = appState.hardwareAccelEnabled;
    final bufBytes = appState.bufferBytes;
    final profile  = _profile;

    setState(() {
      _loading      = true;
      _autoRetrying = false;
      _streamDead   = false;
      _position     = Duration.zero;
      _duration     = Duration.zero;
      _playing      = false;
      _buffering    = false; // FIX #6
      _firstFrame   = false; // FIX #6 — a restart has no frame yet
    });
    _syncUiState(); // FIX #6

    _completedSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _playingSub?.cancel();
    _bufferingSub?.cancel(); // FIX #6
    _widthSub?.cancel();     // FIX #6
    
    final playerToDispose = _player;
    if (playerToDispose != null) {
      Future.microtask(() async {
        try {
          await playerToDispose.pause().timeout(const Duration(seconds: 3));
          await playerToDispose.stop().timeout(const Duration(seconds: 3));
          await playerToDispose.dispose().timeout(const Duration(seconds: 3));
        } catch (_) {}
      });
    }
    
    _videoCtrl = null;
    _player    = null;

    // 30-second overall watchdog
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer(const Duration(seconds: 30), () {
      if (!mounted) return;
      debugPrint('⏱ [Episode] 30s watchdog fired');
      _scheduleRetry();
    });

    try {
      // Audio focus is best-effort and takes up to 2 s on some boxes; awaiting
      // it here just delayed the first frame by that much. Fire and forget.
      unawaited(_requestAudio());
      final urls = _episodeUrls(appState);

      // PlayerFactory handles player creation, concurrent property setting
      // (no sequential awaits = no ANR), and stream probing.
      // lastFailureWasPermanent is reset inside probe() on every call.
      final result = await PlayerFactory.probe(
        urls: urls,
        bufBytes: bufBytes,
        hwAccel: hwAccel,
        profile: profile,
        streamHeaders: _streamHeaders,
        isLive: false,
        probeTimeout: const Duration(seconds: 15),
      );

      if (result == null) throw Exception('All episode URLs failed');
      if (!mounted) { result.player.dispose(); return; }

      _player    = result.player;
      _videoCtrl = result.controller;
      await result.player.setVolume(_volume);

      _completedSub = result.player.stream.completed.listen((done) {
        if (done && mounted) setState(() { _position = _duration; });
      });
      _positionSub = result.player.stream.position.listen((p) {
        if (mounted && _showOverlay) {
          final now = DateTime.now();
          if (_lastSeekTime == null || now.difference(_lastSeekTime!) > const Duration(milliseconds: 800)) {
            setState(() => _position = p);
          }
        }
      });
      _durationSub = result.player.stream.duration.listen((d) {
        if (mounted) setState(() => _duration = d);
          _syncUiState(); // duration is a sign of life too
      });
      _playingSub = result.player.stream.playing.listen((p) {
        if (mounted) {
          setState(() {
            _playing = p;
            if (p) { _resetHideTimer(); } else { _hideTimer?.cancel(); _showOverlay = true; }
          });
          _syncUiState(); // FIX #6
        }
      });

      // FIX #6 — mid-playback stalls were previously invisible; nothing
      // subscribed to buffering.
      _bufferingSub = result.player.stream.buffering.listen((b) {
        if (!mounted) return;
        _buffering = b;
        _syncUiState();
      });

      // FIX #6 — until the first frame decodes there is nothing to pause.
      _widthSub = result.player.stream.width.listen((w) {
        if (!mounted) return;
        if (w != null && w > 0 && !_firstFrame) {
          _firstFrame = true;
          _syncUiState();
        }
      });

      _watchdogTimer?.cancel();
      _watchdogTimer = null;
      _startingPlay = false;
      if (!mounted) return;
      setState(() => _loading = false);
      _syncUiState(); // FIX #6
      _showOverlayFor4s();
      await _requestAudio();
    } catch (e) {
      debugPrint('❌ [EpisodePlayer] $e');
      _startingPlay = false;
      if (!mounted) return;
      _scheduleRetry();
    }
  }

  void _scheduleRetry() {
    _retryTimer?.cancel();

    // The provider answered "not there" on every candidate URL. That is
    // permanent, so skip the whole retry/failover cycle and tell the user
    // straight away instead of spinning for two minutes.
    if (PlayerFactory.lastFailureWasPermanent) {
      if (mounted) {
        setState(() {
          _autoRetrying = false;
          _loading      = false;
          _streamDead   = true;
        });
        _syncUiState();
      }
      return;
    }

    _attemptNumber++;
    if (_attemptNumber > _maxAttempts) {
      if (_failoverLevel < 2) {
        _failoverLevel++;
        _attemptNumber = 0;
        setState(() { _autoRetrying = false; _loading = false; });
        _startPlay();
        return;
      }
      if (mounted) {
        setState(() { _autoRetrying = false; _loading = false; _streamDead = true; _zone = _EZone.retry; });
        _syncUiState(); // FIX #6 — button becomes a retry icon
      }
      return;
    }
    setState(() { _autoRetrying = true; _loading = false; _retryCountdown = 5; });
    _syncUiState(); // FIX #6
    _retryTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      setState(() => _retryCountdown--);
      if (_retryCountdown <= 0) {
        t.cancel();
        setState(() => _autoRetrying = false);
        _startPlay();
      }
    });
  }

  bool _isNonFatalError(String err) {
    final l = err.toLowerCase();
    return l.contains('subtitle') || l.contains('unsupported tag') ||
        l.contains('skipping') || l.contains('audio track') ||
        l.startsWith('warning:') || l.contains('[warning]') ||
        l.contains('demuxer cache') || l.contains('cache is full') ||
        l.contains('cache underrun') || l.contains('video codec') ||
        l.contains('audio codec') || l.contains('selected video') ||
        l.contains('selected audio') || l.contains('pts') ||
        l.contains('dts') || l == 'eof' || l.startsWith('eof ');
  }

  String _fmt(Duration d) {
    final h  = d.inHours;
    final mm = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  void _seekTo(Duration t) {
    if (_player == null) return;
    final c = t < Duration.zero ? Duration.zero : (t > _duration ? _duration : t);
    setState(() {
      _position = c;
      _lastSeekTime = DateTime.now();
    });
    _player!.seek(c);
  }

  void _togglePlay() {
    if (_player == null) return;
    _player!.playOrPause();
    setState(() => _playing = _player!.state.playing);
    _syncUiState(); // FIX #6
    _resetHideTimer();
  }

  // ── Switch to a different episode ─────────────────────────────────────────
  void _switchEpisode(EpisodeInfo ep) {
    setState(() {
      _currentEp    = ep;
      _failoverLevel = 0;
      _attemptNumber = 0;
    });
    _buildSuggestions();
    _startPlay();
  }

  // ── TV D-pad navigation ───────────────────────────────────────────────────
  void _activateZone() {
    if (_controlsLocked && _zone != _EZone.lock) { _showOverlayFor4s(); return; }
    switch (_zone) {
      case _EZone.back:
        _safeExit();
        break;
      case _EZone.lock:
        setState(() => _controlsLocked = !_controlsLocked);
      case _EZone.fav:
        final s = context.read<AppState>();
        s.toggleFavorite(widget.series);
      case _EZone.settings:
        _showSettingsMenu();
      case _EZone.replay:
        if (_player != null) _seekTo(_player!.state.position - const Duration(seconds: 10));
        _showOverlayFor4s();
      case _EZone.play:
        _togglePlay();
        _showOverlayFor4s();
      case _EZone.forward:
        if (_player != null) _seekTo(_player!.state.position + const Duration(seconds: 10));
        _showOverlayFor4s();
      case _EZone.progress:
        _showOverlayFor4s();
      case _EZone.episodesList:
        _showEpisodesMenu();
      case _EZone.aspectRatio:
        _showAspectMenu();
      case _EZone.speed:
        _showSpeedMenu();
      case _EZone.subtitles:
        _showSubtitlesInfo();
      case _EZone.nextEpisode:
        _playNextEpisode();
      default:
        _showOverlayFor4s();
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = event.logicalKey;

    if (k == LogicalKeyboardKey.audioVolumeUp)   { _volumeUp();   return KeyEventResult.handled; }
    if (k == LogicalKeyboardKey.audioVolumeDown) { _volumeDown(); return KeyEventResult.handled; }

    // Dead stream: only the Retry action (and Back, to exit) is reachable —
    // this button lives outside the overlay/zone grid entirely.
    if (_streamDead) {
      final isRetrySelect = k == LogicalKeyboardKey.select ||
          k == LogicalKeyboardKey.enter ||
          k == LogicalKeyboardKey.gameButtonA ||
          k == LogicalKeyboardKey.numpadEnter ||
          k.keyId == 13 || k.keyId == 23 || k.keyId == 96 || k.keyId == 160;
      final isRetryBack = k == LogicalKeyboardKey.goBack ||
          k == LogicalKeyboardKey.escape ||
          k.keyId == 0x1000000a6 || k.keyId == 166 || k.keyId == 8;
      if (isRetrySelect) { _retryDeadStream(); return KeyEventResult.handled; }
      if (isRetryBack)   { _safeExit();        return KeyEventResult.handled; }
      return KeyEventResult.handled;
    }

    if (_showOverlay) _resetHideTimer();

    // Dedicated media seek keys — jump 1 min (60 seconds). Ignored while locked.
    final isMediaLeft = k == LogicalKeyboardKey.mediaRewind || k == LogicalKeyboardKey.mediaTrackPrevious;
    final isMediaRight = k == LogicalKeyboardKey.mediaFastForward || k == LogicalKeyboardKey.mediaTrackNext;
    if (isMediaLeft || isMediaRight) {
      if (!_controlsLocked && _player != null) {
        _seekTo(_player!.state.position + (isMediaLeft ? -const Duration(seconds: 60) : const Duration(seconds: 60)));
        _showOverlayFor4s();
      }
      return KeyEventResult.handled;
    }

    final isBack = k == LogicalKeyboardKey.goBack ||
        k == LogicalKeyboardKey.escape ||
        k.keyId == 0x1000000a6 || k.keyId == 166 || k.keyId == 8;
    if (isBack) {
      if (_showOverlay) {
        if (!_controlsLocked) {
          setState(() => _showOverlay = false);
        }
      } else {
        _safeExit();
      }
      return KeyEventResult.handled;
    }

    if (k == LogicalKeyboardKey.mediaPlayPause ||
        k == LogicalKeyboardKey.mediaPlay ||
        k == LogicalKeyboardKey.mediaPause) {
      if (!_controlsLocked) {
        _togglePlay();
        _showOverlayFor4s();
      }
      return KeyEventResult.handled;
    }

    // Any key while overlay hidden → reveal overlay (and act on seek arrows) first.
    if (!_showOverlay) {
      final isSeekLeft = k == LogicalKeyboardKey.arrowLeft;
      final isSeekRight = k == LogicalKeyboardKey.arrowRight;
      _showOverlayFor4s(
        zone: _controlsLocked
            ? _EZone.lock
            : (isSeekLeft ? _EZone.replay : (isSeekRight ? _EZone.forward : _EZone.play)),
      );
      if (!_controlsLocked && _player != null) {
        if (isSeekLeft) _seekTo(_player!.state.position - const Duration(seconds: 10));
        if (isSeekRight) _seekTo(_player!.state.position + const Duration(seconds: 10));
      }
      return KeyEventResult.handled;
    }

    // "OK"/select — accept every keycode TV remotes/gamepads commonly send for it.
    final isSelect = k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.gameButtonA ||
        k == LogicalKeyboardKey.numpadEnter ||
        k.keyId == 13 || k.keyId == 23 || k.keyId == 96 || k.keyId == 160;

    // While locked, only the lock button itself is reachable/activatable.
    if (_controlsLocked) {
      if (isSelect) {
        if (_zone == _EZone.lock) _activateZone();
        return KeyEventResult.handled;
      }
      setState(() => _zone = _EZone.lock);
      return KeyEventResult.handled;
    }

    if (isSelect) {
      _activateZone();
      return KeyEventResult.handled;
    }

    // D-pad navigation between zones
    if (k == LogicalKeyboardKey.arrowLeft) {
      _navigateZoneH(-1);
      _showOverlayFor4s(zone: _zone);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight) {
      _navigateZoneH(1);
      _showOverlayFor4s(zone: _zone);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp) {
      _navigateZoneV(-1);
      _showOverlayFor4s(zone: _zone);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown) {
      _navigateZoneV(1);
      _showOverlayFor4s(zone: _zone);
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  void _navigateZoneH(int dir) {
    switch (_zone) {
      case _EZone.back:     if (dir > 0) setState(() => _zone = _EZone.lock); break;
      case _EZone.lock:     setState(() => _zone = dir > 0 ? _EZone.fav : _EZone.back); break;
      case _EZone.fav:      setState(() => _zone = dir > 0 ? _EZone.settings : _EZone.lock); break;
      case _EZone.settings: if (dir < 0) setState(() => _zone = _EZone.fav); break;
      case _EZone.replay:  if (dir > 0) setState(() => _zone = _EZone.play); break;
      case _EZone.play:    setState(() => _zone = dir > 0 ? _EZone.forward : _EZone.replay); break;
      case _EZone.forward: if (dir < 0) setState(() => _zone = _EZone.play); break;
      case _EZone.progress:
        if (_player != null) {
          final target = _player!.state.position + (dir > 0 ? const Duration(minutes: 1) : -const Duration(minutes: 1));
          _seekTo(target);
        }
        break;
      case _EZone.episodesList: if (dir > 0) setState(() => _zone = _EZone.aspectRatio); break;
      case _EZone.aspectRatio: setState(() => _zone = dir > 0 ? _EZone.speed : _EZone.episodesList); break;
      case _EZone.speed:       setState(() => _zone = dir > 0 ? _EZone.subtitles : _EZone.aspectRatio); break;
      case _EZone.subtitles:   setState(() => _zone = dir > 0 ? _EZone.nextEpisode : _EZone.speed); break;
      case _EZone.nextEpisode: if (dir < 0) setState(() => _zone = _EZone.subtitles); break;
      default: break;
    }
  }

  void _navigateZoneV(int dir) {
    // Up row: back/lock/fav/settings  →  Middle: replay/play/forward  →  Bottom: progress/aspectRatio/speed/subtitles
    if (dir > 0) {
      switch (_zone) {
        case _EZone.back:       setState(() => _zone = _EZone.replay); break;
        case _EZone.lock:       setState(() => _zone = _EZone.play); break;
        case _EZone.fav:        setState(() => _zone = _EZone.forward); break;
        case _EZone.settings:   setState(() => _zone = _EZone.forward); break;
        case _EZone.replay:
        case _EZone.play:
        case _EZone.forward:    setState(() => _zone = _EZone.progress); break;
        case _EZone.progress:   setState(() => _zone = _EZone.episodesList); break;
        default: break;
      }
    } else {
      switch (_zone) {
        case _EZone.episodesList:
        case _EZone.aspectRatio:
        case _EZone.speed:
        case _EZone.subtitles:
        case _EZone.nextEpisode:  setState(() => _zone = _EZone.progress); break;
        case _EZone.progress:   setState(() => _zone = _EZone.play); break;
        case _EZone.replay:     setState(() => _zone = _EZone.back); break;
        case _EZone.play:       setState(() => _zone = _EZone.lock); break;
        case _EZone.forward:    setState(() => _zone = _EZone.fav); break;
        default: break;
      }
    }
  }

  void _scrollToSuggestion(int idx) {
    if (!_suggScroll.hasClients) return;
    _suggScroll.animateTo(
      idx * 92.0,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  void _showEpisodesMenu() {
    _showOverlayFor4s();
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.bg2,
      isScrollControlled: true,
      builder: (context) {
        return Container(
          height: MediaQuery.of(context).size.height * 0.6,
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text(
                  'Episodes',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const Divider(color: Colors.white10),
              Expanded(
                child: ListView.builder(
                  itemCount: widget.allEpisodes.length,
                  itemBuilder: (context, index) {
                    final ep = widget.allEpisodes[index];
                    final isCurrent = ep.streamId == _currentEp.streamId;
                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: ep.thumbnail != null && ep.thumbnail!.isNotEmpty
                            ? CachedNetworkImage(
                                imageUrl: ep.thumbnail!,
                                width: 80,
                                height: 45,
                                fit: BoxFit.cover,
                                placeholder: (context, url) => Container(
                                  width: 80,
                                  height: 45,
                                  color: Colors.white10,
                                  child: const Center(
                                    child: SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 1.5,
                                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white30),
                                      ),
                                    ),
                                  ),
                                ),
                                errorWidget: (context, url, error) => Container(
                                  width: 80,
                                  height: 45,
                                  color: Colors.white10,
                                  child: const Icon(Icons.movie_outlined, color: Colors.white30, size: 18),
                                ),
                              )
                            : Container(
                                width: 80,
                                height: 45,
                                color: Colors.white10,
                                child: const Icon(Icons.movie_outlined, color: Colors.white30, size: 18),
                              ),
                      ),
                      title: Text(
                        'E${ep.episodeNum}: ${ep.title}',
                        style: TextStyle(
                          color: isCurrent ? AppColors.accent : Colors.white,
                          fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                          fontSize: 14,
                        ),
                      ),
                      trailing: isCurrent
                          ? const Icon(Icons.play_circle_fill, color: AppColors.accent, size: 20)
                          : null,
                      onTap: () {
                        Navigator.pop(context);
                        _switchEpisode(ep);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _playNextEpisode() {
    final all = widget.allEpisodes;
    final curIdx = all.indexWhere((e) => e.streamId == _currentEp.streamId);
    if (curIdx != -1 && curIdx < all.length - 1) {
      _switchEpisode(all[curIdx + 1]);
      _showOverlayFor4s();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This is the last episode'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  void _showSettingsMenu() {
    _hideTimer?.cancel();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black.withOpacity(0.95),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (context) {
        return Container(
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Stream Details', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              _settingsRow('Resolution', _player?.state.width != null && _player!.state.width! > 0 ? '${_player!.state.width}x${_player!.state.height}' : 'Auto/Detecting'),
              _settingsRow('Device Profile', '${_profile.brand} ${_profile.model} (${_profile.deviceId})'),
              _settingsRow('Failover quality tier', _failoverLevel == 0 ? 'Original' : _failoverLevel == 1 ? 'Medium Fallback' : 'Lowest Fallback'),
              _settingsRow('Audio Focus State', 'Acquired'),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    ).then((_) => _resetHideTimer());
  }

  Widget _settingsRow(String label, String val) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.white70, fontSize: 14)),
          Text(val, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  void _showAspectMenu() {
    _showOverlayFor4s();
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.bg2,
      builder: (_) => _aspectSheet(),
    );
  }

  Widget _aspectSheet() {
    final fits = [
      ('Contain', BoxFit.contain),
      ('Fill', BoxFit.fill),
      ('Cover', BoxFit.cover),
      ('Fit Width', BoxFit.fitWidth),
      ('Fit Height', BoxFit.fitHeight),
    ];
    return ListView(
      shrinkWrap: true,
      children: fits.map((f) => ListTile(
        focusColor: Colors.white24,
        title: Text(f.$1, style: const TextStyle(color: Colors.white)),
        trailing: _videoFit == f.$2 ? const Icon(Icons.check, color: AppColors.accent) : null,
        onTap: () { setState(() => _videoFit = f.$2); Navigator.pop(context); },
      )).toList(),
    );
  }

  // FIX #10 — see MoviePlayerScreen: the old bottom sheet was unreachable by
  // remote. Shared D-pad picker, same behaviour in both players.
  Future<void> _showSpeedMenu() async {
    _showOverlayFor4s();
    final picked = await showSpeedPicker(context, current: _playbackSpeed);
    if (!mounted) return;
    // null = backed out; leave the speed untouched.
    if (picked != null && picked != _playbackSpeed) {
      setState(() => _playbackSpeed = picked);
      await _player?.setRate(picked);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Speed ${picked}x'), // FIX #10 (item 4)
            duration: const Duration(milliseconds: 1200),
            backgroundColor: Colors.black87,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  void _retryDeadStream() {
    setState(() { _streamDead = false; _attemptNumber = 0; _failoverLevel = 0; });
    _startPlay();
  }

  void _showSubtitlesInfo() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Subtitles not available for this stream'), duration: Duration(seconds: 2)),
    );
  }

  // ── UI ────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _safeExit();
      },
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Scaffold(
        backgroundColor: Colors.black,
        body: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            if (_showOverlay) {
              _hideTimer?.cancel();
              setState(() => _showOverlay = false);
            } else {
              _showOverlayFor4s();
            }
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              // ── VIDEO or OPAQUE LOADING SCREEN ─────────────────────────
              // IMPORTANT: During loading, show a fully opaque black screen so
              // the home screen never bleeds through behind the player.
              if (_videoCtrl != null && !_loading)
                Video(
                  controller: _videoCtrl!,
                  controls: NoVideoControls,
                  fit: _videoFit,
                )
              else
                Container(
                  color: Colors.black,
                ),

              // ── Overlay ──
              if (_showOverlay) _buildOverlay(context.read<AppState>()),

              // Fullscreen loading spinner removed

              // ── Dead stream ──
              if (_streamDead)
                _buildDeadScreen(),
            ],
          ),
        ),
      ),
    ),
   );
  }

  Widget _buildDeadScreen() => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.signal_wifi_bad, color: Colors.white54, size: 64),
        const SizedBox(height: 16),
        const Text('Stream unavailable', style: TextStyle(color: Colors.white, fontSize: 18)),
        const SizedBox(height: 24),
        Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white, width: 2),
          ),
          child: ElevatedButton.icon(
            onPressed: _retryDeadStream,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent),
          ),
        ),
      ],
    ),
  );

  Widget _buildOverlay(AppState state) {
    final isFav = state.isFavorite(widget.series.id);
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xCC000000), Colors.transparent, Colors.transparent, Color(0xCC000000)],
          stops: [0.0, 0.25, 0.70, 1.0],
        ),
      ),
      // FIX #12: gradient stays full-bleed; only the controls move
      // inside the overscan margin.
      child: TvSafeArea(
      child: Stack(
        children: [
          // ── TOP BAR ──
          Positioned(
            top: 0, left: 0, right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    _circleBtn(
                      zone: _EZone.back,
                      size: 44,
                      icon: const Icon(Icons.arrow_back, color: Colors.white, size: 22),
                      onTap: () { _safeExit(); },
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.series.title,
                            style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            'S${_currentEp.seasonNum}:E${_currentEp.episodeNum}  •  ${_currentEp.title}',
                            style: const TextStyle(color: Colors.white70, fontSize: 12),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    _circleBtn(
                      zone: _EZone.lock,
                      size: 40,
                      icon: Icon(_controlsLocked ? Icons.lock : Icons.lock_open_outlined, color: Colors.white, size: 20),
                    ),
                    const SizedBox(width: 8),
                    _circleBtn(
                      zone: _EZone.fav,
                      size: 40,
                      icon: Icon(isFav ? Icons.favorite : Icons.favorite_border, color: Colors.white, size: 20),
                    ),
                    const SizedBox(width: 8),
                    _circleBtn(
                      zone: _EZone.settings,
                      size: 40,
                      icon: const Icon(Icons.settings_outlined, color: Colors.white, size: 20),
                    ),
                  ],
                ),
              ),
            ),
          ),



           // ── CENTER CONTROLS ──
          if (!_controlsLocked && !_streamDead)
            Positioned.fill(
              child: Center(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () { if (_player != null) _seekTo(_player!.state.position - const Duration(seconds: 10)); _showOverlayFor4s(); },
                      child: _circleBtn(zone: _EZone.replay, size: 56, icon: const Icon(Icons.replay_10, color: Colors.white, size: 32), hasBg: false),
                    ),
                    const SizedBox(width: 32),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () { _togglePlay(); _showOverlayFor4s(); },
                      child: _circleBtn(
                        zone: _EZone.play, size: 72,
                        // FIX #6 — single state-driven glyph, cross-faded.
                        icon: playPauseGlyph(_uiState),
                        hasBg: false,
                      ),
                    ),
                    const SizedBox(width: 32),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () { if (_player != null) _seekTo(_player!.state.position + const Duration(seconds: 10)); _showOverlayFor4s(); },
                      child: _circleBtn(zone: _EZone.forward, size: 56, icon: const Icon(Icons.forward_10, color: Colors.white, size: 32), hasBg: false),
                    ),
                  ],
                ),
              ),
            ),

          // ── BOTTOM BAR: seekbar + actions + episode suggestions ──
          if (!_controlsLocked)
            Positioned(
              bottom: 0, left: 60, right: 60,
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Seek bar
                    Row(
                      children: [
                        Text(_fmt(_draggingProgress ? _dragPosition : _position),
                            style: const TextStyle(color: Colors.white70, fontSize: 12)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: LayoutBuilder(builder: (ctx, constraints) {
                            final bw = constraints.maxWidth;
                            final pct = _duration.inMilliseconds > 0
                                ? ((_draggingProgress ? _dragPosition : _position).inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0)
                                : 0.0;
                            final focused = _zone == _EZone.progress;

                            Duration dxToPos(double dx) {
                              if (_duration.inMilliseconds == 0) return Duration.zero;
                              return Duration(milliseconds: ((dx / bw).clamp(0.0, 1.0) * _duration.inMilliseconds).toInt());
                            }

                            return GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTapDown: (d) {
                                if (_duration.inMilliseconds == 0) return;
                                final t = dxToPos(d.localPosition.dx);
                                setState(() { _draggingProgress = true; _dragPosition = t; });
                                _seekTo(t);
                              },
                              onTapUp: (_) { setState(() => _draggingProgress = false); _showOverlayFor4s(); },
                              onTapCancel: () => setState(() => _draggingProgress = false),
                              onHorizontalDragStart: (d) {
                                _hideTimer?.cancel();
                                setState(() { _draggingProgress = true; _dragPosition = dxToPos(d.localPosition.dx); });
                              },
                              onHorizontalDragUpdate: (d) {
                                if (_duration.inMilliseconds == 0) return;
                                setState(() => _dragPosition = dxToPos(d.localPosition.dx));
                              },
                              onHorizontalDragEnd: (_) {
                                _seekTo(_dragPosition);
                                setState(() => _draggingProgress = false);
                                _showOverlayFor4s();
                              },
                              child: Container(
                                height: 32,
                                alignment: Alignment.center,
                                child: Stack(
                                  alignment: Alignment.centerLeft,
                                  children: [
                                    Container(height: focused ? 6 : 4, width: double.infinity, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(3))),
                                    FractionallySizedBox(
                                      widthFactor: pct,
                                      child: Container(height: focused ? 6 : 4, decoration: BoxDecoration(color: focused ? AppColors.accent : Colors.white, borderRadius: BorderRadius.circular(3))),
                                    ),
                                    Positioned(
                                      left: (bw * pct).clamp(0.0, bw - 10),
                                      child: Container(width: 10, height: 10, decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle)),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          }),
                        ),
                        const SizedBox(width: 8),
                        Text(_fmt(_duration), style: const TextStyle(color: Colors.white70, fontSize: 12)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    // Action row
                    Center(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _bottomActionBtn(zone: _EZone.episodesList, icon: Icons.collections_outlined, label: 'Episodes', onTap: _showEpisodesMenu),
                          const SizedBox(width: 24),
                          _bottomActionBtn(zone: _EZone.aspectRatio, icon: Icons.aspect_ratio, label: 'Aspect Ratio', onTap: _showAspectMenu),
                          const SizedBox(width: 24),
                          _bottomActionBtn(zone: _EZone.speed, icon: Icons.speed, label: 'Speed (${_playbackSpeed}x)', onTap: _showSpeedMenu),
                          const SizedBox(width: 24),
                          _bottomActionBtn(zone: _EZone.subtitles, icon: Icons.closed_caption, label: 'Subtitles', onTap: _showSubtitlesInfo),
                          const SizedBox(width: 24),
                          _bottomActionBtn(zone: _EZone.nextEpisode, icon: Icons.skip_next, label: 'Next Episode', onTap: _playNextEpisode),
                        ],
                      ),
                    ),

                  ],
                ),
              ),
            ),

          // Retry banner removed to prevent background text overlap
        ],
      ),
      ), // FIX #12 TvSafeArea
    );
  }

  Widget _circleBtn({
    required _EZone zone,
    required Widget icon,
    double size = 44,
    bool hasBg = true,
    VoidCallback? onTap,
  }) {
    final focused = _zone == zone;
    return GestureDetector(
      onTap: onTap ?? () { setState(() => _zone = zone); _activateZone(); },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: size, height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: focused
              ? (zone == _EZone.play ? Colors.transparent : Colors.white.withValues(alpha: 0.24))
              : (hasBg ? Colors.white.withValues(alpha: 0.12) : Colors.transparent),
          border: Border.all(color: focused ? Colors.white : (hasBg ? Colors.white30 : Colors.transparent), width: focused ? 2.0 : 1.0),
          boxShadow: focused
              ? [
                  BoxShadow(
                    color: Colors.white.withValues(alpha: 0.4),
                    blurRadius: 18,
                    spreadRadius: 2,
                  )
                ]
              : null,
        ),
        child: Center(child: icon),
      ),
    );
  }

  Widget _verticalSlider({
    required IconData icon,
    required double value,
    required bool focused,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: focused ? AppColors.accent : Colors.white54, size: 20),
        const SizedBox(height: 8),
        SizedBox(
          height: 120,
          child: RotatedBox(
            quarterTurns: -1,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: focused ? AppColors.accent : Colors.white,
                inactiveTrackColor: Colors.white24,
                thumbColor: focused ? AppColors.accent : Colors.white,
                trackHeight: focused ? 4.0 : 2.0,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: SliderComponentShape.noOverlay,
              ),
              child: Slider(value: value, onChanged: onChanged),
            ),
          ),
        ),
      ],
    );
  }

  Widget _bottomActionBtn({
    required _EZone zone,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    final focused = _zone == zone;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: focused ? Colors.white12 : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: focused ? Colors.white30 : Colors.transparent, width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 18),
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }
}

class _EpSuggCard extends StatelessWidget {
  final EpisodeInfo ep;
  final ContentItem series;
  const _EpSuggCard({required this.ep, required this.series});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.bg2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ep.thumbnail != null && ep.thumbnail!.isNotEmpty
                ? CachedNetworkImage(
                    imageUrl: ep.thumbnail!,
                    fit: BoxFit.cover,
                    width: double.infinity,
                    errorWidget: (_, __, ___) => _placeholder(),
                  )
                : series.imageUrl.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: series.imageUrl,
                        fit: BoxFit.cover,
                        width: double.infinity,
                        errorWidget: (_, __, ___) => _placeholder(),
                      )
                    : _placeholder(),
          ),
          Padding(
            padding: const EdgeInsets.all(4),
            child: Text(
              'E${ep.episodeNum}',
              style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _placeholder() => Container(
    color: AppColors.bg3,
    child: const Center(child: Icon(Icons.tv, color: Colors.white30, size: 24)),
  );
}
