import 'package:flutter_test/flutter_test.dart';
import 'package:narrator/pipelines/pipeline1/obstacle_detector.dart';
import 'package:narrator/pipelines/pipeline1/yolo_ncnn_runner.dart';

// Thresholds must mirror AppConstants to keep tests in sync:
//   obstacleAreaThreshold = 0.25
//   obstacleMinCenterX    = 0.25
//   obstacleMaxCenterX    = 0.75
//   obstacleMinCenterY    = 0.35

void main() {
  group('ObstacleDetector', () {
    late ObstacleDetector detector;

    setUp(() {
      // Constructor no longer takes areaThreshold — reads from AppConstants.
      detector = ObstacleDetector();
    });

    test('returns null when no detections', () {
      expect(detector.mostThreateningObstacle([]), isNull);
    });

    test('returns null when detection is too small (far away)', () {
      // area = 0.01 — well below 25% threshold
      final small = const YoloDetection(
        classId: 0, confidence: 0.9,
        x1: 0.4, y1: 0.4, x2: 0.5, y2: 0.5);
      expect(detector.mostThreateningObstacle([small]), isNull);
    });

    test('returns null when detection area is between 12% and 25% (old threshold, new miss)', () {
      // area ≈ 0.18 — would have passed old 12% check, fails new 25% check
      final medium = const YoloDetection(
        classId: 0, confidence: 0.9,
        x1: 0.3, y1: 0.3, x2: 0.72, y2: 0.73);
      expect(detector.mostThreateningObstacle([medium]), isNull);
    });

    test('detects large central obstacle as in-path', () {
      // area = 0.36, centerX = 0.5, centerY = 0.5 — passes all 3 checks
      final large = const YoloDetection(
        classId: 0, confidence: 0.92,
        x1: 0.2, y1: 0.2, x2: 0.8, y2: 0.8);
      final result = detector.mostThreateningObstacle([large]);
      expect(result, isNotNull);
      expect(result!.classId, equals(0));
    });

    test('ignores detection outside horizontal path (centerX < 0.25)', () {
      // box from x=0.01 to x=0.20 — centerX=0.105, left of 0.25 boundary
      final edge = const YoloDetection(
        classId: 0, confidence: 0.95,
        x1: 0.01, y1: 0.2, x2: 0.20, y2: 0.8);
      expect(detector.mostThreateningObstacle([edge]), isNull);
    });

    test('ignores detection outside horizontal path (centerX > 0.75)', () {
      // box from x=0.80 to x=0.99 — centerX=0.895, right of 0.75 boundary
      final rightEdge = const YoloDetection(
        classId: 0, confidence: 0.95,
        x1: 0.80, y1: 0.2, x2: 0.99, y2: 0.8);
      expect(detector.mostThreateningObstacle([rightEdge]), isNull);
    });

    test('ignores detection at top of frame (centerY < 0.35 — background object)', () {
      // Large box but entirely in upper frame — background/distant
      final topFrame = const YoloDetection(
        classId: 0, confidence: 0.95,
        x1: 0.25, y1: 0.0, x2: 0.75, y2: 0.30); // centerY = 0.15
      expect(detector.mostThreateningObstacle([topFrame]), isNull);
    });

    test('picks largest among multiple in-path obstacles', () {
      // mid: area = 0.09 — too small, filtered out
      final mid = const YoloDetection(
        classId: 0, confidence: 0.9,
        x1: 0.3, y1: 0.3, x2: 0.6, y2: 0.6);
      // big: area = 0.36, centerX=0.45, centerY=0.45 — passes all checks
      final big = const YoloDetection(
        classId: 0, confidence: 0.85,
        x1: 0.20, y1: 0.20, x2: 0.70, y2: 0.70);
      final result = detector.mostThreateningObstacle([mid, big]);
      expect(result?.x1, equals(0.20));
    });

    test('estimates distance ~1.5m for 25% area detection', () {
      // k calibrated so area=0.25 → 1.5m
      // Use a box with area exactly 0.25: e.g. 0.5×0.5 centred at (0.5,0.6)
      final near = const YoloDetection(
        classId: 0, confidence: 0.9,
        x1: 0.25, y1: 0.35, x2: 0.75, y2: 0.85); // area = 0.25
      final dist = detector.estimateDistanceM(near);
      expect(dist, closeTo(1.5, 0.3));
    });

    test('isObstacleNear returns false for empty list', () {
      expect(detector.isObstacleNear([]), isFalse);
    });

    test('isObstacleNear returns true for large central in-path obstacle', () {
      // area = 0.30, centerX=0.45, centerY=0.50 — passes all 3 checks
      final close = const YoloDetection(
        classId: 2, confidence: 0.88,
        x1: 0.20, y1: 0.25, x2: 0.70, y2: 0.85);
      expect(detector.isObstacleNear([close]), isTrue);
    });

    test('isObstacleNear returns false for large but off-centre obstacle', () {
      // area is large but centerX = 0.15 — object is to the left of path
      final offCentre = const YoloDetection(
        classId: 2, confidence: 0.88,
        x1: 0.0, y1: 0.25, x2: 0.30, y2: 0.85); // centerX = 0.15
      expect(detector.isObstacleNear([offCentre]), isFalse);
    });
  });
}
