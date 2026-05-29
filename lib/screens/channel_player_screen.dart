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

const _audioCh = MethodChannel('com.example.mbapp/audio');

// TV navigation zones in the player overlay
enum _Zone { back, fav, replay, play, forward, progress, suggestions }

class ChannelPlayerScreen extends StatefulWidget {
  final ContentItem item;
  const ChannelPlayerScreen({super.key, required this.item});

  @override
  State<ChannelPlayerScreen> createState() => _ChannelPlayerScreenState();
}

class _ChannelPlayerScreenState extends State<ChannelPlayerScreen> {
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

  // ── TV navigation state ─────────────────────────────────────────────────────
  _Zone _zone = _Zone.play;
  int   _suggestionIdx = 0;
  List<ContentItem> _suggestions = [];
  final ScrollController _suggScroll = ScrollController();

  StreamSubscription? _completedSub;
  StreamSubscription? _positionSub;
  StreamSubscription? _durationSub;
  StreamSubscription? _playingSub;

  // Single root focus node — handles ALL remote key events
  final FocusNode _focus = FocusNode(debugLabel: 'ChannelPlayer');

  static const _ua =
      'Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  /// All HTTP headers sent with every stream open() call.
  /// These ensure compatibility with Xtream, CDN-proxied, and direct HLS streams.
  static Map<String, String> get _streamHeaders => {
    'User-Agent': _ua,
    'Accept': '*/*',
    'Accept-Language': 'en-US,en;q=0.9',
    'Connection': 'keep-alive',
    'Referer': '${IptvService.baseUrl}/',
    'Origin': IptvService.baseUrl,
    'Icy-MetaData': '1',
  };

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

  // ── Audio ───────────────────────────────────────────────────────────────────
  Future<void> _requestAudio() async {
    try { await _audioCh.invokeMethod('requestAudioFocus'); } catch (_) {}
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
    // Use service-level helper: bare URL first (most compatible with Xtream servers),
    // then .m3u8 (HLS), then .ts (MPEG-TS), then explicit bare fallback.
    return IptvService.getLiveStreamUrlCandidates(u, p, id);
  }

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
    // Transient EOF / read errors that resolve via reconnect
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
    // CRITICAL: hardware accel defaults to OFF — software decoding is
    // universally compatible across all TV chipsets (Amlogic, MediaTek,
    // Qualcomm, Tegra). Hardware decoding causes scrambled video on many boxes.
    final hwAccel = context.read<AppState>().hardwareAccelEnabled;
    final bufBytes = context.read<AppState>().bufferBytes;

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
      final urls = _urls();

      debugPrint('▶ [Channel] hwAccel=$hwAccel bufferBytes=${bufBytes ~/ (1024 * 1024)}MB');

      final player = Player(
        configuration: PlayerConfiguration(
          bufferSize: bufBytes,
          logLevel: MPVLogLevel.warn,
        ),
      );
      // Apply live-optimised mpv properties for universal IPTV streaming.
      // Covers ALL Android TV chipsets: Amlogic S905/S912/S922X, MTK MT5816/MT8695,
      // Qualcomm, Rockchip RK3328/RK3399, Nvidia Tegra X1, Samsung Exynos, Mali GPU.
      final platform = player.platform;
      if (platform is NativePlayer) {
        // -- Caching & buffering --
        await platform.setProperty('cache', 'yes');
        await platform.setProperty('cache-secs', '30');
        await platform.setProperty('demuxer-readahead-secs', '30');
        await platform.setProperty('demuxer-max-bytes', '$bufBytes');
        await platform.setProperty('demuxer-max-back-bytes', '${bufBytes ~/ 4}');
        // Non-blocking demuxer thread — prevents UI stall on slow SoCs (Rockchip, MTK)
        await platform.setProperty('demuxer-thread', 'yes');
        // -- Network & reconnect --
        await platform.setProperty('network-timeout', '15');
        await platform.setProperty('reconnect-streamed', 'yes');
        await platform.setProperty('reconnect-max-retries', '10');
        await platform.setProperty('reconnect-delay-max', '5');
        await platform.setProperty('stream-lavf-o',
            'reconnect=1,reconnect_streamed=1,reconnect_delay_max=5');
        await platform.setProperty('http-header-fields',
            'User-Agent: $_ua\nReferer: ${IptvService.baseUrl}/\nOrigin: ${IptvService.baseUrl}\nAccept: */*\nConnection: keep-alive');
        // -- Codec / decoding --
        // hwdec=no forces SW decoding — universally safe on ALL TV chipsets.
        // HW decoding causes green/scrambled video on Amlogic S905, Rockchip RK3228,
        // MTK MT5816, generic Mali GPU boxes. User can enable in Settings if needed.
        await platform.setProperty('hwdec', hwAccel ? 'auto-safe' : 'no');
        // Auto thread count — let libmpv pick based on available CPU cores.
        // Hardcoded threads=2 caused scrambling on single/odd-core SoCs.
        await platform.setProperty('vd-lavc-threads', '0');
        await platform.setProperty('vd-lavc-skiploopfilter', 'nonref');
        // Auto SW fallback if HW decode fails mid-stream (prevents freeze/scramble)
        await platform.setProperty('vd-lavc-software-fallback', 'yes');
        await platform.setProperty('framedrop', 'decoder+vo');
        // -- Video output & sync --
        await platform.setProperty('gpu-api', 'opengl');
        // EGL/GLES2 fallback — required on old Mali (T628/T760), Vivante GC7000,
        // and any box where desktop OpenGL is unavailable (most Chinese TV boxes).
        await platform.setProperty('opengl-es', '2');
        // Mali GPU frame-flush — prevents tearing/corruption on Mali T-series GPUs
        // (common in generic Amlogic, Rockchip, and Samsung SoC-based boxes).
        await platform.setProperty('opengl-glfinish', 'yes');
        // Anchor A/V sync to audio clock — eliminates frame scrambling caused by
        // separate audio/video clock domains on cheaper TV SoCs.
        await platform.setProperty('video-sync', 'audio');
        // Amlogic live-stream timestamping hack — fixes TS discontinuities that
        // cause seeking/scrambling on Amlogic S905/S912/S922X in live mode.
        await platform.setProperty('video-latency-hacks', 'yes');
        // -- Audio --
        await platform.setProperty('audio-stream-silence', 'yes');
        // IMPORTANT: Do NOT use audio-spdif (HDMI passthrough) — it breaks A/V sync
        // on TVs whose HDMI receiver doesn't support AC3/EAC3 passthrough.
        // Software audio decoding (default) works on ALL devices.
        await platform.setProperty('audio-spdif', '');
        // -- Misc --
        await platform.setProperty('ytdl', 'no');
        await platform.setProperty('demuxer-lavf-analyzeduration', '2');
        await platform.setProperty('demuxer-lavf-probesize', '1048576');
      }

      final ctrl = VideoController(
        player,
        configuration: VideoControllerConfiguration(enableHardwareAcceleration: hwAccel),
      );

      bool ok = false;
      String? lastError;

      // 8s per-URL probe timeout for live channels — fast channel switching
      const probeTimeout = Duration(seconds: 8);
      String? _successUrl; // remember the URL that worked for reconnect

      for (final url in urls) {
        try {
          debugPrint('▶ [Channel] $url');

          // ── Fast health-check: skip obviously dead URLs immediately ──────
          final alive = await IptvService.streamHealthCheck(url)
              .timeout(const Duration(seconds: 3), onTimeout: () => true);
          if (!alive) {
            debugPrint('✗ [Channel] Health-check failed — skipping $url');
            lastError = 'server returned error status';
            continue;
          }

          // Collect FIRST fatal error only — ignore non-fatal libmpv warnings
          String? fatalError;
          final errSub = player.stream.error.listen((err) {
            if (fatalError == null && !_isNonFatalError(err.toString())) {
              fatalError = err.toString();
            }
            debugPrint('⚠ [Channel] Stream error for $url: $err');
          });

          await player.open(Media(url, httpHeaders: _streamHeaders));

          // ── Relaxed success gate ─────────────────────────────────────────
          // Accept ANY of:
          //   (a) playing=true  — decoder confirmed active
          //   (b) width > 0     — first video frame decoded
          //   (c) buffering completed (after initial buffering started)
          final successCompleter = Completer<void>();
          bool _gotWidth    = false;
          bool _gotPlaying  = false;
          bool _hasBuffered = false;

          void _checkSuccess() {
            if (successCompleter.isCompleted) return;
            if (_gotPlaying) { successCompleter.complete(); return; }
            if (_gotWidth)   { successCompleter.complete(); return; }
            if (_hasBuffered) { successCompleter.complete(); return; }
          }

          final widthSub = player.stream.width.listen((w) {
            if (w != null && w > 0) { _gotWidth = true; _checkSuccess(); }
          });
          final durationSub = player.stream.duration.listen((_) {}); // keep sub alive
          final playingSub2 = player.stream.playing.listen((playing) {
            if (playing) { _gotPlaying = true; _checkSuccess(); }
          });
          final bufferingSub = player.stream.buffering.listen((buffering) {
            if (buffering) {
              // started buffering — real data is flowing
              _hasBuffered = true;
            } else if (_hasBuffered) {
              // buffering finished — stream is ready
              _checkSuccess();
            }
          });

          final result = await Future.any([
            successCompleter.future.then((_) => 'ok'),
            Future.delayed(probeTimeout).then((_) => 'timeout'),
          ]);

          await widthSub.cancel();
          await durationSub.cancel();
          await bufferingSub.cancel();
          await playingSub2.cancel();
          await errSub.cancel();

          if (result == 'timeout' || fatalError != null) {
            final reason = fatalError ?? 'timeout after ${probeTimeout.inSeconds}s';
            debugPrint('✗ Failed $url: $reason');
            lastError = reason;
            continue;
          }

          debugPrint('✅ Playing: $url');
          _successUrl = url;
          ok = true;
          break;
        } catch (e) {
          lastError = e.toString();
          debugPrint('✗ Failed $url: $e');
        }
      }

      if (!ok) { player.dispose(); throw Exception('unavailable: $lastError'); }
      if (!mounted) { player.dispose(); return; }

      _player    = player;
      _videoCtrl = ctrl;
      await player.setVolume(_volume);

      // ── Smart reconnect: on stream end, re-open the same working URL instead
      // of full Player teardown. This avoids the ~3s delay of reinitialising libmpv.
      _completedSub = player.stream.completed.listen((done) {
        if (!done || !mounted) return;
        if (_successUrl != null) {
          debugPrint('↺ [Channel] Stream ended — reopening $_successUrl');
          // Re-open the same URL on the existing player (no teardown)
          Future.delayed(const Duration(milliseconds: 800), () {
            if (mounted && _player != null) {
              _player!.open(Media(_successUrl!, httpHeaders: _streamHeaders));
            }
          });
        } else {
          // Fallback: full restart if we somehow lost the URL
          Future.delayed(const Duration(seconds: 2), _startPlay);
        }
      });
      _positionSub = player.stream.position.listen((p) {
        if (mounted && _showOverlay && !_draggingProgress) setState(() => _position = p);
      });
      _durationSub = player.stream.duration.listen((d) {
        if (mounted && _showOverlay) setState(() => _duration = d);
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
      debugPrint('❌ [Channel] $e');
      if (!mounted) return;
      _scheduleRetry();
    }
  }

  void _scheduleRetry() {
    _retryTimer?.cancel();
    _attemptNumber++;

    if (_attemptNumber > _maxAttempts) {
      // All 3 attempts exhausted — mark the stream as dead
      if (mounted) {
        setState(() {
          _autoRetrying = false;
          _loading      = false;
          _streamDead   = true;
        });
      }
      debugPrint('❌ [Channel] Stream marked dead after $_maxAttempts attempts');
      return;
    }

    // Countdown between attempts (5s)
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

  /// Manual retry — resets attempt counter so user gets a fresh 3-attempt cycle.
  void _manualRetry() {
    _retryTimer?.cancel();
    _attemptNumber = 0;
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

  // ── Activate whichever zone the remote cursor is on ─────────────────────────
  void _activateZone() {
    final appState = context.read<AppState>();
    switch (_zone) {
      case _Zone.back:
        _player?.pause();
        Navigator.of(context).pop();
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
      case _Zone.progress:
        _togglePlay();
        break;
      case _Zone.suggestions:
        if (_suggestionIdx < _suggestions.length) {
          final item = _suggestions[_suggestionIdx];
          _player?.pause();
          Navigator.pushReplacement(context,
              MaterialPageRoute(builder: (_) => ChannelPlayerScreen(item: item)));
        }
        break;
    }
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

    // Volume keys — always handled
    if (k == LogicalKeyboardKey.audioVolumeUp)   { _volumeUp();   return KeyEventResult.handled; }
    if (k == LogicalKeyboardKey.audioVolumeDown) { _volumeDown(); return KeyEventResult.handled; }

    if (_showOverlay) _resetHideTimer();

    // Back / Escape
    final isBack = k == LogicalKeyboardKey.goBack ||
        k == LogicalKeyboardKey.escape ||
        k.keyId == 0x1000000a6 || k.keyId == 166 || k.keyId == 8;
    if (isBack) {
      if (_showOverlay) {
        setState(() => _showOverlay = false);
      } else {
        _player?.pause();
        Navigator.of(context).pop();
      }
      return KeyEventResult.handled;
    }

    // Media keys
    if (k == LogicalKeyboardKey.mediaPlayPause ||
        k == LogicalKeyboardKey.mediaPlay ||
        k == LogicalKeyboardKey.mediaPause) {
      _togglePlay();
      return KeyEventResult.handled;
    }

    // Any key while overlay hidden → show overlay
    if (!_showOverlay) {
      final isSeekLeft = k == LogicalKeyboardKey.arrowLeft;
      final isSeekRight = k == LogicalKeyboardKey.arrowRight;
      setState(() {
        _showOverlay = true;
        if (isSeekLeft) {
          _zone = _Zone.replay;
        } else if (isSeekRight) {
          _zone = _Zone.forward;
        } else {
          _zone = _Zone.play;
        }
      });
      _resetHideTimer();
      if (isSeekLeft && _player != null) {
        final target = _player!.state.position - const Duration(seconds: 10);
        _player!.seek(target < Duration.zero ? Duration.zero : (target > _duration ? _duration : target));
      } else if (isSeekRight && _player != null) {
        final target = _player!.state.position + const Duration(seconds: 10);
        _player!.seek(target < Duration.zero ? Duration.zero : (target > _duration ? _duration : target));
      }
      return KeyEventResult.handled;
    }

    // Select / Enter → activate current zone
    // Extended select: covers all TV remote OK/Enter variants
    // 13=Enter, 23=DPAD_CENTER (Amlogic/Rockchip), 96=BUTTON_A, 160=NUMPAD_ENTER
    final isSelect = k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.gameButtonA ||
        k.keyId == 13 ||
        k.keyId == 23 ||
        k.keyId == 96 ||
        k.keyId == 160;    if (isSelect) {
      _activateZone();
      return KeyEventResult.handled;
    }

    // ── Arrow navigation ──────────────────────────────────────────────────────
    if (k == LogicalKeyboardKey.arrowLeft) {
      setState(() {
        switch (_zone) {
          case _Zone.fav:     _zone = _Zone.back; break;
          case _Zone.play:    _zone = _Zone.replay; break;
          case _Zone.forward: _zone = _Zone.play; break;
          case _Zone.progress:
            if (_player != null) {
              final target = _player!.state.position - const Duration(seconds: 10);
              _player!.seek(target < Duration.zero ? Duration.zero : (target > _duration ? _duration : target));
            }
            break;
          case _Zone.suggestions:
            if (_suggestionIdx > 0) { _suggestionIdx--; _scrollSuggestions(); }
            break;
          default: break;
        }
      });
      return KeyEventResult.handled;
    }

    if (k == LogicalKeyboardKey.arrowRight) {
      setState(() {
        switch (_zone) {
          case _Zone.back:    _zone = _Zone.fav; break;
          case _Zone.replay:  _zone = _Zone.play; break;
          case _Zone.play:    _zone = _Zone.forward; break;
          case _Zone.progress:
            if (_player != null) {
              final target = _player!.state.position + const Duration(seconds: 10);
              _player!.seek(target < Duration.zero ? Duration.zero : (target > _duration ? _duration : target));
            }
            break;
          case _Zone.suggestions:
            if (_suggestionIdx < _suggestions.length - 1) { _suggestionIdx++; _scrollSuggestions(); }
            break;
          default: break;
        }
      });
      return KeyEventResult.handled;
    }

    if (k == LogicalKeyboardKey.arrowUp) {
      setState(() {
        switch (_zone) {
          case _Zone.replay:      _zone = _Zone.back; break;
          case _Zone.play:        _zone = _Zone.back; break;
          case _Zone.forward:     _zone = _Zone.fav; break;
          case _Zone.progress:    _zone = _Zone.play; break;
          case _Zone.suggestions:
            if (_duration.inMilliseconds > 0) {
              _zone = _Zone.progress;
            } else {
              _zone = _Zone.play;
            }
            break;
          default: break;
        }
      });
      return KeyEventResult.handled;
    }

    if (k == LogicalKeyboardKey.arrowDown) {
      setState(() {
        switch (_zone) {
          case _Zone.back:    _zone = _Zone.play; break;
          case _Zone.fav:     _zone = _Zone.play; break;
          case _Zone.replay:
          case _Zone.play:
          case _Zone.forward:
            if (_duration.inMilliseconds > 0) {
              _zone = _Zone.progress;
            } else if (_suggestions.isNotEmpty) {
              _zone = _Zone.suggestions;
              _scrollSuggestions();
            }
            break;
          case _Zone.progress:
            if (_suggestions.isNotEmpty) {
              _zone = _Zone.suggestions;
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

  // ── Visual helper: focused circle button ────────────────────────────────────
  Widget _circleBtn({
    required _Zone zone,
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

    return Focus(
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
                      // Channel details / title
                      Positioned(
                        top: 0, left: 0, right: 0,
                        child: SafeArea(
                          bottom: false,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                            child: Row(
                              children: [
                                // Spacer to avoid overlapping Back button
                                const SizedBox(width: 44),
                                const SizedBox(width: 10),
                                if (_currentItem.imageUrl.isNotEmpty) ...[
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(6),
                                    child: CachedNetworkImage(
                                      imageUrl: _currentItem.imageUrl,
                                      width: 36, height: 36,
                                      fit: BoxFit.contain,
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
                                          style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700),
                                          maxLines: 1, overflow: TextOverflow.ellipsis),
                                      const SizedBox(height: 3),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: AppColors.live,
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: const Text('LIVE',
                                            style: TextStyle(color: Colors.white, fontSize: 9,
                                                fontWeight: FontWeight.w800, letterSpacing: 0.5)),
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
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        
                        // ── TOP BAR: Back + Fav (large touch targets with HitTestBehavior.opaque) ────
                        Positioned(
                          top: 0, left: 0, right: 0,
                          child: SafeArea(
                            bottom: false,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                              child: Row(
                                children: [
                                  // Back button with large touch target
                                  GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTap: () {
                                      _player?.pause();
                                      Navigator.of(context).pop();
                                    },
                                    child: Padding(
                                      padding: const EdgeInsets.all(8),
                                      child: _circleBtn(
                                        zone: _Zone.back,
                                        size: 44,
                                        icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white, size: 20),
                                      ),
                                    ),
                                  ),
                                  const Spacer(),
                                  // Fav button with large touch target
                                  GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTap: () {
                                      appState.toggleFavorite(_currentItem);
                                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                        content: Text(
                                          appState.isFavorite(_currentItem.id) ? 'Added to My List' : 'Removed from My List',
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
                                        zone: _Zone.fav,
                                        size: 44,
                                        icon: Icon(
                                          isFav ? Icons.favorite : Icons.favorite_border,
                                          color: (_zone == _Zone.fav)
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

                        // ── BOTTOM BAR: controls + seekbar + suggested channels ────
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

                                  // Playback controls row (large touch targets)
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
                                              zone: _Zone.replay,
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
                                              color: _zone == _Zone.play ? Colors.white : AppColors.accent,
                                              border: Border.all(
                                                color: _zone == _Zone.play ? AppColors.accent : Colors.transparent,
                                                width: 3,
                                              ),
                                              boxShadow: [
                                                BoxShadow(
                                                  color: AppColors.accent.withValues(alpha: _zone == _Zone.play ? 0.7 : 0.4),
                                                  blurRadius: _zone == _Zone.play ? 24 : 14,
                                                  spreadRadius: 2,
                                                ),
                                              ],
                                            ),
                                            child: Center(
                                              child: Icon(
                                                _playing ? Icons.pause : Icons.play_arrow,
                                                color: _zone == _Zone.play ? AppColors.accent : Colors.white,
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
                                              zone: _Zone.forward,
                                              icon: const Icon(Icons.forward_10, color: Colors.white, size: 28),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),

                                  const SizedBox(height: 12),

                                  // ── Seekable progress bar ──────────────────────
                                  Row(
                                    children: [
                                      SizedBox(
                                        width: 44,
                                        child: Text(
                                          _fmtDur(_draggingProgress ? _dragPosition : _position),
                                          style: const TextStyle(color: Colors.white70, fontSize: 12),
                                          textAlign: TextAlign.center,
                                        ),
                                      ),
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
                                            final isFocused  = _zone == _Zone.progress;
                                            final isActive   = isFocused || _draggingProgress;

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
                                                height: 44, // fat touch target
                                                alignment: Alignment.center,
                                                child: Stack(
                                                  alignment: Alignment.centerLeft,
                                                  children: [
                                                    Container(
                                                      height: isActive ? 10 : 5,
                                                      width: double.infinity,
                                                      decoration: BoxDecoration(
                                                        color: Colors.white30,
                                                        borderRadius: BorderRadius.circular(6),
                                                      ),
                                                    ),
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
                                      SizedBox(
                                        width: 52,
                                        child: Text(
                                          _duration.inMilliseconds > 0 ? _fmtDur(_duration) : 'LIVE',
                                          style: TextStyle(
                                            color: _duration.inMilliseconds > 0 ? Colors.white70 : AppColors.live,
                                            fontSize: 12,
                                            fontWeight: _duration.inMilliseconds > 0 ? FontWeight.normal : FontWeight.bold,
                                          ),
                                          textAlign: TextAlign.center,
                                        ),
                                      ),
                                    ],
                                  ),

                                  const SizedBox(height: 10),

                                  // ── Suggested channels ─────────────────────
                                  if (_suggestions.isNotEmpty) ...[
                                    const Text('Suggested Channels',
                                        style: TextStyle(color: Colors.white, fontSize: 13,
                                            fontWeight: FontWeight.bold, fontFamily: 'Inter')),
                                    const SizedBox(height: 8),
                                    SizedBox(
                                      height: 122,
                                      child: ListView.separated(
                                        controller: _suggScroll,
                                        scrollDirection: Axis.horizontal,
                                        itemCount: _suggestions.length,
                                        separatorBuilder: (_, __) => const SizedBox(width: 10),
                                        itemBuilder: (ctx, i) {
                                          final item = _suggestions[i];
                                          final focused = _zone == _Zone.suggestions && _suggestionIdx == i;
                                          return GestureDetector(
                                            behavior: HitTestBehavior.opaque,
                                            onTap: () {
                                              _player?.pause();
                                              Navigator.pushReplacement(context,
                                                  MaterialPageRoute(builder: (_) => ChannelPlayerScreen(item: item)));
                                            },
                                            child: AnimatedContainer(
                                              duration: const Duration(milliseconds: 150),
                                              width: 145,
                                              decoration: BoxDecoration(
                                                borderRadius: BorderRadius.circular(10),
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
                                                borderRadius: BorderRadius.circular(9),
                                                child: _SuggCard(item: item),
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
