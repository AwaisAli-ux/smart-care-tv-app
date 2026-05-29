import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';
import '../theme/app_theme.dart';
import '../models/content_model.dart';
import '../services/app_state.dart';
import '../services/iptv_service.dart';
import 'main_shell.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _obscure = true;
  bool _loading = false;
  String _statusMessage = '';

  void _login() async {
    final user = _userCtrl.text.trim();
    final pass = _passCtrl.text;

    if (user.isEmpty || pass.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter your username and password'),
          backgroundColor: AppColors.accentDark,
        ),
      );
      return;
    }

    setState(() {
      _loading = true;
      _statusMessage = 'Authenticating...';
    });

    // Always clear cached categories so fresh data is fetched for this session
    IptvService.resetCache();

    bool authSuccess = false;

    try {
      authSuccess = await IptvService.authenticate(user, pass);
    } catch (e) {
      if (!mounted) return;
      setState(() => _statusMessage = 'Auth error, retrying...');
      // Retry once
      try {
        authSuccess = await IptvService.authenticate(user, pass);
      } catch (_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Connection failed: $e')),
        );
        setState(() {
          _loading = false;
          _statusMessage = '';
        });
        return;
      }
    }

    if (!mounted) return;

    if (authSuccess) {
      // Capture context-dependent objects before any await
      final appState = context.read<AppState>();
      final navigator = Navigator.of(context);

      appState.login(user, pass);

      // Store login state persistently
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('loggedIn', true);
      await prefs.setString('username', user);
      await prefs.setString('password', pass);

      if (!mounted) return;

      // Load persisted favorites before navigating — pass username explicitly
      // to avoid any race condition with _username assignment.
      await appState.loadFavorites(username: user);

      // Navigate immediately — content loads in background
      navigator.pushReplacement(
        MaterialPageRoute(builder: (_) => const MainShell()),
      );
      // Start loading content + categories in background (all parallel)
      _loadContentInBackground(appState, user, pass);
    } else {
      setState(() {
        _loading = false;
        _statusMessage = '';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invalid username or password')),
      );
    }
  }

  void _loadContentInBackground(AppState appState, String user, String pass) async {
    appState.setContentLoading(true);

    // 1. Pre-load categories (fast)
    await IptvService.ensureCategoriesLoaded(user, pass).catchError((_) {});

    // 2. Load Live Channels and update UI immediately
    final ch = await IptvService.getLiveChannels(user, pass)
        .catchError((_) => <ContentItem>[]);
    if (ch.isNotEmpty) appState.setChannels(ch);

    // 3. Load Movies and update UI immediately
    final mv = await IptvService.getMovies(user, pass)
        .catchError((_) => <ContentItem>[]);
    if (mv.isNotEmpty) appState.setMovies(mv);

    // All done
    appState.setContentLoading(false);
  }

  @override
  void dispose() {
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isWide = size.width > 700;

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: isWide ? _wideLayout() : _narrowLayout(),
    );
  }

  Widget _wideLayout() {
    return Row(
      children: [
        SizedBox(width: 400, child: _formSection()),
        Expanded(child: _posterWall()),
      ],
    );
  }

  Widget _narrowLayout() {
    return SingleChildScrollView(
      child: Column(
        children: [
          SizedBox(
            height: 200,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _posterWall(),
                Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, AppColors.bg],
                    ),
                  ),
                ),
              ],
            ),
          ),
          _formSection(),
        ],
      ),
    );
  }

  Widget _formSection() {
    return Container(
      color: AppColors.bg,
      padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 48),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Logo — uses the actual app_logo.png placed in assets/images/
          Row(
            children: [
              Image.asset(
                'assets/images/app_logo.png',
                width: 52,
                height: 52,
                filterQuality: FilterQuality.high,
              ),
              const SizedBox(width: 12),
              const Text(
                'Smart Care TV',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: AppColors.accent,
                  letterSpacing: -0.3,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Stream smarter. Watch everything.',
            style: TextStyle(fontSize: 13, color: AppColors.textTertiary),
          ),
          const SizedBox(height: 36),

          // Username
          const Text('USERNAME',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppColors.accent,
                  letterSpacing: 0.8)),
          const SizedBox(height: 8),
          TextField(
            controller: _userCtrl,
            autofocus: true,
            textInputAction: TextInputAction.next,
            style: const TextStyle(
                color: AppColors.textPrimary, fontFamily: 'Inter'),
            decoration: const InputDecoration(hintText: 'Enter your username'),
          ),
          const SizedBox(height: 16),

          // Password
          const Text('PASSWORD',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppColors.accent,
                  letterSpacing: 0.8)),
          const SizedBox(height: 8),
          TextField(
            controller: _passCtrl,
            obscureText: _obscure,
            textInputAction: TextInputAction.done,
            style: const TextStyle(
                color: AppColors.textPrimary, fontFamily: 'Inter'),
            onSubmitted: (_) => _login(),
            decoration: InputDecoration(
              hintText: 'Enter your password',
              suffixIcon: IconButton(
                icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility,
                    color: AppColors.textTertiary, size: 20),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
          ),
          const SizedBox(height: 24),

          // Button
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton(
              onPressed: _loading ? null : _login,
              child: _loading
                  ? Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white)),
                        const SizedBox(width: 12),
                        Text(_statusMessage,
                            style: const TextStyle(
                                fontSize: 12, color: Colors.white70)),
                      ],
                    )
                  : const Text('SIGN IN',
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.0)),
            ),
          ),
          const SizedBox(height: 16),

          Center(
            child: RichText(
              text: TextSpan(
                style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textTertiary,
                    fontFamily: 'Inter'),
                children: [
                  const TextSpan(text: "Need an account? "),
                  WidgetSpan(
                    child: InkWell(
                      onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                            content: Text('Contact your service provider')),
                      ),
                      borderRadius: BorderRadius.circular(4),
                      focusColor: AppColors.accent.withValues(alpha: 0.2),
                      child: const Text('Contact support',
                          style: TextStyle(
                              color: AppColors.accent,
                              fontSize: 12,
                              fontFamily: 'Inter')),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _posterWall() {
    final List<String> posters = [
      'https://image.tmdb.org/t/p/w500/4m1Au3YkjqsxF8iwQy0fPYSxE0h.jpg',
      'https://image.tmdb.org/t/p/w500/1pdfLvkbY9ohJlCjQH2CZjjYVvJ.jpg',
      'https://image.tmdb.org/t/p/w500/8cdWjvZQUExUUTzyp4t6EDMubfO.jpg',
      'https://image.tmdb.org/t/p/w500/b33nnKl1GSFbao4l3fZDDqsMx0F.jpg',
      'https://image.tmdb.org/t/p/w500/iADOJ8Zymht2JPMoy3R7xceZprc.jpg',
      'https://image.tmdb.org/t/p/w500/sh7Rg8Er3tFcN9BpKIPOMvALgZd.jpg',
      'https://image.tmdb.org/t/p/w500/vpnVM9B6NMmQpWeZvzLvDESb2QY.jpg',
      'https://image.tmdb.org/t/p/w500/pjnD08FlMAIXsfOLKQbvmO0f0MD.jpg',
    ];
    return GridView.builder(
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        childAspectRatio: 0.65,
      ),
      itemCount: 20,
      itemBuilder: (_, i) {
        final url = posters[i % posters.length];
        return Image.network(
          url,
          fit: BoxFit.cover,
          opacity: const AlwaysStoppedAnimation(0.5),
          errorBuilder: (_, __, ___) => Container(color: AppColors.bg4),
        );
      },
    );
  }
}
