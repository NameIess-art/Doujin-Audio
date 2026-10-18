part of 'main_screen.dart';

extension _MainScreenLayout on _MainScreenState {
  Widget _buildContentNavigator(
    BuildContext context, {
    required bool isDesktop,
    required bool isLandscapeLayout,
    required double bottomInset,
    required bool tinyMode,
  }) {
    final body = _buildBody(
      context,
      isDesktop: isDesktop,
      isLandscapeLayout: isLandscapeLayout,
    );
    // Secondary routes cover and reveal this same dock with their page motion.
    final mainPage = isDesktop
        ? body
        : Stack(
            fit: StackFit.expand,
            children: [
              body,
              Consumer(
                builder: (context, ref, _) => _buildMobileBottomDock(
                  context,
                  i18n: ref.read(appLanguageProviderInstanceProvider),
                  overlaySessions: ref.watch(
                    mainOverlayUiProvider.select(
                      (state) => state.overlaySessions,
                    ),
                  ),
                  tinyMode: tinyMode,
                ),
              ),
            ],
          );
    final navigation = WorkDetailNavigationScope.maybeOf(context);
    if (navigation == null) return mainPage;
    return MainContentNavigator(
      navigation: navigation,
      isLandscape: isLandscapeLayout,
      geometry: widget.playbackDockGeometry,
      // The root page keeps the main dock inset; routed pages use their host's.
      child: MobileOverlayInset(
        bottomInset: bottomInset,
        menuOverlayKey: _mainMenuOverlayKey,
        menuDismiss: navigation.menuDismiss,
        child: mainPage,
      ),
    );
  }

  Widget _buildBody(
    BuildContext context, {
    required bool isDesktop,
    required bool isLandscapeLayout,
  }) {
    final fallbackSettings = ref.read(settingsRepositoryProvider).slice.state;
    final layoutSize = MediaQuery.sizeOf(context);
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
    final (:showLocal, :showAsmr) = ref.watch(
      settingsStateProvider.select(
        (s) => (
          showLocal:
              s.value?.showLocalLibrary ?? fallbackSettings.showLocalLibrary,
          showAsmr: s.value?.showAsmrOne ?? fallbackSettings.showAsmrOne,
        ),
      ),
    );
    final destinations = resolveMainDestinations(
      showLocalLibrary: showLocal,
      showAsmrOne: showAsmr,
    );
    if (_activePageIndex.value >= destinations.length) {
      _activePageIndex.value = destinations.length - 1;
    }
    Widget pageShell(BuildContext context, int actualIndex) {
      final page = _buildMainPage(
        context,
        actualIndex,
        destinations,
        isLandscapeLayout: isLandscapeLayout,
      );

      return KeyedSubtree(
        key: ValueKey<String>('main_page_fade_$actualIndex'),
        child: page,
      );
    }

    final pageCs = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: isDesktop && !isLandscapeLayout ? padding : EdgeInsets.zero,
        child: DecoratedBox(
          decoration: isDesktop
              ? BoxDecoration(
                  color: isLandscapeLayout
                      ? pageCs.surface
                      : pageCs.surfaceContainerLow,
                  borderRadius: isLandscapeLayout ? BorderRadius.zero : radius,
                  border: isLandscapeLayout
                      ? null
                      : Border.all(
                          color: pageCs.outlineVariant.withValues(alpha: 0.85),
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
              key: const ValueKey<String>('main_page_canvas'),
              color: pageCs.surface,
              child: AppFadeThroughIndexedStack.lazy(
                key: const ValueKey<String>('main_page_stack'),
                separateHeader: true,
                indexListenable: _activePageIndex,
                itemCount: destinations.length,
                contentRevision: (showLocal, showAsmr, isLandscapeLayout),
                itemBuilder: pageShell,
                onTransitionCompleted: _handlePageTransitionCompleted,
              ),
            ),
          ),
        ),
      ),
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
    required Animation<double> appearance,
    required Animation<double> expansion,
    required double availableWidth,
    required VoidCallback onCurrentTap,
  }) {
    final fallbackSettings = ref.read(settingsRepositoryProvider).slice.state;
    final (:showLocal, :showAsmr) = ref.watch(
      settingsStateProvider.select(
        (s) => (
          showLocal:
              s.value?.showLocalLibrary ?? fallbackSettings.showLocalLibrary,
          showAsmr: s.value?.showAsmrOne ?? fallbackSettings.showAsmrOne,
        ),
      ),
    );
    final destinations = resolveMainDestinations(
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
        appearance: appearance,
        expansion: expansion,
        availableWidth: availableWidth,
        onCurrentTap: onCurrentTap,
      ),
    );
  }

  Widget _buildBottomBarContent(
    BuildContext context,
    List<MainDestination> destinations,
    int selectedIndex, {
    required bool isPlaybackExpanded,
    required Animation<double> appearance,
    required Animation<double> expansion,
    required double availableWidth,
    required VoidCallback onCurrentTap,
  }) {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final cs = Theme.of(context).colorScheme;

    final entries = destinations.asMap().entries.toList();
    final activeIndex = selectedIndex.clamp(0, destinations.length - 1);
    // Keep the active destination on top throughout collapsing and expanding,
    // smoothly folding inactive destinations beneath it.
    final layeredEntries = [
      ...entries.where((entry) => entry.key != activeIndex),
      entries[activeIndex],
    ];
    final items = layeredEntries.map((entry) {
      final index = entry.key;
      final item = destinations[index];
      final selected = index == activeIndex;
      final label = item.labelKey == 'show_asmr_one'
          ? 'ASMR.ONE'
          : i18n.tr(item.labelKey);
      final inactive = cs.onSurfaceVariant.withValues(alpha: 0.6);

      final activeColor = cs.primary;

      final iconStack = Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            left: 6,
            right: 6,
            top: 6,
            bottom: 6,
            child: AnimatedContainer(
              key: ValueKey<String>(
                'main_destination_indicator_${item.labelKey}',
              ),
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
              decoration: BoxDecoration(
                color: selected
                    ? activeColor.withValues(alpha: 0.11)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(22),
              ),
            ),
          ),
          AnimatedSwitcher(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : kAppFadeDuration,
            switchInCurve: kAppFadeCurve,
            switchOutCurve: kAppFadeCurve,
            transitionBuilder: (child, animation) =>
                MediaQuery.disableAnimationsOf(context)
                ? child
                : FadeTransition(
                    opacity: animation,
                    child: ScaleTransition(
                      scale: animation.drive(Tween<double>(begin: 0.9, end: 1)),
                      child: child,
                    ),
                  ),
            child: Icon(
              selected ? item.selectedIcon : item.icon,
              key: ValueKey<bool>(selected),
              size: 28,
              color: selected ? activeColor : inactive,
            ),
          ),
        ],
      );

      return AnimatedBuilder(
        animation: Listenable.merge([appearance, expansion]),
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
                  child: RepaintBoundary(child: iconStack),
                ),
              ),
            ),
          ),
        ),
        builder: (context, child) {
          final expand = expansion.value;
          final fadeProgress = kAppFadeCurve.transform(expand);
          if (!selected && fadeProgress == 1) {
            return const SizedBox.shrink();
          }
          final progress = index == 0
              ? Curves.easeInOut.transform((expand / 0.2).clamp(0.0, 1.0))
              : Curves.easeInOut.transform(
                  ((expand - 0.2) / 0.45).clamp(0.0, 1.0),
                );
          final expandedWidth =
              availableWidth -
              kActiveSessionCarouselDockHeight * appearance.value;
          final indicatorWidth =
              ((expandedWidth - 12 - 4 * (destinations.length - 1)) /
                      destinations.length)
                  .clamp(44.0, 68.0);
          final shapeProgress = Curves.easeInOut.transform(
            ((expand - 0.25) / 0.5).clamp(0.0, 1.0),
          );
          final buttonWidth =
              12 + lerpDouble(indicatorWidth, 44, shapeProgress)!;
          // Six pixels of inset put the 44px pill arcs on the 56px dock arcs.
          final expandedLeft =
              (expandedWidth - indicatorWidth - 12) *
              index /
              (destinations.length - 1);
          return Positioned(
            left: 0,
            top: 0,
            width: buttonWidth,
            height: kActiveSessionCarouselDockHeight,
            child: Transform.translate(
              offset: Offset(expandedLeft * (1 - progress), 0),
              child: selected
                  ? child
                  : Opacity(
                      opacity: 1 - fadeProgress,
                      child: Transform.scale(
                        scale: 1 - 0.15 * fadeProgress,
                        child: child,
                      ),
                    ),
            ),
          );
        },
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
                          child: AppDockPanel(
                            key: const ValueKey<String>(
                              'mobile_bottom_capsule_surface',
                            ),
                            shadowOpacity: 0.12,
                            showTopHighlight: false,
                            tinyMode: tinyMode,
                            child: SizedBox(
                              height: kActiveSessionCarouselDockHeight,
                              child: MobileDockCapsuleContent(
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
    List<PlaybackSessionSnapshot> overlaySessions, {
    required bool isMenuCollapsed,
  }) {
    final fallbackSettings = ref.read(settingsRepositoryProvider).slice.state;
    final (:showLocal, :showAsmr) = ref.watch(
      settingsStateProvider.select(
        (s) => (
          showLocal:
              s.value?.showLocalLibrary ?? fallbackSettings.showLocalLibrary,
          showAsmr: s.value?.showAsmrOne ?? fallbackSettings.showAsmrOne,
        ),
      ),
    );
    return DesktopMainNavigation(
      i18n: i18n,
      overlaySessions: overlaySessions,
      destinations: resolveMainDestinations(
        showLocalLibrary: showLocal,
        showAsmrOne: showAsmr,
      ),
      isMenuCollapsed: isMenuCollapsed,
      activePageIndex: _activePageIndex,
      menuIconKeys: _menuIconKeys,
      menuIconLinks: _menuIconLinks,
      collapseOffset: _menuIconCollapseOffset,
      onSwitchPage: _switchPage,
      onToggleMenu: _toggleMenuCollapsed,
      playbackGeometryKey: _desktopPlaybackGeometryKey,
      onReportPlaybackRect: _reportDesktopPlaybackRect,
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
