import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_entry_ink_well.dart';
import 'app_transitions.dart';
import 'search_highlight.dart';
import 'shimmer_loading.dart';

typedef _FileTreeRowHeightKey = (
  TextStyle?,
  TextStyle?,
  TextDirection,
  TextScaler,
  double,
  int,
  int,
  bool,
  double,
);

/// Shared presentation only; callers own expansion, selection and actions.
class FileTreeRow extends StatelessWidget {
  static const int _maxCachedHeights = 64;
  static final Map<_FileTreeRowHeightKey, double> _layoutHeightCache = {};

  const FileTreeRow({
    super.key,
    required this.title,
    this.leading,
    this.subtitle,
    this.subtitleWidget,
    this.selectionControl,
    this.trailing,
    this.trailingSpacing = 8,
    this.onTap,
    this.depth = 0,
    this.minHeight = 44,
    this.titleMaxLines = 1,
    this.subtitleMaxLines = 1,
    this.reserveSubtitleSpace = false,
    this.horizontalPadding = 6,
    this.verticalPadding = 4,
    this.isFolder = false,
    this.compactTitle,
    this.emphasized = false,
    this.titleColor,
    this.backgroundColor,
    this.surfaceKey,
    this.availableWidth,
  }) : assert(subtitle == null || subtitleWidget == null);

  static const borderRadius = BorderRadius.all(Radius.circular(12));
  static const indentWidth = 16.0;

  final String title;
  final String? subtitle;
  final Widget? subtitleWidget;
  final Widget? leading;
  final Widget? selectionControl;
  final Widget? trailing;
  final double trailingSpacing;
  final VoidCallback? onTap;
  final int depth;
  final double minHeight;
  final int titleMaxLines;
  final int subtitleMaxLines;
  final bool reserveSubtitleSpace;
  final double horizontalPadding;
  final double verticalPadding;
  final bool isFolder;
  final bool? compactTitle;
  final bool emphasized;
  final Color? titleColor;
  final Color? backgroundColor;
  final Key? surfaceKey;
  final double? availableWidth;

  // Use the same text capacity for every row, regardless of the actual name
  // length or whether this particular row has a count below its name.
  static double layoutHeight(
    BuildContext context, {
    double minHeight = 44,
    int titleMaxLines = 1,
    int subtitleMaxLines = 1,
    bool reserveSubtitleSpace = false,
    double verticalPadding = 4,
  }) {
    final theme = Theme.of(context);
    final textDirection = Directionality.of(context);
    final textScaler = MediaQuery.textScalerOf(context);
    final baseTitleStyle = theme.textTheme.bodyMedium;
    final baseSubtitleStyle = reserveSubtitleSpace
        ? theme.textTheme.labelSmall
        : null;
    final cacheKey = (
      baseTitleStyle,
      baseSubtitleStyle,
      textDirection,
      textScaler,
      minHeight,
      titleMaxLines,
      subtitleMaxLines,
      reserveSubtitleSpace,
      verticalPadding,
    );
    final cached = _layoutHeightCache[cacheKey];
    if (cached != null) return cached;

    double lineHeight(TextStyle? style) {
      final painter = TextPainter(
        text: TextSpan(text: 'Ag', style: style),
        textDirection: textDirection,
        textScaler: textScaler,
      )..layout();
      final height = painter.height;
      painter.dispose();
      return height;
    }

    final titleHeight = lineHeight(
      baseTitleStyle?.copyWith(
        height: titleMaxLines > 1 ? 1.2 : null,
        fontWeight: FontWeight.w700,
      ),
    );
    final subtitleHeight = reserveSubtitleSpace
        ? lineHeight(baseSubtitleStyle) * subtitleMaxLines + 2
        : 0.0;
    final height = math.max(
      minHeight,
      math.max(
        titleHeight * titleMaxLines + subtitleHeight + verticalPadding * 2,
        titleHeight + 16 + verticalPadding * 2,
      ),
    );
    if (_layoutHeightCache.length >= _maxCachedHeights) {
      _layoutHeightCache.remove(_layoutHeightCache.keys.first);
    }
    return _layoutHeightCache[cacheKey] = height;
  }

  @override
  Widget build(BuildContext context) {
    final width = availableWidth;
    if (width != null) return _buildContent(context, width);
    return LayoutBuilder(
      builder: (context, constraints) =>
          _buildContent(context, constraints.maxWidth),
    );
  }

  Widget _buildContent(BuildContext context, double maxWidth) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final compactTitle = this.compactTitle ?? !isFolder;
    // Preserve room for names and actions even in deeply nested directories.
    final indent = math.min(
      depth * indentWidth,
      math.max(0.0, maxWidth - 240),
    );
    return Padding(
      padding: EdgeInsetsDirectional.only(start: indent),
      child: Material(
        key: surfaceKey,
        color: backgroundColor ?? Colors.transparent,
        borderRadius: borderRadius,
        clipBehavior: Clip.antiAlias,
        child: AppEntryInkWell(
          borderRadius: borderRadius,
          onTap: onTap,
          child: SizedBox(
            height: layoutHeight(
              context,
              minHeight: minHeight,
              titleMaxLines: titleMaxLines,
              subtitleMaxLines: subtitleMaxLines,
              reserveSubtitleSpace:
                  reserveSubtitleSpace ||
                  subtitle != null ||
                  subtitleWidget != null,
              verticalPadding: verticalPadding,
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: horizontalPadding,
                vertical: verticalPadding,
              ),
              child: Row(
                children: [
                  if (selectionControl != null) ...[
                    selectionControl!,
                    const SizedBox(width: 4),
                  ],
                  if (leading != null) ...[
                    leading!,
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SearchHighlightedText(
                          text: title,
                          maxLines: titleMaxLines,
                          style:
                              (theme.textTheme.bodyMedium ?? const TextStyle())
                                  .copyWith(
                                    color: titleColor ?? cs.onSurface,
                                    fontSize: compactTitle ? 13 : null,
                                    height: titleMaxLines > 1 ? 1.2 : null,
                                    fontWeight: !compactTitle || emphasized
                                        ? FontWeight.w700
                                        : FontWeight.w600,
                                  ),
                        ),
                        if (subtitle != null || subtitleWidget != null) ...[
                          const SizedBox(height: 2),
                          subtitleWidget ??
                              SearchHighlightedText(
                                text: subtitle!,
                                maxLines: subtitleMaxLines,
                                style:
                                    (theme.textTheme.labelSmall ??
                                            const TextStyle())
                                        .copyWith(
                                          color: cs.onSurfaceVariant,
                                          fontWeight: FontWeight.w700,
                                        ),
                              ),
                        ],
                      ],
                    ),
                  ),
                  if (trailing != null) ...[
                    SizedBox(width: trailingSpacing),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: math.max(
                          0.0,
                          (maxWidth - indent - horizontalPadding * 2) / 2,
                        ),
                      ),
                      child: trailing!,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class FileTreeSkeleton extends StatelessWidget {
  const FileTreeSkeleton({
    super.key,
    this.viewportHeight,
    this.padding = EdgeInsets.zero,
    this.rowHeight = 48,
    this.rowPadding = const EdgeInsets.only(left: 16, right: 12),
    this.leadingSize = 22,
    this.leadingGap = 18,
    this.shimmerEnabled = true,
  });

  final double? viewportHeight;
  final EdgeInsetsGeometry padding;
  final double rowHeight;
  final EdgeInsetsGeometry rowPadding;
  final double leadingSize;
  final double leadingGap;
  final bool shimmerEnabled;

  static const _titleFractions = [0.52, 0.68, 0.44, 0.60, 0.38, 0.55];

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final availableHeight =
          viewportHeight ??
          (constraints.hasBoundedHeight
              ? constraints.maxHeight
              : MediaQuery.sizeOf(context).height);
      final contentHeight =
          availableHeight -
          padding.resolve(Directionality.of(context)).vertical;
      final itemCount = math.max(1, (contentHeight / rowHeight).ceil());
      final placeholders = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < itemCount; i++)
            SizedBox(
              height: rowHeight,
              child: Padding(
                padding: rowPadding,
                child: Row(
                  children: [
                    ShimmerContainer(
                      width: leadingSize,
                      height: leadingSize,
                      borderRadius: 5,
                    ),
                    SizedBox(width: leadingGap),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor:
                              _titleFractions[i % _titleFractions.length],
                          child: const ShimmerContainer(height: 12),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    const ShimmerContainer(
                      width: 16,
                      height: 16,
                      borderRadius: 8,
                    ),
                  ],
                ),
              ),
            ),
        ],
      );
      final rows = shimmerEnabled
          ? ShimmerLoader(child: placeholders)
          : placeholders;
      if (viewportHeight != null) return Padding(padding: padding, child: rows);
      return SingleChildScrollView(
        primary: false,
        physics: const NeverScrollableScrollPhysics(),
        padding: padding,
        child: rows,
      );
    },
  );
}

class FileTreeExpansionArrow extends StatelessWidget {
  const FileTreeExpansionArrow({super.key, required this.expanded, this.color});

  final bool expanded;
  final Color? color;

  @override
  Widget build(BuildContext context) => AnimatedRotation(
    turns: expanded ? 0.5 : 0,
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : kAppMotionFast,
    curve: Curves.easeOutCubic,
    child: Icon(
      Icons.expand_more_rounded,
      size: 20,
      color: color ?? Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  );
}
