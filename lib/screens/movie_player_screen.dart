import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/content_model.dart';
import '../theme/app_theme.dart';
import '../services/app_state.dart';
import '../services/iptv_service.dart';
import '../services/device_profile_service.dart';
import '../utils/tv_remote_normalizer.dart';

const _movieAudioCh = MethodChannel('com.example.mbapp/audio');

/// TV navigation zones in the movie overlay
enum _MZone { back, fav, replay, play, forward, progress, suggestions }

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
  final BoxFit _videoFit = BoxFit.contain;

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

  double _volume = 80.0;
  bool _showVolumeBar = false;
  Timer? _hideVolumeTimer;

  bool   _showOverlay = true;
  Timer? _hideTimer;

  // ── Phone touch seek state ───────────────────────────────────────────────────
  bool     _draggingProgress = false;
  Duration _dragPosition     = Duration.zero;

  // ── TV navigation state ──────────────────────────────────────────────────────
  _MZone _zone = _MZone.play;
  int    _suggestionIdx = 0;
  List<ContentItem> _suggestions = [];
  final ScrollController _suggScroll = ScrollController();

  StreamSubscription? _completedSub;
  StreamSubscription? _positionSub;
  StreamSubscription? _durationSub;
  StreamSubscription? _playingSub;

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
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
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
    _focus.removeListener(_onFocusChange);
    _hideTimer?.cancel();
    _retryTimer?.cancel();
    _hideVolumeTimer?.cancel();
    _suggScroll.dispose();
    _focus.dispose();
    _completedSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _playingSub?.cancel();
    _player?.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual,
        overlays: SystemUiOverlay.values);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    super.dispose();
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
    if (!mounted) return;

    // Read player settings BEFORE any await — safe synchronous context access.
    final appState   = context.read<AppState>();
    final hwAccel    = appState.hardwareAccelEnabled;
    final bufBytes   = appState.bufferBytes;   // RAM-aware
    final profile    = _profile;

    debugPrint('[Movie] ▶ ${_currentItem.title} | device=${profile.deviceClass} '
        'hevc=${profile.supportsHevc} hdr=${profile.supportsHdr} '
        'buf=${bufBytes ~/ (1024 * 1024)}MB failoverLevel=$_failoverLevel');

    setState(() {
      _loading      = true;
      _autoRetrying = false;
      _streamDead   = false;
      _position     = Duration.zero;
      _duration     = Duration.zero;
      _playing      = false;
    });

    _completedSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _playingSub?.cancel();
    _player?.dispose();
    _videoCtrl = null;
    _player    = null;

    try {
      await _requestAudio();
      final urls = _movieUrls();

      final player = Player(
        configuration: PlayerConfiguration(
          bufferSize: bufBytes,
          logLevel: MPVLogLevel.warn,
        ),
      );

      // Universal mpv configuration — same brand coverage as channel player.
      final platform = player.platform;
      if (platform is NativePlayer) {
        // ── Caching & buffering ──
        await platform.setProperty('cache', 'yes');
        await platform.setProperty('cache-secs', '60');             // 60s for VOD
        await platform.setProperty('demuxer-readahead-secs', '30');
        await platform.setProperty('demuxer-max-bytes', '$bufBytes');
        await platform.setProperty('demuxer-max-back-bytes', '${bufBytes ~/ 4}');
        await platform.setProperty('demuxer-thread', 'yes');

        // ── Network & reconnect ──
        // Increased timeout + retries for flaky IPTV CDNs and slow ISPs worldwide
        await platform.setProperty('network-timeout', '20');
        await platform.setProperty('reconnect-streamed', 'yes');
        await platform.setProperty('reconnect-max-retries', '10');
        await platform.setProperty('reconnect-delay-max', '4');
        await platform.setProperty('stream-lavf-o',
            'reconnect=1,reconnect_streamed=1,reconnect_delay_max=4,listen_timeout=20000');

        // ── AES-128 HLS & encrypted stream support ──
        await platform.setProperty('demuxer-lavf-o',
            'allowed_extensions=ALL,'
            'protocol_whitelist=file,http,https,tcp,tls,crypto,data,ftp');
        await platform.setProperty('tls-verify', 'no');
        await platform.setProperty('tls-min-version', '1.0');

        // ── Seeking (VOD) ──
        await platform.setProperty('force-seekable', 'yes');
        await platform.setProperty('hr-seek', 'yes');

        // ── Device-specific HTTP headers ──
        final ua      = profile.userAgent;
        const referer = '${IptvService.baseUrl}/';
        const origin  = IptvService.baseUrl;
        await platform.setProperty('http-header-fields',
            'User-Agent: $ua\nReferer: $referer\nOrigin: $origin\nAccept: */*\nConnection: keep-alive');

        // ── Codec / decoding ──
        await platform.setProperty('hwdec', hwAccel ? 'auto-safe' : 'no');
        await platform.setProperty('vd-lavc-threads', '0');
        await platform.setProperty('vd-lavc-skiploopfilter', 'nonref');
        await platform.setProperty('vd-lavc-software-fallback', 'yes');
        await platform.setProperty('framedrop', 'decoder+vo');

        // ── H.264 force for HEVC-unsupported devices ──
        if (profile.forceH264) {
          await platform.setProperty('vd-lavc-vcodec', 'h264');
          debugPrint('[Movie] H.264 forced (no HEVC decoder)');
        }

        // ── HDR disable on SDR-only displays ──
        if (profile.disableHdr) {
          await platform.setProperty('tone-mapping', 'clip');
          await platform.setProperty('hdr-compute-peak', 'no');
          debugPrint('[Movie] HDR tone-mapping disabled (SDR display)');
        }

        // ── Video output & sync ──
        await platform.setProperty('gpu-api', 'opengl');
        await platform.setProperty('opengl-es', '2');
        await platform.setProperty('opengl-glfinish', 'yes');
        await platform.setProperty('video-sync', 'audio');
        await platform.setProperty('video-latency-hacks',
            profile.enableLatencyHacks ? 'yes' : 'no');

        // ── Audio ──
        await platform.setProperty('audio-stream-silence', 'yes');
        await platform.setProperty('audio-spdif', '');

        // ── Misc ──
        await platform.setProperty('ytdl', 'no');
        // Larger probe size + duration — better stream format detection for
        // TS/HLS streams from non-standard IPTV encoders (fixes seek issues)
        await platform.setProperty('demuxer-lavf-analyzeduration', '5');
        await platform.setProperty('demuxer-lavf-probesize', '5242880');
      }

      final ctrl = VideoController(
        player,
        configuration: VideoControllerConfiguration(enableHardwareAcceleration: hwAccel),
      );

      bool ok = false;
      String? lastError;

      // 12s per-URL probe timeout — fast enough to try all candidates in <60s
      const probeTimeout = Duration(seconds: 12);

      for (final url in urls) {
        try {
          debugPrint('▶ [Movie] Trying: $url');

          // ── Fast health-check: skip obviously dead URLs immediately ──────
          // HEAD request takes <1s and avoids wasting 12s on 403/404 endpoints.
          final alive = await IptvService.streamHealthCheck(url)
              .timeout(const Duration(seconds: 4), onTimeout: () => true);
          if (!alive) {
            debugPrint('✗ [Movie] Health-check failed — skipping $url');
            lastError = 'server returned error status';
            continue;
          }

          // Collect the FIRST fatal error (ignore non-fatal warnings)
          String? fatalError;
          final errSub = player.stream.error.listen((err) {
            if (fatalError == null && !_isNonFatalError(err)) {
              fatalError = err;
            }
            debugPrint('⚠ [Movie] Stream error for $url: $err');
          });

          await player.open(Media(url, httpHeaders: _streamHeaders));

          // ── Relaxed success gate ──────────────────────────────────────────
          // Accept ANY of the following as proof the stream is alive:
          //   (a) playing=true           — audio/video decoder started
          //   (b) width > 0              — video frame decoded
          //   (c) duration > 0 + buffering→false — metadata + data arrived
          // This fixes streams that start playing before sending a duration,
          // and streams that send duration before the first video frame.
          final successCompleter = Completer<void>();
          bool gotDuration = false;
          bool gotWidth    = false;
          bool gotPlaying  = false;
          bool hasBuffered = false;

          void checkSuccess() {
            if (successCompleter.isCompleted) return;
            // Gate 1: playing alone is enough — decoder confirmed active
            if (gotPlaying) { successCompleter.complete(); return; }
            // Gate 2: video frame seen
            if (gotWidth)   { successCompleter.complete(); return; }
            // Gate 3: metadata + buffer cycle completed
            if (gotDuration && hasBuffered) { successCompleter.complete(); return; }
          }

          final widthSub = player.stream.width.listen((w) {
            if (w != null && w > 0) { gotWidth = true; checkSuccess(); }
          });
          final durSub = player.stream.duration.listen((d) {
            if (d.inMilliseconds > 0) { gotDuration = true; checkSuccess(); }
          });
          final playingSub = player.stream.playing.listen((playing) {
            if (playing) { gotPlaying = true; checkSuccess(); }
          });
          final bufferingSub = player.stream.buffering.listen((buffering) {
            if (buffering) {
              hasBuffered = true;
            } else if (hasBuffered) {
              // Buffering completed → data arrived
              checkSuccess();
            }
          });

          final result = await Future.any([
            successCompleter.future.then((_) => 'ok'),
            Future.delayed(probeTimeout).then((_) => 'timeout'),
          ]);

          await widthSub.cancel();
          await durSub.cancel();
          await bufferingSub.cancel();
          await playingSub.cancel();
          await errSub.cancel();

          if (result == 'timeout' || fatalError != null) {
            final reason = fatalError ?? 'timeout after ${probeTimeout.inSeconds}s';
            debugPrint('✗ [Movie] Failed $url: $reason');
            lastError = reason;
            continue;
          }

          debugPrint('✅ [Movie] Playing: $url');
          ok = true;
          break;
        } catch (e) {
          lastError = e.toString();
          debugPrint('✗ [Movie] Exception $url: $e');
        }
      }

      if (!ok) {
        player.dispose();
        throw Exception('All URLs failed. Last error: $lastError');
      }

      if (!mounted) { player.dispose(); return; }

      _player    = player;
      _videoCtrl = ctrl;
      await player.setVolume(_volume);

      _completedSub = player.stream.completed.listen((done) {
        if (done && mounted) {
          setState(() { _position = _duration; });
        }
      });
      _positionSub = player.stream.position.listen((p) {
        if (mounted && _showOverlay) setState(() => _position = p);
      });
      _durationSub = player.stream.duration.listen((d) {
        if (mounted) setState(() => _duration = d);
      });
      _playingSub = player.stream.playing.listen((p) {
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
        }
      });

      if (!mounted) return;
      setState(() => _loading = false);
      _showOverlayFor4s();
      await _requestAudio();
    } catch (e) {
      debugPrint('❌ [Movie] $e');
      if (!mounted) return;
      _scheduleRetry();
    }
  }

  void _scheduleRetry() {
    _retryTimer?.cancel();
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
      }
      debugPrint('❌ [Movie] Stream marked dead after all failover levels exhausted');
      return;
    }

    setState(() {
      _autoRetrying    = true;
      _loading         = false;
      _retryCountdown  = 5;
    });
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
    _player!.seek(clamped);
  }

  void _togglePlay() {
    if (_player == null) return;
    _player!.playOrPause();
    setState(() => _playing = _player!.state.playing);
    _resetHideTimer();
  }

  // ── Activate whichever zone the remote cursor is on ──────────────────────────
  void _activateZone() {
    final appState = context.read<AppState>();
    switch (_zone) {
      case _MZone.back:
        _player?.pause();
        Navigator.of(context).pop();
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
      case _MZone.suggestions:
        if (_suggestionIdx < _suggestions.length) {
          final item = _suggestions[_suggestionIdx];
          _player?.pause();
          Navigator.pushReplacement(context,
              MaterialPageRoute(builder: (_) => MoviePlayerScreen(item: item)));
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
    final action = TvRemoteNormalizer.normalize(e);
    if (action == TvNavAction.none) return KeyEventResult.ignored;

    // Volume
    if (action == TvNavAction.volumeUp)   { _volumeUp();   return KeyEventResult.handled; }
    if (action == TvNavAction.volumeDown) { _volumeDown(); return KeyEventResult.handled; }
    if (action == TvNavAction.mute) {
      _volume = _volume > 0 ? 0 : 80;
      _player?.setVolume(_volume);
      _showVolumeBarBriefly();
      return KeyEventResult.handled;
    }

    // Media transport
    if (action == TvNavAction.play  ||
        action == TvNavAction.pause ||
        action == TvNavAction.playPause) {
      _togglePlay();
      return KeyEventResult.handled;
    }

    if (_showOverlay) _resetHideTimer();

    // Back
    if (action == TvNavAction.back) {
      if (_showOverlay) {
        setState(() => _showOverlay = false);
      } else {
        _player?.pause();
        Navigator.of(context).pop();
      }
      return KeyEventResult.handled;
    }

    // Any key while overlay hidden → show overlay (+ seek on Left/Right)
    if (!_showOverlay) {
      setState(() {
        _showOverlay = true;
        if (action == TvNavAction.left) {
          _zone = _MZone.replay;
        } else if (action == TvNavAction.right) {
          _zone = _MZone.forward;
        } else {
          _zone = _MZone.play;
        }
      });
      _resetHideTimer();
      if (action == TvNavAction.left && _player != null) {
        final t = _player!.state.position - const Duration(seconds: 10);
        _player!.seek(t < Duration.zero ? Duration.zero : (t > _duration ? _duration : t));
      } else if (action == TvNavAction.right && _player != null) {
        final t = _player!.state.position + const Duration(seconds: 10);
        _player!.seek(t < Duration.zero ? Duration.zero : (t > _duration ? _duration : t));
      }
      return KeyEventResult.handled;
    }

    // Select → activate current zone
    if (action == TvNavAction.select) {
      _activateZone();
      return KeyEventResult.handled;
    }

    // ── D-pad zone navigation ─────────────────────────────────────────────────
    if (action == TvNavAction.left) {
      setState(() {
        switch (_zone) {
          case _MZone.fav:     _zone = _MZone.back; break;
          case _MZone.play:    _zone = _MZone.replay; break;
          case _MZone.forward: _zone = _MZone.play; break;
          case _MZone.progress:
            if (_player != null) {
              final t = _player!.state.position - const Duration(minutes: 1);
              _player!.seek(t < Duration.zero ? Duration.zero : (t > _duration ? _duration : t));
            }
            break;
          case _MZone.suggestions:
            if (_suggestionIdx > 0) { _suggestionIdx--; _scrollSuggestions(); }
            break;
          default: break;
        }
      });
      return KeyEventResult.handled;
    }

    if (action == TvNavAction.right) {
      setState(() {
        switch (_zone) {
          case _MZone.back:    _zone = _MZone.fav; break;
          case _MZone.replay:  _zone = _MZone.play; break;
          case _MZone.play:    _zone = _MZone.forward; break;
          case _MZone.progress:
            if (_player != null) {
              final t = _player!.state.position + const Duration(minutes: 1);
              _player!.seek(t < Duration.zero ? Duration.zero : (t > _duration ? _duration : t));
            }
            break;
          case _MZone.suggestions:
            if (_suggestionIdx < _suggestions.length - 1) { _suggestionIdx++; _scrollSuggestions(); }
            break;
          default: break;
        }
      });
      return KeyEventResult.handled;
    }

    if (action == TvNavAction.up) {
      setState(() {
        switch (_zone) {
          case _MZone.replay:
          case _MZone.play:      _zone = _MZone.back; break;
          case _MZone.forward:   _zone = _MZone.fav; break;
          case _MZone.progress:  _zone = _MZone.play; break;
          case _MZone.suggestions:
            _zone = _duration.inMilliseconds > 0 ? _MZone.progress : _MZone.play;
            break;
          default: break;
        }
      });
      return KeyEventResult.handled;
    }

    if (action == TvNavAction.down) {
      setState(() {
        switch (_zone) {
          case _MZone.back:
          case _MZone.fav:    _zone = _MZone.play; break;
          case _MZone.replay:
          case _MZone.play:
          case _MZone.forward:
            if (_duration.inMilliseconds > 0) {
              _zone = _MZone.progress;
            } else if (_suggestions.isNotEmpty) {
              _zone = _MZone.suggestions;
              _scrollSuggestions();
            }
            break;
          case _MZone.progress:
            if (_suggestions.isNotEmpty) {
              _zone = _MZone.suggestions;
              _scrollSuggestions();
            }
            break;
          default: break;
        }
      });
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  // ── Visual helper: focused circle button ─────────────────────────────────────
  Widget _circleBtn({
    required _MZone zone,
    required Widget icon,
    double size = 52,
    Color? defaultBg,
  }) {
    final focused = _zone == zone;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: focused ? AppColors.accent : (defaultBg ?? Colors.black.withValues(alpha: 0.65)),
        border: Border.all(
          color: focused ? Colors.white : Colors.white24,
          width: focused ? 2.5 : 1.5,
        ),
        boxShadow: focused
            ? [BoxShadow(color: AppColors.accent.withValues(alpha: 0.55), blurRadius: 18, spreadRadius: 2)]
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

    return Focus(
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

              // ── VIDEO ─────────────────────────────────────────────────
              if (_videoCtrl != null && !_loading)
                Video(controller: _videoCtrl!, controls: NoVideoControls, fit: _videoFit)
              else
                _thumbnail(_currentItem),

              // ── LOADING ───────────────────────────────────────────────
              if (_loading)
                Container(
                  color: Colors.black54,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(
                          valueColor: AlwaysStoppedAnimation<Color>(AppColors.accent),
                          strokeWidth: 3,
                        ),
                        const SizedBox(height: 16),
                        Text('Loading ${_currentItem.title}…',
                            style: const TextStyle(color: Colors.white70, fontSize: 14)),
                      ],
                    ),
                  ),
                ),

              // ── RETRY ─────────────────────────────────────────────────
              if (_autoRetrying)
                Container(
                  color: Colors.black87,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 28, height: 28,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            valueColor: AlwaysStoppedAnimation<Color>(AppColors.accent),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Attempt $_attemptNumber of $_maxAttempts — reconnecting in ${_retryCountdown}s…',
                          style: const TextStyle(color: Colors.white70, fontSize: 14),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 12),
                        TextButton(
                          onPressed: () {
                            _retryTimer?.cancel();
                            setState(() => _autoRetrying = false);
                            _startPlay();
                          },
                          child: const Text('Retry Now',
                              style: TextStyle(color: AppColors.accent, fontSize: 14)),
                        ),
                      ],
                    ),
                  ),
                ),

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
                            _player?.pause();
                            Navigator.of(context).pop();
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
                      // Title area (no interaction needed)
                      Positioned(
                        top: 0, left: 0, right: 0,
                        child: SafeArea(
                          bottom: false,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                            child: Row(
                              children: [
                                // Back placeholder (not interactive here)
                                const SizedBox(width: 44),
                                const SizedBox(width: 10),
                                if (_currentItem.imageUrl.isNotEmpty) ...[
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(6),
                                    child: CachedNetworkImage(
                                      imageUrl: _currentItem.imageUrl,
                                      width: 36, height: 50,
                                      fit: BoxFit.cover,
                                      errorWidget: (_, __, ___) => const SizedBox.shrink(),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                ],
                                Expanded(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(_currentItem.title,
                                          style: const TextStyle(color: Colors.white, fontSize: 17,
                                              fontWeight: FontWeight.w700),
                                          maxLines: 1, overflow: TextOverflow.ellipsis),
                                      if (_currentItem.year != null) ...[
                                        const SizedBox(height: 2),
                                        Text(
                                          '${_currentItem.year}'
                                          '${_currentItem.genre != null ? '  \u2022  ${_currentItem.genre}' : ''}',
                                          style: const TextStyle(color: Colors.white60, fontSize: 11),
                                        ),
                                      ],
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
                    child: Stack(
                      fit: StackFit.expand,
                      children: [

                        // ── TOP BAR: Back + Fav (large 48dp touch targets) ────
                        Positioned(
                          top: 0, left: 0, right: 0,
                          child: SafeArea(
                            bottom: false,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                              child: Row(
                                children: [
                                  // Back button — larger touch target
                                  GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTap: () {
                                      _player?.pause();
                                      Navigator.of(context).pop();
                                    },
                                    child: Padding(
                                      padding: const EdgeInsets.all(8),
                                      child: _circleBtn(
                                        zone: _MZone.back,
                                        size: 44,
                                        icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white, size: 20),
                                      ),
                                    ),
                                  ),
                                  const Spacer(),
                                  // Fav button — larger touch target
                                  GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTap: () {
                                      appState.toggleFavorite(_currentItem);
                                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                        content: Text(
                                          appState.isFavorite(_currentItem.id)
                                              ? 'Added to My List'
                                              : 'Removed from My List',
                                          style: const TextStyle(color: Colors.white),
                                        ),
                                        backgroundColor: AppColors.bg4,
                                        duration: const Duration(seconds: 2),
                                      ));
                                      setState(() {});
                                      _resetHideTimer();
                                    },
                                    child: Padding(
                                      padding: const EdgeInsets.all(8),
                                      child: _circleBtn(
                                        zone: _MZone.fav,
                                        size: 44,
                                        icon: Icon(
                                          isFav ? Icons.favorite : Icons.favorite_border,
                                          color: (_zone == _MZone.fav)
                                              ? Colors.white
                                              : (isFav ? AppColors.accent : Colors.white),
                                          size: 22,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),

                        // ── BOTTOM: controls + progress + suggestions ──────────
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

                                  // ── Playback controls row (large touch targets) ──
                                  Center(
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
                                              icon: const Icon(Icons.replay_10, color: Colors.white, size: 28),
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
                                          child: AnimatedContainer(
                                            duration: const Duration(milliseconds: 150),
                                            width: 72, height: 72,
                                            decoration: BoxDecoration(
                                              shape: BoxShape.circle,
                                              color: _zone == _MZone.play ? Colors.white : AppColors.accent,
                                              border: Border.all(
                                                color: _zone == _MZone.play ? AppColors.accent : Colors.transparent,
                                                width: 3,
                                              ),
                                              boxShadow: [
                                                BoxShadow(
                                                  color: AppColors.accent.withValues(alpha: _zone == _MZone.play ? 0.7 : 0.4),
                                                  blurRadius: _zone == _MZone.play ? 24 : 14,
                                                  spreadRadius: 2,
                                                ),
                                              ],
                                            ),
                                            child: Center(
                                              child: Icon(
                                                _playing ? Icons.pause : Icons.play_arrow,
                                                color: _zone == _MZone.play ? AppColors.accent : Colors.white,
                                                size: 40,
                                              ),
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
                                              icon: const Icon(Icons.forward_10, color: Colors.white, size: 28),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),

                                  const SizedBox(height: 12),

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
                                                          color: AppColors.accent,
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

                                  const SizedBox(height: 10),

                                  // ── More movies suggestions ──────────────────
                                  if (_suggestions.isNotEmpty) ...[
                                    const Text('More Movies',
                                        style: TextStyle(color: Colors.white, fontSize: 13,
                                            fontWeight: FontWeight.bold, fontFamily: 'Inter')),
                                    const SizedBox(height: 8),
                                    SizedBox(
                                      height: 155,
                                      child: ListView.separated(
                                        controller: _suggScroll,
                                        scrollDirection: Axis.horizontal,
                                        itemCount: _suggestions.length,
                                        separatorBuilder: (_, __) => const SizedBox(width: 10),
                                        itemBuilder: (ctx, i) {
                                          final item = _suggestions[i];
                                          final focused = _zone == _MZone.suggestions && _suggestionIdx == i;
                                          return GestureDetector(
                                            behavior: HitTestBehavior.opaque,
                                            onTap: () {
                                              _player?.pause();
                                              Navigator.pushReplacement(context,
                                                  MaterialPageRoute(builder: (_) => MoviePlayerScreen(item: item)));
                                            },
                                            child: AnimatedContainer(
                                              duration: const Duration(milliseconds: 150),
                                              width: 95,
                                              decoration: BoxDecoration(
                                                borderRadius: BorderRadius.circular(8),
                                                border: Border.all(
                                                  color: focused ? AppColors.accent : Colors.white12,
                                                  width: focused ? 2.5 : 1,
                                                ),
                                                boxShadow: focused
                                                    ? [BoxShadow(
                                                        color: AppColors.accent.withValues(alpha: 0.45),
                                                        blurRadius: 14, spreadRadius: 1)]
                                                    : null,
                                              ),
                                              child: ClipRRect(
                                                borderRadius: BorderRadius.circular(7),
                                                child: _MovieSuggCard(item: item),
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
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
