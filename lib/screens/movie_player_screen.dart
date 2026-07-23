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

const _movieAudioCh = MethodChannel('com.smartcaretv.app/audio');

enum _MZone {
  back,
  lock,
  fav,
  settings,
  replay,
  play,
  forward,
  progress,
  aspectRatio,
  speed,
  subtitles,
  suggestions
}

/// Full-screen movie/VOD player with 100% reliable TV D-pad navigation.
/// A single root FocusNode handles ALL remote key events using a _MZone state variable.
class MoviePlayerScreen extends StatefulWidget {
  final ContentItem item;
  const MoviePlayerScreen({super.key, required this.item});

  @override
  State<MoviePlayerScreen> createState() => _MoviePlayerScreenState();
}

class _MoviePlayerScreenState extends State<MoviePlayerScreen> {
  Player? _player;
  VideoController? _videoCtrl;
  BoxFit _videoFit = BoxFit.contain;
  double _playbackSpeed = 1.0;
  bool _controlsLocked = false;
  bool _disposed = false;
  bool _exiting = false;

  bool _loading = true;
  bool _autoRetrying = false;
  bool _streamDead = false;   // true after 3 failed attempts
  int  _retryCountdown = 0;
  int  _attemptNumber  = 0;   // current attempt (1-3)
  static const int _maxAttempts = 5;
  Timer? _retryTimer;

  late ContentItem _currentItem;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;

  double _volume = 100.0;
  bool _showVolumeBar = false;
  Timer? _hideVolumeTimer;

  bool   _showOverlay = true;
  Timer? _hideTimer;

  // ── Phone touch seek state ───────────────────────────────────────────────────
  bool     _draggingProgress = false;
  Duration _dragPosition     = Duration.zero;
  DateTime? _lastSeekTime;

  // ── TV navigation state ──────────────────────────────────────────────────────
  _MZone _zone = _MZone.play;
  int    _suggestionIdx = 0;
  List<ContentItem> _suggestions = [];
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

  /// Recomputes the button state and rebuilds only when it actually changed —
  /// this must never add a rebuild to the position tick.
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

  /// Single root focus node — handles ALL remote key events
  final FocusNode _focus = FocusNode(debugLabel: 'MoviePlayer');

  // Failover level: 0 = full quality, 1 = one tier lower, 2 = lowest (360p)
  int _failoverLevel = 0;

  // Device profile — resolved once at initState
  DeviceProfile? _deviceProfile;
  DeviceProfile get _profile =>
      _deviceProfile ?? DeviceProfileService.instance.currentProfile;

  // Device-specific stream headers (UA varies by brand)
  Map<String, String> get _streamHeaders => _profile.streamHeaders;

  @override
  void initState() {
    super.initState();
    _currentItem = widget.item;
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
        // Cache device profile once so we don't read context inside async gaps
        _deviceProfile = context.read<AppState>().deviceProfile;
        _focus.requestFocus();
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
      if (route != null && route.isCurrent) {
        _focus.requestFocus();
      }
    }
  }

  // ── Audio ────────────────────────────────────────────────────────────────────
  Future<void> _requestAudio() async {
    try { await _movieAudioCh.invokeMethod('requestAudioFocus'); } catch (_) {}
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

  // ── Overlay ──────────────────────────────────────────────────────────────────
  void _showOverlayFor4s() {
    if (!mounted) return;
    setState(() {
      _showOverlay = true;
      _zone = _MZone.play;
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
    if (!_playing) return; // Do NOT hide overlay if video is paused!
    _hideTimer = Timer(const Duration(seconds: 6), () {
      if (mounted && !_loading && !_autoRetrying) {
        setState(() => _showOverlay = false);
        _focus.requestFocus();
      }
    });
  }

  // ── Playback ─────────────────────────────────────────────────────────────────

  /// Build quality-tier-aware URL candidates for this movie.
  List<String> _movieUrls() {
    final s = context.read<AppState>();
    final u = s.username;
    final p = s.password;
    final id = _currentItem.id;
    final declaredExt =
        (_currentItem.containerExtension ?? 'mp4').toLowerCase();
    final tier = _failoverTier(s.qualityTier);
    return IptvService.getMovieStreamUrlCandidatesByQuality(u, p, id, tier, declaredExt);
  }

  /// Returns the actual tier to use, degraded by failover level.
  QualityTier _failoverTier(QualityTier base) {
    if (_failoverLevel == 0) return base;
    if (_failoverLevel == 1) {
      switch (base) {
        case QualityTier.uhd4k:   return QualityTier.fhd1080;
        case QualityTier.fhd1080: return QualityTier.hd720;
        case QualityTier.hd720:   return QualityTier.sd480;
        case QualityTier.sd480:
        case QualityTier.low360:
        case QualityTier.auto:    return QualityTier.sd480;
      }
    }
    return QualityTier.low360;
  }

  /// Returns true if the error string is a non-fatal libmpv warning
  /// that should NOT cause us to abandon a URL.
  bool _isNonFatalError(String err) {
    final lower = err.toLowerCase();
    // Subtitle / tag / codec warnings — always harmless
    if (lower.contains('subtitle')) return true;
    if (lower.contains('unsupported tag')) return true;
    if (lower.contains('skipping')) return true;
    if (lower.contains('matroska/webm: skipping')) return true;
    if (lower.contains('audio track selection')) return true;
    if (lower.contains('no audio') && lower.contains('available')) return true;
    // Generic warning prefixes from libmpv / FFmpeg
    if (lower.startsWith('warning:')) return true;
    if (lower.contains('[warning]')) return true;
    // Cache / buffer warnings — stream is still alive
    if (lower.contains('demuxer cache')) return true;
    if (lower.contains('cache is full')) return true;
    if (lower.contains('cache underrun')) return true;
    // Transient read / EOF that resolves via reconnect
    if (lower.contains('end of file') && !lower.contains('failed')) return true;
    if (lower == 'eof' || lower.startsWith('eof ')) return true;
    if (lower.contains('read error') && lower.contains('retry')) return true;
    // Video/audio codec info messages (not errors)
    if (lower.contains('video codec')) return true;
    if (lower.contains('audio codec')) return true;
    if (lower.contains('selected video') || lower.contains('selected audio')) return true;
    // Packet / seek warnings that don't stop playback
    if (lower.contains('packet too large')) return true;
    if (lower.contains('pts') && lower.contains('discontinuity')) return true;
    if (lower.contains('dts') && lower.contains('discontinuity')) return true;
    return false;
  }

  Future<void> _startPlay() async {
    if (!mounted || _startingPlay) return;
    _startingPlay = true;

    final appState = context.read<AppState>();
    final hwAccel  = appState.hardwareAccelEnabled;
    final bufBytes = appState.bufferBytes;
    final profile  = _profile;

    debugPrint('[Movie] ▶ ${_currentItem.title} | device=${profile.deviceClass} '
        'buf=${bufBytes ~/ (1024 * 1024)}MB failoverLevel=$_failoverLevel');

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
      debugPrint('⏱ [Movie] 30s watchdog fired');
      _scheduleRetry();
    });

    try {
      // Audio focus is best-effort and takes up to 2 s on some boxes; awaiting
      // it here just delayed the first frame by that much. Fire and forget.
      unawaited(_requestAudio());
      final urls = _movieUrls();

      // PlayerFactory fires all mpv properties concurrently (Future.wait)
      // instead of 20+ sequential awaits — eliminates the ANR on Android.
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

      if (result == null) throw Exception('All movie URLs failed');
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
            if (p) {
              _resetHideTimer();
            } else {
              _hideTimer?.cancel();
              _showOverlay = true;
            }
          });
          _syncUiState(); // FIX #6
        }
      });

      // FIX #6 — nothing subscribed to buffering before, so a mid-playback
      // stall left a stale play/pause icon on screen.
      _bufferingSub = result.player.stream.buffering.listen((b) {
        if (!mounted) return;
        _buffering = b;
        _syncUiState();
      });

      // FIX #6 — first decoded frame: until this arrives there is nothing to
      // pause, so the button must stay a spinner.
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
      debugPrint('❌ [Movie] $e');
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
      // 3-Level Failover — same logic as channel player
      if (_failoverLevel < 2) {
        _failoverLevel++;
        _attemptNumber = 0;
        debugPrint('[Movie] ↳ Failover Level $_failoverLevel (quality degraded silently)');
        setState(() { _autoRetrying = false; _loading = false; });
        _startPlay();
        return;
      }
      if (mounted) {
        setState(() {
          _autoRetrying = false;
          _loading      = false;
          _streamDead   = true;
        });
        _syncUiState(); // FIX #6 — button becomes a retry icon
      }
      debugPrint('❌ [Movie] Stream marked dead after all failover levels exhausted');
      return;
    }

    setState(() {
      _autoRetrying    = true;
      _loading         = false;
      _retryCountdown  = 5;
    });
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

  /// Manual retry — resets attempt counter AND failover level.
  void _manualRetry() {
    _retryTimer?.cancel();
    _attemptNumber = 0;
    _failoverLevel = 0;
    setState(() { _streamDead = false; _autoRetrying = false; });
    _startPlay();
  }

  String _fmt(Duration d) {
    final h  = d.inHours;
    final mm = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  void _seekTo(Duration target) {
    if (_player == null) return;
    final clamped = target < Duration.zero
        ? Duration.zero
        : (target > _duration ? _duration : target);
    setState(() {
      _position = clamped;
      _lastSeekTime = DateTime.now();
    });
    _player!.seek(clamped);
  }

  void _togglePlay() {
    if (_player == null) return;
    _player!.playOrPause();
    setState(() => _playing = _player!.state.playing);
    _syncUiState(); // FIX #6
    _resetHideTimer();
  }

  // ── Activate whichever zone the remote cursor is on ──────────────────────────
  void _activateZone() {
    final appState = context.read<AppState>();
    switch (_zone) {
      case _MZone.back:
        _safeExit();
        break;

      case _MZone.lock:
        setState(() {
          _controlsLocked = !_controlsLocked;
        });
        _showOverlayFor4s();
        break;
      case _MZone.fav:
        appState.toggleFavorite(_currentItem);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
            appState.isFavorite(_currentItem.id) ? 'Added to My List' : 'Removed from My List',
            style: const TextStyle(color: Colors.white),
          ),
          backgroundColor: AppColors.bg4,
          duration: const Duration(seconds: 2),
        ));
        _resetHideTimer();
        setState(() {});
        break;
      case _MZone.settings:
        _showSettingsMenu();
        break;
      case _MZone.replay:
        if (_player != null) {
          _player!.seek(_player!.state.position - const Duration(seconds: 10));
          _resetHideTimer();
        }
        break;
      case _MZone.play:
        _togglePlay();
        break;
      case _MZone.forward:
        if (_player != null) {
          _player!.seek(_player!.state.position + const Duration(seconds: 10));
          _resetHideTimer();
        }
        break;
      case _MZone.progress:
        _togglePlay();
        break;
      case _MZone.aspectRatio:
        _showAspectMenu();
        break;
      case _MZone.speed:
        _showSpeedMenu();
        break;
      case _MZone.subtitles:
        _showSubtitlesMenu();
        break;
      case _MZone.suggestions:
        if (_suggestionIdx < _suggestions.length) {
          final item = _suggestions[_suggestionIdx];
          final p = _player;
          if (p != null) {
            p.stop().catchError((_) => null).then((_) {
              if (mounted) {
                Navigator.pushReplacement(context,
                    MaterialPageRoute(builder: (_) => MoviePlayerScreen(item: item)));
              }
            });
          } else {
            Navigator.pushReplacement(context,
                MaterialPageRoute(builder: (_) => MoviePlayerScreen(item: item)));
          }
        }
        break;
    }
  }

  // ── Auto-scroll suggestions to keep focused card visible ────────────────────
  void _scrollSuggestions() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_suggScroll.hasClients) return;
      const cardW = 105.0;
      final target = _suggestionIdx * cardW;
      final viewW = _suggScroll.position.viewportDimension;
      final current = _suggScroll.offset;
      if (target < current) {
        _suggScroll.animateTo(target,
            duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      } else if (target + cardW > current + viewW) {
        _suggScroll.animateTo(target + cardW - viewW,
            duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    });
  }

  // ── Master key handler ───────────────────────────────────────────────────────
  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;

    // Volume keys — always handled
    if (k == LogicalKeyboardKey.audioVolumeUp)   { _volumeUp();   return KeyEventResult.handled; }
    if (k == LogicalKeyboardKey.audioVolumeDown) { _volumeDown(); return KeyEventResult.handled; }

    if (_showOverlay) _resetHideTimer();

    // Dedicated media seek keys — jump 1 min (60 seconds)
    final isMediaLeft = k == LogicalKeyboardKey.mediaRewind ||
        k == LogicalKeyboardKey.mediaTrackPrevious;
    final isMediaRight = k == LogicalKeyboardKey.mediaFastForward ||
        k == LogicalKeyboardKey.mediaTrackNext;
    if (isMediaLeft || isMediaRight) {
      if (!_controlsLocked && _player != null) {
        final step = const Duration(seconds: 60);
        final target = isMediaLeft
            ? _player!.state.position - step
            : _player!.state.position + step;
        _player!.seek(target < Duration.zero ? Duration.zero : (target > _duration ? _duration : target));
        _showOverlayFor4s();
      }
      return KeyEventResult.handled;
    }

    // Back / Escape
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

    // Media keys
    if (k == LogicalKeyboardKey.mediaPlayPause ||
        k == LogicalKeyboardKey.mediaPlay ||
        k == LogicalKeyboardKey.mediaPause) {
      if (!_controlsLocked) {
        _togglePlay();
      }
      return KeyEventResult.handled;
    }

    // Any key while overlay hidden → show overlay
    if (!_showOverlay) {
      final isSeekLeft = k == LogicalKeyboardKey.arrowLeft;
      final isSeekRight = k == LogicalKeyboardKey.arrowRight;
      setState(() {
        _showOverlay = true;
        if (_controlsLocked) {
          _zone = _MZone.lock;
        } else {
          if (isSeekLeft) {
            _zone = _MZone.replay;
          } else if (isSeekRight) {
            _zone = _MZone.forward;
          } else {
            _zone = _MZone.play;
          }
        }
      });
      _resetHideTimer();
      if (!_controlsLocked) {
        if (isSeekLeft && _player != null) {
          final target = _player!.state.position - const Duration(seconds: 10);
          _player!.seek(target < Duration.zero ? Duration.zero : (target > _duration ? _duration : target));
        } else if (isSeekRight && _player != null) {
          final target = _player!.state.position + const Duration(seconds: 10);
          _player!.seek(target < Duration.zero ? Duration.zero : (target > _duration ? _duration : target));
        }
      }
      return KeyEventResult.handled;
    }

    // Controls Locked Guard: restrict navigation when locked
    if (_controlsLocked) {
      final isSelect = k == LogicalKeyboardKey.select ||
          k == LogicalKeyboardKey.enter ||
          k == LogicalKeyboardKey.gameButtonA ||
          k.keyId == 13 ||
          k.keyId == 23 ||
          k.keyId == 96 ||
          k.keyId == 160;
      if (isSelect) {
        if (_zone == _MZone.lock) {
          _activateZone();
        }
        return KeyEventResult.handled;
      }
      setState(() => _zone = _MZone.lock);
      return KeyEventResult.handled;
    }

    // Select / Enter → activate current zone
    final isSelect = k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.gameButtonA ||
        k.keyId == 13 ||
        k.keyId == 23 ||
        k.keyId == 96 ||
        k.keyId == 160;
    if (isSelect) {
      _activateZone();
      return KeyEventResult.handled;
    }

    // ── Arrow navigation ─────────────────────────────────────────────────────
    if (k == LogicalKeyboardKey.arrowLeft) {
      setState(() {
        switch (_zone) {
          case _MZone.lock:     _zone = _MZone.back; break;
          case _MZone.fav:      _zone = _MZone.lock; break;
          case _MZone.settings: _zone = _MZone.fav; break;
          case _MZone.replay:   break;
          case _MZone.play:     _zone = _MZone.replay; break;
          case _MZone.forward:  _zone = _MZone.play; break;
          case _MZone.progress:
            if (_player != null) {
              final target = _player!.state.position - const Duration(seconds: 60);
              _player!.seek(target < Duration.zero ? Duration.zero : (target > _duration ? _duration : target));
            }
            break;
          case _MZone.speed:       _zone = _MZone.aspectRatio; break;
          case _MZone.subtitles:   _zone = _MZone.speed; break;
          default: break;
        }
      });
      return KeyEventResult.handled;
    }

    if (k == LogicalKeyboardKey.arrowRight) {
      setState(() {
        switch (_zone) {
          case _MZone.back:       _zone = _MZone.lock; break;
          case _MZone.lock:       _zone = _MZone.fav; break;
          case _MZone.fav:        _zone = _MZone.settings; break;
          case _MZone.replay:     _zone = _MZone.play; break;
          case _MZone.play:       _zone = _MZone.forward; break;
          case _MZone.forward:    break;
          case _MZone.progress:
            if (_player != null) {
              final target = _player!.state.position + const Duration(seconds: 60);
              _player!.seek(target < Duration.zero ? Duration.zero : (target > _duration ? _duration : target));
            }
            break;
          case _MZone.aspectRatio: _zone = _MZone.speed; break;
          case _MZone.speed:       _zone = _MZone.subtitles; break;
          default: break;
        }
      });
      return KeyEventResult.handled;
    }

    if (k == LogicalKeyboardKey.arrowUp) {
      setState(() {
        switch (_zone) {
          case _MZone.replay:      _zone = _MZone.back; break;
          case _MZone.play:        _zone = _MZone.lock; break;
          case _MZone.forward:     _zone = _MZone.fav; break;
          case _MZone.progress:    _zone = _MZone.play; break;
          case _MZone.aspectRatio:
          case _MZone.speed:
          case _MZone.subtitles:
            _zone = _MZone.progress;
            break;
          default: break;
        }
      });
      return KeyEventResult.handled;
    }

    if (k == LogicalKeyboardKey.arrowDown) {
      setState(() {
        switch (_zone) {
          case _MZone.back:        _zone = _MZone.replay; break;
          case _MZone.lock:
            _zone = _MZone.play;
            break;
          case _MZone.fav:
          case _MZone.settings:
            _zone = _MZone.forward;
            break;
          case _MZone.replay:
          case _MZone.play:
          case _MZone.forward:
            _zone = _MZone.progress;
            break;
          case _MZone.progress:
            _zone = _MZone.speed;
            break;
          default: break;
        }
      });
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
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
            children: [
              const Text('Aspect Ratio', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              ListTile(
                focusColor: Colors.white24,
                title: const Text('Fit (Original)', style: TextStyle(color: Colors.white)),
                leading: Icon(Icons.fit_screen, color: _videoFit == BoxFit.contain ? AppColors.accent : Colors.white70),
                onTap: () {
                  setState(() => _videoFit = BoxFit.contain);
                  Navigator.pop(context);
                  _showOverlayFor4s();
                },
              ),
              ListTile(
                focusColor: Colors.white24,
                title: const Text('Stretch (16:9)', style: TextStyle(color: Colors.white)),
                leading: Icon(Icons.open_in_full, color: _videoFit == BoxFit.fill ? AppColors.accent : Colors.white70),
                onTap: () {
                  setState(() => _videoFit = BoxFit.fill);
                  Navigator.pop(context);
                  _showOverlayFor4s();
                },
              ),
              ListTile(
                focusColor: Colors.white24,
                title: const Text('Zoom (Crop)', style: TextStyle(color: Colors.white)),
                leading: Icon(Icons.fullscreen, color: _videoFit == BoxFit.cover ? AppColors.accent : Colors.white70),
                onTap: () {
                  setState(() => _videoFit = BoxFit.cover);
                  Navigator.pop(context);
                  _showOverlayFor4s();
                },
              ),
            ],
          ),
        );
      },
    ).then((_) => _resetHideTimer());
  }

  // FIX #10 — was a showModalBottomSheet of plain ListTiles: nothing in it was
  // focusable and it stole focus from the player's key handler, so a TV remote
  // could not operate it at all. Now uses the shared D-pad speed picker.
  Future<void> _showSpeedMenu() async {
    _hideTimer?.cancel();
    final picked = await showSpeedPicker(context, current: _playbackSpeed);
    if (!mounted) {
      return;
    }
    // null = backed out; leave the speed untouched.
    if (picked != null && picked != _playbackSpeed) {
      setState(() => _playbackSpeed = picked);
      await _player?.setRate(picked);
      if (mounted) _showSpeedToast(picked); // FIX #10 (item 4)
    }
    _resetHideTimer();
  }

  /// Brief confirmation overlay so the user knows the change landed.
  void _showSpeedToast(double speed) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Speed ${speed}x'),
        duration: const Duration(milliseconds: 1200),
        backgroundColor: Colors.black87,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _showSubtitlesMenu() {
    _hideTimer?.cancel();
    final tracks = _player?.state.tracks.subtitle ?? [];
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black.withOpacity(0.95),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (context) {
        return Container(
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Subtitles', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              if (tracks.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Text('No subtitle tracks available', style: TextStyle(color: Colors.white70)),
                )
              else
                Expanded(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: tracks.length,
                    itemBuilder: (context, idx) {
                      final track = tracks[idx];
                      final isSelected = _player?.state.track.subtitle == track;
                      return ListTile(
                        title: Text(track.title ?? track.language ?? 'Track $idx', style: const TextStyle(color: Colors.white)),
                        leading: Icon(Icons.subtitles, color: isSelected ? AppColors.accent : Colors.white70),
                        onTap: () {
                          _player?.setSubtitleTrack(track);
                          Navigator.pop(context);
                          _showOverlayFor4s();
                        },
                      );
                    },
                  ),
                ),
            ],
          ),
        );
      },
    ).then((_) => _resetHideTimer());
  }

  void _showCastModal() {
    _hideTimer?.cancel();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.bg3,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.cast, color: Colors.white),
            SizedBox(width: 12),
            Text('Chromecast', style: TextStyle(color: Colors.white)),
          ],
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Searching for compatible screens on your network...', style: TextStyle(color: Colors.white70)),
            SizedBox(height: 16),
            Center(
              child: SizedBox(
                width: 24, height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(AppColors.accent),
                ),
              ),
            ),
            SizedBox(height: 16),
            Text('Note: Make sure your TV or streaming device is on the same Wi-Fi network.', style: TextStyle(color: Colors.white38, fontSize: 11)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: AppColors.accent)),
          ),
        ],
      ),
    ).then((_) => _resetHideTimer());
  }

  Widget _bottomActionBtn({
    required _MZone zone,
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
            Text(
              label,
              style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    );
  }

  // ── Visual helper: focused circle button ─────────────────────────────────────
  Widget _circleBtn({
    required _MZone zone,
    required Widget icon,
    double size = 44,
    bool hasBg = true,
    Color? defaultBg,
  }) {
    final focused = _zone == zone;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: focused
            ? (zone == _MZone.play ? Colors.transparent : Colors.white.withValues(alpha: 0.24))
            : (defaultBg ?? (hasBg ? Colors.white.withValues(alpha: 0.12) : Colors.transparent)),
        border: Border.all(
          color: focused ? Colors.white : (hasBg ? Colors.white30 : Colors.transparent),
          width: focused ? 2.0 : 1.0,
        ),
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
    );
  }

  // ── Build suggestions list ───────────────────────────────────────────────────
  void _buildSuggestions(AppState state) {
    final catMovies = state.movies
        .where((m) => m.category == _currentItem.category)
        .toList();
    List<ContentItem> rel = [];
    final catIdx = catMovies.indexWhere((m) => m.id == _currentItem.id);
    if (catIdx != -1 && catMovies.length > 1) {
      for (int i = 1; i <= 20; i++) {
        final next = catMovies[(catIdx + i) % catMovies.length];
        if (next.id != _currentItem.id) rel.add(next);
      }
    }
    if (rel.length < 10) {
      rel = [];
      final all = state.movies;
      final idx = all.indexWhere((m) => m.id == _currentItem.id);
      if (idx != -1) {
        for (int i = 1; i <= 20; i++) {
          final next = all[(idx + i) % all.length];
          if (next.id != _currentItem.id) rel.add(next);
        }
      }
    }
    _suggestions = rel;
  }

  // ── Build ────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final isFav = appState.isFavorite(_currentItem.id);
    _buildSuggestions(appState);

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
          behavior: HitTestBehavior.translucent,
          // Tap empty video area to toggle overlay show/hide
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

              // ── VIDEO or OPAQUE LOADING SCREEN ──────────────────────────
              // IMPORTANT: During loading we use a fully opaque black screen
              // so the home screen never shows behind the player.
              if (_videoCtrl != null && !_loading)
                Video(controller: _videoCtrl!, controls: NoVideoControls, fit: _videoFit)
              else
                Container(
                  color: Colors.black,
                ),

              // Fullscreen loading/retry overlays removed to prevent text overlap in the background

              // ── STREAM DEAD ───────────────────────────────────────────
              if (_streamDead)
                Container(
                  color: Colors.black87,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.movie_filter_outlined,
                            color: Colors.white38, size: 56),
                        const SizedBox(height: 20),
                        const Text('Movie Unavailable',
                            style: TextStyle(color: Colors.white, fontSize: 18,
                                fontWeight: FontWeight.w700)),
                        const SizedBox(height: 8),
                        Text(
                          // _attemptNumber == 0 means we never retried: the
                          // provider said "not there", so say that plainly
                          // rather than claiming attempts that never happened.
                          _attemptNumber == 0
                              ? '${_currentItem.title} is not available\nfrom your provider right now.'
                              : '${_currentItem.title} could not be loaded\nafter $_maxAttempts attempts.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white54, fontSize: 13, height: 1.5),
                        ),
                        const SizedBox(height: 24),
                        ElevatedButton.icon(
                          onPressed: _manualRetry,
                          icon: const Icon(Icons.refresh, size: 18),
                          label: const Text('Try Again'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.accent,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8)),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextButton(
                          onPressed: () {
                            _safeExit();
                          },
                          child: const Text('Go Back',
                              style: TextStyle(color: Colors.white54, fontSize: 13)),
                        ),
                      ],
                    ),
                  ),
                ),

              // ── OVERLAY: visual gradients + title (non-interactive) ──
              AnimatedOpacity(
                opacity: _showOverlay ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 300),
                child: IgnorePointer(
                  // Gradients and title text never need touch events
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // Top gradient
                      Positioned(
                        top: 0, left: 0, right: 0,
                        child: Container(
                          height: 120,
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Color(0xEE000000), Colors.transparent],
                            ),
                          ),
                        ),
                      ),
                      // Bottom gradient
                      Positioned(
                        bottom: 0, left: 0, right: 0,
                        child: Container(
                          height: 400,
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.bottomCenter,
                              end: Alignment.topCenter,
                              colors: [Color(0xEE000000), Colors.transparent],
                            ),
                          ),
                        ),
                      ),

                    ],
                  ),
                ),
              ),

              // ── OVERLAY: interactive controls (OUTSIDE IgnorePointer so phone touches always reach them) ──
              AnimatedOpacity(
                opacity: _showOverlay ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 300),
                child: IgnorePointer(
                  ignoring: !_showOverlay, // block touches only when hidden
                  child: ExcludeFocus(
                    excluding: true, // root _focus handles all key events
                    // FIX #12 — video and gradients stay full-bleed;
                    // only the controls move inside the overscan margin.
                    child: TvSafeArea(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [

                        // ── TOP BAR: Back, Cast, Lock, Fav, Settings ────
                        Positioned(
                          top: 0, left: 0, right: 0,
                          child: SafeArea(
                            bottom: false,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              child: Row(
                                children: [
                                  // Back button
                                  if (!_controlsLocked)
                                    GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onTap: () {
                                        _safeExit();
                                      },
                                      child: _circleBtn(
                                        zone: _MZone.back,
                                        size: 40,
                                        icon: const Icon(Icons.arrow_back, color: Colors.white, size: 20),
                                        hasBg: true,
                                      ),
                                    ),
                                  const SizedBox(width: 12),
                                  // Title text
                                  Expanded(
                                    child: Text(
                                      _currentItem.title,
                                      style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold, fontFamily: 'Outfit'),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  // Lock button (always visible so user can unlock)
                                  GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTap: () {
                                      setState(() {
                                        _controlsLocked = !_controlsLocked;
                                      });
                                      _showOverlayFor4s();
                                    },
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 4),
                                      child: _circleBtn(
                                        zone: _MZone.lock,
                                        size: 40,
                                        icon: Icon(_controlsLocked ? Icons.lock : Icons.lock_open, color: Colors.white, size: 20),
                                        hasBg: _controlsLocked,
                                      ),
                                    ),
                                  ),
                                  if (!_controlsLocked) ...[
                                    const SizedBox(width: 8),
                                    // Fav button
                                    GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onTap: () {
                                        appState.toggleFavorite(_currentItem);
                                        _showOverlayFor4s();
                                      },
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(horizontal: 4),
                                        child: _circleBtn(
                                          zone: _MZone.fav,
                                          size: 40,
                                          icon: Icon(isFav ? Icons.favorite : Icons.favorite_border, color: Colors.white, size: 20),
                                          hasBg: true,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    // Settings button
                                    GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onTap: _showSettingsMenu,
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(horizontal: 4),
                                        child: _circleBtn(
                                          zone: _MZone.settings,
                                          size: 40,
                                          icon: const Icon(Icons.settings, color: Colors.white, size: 20),
                                          hasBg: true,
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),

                        // ── CENTER PLAYBACK CONTROLS ────
                        if (!_controlsLocked && !_streamDead)
                          Positioned.fill(
                            child: Center(
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // -10s
                                GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () {
                                    if (_player != null) _seekTo(_player!.state.position - const Duration(seconds: 10));
                                    _showOverlayFor4s();
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.all(8),
                                    child: _circleBtn(
                                      zone: _MZone.replay,
                                      icon: const Icon(Icons.replay_10, color: Colors.white, size: 32),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 16),
                                // Play/Pause
                                GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () {
                                    _togglePlay();
                                    _showOverlayFor4s();
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.all(8),
                                    child: _circleBtn(
                                      zone: _MZone.play,
                                      size: 72,
                                      defaultBg: Colors.transparent,
                                      // FIX #6 — one glyph driven by the state
                                      // enum, cross-faded, fixed size so the
                                      // button never shifts.
                                      icon: playPauseGlyph(_uiState),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 16),
                                // +10s
                                GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () {
                                    if (_player != null) _seekTo(_player!.state.position + const Duration(seconds: 10));
                                    _showOverlayFor4s();
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.all(8),
                                    child: _circleBtn(
                                      zone: _MZone.forward,
                                      icon: const Icon(Icons.forward_10, color: Colors.white, size: 32),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),

                        // ── BOTTOM: progress + action row ──────────
                        Positioned(
                          bottom: 0, left: 0, right: 0,
                          child: SafeArea(
                            top: false,
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [


                                  // ── Seekable progress bar ──────────────────────
                                  // Supports tap-to-seek AND drag-to-scrub on phone
                                  Row(
                                    children: [
                                      // Current position (shows drag pos while scrubbing)
                                      SizedBox(
                                        width: 44,
                                        child: Text(
                                          _fmt(_draggingProgress ? _dragPosition : _position),
                                          style: const TextStyle(color: Colors.white70, fontSize: 12),
                                          textAlign: TextAlign.center,
                                        ),
                                      ),
                                      // Interactive scrub bar
                                      Expanded(
                                        child: LayoutBuilder(
                                          builder: (ctx, constraints) {
                                            final barWidth = constraints.maxWidth;
                                            final displayPct = _draggingProgress
                                                ? (_duration.inMilliseconds > 0
                                                    ? (_dragPosition.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0)
                                                    : 0.0)
                                                : (_duration.inMilliseconds > 0
                                                    ? (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0)
                                                    : 0.0);
                                            final isFocused  = _zone == _MZone.progress;
                                            final isActive   = isFocused || _draggingProgress;

                                            Duration dxToPos(double dx) {
                                              if (_duration.inMilliseconds == 0) return Duration.zero;
                                              final pct = (dx / barWidth).clamp(0.0, 1.0);
                                              return Duration(milliseconds: (pct * _duration.inMilliseconds).toInt());
                                            }

                                            return GestureDetector(
                                              behavior: HitTestBehavior.opaque,
                                              // Tap anywhere on bar to seek
                                              onTapDown: (d) {
                                                _hideTimer?.cancel();
                                                final target = dxToPos(d.localPosition.dx);
                                                setState(() {
                                                  _draggingProgress = true;
                                                  _dragPosition = target;
                                                });
                                                _seekTo(target);
                                              },
                                              onTapUp: (_) {
                                                setState(() => _draggingProgress = false);
                                                _showOverlayFor4s();
                                              },
                                              onTapCancel: () => setState(() => _draggingProgress = false),
                                              // Drag to scrub
                                              onHorizontalDragStart: (d) {
                                                _hideTimer?.cancel();
                                                setState(() {
                                                  _draggingProgress = true;
                                                  _dragPosition = dxToPos(d.localPosition.dx);
                                                });
                                              },
                                              onHorizontalDragUpdate: (d) {
                                                setState(() => _dragPosition = dxToPos(d.localPosition.dx));
                                              },
                                              onHorizontalDragEnd: (_) {
                                                _seekTo(_dragPosition);
                                                setState(() => _draggingProgress = false);
                                                _showOverlayFor4s();
                                              },
                                              child: Container(
                                                height: 44, // fat touch target
                                                alignment: Alignment.center,
                                                child: Stack(
                                                  alignment: Alignment.centerLeft,
                                                  children: [
                                                    // Track
                                                    Container(
                                                      height: isActive ? 10 : 5,
                                                      width: double.infinity,
                                                      decoration: BoxDecoration(
                                                        color: Colors.white30,
                                                        borderRadius: BorderRadius.circular(6),
                                                      ),
                                                    ),
                                                    // Filled portion
                                                    FractionallySizedBox(
                                                      widthFactor: displayPct,
                                                      child: Container(
                                                        height: isActive ? 10 : 5,
                                                        decoration: BoxDecoration(
                                                          color: isActive ? AppColors.accent : Colors.white,
                                                          borderRadius: BorderRadius.circular(6),
                                                          boxShadow: isActive
                                                              ? [BoxShadow(
                                                                  color: AppColors.accent.withValues(alpha: 0.8),
                                                                  blurRadius: 8, spreadRadius: 2,
                                                                )]
                                                              : null,
                                                        ),
                                                      ),
                                                    ),
                                                    // Scrub thumb (visible when active)
                                                    if (isActive)
                                                      Positioned(
                                                        left: (barWidth * displayPct).clamp(0.0, barWidth - 16),
                                                        child: Container(
                                                          width: 18, height: 18,
                                                          decoration: const BoxDecoration(
                                                            color: Colors.white,
                                                            shape: BoxShape.circle,
                                                            boxShadow: [BoxShadow(color: Colors.black54, blurRadius: 6)],
                                                          ),
                                                        ),
                                                      ),
                                                  ],
                                                ),
                                              ),
                                            );
                                          },
                                        ),
                                      ),
                                      // Total duration
                                      SizedBox(
                                        width: 44,
                                        child: Text(
                                          _fmt(_duration),
                                          style: const TextStyle(color: Colors.white70, fontSize: 12),
                                          textAlign: TextAlign.center,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  // Action Row Below SeekBar
                                  Center(
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        _bottomActionBtn(
                                          zone: _MZone.aspectRatio,
                                          icon: Icons.aspect_ratio,
                                          label: 'Aspect Ratio',
                                          onTap: _showAspectMenu,
                                        ),
                                        const SizedBox(width: 24),
                                        _bottomActionBtn(
                                          zone: _MZone.speed,
                                          icon: Icons.speed,
                                          label: 'Speed (${_playbackSpeed}x)',
                                          onTap: _showSpeedMenu,
                                        ),
                                        const SizedBox(width: 24),
                                        _bottomActionBtn(
                                          zone: _MZone.subtitles,
                                          icon: Icons.subtitles,
                                          label: 'Subtitles',
                                          onTap: _showSubtitlesMenu,
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    ), // FIX #12 TvSafeArea
                  ),
                ),
              ),

              // ── VOLUME INDICATOR ──────────────────────────────────────
              Positioned(
                right: 32, top: 0, bottom: 0,
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    opacity: _showVolumeBar ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 250),
                    child: Center(
                      child: Container(
                        width: 52, height: 200,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.75),
                          borderRadius: BorderRadius.circular(26),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: RotatedBox(
                                  quarterTurns: -1,
                                  child: LinearProgressIndicator(
                                    value: (_volume / 100.0).clamp(0.0, 1.0),
                                    backgroundColor: Colors.white24,
                                    valueColor: const AlwaysStoppedAnimation<Color>(AppColors.accent),
                                    minHeight: 10,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Icon(
                              _volume == 0 ? Icons.volume_off : _volume < 40 ? Icons.volume_down : Icons.volume_up,
                              color: Colors.white, size: 20,
                            ),
                            const SizedBox(height: 4),
                            Text('${_volume.round()}',
                                style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
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
      ),
    ),
   );
  }

  Widget _thumbnail(ContentItem item) {
    if (item.imageUrl.isEmpty) {
      return Container(
        color: Colors.black,
        child: Center(
          child: Text(
            item.title.isNotEmpty ? item.title[0].toUpperCase() : '?',
            style: const TextStyle(color: AppColors.accent, fontSize: 72, fontWeight: FontWeight.w800),
          ),
        ),
      );
    }
    return CachedNetworkImage(
      imageUrl: item.imageUrl,
      fit: BoxFit.contain,
      errorWidget: (_, __, ___) => Container(color: Colors.black),
    );
  }
}

/// Minimal movie suggestion card — no focus node, root _focus handles everything
class _MovieSuggCard extends StatelessWidget {
  final ContentItem item;
  const _MovieSuggCard({required this.item});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF1A1A2E),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: item.imageUrl.isNotEmpty
                ? CachedNetworkImage(
                    imageUrl: item.imageUrl,
                    fit: BoxFit.cover,
                    width: double.infinity,
                    memCacheWidth: 200,
                    errorWidget: (_, __, ___) => _fallback(item),
                  )
                : _fallback(item),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(5, 4, 5, 1),
            child: Text(item.title,
                maxLines: 2, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w500, color: Colors.white70)),
          ),
          if (item.year != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(5, 0, 5, 5),
              child: Text('${item.year}',
                  style: const TextStyle(fontSize: 9, color: Colors.white38)),
            ),
        ],
      ),
    );
  }

  static Widget _fallback(ContentItem item) {
    return Center(
      child: Text(
        item.title.isNotEmpty ? item.title[0].toUpperCase() : '?',
        style: const TextStyle(color: AppColors.accent, fontSize: 24, fontWeight: FontWeight.w800),
      ),
    );
  }
}
