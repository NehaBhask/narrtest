import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:gap/gap.dart';

/// Badge showing live pipeline status with optional pulsing ring.
class PipelineStatusBadge extends StatelessWidget {
  final String label;
  final String sublabel;
  final bool isActive;
  final bool isPulsing;
  final Color color;

  const PipelineStatusBadge({
    super.key,
    required this.label,
    required this.sublabel,
    required this.isActive,
    required this.color,
    this.isPulsing = false,
  });

  @override
  Widget build(BuildContext context) {
    final dot = Container(
      width: 8, height: 8,
      decoration: BoxDecoration(
        color: isActive ? color : Colors.white24,
        shape: BoxShape.circle,
        boxShadow: isActive
            ? [BoxShadow(color: color.withOpacity(0.6), blurRadius: 6, spreadRadius: 1)]
            : null,
      ),
    );

    final badge = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.65),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: isActive ? color.withOpacity(0.5) : Colors.white10),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        isPulsing
            ? dot.animate(onPlay: (c) => c.repeat())
                .scale(begin: const Offset(1, 1), end: const Offset(1.5, 1.5),
                    duration: 700.ms, curve: Curves.easeInOut)
                .then()
                .scale(begin: const Offset(1.5, 1.5), end: const Offset(1, 1), duration: 700.ms)
            : dot,
        const Gap(7),
        Text('$label ', style: TextStyle(
          color: isActive ? color : Colors.white38,
          fontSize: 11, fontWeight: FontWeight.bold)),
        Text(sublabel, style: const TextStyle(color: Colors.white54, fontSize: 11)),
      ]),
    );

    return badge;
  }
}
