import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Blurs only this surface's backdrop; foreground animation stays isolated.
class AppGlassSurface extends StatelessWidget {
  const AppGlassSurface({
    super.key,
    required this.child,
    required this.backgroundColor,
    this.borderRadius = BorderRadius.zero,
    this.blurSigma = 16,
    this.blurProgress = 1,
    this.blendMode = BlendMode.srcOver,
    this.enabled = true,
  }) : assert(blurSigma >= 0 && blurSigma < double.infinity),
       assert(blurProgress >= 0 && blurProgress <= 1);

  static const double darkGlassOpacity = 0.68;
  static const double lightGlassOpacity = 0.66;

  static final Map<double, ui.ImageFilter> _blurFilters =
      <double, ui.ImageFilter>{};

  static ui.ImageFilter _blurFilterFor(double sigma) => _blurFilters
      .putIfAbsent(sigma, () => ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma));

  final Widget child;
  final Color backgroundColor;
  final BorderRadius borderRadius;
  final double blurSigma;
  final double blurProgress;
  final BlendMode blendMode;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final opacity = Theme.of(context).brightness == Brightness.dark
        ? darkGlassOpacity
        : lightGlassOpacity;
    final sigma = blurSigma * blurProgress;
    final content = ColoredBox(
      color: backgroundColor.withValues(
        alpha: backgroundColor.a * (enabled ? opacity : 1),
      ),
      child: RepaintBoundary(child: child),
    );
    final surface = ClipRRect(
      borderRadius: borderRadius,
      child: enabled
          ? BackdropFilter.grouped(
              enabled: backgroundColor.a > 0 && sigma > 0,
              blendMode: blendMode,
              // Keep transient animation frames out of the filter cache.
              filter: blurProgress == 1
                  ? _blurFilterFor(blurSigma)
                  : ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
              child: content,
            )
          : content,
    );
    // Keep the clip and filter in the layer tree when a scrolling backdrop
    // repaints. The engine still samples the current pixels behind the glass.
    return enabled ? RepaintBoundary(child: surface) : surface;
  }
}
