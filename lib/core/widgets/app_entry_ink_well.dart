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

  /// Buttons use their overlay color for both the highlight and the splash.
  /// Keep only the splash so release can end all pressed ink synchronously.
  static ButtonStyle entryButtonStyle(
    ThemeData theme, {
    Color? foregroundColor,
    OutlinedBorder? shape,
  }) {
    final immediateHover = theme.platform == TargetPlatform.windows;
    return ButtonStyle(
      splashFactory: _EntrySplashFactory(
        splashColor: (foregroundColor ?? theme.colorScheme.primary).withValues(
          alpha: 0.12,
        ),
      ),
      overlayColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.pressed) ||
                (immediateHover && states.contains(WidgetState.hovered))
            ? Colors.transparent
            : null,
      ),
      // Material buttons cannot set InkWell.hoverDuration. Paint hover from
      // the live state so a covered page cannot retain a fading ink highlight.
      backgroundBuilder: immediateHover
          ? (context, states, child) => Builder(
              builder: (context) {
                final hovering = states.contains(WidgetState.hovered) &&
                    !states.contains(WidgetState.disabled) &&
                    TickerMode.valuesOf(context).enabled;
                final color = foregroundColor ??
                    DefaultTextStyle.of(context).style.color ??
                    theme.colorScheme.primary;
                final resolvedShape = _resolveButtonShape(
                  context,
                  states,
                  theme,
                  explicitShape: shape,
                );
                return DecoratedBox(
                  decoration: ShapeDecoration(
                    color: hovering ? color.withValues(alpha: 0.08) : null,
                    shape: resolvedShape,
                  ),
                  child: child,
                );
              },
            )
          : null,
    );
  }

  static OutlinedBorder _resolveButtonShape(
    BuildContext context,
    Set<WidgetState> states,
    ThemeData theme, {
    OutlinedBorder? explicitShape,
  }) {
    if (explicitShape != null) {
      return explicitShape.copyWith(side: BorderSide.none);
    }
    if (context.widget is ButtonStyleButton) {
      final button = context.widget as ButtonStyleButton;
      final buttonShape = button.style?.shape?.resolve(states);
      if (buttonShape != null) {
        return buttonShape.copyWith(side: BorderSide.none);
      }
    }
    final iconButtonShape =
        IconButtonTheme.of(context).style?.shape?.resolve(states) ??
        theme.iconButtonTheme.style?.shape?.resolve(states);
    if (iconButtonShape != null) {
      return iconButtonShape.copyWith(side: BorderSide.none);
    }
    final filledButtonShape =
        FilledButtonTheme.of(context).style?.shape?.resolve(states) ??
        theme.filledButtonTheme.style?.shape?.resolve(states);
    if (filledButtonShape != null && context.widget is FilledButton) {
      return filledButtonShape.copyWith(side: BorderSide.none);
    }
    final outlinedButtonShape =
        OutlinedButtonTheme.of(context).style?.shape?.resolve(states) ??
        theme.outlinedButtonTheme.style?.shape?.resolve(states);
    if (outlinedButtonShape != null && context.widget is OutlinedButton) {
      return outlinedButtonShape.copyWith(side: BorderSide.none);
    }
    return const CircleBorder();
  }

  /// Applies entry feedback to Material controls that own their ink response.
  static ThemeData entryTheme(ThemeData theme) => theme.copyWith(
    splashFactory: _splashFactory,
    highlightColor: Colors.transparent,
    iconButtonTheme: IconButtonThemeData(
      style: entryButtonStyle(theme).merge(theme.iconButtonTheme.style),
    ),
  );
}

class _EntrySplashFactory extends InteractiveInkFeatureFactory {
  const _EntrySplashFactory({this.splashColor});

  final Color? splashColor;

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
    Color? splashColor,
    super.containedInkWell,
    super.rectCallback,
    super.borderRadius,
    super.customBorder,
    super.radius,
    super.onRemoved,
  }) : _splashColor = splashColor;

  final Color? _splashColor;

  @override
  set color(Color value) => super.color = _splashColor ?? value;

  @override
  void confirm() => dispose();

  @override
  void cancel() => dispose();
}
