import 'package:flutter/material.dart';

/// Navigation can mute the source page's tickers before an ink fade finishes.
/// End entry feedback on release so it cannot resume over the returning page.
class AppEntryInkWell extends InkWell {
  const AppEntryInkWell({
    super.key,
    bool navigationEntry = true,
    super.splashColor,
    super.hoverColor,
    super.onTap,
    super.onLongPress,
    super.borderRadius,
    super.customBorder,
    super.canRequestFocus,
    super.excludeFromSemantics,
    super.child,
  }) : super(
         splashFactory: navigationEntry ? _splashFactory : null,
         highlightColor: navigationEntry ? Colors.transparent : null,
         hoverDuration: navigationEntry ? Duration.zero : null,
       );
  static const _splashFactory = _EntrySplashFactory();

  /// Applies entry feedback to Material controls that own their ink response.
  static ThemeData entryTheme(ThemeData theme) => theme.copyWith(
    splashFactory: _splashFactory,
    highlightColor: Colors.transparent,
  );
}

class _EntrySplashFactory extends InteractiveInkFeatureFactory {
  const _EntrySplashFactory();

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
    position: position,
    color: color,
    textDirection: textDirection,
    containedInkWell: containedInkWell,
    rectCallback: rectCallback,
    borderRadius: borderRadius,
    customBorder: customBorder,
    radius: radius,
    onRemoved: onRemoved,
  );
}

class _EntrySplash extends InkSplash {
  _EntrySplash({
    required super.controller,
    required super.referenceBox,
    required super.position,
    required super.color,
    required super.textDirection,
    super.containedInkWell,
    super.rectCallback,
    super.borderRadius,
    super.customBorder,
    super.radius,
    super.onRemoved,
  });

  @override
  void confirm() => dispose();

  @override
  void cancel() => dispose();
}
