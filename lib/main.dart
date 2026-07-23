import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:media_kit/media_kit.dart';
import 'core/widgets/tv_safe_area.dart';
import 'theme/app_theme.dart';
import 'services/app_state.dart';
import 'services/device_profile_service.dart';
import 'services/device_lock_service.dart';
import 'services/player_factory.dart';
import 'services/search_state.dart';
import 'screens/splash_screen.dart';

/// App-wide navigator key — lets DeviceLockService replace the entire route
import 'services/cache_service.dart';

/// App-wide navigator key — lets DeviceLockService replace the entire route
/// stack with LockedScreen/ExpiredScreen/LoginScreen from outside the
/// widget tree (periodic timer, app-resume hook).
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Enforce RAM limits on Flutter's imageCache (50 images / 25MB max) to protect Smart TV RAM
  CacheService.configureRamImageCache();
  // Auto-prune disk image cache on startup if it exceeds 30 MB
  CacheService.autoPruneDiskCache();

  debugPrint('[Build] running build 2.7.0 (tv-ux-overhaul)');

  // CRITICAL: Must be called before any Player() is created.
  // This loads the native libmpv/FFmpeg libraries that provide
  // AC3, EAC3, Dolby Digital, DTS audio codec support.
  MediaKit.ensureInitialized();

  // Warm up an idle Player now, while the splash screen is showing and no
  // input event is pending — mpv_initialize() blocks the main isolate for
  // several seconds, and doing that the instant the user taps a channel is
  // what causes the "Waited 5002ms for FocusEvent" ANR. See PlayerFactory
  // for the full explanation.
  PlayerFactory.prewarm();

  // Detect device hardware capabilities in the background.
  // Do not await this so it doesn't cause startup ANR.
  DeviceProfileService.instance.detect();

  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Color(0xFF0C1018),
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  runApp(const SmartCareTVApp());
}

class SmartCareTVApp extends StatefulWidget {
  const SmartCareTVApp({super.key});

  @override
  State<SmartCareTVApp> createState() => _SmartCareTVAppState();
}

class _SmartCareTVAppState extends State<SmartCareTVApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Device-binding watchdog: re-validates this device with the backend
    // every few hours and immediately on resume. No-ops until the user is
    // actually logged in (checked internally on every call).
    DeviceLockService.instance.start(rootNavigatorKey);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    DeviceLockService.instance.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      DeviceLockService.instance.checkNow();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) {
            final state = AppState();
            // Load persisted player settings immediately so players
            // use the correct hw-accel / buffer values from first launch.
            state.loadPlayerSettings();
            // Detect and inject the device profile asynchronously
            DeviceProfileService.instance.detect().then((profile) {
              state.setDeviceProfile(profile);
            });
            return state;
          },
        ),
        // FIX #5 — registered above the navigator so the user's search
        // survives every route change and tab switch.
        ChangeNotifierProvider(create: (_) => SearchState()),
      ],
      child: MaterialApp(
        title: 'Smart Care TV',
        debugShowCheckedModeBanner: false,
        navigatorKey: rootNavigatorKey,
        theme: AppTheme.darkTheme,
        // FIX #12 (item 5) — one app-wide clamp so a device-level font scale
        // can't overflow layouts that already give up 10% to overscan.
        builder: clampTextScale,
        shortcuts: <ShortcutActivator, Intent>{
          ...WidgetsApp.defaultShortcuts,
          // Standard remote select keys → ActivateIntent (fires onPressed/onActivate)
          const SingleActivator(LogicalKeyboardKey.select):      const ActivateIntent(),
          const SingleActivator(LogicalKeyboardKey.enter):       const ActivateIntent(),
          const SingleActivator(LogicalKeyboardKey.numpadEnter): const ActivateIntent(),
          const SingleActivator(LogicalKeyboardKey.gameButtonA): const ActivateIntent(),
          // Space = confirm on some USB remotes and BT keyboards
          const SingleActivator(LogicalKeyboardKey.space):       const ActivateIntent(),
        },
        home: const SplashScreen(),
      ),
    );
  }
}
