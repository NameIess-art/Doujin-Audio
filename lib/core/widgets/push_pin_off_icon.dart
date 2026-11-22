import 'dart:collection';
import 'dart:math' as math;

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

  static const int _maxCachedPainters = 12;
  static final LinkedHashMap<(double, int), TextPainter> _painterCache =
      LinkedHashMap<(double, int), TextPainter>();

  // Inverse clip path in 24x24 coordinates that masks out the 3.2-unit-wide
  // diagonal slash gap without requiring canvas.saveLayer + BlendMode.clear.
  static final Path _glyphClipPath = () {
    const radius = 1.6;
    const halfLength = 17.0 * math.sqrt2 / 2.0;
    final transform = (Matrix4.identity()
      ..translateByDouble(12.0, 12.0, 0.0, 1.0)
      ..rotateZ(math.pi / 4.0)).storage;
    final slashGap = (Path()
          ..addRRect(
            RRect.fromRectAndRadius(
              const Rect.fromLTRB(
                -halfLength - radius,
                -radius,
                halfLength + radius,
                radius,
              ),
              const Radius.circular(radius),
            ),
          ))
        .transform(transform);
    return Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(const Rect.fromLTWH(-4, -4, 32, 32))
      ..addPath(slashGap, Offset.zero);
  }();

  static TextPainter _cachedTextPainter(double size, Color color) {
    final key = (size, color.toARGB32());
    final existing = _painterCache.remove(key);
    if (existing != null) {
      _painterCache[key] = existing;
      return existing;
    }
    final painter = TextPainter(
      textDirection: TextDirection.ltr,
      text: TextSpan(
        text: String.fromCharCode(Icons.push_pin_rounded.codePoint),
        style: TextStyle(
          fontSize: size,
          fontFamily: Icons.push_pin_rounded.fontFamily,
          package: Icons.push_pin_rounded.fontPackage,
          color: color,
        ),
      ),
    )..layout();
    _painterCache[key] = painter;
    while (_painterCache.length > _maxCachedPainters) {
      _painterCache.remove(_painterCache.keys.first)?.dispose();
    }
    return painter;
  }

  @override
  void paint(Canvas canvas, Size canvasSize) {
    if (size <= 0 || canvasSize.isEmpty) return;
    final scale = size / 24.0;
    final textPainter = _cachedTextPainter(size, iconColor);
    final textOffset = Offset(
      (canvasSize.width - textPainter.width) / 2,
      (canvasSize.height - textPainter.height) / 2,
    );

    canvas.save();
    canvas.scale(scale, scale);
    canvas.clipPath(_glyphClipPath);
    canvas.scale(1 / scale, 1 / scale);
    textPainter.paint(canvas, textOffset);
    canvas.restore();

    final p1 = Offset(3.5 * scale, 3.5 * scale);
    final p2 = Offset(20.5 * scale, 20.5 * scale);
    final linePaint = Paint()
      ..color = iconColor
      ..strokeWidth = 1.8 * scale
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    canvas.drawLine(p1, p2, linePaint);
  }

  @override
  bool shouldRepaint(covariant PushPinOffPainter oldDelegate) {
    return oldDelegate.iconColor != iconColor || oldDelegate.size != size;
  }
}
