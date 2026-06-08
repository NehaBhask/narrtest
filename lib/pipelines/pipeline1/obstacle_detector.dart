import 'dart:math';
import 'yolo_ncnn_runner.dart';

// ── Blind-navigation class registry ──────────────────────────────────────────
//
// COCO-80 has 80 classes. We split them into three tiers based on how
// dangerous they are for a pedestrian who cannot see:
//
//  Tier 1 — ALWAYS alert, regardless of where in frame (id → real-world height m)
//  Tier 2 — Alert when in the lower 70 % of frame (walking-level objects)
//  Tier 3 — Alert only when very large / close AND in walking path
//
// All COCO class IDs (0-indexed):
//  0  person       1  bicycle      2  car          3  motorcycle
//  4  airplane     5  bus          6  train        7  truck
//  8  boat         9  traffic light 10 fire hydrant 11 stop sign
//  12 parking meter 13 bench       14 bird         15 cat
//  16 dog          17 horse        18 sheep        19 cow
//  20 elephant     21 bear         22 zebra        23 giraffe
//  24 backpack     25 umbrella     26 handbag       27 tie
//  28 suitcase     29 frisbee      30 skis          31 snowboard
//  32 sports ball  33 kite         34 baseball bat  35 baseball glove
//  36 skateboard   37 surfboard    38 tennis racket 39 bottle
//  40 wine glass   41 cup          42 fork          43 knife
//  44 spoon        45 bowl         46 banana        47 apple
//  48 sandwich     49 orange       50 broccoli      51 carrot
//  52 hot dog      53 pizza        54 donut         55 cake
//  56 chair        57 couch        58 potted plant  59 bed
//  60 dining table 61 toilet       62 tv            63 laptop
//  64 mouse        65 remote       66 keyboard      67 cell phone
//  68 microwave    69 oven         70 toaster       71 sink
//  72 refrigerator 73 book         74 clock         75 vase
//  76 scissors     77 teddy bear   78 hair drier    79 toothbrush

/// Per-class metadata used by [ObstacleDetector].
class _ClassMeta {
  /// Minimum confidence to treat a raw YOLO detection as real for this class.
  /// Lower for large/dangerous things (we'd rather have a false positive than
  /// miss a vehicle). Higher for small irrelevant things.
  final double minConf;

  /// Approximate real-world height in metres — used for distance estimation.
  /// k = H² × typical-frame-fill-at-1m (empirical constant).
  final double distK;

  /// Human-readable label used in TTS alerts.
  /// Kept short — every extra syllable adds TTS latency.
  final String label;

  /// Alert tier (1 = highest priority / any position, 3 = lowest).
  final int tier;

  const _ClassMeta({
    required this.minConf,
    required this.distK,
    required this.label,
    required this.tier,
  });
}

/// Identifies which COCO classes matter for blind-pedestrian navigation,
/// classifies detections as obstacles, and computes direction + distance.
///
/// ──────────────────────────────────────────────────────────────────────────
/// DESIGN RATIONALE
///
/// The original code delegated class filtering to AppConstants, which used a
/// fixed whitelist and a uniform confidence threshold. This caused two problems:
///
///  1. False negatives on large dangerous objects (car, bus) because the
///     confidence bar was the same as for benign small objects.
///  2. False positives from tiny far-away instances of relevant classes
///     (person 20 m away) and from irrelevant classes.
///
/// We solve this with:
///  • Per-class minimum confidence thresholds (cars need lower conf, bottles
///    need higher conf — we'd rather miss a bottle than false-alarm on a wall).
///  • Three priority tiers controlling spatial filter strictness.
///  • A floor-zone mask: only the bottom 70 % of the frame is "walking level".
///    Objects above that are likely distant background.
///  • Area thresholds that scale with tier so we alert earlier on vehicles.
///  • Cross-class NMS via [mergeOverlappingThreats] (called from runner).
/// ──────────────────────────────────────────────────────────────────────────
class ObstacleDetector {
  ObstacleDetector();

  // ── Per-class registry ────────────────────────────────────────────────────
  //
  // Only classes that can realistically obstruct a walking blind person are
  // included. Everything else is silently ignored.
  static const Map<int, _ClassMeta> _registry = {
    // ── Tier 1: moving vehicles and large animals — always critical ────────
    0:  _ClassMeta(minConf: 0.28, distK: 0.87, label: 'person',     tier: 1),
    1:  _ClassMeta(minConf: 0.28, distK: 0.50, label: 'bicycle',    tier: 1),
    2:  _ClassMeta(minConf: 0.22, distK: 0.80, label: 'car',        tier: 1),
    3:  _ClassMeta(minConf: 0.22, distK: 0.45, label: 'motorbike',  tier: 1),
    5:  _ClassMeta(minConf: 0.20, distK: 2.10, label: 'bus',        tier: 1),
    7:  _ClassMeta(minConf: 0.20, distK: 2.10, label: 'truck',      tier: 1),
    16: _ClassMeta(minConf: 0.28, distK: 0.35, label: 'dog',        tier: 1),
    17: _ClassMeta(minConf: 0.25, distK: 1.00, label: 'horse',      tier: 1),
    19: _ClassMeta(minConf: 0.25, distK: 0.90, label: 'cow',        tier: 1),
    20: _ClassMeta(minConf: 0.22, distK: 2.50, label: 'elephant',   tier: 1),
    21: _ClassMeta(minConf: 0.22, distK: 1.20, label: 'bear',       tier: 1),

    // ── Tier 2: static objects at walking height — alert in lower 70 % ────
    9:  _ClassMeta(minConf: 0.30, distK: 0.30, label: 'traffic light', tier: 2),
    10: _ClassMeta(minConf: 0.30, distK: 0.18, label: 'fire hydrant',  tier: 2),
    11: _ClassMeta(minConf: 0.30, distK: 0.20, label: 'stop sign',     tier: 2),
    12: _ClassMeta(minConf: 0.30, distK: 0.15, label: 'parking meter', tier: 2),
    13: _ClassMeta(minConf: 0.28, distK: 0.14, label: 'bench',         tier: 2),
    56: _ClassMeta(minConf: 0.28, distK: 0.15, label: 'chair',         tier: 2),
    57: _ClassMeta(minConf: 0.28, distK: 0.35, label: 'couch',         tier: 2),
    58: _ClassMeta(minConf: 0.30, distK: 0.10, label: 'potted plant',  tier: 2),
    59: _ClassMeta(minConf: 0.28, distK: 0.50, label: 'bed',           tier: 2),
    60: _ClassMeta(minConf: 0.28, distK: 0.25, label: 'table',         tier: 2),
    61: _ClassMeta(minConf: 0.28, distK: 0.25, label: 'toilet',        tier: 2),
    72: _ClassMeta(minConf: 0.25, distK: 0.55, label: 'fridge',        tier: 2),
    28: _ClassMeta(minConf: 0.32, distK: 0.12, label: 'suitcase',      tier: 2),
    24: _ClassMeta(minConf: 0.32, distK: 0.06, label: 'backpack',      tier: 2),

    // ── Tier 3: small or low-priority hazards — only when very close ───────
    39: _ClassMeta(minConf: 0.38, distK: 0.04, label: 'bottle',    tier: 3),
    41: _ClassMeta(minConf: 0.38, distK: 0.03, label: 'cup',       tier: 3),
    73: _ClassMeta(minConf: 0.35, distK: 0.05, label: 'book',      tier: 3),
    75: _ClassMeta(minConf: 0.38, distK: 0.04, label: 'vase',      tier: 3),
  };

  // ── Spatial filter thresholds per tier ───────────────────────────────────
  //
  // minArea: minimum bounding-box area fraction of the total frame.
  //   • Tier 1: 0.010 → object occupies ≥ 1 % of frame (≈ 5 m away for a person)
  //   • Tier 2: 0.015 → needs to be a bit closer before alerting
  //   • Tier 3: 0.040 → only really close objects
  //
  // maxCenterY_upper: objects with centerY below this are in the upper part of
  //   the frame and are likely sky / distant background.
  //   • Tier 1: 0.20 → filter only the very top 20 % (vehicles can be tall)
  //   • Tier 2: 0.30 → top 30 %
  //   • Tier 3: 0.35 → top 35 %
  //
  // Note: these are _minimum_ centerY values — a higher centerY means lower
  // in the frame (closer to the ground), so we REQUIRE centerY ≥ threshold.
  static const _tierMinArea     = [0.010, 0.015, 0.040];
  static const _tierMinCenterY  = [0.20,  0.30,  0.35 ];

  // CenterX gate: we alert for anything in the middle 90 % of the frame
  // horizontally. Only extreme edges (< 0.05 or > 0.95) are ignored because
  // a blind person needs to know about hazards slightly to the side too.
  static const _minCenterX = 0.05;
  static const _maxCenterX = 0.95;

  // ── Public API ────────────────────────────────────────────────────────────

  /// Returns true if any detection qualifies as an in-path obstacle.
  bool isObstacleNear(List<YoloDetection> detections) =>
      mostThreateningObstacle(detections) != null;

  /// Returns the highest-priority in-path obstacle, or null.
  ///
  /// Priority = tier (lower is higher priority), then area (larger = closer).
  YoloDetection? mostThreateningObstacle(List<YoloDetection> detections) {
    YoloDetection? best;
    int bestTier = 999;
    double bestArea = -1;

    for (final d in detections) {
      if (!_isRelevant(d)) continue;
      final meta = _registry[d.classId]!;
      if (!_passesConfidence(d, meta)) continue;
      if (!_passesSpatialFilter(d, meta)) continue;

      final tier = meta.tier;
      final area = d.area;
      if (best == null || tier < bestTier || (tier == bestTier && area > bestArea)) {
        best = d;
        bestTier = tier;
        bestArea = area;
      }
    }
    return best;
  }

  /// Returns all in-path obstacles (for overlay rendering on the debug UI).
  List<YoloDetection> allInPathObstacles(List<YoloDetection> detections) =>
      detections.where((d) {
        if (!_isRelevant(d)) return false;
        final meta = _registry[d.classId]!;
        return _passesConfidence(d, meta) && _passesSpatialFilter(d, meta);
      }).toList();

  /// Human-readable label for this detection (short, suitable for TTS).
  String labelFor(YoloDetection d) =>
      _registry[d.classId]?.label ?? d.className;

  // ── Spatial helpers ───────────────────────────────────────────────────────

  /// Clock-position direction (11, 12, 1 o'clock style) based on centerX.
  ///
  /// Maps the horizontal [0,1] range to a 180° arc from 9 o'clock (far left)
  /// to 3 o'clock (far right), passing through 12 o'clock (straight ahead).
  ///
  ///   centerX → clock hour
  ///   ≤ 0.10  → 9
  ///   0.10–0.25 → 10
  ///   0.25–0.42 → 11
  ///   0.42–0.58 → 12
  ///   0.58–0.75 → 1
  ///   0.75–0.90 → 2
  ///   ≥ 0.90  → 3
  String clockPosition(YoloDetection d) {
    final x = d.centerX;
    if (x <= 0.10) return '9 o\'clock';
    if (x <= 0.25) return '10 o\'clock';
    if (x <= 0.42) return '11 o\'clock';
    if (x <= 0.58) return '12 o\'clock';
    if (x <= 0.75) return '1 o\'clock';
    if (x <= 0.90) return '2 o\'clock';
    return '3 o\'clock';
  }

  /// Simple L/R/ahead direction — used for non-English TTS where clock-position
  /// strings are harder to localise.
  String direction(YoloDetection d) {
    if (d.centerX < 0.35) return 'left';
    if (d.centerX > 0.65) return 'right';
    return 'ahead';
  }

  /// Whether the obstacle is critically close (very large in frame).
  /// Urgent threshold scales by tier: tier-1 objects are urgent earlier.
  bool isUrgent(YoloDetection d) {
    final tier = _registry[d.classId]?.tier ?? 3;
    final threshold = tier == 1 ? 0.10 : tier == 2 ? 0.14 : 0.20;
    return d.area >= threshold;
  }

  /// Proximity level 0–3 for haptic escalation.
  ///   0 = distant  (area < 0.03)
  ///   1 = moderate (area 0.03–0.08)
  ///   2 = close    (area 0.08–0.18)
  ///   3 = imminent (area ≥ 0.18)
  int proximityLevel(YoloDetection d) {
    final a = d.area;
    if (a >= 0.18) return 3;
    if (a >= 0.08) return 2;
    if (a >= 0.03) return 1;
    return 0;
  }

  /// Estimate rough distance in metres using class-aware inverse-square heuristic.
  ///
  /// Model: camera projects an object of real height H onto a fraction f of
  /// the frame height. At distance D:  f ≈ H / (D * tan(vFOV/2) * 2)
  /// Rearranging: D ≈ H / (f * c)  where c is a camera-dependent constant.
  ///
  /// We absorb the camera constant into k = H² (empirically tuned) and use
  /// bounding-box area as a proxy for f²:   D ≈ sqrt(k / area)
  ///
  /// Values are clamped to [0.3, 20.0] metres.
  double estimateDistanceM(YoloDetection d) {
    final k = _registry[d.classId]?.distK ?? 0.18;
    return sqrt(k / d.area).clamp(0.3, 20.0);
  }

  // ── Internal helpers ──────────────────────────────────────────────────────

  bool _isRelevant(YoloDetection d) => _registry.containsKey(d.classId);

  bool _passesConfidence(YoloDetection d, _ClassMeta meta) =>
      d.confidence >= meta.minConf;

  bool _passesSpatialFilter(YoloDetection d, _ClassMeta meta) {
    final idx = meta.tier - 1; // 0-indexed

    // Area gate
    if (d.area < _tierMinArea[idx]) return false;

    // Vertical gate — ignore very-top-of-frame detections
    if (d.centerY < _tierMinCenterY[idx]) return false;

    // Horizontal gate — ignore extreme edge detections
    if (d.centerX < _minCenterX || d.centerX > _maxCenterX) return false;

    return true;
  }
}