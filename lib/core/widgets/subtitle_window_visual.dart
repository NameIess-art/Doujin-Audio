import 'package:flutter/material.dart';

abstract interface class SubtitleWindowVisualStyle {
  String get fontFamily;
  Color? get fontColor;
  double get backgroundOpacity;
  Color? get backgroundColor;
  double get borderDepth;
  double get fontSize;
}

class SubtitleWindowStyle implements SubtitleWindowVisualStyle {
  const SubtitleWindowStyle({
    this.fontFamily = '',
    this.fontColor,
    this.backgroundOpacity = 0.2,
    this.backgroundColor,
    this.borderDepth = 0.5,
    this.fontSize = 16,
  });

  @override
  final String fontFamily;
  @override
  final Color? fontColor;
  @override
  final double backgroundOpacity;
  @override
  final Color? backgroundColor;
  @override
  final double borderDepth;
  @override
  final double fontSize;
}

class SubtitleWindowVisual extends StatelessWidget {
  const SubtitleWindowVisual({
    super.key,
    required this.settings,
    required this.text,
    required this.maxTextWidth,
    this.animateChanges = true,
    this.padding = const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
    this.fallbackBackgroundColor,
  });

  final SubtitleWindowVisualStyle settings;
  final String text;
  final double maxTextWidth;
  final bool animateChanges;
  final EdgeInsetsGeometry padding;
  final Color? fallbackBackgroundColor;

  @override
  Widget build(BuildContext context) {
    final fallbackSurface = fallbackBackgroundColor ?? Colors.black;
    final backgroundColor =
        settings.backgroundColor?.withValues(
          alpha: settings.backgroundOpacity,
        ) ??
        fallbackSurface.withValues(alpha: settings.backgroundOpacity);

    final borderWidth = settings.borderDepth > 0
        ? settings.borderDepth * 4
        : 0.0;

    final reducedMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final animDuration = animateChanges && !reducedMotion
        ? const Duration(milliseconds: 180)
        : Duration.zero;

    return AnimatedContainer(
      key: const ValueKey<String>('subtitle_window_visual_surface'),
      duration: animDuration,
      curve: Curves.easeOutCubic,
      padding: padding,
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(settings.fontSize * 1.2),
        border: borderWidth > 0
            ? Border.all(color: const Color(0x40FFFFFF), width: borderWidth)
            : null,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxTextWidth),
        child: AnimatedDefaultTextStyle(
          duration: animDuration,
          curve: Curves.easeOutCubic,
          style: TextStyle(
            inherit: false,
            color: settings.fontColor ?? Colors.white,
            fontWeight: FontWeight.normal,
            fontFeatures: const [FontFeature.tabularFigures()],
            fontSize: settings.fontSize,
            fontFamily: settings.fontFamily.isEmpty
                ? null
                : settings.fontFamily,
            shadows: const [
              Shadow(
                color: Color(0x80000000),
                blurRadius: 4,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: Text(text, textAlign: TextAlign.center),
        ),
      ),
    );
  }
}
