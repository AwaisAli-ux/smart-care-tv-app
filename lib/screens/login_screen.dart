import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';
import '../theme/app_theme.dart';
import '../models/content_model.dart';
import '../services/app_state.dart';
import '../services/iptv_service.dart';
import '../services/auth_api.dart';
import '../services/auth_config.dart';
import '../services/device_lock_service.dart';
import '../widgets/tv_focus.dart';
import '../services/device_profile_service.dart';
import 'main_shell.dart';

// ── Demo-mode credentials ──────────────────────────────────────────────────────
// Use these to sign in and see the app structure with placeholder content.
// No real server is contacted, and no device-binding check runs.
const _demoUrl  = 'http://full.smartcaretv.app';
const _demoUser = 'david';
const _demoPass = 'david123';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _urlCtrl  = TextEditingController();
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _obscure = true;
  bool _loading = false;
  String _statusMessage = '';

  final ScrollController _scrollController = ScrollController();

  final FocusNode _urlFocusNode     = FocusNode(debugLabel: 'LoginUrl');
  final FocusNode _userFocusNode    = FocusNode(debugLabel: 'LoginUser');
  final FocusNode _passFocusNode    = FocusNode(debugLabel: 'LoginPass');
  final FocusNode _eyeFocusNode     = FocusNode(debugLabel: 'LoginEye');
  final FocusNode _loginFocusNode   = FocusNode(debugLabel: 'LoginBtn');
  final FocusNode _supportFocusNode = FocusNode(debugLabel: 'LoginSupport');

  // FIX #2 — the one and only traversal order for this screen. Everything
  // (wrap-around, up, down) is derived from this list, so the order can never
  // disagree with itself the way five hand-written handlers did.
  late final List<FocusNode> _order = [
    _urlFocusNode,      // 1
    _userFocusNode,     // 2
    _passFocusNode,     // 3
    _eyeFocusNode,      // 4
    _loginFocusNode,    // 5
    _supportFocusNode,  // 6
  ];

  // FIX #2 (item 4) — which field currently has the on-screen keyboard open.
  // On TV, arriving at a field must NOT open the IME (that traps the user);
  // the field only shows a focus border, and SELECT starts editing.
  FocusNode? _editingField;

  bool _isEditing(FocusNode node) => _editingField == node;

  @override
  void initState() {
    super.initState();

    for (final node in _order) {
      node.addListener(_onFocusChange);
    }

    // The three text fields need their handler on the node itself: a focused
    // EditableText consumes arrow keys before they can bubble to an ancestor.
    _urlFocusNode.onKeyEvent  = _navKey;
    _userFocusNode.onKeyEvent = _navKey;
    _passFocusNode.onKeyEvent = _navKey;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _urlFocusNode.requestFocus();
    });
  }

  // ── FIX #2: unified D-pad navigation ──────────────────────────────────────
  bool _isSelectKey(LogicalKeyboardKey k) =>
      k == LogicalKeyboardKey.select ||
      k == LogicalKeyboardKey.enter ||
      k == LogicalKeyboardKey.numpadEnter ||
      k == LogicalKeyboardKey.gameButtonA ||
      k.keyId == 13 ||
      k.keyId == 23 ||
      k.keyId == 66 ||
      k.keyId == 96 ||
      k.keyId == 107 ||
      k.keyId == 160;

  /// Circular up/down traversal plus right/left between the password field and
  /// its visibility toggle. Used both on the text field nodes directly and on
  /// the group Focus that wraps the form.
  KeyEventResult _navKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final current = FocusManager.instance.primaryFocus;
    final idx = _order.indexOf(current ?? _urlFocusNode);
    if (idx < 0) return KeyEventResult.ignored;

    final key = event.logicalKey;
    final node = _order[idx];

    // ── Keyboard is open (user is typing) ────────────────────────────────────
    // Back key closes keyboard and stays on same field.
    // Up/Down while typing: close keyboard and jump to prev/next text field,
    // then reopen keyboard there so the user can keep typing without an extra OK.
    if (_editingField != null) {
      if (_isBackKey(key)) {
        _stopEditing();
        return KeyEventResult.handled;
      }
      // Up → previous text field (skip non-text nodes like eye toggle)
      if (key == LogicalKeyboardKey.arrowUp || key.keyId == 38) {
        _stopEditing();
        final textNodes = [_urlFocusNode, _userFocusNode, _passFocusNode];
        final tIdx = textNodes.indexOf(node);
        if (tIdx > 0) {
          // Small delay so the keyboard hide animation doesn't fight the show
          Future.delayed(const Duration(milliseconds: 80), () {
            if (mounted) _startEditing(textNodes[tIdx - 1]);
          });
        }
        return KeyEventResult.handled;
      }
      // Down → next text field
      if (key == LogicalKeyboardKey.arrowDown || key.keyId == 40) {
        _stopEditing();
        final textNodes = [_urlFocusNode, _userFocusNode, _passFocusNode];
        final tIdx = textNodes.indexOf(node);
        if (tIdx >= 0 && tIdx < textNodes.length - 1) {
          Future.delayed(const Duration(milliseconds: 80), () {
            if (mounted) _startEditing(textNodes[tIdx + 1]);
          });
        } else {
          // Past last text field → move to Sign In button
          Future.delayed(const Duration(milliseconds: 80), () {
            if (mounted) {
              _loginFocusNode.requestFocus();
              _scrollFocusedIntoView();
            }
          });
        }
        return KeyEventResult.handled;
      }
      // All other keys while editing go to the IME
      return KeyEventResult.ignored;
    }

    // ── Keyboard is closed (D-pad navigation between fields) ─────────────────
    // SELECT on a text field: open keyboard immediately
    if (_isSelectKey(key)) {
      if (node == _urlFocusNode ||
          node == _userFocusNode ||
          node == _passFocusNode) {
        _startEditing(node);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    if (key == LogicalKeyboardKey.arrowDown || key.keyId == 40) {
      _order[(idx + 1) % _order.length].requestFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp || key.keyId == 38) {
      _order[(idx - 1 + _order.length) % _order.length].requestFocus();
      return KeyEventResult.handled;
    }
    // The eye toggle is also reachable sideways from the password field.
    if ((key == LogicalKeyboardKey.arrowRight || key.keyId == 39) &&
        node == _passFocusNode) {
      _eyeFocusNode.requestFocus();
      return KeyEventResult.handled;
    }
    if ((key == LogicalKeyboardKey.arrowLeft || key.keyId == 37) &&
        node == _eyeFocusNode) {
      _passFocusNode.requestFocus();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  bool _isBackKey(LogicalKeyboardKey k) =>
      k == LogicalKeyboardKey.goBack ||
      k == LogicalKeyboardKey.escape ||
      k.keyId == 27 ||
      k.keyId == 166;

  /// The controller behind a given field's focus node.
  TextEditingController? _controllerFor(FocusNode node) {
    if (node == _urlFocusNode) return _urlCtrl;
    if (node == _userFocusNode) return _userCtrl;
    if (node == _passFocusNode) return _passCtrl;
    return null;
  }

  /// Opens the on-screen keyboard for [node] — only ever from an explicit
  /// SELECT press or a tap, never from focus arriving.
  ///
  /// Coming back to a field to correct a typo is the common case, so the
  /// caret goes to the END of whatever is already there. Otherwise it lands
  /// at position 0 and backspace does nothing to the wrong characters.
  void _startEditing(FocusNode node) {
    setState(() => _editingField = node);
    node.requestFocus();

    final ctrl = _controllerFor(node);
    if (ctrl != null) {
      ctrl.selection = TextSelection.collapsed(offset: ctrl.text.length);
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      SystemChannels.textInput.invokeMethod('TextInput.show');
    });
    _scrollFocusedIntoView();
  }

  /// Closes the keyboard and leaves focus on the field it was opened from —
  /// never drops focus somewhere else.
  void _stopEditing() {
    final node = _editingField;
    if (node == null) return;
    setState(() => _editingField = null);
    SystemChannels.textInput.invokeMethod('TextInput.hide');
    node.requestFocus();
  }

  void _login() async {
    final url = _urlCtrl.text.trim();
    final user = _userCtrl.text.trim();
    final pass = _passCtrl.text;

    if (url.isEmpty || user.isEmpty || pass.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter server URL, username, and password'),
          backgroundColor: AppColors.accentDark,
        ),
      );
      return;
    }

    // ── Demo mode bypass — no backend / device-binding check ───────────────
    if (user == _demoUser && pass == _demoPass) {
      await _loginDemo();
      return;
    }

    // Connect directly to the IPTV URL entered on the screen
    await _loginDirect(url, user, pass);
  }

  Future<void> _loginDirect(String url, String user, String pass) async {
    setState(() {
      _loading = true;
      _statusMessage = 'Authenticating...';
    });

    IptvService.setBaseUrl(url);
    IptvService.resetCache();

    bool authSuccess = false;
    try {
      authSuccess = await IptvService.authenticate(user, pass);
    } catch (e) {
      if (!mounted) return;
      setState(() => _statusMessage = 'Auth error, retrying...');
      try {
        authSuccess = await IptvService.authenticate(user, pass);
      } catch (err) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Connection failed: $err')),
        );
        setState(() {
          _loading = false;
          _statusMessage = '';
        });
        return;
      }
    }

    if (!mounted) return;

    if (!authSuccess) {
      setState(() {
        _loading = false;
        _statusMessage = '';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invalid username or password')),
      );
      return;
    }

    // ── Report this device to the admin backend (view + remote-block) ──────
    // Runs alongside the real IPTV auth above; only an explicit "locked"
    // response blocks sign-in. Any other outcome (unknown account, network
    // error, backend down) never stops a genuinely valid IPTV login.
    final appState = context.read<AppState>();
    final profile = appState.deviceProfile;
    final tracked = await AuthApi.trackDevice(
      username: user,
      serverUrl: url,
      deviceId: profile?.deviceId ?? 'unknown',
      deviceModel: profile?.model ?? '',
      deviceBrand: profile?.brand ?? '',
    );
    if (!mounted) return;
    if (tracked.status == AuthStatus.locked) {
      setState(() {
        _loading = false;
        _statusMessage = '';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tracked.message.isNotEmpty ? tracked.message : 'This device has been blocked. Contact support.')),
      );
      return;
    }

    final navigator = Navigator.of(context);

    appState.login(user, pass);
    appState.setServerUrl(url);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AuthPrefsKeys.loggedIn, true);
    await prefs.setString(AuthPrefsKeys.username, user);
    await prefs.setString(AuthPrefsKeys.password, pass);
    await prefs.setString(AuthPrefsKeys.serverUrl, url);
    // Remove backend token so watchdog knows this is a direct login
    await prefs.remove(AuthPrefsKeys.scToken);

    await appState.loadFavorites(username: user);

    navigator.pushReplacement(
      MaterialPageRoute(builder: (_) => const MainShell()),
    );
    _loadContentInBackground(appState, user, pass);
  }

  Future<void> _completeLogin(AuthResult result) async {
    final xtream = result.xtream;
    if (xtream == null || xtream.host.isEmpty) {
      setState(() { _loading = false; _statusMessage = ''; });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Server did not return stream credentials. Contact support.')),
      );
      return;
    }

    final appState = context.read<AppState>();
    final navigator = Navigator.of(context);

    IptvService.setBaseUrl(xtream.host);
    IptvService.resetCache();
    appState.login(xtream.username, xtream.password);
    appState.setServerUrl(xtream.host);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AuthPrefsKeys.loggedIn, true);
    await prefs.setString(AuthPrefsKeys.username, xtream.username);
    await prefs.setString(AuthPrefsKeys.password, xtream.password);
    await prefs.setString(AuthPrefsKeys.serverUrl, xtream.host);
    await prefs.setString(AuthPrefsKeys.scToken, result.token ?? '');
    await prefs.setInt(AuthPrefsKeys.scLastCheck, DateTime.now().millisecondsSinceEpoch);

    if (!mounted) return;

    await appState.loadFavorites(username: xtream.username);

    navigator.pushReplacement(
      MaterialPageRoute(builder: (_) => const MainShell()),
    );
    _loadContentInBackground(appState, xtream.username, xtream.password);
  }

  void _showDeviceLimitDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bg2,
        title: const Text('Device Limit Reached', style: TextStyle(color: AppColors.textPrimary)),
        content: Text(
          'This account has reached its device limit. '
          'Contact support to add this device.\n\n${AuthConfig.supportContact}',
          style: const TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK', style: TextStyle(color: AppColors.accent)),
          ),
        ],
      ),
    );
  }

  // ── Demo mode ───────────────────────────────────────────────────────────────
  Future<void> _loginDemo() async {
    setState(() {
      _loading = true;
      _statusMessage = 'Loading demo...';
    });

    final appState = context.read<AppState>();
    final navigator = Navigator.of(context);

    appState.login(_demoUser, _demoPass);
    appState.setServerUrl(_demoUrl);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AuthPrefsKeys.loggedIn, true);
    await prefs.setString(AuthPrefsKeys.username, _demoUser);
    await prefs.setString(AuthPrefsKeys.password, _demoPass);
    await prefs.setString(AuthPrefsKeys.serverUrl, _demoUrl);
    // No sc_token is stored for demo mode — DeviceLockService no-ops without one.
    await prefs.remove(AuthPrefsKeys.scToken);

    if (!mounted) return;

    await appState.loadFavorites(username: _demoUser);

    navigator.pushReplacement(
      MaterialPageRoute(builder: (_) => const MainShell()),
    );

    // Load placeholder content after navigating
    _loadDemoContent(appState);
  }

  void _loadDemoContent(AppState appState) {
    appState.setContentLoading(true);

    // ─ Placeholder live channels ──────────────────────────────────────────────
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
        description: 'This is a sample live channel showing the app structure. '
            'Connect with your real credentials to stream live TV.',
        imageUrl: '',
        genre: genres[i % genres.length],
        category: genres[i % genres.length],
        channelNumber: i + 1,
        nowPlaying: 'Sample Program ${i + 1}',
        nextUp: 'Upcoming Show ${i + 2}',
      );
    });

    // ─ Placeholder movies ──────────────────────────────────────────────────
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
        description: 'Sample movie placeholder showing the app browsing experience. '
            'Sign in with your real credentials to access your full movie library.',
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

  void _loadContentInBackground(AppState appState, String user, String pass) async {
    appState.setContentLoading(true);

    final liveFuture = IptvService.getLiveChannels(user, pass)
        .then((ch) {
          if (ch.isNotEmpty) appState.setChannels(ch);
          return ch;
        })
        .catchError((_) => <ContentItem>[]);

    final moviesFuture = IptvService.getMovies(user, pass)
        .then((mv) {
          if (mv.isNotEmpty) appState.setMovies(mv);
          return mv;
        })
        .catchError((_) => <ContentItem>[]);

    final seriesFuture = IptvService.getSeries(user, pass)
        .then((sr) {
          if (sr.isNotEmpty) appState.setSeries(sr);
          return sr;
        })
        .catchError((_) => <ContentItem>[]);

    await Future.wait([liveFuture, moviesFuture, seriesFuture]);

    debugPrint('[Login] Content loaded in parallel');
    appState.setContentLoading(false);
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    _urlFocusNode.dispose();
    _userFocusNode.dispose();
    _passFocusNode.dispose();
    _eyeFocusNode.dispose(); // FIX #2
    _loginFocusNode.dispose();
    _supportFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (!mounted) return;
    setState(() {});
    _scrollFocusedIntoView();
  }

  /// Keeps whatever currently has focus on screen.
  ///
  /// This used to animate to hardcoded offsets (40 / 130 / 220), which were
  /// already wrong once the helper texts were added and would break again on
  /// any layout change or a different screen height. Asking the framework
  /// where the focused widget actually is always lands correctly, and it also
  /// accounts for the on-screen keyboard covering the lower half.
  void _scrollFocusedIntoView() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = FocusManager.instance.primaryFocus?.context;
      if (ctx == null) return;
      try {
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.3, // sit in the upper third, clear of the keyboard
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
        );
      } catch (_) {
        // Not inside a Scrollable — nothing to do.
      }
    });
  }

  /// Moves to the next field and keeps typing: focus follows, the keyboard
  /// stays open, and the screen scrolls along. This is what OK on a TV remote
  /// should do — previously it closed the keyboard and the view did not move.
  void _advanceTo(FocusNode next) => _startEditing(next);

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final profile = appState.deviceProfile;

    // FIX #2 (item 4) — BACK closes the keyboard and leaves focus on the field
    // it was opened from, instead of falling through and leaving the screen.
    return PopScope(
      canPop: _editingField == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _editingField != null) _stopEditing();
      },
      child: Scaffold(
      backgroundColor: AppColors.bg,
      body: Stack(
        children: [
          Center(
            child: SingleChildScrollView(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: _buildForm(),
              ),
            ),
          ),
          if (profile != null)
            Positioned(
              bottom: 16,
              right: 16,
              child: _buildHardwareBadge(profile),
            ),
        ],
      ),
      ),
    );
  }

  Widget _buildHardwareBadge(DeviceProfile profile) {
    // Use the pre-computed displayName (properly capitalised: "Google Pixel 7",
    // "Samsung Galaxy S24", etc.) — never shows raw lowercase brand.
    final cleanDeviceName = profile.displayName.isNotEmpty
        ? profile.displayName
        : 'Android Device';

    // Hardware ID — ANDROID_ID from Settings.Secure (unique per device + user account).
    // Truncated to 16 chars for clean display, still unique enough to identify a device.
    final hwId = profile.deviceId != 'unknown' && profile.deviceId.length > 8
        ? profile.deviceId.substring(0, 16).toUpperCase()
        : (profile.deviceId.toUpperCase());

    final isTV = profile.deviceClass != DeviceClass.generic;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12, width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 6,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isTV ? Icons.tv : Icons.phone_android,
            color: AppColors.accent,
            size: 16,
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                cleanDeviceName,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'Inter',
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'ID: $hwId',
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 10,
                  fontFamily: 'Inter',
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // FIX #2 (item 5) — short plain-language hint under each field so a
  // non-technical user knows what to type.
  Widget _fieldHint(String text) => Padding(
        padding: const EdgeInsets.only(top: 6, left: 4),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 11,
            color: AppColors.textTertiary,
            fontFamily: 'Inter',
          ),
        ),
      );

  // FIX #2 (item 3) — focusable, D-pad reachable password visibility toggle
  // with its own visible focus ring. SELECT toggles obscureText.
  Widget _visibilityToggle() {
    return FocusTraversalOrder(
      order: const NumericFocusOrder(4),
      child: Focus(
        focusNode: _eyeFocusNode,
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
            return KeyEventResult.ignored;
          }
          if (_isSelectKey(event.logicalKey)) {
            setState(() => _obscure = !_obscure);
            return KeyEventResult.handled;
          }
          return _navKey(node, event);
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            _eyeFocusNode.requestFocus();
            setState(() => _obscure = !_obscure);
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            margin: const EdgeInsets.all(6),
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: _eyeFocusNode.hasFocus
                    ? AppColors.accent
                    : Colors.transparent,
                width: 2,
              ),
            ),
            child: Icon(
              _obscure
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              color: _eyeFocusNode.hasFocus
                  ? AppColors.accent
                  : AppColors.textTertiary,
              size: 18,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildForm() {
    // FIX #2 (item 1) — one ordered traversal group for the whole form, so
    // traversal follows the declared 1..6 order instead of the default
    // reading-order geometry. The group Focus catches arrows that bubble up
    // from the button-style controls (the text fields handle their own).
    return FocusTraversalGroup(
      policy: OrderedTraversalPolicy(),
      child: Focus(
        canRequestFocus: false,
        onKeyEvent: _navKey,
        child: _formBody(),
      ),
    );
  }

  Widget _formBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // ── Logo & title ────────────────────────────────────────────────
        Center(
          child: Column(
            children: [
              Image.asset(
                'assets/images/app_logo.png',
                width: 72,
                height: 72,
                filterQuality: FilterQuality.high,
              ),
              const SizedBox(height: 14),
              const Text(
                'Smart Care TV',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  color: AppColors.accent,
                  letterSpacing: -0.3,
                  fontFamily: 'Inter',
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Sign in to continue',
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.textTertiary,
                  fontFamily: 'Inter',
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 40),

        // ── Server URL ──────────────────────────────────────────────────
        const Text('SERVER URL',
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AppColors.accent,
                letterSpacing: 0.8,
                fontFamily: 'Inter')),
        const SizedBox(height: 8),
        FocusTraversalOrder(
          order: const NumericFocusOrder(1), // FIX #2
          child: TextField(
            controller: _urlCtrl,
            focusNode: _urlFocusNode,
            // FIX #2 (item 4) — read-only until the user explicitly starts
            // editing, so arriving here with the D-pad does not pop the IME.
            // onTap still fires when read-only, so touch users are unaffected.
            readOnly: !_isEditing(_urlFocusNode),
            onTap: () => _startEditing(_urlFocusNode),
            scrollPadding: const EdgeInsets.only(bottom: 300),
            // The IME was "correcting" typed URLs — "fulltv" became "full TV",
            // which silently produced an unusable server address. A URL must
            // be taken exactly as typed.
            keyboardType: TextInputType.url,
            autocorrect: false,
            enableSuggestions: false,
            textCapitalization: TextCapitalization.none,
            // The four settings above are only hints to the IME, and some
            // Android TV keyboards ignore them. This is the hard guarantee:
            // whitespace can never land in a server URL, whatever the
            // keyboard tries to insert.
            inputFormatters: [
              FilteringTextInputFormatter.deny(RegExp(r'\s')),
            ],
            textInputAction: TextInputAction.next,
            // OK on the remote / Next on the IME → username, still typing.
            onEditingComplete: () => _advanceTo(_userFocusNode),
            onSubmitted: (_) => _advanceTo(_userFocusNode),
            style: const TextStyle(color: AppColors.textPrimary, fontFamily: 'Inter'),
            decoration: const InputDecoration(
              hintText: 'e.g. http://domain.com:port',
              prefixIcon: Icon(Icons.link_rounded, color: AppColors.textTertiary, size: 18),
            ),
          ),
        ),
        _fieldHint('Enter the URL provided by your provider'), // FIX #2 (item 5)
        const SizedBox(height: 20),

        // ── Username ────────────────────────────────────────────────────
        const Text('USERNAME',
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AppColors.accent,
                letterSpacing: 0.8,
                fontFamily: 'Inter')),
        const SizedBox(height: 8),
        FocusTraversalOrder(
          order: const NumericFocusOrder(2), // FIX #2
          child: TextField(
            controller: _userCtrl,
            focusNode: _userFocusNode,
            readOnly: !_isEditing(_userFocusNode), // FIX #2 (item 4)
            onTap: () => _startEditing(_userFocusNode),
            scrollPadding: const EdgeInsets.only(bottom: 300),
            // Same reason as the URL field: a username must not be
            // autocorrected or auto-capitalised.
            autocorrect: false,
            enableSuggestions: false,
            textCapitalization: TextCapitalization.none,
            // A username cannot contain spaces either.
            inputFormatters: [
              FilteringTextInputFormatter.deny(RegExp(r'\s')),
            ],
            textInputAction: TextInputAction.next,
            onEditingComplete: () => _advanceTo(_passFocusNode),
            onSubmitted: (_) => _advanceTo(_passFocusNode),
            style: const TextStyle(color: AppColors.textPrimary, fontFamily: 'Inter'),
            decoration: const InputDecoration(
              hintText: 'Enter your username',
              prefixIcon: Icon(Icons.person_outline_rounded, color: AppColors.textTertiary, size: 18),
            ),
          ),
        ),
        _fieldHint('The username your provider gave you'), // FIX #2 (item 5)
        const SizedBox(height: 20),

        // ── Password ────────────────────────────────────────────────────
        const Text('PASSWORD',
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AppColors.accent,
                letterSpacing: 0.8,
                fontFamily: 'Inter')),
        const SizedBox(height: 8),
        FocusTraversalOrder(
          order: const NumericFocusOrder(3), // FIX #2
          child: TextField(
            controller: _passCtrl,
            focusNode: _passFocusNode,
            readOnly: !_isEditing(_passFocusNode), // FIX #2 (item 4)
            onTap: () => _startEditing(_passFocusNode),
            scrollPadding: const EdgeInsets.only(bottom: 300),
            obscureText: _obscure,
            // Matters while the password is visible via the eye toggle —
            // obscured text is exempt from autocorrect, un-obscured is not.
            autocorrect: false,
            enableSuggestions: false,
            textCapitalization: TextCapitalization.none,
            textInputAction: TextInputAction.done,
            // Last field: close the keyboard and land on Sign In, ready to
            // press OK once more.
            onEditingComplete: () {
              _stopEditing();
              _loginFocusNode.requestFocus();
              _scrollFocusedIntoView();
            },
            onSubmitted: (_) {
              _stopEditing();
              _loginFocusNode.requestFocus();
              _scrollFocusedIntoView();
            },
            style: const TextStyle(color: AppColors.textPrimary, fontFamily: 'Inter'),
            decoration: InputDecoration(
              hintText: 'Enter your password',
              prefixIcon: const Icon(Icons.lock_outline_rounded, color: AppColors.textTertiary, size: 18),
              // FIX #2 (item 3) — the visibility toggle is now a real
              // focusable widget. It used to be an IconButton with
              // skipTraversal: true, which put it permanently out of D-pad
              // reach, and it allocated a fresh FocusNode on every rebuild.
              suffixIcon: _visibilityToggle(),
            ),
          ),
        ),
        _fieldHint('Press OK to type • Up/Down to switch fields • Right for show/hide'),
        const SizedBox(height: 28),

        // ── Sign In button ──────────────────────────────────────────────
        FocusTraversalOrder(
          order: const NumericFocusOrder(5), // FIX #2
          child: TvFocusable(
          focusNode: _loginFocusNode,
          onActivate: _loading ? null : _login,
          scaleOnFocus: true,
          borderRadius: 8,
          child: SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton(
              onPressed: _loading ? null : _login,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
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
                          letterSpacing: 1.0,
                          fontFamily: 'Inter')),
            ),
          ),
        ),
        ),
        const SizedBox(height: 20),

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
                  alignment: PlaceholderAlignment.middle,
                  child: FocusTraversalOrder(
                    order: const NumericFocusOrder(6), // FIX #2
                    child: TvFocusable(
                    focusNode: _supportFocusNode,
                    scaleOnFocus: true,
                    borderRadius: 4,
                    onActivate: () => ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Contact support: ${AuthConfig.supportContact}')),
                    ),
                    child: InkWell(
                      onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Contact support: ${AuthConfig.supportContact}')),
                      ),
                      borderRadius: BorderRadius.circular(4),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        child: Text('Contact support',
                            style: TextStyle(
                                color: AppColors.accent,
                                fontSize: 12,
                                fontFamily: 'Inter')),
                      ),
                    ),
                  ),
                  ),
                ),
              ],
            ),
          ),
        ),
        // Dynamic spacer to allow scrolling when keypad is active on TV
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          height: (_urlFocusNode.hasFocus || _userFocusNode.hasFocus || _passFocusNode.hasFocus) ? 350.0 : 20.0,
        ),
      ],
    );
  }
}
