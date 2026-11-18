import 'package:flutter/material.dart';

class SettingsTileTheme extends StatelessWidget {
  const SettingsTileTheme({super.key, required this.child})
    : _titleFontSize = titleFontSize,
      _subtitleFontSize = 13,
      _titleFontWeight = null,
      _subtitleFontWeight = null;

  const SettingsTileTheme.categories({super.key, required this.child})
    : _titleFontSize = 18,
      _subtitleFontSize = 14,
      _titleFontWeight = FontWeight.bold,
      _subtitleFontWeight = FontWeight.normal;

  static const double minTileHeight = 64;
  static const double titleFontSize = 16;
  static const double leadingWidth = 40;
  static const double iconSize = 30;

  final Widget child;
  final double _titleFontSize;
  final double _subtitleFontSize;
  final FontWeight? _titleFontWeight;
  final FontWeight? _subtitleFontWeight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final titleTextStyle = theme.textTheme.titleMedium?.copyWith(
      fontSize: _titleFontSize,
      fontWeight: _titleFontWeight,
    );
    final subtitleTextStyle = theme.textTheme.bodyMedium?.copyWith(
      fontSize: _subtitleFontSize,
      fontWeight: _subtitleFontWeight,
      color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.68),
    );

    return Theme(
      data: theme.copyWith(
        textTheme: theme.textTheme.copyWith(
          titleMedium: titleTextStyle,
          bodyMedium: subtitleTextStyle,
        ),
      ),
      child: ListTileTheme.merge(
        visualDensity: const VisualDensity(horizontal: -1),
        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
        minTileHeight: minTileHeight,
        iconColor: theme.colorScheme.primary,
        minVerticalPadding: 2,
        titleTextStyle: titleTextStyle,
        subtitleTextStyle: subtitleTextStyle,
        titleAlignment: ListTileTitleAlignment.center,
        child: child,
      ),
    );
  }
}
