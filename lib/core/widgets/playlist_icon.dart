import 'package:flutter/material.dart';

enum PlaylistIconVariant { play, add }

/// Custom vector icon for the playlist destination and add-to-playlist actions,
/// transitioning between an outlined card and a solid filled card.
class PlaylistIcon extends StatelessWidget {
  const PlaylistIcon({
    super.key,
    this.filled = true,
    this.size,
    this.color,
  }) : variant = PlaylistIconVariant.play;

  const PlaylistIcon.add({
    super.key,
    this.filled = true,
    this.size,
    this.color,
  }) : variant = PlaylistIconVariant.add;

  final PlaylistIconVariant variant;
  final bool filled;
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
          painter: PlaylistIconPainter(
            filled: filled,
            color: effectiveColor,
            variant: variant,
          ),
        ),
      ),
    );
  }
}

class PlaylistIconPainter extends CustomPainter {
  const PlaylistIconPainter({
    required this.filled,
    required this.color,
    this.variant = PlaylistIconVariant.play,
  });

  final bool filled;
  final Color color;
  final PlaylistIconVariant variant;

  static Path _roundedTrianglePath(
    Offset a,
    Offset b,
    Offset c,
    double radius,
  ) {
    final points = [a, b, c];
    final path = Path();
    for (var i = 0; i < 3; i++) {
      final prev = points[(i + 2) % 3];
      final curr = points[i];
      final next = points[(i + 1) % 3];

      final v1 = prev - curr;
      final v2 = next - curr;
      final len1 = v1.distance;
      final len2 = v2.distance;
      final r1 = radius.clamp(0.0, len1 * 0.4);
      final r2 = radius.clamp(0.0, len2 * 0.4);

      final p1 = curr + (v1 / len1) * r1;
      final p2 = curr + (v2 / len2) * r2;

      if (i == 0) {
        path.moveTo(p1.dx, p1.dy);
      } else {
        path.lineTo(p1.dx, p1.dy);
      }
      path.quadraticBezierTo(curr.dx, curr.dy, p2.dx, p2.dy);
    }
    path.close();
    return path;
  }

  static final Path _playTrianglePath = _roundedTrianglePath(
    const Offset(6.3, 8.6),
    const Offset(11.1, 12.0),
    const Offset(6.3, 15.4),
    0.7,
  );

  static const Offset _plusCenter = Offset(8.6, 12.0);
  static const double _plusHalf = 2.45;
  static const _barXs = (12.9, 17.9);
  static const _barYs = [8.6, 12.0, 15.4];
  static const double _filledCutoutRadius = 1.75 / 2;

  static final RRect _filledCardRRect = RRect.fromRectAndRadius(
    const Rect.fromLTRB(1.8, 3.2, 22.2, 20.8),
    const Radius.circular(3.5),
  );

  static Path _buildFilledPath(Path leftCutout) {
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRRect(_filledCardRRect)
      ..addPath(leftCutout, Offset.zero);
    for (final y in _barYs) {
      path.addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(
            _barXs.$1 - _filledCutoutRadius,
            y - _filledCutoutRadius,
            _barXs.$2 + _filledCutoutRadius,
            y + _filledCutoutRadius,
          ),
          const Radius.circular(_filledCutoutRadius),
        ),
      );
    }
    return path;
  }

  static final Path _filledPlayPath = _buildFilledPath(_playTrianglePath);

  static final Path _filledAddPath = _buildFilledPath(
    Path.combine(
      PathOperation.union,
      Path()..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(
            _plusCenter.dx - _plusHalf - _filledCutoutRadius,
            _plusCenter.dy - _filledCutoutRadius,
            _plusCenter.dx + _plusHalf + _filledCutoutRadius,
            _plusCenter.dy + _filledCutoutRadius,
          ),
          const Radius.circular(_filledCutoutRadius),
        ),
      ),
      Path()..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(
            _plusCenter.dx - _filledCutoutRadius,
            _plusCenter.dy - _plusHalf - _filledCutoutRadius,
            _plusCenter.dx + _filledCutoutRadius,
            _plusCenter.dy + _plusHalf + _filledCutoutRadius,
          ),
          const Radius.circular(_filledCutoutRadius),
        ),
      ),
    ),
  );

  void _paintLeftGlyph(
    Canvas canvas, {
    required Paint fillPaint,
    required Paint strokePaint,
  }) {
    switch (variant) {
      case PlaylistIconVariant.play:
        canvas.drawPath(_playTrianglePath, fillPaint);
      case PlaylistIconVariant.add:
        canvas.drawLine(
          Offset(_plusCenter.dx - _plusHalf, _plusCenter.dy),
          Offset(_plusCenter.dx + _plusHalf, _plusCenter.dy),
          strokePaint,
        );
        canvas.drawLine(
          Offset(_plusCenter.dx, _plusCenter.dy - _plusHalf),
          Offset(_plusCenter.dx, _plusCenter.dy + _plusHalf),
          strokePaint,
        );
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.shortestSide;
    final scale = side / 24.0;
    final dx = (size.width - side) / 2.0;
    final dy = (size.height - side) / 2.0;

    canvas.save();
    canvas.translate(dx, dy);
    canvas.scale(scale, scale);
    // Optical normalization inside the 24x24 viewBox to match neighboring nav icons.
    canvas.translate(12.0, 12.0);
    canvas.scale(1.04, 1.04);
    canvas.translate(-12.0, -12.0);

    final fillPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    if (!filled) {
      final strokePaint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.65
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true;

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTRB(2.6, 4.0, 21.4, 20.0),
          const Radius.circular(3.0),
        ),
        strokePaint,
      );
      _paintLeftGlyph(canvas, fillPaint: fillPaint, strokePaint: strokePaint);
      for (final y in _barYs) {
        canvas.drawLine(Offset(_barXs.$1, y), Offset(_barXs.$2, y), strokePaint);
      }
    } else {
      canvas.drawPath(
        variant == PlaylistIconVariant.play ? _filledPlayPath : _filledAddPath,
        fillPaint,
      );
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant PlaylistIconPainter oldDelegate) =>
      oldDelegate.filled != filled ||
      oldDelegate.color != color ||
      oldDelegate.variant != variant;
}
