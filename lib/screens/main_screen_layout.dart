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
    final isWindows =
        Platform.isWindows ||
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    Widget pageShell(int actualIndex) {
      final bool isActive = actualIndex == _currentIndex;
      final Widget page = TickerMode(
        enabled: isActive,
        child: ExcludeFocus(
          excluding: !isActive,
          child: ExcludeSemantics(
            excluding: !isActive,
            child: _pages[actualIndex],
          ),
        ),
      );

      return AnimatedOpacity(
        key: ValueKey<String>('main_page_fade_$actualIndex'),
        opacity: isActive ? 1 : 0,
        duration: reduceMotion
            ? Duration.zero
            : AppDesignTokens.of(context).motionFast,
        curve: Curves.easeOutCubic,
        child: Align(
          alignment: Alignment.topCenter,
          child: isDesktop
              ? Padding(
                  padding: isWindows ? EdgeInsets.zero : padding,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: isWindows ? cs.surface : cs.surfaceContainerLow,
                      borderRadius: isWindows
                          ? const BorderRadius.only(
                              topLeft: Radius.circular(AppRadius.medium),
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
                              color: cs.outlineVariant.withValues(alpha: 0.85),
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
                              topLeft: Radius.circular(AppRadius.medium),
                            )
                          : radius,
                      clipBehavior: Clip.hardEdge,
                      child: ColoredBox(
                        color: cs.surface,
                        child: RepaintBoundary(child: page),
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
      children: <int>{..._visitedPageIndices, if (_isDataReady) _currentIndex}
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

      final tokens = AppDesignTokens.of(context);
      final asmrBlue = tokens.asmrAccent;
      final isAsmr = item.labelKey == 'ASMR.ONE';
      final activeColor = (selected && isAsmr) ? asmrBlue : cs.primary;

      return Expanded(
        child: Semantics(
          button: true,
          selected: selected,
          label: label,
          child: Material(
            type: MaterialType.transparency,
            child: InkResponse(
              onTap: () => _switchPage(index),
              containedInkWell: true,
              highlightShape: BoxShape.rectangle,
              radius: 32,
              highlightColor: activeColor.withValues(alpha: 0.08),
              splashColor: activeColor.withValues(alpha: 0.10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Stack(
                    alignment: Alignment.center,
                    children: [
                      AnimatedContainer(
                        duration: tokens.motionSlow,
                        curve: Curves.easeOutQuint,
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
    required BottomNavigationStyle style,
    bool tinyMode = false,
  }) {
    final isBar = style == BottomNavigationStyle.bar;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) {
        return FadeTransition(opacity: animation, child: child);
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
    required List<PlaybackSession> overlaySessions,
    bool tinyMode = false,
    bool isCurrent = true,
  }) {
    return SafeArea(
      key: key,
      top: false,
      minimum: const EdgeInsets.fromLTRB(AppSpacing.sm, 0, AppSpacing.sm, 6),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 430),
          child: Column(
            key: isCurrent ? _dockContentKey : null,
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

  Widget _buildMobileBottomNavigationBar(
    BuildContext context, {
    Key? key,
    required AppLanguageProvider i18n,
    required List<PlaybackSession> overlaySessions,
    bool tinyMode = false,
    bool isCurrent = true,
  }) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final blurEnabled = ref.watch(
      settingsStateProvider.select(
        (s) => s.valueOrNull?.uiBlurEffectEnabled ?? true,
      ),
    );
    final bgColor = isDark ? cs.surfaceBright : cs.surfaceContainerHigh;

    Widget buildBar(bool useBlur) => DecoratedBox(
      decoration: BoxDecoration(
        color: bgColor.withValues(
          alpha: useBlur ? (isDark ? 0.80 : 0.86) : 1.0,
        ),
        border: Border(
          top: BorderSide(
            color: cs.outlineVariant.withValues(alpha: 0.55),
            width: 0.5,
          ),
        ),
      ),
      child: SizedBox(
        height: 58,
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
                provider: ref.read(audioProviderFacadeProvider),
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
    List<PlaybackSession> overlaySessions,
  ) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isWindows =
        Platform.isWindows ||
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final double expandedWidth = isWindows ? 260 : 292;
    final double collapsedWidth = isWindows ? 80 : 92;
    final double containerWidth = _isMenuCollapsed
        ? collapsedWidth
        : expandedWidth;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      width: containerWidth,
      margin: isWindows
          ? EdgeInsets.zero
          : const EdgeInsets.fromLTRB(AppSpacing.md, 18, AppSpacing.xs, 18),
      padding: isWindows
          ? const EdgeInsets.fromLTRB(8, 4, 8, 8)
          : const EdgeInsets.fromLTRB(10, AppSpacing.md, 10, 10),
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
                final rail = Theme(
                  data: Theme.of(context).copyWith(
                    navigationRailTheme: Theme.of(context).navigationRailTheme
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
                    selectedIndex: _currentIndex,
                    onDestinationSelected: _switchPage,
                    extended: !_isMenuCollapsed,
                    minWidth: 64,
                    minExtendedWidth: isWindows ? 212 : 236,
                    useIndicator: true,
                    groupAlignment: -1.0,
                    leading: isWindows
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
                                            borderRadius: BorderRadius.circular(
                                              AppRadius.medium,
                                            ),
                                          ),
                                          child: Icon(
                                            Icons.graphic_eq_rounded,
                                            color: cs.onPrimaryContainer,
                                          ),
                                        ),
                                        const SizedBox(width: AppSpacing.sm),
                                        Expanded(
                                          child: Text(
                                            i18n.tr('asmr_player'),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: Theme.of(context)
                                                .textTheme
                                                .titleMedium
                                                ?.copyWith(
                                                  fontWeight: FontWeight.w800,
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
                    destinations: _MainScreenState._destinations
                        .asMap()
                        .entries
                        .map((entry) {
                          final item = entry.value;
                          final isSelected = _currentIndex == entry.key;
                          final isAsmr =
                              isSelected && item.labelKey == 'ASMR.ONE';
                          final asmrBlue = AppDesignTokens.of(
                            context,
                          ).asmrAccent;
                          return NavigationRailDestination(
                            icon: Icon(item.icon),
                            selectedIcon: Icon(
                              item.selectedIcon,
                              color: isAsmr ? asmrBlue : null,
                            ),
                            label: Text(
                              _isMenuCollapsed ? '' : i18n.tr(item.labelKey),
                              style: isSelected
                                  ? TextStyle(
                                      color: isAsmr ? asmrBlue : cs.primary,
                                      fontWeight: FontWeight.w700,
                                    )
                                  : null,
                            ),
                          );
                        })
                        .toList(),
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
                provider: ref.read(audioProviderFacadeProvider),
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

  double _mobileContentInset({required bool hasNowPlaying}) {
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
