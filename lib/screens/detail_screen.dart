import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/content_model.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';
import '../services/app_state.dart';
import '../services/iptv_service.dart';

/// Native method channel to control Android AudioManager.
/// Requests audio focus and raises media volume before any stream plays.
const _audioChannel = MethodChannel('com.example.mbapp/audio');

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
  VideoPlayerController? _vpc;
  ChewieController? _cc;

  // ── Episodes state ────────────────────────────────────────────
  bool _episodesLoading = false;
  List<SeasonInfo> _seasons = [];
  int _selectedSeason = 0;
  EpisodeInfo? _currentEpisode;

  static const _ua =
      'Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  @override
  void initState() {
    super.initState();
    if (widget.item.isSeries) {
      _loadEpisodes();
    }
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    _volumeTimer?.cancel();
    _vpc?.removeListener(_onPlayerValueChanged);
    _cc?.dispose();
    _vpc?.dispose();
    super.dispose();
  }

  /// Called whenever VideoPlayerController value changes.
  /// Enforces unmuted audio and triggers auto-retry on errors.
  void _onPlayerValueChanged() {
    if (!mounted) return;
    final vpc = _vpc;
    if (vpc == null) return;
    // Enforce unmuted audio on EVERY state change — no exceptions
    if (vpc.value.volume < 1.0) {
      vpc.setVolume(1.0).catchError((_) {});
    }
    if (vpc.value.hasError && !_playerLoading && !_autoRetrying) {
      debugPrint('🔴 Post-init player error: ${vpc.value.errorDescription}');
      _scheduleAutoRetry();
    }
  }

  /// Runs every 300ms for the first 5 seconds, then every second for 15 more seconds.
  /// On EACH tick: enforces Flutter player volume = 1.0 and Android STREAM_MUSIC to max.
  /// This catches every codec-level audio reset window (CNN, Cartoon Network, BBC, etc.)
  void _startVolumeEnforcement() {
    _volumeTimer?.cancel();
    int ticks = 0;
    // Phase 1: every 300ms for first 5s (most codecs reset within 3s of start)
    _volumeTimer = Timer.periodic(const Duration(milliseconds: 300), (t) {
      ticks++;
      if (!mounted || _vpc == null) { t.cancel(); return; }
      _vpc!.setVolume(1.0).catchError((_) {});
      _audioChannel.invokeMethod('setMaxVolume').catchError((_) {});
      if (ticks >= 17) {
        // ~5 seconds done; switch to phase 2
        t.cancel();
        _startVolumeEnforcementPhase2();
      }
    });
  }

  /// Phase 2: enforce every 1s for 15 more seconds.
  void _startVolumeEnforcementPhase2() {
    int ticks = 0;
    _volumeTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      ticks++;
      if (!mounted || _vpc == null) { t.cancel(); return; }
      _vpc!.setVolume(1.0).catchError((_) {});
      if (ticks % 3 == 0) {
        _audioChannel.invokeMethod('setMaxVolume').catchError((_) {});
      }
      if (ticks >= 15) t.cancel(); // Stop after ~15 more seconds
    });
  }

  // ── Auto-retry logic ────────────────────────────────────────────
  void _scheduleAutoRetry() {
    if (!mounted) return;
    _retryTimer?.cancel();
    // Use a shorter delay for faster recovery; live channels especially need quick retry
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

  // ── Episode loading ───────────────────────────────────────────────────────
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

  // ── Video player controller builder ─────────────────────────────────────
  Future<VideoPlayerController> _buildController(String url,
      {int timeoutSeconds = 20}) async {
    // Only actual .m3u8 URLs are HLS. Everything else: auto-detect.
    final isHls = url.toLowerCase().endsWith('.m3u8');
    final ctrl = VideoPlayerController.networkUrl(
      Uri.parse(url),
      formatHint: isHls ? VideoFormat.hls : null,
      httpHeaders: {
        'User-Agent': _ua,
        'Accept': '*/*',
        'Connection': 'keep-alive',
        'Referer': '${IptvService.baseUrl}/',
        'Range': 'bytes=0-',
      },
    );

    // Timeout so we don't hang forever on dead URLs.
    try {
      await ctrl.initialize().timeout(
        Duration(seconds: timeoutSeconds),
        onTimeout: () =>
            throw TimeoutException('Stream timed out after ${timeoutSeconds}s'),
      );
    } catch (e) {
      ctrl.dispose();
      rethrow;
    }

    if (ctrl.value.hasError) {
      ctrl.dispose();
      throw Exception(ctrl.value.errorDescription ?? 'Source error after init');
    }

    // Fix muted audio — set volume to max immediately after initialization.
    // Some IPTV channels (especially live news channels) reset volume to 0
    // after buffering. We set it here, and also start a repeating enforcement
    // timer after playback begins.
    try {
      await ctrl.setVolume(1.0);
    } catch (_) {}
    // Double-ensure it's set after a brief pause (some codecs reset it)
    Future.delayed(const Duration(milliseconds: 200), () {
      ctrl.setVolume(1.0).catchError((_) {});
    });

    return ctrl;
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
      return [
        IptvService.getLiveStreamUrl(u, p, id),       // .m3u8 HLS (best)
        IptvService.getLiveStreamUrlTs(u, p, id),     // .ts fallback
        IptvService.getLiveStreamUrlNoExt(u, p, id),  // no-ext fallback
        '${IptvService.baseUrl}/live/$u/$p/$id',      // bare URL last resort
      ];
    }

    if (widget.item.isMovie) {
      final ext =
          (widget.item.containerExtension ?? 'mp4').toLowerCase();
      return [
        IptvService.getMovieStreamUrl(u, p, id, ext),
        if (ext != 'mp4') IptvService.getMovieStreamUrl(u, p, id, 'mp4'),
        if (ext != 'mkv') IptvService.getMovieStreamUrl(u, p, id, 'mkv'),
        if (ext != 'ts') IptvService.getMovieStreamUrl(u, p, id, 'ts'),
      ];
    }

    // Series — build episode URL candidates
    final ep = episode ?? _currentEpisode;
    if (ep != null) {
      final u2 = state.username;
      final p2 = state.password;
      return [
        // Highest priority: direct_source from API (most reliable when present)
        if (ep.directSource != null && ep.directSource!.isNotEmpty)
          ep.directSource!,
        // Primary: series endpoint
        IptvService.getSeriesStreamUrl(u2, p2, ep.streamPath),
        // Fallback 1: movie endpoint with original ext
        '${IptvService.baseUrl}/movie/$u2/$p2/${ep.streamId}.${ep.ext}',
        // Fallback 2: mp4
        if (ep.ext != 'mp4') '${IptvService.baseUrl}/movie/$u2/$p2/${ep.streamId}.mp4',
        // Fallback 3: mkv
        if (ep.ext != 'mkv') '${IptvService.baseUrl}/movie/$u2/$p2/${ep.streamId}.mkv',
        // Fallback 4: ts
        if (ep.ext != 'ts') '${IptvService.baseUrl}/movie/$u2/$p2/${ep.streamId}.ts',
        // Fallback 5: series endpoint no extension
        '${IptvService.baseUrl}/series/$u2/$p2/${ep.streamId}',
      ];
    }
    throw Exception('No episode selected. Tap an episode from the list below.');
  }

  Future<void> _playEpisode(EpisodeInfo ep) async {
    setState(() {
      _currentEpisode = ep;
      _playerError = null;
    });
    await _startPlay(episode: ep);
  }

  Future<void> _startPlay({EpisodeInfo? episode}) async {
    EpisodeInfo? ep = episode;

    // For series: if episodes are still loading, wait for them (max 15s)
    if (widget.item.isSeries && ep == null && _currentEpisode == null) {
      if (_episodesLoading) {
        setState(() {
          _playerLoading = true;
          _playing = true;
          _playerError = null;
        });
        // Poll until episodes are ready or timeout
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
    });

    _cc?.dispose();
    _vpc?.dispose();
    _cc = null;
    _vpc = null;

    try {
      // ── Step 1: Request audio focus + set Android STREAM_MUSIC to MAX
      // This is the #1 fix for muted IPTV channels: even if VideoPlayerController
      // sets volume=1.0, if Android's STREAM_MUSIC is 0 the device is silent.
      try {
        await _audioChannel.invokeMethod('requestAudioFocus');
        await _audioChannel.invokeMethod('setMaxVolume');
      } catch (_) {} // Ignore on non-Android platforms

      final state = context.read<AppState>();
      final rawUrls = await _candidateUrls(state, episode: ep);
      final urls = rawUrls;

      VideoPlayerController? ctrl;

      // Tuned timeouts: live=12s (fast-fail for dead channels), movie=15s, series=25s
      final tSecs = widget.item.isLive
          ? 12
          : widget.item.isSeries
              ? 25
              : 15;
      for (final url in urls) {
        try {
          debugPrint('▶ Trying: $url');
          ctrl = await _buildController(url, timeoutSeconds: tSecs);
          debugPrint('✅ Playing: $url');
          break; // success
        } catch (e) {
          ctrl?.dispose();
          ctrl = null;
          debugPrint('✗ Failed $url: $e');
        }
      }

      if (ctrl == null) {
        throw Exception(
            'Stream unavailable.\nAll ${urls.length} URL formats tried.');
      }

      _vpc = ctrl;
      _vpc!.addListener(_onPlayerValueChanged);

      _cc = ChewieController(
        videoPlayerController: _vpc!,
        autoPlay: true,
        looping: widget.item.isLive,
        isLive: widget.item.isLive,
        aspectRatio:
            _vpc!.value.aspectRatio > 0 ? _vpc!.value.aspectRatio : 16 / 9,
        allowFullScreen: true,
        // Disable in-player mute button — audio must NEVER be mutable
        allowMuting: false,
        placeholder: Container(color: Colors.black),
        materialProgressColors: ChewieProgressColors(
          playedColor: AppColors.accent,
          handleColor: AppColors.accent,
          backgroundColor: AppColors.bg4,
          bufferedColor: AppColors.accent.withValues(alpha: 0.3),
        ),
      );

      if (!mounted) return;
      setState(() => _playerLoading = false);

      // ── Step 2: Immediate Flutter-level volume enforcement
      // Set volume immediately and at multiple intervals to catch codec reset windows.
      // CNN, Cartoon Network, BBC, and many IPTV streams reset volume during buffering.
      for (final ms in [0, 100, 250, 500, 800, 1200, 1800, 2500]) {
        Future.delayed(Duration(milliseconds: ms), () {
          if (mounted) _vpc?.setVolume(1.0).catchError((_) {});
        });
      }

      // ── Step 3: Re-enforce Android STREAM_MUSIC at the hardware level
      // requestAudioFocus also triggers the native deferred schedule (0.5s–8s)
      Future.delayed(const Duration(milliseconds: 200), () async {
        try { await _audioChannel.invokeMethod('requestAudioFocus'); } catch (_) {}
        _vpc?.setVolume(1.0).catchError((_) {});
      });

      // ── Step 4: Repeating enforcement timer (every 300ms for 5s, then 1s for 15s)
      _startVolumeEnforcement();
    } catch (e) {
      if (!mounted) return;
      // Don't show error — auto-retry instead
      _scheduleAutoRetry();
    }
  }

  void _resetPlayer() {
    _retryTimer?.cancel();
    _cc?.dispose();
    _vpc?.dispose();
    _cc = null;
    _vpc = null;
    setState(() {
      _playing = false;
      _playerLoading = false;
      _playerError = null;
      _autoRetrying = false;
      _retryCount = 0;
    });
  }

  /// Navigate to the next channel / movie / series in the list.
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

  // ── Build ───────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final state = context.watch<AppState>();
    final isFav = state.isFavorite(item.id);
    final screenW = MediaQuery.of(context).size.width;

    // PopScope: pause stream when user presses hardware back button
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // Pause playback before navigating away
        _vpc?.pause();
        Navigator.of(context).pop();
      },
      child: Scaffold(
        backgroundColor: AppColors.bg,
        body: CustomScrollView(
        slivers: [
          // ── Hero / Player ─────────────────────────────────────
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
                  // Auto-retry banner (shown instead of error)
                  if (_autoRetrying)
                    _retryingBanner()
                  else if (_playerError != null)
                    _errorBanner(_playerError!, onRetry: _startPlay),

                  // Badges
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    if (item.isLive) const LiveBadge(),
                    if (item.rating != null)
                      RatingBadge(rating: item.rating!),
                    if (item.genre != null || item.category != null)
                      _chip(item.genre ?? item.category ?? ''),
                    if (item.year != null) _chip('${item.year}'),
                  ]),
                  const SizedBox(height: 14),

                  // Title
                  Text(item.title,
                      style: const TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                        letterSpacing: -0.5,
                      )),
                  const SizedBox(height: 8),

                  // Meta
                  Wrap(spacing: 16, runSpacing: 4, children: [
                    if (item.duration != null && item.duration!.isNotEmpty)
                      _metaItem(Icons.access_time, item.duration!),
                    if (item.episodeCount != null)
                      _metaItem(Icons.video_library_outlined,
                          '${item.episodeCount} Episode${(item.episodeCount ?? 1) > 1 ? 's' : ''}'),
                    if (item.channelNumber != null)
                      _metaItem(
                          Icons.live_tv, 'Ch. ${item.channelNumber}'),
                  ]),
                  const SizedBox(height: 16),

                  // Description
                  if (item.description != null &&
                      item.description!.isNotEmpty)
                    Text(item.description!,
                        style: const TextStyle(
                            fontSize: 14,
                            color: AppColors.textSecondary,
                            height: 1.65)),
                  const SizedBox(height: 24),

                  // Action row
                  Row(children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: (_playerLoading || _autoRetrying) ? null : _startPlay,
                        icon: _playerLoading
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white))
                            : const Icon(Icons.play_arrow, size: 20),
                        label: Text(_playerLoading
                            ? 'Loading…'
                            : _autoRetrying
                                ? 'Retrying in ${_retryCountdown}s…'
                                : item.isLive
                                    ? 'Watch Live'
                                    : item.isSeries
                                        ? 'Play S1 E1'
                                        : 'Play'),
                        style: ElevatedButton.styleFrom(
                            padding:
                                const EdgeInsets.symmetric(vertical: 13)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    _iconBtn(
                      icon: isFav ? Icons.favorite : Icons.favorite_border,
                      color: isFav ? AppColors.accent : AppColors.textTertiary,
                      active: isFav,
                      onTap: () {
                        state.toggleFavorite(item);
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(state.isFavorite(item.id)
                              ? 'Added to My List'
                              : 'Removed from My List'),
                          backgroundColor: AppColors.bg4,
                          duration: const Duration(seconds: 2),
                        ));
                      },
                    ),
                    const SizedBox(width: 12),
                    _iconBtn(
                      icon: Icons.skip_next,
                      color: AppColors.textTertiary,
                      onTap: _playNext,
                    ),
                  ]),

                  // ── Episode picker (series only) ──────────────
                  if (item.isSeries) ...[
                    const SizedBox(height: 28),
                    _episodeSection(),
                  ],

                  // ── EPG (live) ────────────────────────────────────────────
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
                    // "Later" — tapping opens the next channel in the list
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

                  // ── Related ───────────────────────────────────
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
    ),  // end PopScope child Scaffold
    );  // end PopScope
  }

  // ── Episode section ───────────────────────────────────────────────────────
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
        // Season header + picker
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

        // Episode list
        ..._seasons[_selectedSeason].episodes.map((ep) {
          final isPlaying = _currentEpisode?.streamId == ep.streamId;
          return _episodeTile(ep, isPlaying);
        }),
      ],
    );
  }

  Widget _seasonDropdown() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.bg3,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.border),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<int>(
          value: _selectedSeason,
          dropdownColor: AppColors.bg3,
          isDense: true,
          style: const TextStyle(
              color: AppColors.textPrimary, fontSize: 13),
          items: List.generate(
              _seasons.length,
              (i) => DropdownMenuItem(
                    value: i,
                    child: Text(_seasons[i].label),
                  )),
          onChanged: (v) {
            if (v != null) setState(() => _selectedSeason = v);
          },
        ),
      ),
    );
  }

  Widget _episodeTile(EpisodeInfo ep, bool isPlaying) {
    // Use InkWell instead of GestureDetector so TV remote D-pad / Enter works
    return InkWell(
      onTap: () => _playEpisode(ep),
      borderRadius: BorderRadius.circular(8),
      focusColor: AppColors.accent.withValues(alpha: 0.15),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
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
          // Episode number circle
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

          // Episode info
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

          // Play icon
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

  // ── Player area ───────────────────────────────────────────────────────────
  Widget _playerArea(ContentItem item) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Background thumbnail
        if (item.imageUrl.isNotEmpty)
          CachedNetworkImage(
            imageUrl: item.imageUrl,
            fit: BoxFit.cover,
            errorWidget: (_, __, ___) => Container(color: AppColors.bg4),
          )
        else
          Container(color: AppColors.bg4),

        // Dim overlay
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

        // Video player
        if (_playing && _cc != null && !_playerLoading)
          Chewie(controller: _cc!),

        // Loading
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

        // Play button — autofocus enables TV remote OK/Select button
        if (!_playing && !_playerLoading && _playerError == null)
          Center(
            child: InkWell(
              onTap: _startPlay,
              autofocus: true,
              borderRadius: BorderRadius.circular(34),
              focusColor: AppColors.accent.withValues(alpha: 0.3),
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

        // Error in player
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
                  ElevatedButton.icon(
                    onPressed: _startPlay,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('Retry'),
                    style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 10)),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  // ── Helper widgets ────────────────────────────────────────────────────────
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

  /// Shown while auto-retry countdown is active — replaces the error banner.
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

  Widget _iconBtn(
          {required IconData icon,
          required Color color,
          bool active = false,
          required VoidCallback onTap}) =>
      InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        focusColor: AppColors.accent.withValues(alpha: 0.25),
        hoverColor: AppColors.accent.withValues(alpha: 0.1),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: active
                ? AppColors.accent.withValues(alpha: 0.15)
                : AppColors.bg3,
            borderRadius: BorderRadius.circular(8),
            border:
                Border.all(color: active ? AppColors.accent : AppColors.border),
          ),
          child: Icon(icon, color: color, size: 22),
        ),
      );

  Widget _scheduleRow(String label, String title, bool isNow,
          {VoidCallback? onTap}) =>
      InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: isNow
                ? AppColors.accent.withValues(alpha: 0.1)
                : AppColors.bg3,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: isNow
                    ? AppColors.accent.withValues(alpha: 0.4)
                    : onTap != null
                        ? AppColors.accent.withValues(alpha: 0.25)
                        : AppColors.border),
          ),
          child: Row(children: [
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: isNow ? AppColors.accent : AppColors.bg4,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: isNow ? Colors.white : AppColors.textTertiary,
                  )),
            ),
            const SizedBox(width: 12),
            Expanded(
                child: Text(title,
                    style: const TextStyle(
                        fontSize: 13, color: AppColors.textPrimary))),
            if (onTap != null)
              const Icon(Icons.play_circle_outline,
                  color: AppColors.accent, size: 20),
          ]),
        ),
      );

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
      related = state.series
          .where(
              (s) => s.id != current.id && s.category == current.category)
          .take(10)
          .toList();
      if (related.length < 3) {
        related = state.series
            .where((s) => s.id != current.id)
            .take(10)
            .toList();
      }
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
}
