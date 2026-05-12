import 'package:flutter_tts/flutter_tts.dart';
import 'package:logger/logger.dart';
import '../core/constants.dart';

class TtsService {
  TtsService._();
  static final TtsService instance = TtsService._();

  final FlutterTts _tts = FlutterTts();
  final _log = Logger();
  bool _isSpeaking = false;
  bool _stopCalled = false;   // guards against completion firing after manual stop()
  String _currentLanguageCode = 'en';
  String _lastAlertText = '';  // dedup guard — don’t re-queue the exact same alert

  // Separate queues so alerts never get mixed with response sentences
  final List<String> _alertQueue    = [];
  final List<String> _responseQueue = [];

  Future<void> init() async {
    await _tts.setSharedInstance(true);
    await _tts.awaitSpeakCompletion(true);  // makes speak() properly async
    await _tts.setSpeechRate(0.50);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);

    _tts.setStartHandler(() {
      _isSpeaking = true;
      _stopCalled = false;
    });

    _tts.setCompletionHandler(() {
      _isSpeaking = false;
      // Only advance the queue if we didn’t call stop() ourselves.
      // When stop() is called, _stopCalled is set true and the queue is
      // cleared — so there is nothing to process anyway.
      if (!_stopCalled) _processNext();
    });

    _tts.setErrorHandler((msg) {
      _log.e('TTS error: $msg');
      _isSpeaking = false;
      if (!_stopCalled) _processNext();
    });

    _tts.setCancelHandler(() {
      _isSpeaking = false;
    });
  }

  void setLanguage(String langCode) {
    _currentLanguageCode = langCode;
    final locale = AppConstants.supportedLanguages
        .firstWhere((l) => l['code'] == langCode,
            orElse: () => {'locale': 'en-IN'})['locale']!;
    _tts.setLanguage(locale);
  }

  /// P1 obstacle alert — immediately interrupts everything.
  Future<void> speakAlert(String? text) async {
    final msg = (text != null && text.trim().isNotEmpty)
        ? text
        : AppConstants.obstacleAlertMessages[_currentLanguageCode] ?? 'Obstacle ahead';

    // Dedup: if we are already playing this exact alert, don’t restart it.
    if (_isSpeaking && msg == _lastAlertText) return;

    // Discard any pending response sentences — alert takes priority
    _responseQueue.clear();
    _alertQueue.clear();
    _alertQueue.add(msg);
    _lastAlertText = msg;

    if (_isSpeaking) {
      _stopCalled = true;
      _isSpeaking = false;
      await _tts.stop();
    }
    _processNext();
  }

  /// Queue one response sentence (called per-sentence by StreamingTts).
  /// Does NOT clear existing queue — sentences accumulate and play in order.
  Future<void> speakSentence(String text) async {
    if (text.trim().isEmpty) return;
    _responseQueue.add(text);
    // Only kick off playback if nothing is playing right now
    if (!_isSpeaking) _processNext();
  }

  /// Speak a complete pre-built response (non-streaming fallback).
  Future<void> speakResponse(String text) async {
    if (text.trim().isEmpty) return;
    _responseQueue.clear();
    _responseQueue.add(text);
    if (_isSpeaking) {
      _stopCalled = true;
      _isSpeaking = false;
      await _tts.stop();
    }
    _processNext();
  }

  void _processNext() {
    if (_isSpeaking) return;
    // Alerts have strict priority
    if (_alertQueue.isNotEmpty) {
      final text = _alertQueue.removeAt(0);
      _isSpeaking = true;
      _stopCalled = false;
      _tts.speak(text);
      return;
    }
    // Alert queue is now empty — clear the dedup guard so the same obstacle
    // can be announced again after the SafetyCoordinator cooldown expires.
    _lastAlertText = '';
    if (_responseQueue.isNotEmpty) {
      final text = _responseQueue.removeAt(0);
      _isSpeaking = true;
      _stopCalled = false;
      _tts.speak(text);
    }
  }

  /// Stop all speech and clear every queue.
  Future<void> stop() async {
    _alertQueue.clear();
    _responseQueue.clear();
    _lastAlertText = '';
    _stopCalled = true;
    _isSpeaking = false;
    await _tts.stop();
  }

  bool get isSpeaking => _isSpeaking;
}
