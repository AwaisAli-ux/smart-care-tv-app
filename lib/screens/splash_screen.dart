import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/content_model.dart';
import '../services/app_state.dart';
import '../services/iptv_service.dart';
import '../theme/app_theme.dart';
import 'login_screen.dart';
import 'main_shell.dart';

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

  Future<void> _decideRoute() async {
    if (!mounted) return;

    final prefs = await SharedPreferences.getInstance();
    final loggedIn = prefs.getBool('loggedIn') ?? false;

    if (!mounted) return;

    if (loggedIn) {
      final username = prefs.getString('username') ?? '';
      final password = prefs.getString('password') ?? '';

      // Capture AppState reference NOW before we navigate away
      final appState = Provider.of<AppState>(context, listen: false);

      // Restore auth credentials into AppState immediately
      appState.login(username, password);
      appState.setContentLoading(true);

      // Restore persisted favorites immediately — pass username explicitly
      // to guarantee we read from the correct per-user key.
      await appState.loadFavorites(username: username);

      // Navigate to MainShell immediately — don't make user wait for content
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const MainShell()),
      );

      // Load content in background using the captured AppState reference
      // (safe because AppState is a long-lived ChangeNotifier, not tied to
      // this widget's BuildContext)
      _loadContent(appState, username, password);
    } else {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
      );
    }
  }

  /// Loads content sequentially to avoid IPTV server rate limits (anti-DDoS),
  /// but updates the UI incrementally as each type arrives.
  static Future<void> _loadContent(
      AppState appState, String username, String password) async {
    // 1. Pre-load categories (fast)
    await IptvService.ensureCategoriesLoaded(username, password)
        .catchError((_) {});

    // 2. Load Live Channels and update UI immediately
    final ch = await IptvService.getLiveChannels(username, password)
        .catchError((_) => <ContentItem>[]);
    if (ch.isNotEmpty) appState.setChannels(ch);

    // 3. Load Movies and update UI immediately
    final mv = await IptvService.getMovies(username, password)
        .catchError((_) => <ContentItem>[]);
    if (mv.isNotEmpty) appState.setMovies(mv);

    // 4. Load Series and update UI immediately
    final sr = await IptvService.getSeries(username, password)
        .catchError((_) => <ContentItem>[]);
    if (sr.isNotEmpty) appState.setSeries(sr);

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
                SizedBox(
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
