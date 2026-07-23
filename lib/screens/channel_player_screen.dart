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
import '../services/app_state.dart';
import '../services/iptv_service.dart';
import '../services/device_profile_service.dart';
import '../services/player_factory.dart';
import '../services/cache_service.dart';

const _audioCh = MethodChannel('com.smartcaretv.app/audio');

// TV navigation zones in the player overlay
enum _Zone {
  back,
  lock,
  fav,
  settings,
  brightness,
  replay,
  play,
  forward,
  volume,
  progress,
  aspectRatio,
  speed,
  subtitles,
  suggestions
}

class ChannelPlayerScreen extends StatefulWidget {
  final ContentItem item;
  const ChannelPlayerScreen({super.key, required this.item});

  @override
  State<ChannelPlayerScreen> createState() => _ChannelPlayerScreenState();
}

class _ChannelPlayerScreenState extends State<ChannelPlayerScreen> {
  Player? _player;
  VideoController? _videoCtrl;
  BoxFit _videoFit = BoxFit.contain;
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

  double _brightness = 1.0;
  bool _controlsLocked = false;
  double _playbackSpeed = 1.0;

  // ── Phone touch seek state ───────────────────────────────────────────────────
  bool     _draggingProgress = false;
  Duration _dragPosition     = Duration.zero;

  // ── TV navigation state ─────────────────────────────────────────────────────
  _Zone _zone = _Zone.play;
  int   _suggestionIdx = 0;
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
  Timer? _stallTimer;

  // Prevents the watchdog/retry timers from firing a second, overlapping
  // _startPlay() while a previous probe is still in flight — without this,
  // a slow probe (many candidate URLs) can race the 20s watchdog into
  // starting a second concurrent PlayerFactory.probe(), doubling native
  // Player/Texture creation and starving the platform thread.
  bool _startingPlay = false;

  // Single root focus node — handles ALL remote key events
  final FocusNode _focus = FocusNode(debugLabel: 'ChannelPlayer');

  // Failover level tracks which URL tier we are currently on:
  //  0 = full-quality (user-selected tier)
  //  1 = one tier lower (e.g. 1080p → 720p)
  //  2 = lowest quality (360p fallback)
  int _failoverLevel = 0;

  // ── Device profile — resolved once at build time ─────────────────────────
  DeviceProfile? _deviceProfile;

  DeviceProfile get _profile =>
      _deviceProfile ?? DeviceProfileService.instance.currentProfile;

  // ── Stream headers are now device-specific (not static) ──────────────────
  Map<String, String> get _streamHeaders => _profile.streamHeaders;

  @override
  void initState() {
    super.initState();
    _currentItem = widget.item;
    _focus.addListener(_onFocusChange);
    // Fire-and-forget — do NOT await these before starting playback.
    // Confirmed via device testing (with playback code entirely skipped)
    // that Android's own orientation+immersive-mode transition can take 5+
    // seconds to complete on some devices regardless of when it's kicked
    // off or what else is running — awaiting it just delays everything
    // without avoiding the "Waited Xms for FocusEvent" ANR. Firing it here
    // and letting _startPlay() proceed independently (after the first
    // frame) is the same pattern this screen used before player.open()
    // ever caused an ANR.
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        // Cache the device profile once so we don't read context inside async gaps
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
    _stallTimer?.cancel();
    _suggScroll.dispose();
    _focus.dispose();
    _completedSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _playingSub?.cancel();
    _bufferingSub?.cancel(); // FIX #6
    _widthSub?.cancel();     // FIX #6
    CacheService.clearRamCache();
    final p = _player;
    _player = null;
    if (p != null) {
      // Ordered teardown — see core/player/safe_dispose.dart. Disposing while
      // stop() is still running natively aborts the whole process. This is the
      // path that crashed on channel switching.
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

  // ── Audio ───────────────────────────────────────────────────────────────────
  // Requesting audio focus is best-effort — never let a stuck or slow
  // platform-channel round trip here block playback startup. This is what
  // caused the release-build ANR: the native handler used to reply to
  // Flutter only after its own (occasionally-hanging) AudioManager Binder
  // call finished, so a stuck native call meant this `await` never
  // returned. The native handler now replies immediately regardless, but
  // this timeout stays as a second line of defense.
  Future<void> _requestAudio() async {
    try {
      await _audioCh
          .invokeMethod('requestAudioFocus')
          .timeout(const Duration(seconds: 2));
    } catch (_) {}
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

  // ── Overlay ─────────────────────────────────────────────────────────────────
  void _showOverlayFor4s() {
    if (!mounted) return;
    setState(() {
      _showOverlay = true;
      _zone = _Zone.play;
    });
    if (_player != null) {
      setState(() {
        _position = _player!.state.position;
        _duration = _player!.state.duration;
        _playing  = _player!.state.playing;
      });
    }
    _resetHideTimer();
  }

  void _resetHideTimer() {
    _hideTimer?.cancel();
    if (!_playing) return; // Do NOT hide overlay if video is paused!
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && !_loading && !_autoRetrying) {
        setState(() => _showOverlay = false);
        _focus.requestFocus();
      }
    });
  }

  // ── Playback ────────────────────────────────────────────────────────────────
  List<String> _urls() {
    final s = context.read<AppState>();
    final u = s.username;
    final p = s.password;
    final id = _currentItem.id;
    // Quality-tier-aware candidate list — respects the user's Settings selection.
    // _failoverLevel 0 = user-selected tier, 1 = one step lower, 2 = lowest (360p)
    final tier = _failoverTier(s.qualityTier);
    return IptvService.getLiveStreamUrlCandidatesByQuality(u, p, id, tier);
  }

  /// Returns the actual tier to use based on failover level.
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
    return QualityTier.low360; // Level 2: absolute lowest
  }

  bool _isNonFatalError(String err) {
    final lower = err.toLowerCase();
    if (lower.contains('subtitle')) return true;
    if (lower.contains('unsupported tag')) return true;
    if (lower.contains('skipping')) return true;
    if (lower.contains('matroska/webm: skipping')) return true;
    if (lower.contains('audio track selection')) return true;
    if (lower.contains('no audio') && lower.contains('available')) return true;
    if (lower.startsWith('warning:')) return true;
    if (lower.contains('[warning]')) return true;
    if (lower.contains('demuxer cache')) return true;
    if (lower.contains('cache is full')) return true;
    if (lower.contains('cache underrun')) return true;
    if (lower.contains('end of file') && !lower.contains('failed')) return true;
    if (lower == 'eof' || lower.startsWith('eof ')) return true;
    if (lower.contains('read error') && lower.contains('retry')) return true;
    if (lower.contains('video codec')) return true;
    if (lower.contains('audio codec')) return true;
    if (lower.contains('selected video') || lower.contains('selected audio')) return true;
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

    debugPrint('[Channel] ▶ Starting play | device=${profile.deviceClass} '
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

    // 20-second overall watchdog
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer(const Duration(seconds: 20), () {
      if (!mounted) return;
      debugPrint('⏱ [Channel] 20s watchdog fired');
      _scheduleRetry();
    });

    try {
      // Audio focus is best-effort and takes up to 2 s on some boxes; awaiting
      // it here just delayed the first frame by that much. Fire and forget.
      unawaited(_requestAudio());
      final urls = _urls();

      // PlayerFactory fires all mpv properties concurrently (Future.wait)
      // instead of 20+ sequential awaits — eliminates the ANR on Android.
      final result = await PlayerFactory.probe(
        urls: urls,
        bufBytes: bufBytes,
        hwAccel: hwAccel,
        profile: profile,
        streamHeaders: _streamHeaders,
        isLive: true,
        probeTimeout: const Duration(seconds: 3),
      );

      if (result == null) throw Exception('unavailable: all channel URLs failed');
      if (!mounted) { result.player.dispose(); return; }

      _player    = result.player;
      _videoCtrl = result.controller;
      final successUrl = result.url;
      await result.player.setVolume(_volume);

      // Smart reconnect on stream completion
      _completedSub = result.player.stream.completed.listen((done) {
        if (!done || !mounted) return;
        debugPrint('↺ [Channel] Stream ended — reopening $successUrl');
        Future.delayed(const Duration(milliseconds: 500), () {
          if (mounted && _player != null) {
            _player!.open(Media(successUrl, httpHeaders: _streamHeaders));
          }
        });
      });
      _positionSub = result.player.stream.position.listen((p) {
        if (mounted && _showOverlay && !_draggingProgress) setState(() => _position = p);
      });
      _durationSub = result.player.stream.duration.listen((d) {
        if (mounted && _showOverlay) setState(() => _duration = d);
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
          _syncUiState();
        }
      });

      // Live stall watchdog — if buffering persists for more than 8 seconds,
      // force-reopen the stream. mpv's own reconnect sometimes stalls on
      // mid-segment drops; reopening the URL resets the demuxer cleanly.
      _stallTimer?.cancel();
      _stallTimer = null;
      _bufferingSub = result.player.stream.buffering.listen((b) {
        if (!mounted) return;
        _buffering = b;
        _syncUiState();
        if (b) {
          // Buffering started — start stall watchdog (15s threshold)
          _stallTimer ??= Timer(const Duration(seconds: 15), () {
            _stallTimer = null;
            if (!mounted || _player == null) return;
            debugPrint('⚡ [Channel] Stall watchdog fired — force-reopening $successUrl');
            _player!.open(Media(successUrl, httpHeaders: _streamHeaders)).catchError((_) {});
          });
        } else {
          // Buffering ended — cancel watchdog (stream recovered on its own)
          _stallTimer?.cancel();
          _stallTimer = null;
        }
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
      debugPrint('❌ [Channel] $e');
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
      // ──────────────────────────────────────────────────────────────
      // 3-Level Failover:
      //  Level 0 attempts exhausted → drop to Level 1 (one tier lower quality)
      //  Level 1 attempts exhausted → drop to Level 2 (lowest 360p quality)
      //  Level 2 attempts exhausted → mark stream dead
      // ──────────────────────────────────────────────────────────────
      if (_failoverLevel < 2) {
        _failoverLevel++;
        _attemptNumber = 0;
        debugPrint('[Channel] ↳ Failover Level $_failoverLevel activated (quality degraded silently)');
        // Silent quality switch — restart immediately with lower-quality URLs
        setState(() { _autoRetrying = false; _loading = false; });
        _startPlay();
        return;
      }
      // All 3 failover levels exhausted — mark dead
      if (mounted) {
        setState(() {
          _autoRetrying = false;
          _loading      = false;
          _streamDead   = true;
        });
        _syncUiState(); // FIX #6 — button becomes a retry icon
      }
      debugPrint('❌ [Channel] Stream marked dead after all failover levels exhausted');
      return;
    }

    // Countdown between attempts (5s)
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

  /// Manual retry — resets attempt counter AND failover level so the user
  /// gets a fresh full-quality 3-level cycle.
  void _manualRetry() {
    _retryTimer?.cancel();
    _attemptNumber = 0;
    _failoverLevel = 0; // Reset to full quality on manual retry
    setState(() { _streamDead = false; _autoRetrying = false; });
    _startPlay();
  }

  String _fmtDur(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  void _seekTo(Duration target) {
    if (_player == null) return;
    // Live channels report _duration == 0 (no fixed length), so clamping the
    // upper bound against it would force every forward/back seek to 0.
    // Only clamp the lower bound — mpv itself bounds the seek to whatever is
    // actually available in the live demuxer cache.
    final clamped = target < Duration.zero ? Duration.zero : target;
    _player!.seek(clamped);
  }

  void _togglePlay() {
    if (_player == null) return;
    _player!.playOrPause();
    setState(() => _playing = _player!.state.playing);
    _syncUiState(); // FIX #6
    _resetHideTimer();
  }

  // ── Activate whichever zone the remote cursor is on ─────────────────────────
  void _activateZone() {
    if (_controlsLocked && _zone != _Zone.lock) {
      _showOverlayFor4s();
      return;
    }
    final appState = context.read<AppState>();
    switch (_zone) {
      case _Zone.back:
        _safeExit();
        break;

      case _Zone.lock:
        setState(() {
          _controlsLocked = !_controlsLocked;
        });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
            _controlsLocked ? 'Controls Locked. Press OK on Lock icon to unlock.' : 'Controls Unlocked.',
            style: const TextStyle(color: Colors.white),
          ),
          backgroundColor: _controlsLocked ? Colors.red[800] : Colors.green[800],
          duration: const Duration(seconds: 3),
        ));
        _showOverlayFor4s();
        break;
      case _Zone.fav:
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
      case _Zone.settings:
        _showSettingsMenu();
        break;
      case _Zone.brightness:
        setState(() => _brightness = 1.0);
        _showOverlayFor4s();
        break;
      case _Zone.replay:
        if (_player != null) {
          _player!.seek(_player!.state.position - const Duration(seconds: 10));
          _resetHideTimer();
        }
        break;
      case _Zone.play:
        _togglePlay();
        break;
      case _Zone.forward:
        if (_player != null) {
          _player!.seek(_player!.state.position + const Duration(seconds: 10));
          _resetHideTimer();
        }
        break;
      case _Zone.volume:
        if (_volume > 0) {
          setState(() => _volume = 0.0);
          _player?.setVolume(0.0);
        } else {
          setState(() => _volume = 100.0);
          _player?.setVolume(100.0);
        }
        _showVolumeBarBriefly();
        break;
      case _Zone.progress:
        _togglePlay();
        break;
      case _Zone.aspectRatio:
        _showAspectMenu();
        break;
      case _Zone.speed:
        _showSpeedMenu();
        break;
      case _Zone.subtitles:
        _showSubtitlesMenu();
        break;
      case _Zone.suggestions:
        if (_suggestionIdx < _suggestions.length) {
          final item = _suggestions[_suggestionIdx];
          final p = _player;
          if (p != null) {
            p.stop().catchError((_) => null).then((_) {
              if (mounted) {
                Navigator.pushReplacement(context,
                    MaterialPageRoute(builder: (_) => ChannelPlayerScreen(item: item)));
              }
            });
          } else {
            Navigator.pushReplacement(context,
                MaterialPageRoute(builder: (_) => ChannelPlayerScreen(item: item)));
          }
        }
        break;
    }
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

  void _showSpeedMenu() {
    _hideTimer?.cancel();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black.withOpacity(0.95),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (context) {
        final speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
        return Container(
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Playback Speed', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              ...speeds.map((s) => ListTile(
                focusColor: Colors.white24,
                title: Text('${s}x${s == 1.0 ? " (Normal)" : ""}', style: const TextStyle(color: Colors.white)),
                leading: Icon(Icons.speed, color: _playbackSpeed == s ? AppColors.accent : Colors.white70),
                onTap: () {
                  setState(() {
                    _playbackSpeed = s;
                    _player?.setRate(s);
                  });
                  Navigator.pop(context);
                  _showOverlayFor4s();
                },
              )),
            ],
          ),
        );
      },
    ).then((_) => _resetHideTimer());
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

  // ── Scroll suggestions list to keep focused card visible ────────────────────
  void _scrollSuggestions() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_suggScroll.hasClients) return;
      const cardW = 155.0; // card width + gap
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

  // ── Master key handler — single source of truth for ALL remote navigation ───
  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;

    // Volume keys — always handled (covers ALL brands' remote volume buttons)
    if (k == LogicalKeyboardKey.audioVolumeUp)   { _volumeUp();   return KeyEventResult.handled; }
    if (k == LogicalKeyboardKey.audioVolumeDown) { _volumeDown(); return KeyEventResult.handled; }
    // Mute key — toggle volume between 0 and last level
    if (k == LogicalKeyboardKey.audioVolumeMute || k.keyId == 0x1000000a8) {
      if (_volume > 0) { _volume = 0; } else { _volume = 100; }
      _player?.setVolume(_volume);
      _showVolumeBarBriefly();
      return KeyEventResult.handled;
    }
    // Amazon Fire TV dedicated Play button (keyId 85 = KEYCODE_MEDIA_PLAY on FireOS)
    if (k.keyId == 85) { _togglePlay(); return KeyEventResult.handled; }

    if (_showOverlay) _resetHideTimer();

    // Back / Escape
    final isBack = k == LogicalKeyboardKey.goBack ||
        k == LogicalKeyboardKey.escape ||
        k.keyId == 0x1000000a6 || k.keyId == 166 || k.keyId == 8;
    if (isBack) {
      if (_controlsLocked) {
        return KeyEventResult.handled;
      }
      if (_showOverlay) {
        setState(() => _showOverlay = false);
      } else {
        _safeExit();
      }
      return KeyEventResult.handled;
    }

    // Media keys
    if (k == LogicalKeyboardKey.mediaPlayPause ||
        k == LogicalKeyboardKey.mediaPlay ||
        k == LogicalKeyboardKey.mediaPause) {
      if (!_controlsLocked) _togglePlay();
      return KeyEventResult.handled;
    }

    // Any key while overlay hidden → show overlay
    if (!_showOverlay) {
      setState(() {
        _showOverlay = true;
        if (!_controlsLocked) {
          final isSeekLeft = k == LogicalKeyboardKey.arrowLeft;
          final isSeekRight = k == LogicalKeyboardKey.arrowRight;
          if (isSeekLeft) {
            _zone = _Zone.replay;
          } else if (isSeekRight) {
            _zone = _Zone.forward;
          } else {
            _zone = _Zone.play;
          }
          if (isSeekLeft && _player != null) {
            final target = _player!.state.position - const Duration(seconds: 10);
            _player!.seek(target < Duration.zero ? Duration.zero : (target > _duration ? _duration : target));
          } else if (isSeekRight && _player != null) {
            final target = _player!.state.position + const Duration(seconds: 10);
            _player!.seek(target < Duration.zero ? Duration.zero : (target > _duration ? _duration : target));
          }
        } else {
          _zone = _Zone.lock;
        }
      });
      _resetHideTimer();
      return KeyEventResult.handled;
    }

    // Controls Locked Guard: restrict navigation when locked
    if (_controlsLocked) {
      if (k == LogicalKeyboardKey.select ||
          k == LogicalKeyboardKey.enter ||
          k == LogicalKeyboardKey.gameButtonA ||
          k == LogicalKeyboardKey.numpadEnter ||
          k.keyId == 13 || k.keyId == 23 || k.keyId == 66) {
        if (_zone == _Zone.lock) {
          _activateZone();
        }
        return KeyEventResult.handled;
      }
      setState(() => _zone = _Zone.lock);
      return KeyEventResult.handled;
    }

    // Select / Enter → activate current zone
    final isSelect = k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.gameButtonA ||
        k == LogicalKeyboardKey.numpadEnter ||
        k.keyId == 13 || k.keyId == 23 || k.keyId == 66 || k.keyId == 96 ||
        k.keyId == 107 || k.keyId == 160 || k.keyId == 0x10000042 ||
        k.keyId == 0x10000017 || k.keyId == 0x100000017 || k.keyId == 0x1100000017;
    if (isSelect) {
      _activateZone();
      return KeyEventResult.handled;
    }

    // ── Arrow navigation ──────────────────────────────────────────────────────
    if (k == LogicalKeyboardKey.arrowLeft) {
      setState(() {
        switch (_zone) {
          case _Zone.lock:     _zone = _Zone.back; break;
          case _Zone.fav:      _zone = _Zone.lock; break;
          case _Zone.settings: _zone = _Zone.fav; break;
          case _Zone.replay:   break;
          case _Zone.play:     _zone = _Zone.replay; break;
          case _Zone.forward:  _zone = _Zone.play; break;
          case _Zone.progress:
            if (_player != null) {
              final target = _player!.state.position - const Duration(seconds: 10);
              _player!.seek(target < Duration.zero ? Duration.zero : (target > _duration ? _duration : target));
            }
            break;
          case _Zone.speed:       _zone = _Zone.aspectRatio; break;
          case _Zone.subtitles:   _zone = _Zone.speed; break;
          default: break;
        }
      });
      return KeyEventResult.handled;
    }

    if (k == LogicalKeyboardKey.arrowRight) {
      setState(() {
        switch (_zone) {
          case _Zone.back:       _zone = _Zone.lock; break;
          case _Zone.lock:       _zone = _Zone.fav; break;
          case _Zone.fav:        _zone = _Zone.settings; break;
          case _Zone.replay:     _zone = _Zone.play; break;
          case _Zone.play:       _zone = _Zone.forward; break;
          case _Zone.forward:    break;
          case _Zone.progress:
            if (_player != null) {
              final target = _player!.state.position + const Duration(seconds: 10);
              _player!.seek(target < Duration.zero ? Duration.zero : (target > _duration ? _duration : target));
            }
            break;
          case _Zone.aspectRatio: _zone = _Zone.speed; break;
          case _Zone.speed:       _zone = _Zone.subtitles; break;
          default: break;
        }
      });
      return KeyEventResult.handled;
    }

    if (k == LogicalKeyboardKey.arrowUp) {
      setState(() {
        switch (_zone) {
          case _Zone.replay:      _zone = _Zone.back; break;
          case _Zone.play:        _zone = _Zone.lock; break;
          case _Zone.forward:     _zone = _Zone.fav; break;
          case _Zone.progress:    _zone = _Zone.play; break;
          case _Zone.aspectRatio:
          case _Zone.speed:
          case _Zone.subtitles:
            _zone = _Zone.progress;
            break;
          default: break;
        }
      });
      return KeyEventResult.handled;
    }

    if (k == LogicalKeyboardKey.arrowDown) {
      setState(() {
        switch (_zone) {
          case _Zone.back:        _zone = _Zone.replay; break;
          case _Zone.lock:
            _zone = _Zone.play;
            break;
          case _Zone.fav:
          case _Zone.settings:
            _zone = _Zone.forward;
            break;
          case _Zone.replay:
          case _Zone.play:
          case _Zone.forward:
            _zone = _Zone.progress;
            break;
          case _Zone.progress:
            _zone = _Zone.speed;
            break;
          default: break;
        }
      });
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  // ── Visual helper: focused circle button ────────────────────────────────────
  Widget _circleBtn({
    required _Zone zone,
    required Widget icon,
    double size = 44,
    bool hasBg = true,
  }) {
    final focused = _zone == zone;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: focused
            ? (zone == _Zone.play ? Colors.transparent : Colors.white.withValues(alpha: 0.24))
            : (hasBg ? Colors.white.withValues(alpha: 0.12) : Colors.transparent),
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

  // ── Suggestions ─────────────────────────────────────────────────────────────
  void _buildSuggestions(AppState state) {
    final all = state.channels;
    final idx = all.indexWhere((c) => c.id == _currentItem.id);
    _suggestions = [];
    if (idx != -1) {
      for (int i = 1; i <= 20; i++) {
        final next = all[(idx + i) % all.length];
        if (next.id != _currentItem.id) _suggestions.add(next);
      }
    }
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

              // ── VIDEO ─────────────────────────────────────────────────
              // ── VIDEO or OPAQUE LOADING SCREEN ──────────────────────────
              // IMPORTANT: During loading we show a fully opaque black screen
              // so the previous route (home screen) is never visible behind
              // the player — fixes the semi-transparent overlay / UI bleed.
              if (_videoCtrl != null && !_loading)
                Video(controller: _videoCtrl!, controls: NoVideoControls, fit: _videoFit)
              else
                Container(
                  color: Colors.black,
                ),

              // ── BRIGHTNESS DIMMING OVERLAY ────────────────────────────
              IgnorePointer(
                child: Container(
                  color: Colors.black.withOpacity((1.0 - _brightness).clamp(0.0, 0.85)),
                ),
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
                        const Icon(Icons.signal_wifi_statusbar_connected_no_internet_4,
                            color: Colors.white38, size: 56),
                        const SizedBox(height: 20),
                        const Text('Stream Unavailable',
                            style: TextStyle(color: Colors.white, fontSize: 18,
                                fontWeight: FontWeight.w700)),
                        const SizedBox(height: 8),
                        Text(
                          '${_currentItem.title} could not be loaded\nafter $_maxAttempts attempts.',
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

              // ── OVERLAY: visual gradients + channel info (non-interactive) ──
              AnimatedOpacity(
                opacity: _showOverlay ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 300),
                child: IgnorePointer(
                  ignoring: true, // NEVER intercepts touch events
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
                    excluding: true, // root _focus handles all D-pad key events
                    // FIX #12: video and gradients stay full-bleed;
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
                                        zone: _Zone.back,
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
                                        zone: _Zone.lock,
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
                                          zone: _Zone.fav,
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
                                          zone: _Zone.settings,
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

                        if (!_controlsLocked && !_streamDead) ...[

                          // ── CENTER PLAYBACK CONTROLS ────
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
                                    child: _circleBtn(
                                      zone: _Zone.replay,
                                      size: 56,
                                      icon: const Icon(Icons.replay_10, color: Colors.white, size: 32),
                                      hasBg: false,
                                    ),
                                  ),
                                  const SizedBox(width: 32),
                                  // Play/Pause / Loading Spinner
                                  GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTap: () {
                                      _togglePlay();
                                      _showOverlayFor4s();
                                    },
                                    child: _circleBtn(
                                      zone: _Zone.play,
                                      size: 72,
                                      // FIX #6 — single state-driven glyph, cross-faded.
                                      icon: playPauseGlyph(_uiState),
                                      hasBg: false,
                                    ),
                                  ),
                                  const SizedBox(width: 32),
                                  // +10s
                                  GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTap: () {
                                      if (_player != null) _seekTo(_player!.state.position + const Duration(seconds: 10));
                                      _showOverlayFor4s();
                                    },
                                    child: _circleBtn(
                                      zone: _Zone.forward,
                                      size: 56,
                                      icon: const Icon(Icons.forward_10, color: Colors.white, size: 32),
                                      hasBg: false,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),

                          // ── BOTTOM CONTROLS: SeekBar + Action Buttons + Suggestions ──
                          Positioned(
                            bottom: 0, left: 60, right: 60,
                            child: SafeArea(
                              top: false,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // SeekBar Row
                                  Row(
                                    children: [
                                      Text(
                                        _fmtDur(_draggingProgress ? _dragPosition : _position),
                                        style: const TextStyle(color: Colors.white70, fontSize: 12),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: LayoutBuilder(
                                          builder: (ctx, constraints) {
                                            final barWidth = constraints.maxWidth;
                                            final displayPct = _duration.inMilliseconds > 0
                                                ? ((_draggingProgress ? _dragPosition : _position).inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0)
                                                : 0.0;
                                            final isFocused = _zone == _Zone.progress;
                                            final isActive = isFocused || _draggingProgress;

                                            Duration dxToPos(double dx) {
                                              if (_duration.inMilliseconds == 0) return Duration.zero;
                                              final pct = (dx / barWidth).clamp(0.0, 1.0);
                                              return Duration(milliseconds: (pct * _duration.inMilliseconds).toInt());
                                            }

                                            return GestureDetector(
                                              behavior: HitTestBehavior.opaque,
                                              onTapDown: (d) {
                                                if (_duration.inMilliseconds == 0) return;
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
                                              onHorizontalDragStart: (d) {
                                                if (_duration.inMilliseconds == 0) return;
                                                _hideTimer?.cancel();
                                                setState(() {
                                                  _draggingProgress = true;
                                                  _dragPosition = dxToPos(d.localPosition.dx);
                                                });
                                              },
                                              onHorizontalDragUpdate: (d) {
                                                if (_duration.inMilliseconds == 0) return;
                                                setState(() => _dragPosition = dxToPos(d.localPosition.dx));
                                              },
                                              onHorizontalDragEnd: (_) {
                                                if (_duration.inMilliseconds == 0) return;
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
                                                    Container(
                                                      height: 4,
                                                      width: double.infinity,
                                                      decoration: BoxDecoration(
                                                        color: Colors.white24,
                                                        borderRadius: BorderRadius.circular(2),
                                                      ),
                                                    ),
                                                    FractionallySizedBox(
                                                      widthFactor: displayPct,
                                                      child: Container(
                                                        height: 4,
                                                        decoration: BoxDecoration(
                                                          color: isFocused ? AppColors.accent : Colors.white,
                                                          borderRadius: BorderRadius.circular(2),
                                                        ),
                                                      ),
                                                    ),
                                                    Positioned(
                                                      left: (barWidth * displayPct).clamp(0.0, barWidth - 10),
                                                      child: Container(
                                                        width: 10, height: 10,
                                                        decoration: const BoxDecoration(
                                                          color: Colors.white,
                                                          shape: BoxShape.circle,
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
                                      const SizedBox(width: 8),
                                      Text(
                                        _duration.inMilliseconds > 0 ? _fmtDur(_duration) : 'LIVE',
                                        style: TextStyle(
                                          color: _duration.inMilliseconds > 0 ? Colors.white70 : AppColors.live,
                                          fontSize: 12,
                                          fontWeight: _duration.inMilliseconds > 0 ? FontWeight.normal : FontWeight.bold,
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
                                          zone: _Zone.aspectRatio,
                                          icon: Icons.aspect_ratio,
                                          label: 'Aspect Ratio',
                                          onTap: _showAspectMenu,
                                        ),
                                        const SizedBox(width: 24),
                                        _bottomActionBtn(
                                          zone: _Zone.speed,
                                          icon: Icons.speed,
                                          label: 'Speed (${_playbackSpeed}x)',
                                          onTap: _showSpeedMenu,
                                        ),
                                        const SizedBox(width: 24),
                                        _bottomActionBtn(
                                          zone: _Zone.subtitles,
                                          icon: Icons.closed_caption,
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
                        ],
                      ],
                    ),
                    ), // FIX #12 TvSafeArea
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

  Widget _verticalSlider({
    required IconData icon,
    required double value, // 0.0 to 1.0
    required bool focused,
    required _Zone zone,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: (details) {
        final dy = details.primaryDelta ?? 0;
        final change = -dy / 140.0;
        if (zone == _Zone.brightness) {
          setState(() {
            _brightness = (_brightness + change).clamp(0.1, 1.0);
          });
        } else {
          setState(() {
            _volume = (_volume + change * 100.0).clamp(0.0, 100.0);
            _player?.setVolume(_volume);
          });
        }
        _showOverlayFor4s();
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white70, size: 20),
          const SizedBox(height: 8),
          Container(
            width: 14,
            height: 140,
            decoration: BoxDecoration(
              color: Colors.white12,
              borderRadius: BorderRadius.circular(7),
              border: Border.all(
                color: focused ? AppColors.accent : Colors.white24,
                width: focused ? 2.0 : 1.0,
              ),
              boxShadow: focused
                  ? [BoxShadow(color: AppColors.accent.withOpacity(0.4), blurRadius: 10)]
                  : null,
            ),
            child: Stack(
              alignment: Alignment.bottomCenter,
              children: [
                FractionallySizedBox(
                  heightFactor: value.clamp(0.0, 1.0),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(7),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _bottomActionBtn({
    required _Zone zone,
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

// ── Minimal suggestion card (no focus handling — root FocusNode manages everything) ──
class _SuggCard extends StatelessWidget {
  final ContentItem item;
  const _SuggCard({required this.item});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF1A1A2E),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              children: [
                SizedBox(
                  width: double.infinity,
                  child: item.imageUrl.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: item.imageUrl,
                          fit: BoxFit.contain,
                          memCacheWidth: 300,
                          errorWidget: (_, __, ___) => _fallback(item),
                        )
                      : _fallback(item),
                ),
                Positioned(
                  top: 5, right: 5,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppColors.live,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(width: 5, height: 5,
                            decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle)),
                        const SizedBox(width: 3),
                        const Text('LIVE',
                            style: TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.w700)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(7, 4, 7, 1),
            child: Text(item.title,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: Colors.white70)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(7, 0, 7, 5),
            child: Text(
              item.channelNumber != null ? 'Ch. ${item.channelNumber}' : (item.category ?? ''),
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10, color: Colors.white38),
            ),
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
