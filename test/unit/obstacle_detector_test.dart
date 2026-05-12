import 'package:flutter_test/flutter_test.dart';
import 'package:narrator/pipelines/pipeline1/obstacle_detector.dart';
import 'package:narrator/pipelines/pipeline1/yolo_ncnn_runner.dart';

void main() {
  group('ObstacleDetector', () {
    late ObstacleDetector detector;

    setUp(() {
      detector = ObstacleDetector(areaThreshold: 0.12);
    });

    test('returns null when no detections', () {
      expect(detector.mostThreateningObstacle([]), isNull);
    });

    test('returns null when detection is too small (far away)', () {
      final small = const YoloDetection(
        classId: 0, confidence: 0.9, x1: 0.4, y1: 0.4, x2: 0.5, y2: 0.5); // area = 0.01
      expect(detector.mostThreateningObstacle([small]), isNull);
    });

    test('detects large central obstacle as near', () {
      final large = const YoloDetection(
        classId: 0, confidence: 0.92, x1: 0.2, y1: 0.2, x2: 0.8, y2: 0.8); // area = 0.36
      final result = detector.mostThreateningObstacle([large]);
      expect(result, isNotNull);
      expect(result!.classId, equals(0));
    });

    test('ignores edge detections (x < 0.10)', () {
      final edge = const YoloDetection(
        classId: 0, confidence: 0.95, x1: 0.01, y1: 0.2, x2: 0.08, y2: 0.8);
      expect(detector.mostThreateningObstacle([edge]), isNull);
    });

    test('picks largest among multiple near obstacles', () {
      final mid = const YoloDetection(
        classId: 0, confidence: 0.9, x1: 0.3, y1: 0.3, x2: 0.6, y2: 0.6); // area = 0.09 — too small
      final big = const YoloDetection(
        classId: 0, confidence: 0.85, x1: 0.15, y1: 0.15, x2: 0.75, y2: 0.75); // area = 0.36
      final result = detector.mostThreateningObstacle([mid, big]);
      expect(result?.x1, equals(0.15));
    });

    test('estimates distance ~1.5m for 18% area detection', () {
      final near = const YoloDetection(
        classId: 0, confidence: 0.9, x1: 0.3, y1: 0.3, x2: 0.72, y2: 0.73); // area ~0.18
      final dist = detector.estimateDistanceM(near);
      expect(dist, closeTo(1.5, 0.5));
    });

    test('isObstacleNear returns false for empty list', () {
      expect(detector.isObstacleNear([]), isFalse);
    });

    test('isObstacleNear returns true for close obstacle', () {
      final close = const YoloDetection(
        classId: 2, confidence: 0.88, x1: 0.2, y1: 0.2, x2: 0.7, y2: 0.8);
      expect(detector.isObstacleNear([close]), isTrue);
    });
  });
}
