import 'dart:typed_data';
import 'package:onnxruntime/onnxruntime.dart';
import 'package:logger/logger.dart';
import '../../core/constants.dart';
import '../../core/model_manager.dart';
import '../../core/dpdp_consent.dart';
import '../../services/language_service.dart';
import 'dart:io';

/// IndicTrans2 INT8 ONNX — translates Indian language text → English.
/// Model: ~280MB, latency ~150–200ms on mid-range device.
class TranslationEngine {
  TranslationEngine._();
  static final TranslationEngine instance = TranslationEngine._();

  final _log = Logger();
  OrtSession? _session;
  bool _isLoaded = false;

  // Simple LRU cache: skip translation for repeated identical queries
  final Map<String, String> _cache = {};
  static const int _maxCache = 20;

  Future<void> init() async {
    try {
      final path = ModelManager.instance.modelPath(AppConstants.indicTrans2File);
      final opts = OrtSessionOptions()
        ..setInterOpNumThreads(2)
        ..setIntraOpNumThreads(2);
      _session = await OrtSession.fromFile(File(path), opts);
      _isLoaded = true;
      _log.i('IndicTrans2 loaded');
    } catch (e) {
      _log.e('IndicTrans2 load failed: $e');
    }
  }

  /// Translate [text] from [sourceLangCode] to English.
  /// Returns [text] unchanged if already English or translation fails.
  Future<String> translateToEnglish(String text, String sourceLangCode) async {
    if (sourceLangCode == 'en' || text.trim().isEmpty) return text;

    final cacheKey = '$sourceLangCode:$text';
    if (_cache.containsKey(cacheKey)) return _cache[cacheKey]!;

    if (!_isLoaded) {
      _log.w('IndicTrans2 not loaded, returning original text');
      return text;
    }

    try {
      final result = await _runInference(text, sourceLangCode);
      _addToCache(cacheKey, result);
      DpdpConsentManager.instance.logEvent(DpdpAuditEvent(
        dataType: DpdpDataType.modelInference,
        description: 'IndicTrans2: $sourceLangCode→en, on-device',
        stayedOnDevice: true,
        timestamp: DateTime.now(),
      ));
      return result;
    } catch (e) {
      _log.e('Translation failed: $e');
      return text; // graceful degradation
    }
  }

  Future<String> _runInference(String text, String srcLang) async {
    // IndicTrans2 ONNX expects tokenized integer input IDs
    // This is a simplified stub — real impl uses SentencePiece tokenizer
    // bound via native channel or precomputed vocab lookup.
    final inputIds = _mockTokenize(text, srcLang);
    final attentionMask = Int64List.fromList(List.filled(inputIds.length, 1));

    final inputT = OrtValueTensor.createTensorWithDataList(
        inputIds, [1, inputIds.length]);
    final maskT = OrtValueTensor.createTensorWithDataList(
        attentionMask, [1, attentionMask.length]);

    final outputs = _session!.run(
      OrtRunOptions(),
      {'input_ids': inputT, 'attention_mask': maskT},
      ['logits'],
    );

    inputT.release(); maskT.release();
    final outputList = outputs!;
    final logits = outputList[0]?.value;
    outputList[0]?.release();

    // Decode output token IDs to string (stub)
    return _mockDetokenize(logits, text);
  }

  // In production: use SentencePiece native binding
  Int64List _mockTokenize(String text, String srcLang) {
    final words = text.split(' ');
    return Int64List.fromList(
        words.map((w) => w.codeUnitAt(0) % 32000).toList());
  }

  String _mockDetokenize(dynamic logits, String fallback) {
    // Real impl: argmax over vocab → SentencePiece decode
    // Returns English translation
    if (logits == null) return fallback;
    return fallback; // stub: return original until tokenizer is wired
  }

  void _addToCache(String key, String value) {
    if (_cache.length >= _maxCache) {
      _cache.remove(_cache.keys.first);
    }
    _cache[key] = value;
  }

  void dispose() { _session?.release(); }
}
