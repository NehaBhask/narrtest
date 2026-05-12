import 'dart:async';
import 'package:logger/logger.dart';
import '../../services/tts_service.dart';
import '../../services/haptic_service.dart';

/// Streaming TTS — speaks first sentence as soon as VLM starts generating.
/// Subsequent sentences are queued and spoken as they complete.
class StreamingTts {
  StreamingTts._();
  static final StreamingTts instance = StreamingTts._();

  final _log = Logger();
  final StringBuffer _tokenBuffer = StringBuffer();
  int _sentenceCount = 0;
  static final _sentenceEnd = RegExp(r'[.!?।\n]');
  StreamSubscription<String>? _tokenSub;

  void startStreaming(Stream<String> tokenStream, {void Function(String)? onSentence}) {
    _tokenBuffer.clear();
    _sentenceCount = 0;
    _tokenSub?.cancel();
    _tokenSub = tokenStream.listen(
      (token) {
        if (token == '\x00') {
          final remaining = _tokenBuffer.toString().trim();
          if (remaining.isNotEmpty) {
            _speakSentence(remaining);
            onSentence?.call(remaining);
            _tokenBuffer.clear();
          }
          _onComplete();
          return;
        }
        _tokenBuffer.write(token);
        _tryExtractSentence(onSentence);
      },
      onError: (e) => _log.e('Token stream error: $e'),
    );
  }

  void _tryExtractSentence(void Function(String)? onSentence) {
    final text = _tokenBuffer.toString();
    final match = _sentenceEnd.firstMatch(text);
    if (match == null) return;
    final sentence  = text.substring(0, match.end).trim();
    final remainder = text.substring(match.end);
    _tokenBuffer.clear();
    _tokenBuffer.write(remainder);
    if (sentence.isNotEmpty) {
      _speakSentence(sentence);
      onSentence?.call(sentence);
    }
  }

  void _speakSentence(String sentence) {
    _sentenceCount++;
    _log.d('TTS[$_sentenceCount]: "${sentence.substring(0, sentence.length.clamp(0, 50))}"');
    TtsService.instance.speakResponse(sentence);
  }

  Future<void> _onComplete() async {
    _log.i('Streaming TTS complete ($_sentenceCount sentences)');
    await HapticService.instance.responseComplete();
    _tokenSub?.cancel();
    _tokenSub = null;
  }

  Future<void> stop() async {
    _tokenSub?.cancel();
    _tokenSub = null;
    _tokenBuffer.clear();
    await TtsService.instance.stop();
  }

  /// Speak a complete pre-built response in one shot (no streaming needed).
  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    _log.i('TTS speak: "${text.substring(0, text.length.clamp(0, 60))}"');
    await TtsService.instance.speakResponse(text);
    await HapticService.instance.responseComplete();
  }
}
