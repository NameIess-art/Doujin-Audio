import 'package:flutter/material.dart';

import 'playlist_shared_helpers.dart';

class SessionFeatureIconRow extends StatelessWidget {
  const SessionFeatureIconRow({
    super.key,
    required this.featureIcons,
    required this.color,
    this.iconSize = 10,
    this.spacing = 2,
    this.runSpacing = 1,
    this.maxWidth,
    this.alignment = WrapAlignment.center,
  });

  final List<IconData> featureIcons;
  final Color color;
  final double iconSize;
  final double spacing;
  final double runSpacing;
  final double? maxWidth;
  final WrapAlignment alignment;

  @override
  Widget build(BuildContext context) {
    if (featureIcons.isEmpty) {
      return const SizedBox.shrink();
    }
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var index = 0; index < featureIcons.length; index++) ...[
          if (index > 0) SizedBox(width: spacing),
          Icon(featureIcons[index], size: iconSize, color: color),
        ],
      ],
    );
    if (maxWidth == null) return row;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth!),
      child: Align(alignment: _featureIconAlignment(alignment), child: row),
    );
  }
}

Alignment _featureIconAlignment(WrapAlignment alignment) {
  return switch (alignment) {
    WrapAlignment.start => Alignment.centerLeft,
    WrapAlignment.end => Alignment.centerRight,
    _ => Alignment.center,
  };
}

class SessionFeatureBadgeStack extends StatelessWidget {
  const SessionFeatureBadgeStack({
    super.key,
    required this.featureIcons,
    required this.color,
    required this.child,
    this.width = 56,
    this.height = 64,
  });

  final List<IconData> featureIcons;
  final Color color;
  final Widget child;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final rows = splitSessionFeatureBadgeIcons(featureIcons);
    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          Positioned(
            top: 0,
            child: SessionFeatureIconRow(
              featureIcons: rows.top,
              color: color,
              maxWidth: width,
            ),
          ),
          Center(child: child),
          Positioned(
            bottom: 0,
            child: SessionFeatureIconRow(
              featureIcons: rows.bottom,
              color: color,
              maxWidth: width,
            ),
          ),
        ],
      ),
    );
  }
}
