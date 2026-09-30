import 'package:flutter/material.dart';

class PushPinOffIcon extends StatelessWidget {
  const PushPinOffIcon({super.key});

  @override
  Widget build(BuildContext context) {
    final iconTheme = IconTheme.of(context);
    final effectiveSize = iconTheme.size ?? 22.0;
    final effectiveColor =
        iconTheme.color ?? Theme.of(context).colorScheme.onSurface;

    return RepaintBoundary(
      child: SizedBox(
        width: effectiveSize,
        height: effectiveSize,
        child: CustomPaint(
          painter: PushPinOffPainter(
            iconColor: effectiveColor,
            size: effectiveSize,
          ),
        ),
      ),
    );
  }
}

class PushPinOffPainter extends CustomPainter {
  const PushPinOffPainter({required this.iconColor, required this.size});

  final Color iconColor;
  final double size;

  @override
  void paint(Canvas canvas, Size canvasSize) {
    final rect = Offset.zero & canvasSize;
    canvas.saveLayer(rect, Paint());

    final textPainter = TextPainter(
      textDirection: TextDirection.ltr,
      text: TextSpan(
        text: String.fromCharCode(Icons.push_pin_rounded.codePoint),
        style: TextStyle(
          fontSize: size,
          fontFamily: Icons.push_pin_rounded.fontFamily,
          package: Icons.push_pin_rounded.fontPackage,
          color: iconColor,
        ),
      ),
    )..layout();

    final textOffset = Offset(
      (canvasSize.width - textPainter.width) / 2,
      (canvasSize.height - textPainter.height) / 2,
    );
    textPainter.paint(canvas, textOffset);

    final scale = size / 24.0;
    final p1 = Offset(3.5 * scale, 3.5 * scale);
    final p2 = Offset(20.5 * scale, 20.5 * scale);

    final clearPaint = Paint()
      ..blendMode = BlendMode.clear
      ..strokeWidth = 3.2 * scale
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    canvas.drawLine(p1, p2, clearPaint);

    final linePaint = Paint()
      ..color = iconColor
      ..strokeWidth = 1.8 * scale
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    canvas.drawLine(p1, p2, linePaint);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant PushPinOffPainter oldDelegate) {
    return oldDelegate.iconColor != iconColor || oldDelegate.size != size;
  }
}
