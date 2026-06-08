import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'core/dpdp_consent.dart';
import 'screens/onboarding/splash_screen.dart';
import 'screens/onboarding/privacy_consent_screen.dart';
import 'screens/onboarding/model_download_screen.dart';
import 'screens/home_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/privacy_dashboard_screen.dart';

class NarratorApp extends StatelessWidget {
  const NarratorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Narrator',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(),
      initialRoute: '/',
      onGenerateRoute: _router,
    );
  }

  ThemeData _buildTheme() {
    const seed = Color(0xFF6C63FF); // Indigo-violet
    final base = ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: seed,
        brightness: Brightness.dark,
        primary: seed,
        secondary: const Color(0xFF00D4AA),
        surface: const Color(0xFF0F0F1A),
        background: const Color(0xFF0A0A14),
        error: const Color(0xFFFF6B6B),
      ),
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xFF0A0A14),
    );
    return base.copyWith(
      textTheme: GoogleFonts.outfitTextTheme(base.textTheme).apply(
        bodyColor: Colors.white,
        displayColor: Colors.white,
      ),
    );
  }

  Route<dynamic>? _router(RouteSettings settings) {
    switch (settings.name) {
      case '/':
        return MaterialPageRoute(builder: (_) => const SplashScreen());
      case '/consent':
        return MaterialPageRoute(builder: (_) => const PrivacyConsentScreen());
      case '/download':
        return MaterialPageRoute(builder: (_) => const ModelDownloadScreen());
      case '/home':
        return MaterialPageRoute(builder: (_) => const HomeScreen());
      case '/settings':
        return MaterialPageRoute(builder: (_) => const SettingsScreen());
      case '/privacy':
        return MaterialPageRoute(builder: (_) => const PrivacyDashboardScreen());
      default:
        return MaterialPageRoute(builder: (_) => const SplashScreen());
    }
  }
}
