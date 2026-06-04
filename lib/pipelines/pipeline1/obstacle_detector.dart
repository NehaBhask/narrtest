import 'dart:math';
import 'yolo_ncnn_runner.dart';
import '../../core/constants.dart';

/// Classifies whether a detection is a genuine in-path obstacle.
///
/// Filtering layers (applied in order):
///   1. Class relevance  — only COCO classes meaningful for pedestrian nav
///   2. Confidence       — already filtered in _parseResult (≥ minConfidenceThreshold)
///   3. Area             — object is large/close enough (≥ obstacleAreaThreshold)
///   4. CenterX          — in the walking path, not to the far side
///   5. CenterY          — not a background/sky object at the top of frame
///
/// This eliminates false positives from:
///   • Irrelevant classes (spoon, kite, toothbrush…)
///   • Tiny far-away objects (person 20 m away)
///   • Objects at the frame edges
///   • Elevated objects the user is not about to walk into
class ObstacleDetector {
  ObstacleDetector();

  /// Returns true if any detection qualifies as an in-path obstacle.
  bool isObstacleNear(List<YoloDetection> detections) {
    return detections.any(_isInPath);
  }

  /// Returns the most threatening (largest) in-path obstacle, or null.
  YoloDetection? mostThreateningObstacle(List<YoloDetection> detections) {
    final inPath = detections.where(_isInPath).toList();
    if (inPath.isEmpty) return null;
    // Prioritise by area (largest = nearest = most urgent).
    inPath.sort((a, b) => b.area.compareTo(a.area));
    return inPath.first;
  }

  bool _isInPath(YoloDetection d) {
    // 1. Must be a navigation-relevant COCO class
    if (!AppConstants.navigationRelevantClassIds.contains(d.classId)) {
      return false;
    }

    // 2. Must be large enough to be a real near-field obstacle
    if (d.area < AppConstants.obstacleAreaThreshold) return false;

    // 3. Must be horizontally centred (in the walking path, not to the side)
    if (d.centerX < AppConstants.obstacleMinCenterX ||
        d.centerX > AppConstants.obstacleMaxCenterX) return false;

    // 4. Must be in the lower/mid portion of the frame.
    // Objects near the very top of frame are background or distant.
    if (d.centerY < AppConstants.obstacleMinCenterY) return false;

    return true;
  }

  /// Rough direction relative to the camera's field of view.
  /// Returns 'left', 'ahead', or 'right' based on bounding box centre.
  String direction(YoloDetection d) {
    if (d.centerX < 0.38) return 'left';
    if (d.centerX > 0.62) return 'right';
    return 'ahead';
  }

  /// Whether the obstacle is critically close (very large in frame).
  bool isUrgent(YoloDetection d) =>
      d.area >= AppConstants.obstacleUrgentAreaThreshold;

  /// Estimate rough distance in metres using class-aware inverse-square heuristic.
  ///
  /// Reference: object at real height H, filling fraction f of frame height
  ///   → k = f * H²
  ///
  /// | Class   | H (m) | k approx |
  /// |---------|-------|----------|
  /// | person  | 1.70  | 0.87     |
  /// | car     | 1.50  | 0.56     |
  /// | bus     | 3.00  | 1.20     |
  /// | other   | 1.20  | 0.29     |
  double estimateDistanceM(YoloDetection d) {
    final double k;
    switch (d.classId) {
      case 0:  k = 0.87; break; // person
      case 2:  k = 0.56; break; // car
      case 3:  k = 0.40; break; // motorcycle
      case 5:  k = 1.20; break; // bus
      case 7:  k = 1.20; break; // truck
      default: k = 0.29;
    }
    // distance ≈ sqrt(k / area), clamped to [0.3, 15.0] metres
    return sqrt(k / d.area).clamp(0.3, 15.0);
  }
}
