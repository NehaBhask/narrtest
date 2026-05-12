import 'package:flutter_tts/flutter_tts.dart';
import 'package:logger/logger.dart';
import '../core/constants.dart';

class TtsService {
  TtsService._();
  static final TtsService instance = TtsService._();

  final FlutterTts _tts = FlutterTts();
  final _log = Logger();
  bool _isSpeaking = false;
  bool _stopped = false;
  String _currentLanguageCode = 'en';

  final List<_TtsRequest> _queue = [];

  Future<void> init() async {
    await _tts.setSharedInstance(true);
    await _tts.setSpeechRate(0.50);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);

    _tts.setStartHandler(() {
      _isSpeaking = true;
      _stopped = false;
    });

    _tts.setCompletionHandler(() {
      _isSpeaking = false;
      if (!_stopped) _processQueue();
    });

    _tts.setErrorHandler((msg) {
      _log.e('TTS error: $msg');
      _isSpeaking = false;
      if (!_stopped) _processQueue();
    });

    _tts.setCancelHandler(() {
      _isSpeaking = false;
    });
  }

  void setLanguage(String langCode) {
    _currentLanguageCode = langCode;
    final locale = AppConstants.supportedLanguages
        .firstWhere((l) => l['code'] == langCode,
            orElse: () => {'locale': 'en-US'})['locale']!;
    _tts.setLanguage(locale);
  }

  /// P1 alert — interrupts everything immediately.
  Future<void> speakAlert(String? text) async {
    final msg = text ??
        AppConstants.obstacleAlertMessages[_currentLanguageCode] ??
        'Obstacle ahead';
    _queue.removeWhere((r) => !r.isAlert);
    _queue.insert(0, _TtsRequest(text: msg, isAlert: true));
    if (_isSpeaking) await _tts.stop();
    _stopped = false;
    _processQueue();
  }

  /// Speak a single complete response — clears any pending queue first
  /// so we never repeat or stack old responses.
  Future<void> speakResponse(String text) async {
    if (text.trim().isEmpty) return;
    _stopped = false;
    _queue.clear(); // clear any stale items before adding new response
    _queue.add(_TtsRequest(text: text, isAlert: false));
    if (_isSpeaking) {
      await _tts.stop();
    }
    _processQueue();
  }

  void _processQueue() {
    if (_queue.isEmpty || _isSpeaking || _stopped) return;
    final next = _queue.removeAt(0);
    _isSpeaking = true;
    _tts.speak(next.text);
  }

  /// Stop speaking and clear all pending speech.
  Future<void> stop() async {
    _stopped = true;
    _queue.clear();
    _isSpeaking = false;
    await _tts.stop();
  }

  bool get isSpeaking => _isSpeaking;
}

class _TtsRequest {
  final String text;
  final bool isAlert;
  _TtsRequest({required this.text, required this.isAlert});
}
