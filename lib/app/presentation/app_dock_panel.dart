import 'package:flutter/material.dart';

import '../../core/widgets/app_glass_surface.dart';
import '../theme/app_design_tokens.dart';

class AppDockPanel extends StatelessWidget {
  const AppDockPanel({
    super.key,
    required this.child,
    this.showTopHighlight = true,
    this.tinyMode = false,
  });

  final Widget child;
  final double radius = 100;
  final bool showTopHighlight;
  final bool tinyMode;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? cs.surfaceContainer : cs.surfaceContainerHigh;
    final glassEnabled = AppDesignTokens.of(context).barGlassEnabled;
    return AppGlassSurface(
      enabled: glassEnabled,
      borderRadius: BorderRadius.circular(radius),
      backgroundColor: glassEnabled
          ? bgColor.withValues(alpha: bgColor.a * 0.9)
          : bgColor,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(
            color: cs.outlineVariant.withValues(alpha: isDark ? 0.24 : 0.42),
          ),
        ),
        child: Stack(
          children: [
            if (showTopHighlight && !tinyMode)
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(radius),
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.white.withValues(alpha: isDark ? 0.18 : 0.45),
                          Colors.white.withValues(alpha: 0),
                        ],
                        stops: const [0, 0.15],
                      ),
                    ),
                  ),
                ),
              ),
            child,
          ],
        ),
      ),
    );
  }
}
