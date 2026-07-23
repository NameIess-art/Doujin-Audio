import 'dart:ui' as dart_ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/state/app_runtime_providers.dart';
import '../../app/theme/app_design_tokens.dart';
import '../../app/theme/app_styles.dart';
import 'marquee_text.dart';

class TopPageHeader extends ConsumerStatefulWidget {
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
    this.padding = const EdgeInsets.fromLTRB(
      AppSpacing.xl,
      AppSpacing.xs,
      AppSpacing.lg,
      0,
    ),
    this.bottomSpacing = AppSpacing.sm,
    this.useSafeAreaTop = true,
    this.additionalChild,
    this.marqueeTitle = false,
    this.forceMarqueeTitle = false,
    this.collapseController,
    this.collapseDistance = 76,
    this.floatingReveal = false,
    this.floatingRevealDistance = 64,
    this.floatingRevealTriggerDistance = 124,
    this.collapsedPadding = const EdgeInsets.fromLTRB(
      AppSpacing.md,
      AppSpacing.xxs,
      AppSpacing.sm,
      0,
    ),
    this.collapsedBottomSpacing = AppSpacing.xs,
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
  final bool marqueeTitle;
  final bool forceMarqueeTitle;
  final ScrollController? collapseController;
  final double collapseDistance;
  final bool floatingReveal;
  final double floatingRevealDistance;
  final double floatingRevealTriggerDistance;
  final EdgeInsetsGeometry collapsedPadding;
  final double collapsedBottomSpacing;

  @override
  ConsumerState<TopPageHeader> createState() => _TopPageHeaderState();
}

class _TopPageHeaderState extends ConsumerState<TopPageHeader> {
  final ValueNotifier<double> _floatingReveal = ValueNotifier<double>(0);
  double _floatingRevealPendingDistance = 0;
  double? _lastOffset;

  @override
  void initState() {
    super.initState();
    widget.collapseController?.addListener(_handleScrollChanged);
  }

  @override
  void didUpdateWidget(covariant TopPageHeader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.collapseController != widget.collapseController) {
      oldWidget.collapseController?.removeListener(_handleScrollChanged);
      widget.collapseController?.addListener(_handleScrollChanged);
      _lastOffset = null;
      _floatingReveal.value = 0;
      _floatingRevealPendingDistance = 0;
    }
    if (!widget.floatingReveal && _floatingReveal.value != 0) {
      _floatingReveal.value = 0;
      _floatingRevealPendingDistance = 0;
      _lastOffset = null;
    }
  }

  @override
  void dispose() {
    widget.collapseController?.removeListener(_handleScrollChanged);
    _floatingReveal.dispose();
    super.dispose();
  }

  void _handleScrollChanged() {
    if (!widget.floatingReveal || widget.floatingRevealDistance <= 0) {
      _lastOffset = null;
      _floatingRevealPendingDistance = 0;
      return;
    }
    final controller = widget.collapseController;
    if (controller == null || controller.positions.length != 1) {
      _lastOffset = null;
      _floatingRevealPendingDistance = 0;
      return;
    }

    final offset = controller.positions.single.pixels;
    final lastOffset = _lastOffset;
    _lastOffset = offset;
    if (lastOffset == null) return;

    final delta = offset - lastOffset;
    if (delta == 0) return;

    double nextReveal;
    if (delta < 0) {
      var revealDistance = -delta;
      if (_floatingReveal.value == 0 &&
          _floatingRevealPendingDistance <
              widget.floatingRevealTriggerDistance) {
        final remainingTrigger =
            widget.floatingRevealTriggerDistance -
            _floatingRevealPendingDistance;
        if (revealDistance <= remainingTrigger) {
          _floatingRevealPendingDistance += revealDistance;
          return;
        }
        _floatingRevealPendingDistance = widget.floatingRevealTriggerDistance;
        revealDistance -= remainingTrigger;
      }
      nextReveal =
          (_floatingReveal.value +
                  revealDistance / widget.floatingRevealDistance)
              .clamp(0.0, 1.0);
    } else {
      _floatingRevealPendingDistance = 0;
      nextReveal =
          (_floatingReveal.value - delta / widget.floatingRevealDistance).clamp(
            0.0,
            1.0,
          );
      if (nextReveal == 0) {
        _floatingRevealPendingDistance = 0;
      }
    }

    if (nextReveal == _floatingReveal.value) return;
    _floatingReveal.value = nextReveal;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tokens = AppDesignTokens.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final blurEnabled = ref.watch(
      settingsStateProvider.select((s) => s.value?.uiBlurEffectEnabled ?? true),
    );
    final useBlur = blurEnabled;
    final currentAlpha = useBlur ? (isDark ? 0.82 : 0.88) : 1.0;
    final topPadding = widget.useSafeAreaTop
        ? MediaQuery.paddingOf(context).top
        : 0.0;
    final resolvedTitle = widget.title;

    Widget buildHeaderContent(double collapseT) {
      final titleCollapseT = Curves.easeOutCubic.transform(collapseT);
      final auxiliaryCollapseT = Curves.easeInOutCubic.transform(collapseT);
      final expandedTitleStyle = Theme.of(context).textTheme.headlineMedium
          ?.copyWith(fontWeight: FontWeight.w800, letterSpacing: 0);
      final collapsedTitleStyle = Theme.of(context).textTheme.titleMedium
          ?.copyWith(fontWeight: FontWeight.w800, letterSpacing: 0);
      final titleStyle =
          TextStyle.lerp(
            expandedTitleStyle,
            collapsedTitleStyle,
            titleCollapseT,
          ) ??
          expandedTitleStyle;
      final titleHeight =
          (titleStyle?.fontSize ?? 28) * (titleStyle?.height ?? 1.2);
      final resolvedPadding = EdgeInsetsGeometry.lerp(
        widget.padding,
        widget.collapsedPadding,
        titleCollapseT,
      )!;
      final resolvedBottomSpacing = dart_ui.lerpDouble(
        widget.bottomSpacing,
        widget.collapsedBottomSpacing,
        titleCollapseT,
      )!;
      final subtitleFactor = 1 - auxiliaryCollapseT;
      final trailingFactor = 1 - auxiliaryCollapseT;
      final trailingOffset = (1 - trailingFactor) * 6;
      final prefersExpandedText =
          MediaQuery.textScalerOf(context).scale(1) > 1.3;

      return Padding(
        padding: resolvedPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SizedBox(height: 44 * trailingFactor),
                if (widget.leading != null) ...[
                  widget.leading!,
                  const SizedBox(width: AppSpacing.xs),
                ],
                Expanded(
                  child: widget.marqueeTitle
                      ? SizedBox(
                          height: titleHeight,
                          child: MarqueeText(
                            text: resolvedTitle,
                            style: titleStyle,
                            scrollSpeed: 24,
                            edgePadding: 2,
                            forceMarquee: widget.forceMarqueeTitle,
                          ),
                        )
                      : Semantics(
                          header: true,
                          child: Text(
                            resolvedTitle,
                            maxLines: prefersExpandedText ? 2 : 1,
                            overflow: TextOverflow.ellipsis,
                            style: titleStyle,
                          ),
                        ),
                ),
                if (widget.titleSuffix != null) ...[
                  const SizedBox(width: AppSpacing.xs),
                  widget.titleSuffix!,
                ],
                if (widget.trailing != null) ...[
                  SizedBox(width: AppSpacing.sm * trailingFactor),
                  ClipRect(
                    child: Align(
                      widthFactor: trailingFactor,
                      heightFactor: trailingFactor,
                      alignment: Alignment.centerRight,
                      child: Opacity(
                        opacity: trailingFactor,
                        child: Transform.translate(
                          offset: Offset(trailingOffset, 0),
                          child: IgnorePointer(
                            ignoring: trailingFactor < 0.05,
                            child: ExcludeSemantics(
                              excluding: trailingFactor < 0.05,
                              child: widget.trailing!,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
            if (widget.subtitle != null)
              ClipRect(
                child: Align(
                  heightFactor: subtitleFactor,
                  alignment: Alignment.topLeft,
                  child: Opacity(
                    opacity: subtitleFactor,
                    child: Padding(
                      padding: const EdgeInsets.only(top: AppSpacing.xxs),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final style = Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                fontSize: widget.subtitleFontSize ?? 11,
                                height: 1.16,
                                color: cs.onSurfaceVariant,
                                fontWeight: FontWeight.w600,
                              );
                          final text = Text(
                            widget.subtitle!,
                            maxLines: widget.subtitleMaxLines,
                            softWrap: prefersExpandedText,
                            overflow: TextOverflow.ellipsis,
                            style: style,
                          );
                          if (!widget.fitSubtitleToWidth ||
                              prefersExpandedText) {
                            return text;
                          }
                          return SizedBox(
                            width: constraints.maxWidth,
                            height: (widget.subtitleFontSize ?? 11) * 1.18,
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Text(
                                widget.subtitle!,
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
      final controller = widget.collapseController;
      if (controller == null || !controller.hasClients) return 0;
      if (widget.collapseDistance <= 0) return 1;
      final offset = controller.positions.length == 1
          ? controller.positions.single.pixels
          : 0.0;
      final absoluteProgress = (offset / widget.collapseDistance).clamp(
        0.0,
        1.0,
      );
      return absoluteProgress * (1 - _floatingReveal.value);
    }

    Widget headerContainer = Container(
      padding: EdgeInsets.only(top: topPadding),
      decoration: BoxDecoration(
        color: cs.surface.withValues(alpha: currentAlpha),
        border: Border(
          bottom: BorderSide(
            color: cs.outlineVariant.withValues(
              alpha: tokens.subtleBorderAlpha,
            ),
            width: 0.5,
          ),
        ),
      ),
      child: AnimatedBuilder(
        animation: Listenable.merge(<Listenable>[
          widget.collapseController ?? kAlwaysDismissedAnimation,
          _floatingReveal,
        ]),
        child: widget.additionalChild,
        builder: (context, additionalChild) {
          final collapseT = collapseProgress();
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [buildHeaderContent(collapseT), ?additionalChild],
          );
        },
      ),
    );

    if (useBlur) {
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
