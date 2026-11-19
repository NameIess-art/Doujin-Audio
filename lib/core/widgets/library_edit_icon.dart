import 'package:flutter/material.dart';

/// Custom vector icon for editing the local library, pairing the stacked
/// library silhouette of `Icons.library_music_rounded` with a knocked-out
/// pencil glyph.
class LibraryEditIcon extends StatelessWidget {
  const LibraryEditIcon({
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
          painter: LibraryEditIconPainter(color: effectiveColor),
        ),
      ),
    );
  }
}

class LibraryEditIconPainter extends CustomPainter {
  const LibraryEditIconPainter({required this.color});

  final Color color;

  static final Path _stackPath = Path()
    ..moveTo(3.0, 6.6)
    ..lineTo(3.0, 19.0)
    ..quadraticBezierTo(3.0, 21.0, 5.0, 21.0)
    ..lineTo(17.2, 21.0);

  static final Path _pencilPath = Path()
    ..moveTo(-5.0, 0.0)
    ..lineTo(-2.3, -1.55)
    ..lineTo(3.3, -1.55)
    ..quadraticBezierTo(4.3, -1.55, 4.3, -0.55)
    ..lineTo(4.3, 0.55)
    ..quadraticBezierTo(4.3, 1.55, 3.3, 1.55)
    ..lineTo(-2.3, 1.55)
    ..close();

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.shortestSide;
    final scale = side / 24.0;
    final dx = (size.width - side) / 2.0;
    final dy = (size.height - side) / 2.0;

    canvas.save();
    canvas.translate(dx, dy);
    canvas.scale(scale, scale);

    final fillPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    final stackPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.9
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    canvas.drawPath(_stackPath, stackPaint);

    final clearPaint = Paint()
      ..blendMode = BlendMode.clear
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    canvas.saveLayer(const Rect.fromLTWH(0, 0, 24, 24), Paint());
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTRB(6.6, 2.4, 21.6, 17.4),
        const Radius.circular(2.3),
      ),
      fillPaint,
    );

    canvas.save();
    canvas.translate(14.1, 9.9);
    canvas.rotate(-0.78539816339);
    canvas.drawPath(_pencilPath, clearPaint);
    // Keep a crisp collar divider matching Material's pencil silhouette.
    canvas.drawRect(const Rect.fromLTRB(1.8, -1.65, 2.55, 1.65), fillPaint);
    canvas.restore();
    canvas.restore();

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant LibraryEditIconPainter oldDelegate) =>
      oldDelegate.color != color;
}
