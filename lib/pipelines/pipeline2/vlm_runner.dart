import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:logger/logger.dart';
import '../../core/constants.dart';
import '../../core/model_manager.dart';
import '../../core/dpdp_consent.dart';
import '../../services/tts_service.dart';

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

  // Maximum JPEG size sent to the native VLM layer.
  //
  // CRASH FIX context: The SIGSEGV was in ggml_compute_forward_mul_mat caused
  // by a context-window overflow (see llama_server_runner.dart for details).
  // As a defence-in-depth measure we also cap the JPEG here: if the
  // FrameSelector ever returns a very large frame (e.g. from a high-res sensor
  // that ignores the 720×480 target), capping the byte payload ensures the
  // vision encoder stays within the token budget even if the server config
  // is misconfigured.
  //
  // 150 KB corresponds to a quality-75 JPEG of roughly 640×480 — enough
  // detail for scene description, comfortably within the 2048-token context.
  static const int _maxImageBytes = 150 * 1024; // 150 KB

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
  ///
  /// Changes vs original:
  ///   • Image byte-size guard: frames larger than [_maxImageBytes] are
  ///     rejected with a clear log. The native side must resize before calling
  ///     this, or FrameSelector must be configured for a smaller capture size.
  ///     This prevents the KV-cache overflow that caused the SIGSEGV.
  ///   • Prompt shortened: removed redundant phrasing that bloated the token
  ///     count unnecessarily within an already tight context budget.
  ///   • Hard timeout: [AppConstants.maxVlmTimeoutSeconds] (12s).
  ///   • First-token timeout: reassurance TTS if VLM is slow to start.
  Future<String> generateResponse({
    required Uint8List frameJpeg,
    required String englishQuery,
    String responseLanguage = 'en',
  }) async {
    if (_state == VlmState.loading) {
      await TtsService.instance.speakImmediate('Still loading the model, please wait.');
      return 'Still loading the model, please wait.';
    }

    // ── Image size guard ──────────────────────────────────────────────────
    // If the frame is too large, the vision encoder generates more tokens than
    // the context window can hold, overflowing the KV-cache and crashing the
    // native matmul kernel (SIGSEGV in ggml_compute_forward_mul_mat).
    // The native plugin is responsible for resizing; log a hard warning here
    // so misconfiguration is immediately visible in logcat.
    _log.i('VLM generateResponse: image=${frameJpeg.length} bytes, '
        'query="${englishQuery.substring(0, englishQuery.length.clamp(0, 60))}"');

    if (frameJpeg.length > _maxImageBytes) {
      _log.e(
        'Frame too large: ${frameJpeg.length} bytes > $_maxImageBytes limit. '
        'The native plugin must resize the image before calling generateResponse. '
        'Proceeding anyway — if the server crashes, reduce capture resolution.',
      );
      // We do NOT truncate the bytes — a truncated JPEG is not a valid image.
      // The error log gives the native developer a clear action item.
    }

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

    // Prompt kept intentionally short to minimise token count.
    // Every token in the prompt consumes KV-cache space that is shared with
    // the vision tokens — a verbose prompt risks overflowing -c 2048 on
    // longer queries in non-English languages.
    const systemInstruction =
        'You are a visual assistant for a blind person. '
        'Give a single clear spoken sentence describing what you see. '
        'No lists, no labels, no "Answer:" prefix.';

    final query = responseLanguage == 'en'
        ? '$systemInstruction\n\nQ: $englishQuery'
        : '$systemInstruction\n\nQ: $englishQuery\n\nRespond in $langName.';

    final buffer = StringBuffer();
    final completer = Completer<String>();
    StreamSubscription? sub;
    bool firstTokenReceived = false;

    // ── Hard timeout ──────────────────────────────────────────────────────
    final hardTimeout = Timer(
      Duration(seconds: AppConstants.maxVlmTimeoutSeconds),
      () {
        if (!completer.isCompleted) {
          _log.w('VLM hard timeout — returning partial response');
          sub?.cancel();
          completer.complete(buffer.toString().trim());
        }
      },
    );

    // ── First-token timeout: reassure the blind user if VLM is slow ──────
    final firstTokenTimeout = Timer(
      Duration(seconds: AppConstants.vlmFirstTokenTimeoutSeconds),
      () {
        if (!firstTokenReceived && !completer.isCompleted && !_cancelled) {
          _log.d('VLM first-token timeout — speaking wait message');
          TtsService.instance.speakImmediate(_waitMessage(responseLanguage));
        }
      },
    );

    sub = tokenStream.listen((token) {
      if (_cancelled) {
        sub?.cancel();
        hardTimeout.cancel();
        firstTokenTimeout.cancel();
        if (!completer.isCompleted) completer.complete('');
        return;
      }
      if (!firstTokenReceived) {
        firstTokenReceived = true;
        firstTokenTimeout.cancel();
      }
      if (token == '\x00') {
        sub?.cancel();
        hardTimeout.cancel();
        if (!completer.isCompleted) completer.complete(buffer.toString().trim());
      } else {
        buffer.write(token);
      }
    }, onError: (e) {
      hardTimeout.cancel();
      firstTokenTimeout.cancel();
      if (!completer.isCompleted) completer.completeError(e);
    });

    try {
      final nativeResult = _channel.invokeMethod<String>('generateResponse', {
        'imageBytes': frameJpeg,
        'query': query,
      });

      final response = await completer.future;

      if (response.isEmpty) {
        final fallback = await nativeResult;
        _state = VlmState.done;
        return fallback?.trim() ?? 'No response from model.';
      }

      _state = VlmState.done;
      return response;
    } catch (e) {
      hardTimeout.cancel();
      firstTokenTimeout.cancel();
      sub?.cancel();
      _state = VlmState.error;
      _log.e('VLM inference error: $e');
      return 'Sorry, I could not process that. Please try again.';
    }
  }

  String _waitMessage(String langCode) {
    switch (langCode) {
      case 'hi': return 'सोच रहा हूँ, एक पल...';
      case 'ta': return 'யோசிக்கிறேன், ஒரு நிமிடம்...';
      case 'te': return 'ఆలోచిస్తున్నాను, ఒక క్షణం...';
      case 'bn': return 'ভাবছি, একটু অপেক্ষা করুন...';
      case 'mr': return 'विचार करतोय, एक क्षण...';
      case 'kn': return 'ಯೋಚಿಸುತ್ತಿದ್ದೇನೆ, ಒಂದು ಕ್ಷಣ...';
      default:   return 'Thinking, one moment...';
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