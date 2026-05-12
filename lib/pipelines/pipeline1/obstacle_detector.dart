import 'yolo_ncnn_runner.dart';
import '../../core/constants.dart';

/// Classifies whether a detection is a genuine in-path obstacle.
///
/// Because EVERY class in the nav-model (obstacle, stairs, door, hazard,
/// pole, person, vehicle) is inherently a navigation concern, we no longer
/// filter by class ID.  Instead we apply three geometric guards:
///
///   1. Area  ≥ obstacleAreaThreshold  (object is large/close enough)
///   2. CenterX in [obstacleMinCenterX, obstacleMaxCenterX]  (in walking path)
///   3. CenterY ≥ obstacleMinCenterY  (not a distant/background object at top)
///
/// This eliminates false positives from:
///   • Tiny far-away objects (a person 20 m down the street)
///   • Objects at the frame edges (pole glimpsed on the far right)
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
    // 1. Must be large enough to be a real near-field obstacle
    if (d.area < AppConstants.obstacleAreaThreshold) return false;

    // 2. Must be horizontally centred (in the walking path, not to the side)
    if (d.centerX < AppConstants.obstacleMinCenterX ||
        d.centerX > AppConstants.obstacleMaxCenterX) return false;

    // 3. Must be in the lower/mid portion of the frame.
    // Objects near the very top of frame are background or distant.
    if (d.centerY < AppConstants.obstacleMinCenterY) return false;

    return true;
  }

  /// Estimate rough distance in metres using inverse-square heuristic.
  /// Calibrated empirically: person at 1.5 m ≈ 25 % area.
  double estimateDistanceM(YoloDetection d) {
    // area ≈ k / distance²  →  distance ≈ sqrt(k / area)
    const k = 0.25 * 1.5 * 1.5;
    return (k / d.area).clamp(0.3, 10.0);
  }
}
