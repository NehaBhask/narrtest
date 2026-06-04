import 'dart:typed_data';
import 'package:dio/dio.dart';
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
  const SttResult({required this.transcript, required this.provider, required this.latencyMs});
}

/// STT: Groq Whisper (online) + Whisper-tiny ONNX (offline).
class SttManager {
  SttManager._();
  static final SttManager instance = SttManager._();

  final _log = Logger();
  final _dio = Dio();
  SttMode _mode = SttMode.auto;
  OrtSession? _offlineSession;
  SttMode get mode => _mode;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _mode = SttMode.values[prefs.getInt('stt_mode') ?? 0];
    _dio.options = BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 30),
    );
  }

  Future<void> loadOfflineModel() async {
    try {
      final options = OrtSessionOptions()
        ..setInterOpNumThreads(2)
        ..setIntraOpNumThreads(2);
      _offlineSession = await OrtSession.fromFile(
          File(ModelManager.instance.modelPath(AppConstants.whisperTinyFile)), options);
      _log.i('Offline STT loaded. Inputs: ${_offlineSession?.inputNames}, Outputs: ${_offlineSession?.outputNames}');
    } catch (e) {
      _log.e('Offline STT load failed: $e');
    }
  }

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
    final t = await _transcribeOffline(pcm16leBytes);
    final ms = DateTime.now().difference(start).inMilliseconds;
    DpdpConsentManager.instance.logEvent(DpdpAuditEvent(
      dataType: DpdpDataType.audioCapture,
      description: 'Audio transcribed on-device (Whisper-tiny)',
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
    _log.i('Starting online STT transcribe: ${pcm.length} bytes');
    final prefs = await SharedPreferences.getInstance();
    final key = prefs.getString(AppConstants.groqApiKeyPrefKey) ?? '';
    if (key.isEmpty) {
      _log.i('No Groq API key configured');
      throw Exception('No Groq API key');
    }
    final wav = _pcmToWav(pcm, 16000, 1, 16);
    final lang = LanguageService.instance.currentCode;
    final form = FormData.fromMap({
      'file': MultipartFile.fromBytes(wav, filename: 'audio.wav'),
      'model': AppConstants.groqWhisperModel,
      'language': lang,
      'response_format': 'text',
    });
    _log.i('Sending audio to Groq Whisper endpoint...');
    final resp = await _dio.post(
      '${AppConstants.groqApiBaseUrl}/audio/transcriptions',
      data: form,
      options: Options(headers: {'Authorization': 'Bearer $key'}),
    );
    _log.i('Groq Whisper response received');
    return (resp.data as String).trim();
  }

  Future<String> _transcribeOffline(Uint8List pcm) async {
    _log.i('Starting offline STT transcribe: ${pcm.length} bytes');
    if (_offlineSession == null) {
      _log.i('Offline session is null, loading model...');
      await loadOfflineModel();
    }
    if (_offlineSession == null) {
      _log.e('Offline session failed to load, returning placeholder');
      return '[offline STT unavailable]';
    }
    final bd = ByteData.sublistView(pcm);
    final samples = Float32List(pcm.length ~/ 2);
    for (int i = 0; i < samples.length; i++) {
      samples[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
    }
    _log.i('Prepared offline audio tensor of size ${samples.length}');
    final inputT = OrtValueTensor.createTensorWithDataList(samples, [1, samples.length]);
    final langT = OrtValueTensor.createTensorWithDataList(
        Int64List.fromList([_langId(LanguageService.instance.currentCode)]), [1]);
    _log.i('Running offline Whisper session (run)...');
    final outs = _offlineSession!.run(
        OrtRunOptions(), {'audio': inputT, 'language': langT}, ['output']);
    _log.i('Offline Whisper session finished');
    inputT.release(); langT.release();
    final outputList = outs!;
    final tokens = outputList[0]?.value as List<dynamic>?;
    outputList[0]?.release();
    _log.i('Offline Whisper returned ${tokens?.length} tokens. Type: ${tokens.runtimeType}');
    _log.i('Tokens content: $tokens');
    return tokens?.map((t) => t.toString()).join(' ') ?? '';
  }

  int _langId(String c) =>
      {'en': 0, 'hi': 1, 'ta': 2, 'te': 3, 'bn': 4, 'mr': 5, 'kn': 6}[c] ?? 1;

  Uint8List _pcmToWav(Uint8List pcm, int sr, int ch, int bps) {
    final buf = ByteData(44 + pcm.length);
    void s(int o, List<int> b) { for (int i=0;i<b.length;i++) buf.setUint8(o+i,b[i]); }
    s(0, [0x52,0x49,0x46,0x46]);
    buf.setUint32(4, 36 + pcm.length, Endian.little);
    s(8, [0x57,0x41,0x56,0x45,0x66,0x6D,0x74,0x20]);
    buf.setUint32(16,16,Endian.little); buf.setUint16(20,1,Endian.little);
    buf.setUint16(22,ch,Endian.little); buf.setUint32(24,sr,Endian.little);
    buf.setUint32(28,sr*ch*bps~/8,Endian.little); buf.setUint16(32,ch*bps~/8,Endian.little);
    buf.setUint16(34,bps,Endian.little);
    s(36,[0x64,0x61,0x74,0x61]); buf.setUint32(40,pcm.length,Endian.little);
    for(int i=0;i<pcm.length;i++) buf.setUint8(44+i,pcm[i]);
    return buf.buffer.asUint8List();
  }

  void setMode(SttMode mode) {
    _mode = mode;
    SharedPreferences.getInstance().then((p) => p.setInt('stt_mode', mode.index));
  }

  /// Translate [text] from English into [targetLangCode] using Groq LLaMA.
  /// Returns the original text if translation fails or language is English.
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
                  'You are a translator. Translate the given English text to '
                  '$langName. Return ONLY the translated text, no explanations.'
            },
            {'role': 'user', 'content': text},
          ],
          'max_tokens': 512,
          'temperature': 0.1,
        },
        options: Options(headers: {'Authorization': 'Bearer $key'}),
      );
      final translated =
          (resp.data['choices'][0]['message']['content'] as String).trim();
      _log.i('Translated to $langName: $translated');
      return translated;
    } catch (e) {
      _log.w('Translation to $langName failed, returning original: $e');
      return text;
    }
  }

  void dispose() { _offlineSession?.release(); }
}
