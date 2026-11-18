import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Blurs only this surface's backdrop; foreground animation stays isolated.
class AppGlassSurface extends StatelessWidget {
  const AppGlassSurface({
    super.key,
    required this.child,
    required this.backgroundColor,
    this.borderRadius = BorderRadius.zero,
    this.blurSigma = 6,
    this.blendMode = BlendMode.srcOver,
    this.enabled = true,
  }) : assert(blurSigma >= 0 && blurSigma < double.infinity);

  static final Map<double, ui.ImageFilter> _blurFilters =
      <double, ui.ImageFilter>{};

  static ui.ImageFilter _blurFilterFor(double sigma) => _blurFilters
      .putIfAbsent(sigma, () => ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma));

  final Widget child;
  final Color backgroundColor;
  final BorderRadius borderRadius;
  final double blurSigma;
  final BlendMode blendMode;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final opacity = Theme.of(context).brightness == Brightness.dark
        ? 0.84
        : 0.8;
    final content = ColoredBox(
      color: backgroundColor.withValues(
        alpha: backgroundColor.a * (enabled ? opacity : 1),
      ),
      child: RepaintBoundary(child: child),
    );
    return ClipRRect(
      borderRadius: borderRadius,
      child: enabled
          ? BackdropFilter.grouped(
              enabled: backgroundColor.a > 0 && blurSigma > 0,
              blendMode: blendMode,
              filter: _blurFilterFor(blurSigma),
              child: content,
            )
          : content,
    );
  }
}
