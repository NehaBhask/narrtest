import '../../core/constants.dart';

/// A single YOLO detection result.
class Detection {
  final int    classId;
  final String className;
  final double confidence;
  /// Normalised bounding box [0, 1].
  final double x1, y1, x2, y2;

  const Detection({
    required this.classId,
    required this.className,
    required this.confidence,
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
  });

  double get width  => x2 - x1;
  double get height => y2 - y1;
  double get area   => width * height;
  double get centerX => (x1 + x2) / 2;
  double get centerY => (y1 + y2) / 2;
}

/// Distance estimate based on bounding-box area.
enum ObstacleDistance { close, medium, far }

/// Result of obstacle analysis for one frame.
class ObstacleResult {
  final bool hasObstacle;
  final List<Detection> detections;
  final ObstacleDistance? primaryDistance;
  final String? alertMessage;

  const ObstacleResult({
    required this.hasObstacle,
    required this.detections,
    this.primaryDistance,
    this.alertMessage,
  });

  static const ObstacleResult none = ObstacleResult(
    hasObstacle: false,
    detections:  [],
  );
}

// Full COCO-80 class names (must match narrator_ncnn.cpp)
const List<String> _cocoNames = [
  'person','bicycle','car','motorcycle','airplane','bus','train','truck','boat',
  'traffic light','fire hydrant','stop sign','parking meter','bench','bird',
  'cat','dog','horse','sheep','cow','elephant','bear','zebra','giraffe',
  'backpack','umbrella','handbag','tie','suitcase','frisbee','skis','snowboard',
  'sports ball','kite','baseball bat','baseball glove','skateboard','surfboard',
  'tennis racket','bottle','wine glass','cup','fork','knife','spoon','bowl',
  'banana','apple','sandwich','orange','broccoli','carrot','hot dog','pizza',
  'donut','cake','chair','couch','potted plant','bed','dining table','toilet',
  'tv','laptop','mouse','remote','keyboard','cell phone','microwave','oven',
  'toaster','sink','refrigerator','book','clock','vase','scissors','teddy bear',
  'hair drier','toothbrush',
];

// Obstacle mask — true = relevant for navigation safety
const List<bool> _isObstacle = [
  true,  // person
  true,  // bicycle
  true,  // car
  true,  // motorcycle
  false, // airplane
  true,  // bus
  false, // train
  true,  // truck
  false, // boat
  true,  // traffic light
  true,  // fire hydrant
  true,  // stop sign
  false, // parking meter
  true,  // bench
  false, // bird
  false, // cat
  true,  // dog
  false, false, false, false, false, false, false, // horse-giraffe
  true,  // backpack
  false, false, false, // umbrella-tie
  true,  // suitcase
  false, false, false, false, false, false, false, false, false, // frisbee-tennis
  true,  // bottle
  false, // wine glass
  true,  // cup
  false, false, false, false, false, false, false, false, false, false, // fork-orange
  false, false, false, false, false, false, // broccoli-donut
  false, // cake
  true,  // chair
  true,  // couch
  true,  // potted plant
  true,  // bed
  true,  // dining table
  true,  // toilet
  false, // tv
  true,  // laptop
  false, false, false, false, false, false, false, false, false, false, false, false, // mouse-toothbrush
];

/// Pure Dart obstacle analysis — no platform calls.
///
/// Input [rawDetections] is the flat float array from native:
///   [classId, confidence, x1, y1, x2, y2,  classId, confidence, ...]
class ObstacleDetector {
  final double confidenceThreshold;
  final double closeObstacleFraction;

  const ObstacleDetector({
    this.confidenceThreshold   = DetectionConfig.confidenceThreshold,
    this.closeObstacleFraction = DetectionConfig.closeObstacleFraction,
  });

  /// Parse raw float array → list of Detection objects.
  List<Detection> parseDetections(List<double> raw) {
    if (raw.length % 6 != 0) return [];
    final result = <Detection>[];
    for (var i = 0; i < raw.length; i += 6) {
      final classId    = raw[i].toInt();
      final confidence = raw[i + 1];
      final x1 = raw[i + 2];
      final y1 = raw[i + 3];
      final x2 = raw[i + 4];
      final y2 = raw[i + 5];

      if (confidence < confidenceThreshold) continue;
      if (classId < 0 || classId >= _cocoNames.length) continue;

      result.add(Detection(
        classId:    classId,
        className:  _cocoNames[classId],
        confidence: confidence,
        x1: x1, y1: y1, x2: x2, y2: y2,
      ));
    }
    return result;
  }

  /// Filter to only obstacle-class detections.
  List<Detection> filterObstacles(List<Detection> detections) =>
      detections.where((d) {
        if (d.classId < 0 || d.classId >= _isObstacle.length) return false;
        return _isObstacle[d.classId];
      }).toList();

  /// Estimate distance from bounding-box area (heuristic).
  ObstacleDistance estimateDistance(Detection d) {
    final area = d.area;
    if (area >= closeObstacleFraction * closeObstacleFraction) {
      return ObstacleDistance.close;
    } else if (area >= 0.05) {
      return ObstacleDistance.medium;
    }
    return ObstacleDistance.far;
  }

  /// Full analysis pipeline — parse → filter → classify → alert.
  ObstacleResult analyse(List<double> rawDetections) {
    final all       = parseDetections(rawDetections);
    final obstacles = filterObstacles(all);

    if (obstacles.isEmpty) return ObstacleResult.none;

    // Pick largest obstacle as primary
    obstacles.sort((a, b) => b.area.compareTo(a.area));
    final primary  = obstacles.first;
    final distance = estimateDistance(primary);

    final distLabel = switch (distance) {
      ObstacleDistance.close  => 'very close',
      ObstacleDistance.medium => 'ahead',
      ObstacleDistance.far    => 'in the distance',
    };

    return ObstacleResult(
      hasObstacle:     true,
      detections:      obstacles,
      primaryDistance: distance,
      alertMessage:    '${primary.className} $distLabel',
    );
  }

  /// Returns class name for a valid class id, or null.
  static String? className(int classId) {
    if (classId < 0 || classId >= _cocoNames.length) return null;
    return _cocoNames[classId];
  }

  /// Returns true if classId is an obstacle class.
  static bool isObstacleClass(int classId) {
    if (classId < 0 || classId >= _isObstacle.length) return false;
    return _isObstacle[classId];
  }
}
