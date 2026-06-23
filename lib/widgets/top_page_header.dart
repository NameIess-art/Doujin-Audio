import 'dart:ui' as dart_ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:provider/provider.dart' hide Consumer;

import '../i18n/app_language_provider.dart';
import '../providers/audio_provider_riverpod.dart';
import 'marquee_text.dart';

class TopPageHeader extends ConsumerWidget {
  const TopPageHeader({
    super.key,
    this.icon,
    required this.title,
    this.leading,
    this.trailing,
    this.titleSuffix,
    this.subtitle,
    this.subtitleMaxLines = 1,
    this.subtitleFontSize,
    this.fitSubtitleToWidth = false,
    this.padding = const EdgeInsets.fromLTRB(24, 6, 20, 0),
    this.bottomSpacing = 10,
    this.useSafeAreaTop = true,
    this.additionalChild,
    this.isLoading = false,
    this.marqueeTitle = false,
    this.forceMarqueeTitle = false,
    this.collapseController,
    this.collapseDistance = 76,
    this.collapsedPadding = const EdgeInsets.fromLTRB(16, 4, 12, 0),
    this.collapsedBottomSpacing = 6,
  });

  final IconData? icon;
  final String title;
  final Widget? leading;
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
  final bool isLoading;
  final bool marqueeTitle;
  final bool forceMarqueeTitle;
  final ScrollController? collapseController;
  final double collapseDistance;
  final EdgeInsetsGeometry collapsedPadding;
  final double collapsedBottomSpacing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final blurEnabled = ref.watch(
      settingsStateProvider.select(
        (s) => s.valueOrNull?.uiBlurEffectEnabled ?? true,
      ),
    );
    final currentAlpha = blurEnabled ? (isDark ? 0.82 : 0.88) : 0.95;
    final i18n = context.watch<AppLanguageProvider>();
    final topPadding = useSafeAreaTop ? MediaQuery.paddingOf(context).top : 0.0;
    final resolvedTitle = isLoading ? i18n.tr('loading_dot') : title;

    Widget buildHeaderContent(double collapseT) {
      final expandedTitleStyle = Theme.of(context).textTheme.headlineMedium
          ?.copyWith(fontWeight: FontWeight.w800, letterSpacing: 0);
      final collapsedTitleStyle = Theme.of(context).textTheme.titleMedium
          ?.copyWith(fontWeight: FontWeight.w800, letterSpacing: 0);
      final titleStyle =
          TextStyle.lerp(expandedTitleStyle, collapsedTitleStyle, collapseT) ??
          expandedTitleStyle;
      final titleHeight =
          (titleStyle?.fontSize ?? 28) * (titleStyle?.height ?? 1.2);
      final resolvedPadding = EdgeInsetsGeometry.lerp(
        padding,
        collapsedPadding,
        collapseT,
      )!;
      final resolvedBottomSpacing = dart_ui.lerpDouble(
        bottomSpacing,
        collapsedBottomSpacing,
        collapseT,
      )!;
      final subtitleFactor = 1 - collapseT;
      final trailingFactor = 1 - collapseT;

      return Padding(
        padding: resolvedPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (leading != null) ...[leading!, const SizedBox(width: 8)],
                Expanded(
                  child: marqueeTitle
                      ? SizedBox(
                          height: titleHeight,
                          child: MarqueeText(
                            text: resolvedTitle,
                            style: titleStyle,
                            scrollSpeed: 24,
                            edgePadding: 2,
                            forceMarquee: forceMarqueeTitle,
                          ),
                        )
                      : Semantics(
                          header: true,
                          child: Text(
                            resolvedTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: titleStyle,
                          ),
                        ),
                ),
                if (titleSuffix != null) ...[
                  const SizedBox(width: 8),
                  titleSuffix!,
                ],
                if (trailing != null) ...[
                  SizedBox(width: 12 * trailingFactor),
                  ClipRect(
                    child: Align(
                      widthFactor: trailingFactor,
                      heightFactor: trailingFactor,
                      alignment: Alignment.centerRight,
                      child: Opacity(
                        opacity: trailingFactor,
                        child: IgnorePointer(
                          ignoring: trailingFactor < 0.05,
                          child: ExcludeSemantics(
                            excluding: trailingFactor < 0.05,
                            child: trailing!,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
            if (subtitle != null)
              ClipRect(
                child: Align(
                  heightFactor: subtitleFactor,
                  alignment: Alignment.topLeft,
                  child: Opacity(
                    opacity: subtitleFactor,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final style = Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
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
                    ),
                  ),
                ),
              ),
            SizedBox(height: resolvedBottomSpacing),
          ],
        ),
      );
    }

    double collapseProgress() {
      final controller = collapseController;
      if (controller == null || !controller.hasClients) return 0;
      if (collapseDistance <= 0) return 1;
      final offset = controller.positions.length == 1
          ? controller.positions.single.pixels
          : 0.0;
      return (offset / collapseDistance).clamp(0.0, 1.0);
    }

    Widget headerContainer = Container(
      padding: EdgeInsets.only(top: topPadding),
      decoration: BoxDecoration(
        color: cs.surface.withValues(alpha: currentAlpha),
        border: Border(
          bottom: BorderSide(
            color: cs.outlineVariant.withValues(alpha: 0.15),
            width: 0.5,
          ),
        ),
      ),
      child: AnimatedBuilder(
        animation: collapseController ?? kAlwaysDismissedAnimation,
        builder: (context, _) {
          final collapseT = collapseProgress();
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [buildHeaderContent(collapseT), ?additionalChild],
          );
        },
      ),
    );

    if (blurEnabled) {
      return RepaintBoundary(
        child: ClipRect(
          child: BackdropFilter(
            filter: dart_ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: headerContainer,
          ),
        ),
      );
    }
    return headerContainer;
  }
}
