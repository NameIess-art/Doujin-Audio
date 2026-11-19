import 'package:flutter/material.dart';

/// Bolder rounded plus icon keeping the exact `14x14` outer bounds (`5..19`
/// in a `24x24` viewBox) of `Icons.add_rounded`.
class BoldAddIcon extends StatelessWidget {
  const BoldAddIcon({
    super.key,
    this.size,
    this.color,
  });

  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final iconTheme = IconTheme.of(context);
    final effectiveSize = size ?? iconTheme.size ?? 24.0;
    final effectiveColor =
        color ?? iconTheme.color ?? Theme.of(context).colorScheme.onSurface;

    return RepaintBoundary(
      child: SizedBox.square(
        dimension: effectiveSize,
        child: CustomPaint(
          painter: BoldAddIconPainter(color: effectiveColor),
        ),
      ),
    );
  }
}

class BoldAddIconPainter extends CustomPainter {
  const BoldAddIconPainter({required this.color});

  final Color color;

  static const double _inset = 6.4;
  static const double _strokeWidth = 2.8;

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.shortestSide;
    final scale = side / 24.0;
    final dx = (size.width - side) / 2.0;
    final dy = (size.height - side) / 2.0;

    canvas.save();
    canvas.translate(dx, dy);
    canvas.scale(scale, scale);

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = _strokeWidth
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;

    canvas.drawLine(
      const Offset(12.0, _inset),
      const Offset(12.0, 24.0 - _inset),
      paint,
    );
    canvas.drawLine(
      const Offset(_inset, 12.0),
      const Offset(24.0 - _inset, 12.0),
      paint,
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant BoldAddIconPainter oldDelegate) =>
      oldDelegate.color != color;
}
