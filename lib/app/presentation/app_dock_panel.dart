import 'package:flutter/material.dart';

import '../../core/widgets/app_glass_surface.dart';
import '../theme/app_design_tokens.dart';
import '../theme/app_styles.dart';

class AppDockPanel extends StatelessWidget {
  const AppDockPanel({
    super.key,
    required this.child,
    this.showTopHighlight = true,
    this.tinyMode = false,
    this.radius = AppRadius.pill,
  });

  final Widget child;
  final double radius;
  final bool showTopHighlight;
  final bool tinyMode;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final tokens = AppDesignTokens.of(context);
    final bgColor = cs.surfaceContainerHigh;
    final glassEnabled = tokens.barGlassEnabled;
    final borderColor = appOverlayBorderColor(cs, tokens, elevated: true);
    return AppGlassSurface(
      enabled: glassEnabled,
      borderRadius: BorderRadius.circular(radius),
      backgroundColor: bgColor,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: borderColor),
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
                          Colors.white.withValues(alpha: isDark ? 0.12 : 0.38),
                          Colors.white.withValues(alpha: 0),
                        ],
                        stops: const [0, 0.08],
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
