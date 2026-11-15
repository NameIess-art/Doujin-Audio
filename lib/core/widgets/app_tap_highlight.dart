import 'dart:async';

import 'package:flutter/material.dart';

const kAppQuickTapFeedback = Duration(milliseconds: 60);

class AppTapHighlightFactory extends InteractiveInkFeatureFactory {
  const AppTapHighlightFactory({this.showQuickTap = false});

  static const _standard = AppTapHighlightFactory();
  static const _android = AppTapHighlightFactory(showQuickTap: true);

  static AppTapHighlightFactory forPlatform(TargetPlatform platform) =>
      platform == TargetPlatform.android ? _android : _standard;

  final bool showQuickTap;

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
  }) => _EntrySplash(
    controller: controller,
    referenceBox: referenceBox,
    color: color,
    textDirection: textDirection,
    bounds: rectCallback ?? (() => Offset.zero & referenceBox.size),
    borderRadius: borderRadius ?? BorderRadius.zero,
    customBorder: customBorder,
    onRemoved: onRemoved,
    showQuickTap: showQuickTap,
  );
}

class _EntrySplash extends InteractiveInkFeature {
  _EntrySplash({
    required super.controller,
    required super.referenceBox,
    required super.color,
    required this.textDirection,
    required this.bounds,
    required this.borderRadius,
    required this.showQuickTap,
    super.customBorder,
    super.onRemoved,
  }) {
    controller.addInkFeature(this);
  }

  final TextDirection textDirection;
  final RectCallback bounds;
  final BorderRadius borderRadius;
  final bool showQuickTap;
  bool _painted = false;
  Timer? _release;

  @override
  void paintFeature(Canvas canvas, Matrix4 transform) {
    _painted = true;
    final rect = bounds();
    canvas.save();
    canvas.transform(transform.storage);
    final paint = Paint()..color = color;
    final shape = customBorder;
    if (shape != null) {
      canvas.drawPath(
        shape.getOuterPath(rect, textDirection: textDirection),
        paint,
      );
    } else {
      canvas.drawRRect(borderRadius.toRRect(rect), paint);
    }
    canvas.restore();
  }

  @override
  void confirm() {
    // A quick tap can create and confirm the ink before Flutter paints a frame.
    if (showQuickTap && !_painted) {
      _release = Timer(kAppQuickTapFeedback, dispose);
    } else {
      dispose();
    }
  }

  @override
  void cancel() => dispose();

  @override
  void dispose() {
    _release?.cancel();
    super.dispose();
  }
}
