import 'package:flutter_test/flutter_test.dart';
import 'package:narrator/pipelines/pipeline1/obstacle_detector.dart';

void main() {
  group('ObstacleDetector', () {
    const detector = ObstacleDetector();

    // ── parseDetections ─────────────────────────────────────────────────────

    group('parseDetections', () {
      test('returns empty list for empty input', () {
        expect(detector.parseDetections([]), isEmpty);
      });

      test('returns empty list for malformed input (length % 6 != 0)', () {
        expect(detector.parseDetections([1.0, 2.0, 3.0]), isEmpty);
      });

      test('parses a single high-confidence detection', () {
        // classId=0 (person), conf=0.9, bbox=[0.1,0.1,0.5,0.8]
        final raw = [0.0, 0.9, 0.1, 0.1, 0.5, 0.8];
        final dets = detector.parseDetections(raw);
        expect(dets, hasLength(1));
        expect(dets.first.classId,    equals(0));
        expect(dets.first.className,  equals('person'));
        expect(dets.first.confidence, closeTo(0.9, 0.001));
        expect(dets.first.x1, closeTo(0.1, 0.001));
        expect(dets.first.y2, closeTo(0.8, 0.001));
      });

      test('filters out detections below confidence threshold', () {
        // conf=0.3 < default threshold 0.45
        final raw = [0.0, 0.3, 0.1, 0.1, 0.5, 0.8];
        expect(detector.parseDetections(raw), isEmpty);
      });

      test('filters out invalid class ids', () {
        // classId=99 is out of range for COCO-80
        final raw = [99.0, 0.9, 0.1, 0.1, 0.5, 0.8];
        expect(detector.parseDetections(raw), isEmpty);
      });

      test('parses multiple detections', () {
        final raw = [
          0.0, 0.9, 0.1, 0.1, 0.5, 0.8,   // person
          2.0, 0.8, 0.4, 0.2, 0.9, 0.7,   // car
          15.0, 0.7, 0.0, 0.0, 0.3, 0.3,  // cat (non-obstacle)
        ];
        final dets = detector.parseDetections(raw);
        expect(dets, hasLength(3));
        expect(dets[0].className, equals('person'));
        expect(dets[1].className, equals('car'));
        expect(dets[2].className, equals('cat'));
      });

      test('detection area is computed correctly', () {
        final raw = [0.0, 0.9, 0.1, 0.1, 0.5, 0.6]; // w=0.4, h=0.5
        final d = detector.parseDetections(raw).first;
        expect(d.width,  closeTo(0.4, 0.001));
        expect(d.height, closeTo(0.5, 0.001));
        expect(d.area,   closeTo(0.2, 0.001));
      });

      test('detection center is computed correctly', () {
        final raw = [0.0, 0.9, 0.0, 0.0, 0.6, 0.4];
        final d = detector.parseDetections(raw).first;
        expect(d.centerX, closeTo(0.3, 0.001));
        expect(d.centerY, closeTo(0.2, 0.001));
      });
    });

    // ── filterObstacles ──────────────────────────────────────────────────────

    group('filterObstacles', () {
      test('keeps person (class 0)', () {
        final dets = detector.parseDetections([0.0, 0.9, 0.1, 0.1, 0.5, 0.8]);
        expect(detector.filterObstacles(dets), hasLength(1));
      });

      test('removes cat (class 15) — non-obstacle', () {
        final dets = detector.parseDetections([15.0, 0.9, 0.1, 0.1, 0.5, 0.8]);
        expect(detector.filterObstacles(dets), isEmpty);
      });

      test('keeps car (class 2)', () {
        final dets = detector.parseDetections([2.0, 0.9, 0.0, 0.0, 0.8, 0.8]);
        expect(detector.filterObstacles(dets), hasLength(1));
      });

      test('keeps dog (class 16)', () {
        final dets = detector.parseDetections([16.0, 0.9, 0.0, 0.0, 0.3, 0.3]);
        expect(detector.filterObstacles(dets), hasLength(1));
      });

      test('keeps bench (class 13)', () {
        final dets = detector.parseDetections([13.0, 0.9, 0.0, 0.0, 0.5, 0.5]);
        expect(detector.filterObstacles(dets), hasLength(1));
      });

      test('removes airplane (class 4)', () {
        final dets = detector.parseDetections([4.0, 0.9, 0.0, 0.0, 0.9, 0.9]);
        expect(detector.filterObstacles(dets), isEmpty);
      });

      test('filters mixed list correctly', () {
        final raw = [
          0.0,  0.9, 0.0, 0.0, 0.5, 0.5, // person — obstacle
          4.0,  0.9, 0.0, 0.0, 0.5, 0.5, // airplane — not
          2.0,  0.9, 0.0, 0.0, 0.5, 0.5, // car — obstacle
          15.0, 0.9, 0.0, 0.0, 0.5, 0.5, // cat — not
        ];
        final dets      = detector.parseDetections(raw);
        final obstacles = detector.filterObstacles(dets);
        expect(obstacles, hasLength(2));
        expect(obstacles.map((d) => d.className), containsAll(['person', 'car']));
      });
    });

    // ── estimateDistance ─────────────────────────────────────────────────────

    group('estimateDistance', () {
      Detection makeDet(double x1, double y1, double x2, double y2) =>
          Detection(classId: 0, className: 'person', confidence: 0.9,
              x1: x1, y1: y1, x2: x2, y2: y2);

      test('large box → close', () {
        // area = 0.7*0.7 = 0.49 → well above 0.35^2 = 0.1225
        final d = makeDet(0.0, 0.0, 0.7, 0.7);
        expect(detector.estimateDistance(d), equals(ObstacleDistance.close));
      });

      test('medium box → medium', () {
        // area ≈ 0.05 threshold → pick something between
        final d = makeDet(0.0, 0.0, 0.3, 0.3); // area=0.09 > 0.05
        expect(detector.estimateDistance(d), equals(ObstacleDistance.medium));
      });

      test('tiny box → far', () {
        final d = makeDet(0.0, 0.0, 0.1, 0.1); // area=0.01 < 0.05
        expect(detector.estimateDistance(d), equals(ObstacleDistance.far));
      });
    });

    // ── analyse (full pipeline) ──────────────────────────────────────────────

    group('analyse', () {
      test('returns ObstacleResult.none for empty input', () {
        final r = detector.analyse([]);
        expect(r.hasObstacle, isFalse);
        expect(r.detections, isEmpty);
        expect(r.alertMessage, isNull);
      });

      test('returns no obstacle when only non-obstacle classes present', () {
        final raw = [15.0, 0.9, 0.0, 0.0, 0.8, 0.8]; // cat
        final r   = detector.analyse(raw);
        expect(r.hasObstacle, isFalse);
      });

      test('returns obstacle when person is detected', () {
        final raw = [0.0, 0.9, 0.0, 0.0, 0.8, 0.8]; // large person
        final r   = detector.analyse(raw);
        expect(r.hasObstacle, isTrue);
        expect(r.alertMessage, contains('person'));
        expect(r.primaryDistance, isNotNull);
      });

      test('alert message contains distance word', () {
        // Tiny person → far
        final raw = [0.0, 0.9, 0.0, 0.0, 0.1, 0.1];
        final r   = detector.analyse(raw);
        expect(r.alertMessage, contains('in the distance'));
      });

      test('alert message contains "very close" for large obstacle', () {
        final raw = [0.0, 0.9, 0.0, 0.0, 0.8, 0.8];
        final r   = detector.analyse(raw);
        expect(r.alertMessage, contains('very close'));
      });

      test('largest obstacle is chosen as primary', () {
        final raw = [
          0.0, 0.9, 0.0, 0.0, 0.2, 0.2,   // small person
          2.0, 0.9, 0.0, 0.0, 0.9, 0.9,   // large car
        ];
        final r = detector.analyse(raw);
        expect(r.alertMessage, contains('car'));
      });

      test('low confidence detections do not trigger obstacle', () {
        final raw = [0.0, 0.1, 0.0, 0.0, 0.9, 0.9]; // person, conf=0.1
        final r   = detector.analyse(raw);
        expect(r.hasObstacle, isFalse);
      });
    });

    // ── static helpers ───────────────────────────────────────────────────────

    group('static helpers', () {
      test('className returns correct name for valid id', () {
        expect(ObstacleDetector.className(0),  equals('person'));
        expect(ObstacleDetector.className(2),  equals('car'));
        expect(ObstacleDetector.className(79), equals('toothbrush'));
      });

      test('className returns null for invalid id', () {
        expect(ObstacleDetector.className(-1), isNull);
        expect(ObstacleDetector.className(80), isNull);
      });

      test('isObstacleClass is true for person', () {
        expect(ObstacleDetector.isObstacleClass(0), isTrue);
      });

      test('isObstacleClass is false for airplane', () {
        expect(ObstacleDetector.isObstacleClass(4), isFalse);
      });

      test('isObstacleClass is false for out-of-range id', () {
        expect(ObstacleDetector.isObstacleClass(99), isFalse);
      });
    });

    // ── custom threshold ─────────────────────────────────────────────────────

    group('custom confidence threshold', () {
      test('detector with higher threshold rejects borderline detection', () {
        const strict = ObstacleDetector(confidenceThreshold: 0.8);
        final raw = [0.0, 0.6, 0.0, 0.0, 0.9, 0.9]; // conf=0.6
        expect(strict.analyse(raw).hasObstacle, isFalse);
      });

      test('detector with lower threshold accepts borderline detection', () {
        const lenient = ObstacleDetector(confidenceThreshold: 0.3);
        final raw = [0.0, 0.4, 0.0, 0.0, 0.9, 0.9]; // conf=0.4
        expect(lenient.analyse(raw).hasObstacle, isTrue);
      });
    });
  });
}
