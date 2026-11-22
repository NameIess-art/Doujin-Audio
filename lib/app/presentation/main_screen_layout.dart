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
    return _MobileBottomBarContent(
      destinations: destinations,
      selectedIndex: selectedIndex,
      isPlaybackExpanded: isPlaybackExpanded,
      appearance: appearance,
      expansion: expansion,
      rowProgress: rowProgress,
      availableWidth: availableWidth,
      onCurrentTap: onCurrentTap,
      onSwitchPage: _switchPage,
      pageDragPosition: _pageDragPosition,
      i18n: i18n,
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
    final visibilitySource = routedDockActive ?? detailNavigation;
    if (_mobileDockVisibilityListenable == null ||
        !identical(_mobileDockVisibilitySource, visibilitySource)) {
      _mobileDockVisibilitySource = visibilitySource;
      _mobileDockVisibilityListenable = Listenable.merge([
        visibilitySource,
        _mobilePlaybackRaised,
      ]);
    }
    return ListenableBuilder(
      listenable: _mobileDockVisibilityListenable!,
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
      onShowShortcuts: defaultTargetPlatform == TargetPlatform.windows
          ? () => unawaited(GlobalShortcuts.showHelp(context, ref))
          : null,
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

class _MobileBottomBarGeometry {
  _MobileBottomBarGeometry({
    required this.availableWidth,
    required this.destinationCount,
    required this.appearance,
    required this.expansion,
    required this.rowProgress,
  }) : inlineShare = appearance * (1 - rowProgress),
       expand = expansion * (1 - rowProgress),
       navigationLeft =
           MobileDockCapsuleContentState.inlinePlaybackWidth(
             availableWidth,
             expansion,
           ) *
           appearance *
           (1 - rowProgress),
       _destinationRects = List<Rect?>.filled(destinationCount, null),
       _indicatorRects = List<Rect?>.filled(destinationCount, null) {
    final width = availableWidth - navigationLeft;
    final innerWidth = (width - indicatorInset * 2).clamp(0.0, width);
    slotWidth = innerWidth / destinationCount;
    // Reserve outer capsule insets so every indicator slot shares the same
    // width while outer destinations keep full-edge hit targets.
    final menuInnerWidth =
        (availableWidth -
                kActiveSessionCarouselDockHeight * inlineShare -
                indicatorInset * 2)
            .clamp(0.0, availableWidth);
    menuSlotBaseWidth = menuInnerWidth / destinationCount;
    shapeProgress = kAppSpringCurve.transform(
      ((expand - 0.25) / 0.5).clamp(0.0, 1.0),
    );
    fadeProgress = kAppSpringCurve.transform(expand);
    firstProgress = kAppSpringCurve.transform((expand / 0.2).clamp(0.0, 1.0));
    otherProgress = kAppSpringCurve.transform(
      ((expand - 0.2) / 0.45).clamp(0.0, 1.0),
    );
    indicatorMinLeft = navigationLeft + indicatorInset;
    indicatorMaxRight = availableWidth - indicatorInset;
  }

  static const double indicatorInset = 6.0;

  final double availableWidth;
  final int destinationCount;
  final double appearance;
  final double expansion;
  final double rowProgress;
  final double inlineShare;
  final double expand;
  final double navigationLeft;
  late final double slotWidth;
  late final double menuSlotBaseWidth;
  late final double shapeProgress;
  late final double fadeProgress;
  late final double firstProgress;
  late final double otherProgress;
  late final double indicatorMinLeft;
  late final double indicatorMaxRight;
  final List<Rect?> _destinationRects;
  final List<Rect?> _indicatorRects;

  bool matches({
    required double availableWidth,
    required int destinationCount,
    required double appearance,
    required double expansion,
    required double rowProgress,
  }) =>
      this.availableWidth == availableWidth &&
      this.destinationCount == destinationCount &&
      this.appearance == appearance &&
      this.expansion == expansion &&
      this.rowProgress == rowProgress;

  Rect destinationRect(int index) {
    final cached = _destinationRects[index];
    if (cached != null) return cached;
    const height = kActiveSessionCarouselDockHeight;
    final isFirst = index == 0;
    final isLast = index == destinationCount - 1;
    final outerEdgeInset =
        (isFirst ? indicatorInset : 0.0) + (isLast ? indicatorInset : 0.0);
    // Morph from the full menu cell to the single control. The shrinking
    // viewport would otherwise make the cell narrower than its final size.
    final menuSlotWidth = menuSlotBaseWidth + outerEdgeInset;
    final buttonWidth = lerpDouble(menuSlotWidth, height, shapeProgress)!;
    final progress = isFirst ? firstProgress : otherProgress;
    final distanceFromRight = isLast
        ? 0.0
        : indicatorInset + (destinationCount - 1 - index) * slotWidth;
    final rect = Rect.fromLTWH(
      availableWidth - buttonWidth - distanceFromRight * (1 - progress),
      0,
      buttonWidth,
      height,
    );
    _destinationRects[index] = rect;
    return rect;
  }

  Rect indicatorRect(int index) {
    final cached = _indicatorRects[index];
    if (cached != null) return cached;
    final destination = destinationRect(index);
    final rect = Rect.fromLTRB(
      destination.left.clamp(indicatorMinLeft, indicatorMaxRight),
      destination.top + indicatorInset,
      destination.right.clamp(indicatorMinLeft, indicatorMaxRight),
      destination.bottom - indicatorInset,
    );
    _indicatorRects[index] = rect;
    return rect;
  }
}

class _MobileBottomBarContent extends StatefulWidget {
  const _MobileBottomBarContent({
    required this.destinations,
    required this.selectedIndex,
    required this.isPlaybackExpanded,
    required this.appearance,
    required this.expansion,
    required this.rowProgress,
    required this.availableWidth,
    required this.onCurrentTap,
    required this.onSwitchPage,
    required this.pageDragPosition,
    required this.i18n,
  });

  final List<MainDestination> destinations;
  final int selectedIndex;
  final bool isPlaybackExpanded;
  final Animation<double> appearance;
  final Animation<double> expansion;
  final Animation<double> rowProgress;
  final double availableWidth;
  final VoidCallback onCurrentTap;
  final ValueChanged<int> onSwitchPage;
  final ValueListenable<double?> pageDragPosition;
  final AppLanguageProvider i18n;

  @override
  State<_MobileBottomBarContent> createState() =>
      _MobileBottomBarContentState();
}

class _MobileBottomBarContentState extends State<_MobileBottomBarContent> {
  late Listenable _motionListenable;
  late _BottomDestinationOpacityAnimation _inactiveOpacity;
  _MobileBottomBarGeometry? _cachedGeometry;

  @override
  void initState() {
    super.initState();
    _initMotionListenables();
  }

  void _initMotionListenables() {
    _motionListenable = Listenable.merge([
      widget.appearance,
      widget.expansion,
      widget.rowProgress,
    ]);
    _inactiveOpacity = _BottomDestinationOpacityAnimation(
      widget.expansion,
      widget.rowProgress,
    );
  }

  @override
  void didUpdateWidget(covariant _MobileBottomBarContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.appearance != widget.appearance ||
        oldWidget.expansion != widget.expansion ||
        oldWidget.rowProgress != widget.rowProgress) {
      _initMotionListenables();
      _cachedGeometry = null;
    } else if (oldWidget.availableWidth != widget.availableWidth ||
        oldWidget.destinations.length != widget.destinations.length) {
      _cachedGeometry = null;
    }
  }

  _MobileBottomBarGeometry _geometry() {
    final appearance = widget.appearance.value;
    final expansion = widget.expansion.value;
    final rowProgress = widget.rowProgress.value;
    final existing = _cachedGeometry;
    if (existing != null &&
        existing.matches(
          availableWidth: widget.availableWidth,
          destinationCount: widget.destinations.length,
          appearance: appearance,
          expansion: expansion,
          rowProgress: rowProgress,
        )) {
      return existing;
    }
    return _cachedGeometry = _MobileBottomBarGeometry(
      availableWidth: widget.availableWidth,
      destinationCount: widget.destinations.length,
      appearance: appearance,
      expansion: expansion,
      rowProgress: rowProgress,
    );
  }

  Rect _indicatorRect(int index) => _geometry().indicatorRect(index);

  @override
  Widget build(BuildContext context) {
    final destinations = widget.destinations;
    final cs = Theme.of(context).colorScheme;
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    final activeIndex = widget.selectedIndex.clamp(0, destinations.length - 1);
    final entries = destinations.asMap().entries.toList();
    // Keep the active destination on top throughout collapsing and expanding,
    // smoothly folding inactive destinations beneath it.
    final layeredEntries = [
      ...entries.where((entry) => entry.key != activeIndex),
      entries[activeIndex],
    ];

    Widget buildDestination(MapEntry<int, MainDestination> entry) {
      final index = entry.key;
      final item = destinations[index];
      final selected = index == activeIndex;
      final label = widget.i18n.tr(item.labelKey);
      final inactive = cs.onSurfaceVariant.withValues(alpha: 0.6);
      final activeColor = cs.primary;

      final icon = AnimatedSwitcher(
        duration: disableAnimations ? Duration.zero : kAppMotionFast,
        switchInCurve: kAppSpringCurve,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) => disableAnimations
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
        animation: _motionListenable,
        child: IgnorePointer(
          ignoring: widget.isPlaybackExpanded && !selected,
          child: ExcludeSemantics(
            excluding: widget.isPlaybackExpanded && !selected,
            child: Semantics(
              key: ValueKey<String>('main_destination_${item.labelKey}'),
              button: true,
              selected: selected,
              label: label,
              hint: widget.isPlaybackExpanded && selected
                  ? widget.i18n.tr('dock_show_navigation')
                  : null,
              child: Material(
                type: MaterialType.transparency,
                child: IconTheme.merge(
                  data: IconThemeData(color: selected ? activeColor : inactive),
                  child: _BottomDestinationInkResponse(
                    inkKey: ValueKey<String>(
                      'main_destination_ink_${item.labelKey}',
                    ),
                    onTap: widget.isPlaybackExpanded && selected
                        ? widget.onCurrentTap
                        : () => widget.onSwitchPage(index),
                    child: AnimatedBuilder(
                      animation: _motionListenable,
                      child: RepaintBoundary(child: icon),
                      builder: (context, child) {
                        final geometry = _geometry();
                        final destination = geometry.destinationRect(index);
                        final indicator = geometry.indicatorRect(index);
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
          final geometry = _geometry();
          if (!selected && geometry.fadeProgress == 1) {
            return const SizedBox.shrink();
          }
          return Positioned.fromRect(
            rect: geometry.destinationRect(index),
            child: selected
                ? child!
                : FadeTransition(
                    opacity: _inactiveOpacity,
                    child: Transform.scale(
                      scale: 1 - 0.15 * geometry.fadeProgress,
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
        enabled: !widget.isPlaybackExpanded && destinations.length > 1,
        destinationCount: destinations.length,
        activeIndex: activeIndex,
        slotAt: _indicatorRect,
        onSelectIndex: widget.onSwitchPage,
        builder: (context, dragPosition) => ValueListenableBuilder<double?>(
          valueListenable: widget.pageDragPosition,
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
                    animation: _motionListenable,
                    builder: (context, _) {
                      final rect = SlidingSelectionIndicator.rectAt(
                        position,
                        _indicatorRect,
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
