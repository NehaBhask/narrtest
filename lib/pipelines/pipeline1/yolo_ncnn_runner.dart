import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:logger/logger.dart';
import '../../core/model_manager.dart';
import '../../core/constants.dart';
import 'dart:io';

// ── Assistive-Navigation class names ─────────────────────────────────────────
// Order MUST match the label indices in the Roboflow-exported NCNN model.
// Dataset: "Obstacle Detection for Assistive Navigation" (Roboflow Universe)
// Classes (index 0–6):
//   0 obstacle  — generic blocking object
//   1 stairs    — step / staircase in path
//   2 door      — door (open or closed)
//   3 hazard    — wet floor, construction, etc.
//   4 pole      — lamp-post, bollard, signpost
//   5 person    — pedestrian / bystander
//   6 vehicle   — car, bike, bus, auto-rickshaw
const List<String> navClassNames = [
  'obstacle',
  'stairs',
  'door',
  'hazard',
  'pole',
  'person',
  'vehicle',
];

class YoloDetection {
  final int classId;
  final double confidence;
  final double x1, y1, x2, y2; // normalised [0,1]

  const YoloDetection({
    required this.classId,
    required this.confidence,
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
  });

  /// Human-readable class name e.g. "person", "stairs", "vehicle"
  String get className =>
      (classId >= 0 && classId < navClassNames.length)
          ? navClassNames[classId]
          : 'cls$classId';

  double get area    => (x2 - x1) * (y2 - y1);
  double get centerX => (x1 + x2) / 2;
  double get centerY => (y1 + y2) / 2;

  @override
  String toString() =>
      '$className(${(confidence * 100).toInt()}%) '
      '[${x1.toStringAsFixed(2)},${y1.toStringAsFixed(2)},'
      '${x2.toStringAsFixed(2)},${y2.toStringAsFixed(2)}]';
}

class YoloNcnnRunner {
  YoloNcnnRunner._();
  static final YoloNcnnRunner instance = YoloNcnnRunner._();

  final _log = Logger();
  bool _isLoaded = false;
  bool get isLoaded => _isLoaded;

  static const _channel = MethodChannel('com.narrator/ncnn_plugin');

  static bool? _nativeLibraryLoaded;
  static bool get nativeLibraryLoaded => _nativeLibraryLoaded ?? true;

  Future<bool> _queryNativeLibStatus() async {
    try {
      final result = await _channel.invokeMethod<bool>('isNativeLibLoaded');
      _nativeLibraryLoaded = result ?? false;
      return _nativeLibraryLoaded!;
    } catch (_) {
      _nativeLibraryLoaded = true;
      return true;
    }
  }

  Future<bool> loadModel() async {
    final libOk = await _queryNativeLibStatus();
    if (!libOk) {
      _log.e('narrator_ncnn.so not loaded — YOLO disabled');
      return false;
    }

    final paramPath = ModelManager.instance.modelPath(AppConstants.yolov8nParamFile);
    final binPath   = ModelManager.instance.modelPath(AppConstants.yolov8nBinFile);

    if (!File(paramPath).existsSync() || !File(binPath).existsSync()) {
      _log.e('YOLO model files not found — param: $paramPath');
      return false;
    }

    try {
      final result = await _channel.invokeMethod<bool>('loadYoloModel', {
        'paramPath': paramPath,
        'binPath':   binPath,
      });
      _isLoaded = result ?? false;
      _log.i('YOLOv8 nav-model loaded: $_isLoaded  (${navClassNames.length} classes)');
      return _isLoaded;
    } catch (e) {
      _log.e('Error loading YOLO model: $e');
      return false;
    }
  }

  Future<List<YoloDetection>> detectFromJpeg(Uint8List jpegBytes) async {
    if (!_isLoaded) return [];
    return _parseResult(
      await _channel.invokeMethod<List<dynamic>>('detectFromJpeg', {
        'jpegData': jpegBytes,
      }),
    );
  }

  Future<List<YoloDetection>> detectFromBytes(
      Uint8List nv21Bytes, int width, int height) async {
    if (!_isLoaded) return [];
    return _parseResult(
      await _channel.invokeMethod<List<dynamic>>('detectObjects', {
        'yuvData': nv21Bytes,
        'width':   width,
        'height':  height,
      }),
    );
  }

  List<YoloDetection> _parseResult(List<dynamic>? raw) {
    if (raw == null || raw.isEmpty) return [];
    final detections = <YoloDetection>[];
    for (int i = 0; i + 6 <= raw.length; i += 6) {
      final classId    = (raw[i]     as num).toInt();
      final confidence = (raw[i + 1] as num).toDouble();
      final x1         = (raw[i + 2] as num).toDouble();
      final y1         = (raw[i + 3] as num).toDouble();
      final x2         = (raw[i + 4] as num).toDouble();
      final y2         = (raw[i + 5] as num).toDouble();

      // Guard: skip any classId outside the nav-model range (0–6)
      if (classId < 0 || classId >= navClassNames.length) {
        _log.w('_parseResult: skipping out-of-range classId=$classId (raw idx $i)');
        continue;
      }
      // Guard: skip degenerate boxes
      if (x2 <= x1 || y2 <= y1) continue;

      detections.add(YoloDetection(
        classId:    classId,
        confidence: confidence,
        x1: x1, y1: y1, x2: x2, y2: y2,
      ));
    }
    detections.sort((a, b) => b.confidence.compareTo(a.confidence));
    _log.d('_parseResult: ${detections.length} valid detections '
        '(raw floats=${raw.length}, packets=${raw.length ~/ 6})');
    return detections;
  }

  Future<void> release() async {
    try { await _channel.invokeMethod('releaseYoloModel'); } catch (_) {}
    _isLoaded = false;
  }
}
