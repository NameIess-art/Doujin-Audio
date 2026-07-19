import 'package:flutter/material.dart';

import '../../app/state/subtitle_settings_provider.dart';

class SubtitleWindowVisual extends StatelessWidget {
  const SubtitleWindowVisual({
    super.key,
    required this.settings,
    required this.text,
    required this.maxTextWidth,
    this.padding = const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
    this.fallbackBackgroundColor,
  });

  final SubtitleSettingsState settings;
  final String text;
  final double maxTextWidth;
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

    return Container(
      key: const ValueKey<String>('subtitle_window_visual_surface'),
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
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            inherit: false,
            color: settings.fontColor ?? Colors.white,
            fontWeight: FontWeight.normal,
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
        ),
      ),
    );
  }
}
