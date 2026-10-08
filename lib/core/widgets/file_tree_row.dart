import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_transitions.dart';
import 'search_highlight.dart';

/// Shared presentation only; callers own expansion, selection and actions.
class FileTreeRow extends StatelessWidget {
  const FileTreeRow({
    super.key,
    required this.title,
    this.leading,
    this.subtitle,
    this.selectionControl,
    this.trailing,
    this.onTap,
    this.depth = 0,
    this.minHeight = 44,
    this.titleMaxLines = 1,
    this.subtitleMaxLines = 1,
    this.reserveSubtitleSpace = false,
    this.verticalPadding = 4,
    this.isFolder = false,
    this.emphasized = false,
    this.titleColor,
    this.backgroundColor,
    this.surfaceKey,
  });

  static const borderRadius = BorderRadius.all(Radius.circular(12));
  static const indentWidth = 16.0;

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? selectionControl;
  final Widget? trailing;
  final VoidCallback? onTap;
  final int depth;
  final double minHeight;
  final int titleMaxLines;
  final int subtitleMaxLines;
  final bool reserveSubtitleSpace;
  final double verticalPadding;
  final bool isFolder;
  final bool emphasized;
  final Color? titleColor;
  final Color? backgroundColor;
  final Key? surfaceKey;

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
    double lineHeight(TextStyle? style) {
      final painter = TextPainter(
        text: TextSpan(text: 'Ag', style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout();
      final height = painter.height;
      painter.dispose();
      return height;
    }

    final titleHeight = lineHeight(
      theme.textTheme.bodyMedium?.copyWith(
        height: titleMaxLines > 1 ? 1.2 : null,
        fontWeight: FontWeight.w700,
      ),
    );
    final subtitleHeight = reserveSubtitleSpace
        ? lineHeight(theme.textTheme.labelSmall) * subtitleMaxLines + 2
        : 0.0;
    return math.max(
      minHeight,
      math.max(
        titleHeight * titleMaxLines + subtitleHeight + verticalPadding * 2,
        titleHeight + 16 + verticalPadding * 2,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final theme = Theme.of(context);
      final cs = theme.colorScheme;
      // Preserve room for names and actions even in deeply nested directories.
      final indent = math.min(
        depth * indentWidth,
        math.max(0.0, constraints.maxWidth - 240),
      );
      return Padding(
        padding: EdgeInsetsDirectional.only(start: indent),
        child: Material(
          key: surfaceKey,
          color: backgroundColor ?? Colors.transparent,
          borderRadius: borderRadius,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            borderRadius: borderRadius,
            onTap: onTap,
            child: SizedBox(
              height: layoutHeight(
                context,
                minHeight: minHeight,
                titleMaxLines: titleMaxLines,
                subtitleMaxLines: subtitleMaxLines,
                reserveSubtitleSpace: reserveSubtitleSpace || subtitle != null,
                verticalPadding: verticalPadding,
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: 6,
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
                                (theme.textTheme.bodyMedium ??
                                        const TextStyle())
                                    .copyWith(
                                      color: titleColor ?? cs.onSurface,
                                      fontSize: isFolder ? null : 13,
                                      height: titleMaxLines > 1 ? 1.2 : null,
                                      fontWeight: isFolder || emphasized
                                          ? FontWeight.w700
                                          : FontWeight.w600,
                                    ),
                          ),
                          if (subtitle != null) ...[
                            const SizedBox(height: 2),
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
                      const SizedBox(width: 8),
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: math.max(
                            0.0,
                            (constraints.maxWidth - indent - 12) / 2,
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
