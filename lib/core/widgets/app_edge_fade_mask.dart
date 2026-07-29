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
    final bottomColors = <Color>[
      baseColor.withValues(alpha: 0),
      baseColor.withValues(alpha: isDark ? 0.12 : 0.08),
      baseColor.withValues(alpha: isDark ? 0.50 : 0.38),
      baseColor.withValues(alpha: isDark ? 0.90 : 0.82),
    ];
    final towardBottom = direction == AppEdgeFadeDirection.towardBottom;
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: towardBottom
                ? bottomColors
                : bottomColors.reversed.toList(growable: false),
            stops: towardBottom
                ? const <double>[0, 0.28, 0.68, 1]
                : const <double>[0, 0.32, 0.72, 1],
          ),
        ),
      ),
    );
  }
}
