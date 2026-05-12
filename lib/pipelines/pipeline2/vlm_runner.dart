import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:logger/logger.dart';
import '../../core/constants.dart';
import '../../core/model_manager.dart';
import '../../core/dpdp_consent.dart';

enum VlmTier { smolvlm256m, qwen3vl2b }
enum VlmState { idle, loading, generating, done, error }

class VlmRunner {
  VlmRunner._();
  static final VlmRunner instance = VlmRunner._();

  final _log = Logger();
  VlmTier _tier = VlmTier.smolvlm256m;
  VlmState _state = VlmState.idle;
  VlmState get state => _state;
  VlmTier get currentTier => _tier;

  static const _channel = MethodChannel('com.narrator/vlm_plugin');

  // Token stream — emits words during generation, '\x00' signals end
  final _tokenController = StreamController<String>.broadcast();
  Stream<String> get tokenStream => _tokenController.stream;

  bool _cancelled = false;

  Future<void> init() async {
    _tier = VlmTier.smolvlm256m;
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onToken':
        final token = call.arguments as String? ?? '';
        if (token.isNotEmpty) _tokenController.add(token);
        break;
      case 'onGenerationDone':
        _tokenController.add('\x00'); // end sentinel
        break;
    }
  }

  Future<bool> loadModel() async {
    _state = VlmState.loading;
    final modelPath  = ModelManager.instance.modelPath(AppConstants.smolvlmModelFile);
    final mmprojPath = ModelManager.instance.modelPath(AppConstants.smolvlmMmprojFile);
    _log.i('VLM loadModel: $modelPath');

    try {
      final ok = await _channel.invokeMethod<bool>('loadVlmModel', {
        'modelPath': modelPath, 'mmprojPath': mmprojPath,
      }) ?? false;
      _state = ok ? VlmState.idle : VlmState.error;
      _log.i('VLM loaded: $ok');
      return ok;
    } catch (e) {
      _state = VlmState.error;
      _log.e('VLM load error: $e');
      return false;
    }
  }

  /// Generate a response for the given frame and query.
  /// Collects tokens from the native stream and returns the full text.
  /// The caller (ConversationCoordinator) handles TTS streaming separately.
  Future<String> generateResponse({
    required Uint8List frameJpeg,
    required String englishQuery,
    String responseLanguage = 'en',
  }) async {
    if (_state == VlmState.loading) return 'Still loading the model, please wait.';

    _state = VlmState.generating;
    _cancelled = false;

    DpdpConsentManager.instance.logEvent(DpdpAuditEvent(
      dataType: DpdpDataType.cameraFrame,
      description: 'Frame processed on-device by VLM',
      stayedOnDevice: true,
      timestamp: DateTime.now(),
    ));

    final langNames = {
      'hi': 'Hindi', 'ta': 'Tamil', 'te': 'Telugu',
      'bn': 'Bengali', 'mr': 'Marathi', 'kn': 'Kannada', 'en': 'English',
    };
    final langName = langNames[responseLanguage] ?? 'English';

    // ── FIX: Instruct the model to respond in natural descriptive language ──
    // SmolVLM was fine-tuned on VQA datasets that use a "Caption. Answer: Label"
    // format for short questions — e.g. "Laptop. Answer: Computer."
    // Prepending a narration instruction overrides this and produces a full
    // natural sentence suitable for a visually impaired user.
    // ────────────────────────────────────────────────────────────────────────
    const narratorInstruction =
        'You are a visual assistant helping a visually impaired person. '
        'Describe what you see in a single clear natural sentence. '
        'Do NOT use "Answer:" format. Do NOT list labels. '
        'Respond as if speaking directly to the person.';

    final query = responseLanguage == 'en'
        ? '$narratorInstruction\n\nQuestion: $englishQuery'
        : '$narratorInstruction\n\nQuestion: $englishQuery\n\n(Respond in $langName.)';

    // Collect all tokens until sentinel '\x00', with a hard timeout
    final buffer = StringBuffer();
    final completer = Completer<String>();
    StreamSubscription? sub;

    // Timeout guard — if native never sends '\x00', we don't hang forever
    final timeout = Timer(const Duration(seconds: 20), () {
      if (!completer.isCompleted) {
        _log.w('VLM generation timeout — returning partial response');
        sub?.cancel();
        completer.complete(buffer.toString().trim());
      }
    });

    sub = tokenStream.listen((token) {
      if (_cancelled) {
        sub?.cancel();
        timeout.cancel();
        if (!completer.isCompleted) completer.complete('');
        return;
      }
      if (token == '\x00') {
        // End sentinel — generation complete
        sub?.cancel();
        timeout.cancel();
        if (!completer.isCompleted) completer.complete(buffer.toString().trim());
      } else {
        buffer.write(token);
      }
    }, onError: (e) {
      timeout.cancel();
      if (!completer.isCompleted) completer.completeError(e);
    });

    try {
      // Fire the native call — tokens stream back via _handleNativeCall
      // This call itself returns the full response too (used as fallback)
      final nativeResult = _channel.invokeMethod<String>('generateResponse', {
        'imageBytes': frameJpeg,
        'query': query,
      });

      final response = await completer.future;

      // If stream gave us nothing, fall back to the method channel return value
      if (response.isEmpty) {
        final fallback = await nativeResult;
        _state = VlmState.done;
        return fallback?.trim() ?? 'No response from model.';
      }

      _state = VlmState.done;
      return response;
    } catch (e) {
      timeout.cancel();
      sub?.cancel();
      _state = VlmState.error;
      _log.e('VLM inference error: $e');
      return 'Sorry, I could not process that. Please try again.';
    }
  }

  void forceSetTier(VlmTier tier) => _tier = tier;

  Future<void> cancel() async {
    _cancelled = true;
    try { await _channel.invokeMethod('cancelVlmModel'); } catch (_) {}
    _state = VlmState.idle;
  }

  Future<void> release() async {
    try { await _channel.invokeMethod('releaseVlmModel'); } catch (_) {}
    _state = VlmState.idle;
  }

  void dispose() {
    _tokenController.close();
    release();
  }
}
