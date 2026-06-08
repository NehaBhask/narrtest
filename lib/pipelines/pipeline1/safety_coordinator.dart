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
///
/// ── Alert design for blind users ──────────────────────────────────────────
///
/// TTS messages are kept intentionally short (≤ 5 words) because every extra
/// syllable is time the user cannot hear their surroundings.
///
/// We layer three feedback channels:
///   1. Haptic — fires immediately, no audio processing lag. Pattern intensity
///      scales with proximity (4 levels). Always fires even when TTS is muted.
///   2. TTS alert — short, direction-aware. Suppressed only when P2 is
///      actively SPEAKING; urgent tier-1 threats (vehicles, animals) always
///      break through.
///   3. Cooldown — 2 s for non-urgent, 0.8 s for urgent, so the user isn't
///      flooded but critical alerts are repeated quickly.
///
/// Direction uses clock-position phrasing in English ("car at 10 o'clock")
/// and simple left/ahead/right in Indian languages where clock phrasing is
/// harder to localise.
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
  // Track last alerted class to avoid repeating the exact same alert.
  int _lastAlertedClassId = -1;

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

  void attachController(CameraController controller) {
    _controller = controller;
  }

  Future<void> start() async {
    if (_state == Pipeline1State.running) return;

    if (!YoloNcnnRunner.nativeLibraryLoaded) {
      _log.e('P1: narrator_ncnn.so failed to load — YOLO disabled.');
      return;
    }

    final loaded = await _yolo.loadModel();
    if (!loaded) {
      _log.e('P1: YOLOv8 model load failed — safety pipeline inactive. '
          'Ensure yolov8n.ncnn.param and yolov8n.ncnn.bin are in assets/models/.');
      return;
    }

    _state = Pipeline1State.running;
    _startListener();
    _log.i('Pipeline 1 started');
  }

  void _startListener() {
    _frameSub?.cancel();
    _frameSub = FrameSelector.instance.frameStream.listen(_runInference);
  }

  Future<void> _runInference(Uint8List jpegBytes) async {
    if (_state != Pipeline1State.running) return;
    if (_inferring) return;

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
    final now    = DateTime.now();
    final urgent = _detector.isUrgent(threat);

    // ── Cooldown ───────────────────────────────────────────────────────────
    // Urgent tier-1 threats (vehicles, animals) get a shorter cooldown so the
    // user is re-warned if the hazard persists.
    // Same-class repeated alert: use longer cooldown to avoid repetition.
    final cooldownMs = urgent ? 800 : 2000;
    final sameClass  = threat.classId == _lastAlertedClassId;
    final effectiveCooldownMs = sameClass ? cooldownMs * 2 : cooldownMs;

    if (_lastAlertTime != null &&
        now.difference(_lastAlertTime!).inMilliseconds < effectiveCooldownMs) {
      // Still fire haptic even during cooldown — tactile feedback is fast and
      // non-intrusive. Only skip it for proximitylevel 0 (distant object).
      if (_detector.proximityLevel(threat) >= 2) {
        unawaited(HapticService.instance.obstacleAlert());
      }
      return;
    }

    // ── P2 suppression ────────────────────────────────────────────────────
    // Only suppress TTS (not haptic) when P2 is actively speaking.
    // We used to suppress during .thinking and .transcribing too, which meant
    // the user could walk into a car while waiting for a VLM response.
    // Now: urgent tier-1 threats always break through; others suppress during
    // speaking only.
    final p2State = ConversationCoordinator.instance.state;
    final p2Speaking = p2State == Pipeline2State.speaking;
    if (p2Speaking && !urgent) {
      // Still give haptic feedback
      unawaited(HapticService.instance.obstacleAlert());
      _log.d('P1: TTS suppressed (P2 speaking, non-urgent)');
      return;
    }

    _lastAlertTime    = now;
    _lastAlertedClassId = threat.classId;

    final proximity = _detector.proximityLevel(threat);
    final distance  = _detector.estimateDistanceM(threat);
    final label     = _detector.labelFor(threat);

    _log.i('🚨 class=${threat.className} conf=${threat.confidence.toStringAsFixed(2)} '
        'prox=$proximity dist≈${distance.toStringAsFixed(1)}m '
        'area=${threat.area.toStringAsFixed(3)} urgent=$urgent');

    // ── Haptic — fires immediately before TTS ─────────────────────────────
    // Intensity is driven by proximity level (0–3) so the user has a physical
    // sense of how close the hazard is even before the voice speaks.
    unawaited(HapticService.instance.obstacleAlert());

    // ── TTS ───────────────────────────────────────────────────────────────
    final lang = LanguageService.instance.currentCode;
    final msg  = _buildAlertMessage(lang, label, threat, urgent);
    await TtsService.instance.speakAlert(msg);
  }

  // ── Alert message builder ──────────────────────────────────────────────────
  //
  // English uses clock-position phrasing ("car at 10 o'clock") because it
  // conveys more precise direction with fewer words than "on your left".
  //
  // Indian languages use simple left/ahead/right because clock-position
  // numbers don't localise cleanly — a user thinking in Kannada shouldn't
  // have to parse an English "10 o'clock" mid-stride.
  //
  // Message length targets:
  //   Non-urgent: ≤ 4 words   e.g. "Car at 10 o'clock"
  //   Urgent:     ≤ 6 words   e.g. "Warning! Car very close ahead"
  String _buildAlertMessage(
    String langCode,
    String label,
    YoloDetection threat,
    bool urgent,
  ) {
    final warn = urgent ? _urgentPrefix(langCode) : '';

    if (langCode == 'en') {
      // English: clock-position
      final clock = _detector.clockPosition(threat);
      if (urgent) {
        // e.g. "Warning! Car very close, 11 o'clock"
        return '${warn}$label very close, $clock';
      }
      // e.g. "Car at 10 o'clock"
      return '$label at $clock';
    }

    // Indian languages: simple direction
    final dir = _detector.direction(threat);

    switch (langCode) {
      case 'hi':
        final d = dir == 'left' ? 'बाईं तरफ' : dir == 'right' ? 'दाईं तरफ' : 'आगे';
        return '${warn}$d $label, सावधान';

      case 'ta':
        final d = dir == 'left' ? 'இடதுபக்கம்' : dir == 'right' ? 'வலதுபக்கம்' : 'முன்னால்';
        return '${warn}$d $label';

      case 'te':
        final d = dir == 'left' ? 'ఎడమవైపు' : dir == 'right' ? 'కుడివైపు' : 'ముందు';
        return '${warn}$d $label';

      case 'bn':
        final d = dir == 'left' ? 'বামদিকে' : dir == 'right' ? 'ডানদিকে' : 'সামনে';
        return '${warn}$d $label';

      case 'mr':
        final d = dir == 'left' ? 'डावीकडे' : dir == 'right' ? 'उजवीकडे' : 'पुढे';
        return '${warn}$d $label';

      case 'kn':
        final d = dir == 'left' ? 'ಎಡಭಾಗದಲ್ಲಿ' : dir == 'right' ? 'ಬಲಭಾಗದಲ್ಲಿ' : 'ಮುಂದೆ';
        return '${warn}$d $label';

      default:
        // Fallback English with simple direction
        final d = dir == 'left' ? 'on your left' : dir == 'right' ? 'on your right' : 'ahead';
        return '${warn}$label $d';
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

  int get frameCount     => _frameCount;
  int get detectionCount => _detectionCount;
}

// ignore: nothing_returned
void unawaited(Future<void> future) {
  // Intentionally not awaited — fire-and-forget for parallel execution.
}