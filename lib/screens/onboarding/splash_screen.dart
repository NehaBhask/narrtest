import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../../core/dpdp_consent.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _navigate();
  }

  Future<void> _navigate() async {
    await Future.delayed(const Duration(milliseconds: 2200));
    if (!mounted) return;
    if (!DpdpConsentManager.instance.hasConsented()) {
      Navigator.pushReplacementNamed(context, '/consent');
    } else {
      // Core models (YOLO, Silero VAD) are bundled in the APK — always available.
      // Large optional models (Whisper, SmolVLM) are downloaded on-demand from
      // the home screen; they don't block startup.
      Navigator.pushReplacementNamed(context, '/home');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A14),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 100, height: 100,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const RadialGradient(colors: [Color(0xFF6C63FF), Color(0xFF2D2B6B)]),
                boxShadow: [BoxShadow(color: const Color(0xFF6C63FF).withOpacity(0.5), blurRadius: 40, spreadRadius: 8)],
              ),
              child: const Icon(Icons.visibility, color: Colors.white, size: 48),
            )
                .animate()
                .scale(duration: 700.ms, curve: Curves.elasticOut)
                .fadeIn(duration: 500.ms),
            const SizedBox(height: 28),
            Text('Narrator',
              style: Theme.of(context).textTheme.displaySmall?.copyWith(
                fontWeight: FontWeight.bold,
                letterSpacing: 1.5,
                color: Colors.white,
              ),
            ).animate().fadeIn(delay: 400.ms, duration: 600.ms).slideY(begin: 0.3, end: 0),
            const SizedBox(height: 10),
            Text('Your AI Vision Assistant',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: Colors.white54, letterSpacing: 0.5,
              ),
            ).animate().fadeIn(delay: 700.ms, duration: 600.ms),
            const SizedBox(height: 60),
            SizedBox(
              width: 36, height: 36,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: const Color(0xFF6C63FF).withOpacity(0.7),
              ),
            ).animate().fadeIn(delay: 1200.ms),
          ],
        ),
      ),
    );
  }
}
