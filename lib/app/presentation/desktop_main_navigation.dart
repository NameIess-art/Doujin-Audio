import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import '../../core/ui/ui_interaction_coordinator.dart';
import '../../core/widgets/app_transitions.dart';
import '../localization/app_language_provider.dart';
import '../theme/app_styles.dart';
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
  });
  final AppLanguageProvider i18n;
  final List<PlaybackSessionSnapshot> overlaySessions;
  final List<MainDestination> destinations;
  final bool isMenuCollapsed;
  final ValueListenable<int> activePageIndex;
  final List<GlobalKey> menuIconKeys;
  final List<LayerLink> menuIconLinks;
  final Offset Function(MainDestinationType source, MainDestinationType target)
  collapseOffset;
  final ValueChanged<int> onSwitchPage;
  final VoidCallback onToggleMenu;
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

class _DesktopMainNavigationState extends State<DesktopMainNavigation> {
  final Object _motionInteraction = Object();
  final GlobalKey _menuToggleKey = GlobalKey();
  bool _motionActive = false;
  bool _tickerModeEnabled = true;
  bool _disableAnimations = false;
  bool? _landscapeLayout;

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
    _landscapeLayout = landscape;
    _syncMotionInteraction();
  }

  @override
  void dispose() {
    UiInteractionCoordinator.instance.cancelInteraction(_motionInteraction);
    super.dispose();
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
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isLandscapeLayout =
        defaultTargetPlatform == TargetPlatform.windows ||
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final motionDuration = _disableAnimations
        ? Duration.zero
        : isLandscapeLayout
        ? kThemeAnimationDuration
        : const Duration(milliseconds: 300);
    final double expandedWidth = isLandscapeLayout ? 260 : 292;
    final double collapsedWidth = isLandscapeLayout ? 80 : 92;
    final double containerWidth = isMenuCollapsed
        ? collapsedWidth
        : expandedWidth;
    final horizontalPadding = isLandscapeLayout ? 16.0 : 20.0;
    final horizontalBorder = isLandscapeLayout ? 1.0 : 2.0;
    final railMinWidth = collapsedWidth - horizontalPadding - horizontalBorder;
    final railMinExtendedWidth =
        expandedWidth - horizontalPadding - horizontalBorder;

    final sidebarColor = isLandscapeLayout
        ? (isDark
              ? (cs.surfaceContainerLowest == cs.surface
                    ? cs.surfaceContainerLow
                    : cs.surfaceContainerLowest)
              : cs.surfaceContainerLow)
        : cs.surfaceContainerLow;

    final sidebar = AnimatedContainer(
      key: ValueKey<bool>(isLandscapeLayout),
      // Resizing the shell every frame also relayouts the adjacent page trees.
      // Landscape motion is confined to the rail below instead.
      duration: isLandscapeLayout ? Duration.zero : motionDuration,
      onEnd: isLandscapeLayout ? null : _finishMotion,
      curve: Curves.easeInOut,
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
            : BorderRadius.circular(16),
        border: isLandscapeLayout
            ? Border(
                right: BorderSide(
                  color: cs.outlineVariant.withValues(
                    alpha: isDark ? 0.4 : 0.65,
                  ),
                ),
              )
            : Border.all(color: cs.outlineVariant.withValues(alpha: 0.85)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final rail = ValueListenableBuilder<int>(
                  valueListenable: activePageIndex,
                  builder: (context, selectedIndex, _) {
                    final activeIndex = selectedIndex < destinations.length
                        ? selectedIndex
                        : 0;
                    return Theme(
                      data: Theme.of(context).copyWith(
                        splashFactory: NoSplash.splashFactory,
                        highlightColor: isLandscapeLayout
                            ? Colors.transparent
                            : Theme.of(context).highlightColor,
                        // NavigationRail derives its ink colors directly from
                        // primary; landscape pointer feedback belongs to buttons.
                        colorScheme: isLandscapeLayout
                            ? cs.copyWith(
                                primary: cs.primary.withValues(alpha: 0),
                              )
                            : cs,
                        navigationRailTheme: Theme.of(context)
                            .navigationRailTheme
                            .copyWith(
                              indicatorShape: const CircleBorder(),
                              indicatorColor: isDark
                                  ? cs.primary.withValues(alpha: 0.15)
                                  : cs.primaryContainer.withValues(alpha: 0.6),
                            ),
                      ),
                      child: Stack(
                        children: [
                          NavigationRail(
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
                                  menuIconKeys[destinations[index].type.index];
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
                            extended: !isMenuCollapsed,
                            minWidth: railMinWidth,
                            minExtendedWidth: railMinExtendedWidth,
                            useIndicator: !isLandscapeLayout,
                            groupAlignment: -1.0,
                            leading: isLandscapeLayout
                                ? Container(
                                    alignment: Alignment.centerLeft,
                                    child: SizedBox(
                                      width: isMenuCollapsed
                                          ? railMinWidth
                                          : 72,
                                      child: Center(
                                        child: IconButton(
                                          key: _menuToggleKey,
                                          style: IconButton.styleFrom(
                                            shape: const CircleBorder(),
                                            fixedSize: const Size.square(48),
                                            overlayColor: cs.primary,
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
                                          ? IconButton(
                                              key: _menuToggleKey,
                                              style: IconButton.styleFrom(
                                                shape: const CircleBorder(),
                                              ),
                                              icon: const Icon(
                                                Icons.menu_rounded,
                                              ),
                                              onPressed: onToggleMenu,
                                            )
                                          : Row(
                                              children: [
                                                Container(
                                                  width: 38,
                                                  height: 38,
                                                  decoration: BoxDecoration(
                                                    color: cs.primaryContainer,
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
                                                IconButton(
                                                  key: _menuToggleKey,
                                                  style: IconButton.styleFrom(
                                                    shape: const CircleBorder(),
                                                  ),
                                                  icon: const Icon(
                                                    Icons.menu_open_rounded,
                                                  ),
                                                  onPressed: onToggleMenu,
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
                              final label = item.labelKey == 'show_asmr_one'
                                  ? 'ASMR.ONE'
                                  : i18n.tr(item.labelKey);

                              return NavigationRailDestination(
                                icon: CompositedTransformTarget(
                                  key: menuIconKeys[item.type.index],
                                  link: menuIconLinks[item.type.index],
                                  child: SizedBox.square(
                                    dimension: isLandscapeLayout ? 48 : 21,
                                  ),
                                ),
                                selectedIcon: CompositedTransformTarget(
                                  key: menuIconKeys[item.type.index],
                                  link: menuIconLinks[item.type.index],
                                  child: SizedBox.square(
                                    dimension: isLandscapeLayout ? 48 : 22,
                                  ),
                                ),
                                label: Text(
                                  label,
                                  style: isSelected
                                      ? TextStyle(
                                          color: cs.primary,
                                          fontWeight: FontWeight.w700,
                                        )
                                      : null,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              );
                            }).toList(),
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
                                        for (final entry
                                            in destinations.asMap().entries)
                                          if (entry.key != activeIndex)
                                            Positioned(
                                              left: 0,
                                              top: 0,
                                              child: CompositedTransformFollower(
                                                link:
                                                    menuIconLinks[entry
                                                        .value
                                                        .type
                                                        .index],
                                                showWhenUnlinked: false,
                                                offset:
                                                    collapseOffset(
                                                          entry.value.type,
                                                          destinations[activeIndex]
                                                              .type,
                                                        ) *
                                                        collapse +
                                                    (isLandscapeLayout
                                                        ? Offset(
                                                            -(railMinWidth -
                                                                    48) /
                                                                2,
                                                            -8,
                                                          )
                                                        : Offset.zero),
                                                child: Opacity(
                                                  opacity: 1 - collapse,
                                                  child: _buildDestinationIcon(
                                                    isLandscapeLayout:
                                                        isLandscapeLayout,
                                                    railMinWidth: railMinWidth,
                                                    onPressed: () =>
                                                        onSwitchPage(entry.key),
                                                    icon: Icon(
                                                      entry.value.icon,
                                                      key: ValueKey<String>(
                                                        'main_destination_${entry.value.labelKey}',
                                                      ),
                                                      color:
                                                          cs.onSurfaceVariant,
                                                      size: 21,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                        Positioned(
                                          left: 0,
                                          top: 0,
                                          child: CompositedTransformFollower(
                                            link:
                                                menuIconLinks[destinations[activeIndex]
                                                    .type
                                                    .index],
                                            showWhenUnlinked: false,
                                            offset: isLandscapeLayout
                                                ? Offset(
                                                    -(railMinWidth - 48) / 2,
                                                    -8,
                                                  )
                                                : Offset.zero,
                                            child: _buildDestinationIcon(
                                              isLandscapeLayout:
                                                  isLandscapeLayout,
                                              railMinWidth: railMinWidth,
                                              onPressed: () =>
                                                  onSwitchPage(activeIndex),
                                              backgroundColor: isDark
                                                  ? cs.primary.withValues(
                                                      alpha: 0.15,
                                                    )
                                                  : cs.primaryContainer
                                                        .withValues(alpha: 0.6),
                                              icon: Icon(
                                                destinations[activeIndex]
                                                    .selectedIcon,
                                                key: ValueKey<String>(
                                                  'main_destination_${destinations[activeIndex].labelKey}',
                                                ),
                                                color: cs.primary,
                                                size: 22,
                                              ),
                                            ),
                                          ),
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

                if (!isLandscapeLayout) return rail;
                return Align(
                  alignment: Alignment.topLeft,
                  child: TweenAnimationBuilder<double>(
                    tween: Tween<double>(
                      end: isMenuCollapsed
                          ? railMinWidth
                          : railMinExtendedWidth,
                    ),
                    duration: motionDuration,
                    curve: Curves.easeInOut,
                    onEnd: _finishMotion,
                    builder: (context, width, child) {
                      final maxWidth = isMenuCollapsed
                          ? width
                          : (width < railMinWidth + 8.0
                              ? railMinWidth + 8.0
                              : width);
                      return ClipRect(
                        child: SizedBox(
                          width: width,
                          child: OverflowBox(
                            alignment: Alignment.topLeft,
                            minWidth: width,
                            maxWidth: maxWidth,
                            child: child,
                          ),
                        ),
                      );
                    },
                    child: rail,
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
                      expandedDockWidth: railMinExtendedWidth,
                    );
                  }

                  reportPlaybackRect();
                  return Align(
                    alignment: isMenuCollapsed
                        ? Alignment.center
                        : Alignment.centerLeft,
                    child: AnimatedContainer(
                      key: playbackGeometryKey,
                      duration: motionDuration,
                      curve: Curves.easeInOut,
                      onEnd: reportPlaybackRect,
                      width: isMenuCollapsed
                          ? kActiveSessionCarouselDockHeight
                          : constraints.maxWidth,
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
                              presentation:
                                  ActiveSessionCarouselPresentation.embedded,
                              onOpenSession: (sessionId) {
                                Navigator.of(context, rootNavigator: true).push(
                                  buildSessionDetailRoute(sessionId: sessionId),
                                );
                              },
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
    required bool isLandscapeLayout,
    required double railMinWidth,
    required Widget icon,
    required VoidCallback onPressed,
    Color? backgroundColor,
  }) {
    if (!isLandscapeLayout) return icon;
    // Consume the rail's surrounding padding so only the 48px button accepts
    // pointer taps in the icon column. The rail retains keyboard/label actions.
    return Listener(
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: railMinWidth,
        height: 64,
        child: Center(
          child: IconButton(
            style: IconButton.styleFrom(
              fixedSize: const Size.square(48),
              shape: const CircleBorder(),
              backgroundColor: backgroundColor,
              overlayColor: Theme.of(context).colorScheme.primary,
            ),
            onPressed: onPressed,
            icon: icon,
          ),
        ),
      ),
    );
  }
}
