part of 'main_screen.dart';

extension _MainScreenLayout on _MainScreenState {
  Widget _buildAnimatedBody({required bool isDesktop}) {
    final cs = Theme.of(context).colorScheme;
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
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final settingsState = ref.watch(settingsStateProvider).value;
    final showLocal = settingsState?.showLocalLibrary ?? true;
    final showAsmr = settingsState?.showAsmrOne ?? true;
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
            child: DecoratedBox(
              decoration: isDesktop
                  ? BoxDecoration(
                      color: isLandscapeLayout
                          ? cs.surface
                          : cs.surfaceContainerLow,
                      borderRadius: isLandscapeLayout
                          ? const BorderRadius.only(
                              topLeft: Radius.circular(AppRadius.medium),
                            )
                          : radius,
                      border: isLandscapeLayout
                          ? Border(
                              left: BorderSide(
                                color: cs.outlineVariant.withValues(
                                  alpha: 0.25,
                                ),
                              ),
                              top: BorderSide(
                                color: cs.outlineVariant.withValues(
                                  alpha: 0.25,
                                ),
                              ),
                            )
                          : Border.all(
                              color: cs.outlineVariant.withValues(alpha: 0.85),
                            ),
                      boxShadow: isLandscapeLayout
                          ? [
                              BoxShadow(
                                color: cs.shadow.withValues(alpha: 0.04),
                                blurRadius: 16,
                                offset: const Offset(-2, -2),
                              ),
                            ]
                          : [
                              BoxShadow(
                                color: cs.shadow.withValues(alpha: 0.1),
                                blurRadius: 28,
                                offset: const Offset(0, 12),
                              ),
                            ],
                    )
                  : const BoxDecoration(),
              child: ClipRRect(
                borderRadius: isDesktop
                    ? (isLandscapeLayout
                          ? const BorderRadius.only(
                              topLeft: Radius.circular(AppRadius.medium),
                            )
                          : radius)
                    : BorderRadius.zero,
                clipBehavior: isDesktop ? Clip.hardEdge : Clip.none,
                child: ColoredBox(
                  key: ValueKey<String>('main_page_canvas_$actualIndex'),
                  color: cs.surface,
                  child: RepaintBoundary(child: page),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return AppFadeThroughIndexedStack.lazy(
      key: const ValueKey<String>('main_page_stack'),
      indexListenable: _activePageIndex,
      itemCount: destinations.length,
      itemBuilder: pageShell,
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
      builder: (_) => TimerTab(
        showHeader: false,
        useSafeArea: false,
        compactOnly: true,
        initialCompactDetail: timerState.duration != null,
      ),
    );
  }

  Widget _buildBottomBar(BuildContext context) {
    final settingsState = ref.watch(settingsStateProvider).value;
    final showLocal = settingsState?.showLocalLibrary ?? true;
    final showAsmr = settingsState?.showAsmrOne ?? true;
    final destinations = _resolveMainDestinations(
      showLocalLibrary: showLocal,
      showAsmrOne: showAsmr,
    );

    return ValueListenableBuilder<int>(
      valueListenable: _activePageIndex,
      builder: (context, selectedIndex, _) =>
          _buildBottomBarContent(context, destinations, selectedIndex),
    );
  }

  Widget _buildBottomBarContent(
    BuildContext context,
    List<_MainDestination> destinations,
    int selectedIndex,
  ) {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final cs = Theme.of(context).colorScheme;

    final items = destinations.asMap().entries.map((entry) {
      final index = entry.key;
      final item = entry.value;
      final selected = index == selectedIndex;
      final label = item.labelKey == 'show_asmr_one'
          ? 'ASMR.ONE'
          : i18n.tr(item.labelKey);
      final inactive = cs.onSurfaceVariant.withValues(alpha: 0.6);

      final tokens = AppDesignTokens.of(context);
      final activeColor = cs.primary;
      final labelText = AnimatedDefaultTextStyle(
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
        style: Theme.of(context).textTheme.labelSmall!.copyWith(
          fontSize: 10,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
          color: selected ? activeColor : inactive,
          letterSpacing: 0,
        ),
        child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      );

      return Expanded(
        child: Semantics(
          key: ValueKey<String>('main_destination_${item.labelKey}'),
          button: true,
          selected: selected,
          label: label,
          child: Material(
            type: MaterialType.transparency,
            child: _BottomDestinationInkResponse(
              inkKey: ValueKey<String>('main_destination_ink_${item.labelKey}'),
              onTap: () => _switchPage(index),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Stack(
                    alignment: Alignment.center,
                    children: [
                      AnimatedContainer(
                        duration: MediaQuery.disableAnimationsOf(context)
                            ? Duration.zero
                            : const Duration(milliseconds: 350),
                        curve: Curves.easeOutCubic,
                        width: selected ? 56 : 0,
                        height: 26,
                        decoration: BoxDecoration(
                          color: selected
                              ? activeColor.withValues(alpha: 0.11)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(
                            tokens.radiusCard,
                          ),
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
                          size: 20,
                          color: selected ? activeColor : inactive,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 1),
                  labelText,
                ],
              ),
            ),
          ),
        ),
      );
    }).toList();

    return Theme(
      data: Theme.of(context).copyWith(splashFactory: NoSplash.splashFactory),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: items,
      ),
    );
  }

  Widget _buildMobileBottomDock(
    BuildContext context, {
    required AppLanguageProvider i18n,
    required List<PlaybackSessionSnapshot> overlaySessions,
    required BottomNavigationStyle style,
    bool tinyMode = false,
  }) {
    final isBar = style == BottomNavigationStyle.bar;
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    return AnimatedSwitcher(
      duration: reducedMotion
          ? Duration.zero
          : const Duration(milliseconds: 300),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) {
        return buildAppScaleFadeTransition(
          context: context,
          animation: animation,
          child: child,
          beginScale: 0.96,
        );
      },
      child: isBar
          ? _buildMobileBottomNavigationBar(
              context,
              key: const ValueKey('bar'),
              i18n: i18n,
              overlaySessions: overlaySessions,
              tinyMode: tinyMode,
              isCurrent: isBar,
            )
          : _buildMobileBottomCapsule(
              context,
              key: const ValueKey('capsule'),
              i18n: i18n,
              overlaySessions: overlaySessions,
              tinyMode: tinyMode,
              isCurrent: !isBar,
            ),
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
    return Stack(
      key: key,
      fit: StackFit.expand,
      children: [
        if (!tinyMode)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 60 + systemBottom,
            child: const AppEdgeFadeMask(
              key: ValueKey<String>('mobile_bottom_capsule_fade_mask'),
              direction: AppEdgeFadeDirection.towardBottom,
            ),
          ),
        SafeArea(
          top: false,
          minimum: const EdgeInsets.only(bottom: 6),
          child: Align(
            alignment: Alignment.bottomCenter,
            child: SizedBox(
              width: double.infinity,
              child: Column(
                key: isCurrent ? _dockContentKey : null,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (overlaySessions.isNotEmpty)
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final viewportWidth = constraints.maxWidth;
                        final menuWidth = (viewportWidth - AppSpacing.sm * 2)
                            .clamp(0.0, 430.0)
                            .toDouble();
                        final cardWidth = menuWidth * 0.96;
                        final viewportFraction = viewportWidth <= 0
                            ? 0.90
                            : ((cardWidth + 4) / viewportWidth).clamp(0.1, 1.0);
                        return ActiveSessionCarousel(
                          sessions: overlaySessions,
                          i18n: i18n,
                          viewportFraction: viewportFraction,
                          onOpenSession: (sessionId) {
                            Navigator.of(context).push(
                              buildSessionDetailRoute(sessionId: sessionId),
                            );
                          },
                        );
                      },
                    ),
                  if (overlaySessions.isNotEmpty) const SizedBox(height: 6),
                  if (!tinyMode)
                    Padding(
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
                          child: _FloatingGlassPanel(
                            padding: const EdgeInsets.fromLTRB(10, 5, 10, 5),
                            shadowOpacity: 0.12,
                            showTopHighlight: false,
                            tinyMode: tinyMode,
                            child: _buildBottomBar(context),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMobileBottomNavigationBar(
    BuildContext context, {
    Key? key,
    required AppLanguageProvider i18n,
    required List<PlaybackSessionSnapshot> overlaySessions,
    bool tinyMode = false,
    bool isCurrent = true,
  }) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final blurEnabled = ref.watch(
      settingsStateProvider.select((s) => s.value?.uiBlurEffectEnabled ?? true),
    );
    final bgColor = isDark ? cs.surfaceContainer : cs.surfaceContainerHigh;
    final textScale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.5);
    final barHeight = (58 * textScale).toDouble();

    Widget buildBar(bool useBlur) => DecoratedBox(
      decoration: BoxDecoration(
        color: bgColor.withValues(
          alpha: useBlur ? (isDark ? 0.82 : 0.88) : 1.0,
        ),
        border: Border(
          top: BorderSide(
            color: cs.outlineVariant.withValues(alpha: 0.55),
            width: 0.5,
          ),
        ),
      ),
      child: SizedBox(
        height: barHeight,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 2),
          child: _buildBottomBar(context),
        ),
      ),
    );

    final useBlur = blurEnabled;
    return SafeArea(
      key: key,
      top: false,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Column(
          key: isCurrent ? _dockContentKey : null,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (overlaySessions.isNotEmpty)
              ActiveSessionCarousel(
                sessions: overlaySessions,
                i18n: i18n,
                onOpenSession: (sessionId) {
                  Navigator.of(
                    context,
                  ).push(buildSessionDetailRoute(sessionId: sessionId));
                },
              ),
            if (!tinyMode)
              ClipRect(
                child: useBlur
                    ? BackdropFilter(
                        key: const ValueKey('mobile_bottom_bar_blur'),
                        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                        child: buildBar(useBlur),
                      )
                    : buildBar(useBlur),
              ),
          ],
        ),
      ),
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
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final double expandedWidth = isLandscapeLayout ? 260 : 292;
    final double collapsedWidth = isLandscapeLayout ? 80 : 92;
    final double containerWidth = _isMenuCollapsed
        ? collapsedWidth
        : expandedWidth;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      width: containerWidth,
      margin: isLandscapeLayout
          ? EdgeInsets.zero
          : const EdgeInsets.fromLTRB(AppSpacing.md, 18, AppSpacing.xs, 18),
      padding: isLandscapeLayout
          ? const EdgeInsets.fromLTRB(8, 4, 8, 8)
          : const EdgeInsets.fromLTRB(10, AppSpacing.md, 10, 10),
      decoration: BoxDecoration(
        color: isLandscapeLayout ? Colors.transparent : cs.surfaceContainerLow,
        borderRadius: isLandscapeLayout
            ? BorderRadius.zero
            : BorderRadius.circular(16),
        border: isLandscapeLayout
            ? null
            : Border.all(color: cs.outlineVariant.withValues(alpha: 0.85)),
        boxShadow: isLandscapeLayout
            ? null
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
                final settingsState = ref.watch(settingsStateProvider).value;
                final showLocal = settingsState?.showLocalLibrary ?? true;
                final showAsmr = settingsState?.showAsmrOne ?? true;
                final destinations = _resolveMainDestinations(
                  showLocalLibrary: showLocal,
                  showAsmrOne: showAsmr,
                );

                final rail = ValueListenableBuilder<int>(
                  valueListenable: _activePageIndex,
                  builder: (context, selectedIndex, _) => Theme(
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
                    child: NavigationRail(
                      backgroundColor: Colors.transparent,
                      selectedIndex: selectedIndex < destinations.length
                          ? selectedIndex
                          : 0,
                      onDestinationSelected: _switchPage,
                      extended: !_isMenuCollapsed,
                      minWidth: 64,
                      minExtendedWidth: isLandscapeLayout ? 212 : 236,
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
                                        icon: const Icon(Icons.menu_rounded),
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
                                              color: cs.onPrimaryContainer,
                                            ),
                                          ),
                                          const SizedBox(
                                            width: AppSpacing.sm,
                                          ),
                                          Expanded(
                                            child: Text(
                                              i18n.tr('asmr_player'),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
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
                                            onPressed: _toggleMenuCollapsed,
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
                        final isSelected = selectedIndex == index;
                        final label = item.labelKey == 'show_asmr_one'
                            ? 'ASMR.ONE'
                            : i18n.tr(item.labelKey);

                        return NavigationRailDestination(
                          icon: Icon(
                            item.icon,
                            key: ValueKey<String>(
                              'main_destination_${item.labelKey}',
                            ),
                          ),
                          selectedIcon: Icon(
                            item.selectedIcon,
                            key: ValueKey<String>(
                              'main_destination_${item.labelKey}',
                            ),
                            color: cs.primary,
                          ),
                          label: Text(
                            _isMenuCollapsed ? '' : label,
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
                  ),
                );

                return rail;
              },
            ),
          ),
          if (overlaySessions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.sm),
              child: ActiveSessionCarousel(
                sessions: overlaySessions,
                i18n: i18n,
                compactForFab: _isMenuCollapsed,
                onOpenSession: (sessionId) {
                  Navigator.of(
                    context,
                  ).push(buildSessionDetailRoute(sessionId: sessionId));
                },
              ),
            ),
        ],
      ),
    );
  }

  double _mobileContentInset({
    required bool hasNowPlaying,
    required bool? previousHasNowPlaying,
    required BottomNavigationStyle bottomNavigationStyle,
  }) {
    // The render box still has the previous frame's height while the playback
    // card is entering or leaving, so compensate for that one transition.
    final contentBox =
        _dockContentKey.currentContext?.findRenderObject() as RenderBox?;
    if (contentBox != null && contentBox.hasSize) {
      final systemBottom = MediaQuery.of(context).padding.bottom;
      var contentHeight = contentBox.size.height;
      if (previousHasNowPlaying != null &&
          previousHasNowPlaying != hasNowPlaying) {
        final cardExtent = bottomNavigationStyle == BottomNavigationStyle.bar
            ? kActiveSessionCarouselBarHeight
            : kActiveSessionCarouselCapsuleHeight + 6;
        contentHeight += hasNowPlaying ? cardExtent : -cardExtent;
      }
      return (max(systemBottom, 6.0) + contentHeight).clamp(
        0.0,
        double.infinity,
      );
    }
    final systemBottom = MediaQuery.of(context).padding.bottom;
    if (hasNowPlaying) return systemBottom + 150;
    return systemBottom + 60;
  }
}
