import 'dart:async';
import 'package:flutter/services.dart';
import 'package:logger/logger.dart';
import '../../services/haptic_service.dart';

enum WakeWordState { idle, listening, detected }

/// Wake word detection engine.
/// Uses openWakeWord (Apache 2.0) via Android native plugin.
/// Keywords: "hey narrator", "suno"
/// CPU usage: <5% (documented for wake word models of this size).
class WakeWordEngine {
  WakeWordEngine._();
  static final WakeWordEngine instance = WakeWordEngine._();

  static const _channel = MethodChannel('com.narrator/wake_word');
  final _log = Logger();

  WakeWordState _state = WakeWordState.idle;
  WakeWordState get state => _state;

  final _detectedController = StreamController<String>.broadcast();
  Stream<String> get onWakeWordDetected => _detectedController.stream;

  Future<void> init() async {
    // Register callback handler from native
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onWakeWordDetected') {
        final keyword = call.arguments as String? ?? 'narrator';
        _log.i('Wake word detected: $keyword');
        _state = WakeWordState.detected;
        await HapticService.instance.wakeWordConfirm();
        _detectedController.add(keyword);
        // Auto-reset to listening after emit
        await Future.delayed(const Duration(milliseconds: 500));
        if (_state == WakeWordState.detected) {
          _state = WakeWordState.listening;
        }
      }
    });
  }

  Future<void> start() async {
    if (_state != WakeWordState.idle) return;
    try {
      await _channel.invokeMethod('startListening');
      _state = WakeWordState.listening;
      _log.i('Wake word engine started');
    } on MissingPluginException {
      // Native wake word channel not implemented yet — run in manual-trigger-only mode
      _log.w('Wake word native channel not found — wake word disabled, use manual trigger.');
      _state = WakeWordState.listening; // allow coordinator to continue
    } on PlatformException catch (e) {
      _log.e('Failed to start wake word engine: $e');
    }
  }

  Future<void> stop() async {
    try {
      await _channel.invokeMethod('stopListening');
      _state = WakeWordState.idle;
      _log.i('Wake word engine stopped');
    } on MissingPluginException {
      _state = WakeWordState.idle;
    } on PlatformException catch (e) {
      _log.e('Failed to stop wake word engine: $e');
    }
  }

  void dispose() {
    _detectedController.close();
  }
}
