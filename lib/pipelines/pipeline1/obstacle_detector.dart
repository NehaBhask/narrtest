import 'yolo_ncnn_runner.dart';

/// Classifies whether a detection represents a near-field obstacle (~1.5m).
///
/// Strategy: bounding-box-area heuristic.
/// A full-height person at ~1.5m occupies ~15–20% of a standard camera frame.
/// We use a conservative 12% threshold to catch chairs, poles, and low objects.
class ObstacleDetector {
  ObstacleDetector({this.areaThreshold = 0.12});

  /// Normalised area threshold (0–1). Default 12% of frame.
  final double areaThreshold;

  /// Returns true if any detection is classified as a near obstacle.
  bool isObstacleNear(List<YoloDetection> detections) {
    return detections.any(_isNear);
  }

  /// Returns the most threatening (largest) near obstacle, or null.
  YoloDetection? mostThreateningObstacle(List<YoloDetection> detections) {
    final near = detections.where(_isNear).toList();
    if (near.isEmpty) return null;
    near.sort((a, b) => b.area.compareTo(a.area));
    return near.first;
  }

  bool _isNear(YoloDetection d) {
    // Must occupy sufficient area
    if (d.area < areaThreshold) return false;
    // Must be in central 80% of frame (avoid edge ghosts)
    if (d.centerX < 0.10 || d.centerX > 0.90) return false;
    return true;
  }

  /// Estimate rough distance in metres using inverse-square heuristic.
  /// Calibrated empirically: person at 1.5m ≈ 18% area.
  double estimateDistanceM(YoloDetection d) {
    // d.area ≈ k / distance^2  →  distance ≈ sqrt(k / area)
    // k calibrated so area=0.18 → 1.5m
    const k = 0.18 * 1.5 * 1.5;
    return (k / d.area).clamp(0.3, 10.0);
  }
}
