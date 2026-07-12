import 'package:flutter/material.dart';

import '../services/time_text_formatters.dart';

class DurationOverlay extends StatelessWidget {
  const DurationOverlay({super.key, required this.duration});

  final Duration duration;

  @override
  Widget build(BuildContext context) {
    if (duration <= Duration.zero) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        formatDurationCompact(duration),
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w600,
          height: 1.1,
        ),
      ),
    );
  }
}
