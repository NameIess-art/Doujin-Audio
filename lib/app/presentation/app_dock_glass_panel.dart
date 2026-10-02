import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../features/settings/presentation/settings_providers.dart';

class AppDockGlassPanel extends ConsumerWidget {
  const AppDockGlassPanel({
    super.key,
    required this.child,
    this.shadowOpacity = 0.22,
    this.showTopHighlight = true,
    this.tinyMode = false,
  });

  final Widget child;
  final double radius = 100;
  final double shadowOpacity;
  final bool showTopHighlight;
  final bool tinyMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? cs.surfaceContainer : cs.surfaceContainerHigh;
    final blurEnabled = ref.watch(
      settingsStateProvider.select((s) => s.value?.uiBlurEffectEnabled ?? false),
    );

    Widget buildPanel(bool useBlur) => DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        color: bgColor.withValues(
          alpha: useBlur ? (isDark ? 0.72 : 0.78) : 1.0,
        ),
        border: Border.all(
          color: cs.outlineVariant.withValues(alpha: isDark ? 0.24 : 0.42),
        ),
        boxShadow: tinyMode
            ? null
            : [
                BoxShadow(
                  color: cs.shadow.withValues(alpha: shadowOpacity * 0.68),
                  blurRadius: 28,
                  spreadRadius: -6,
                  offset: const Offset(0, 14),
                ),
                BoxShadow(
                  color: cs.primary.withValues(alpha: isDark ? 0.05 : 0.035),
                  blurRadius: 14,
                  spreadRadius: -10,
                  offset: const Offset(0, 8),
                ),
              ],
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
          RepaintBoundary(child: child),
        ],
      ),
    );

    final useBlur = blurEnabled;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: useBlur
          ? BackdropFilter(
              key: const ValueKey('floating_glass_panel_blur'),
              filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
              child: buildPanel(useBlur),
            )
          : buildPanel(useBlur),
    );
  }
}
