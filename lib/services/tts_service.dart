import 'package:flutter_tts/flutter_tts.dart';
import 'package:logger/logger.dart';
import '../core/constants.dart';

/// TTS priority-queue service.
///
/// Three utterance categories with strict priority:
///   1. ALERT   — P1 obstacle warnings. Interrupts everything. Faster rate.
///   2. SYSTEM  — App-state announcements ("Narrator ready", "Listening").
///               Interrupts responses but not active alerts.
///   3. RESPONSE— VLM sentence stream. Lowest priority. Slower, clearer rate.
///
/// Speech rates:
///   Alert    → [AppConstants.alertSpeechRate]    (0.65) — faster, urgent
///   Response → [AppConstants.responseSpeechRate] (0.52) — slower, clear
class TtsService {
  TtsService._();
  static final TtsService instance = TtsService._();

  final FlutterTts _tts = FlutterTts();
  final _log = Logger();
  bool _isSpeaking = false;
  bool _stopCalled = false;
  String _currentLanguageCode = 'en';
  String _lastAlertText = '';

  // ── Queues (priority: alert > system > response)
  final List<_TtsItem> _alertQueue    = [];
  final List<_TtsItem> _systemQueue   = [];
  final List<_TtsItem> _responseQueue = [];

  Future<void> init() async {
    await _tts.setSharedInstance(true);
    await _tts.awaitSpeakCompletion(true);
    await _tts.setSpeechRate(AppConstants.responseSpeechRate);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);

    _tts.setStartHandler(() {
      _isSpeaking = true;
      _stopCalled = false;
    });

    _tts.setCompletionHandler(() {
      _isSpeaking = false;
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

  // ── P1 Obstacle Alert ──────────────────────────────────────────────────────

  /// P1 obstacle alert — immediately interrupts everything.
  /// Uses a faster speech rate for urgency.
  Future<void> speakAlert(String? text) async {
    final msg = (text != null && text.trim().isNotEmpty)
        ? text
        : AppConstants.obstacleAlertMessages[_currentLanguageCode] ??
            'Obstacle ahead';

    // Dedup: if already playing this exact alert, don't restart
    if (_isSpeaking && msg == _lastAlertText) return;

    _responseQueue.clear();
    _systemQueue.clear();
    _alertQueue.clear();
    _alertQueue.add(_TtsItem(text: msg, rate: AppConstants.alertSpeechRate));
    _lastAlertText = msg;

    if (_isSpeaking) {
      _stopCalled = true;
      _isSpeaking = false;
      await _tts.stop();
    }
    _processNext();
  }

  // ── System Announcements ───────────────────────────────────────────────────

  /// Speak a system message immediately (e.g. "Narrator ready", "Listening").
  /// Interrupts P2 responses but not P1 alerts.
  Future<void> speakImmediate(String text) async {
    if (text.trim().isEmpty) return;
    _responseQueue.clear();
    _systemQueue.clear();
    _systemQueue.add(_TtsItem(text: text, rate: AppConstants.alertSpeechRate));

    if (_isSpeaking && _alertQueue.isEmpty) {
      // Don't interrupt an active alert, but do interrupt responses
      _stopCalled = true;
      _isSpeaking = false;
      await _tts.stop();
    }
    if (!_isSpeaking) _processNext();
  }

  // ── P2 Response Streaming ──────────────────────────────────────────────────

  /// Queue one response sentence (called per-sentence by StreamingTts).
  /// Does NOT clear existing queue — sentences accumulate and play in order.
  Future<void> speakSentence(String text) async {
    if (text.trim().isEmpty) return;
    _responseQueue.add(_TtsItem(text: text, rate: AppConstants.responseSpeechRate));
    if (!_isSpeaking) _processNext();
  }

  /// Speak a complete pre-built response (non-streaming fallback).
  Future<void> speakResponse(String text) async {
    if (text.trim().isEmpty) return;
    _responseQueue.clear();
    _responseQueue.add(_TtsItem(text: text, rate: AppConstants.responseSpeechRate));
    if (_isSpeaking) {
      _stopCalled = true;
      _isSpeaking = false;
      await _tts.stop();
    }
    _processNext();
  }

  // ── Queue Processing ───────────────────────────────────────────────────────

  void _processNext() {
    if (_isSpeaking) return;

    _TtsItem? next;

    if (_alertQueue.isNotEmpty) {
      next = _alertQueue.removeAt(0);
    } else {
      // Clear dedup guard once all alerts are consumed
      _lastAlertText = '';
      if (_systemQueue.isNotEmpty) {
        next = _systemQueue.removeAt(0);
      } else if (_responseQueue.isNotEmpty) {
        next = _responseQueue.removeAt(0);
      }
    }

    if (next == null) return;

    _isSpeaking = true;
    _stopCalled = false;
    _tts.setSpeechRate(next.rate).then((_) => _tts.speak(next!.text));
  }

  /// Stop all speech and clear every queue.
  Future<void> stop() async {
    _alertQueue.clear();
    _systemQueue.clear();
    _responseQueue.clear();
    _lastAlertText = '';
    _stopCalled = true;
    _isSpeaking = false;
    await _tts.stop();
  }

  bool get isSpeaking => _isSpeaking;
}

/// Internal model for a queued TTS utterance with its own speech rate.
class _TtsItem {
  final String text;
  final double rate;
  const _TtsItem({required this.text, required this.rate});
}
