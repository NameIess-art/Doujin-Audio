import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Marks subtrees whose backdrop is already blurred by an outer modal layer
/// so inner glass cards keep their frosted tint without nesting [BackdropFilter].
class AppGlassBackdropScope extends InheritedWidget {
  const AppGlassBackdropScope({
    super.key,
    required this.backdropBlurred,
    required super.child,
  });

  final bool backdropBlurred;

  static bool isBackdropBlurredOf(BuildContext context) {
    return context
            .dependOnInheritedWidgetOfExactType<AppGlassBackdropScope>()
            ?.backdropBlurred ??
        false;
  }

  @override
  bool updateShouldNotify(AppGlassBackdropScope oldWidget) =>
      backdropBlurred != oldWidget.backdropBlurred;
}

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
  static const int _fadeSteps = 16;

  static final Map<double, ui.ImageFilter> _blurFilters =
      <double, ui.ImageFilter>{};
  static final Map<double, List<ui.ImageFilter>> _fadeFilters =
      <double, List<ui.ImageFilter>>{};

  static ui.ImageFilter _blurFilterFor(double sigma, double progress) {
    final base = _blurFilters.putIfAbsent(
      sigma,
      () => ui.ImageFilter.blur(
        sigmaX: sigma,
        sigmaY: sigma,
        tileMode: ui.TileMode.clamp,
      ),
    );
    if (progress >= 1) return base;
    final step = (_fadeSteps * progress).round().clamp(1, _fadeSteps);
    if (step >= _fadeSteps) return base;
    final steps = _fadeFilters.putIfAbsent(sigma, () {
      return List<ui.ImageFilter>.generate(_fadeSteps - 1, (index) {
        final alpha = (index + 1) / _fadeSteps;
        return ui.ImageFilter.compose(
          outer: ui.ColorFilter.matrix(<double>[
            1, 0, 0, 0, 0,
            0, 1, 0, 0, 0,
            0, 0, 1, 0, 0,
            0, 0, 0, alpha, 0,
          ]),
          inner: base,
        );
      }, growable: false);
    });
    return steps[step - 1];
  }

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
    final applyBlur =
        enabled && !AppGlassBackdropScope.isBackdropBlurredOf(context);
    final content = ColoredBox(
      color: backgroundColor.withValues(
        alpha: backgroundColor.a * (enabled ? opacity : 1),
      ),
      child: RepaintBoundary(child: child),
    );
    final surface = ClipRRect(
      borderRadius: borderRadius,
      child: applyBlur
          ? BackdropFilter.grouped(
              enabled:
                  backgroundColor.a > 0 && blurSigma > 0 && blurProgress > 0,
              blendMode: blendMode,
              // Reuse the static blur kernel with cached alpha steps instead of
              // allocating a new ImageFilter.blur on every animation frame.
              filter: _blurFilterFor(blurSigma, blurProgress),
              child: content,
            )
          : content,
    );
    // Keep the clip and filter in the layer tree when a scrolling backdrop
    // repaints. The engine still samples the current pixels behind the glass.
    return applyBlur ? RepaintBoundary(child: surface) : surface;
  }
}
