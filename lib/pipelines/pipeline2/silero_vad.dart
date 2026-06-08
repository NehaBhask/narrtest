import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import '../../core/constants.dart';

/// State of the VAD engine.
enum VadState { idle, speech, silence }

/// Result of processing one audio window.
class VadResult {
  final double probability; // 0.0 – 1.0
  final VadState state;
  final bool speechEndDetected;

  const VadResult({
    required this.probability,
    required this.state,
    this.speechEndDetected = false,
  });
}

/// Silero VAD wrapper — uses ONNX Runtime via MethodChannel.
///
/// Usage:
/// ```dart
/// final vad = SileroVad();
/// await vad.init(modelPath);
/// final stream = vad.process(audioStream);
/// await for (final result in stream) {
///   if (result.speechEndDetected) captureFrame();
/// }
/// ```
class SileroVad {
  static const _channel = MethodChannel('com.narrator/vad_plugin');

  bool _initialized = false;
  VadState _currentState = VadState.idle;
  int _silenceFrameCount = 0;

  /// Number of silent windows needed to declare speech end.
  final int silenceWindowsRequired;
  final double speechThreshold;
  final double silenceThreshold;

  SileroVad({
    this.silenceWindowsRequired = _defaultSilenceWindows,
    this.speechThreshold  = VadConfig.speechThreshold,
    this.silenceThreshold = VadConfig.silenceThreshold,
  });

  static int get _defaultSilenceWindows =>
      (VadConfig.silenceTimeoutMs /
          (VadConfig.windowSizeSamples * 1000 / VadConfig.sampleRate))
          .ceil();

  bool get isInitialized => _initialized;
  VadState get currentState => _currentState;

  /// Load the ONNX VAD model. Must be called before [process].
  Future<bool> init(String modelPath) async {
    try {
      final ok = await _channel.invokeMethod<bool>(
          'loadVadModel', {'modelPath': modelPath});
      _initialized = ok ?? false;
      return _initialized;
    } on PlatformException catch (e) {
      // Graceful degradation — VAD unavailable, Pipeline 2 will use a
      // fixed silence timeout instead.
      _initialized = false;
      return false;
    }
  }

  /// Process a 512-sample (32ms @ 16kHz) audio window.
  ///
  /// Returns a [VadResult] with speech probability and whether speech has ended.
  Future<VadResult> processWindow(Int16List pcmWindow) async {
    if (!_initialized) {
      return const VadResult(
          probability: 0.0, state: VadState.idle);
    }

    final bytes = _int16ToBytes(pcmWindow);
    double prob = 0.0;
    try {
      prob = await _channel.invokeMethod<double>(
              'processVadWindow', {'pcmBytes': bytes}) ??
          0.0;
    } on PlatformException {
      prob = 0.0;
    }

    return _updateState(prob);
  }

  VadResult _updateState(double prob) {
    VadState newState;

    if (prob >= speechThreshold) {
      newState = VadState.speech;
      _silenceFrameCount = 0;
    } else if (prob <= silenceThreshold && _currentState == VadState.speech) {
      _silenceFrameCount++;
      newState = _silenceFrameCount >= silenceWindowsRequired
          ? VadState.silence
          : VadState.speech; // still speech until timeout
    } else {
      newState = _currentState;
    }

    final speechEnd = _currentState == VadState.speech &&
        newState == VadState.silence;

    if (speechEnd) _silenceFrameCount = 0;

    _currentState = newState;
    return VadResult(
      probability:        prob,
      state:              newState,
      speechEndDetected:  speechEnd,
    );
  }

  /// Reset internal state machine (call before each new utterance).
  void reset() {
    _currentState     = VadState.idle;
    _silenceFrameCount = 0;
  }

  Future<void> dispose() async {
    if (_initialized) {
      await _channel.invokeMethod('releaseVadModel');
      _initialized = false;
    }
  }

  static Uint8List _int16ToBytes(Int16List samples) {
    final bytes = Uint8List(samples.length * 2);
    final bd    = bytes.buffer.asByteData();
    for (var i = 0; i < samples.length; i++) {
      bd.setInt16(i * 2, samples[i], Endian.little);
    }
    return bytes;
  }
}
