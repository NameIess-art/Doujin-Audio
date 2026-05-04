import 'dart:ui';

import 'package:flutter/material.dart';

class TopPageHeader extends StatelessWidget {
  const TopPageHeader({
    super.key,
    this.icon,
    required this.title,
    this.trailing,
    this.titleSuffix,
    this.subtitle,
    this.subtitleMaxLines = 2,
    this.subtitleFontSize,
    this.fitSubtitleToWidth = false,
    this.padding = const EdgeInsets.fromLTRB(24, 6, 20, 0),
    this.bottomSpacing = 10,
    this.useSafeAreaTop = true,
    this.additionalChild,
  });

  final IconData? icon;
  final String title;
  final Widget? trailing;
  final Widget? titleSuffix;
  final String? subtitle;
  final int subtitleMaxLines;
  final double? subtitleFontSize;
  final bool fitSubtitleToWidth;
  final EdgeInsetsGeometry padding;
  final double bottomSpacing;
  final bool useSafeAreaTop;
  final Widget? additionalChild;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final topPadding = useSafeAreaTop ? MediaQuery.paddingOf(context).top : 0.0;

    final headerContent = Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.5,
                      ),
                ),
              ),
              if (titleSuffix != null) ...[
                const SizedBox(width: 8),
                titleSuffix!,
              ],
              if (trailing != null) ...[const SizedBox(width: 12), trailing!],
            ],
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            LayoutBuilder(
              builder: (context, constraints) {
                final style = Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontSize: subtitleFontSize ?? 11,
                      height: 1.16,
                      color: cs.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    );
                final text = Text(
                  subtitle!,
                  maxLines: subtitleMaxLines,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: style,
                );
                if (!fitSubtitleToWidth) return text;
                return SizedBox(
                  width: constraints.maxWidth,
                  height: (subtitleFontSize ?? 11) * 1.18,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      subtitle!,
                      maxLines: 1,
                      softWrap: false,
                      style: style,
                    ),
                  ),
                );
              },
            ),
          ],
          SizedBox(height: bottomSpacing),
        ],
      ),
    );

    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          padding: EdgeInsets.only(top: topPadding),
          decoration: BoxDecoration(
            color: cs.surface.withValues(alpha: 0.65),
            border: Border(
              bottom: BorderSide(
                color: cs.outlineVariant.withValues(alpha: 0.15),
                width: 0.5,
              ),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              headerContent,
              if (additionalChild != null) additionalChild!,
            ],
          ),
        ),
      ),
    );
  }
}
