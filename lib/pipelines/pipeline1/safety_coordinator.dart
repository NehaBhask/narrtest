import 'dart:async';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:logger/logger.dart';
import 'yolo_ncnn_runner.dart';
import 'obstacle_detector.dart';
import '../pipeline2/frame_selector.dart';
import '../pipeline2/conversation_coordinator.dart';
import '../../services/haptic_service.dart';
import '../../services/tts_service.dart';
import '../../services/language_service.dart';
import '../../core/constants.dart';

enum Pipeline1State { idle, running, paused }

/// Pipeline 1 — continuous obstacle detection via YOLO.
///
/// WHY no startImageStream:
/// On RMX3092, startImageStream forces a camera session reconfiguration that
/// kills the preview texture. Instead we use takePicture() on a 300ms timer
/// driven by FrameSelector, which works within the existing preview session.
class SafetyCoordinator {
  SafetyCoordinator._();
  static final SafetyCoordinator instance = SafetyCoordinator._();

  final _log = Logger();
  final _yolo = YoloNcnnRunner.instance;
  final _detector = ObstacleDetector();

  Pipeline1State _state = Pipeline1State.idle;
  Pipeline1State get state => _state;

  CameraController? _controller; // ignore: unused_field
  bool _inferring = false;

  DateTime? _lastAlertTime;
  int _frameCount = 0;
  int _detectionCount = 0;
  double _currentFps = 0.0;
  DateTime? _fpsTimer;
  StreamSubscription? _frameSub;

  bool get nativeLibLoaded => YoloNcnnRunner.nativeLibraryLoaded;

  final _detectionsController =
      StreamController<List<YoloDetection>>.broadcast();
  Stream<List<YoloDetection>> get detectionsStream =>
      _detectionsController.stream;
  double get currentFps => _currentFps;

  /// Must be called after camera controller is initialised.
  void attachController(CameraController controller) {
    _controller = controller;
  }

  Future<void> start() async {
    if (_state == Pipeline1State.running) return;

    if (!YoloNcnnRunner.nativeLibraryLoaded) {
      _log.e('P1: narrator_ncnn.so failed to load — YOLO disabled. '
          'Check that the native library was compiled and packaged correctly.');
      return;
    }

    final loaded = await _yolo.loadModel();
    if (!loaded) {
      _log.e('P1: YOLOv8 model load failed — safety pipeline inactive. '
          'Check that yolov8n.ncnn.param and yolov8n.ncnn.bin are present '
          'in assets/models/ (standard COCO 80-class NCNN export).');
      return;
    }

    _state = Pipeline1State.running;
    _startListener();
    _log.i('Pipeline 1 started — YOLO running (conf≥${AppConstants.minConfidenceThreshold})');
  }

  void _startListener() {
    _frameSub?.cancel();
    _frameSub = FrameSelector.instance.frameStream.listen((jpegBytes) {
      _runInference(jpegBytes);
    });
  }

  Future<void> _runInference(Uint8List jpegBytes) async {
    if (_state != Pipeline1State.running) return;
    if (_inferring) return; // drop frame if previous inference still running

    _inferring = true;
    try {
      _frameCount++;
      if (_frameCount % 5 == 0) {
        final now = DateTime.now();
        if (_fpsTimer != null) {
          _currentFps = 5000 / now.difference(_fpsTimer!).inMilliseconds;
        }
        _fpsTimer = now;
      }

      final detections = await _yolo.detectFromJpeg(jpegBytes);

      if (!_detectionsController.isClosed) {
        _detectionsController.add(detections);
      }

      final threat = _detector.mostThreateningObstacle(detections);
      if (threat != null) {
        _detectionCount++;
        await _triggerAlert(threat);
      }

      if (detections.isNotEmpty) {
        _log.d('P1: ${detections.length} detections, '
            'top=${detections.first.className} '
            '${(detections.first.confidence * 100).toInt()}%');
      }
    } catch (e) {
      _log.d('P1 inference skipped: $e');
    } finally {
      _inferring = false;
    }
  }

  Future<void> _triggerAlert(YoloDetection threat) async {
    // ── Guard 1: cooldown ───────────────────────────────────────────────
    final now = DateTime.now();
    if (_lastAlertTime != null &&
        now.difference(_lastAlertTime!).inMilliseconds <
            AppConstants.obstacleCooldownMs) {
      return;
    }

    // ── Guard 2: never interrupt P2 speaking/thinking ───────────────────
    // Allow alerts to fire while P2 is awaitingWakeWord or idle.
    // Suppress only during active user interaction (recording, transcribing,
    // thinking, speaking) so the VLM answer is not cut off.
    final p2State = ConversationCoordinator.instance.state;
    if (p2State == Pipeline2State.speaking ||
        p2State == Pipeline2State.thinking ||
        p2State == Pipeline2State.transcribing ||
        p2State == Pipeline2State.recording) {
      _log.d('P1: suppressing alert — P2 is $p2State');
      return;
    }

    _lastAlertTime = now;

    final dir      = _detector.direction(threat);
    final urgent   = _detector.isUrgent(threat);
    final distance = _detector.estimateDistanceM(threat);

    _log.i('🚨 Obstacle! class=${threat.className}, '
        'conf=${threat.confidence.toStringAsFixed(2)}, '
        'dir=$dir, urgent=$urgent, '
        'dist≈${distance.toStringAsFixed(1)}m, '
        'area=${threat.area.toStringAsFixed(2)}');

    final lang  = LanguageService.instance.currentCode;
    final label = threat.className;
    final msg   = _buildAlertMessage(lang, label, dir, urgent);

    // ── Fire haptic and TTS in parallel for minimum latency ────────────
    // Haptic gives ~instant tactile feedback while TTS is initialising.
    // We do NOT await the haptic — both fire simultaneously.
    unawaited(HapticService.instance.obstacleAlert());
    await TtsService.instance.speakAlert(msg);
  }

  /// Build a localised, direction-aware alert string.
  ///
  /// Examples:
  ///   EN: "Warning! Person ahead"  or  "Car on your left"
  ///   HI: "चेतावनी! आगे person है"  or  "बाईं तरफ car है"
  String _buildAlertMessage(
      String langCode, String objectName, String direction, bool urgent) {
    final warn = urgent ? _urgentPrefix(langCode) : '';

    switch (langCode) {
      case 'hi':
        final dirHi = direction == 'left'
            ? 'बाईं तरफ'
            : direction == 'right'
                ? 'दाईं तरफ'
                : 'आगे';
        return '${warn}$dirHi $objectName है, सावधान';

      case 'ta':
        final dirTa = direction == 'left'
            ? 'இடதுபக்கம்'
            : direction == 'right'
                ? 'வலதுபக்கம்'
                : 'முன்னால்';
        return '${warn}$dirTa $objectName உள்ளது';

      case 'te':
        final dirTe = direction == 'left'
            ? 'ఎడమవైపు'
            : direction == 'right'
                ? 'కుడివైపు'
                : 'ముందు';
        return '${warn}$dirTe $objectName ఉంది';

      case 'bn':
        final dirBn = direction == 'left'
            ? 'বামদিকে'
            : direction == 'right'
                ? 'ডানদিকে'
                : 'সামনে';
        return '${warn}$dirBn $objectName আছে';

      case 'mr':
        final dirMr = direction == 'left'
            ? 'डावीकडे'
            : direction == 'right'
                ? 'उजवीकडे'
                : 'पुढे';
        return '${warn}$dirMr $objectName आहे';

      case 'kn':
        final dirKn = direction == 'left'
            ? 'ಎಡಭಾಗದಲ್ಲಿ'
            : direction == 'right'
                ? 'ಬಲಭಾಗದಲ್ಲಿ'
                : 'ಮುಂದೆ';
        return '${warn}$dirKn $objectName ಇದೆ';

      default: // English
        final dirEn = direction == 'left'
            ? 'on your left'
            : direction == 'right'
                ? 'on your right'
                : 'ahead';
        return '${warn}$objectName $dirEn';
    }
  }

  String _urgentPrefix(String langCode) {
    switch (langCode) {
      case 'hi': return 'चेतावनी! ';
      case 'ta': return 'எச்சரிக்கை! ';
      case 'te': return 'హెచ్చరిక! ';
      case 'bn': return 'সতর্কতা! ';
      case 'mr': return 'इशारा! ';
      case 'kn': return 'ಎಚ್ಚರಿಕೆ! ';
      default:   return 'Warning! ';
    }
  }

  void pause() {
    if (_state == Pipeline1State.running) {
      _frameSub?.pause();
      _state = Pipeline1State.paused;
      _log.i('Pipeline 1 paused');
    }
  }

  void resume() {
    if (_state == Pipeline1State.paused) {
      _frameSub?.resume();
      _state = Pipeline1State.running;
      _log.i('Pipeline 1 resumed');
    }
  }

  Future<void> stop() async {
    _frameSub?.cancel();
    _frameSub = null;
    await _yolo.release();
    _state = Pipeline1State.idle;
    _log.i('Pipeline 1 stopped');
  }

  void dispose() {
    _frameSub?.cancel();
    _frameSub = null;
    Future.delayed(const Duration(milliseconds: 100), () {
      if (!_detectionsController.isClosed) _detectionsController.close();
    });
  }

  int get frameCount => _frameCount;
  int get detectionCount => _detectionCount;
}

// ignore: nothing_returned
void unawaited(Future<void> future) {
  // Intentionally not awaited — fire-and-forget for parallel execution.
}
