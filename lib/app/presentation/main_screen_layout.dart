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
    final destinations = resolveMainDestinations(
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
      style: AppIndexedStackTransitionStyle.none,
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
    required double anchorProgress,
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
        anchorProgress: anchorProgress,
        stackProgress: stackProgress,
        expandedWidth: expandedWidth,
        onCurrentTap: onCurrentTap,
      ),
    );
  }

  Widget _buildBottomBarContent(
    BuildContext context,
    List<MainDestination> destinations,
    int selectedIndex, {
    required bool isPlaybackExpanded,
    required double anchorProgress,
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
    // ASMR.ONE occupies the first slot. Keep that motion anchor independent
    // of selection, then show the active destination once the icons overlap.
    final collapsed = stackProgress == 1;
    final layeredEntries = [if (!collapsed) ...entries.skip(1), entries.first];
    final items = layeredEntries.map((entry) {
      final index = entry.key;
      final destinationIndex = index == 0 && collapsed ? activeIndex : index;
      final item = destinations[destinationIndex];
      final selected = destinationIndex == activeIndex;
      final label = item.labelKey == 'show_asmr_one'
          ? 'ASMR.ONE'
          : i18n.tr(item.labelKey);
      final inactive = cs.onSurfaceVariant.withValues(alpha: 0.6);

      final activeColor = cs.primary;
      final expandedLeft =
          expandedWidth * (index + 0.5) / destinations.length -
          kActiveSessionCarouselDockHeight / 2;
      final progress = index == 0 ? anchorProgress : stackProgress;
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
                      : () => _switchPage(destinationIndex),
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
    List<PlaybackSessionSnapshot> overlaySessions,
  ) {
    final (:showLocal, :showAsmr) = ref.watch(
      settingsStateProvider.select(
        (s) => (
          showLocal: s.value?.showLocalLibrary ?? true,
          showAsmr: s.value?.showAsmrOne ?? true,
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
      isMenuCollapsed: _isMenuCollapsed,
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
