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
                      child: RepaintBoundary(child: _pages[index]),
                    ),
                  ),
                ),
              )
            : RepaintBoundary(child: _pages[index]),
      );
    }

    return PageView.builder(
      controller: _pageController,
      itemCount: _pages.length,
      pageSnapping: false,
      physics: const SnapScrollPhysics(parent: BouncingScrollPhysics()),
      onPageChanged: (index) {
        if (_currentIndex == index) return;
        _setLocalState(() {
          _currentIndex = index;
        });
      },
      itemBuilder: (context, index) {
        return AnimatedBuilder(
          animation: _pageController,
          builder: (context, child) {
            double pageOffset = 0;
            if (_pageController.hasClients &&
                _pageController.position.haveDimensions) {
              pageOffset =
                  ((_pageController.page ?? _currentIndex.toDouble()) - index)
                      .toDouble();
            } else {
              pageOffset = (_currentIndex - index).toDouble();
            }
            final clampedOffset = pageOffset.clamp(-1.0, 1.0).toDouble();
            final pageProgress = clampedOffset.abs();
            final curveValue = Curves.easeOutCubic.transform(1 - pageProgress);
            final opacity = 0.84 + (0.16 * curveValue);
            final scale = 0.984 + (0.016 * curveValue);

            return Opacity(
              opacity: opacity.clamp(0.0, 1.0),
              child: Transform.scale(scale: scale, child: child),
            );
          },
          child: pageShell(index),
        );
      },
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
    final items = _MainScreenState._destinations.asMap().entries.map((entry) {
      final index = entry.key;
      final item = entry.value;
      final selected = index == _currentIndex;
      final label = i18n.tr(item.labelKey);
      final inactive = Theme.of(
        context,
      ).colorScheme.onSurfaceVariant.withValues(alpha: 0.6);

      return Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Semantics(
            button: true,
            selected: selected,
            label: label,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: () => _switchPage(index),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: selected
                        ? Theme.of(
                            context,
                          ).colorScheme.primary.withValues(alpha: 0.12)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: selected
                          ? Theme.of(
                              context,
                            ).colorScheme.primary.withValues(alpha: 0.24)
                          : Colors.transparent,
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 200),
                        transitionBuilder: (child, animation) => FadeTransition(
                          opacity: animation,
                          child: ScaleTransition(
                            scale: animation,
                            child: child,
                          ),
                        ),
                        child: Icon(
                          selected ? item.selectedIcon : item.icon,
                          key: ValueKey<bool>(selected),
                          size: 21,
                          color: selected
                              ? Theme.of(context).colorScheme.primary
                              : inactive,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          fontSize: 9.4,
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.w600,
                          letterSpacing: 0.1,
                          color: selected
                              ? Theme.of(context).colorScheme.primary
                              : inactive,
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

    return Padding(
      padding: const EdgeInsets.fromLTRB(3, 0, 3, 0),
      child: Row(children: items),
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
      minimum: const EdgeInsets.fromLTRB(12, 0, 12, 8),
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
                  provider: context.read<AudioProvider>(),
                  i18n: i18n,
                  onOpenSession: (sessionId) {
                    Navigator.of(
                      context,
                    ).push(buildSessionDetailRoute(sessionId: sessionId));
                  },
                ),
              if (overlaySessions.isNotEmpty) const SizedBox(height: 6),
              _FloatingGlassPanel(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
                borderOpacity: 0.8,
                shadowOpacity: 0.11,
                showTopHighlight: false,
                primaryFillOpacity: 1,
                secondaryFillOpacity: 0.82,
                child: _buildBottomBar(context),
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
      return (systemBottom +
              _measuredDockContent +
              8 -
              _MainScreenState._mobileDockContentGap)
          .clamp(0.0, double.infinity);
    }
    final systemBottom = MediaQuery.of(context).padding.bottom;
    if (hasNowPlaying) return systemBottom + 158;
    return systemBottom + 64;
  }
}
