import 'package:flutter/material.dart';

enum AppEdgeFadeDirection { towardTop, towardBottom }

class AppEdgeFadeMask extends StatelessWidget {
  const AppEdgeFadeMask({super.key, required this.direction, this.color});

  final AppEdgeFadeDirection direction;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final baseColor = color ?? theme.colorScheme.surface;
    final isDark = theme.brightness == Brightness.dark;
    final towardBottom = direction == AppEdgeFadeDirection.towardBottom;
    final peakAlpha = isDark ? 0.86 : 0.82;
    final midHighAlpha = isDark ? 0.76 : 0.70;
    final lowAlpha = isDark ? 0.28 : 0.22;
    final colors = towardBottom
        ? <Color>[
            baseColor.withValues(alpha: 0),
            baseColor.withValues(alpha: lowAlpha),
            baseColor.withValues(alpha: midHighAlpha),
            baseColor.withValues(alpha: peakAlpha),
            baseColor.withValues(alpha: peakAlpha),
          ]
        : <Color>[
            baseColor.withValues(alpha: peakAlpha),
            baseColor.withValues(alpha: peakAlpha),
            baseColor.withValues(alpha: midHighAlpha),
            baseColor.withValues(alpha: lowAlpha),
            baseColor.withValues(alpha: 0),
          ];

    final stops = towardBottom
        ? const <double>[0.0, 0.18, 0.42, 0.65, 1.0]
        : const <double>[0.0, 0.35, 0.58, 0.82, 1.0];

    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: colors,
            stops: stops,
          ),
        ),
      ),
    );
  }
}
