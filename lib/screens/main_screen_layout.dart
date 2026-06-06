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
    final isWindows =
        Platform.isWindows ||
        MediaQuery.orientationOf(context) == Orientation.landscape;

    Widget pageShell(int actualIndex) {
      final bool isActive = actualIndex == _currentIndex;
      final bool isReady = _visitedPageIndices.contains(actualIndex);
      final Widget page = TickerMode(
        enabled: isActive,
        child: ExcludeFocus(
          excluding: !isActive,
          child: ExcludeSemantics(
            excluding: !isActive,
            child: isReady
                ? _pages[actualIndex]
                : const _MainPageLoadingPlaceholder(),
          ),
        ),
      );

      return AnimatedOpacity(
        key: ValueKey<String>('main_page_fade_$actualIndex'),
        opacity: isActive ? 1 : 0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOutCubic,
        child: Align(
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
                            ? const BorderRadius.only(
                                topLeft: Radius.circular(12),
                              )
                            : radius,
                        border: isWindows
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
                                color: cs.outlineVariant.withValues(
                                  alpha: 0.85,
                                ),
                              ),
                        boxShadow: isWindows
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
                      ),
                      child: ClipRRect(
                        borderRadius: isWindows
                            ? const BorderRadius.only(
                                topLeft: Radius.circular(12),
                              )
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
        ),
      );
    }

    return Stack(
      key: ValueKey<int>(_metricsEpoch),
      clipBehavior: Clip.none,
      children: <int>{..._visitedPageIndices, _currentIndex}
          .map((i) {
            final bool isActive = i == _currentIndex;
            return IgnorePointer(
              key: ValueKey<int>(i),
              ignoring: !isActive,
              child: pageShell(i),
            );
          })
          .toList(growable: false),
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
      transitionDuration: kSecondaryOverlayConfig.transitionDuration,
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
                      height: 26,
                      decoration: BoxDecoration(
                        color: selected
                            ? activeColor.withValues(alpha: 0.11)
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
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                    color: selected ? activeColor : inactive,
                    letterSpacing: 0,
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
                  widthFactor: 0.88,
                  child: _FloatingGlassPanel(
                    padding: const EdgeInsets.fromLTRB(10, 5, 10, 5),
                    shadowOpacity: 0.12,
                    showTopHighlight: false,
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
    final isWindows =
        Platform.isWindows ||
        MediaQuery.orientationOf(context) == Orientation.landscape;

    return Container(
      width: isWindows ? 260 : 292,
      margin: isWindows
          ? EdgeInsets.zero
          : const EdgeInsets.fromLTRB(16, 18, 8, 18),
      padding: isWindows
          ? const EdgeInsets.fromLTRB(16, 16, 16, 16)
          : const EdgeInsets.fromLTRB(10, 16, 10, 10),
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
                      indicatorShape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      indicatorColor: isDark
                          ? cs.primary.withValues(alpha: 0.15)
                          : cs.primaryContainer.withValues(alpha: 0.6),
                    ),
              ),
              child: NavigationRail(
                backgroundColor: Colors.transparent,
                selectedIndex: _currentIndex,
                onDestinationSelected: _switchPage,
                extended: true,
                minExtendedWidth: isWindows ? 228 : 256,
                useIndicator: true,
                groupAlignment: isWindows
                    ? -1.0
                    : 0.0, // Top aligned for desktop apps
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
                          style: isSelected
                              ? TextStyle(
                                  color: isAsmr ? asmrBlue : cs.primary,
                                  fontWeight: FontWeight.w800,
                                )
                              : TextStyle(
                                  color: cs.onSurfaceVariant.withValues(
                                    alpha: 0.8,
                                  ),
                                  fontWeight: FontWeight.w600,
                                ),
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
  }

  double _mobileContentInset({required bool hasNowPlaying}) {
    // If we just toggled the card, the render box size is still stale.
    // Use predicted values for one frame until post-frame measurement completes.
    if (_needsMeasurement) {
      final systemBottom = MediaQuery.of(context).padding.bottom;
      if (hasNowPlaying) return systemBottom + 150;
      return systemBottom + 60;
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
    if (hasNowPlaying) return systemBottom + 150;
    return systemBottom + 60;
  }
}

class _MainPageLoadingPlaceholder extends StatelessWidget {
  const _MainPageLoadingPlaceholder();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ColoredBox(
      color: cs.surface,
      child: ListView(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 96, 16, 24),
        children: [
          for (var i = 0; i < 5; i++)
            Container(
              height: 92,
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(12),
              ),
            ),
        ],
      ),
    );
  }
}
