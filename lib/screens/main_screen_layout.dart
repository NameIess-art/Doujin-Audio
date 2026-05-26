part of 'main_screen.dart';

extension _MainScreenLayout on _MainScreenState {
  Widget _buildAnimatedBody({required bool isDesktop}) {
    final cs = Theme.of(context).colorScheme;
    final width = MediaQuery.sizeOf(context).width;
    final isLargeScreen = width >= 980;
    final radius = BorderRadius.circular(
      isDesktop ? (isLargeScreen ? 16 : 12) : 24,
    );
    final padding = isDesktop
        ? (isLargeScreen
              ? const EdgeInsets.fromLTRB(24, 22, 24, 22)
              : const EdgeInsets.fromLTRB(12, 12, 16, 12))
        : EdgeInsets.zero;
    final isWindows = Platform.isWindows ||
        MediaQuery.orientationOf(context) == Orientation.landscape;

    Widget pageShell(int actualIndex) {
      final Widget page = TickerMode(
        enabled: actualIndex == _currentIndex,
        child: _pages[actualIndex],
      );

      return Align(
        alignment: Alignment.topCenter,
        child: isDesktop
            ? ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 980),
                child: Padding(
                  padding: isWindows ? EdgeInsets.zero : padding,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: isWindows ? cs.surface : cs.surfaceContainerLow,
                      borderRadius: isWindows
                          ? const BorderRadius.only(topLeft: Radius.circular(8))
                          : radius,
                      border: isWindows
                          ? Border(
                              left: BorderSide(
                                color: cs.outlineVariant.withValues(alpha: 0.5),
                              ),
                              top: BorderSide(
                                color: cs.outlineVariant.withValues(alpha: 0.5),
                              ),
                            )
                          : Border.all(
                              color: cs.outlineVariant.withValues(alpha: 0.85),
                            ),
                      boxShadow: isWindows
                          ? null
                          : [
                              BoxShadow(
                                color: cs.shadow.withValues(alpha: 0.1),
                                blurRadius: 28,
                                offset: const Offset(0, 12),
                              ),
                            ],
                    ),
                    child: ClipRRect(
                      borderRadius: isWindows
                          ? const BorderRadius.only(topLeft: Radius.circular(8))
                          : radius,
                      clipBehavior: Clip.hardEdge,
                      child: ColoredBox(
                        color: cs.surface,
                        child: RepaintBoundary(child: page),
                      ),
                    ),
                  ),
                ),
              )
            : RepaintBoundary(child: page),
      );
    }

    return PageView.builder(
      key: _pageViewKey,
      controller: _pageController,
      clipBehavior: Clip.none,
      physics: const _TelegramLikeScrollPhysics(
        parent: ClampingScrollPhysics(),
      ),
      onPageChanged: (index) {
        if (_pendingTargetIndex != null && index != _pendingTargetIndex) {
          return;
        }
        _pendingTargetIndex = null;
        if (_currentIndex == index) return;
        _setLocalState(() {
          _currentIndex = index;
        });
        ref
            .read(audioProviderFacadeProvider)
            .scheduleUiWarmup(currentPageIndex: index);
      },
      itemCount: _pages.length,
      itemBuilder: (context, i) {
        return pageShell(i);
      },
    );
  }

  Future<void> _openTimerSettingsPage(
    BuildContext context,
    _TimerPresentation timerState,
  ) {
    final i18n = context.read<AppLanguageProvider>();
    final mediaSize = MediaQuery.sizeOf(context);
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final isDesktop =
        Platform.isWindows || mediaSize.width >= 760 || isLandscape;

    if (!_timerOverlayPrimed) {
      _setLocalState(() {
        _timerOverlayPrimed = true;
      });
    }

    return showGeneralDialog<void>(
      context: context,
      barrierLabel: i18n.tr('close'),
      barrierDismissible: true,
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        return _TimerOverlaySheet(
          isDesktop: isDesktop,
          animation: animation,
          openDetail: timerState.duration != null,
        );
      },
    ).whenComplete(() {
      if (!mounted) return;
      _setLocalState(() {
        _timerOverlayPrimed = false;
      });
    });
  }

  Widget _buildBottomBar(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    final cs = Theme.of(context).colorScheme;

    final items = _MainScreenState._destinations.asMap().entries.map((entry) {
      final index = entry.key;
      final item = entry.value;
      final selected = index == _currentIndex;
      final label = i18n.tr(item.labelKey);
      final inactive = cs.onSurfaceVariant.withValues(alpha: 0.6);
      final isDark = Theme.of(context).brightness == Brightness.dark;
      final asmrBlue = isDark
          ? const Color(0xFF60A5FA)
          : const Color(0xFF1D4ED8);
      final activeColor = (index == 0) ? asmrBlue : cs.primary;

      return Expanded(
        child: Semantics(
          button: true,
          selected: selected,
          label: label,
          child: GestureDetector(
            onTap: () => _switchPage(index),
            behavior: HitTestBehavior.opaque,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Stack(
                  alignment: Alignment.center,
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeOutQuint,
                      width: selected ? 56 : 0,
                      height: 28,
                      decoration: BoxDecoration(
                        color: selected
                            ? activeColor.withValues(alpha: 0.14)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    Icon(
                      selected ? item.selectedIcon : item.icon,
                      size: 20,
                      color: selected ? activeColor : inactive,
                    ),
                  ],
                ),
                const SizedBox(height: 1),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    fontSize: 10,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    color: selected ? activeColor : inactive,
                    letterSpacing: 0.1,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }).toList();

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: items,
    );
  }

  Widget _buildMobileBottomDock(
    BuildContext context, {
    required AppLanguageProvider i18n,
    required List<PlaybackSession> overlaySessions,
    bool tinyMode = false,
  }) {
    return SafeArea(
      key: _bottomDockKey,
      top: false,
      minimum: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 430),
          child: Column(
            key: _dockContentKey,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (overlaySessions.isNotEmpty)
                ActiveSessionCarousel(
                  sessions: overlaySessions,
                  provider: ref.read(audioProviderFacadeProvider),
                  i18n: i18n,
                  onOpenSession: (sessionId) {
                    Navigator.of(
                      context,
                    ).push(buildSessionDetailRoute(sessionId: sessionId));
                  },
                ),
              if (overlaySessions.isNotEmpty) const SizedBox(height: 6),
              if (!tinyMode)
                FractionallySizedBox(
                  widthFactor: 0.9,
                  child: _FloatingGlassPanel(
                    padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
                    borderOpacity: 0.12,
                    shadowOpacity: 0.18,
                    showTopHighlight: false,
                    primaryFillOpacity: 0.82,
                    secondaryFillOpacity: 0.70,
                    tinyMode: tinyMode,
                    child: _buildBottomBar(context),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDesktopNavigation(
    BuildContext context,
    AppLanguageProvider i18n,
    List<PlaybackSession> overlaySessions,
  ) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final asmrBlue = isDark ? const Color(0xFF60A5FA) : const Color(0xFF1D4ED8);
    final isWindows = Platform.isWindows ||
        MediaQuery.orientationOf(context) == Orientation.landscape;

    return Container(
      width: 292,
      margin: isWindows
          ? EdgeInsets.zero
          : const EdgeInsets.fromLTRB(16, 18, 8, 18),
      padding: const EdgeInsets.fromLTRB(10, 16, 10, 10),
      decoration: BoxDecoration(
        color: isWindows ? Colors.transparent : cs.surfaceContainerLow,
        borderRadius: isWindows ? BorderRadius.zero : BorderRadius.circular(26),
        border: isWindows
            ? null
            : Border.all(color: cs.outlineVariant.withValues(alpha: 0.85)),
        boxShadow: isWindows
            ? null
            : [
                BoxShadow(
                  color: cs.shadow.withValues(alpha: 0.1),
                  blurRadius: 28,
                  offset: const Offset(0, 14),
                ),
              ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isWindows)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 2, 10, 14),
              child: Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: cs.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.graphic_eq_rounded,
                      color: cs.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      i18n.tr('asmr_player'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: Theme(
              data: Theme.of(context).copyWith(
                navigationRailTheme: Theme.of(context).navigationRailTheme
                    .copyWith(
                      indicatorColor: _currentIndex == 0
                          ? (isDark
                                ? const Color(0xFF1E3A8A)
                                : const Color(0xFFDBEAFE))
                          : null,
                    ),
              ),
              child: NavigationRail(
                backgroundColor: Colors.transparent,
                selectedIndex: _currentIndex,
                onDestinationSelected: _switchPage,
                extended: true,
                minExtendedWidth: 256,
                useIndicator: true,
                groupAlignment: 0.0, // Center aligned for better layout
                destinations: _MainScreenState._destinations
                    .asMap()
                    .entries
                    .map((entry) {
                      final idx = entry.key;
                      final item = entry.value;
                      final isAsmr = idx == 0;
                      final isSelected = idx == _currentIndex;

                      return NavigationRailDestination(
                        icon: Icon(
                          item.icon,
                          color: isSelected && isAsmr ? asmrBlue : null,
                        ),
                        selectedIcon: Icon(
                          item.selectedIcon,
                          color: isAsmr ? asmrBlue : null,
                        ),
                        label: Text(
                          i18n.tr(item.labelKey),
                          style: isSelected && isAsmr
                              ? TextStyle(
                                  color: asmrBlue,
                                  fontWeight: FontWeight.w800,
                                )
                              : null,
                        ),
                      );
                    })
                    .toList(),
              ),
            ),
          ),
          if (overlaySessions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: ActiveSessionCarousel(
                sessions: overlaySessions,
                provider: ref.read(audioProviderFacadeProvider),
                i18n: i18n,
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

  void _measureBottomDock() {
    final safeAreaBox =
        _bottomDockKey.currentContext?.findRenderObject() as RenderBox?;
    if (safeAreaBox != null && safeAreaBox.hasSize && mounted) {
      final h = safeAreaBox.size.height;
      if (h > 0 && (_measuredBottomInset - h).abs() > 0.5) {
        _setLocalState(() => _measuredBottomInset = h);
      }
    }
    final contentBox =
        _dockContentKey.currentContext?.findRenderObject() as RenderBox?;
    if (contentBox != null && contentBox.hasSize && mounted) {
      final h = contentBox.size.height;
      if (h > 0 && (_measuredDockContent - h).abs() > 0.5) {
        _setLocalState(() => _measuredDockContent = h);
      }
    }
  }

  double _mobileContentInset({required bool hasNowPlaying}) {
    // If we just toggled the card, the render box size is still stale.
    // Use predicted values for one frame until post-frame measurement completes.
    if (_needsMeasurement) {
      final systemBottom = MediaQuery.of(context).padding.bottom;
      if (hasNowPlaying) return systemBottom + 158;
      return systemBottom + 64;
    }

    // Read the content column render box live so it stays accurate when the
    // playback card appears or disappears without a metrics change.
    final contentBox =
        _dockContentKey.currentContext?.findRenderObject() as RenderBox?;
    if (contentBox != null && contentBox.hasSize) {
      final systemBottom = MediaQuery.of(context).padding.bottom;
      return (max(systemBottom, 6.0) + contentBox.size.height).clamp(
        0.0,
        double.infinity,
      );
    }
    final systemBottom = MediaQuery.of(context).padding.bottom;
    if (hasNowPlaying) return systemBottom + 158;
    return systemBottom + 64;
  }
}

class _TelegramLikeScrollPhysics extends PageScrollPhysics {
  const _TelegramLikeScrollPhysics({super.parent});

  @override
  _TelegramLikeScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return _TelegramLikeScrollPhysics(parent: buildParent(ancestor));
  }

  @override
  double? get dragStartDistanceMotionThreshold => 36.0;

  @override
  double get minFlingVelocity => 800.0;

  @override
  Tolerance toleranceFor(ScrollMetrics metrics) {
    final Tolerance base = super.toleranceFor(metrics);
    return Tolerance(
      distance: base.distance,
      time: base.time,
      velocity: base.velocity * 16.0,
    );
  }
}
