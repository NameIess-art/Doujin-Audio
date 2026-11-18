import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import '../../core/ui/ui_interaction_coordinator.dart';
import '../../core/widgets/app_buttons.dart';
import '../../core/widgets/app_transitions.dart';
import '../../core/widgets/sliding_selection_indicator.dart';
import '../localization/app_language_provider.dart';
import '../theme/app_styles.dart';
import '../theme/app_design_tokens.dart';
import '../../features/player/application/playback_session_snapshot.dart';
import '../../features/player/presentation/active_session_carousel.dart';
import '../../features/player/presentation/playlist/session_detail_page.dart';
import 'main_destination.dart';
import 'app_dock_panel.dart';

class DesktopMainNavigation extends StatefulWidget {
  const DesktopMainNavigation({
    super.key,
    required this.i18n,
    required this.overlaySessions,
    required this.destinations,
    required this.isMenuCollapsed,
    required this.activePageIndex,
    required this.menuIconKeys,
    required this.menuIconLinks,
    required this.collapseOffset,
    required this.onSwitchPage,
    required this.onToggleMenu,
    required this.playbackGeometryKey,
    required this.onReportPlaybackRect,
    this.pageDragPosition,
  });
  final AppLanguageProvider i18n;
  final List<PlaybackSessionSnapshot> overlaySessions;
  final List<MainDestination> destinations;
  final bool isMenuCollapsed;
  final ValueListenable<int> activePageIndex;
  final ValueListenable<double?>? pageDragPosition;
  final List<GlobalKey> menuIconKeys;
  final List<LayerLink> menuIconLinks;
  final Offset Function(MainDestinationType source, MainDestinationType target)
  collapseOffset;
  final ValueChanged<int> onSwitchPage;
  final VoidCallback? onToggleMenu;
  final GlobalKey playbackGeometryKey;
  final void Function({
    required bool dockCollapsed,
    required double dockAreaWidth,
    required double expandedDockWidth,
  })
  onReportPlaybackRect;

  @override
  State<DesktopMainNavigation> createState() => _DesktopMainNavigationState();
}

class _DesktopMainNavigationState extends State<DesktopMainNavigation>
    with SingleTickerProviderStateMixin {
  static const double _landscapeCollapsedRailWidth = 64.0;
  static const double _landscapeExpandedRailWidth = 244.0;

  final Object _motionInteraction = Object();
  final GlobalKey _menuToggleKey = GlobalKey();
  final GlobalKey _railPaintKey = GlobalKey();
  final _railScroll = ValueNotifier(0.0);
  final _destinationStates = {
    for (final type in MainDestinationType.values) type: WidgetStatesController(),
  };
  late final AnimationController _widthController;
  late final CurvedAnimation _widthCurve;
  late final Animation<double> _landscapeWidthAnimation;
  bool _motionActive = false;
  bool _tickerModeEnabled = true;
  bool _disableAnimations = false;
  bool? _landscapeLayout;

  @override
  void initState() {
    super.initState();
    _widthController = AnimationController(
      vsync: this,
      duration: kThemeAnimationDuration,
      value: widget.isMenuCollapsed ? 0.0 : 1.0,
    );
    _widthCurve = CurvedAnimation(
      parent: _widthController,
      curve: Curves.easeInOut,
    );
    _landscapeWidthAnimation = Tween<double>(
      begin: _landscapeCollapsedRailWidth,
      end: _landscapeExpandedRailWidth,
    ).animate(_widthCurve);
    _widthController.addStatusListener((status) {
      if (_landscapeLayout == true &&
          (status.isDismissed || status.isCompleted)) {
        _finishMotion();
      }
    });
  }

  void _syncWidthAnimation() {
    final target = widget.isMenuCollapsed ? 0.0 : 1.0;
    if (_landscapeLayout != true || _disableAnimations) {
      if (_widthController.value != target || _widthController.isAnimating) {
        _widthController.value = target;
      }
      return;
    }
    if (_widthController.value != target || _widthController.isAnimating) {
      _widthController.animateTo(target);
    }
  }

  void _syncMotionInteraction() {
    final coordinator = UiInteractionCoordinator.instance;
    if (!_tickerModeEnabled || _disableAnimations) {
      coordinator.cancelInteraction(_motionInteraction);
    } else if (_motionActive) {
      coordinator.beginInteraction(_motionInteraction);
    } else {
      coordinator.endInteraction(_motionInteraction);
    }
  }

  @override
  void didUpdateWidget(covariant DesktopMainNavigation oldWidget) {
    super.didUpdateWidget(oldWidget);
    _disableAnimations = MediaQuery.disableAnimationsOf(context);
    if (oldWidget.isMenuCollapsed != widget.isMenuCollapsed) {
      _motionActive = !_disableAnimations;
      _syncMotionInteraction();
      _syncWidthAnimation();
    }
    final remaining = widget.destinations.map((item) => item.type).toSet();
    for (final item in oldWidget.destinations) {
      if (!remaining.contains(item.type)) {
        _clearDestinationFeedback(_destinationStates[item.type]!);
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerModeEnabled = TickerMode.valuesOf(context).enabled;
    _disableAnimations = MediaQuery.disableAnimationsOf(context);
    final landscape =
        defaultTargetPlatform == TargetPlatform.windows ||
        MediaQuery.orientationOf(context) == Orientation.landscape;
    if (_disableAnimations || _landscapeLayout != landscape) {
      _motionActive = false;
    }
    if (_landscapeLayout == true && !landscape) {
      _destinationStates.values.forEach(_clearDestinationFeedback);
    }
    _landscapeLayout = landscape;
    _syncMotionInteraction();
    _syncWidthAnimation();
  }

  @override
  void dispose() {
    UiInteractionCoordinator.instance.cancelInteraction(_motionInteraction);
    _widthCurve.dispose();
    _widthController.dispose();
    _railScroll.dispose();
    for (final states in _destinationStates.values) {
      states.dispose();
    }
    super.dispose();
  }

  void _clearDestinationFeedback(WidgetStatesController states) {
    states.update(WidgetState.hovered, false);
    states.update(WidgetState.pressed, false);
  }

  @override
  Widget build(BuildContext context) {
    final DesktopMainNavigation(
      :i18n,
      :overlaySessions,
      :destinations,
      :isMenuCollapsed,
      :activePageIndex,
      :menuIconKeys,
      :menuIconLinks,
      :collapseOffset,
      :onSwitchPage,
      :onToggleMenu,
      :playbackGeometryKey,
      :onReportPlaybackRect,
    ) = widget;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isWindows = theme.platform == TargetPlatform.windows;
    final isLandscapeLayout =
        defaultTargetPlatform == TargetPlatform.windows ||
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final motionDuration = _disableAnimations
        ? Duration.zero
        : isLandscapeLayout
        ? kThemeAnimationDuration
        : kAppMotionStandard;
    final double expandedWidth = isLandscapeLayout ? 260 : 292;
    final double collapsedWidth = isLandscapeLayout ? 80 : 92;
    final double containerWidth = isMenuCollapsed
        ? collapsedWidth
        : expandedWidth;
    final horizontalPadding = isLandscapeLayout ? 16.0 : 20.0;
    final horizontalBorder = isLandscapeLayout ? 0.0 : 2.0;
    final railMinWidth = collapsedWidth - horizontalPadding - horizontalBorder;
    final railMinExtendedWidth =
        expandedWidth - horizontalPadding - horizontalBorder;
    final dockLeadingInset = isLandscapeLayout
        ? (railMinWidth - kActiveSessionCarouselDockHeight) / 2
        : 0.0;
    final expandedDockWidth = railMinExtendedWidth - dockLeadingInset;

    final sidebarColor = isLandscapeLayout
        ? landscapeNavigationBackground(cs)
        : cs.surfaceContainerLow;
    final indicatorColor = SlidingSelectionIndicator.fill(cs.primary);

    final sidebar = AnimatedContainer(
      key: ValueKey<bool>(isLandscapeLayout),
      // Resizing the shell every frame also relayouts the adjacent page trees.
      // Landscape motion is confined to the rail below instead.
      duration: isLandscapeLayout ? Duration.zero : motionDuration,
      onEnd: isLandscapeLayout ? null : _finishMotion,
      curve: kAppSpringCurve,
      width: containerWidth,
      margin: isLandscapeLayout
          ? EdgeInsets.zero
          : const EdgeInsets.fromLTRB(AppSpacing.md, 18, AppSpacing.xs, 18),
      padding: isLandscapeLayout
          ? const EdgeInsets.fromLTRB(8, 4, 8, 8)
          : const EdgeInsets.fromLTRB(10, AppSpacing.md, 10, 10),
      decoration: BoxDecoration(
        color: sidebarColor,
        borderRadius: isLandscapeLayout
            ? BorderRadius.zero
            : BorderRadius.circular(AppRadius.section),
        border: isLandscapeLayout
            ? null
            : Border.all(color: cs.outlineVariant.withValues(alpha: 0.85)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Builder(
              builder: (context) {
                Widget buildRail(
                  ValueListenable<double>? landscapeWidthListenable,
                ) => ValueListenableBuilder<int>(
                  valueListenable: activePageIndex,
                  builder: (context, selectedIndex, _) {
                    final activeIndex = selectedIndex.clamp(
                      0,
                      destinations.length - 1,
                    );
                    Widget withIndicator(Widget rail) {
                      if (landscapeWidthListenable == null) return rail;
                      Widget buildIndicator(double? dragPos) =>
                          SlidingSelectionIndicator(
                            index: activeIndex,
                            layoutKey: Object.hashAll(
                              destinations.map((item) => item.type),
                            ),
                            overridePosition: dragPos,
                            child: rail,
                            builder: (context, position, child) =>
                                ValueListenableBuilder<double>(
                                  valueListenable: landscapeWidthListenable,
                                  child: child,
                                  builder:
                                      (context, landscapeWidth, railChild) =>
                                          CustomPaint(
                                            key: _railPaintKey,
                                            painter: SlidingSelectionPainter(
                                              containerKey: _railPaintKey,
                                              position: position,
                                              width:
                                                  landscapeWidth -
                                                  railMinWidth +
                                                  48,
                                              accentColor: cs.primary,
                                              scrollOffset: _railScroll,
                                              slots: [
                                                for (final destination
                                                    in destinations)
                                                  menuIconKeys[destination
                                                      .type
                                                      .index],
                                              ],
                                            ),
                                            child: railChild,
                                          ),
                                ),
                          );
                      final pageDrag = widget.pageDragPosition;
                      return NotificationListener<ScrollNotification>(
                        key: const ValueKey('desktop_navigation_indicator'),
                        onNotification: (notification) {
                          _railScroll.value = notification.metrics.pixels;
                          return false;
                        },
                        child: pageDrag == null
                            ? buildIndicator(null)
                            : ValueListenableBuilder<double?>(
                                valueListenable: pageDrag,
                                builder: (context, dragPos, _) =>
                                    buildIndicator(dragPos),
                              ),
                      );
                    }

                    Widget buildDestinationFollower(
                      int index,
                      double collapse,
                    ) {
                      final item = destinations[index];
                      final selected = index == activeIndex;
                      final glyph = selected ? item.selectedIcon : item.icon;
                      final iconOffset = isLandscapeLayout
                          ? Offset(-(railMinWidth - 48) / 2, -8)
                          : Offset.zero;
                      final offset = selected
                          ? iconOffset
                          : collapseOffset(
                                      item.type,
                                      destinations[activeIndex].type,
                                    ) *
                                    collapse +
                                iconOffset;
                      return Positioned(
                        key: ValueKey(item.type),
                        left: 0,
                        top: 0,
                        child: CompositedTransformFollower(
                          link: menuIconLinks[item.type.index],
                          showWhenUnlinked: false,
                          offset: offset,
                          child: Opacity(
                            opacity: selected ? 1 : 1 - collapse,
                            child: _buildDestinationIcon(
                              landscapeWidthListenable:
                                  landscapeWidthListenable,
                              railMinWidth: railMinWidth,
                              onPressed: () => onSwitchPage(index),
                              colorScheme: cs,
                              pointerStates: _destinationStates[item.type]!,
                              foregroundColor: selected
                                  ? cs.primary
                                  : cs.onSurfaceVariant,
                              icon: Icon(
                                glyph,
                                key: ValueKey<String>(
                                  'main_destination_${item.labelKey}',
                                ),
                                color: landscapeWidthListenable == null
                                    ? (selected
                                          ? cs.primary
                                          : cs.onSurfaceVariant)
                                    : null,
                                size: AppDesignTokens.opticalIconSize(
                                  glyph,
                                  selected ? 22 : 21,
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    }

                    return Theme(
                      data: Theme.of(context).copyWith(
                        splashFactory: NoSplash.splashFactory,
                        highlightColor: Colors.transparent,
                        // The rail uses primary for its pointer ink. The
                        // theme's focus color still applies to keyboard focus.
                        colorScheme: cs.copyWith(primary: Colors.transparent),
                        navigationRailTheme: Theme.of(context)
                            .navigationRailTheme
                            .copyWith(
                              indicatorShape: const CircleBorder(),
                              indicatorColor: indicatorColor,
                            ),
                      ),
                      child: Stack(
                        children: [
                          withIndicator(
                            NavigationRail(
                              scrollable: isLandscapeLayout,
                              // Its internal controllers have no duration option.
                              // Recreate only reduced motion states at their final
                              // layout so they stay aligned with the snapped shell.
                              key: _disableAnimations
                                  ? ValueKey((isMenuCollapsed, activeIndex))
                                  : null,
                              backgroundColor: Colors.transparent,
                              selectedIndex: activeIndex,
                              onDestinationSelected: (index) {
                                final iconKey =
                                    menuIconKeys[destinations[index]
                                        .type
                                        .index];
                                final iconContext = iconKey.currentContext;
                                final restoreFocus =
                                    _disableAnimations &&
                                    iconContext != null &&
                                    Focus.of(iconContext).hasPrimaryFocus;
                                onSwitchPage(index);
                                if (restoreFocus) {
                                  // Recreating the rail disposes its internal focus nodes.
                                  WidgetsBinding.instance.addPostFrameCallback((
                                    _,
                                  ) {
                                    final nextContext = iconKey.currentContext;
                                    if (mounted && nextContext != null) {
                                      Focus.of(nextContext).requestFocus();
                                    }
                                  });
                                }
                              },
                              extended: isLandscapeLayout || !isMenuCollapsed,
                              minWidth: railMinWidth,
                              minExtendedWidth: railMinExtendedWidth,
                              useIndicator: !isLandscapeLayout,
                              groupAlignment: -1.0,
                              leading: isLandscapeLayout
                                  ? Container(
                                      alignment: Alignment.centerLeft,
                                      child: SizedBox(
                                        width: railMinWidth,
                                        child: Center(
                                          child: Theme(
                                            data: Theme.of(
                                              context,
                                            ).copyWith(colorScheme: cs),
                                            child: IconButton(
                                              key: _menuToggleKey,
                                              tooltip: MaterialLocalizations.of(
                                                context,
                                              ).drawerLabel,
                                              style: appIconButtonStyle(
                                                IconButton.styleFrom(
                                                  shape: const CircleBorder(),
                                                  fixedSize: const Size.square(
                                                    48,
                                                  ),
                                                ),
                                              ),
                                              icon: Icon(
                                                isMenuCollapsed
                                                    ? Icons.menu_rounded
                                                    : Icons.menu_open_rounded,
                                              ),
                                              onPressed: onToggleMenu,
                                            ),
                                          ),
                                        ),
                                      ),
                                    )
                                  : Container(
                                      alignment: isMenuCollapsed
                                          ? Alignment.center
                                          : Alignment.centerLeft,
                                      child: Padding(
                                        padding: EdgeInsets.only(
                                          left: isMenuCollapsed ? 0 : 6,
                                        ),
                                        child: isMenuCollapsed
                                            ? Theme(
                                                data: Theme.of(
                                                  context,
                                                ).copyWith(colorScheme: cs),
                                                child: IconButton(
                                                  key: _menuToggleKey,
                                                  tooltip:
                                                      MaterialLocalizations.of(
                                                        context,
                                                      ).drawerLabel,
                                                  style: appIconButtonStyle(
                                                    IconButton.styleFrom(
                                                      shape:
                                                          const CircleBorder(),
                                                    ),
                                                  ),
                                                  icon: const Icon(
                                                    Icons.menu_rounded,
                                                  ),
                                                  onPressed: onToggleMenu,
                                                ),
                                              )
                                            : Row(
                                                children: [
                                                  Container(
                                                    width: 38,
                                                    height: 38,
                                                    decoration: BoxDecoration(
                                                      color:
                                                          cs.primaryContainer,
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            AppRadius.medium,
                                                          ),
                                                    ),
                                                    child: Icon(
                                                      Icons.graphic_eq_rounded,
                                                      color:
                                                          cs.onPrimaryContainer,
                                                    ),
                                                  ),
                                                  const SizedBox(
                                                    width: AppSpacing.sm,
                                                  ),
                                                  Expanded(
                                                    child: Text(
                                                      i18n.tr('asmr_player'),
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: Theme.of(context)
                                                          .textTheme
                                                          .titleMedium
                                                          ?.copyWith(
                                                            fontWeight:
                                                                FontWeight.w800,
                                                          ),
                                                    ),
                                                  ),
                                                  Theme(
                                                    data: Theme.of(
                                                      context,
                                                    ).copyWith(colorScheme: cs),
                                                    child: IconButton(
                                                      key: _menuToggleKey,
                                                      tooltip:
                                                          MaterialLocalizations.of(
                                                            context,
                                                          ).drawerLabel,
                                                      style: appIconButtonStyle(
                                                        IconButton.styleFrom(
                                                          shape:
                                                              const CircleBorder(),
                                                        ),
                                                      ),
                                                      icon: const Icon(
                                                        Icons.menu_open_rounded,
                                                      ),
                                                      onPressed: onToggleMenu,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                      ),
                                    ),
                              destinations: destinations.asMap().entries.map((
                                entry,
                              ) {
                                final index = entry.key;
                                final item = entry.value;
                                final isSelected = activeIndex == index;
                                final label = i18n.tr(item.labelKey);
                                final labelStyle = isSelected
                                    ? TextStyle(
                                        color: cs.primary,
                                        fontWeight: isWindows
                                            ? FontWeight.w600
                                            : FontWeight.w700,
                                      )
                                    : null;

                                Widget iconTarget(bool selected) =>
                                    CompositedTransformTarget(
                                      key: menuIconKeys[item.type.index],
                                      link: menuIconLinks[item.type.index],
                                      child: SizedBox.square(
                                        dimension: isLandscapeLayout
                                            ? 48
                                            : (selected ? 22 : 21),
                                      ),
                                    );
                                return NavigationRailDestination(
                                  icon: iconTarget(false),
                                  selectedIcon: iconTarget(true),
                                  label: landscapeWidthListenable != null
                                      ? SizedBox(
                                          height: 48,
                                          child: Align(
                                            alignment: AlignmentDirectional
                                                .centerStart,
                                            widthFactor: 1,
                                            child:
                                                ValueListenableBuilder<double>(
                                                  valueListenable:
                                                      landscapeWidthListenable,
                                                  child: AppButtonText(
                                                    states:
                                                        _destinationStates[item
                                                            .type]!,
                                                    label: label,
                                                    style: labelStyle,
                                                    accentColor: cs.primary,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                  builder:
                                                      (
                                                        context,
                                                        landscapeWidth,
                                                        labelChild,
                                                      ) => Opacity(
                                                        alwaysIncludeSemantics:
                                                            true,
                                                        opacity:
                                                            (4 *
                                                                    (landscapeWidth -
                                                                        railMinWidth) /
                                                                    (railMinExtendedWidth -
                                                                        railMinWidth))
                                                                .clamp(
                                                                  0.0,
                                                                  1.0,
                                                                ),
                                                        child: labelChild,
                                                      ),
                                                ),
                                          ),
                                        )
                                      : Text(
                                          label,
                                          style: labelStyle,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                );
                              }).toList(),
                            ),
                          ),
                          Positioned.fill(
                            child: IgnorePointer(
                              ignoring: !isLandscapeLayout,
                              child: ExcludeFocus(
                                child: ExcludeSemantics(
                                  child: TweenAnimationBuilder<double>(
                                    tween: Tween<double>(
                                      end: isMenuCollapsed && !isLandscapeLayout
                                          ? 1
                                          : 0,
                                    ),
                                    duration: _disableAnimations
                                        ? Duration.zero
                                        : kAppFadeDuration,
                                    curve: kAppFadeCurve,
                                    builder: (context, collapse, _) => Stack(
                                      children: [
                                        for (final index in [
                                          for (
                                            var i = 0;
                                            i < destinations.length;
                                            i++
                                          )
                                            if (i != activeIndex) i,
                                          activeIndex,
                                        ])
                                          buildDestinationFollower(
                                            index,
                                            collapse,
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                );

                if (!isLandscapeLayout) return buildRail(null);
                return Align(
                  alignment: Alignment.topLeft,
                  child: ValueListenableBuilder<double>(
                    valueListenable: _landscapeWidthAnimation,
                    child: buildRail(_landscapeWidthAnimation),
                    // The viewport can still paint during collapse after the
                    // shell releases its space to the content pane.
                    builder: (context, width, railChild) => OverflowBox(
                      alignment: Alignment.topLeft,
                      minWidth: width,
                      maxWidth: width,
                      child: ClipRect(
                        key: const ValueKey('landscape_navigation_viewport'),
                        child: ColoredBox(
                          color: sidebarColor,
                          // Keep the rail laid out at full width so its icon
                          // column never moves as the viewport is resized.
                          child: OverflowBox(
                            alignment: Alignment.topLeft,
                            minWidth: railMinExtendedWidth,
                            maxWidth: railMinExtendedWidth,
                            child: railChild,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          if (overlaySessions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.sm),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  void reportPlaybackRect() {
                    onReportPlaybackRect(
                      dockCollapsed: isMenuCollapsed,
                      dockAreaWidth: constraints.maxWidth,
                      expandedDockWidth: expandedDockWidth,
                    );
                  }

                  reportPlaybackRect();
                  return Padding(
                    padding: EdgeInsets.only(left: dockLeadingInset),
                    child: Align(
                      alignment: isMenuCollapsed && !isLandscapeLayout
                          ? Alignment.center
                          : Alignment.centerLeft,
                      child: AnimatedContainer(
                        key: playbackGeometryKey,
                        duration: isLandscapeLayout && isMenuCollapsed
                            ? Duration.zero
                            : motionDuration,
                        curve: Curves.easeInOut,
                        onEnd: reportPlaybackRect,
                        width: isMenuCollapsed
                            ? kActiveSessionCarouselDockHeight
                            : constraints.maxWidth - dockLeadingInset,
                        height: kActiveSessionCarouselDockHeight,
                        child: RepaintBoundary(
                          child: AppDockPanel(
                            showTopHighlight: false,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(
                                kActiveSessionCarouselDockHeight / 2,
                              ),
                              child: ActiveSessionCarousel(
                                sessions: overlaySessions,
                                i18n: i18n,
                                viewportFraction: 1,
                                expandedDockWidth: expandedDockWidth,
                                presentation:
                                    ActiveSessionCarouselPresentation.embedded,
                                onOpenSession: (sessionId, coverOrigin) {
                                  Navigator.of(
                                    context,
                                    rootNavigator: true,
                                  ).push(
                                    buildSessionDetailRoute(
                                      sessionId: sessionId,
                                      coverOrigin: coverOrigin,
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
    return Listener(behavior: HitTestBehavior.opaque, child: sidebar);
  }

  void _finishMotion() {
    _motionActive = false;
    _syncMotionInteraction();
  }

  Widget _buildDestinationIcon({
    required ValueListenable<double>? landscapeWidthListenable,
    required double railMinWidth,
    required ColorScheme colorScheme,
    required WidgetStatesController pointerStates,
    required Color foregroundColor,
    required Widget icon,
    required VoidCallback onPressed,
  }) {
    if (landscapeWidthListenable == null) return icon;
    return Theme(
      data: Theme.of(context).copyWith(colorScheme: colorScheme),
      child: _DestinationPointerRow(
        landscapeWidthListenable: landscapeWidthListenable,
        railMinWidth: railMinWidth,
        pointerStates: pointerStates,
        iconButton: IconButton(
          style: appIconButtonStyle(
            IconButton.styleFrom(
              fixedSize: const Size.square(48),
              shape: const CircleBorder(),
              foregroundColor: foregroundColor,
            ),
            pointerStates,
          ),
          onPressed: onPressed,
          icon: icon,
        ),
      ),
    );
  }
}

/// Splits pointer tracking between the 48px icon button and extended label so
/// blocked rail padding stays non-interactive without triggering hover tint.
class _DestinationPointerRow extends StatefulWidget {
  const _DestinationPointerRow({
    required this.landscapeWidthListenable,
    required this.railMinWidth,
    required this.pointerStates,
    required this.iconButton,
  });

  final ValueListenable<double> landscapeWidthListenable;
  final double railMinWidth;
  final WidgetStatesController pointerStates;
  final Widget iconButton;

  @override
  State<_DestinationPointerRow> createState() => _DestinationPointerRowState();
}

class _DestinationPointerRowState extends State<_DestinationPointerRow> {
  final WidgetStatesController _iconStates = WidgetStatesController();
  final WidgetStatesController _labelStates = WidgetStatesController();

  @override
  void initState() {
    super.initState();
    _iconStates.addListener(_syncStates);
    _labelStates.addListener(_syncStates);
  }

  @override
  void didUpdateWidget(covariant _DestinationPointerRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pointerStates != widget.pointerStates) {
      oldWidget.pointerStates
        ..update(WidgetState.hovered, false)
        ..update(WidgetState.pressed, false);
      _syncStates();
    }
  }

  @override
  void dispose() {
    _iconStates
      ..removeListener(_syncStates)
      ..dispose();
    _labelStates
      ..removeListener(_syncStates)
      ..dispose();
    super.dispose();
  }

  void _syncStates() {
    final hovered =
        _iconStates.value.contains(WidgetState.hovered) ||
        _labelStates.value.contains(WidgetState.hovered);
    final pressed =
        _iconStates.value.contains(WidgetState.pressed) ||
        _labelStates.value.contains(WidgetState.pressed);
    widget.pointerStates
      ..update(WidgetState.hovered, hovered)
      ..update(WidgetState.pressed, pressed);
  }

  @override
  Widget build(BuildContext context) {
    final iconArea = MouseRegion(
      cursor: SystemMouseCursors.basic,
      hitTestBehavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: widget.railMinWidth,
        height: 64,
        child: Center(
          child: SizedBox.square(
            dimension: 48,
            child: AppButtonPointerRegion(
              statesController: _iconStates,
              cursor: SystemMouseCursors.click,
              builder: (_, _) => widget.iconButton,
            ),
          ),
        ),
      ),
    );
    return ValueListenableBuilder<double>(
      valueListenable: widget.landscapeWidthListenable,
      child: iconArea,
      builder: (context, landscapeWidth, iconChild) {
        final hasLabelArea = landscapeWidth > widget.railMinWidth;
        return SizedBox(
          width: landscapeWidth,
          height: 64,
          child: Row(
            children: [
              // Consume padding around the 48px icon so only the circular button
              // and extended label receive hover tint and click cursors.
              iconChild!,
              if (hasLabelArea)
                Expanded(
                  child: AppButtonPointerRegion(
                    statesController: _labelStates,
                    cursor: SystemMouseCursors.click,
                    builder: (_, _) => const SizedBox.expand(),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
