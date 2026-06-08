import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:gap/gap.dart';

/// Chat-style bubble for user transcript and AI response.
class ResponseBubble extends StatelessWidget {
  final String text;
  final bool isUser;

  const ResponseBubble({super.key, required this.text, required this.isUser});

  @override
  Widget build(BuildContext context) {
    final userColor = const Color(0xFF6C63FF).withOpacity(0.85);
    final aiColor = Colors.white.withOpacity(0.08);

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.82,
        ),
        margin: EdgeInsets.only(
          left: isUser ? 40 : 0,
          right: isUser ? 0 : 40,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isUser ? userColor : aiColor,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(isUser ? 18 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 18),
          ),
          border: Border.all(
            color: isUser
                ? const Color(0xFF6C63FF).withOpacity(0.4)
                : Colors.white.withOpacity(0.12),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.3),
              blurRadius: 8, offset: const Offset(0, 3)),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(
                isUser ? Icons.person_outline : Icons.auto_awesome,
                size: 12,
                color: isUser ? Colors.white70 : const Color(0xFF00D4AA),
              ),
              const Gap(5),
              Text(
                isUser ? 'You' : 'Narrator',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: isUser ? Colors.white70 : const Color(0xFF00D4AA),
                  letterSpacing: 0.5,
                ),
              ),
            ]),
            const Gap(5),
            Text(
              text,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
