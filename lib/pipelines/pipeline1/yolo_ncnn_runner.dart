import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:logger/logger.dart';
import '../../core/model_manager.dart';
import '../../core/constants.dart';
import 'dart:io';

// ── COCO 80-Class Names ────────────────────────────────────────────────────
// Index MUST match the NCNN-exported YOLOv8n COCO label order.
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
      _log.i('YOLOv8 COCO model loaded: $_isLoaded '
          '(${_cocoNames.length} classes)');
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

  // ── Result parsing ─────────────────────────────────────────────────────────
  //
  // The JNI side returns a flat List<double> in groups of 6:
  //   [classId, confidence, x1, y1, x2, y2, classId, confidence, ...]
  //
  // Filtering strategy:
  //   • We apply a GLOBAL minimum confidence of 0.20 here to discard clearly
  //     garbage detections before they reach ObstacleDetector. Per-class
  //     thresholds are enforced in ObstacleDetector._passesConfidence().
  //   • NMS is applied in two passes:
  //       Pass 1 (same-class): standard greedy per-class NMS.
  //       Pass 2 (cross-class): suppress heavily-overlapping boxes of
  //         DIFFERENT classes, keeping the higher-confidence one. This handles
  //         the case where YOLO fires both "person" and "bicycle" on a cyclist,
  //         or "car" and "truck" on the same vehicle. Without this, the blind
  //         user hears two alerts for one physical object.
  //
  // NMS IoU thresholds:
  //   Same-class:  0.45 — fairly aggressive, YOLO already handles most same-
  //                        class NMS internally; this is a safety net.
  //   Cross-class: 0.60 — less aggressive; only suppress when boxes are nearly
  //                        identical (genuine duplicate label, not two objects).

  static const _globalMinConf      = 0.20;
  static const _nmsIouSameClass    = 0.45;
  static const _nmsIouCrossClass   = 0.60;

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

      // Guard 1: valid COCO class ID (0–79)
      if (classId < 0 || classId >= _cocoNames.length) {
        _log.w('_parseResult: skipping out-of-range classId=$classId');
        continue;
      }

      // Guard 2: global floor confidence — catches garbage boxes from
      // the blob-name mismatch bug (out0 vs output0) which produces
      // near-zero confidence detections.
      if (confidence < _globalMinConf) continue;

      // Guard 3: degenerate bounding box
      if (x2 <= x1 || y2 <= y1) continue;

      // Guard 4: minimum area — discard single-pixel noise boxes
      final area = (x2 - x1) * (y2 - y1);
      if (area < 0.0004) continue; // < 0.04 % of frame

      rawDetections.add(YoloDetection(
        classId:    classId,
        confidence: confidence,
        x1: x1, y1: y1, x2: x2, y2: y2,
      ));
    }

    // Sort by confidence descending before NMS
    rawDetections.sort((a, b) => b.confidence.compareTo(a.confidence));

    // Pass 1: same-class NMS
    final afterPass1 = _nms(rawDetections, _nmsIouSameClass, sameClassOnly: true);

    // Pass 2: cross-class NMS (remove duplicate-label overlaps)
    final detections = _nms(afterPass1, _nmsIouCrossClass, sameClassOnly: false);

    _log.d('_parseResult: ${detections.length} detections after 2-pass NMS '
        '(raw=${raw.length ~/ 6} packets)');
    return detections;
  }

  /// Greedy NMS.
  ///
  /// [sameClassOnly] = true  → suppress only same-class overlaps (Pass 1)
  /// [sameClassOnly] = false → suppress any class overlap (Pass 2)
  List<YoloDetection> _nms(
    List<YoloDetection> sorted,
    double iouThreshold, {
    required bool sameClassOnly,
  }) {
    final kept       = <YoloDetection>[];
    final suppressed = List<bool>.filled(sorted.length, false);

    for (int i = 0; i < sorted.length; i++) {
      if (suppressed[i]) continue;
      kept.add(sorted[i]);
      for (int j = i + 1; j < sorted.length; j++) {
        if (suppressed[j]) continue;
        if (sameClassOnly && sorted[j].classId != sorted[i].classId) continue;
        if (_iou(sorted[i], sorted[j]) > iouThreshold) {
          suppressed[j] = true;
        }
      }
    }
    return kept;
  }

  /// Intersection over Union.
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