import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../app/theme/app_styles.dart';
import 'app_tap_highlight.dart';
import 'app_transitions.dart';

/// Removes pointer ink while letting Material paint keyboard focus.
ButtonStyle appButtonStyle([ButtonStyle? style]) =>
    (style ?? const ButtonStyle()).copyWith(
      mouseCursor: WidgetStateProperty.resolveWith(
        (states) =>
            style?.mouseCursor?.resolve(states) ??
            WidgetStateMouseCursor.clickable.resolve(states),
      ),
      splashFactory: NoSplash.splashFactory,
      overlayColor: WidgetStateProperty.resolveWith(
        (states) =>
            states.contains(WidgetState.hovered) ||
                states.contains(WidgetState.pressed)
            ? Colors.transparent
            : style?.overlayColor?.resolve(states),
      ),
    );

ButtonStyle appIconButtonStyle([
  ButtonStyle? style,
  WidgetStatesController? pointerStates,
  bool allowThemeHighlight = true,
]) => _iconButtonStyle(
  style,
  pointerStates,
  allowThemeHighlight: allowThemeHighlight,
);

ButtonStyle appTransportIconButtonStyle(ButtonStyle style) =>
    _iconButtonStyle(style, null, isTransportControl: true);

ButtonStyle _iconButtonStyle(
  ButtonStyle? style,
  WidgetStatesController? pointerStates, {
  bool isTransportControl = false,
  bool allowThemeHighlight = true,
}) => appButtonStyle(style).copyWith(
  backgroundBuilder: pointerStates == null && !isTransportControl
      ? _touchButtonLayer(style)
      : style?.backgroundBuilder,
  foregroundBuilder: (context, states, icon) {
    final backgroundColor = style?.backgroundColor?.resolve(states);
    if (pointerStates != null) {
      return AppButtonIcon(
        states: pointerStates,
        backgroundColor: backgroundColor,
        allowThemeHighlight: allowThemeHighlight,
        child: icon!,
      );
    }
    return _ButtonIconFeedback(
      pressed: states.contains(WidgetState.pressed),
      hovered: states.contains(WidgetState.hovered),
      enabled: !states.contains(WidgetState.disabled),
      allowThemeHighlight: allowThemeHighlight,
      isTransportControl: isTransportControl,
      backgroundColor: backgroundColor,
      child: icon!,
    );
  },
);

bool _hasReadableContrast(Color foreground, Color? background) {
  if (foreground.a == 0) return false;
  if (background == null || background.a <= 0.2) return true;
  final foregroundLuminance = foreground.computeLuminance();
  final backgroundLuminance = background.computeLuminance();
  return (math.max(foregroundLuminance, backgroundLuminance) + 0.05) /
          (math.min(foregroundLuminance, backgroundLuminance) + 0.05) >=
      2.2;
}

/// Computes the icon transform, opacity, color, and duration for pointer button
/// feedback while respecting [TickerMode], reduced motion, and Windows hover.
({double scale, double opacity, Color? color, Duration duration})
resolveAppButtonIconFeedback({
  required BuildContext context,
  required bool pressed,
  required bool hovered,
  required bool enabled,
  Color? baseColor,
  Color? backgroundColor,
  bool allowThemeHighlight = true,
  bool isTransportControl = false,
}) {
  final theme = Theme.of(context);
  final isWindows = theme.platform == TargetPlatform.windows;
  final visible = TickerMode.valuesOf(context).enabled;
  final reduceMotion = MediaQuery.disableAnimationsOf(context);
  final isPressed = visible && enabled && pressed;
  final isHovered = visible && enabled && hovered && isWindows;
  final cs = theme.colorScheme;
  final highlight =
      allowThemeHighlight &&
      (isHovered || (isPressed && !isTransportControl)) &&
      _hasReadableContrast(cs.primary, backgroundColor);
  final Color? color;
  if (!highlight) {
    color = baseColor;
  } else if (baseColor != null &&
      baseColor.toARGB32() == cs.primary.toARGB32()) {
    color = Color.lerp(cs.primary, cs.onPrimaryContainer, 0.35);
  } else {
    color = cs.primary;
  }
  return (
    scale: !reduceMotion && isPressed
        ? (isTransportControl
              ? (isWindows ? 0.90 : 0.92)
              : (isWindows ? 0.82 : 0.84))
        : 1.0,
    opacity: reduceMotion && isPressed
        ? 0.72
        : reduceMotion && isHovered
        ? 0.85
        : 1.0,
    color: color,
    duration: !visible || reduceMotion || !enabled
        ? Duration.zero
        : isWindows
        ? _windowsButtonFeedbackDuration(isPressed)
        : isPressed && !isTransportControl
        ? Duration.zero
        : Duration(milliseconds: isPressed ? 80 : 120),
  );
}

({double scale, double opacity, Color? color, Duration duration})
resolveAppTextButtonFeedback({
  required BuildContext context,
  required bool pressed,
  required bool hovered,
  required bool enabled,
  Color? baseColor,
  Color? backgroundColor,
  Color? accentColor,
}) {
  final theme = Theme.of(context);
  final isWindows = theme.platform == TargetPlatform.windows;
  final isDark = theme.brightness == Brightness.dark;
  final visible = TickerMode.valuesOf(context).enabled;
  final reduceMotion = MediaQuery.disableAnimationsOf(context);
  final isPressed = visible && enabled && pressed;
  final isHovered = visible && enabled && hovered && isWindows;
  final cs = theme.colorScheme;
  final accent = accentColor ?? cs.primary;
  final canHighlight =
      (isHovered || isPressed) && _hasReadableContrast(accent, backgroundColor);
  final color = !canHighlight
      ? baseColor
      : baseColor == accent
      ? Color.lerp(accent, isDark ? Colors.white : cs.onPrimaryContainer, 0.35)
      : accent;
  return (
    scale: !reduceMotion && isPressed ? 0.94 : 1.0,
    opacity: reduceMotion && isPressed
        ? 0.72
        : reduceMotion && isHovered
        ? 0.85
        : 1.0,
    color: color,
    duration: !visible || reduceMotion || !enabled
        ? Duration.zero
        : isWindows
        ? _windowsButtonFeedbackDuration(isPressed)
        : isPressed
        ? Duration.zero
        : const Duration(milliseconds: 120),
  );
}

Widget _identityForegroundBuilder(
  BuildContext context,
  Set<WidgetState> states,
  Widget? child,
) => child ?? const SizedBox.shrink();

/// Computes whole-button motion feedback for large pill/surface action buttons,
/// distinct from icon-only buttons.
({double scale, bool pressed, bool hovered, Duration duration})
resolveAppSurfaceButtonFeedback({
  required BuildContext context,
  required bool pressed,
  required bool hovered,
  required bool enabled,
}) {
  final theme = Theme.of(context);
  final visible = TickerMode.valuesOf(context).enabled;
  final reduceMotion = MediaQuery.disableAnimationsOf(context);
  final isWindows = theme.platform == TargetPlatform.windows;
  final isPressed = visible && enabled && pressed;
  final isHovered = visible && enabled && hovered && isWindows;
  return (
    scale: !reduceMotion && isPressed ? (isWindows ? 0.975 : 0.98) : 1.0,
    pressed: isPressed,
    hovered: isHovered,
    duration: !visible || reduceMotion || !enabled
        ? Duration.zero
        : isWindows
        ? _windowsButtonFeedbackDuration(isPressed)
        : isPressed
        ? Duration.zero
        : const Duration(milliseconds: 140),
  );
}

Duration _windowsButtonFeedbackDuration(bool pressed) =>
    Duration(milliseconds: pressed ? 60 : 90);

Color appHoverTint(ColorScheme colors) => colors.primary.withValues(
  alpha: colors.brightness == Brightness.dark ? 0.14 : 0.08,
);

Color appPressedTint(ColorScheme colors) => colors.primary.withValues(
  alpha: colors.brightness == Brightness.dark ? 0.22 : 0.14,
);

Color appSurfaceHighlight(
  ColorScheme colors,
  Color background, {
  required bool pressed,
  required bool hovered,
}) {
  if (!pressed && !hovered) return background;
  return Color.alphaBlend(
    _surfaceTint(colors, background, pressed),
    background,
  );
}

Color appLabelledButtonHighlight(
  ColorScheme colors, {
  required Color foreground,
  required Color background,
}) {
  final surface = Color.alphaBlend(background, colors.surface);
  if (foreground != colors.primary &&
      _hasReadableContrast(colors.primary, surface)) {
    return colors.primary;
  }
  // Filled actions need a foreground that still reads against their fill.
  final tinted = Color.lerp(foreground, surface, 0.20)!;
  return _hasReadableContrast(tinted, surface) ? tinted : foreground;
}

Color _surfaceTint(ColorScheme colors, Color background, bool pressed) {
  final tint = pressed ? appPressedTint(colors) : appHoverTint(colors);
  // An accent-colored surface needs a contrasting tint to show interaction.
  return background.a >= 0.85 && _colorChroma(background) >= 0.14
      ? colors.onPrimary.withValues(alpha: tint.a)
      : tint;
}

double _colorChroma(Color c) =>
    math.max(c.r, math.max(c.g, c.b)) - math.min(c.r, math.min(c.g, c.b));

ButtonStyle appSurfaceButtonStyle({
  ButtonStyle? style,
  required ColorScheme colorScheme,
  required TargetPlatform platform,
  Color defaultBackgroundColor = Colors.transparent,
  Duration animationDuration = const Duration(milliseconds: 90),
}) {
  final base = appButtonStyle(style);
  final android = platform == TargetPlatform.android;
  Color? restingBackground(Set<WidgetState> states) =>
      style?.backgroundColor?.resolve(_restingStates(states));

  return base.copyWith(
    animationDuration: android ? Duration.zero : animationDuration,
    foregroundBuilder: _identityForegroundBuilder,
    splashFactory: android
        ? AppTapHighlightFactory.forPlatform(platform)
        : null,
    overlayColor: android
        ? WidgetStateProperty.resolveWith(
            (states) =>
                states.contains(WidgetState.pressed) &&
                    !states.contains(WidgetState.disabled)
                ? _surfaceTint(
                    colorScheme,
                    restingBackground(states) ?? defaultBackgroundColor,
                    true,
                  )
                : base.overlayColor?.resolve(states),
          )
        : null,
    backgroundColor: WidgetStateProperty.resolveWith((states) {
      final background = restingBackground(states);
      if (android || states.contains(WidgetState.disabled)) return background;
      final pressed = states.contains(WidgetState.pressed);
      final hovered =
          platform == TargetPlatform.windows &&
          states.contains(WidgetState.hovered);
      if (!pressed && !hovered) return background;
      return appSurfaceHighlight(
        colorScheme,
        background ?? defaultBackgroundColor,
        pressed: pressed,
        hovered: hovered,
      );
    }),
  );
}

Set<WidgetState> _restingStates(Set<WidgetState> states) =>
    states.difference(const {WidgetState.hovered, WidgetState.pressed});

ButtonStyle appTextButtonStyle({ButtonStyle? style}) =>
    appButtonStyle(style).copyWith(
      backgroundBuilder: _touchButtonLayer(style),
      backgroundColor: WidgetStateProperty.resolveWith(
        (states) => style?.backgroundColor?.resolve(_restingStates(states)),
      ),
      side: WidgetStateProperty.resolveWith(
        (states) => style?.side?.resolve(_restingStates(states)),
      ),
      foregroundBuilder: (context, states, child) => _TextButtonFeedback(
        pressed: states.contains(WidgetState.pressed),
        hovered: states.contains(WidgetState.hovered),
        enabled: !states.contains(WidgetState.disabled),
        backgroundColor: style?.backgroundColor?.resolve(
          _restingStates(states),
        ),
        child: child ?? const SizedBox.shrink(),
      ),
    );

ButtonLayerBuilder _touchButtonLayer(ButtonStyle? style) =>
    (context, states, child) => AppTouchFeedback(
      enabled: !states.contains(WidgetState.disabled),
      child:
          style?.backgroundBuilder?.call(context, states, child) ??
          child ??
          const SizedBox.shrink(),
    );

ButtonStyle appSegmentedButtonStyle({
  ButtonStyle? style,
  required ColorScheme colorScheme,
  required TargetPlatform platform,
}) {
  final base = style ?? const ButtonStyle();
  return appSurfaceButtonStyle(
    style: base.copyWith(
      backgroundColor: WidgetStateProperty.resolveWith(
        (states) =>
            base.backgroundColor?.resolve(states) ??
            (states.contains(WidgetState.selected) &&
                    !states.contains(WidgetState.disabled)
                ? colorScheme.secondaryContainer
                : null),
      ),
      overlayColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.focused)
            ? colorScheme.primary.withValues(alpha: 0.12)
            : base.overlayColor?.resolve(states),
      ),
    ),
    colorScheme: colorScheme,
    platform: platform,
  );
}

ButtonStyle appSelectablePillButtonStyle({
  required ButtonStyle style,
  required bool selected,
  required ColorScheme colorScheme,
}) => appTextButtonStyle(
  style: style.copyWith(
    backgroundColor: WidgetStateProperty.resolveWith(
      (states) =>
          style.backgroundColor?.resolve(states) ??
          (selected && !states.contains(WidgetState.disabled)
              ? colorScheme.secondaryContainer
              : null),
    ),
    foregroundColor: WidgetStateProperty.resolveWith(
      (states) =>
          style.foregroundColor?.resolve(states) ??
          (states.contains(WidgetState.disabled)
              ? null
              : selected
              ? colorScheme.primary
              : colorScheme.onSurfaceVariant),
    ),
  ),
);

ChipThemeData appChipTheme({
  required ColorScheme colorScheme,
  required TargetPlatform platform,
  TextStyle? baseLabelStyle,
}) => ChipThemeData(
  color: appChipColor(colorScheme: colorScheme, platform: platform),
  labelStyle: (baseLabelStyle ?? const TextStyle(fontSize: 14)).copyWith(
    color: WidgetStateColor.resolveWith(
      (states) => states.contains(WidgetState.disabled)
          ? colorScheme.onSurface.withValues(alpha: 0.38)
          : states.contains(WidgetState.selected)
          ? colorScheme.onSecondaryContainer
          : colorScheme.onSurfaceVariant,
    ),
  ),
);

WidgetStateProperty<Color?> appChipColor({
  required ColorScheme colorScheme,
  required TargetPlatform platform,
  Color? background,
  Color? selectedBackground,
}) => WidgetStateProperty.resolveWith((states) {
  if (states.contains(WidgetState.disabled)) return null;
  final base = states.contains(WidgetState.selected)
      ? selectedBackground
      : background;
  final pressed =
      platform != TargetPlatform.android &&
      states.contains(WidgetState.pressed);
  final hovered =
      platform == TargetPlatform.windows &&
      states.contains(WidgetState.hovered);
  if (!pressed && !hovered) return base;
  return appSurfaceHighlight(
    colorScheme,
    base ??
        (states.contains(WidgetState.selected)
            ? colorScheme.secondaryContainer
            : colorScheme.surface),
    pressed: pressed,
    hovered: hovered,
  );
});

class _AnimatedForegroundFeedback extends StatelessWidget {
  const _AnimatedForegroundFeedback({
    required this.scale,
    required this.opacity,
    required this.color,
    this.baseColor,
    required this.duration,
    required this.animateTint,
    required this.tintText,
    required this.isWindows,
    required this.child,
  });

  final double scale;
  final double opacity;
  final Color? color;
  final Color? baseColor;
  final Duration duration;
  final bool animateTint;
  final bool tintText;
  final bool isWindows;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tintedChild = animateTint
        ? TweenAnimationBuilder<Color?>(
            key: ValueKey(baseColor),
            tween: ColorTween(end: color),
            duration: duration,
            curve: Curves.easeOutQuad,
            child: child,
            builder: (context, resolvedColor, child) {
              if (resolvedColor == null) return child!;
              final iconWrapped = IconTheme.merge(
                data: IconThemeData(color: resolvedColor),
                child: child!,
              );
              return tintText
                  ? DefaultTextStyle.merge(
                      style: TextStyle(color: resolvedColor),
                      child: iconWrapped,
                    )
                  : iconWrapped;
            },
          )
        : child;

    return TweenAnimationBuilder<double>(
      tween: Tween(end: scale),
      duration: duration,
      curve: isWindows
          ? Curves.easeOutQuad
          : (scale == 1.0 ? kAppSpringBackCurve : Curves.easeOutCubic),
      child: Opacity(opacity: opacity, child: tintedChild),
      // Paint the glyph directly so glass toolbars can composite it while scaled.
      builder: (context, value, child) =>
          Transform.scale(scale: value, transformHitTests: false, child: child),
    );
  }
}

class _ButtonIconFeedback extends StatelessWidget {
  const _ButtonIconFeedback({
    required this.pressed,
    required this.hovered,
    required this.enabled,
    this.backgroundColor,
    this.allowThemeHighlight = true,
    this.isTransportControl = false,
    required this.child,
  });

  final bool pressed;
  final bool hovered;
  final bool enabled;
  final Color? backgroundColor;
  final bool allowThemeHighlight;
  final bool isTransportControl;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isWindows = Theme.of(context).platform == TargetPlatform.windows;
    final baseColor = IconTheme.of(context).color;
    final feedback = resolveAppButtonIconFeedback(
      context: context,
      pressed: pressed || _AppTouchState.isPressed(context),
      hovered: hovered,
      enabled: enabled,
      baseColor: baseColor,
      backgroundColor: backgroundColor,
      allowThemeHighlight: allowThemeHighlight,
      isTransportControl: isTransportControl,
    );
    return _AnimatedForegroundFeedback(
      scale: feedback.scale,
      opacity: feedback.opacity,
      color: feedback.color,
      duration: feedback.duration,
      animateTint: allowThemeHighlight && (isWindows || !isTransportControl),
      tintText: true,
      isWindows: isWindows,
      child: child,
    );
  }
}

class _TextButtonFeedback extends StatelessWidget {
  const _TextButtonFeedback({
    required this.pressed,
    required this.hovered,
    required this.enabled,
    this.backgroundColor,
    this.accentColor,
    required this.child,
  });

  final bool pressed;
  final bool hovered;
  final bool enabled;
  final Color? backgroundColor;
  final Color? accentColor;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isWindows = Theme.of(context).platform == TargetPlatform.windows;
    final baseColor = DefaultTextStyle.of(context).style.color;
    final feedback = resolveAppTextButtonFeedback(
      context: context,
      pressed: pressed || _AppTouchState.isPressed(context),
      hovered: hovered,
      enabled: enabled,
      baseColor: baseColor,
      backgroundColor: backgroundColor,
      accentColor: accentColor,
    );
    return _AnimatedForegroundFeedback(
      scale: feedback.scale,
      opacity: feedback.opacity,
      color: feedback.color,
      baseColor: baseColor,
      duration: feedback.duration,
      animateTint: true,
      tintText: true,
      isWindows: isWindows,
      child: child,
    );
  }
}

class AppButtonText extends StatelessWidget {
  const AppButtonText({
    super.key,
    required this.states,
    required this.label,
    this.style,
    this.accentColor,
    this.maxLines,
    this.overflow,
  });

  final WidgetStatesController states;
  final String label;
  final TextStyle? style;
  final Color? accentColor;
  final int? maxLines;
  final TextOverflow? overflow;

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<Set<WidgetState>>(
        valueListenable: states,
        builder: (context, value, _) => DefaultTextStyle.merge(
          style: style,
          child: _TextButtonFeedback(
            pressed: value.contains(WidgetState.pressed),
            hovered: value.contains(WidgetState.hovered),
            enabled: !value.contains(WidgetState.disabled),
            accentColor: accentColor,
            child: Text(label, maxLines: maxLines, overflow: overflow),
          ),
        ),
      );
}

/// An inline text action with the same feedback as a Material text button.
class AppTextLink extends StatefulWidget {
  const AppTextLink({
    super.key,
    required this.label,
    required this.onTap,
    this.style,
    this.padding = EdgeInsets.zero,
    this.maxLines,
    this.overflow,
  });

  final String label;
  final VoidCallback? onTap;
  final TextStyle? style;
  final EdgeInsetsGeometry padding;
  final int? maxLines;
  final TextOverflow? overflow;

  @override
  State<AppTextLink> createState() => _AppTextLinkState();
}

class _AppTextLinkState extends State<AppTextLink> {
  final _states = WidgetStatesController();

  @override
  void dispose() {
    _states.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => InkWell(
    mouseCursor: WidgetStateMouseCursor.clickable,
    onTap: widget.onTap,
    statesController: _states,
    hoverColor: Colors.transparent,
    highlightColor: Colors.transparent,
    splashFactory: NoSplash.splashFactory,
    child: AppTouchFeedback(
      enabled: widget.onTap != null,
      child: Padding(
        padding: widget.padding,
        child: AppButtonText(
          states: _states,
          label: widget.label,
          style: widget.style,
          maxLines: widget.maxLines,
          overflow: widget.overflow,
        ),
      ),
    ),
  );
}

/// Publishes Android touch feedback inside controls whose gesture stays native.
class AppTouchFeedback extends StatelessWidget {
  const AppTouchFeedback({
    super.key,
    required this.enabled,
    required this.child,
  });

  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (Theme.of(context).platform != TargetPlatform.android) return child;
    return AppButtonPointerRegion(
      enabled: enabled,
      touchOnly: true,
      builder: (context, states) =>
          _AppTouchState(notifier: states, child: child),
    );
  }
}

class _AppTouchState extends InheritedNotifier<WidgetStatesController> {
  const _AppTouchState({required super.notifier, required super.child});

  static bool isPressed(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_AppTouchState>()
          ?.notifier
          ?.value
          .contains(WidgetState.pressed) ??
      false;
}

class AppButtonIcon extends StatelessWidget {
  const AppButtonIcon({
    super.key,
    required this.states,
    this.backgroundColor,
    this.allowThemeHighlight = true,
    required this.child,
  });

  final WidgetStatesController states;
  final Color? backgroundColor;
  final bool allowThemeHighlight;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<Set<WidgetState>>(
        valueListenable: states,
        child: child,
        builder: (context, value, child) => _ButtonIconFeedback(
          pressed: value.contains(WidgetState.pressed),
          hovered: value.contains(WidgetState.hovered),
          enabled: !value.contains(WidgetState.disabled),
          backgroundColor: backgroundColor,
          allowThemeHighlight: allowThemeHighlight,
          child: child!,
        ),
      );
}

/// Observes the trigger when its control does not expose a states controller.
class AppButtonPointerRegion extends StatefulWidget {
  const AppButtonPointerRegion({
    super.key,
    this.enabled = true,
    this.statesController,
    this.cursor = MouseCursor.defer,
    this.touchOnly = false,
    required this.builder,
  });

  final bool enabled;
  final WidgetStatesController? statesController;
  final MouseCursor cursor;
  final bool touchOnly;
  final Widget Function(BuildContext, WidgetStatesController) builder;

  @override
  State<AppButtonPointerRegion> createState() => _AppButtonPointerRegionState();
}

/// Suppresses pointer ink and lets chips opt into Android's brief press fill.
Widget appNoPointerInkTheme({
  required BuildContext context,
  required Widget child,
  bool androidPressHighlight = false,
}) => Theme(
  data: Theme.of(context).copyWith(
    hoverColor: Colors.transparent,
    highlightColor: Colors.transparent,
    splashColor: appPressedTint(Theme.of(context).colorScheme),
    splashFactory:
        androidPressHighlight &&
            Theme.of(context).platform == TargetPlatform.android
        ? AppTapHighlightFactory.forPlatform(
            TargetPlatform.android,
            animateRipple: false,
          )
        : NoSplash.splashFactory,
  ),
  child: child,
);

class _AppButtonPointerRegionState extends State<AppButtonPointerRegion> {
  WidgetStatesController? _ownedStates;
  WidgetStatesController get _states =>
      widget.statesController ?? (_ownedStates ??= WidgetStatesController());
  int? _pointer;
  Offset? _touchOrigin;
  Timer? _minimumTouchFeedback;

  @override
  void initState() {
    super.initState();
    _states.update(WidgetState.disabled, !widget.enabled);
  }

  @override
  void didUpdateWidget(covariant AppButtonPointerRegion oldWidget) {
    super.didUpdateWidget(oldWidget);
    _states.update(WidgetState.disabled, !widget.enabled);
    if (!widget.enabled ||
        oldWidget.statesController != widget.statesController) {
      _clearPress();
      _states.update(WidgetState.hovered, false);
    }
  }

  @override
  void dispose() {
    _minimumTouchFeedback?.cancel();
    _ownedStates?.dispose();
    super.dispose();
  }

  void _clearPress() {
    _pointer = null;
    _touchOrigin = null;
    _minimumTouchFeedback?.cancel();
    _minimumTouchFeedback = null;
    _states.update(WidgetState.pressed, false);
  }

  @override
  Widget build(BuildContext context) {
    final android = Theme.of(context).platform == TargetPlatform.android;
    final listener = Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        if (!widget.enabled ||
            _pointer != null ||
            event.buttons != kPrimaryButton ||
            (widget.touchOnly && event.kind != PointerDeviceKind.touch)) {
          return;
        }
        _minimumTouchFeedback?.cancel();
        _minimumTouchFeedback = null;
        _pointer = event.pointer;
        if (android && event.kind == PointerDeviceKind.touch) {
          _touchOrigin = event.position;
          _minimumTouchFeedback = Timer(kAppQuickTapFeedback, () {
            _minimumTouchFeedback = null;
            if (_pointer == null) _clearPress();
          });
        }
        _states.update(WidgetState.pressed, true);
      },
      onPointerMove: (event) {
        if (_pointer != event.pointer) return;
        final size = context.size;
        final origin = _touchOrigin;
        if (size == null ||
            !(Offset.zero & size).contains(event.localPosition) ||
            (origin != null &&
                (event.position - origin).distance >
                    computeHitSlop(
                      event.kind,
                      MediaQuery.gestureSettingsOf(context),
                    ))) {
          _clearPress();
        }
      },
      onPointerUp: (event) {
        if (_pointer != event.pointer) return;
        _pointer = null;
        _touchOrigin = null;
        if (_minimumTouchFeedback == null) _clearPress();
      },
      onPointerCancel: (event) {
        if (_pointer == event.pointer) _clearPress();
      },
      child: widget.builder(context, _states),
    );
    if (widget.touchOnly) return listener;
    return MouseRegion(
      cursor: widget.enabled ? widget.cursor : MouseCursor.defer,
      hitTestBehavior: HitTestBehavior.translucent,
      onEnter: widget.enabled
          ? (_) => _states.update(WidgetState.hovered, true)
          : null,
      onExit: (_) => _states.update(WidgetState.hovered, false),
      child: listener,
    );
  }
}

class AppSurfaceButtonShell extends StatelessWidget {
  const AppSurfaceButtonShell({
    super.key,
    required this.enabled,
    required this.builder,
  });

  final bool enabled;
  final Widget Function(
    BuildContext context,
    ({double scale, bool pressed, bool hovered, Duration duration}) feedback,
  )
  builder;

  @override
  Widget build(BuildContext context) => AppButtonPointerRegion(
    enabled: enabled,
    builder: (context, states) => ValueListenableBuilder<Set<WidgetState>>(
      valueListenable: states,
      builder: (context, value, _) {
        final feedback = resolveAppSurfaceButtonFeedback(
          context: context,
          pressed: value.contains(WidgetState.pressed),
          hovered: value.contains(WidgetState.hovered),
          enabled: enabled,
        );
        return TweenAnimationBuilder<double>(
          tween: Tween(end: feedback.scale),
          duration: feedback.duration,
          curve: Theme.of(context).platform == TargetPlatform.windows
              ? Curves.easeOutQuad
              : (feedback.scale == 1.0
                    ? kAppSpringBackCurve
                    : Curves.easeOutCubic),
          child: builder(context, feedback),
          builder: (context, scale, child) => Transform.scale(
            scale: scale,
            transformHitTests: false,
            child: child,
          ),
        );
      },
    ),
  );
}

// Material owns focus, gestures, semantics and label layout for both kinds of
// buttons. Share its controller with the icon without scaling the label.
typedef AppLabelledButtonConstructor =
    ButtonStyleButton Function({
      Key? key,
      required VoidCallback? onPressed,
      ButtonStyle? style,
      WidgetStatesController? statesController,
      Widget? icon,
      required Widget label,
    });

class AppLabelledButton extends StatelessWidget {
  const AppLabelledButton(
    this.button, {
    super.key,
    this.style,
    required this.onPressed,
    required this.icon,
    required this.label,
  });

  final AppLabelledButtonConstructor button;
  final ButtonStyle? style;
  final VoidCallback? onPressed;
  final Widget icon;
  final Widget label;

  @override
  Widget build(BuildContext context) {
    if (button == TextButton.icon) {
      return button(
        onPressed: onPressed,
        style: appTextButtonStyle(style: style),
        icon: icon,
        label: label,
      );
    }
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final defaultBg = switch (button) {
      _ when button == FilledButton.tonalIcon => cs.secondaryContainer,
      _ when button == ElevatedButton.icon => cs.surfaceContainerLow,
      _ when button == OutlinedButton.icon => Colors.transparent,
      _ => cs.primary,
    };
    final defaultFg = switch (button) {
      _ when button == FilledButton.tonalIcon => cs.onSecondaryContainer,
      _ when button == ElevatedButton.icon || button == OutlinedButton.icon =>
        cs.primary,
      _ => cs.onPrimary,
    };
    final surfaceStyle = appSurfaceButtonStyle(
      style: style,
      colorScheme: cs,
      platform: theme.platform,
      defaultBackgroundColor: defaultBg,
      animationDuration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 90),
    );
    return AppSurfaceButtonShell(
      enabled: onPressed != null,
      builder: (context, feedback) {
        var resolvedStyle = surfaceStyle;
        if (feedback.pressed || feedback.hovered) {
          const resting = <WidgetState>{};
          final background =
              style?.backgroundColor?.resolve(resting) ?? defaultBg;
          final foreground = appLabelledButtonHighlight(
            cs,
            foreground: style?.foregroundColor?.resolve(resting) ?? defaultFg,
            background: appSurfaceHighlight(
              cs,
              background,
              pressed: feedback.pressed,
              hovered: feedback.hovered,
            ),
          );
          final tint = WidgetStatePropertyAll(foreground);
          resolvedStyle = surfaceStyle.copyWith(
            foregroundColor: tint,
            iconColor: tint,
          );
        }
        return button(
          onPressed: onPressed,
          style: resolvedStyle,
          icon: icon,
          label: label,
        );
      },
    );
  }
}

class AppOverlayIconButton extends StatelessWidget {
  const AppOverlayIconButton({
    super.key,
    this.buttonKey,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.buttonSize = AppPageHeaderMetrics.buttonSize,
    this.foregroundColor = Colors.white,
  });

  static const iconShadows = [
    Shadow(color: Color(0xA6000000), offset: Offset(0, 2), blurRadius: 5),
  ];

  final Key? buttonKey;
  final Widget icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double buttonSize;
  final Color foregroundColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isWindows = theme.platform == TargetPlatform.windows;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final size = Size.square(buttonSize);
    return IconButton(
      key: buttonKey,
      onPressed: onPressed,
      tooltip: tooltip,
      style: appIconButtonStyle(
        IconButton.styleFrom(
          fixedSize: size,
          minimumSize: size,
          maximumSize: size,
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.standard,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          iconSize: 32,
          shape: const CircleBorder(),
        ).copyWith(
          animationDuration: reduceMotion
              ? Duration.zero
              : const Duration(milliseconds: 90),
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) {
              return Colors.transparent;
            }
            if (states.contains(WidgetState.pressed)) {
              return Colors.black.withValues(alpha: 0.48);
            }
            if (isWindows && states.contains(WidgetState.hovered)) {
              return Colors.black.withValues(alpha: 0.32);
            }
            return Colors.transparent;
          }),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) {
              return colors.onSurface.withValues(alpha: 0.38);
            }
            return foregroundColor;
          }),
        ),
        null,
        false,
      ),
      icon: IconTheme.merge(
        data: const IconThemeData(shadows: iconShadows),
        child: icon,
      ),
    );
  }
}

class AppPillButton extends StatelessWidget {
  const AppPillButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.style,
  }) : _outlined = false;

  const AppPillButton.outlined({
    super.key,
    required this.onPressed,
    required this.child,
    this.style,
  }) : _outlined = true;

  final VoidCallback? onPressed;
  final Widget child;
  final ButtonStyle? style;
  final bool _outlined;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final feedbackStyle = appSurfaceButtonStyle(
      style: style,
      colorScheme: theme.colorScheme,
      platform: theme.platform,
      defaultBackgroundColor: _outlined
          ? Colors.transparent
          : theme.colorScheme.primary,
      animationDuration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 90),
    );
    return AppSurfaceButtonShell(
      enabled: onPressed != null,
      builder: (context, _) => _outlined
          ? OutlinedButton(
              onPressed: onPressed,
              style: feedbackStyle,
              child: child,
            )
          : FilledButton(
              onPressed: onPressed,
              style: feedbackStyle,
              child: child,
            ),
    );
  }
}

class AppPrimaryButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final String label;
  final IconData? icon;
  final bool isLoading;
  final bool isDestructive;

  const AppPrimaryButton({
    super.key,
    required this.onPressed,
    required this.label,
    this.icon,
    this.isLoading = false,
    this.isDestructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final foregroundColor = isDestructive
        ? colorScheme.onError
        : colorScheme.onPrimary;
    final backgroundColor = isDestructive
        ? colorScheme.error
        : colorScheme.primary;

    final style = FilledButton.styleFrom(
      foregroundColor: foregroundColor,
      backgroundColor: backgroundColor,
      minimumSize: const Size.fromHeight(48),
      shape: const StadiumBorder(),
      textStyle: theme.textTheme.labelLarge?.copyWith(
        fontWeight: FontWeight.bold,
      ),
    );

    if (isLoading) {
      return FilledButton.icon(
        onPressed: null,
        style: appButtonStyle(style),
        icon: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: foregroundColor,
          ),
        ),
        label: Text(label),
      );
    }
    if (icon != null) {
      return AppLabelledButton(
        FilledButton.icon,
        onPressed: onPressed,
        style: style,
        icon: Icon(icon, size: 20),
        label: Text(label),
      );
    }

    return AppPillButton(
      onPressed: onPressed,
      style: style,
      child: Text(label),
    );
  }
}

class AppSecondaryButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final String label;
  final IconData? icon;
  final bool isDestructive;
  final bool isLoading;

  const AppSecondaryButton({
    super.key,
    required this.onPressed,
    required this.label,
    this.icon,
    this.isDestructive = false,
    this.isLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final foregroundColor = isDestructive
        ? colorScheme.error
        : colorScheme.primary;

    final style = OutlinedButton.styleFrom(
      foregroundColor: foregroundColor,
      minimumSize: const Size.fromHeight(48),
      side: BorderSide(
        color: isDestructive
            ? colorScheme.error.withValues(alpha: 0.5)
            : colorScheme.outlineVariant,
      ),
      shape: const StadiumBorder(),
      textStyle: theme.textTheme.labelLarge?.copyWith(
        fontWeight: FontWeight.bold,
      ),
    );

    if (isLoading) {
      return OutlinedButton.icon(
        onPressed: null,
        style: appButtonStyle(style),
        icon: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: foregroundColor.withValues(alpha: 0.5),
          ),
        ),
        label: Text(label),
      );
    }
    if (icon != null) {
      return AppLabelledButton(
        OutlinedButton.icon,
        onPressed: onPressed,
        style: style,
        icon: Icon(icon, size: 20),
        label: Text(label),
      );
    }

    return AppPillButton.outlined(
      onPressed: onPressed,
      style: style,
      child: Text(label),
    );
  }
}
