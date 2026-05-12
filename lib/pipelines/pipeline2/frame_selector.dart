import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:logger/logger.dart';

/// Captures frames via takePicture() on a timer.
///
/// WHY takePicture() instead of startImageStream():
/// On Realme/Oppo devices (RMX3092), calling startImageStream() on the same
/// CameraController that feeds CameraPreview forces a full camera session
/// reconfiguration, which disconnects the preview SurfaceTexture → black screen.
/// takePicture() uses a still-capture request on the EXISTING session — no
/// reconfiguration, no SurfaceTexture disconnect, preview stays live.
class FrameSelector {
  FrameSelector._();
  static final FrameSelector instance = FrameSelector._();

  final _log = Logger();

  CameraController? _controller;
  Timer? _captureTimer;
  Uint8List? _lastFrame;
  DateTime? _lastFrameTime;
  bool _capturing = false;

  final _frameStreamController = StreamController<Uint8List>.broadcast();
  Stream<Uint8List> get frameStream => _frameStreamController.stream;

  /// Attach the camera controller and start periodic capture.
  /// Call this after the controller is initialised.
  void attachController(CameraController controller) {
    _controller = controller;
    _startTimer();
  }

  void _startTimer() {
    _captureTimer?.cancel();
    // Capture a fresh frame every 800ms — frequent enough for scene changes,
    // slow enough not to interfere with the preview session.
    _captureTimer = Timer.periodic(const Duration(milliseconds: 800), (_) {
      _captureFrame();
    });
  }

  Future<void> _captureFrame() async {
    if (_controller == null) return;
    if (!_controller!.value.isInitialized) return;
    if (_controller!.value.isTakingPicture) return;
    if (_capturing) return;

    _capturing = true;
    try {
      final xFile = await _controller!.takePicture();
      final bytes = await File(xFile.path).readAsBytes();
      // Clean up temp file immediately
      await File(xFile.path).delete();
      _lastFrame = bytes;
      _lastFrameTime = DateTime.now();
      if (!_frameStreamController.isClosed) {
        _frameStreamController.add(bytes);
      }
    } catch (e) {
      // takePicture can fail if the controller is being disposed — ignore silently
      _log.d('Frame capture skipped: $e');
    } finally {
      _capturing = false;
    }
  }

  /// Returns the most recently captured JPEG frame.
  /// If no frame has been captured yet, waits up to 3 seconds for one.
  Future<Uint8List?> selectSharpestFrame() async {
    // If we already have a recent frame (< 2s old), return it immediately
    if (_lastFrame != null && _lastFrameTime != null) {
      final age = DateTime.now().difference(_lastFrameTime!).inMilliseconds;
      if (age < 2000) {
        _log.i('Frame selected, age=${age}ms');
        return _lastFrame;
      }
    }

    // Otherwise capture one right now and wait for it
    _log.i('No recent frame — capturing on demand');
    await _captureFrame();

    if (_lastFrame != null) {
      _log.i('On-demand frame captured');
      return _lastFrame;
    }

    _log.w('Frame capture failed');
    return null;
  }

  /// Legacy: called by SafetyCoordinator with CameraImage — no-op here
  /// since we use takePicture() instead of startImageStream().
  void addFrame(CameraImage cameraImage) {
    // Not used in takePicture() mode.
  }

  void clear() {
    _lastFrame = null;
    _lastFrameTime = null;
  }

  void dispose() {
    _captureTimer?.cancel();
    _captureTimer = null;
    _controller = null;
    _frameStreamController.close();
  }
}
