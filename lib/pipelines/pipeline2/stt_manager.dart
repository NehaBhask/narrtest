import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

enum SttMode { online, offline, auto }

enum SttProvider { groq, whisperLocal }

class SttResult {
  final String text;
  final SttProvider provider;
  final Duration latency;
  final bool isError;

  const SttResult({
    required this.text,
    required this.provider,
    required this.latency,
    this.isError = false,
  });

  static SttResult error(SttProvider provider) => SttResult(
        text:     '',
        provider: provider,
        latency:  Duration.zero,
        isError:  true,
      );
}

/// Manages Speech-to-Text with online (Groq) / offline (Whisper-tiny) fallback.
class SttManager {
  final String? groqApiKey;
  final http.Client _httpClient;
  final SttMode mode;

  static const _groqEndpoint =
      'https://api.groq.com/openai/v1/audio/transcriptions';
  static const _groqModel    = 'whisper-large-v3-turbo';
  static const _ncnnChannel  = MethodChannel('com.narrator/ncnn_plugin');

  SttManager({
    this.groqApiKey,
    this.mode = SttMode.auto,
    http.Client? httpClient,
  }) : _httpClient = httpClient ?? http.Client();

  bool get hasGroqKey =>
      groqApiKey != null && groqApiKey!.trim().isNotEmpty;

  bool get canUseOnline =>
      hasGroqKey && (mode == SttMode.online || mode == SttMode.auto);

  /// Transcribe [audioBytes] (16-bit PCM WAV, 16kHz mono).
  Future<SttResult> transcribe(
    Uint8List audioBytes, {
    String language = 'en',
  }) async {
    if (canUseOnline) {
      return _transcribeGroq(audioBytes, language: language);
    }
    return _transcribeOffline(audioBytes, language: language);
  }

  Future<SttResult> _transcribeGroq(
    Uint8List audioBytes, {
    required String language,
  }) async {
    final start = DateTime.now();
    try {
      final request = http.MultipartRequest('POST', Uri.parse(_groqEndpoint))
        ..headers['Authorization'] = 'Bearer $groqApiKey'
        ..fields['model']          = _groqModel
        ..fields['language']       = language
        ..fields['response_format'] = 'json'
        ..files.add(http.MultipartFile.fromBytes(
          'file',
          audioBytes,
          filename: 'audio.wav',
        ));

      final response = await _httpClient.send(request);
      final body     = await response.stream.bytesToString();

      if (response.statusCode != 200) {
        return _transcribeOffline(audioBytes, language: language);
      }

      final json = jsonDecode(body) as Map<String, dynamic>;
      final text = (json['text'] as String?)?.trim() ?? '';

      return SttResult(
        text:     text,
        provider: SttProvider.groq,
        latency:  DateTime.now().difference(start),
      );
    } catch (_) {
      return _transcribeOffline(audioBytes, language: language);
    }
  }

  /// Offline Whisper-tiny via ONNX Runtime on-device.
  ///
  /// Flow:
  ///   1. Convert raw PCM bytes → Float32 samples
  ///   2. Compute mel spectrogram (80×3000) via native C++ JNI
  ///   3. Pass mel to ONNX Whisper-tiny encoder+decoder via MethodChannel
  ///   4. Return decoded text
  Future<SttResult> _transcribeOffline(
    Uint8List audioBytes, {
    required String language,
  }) async {
    final start = DateTime.now();
    try {
      // Step 1 — PCM bytes (16-bit LE) → Float32 normalised [-1, 1]
      final pcmFloat = _pcmBytesToFloat32(audioBytes);

      // Step 2 — Mel spectrogram computed in native C++ (whisper_mel.so)
      final List<dynamic> melRaw = await _ncnnChannel.invokeMethod(
        'computeMelSpectrogram',
        {'pcmSamples': pcmFloat},
      );
      final mel = Float32List.fromList(melRaw.cast<double>().map((v) => v.toDouble()).toList());

      if (mel.isEmpty) {
        return SttResult.error(SttProvider.whisperLocal);
      }

      // Step 3 — Run Whisper-tiny ONNX encoder + decoder via MethodChannel
      final String? text = await _ncnnChannel.invokeMethod<String>(
        'transcribeWhisper',
        {
          'melSpectrogram': mel,
          'language':       language,
        },
      );

      return SttResult(
        text:     text?.trim() ?? '',
        provider: SttProvider.whisperLocal,
        latency:  DateTime.now().difference(start),
      );
    } on PlatformException catch (_) {
      return SttResult.error(SttProvider.whisperLocal);
    } catch (_) {
      return SttResult.error(SttProvider.whisperLocal);
    }
  }

  /// Convert 16-bit little-endian PCM bytes → Float32 list normalised to [-1.0, 1.0].
  static Float32List _pcmBytesToFloat32(Uint8List pcmBytes) {
    final sampleCount = pcmBytes.length ~/ 2;
    final floats      = Float32List(sampleCount);
    final bd          = pcmBytes.buffer.asByteData();
    for (var i = 0; i < sampleCount; i++) {
      final sample = bd.getInt16(i * 2, Endian.little);
      floats[i] = sample / 32768.0;
    }
    return floats;
  }

  /// Build a minimal WAV header for raw PCM bytes.
  static Uint8List buildWavHeader({
    required int pcmByteCount,
    int sampleRate   = 16000,
    int channels     = 1,
    int bitsPerSample = 16,
  }) {
    final byteRate   = sampleRate * channels * bitsPerSample ~/ 8;
    final blockAlign = channels * bitsPerSample ~/ 8;
    final dataSize   = pcmByteCount;
    final chunkSize  = 36 + dataSize;

    final header = ByteData(44);
    // RIFF
    header.setUint8(0,  0x52); header.setUint8(1,  0x49);
    header.setUint8(2,  0x46); header.setUint8(3,  0x46);
    header.setUint32(4, chunkSize,  Endian.little);
    // WAVE
    header.setUint8(8,  0x57); header.setUint8(9,  0x41);
    header.setUint8(10, 0x56); header.setUint8(11, 0x45);
    // fmt
    header.setUint8(12, 0x66); header.setUint8(13, 0x6D);
    header.setUint8(14, 0x74); header.setUint8(15, 0x20);
    header.setUint32(16, 16,          Endian.little); // subchunk1 size
    header.setUint16(20, 1,           Endian.little); // PCM
    header.setUint16(22, channels,    Endian.little);
    header.setUint32(24, sampleRate,  Endian.little);
    header.setUint32(28, byteRate,    Endian.little);
    header.setUint16(32, blockAlign,  Endian.little);
    header.setUint16(34, bitsPerSample, Endian.little);
    // data
    header.setUint8(36, 0x64); header.setUint8(37, 0x61);
    header.setUint8(38, 0x74); header.setUint8(39, 0x61);
    header.setUint32(40, dataSize, Endian.little);

    return header.buffer.asUint8List();
  }
}
