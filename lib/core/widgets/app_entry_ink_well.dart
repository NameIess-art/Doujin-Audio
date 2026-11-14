import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Navigation can mute the source page's tickers before an ink fade finishes.
/// End entry feedback on release so it cannot resume over the returning page.
class AppEntryInkWell extends InkWell {
  const AppEntryInkWell({
    super.key,
    this.navigationEntry = true,
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
         highlightColor: navigationEntry ? Colors.transparent : null,
         hoverDuration: navigationEntry ? Duration.zero : null,
       );
  final bool navigationEntry;

  @override
  Widget build(BuildContext context) {
    if (!navigationEntry) return super.build(context);
    return InkWell(
      splashFactory: entrySplashFactory(context),
      highlightColor: Colors.transparent,
      hoverDuration: Duration.zero,
      splashColor: splashColor,
      hoverColor: hoverColor,
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: borderRadius,
      customBorder: customBorder,
      canRequestFocus: canRequestFocus,
      excludeFromSemantics: excludeFromSemantics,
      child: child,
    );
  }

  static InteractiveInkFeatureFactory entrySplashFactory(
    BuildContext context, {
    Color? color,
  }) => _EntrySplashFactory(
    splashColor: color,
    animate:
        Theme.of(context).platform != TargetPlatform.windows &&
        !MediaQuery.disableAnimationsOf(context),
  );

  /// Buttons use their overlay color for both the highlight and the splash.
  /// Keep only the splash so release can end all pressed ink synchronously.
  static ButtonStyle entryButtonStyle(
    BuildContext context, {
    Color? foregroundColor,
  }) {
    final theme = Theme.of(context);
    final immediateHover = theme.platform == TargetPlatform.windows;
    return ButtonStyle(
      splashFactory: entrySplashFactory(
        context,
        color: (foregroundColor ?? theme.colorScheme.primary).withValues(
          alpha: 0.12,
        ),
      ),
      overlayColor: WidgetStateProperty.resolveWith(
        (states) =>
            states.contains(WidgetState.pressed) ||
                (immediateHover && states.contains(WidgetState.hovered))
            ? Colors.transparent
            : null,
      ),
      // Material buttons cannot set InkWell.hoverDuration. Paint hover from
      // the live state so a covered page cannot retain a fading ink highlight.
      backgroundBuilder: immediateHover
          ? (context, states, child) => Builder(
              builder: (context) {
                final hovering =
                    states.contains(WidgetState.hovered) &&
                    !states.contains(WidgetState.disabled) &&
                    TickerMode.valuesOf(context).enabled;
                final color =
                    foregroundColor ??
                    DefaultTextStyle.of(context).style.color ??
                    theme.colorScheme.primary;
                // Material already has the final shape after local styles,
                // component themes and defaults have been resolved.
                final resolvedShape =
                    context.findAncestorWidgetOfExactType<Material>()!.shape!
                        as OutlinedBorder;
                return DecoratedBox(
                  decoration: ShapeDecoration(
                    color: hovering ? color.withValues(alpha: 0.08) : null,
                    shape: resolvedShape.copyWith(side: BorderSide.none),
                  ),
                  child: child,
                );
              },
            )
          : null,
    );
  }

  /// Applies entry feedback to Material controls that own their ink response.
  static ThemeData entryTheme(BuildContext context) {
    final theme = Theme.of(context);
    return theme.copyWith(
      splashFactory: entrySplashFactory(context),
      highlightColor: Colors.transparent,
      iconButtonTheme: IconButtonThemeData(
        style: entryButtonStyle(context).merge(theme.iconButtonTheme.style),
      ),
    );
  }
}

class _EntrySplashFactory extends InteractiveInkFeatureFactory {
  const _EntrySplashFactory({this.splashColor, required this.animate});

  final Color? splashColor;
  final bool animate;

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
    color: splashColor ?? color,
    splashColor: splashColor,
    textDirection: textDirection,
    clipCallback: containedInkWell
        ? rectCallback ?? (() => Offset.zero & referenceBox.size)
        : null,
    borderRadius: borderRadius ?? BorderRadius.zero,
    customBorder: customBorder,
    radius: radius,
    animate: animate,
    onRemoved: onRemoved,
  );
}

class _EntrySplash extends InteractiveInkFeature {
  _EntrySplash({
    required super.controller,
    required super.referenceBox,
    required super.color,
    required this.position,
    required this.textDirection,
    required this.splashColor,
    required this.clipCallback,
    required this.borderRadius,
    required this.radius,
    required bool animate,
    super.customBorder,
    super.onRemoved,
  }) {
    if (animate) {
      _expansion = AnimationController(
        vsync: controller.vsync,
        duration: const Duration(milliseconds: 120),
      )..addListener(controller.markNeedsPaint);
      _expansion!.forward();
    }
    controller.addInkFeature(this);
  }

  final Offset position;
  final TextDirection textDirection;
  final Color? splashColor;
  final RectCallback? clipCallback;
  final BorderRadius borderRadius;
  final double? radius;
  AnimationController? _expansion;

  @override
  set color(Color value) => super.color = splashColor ?? value;

  @override
  void paintFeature(Canvas canvas, Matrix4 transform) {
    final bounds = clipCallback?.call() ?? Offset.zero & referenceBox.size;
    final farthestCorner = Offset(
      math.max(position.dx - bounds.left, bounds.right - position.dx),
      math.max(position.dy - bounds.top, bounds.bottom - position.dy),
    );
    final targetRadius = _expansion == null
        ? farthestCorner.distance
        : radius ?? farthestCorner.distance;
    final progress = Curves.easeOutCubic.transform(_expansion?.value ?? 1);
    paintInkCircle(
      canvas: canvas,
      transform: transform,
      paint: Paint()..color = color,
      center: position,
      radius: targetRadius * (0.22 + 0.78 * progress),
      textDirection: textDirection,
      clipCallback: clipCallback,
      borderRadius: borderRadius,
      customBorder: customBorder,
    );
  }

  @override
  void confirm() => dispose();

  @override
  void cancel() => dispose();

  @override
  void dispose() {
    _expansion?.dispose();
    super.dispose();
  }
}
