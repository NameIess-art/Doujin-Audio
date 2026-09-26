part of 'main_screen.dart';

extension _MainScreenLayout on _MainScreenState {
  Widget _buildBody({required bool isDesktop}) {
    final layoutSize = _layoutViewSize();
    final width = layoutSize.width;
    final isLargeScreen = width >= 980;
    final radius = BorderRadius.circular(
      isDesktop
          ? (isLargeScreen ? AppRadius.card : AppRadius.medium)
          : AppRadius.dialog,
    );
    final padding = isDesktop
        ? (isLargeScreen
              ? const EdgeInsets.fromLTRB(AppSpacing.xl, 22, AppSpacing.xl, 22)
              : const EdgeInsets.fromLTRB(
                  AppSpacing.sm,
                  AppSpacing.sm,
                  AppSpacing.md,
                  AppSpacing.sm,
                ))
        : EdgeInsets.zero;
    final isLandscapeLayout =
        defaultTargetPlatform == TargetPlatform.windows ||
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final (:showLocal, :showAsmr) = ref.watch(
      settingsStateProvider.select(
        (s) => (
          showLocal: s.value?.showLocalLibrary ?? true,
          showAsmr: s.value?.showAsmrOne ?? true,
        ),
      ),
    );
    final destinations = _resolveMainDestinations(
      showLocalLibrary: showLocal,
      showAsmrOne: showAsmr,
    );
    if (_activePageIndex.value >= destinations.length) {
      _activePageIndex.value = destinations.length - 1;
    }
    Widget pageShell(BuildContext context, int actualIndex) {
      final page = _buildMainPage(context, actualIndex, destinations);

      return KeyedSubtree(
        key: ValueKey<String>('main_page_fade_$actualIndex'),
        child: Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: isDesktop && !isLandscapeLayout
                ? padding
                : EdgeInsets.zero,
            child: Builder(
              builder: (pageContext) {
                // This shell is cached by the lazy indexed stack. Read the
                // inherited theme here so its surfaces follow live changes.
                final pageCs = Theme.of(pageContext).colorScheme;
                return DecoratedBox(
                  decoration: isDesktop
                      ? BoxDecoration(
                          color: isLandscapeLayout
                              ? pageCs.surface
                              : pageCs.surfaceContainerLow,
                          borderRadius: isLandscapeLayout
                              ? BorderRadius.zero
                              : radius,
                          border: isLandscapeLayout
                              ? null
                              : Border.all(
                                  color: pageCs.outlineVariant.withValues(
                                    alpha: 0.85,
                                  ),
                                ),
                          boxShadow: isLandscapeLayout
                              ? null
                              : [
                                  BoxShadow(
                                    color: pageCs.shadow.withValues(alpha: 0.1),
                                    blurRadius: 28,
                                    offset: const Offset(0, 12),
                                  ),
                                ],
                        )
                      : const BoxDecoration(),
                  child: ClipRRect(
                    borderRadius: isDesktop
                        ? (isLandscapeLayout ? BorderRadius.zero : radius)
                        : BorderRadius.zero,
                    clipBehavior: isDesktop && !isLandscapeLayout
                        ? Clip.hardEdge
                        : Clip.none,
                    child: ColoredBox(
                      key: ValueKey<String>('main_page_canvas_$actualIndex'),
                      color: pageCs.surface,
                      child: RepaintBoundary(child: page),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
    }

    return AppFadeThroughIndexedStack.lazy(
      key: const ValueKey<String>('main_page_stack'),
      separateHeader: true,
      indexListenable: _activePageIndex,
      itemCount: destinations.length,
      itemBuilder: pageShell,
      style: AppIndexedStackTransitionStyle.gradient,
      duration: kAppMotionSlow,
      onTransitionCompleted: _handlePageTransitionCompleted,
    );
  }

  Future<void> _openTimerSettingsPage(
    BuildContext context,
    _TimerPresentation timerState,
  ) {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    return showAppOverlayPanel<void>(
      context: context,
      barrierLabel: i18n.tr('close'),
      maxHeight: kTimerCompactPanelHeight,
      mobileAlignment: Alignment.center,
      mobileOuterPadding: const EdgeInsets.symmetric(
        horizontal: 16,
        vertical: 24,
      ),
      builder: (_) => TimerTab(
        showHeader: false,
        useSafeArea: false,
        compactOnly: true,
        initialCompactDetail: timerState.duration != null,
      ),
    );
  }

  Widget _buildBottomBar(
    BuildContext context, {
    required bool isPlaybackExpanded,
    required double focusProgress,
    required double stackProgress,
    required double expandedWidth,
    required VoidCallback onCurrentTap,
  }) {
    final (:showLocal, :showAsmr) = ref.watch(
      settingsStateProvider.select(
        (s) => (
          showLocal: s.value?.showLocalLibrary ?? true,
          showAsmr: s.value?.showAsmrOne ?? true,
        ),
      ),
    );
    final destinations = _resolveMainDestinations(
      showLocalLibrary: showLocal,
      showAsmrOne: showAsmr,
    );

    return ValueListenableBuilder<int>(
      valueListenable: _activePageIndex,
      builder: (context, selectedIndex, _) => _buildBottomBarContent(
        context,
        destinations,
        selectedIndex,
        isPlaybackExpanded: isPlaybackExpanded,
        focusProgress: focusProgress,
        stackProgress: stackProgress,
        expandedWidth: expandedWidth,
        onCurrentTap: onCurrentTap,
      ),
    );
  }

  Widget _buildBottomBarContent(
    BuildContext context,
    List<_MainDestination> destinations,
    int selectedIndex, {
    required bool isPlaybackExpanded,
    required double focusProgress,
    required double stackProgress,
    required double expandedWidth,
    required VoidCallback onCurrentTap,
  }) {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final cs = Theme.of(context).colorScheme;

    final entries = destinations.asMap().entries.toList();
    final activeIndex = selectedIndex.clamp(0, destinations.length - 1);
    final layeredEntries = [
      if (stackProgress < 1)
        ...entries.where((entry) => entry.key != activeIndex),
      entries[activeIndex],
    ];
    final items = layeredEntries.map((entry) {
      final index = entry.key;
      final item = entry.value;
      final selected = index == activeIndex;
      final label = item.labelKey == 'show_asmr_one'
          ? 'ASMR.ONE'
          : i18n.tr(item.labelKey);
      final inactive = cs.onSurfaceVariant.withValues(alpha: 0.6);

      final activeColor = cs.primary;
      final expandedLeft =
          expandedWidth * (index + 0.5) / destinations.length -
          kActiveSessionCarouselDockHeight / 2;
      final progress = selected ? focusProgress : stackProgress;
      return Positioned(
        left: expandedLeft * (1 - progress),
        top: 0,
        width: kActiveSessionCarouselDockHeight,
        height: kActiveSessionCarouselDockHeight,
        child: IgnorePointer(
          ignoring: isPlaybackExpanded && !selected,
          child: ExcludeSemantics(
            excluding: isPlaybackExpanded && !selected,
            child: Semantics(
              key: ValueKey<String>('main_destination_${item.labelKey}'),
              button: true,
              selected: selected,
              label: label,
              child: Material(
                type: MaterialType.transparency,
                child: _BottomDestinationInkResponse(
                  inkKey: ValueKey<String>(
                    'main_destination_ink_${item.labelKey}',
                  ),
                  onTap: isPlaybackExpanded && selected
                      ? onCurrentTap
                      : () => _switchPage(index),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      AnimatedContainer(
                        duration: MediaQuery.disableAnimationsOf(context)
                            ? Duration.zero
                            : const Duration(milliseconds: 250),
                        curve: Curves.easeOutCubic,
                        width: selected ? 44 : 0,
                        height: selected ? 44 : 0,
                        decoration: BoxDecoration(
                          color: selected
                              ? activeColor.withValues(alpha: 0.11)
                              : Colors.transparent,
                          shape: BoxShape.circle,
                        ),
                      ),
                      AnimatedSwitcher(
                        duration: MediaQuery.disableAnimationsOf(context)
                            ? Duration.zero
                            : kAppMotionFast,
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeInCubic,
                        transitionBuilder: (child, animation) =>
                            buildAppScaleFadeTransition(
                              context: context,
                              animation: animation,
                              child: child,
                              beginScale: 0.9,
                            ),
                        child: Icon(
                          selected ? item.selectedIcon : item.icon,
                          key: ValueKey<bool>(selected),
                          size: 28,
                          color: selected ? activeColor : inactive,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }).toList();

    return Theme(
      data: Theme.of(context).copyWith(splashFactory: NoSplash.splashFactory),
      child: Stack(children: items),
    );
  }

  Widget _buildMobileBottomDock(
    BuildContext context, {
    required AppLanguageProvider i18n,
    required List<PlaybackSessionSnapshot> overlaySessions,
    bool tinyMode = false,
  }) {
    return _buildMobileBottomCapsule(
      context,
      key: const ValueKey('capsule'),
      i18n: i18n,
      overlaySessions: overlaySessions,
      tinyMode: tinyMode,
    );
  }

  Widget _buildMobileBottomCapsule(
    BuildContext context, {
    Key? key,
    required AppLanguageProvider i18n,
    required List<PlaybackSessionSnapshot> overlaySessions,
    bool tinyMode = false,
    bool isCurrent = true,
  }) {
    final systemBottom = MediaQuery.paddingOf(context).bottom;
    final maskHeight =
        kActiveSessionCarouselDockHeight +
        kMobileDockBottomMargin +
        2.0 +
        systemBottom;
    final hasPlayback = overlaySessions.isNotEmpty;
    final playbackExpanded = hasPlayback && _isMobilePlaybackExpanded;
    return Stack(
      key: key,
      fit: StackFit.expand,
      children: [
        if (!tinyMode)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: maskHeight,
            child: const AppEdgeFadeMask(
              key: ValueKey<String>('mobile_bottom_capsule_fade_mask'),
              direction: AppEdgeFadeDirection.towardBottom,
            ),
          ),
        SafeArea(
          top: false,
          minimum: const EdgeInsets.only(bottom: kMobileDockBottomMargin),
          child: Align(
            alignment: Alignment.bottomCenter,
            child: SizedBox(
              width: double.infinity,
              child: tinyMode
                  ? const SizedBox.shrink()
                  : Padding(
                      key: isCurrent ? _dockContentKey : null,
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.sm,
                      ),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 430),
                        child: FractionallySizedBox(
                          key: const ValueKey<String>(
                            'mobile_bottom_capsule_panel',
                          ),
                          widthFactor: 0.96,
                          child: AppDockGlassPanel(
                            key: const ValueKey<String>(
                              'mobile_bottom_capsule_surface',
                            ),
                            shadowOpacity: 0.12,
                            showTopHighlight: false,
                            tinyMode: tinyMode,
                            child: SizedBox(
                              height: kActiveSessionCarouselDockHeight,
                              child: _MobileDockCapsuleContent(
                                overlaySessions: overlaySessions,
                                isPlaybackExpanded: playbackExpanded,
                                i18n: i18n,
                                mobilePlaybackGeometryKey:
                                    _mobilePlaybackGeometryKey,
                                onShowPlayback: _showMobilePlayback,
                                onShowDestinations: _showMobileDestinations,
                                onReportPlaybackCoverRect:
                                    _reportMobilePlaybackCoverRect,
                                buildBottomBar: _buildBottomBar,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDesktopNavigation(
    BuildContext context,
    AppLanguageProvider i18n,
    List<PlaybackSessionSnapshot> overlaySessions,
  ) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isLandscapeLayout =
        defaultTargetPlatform == TargetPlatform.windows ||
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final double expandedWidth = isLandscapeLayout ? 260 : 292;
    final double collapsedWidth = isLandscapeLayout ? 80 : 92;
    final double containerWidth = _isMenuCollapsed
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
                final (:showLocal, :showAsmr) = ref.watch(
                  settingsStateProvider.select(
                    (s) => (
                      showLocal: s.value?.showLocalLibrary ?? true,
                      showAsmr: s.value?.showAsmrOne ?? true,
                    ),
                  ),
                );
                final destinations = _resolveMainDestinations(
                  showLocalLibrary: showLocal,
                  showAsmrOne: showAsmr,
                );

                final rail = ValueListenableBuilder<int>(
                  valueListenable: _activePageIndex,
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
                            onDestinationSelected: _switchPage,
                            extended: !_isMenuCollapsed,
                            minWidth: railMinWidth,
                            minExtendedWidth: railMinExtendedWidth,
                            useIndicator: true,
                            groupAlignment: -1.0,
                            leading: isLandscapeLayout
                                ? Container(
                                    alignment: _isMenuCollapsed
                                        ? Alignment.center
                                        : Alignment.centerLeft,
                                    child: Padding(
                                      padding: EdgeInsets.only(
                                        left: _isMenuCollapsed ? 0 : 12,
                                      ),
                                      child: IconButton(
                                        icon: Icon(
                                          _isMenuCollapsed
                                              ? Icons.menu_rounded
                                              : Icons.menu_open_rounded,
                                        ),
                                        onPressed: _toggleMenuCollapsed,
                                      ),
                                    ),
                                  )
                                : Container(
                                    alignment: _isMenuCollapsed
                                        ? Alignment.center
                                        : Alignment.centerLeft,
                                    child: Padding(
                                      padding: EdgeInsets.only(
                                        left: _isMenuCollapsed ? 0 : 6,
                                      ),
                                      child: _isMenuCollapsed
                                          ? IconButton(
                                              icon: const Icon(
                                                Icons.menu_rounded,
                                              ),
                                              onPressed: _toggleMenuCollapsed,
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
                                                  onPressed:
                                                      _toggleMenuCollapsed,
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
                                  key: _menuIconKeys[item.type.index],
                                  link: _menuIconLinks[item.type.index],
                                  child: const SizedBox.square(dimension: 21),
                                ),
                                selectedIcon: CompositedTransformTarget(
                                  key: _menuIconKeys[item.type.index],
                                  link: _menuIconLinks[item.type.index],
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
                                    end:
                                        _isMenuCollapsed &&
                                            defaultTargetPlatform !=
                                                TargetPlatform.windows
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
                                                  _menuIconLinks[entry
                                                      .value
                                                      .type
                                                      .index],
                                              showWhenUnlinked: false,
                                              offset:
                                                  _menuIconCollapseOffset(
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
                                              _menuIconLinks[destinations[activeIndex]
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
                  void reportPlaybackRect() => _reportDesktopPlaybackRect(
                    dockCollapsed: _isMenuCollapsed,
                    dockAreaWidth: constraints.maxWidth,
                    expandedDockWidth: railMinExtendedWidth,
                  );

                  reportPlaybackRect();
                  return Align(
                    alignment: _isMenuCollapsed
                        ? Alignment.center
                        : Alignment.centerLeft,
                    child: AnimatedContainer(
                      key: _desktopPlaybackGeometryKey,
                      duration: kThemeAnimationDuration,
                      curve: Curves.easeInOut,
                      onEnd: reportPlaybackRect,
                      width: _isMenuCollapsed
                          ? kActiveSessionCarouselDockHeight
                          : constraints.maxWidth,
                      height: kActiveSessionCarouselDockHeight,
                      child: AppDockGlassPanel(
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
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  double _mobileContentInset() {
    final contentBox =
        _dockContentKey.currentContext?.findRenderObject() as RenderBox?;
    if (contentBox != null && contentBox.hasSize) {
      final systemBottom = MediaQuery.of(context).padding.bottom;
      return (max(systemBottom, kMobileDockBottomMargin) +
              contentBox.size.height)
          .clamp(0.0, double.infinity);
    }
    final systemBottom = MediaQuery.of(context).padding.bottom;
    return max(systemBottom, kMobileDockBottomMargin) + 72;
  }
}

class _MobileDockCapsuleContent extends StatefulWidget {
  const _MobileDockCapsuleContent({
    required this.overlaySessions,
    required this.isPlaybackExpanded,
    required this.i18n,
    required this.mobilePlaybackGeometryKey,
    required this.onShowPlayback,
    required this.onShowDestinations,
    required this.onReportPlaybackCoverRect,
    required this.buildBottomBar,
  });

  final List<PlaybackSessionSnapshot> overlaySessions;
  final bool isPlaybackExpanded;
  final AppLanguageProvider i18n;
  final GlobalKey mobilePlaybackGeometryKey;
  final VoidCallback onShowPlayback;
  final VoidCallback onShowDestinations;
  final VoidCallback onReportPlaybackCoverRect;
  final Widget Function(
    BuildContext context, {
    required bool isPlaybackExpanded,
    required double focusProgress,
    required double stackProgress,
    required double expandedWidth,
    required VoidCallback onCurrentTap,
  })
  buildBottomBar;

  @override
  State<_MobileDockCapsuleContent> createState() =>
      _MobileDockCapsuleContentState();
}

class _MobileDockCapsuleContentState extends State<_MobileDockCapsuleContent>
    with TickerProviderStateMixin {
  late final AnimationController _appearanceController;
  late final CurvedAnimation _appearanceCurve;
  late final AnimationController _expandController;
  late final Listenable _animationListenable;
  List<PlaybackSessionSnapshot> _cachedSessions = const [];

  static const Duration _motionDuration = Duration(milliseconds: 280);

  @override
  void initState() {
    super.initState();
    final hasPlayback = widget.overlaySessions.isNotEmpty;
    if (hasPlayback) {
      _cachedSessions = widget.overlaySessions;
    }
    _appearanceController = AnimationController(
      vsync: this,
      duration: _motionDuration,
      value: hasPlayback ? 1.0 : 0.0,
    );
    _appearanceCurve = CurvedAnimation(
      parent: _appearanceController,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeOutCubic,
    );
    _expandController = AnimationController(
      vsync: this,
      duration: _motionDuration,
      value: (hasPlayback && widget.isPlaybackExpanded) ? 1.0 : 0.0,
    );
    _animationListenable = Listenable.merge([
      _appearanceCurve,
      _expandController,
    ]);

    _appearanceController.addStatusListener((status) {
      if (status == AnimationStatus.dismissed) {
        if (mounted && widget.overlaySessions.isEmpty) {
          setState(() {
            _cachedSessions = const [];
          });
        }
      }
      widget.onReportPlaybackCoverRect();
    });
    _expandController.addStatusListener((_) {
      widget.onReportPlaybackCoverRect();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onReportPlaybackCoverRect();
    });
  }

  @override
  void didUpdateWidget(covariant _MobileDockCapsuleContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    final hasPlayback = widget.overlaySessions.isNotEmpty;
    final hadPlayback = oldWidget.overlaySessions.isNotEmpty;

    if (hasPlayback) {
      _cachedSessions = widget.overlaySessions;
    }

    final disableAnimations = MediaQuery.disableAnimationsOf(context);

    if (hasPlayback != hadPlayback) {
      if (disableAnimations) {
        _appearanceController.value = hasPlayback ? 1.0 : 0.0;
        if (!hasPlayback) {
          _cachedSessions = const [];
        }
      } else {
        if (hasPlayback) {
          _appearanceController.forward();
        } else {
          _appearanceController.reverse();
        }
      }
    }

    final isExpanded = hasPlayback && widget.isPlaybackExpanded;
    final wasExpanded = hadPlayback && oldWidget.isPlaybackExpanded;
    if (isExpanded != wasExpanded) {
      if (disableAnimations) {
        _expandController.value = isExpanded ? 1.0 : 0.0;
      } else {
        if (isExpanded) {
          _expandController.forward();
        } else {
          _expandController.reverse();
        }
      }
    }
  }

  @override
  void dispose() {
    _appearanceCurve.dispose();
    _appearanceController.dispose();
    _expandController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth;
        final playbackChild = _buildPlaybackChild(context);

        return AnimatedBuilder(
          animation: _animationListenable,
          builder: (context, _) {
            final appearance = _appearanceCurve.value;
            final expand = _expandController.value;
            // Move the focused icon first, then gather the others behind it.
            final focusProgress = Curves.easeInOut.transform(
              (expand / 0.2).clamp(0.0, 1.0),
            );
            final stackProgress = Curves.easeInOut.transform(
              ((expand - 0.2) / 0.45).clamp(0.0, 1.0),
            );
            final layoutProgress = Curves.easeInOut.transform(
              ((expand - 0.25) / 0.5).clamp(0.0, 1.0),
            );
            const compactWidth = kActiveSessionCarouselDockHeight;
            final targetExpandedWidth =
                compactWidth +
                (availableWidth - compactWidth * 2).clamp(0.0, availableWidth) *
                    layoutProgress;
            final playbackWidth = (targetExpandedWidth * appearance).clamp(
              0.0,
              availableWidth,
            );
            final navigationWidth = (availableWidth - playbackWidth).clamp(
              0.0,
              availableWidth,
            );
            final navigationChild = _buildNavigationChild(
              context,
              focusProgress: focusProgress,
              stackProgress: stackProgress,
              expandedWidth: availableWidth - compactWidth * appearance,
            );

            return Stack(
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: RepaintBoundary(
                    child: SizedBox(
                      key: const ValueKey<String>('mobile_dock_navigation'),
                      width: navigationWidth,
                      height: kActiveSessionCarouselDockHeight,
                      child: navigationChild,
                    ),
                  ),
                ),
                if (playbackChild != null)
                  Align(
                    alignment: Alignment.centerRight,
                    child: RepaintBoundary(
                      child: SizedBox(
                        key: const ValueKey<String>('mobile_dock_playback'),
                        width: playbackWidth,
                        height: kActiveSessionCarouselDockHeight,
                        child: SizedBox.expand(
                          key: widget.mobilePlaybackGeometryKey,
                          child: ClipRRect(
                            key: const ValueKey<String>(
                              'mobile_dock_playback_viewport',
                            ),
                            borderRadius: BorderRadius.circular(
                              kActiveSessionCarouselDockHeight / 2,
                            ),
                            child: appearance < 1.0
                                ? Opacity(
                                    opacity: appearance.clamp(0.0, 1.0),
                                    child: Transform.scale(
                                      scale: (0.7 + 0.3 * appearance).clamp(
                                        0.0,
                                        1.0,
                                      ),
                                      alignment: Alignment.centerRight,
                                      child: playbackChild,
                                    ),
                                  )
                                : playbackChild,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildNavigationChild(
    BuildContext context, {
    required double focusProgress,
    required double stackProgress,
    required double expandedWidth,
  }) {
    return ClipRect(
      child: widget.buildBottomBar(
        context,
        isPlaybackExpanded: widget.isPlaybackExpanded,
        focusProgress: focusProgress,
        stackProgress: stackProgress,
        expandedWidth: expandedWidth,
        onCurrentTap: widget.onShowDestinations,
      ),
    );
  }

  Widget? _buildPlaybackChild(BuildContext context) {
    if (_cachedSessions.isEmpty) return null;
    return ActiveSessionCarousel(
      key: const ValueKey<String>('mobile_dock_carousel'),
      sessions: _cachedSessions,
      i18n: widget.i18n,
      viewportFraction: 1,
      presentation: ActiveSessionCarouselPresentation.embedded,
      onOpenSession: (sessionId) {
        if (!widget.isPlaybackExpanded) {
          widget.onShowPlayback();
          return;
        }
        Navigator.of(
          context,
        ).push(buildSessionDetailRoute(sessionId: sessionId));
      },
    );
  }
}
