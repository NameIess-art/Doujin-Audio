import 'dart:ui';

import 'package:flutter/material.dart';

import '../providers/subtitle_settings_provider.dart';

class SubtitleWindowVisual extends StatelessWidget {
  const SubtitleWindowVisual({
    super.key,
    required this.settings,
    required this.text,
    required this.maxTextWidth,
    this.enableBackdropBlur = true,
    this.padding = const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
    this.fallbackBackgroundColor,
  });

  final SubtitleSettingsState settings;
  final String text;
  final double maxTextWidth;
  final bool enableBackdropBlur;
  final EdgeInsetsGeometry padding;
  final Color? fallbackBackgroundColor;

  @override
  Widget build(BuildContext context) {
    final fallbackSurface =
        fallbackBackgroundColor ?? Theme.of(context).colorScheme.surface;
    final backgroundColor =
        settings.backgroundColor?.withValues(
          alpha: settings.backgroundOpacity,
        ) ??
        fallbackSurface.withValues(alpha: settings.backgroundOpacity);

    Widget container = Container(
      constraints: const BoxConstraints(minHeight: 34),
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: backgroundColor,
        border: Border(
          top: BorderSide(
            color: Colors.white.withValues(alpha: 0.1 * settings.borderDepth),
            width: settings.borderDepth,
          ),
          bottom: BorderSide(
            color: Colors.white.withValues(alpha: 0.1 * settings.borderDepth),
            width: settings.borderDepth,
          ),
        ),
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxTextWidth),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color:
                  settings.fontColor ?? Theme.of(context).colorScheme.onSurface,
              fontWeight: FontWeight.w700,
              fontSize: settings.fontSize,
              fontFamily: settings.fontFamily.isEmpty
                  ? null
                  : settings.fontFamily,
              shadows: [
                Shadow(
                  color: Colors.black.withValues(alpha: 0.5),
                  blurRadius: 4,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (!enableBackdropBlur) {
      return container;
    }

    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: settings.backgroundBlur,
          sigmaY: settings.backgroundBlur,
        ),
        child: container,
      ),
    );
  }
}
