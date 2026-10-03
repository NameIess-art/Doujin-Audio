import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import '../../core/ui/ui_interaction_coordinator.dart';
import '../localization/app_language_provider.dart';
import '../theme/app_styles.dart';
import '../../features/player/application/playback_session_snapshot.dart';
import '../../features/player/presentation/active_session_carousel.dart';
import '../../features/player/presentation/playlist/session_detail_page.dart';
import 'main_destination.dart';
import 'app_dock_panel.dart';

class DesktopMainNavigation extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isLandscapeLayout =
        defaultTargetPlatform == TargetPlatform.windows ||
        MediaQuery.orientationOf(context) == Orientation.landscape;
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

    return AnimatedContainer(
      key: ValueKey<bool>(isLandscapeLayout),
      duration: kThemeAnimationDuration,
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
        boxShadow: isLandscapeLayout
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.04),
                  blurRadius: 10,
                  offset: const Offset(2, 0),
                ),
              ]
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.1),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
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
                        navigationRailTheme: Theme.of(context)
                            .navigationRailTheme
                            .copyWith(
                              indicatorShape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(
                                  AppRadius.medium,
                                ),
                              ),
                              indicatorColor: isDark
                                  ? cs.primary.withValues(alpha: 0.15)
                                  : cs.primaryContainer.withValues(alpha: 0.6),
                            ),
                      ),
                      child: Stack(
                        children: [
                          NavigationRail(
                            backgroundColor: Colors.transparent,
                            selectedIndex: activeIndex,
                            onDestinationSelected: onSwitchPage,
                            extended: !isMenuCollapsed,
                            minWidth: railMinWidth,
                            minExtendedWidth: railMinExtendedWidth,
                            useIndicator: true,
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
                                  child: const SizedBox.square(dimension: 21),
                                ),
                                selectedIcon: CompositedTransformTarget(
                                  key: menuIconKeys[item.type.index],
                                  link: menuIconLinks[item.type.index],
                                  child: const SizedBox.square(dimension: 22),
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
                              child: ExcludeSemantics(
                                child: TweenAnimationBuilder<double>(
                                  tween: Tween<double>(
                                    end: isMenuCollapsed && !isLandscapeLayout
                                        ? 1
                                        : 0,
                                  ),
                                  duration: kThemeAnimationDuration,
                                  curve: Curves.easeInOut,
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
                                                  collapse,
                                              child: Opacity(
                                                opacity: 1 - collapse,
                                                child: Icon(
                                                  entry.value.icon,
                                                  key: ValueKey<String>(
                                                    'main_destination_${entry.value.labelKey}',
                                                  ),
                                                  color: cs.onSurfaceVariant,
                                                  size: 21,
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
                                          child: Icon(
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
                                    ],
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

                return rail;
              },
            ),
          ),
          if (overlaySessions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.sm),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  void reportPlaybackRect() {
                    if (UiInteractionCoordinator.instance.isInteracting) return;
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
                      duration: kThemeAnimationDuration,
                      curve: Curves.easeInOut,
                      onEnd: reportPlaybackRect,
                      width: isMenuCollapsed
                          ? kActiveSessionCarouselDockHeight
                          : constraints.maxWidth,
                      height: kActiveSessionCarouselDockHeight,
                      child: RepaintBoundary(
                        child: AppDockPanel(
                          shadowOpacity: 0.12,
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
                                Navigator.of(context).push(
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
  }
}
