import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:logger/logger.dart';
import '../../core/model_manager.dart';
import '../../core/constants.dart';
import 'dart:io';

// ── COCO 80-Class Names ───────────────────────────────────────────────────────
// Alias to AppConstants for easy access throughout this file.
// Index MUST match the NCNN-exported YOLOv8n COCO model label order.
// To verify your model's label order, check the .param file's output layer
// or run: yolo predict model=yolov8n.pt source=your_image.jpg
List<String> get _cocoNames => AppConstants.cocoClassNames;

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

  /// Human-readable COCO class name e.g. "person", "car", "chair"
  String get className =>
      (classId >= 0 && classId < _cocoNames.length)
          ? _cocoNames[classId]
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
      _log.i('YOLOv8 COCO model loaded: $_isLoaded  '
          '(${_cocoNames.length} classes, '
          '${AppConstants.navigationRelevantClassIds.length} nav-relevant)');
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

    final rawDetections = <YoloDetection>[];

    for (int i = 0; i + 6 <= raw.length; i += 6) {
      final classId    = (raw[i]     as num).toInt();
      final confidence = (raw[i + 1] as num).toDouble();
      final x1         = (raw[i + 2] as num).toDouble();
      final y1         = (raw[i + 3] as num).toDouble();
      final x2         = (raw[i + 4] as num).toDouble();
      final y2         = (raw[i + 5] as num).toDouble();

      // ── Guard 1: valid COCO class ID (0–79)
      if (classId < 0 || classId >= _cocoNames.length) {
        _log.w('_parseResult: skipping out-of-range classId=$classId');
        continue;
      }

      // ── Guard 2: confidence threshold — suppress ghost boxes
      if (confidence < AppConstants.minConfidenceThreshold) {
        _log.d('_parseResult: skipping low-confidence '
            'classId=$classId conf=${confidence.toStringAsFixed(2)}');
        continue;
      }

      // ── Guard 3: degenerate bounding box
      if (x2 <= x1 || y2 <= y1) continue;

      rawDetections.add(YoloDetection(
        classId:    classId,
        confidence: confidence,
        x1: x1, y1: y1, x2: x2, y2: y2,
      ));
    }

    // ── Sort by confidence descending before NMS
    rawDetections.sort((a, b) => b.confidence.compareTo(a.confidence));

    // ── Dart-side NMS: suppress overlapping boxes of the same class
    final detections = _applyNms(rawDetections);

    _log.d('_parseResult: ${detections.length} detections after NMS '
        '(raw=${raw.length ~/ 6} packets, '
        'minConf=${AppConstants.minConfidenceThreshold})');
    return detections;
  }

  /// Non-Maximum Suppression — removes duplicate overlapping boxes.
  ///
  /// Algorithm: greedy NMS per class.
  ///   1. Sort by confidence (already done before calling).
  ///   2. For each box, suppress any lower-confidence box of the same class
  ///      whose IoU with the current box exceeds [AppConstants.nmsIouThreshold].
  List<YoloDetection> _applyNms(List<YoloDetection> sorted) {
    final kept = <YoloDetection>[];
    final suppressed = List<bool>.filled(sorted.length, false);

    for (int i = 0; i < sorted.length; i++) {
      if (suppressed[i]) continue;
      kept.add(sorted[i]);
      for (int j = i + 1; j < sorted.length; j++) {
        if (suppressed[j]) continue;
        // Only suppress same-class boxes
        if (sorted[j].classId != sorted[i].classId) continue;
        if (_iou(sorted[i], sorted[j]) > AppConstants.nmsIouThreshold) {
          suppressed[j] = true;
        }
      }
    }
    return kept;
  }

  /// Intersection over Union for two bounding boxes.
  double _iou(YoloDetection a, YoloDetection b) {
    final ix1 = a.x1 > b.x1 ? a.x1 : b.x1;
    final iy1 = a.y1 > b.y1 ? a.y1 : b.y1;
    final ix2 = a.x2 < b.x2 ? a.x2 : b.x2;
    final iy2 = a.y2 < b.y2 ? a.y2 : b.y2;

    if (ix2 <= ix1 || iy2 <= iy1) return 0.0;
    final intersection = (ix2 - ix1) * (iy2 - iy1);
    final union = a.area + b.area - intersection;
    return union <= 0 ? 0.0 : intersection / union;
  }

  Future<void> release() async {
    try { await _channel.invokeMethod('releaseYoloModel'); } catch (_) {}
    _isLoaded = false;
  }
}
