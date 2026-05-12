import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:logger/logger.dart';
import 'package:onnxruntime/onnxruntime.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';

/// Silero VAD v4 — detects speech/silence boundaries in PCM-16 audio.
///
/// Feed 512-sample (32ms @ 16kHz) chunks via [feed()].
/// Subscribe to [onSpeechEnd] to receive buffered audio when speech ends.
class SileroVad {
  SileroVad._();
  static final SileroVad instance = SileroVad._();

  final _log = Logger();

  OrtSession? _session;
  bool _isLoaded = false;
  List<String> _inputNames = [];
  List<String> _outputNames = [];
  bool _isV5 = false; // v5 uses single 'state' tensor; v4 uses separate h/c

  // Stateful tensors
  // v4: separate h/c → [2,1,64] each
  // v5: single state → [2,1,128]
  List<List<List<double>>> _h =
      List.generate(2, (_) => List.generate(1, (_) => List.filled(64, 0.0)));
  List<List<List<double>>> _c =
      List.generate(2, (_) => List.generate(1, (_) => List.filled(64, 0.0)));
  List<List<List<double>>> _state =
      List.generate(2, (_) => List.generate(1, (_) => List.filled(128, 0.0)));

  // VAD parameters
  static const double _speechThreshold = 0.5;
  static const double _silenceThreshold = 0.35;
  static const int _silenceFramesRequired = 22; // ~700ms of silence at 32ms/frame
  static const int _chunkSize = 512; // 32ms @ 16kHz

  // State
  bool _isSpeaking = false;
  int _silenceFrameCount = 0;
  final List<int> _audioBuffer = []; // PCM int16 samples

  // Speech-end stream
  final _speechEndController = StreamController<Uint8List>.broadcast();
  Stream<Uint8List> get onSpeechEnd => _speechEndController.stream;
  bool get isSpeaking => _isSpeaking;

  // Leftover bytes from incomplete chunk
  final List<int> _pending = [];

  Future<void> init() async {
    try {
      final byteData = await rootBundle.load('assets/models/silero_vad.onnx');
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/silero_vad.onnx');
      if (!file.existsSync()) {
        await file.writeAsBytes(byteData.buffer.asUint8List());
      }

      final opts = OrtSessionOptions()
        ..setInterOpNumThreads(1)
        ..setIntraOpNumThreads(1);
      _session = await OrtSession.fromFile(file, opts);

      // Auto-detect model version from input names
      _inputNames = _session!.inputNames;
      _outputNames = _session!.outputNames;
      _isV5 = _inputNames.contains('state') && !_inputNames.contains('h');

      _log.i('💡 Silero VAD loaded — version: ${_isV5 ? "v5" : "v4"}');
      _log.i('   inputs : $_inputNames');
      _log.i('   outputs: $_outputNames');
      _isLoaded = true;
    } catch (e) {
      _log.e('VAD init failed: $e');
    }
  }

  /// Feed raw PCM-16LE bytes from the microphone stream.
  void feed(Uint8List pcmBytes) {
    if (!_isLoaded || _session == null) return;

    // Append to pending buffer, process in 512-sample (1024-byte) chunks
    _pending.addAll(pcmBytes);

    while (_pending.length >= _chunkSize * 2) {
      final chunkBytes = _pending.sublist(0, _chunkSize * 2);
      _pending.removeRange(0, _chunkSize * 2);
      _processChunk(Uint8List.fromList(chunkBytes));
    }
  }

  void _processChunk(Uint8List chunkBytes) {
    // Convert PCM int16 → float32 [-1, 1]
    final samples = Float32List(_chunkSize);
    final bd = ByteData.sublistView(chunkBytes);
    for (int i = 0; i < _chunkSize; i++) {
      samples[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
    }

    // Buffer audio regardless of speech detection
    for (int i = 0; i < _chunkSize; i++) {
      _audioBuffer.add(bd.getInt16(i * 2, Endian.little));
    }

    try {
      final inputT = OrtValueTensor.createTensorWithDataList(
          samples, [1, _chunkSize]);
      final srT = OrtValueTensor.createTensorWithDataList(
          Int64List.fromList([16000]), [1]);

      Map<String, OrtValueTensor> inputs;
      List<String> requestedOutputs;

      if (_isV5) {
        // Silero VAD v5 — single state tensor [2, 1, 128]
        final stateFlat = Float32List.fromList(
            _state.expand((b) => b.expand((r) => r)).toList());
        final stateT = OrtValueTensor.createTensorWithDataList(
            stateFlat, [2, 1, 128]);
        inputs = {'input': inputT, 'state': stateT, 'sr': srT};
        requestedOutputs = ['output', 'stateN'];
      } else {
        // Silero VAD v4 — separate h/c tensors [2, 1, 64]
        final hFlat = Float32List.fromList(
            _h.expand((b) => b.expand((r) => r)).toList());
        final cFlat = Float32List.fromList(
            _c.expand((b) => b.expand((r) => r)).toList());
        final hT = OrtValueTensor.createTensorWithDataList(hFlat, [2, 1, 64]);
        final cT = OrtValueTensor.createTensorWithDataList(cFlat, [2, 1, 64]);
        inputs = {'input': inputT, 'h': hT, 'c': cT, 'sr': srT};
        requestedOutputs = ['output', 'hn', 'cn'];
      }

      final outputs = _session!.run(
          OrtRunOptions(), inputs, requestedOutputs);

      // Release inputs
      for (final t in inputs.values) t.release();

      if (outputs == null || outputs.isEmpty) return;

      // Parse speech probability
      final rawProb = outputs[0]?.value;
      double speechProb = 0.0;
      if (rawProb is List) {
        final inner = rawProb.first;
        speechProb = (inner is List ? inner.first : inner) as double;
      } else if (rawProb is double) {
        speechProb = rawProb;
      }

      // Update state tensors
      if (_isV5) {
        final snVal = outputs[1]?.value as List?;
        if (snVal != null) _state = _parseTensor3d(snVal, 2, 1, 128);
      } else {
        final hnVal = outputs[1]?.value as List?;
        final cnVal = outputs[2]?.value as List?;
        if (hnVal != null) _h = _parseTensor3d(hnVal, 2, 1, 64);
        if (cnVal != null) _c = _parseTensor3d(cnVal, 2, 1, 64);
      }
      for (final o in outputs) { o?.release(); }

      // VAD logic
      if (speechProb >= _speechThreshold) {
        _isSpeaking = true;
        _silenceFrameCount = 0;
      } else if (_isSpeaking && speechProb < _silenceThreshold) {
        _silenceFrameCount++;
        if (_silenceFrameCount >= _silenceFramesRequired) {
          _emitSpeechEnd();
        }
      }
    } catch (e) {
      _log.e('VAD inference error: $e');
    }
  }

  void _emitSpeechEnd() {
    if (_audioBuffer.isEmpty) return;
    final pcm = _buildWavBytes();
    _speechEndController.add(pcm);
    reset();
  }

  /// Build a raw PCM Uint8List (int16 little-endian) from the buffer.
  Uint8List _buildWavBytes() {
    final out = ByteData(_audioBuffer.length * 2);
    for (int i = 0; i < _audioBuffer.length; i++) {
      out.setInt16(i * 2, _audioBuffer[i], Endian.little);
    }
    return out.buffer.asUint8List();
  }

  /// Returns a snapshot of the current audio buffer as PCM int16 bytes.
  List<int> audioBufferSnapshot() {
    final bd = ByteData(_audioBuffer.length * 2);
    for (int i = 0; i < _audioBuffer.length; i++) {
      bd.setInt16(i * 2, _audioBuffer[i], Endian.little);
    }
    return bd.buffer.asUint8List().toList();
  }

  void reset() {
    _h = List.generate(2, (_) => List.generate(1, (_) => List.filled(64, 0.0)));
    _c = List.generate(2, (_) => List.generate(1, (_) => List.filled(64, 0.0)));
    _state = List.generate(2, (_) => List.generate(1, (_) => List.filled(128, 0.0)));
    _isSpeaking = false;
    _silenceFrameCount = 0;
    _audioBuffer.clear();
    _pending.clear();
  }

  List<List<List<double>>> _parseTensor3d(List raw, int d0, int d1, int d2) {
    final flat = raw.expand((e) => e is List ? e.expand((f) => f is List ? f : [f]) : [e])
        .map((e) => (e as num).toDouble()).toList();
    return List.generate(d0, (i) =>
        List.generate(d1, (j) =>
            List.generate(d2, (k) => flat[i * d1 * d2 + j * d2 + k])));
  }

  void dispose() {
    _session?.release();
    _speechEndController.close();
  }
}
