import 'package:vibration/vibration.dart';
import 'package:logger/logger.dart';
import '../core/constants.dart';

/// Haptic feedback service — distinctive pulse patterns for each event type.
///
/// Patterns for blind users:
///   obstacleAlert     — 2 sharp pulses (urgent, danger)
///   listeningPulse    — 1 medium pulse (mic open, I am listening)
///   readyPulse        — 2 gentle taps (system ready)
///   responseComplete  — double-tap (answer finished)
///   cancelPulse       — 1 short buzz (cancelled/stopped)
class HapticService {
  HapticService._();
  static final HapticService instance = HapticService._();

  final _log = Logger();
  bool _hasVibrator = false;
  bool _hasAmplitudeControl = false;

  Future<void> init() async {
    _hasVibrator = await Vibration.hasVibrator() ?? false;
    _hasAmplitudeControl = await Vibration.hasAmplitudeControl() ?? false;
    _log.i('Vibrator: $_hasVibrator, AmplitudeControl: $_hasAmplitudeControl');
  }

  /// Two-pulse pattern: urgent obstacle nearby.
  /// Uses [AppConstants.obstaclePulsePattern] + matching intensities.
  Future<void> obstacleAlert() async {
    if (!_hasVibrator) return;
    // obstaclePulsePattern has 5 entries: [0, 120, 80, 120, 0]
    // obstaclePulseIntensities MUST also have 5 entries: [0, 220, 0, 220, 0]
    if (_hasAmplitudeControl) {
      await Vibration.vibrate(
        pattern: AppConstants.obstaclePulsePattern,
        intensities: AppConstants.obstaclePulseIntensities,
      );
    } else {
      await Vibration.vibrate(pattern: AppConstants.obstaclePulsePattern);
    }
  }

  /// Single medium pulse: mic is now open and recording.
  /// Gives the blind user tactile confirmation that the app is listening.
  Future<void> listeningPulse() async {
    if (!_hasVibrator) return;
    if (_hasAmplitudeControl) {
      await Vibration.vibrate(duration: 180, amplitude: 160);
    } else {
      await Vibration.vibrate(duration: 180);
    }
  }

  /// Two gentle taps: system is initialised and ready.
  Future<void> readyPulse() async {
    if (!_hasVibrator) return;
    if (_hasAmplitudeControl) {
      await Vibration.vibrate(
        pattern: [0, 60, 80, 60],
        intensities: [0, 100, 0, 100],
      );
    } else {
      await Vibration.vibrate(pattern: [0, 60, 80, 60]);
    }
  }

  /// Single short buzz: wake word confirmation (lighter than listening).
  Future<void> wakeWordConfirm() async {
    if (!_hasVibrator) return;
    if (_hasAmplitudeControl) {
      await Vibration.vibrate(duration: 50, amplitude: 100);
    } else {
      await Vibration.vibrate(duration: 50);
    }
  }

  /// Double-tap: P2 response has finished speaking.
  Future<void> responseComplete() async {
    if (!_hasVibrator) return;
    if (_hasAmplitudeControl) {
      await Vibration.vibrate(
        pattern: [0, 60, 60, 60],
        intensities: [0, 150, 0, 150],
      );
    } else {
      await Vibration.vibrate(pattern: [0, 60, 60, 60]);
    }
  }

  /// Single short buzz: action cancelled.
  Future<void> cancelPulse() async {
    if (!_hasVibrator) return;
    if (_hasAmplitudeControl) {
      await Vibration.vibrate(duration: 80, amplitude: 80);
    } else {
      await Vibration.vibrate(duration: 80);
    }
  }

  Future<void> cancel() async {
    await Vibration.cancel();
  }
}
