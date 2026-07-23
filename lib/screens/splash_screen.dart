import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/content_model.dart';
import '../services/app_state.dart';
import '../services/iptv_service.dart';
import '../services/auth_api.dart';
import '../services/auth_config.dart';
import '../services/device_service.dart';
import '../services/device_lock_service.dart';
import '../services/player_factory.dart';
import '../theme/app_theme.dart';
import 'login_screen.dart';
import 'locked_screen.dart';
import 'expired_screen.dart';
import 'main_shell.dart';

// Same demo constants as login_screen.dart — kept in sync manually.
const _splashDemoUrl  = 'http://full.smartcaretv.app';
const _splashDemoUser = 'david';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _fadeAnim;
  late Animation<double> _scaleAnim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1200));
    _fadeAnim = CurvedAnimation(parent: _ctrl, curve: Curves.easeIn);
    _scaleAnim = Tween<double>(begin: 0.8, end: 1.0)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutBack));
    _ctrl.forward();

    // After splash animation, decide where to route — 1.5 s is enough to
    // render the animation while SharedPreferences is being read.
    Future.delayed(const Duration(milliseconds: 1500), _decideRoute);
  }

  /// Every app launch: if the user was logged in, re-validate this device
  /// with the backend BEFORE showing any content (device-binding gate).
  Future<void> _decideRoute() async {
    if (!mounted) return;

    // Block here — not in the background — until media_kit's one-time,
    // multi-second-blocking native decoder-list query has actually finished.
    // Racing it in the background isn't reliable: if the user reaches a
    // channel before that warm-up completes, the same blocking native call
    // still lands on the main isolate right as they tap play, producing a
    // real Android ANR ("Waited 5002ms for FocusEvent"). The splash screen
    // is the one place in the app where a multi-second stall is safe (no
    // pending input to time out on), so pay for it here. Capped so a
    // freak failure can't strand the user on the splash screen forever.
    try {
      await PlayerFactory.ensureWarm().timeout(const Duration(seconds: 12));
    } catch (_) {}
    if (!mounted) return;

    final prefs = await SharedPreferences.getInstance();
    final loggedIn = prefs.getBool(AuthPrefsKeys.loggedIn) ?? false;

    if (!mounted) return;

    if (!loggedIn) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
      );
      return;
    }

    final username  = prefs.getString(AuthPrefsKeys.username)  ?? '';
    final password  = prefs.getString(AuthPrefsKeys.password)  ?? '';
    final serverUrl = prefs.getString(AuthPrefsKeys.serverUrl) ?? '';
    final token     = prefs.getString(AuthPrefsKeys.scToken);

    final appState = Provider.of<AppState>(context, listen: false);

    // ── Direct IPTV or Demo Account (no backend token) ─────────────────────
    if (serverUrl.isNotEmpty && (token == null || token.isEmpty)) {
      appState.login(username, password);
      appState.setServerUrl(serverUrl);
      IptvService.setBaseUrl(serverUrl);
      await appState.loadFavorites(username: username);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const MainShell()),
      );
      appState.setContentLoading(true);
      if (serverUrl == _splashDemoUrl && username == _splashDemoUser) {
        _loadDemoContent(appState);
      } else {
        _loadContent(appState, username, password);
      }
      return;
    }

    if (token == null || token.isEmpty) {
      await prefs.setBool(AuthPrefsKeys.loggedIn, false);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
      );
      return;
    }

    // ── Device-binding gate: validate BEFORE showing any home content ──────
    final device = await DeviceService.get();
    final result = await AuthApi.checkStatus(token: token, deviceId: device.deviceId);

    if (!mounted) return;

    switch (result.status) {
      case AuthStatus.ok:
        final xtream = result.xtream;
        final xHost = (xtream != null && xtream.host.isNotEmpty) ? xtream.host : serverUrl;
        final xUser = (xtream != null && xtream.username.isNotEmpty) ? xtream.username : username;
        final xPass = (xtream != null && xtream.password.isNotEmpty) ? xtream.password : password;

        await prefs.setInt(AuthPrefsKeys.scLastCheck, DateTime.now().millisecondsSinceEpoch);
        if (xtream != null && xtream.host.isNotEmpty) {
          await prefs.setString(AuthPrefsKeys.serverUrl, xtream.host);
          await prefs.setString(AuthPrefsKeys.username, xtream.username);
          await prefs.setString(AuthPrefsKeys.password, xtream.password);
        }

        appState.login(xUser, xPass);
        appState.setServerUrl(xHost);
        await appState.loadFavorites(username: xUser);

        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const MainShell()),
        );

        IptvService.setBaseUrl(xHost);
        appState.setContentLoading(true);
        _loadContent(appState, xUser, xPass);
        break;

      case AuthStatus.locked:
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const LockedScreen(reason: LockReason.locked)),
        );
        break;

      case AuthStatus.expired:
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => ExpiredScreen(expiryDate: result.expiryDate)),
        );
        break;

      case AuthStatus.invalidToken:
        await prefs.setBool(AuthPrefsKeys.loggedIn, false);
        await prefs.remove(AuthPrefsKeys.scToken);
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const LoginScreen()),
        );
        break;

      case AuthStatus.networkError:
      case AuthStatus.error:
      case AuthStatus.deviceLimit:
      case AuthStatus.invalidCredentials:
        // Backend unreachable at launch — allow a grace period on cached
        // credentials so a brief outage doesn't lock out paying customers.
        final lastCheck = prefs.getInt(AuthPrefsKeys.scLastCheck) ?? 0;
        final elapsed = DateTime.now().millisecondsSinceEpoch - lastCheck;
        final graceExpired = lastCheck == 0 ||
            elapsed > AuthConfig.offlineGracePeriod.inMilliseconds;

        if (graceExpired) {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (_) => LockedScreen(reason: LockReason.offline, onRetry: _decideRoute),
            ),
          );
          break;
        }

        appState.login(username, password);
        appState.setServerUrl(serverUrl);
        await appState.loadFavorites(username: username);
        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const MainShell()),
        );
        IptvService.setBaseUrl(serverUrl);
        appState.setContentLoading(true);
        _loadContent(appState, username, password);
        break;
    }
  }

  /// Loads placeholder content for demo accounts.
  static void _loadDemoContent(AppState appState) {
    final demoChannels = List.generate(12, (i) {
      final names = [
        'News Channel HD', 'Sports Zone', 'Entertainment Plus',
        'Documentary World', 'Kids Corner', 'Movie Central',
        'Music Hits', 'Nature TV', 'Science Channel',
        'Comedy Club', 'Fashion TV', 'Travel & Food',
      ];
      final genres = [
        'News', 'Sports', 'Entertainment', 'Documentary',
        'Kids', 'Movies', 'Music', 'Nature', 'Science',
        'Comedy', 'Fashion', 'Lifestyle',
      ];
      return ContentItem(
        id: 'demo_ch_$i',
        type: ContentType.live,
        title: names[i % names.length],
        description: 'Sample live channel. Sign in with real credentials to stream.',
        imageUrl: '',
        genre: genres[i % genres.length],
        category: genres[i % genres.length],
        channelNumber: i + 1,
        nowPlaying: 'Sample Program ${i + 1}',
        nextUp: 'Upcoming Show ${i + 2}',
      );
    });
    final demoMovies = List.generate(16, (i) {
      final titles = [
        'Action Hero', 'The Mystery', 'Love Story', 'Sci-Fi Adventure',
        'The Thriller', 'Comedy Night', 'War Chronicle', 'Family Joy',
        'Horror Night', 'Drama Series', 'Animation World', 'The Western',
        'Crime City', 'Fantasy Realm', 'Romantic Eve', 'Sports Glory',
      ];
      final genres = [
        'Action', 'Mystery', 'Romance', 'Sci-Fi',
        'Thriller', 'Comedy', 'War', 'Family',
        'Horror', 'Drama', 'Animation', 'Western',
        'Crime', 'Fantasy', 'Romance', 'Sports',
      ];
      return ContentItem(
        id: 'demo_mv_$i',
        type: ContentType.movie,
        title: titles[i % titles.length],
        description: 'Sample movie. Sign in with real credentials to access your library.',
        imageUrl: '',
        genre: genres[i % genres.length],
        category: genres[i % genres.length],
        year: 2020 + (i % 5),
        rating: 6.0 + (i % 40) / 10,
        duration: '${90 + (i * 7) % 60} min',
      );
    });
    appState.setChannels(demoChannels);
    appState.setMovies(demoMovies);
    appState.setContentLoading(false);
  }

  /// Loads content in parallel to maximize network speed and updates the UI
  /// incrementally as each type arrives.
  static Future<void> _loadContent(
      AppState appState, String username, String password) async {
    final liveFuture = IptvService.getLiveChannels(username, password)
        .then((ch) {
          if (ch.isNotEmpty) appState.setChannels(ch);
          return ch;
        })
        .catchError((_) => <ContentItem>[]);

    final moviesFuture = IptvService.getMovies(username, password)
        .then((mv) {
          if (mv.isNotEmpty) appState.setMovies(mv);
          return mv;
        })
        .catchError((_) => <ContentItem>[]);

    final seriesFuture = IptvService.getSeries(username, password)
        .then((sr) {
          if (sr.isNotEmpty) appState.setSeries(sr);
          return sr;
        })
        .catchError((_) => <ContentItem>[]);

    await Future.wait([liveFuture, moviesFuture, seriesFuture]);

    debugPrint('[Splash] Content loaded in parallel');

    // All done
    appState.setContentLoading(false);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Center(
        child: FadeTransition(
          opacity: _fadeAnim,
          child: ScaleTransition(
            scale: _scaleAnim,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Logo — transparent PNG, no clipping needed
                Image.asset(
                  'assets/images/app_logo.png',
                  width: 120,
                  height: 120,
                  filterQuality: FilterQuality.high,
                ),
                const SizedBox(height: 20),
                const Text(
                  'Smart Care TV',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Premium Streaming',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 14,
                    color: AppColors.textTertiary,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 48),
                const SizedBox(
                  width: 32,
                  height: 32,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(AppColors.accent),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
