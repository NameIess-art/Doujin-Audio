import 'package:flutter/material.dart';

class RjCodeOverlay extends StatelessWidget {
  const RjCodeOverlay({
    super.key,
    required this.rjCode,
    this.maxWidth,
  });

  final String rjCode;
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    final code = rjCode.trim();
    if (code.isEmpty) return const SizedBox.shrink();
    return Container(
      constraints:
          maxWidth != null ? BoxConstraints(maxWidth: maxWidth!) : null,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1.5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        code,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Color(0xFFF8F5F7),
          fontSize: 9,
          fontWeight: FontWeight.w700,
          height: 1.1,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}
