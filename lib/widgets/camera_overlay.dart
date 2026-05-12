import 'package:flutter/material.dart';
import '../pipelines/pipeline1/yolo_ncnn_runner.dart';

/// Draws bounding boxes over camera preview for detected obstacles.
class CameraOverlay extends StatelessWidget {
  final List<YoloDetection> detections;
  final Size imageSize;

  const CameraOverlay({
    super.key,
    required this.detections,
    required this.imageSize,
  });

  static const _obstacleColor = Color(0xFFFF6B6B);
  static const _safeColor = Color(0xFF00D4AA);

  @override
  Widget build(BuildContext context) {
    if (detections.isEmpty) return const SizedBox.shrink();
    return CustomPaint(
      painter: _BBoxPainter(detections: detections),
      child: const SizedBox.expand(),
    );
  }
}

class _BBoxPainter extends CustomPainter {
  final List<YoloDetection> detections;
  _BBoxPainter({required this.detections});

  @override
  void paint(Canvas canvas, Size size) {
    for (final det in detections) {
      // Skip tiny ghost boxes (< 5% of frame)
      if (det.area < 0.05) continue;

      final isClose = det.area > 0.12;
      final color = isClose ? const Color(0xFFFF6B6B) : const Color(0xFF6C63FF);

      final boxPaint = Paint()
        ..color = color.withOpacity(0.6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;

      final fillPaint = Paint()
        ..color = color.withOpacity(0.08)
        ..style = PaintingStyle.fill;

      final rect = Rect.fromLTRB(
        det.x1 * size.width,
        det.y1 * size.height,
        det.x2 * size.width,
        det.y2 * size.height,
      );

      canvas.drawRect(rect, fillPaint);
      canvas.drawRect(rect, boxPaint);

      // Corner accents
      _drawCornerAccents(canvas, rect, color, isClose ? 3.0 : 2.0);

      // Label: real class name + confidence, with warning prefix if close
      final prefix = isClose ? '⚠ ' : '';
      final label  = '$prefix${det.className}';
      final conf   = '${(det.confidence * 100).toInt()}%';
      _drawLabel(canvas, rect, '$label $conf', color);
    }
  }

  void _drawCornerAccents(Canvas canvas, Rect rect, Color color, double w) {
    final p = Paint()..color = color..strokeWidth = w..style = PaintingStyle.stroke;
    const len = 14.0;
    // TL
    canvas.drawLine(rect.topLeft, rect.topLeft.translate(len, 0), p);
    canvas.drawLine(rect.topLeft, rect.topLeft.translate(0, len), p);
    // TR
    canvas.drawLine(rect.topRight, rect.topRight.translate(-len, 0), p);
    canvas.drawLine(rect.topRight, rect.topRight.translate(0, len), p);
    // BL
    canvas.drawLine(rect.bottomLeft, rect.bottomLeft.translate(len, 0), p);
    canvas.drawLine(rect.bottomLeft, rect.bottomLeft.translate(0, -len), p);
    // BR
    canvas.drawLine(rect.bottomRight, rect.bottomRight.translate(-len, 0), p);
    canvas.drawLine(rect.bottomRight, rect.bottomRight.translate(0, -len), p);
  }

  void _drawLabel(Canvas canvas, Rect rect, String text, Color color) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.bold,
          background: Paint()..color = color.withOpacity(0.8),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(rect.left + 4, rect.top + 4));
  }

  @override
  bool shouldRepaint(_BBoxPainter old) => old.detections != detections;
}
