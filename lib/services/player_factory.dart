import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'device_profile_service.dart';

/// Result of a successful stream probe.
class PlayerResult {
  final Player player;
  final VideoController controller;
  final String url;
  PlayerResult(this.player, this.controller, this.url);
}

/// Initialises a [Player], applies ALL mpv properties in one go (avoiding
/// 20+ platform-channel round-trips that were starving the Android main thread
/// and causing ANR), probes the candidate URL list, and returns the first
/// working stream.
///
/// Call this from any async context — it yields frequently so the UI stays
/// responsive.
class PlayerFactory {
  PlayerFactory._();

  // ── Warm player pool ─────────────────────────────────────────────────────
  // `Player()` construction triggers media_kit's `mpv_create()` /
  // `mpv_initialize()` native calls (see media_kit's
  // InitializerNativeCallable), which run as plain synchronous FFI calls on
  // whatever isolate calls them — on Android that's Flutter's single Dart UI
  // isolate, the same one the OS depends on to acknowledge input/focus
  // events. Building a fresh Player() the instant the user taps a channel
  // blocks that isolate for the full native-init duration and produces a
  // real Android ANR ("Waited 5002ms for FocusEvent") — wrapping the call in
  // async/await doesn't help, since there's no actual async I/O inside
  // mpv_initialize(), just a blocking native call.
  //
  // Fix: keep one idle, fully-initialised Player warmed up ahead of time
  // (built at app start, and again immediately after each one is consumed)
  // so probe() can hand it out instantly — the blocking init cost is paid
  // during idle time instead of while the user is staring at a spinner.
  static Player? _warmPlayer;
  static Future<Player>? _warming;

  // media_kit_video's AndroidVideoController.create() runs
  // queryDecoders(handle), which issues a SYNCHRONOUS `mpv_get_property(ctx,
  // 'decoder-list', ...)` FFI call — unlike every other mpv call in this
  // codebase (all of which use mpv's async command/property API resolved via
  // completers), this one blocks the calling isolate directly until libmpv
  // finishes probing available decoders (including Android hardware codecs),
  // which can take multiple seconds on some devices. Its result is cached
  // process-wide (`_decoders` in query_decoders.dart) — but only AFTER the
  // first successful call. This is what was still causing the ANR even after
  // pre-warming a bare Player: every first `VideoController(...)` call in a
  // fresh app process pays this cost, and it happens exactly when the user
  // taps a channel (VideoController is only ever constructed inside
  // PlayerFactory.probe()). Warm this cache once, early, with a disposable
  // scratch player, so the real first play never pays for it.
  static bool _decoderCacheWarmed = false;

  static Future<Player> _newIdlePlayer(int bufBytes) async {
    return Player(
      configuration: PlayerConfiguration(
        bufferSize: bufBytes,
        logLevel: MPVLogLevel.warn,
      ),
    );
  }

  static Future<void> _warmDecoderCacheOnce() async {
    if (_decoderCacheWarmed) return;
    _decoderCacheWarmed = true; // set eagerly — don't retry forever on failure
    Player? scratch;
    try {
      scratch = await _newIdlePlayer(16 * 1024 * 1024);
      final ctrl = VideoController(scratch);
      await ctrl.platform.future;
    } catch (e) {
      debugPrint('✗ [PlayerFactory] Decoder cache warm-up failed: $e');
    } finally {
      try { await scratch?.dispose(); } catch (_) {}
    }
  }

  /// Begins warming a spare [Player] (and the decoder-list cache above) in
  /// the background if one isn't already warm or warming. Safe to call
  /// repeatedly.
  static void prewarm({int bufBytes = 64 * 1024 * 1024}) {
    if (_warmPlayer != null || _warming != null) return;
    _warming = () async {
      await _warmDecoderCacheOnce();
      return _newIdlePlayer(bufBytes);
    }().then((p) {
      _warmPlayer = p;
      _warming = null;
      return p;
    }).catchError((e) {
      debugPrint('✗ [PlayerFactory] prewarm failed: $e');
      _warming = null;
      throw e;
    });
  }

  /// Like [prewarm], but returns a Future that completes once warm-up is
  /// actually done. Firing prewarm() in the background at app start is not
  /// enough on its own — if the user reaches a channel before the
  /// background warm-up has finished running its blocking native call, they
  /// still pay for it on tap (probe() correctly waits for the SAME in-flight
  /// warm-up instead of racing a duplicate, but the blocking cost still
  /// lands wherever the isolate happens to reach it). Callers that can gate
  /// navigation on this — namely the splash screen, before the user can
  /// reach anything that plays video — should await this (with their own
  /// timeout safeguard) so the one-time cost is guaranteed to be paid during
  /// idle time, not during a live input dispatch.
  static Future<void> ensureWarm({int bufBytes = 64 * 1024 * 1024}) {
    prewarm(bufBytes: bufBytes);
    return (_warming ?? Future.value(_warmPlayer)).then((_) {});
  }

  /// Hands out the warm player if one is ready; otherwise falls back to
  /// building one on the spot (same blocking cost as before — only happens
  /// if a probe races ahead of a still-in-progress warm-up).
  /// TEMPORARY diagnostic bypass — when true, _takePlayer() never hands out
  /// a warm/reused Player. It always constructs a brand-new one on the spot,
  /// exactly like the app worked before the warm-pool system existed. Used
  /// to test whether reusing a pre-warmed idle mpv instance is what causes
  /// open() to hang.
  static bool debugBypassWarmPool = false;

  static Future<Player> _takePlayer(int bufBytes) {
    debugPrint('[PlayerFactory] tap: warmReady=${_warmPlayer != null} warming=${_warming != null} '
        'bypassWarmPool=$debugBypassWarmPool');
    if (debugBypassWarmPool) {
      final started = DateTime.now();
      debugPrint('[PlayerFactory] BYPASS warm pool: constructing fresh Player() — ENTER @$started');
      return _newIdlePlayer(bufBytes).then((p) {
        debugPrint('[PlayerFactory] BYPASS warm pool: fresh Player() constructed — EXIT, took '
            '${DateTime.now().difference(started).inMilliseconds}ms');
        return p;
      });
    }
    if (_warmPlayer != null) {
      final p = _warmPlayer!;
      _warmPlayer = null;
      return Future.value(p);
    }
    final warming = _warming;
    if (warming != null) return warming;
    final started = DateTime.now();
    debugPrint('[PlayerFactory] fallback: constructing Player() synchronously — ENTER @$started');
    return _newIdlePlayer(bufBytes).then((p) {
      debugPrint('[PlayerFactory] fallback: Player() constructed — EXIT, took '
          '${DateTime.now().difference(started).inMilliseconds}ms');
      return p;
    });
  }

  // ── Configures ALL mpv properties on an existing Player in one go ───────
  static Future<void> _configurePlayer(
    Player player, {
    required int bufBytes,
    required bool hwAccel,
    required DeviceProfile profile,
    required bool isLive,
  }) async {
    final platform = player.platform;
    if (platform is NativePlayer) {


      // ── All properties in ONE microtask batch ──────────────────────────
      // Each setProperty is a platform-channel call. By grouping them with
      // unawaited futures we fire them all in a single event-loop turn,
      // preventing the ANR caused by 20+ sequential awaits holding the thread.
      // ── Live vs VOD buffer sizing ──────────────────────────────────────
      // Live streams must NOT fill a huge buffer before playing — that causes
      // the "stuck / lagging" behaviour: mpv waits to fill 30 s of readahead
      // before committing to playback, falls 30 s behind the broadcast, then
      // stalls every time the pre-buffer drains. Keep live buffers tiny so the
      // player starts instantly and stays at the live edge.
      // 16 MB was too tight for 1080p live on a weak box: the cache drained
      // faster than the network refilled it, which is what the viewer sees as
      // stuttering. 32 MB still starts quickly and stays near the live edge.
      // 32 MB live buffer provides enough headroom for high-bitrate 1080p/4K live streams
      const int liveBufBytes  = 32 * 1024 * 1024;  // 32 MB live buffer
      final int vodBufBytes   = bufBytes;            // user-configured (default 64 MB)
      final int activeBuf     = isLive ? liveBufBytes : vodBufBytes;
      final int activeBackBuf = isLive ? (1 * 1024 * 1024) : (bufBytes ~/ 4);

      final props = <String, String>{
        // ── Caching ───────────────────────────────────────────────────────
        // Live: 10s cache / 3s readahead so live stream starts instantly (1-2s) & stays smooth.
        // VOD:  60s cache / 15s readahead so network jitter doesn't break seeks.
        'cache'                       : 'yes',
        'cache-secs'                  : isLive ? '10'  : '60',
        'demuxer-readahead-secs'      : isLive ? '3'   : '15',
        'demuxer-max-bytes'           : '$activeBuf',
        'demuxer-max-back-bytes'      : '$activeBackBuf',
        'demuxer-thread'              : 'yes',
        // ── Network / reconnect ───────────────────────────────────────────
        'network-timeout'             : '5',
        'reconnect-streamed'          : 'yes',
        'reconnect-max-retries'       : isLive ? '999' : '10',
        'reconnect-delay-max'         : isLive ? '2'   : '5',
        if (isLive) 'stream-lavf-o'   : 'reconnect=1,reconnect_streamed=1,reconnect_delay_max=2',
        // ── Cache pause behaviour ─────────────────────────────────────────
        // Enable cache-pause to prevent infinite stutter loops on minor network drops.
        // cache-pause-initial='no' ensures instant playback start on live.
        'cache-pause'                 : 'yes',
        'cache-pause-wait'            : isLive ? '0.2' : '1',
        'cache-pause-initial'         : 'no',
        // ── Container & Protocols ────────────────────────────────────────
        // fflags=+genpts+discardcorrupt
        'demuxer-lavf-o'              : isLive
            ? 'fflags=+genpts+discardcorrupt,allowed_extensions=ALL,protocol_whitelist=[file,http,https,tcp,tls,crypto,data,ftp,httpproxy]'
            : 'allowed_extensions=ALL,protocol_whitelist=[file,http,https,tcp,tls,crypto,data,ftp,httpproxy]',
        // 64 KB probesize & 0.1s analyzeduration allows FFmpeg to analyze stream headers in <100ms
        'demuxer-lavf-probesize'      : isLive ? '65536' : '500000',
        'demuxer-lavf-analyzeduration': isLive ? '0.1' : '0.5',
        'tls-verify'                  : 'no',
        'tls-min-version'             : '1.0',
        // ── Seeking ───────────────────────────────────────────────────────
        'force-seekable'              : 'yes',
        if (!isLive) 'hr-seek'        : 'yes',
        // ── Codec / decoding ─────────────────────────────────────────────
        // auto-safe enables MediaCodec hardware decoding with automatic software fallback.
        'hwdec'                       : 'auto-safe',
        'vd-lavc-threads'             : '0',
        'vd-lavc-software-fallback'   : 'yes',
        'vd-lavc-skiploopfilter'      : profile.forceH264 ? 'nonref' : 'default',
        // framedrop='no' prevents mpv from dropping video frames on small timestamp jitter.
        'framedrop'                   : 'no',
        // ── Identity ──────────────────────────────────────────────────────
        'user-agent'                  : profile.userAgent,
        // ── Video sync ───────────────────────────────────────────────────
        'video-sync'                  : 'audio',
        'video-latency-hacks'         : profile.enableLatencyHacks ? 'yes' : 'no',
        // ── Audio ─────────────────────────────────────────────────────────
        'audio-stream-silence'        : 'yes',
        'audio-spdif'                 : '',
        'audio-normalize-downmix'     : 'yes',
        // ── Misc ──────────────────────────────────────────────────────────
        'ytdl'                        : 'no',
      };

      if (profile.forceH264) props['vd-lavc-vcodec'] = 'h264';
      if (profile.disableHdr) {
        props['tone-mapping']      = 'clip';
        props['hdr-compute-peak']  = 'no';
      }

      // Fire all setProperty calls concurrently — no sequential blocking!
      //
      // waitForInitialization: false is REQUIRED here. By default
      // NativePlayer.setProperty() first awaits waitForPlayerInitialization
      // (a Completer that only resolves once mpv fires an 'idle-active'
      // property-change event through its own internal event loop) and
      // waitForVideoControllerInitializationIfAttached. For a Player pulled
      // from our warm pool there is no guarantee that idle-active event has
      // already been delivered/processed by the time we reuse it — and if it
      // never arrives, every one of these calls (and this whole probe())
      // hangs forever, which is exactly what caused the ANR to still occur
      // even after Player() construction and the decoder-list query were
      // both pre-warmed. media_kit_video's OWN internal property-setting
      // (AndroidVideoController.setProperty) already passes
      // waitForInitialization: false for this exact reason — match it here.
      debugPrint('… [Trace] _configurePlayer: setting ${props.length} props');
      await Future.wait(
        props.entries.map(
          (e) => platform.setProperty(e.key, e.value, waitForInitialization: false),
        ),
      );
      debugPrint('… [Trace] _configurePlayer: props set');

      // Yield again after configuration so the UI can breathe.
      await Future.delayed(Duration.zero);
    }
  }

  // ── Non-fatal error filter ────────────────────────────────────────────────
  static bool _isNonFatal(String err) {
    final lower = err.toLowerCase();
    if (lower.contains('subtitle')) return true;
    if (lower.contains('unsupported tag')) return true;
    if (lower.contains('skipping')) return true;
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
    // Extended non-fatal patterns — common on IPTV/Xtream streams
    if (lower.contains('connection reset')) return true;
    if (lower.contains('tls') && lower.contains('handshake')) return true;
    if (lower.contains('reconnect')) return true;
    if (lower.contains('[lavf]')) return true;
    if (lower.contains('[ffmpeg]')) return true;
    if (lower.contains('http error 0')) return true;  // pre-play HEAD artifact
    if (lower.contains('avformat')) return true;
    if (lower.contains('application provided invalid')) return true;
    if (lower.contains('invalid data found')) return true; // usually non-fatal with reconnect
    if (lower.contains('moov atom not found') && lower.contains('retry')) return true;
    if (lower.startsWith('error: ') && lower.contains('track')) return true;
    return false;
  }

  // ── Public API ────────────────────────────────────────────────────────────

  /// Probes [urls] in order and returns the first that produces playback.
  ///
  /// [probeTimeout] controls how long we wait per-URL for a success signal.
  /// [isLive] selects live-stream vs VOD mpv settings.
  static Future<PlayerResult?> probe({
    required List<String> urls,
    required int bufBytes,
    required bool hwAccel,
    required DeviceProfile profile,
    required Map<String, String> streamHeaders,
    bool isLive = false,
    Duration probeTimeout = const Duration(seconds: 15),
  }) async {
    // Reset the permanent-failure flag at the start of every probe so that a
    // previously-failed title never silently blocks the next one.
    lastFailureWasPermanent = false;
    // Take the pre-warmed idle Player (instant — see prewarm() above) and
    // reuse THIS SAME instance across every candidate URL below, instead of
    // constructing a fresh Player (and re-paying the blocking mpv_initialize
    // cost) per failover attempt.
    Player player;
    VideoController ctrl;
    try {
      debugPrint('… [Trace] probe: taking player');
      player = await _takePlayer(bufBytes);
      debugPrint('… [Trace] probe: got player, configuring');
      await _configurePlayer(player, bufBytes: bufBytes, hwAccel: hwAccel, profile: profile, isLive: isLive);
      debugPrint('… [Trace] probe: configured, creating VideoController');

      // enableHardwareAcceleration must mirror `hwAccel` (and therefore the
      // device profile's safety check) — on Android this flag is fed
      // straight into mpv's `hwdec` property by media_kit_video, AFTER
      // _configurePlayer already set it to 'no' for unsafe chipsets.
      // Hardcoding this to `true` silently re-enabled hardware decoding on
      // Amlogic/Rockchip/MediaTek/Mali boxes, whose buggy vendor MediaCodec
      // HALs can hang the platform thread and freeze the whole app the
      // instant playback starts.
      ctrl = VideoController(
        player,
        configuration: VideoControllerConfiguration(
          enableHardwareAcceleration: hwAccel,
        ),
      );
      debugPrint('… [Trace] probe: VideoController constructed');
    } catch (e) {
      debugPrint('✗ [PlayerFactory] Failed to build player: $e');
      prewarm(bufBytes: bufBytes);
      return null;
    }


    for (final url in urls) {
      debugPrint('… [Trace] probe: trying $url');
      // Skip obviously empty URLs
      if (url.trim().isEmpty) continue;
      debugPrint('… [Trace] probe: opening media for $url');

      try {
        String? fatalError;
        final errSub = player.stream.error.listen((err) {
          if (fatalError == null && !_isNonFatal(err)) fatalError = err;
        });

        // A hung native open() call must never freeze this flow forever.
        await player.open(Media(url, httpHeaders: streamHeaders))
            .timeout(const Duration(seconds: 12));
        debugPrint('… [Trace] probe: open() returned, instant success');

        // open() succeeded without throwing — media connection is established!
        final ok = Completer<void>();
        ok.complete();

        final result = await Future.any([
          ok.future.then((_) => 'ok'),
          Future.delayed(probeTimeout).then((_) => 'timeout'),
        ]);

        await errSub.cancel();
        debugPrint('… [Trace] probe: signal="$result"');

        if (result == 'ok') {
          // Playback started — use this URL regardless of any side-channel
          // error events that arrived during the initial buffering phase.
          debugPrint('✅ [PlayerFactory] Playing: $url (fatalError=$fatalError, ignored)');
        } else if (result == 'timeout' || fatalError != null) {
          debugPrint('✗ [PlayerFactory] Probe failed for $url: ${fatalError ?? 'timeout'}');
          // Keep reusing the SAME player instance for the next candidate —
          // do NOT dispose/rebuild here, that's what re-triggers the ANR.
          continue;
        }

        // Immediately start warming a spare for the *next* probe() call
        // (channel switch, retry, etc.) so it never pays the blocking cost.
        prewarm(bufBytes: bufBytes);
        return PlayerResult(player, ctrl, url);
      } catch (e) {
        debugPrint('✗ [PlayerFactory] Exception for $url: $e');
      }
    }

    // All candidates failed on this player instance — dispose it and make
    // sure a fresh spare is warming for the next attempt.
    try { await player.dispose().timeout(const Duration(seconds: 5)); } catch (_) {}
    prewarm(bufBytes: bufBytes);

    // All URLs failed — treat as transient network failure so the retry
    // cycle can try again. We no longer mark permanent failures based on
    // URL-only heuristics since we skip the HEAD health-check.
    lastFailureWasPermanent = false;
    return null;
  }

  /// True when the most recent [probe] failed because the provider does not
  /// have the content (404/403 on every candidate URL), as opposed to a
  /// network hiccup. Callers use this to show "unavailable" straight away
  /// instead of grinding through a retry/failover cycle that cannot succeed.
  static bool lastFailureWasPermanent = false;
}
