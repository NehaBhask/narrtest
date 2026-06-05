import 'dart:async';
import 'package:flutter/services.dart';
import 'package:logger/logger.dart';
import '../../services/haptic_service.dart';

enum WakeWordState { idle, listening, detected }

/// Wake word detection engine.
/// Uses openWakeWord (Apache 2.0) via Android native plugin.
/// Keywords: "hey narrator", "suno"
/// CPU usage: <5% (documented for wake word models of this size).
///
/// FIX: When the native channel is missing (MissingPluginException),
/// the engine now stays in a valid [WakeWordState.listening] state AND
/// exposes [triggerSoftware()] so [ConversationCoordinator.triggerManually()]
/// can fire a detection event without the native side. Previously the
/// exception was silently swallowed but [onWakeWordDetected] never emitted,
/// so the coordinator was permanently stuck.
class WakeWordEngine {
  WakeWordEngine._();
  static final WakeWordEngine instance = WakeWordEngine._();

  static const _channel = MethodChannel('com.narrator/wake_word');
  final _log = Logger();

  WakeWordState _state = WakeWordState.idle;
  WakeWordState get state => _state;

  /// Whether the native wake-word channel is available.
  /// False means we are running in software/manual-trigger-only mode.
  bool _nativeAvailable = false;
  bool get nativeAvailable => _nativeAvailable;

  final _detectedController = StreamController<String>.broadcast();
  Stream<String> get onWakeWordDetected => _detectedController.stream;

  Future<void> init() async {
    // Register callback handler from native side
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onWakeWordDetected') {
        final keyword = call.arguments as String? ?? 'narrator';
        _log.i('Wake word detected (native): $keyword');
        await _emitDetection(keyword);
      }
    });
  }

  Future<void> start() async {
    if (_state != WakeWordState.idle) return;
    try {
      await _channel.invokeMethod('startListening');
      _nativeAvailable = true;
      _state = WakeWordState.listening;
      _log.i('Wake word engine started (native)');
    } on MissingPluginException {
      // Native channel not wired yet — fall back to software/manual mode.
      // The coordinator can still work via triggerManually() / triggerSoftware().
      _nativeAvailable = false;
      _state = WakeWordState.listening; // allow coordinator to proceed
      _log.w(
        'Wake word native channel not found — running in manual-trigger mode. '
        'Call WakeWordEngine.instance.triggerSoftware() to simulate detection.',
      );
    } on PlatformException catch (e) {
      _nativeAvailable = false;
      _log.e('Failed to start wake word engine: $e');
      // Still move to listening so manual trigger works
      _state = WakeWordState.listening;
    }
  }

  /// Programmatically fire a wake-word event — used by the UI "tap to speak"
  /// button and by [ConversationCoordinator.triggerManually()].
  Future<void> triggerSoftware({String keyword = 'narrator'}) async {
    if (_state == WakeWordState.idle) {
      _log.w('triggerSoftware called while idle — starting first');
      await start();
    }
    _log.i('Wake word triggered (software): $keyword');
    await _emitDetection(keyword);
  }

  Future<void> _emitDetection(String keyword) async {
    _state = WakeWordState.detected;
    await HapticService.instance.wakeWordConfirm();
    _detectedController.add(keyword);
    // Auto-reset to listening after emit
    await Future.delayed(const Duration(milliseconds: 500));
    if (_state == WakeWordState.detected) {
      _state = WakeWordState.listening;
    }
  }

  Future<void> stop() async {
    try {
      await _channel.invokeMethod('stopListening');
      _state = WakeWordState.idle;
      _log.i('Wake word engine stopped (native)');
    } on MissingPluginException {
      _state = WakeWordState.idle;
    } on PlatformException catch (e) {
      _log.e('Failed to stop wake word engine: $e');
      _state = WakeWordState.idle;
    }
  }

  void dispose() {
    _detectedController.close();
  }
}