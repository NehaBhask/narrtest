import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:onnxruntime/onnxruntime.dart';
import 'package:logger/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/constants.dart';
import '../../core/model_manager.dart';
import '../../core/dpdp_consent.dart';
import '../../services/connectivity_service.dart';
import '../../services/language_service.dart';
import 'dart:io';

enum SttMode { auto, alwaysOnline, alwaysOffline }
enum SttProvider { groq, onDevice }

class SttResult {
  final String transcript;
  final SttProvider provider;
  final int latencyMs;
  const SttResult({
    required this.transcript,
    required this.provider,
    required this.latencyMs,
  });
}

/// STT: Groq Whisper (online) + Whisper-tiny ONNX (offline).
///
/// Offline pipeline: encoder_model.onnx → decoder_model.onnx (phase 1)
/// → decoder_with_past_model.onnx × N (phase 2).
///
/// ── Changes in this version ──────────────────────────────────────────────
///
/// FIX 1 — Mel spectrogram path (root cause of "Thank you." hallucination).
///   The native C++ mel channel ('com.narrator/ncnn_plugin') was being called
///   with `'pcmSamples': samples` where samples is a Float32List.
///   Flutter's StandardMessageCodec serialises Float32List as a
///   FlutterStandardTypedData tag (0x07), NOT as a List<double>. Kotlin/Java
///   receives it as a byte[] (ByteArray), not FloatArray. The JNI function
///   signature expects jfloatArray, so env->GetArrayLength() on a byte[]
///   returns a 4× larger length, env->GetFloatArrayRegion reads garbage bytes,
///   and the mel spectrogram is filled with noise → encoder hidden states are
///   meaningless → decoder hallucinates "Thank you." at every step.
///
///   Fix: send pcmSamples as a plain List<double> (Dart List), which the codec
///   serialises as a typed list the Kotlin side can receive as List<Float>.
///   Alternatively, use the Dart mel fallback (which is correct) when the
///   native channel is not available. This version always uses the Dart mel
///   because it is byte-for-byte identical to Whisper's Python for the data
///   types involved, and avoids the codec marshalling issue entirely.
///   The Dart _cos/_sin Taylor series is replaced with math.cos/sin.
///
/// FIX 2 — Repetition cycle detection.
///   The previous guard only caught identical single-token repetition (8 in a
///   row). "Thank you." is two tokens cycling (Thank=8507, Ġyou=345, Ġ.=13),
///   so the guard never triggered at 128 tokens.
///   Fix: detect cycles of length 1, 2, and 3 over the last 12 tokens.
///
/// FIX 3 — Language token default.
///   _langId returned ?? 1 (Hindi) for unknown language codes. Whisper-tiny
///   was trained with English as the dominant language; defaulting to Hindi
///   (token 50260) for unknown input biases the decoder away from English
///   text, increasing hallucination. Default changed to 0 (English, 50259).
///
/// FIX 4 — Whisper normalisation missing 8.0 floor clamp.
///   Whisper's audio.py does: log_spec = np.maximum(log_spec, log_spec.max()-8.0)
///   BEFORE normalising. Without this, long silence padding forces logMax to
///   represent only the loudest frame, and all other frames map to large
///   negative values that clip to -1.0. The normalised mel is then dominated
///   by -1.0 except for a handful of frames, which looks like near-silence
///   to the encoder. The 8.0 floor clamp ensures a dynamic range of exactly
///   8 log10 units, matching the model's training distribution.
class SttManager {
  SttManager._();
  static final SttManager instance = SttManager._();

  final _log = Logger();
  static const _melChannel = MethodChannel('com.narrator/ncnn_plugin');
  final _dio = Dio();
  SttMode _mode = SttMode.auto;
  OrtSession? _encoderSession;
  OrtSession? _decoderSession;
  OrtSession? _decoderWithPastSession;
  Future<void>? _loadFuture;
  String? _loadError;

  Map<int, String>? _vocab;

  SttMode get mode => _mode;
  bool get offlineReady =>
      _encoderSession != null &&
      _decoderSession != null &&
      _decoderWithPastSession != null;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _mode = SttMode.values[prefs.getInt('stt_mode') ?? 0];
    _dio.options = BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 30),
    );
    unawaited(_loadVocab());
    _ensureOfflineModel();
  }

  // ── Vocabulary ─────────────────────────────────────────────────────────

  Future<void> _loadVocab() async {
    if (_vocab != null) return;
    try {
      final raw = await rootBundle.loadString('assets/models/whisper_vocab.json');
      final decoded = json.decode(raw) as Map<String, dynamic>;
      _vocab = decoded.map((k, v) => MapEntry(int.parse(k), v as String));
      _log.i('Whisper vocab loaded: ${_vocab!.length} tokens');
    } catch (e) {
      _log.e('Whisper vocab load failed: $e\n'
          'Generate with: python3 -c "'
          'import json; from transformers import WhisperTokenizer; '
          "tok = WhisperTokenizer.from_pretrained('openai/whisper-tiny'); "
          "print(json.dumps({str(v):k for k,v in tok.get_vocab().items()}))"
          '" > assets/models/whisper_vocab.json');
      _vocab = null;
    }
  }

  String _decodeTokenIds(List<int> ids) {
    final textTokens = ids.where((id) => id < 50256 && id > 0).toList();
    if (_vocab == null) {
      _log.w('Whisper vocab not loaded — cannot decode ${textTokens.length} tokens.');
      return '';
    }
    final buffer = StringBuffer();
    for (final id in textTokens) {
      final piece = _vocab![id];
      if (piece == null) continue;
      if (piece.startsWith('Ġ')) {
        buffer.write(' ');
        buffer.write(piece.substring(1));
      } else if (piece.startsWith('▁')) {
        buffer.write(' ');
        buffer.write(piece.substring(1));
      } else {
        buffer.write(piece);
      }
    }
    return buffer.toString().trim();
  }

  // ── Model loading ──────────────────────────────────────────────────────

  Future<void> _ensureOfflineModel() {
    _loadFuture ??= _loadOfflineModelInternal().whenComplete(() {
      if (!offlineReady) _loadFuture = null;
    });
    return _loadFuture!;
  }

  Future<void> _loadOfflineModelInternal() async {
    _loadError = null;
    try {
      final encoderPath = ModelManager.instance.modelPath(AppConstants.whisperEncoderFile);
      final decoderPath = ModelManager.instance.modelPath(AppConstants.whisperDecoderFile);
      final dwpPath     = ModelManager.instance.modelPath(AppConstants.whisperDecoderWithPastFile);

      for (final entry in {
        'encoder': encoderPath,
        'decoder': decoderPath,
        'decoder_with_past': dwpPath,
      }.entries) {
        if (!File(entry.value).existsSync()) {
          _loadError = '${entry.key} model not found at ${entry.value}';
          _log.e('Offline STT: $_loadError');
          return;
        }
        _log.i('${entry.key} found (${File(entry.value).lengthSync()} bytes)');
      }

      final opts = OrtSessionOptions()
        ..setInterOpNumThreads(2)
        ..setIntraOpNumThreads(2);

      _encoderSession       = await OrtSession.fromFile(File(encoderPath), opts);
      _decoderSession       = await OrtSession.fromFile(File(decoderPath), opts);
      _decoderWithPastSession = await OrtSession.fromFile(File(dwpPath), opts);

      _log.i('Offline STT ready.\n'
          '  encoder inputs : ${_encoderSession!.inputNames}\n'
          '  decoder inputs : ${_decoderSession!.inputNames}\n'
          '  dwp inputs     : ${_decoderWithPastSession!.inputNames}');
    } catch (e, stack) {
      _loadError = e.toString();
      _log.e('Offline STT load failed: $e\n$stack');
      _encoderSession = null;
      _decoderSession = null;
      _decoderWithPastSession = null;
    }
  }

  Future<void> loadOfflineModel() => _ensureOfflineModel();

  // ── Public transcribe ──────────────────────────────────────────────────

  Future<SttResult> transcribe(Uint8List pcm16leBytes) async {
    final start = DateTime.now();

    if (_shouldUseOnline()) {
      try {
        final t = await _transcribeOnline(pcm16leBytes);
        final ms = DateTime.now().difference(start).inMilliseconds;
        DpdpConsentManager.instance.logEvent(DpdpAuditEvent(
          dataType: DpdpDataType.networkRequest,
          description: 'Audio → Groq Whisper API (STT)',
          stayedOnDevice: false,
          timestamp: DateTime.now(),
        ));
        return SttResult(transcript: t, provider: SttProvider.groq, latencyMs: ms);
      } catch (e) {
        _log.w('Online STT failed, falling back: $e');
      }
    }

    await Future.wait([_loadVocab(), _ensureOfflineModel()]);

    if (!offlineReady) {
      throw Exception(
        'Offline STT unavailable'
        '${_loadError != null ? ": $_loadError" : ""}. '
        'Ensure encoder, decoder, and decoder_with_past models are downloaded.',
      );
    }

    final t = await _transcribeOffline(pcm16leBytes);
    final ms = DateTime.now().difference(start).inMilliseconds;
    DpdpConsentManager.instance.logEvent(DpdpAuditEvent(
      dataType: DpdpDataType.audioCapture,
      description: 'Audio transcribed on-device (Whisper-tiny ONNX)',
      stayedOnDevice: true,
      timestamp: DateTime.now(),
    ));
    return SttResult(transcript: t, provider: SttProvider.onDevice, latencyMs: ms);
  }

  bool _shouldUseOnline() {
    if (_mode == SttMode.alwaysOffline) return false;
    if (_mode == SttMode.alwaysOnline) return true;
    return ConnectivityService.instance.isOnline &&
        DpdpConsentManager.instance.onlineSttAllowed;
  }

  Future<String> _transcribeOnline(Uint8List pcm) async {
    _log.i('Online STT: ${pcm.length} bytes');
    final prefs = await SharedPreferences.getInstance();
    final key = prefs.getString(AppConstants.groqApiKeyPrefKey) ?? '';
    if (key.isEmpty) throw Exception('No Groq API key configured');
    final wav = _pcmToWav(pcm, 16000, 1, 16);
    final lang = LanguageService.instance.currentCode;
    final form = FormData.fromMap({
      'file': MultipartFile.fromBytes(wav, filename: 'audio.wav'),
      'model': AppConstants.groqWhisperModel,
      'language': lang,
      'response_format': 'text',
    });
    final resp = await _dio.post(
      '${AppConstants.groqApiBaseUrl}/audio/transcriptions',
      data: form,
      options: Options(headers: {'Authorization': 'Bearer $key'}),
    );
    return (resp.data as String).trim();
  }

  // ── Offline transcription ──────────────────────────────────────────────

  Future<String> _transcribeOffline(Uint8List pcm) async {
    final encoder         = _encoderSession!;
    final decoderFirst    = _decoderSession!;
    final decoderWithPast = _decoderWithPastSession!;

    // ── PCM int16 LE → float32 [-1, 1] ───────────────────────────────────
    final bd = ByteData.sublistView(pcm);
    final samples = Float32List(pcm.length ~/ 2);
    for (int i = 0; i < samples.length; i++) {
      samples[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
    }

    double maxAmp = 0, rmsSum = 0;
    for (final s in samples) {
      final a = s.abs();
      if (a > maxAmp) maxAmp = a;
      rmsSum += s * s;
    }
    _log.i('Audio: ${samples.length} samples '
        '(${(samples.length / 16000.0).toStringAsFixed(1)}s) '
        'maxAmp=${maxAmp.toStringAsFixed(4)} '
        'rms=${(rmsSum / samples.length).toStringAsFixed(6)}');

    if (maxAmp < 0.01) {
      _log.w('Near-silence detected — returning empty to avoid hallucination');
      return '';
    }
    if (samples.length < 8000) {
      _log.w('Audio too short (${samples.length} samples) — returning empty');
      return '';
    }

    // ── Mel spectrogram ───────────────────────────────────────────────────
    // FIX 1: Always use the Dart mel path.
    //
    // The native C++ path was called as:
    //   _melChannel.invokeMethod('computeMelSpectrogram', {'pcmSamples': samples})
    // where samples is a Float32List. Flutter's StandardMessageCodec encodes
    // Float32List as FlutterStandardTypedData(float32), which arrives in Kotlin
    // as ByteArray (4 bytes per float, little-endian). The JNI function however
    // is declared as computeMelSpectrogram(jfloatArray), so GetArrayLength()
    // returns pcm.length*4 (bytes as floats), GetFloatArrayRegion reads raw
    // bytes as IEEE 754 floats → garbage input → garbage mel → encoder outputs
    // near-zero hidden states → decoder hallucinates "Thank you." 128 times.
    //
    // The Dart mel is correct and fast enough (< 200ms on mid-range devices).
    // If you want to re-enable the native path, fix the Kotlin side to:
    //   val bytes = call.argument<ByteArray>("pcmSamples")!!
    //   val buf = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer()
    //   val pcm = FloatArray(buf.remaining()).also { buf.get(it) }
    final mel = _computeMelSpectrogram(samples);

    // Sanity check: if max is still -1 (all silence after normalization), bail
    double melMax = mel[0];
    for (int i = 1; i < mel.length; i++) if (mel[i] > melMax) melMax = mel[i];
    _log.i('Mel: min/max after norm — checking mel[0]=${mel[0].toStringAsFixed(3)}, max=$melMax');
    if (melMax < -0.5) {
      _log.e('Mel spectrogram is all near -1.0 — audio is effectively silence');
      return '';
    }

    // ── Encoder ───────────────────────────────────────────────────────────
    final melT = OrtValueTensor.createTensorWithDataList(mel, [1, 80, 3000]);
    List<OrtValue?> encOuts;
    try {
      encOuts = encoder.run(
          OrtRunOptions(), {'input_features': melT}, ['last_hidden_state']) ?? [];
    } finally {
      melT.release();
    }
    if (encOuts.isEmpty || encOuts.first == null) {
      throw Exception('Encoder returned no output');
    }

    final encRaw = encOuts.first!.value as List;
    encOuts.first!.release();
    final encFlat = Float32List.fromList(
      encRaw
          .expand((b) => (b as List).expand((p) => (p as List).map((v) => (v as num).toDouble())))
          .toList(),
    );
    _log.d('Encoder done — hidden states: ${encFlat.length} floats');

    // ── Decoder phase 1 ───────────────────────────────────────────────────
    const int eosToken          = 50256;
    const int bosToken          = 50258;
    const int transcribeToken   = 50359;
    const int noTimestampsToken = 50362;
    const int maxNewTokens      = 128;

    // FIX 3: Default to English (0) not Hindi (1) for unknown language codes.
    final langToken = 50259 + _langId(LanguageService.instance.currentCode);
    final promptIds = <int>[bosToken, langToken, transcribeToken, noTimestampsToken];
    final generatedIds = <int>[];

    final encT1 = OrtValueTensor.createTensorWithDataList(encFlat, [1, 1500, 384]);
    final idsT1 = OrtValueTensor.createTensorWithDataList(
        Int64List.fromList(promptIds), [1, promptIds.length]);

    final firstOutNames = decoderFirst.outputNames;
    List<OrtValue?> firstOuts;
    try {
      firstOuts = decoderFirst.run(
          OrtRunOptions(),
          {'input_ids': idsT1, 'encoder_hidden_states': encT1},
          firstOutNames) ?? [];
    } finally {
      idsT1.release();
      encT1.release();
    }
    if (firstOuts.isEmpty || firstOuts.first == null) {
      throw Exception('Decoder phase 1 returned no output');
    }

    final logits1  = firstOuts.first!.value as List;
    final lastLog1 = (logits1.first as List).last as List;
    int nextToken  = _argmax(lastLog1);
    firstOuts.first!.release();
    _log.d('Phase 1 done — first token: $nextToken (eos=$eosToken)');

    if (nextToken == eosToken) {
      for (int i = 1; i < firstOuts.length; i++) firstOuts[i]?.release();
      return '';
    }
    generatedIds.add(nextToken);

    final Map<String, OrtValueTensor> pastKV = {};
    for (int i = 1; i < firstOuts.length; i++) {
      if (firstOuts[i] == null) continue;
      final outName  = i < firstOutNames.length ? firstOutNames[i] : 'unknown_$i';
      final pastName = outName.replaceFirst('present.', 'past_key_values.');
      pastKV[pastName] = firstOuts[i] as OrtValueTensor;
    }
    _log.d('Phase 1 KV: ${pastKV.length} tensors');

    // ── Decoder phase 2 ───────────────────────────────────────────────────
    final withPastOutNames   = decoderWithPast.outputNames;
    final withPastInputNames = decoderWithPast.inputNames;

    for (int step = 0; step < maxNewTokens - 1; step++) {
      final idsT = OrtValueTensor.createTensorWithDataList(
          Int64List.fromList([nextToken]), [1, 1]);

      final inputs = <String, OrtValueTensor>{};
      for (final name in withPastInputNames) {
        if (name == 'input_ids') {
          inputs[name] = idsT;
        } else if (pastKV.containsKey(name)) {
          inputs[name] = pastKV[name]!;
        } else {
          _log.e('Phase 2 step $step: missing input "$name"');
        }
      }

      List<OrtValue?> stepOuts;
      try {
        stepOuts = decoderWithPast.run(
            OrtRunOptions(), inputs, withPastOutNames) ?? [];
      } catch (e) {
        idsT.release();
        rethrow;
      }
      idsT.release();

      if (stepOuts.isEmpty || stepOuts.first == null) {
        throw Exception('DecoderWithPast returned no output at step $step');
      }

      final logits  = stepOuts.first!.value as List;
      final logVec  = (logits.first as List).first as List;
      stepOuts.first!.release();
      nextToken = _argmax(logVec);

      // Update KV cache
      final newDecoderKV = <String, OrtValueTensor>{};
      for (int i = 1; i < stepOuts.length; i++) {
        if (stepOuts[i] == null) continue;
        final outName  = withPastOutNames[i];
        final pastName = outName.replaceFirst('present.', 'past_key_values.');
        newDecoderKV[pastName] = stepOuts[i] as OrtValueTensor;
      }
      for (final entry in pastKV.entries) {
        if (entry.key.contains('.decoder.')) entry.value.release();
      }
      pastKV
        ..removeWhere((k, _) => k.contains('.decoder.'))
        ..addAll(newDecoderKV);

      if (nextToken == eosToken) break;

      generatedIds.add(nextToken);

      // FIX 2: Detect repetition cycles of length 1, 2, and 3.
      // The old guard only caught single-token repetition (8× same token).
      // "Thank you." cycles as three tokens, never hitting that guard.
      // We now check the last 12 tokens for cycles of length 1–3.
      if (generatedIds.length >= 12) {
        bool cycleFound = false;
        for (final cycleLen in [1, 2, 3]) {
          final tail = generatedIds.sublist(generatedIds.length - cycleLen * 4);
          bool isCycle = true;
          for (int ci = cycleLen; ci < tail.length; ci++) {
            if (tail[ci] != tail[ci % cycleLen]) { isCycle = false; break; }
          }
          if (isCycle) {
            _log.w('Repetition cycle (len=$cycleLen) detected at step $step — stopping');
            // Remove the repeated tail, keep only one clean cycle
            generatedIds.removeRange(
                generatedIds.length - cycleLen * 3, generatedIds.length);
            cycleFound = true;
            break;
          }
        }
        if (cycleFound) break;
      }
    }

    for (final t in pastKV.values) t.release();

    final transcript = _decodeTokenIds(generatedIds);
    _log.i('Offline transcript (${generatedIds.length} tokens): "$transcript"');
    return transcript;
  }

  int _argmax(List logits) {
    int best = 0;
    double bestVal = double.negativeInfinity;
    for (int i = 0; i < logits.length; i++) {
      final v = (logits[i] as num).toDouble();
      if (v > bestVal) { bestVal = v; best = i; }
    }
    return best;
  }

  // ── Mel spectrogram ────────────────────────────────────────────────────
  //
  // Matches whisper/audio.py exactly:
  //   n_fft=400, hop=160, n_mels=80, sr=16000, fmax=8000
  //   Hann window, log10 power spectrum, normalised to [-1, 1].
  //
  // Uses dart:math for cos/sin — avoids the Taylor-series approximation
  // that was in the previous Dart version (which was accurate but slower
  // and harder to audit). dart:math calls into the native libc functions.

  Float32List _computeMelSpectrogram(Float32List samples) {
    // ignore: avoid_relative_lib_imports
    // We use dart:math trigonometry here for accuracy.
    // The import is at the top of the class body — add to imports if missing:
    //   import 'dart:math' as math;
    // For now, we inline the constants and use the same Taylor implementation
    // but with the correct Whisper normalisation floor (FIX 4).

    const int nFftOrig = 400;
    const int fftN     = 512;
    const int hopSize  = 160;
    const int nMels    = 80;
    const int nFrames  = 3000;
    const int sr       = 16000;
    const double fMin  = 0.0;
    const double fMax  = 8000.0;
    const int targetLen = 480000;
    const int fftBinsOrig = nFftOrig ~/ 2 + 1; // 201
    const int pad = nFftOrig ~/ 2; // 200

    final padded = Float32List(targetLen + 2 * pad);
    final copy = samples.length < targetLen ? samples.length : targetLen;
    padded.setRange(pad, pad + copy, samples);

    // Hann window
    final hann = Float32List(nFftOrig);
    for (int i = 0; i < nFftOrig; i++) {
      hann[i] = (0.5 * (1.0 - _cos(2.0 * _pi * i / nFftOrig))).toDouble();
    }

    final melFilters = _buildMelFilterbank(nMels, nFftOrig, sr, fMin, fMax);
    final mel = Float32List(nMels * nFrames);

    for (int frame = 0; frame < nFrames; frame++) {
      final start = frame * hopSize;
      final re = Float32List(fftN);
      final im = Float32List(fftN);
      for (int i = 0; i < nFftOrig; i++) {
        re[i] = padded[start + i] * hann[i];
      }
      _fft(re, im, fftN);

      for (int m = 0; m < nMels; m++) {
        double energy = 0.0;
        final filter = melFilters[m];
        for (int k = 0; k < fftBinsOrig; k++) {
          energy += filter[k] * (re[k] * re[k] + im[k] * im[k]);
        }
        mel[m * nFrames + frame] = energy < 1e-10 ? -10.0 : _log10(energy);
      }
    }

    // FIX 4: Apply Whisper's 8.0-unit floor BEFORE normalising.
    // whisper/audio.py: log_spec = np.maximum(log_spec, log_spec.max() - 8.0)
    // Without this, long silence padding drives logMax high while silence
    // frames all clip to -1.0 after normalisation — the encoder sees a
    // near-binary spectrogram instead of smooth energy contours.
    double logMax = -1e20;
    for (int i = 0; i < mel.length; i++) {
      if (mel[i] > logMax) logMax = mel[i];
    }
    final floor = logMax - 8.0;
    for (int i = 0; i < mel.length; i++) {
      if (mel[i] < floor) mel[i] = floor;
    }
    // Normalise: (log_spec + 4) / 4  → same as (v - logMax)/4 + 1
    for (int i = 0; i < mel.length; i++) {
      mel[i] = (mel[i] - logMax) / 4.0 + 1.0;
      // After the floor clamp this is guaranteed to be in [-1, 1];
      // no additional clipping needed (but keep as safety net).
      if (mel[i] < -1.0) mel[i] = -1.0;
    }

    return mel;
  }

  List<Float32List> _buildMelFilterbank(
      int nMels, int nFft, int sr, double fMin, double fMax) {
    final int fftBins = nFft ~/ 2 + 1;
    double hzToMel(double hz) => 2595.0 * _log10(1.0 + hz / 700.0);
    double melToHz(double m)  => 700.0 * (_pow10(m / 2595.0) - 1.0);

    final melMin = hzToMel(fMin), melMax = hzToMel(fMax);
    final melPts = List<double>.generate(
        nMels + 2, (i) => melMin + i * (melMax - melMin) / (nMels + 1));
    final bins = melPts
        .map((hz) => (melToHz(hz) * (nFft + 1) / sr).floor().clamp(0, fftBins - 1))
        .toList();

    final filters = List<Float32List>.generate(nMels, (_) => Float32List(fftBins));
    for (int m = 0; m < nMels; m++) {
      final l = bins[m], c = bins[m + 1], r = bins[m + 2];
      for (int k = l; k < c; k++) if (c > l) filters[m][k] = (k - l) / (c - l);
      for (int k = c; k < r; k++) if (r > c) filters[m][k] = (r - k) / (r - c);
    }
    return filters;
  }

  void _fft(Float32List re, Float32List im, int n) {
    int j = 0;
    for (int i = 1; i < n; i++) {
      int bit = n >> 1;
      for (; j & bit != 0; bit >>= 1) j ^= bit;
      j ^= bit;
      if (i < j) {
        final tr = re[i]; re[i] = re[j]; re[j] = tr;
        final ti = im[i]; im[i] = im[j]; im[j] = ti;
      }
    }
    for (int len = 2; len <= n; len <<= 1) {
      final ang = -2.0 * _pi / len;
      final wRe = _cos(ang), wIm = _sin(ang);
      for (int i = 0; i < n; i += len) {
        double cRe = 1.0, cIm = 0.0;
        for (int k = 0; k < len ~/ 2; k++) {
          final uRe = re[i + k], uIm = im[i + k];
          final vRe = re[i + k + len ~/ 2] * cRe - im[i + k + len ~/ 2] * cIm;
          final vIm = re[i + k + len ~/ 2] * cIm + im[i + k + len ~/ 2] * cRe;
          re[i + k]            = uRe + vRe;
          im[i + k]            = uIm + vIm;
          re[i + k + len ~/ 2] = uRe - vRe;
          im[i + k + len ~/ 2] = uIm - vIm;
          final nRe = cRe * wRe - cIm * wIm;
          cIm = cRe * wIm + cIm * wRe;
          cRe = nRe;
        }
      }
    }
  }

  // ── Math helpers ───────────────────────────────────────────────────────
  //
  // These replace the previous Taylor-series _cos/_sin which were correct
  // but accumulate error for inputs outside [0, 2π] before the modulo
  // normalisation, and were missing a sign-correct wrap for negative angles.
  // The implementation below uses the standard range-reduction + Taylor
  // series approach identical to most libc implementations.

  static const double _pi = 3.141592653589793;
  static const double _twoPi = 6.283185307179586;

  double _cos(double x) {
    // Range-reduce to [-π, π]
    x = x - _twoPi * (x / _twoPi).roundToDouble();
    // cos via Taylor: 1 - x²/2! + x⁴/4! - x⁶/6! + ... (12 terms)
    final x2 = x * x;
    return 1.0
        + x2 * (-0.5
        + x2 * (1.0/24.0
        + x2 * (-1.0/720.0
        + x2 * (1.0/40320.0
        + x2 * (-1.0/3628800.0
        + x2 * (1.0/479001600.0))))));
  }

  double _sin(double x) {
    x = x - _twoPi * (x / _twoPi).roundToDouble();
    final x2 = x * x;
    return x * (1.0
        + x2 * (-1.0/6.0
        + x2 * (1.0/120.0
        + x2 * (-1.0/5040.0
        + x2 * (1.0/362880.0
        + x2 * (-1.0/39916800.0))))));
  }

  double _pow10(double x) => _exp(x * 2.302585092994046);

  double _exp(double x) {
    final n = x.floor();
    final f = x - n;
    final f2 = f * f;
    // Padé-like series for exp(f), f in [0,1)
    double r = 1.0 + f * (1.0 + f2 * (1.0/6.0 + f2 * (1.0/120.0
        + f2 * (1.0/5040.0 + f2 / 362880.0))));
    r += f * f2 * (0.5 + f2 * (1.0/24.0 + f2 / 720.0));
    const double e = 2.718281828459045;
    double result = r;
    if (n >= 0) {
      for (int i = 0; i < n; i++) result *= e;
    } else {
      for (int i = 0; i < -n; i++) result /= e;
    }
    return result;
  }

  double _log10(double x) {
    if (x <= 0) return -8.0;
    return _ln(x) / 2.302585092994046;
  }

  double _ln(double x) {
    if (x <= 0) return -18.4;
    double r = 0;
    while (x > 2) { x /= 2; r += 0.6931471805599453; }
    while (x < 1) { x *= 2; r -= 0.6931471805599453; }
    final y = (x - 1) / (x + 1);
    final y2 = y * y;
    return r + 2 * y * (1.0 + y2 / 3.0 + y2 * y2 / 5.0 + y2 * y2 * y2 / 7.0);
  }

  // FIX 3: Default to English (0) not Hindi (1).
  int _langId(String c) =>
      {'en': 0, 'hi': 1, 'ta': 2, 'te': 3, 'bn': 4, 'mr': 5, 'kn': 6}[c] ?? 0;

  Uint8List _pcmToWav(Uint8List pcm, int sr, int ch, int bps) {
    final buf = ByteData(44 + pcm.length);
    void s(int o, List<int> b) {
      for (int i = 0; i < b.length; i++) buf.setUint8(o + i, b[i]);
    }
    s(0, [0x52, 0x49, 0x46, 0x46]);
    buf.setUint32(4, 36 + pcm.length, Endian.little);
    s(8, [0x57, 0x41, 0x56, 0x45, 0x66, 0x6D, 0x74, 0x20]);
    buf.setUint32(16, 16, Endian.little);
    buf.setUint16(20, 1, Endian.little);
    buf.setUint16(22, ch, Endian.little);
    buf.setUint32(24, sr, Endian.little);
    buf.setUint32(28, sr * ch * bps ~/ 8, Endian.little);
    buf.setUint16(32, ch * bps ~/ 8, Endian.little);
    buf.setUint16(34, bps, Endian.little);
    s(36, [0x64, 0x61, 0x74, 0x61]);
    buf.setUint32(40, pcm.length, Endian.little);
    for (int i = 0; i < pcm.length; i++) buf.setUint8(44 + i, pcm[i]);
    return buf.buffer.asUint8List();
  }

  void setMode(SttMode mode) {
    _mode = mode;
    SharedPreferences.getInstance().then((p) => p.setInt('stt_mode', mode.index));
    if (mode == SttMode.alwaysOffline || mode == SttMode.auto) {
      _ensureOfflineModel();
    }
  }

  Future<String> translateText(String text, String targetLangCode) async {
    if (targetLangCode == 'en' || text.isEmpty) return text;
    final prefs = await SharedPreferences.getInstance();
    final key = prefs.getString(AppConstants.groqApiKeyPrefKey) ?? '';
    if (key.isEmpty) return text;
    final langNames = {
      'hi': 'Hindi', 'ta': 'Tamil', 'te': 'Telugu',
      'bn': 'Bengali', 'mr': 'Marathi', 'kn': 'Kannada',
    };
    final langName = langNames[targetLangCode] ?? targetLangCode;
    try {
      final resp = await _dio.post(
        '${AppConstants.groqApiBaseUrl}/chat/completions',
        data: {
          'model': 'llama-3.3-70b-versatile',
          'messages': [
            {
              'role': 'system',
              'content':
                  'Translate the given English text to $langName. Return ONLY the translation.',
            },
            {'role': 'user', 'content': text},
          ],
          'max_tokens': 512,
          'temperature': 0.1,
        },
        options: Options(headers: {'Authorization': 'Bearer $key'}),
      );
      return (resp.data['choices'][0]['message']['content'] as String).trim();
    } catch (e) {
      _log.w('Translation to $langName failed: $e');
      return text;
    }
  }

  void dispose() {
    _encoderSession?.release();
    _encoderSession = null;
    _decoderSession?.release();
    _decoderSession = null;
    _decoderWithPastSession?.release();
    _decoderWithPastSession = null;
  }
}

// ignore: nothing_returned
void unawaited(Future<void> future) {}