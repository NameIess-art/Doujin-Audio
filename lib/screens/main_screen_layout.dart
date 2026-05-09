part of 'main_screen.dart';

extension _MainScreenLayout on _MainScreenState {
  Widget _buildAnimatedBody({required bool isDesktop}) {
    final cs = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(isDesktop ? 28 : 24);

    Widget pageShell(int index) {
      return Align(
        alignment: Alignment.topCenter,
        child: isDesktop
            ? ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 980),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 22, 24, 22),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerLow,
                      borderRadius: radius,
                      border: Border.all(
                        color: cs.outlineVariant.withValues(alpha: 0.85),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: cs.shadow.withValues(alpha: 0.1),
                          blurRadius: 28,
                          offset: const Offset(0, 12),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: radius,
                      child: RepaintBoundary(child: _pageBuilders[index]()),
                    ),
                  ),
                ),
              )
            : RepaintBoundary(child: _pageBuilders[index]()),
      );
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        // Only respond to horizontal PageView movement. Vertical library/search
        // scrolling must never leave the app in a "transitioning" visual state.
        if (notification.metrics.axis != Axis.horizontal) return false;
        if (notification.depth != 0) return false;
        if (notification is ScrollStartNotification) {
          ref.read(audioProviderFacadeProvider).setPageTransitioning(true);
        } else if (notification is ScrollEndNotification) {
          ref.read(audioProviderFacadeProvider).setPageTransitioning(false);
        }
        return false;
      },
      child: PageView.builder(
        controller: _pageController,
        itemCount: _pageBuilders.length,
        clipBehavior: Clip.none,
        physics: const SnapScrollPhysics(parent: ClampingScrollPhysics()),
        onPageChanged: (index) {
          if (_pendingTargetIndex != null && index != _pendingTargetIndex) {
            return;
          }
          _pendingTargetIndex = null;
          if (_currentIndex == index) return;
          _setLocalState(() {
            _currentIndex = index;
          });
        },
        itemBuilder: (context, index) {
          return pageShell(index);
        },
      ),
    );
  }

  Future<void> _openTimerSettingsPage(
    BuildContext context,
    _TimerPresentation timerState,
  ) {
    final i18n = context.read<AppLanguageProvider>();
    final mediaSize = MediaQuery.sizeOf(context);
    final isDesktop = mediaSize.width >= _MainScreenState._desktopBreakpoint;

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

  String _fmtDuration(Duration duration) {
    final h = duration.inHours;
    final m = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:$m:$s';
    }
    return '$m:$s';
  }

  String _timerFabLabel(
    _TimerPresentation timerState,
    AppLanguageProvider i18n,
  ) {
    final configured = timerState.duration != null;
    if (!configured) return i18n.tr('timer');

    final remaining = timerState.remaining ?? timerState.duration!;
    if (timerState.active) {
      return _fmtDuration(remaining);
    }
    if (remaining <= Duration.zero) {
      return i18n.tr('done');
    }
    if (timerState.mode == TimerMode.trigger) {
      return i18n.tr('timer_play_plus', {'time': _fmtDuration(remaining)});
    }
    return _fmtDuration(remaining);
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
                            ? cs.primary.withValues(alpha: 0.14)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    Icon(
                      selected ? item.selectedIcon : item.icon,
                      size: 20,
                      color: selected ? cs.primary : inactive,
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
                    color: selected ? cs.primary : inactive,
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
    required _TimerPresentation timerState,
    required List<PlaybackSession> overlaySessions,
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
              FractionallySizedBox(
                widthFactor: 0.9,
                child: _FloatingGlassPanel(
                  padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
                  borderOpacity: 0.12,
                  shadowOpacity: 0.18,
                  showTopHighlight: false,
                  primaryFillOpacity: 0.82,
                  secondaryFillOpacity: 0.70,
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
    _TimerPresentation timerState,
    AppLanguageProvider i18n,
  ) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      width: 292,
      margin: const EdgeInsets.fromLTRB(16, 18, 8, 18),
      padding: const EdgeInsets.fromLTRB(10, 16, 10, 10),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.85)),
        boxShadow: [
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
            child: NavigationRail(
              backgroundColor: Colors.transparent,
              selectedIndex: _currentIndex,
              onDestinationSelected: _switchPage,
              extended: true,
              minExtendedWidth: 256,
              useIndicator: true,
              groupAlignment: -0.86,
              destinations: _MainScreenState._destinations
                  .map(
                    (item) => NavigationRailDestination(
                      icon: Icon(item.icon),
                      selectedIcon: Icon(item.selectedIcon),
                      label: Text(i18n.tr(item.labelKey)),
                    ),
                  )
                  .toList(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 2),
            child: _DesktopQuickAction(
              icon: Icons.timer_rounded,
              title: _timerFabLabel(timerState, i18n),
              subtitle: i18n.tr('timer'),
              onTap: () => _openTimerSettingsPage(context, timerState),
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
    if (_measuredDockContent > 0) {
      final systemBottom = MediaQuery.of(context).padding.bottom;
      // Use the actual measured height of the dock content + its bottom margin
      // to ensure the scrollable content is flush with its top edge.
      return (max(systemBottom, 6.0) + _measuredDockContent).clamp(
        0.0,
        double.infinity,
      );
    }
    final systemBottom = MediaQuery.of(context).padding.bottom;
    if (hasNowPlaying) return systemBottom + 158;
    return systemBottom + 64;
  }
}
