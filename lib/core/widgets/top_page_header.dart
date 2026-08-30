import 'dart:ui' as dart_ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/state/app_runtime_providers.dart';
import '../../app/theme/app_design_tokens.dart';
import '../../app/theme/app_styles.dart';
import 'app_edge_fade_mask.dart';
import 'marquee_text.dart';

class AppPageAppBar extends StatelessWidget implements PreferredSizeWidget {
  const AppPageAppBar({
    super.key,
    required this.title,
    this.leading,
    this.actions,
    this.automaticallyImplyLeading = true,
    this.titleSpacing,
    this.useGlassSurface = true,
  });

  final Widget title;
  final Widget? leading;
  final List<Widget>? actions;
  final bool automaticallyImplyLeading;
  final double? titleSpacing;
  final bool useGlassSurface;

  @override
  Size get preferredSize =>
      const Size.fromHeight(AppPageHeaderMetrics.toolbarHeight);

  @override
  Widget build(BuildContext context) {
    final appBar = AppBar(
      title: title,
      leading: leading,
      actions: actions,
      automaticallyImplyLeading: automaticallyImplyLeading,
      titleSpacing: titleSpacing,
      toolbarHeight: AppPageHeaderMetrics.toolbarHeight,
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      forceMaterialTransparency: true,
    );
    if (!useGlassSurface) return appBar;
    return _AppHeaderGlassSurface(child: appBar);
  }
}

class TopPageHeader extends ConsumerStatefulWidget {
  const TopPageHeader({
    super.key,
    this.icon,
    required this.title,
    this.titleWidget,
    this.leading,
    this.trailing,
    this.titleSuffix,
    this.subtitle,
    this.subtitleMaxLines = 1,
    this.subtitleFontSize,
    this.fitSubtitleToWidth = false,
    this.padding = AppPageHeaderMetrics.padding,
    this.bottomSpacing = AppPageHeaderMetrics.bottomSpacing,
    this.useSafeAreaTop = true,
    this.additionalChild,
    this.marqueeTitle = false,
    this.forceMarqueeTitle = false,
    this.onTitleSwipeLeft,
    this.onTitleSwipeRight,
    this.collapseController,
    this.collapseDistance = 56,
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
    this.floating = false,
    this.topCapsuleTitle,
    this.topCapsuleData,
    this.topCapsuleLeading,
    this.topCapsuleTrailing,
    this.topCapsuleChild,
  });

  final IconData? icon;
  final String title;
  final Widget? titleWidget;
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
  final VoidCallback? onTitleSwipeLeft;
  final VoidCallback? onTitleSwipeRight;
  final ScrollController? collapseController;
  final double collapseDistance;
  final bool floatingReveal;
  final double floatingRevealDistance;
  final double floatingRevealTriggerDistance;
  final EdgeInsetsGeometry collapsedPadding;
  final double collapsedBottomSpacing;
  final bool floating;
  final String? topCapsuleTitle;
  final String? topCapsuleData;
  final Widget? topCapsuleLeading;
  final Widget? topCapsuleTrailing;
  final Widget? topCapsuleChild;

  @override
  ConsumerState<TopPageHeader> createState() => _TopPageHeaderState();
}

class _TopPageHeaderState extends ConsumerState<TopPageHeader> {
  static const double _titleSwipeDistance = 32;
  static const double _titleSwipeVelocity = 250;
  final ValueNotifier<double> _floatingReveal = ValueNotifier<double>(0);
  double _titleDragDistance = 0;
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

  void _handleTitleDragStart(DragStartDetails details) {
    _titleDragDistance = 0;
  }

  void _handleTitleDragUpdate(DragUpdateDetails details) {
    _titleDragDistance += details.primaryDelta ?? 0;
  }

  void _handleTitleDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    final isLeft =
        _titleDragDistance <= -_titleSwipeDistance ||
        velocity <= -_titleSwipeVelocity;
    final isRight =
        _titleDragDistance >= _titleSwipeDistance ||
        velocity >= _titleSwipeVelocity;
    _titleDragDistance = 0;
    if (isLeft) {
      widget.onTitleSwipeLeft?.call();
    } else if (isRight) {
      widget.onTitleSwipeRight?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final topPadding = widget.useSafeAreaTop
        ? MediaQuery.paddingOf(context).top
        : 0.0;
    final resolvedTitle = widget.title;

    Widget buildHeaderContent(double collapseT) {
      final hasTopCapsule =
          widget.topCapsuleTitle != null || widget.topCapsuleChild != null;
      final hasMainRow =
          widget.title.isNotEmpty ||
          widget.titleWidget != null ||
          widget.leading != null ||
          widget.trailing != null;

      final mainCollapseT = hasTopCapsule ? 0.0 : collapseT;
      final titleCollapseT = Curves.easeOutCubic.transform(mainCollapseT);
      final auxiliaryCollapseT = Curves.easeInOutCubic.transform(mainCollapseT);
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

      final topCapsuleFactor =
          (1.0 - Curves.easeOutCubic.transform(collapseT)).clamp(0.0, 1.0);
      final topCapsuleWidget = widget.topCapsuleChild ??
          (widget.topCapsuleTitle != null
              ? HeaderTopCapsule(
                  title: widget.topCapsuleTitle!,
                  data: widget.topCapsuleData,
                  leading: widget.topCapsuleLeading,
                  trailing: widget.topCapsuleTrailing,
                )
              : null);

      Widget buildTopCapsule() {
        if (topCapsuleWidget == null) return const SizedBox.shrink();
        final isMainTabPadded =
            widget.padding is EdgeInsets &&
            (widget.padding as EdgeInsets).right < 12;
        return ClipRect(
          child: Align(
            alignment: Alignment.topCenter,
            heightFactor: topCapsuleFactor,
            child: Opacity(
              opacity: topCapsuleFactor,
              child: Padding(
                padding: EdgeInsets.only(
                  right: isMainTabPadded ? 8.0 : 0.0,
                  bottom: hasMainRow ? (6.0 * topCapsuleFactor) : 0.0,
                ),
                child: topCapsuleWidget,
              ),
            ),
          ),
        );
      }

      return Padding(
        padding: resolvedPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (hasTopCapsule) buildTopCapsule(),
            if (hasMainRow) ...[
              Row(
                children: [
                  SizedBox(
                    height: AppPageHeaderMetrics.contentHeight * trailingFactor,
                  ),
                  if (widget.leading != null) ...[
                    SizedBox.square(
                      dimension: AppPageHeaderMetrics.contentHeight,
                      child: widget.leading!,
                    ),
                    const SizedBox(width: AppSpacing.xs),
                  ],
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Builder(
                        builder: (context) {
                          final hasSwipe =
                              widget.titleWidget == null &&
                              (widget.onTitleSwipeLeft != null ||
                                  widget.onTitleSwipeRight != null);
                          return GestureDetector(
                            behavior: hasSwipe
                                ? HitTestBehavior.opaque
                                : HitTestBehavior.deferToChild,
                            onHorizontalDragStart: hasSwipe
                                ? _handleTitleDragStart
                                : null,
                            onHorizontalDragUpdate: hasSwipe
                                ? _handleTitleDragUpdate
                                : null,
                            onHorizontalDragEnd: hasSwipe
                                ? _handleTitleDragEnd
                                : null,
                            child: widget.titleWidget != null
                                ? Semantics(
                                    header: true,
                                    label: resolvedTitle,
                                    child: DefaultTextStyle.merge(
                                      style: titleStyle,
                                      child: widget.titleWidget!,
                                    ),
                                  )
                                : widget.marqueeTitle
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
                          );
                        },
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
            ],
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

    final headerContent = Padding(
      padding: EdgeInsets.only(top: topPadding),
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
    return _AppHeaderGlassSurface(
      floating: widget.floating,
      child: headerContent,
    );
  }
}

class _AppHeaderGlassSurface extends ConsumerWidget {
  const _AppHeaderGlassSurface({
    required this.child,
    this.floating = false,
  });

  final Widget child;
  final bool floating;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (floating) {
      return Stack(
        fit: StackFit.passthrough,
        children: [
          const Positioned.fill(
            child: AppEdgeFadeMask(
              direction: AppEdgeFadeDirection.towardTop,
            ),
          ),
          child,
        ],
      );
    }
    final cs = Theme.of(context).colorScheme;
    final tokens = AppDesignTokens.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final blurEnabled = ref.watch(
      settingsStateProvider.select((s) => s.value?.uiBlurEffectEnabled ?? true),
    );
    final surface = DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surface.withValues(
          alpha: blurEnabled ? (isDark ? 0.72 : 0.78) : 1.0,
        ),
        border: Border(
          bottom: BorderSide(
            color: cs.outlineVariant.withValues(
              alpha: tokens.subtleBorderAlpha,
            ),
            width: 0.5,
          ),
        ),
      ),
      child: child,
    );
    if (!blurEnabled) return surface;
    return RepaintBoundary(
      child: ClipRect(
        child: BackdropFilter(
          key: const ValueKey<String>('app_page_header_blur'),
          filter: dart_ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: surface,
        ),
      ),
    );
  }
}

class HeaderFloatingSurface extends ConsumerWidget {
  const HeaderFloatingSurface({
    super.key,
    required this.child,
    this.radius = 19,
    this.height = 38,
    this.width,
    this.padding,
  });

  final Widget child;
  final double radius;
  final double? height;
  final double? width;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final blurEnabled = ref.watch(
      settingsStateProvider.select((s) => s.value?.uiBlurEffectEnabled ?? true),
    );
    final background = isDark ? cs.surfaceBright : cs.surfaceContainerHigh;
    final borderRadius = BorderRadius.circular(radius);
    final surface = DecoratedBox(
      decoration: BoxDecoration(
        color: background.withValues(
          alpha: blurEnabled ? (isDark ? 0.70 : 0.75) : 1.0,
        ),
        borderRadius: borderRadius,
        border: Border.all(
          color: cs.outlineVariant.withValues(alpha: isDark ? 0.24 : 0.42),
        ),
      ),
      child: padding != null ? Padding(padding: padding!, child: child) : child,
    );

    final content = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: [
          BoxShadow(
            color: cs.shadow.withValues(alpha: 0.14),
            blurRadius: 18,
            spreadRadius: -5,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: blurEnabled
            ? BackdropFilter(
                filter: dart_ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                child: surface,
              )
            : surface,
      ),
    );

    if (width != null || height != null) {
      return SizedBox(
        width: width,
        height: height,
        child: content,
      );
    }
    return content;
  }
}

class HeaderFloatingButton extends StatelessWidget {
  const HeaderFloatingButton({
    super.key,
    required this.child,
    this.size = 38,
  });

  final Widget child;
  final double size;

  @override
  Widget build(BuildContext context) {
    return HeaderFloatingSurface(
      width: size,
      height: size,
      radius: size / 2,
      child: Center(child: child),
    );
  }
}

class HeaderActionPill extends StatelessWidget {
  const HeaderActionPill({
    super.key,
    required this.children,
    this.padding = const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
  });

  final List<Widget> children;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: HeaderFloatingSurface(
        padding: padding,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: children,
        ),
      ),
    );
  }
}

class HeaderSegmentedCategoryBar<T> extends StatelessWidget {
  const HeaderSegmentedCategoryBar({
    super.key,
    required this.items,
    required this.selected,
    required this.onSelected,
    required this.labelBuilder,
  });

  final List<T> items;
  final T selected;
  final ValueChanged<T> onSelected;
  final String Function(T item) labelBuilder;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Align(
      alignment: Alignment.centerLeft,
      child: HeaderFloatingSurface(
        padding: const EdgeInsets.all(3),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: items.map((item) {
              final isSelected = item == selected;
              final label = labelBuilder(item);
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1.5),
                child: Material(
                  color: isSelected
                      ? cs.primary.withValues(alpha: 0.16)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(15),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(15),
                    onTap: () => onSelected(item),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8.5,
                        vertical: 4,
                      ),
                      child: Center(
                        child: Text(
                          label,
                          style: textTheme.labelMedium?.copyWith(
                            color: isSelected
                                ? cs.primary
                                : cs.onSurfaceVariant.withValues(alpha: 0.85),
                            fontWeight: isSelected
                                ? FontWeight.w700
                                : FontWeight.w500,
                            fontSize: 12.5,
                            letterSpacing: 0,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }).toList(growable: false),
          ),
        ),
      ),
    );
  }
}

class HeaderTopCapsule extends StatelessWidget {
  const HeaderTopCapsule({
    super.key,
    required this.title,
    this.data,
    this.leading,
    this.trailing,
    this.height = 36,
  });

  final String title;
  final String? data;
  final Widget? leading;
  final Widget? trailing;
  final double height;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return HeaderFloatingSurface(
      height: height,
      radius: height / 2,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (leading != null) ...[
                leading!,
                const SizedBox(width: 6),
              ],
              Text(
                title,
                style: textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: cs.onSurface,
                  fontSize: 13.5,
                  letterSpacing: 0.1,
                ),
              ),
            ],
          ),
          if (trailing != null)
            trailing!
          else if (data != null && data!.isNotEmpty)
            Text(
              data!,
              style: textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: cs.onSurfaceVariant.withValues(alpha: 0.85),
                fontSize: 11.5,
                letterSpacing: 0,
              ),
            ),
        ],
      ),
    );
  }
}

