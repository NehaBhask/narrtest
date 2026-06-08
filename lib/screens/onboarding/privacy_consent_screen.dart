import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:gap/gap.dart';
import '../../core/dpdp_consent.dart';

class PrivacyConsentScreen extends StatefulWidget {
  const PrivacyConsentScreen({super.key});
  @override
  State<PrivacyConsentScreen> createState() => _PrivacyConsentScreenState();
}

class _PrivacyConsentScreenState extends State<PrivacyConsentScreen> {
  bool _onlineStt = false;
  bool _analytics = false;
  bool _isAdult = false;
  bool _hasScrolledToBottom = false;
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(() {
      if (_scrollController.position.pixels >=
          _scrollController.position.maxScrollExtent - 40) {
        setState(() => _hasScrolledToBottom = true);
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _accept() async {
    await DpdpConsentManager.instance.recordConsent(
      onlineSttAllowed: _onlineStt,
      analyticsAllowed: _analytics,
    );
    if (!mounted) return;
    Navigator.pushReplacementNamed(context, '/download');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A14),
      body: SafeArea(
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.shield_outlined, color: cs.primary, size: 28),
                    const Gap(12),
                    Text('Privacy & Consent',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold, color: Colors.white)),
                  ]),
                  const Gap(6),
                  Text('गोपनीयता और सहमति  •  Privacy Notice',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.white38)),
                ],
              ),
            ).animate().fadeIn(duration: 400.ms),

            // Scrollable content
            Expanded(
              child: SingleChildScrollView(
                controller: _scrollController,
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _infoCard(
                      icon: Icons.camera_alt_outlined,
                      title: 'Camera',
                      titleHi: 'कैमरा',
                      body: 'Camera frames are processed on your device only to detect obstacles and answer your questions. Frames are never stored or sent to any server.',
                      bodyHi: 'कैमरा फ्रेम केवल आपके डिवाइस पर बाधाओं का पता लगाने और प्रश्नों का उत्तर देने के लिए उपयोग किए जाते हैं।',
                      color: const Color(0xFF6C63FF),
                    ),
                    const Gap(14),
                    _infoCard(
                      icon: Icons.mic_none_outlined,
                      title: 'Microphone',
                      titleHi: 'माइक्रोफोन',
                      body: 'Audio is captured only when you speak after the wake word. It is processed on-device by default. You may optionally allow cloud STT below.',
                      bodyHi: 'ऑडियो केवल तब कैप्चर की जाती है जब आप वेक वर्ड के बाद बोलते हैं।',
                      color: const Color(0xFF00D4AA),
                    ),
                    const Gap(14),
                    _infoCard(
                      icon: Icons.storage_outlined,
                      title: 'Local Storage',
                      titleHi: 'स्थानीय संग्रहण',
                      body: 'AI model files (~800MB) are downloaded and stored privately on your device. No personal data is persisted. You can delete all data in Settings.',
                      bodyHi: 'AI मॉडल फ़ाइलें (~800MB) आपके डिवाइस पर निजी रूप से संग्रहीत की जाती हैं।',
                      color: const Color(0xFFFF8C42),
                    ),
                    const Gap(24),

                    // Granular toggles
                    _sectionTitle('Optional Permissions'),
                    const Gap(10),
                    _toggleCard(
                      icon: Icons.cloud_outlined,
                      title: 'Online Speech Recognition',
                      titleHi: 'ऑनलाइन वाक् पहचान',
                      subtitle: 'Sends audio to Groq Whisper API for faster, more accurate transcription. Opt-in only. Audio is not stored by the provider.',
                      value: _onlineStt,
                      onChanged: (v) => setState(() => _onlineStt = v),
                      color: const Color(0xFF6C63FF),
                    ),
                    const Gap(10),
                    _toggleCard(
                      icon: Icons.analytics_outlined,
                      title: 'Crash Analytics',
                      titleHi: 'क्रैश विश्लेषण',
                      subtitle: 'Anonymous crash reports (no audio/video) to help improve the app. Never contains personal data.',
                      value: _analytics,
                      onChanged: (v) => setState(() => _analytics = v),
                      color: const Color(0xFF00D4AA),
                    ),
                    const Gap(24),

                    // Age confirmation
                    _sectionTitle('Age Confirmation'),
                    const Gap(10),
                    InkWell(
                      onTap: () => setState(() => _isAdult = !_isAdult),
                      borderRadius: BorderRadius.circular(14),
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1A1A2E),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: _isAdult ? const Color(0xFF6C63FF) : Colors.white12,
                          ),
                        ),
                        child: Row(children: [
                          Checkbox(
                            value: _isAdult,
                            onChanged: (v) => setState(() => _isAdult = v ?? false),
                            activeColor: const Color(0xFF6C63FF),
                          ),
                          const Gap(8),
                          Expanded(
                            child: Text('I confirm I am 18 years or older, or have parental consent.\n18 वर्ष या उससे अधिक की पुष्टि करता/करती हूँ।',
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.white70)),
                          ),
                        ]),
                      ),
                    ),
                    const Gap(24),

                    // Legal notice
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.04),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.white10),
                      ),
                      child: Text(
                        'This app complies with the Digital Personal Data Protection Act, 2023 (DPDP Act). '
                        'You have the right to withdraw consent and delete your data at any time via Settings → Privacy Dashboard.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Colors.white38, fontSize: 11, height: 1.6),
                      ),
                    ),
                    const Gap(32),
                  ],
                ),
              ),
            ),

            // CTA
            Container(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  if (!_hasScrolledToBottom)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Text('↓ Scroll to read all',
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(color: Colors.white38)),
                    ),
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton(
                      onPressed: (_isAdult && _hasScrolledToBottom) ? _accept : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF6C63FF),
                        disabledBackgroundColor: Colors.white12,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        elevation: 0,
                      ),
                      child: Text('I Understand & Accept  •  स्वीकार करें',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: Colors.white, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            ).animate().fadeIn(delay: 300.ms),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String text) => Text(text,
    style: Theme.of(context).textTheme.titleSmall?.copyWith(
      color: Colors.white54, letterSpacing: 0.8, fontWeight: FontWeight.w600));

  Widget _infoCard({required IconData icon, required String title,
      required String titleHi, required String body, required String bodyHi,
      required Color color}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withOpacity(0.25)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: color, size: 24),
        const Gap(14),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('$title  •  $titleHi',
            style: Theme.of(context).textTheme.titleSmall
                ?.copyWith(color: color, fontWeight: FontWeight.w600)),
          const Gap(6),
          Text(body, style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: Colors.white70, height: 1.5)),
          const Gap(4),
          Text(bodyHi, style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: Colors.white38, fontSize: 11, height: 1.5)),
        ])),
      ]),
    );
  }

  Widget _toggleCard({required IconData icon, required String title,
      required String titleHi, required String subtitle,
      required bool value, required ValueChanged<bool> onChanged,
      required Color color}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: value ? color.withOpacity(0.4) : Colors.white10),
      ),
      child: Row(children: [
        Icon(icon, color: value ? color : Colors.white38, size: 22),
        const Gap(14),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('$title  •  $titleHi',
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(fontWeight: FontWeight.w600, color: Colors.white)),
          const Gap(4),
          Text(subtitle, style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: Colors.white54, height: 1.4)),
        ])),
        Switch(value: value, onChanged: onChanged, activeColor: color),
      ]),
    );
  }
}
