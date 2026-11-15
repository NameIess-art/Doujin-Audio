import 'dart:math' as math;
import 'dart:ui' as dart_ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'app_buttons.dart';

import '../../app/theme/app_design_tokens.dart';
import '../../app/theme/app_styles.dart';
import 'app_edge_fade_mask.dart';
import 'app_glass_surface.dart';
import 'app_transitions.dart';
import 'marquee_text.dart';
import 'sliding_selection_indicator.dart';
import 'unified_popup_menu.dart';
import 'windows_horizontal_wheel_scroll.dart';

class AppPageAppBar extends StatelessWidget implements PreferredSizeWidget {
  const AppPageAppBar({
    super.key,
    required this.title,
    this.icon,
    this.iconColor,
    this.leading,
    this.actions,
    this.automaticallyImplyLeading = true,
    this.titleSpacing,
  });

  final Widget title;
  final IconData? icon;
  final Color? iconColor;
  final Widget? leading;
  final List<Widget>? actions;
  final bool automaticallyImplyLeading;
  final double? titleSpacing;

  @override
  Size get preferredSize =>
      const Size.fromHeight(AppPageHeaderMetrics.toolbarHeight);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget resolvedTitle = title;
    if (icon != null) {
      resolvedTitle = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: AppDesignTokens.opticalIconSize(icon, 18),
            color: iconColor ?? cs.primary,
          ),
          const SizedBox(width: 8),
          Flexible(child: title),
        ],
      );
    }
    final appBar = AppBar(
      title: resolvedTitle,
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
    return AppPageHeaderTransition(
      child: _AppHeaderSurface(floating: false, child: appBar),
    );
  }
}

class TopPageHeader extends StatefulWidget {
  const TopPageHeader({
    super.key,
    this.icon,
    this.iconColor,
    this.title = '',
    this.titleWidget,
    this.leading,
    this.trailing,
    this.titleSuffix,
    this.subtitle,
    this.subtitleMaxLines = 1,
    this.subtitleFontSize,
    this.fitSubtitleToWidth = false,
    this.padding = AppPageHeaderMetrics.padding,
    this.useSafeAreaTop = true,
    this.additionalChild,
    this.marqueeTitle = false,
    this.forceMarqueeTitle = false,
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
    this.floating = true,
    this.showFadeMask = true,
    this.topCapsuleTitle,
    this.topCapsuleData,
    this.topCapsuleLeading,
    this.topCapsuleTrailing,
    this.topCapsuleChild,
  });

  final IconData? icon;
  final Color? iconColor;
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
  final bool floating;
  final bool showFadeMask;
  final String? topCapsuleTitle;
  final String? topCapsuleData;
  final Widget? topCapsuleLeading;
  final Widget? topCapsuleTrailing;
  final Widget? topCapsuleChild;

  @override
  State<TopPageHeader> createState() => _TopPageHeaderState();
}

class _TopPageHeaderState extends State<TopPageHeader> {
  static double _stableTopPadding = 0;
  final ValueNotifier<double> _collapseProgress = ValueNotifier<double>(0);
  final BackdropKey _rowBackdropKey = BackdropKey();
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
    _updateCollapseProgress();
  }

  @override
  void dispose() {
    widget.collapseController?.removeListener(_handleScrollChanged);
    _collapseProgress.dispose();
    super.dispose();
  }

  void _handleScrollChanged() {
    _updateFloatingReveal();
    _updateCollapseProgress();
  }

  void _updateCollapseProgress() {
    final controller = widget.collapseController;
    var progress = 0.0;
    if (controller != null && controller.hasClients) {
      final offset = controller.positions.length == 1
          ? controller.positions.single.pixels
          : 0.0;
      final absoluteProgress = widget.collapseDistance <= 0
          ? 1.0
          : (offset / widget.collapseDistance).clamp(0.0, 1.0);
      progress = absoluteProgress * (1 - _floatingReveal);
    }
    // Fully collapsed/expanded headers need no work for further scroll ticks.
    _collapseProgress.value = progress;
  }

  void _updateFloatingReveal() {
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
    _floatingReveal = nextReveal;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isWindows = theme.platform == TargetPlatform.windows;
    final isLandscape =
        defaultTargetPlatform == TargetPlatform.windows ||
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final rawTop = MediaQuery.paddingOf(context).top;
    if (!isLandscape && rawTop > _stableTopPadding) {
      _stableTopPadding = rawTop;
    }
    final resolvedTop = !isLandscape && _stableTopPadding > 0
        ? math.max(rawTop, _stableTopPadding)
        : rawTop;
    final topPadding = widget.useSafeAreaTop ? resolvedTop : 0.0;
    final resolvedTitle = widget.title;

    final hasTopCapsule =
        widget.topCapsuleTitle != null || widget.topCapsuleChild != null;
    final hasSecondaryContent =
        widget.title.isNotEmpty ||
        widget.titleWidget != null ||
        widget.leading != null ||
        widget.trailing != null;

    Widget wrapButton(Widget button) {
      if (button is IconButton || button is BackButton) {
        return HeaderFloatingButton(child: button);
      }
      return button;
    }

    Widget buildTitleContent() {
      if (widget.titleWidget != null) {
        return Align(
          alignment: Alignment.centerLeft,
          child: widget.titleWidget!,
        );
      }

      final titleStyle = appPageHeaderTitleStyle(context);
      return HeaderFloatingSurface(
        height: null,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 38),
          child: Row(
            children: [
              if (widget.icon != null) ...[
                Icon(
                  widget.icon,
                  size: AppDesignTokens.opticalIconSize(
                    widget.icon,
                    AppDesignTokens.fileTypeIcons.contains(widget.icon)
                        ? AppDesignTokens.fileEntryIconSize
                        : 18,
                  ),
                  color: widget.iconColor ?? cs.primary,
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      widget.marqueeTitle
                          ? MarqueeText(
                              text: resolvedTitle,
                              style: titleStyle,
                              scrollSpeed: 24,
                              edgePadding: 2,
                              forceMarquee: widget.forceMarqueeTitle,
                            )
                          : Text(
                              resolvedTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: titleStyle,
                            ),
                      if (widget.subtitle != null &&
                          widget.subtitle!.isNotEmpty)
                        Text(
                          widget.subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant.withValues(
                              alpha: isWindows ? 1 : 0.85,
                            ),
                            fontSize: isWindows ? null : 11.5,
                            fontWeight: isWindows ? null : FontWeight.w600,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (widget.titleSuffix != null) ...[
                const SizedBox(width: 6),
                widget.titleSuffix!,
              ],
            ],
          ),
        ),
      );
    }

    final titleContent = buildTitleContent();
    final leading = widget.leading == null ? null : wrapButton(widget.leading!);
    final trailing = widget.trailing == null
        ? null
        : wrapButton(widget.trailing!);

    final trailingContent =
        trailing != null && !hasTopCapsule && widget.collapseController != null
        ? ValueListenableBuilder<double>(
            valueListenable: _collapseProgress,
            child: trailing,
            builder: (context, progress, child) => Opacity(
              opacity: 1 - Curves.easeOutCubic.transform(progress),
              child: child,
            ),
          )
        : trailing == null
        ? null
        : Opacity(opacity: 1, child: trailing);

    Widget buildSecondaryCapsuleRow() {
      // Only siblings in this row share input. The upper capsule can overlap
      // this row while collapsing and must keep its own backdrop.
      final row = Row(
        children: [
          if (widget.leading != null) ...[leading!, const SizedBox(width: 8)],
          Expanded(child: titleContent),
          if (trailingContent != null) ...[
            const SizedBox(width: 8),
            trailingContent,
          ],
        ],
      );
      // Android's grouped backdrop can bypass route opacity for an unmasked
      // header. Independent samples keep its glass and controls fading together.
      if (!widget.showFadeMask &&
          defaultTargetPlatform == TargetPlatform.android) {
        return row;
      }
      return BackdropGroup(backdropKey: _rowBackdropKey, child: row);
    }

    final topCapsuleWidget =
        widget.topCapsuleChild ??
        (widget.topCapsuleTitle != null
            ? HeaderTopCapsule(
                title: widget.topCapsuleTitle!,
                data: widget.topCapsuleData,
                leading:
                    widget.topCapsuleLeading ??
                    (widget.icon != null
                        ? Icon(
                            widget.icon,
                            size: AppDesignTokens.opticalIconSize(
                              widget.icon,
                              AppDesignTokens.fileTypeIcons.contains(
                                    widget.icon,
                                  )
                                  ? AppDesignTokens.fileEntryIconSize
                                  : 16,
                            ),
                            color: widget.iconColor ?? cs.primary,
                          )
                        : null),
                trailing: widget.topCapsuleTrailing,
              )
            : null);

    final secondaryCapsuleRow = buildSecondaryCapsuleRow();

    Widget buildHeaderContent(double collapseT) {
      if (hasTopCapsule && !hasSecondaryContent) {
        final titleCollapseT = Curves.easeOutCubic.transform(collapseT);
        final resolvedPadding = EdgeInsetsGeometry.lerp(
          widget.padding,
          widget.collapsedPadding,
          titleCollapseT,
        )!;
        return Padding(
          padding: resolvedPadding,
          child: topCapsuleWidget ?? const SizedBox.shrink(),
        );
      }

      if (!hasTopCapsule) {
        final titleCollapseT = Curves.easeOutCubic.transform(collapseT);
        final resolvedPadding = EdgeInsetsGeometry.lerp(
          widget.padding,
          widget.collapsedPadding,
          titleCollapseT,
        )!;
        return Padding(padding: resolvedPadding, child: secondaryCapsuleRow);
      }

      final topCapsuleOpacity = (1.0 - Curves.easeIn.transform(collapseT))
          .clamp(0.0, 1.0);

      const topCapsuleHeight = AppPageHeaderMetrics.contentHeight;
      const rowGap = AppPageHeaderMetrics.rowSpacing;
      const secondRowHeight = AppPageHeaderMetrics.contentHeight;
      const expandedHeight = topCapsuleHeight + rowGap + secondRowHeight;
      const collapsedHeight = secondRowHeight;

      final currentHeight = dart_ui.lerpDouble(
        expandedHeight,
        collapsedHeight,
        collapseT,
      )!;
      final secondRowTop = dart_ui.lerpDouble(
        topCapsuleHeight + rowGap,
        0.0,
        collapseT,
      )!;
      final topCapsuleTop = dart_ui.lerpDouble(0.0, -12.0, collapseT)!;

      return Padding(
        padding: widget.padding,
        child: SizedBox(
          height: currentHeight,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              if (topCapsuleWidget != null)
                Positioned(
                  top: topCapsuleTop,
                  left: 0,
                  right: 0,
                  height: topCapsuleHeight,
                  // Skip offscreen ColorFilterLayer at full opacity so child
                  // BackdropFilter blurs underlying content directly.
                  child: _ModulateOpacity(
                    opacity: topCapsuleOpacity,
                    child: IgnorePointer(
                      ignoring: collapseT > 0.8,
                      child: ExcludeSemantics(
                        excluding: collapseT > 0.8,
                        child: topCapsuleWidget,
                      ),
                    ),
                  ),
                ),
              Positioned(
                top: secondRowTop,
                left: 0,
                right: 0,
                height: secondRowHeight,
                child: secondaryCapsuleRow,
              ),
            ],
          ),
        ),
      );
    }

    _updateCollapseProgress();

    final headerContent = Padding(
      padding: EdgeInsets.only(top: topPadding),
      child: AnimatedBuilder(
        animation: _collapseProgress,
        child: widget.additionalChild,
        builder: (context, additionalChild) {
          final collapseT = _collapseProgress.value;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [buildHeaderContent(collapseT), ?additionalChild],
          );
        },
      ),
    );
    final surface = _AppHeaderSurface(
      floating: widget.floating,
      showFadeMask: widget.showFadeMask,
      child: headerContent,
    );
    // The switcher resizes the shared backdrop, fades only the controls, and
    // owns their route paint boundaries.
    if (context.findAncestorWidgetOfExactType<AppHeaderTransition>() != null) {
      return surface;
    }
    return AppPageHeaderTransition(child: surface);
  }
}

class _AppHeaderSurface extends StatelessWidget {
  const _AppHeaderSurface({
    required this.child,
    this.floating = true,
    this.showFadeMask = true,
  });

  final Widget child;
  final bool floating;
  final bool showFadeMask;

  @override
  Widget build(BuildContext context) {
    if (floating) {
      if (!showFadeMask ||
          context.findAncestorWidgetOfExactType<AppHeaderTransition>() !=
              null) {
        return child;
      }
      return Stack(
        fit: StackFit.passthrough,
        children: [
          const Positioned.fill(
            child: AppEdgeFadeMask(direction: AppEdgeFadeDirection.towardTop),
          ),
          child,
        ],
      );
    }
    final cs = Theme.of(context).colorScheme;
    final tokens = AppDesignTokens.of(context);
    return AppGlassSurface(
      enabled: tokens.barGlassEnabled,
      backgroundColor: tokens.barGlassEnabled
          ? cs.surface.withValues(alpha: cs.surface.a * 0.9)
          : cs.surface,
      child: DecoratedBox(
        decoration: BoxDecoration(
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
      ),
    );
  }
}

TextStyle? appPageHeaderTitleStyle(BuildContext context) {
  final theme = Theme.of(context);
  final isWindows = theme.platform == TargetPlatform.windows;
  return theme.textTheme.titleSmall?.copyWith(
    color: theme.colorScheme.onSurface,
    fontSize: isWindows ? null : 13.5,
    fontWeight: isWindows ? null : FontWeight.w800,
    letterSpacing: isWindows ? null : 0.1,
  );
}

class HeaderFloatingSurface extends StatelessWidget {
  const HeaderFloatingSurface({
    super.key,
    required this.child,
    this.radius = 19,
    this.height = 38,
    this.width,
    this.padding,
    this.backgroundOpacity = 1,
    this.followBarGlass = false,
    this.hovered,
    this.pressed,
  });

  final Widget child;
  final double radius;
  final double? height;
  final double? width;
  final EdgeInsetsGeometry? padding;
  final double backgroundOpacity;
  final bool followBarGlass;
  final bool? hovered;
  final bool? pressed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final isHovered = hovered ?? false;
    final isPressed = pressed ?? false;
    final background = isDark ? cs.surfaceBright : cs.surfaceContainerHigh;
    final borderRadius = BorderRadius.circular(radius);
    // Content capsules opt in explicitly; full-width glass bars own their filter.
    final headerSurface = context
        .findAncestorWidgetOfExactType<_AppHeaderSurface>();
    final useGlass =
        backgroundOpacity > 0 &&
        AppDesignTokens.of(context).barGlassEnabled &&
        (followBarGlass ||
            context.findAncestorWidgetOfExactType<AppPageHeaderTransition>() !=
                null) &&
        headerSurface?.floating != false;
    final restBackground = background.withValues(
      alpha: background.a * backgroundOpacity * (useGlass ? 0.9 : 1),
    );
    final backgroundColor = appSurfaceHighlight(
      cs,
      restBackground,
      pressed: isPressed,
      hovered: isHovered,
    );
    final border = Border.all(
      color: cs.outlineVariant.withValues(alpha: isDark ? 0.24 : 0.42),
    );
    final innerChild = padding != null
        ? Padding(padding: padding!, child: child)
        : child;
    final decoration = BoxDecoration(
      color: useGlass ? null : backgroundColor,
      borderRadius: borderRadius,
      border: border,
    );
    final surface = !useGlass && (hovered != null || pressed != null)
        ? AnimatedContainer(
            duration: reduceMotion
                ? Duration.zero
                : Duration(milliseconds: isPressed ? 60 : 90),
            curve: Curves.easeOutQuad,
            decoration: decoration,
            child: innerChild,
          )
        : DecoratedBox(decoration: decoration, child: innerChild);

    final content = useGlass
        ? AppGlassSurface(
            backgroundColor: backgroundColor,
            borderRadius: borderRadius,
            // Only masked headers need to replace the gradient's filtered
            // pixels; unmasked capsules keep normal backdrop compositing.
            blendMode: followBarGlass || headerSurface?.showFadeMask == false
                ? BlendMode.srcOver
                : BlendMode.src,
            child: surface,
          )
        : ClipRRect(borderRadius: borderRadius, child: surface);

    if (width != null || height != null) {
      return SizedBox(width: width, height: height, child: content);
    }
    return content;
  }
}

/// Shared floating bottom-right primary capsule button.
class HeaderFloatingActionPill extends StatelessWidget {
  const HeaderFloatingActionPill({
    super.key,
    this.pillKey,
    required this.icon,
    this.iconKey,
    required this.label,
    required this.onTap,
    this.loading = false,
    this.horizontalPadding = 18,
    this.backgroundColor,
    this.foregroundColor,
  });

  final Key? pillKey;
  final IconData icon;
  final Key? iconKey;
  final String label;
  final VoidCallback? onTap;
  final bool loading;
  final double horizontalPadding;
  final Color? backgroundColor;
  final Color? foregroundColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final enabled = !loading && onTap != null;
    final baseBg = backgroundColor ?? cs.primary;
    final effectiveFg = foregroundColor ?? cs.onPrimary;
    final borderRadius = BorderRadius.circular(23);

    return AppSurfaceButtonShell(
      enabled: enabled,
      builder: (context, feedback) {
        final surfaceColor = appSurfaceHighlight(
          cs,
          baseBg,
          pressed: feedback.pressed,
          hovered: feedback.hovered,
        );
        final contentColor = feedback.pressed || feedback.hovered
            ? appLabelledButtonHighlight(
                cs,
                foreground: effectiveFg,
                background: surfaceColor,
              )
            : effectiveFg;
        return HeaderFloatingSurface(
          key: pillKey,
          height: 46,
          radius: 23,
          padding: EdgeInsets.zero,
          child: Material(
            color: surfaceColor,
            animationDuration: feedback.duration,
            shape: RoundedRectangleBorder(borderRadius: borderRadius),
            child: InkWell(
              mouseCursor: WidgetStateMouseCursor.clickable,
              borderRadius: borderRadius,
              hoverColor: Colors.transparent,
              highlightColor: Colors.transparent,
              splashFactory: NoSplash.splashFactory,
              onTap: loading ? null : onTap,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (loading)
                      SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: effectiveFg,
                        ),
                      )
                    else
                      Icon(icon, key: iconKey, size: 18, color: contentColor),
                    const SizedBox(width: 6),
                    Text(
                      label,
                      style: TextStyle(
                        color: contentColor,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class HeaderFloatingButton extends StatelessWidget {
  const HeaderFloatingButton({
    super.key,
    required this.child,
    this.size = AppPageHeaderMetrics.buttonSize,
    this.backgroundOpacity = 1,
    this.followBarGlass = false,
  });

  final Widget child;
  final double size;
  final double backgroundOpacity;
  final bool followBarGlass;

  @override
  Widget build(BuildContext context) {
    // The surface's ClipRRect hit-tests its outer rect; restrict input and
    // paint to the visible circle.
    return ClipPath(
      clipper: const ShapeBorderClipper(shape: CircleBorder()),
      child: HeaderFloatingSurface(
        width: size,
        height: size,
        radius: size / 2,
        backgroundOpacity: backgroundOpacity,
        followBarGlass: followBarGlass,
        child: IconButtonTheme(
          data: IconButtonThemeData(
            style: appIconButtonStyle(
              IconButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.onSurface,
                minimumSize: Size(size, size),
                maximumSize: Size(size, size),
                padding: EdgeInsets.zero,
                iconSize: 20,
                visualDensity: VisualDensity.standard,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: const CircleBorder(),
              ),
            ),
          ),
          child: appNoPointerInkTheme(
            context: context,
            child: Center(
              child: IconTheme.merge(
                data: const IconThemeData(size: 20),
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class HeaderActionPill extends StatelessWidget {
  const HeaderActionPill({
    super.key,
    required this.children,
    this.padding = EdgeInsets.zero,
  });

  static const double _buttonWidth = 48;
  static const double _buttonHeight = AppPageHeaderMetrics.buttonSize;
  static const BoxConstraints buttonConstraints = BoxConstraints.tightFor(
    width: _buttonWidth,
    height: _buttonHeight,
  );

  final List<Widget> children;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final actions = IconButtonTheme(
      data: IconButtonThemeData(
        style: appIconButtonStyle(
          IconButton.styleFrom(
            fixedSize: const Size(_buttonWidth, _buttonHeight),
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.standard,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: const StadiumBorder(),
          ),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final child in children)
            if (child is IconButton || child is UnifiedPopupMenuButton<Object?>)
              SizedBox(
                width: _buttonWidth,
                height: _buttonHeight,
                child: ClipPath(
                  clipper: const ShapeBorderClipper(shape: StadiumBorder()),
                  child: child,
                ),
              )
            else
              child,
        ],
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final horizontalPadding = padding
            .resolve(Directionality.of(context))
            .horizontal;
        final scroll =
            constraints.hasBoundedWidth &&
            (constraints.maxWidth <
                    children.length * _buttonWidth + horizontalPadding ||
                children.any(
                  (child) =>
                      child is! IconButton &&
                      child is! UnifiedPopupMenuButton<Object?>,
                ));
        return Align(
          alignment: Alignment.centerLeft,
          child: ClipPath(
            clipper: const ShapeBorderClipper(shape: StadiumBorder()),
            child: HeaderFloatingSurface(
              padding: padding,
              child: scroll
                  ? WindowsHorizontalWheelScroll(
                      builder: (controller) => ScrollConfiguration(
                        behavior: ScrollConfiguration.of(
                          context,
                        ).copyWith(scrollbars: false),
                        child: SingleChildScrollView(
                          controller: controller,
                          primary: false,
                          scrollDirection: Axis.horizontal,
                          child: actions,
                        ),
                      ),
                    )
                  : actions,
            ),
          ),
        );
      },
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
    this.accentColor,
  });

  final List<T> items;
  final T selected;
  final ValueChanged<T> onSelected;
  final String Function(T item) labelBuilder;
  final Color? accentColor;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: HeaderFloatingSurface(
        child: SegmentedCategoryPillStrip<T>(
          items: items,
          selected: selected,
          onSelected: onSelected,
          labelBuilder: labelBuilder,
          accentColor: accentColor,
          indicatorKey: const ValueKey<String>('header_category_indicator'),
        ),
      ),
    );
  }
}

class SegmentedCategoryPillStrip<T> extends StatefulWidget {
  const SegmentedCategoryPillStrip({
    super.key,
    required this.items,
    required this.selected,
    required this.onSelected,
    required this.labelBuilder,
    this.accentColor,
    this.scrollViewKey,
    this.indicatorKey,
    this.itemKeyBuilder,
  });

  final List<T> items;
  final T? selected;
  final ValueChanged<T>? onSelected;
  final String Function(T item) labelBuilder;
  final Color? accentColor;
  final Key? scrollViewKey;
  final Key? indicatorKey;
  final Key Function(T item)? itemKeyBuilder;

  @override
  State<SegmentedCategoryPillStrip<T>> createState() =>
      _SegmentedCategoryPillStripState<T>();
}

class _SegmentedCategoryPillStripState<T>
    extends State<SegmentedCategoryPillStrip<T>> {
  final GlobalKey _rowKey = GlobalKey();
  List<GlobalKey> _slotKeys = const <GlobalKey>[];

  @override
  void initState() {
    super.initState();
    _syncSlotKeys();
  }

  @override
  void didUpdateWidget(covariant SegmentedCategoryPillStrip<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncSlotKeys();
  }

  void _syncSlotKeys() {
    final targetCount = widget.items.length;
    if (_slotKeys.length == targetCount) return;
    _slotKeys = List<GlobalKey>.generate(
      targetCount,
      (index) => index < _slotKeys.length ? _slotKeys[index] : GlobalKey(),
      growable: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final textTheme = theme.textTheme;
    final isWindows = theme.platform == TargetPlatform.windows;
    final activeColor = widget.accentColor ?? cs.primary;
    final reduceMotion =
        MediaQuery.disableAnimationsOf(context) ||
        !TickerMode.valuesOf(context).enabled;
    final motionDuration = reduceMotion ? Duration.zero : kAppMotionFast;
    final selectedItem = widget.selected;
    final activeIndex = selectedItem == null
        ? -1
        : widget.items.indexOf(selectedItem);
    final labelSignature = Object.hashAll(
      widget.items.map(widget.labelBuilder),
    );
    final onSelected = widget.onSelected;

    final row = Row(
      key: _rowKey,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < widget.items.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1),
            child: _HeaderCategorySegmentItem(
              slotKey: _slotKeys[i],
              itemKey: widget.itemKeyBuilder?.call(widget.items[i]),
              label: widget.labelBuilder(widget.items[i]),
              selected: i == activeIndex,
              activeColor: activeColor,
              inactiveColor: cs.onSurfaceVariant,
              isWindows: isWindows,
              motionDuration: motionDuration,
              baseStyle: textTheme.labelMedium,
              onTap: onSelected == null
                  ? null
                  : () => onSelected(widget.items[i]),
            ),
          ),
      ],
    );

    return WindowsHorizontalWheelScroll(
      builder: (scrollController) => SingleChildScrollView(
        key: widget.scrollViewKey,
        controller: scrollController,
        scrollDirection: Axis.horizontal,
        physics: const ClampingScrollPhysics(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
          child: SlidingSelectionIndicator(
            index: activeIndex,
            layoutKey: Object.hashAll(widget.items),
            child: row,
            builder: (context, position, child) => CustomPaint(
              key: widget.indicatorKey,
              painter: SlidingSelectionPainter(
                containerKey: _rowKey,
                position: position,
                visible: activeIndex >= 0 && widget.items.isNotEmpty,
                accentColor: activeColor,
                slots: _slotKeys,
                layoutSignature: labelSignature,
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

class _HeaderCategorySegmentItem extends StatefulWidget {
  const _HeaderCategorySegmentItem({
    required this.slotKey,
    this.itemKey,
    required this.label,
    required this.selected,
    required this.activeColor,
    required this.inactiveColor,
    required this.isWindows,
    required this.motionDuration,
    required this.baseStyle,
    required this.onTap,
  });

  final GlobalKey slotKey;
  final Key? itemKey;
  final String label;
  final bool selected;
  final Color activeColor;
  final Color inactiveColor;
  final bool isWindows;
  final Duration motionDuration;
  final TextStyle? baseStyle;
  final VoidCallback? onTap;

  @override
  State<_HeaderCategorySegmentItem> createState() =>
      _HeaderCategorySegmentItemState();
}

class _HeaderCategorySegmentItemState
    extends State<_HeaderCategorySegmentItem> {
  final WidgetStatesController _states = WidgetStatesController();

  @override
  void dispose() {
    _states.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selectedStyle = widget.baseStyle?.copyWith(
      color: widget.activeColor,
      fontWeight: widget.isWindows ? FontWeight.w600 : FontWeight.w700,
      fontSize: widget.isWindows ? null : 12.5,
    );
    final unselectedStyle = widget.baseStyle?.copyWith(
      color: widget.inactiveColor,
      fontWeight: widget.isWindows ? null : FontWeight.w600,
      fontSize: widget.isWindows ? null : 12.5,
    );

    return Semantics(
      button: true,
      selected: widget.selected,
      child: Material(
        key: widget.slotKey,
        type: MaterialType.transparency,
        borderRadius: BorderRadius.circular(15),
        child: InkWell(
          mouseCursor: WidgetStateMouseCursor.clickable,
          key: widget.itemKey,
          borderRadius: BorderRadius.circular(15),
          hoverColor: Colors.transparent,
          highlightColor: Colors.transparent,
          splashFactory: NoSplash.splashFactory,
          statesController: _states,
          onTap: widget.onTap,
          child: AppTouchFeedback(
            enabled: widget.onTap != null,
            child: SizedBox(
              height: 32,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: TweenAnimationBuilder<double>(
                    tween: Tween<double>(end: widget.selected ? 1.0 : 0.0),
                    duration: widget.motionDuration,
                    curve: Curves.easeOutCubic,
                    builder: (context, selection, _) => AppButtonText(
                      states: _states,
                      label: widget.label,
                      accentColor: widget.activeColor,
                      style: TextStyle.lerp(
                        unselectedStyle,
                        selectedStyle,
                        selection,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
            ),
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
    this.height = 38,
  });

  final String title;
  final String? data;
  final Widget? leading;
  final Widget? trailing;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final textTheme = theme.textTheme;
    final isWindows = theme.platform == TargetPlatform.windows;
    final titleText = Text(
      title,
      maxLines: 1,
      softWrap: false,
      style: appPageHeaderTitleStyle(context),
    );
    final dataText = trailing == null && data != null && data!.isNotEmpty
        ? Text(
            data!,
            maxLines: 1,
            softWrap: false,
            style: textTheme.bodySmall?.copyWith(
              fontWeight: isWindows ? null : FontWeight.w600,
              color: cs.onSurfaceVariant.withValues(
                alpha: isWindows ? 1 : 0.85,
              ),
              fontSize: isWindows ? null : 11.5,
              letterSpacing: 0,
            ),
          )
        : null;

    return HeaderFloatingSurface(
      height: height,
      radius: height / 2,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 6)],
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => FittedBox(
                fit: BoxFit.scaleDown,
                alignment: AlignmentDirectional.centerStart,
                child: ConstrainedBox(
                  // Keep the count at the far edge when both strings fit.
                  constraints: BoxConstraints(minWidth: constraints.maxWidth),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      titleText,
                      if (dataText != null) ...[
                        const SizedBox(width: 8),
                        dataText,
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
        ],
      ),
    );
  }
}

class _ModulateOpacity extends SingleChildRenderObjectWidget {
  const _ModulateOpacity({required this.opacity, super.child});

  final double opacity;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderModulateOpacity(opacity: opacity);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderModulateOpacity renderObject,
  ) {
    renderObject.opacity = opacity;
  }
}

class _RenderModulateOpacity extends RenderProxyBox {
  _RenderModulateOpacity({required double opacity}) : _opacity = opacity;

  double _opacity;
  double get opacity => _opacity;
  set opacity(double value) {
    final clamped = value.clamp(0.0, 1.0);
    if (_opacity == clamped) return;
    final wasOpaqueOrHidden = _opacity == 0 || _opacity == 1;
    final isOpaqueOrHidden = clamped == 0 || clamped == 1;
    _opacity = clamped;
    if (wasOpaqueOrHidden != isOpaqueOrHidden) {
      markNeedsCompositingBitsUpdate();
    }
    markNeedsPaint();
  }

  @override
  bool get alwaysNeedsCompositing =>
      child != null && _opacity > 0 && _opacity < 1;

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null || _opacity <= 0) {
      layer = null;
      return;
    }
    if (_opacity >= 1) {
      layer = null;
      context.paintChild(child!, offset);
      return;
    }
    layer = context.pushColorFilter(
      offset,
      ColorFilter.mode(
        Colors.white.withValues(alpha: _opacity),
        BlendMode.modulate,
      ),
      super.paint,
      oldLayer: layer as ColorFilterLayer?,
    );
  }
}
