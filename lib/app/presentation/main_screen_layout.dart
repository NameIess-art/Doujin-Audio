part of 'main_screen.dart';

final _mainDestinationsProvider = Provider<List<MainDestination>>((ref) {
  final repository = ref.watch(settingsRepositoryProvider);
  final (:showLocal, :showAsmr, :showMy) = ref.watch(
    settingsStateProvider.select((state) {
      final settings = state.value ?? repository.slice.state;
      return (
        showLocal: settings.showLocalLibrary,
        showAsmr: settings.showAsmrOne,
        showMy: settings.showMyPage,
      );
    }),
  );
  return resolveMainDestinations(
    showLocalLibrary: showLocal,
    showAsmrOne: showAsmr,
    showMyPage: showMy,
  );
});

extension _MainScreenLayout on _MainScreenState {
  Widget _buildContentNavigator(
    BuildContext context, {
    required bool isDesktop,
    required bool isLandscapeLayout,
    required bool hasOverlaySessions,
    required bool tinyMode,
  }) {
    final body = _buildBody(
      context,
      isDesktop: isDesktop,
      isLandscapeLayout: isLandscapeLayout,
    );
    // Secondary routes cover and reveal this same dock with their page motion.
    // Keep the page under the same parent when playback restores portrait.
    // Replacing this Stack with the body would dispose every loaded tab.
    final pageContent = Stack(
      fit: StackFit.expand,
      children: [
        body,
        if (!isDesktop)
          Consumer(
            builder: (context, ref, _) => _buildMobileBottomDock(
              context,
              i18n: ref.read(appLanguageProviderInstanceProvider),
              overlaySessions: ref.watch(
                mainOverlayUiProvider.select((state) => state.overlaySessions),
              ),
              tinyMode: tinyMode,
            ),
          ),
      ],
    );
    // Only the home page ignores IME height. Routes above it still need live
    // insets so search fields and dialogs can move clear of the keyboard.
    final mainPage = Builder(
      builder: (context) => MediaQuery.removeViewInsets(
        key: const ValueKey<String>('main_screen_keyboard_inset_boundary'),
        context: context,
        removeBottom: true,
        child: pageContent,
      ),
    );
    final navigation = WorkDetailNavigationScope.maybeOf(context);
    if (navigation == null) return mainPage;
    return MainContentNavigator(
      navigation: navigation,
      isLandscape: isLandscapeLayout,
      geometry: widget.playbackDockGeometry,
      // The root page keeps the main dock inset; routed pages use their host's.
      child: _wrapMobileOverlayInset(
        isDesktop: isDesktop,
        hasOverlaySessions: hasOverlaySessions,
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
    final destinations = ref.watch(_mainDestinationsProvider);
    Widget pageShell(BuildContext context, int actualIndex) {
      final page = _buildMainPage(
        context,
        actualIndex,
        destinations,
        isLandscapeLayout: isLandscapeLayout,
      );

      return KeyedSubtree(
        key: ValueKey<String>(
          'main_page_fade_${destinations[actualIndex].type.name}',
        ),
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
                duration: kAppMotionStandard,
                separateHeader: true,
                indexListenable: _activePageIndex,
                itemCount: destinations.length,
                itemIds: [
                  for (final destination in destinations) destination.type,
                ],
                contentRevision: isLandscapeLayout,
                itemBuilder: pageShell,
                wrapItem: (child, visible) =>
                    _MainTabOverlayInset(visible: visible, child: child),
                onIndexSelected: _switchPage,
                onDragPositionChanged: (position) {
                  if (mounted) _pageDragPosition.value = position;
                },
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
    return showTimerSettingsPanel(
      context,
      initialCompactDetail: timerState.duration != null,
    );
  }

  Widget _buildBottomBar(
    BuildContext context, {
    required bool isPlaybackExpanded,
    required Animation<double> appearance,
    required Animation<double> expansion,
    required Animation<double> rowProgress,
    required double availableWidth,
    required VoidCallback onCurrentTap,
  }) {
    final destinations = ref.watch(_mainDestinationsProvider);

    return ValueListenableBuilder<int>(
      valueListenable: _activePageIndex,
      builder: (context, selectedIndex, _) => _buildBottomBarContent(
        context,
        destinations,
        selectedIndex,
        isPlaybackExpanded: isPlaybackExpanded,
        appearance: appearance,
        expansion: expansion,
        rowProgress: rowProgress,
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
    required Animation<double> rowProgress,
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

    const indicatorInset = 6.0;
    final motionListenable = Listenable.merge([
      appearance,
      expansion,
      rowProgress,
    ]);
    final inactiveOpacity = _BottomDestinationOpacityAnimation(
      expansion,
      rowProgress,
    );

    double navigationLeft() =>
        MobileDockCapsuleContentState.inlinePlaybackWidth(
          availableWidth,
          expansion.value,
        ) *
        appearance.value *
        (1 - rowProgress.value);

    Rect destinationRect(int index) {
      final expand = expansion.value * (1 - rowProgress.value);
      final progress = index == 0
          ? kAppSpringCurve.transform((expand / 0.2).clamp(0.0, 1.0))
          : kAppSpringCurve.transform(((expand - 0.2) / 0.45).clamp(0.0, 1.0));
      const height = kActiveSessionCarouselDockHeight;
      final inlineShare = appearance.value * (1 - rowProgress.value);
      final width = availableWidth - navigationLeft();
      final innerWidth = (width - indicatorInset * 2).clamp(0.0, width);
      final slotWidth = innerWidth / destinations.length;
      // Reserve outer capsule insets so every indicator slot shares the same
      // width while outer destinations keep full-edge hit targets.
      final menuInnerWidth =
          (availableWidth - height * inlineShare - indicatorInset * 2).clamp(
            0.0,
            availableWidth,
          );
      final isFirst = index == 0;
      final isLast = index == destinations.length - 1;
      final outerEdgeInset =
          (isFirst ? indicatorInset : 0.0) + (isLast ? indicatorInset : 0.0);
      // Morph from the full menu cell to the single control. The shrinking
      // viewport would otherwise make the cell narrower than its final size.
      final menuSlotWidth = menuInnerWidth / destinations.length + outerEdgeInset;
      final shapeProgress = kAppSpringCurve.transform(
        ((expand - 0.25) / 0.5).clamp(0.0, 1.0),
      );
      final buttonWidth = lerpDouble(menuSlotWidth, height, shapeProgress)!;
      final distanceFromRight = isLast
          ? 0.0
          : indicatorInset + (destinations.length - 1 - index) * slotWidth;
      return Rect.fromLTWH(
        availableWidth - buttonWidth - distanceFromRight * (1 - progress),
        0,
        buttonWidth,
        height,
      );
    }

    Rect indicatorRect(int index) {
      final destination = destinationRect(index);
      final left = navigationLeft() + indicatorInset;
      final right = availableWidth - indicatorInset;
      return Rect.fromLTRB(
        destination.left.clamp(left, right),
        destination.top + indicatorInset,
        destination.right.clamp(left, right),
        destination.bottom - indicatorInset,
      );
    }

    Widget buildDestination(MapEntry<int, MainDestination> entry) {
      final index = entry.key;
      final item = destinations[index];
      final selected = index == activeIndex;
      final label = i18n.tr(item.labelKey);
      final inactive = cs.onSurfaceVariant.withValues(alpha: 0.6);

      final activeColor = cs.primary;

      final icon = AnimatedSwitcher(
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : kAppMotionFast,
        switchInCurve: kAppSpringCurve,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) =>
            MediaQuery.disableAnimationsOf(context)
            ? child
            : FadeTransition(
                opacity: animation,
                child: ScaleTransition(
                  scale: animation.drive(Tween<double>(begin: 0.85, end: 1)),
                  child: child,
                ),
              ),
        child: item.buildIcon(
          key: ValueKey<bool>(selected),
          selected: selected,
          size: 28,
        ),
      );

      return AnimatedBuilder(
        key: ValueKey(item.type),
        animation: motionListenable,
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
                child: IconTheme.merge(
                  data: IconThemeData(color: selected ? activeColor : inactive),
                  child: _BottomDestinationInkResponse(
                    inkKey: ValueKey<String>(
                      'main_destination_ink_${item.labelKey}',
                    ),
                    onTap: isPlaybackExpanded && selected
                        ? onCurrentTap
                        : () => _switchPage(index),
                    child: AnimatedBuilder(
                      animation: motionListenable,
                      child: RepaintBoundary(child: icon),
                      builder: (context, child) {
                        final destination = destinationRect(index);
                        final indicator = indicatorRect(index);
                        final dx = indicator.width > 0
                            ? indicator.center.dx - destination.center.dx
                            : 0.0;
                        return Transform.translate(
                          offset: Offset(dx, 0),
                          child: child,
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        builder: (context, child) {
          final fadeProgress = kAppSpringCurve.transform(
            expansion.value * (1 - rowProgress.value),
          );
          if (!selected && fadeProgress == 1) return const SizedBox.shrink();
          return Positioned.fromRect(
            rect: destinationRect(index),
            child: selected
                ? child!
                : FadeTransition(
                    opacity: inactiveOpacity,
                    child: Transform.scale(
                      scale: 1 - 0.15 * fadeProgress,
                      child: child,
                    ),
                  ),
          );
        },
      );
    }

    final layoutKey = Object.hashAll(destinations.map((item) => item.type));
    final stackChild = Stack(
      children: [
        for (final entry in layeredEntries) buildDestination(entry),
      ],
    );
    return Theme(
      data: Theme.of(context).copyWith(splashFactory: NoSplash.splashFactory),
      child: _MobileBottomBarDragScrubber(
        enabled: !isPlaybackExpanded && destinations.length > 1,
        destinationCount: destinations.length,
        activeIndex: activeIndex,
        slotAt: indicatorRect,
        onSelectIndex: _switchPage,
        builder: (context, dragPosition) => ValueListenableBuilder<double?>(
          valueListenable: _pageDragPosition,
          builder: (context, pageDragPosition, _) => SlidingSelectionIndicator(
            index: activeIndex,
            layoutKey: layoutKey,
            overridePosition: dragPosition ?? pageDragPosition,
            child: stackChild,
            builder: (context, position, child) {
              return Stack(
                fit: StackFit.expand,
                children: [
                  AnimatedBuilder(
                    animation: motionListenable,
                    builder: (context, _) {
                      final rect = SlidingSelectionIndicator.rectAt(
                        position,
                        indicatorRect,
                      )!;
                      return Stack(
                        children: [
                          Positioned.fromRect(
                            rect: rect,
                            child: IgnorePointer(
                              child: DecoratedBox(
                                key: const ValueKey(
                                  'mobile_navigation_indicator',
                                ),
                                decoration: ShapeDecoration(
                                  color: SlidingSelectionIndicator.fill(
                                    cs.primary,
                                  ),
                                  shape: SlidingSelectionIndicator.shape,
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                  child!,
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildMobileBottomDock(
    BuildContext context, {
    required AppLanguageProvider i18n,
    required List<PlaybackSessionSnapshot> overlaySessions,
    bool tinyMode = false,
  }) {
    final detailNavigation = WorkDetailNavigationScope.maybeOf(context);
    final isLandscape = WorkDetailNavigationScope.isLandscapeOf(context);
    final routedDockActive = widget.playbackDockGeometry?.routedDockActive;
    return ListenableBuilder(
      listenable: Listenable.merge([
        routedDockActive ?? detailNavigation,
        _mobilePlaybackRaised,
      ]),
      builder: (context, _) {
        final isPlaybackHidden =
            !isLandscape &&
            (routedDockActive?.value ?? detailNavigation?.isOpen ?? false);
        return _buildMobileBottomCapsule(
          context,
          key: const ValueKey('capsule'),
          i18n: i18n,
          overlaySessions: overlaySessions,
          tinyMode: tinyMode,
          isPlaybackHidden: isPlaybackHidden,
        );
      },
    );
  }

  Widget _buildMobileBottomCapsule(
    BuildContext context, {
    Key? key,
    required AppLanguageProvider i18n,
    required List<PlaybackSessionSnapshot> overlaySessions,
    bool tinyMode = false,
    bool isPlaybackHidden = false,
  }) {
    if (tinyMode) return SizedBox.expand(key: key);
    final maskHeight =
        kActiveSessionCarouselDockHeight +
        kMobileDockBottomMargin +
        2.0 +
        MediaQuery.paddingOf(context).bottom;
    return MobileDockCapsuleContent(
      overlaySessions: overlaySessions,
      isPlaybackExpanded:
          overlaySessions.isNotEmpty && _isMobilePlaybackExpanded,
      isPlaybackRaised: _isMobilePlaybackRaised,
      isPlaybackHidden: isPlaybackHidden,
      i18n: i18n,
      mobilePlaybackGeometryKey: _mobilePlaybackGeometryKey,
      onShowPlayback: _showMobilePlayback,
      onShowDestinations: _showMobileDestinations,
      onTogglePlaybackRow: _toggleMobilePlaybackRow,
      onReportPlaybackCoverRect: _reportMobilePlaybackCoverRect,
      buildBottomBar: _buildBottomBar,
      wrapDock: (dock, rowProgress) => Stack(
        key: key,
        fit: StackFit.expand,
        children: [
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: AnimatedBuilder(
              animation: rowProgress,
              builder: (context, child) => SizedBox(
                height:
                    maskHeight +
                    rowProgress.value * MobileDockCapsuleContentState.rowTravel,
                child: child,
              ),
              child: const Listener(
                behavior: HitTestBehavior.opaque,
                child: AppEdgeFadeMask(
                  key: ValueKey<String>('mobile_bottom_capsule_fade_mask'),
                  direction: AppEdgeFadeDirection.towardBottom,
                ),
              ),
            ),
          ),
          SafeArea(
            top: false,
            minimum: const EdgeInsets.only(bottom: kMobileDockBottomMargin),
            child: Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(
                width: double.infinity,
                child: Padding(
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
                      child: dock,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDesktopNavigation(
    BuildContext context,
    AppLanguageProvider i18n,
    List<PlaybackSessionSnapshot> overlaySessions, {
    required bool isMenuCollapsed,
    bool canToggleMenu = true,
  }) {
    final destinations = ref.watch(_mainDestinationsProvider);

    return DesktopMainNavigation(
      i18n: i18n,
      overlaySessions: overlaySessions,
      destinations: destinations,
      isMenuCollapsed: isMenuCollapsed,
      activePageIndex: _activePageIndex,
      menuIconKeys: _menuIconKeys,
      menuIconLinks: _menuIconLinks,
      collapseOffset: _menuIconCollapseOffset,
      onSwitchPage: _switchPage,
      onToggleMenu: canToggleMenu ? _toggleMenuCollapsed : null,
      playbackGeometryKey: _desktopPlaybackGeometryKey,
      onReportPlaybackRect: _reportDesktopPlaybackRect,
      pageDragPosition: _pageDragPosition,
    );
  }

  Widget _wrapMobileOverlayInset({
    required bool isDesktop,
    required bool hasOverlaySessions,
    required ValueNotifier<VoidCallback?>? menuDismiss,
    required Widget child,
  }) {
    // Keep the navigator's ancestors stable while playback restores portrait.
    return ValueListenableBuilder<bool?>(
      valueListenable: _mobilePlaybackRaised,
      child: child,
      builder: (context, _, child) => MobileOverlayInset(
        bottomInset: isDesktop
            ? 0.0
            : _mobileContentInset(
                context,
                hasOverlaySessions: hasOverlaySessions,
              ),
        menuOverlayKey: _mainMenuOverlayKey,
        menuDismiss: menuDismiss,
        child: child!,
      ),
    );
  }

  double _mobileContentInset(
    BuildContext context, {
    required bool hasOverlaySessions,
  }) {
    final hasRaisedPlayback = _isMobilePlaybackRaised && hasOverlaySessions;
    final systemBottom = MediaQuery.paddingOf(context).bottom;
    return max(systemBottom, kMobileDockBottomMargin) +
        kActiveSessionCarouselDockHeight +
        (hasRaisedPlayback ? MobileDockCapsuleContentState.rowTravel : 0);
  }
}

class _MainTabOverlayInset extends StatefulWidget {
  const _MainTabOverlayInset({required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  State<_MainTabOverlayInset> createState() => _MainTabOverlayInsetState();
}

class _MainTabOverlayInsetState extends State<_MainTabOverlayInset> {
  double _bottomInset = 0;

  @override
  Widget build(BuildContext context) {
    final overlay = context
        .dependOnInheritedWidgetOfExactType<MobileOverlayInset>();
    // A retained tab can reuse its layout until the stack prepares it again.
    if (widget.visible) _bottomInset = overlay?.bottomInset ?? 0;
    return MobileOverlayInset(
      bottomInset: _bottomInset,
      menuOverlayKey: overlay?.menuOverlayKey,
      menuDismiss: overlay?.menuDismiss,
      child: widget.child,
    );
  }
}

class _MobileBottomBarDragScrubber extends StatefulWidget {
  const _MobileBottomBarDragScrubber({
    required this.enabled,
    required this.destinationCount,
    required this.activeIndex,
    required this.slotAt,
    required this.onSelectIndex,
    required this.builder,
  });

  final bool enabled;
  final int destinationCount;
  final int activeIndex;
  final Rect Function(int index) slotAt;
  final ValueChanged<int> onSelectIndex;
  final Widget Function(BuildContext context, double? dragPosition) builder;

  @override
  State<_MobileBottomBarDragScrubber> createState() =>
      _MobileBottomBarDragScrubberState();
}

class _MobileBottomBarDragScrubberState
    extends State<_MobileBottomBarDragScrubber> {
  double? _dragPosition;
  int? _lastNotifiedIndex;

  @override
  void didUpdateWidget(covariant _MobileBottomBarDragScrubber oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && _dragPosition != null) {
      _dragPosition = null;
      _lastNotifiedIndex = null;
    }
  }

  double _positionForDx(double dx) {
    final first = widget.slotAt(0).center.dx;
    final last = widget.slotAt(widget.destinationCount - 1).center.dx;
    final span = last - first;
    if (span <= 0) return widget.activeIndex.toDouble();
    final t = ((dx - first) / span).clamp(0.0, 1.0);
    return t * (widget.destinationCount - 1);
  }

  void _updateDrag(double dx) {
    final position = _positionForDx(dx);
    final nearest = position.round().clamp(0, widget.destinationCount - 1);
    setState(() => _dragPosition = position);
    if (nearest != _lastNotifiedIndex) {
      _lastNotifiedIndex = nearest;
      if (nearest != widget.activeIndex) {
        widget.onSelectIndex(nearest);
      }
    }
  }

  void _endDrag() {
    if (_dragPosition == null) return;
    setState(() => _dragPosition = null);
    _lastNotifiedIndex = null;
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: widget.enabled
          ? (details) {
              _lastNotifiedIndex = widget.activeIndex;
              _updateDrag(details.localPosition.dx);
            }
          : null,
      onHorizontalDragUpdate: widget.enabled
          ? (details) => _updateDrag(details.localPosition.dx)
          : null,
      onHorizontalDragEnd: widget.enabled ? (_) => _endDrag() : null,
      onHorizontalDragCancel: widget.enabled ? _endDrag : null,
      child: widget.builder(context, _dragPosition),
    );
  }
}

class _BottomDestinationOpacityAnimation extends Animation<double> {
  _BottomDestinationOpacityAnimation(this._expansion, this._rowProgress);

  final Animation<double> _expansion;
  final Animation<double> _rowProgress;

  @override
  void addListener(VoidCallback listener) {
    _expansion.addListener(listener);
    _rowProgress.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    _expansion.removeListener(listener);
    _rowProgress.removeListener(listener);
  }

  @override
  void addStatusListener(AnimationStatusListener listener) {
    _expansion.addStatusListener(listener);
    _rowProgress.addStatusListener(listener);
  }

  @override
  void removeStatusListener(AnimationStatusListener listener) {
    _expansion.removeStatusListener(listener);
    _rowProgress.removeStatusListener(listener);
  }

  @override
  AnimationStatus get status => _expansion.status;

  @override
  double get value =>
      1 -
      kAppSpringCurve.transform(_expansion.value * (1 - _rowProgress.value));
}
