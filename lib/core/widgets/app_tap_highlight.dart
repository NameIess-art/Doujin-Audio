import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

const kAppQuickTapFeedback = Duration(milliseconds: 60);

class AppTapHighlightFactory extends InteractiveInkFeatureFactory {
  const AppTapHighlightFactory({
    this.showQuickTap = false,
    this.animate = true,
    this.animateRipple = true,
  });

  static const _standard = AppTapHighlightFactory();
  static const _android = AppTapHighlightFactory(showQuickTap: true);
  static const _reduced = AppTapHighlightFactory(animate: false);
  static const _reducedAndroid = AppTapHighlightFactory(
    showQuickTap: true,
    animate: false,
  );
  static const _flatAndroid = AppTapHighlightFactory(
    showQuickTap: true,
    animateRipple: false,
  );

  static AppTapHighlightFactory forPlatform(
    TargetPlatform platform, {
    bool animate = true,
    bool animateRipple = true,
  }) {
    if (!animateRipple) {
      return platform == TargetPlatform.android ? _flatAndroid : _standard;
    }
    if (!animate) {
      return platform == TargetPlatform.android ? _reducedAndroid : _reduced;
    }
    return platform == TargetPlatform.android ? _android : _standard;
  }

  final bool showQuickTap;
  final bool animate;
  final bool animateRipple;

  @override
  InteractiveInkFeature create({
    required MaterialInkController controller,
    required RenderBox referenceBox,
    required Offset position,
    required Color color,
    required TextDirection textDirection,
    bool containedInkWell = false,
    RectCallback? rectCallback,
    BorderRadius? borderRadius,
    ShapeBorder? customBorder,
    double? radius,
    VoidCallback? onRemoved,
  }) {
    final reduceMotion =
        !animate ||
        SchedulerBinding
            .instance
            .platformDispatcher
            .accessibilityFeatures
            .disableAnimations;
    return _EntrySplash(
      controller: controller,
      referenceBox: referenceBox,
      position: position,
      color: color,
      textDirection: textDirection,
      bounds: rectCallback ?? (() => Offset.zero & referenceBox.size),
      borderRadius: borderRadius ?? BorderRadius.zero,
      customBorder: customBorder,
      radius: radius,
      onRemoved: onRemoved,
      showQuickTap: showQuickTap,
      animateRipple: animateRipple && !reduceMotion,
    );
  }
}

class _EntrySplash extends InteractiveInkFeature {
  _EntrySplash({
    required super.controller,
    required super.referenceBox,
    required this.position,
    required super.color,
    required this.textDirection,
    required this.bounds,
    required this.borderRadius,
    required this.radius,
    required this.showQuickTap,
    required this.animateRipple,
    super.customBorder,
    super.onRemoved,
  }) {
    if (animateRipple) {
      _expandController =
          AnimationController(vsync: controller.vsync, duration: _expandDuration)
            ..addListener(_handleTick)
            ..forward();
    }
    controller.addInkFeature(this);
  }

  final Offset position;
  final TextDirection textDirection;
  final RectCallback bounds;
  final BorderRadius borderRadius;
  final double? radius;
  final bool showQuickTap;
  final bool animateRipple;

  bool _painted = false;
  bool _confirming = false;
  bool _disposed = false;
  double _confirmStartExpand = 0.0;
  bool _quickTapConfirm = false;
  AnimationController? _expandController;
  AnimationController? _fadeController;
  Timer? _release;

  Duration get _expandDuration => Duration(
    milliseconds: showQuickTap ? 190 : 145,
  );

  void _handleTick() {
    if (_disposed) return;
    controller.markNeedsPaint();
  }

  void _handleFadeStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      dispose();
    }
  }

  double _currentExpandProgress() {
    if (!animateRipple) return 1.0;
    if (!_confirming) {
      return _expandController?.value ?? 1.0;
    }
    final fadeT = _fadeController?.value ?? 1.0;
    if (!_quickTapConfirm) {
      return ui.lerpDouble(
            _confirmStartExpand,
            1.0,
            (fadeT / 0.65).clamp(0.0, 1.0),
          ) ??
          1.0;
    }
    return ui.lerpDouble(
          _confirmStartExpand,
          1.0,
          (fadeT / 0.72).clamp(0.0, 1.0),
        ) ??
        1.0;
  }

  double _fadeOpacity() {
    if (!_confirming) return 1.0;
    final fadeT = _fadeController?.value ?? 0.0;
    if (_quickTapConfirm) {
      const holdPortion = 0.24;
      if (fadeT <= holdPortion) return 1.0;
      final normalized = ((fadeT - holdPortion) / (1.0 - holdPortion)).clamp(
        0.0,
        1.0,
      );
      return 1.0 - Curves.easeOut.transform(normalized);
    }
    return 1.0 - Curves.easeOut.transform(fadeT.clamp(0.0, 1.0));
  }

  @override
  void paintFeature(Canvas canvas, Matrix4 transform) {
    if (_disposed) return;
    _painted = true;
    final rect = bounds();
    if (rect.isEmpty || color.a <= 0) return;

    final fadeAlpha = _fadeOpacity();
    if (fadeAlpha <= 0) return;

    canvas.save();
    canvas.transform(transform.storage);
    final shape = customBorder;
    if (shape != null) {
      canvas.clipPath(shape.getOuterPath(rect, textDirection: textDirection));
    } else if (borderRadius != BorderRadius.zero) {
      canvas.clipRRect(borderRadius.toRRect(rect));
    } else {
      canvas.clipRect(rect);
    }

    if (!animateRipple) {
      canvas.drawRect(rect, Paint()..color = color);
      canvas.restore();
      return;
    }

    final expandProgress = _currentExpandProgress();
    final easedExpand = Curves.easeOutCubic.transform(expandProgress);
    final ambientRamp = _confirming
        ? 1.0
        : Curves.easeOut.transform(
            (expandProgress * (_expandDuration.inMilliseconds / 45.0))
                .clamp(0.0, 1.0),
          );

    // Subtle full-row ambient tint grounds the expanding wave under the touch.
    final ambientAlpha = color.a * 0.34 * ambientRamp * fadeAlpha;
    if (ambientAlpha > 0) {
      canvas.drawRect(
        rect,
        Paint()..color = color.withValues(alpha: ambientAlpha),
      );
    }

    final dx = math.max(
      (position.dx - rect.left).abs(),
      (rect.right - position.dx).abs(),
    );
    final dy = math.max(
      (position.dy - rect.top).abs(),
      (rect.bottom - position.dy).abs(),
    );
    final targetRadius = radius ?? math.sqrt(dx * dx + dy * dy);
    final waveAlpha = color.a * 0.66 * fadeAlpha;
    if (targetRadius > 0 && waveAlpha > 0) {
      final currentRadius = targetRadius * (0.16 + 1.18 * easedExpand);
      final waveColor = color.withValues(alpha: waveAlpha);
      final wavePaint = Paint()
        ..shader = ui.Gradient.radial(
          position,
          currentRadius,
          <Color>[
            waveColor,
            waveColor,
            waveColor.withValues(alpha: waveAlpha * 0.45),
            waveColor.withValues(alpha: 0.0),
          ],
          const <double>[0.0, 0.72, 0.88, 1.0],
        );
      canvas.drawCircle(position, currentRadius, wavePaint);
    }

    canvas.restore();
  }

  @override
  void confirm() {
    if (_disposed || _confirming) return;
    if (!animateRipple) {
      // A quick tap can create and confirm the ink before Flutter paints a frame.
      if (showQuickTap && !_painted) {
        _release = Timer(kAppQuickTapFeedback, dispose);
      } else {
        dispose();
      }
      return;
    }
    _confirming = true;
    _confirmStartExpand = _expandController?.value ?? 1.0;
    _expandController?.stop();
    _quickTapConfirm = !_painted || _confirmStartExpand < 0.65;
    final fadeDuration = Duration(
      milliseconds: _quickTapConfirm
          ? (showQuickTap ? 160 : 120)
          : (showQuickTap ? 125 : 105),
    );
    _fadeController =
        AnimationController(vsync: controller.vsync, duration: fadeDuration)
          ..addListener(_handleTick)
          ..addStatusListener(_handleFadeStatus)
          ..forward();
    // Covered routes mute page tickers; ensure release ink still finishes cleanly.
    _release = Timer(fadeDuration + const Duration(milliseconds: 16), dispose);
  }

  @override
  void cancel() => dispose();

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _release?.cancel();
    _release = null;
    _expandController?.dispose();
    _expandController = null;
    _fadeController?.dispose();
    _fadeController = null;
    super.dispose();
  }
}
