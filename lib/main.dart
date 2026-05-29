import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:media_kit/media_kit.dart';
import 'theme/app_theme.dart';
import 'services/app_state.dart';
import 'screens/splash_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // CRITICAL: Must be called before any Player() is created.
  // This loads the native libmpv/FFmpeg libraries that provide
  // AC3, EAC3, Dolby Digital, DTS audio codec support.
  MediaKit.ensureInitialized();

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

class SmartCareTVApp extends StatelessWidget {
  const SmartCareTVApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) {
        final state = AppState();
        // Load persisted player settings immediately so players
        // use the correct hw-accel / buffer values from first launch.
        state.loadPlayerSettings();
        return state;
      },
      child: MaterialApp(
        title: 'Smart Care TV',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.darkTheme,
        shortcuts: <ShortcutActivator, Intent>{
          ...WidgetsApp.defaultShortcuts,
          const SingleActivator(LogicalKeyboardKey.select): const ActivateIntent(),
        },
        home: const SplashScreen(),
      ),
    );
  }
}
