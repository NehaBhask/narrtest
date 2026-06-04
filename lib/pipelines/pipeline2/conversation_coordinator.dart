import 'dart:async';
import 'dart:typed_data';
import 'package:logger/logger.dart';
import 'package:record/record.dart';
import 'wake_word_engine.dart';
import 'silero_vad.dart';
import 'frame_selector.dart';
import 'stt_manager.dart';
import 'translation_engine.dart';
import 'vlm_runner.dart';
import 'streaming_tts.dart';
import '../../services/language_service.dart';
import '../../services/haptic_service.dart';
import '../../services/tts_service.dart';

enum Pipeline2State {
  idle, awaitingWakeWord, recording, transcribing, thinking, speaking, error
}

class ConversationCoordinator {
  ConversationCoordinator._();
  static final ConversationCoordinator instance = ConversationCoordinator._();

  final _log = Logger();
  Pipeline2State _state = Pipeline2State.idle;
  Pipeline2State get state => _state;
  int _interactionId = 0;

  final _stateController      = StreamController<Pipeline2State>.broadcast();
  final _responseController   = StreamController<String>.broadcast();
  final _transcriptController = StreamController<String>.broadcast();

  Stream<Pipeline2State> get stateStream     => _stateController.stream;
  Stream<String>         get responseStream  => _responseController.stream;
  Stream<String>         get transcriptStream => _transcriptController.stream;

  final _audioRecorder = AudioRecorder();
  StreamSubscription? _wakeWordSub;
  StreamSubscription? _vadSub;
  FrameSelector? _frameSelector;

  void attachFrameSelector(FrameSelector fs) => _frameSelector = fs;

  Future<void> start() async {
    await WakeWordEngine.instance.init();
    await WakeWordEngine.instance.start();
    _setState(Pipeline2State.awaitingWakeWord);

    _wakeWordSub = WakeWordEngine.instance.onWakeWordDetected.listen((_) async {
      if (_state != Pipeline2State.awaitingWakeWord) return;
      await _onWakeWordDetected();
    });

    _vadSub = SileroVad.instance.onSpeechEnd.listen((audio) async {
      if (_state == Pipeline2State.recording) await _onSpeechEnd(audio);
    });

    _log.i('Pipeline 2 started — awaiting wake word');
  }

  Future<void> _onWakeWordDetected() async {
    _setState(Pipeline2State.recording);
    SileroVad.instance.reset();

    // ── Simultaneous haptic + TTS listening cue ─────────────────────────
    // The blind user MUST know the mic is now open.
    // Fire both in parallel so there is no delay.
    unawaited(HapticService.instance.listeningPulse());
    unawaited(TtsService.instance.speakImmediate(
      _listeningMessage(LanguageService.instance.currentCode),
    ));

    try {
      final micStream = await _audioRecorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
        ),
      );
      micStream.listen(
        (chunk) => SileroVad.instance.feed(chunk),
        onError: (Object err) {
          _log.e('Mic stream error: $err');
          _setState(Pipeline2State.awaitingWakeWord);
        },
        cancelOnError: true,
      );
    } catch (e, stack) {
      _log.e('Could not start microphone: $e\n$stack');
      const msg = 'Microphone unavailable. Please check permissions.';
      _responseController.add(msg);
      unawaited(TtsService.instance.speakImmediate(msg));
      _setState(Pipeline2State.awaitingWakeWord);
    }
  }


  Future<void> _onSpeechEnd(Uint8List audioBytes) async {
    final currentInteraction = ++_interactionId;
    await _audioRecorder.stop();
    _setState(Pipeline2State.transcribing);
    _responseController.add(''); // clear previous response

    try {
      // 1. Capture frame (non-blocking — FrameSelector has a cached frame)
      final frameJpeg = await _frameSelector?.selectSharpestFrame();

      // 2. STT
      final sttResult  = await SttManager.instance.transcribe(audioBytes);
      final transcript = sttResult.transcript;
      if (_interactionId != currentInteraction) return;
      _log.i('Transcript: $transcript');
      _transcriptController.add(transcript);

      if (transcript.trim().isEmpty) {
        final emptyMsg = _emptyTranscriptMessage(LanguageService.instance.currentCode);
        _responseController.add(emptyMsg);
        unawaited(TtsService.instance.speakImmediate(emptyMsg));
        _setState(Pipeline2State.awaitingWakeWord);
        return;
      }

      // 3. Translate to English for VLM
      _setState(Pipeline2State.thinking);
      final englishQuery = await TranslationEngine.instance
          .translateToEnglish(transcript, LanguageService.instance.currentCode);
      if (_interactionId != currentInteraction) return;

      // 4. Frame check
      if (frameJpeg == null) {
        const msg = 'I could not capture a frame. Please try again.';
        _responseController.add(msg);
        unawaited(TtsService.instance.speakImmediate(msg));
        _setState(Pipeline2State.awaitingWakeWord);
        return;
      }

      // 5. VLM inference — stream tokens directly to TTS while generating
      _setState(Pipeline2State.speaking);
      final userLang = LanguageService.instance.currentCode;

      // Start TTS streaming immediately from the token stream
      StreamingTts.instance.startStreaming(VlmRunner.instance.tokenStream);

      final response = await VlmRunner.instance.generateResponse(
        frameJpeg: frameJpeg,
        englishQuery: englishQuery,
        responseLanguage: userLang,
      );
      if (_interactionId != currentInteraction) return;

      if (response.isEmpty) {
        final msg = _noResponseMessage(userLang);
        _responseController.add(msg);
        unawaited(TtsService.instance.speakImmediate(msg));
        _setState(Pipeline2State.awaitingWakeWord);
        return;
      }

      // 6. Show full response in UI (TTS already streaming)
      _responseController.add(response);

      _log.i('Done: "${response.substring(0, response.length.clamp(0, 60))}"');

    } catch (e, stack) {
      if (_interactionId != currentInteraction) return;
      _log.e('Pipeline error: $e\n$stack');
      const errMsg = 'An error occurred. Please say Suno to try again.';
      _responseController.add(errMsg);
      unawaited(TtsService.instance.speakImmediate(errMsg));
    } finally {
      if (_interactionId == currentInteraction) {
        _setState(Pipeline2State.awaitingWakeWord);
      }
    }
  }

  // ── Localised messages ────────────────────────────────────────────────

  String _listeningMessage(String lang) {
    switch (lang) {
      case 'hi': return 'सुन रहा हूँ';
      case 'ta': return 'கேட்கிறேன்';
      case 'te': return 'వింటున్నాను';
      case 'bn': return 'শুনছি';
      case 'mr': return 'ऐकतो आहे';
      case 'kn': return 'ಕೇಳುತ್ತಿದ್ದೇನೆ';
      default:   return 'Listening';
    }
  }

  String _emptyTranscriptMessage(String lang) {
    switch (lang) {
      case 'hi': return 'कुछ सुनाई नहीं दिया। Suno कहकर फिर पूछें।';
      case 'ta': return 'ஒன்றும் கேட்கவில்லை. மீண்டும் Suno சொல்லுங்கள்.';
      case 'te': return 'ఏమీ వినపడలేదు. మళ్ళీ Suno చెప్పండి.';
      case 'bn': return 'কিছু শোনা যায়নি। আবার Suno বলুন।';
      case 'mr': return 'काही ऐकू आले नाही. Suno म्हणून पुन्हा विचारा.';
      case 'kn': return 'ಏನೂ ಕೇಳಿಸಲಿಲ್ಲ. ಮತ್ತೆ Suno ಹೇಳಿ.';
      default:   return "I didn't catch that. Say Suno to try again.";
    }
  }

  String _noResponseMessage(String lang) {
    switch (lang) {
      case 'hi': return 'कोई उत्तर नहीं मिला। कृपया फिर से प्रयास करें।';
      case 'ta': return 'பதில் இல்லை. மீண்டும் முயற்சிக்கவும்.';
      case 'te': return 'సమాధానం రాలేదు. మళ్ళీ ప్రయత్నించండి.';
      case 'bn': return 'কোনো উত্তর নেই। আবার চেষ্টা করুন।';
      case 'mr': return 'उत्तर नाही. कृपया पुन्हा प्रयत्न करा.';
      case 'kn': return 'ಯಾವ ಉತ್ತರವೂ ಇಲ್ಲ. ದಯವಿಟ್ಟು ಮತ್ತೆ ಪ್ರಯತ್ನಿಸಿ.';
      default:   return 'No response. Please try again.';
    }
  }

  // ── Manual controls ───────────────────────────────────────────────────

  /// Cancel current AI response and stop TTS immediately.
  Future<void> cancelResponse() async {
    _interactionId++; // invalidates in-flight interaction
    await VlmRunner.instance.cancel();
    await StreamingTts.instance.stop();
    unawaited(HapticService.instance.cancelPulse());
    _setState(Pipeline2State.awaitingWakeWord);
    _log.i('Response cancelled by user');
  }

  Future<void> triggerManually() async {
    try {
      if (_state == Pipeline2State.idle) {
        // P2 hasn't started yet (e.g. start() is still in progress or failed).
        // Start now and immediately begin listening.
        await start();
        await _onWakeWordDetected();
      } else if (_state == Pipeline2State.awaitingWakeWord) {
        await _onWakeWordDetected();
      } else if (_state == Pipeline2State.speaking ||
                 _state == Pipeline2State.thinking ||
                 _state == Pipeline2State.transcribing) {
        await cancelResponse();
        await _onWakeWordDetected();
      }
      // recording state: user must tap stop (handled via stopManually)
    } catch (e, stack) {
      _log.e('triggerManually error: $e\n$stack');
      const msg = 'Could not start recording. Please try again.';
      _responseController.add(msg);
      unawaited(TtsService.instance.speakImmediate(msg));
      _setState(Pipeline2State.awaitingWakeWord);
    }
  }

  Future<void> stopManually() async {
    if (_state != Pipeline2State.recording) return;
    await _audioRecorder.stop();
    final buffered = Uint8List.fromList(SileroVad.instance.audioBufferSnapshot());
    SileroVad.instance.reset();
    await _onSpeechEnd(buffered);
  }

  void _setState(Pipeline2State s) {
    _state = s;
    _stateController.add(s);
  }

  Future<void> stop() async {
    _wakeWordSub?.cancel();
    _vadSub?.cancel();
    await _audioRecorder.stop();
    await StreamingTts.instance.stop();
    await WakeWordEngine.instance.stop();
    _setState(Pipeline2State.idle);
  }

  void dispose() {
    _stateController.close();
    _responseController.close();
    _transcriptController.close();
  }
}

// ignore: nothing_returned
void unawaited(Future<void> future) {
  // Intentionally fire-and-forget for parallel execution.
}
