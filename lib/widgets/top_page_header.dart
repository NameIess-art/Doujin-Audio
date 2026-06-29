import 'dart:io';
import 'dart:ui' as dart_ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/audio_provider_riverpod.dart';
import '../theme/app_design_tokens.dart';
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
    this.padding = const EdgeInsets.fromLTRB(24, 6, 20, 0),
    this.bottomSpacing = 10,
    this.useSafeAreaTop = true,
    this.additionalChild,
    this.marqueeTitle = false,
    this.forceMarqueeTitle = false,
    this.collapseController,
    this.collapseDistance = 76,
    this.floatingReveal = false,
    this.floatingRevealDistance = 64,
    this.floatingRevealTriggerDistance = 124,
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
  double _floatingReveal = 0;
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
      _floatingReveal = 0;
      _floatingRevealPendingDistance = 0;
    }
    if (!widget.floatingReveal && _floatingReveal != 0) {
      _floatingReveal = 0;
      _floatingRevealPendingDistance = 0;
      _lastOffset = null;
    }
  }

  @override
  void dispose() {
    widget.collapseController?.removeListener(_handleScrollChanged);
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
      if (_floatingReveal == 0 &&
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
          (_floatingReveal + revealDistance / widget.floatingRevealDistance)
              .clamp(0.0, 1.0);
    } else {
      _floatingRevealPendingDistance = 0;
      nextReveal = (_floatingReveal - delta / widget.floatingRevealDistance)
          .clamp(0.0, 1.0);
      if (nextReveal == 0) {
        _floatingRevealPendingDistance = 0;
      }
    }

    if (nextReveal == _floatingReveal) return;
    setState(() => _floatingReveal = nextReveal);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tokens = AppDesignTokens.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final blurEnabled = ref.watch(
      settingsStateProvider.select(
        (s) => s.valueOrNull?.uiBlurEffectEnabled ?? true,
      ),
    );
    final currentAlpha = blurEnabled ? (isDark ? 0.82 : 0.88) : 1.0;
    final topPadding = widget.useSafeAreaTop
        ? MediaQuery.paddingOf(context).top
        : 0.0;
    final resolvedTitle = widget.title;

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
        widget.padding,
        widget.collapsedPadding,
        collapseT,
      )!;
      final resolvedBottomSpacing = dart_ui.lerpDouble(
        widget.bottomSpacing,
        widget.collapsedBottomSpacing,
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
                SizedBox(height: 44 * trailingFactor),
                if (widget.leading != null) ...[
                  widget.leading!,
                  const SizedBox(width: 8),
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
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: titleStyle,
                          ),
                        ),
                ),
                if (widget.titleSuffix != null) ...[
                  const SizedBox(width: 8),
                  widget.titleSuffix!,
                ],
                if (widget.trailing != null) ...[
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
                            child: widget.trailing!,
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
                      padding: const EdgeInsets.only(top: 4),
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
                            softWrap: false,
                            overflow: TextOverflow.ellipsis,
                            style: style,
                          );
                          if (!widget.fitSubtitleToWidth) return text;
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
      if (Platform.isWindows) return 0.0;
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
      return absoluteProgress * (1 - _floatingReveal);
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
        animation: widget.collapseController ?? kAlwaysDismissedAnimation,
        builder: (context, _) {
          final collapseT = collapseProgress();
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [buildHeaderContent(collapseT), ?widget.additionalChild],
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
