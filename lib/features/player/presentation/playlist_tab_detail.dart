part of 'playlist_tab.dart';

const double _kSessionDetailBackgroundBlurSigma = 32;

ThemeData _sessionDetailThemeForTrack(BuildContext context, MusicTrack? track) {
  final base = Theme.of(context);
  if (track?.remoteMetadataKind != 'asmr.one') {
    return base;
  }
  final tokens = AppDesignTokens.of(context);
  final scheme = base.colorScheme.copyWith(
    primary: tokens.asmrAccent,
    onPrimary: tokens.onAsmrAccent,
    primaryContainer: tokens.asmrContainer,
    onPrimaryContainer: tokens.onAsmrContainer,
    secondary: tokens.asmrAccent,
    onSecondary: tokens.onAsmrAccent,
    secondaryContainer: tokens.asmrContainer,
    onSecondaryContainer: tokens.onAsmrContainer,
  );
  return base.copyWith(
    colorScheme: scheme,
    sliderTheme: base.sliderTheme.copyWith(
      activeTrackColor: tokens.asmrAccent,
      thumbColor: tokens.asmrAccent,
      overlayColor: tokens.asmrAccent.withValues(alpha: 0.15),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: tokens.asmrAccent),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: tokens.asmrAccent,
        foregroundColor: tokens.onAsmrAccent,
      ),
    ),
  );
}

final ButtonStyle _sessionDetailResetButtonStyle =
    FilledButton.styleFrom(
      backgroundColor: const Color(0xFFF08599),
      foregroundColor: const Color(0xFF301017),
      disabledBackgroundColor: Colors.white.withValues(alpha: 0.12),
      disabledForegroundColor: Colors.white.withValues(alpha: 0.50),
      minimumSize: const Size(96, 40),
      padding: const EdgeInsets.symmetric(horizontal: 20),
      tapTargetSize: MaterialTapTargetSize.padded,
      visualDensity: VisualDensity.standard,
      shape: const StadiumBorder(),
      elevation: 0,
      textStyle: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        height: 1,
      ),
    ).copyWith(
      overlayColor: WidgetStatePropertyAll(
        Colors.white.withValues(alpha: 0.14),
      ),
    );

class SessionDetailPage extends ConsumerStatefulWidget {
  const SessionDetailPage({
    super.key,
    required this.sessionId,
    required this.revealBehindNotifier,
  });

  final String sessionId;
  final ValueNotifier<bool> revealBehindNotifier;

  @override
  ConsumerState<SessionDetailPage> createState() => _SessionDetailPageState();
}

class _SessionDetailPageState extends ConsumerState<SessionDetailPage>
    with TickerProviderStateMixin {
  late final AnimationController _dismissController;
  late final AnimationController _contentEnterController;
  late String _currentSessionId;
  double _horizontalDragDelta = 0;
  bool _contentEnterStarted = false;
  final Object _dismissInteractionSource = Object();
  bool _dismissInteractionActive = false;
  final ValueNotifier<bool> _dismissInteractionNotifier = ValueNotifier(false);
  final ValueNotifier<bool> _segmentPanelExpandedNotifier = ValueNotifier(
    false,
  );

  @override
  void initState() {
    super.initState();
    _currentSessionId = widget.sessionId;
    _dismissController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
      value: 0,
    );
    _contentEnterController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
  }

  @override
  void dispose() {
    UiInteractionCoordinator.instance.cancelInteraction(
      _dismissInteractionSource,
    );
    widget.revealBehindNotifier.value = false;
    _dismissInteractionNotifier.dispose();
    _segmentPanelExpandedNotifier.dispose();
    _dismissController.dispose();
    _contentEnterController.dispose();
    super.dispose();
  }

  void _changeSessionByOffset(List<String> sessionIds, int offset) {
    if (sessionIds.isEmpty) return;
    final currentIndex = sessionIds.indexOf(_currentSessionId);
    if (currentIndex < 0) return;
    int nextIndex = currentIndex + offset;
    if (nextIndex < 0) nextIndex = sessionIds.length - 1;
    if (nextIndex >= sessionIds.length) nextIndex = 0;
    if (nextIndex == currentIndex) return;

    setState(() {
      _horizontalDragDelta = 0;
      _currentSessionId = sessionIds[nextIndex];
    });
  }

  void _handleHorizontalDragEnd(
    DragEndDetails details,
    List<String> sessionIds,
  ) {
    final velocity = details.primaryVelocity ?? 0;
    final shouldGoPrevious = _horizontalDragDelta > 48 || velocity > 400;
    final shouldGoNext = _horizontalDragDelta < -48 || velocity < -400;
    _horizontalDragDelta = 0;
    if (shouldGoPrevious) {
      _changeSessionByOffset(sessionIds, -1);
      return;
    }
    if (shouldGoNext) {
      _changeSessionByOffset(sessionIds, 1);
    }
  }

  void _ensureContentEnterStarted() {
    if (_contentEnterStarted) return;
    _contentEnterStarted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (MediaQuery.disableAnimationsOf(context)) {
        _contentEnterController.value = 1;
        return;
      }
      unawaited(_contentEnterController.forward());
    });
  }

  void _setRevealBehind(bool value) {
    if (widget.revealBehindNotifier.value == value) return;
    widget.revealBehindNotifier.value = value;
  }

  void _beginDismissInteraction() {
    if (_dismissInteractionActive) return;
    _dismissInteractionActive = true;
    UiInteractionCoordinator.instance.beginInteraction(
      _dismissInteractionSource,
    );
    _dismissInteractionNotifier.value = true;
    _setRevealBehind(true);
  }

  void _endDismissInteraction() {
    if (!_dismissInteractionActive) return;
    _dismissInteractionActive = false;
    if (_dismissController.value <= 0.001) {
      _setRevealBehind(false);
    }
    _dismissInteractionNotifier.value = false;
    UiInteractionCoordinator.instance.endInteraction(_dismissInteractionSource);
  }

  Future<void> _handleVerticalDragEnd(
    DragEndDetails details,
    BuildContext context,
  ) async {
    final navigator = Navigator.of(context);
    final velocity = details.primaryVelocity ?? 0;
    final shouldDismiss = _dismissController.value >= (1 / 3) || velocity > 500;
    if (shouldDismiss) {
      ref
          .read(playlistUiControllerProvider)
          .requestCarouselSnap(_currentSessionId);
      _beginDismissInteraction();
      await _animateDismissToEnd(velocity: velocity);
      _endDismissInteraction();
      if (mounted) {
        await navigator.maybePop();
      }
      return;
    }
    if (_dismissController.value <= 0.001) {
      _endDismissInteraction();
      return;
    }
    _beginDismissInteraction();
    await _animateDismissBack();
    _endDismissInteraction();
  }

  Future<void> _animateDismissToEnd({double velocity = 0}) {
    final remaining = (1 - _dismissController.value).clamp(0.0, 1.0);
    final velocityFactor = (velocity.abs() / 2200).clamp(0.0, 1.0);
    final durationMs = lerpDouble(300, 200, velocityFactor)! * remaining;
    return _dismissController.animateTo(
      1,
      duration: Duration(milliseconds: durationMs.round().clamp(180, 320)),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _animateDismissBack() {
    final progress = _dismissController.value.clamp(0.0, 1.0);
    final durationMs = lerpDouble(120, 220, progress)!;
    return _dismissController.animateBack(
      0,
      duration: Duration(milliseconds: durationMs.round().clamp(120, 240)),
      curve: Curves.easeOutQuart,
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.read<AudioProvider>();
    final detailState = ref.watch(sessionDetailUiProvider(_currentSessionId));
    final sessionIds = detailState.sessionOrder.sessionIds;

    if (sessionIds.isEmpty) {
      return const Scaffold(body: SizedBox.shrink());
    }

    if (detailState.detail == null && sessionIds.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _currentSessionId = sessionIds.first;
        });
      });
      return const Scaffold(body: SizedBox.shrink());
    }

    _ensureContentEnterStarted();
    final routeAnimation = ModalRoute.of(context)?.animation;
    final animatedListenable = Listenable.merge([
      ?routeAnimation,
      _contentEnterController,
      _dismissController,
    ]);
    final isWindows = defaultTargetPlatform == TargetPlatform.windows;
    final enableVerticalDismiss = !isWindows;

    return Material(
      color: Colors.transparent,
      child: AnimatedBuilder(
        animation: animatedListenable,
        builder: (context, child) {
          final rawEnterProgress = min(
            (routeAnimation?.value ?? 1).clamp(0.0, 1.0),
            _contentEnterController.value.clamp(0.0, 1.0),
          );
          final enterProgress = Curves.easeOutCubic.transform(rawEnterProgress);
          final dismissProgress = Curves.easeOutCubic.transform(
            _dismissController.value.clamp(0.0, 1.0),
          );
          final dragDistance =
              MediaQuery.sizeOf(context).height * dismissProgress;
          final enterOffset =
              (1 - enterProgress) * MediaQuery.sizeOf(context).height;
          final revealProgress = (dismissProgress * 3).clamp(0.0, 1.0);
          final backdropProgress = (enterProgress * pow(1 - revealProgress, 2))
              .clamp(0.0, 1.0);
          return Stack(
            fit: StackFit.expand,
            children: [
              const Positioned.fill(
                child: ModalBarrier(
                  dismissible: false,
                  color: Colors.transparent,
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: _SessionDetailBackdrop(progress: backdropProgress),
                ),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: FractionallySizedBox(
                  heightFactor: 1.0,
                  child: Transform.translate(
                    offset: Offset(0, enterOffset + dragDistance),
                    child: child!,
                  ),
                ),
              ),
            ],
          );
        },
        child: ValueListenableBuilder<bool>(
          valueListenable: _dismissInteractionNotifier,
          builder: (context, isDismissing, child) {
            return TickerMode(
              enabled: !isDismissing,
              child: MarqueePauseScope(isPaused: isDismissing, child: child!),
            );
          },
          child: RepaintBoundary(
            child: Listener(
              onPointerSignal: isWindows
                  ? (event) {
                      if (_segmentPanelExpandedNotifier.value) return;
                      if (event is PointerScrollEvent) {
                        if (event.scrollDelta.dy > 0) {
                          _changeSessionByOffset(sessionIds, 1);
                        } else if (event.scrollDelta.dy < 0) {
                          _changeSessionByOffset(sessionIds, -1);
                        }
                      }
                    }
                  : null,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: Builder(
                  key: ValueKey(_currentSessionId),
                  builder: (context) {
                    final pageSession = provider.sessionById(_currentSessionId);
                    if (pageSession == null) {
                      return const SizedBox.shrink();
                    }
                    final detailTrack = provider.trackByPath(
                      pageSession.currentTrackPath,
                    );
                    final coverPathFuture = _coverFutureForTrack(
                      provider,
                      detailTrack,
                    );

                    return _SessionDetailScaffold(
                      session: pageSession,
                      provider: provider,
                      coverPathFuture: coverPathFuture,
                      dismissAnimation: _dismissController,
                      segmentPanelExpandedNotifier:
                          _segmentPanelExpandedNotifier,
                      onClose: () async {
                        ref
                            .read(playlistUiControllerProvider)
                            .requestCarouselSnap(_currentSessionId);
                        _beginDismissInteraction();
                        await _animateDismissToEnd();
                        _endDismissInteraction();
                        if (context.mounted) {
                          await Navigator.of(context).maybePop();
                        }
                      },
                      onHorizontalDragUpdate: isWindows
                          ? null
                          : (details) {
                              if (_segmentPanelExpandedNotifier.value) return;
                              _horizontalDragDelta += details.primaryDelta ?? 0;
                            },
                      onHorizontalDragEnd: isWindows
                          ? null
                          : (details) {
                              if (_segmentPanelExpandedNotifier.value) return;
                              _handleHorizontalDragEnd(details, sessionIds);
                            },
                      onHorizontalDragCancel: isWindows
                          ? null
                          : () {
                              if (_segmentPanelExpandedNotifier.value) return;
                              _horizontalDragDelta = 0;
                            },
                      onVerticalDragUpdate: enableVerticalDismiss
                          ? (delta) {
                              final screenHeight = MediaQuery.sizeOf(
                                context,
                              ).height;
                              if (screenHeight <= 0) return;
                              final nextValue =
                                  _dismissController.value +
                                  (delta / screenHeight);
                              if (nextValue > 0.001) {
                                _beginDismissInteraction();
                              }
                              _dismissController.value = nextValue.clamp(
                                0.0,
                                1.0,
                              );
                            }
                          : null,
                      onVerticalDragEnd: enableVerticalDismiss
                          ? (details) =>
                                _handleVerticalDragEnd(details, context)
                          : null,
                      onVerticalDragCancel: enableVerticalDismiss
                          ? () {
                              if (_dismissController.value <= 0.001) {
                                _endDismissInteraction();
                                return;
                              }
                              _beginDismissInteraction();
                              unawaited(
                                _animateDismissBack().whenComplete(
                                  _endDismissInteraction,
                                ),
                              );
                            }
                          : null,
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SessionDetailBackdrop extends StatelessWidget {
  const _SessionDetailBackdrop({this.progress = 1.0});

  final double progress;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final gradientAlpha = (lerpDouble(0, 0.8, progress) ?? 0).clamp(0.0, 1.0);

    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: cs.surface.withValues(alpha: progress.clamp(0.0, 1.0)),
          ),
        ),
        if (gradientAlpha > 0)
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  cs.surface.withValues(alpha: 0.2 * gradientAlpha),
                  cs.surface.withValues(alpha: 0.5 * gradientAlpha),
                  cs.surface.withValues(alpha: 0.85 * gradientAlpha),
                ],
                stops: const [0.0, 0.4, 1.0],
              ),
            ),
          ),
      ],
    );
  }
}

class _SessionDetailScaffold extends ConsumerStatefulWidget {
  final PlaybackSession session;
  final AudioProvider provider;
  final Future<String?> coverPathFuture;
  final Animation<double> dismissAnimation;
  final VoidCallback onClose;
  final void Function(DragUpdateDetails)? onHorizontalDragUpdate;
  final void Function(DragEndDetails)? onHorizontalDragEnd;
  final VoidCallback? onHorizontalDragCancel;
  final ValueChanged<double>? onVerticalDragUpdate;
  final void Function(DragEndDetails)? onVerticalDragEnd;
  final VoidCallback? onVerticalDragCancel;
  final ValueNotifier<bool>? segmentPanelExpandedNotifier;

  const _SessionDetailScaffold({
    required this.session,
    required this.provider,
    required this.coverPathFuture,
    required this.onClose,
    this.onHorizontalDragUpdate,
    this.onHorizontalDragEnd,
    this.onHorizontalDragCancel,
    this.onVerticalDragUpdate,
    this.onVerticalDragEnd,
    this.onVerticalDragCancel,
    required this.dismissAnimation,
    this.segmentPanelExpandedNotifier,
  });

  @override
  ConsumerState<_SessionDetailScaffold> createState() =>
      _SessionDetailScaffoldState();
}

class _SessionDetailScaffoldState extends ConsumerState<_SessionDetailScaffold>
    with WidgetsBindingObserver {
  final _detailContentKey = GlobalKey<_SessionDetailContentState>();
  final PermissionActionController _permissionActionController =
      PermissionActionController();
  double _segmentPanelDragDelta = 0;
  bool _isDismissGesture = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _permissionActionController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_permissionActionController.handleAppResumed());
    }
  }

  Future<void> _toggleGlobalSubtitleDisplay(
    SubtitleSettingsNotifier notifier,
    SubtitleSettingsState settings,
    String sessionId,
  ) async {
    final isEnabling = !settings.isGlobalEnabled(sessionId);
    if (!isEnabling) {
      notifier.toggleGlobalSubtitles(sessionId);
      return;
    }

    final i18n = context.read<AppLanguageProvider>();
    await _permissionActionController.ensureGrantedAndRun(
      context: context,
      title: i18n.tr('overlay_permission_title'),
      message: i18n.tr('overlay_permission_message'),
      confirmLabel: i18n.tr('go_settings'),
      cancelLabel: i18n.tr('cancel'),
      isGranted: SubtitleOverlayController.canDrawOverlays,
      openSettings: SubtitleOverlayController.openOverlaySettings,
      onGranted: () async {
        notifier.toggleGlobalSubtitles(sessionId);
      },
    );
  }

  Future<void> _openTimerSettingsPage() {
    final i18n = context.read<AppLanguageProvider>();
    final mediaSize = MediaQuery.sizeOf(context);
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final isDesktop =
        Platform.isWindows || mediaSize.width >= 760 || isLandscape;
    final maxWidth = isDesktop ? 520.0 : double.infinity;
    final outerPadding = EdgeInsets.symmetric(
      horizontal: isDesktop ? 24 : 12,
      vertical: isDesktop ? 24 : 12,
    );

    return showGeneralDialog<void>(
      context: context,
      barrierLabel: i18n.tr('close'),
      barrierDismissible: true,
      barrierColor: Colors.transparent,
      transitionDuration: kSecondaryOverlayConfig.transitionDuration,
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return Material(
          color: Colors.transparent,
          child: AnimatedBuilder(
            animation: curved,
            builder: (context, child) {
              return Stack(
                fit: StackFit.expand,
                children: [
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => Navigator.of(context).maybePop(),
                      child: const SizedBox.expand(),
                    ),
                  ),
                  SafeArea(
                    child: FadeTransition(
                      opacity: curved,
                      child: Padding(
                        padding: outerPadding,
                        child: Align(
                          alignment: isDesktop
                              ? Alignment.center
                              : Alignment.topCenter,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(maxWidth: maxWidth),
                            child: const TimerTab(
                              showHeader: false,
                              useSafeArea: false,
                              compactOnly: true,
                              initialCompactDetail: true,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  void _showAudioDetailForSession(
    BuildContext context,
    AudioProvider provider,
    PlaybackSession session,
    MusicTrack? track,
  ) {
    if (track?.remoteMetadataKind == 'asmr.one' &&
        track?.remoteMetadata != null) {
      unawaited(
        showAsmrWorkDetailSheet(
          context,
          AsmrWork.fromJson(Map<String, dynamic>.from(track!.remoteMetadata!)),
        ),
      );
      return;
    }

    final target = provider.audioDetailTargetForSession(session.id);
    if (target != null) {
      unawaited(showAudioDetailSheet(context, target));
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final provider = widget.provider;
    final coverPathFuture = widget.coverPathFuture;
    final onClose = widget.onClose;
    final onHorizontalDragUpdate = widget.onHorizontalDragUpdate;
    final onHorizontalDragEnd = widget.onHorizontalDragEnd;
    final onHorizontalDragCancel = widget.onHorizontalDragCancel;
    final onVerticalDragUpdate = widget.onVerticalDragUpdate;
    final onVerticalDragEnd = widget.onVerticalDragEnd;
    final onVerticalDragCancel = widget.onVerticalDragCancel;

    final track = provider.trackByPath(session.currentTrackPath);
    final detailTheme = _sessionDetailThemeForTrack(context, track);
    final cs = detailTheme.colorScheme;
    final coverCacheWidth = coverCacheWidthForResolution(
      ref.watch(
        settingsStateProvider.select(
          (s) =>
              s.valueOrNull?.coverImageResolution ??
              CoverImageResolution.balanced,
        ),
      ),
    );
    final blurEnabled = ref.watch(
      settingsStateProvider.select(
        (s) => s.valueOrNull?.blurPlayerBackgroundEnabled ?? true,
      ),
    );

    return Theme(
      data: detailTheme,
      child: Material(
        color: cs.surface,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragUpdate: onHorizontalDragUpdate,
          onHorizontalDragEnd: onHorizontalDragEnd,
          onHorizontalDragCancel: onHorizontalDragCancel,
          onVerticalDragStart: (details) {
            _isDismissGesture = widget.dismissAnimation.value > 0.01;
            _segmentPanelDragDelta = 0;
          },
          onVerticalDragUpdate: (details) {
            final delta = details.primaryDelta ?? 0;
            final detailState = _detailContentKey.currentState;
            final panelExpanded = detailState?.isSegmentPanelExpanded ?? false;
            final detailFullyOpen = widget.dismissAnimation.value <= 0.01;

            if (!_isDismissGesture && delta > 0 && !panelExpanded) {
              _segmentPanelDragDelta += delta;
              if (_segmentPanelDragDelta > 24) {
                _isDismissGesture = true;
                final dismissDelta = _segmentPanelDragDelta;
                _segmentPanelDragDelta = 0;
                onVerticalDragUpdate?.call(dismissDelta);
              }
              return;
            }

            if (_isDismissGesture) {
              onVerticalDragUpdate?.call(delta);
              return;
            }

            if ((panelExpanded && delta > 0) ||
                (!panelExpanded && delta < 0 && detailFullyOpen)) {
              _segmentPanelDragDelta += delta;
              return;
            }

            onVerticalDragUpdate?.call(delta);
          },
          onVerticalDragEnd: (details) {
            final velocity = details.primaryVelocity ?? 0;
            final detailState = _detailContentKey.currentState;
            final panelExpanded = detailState?.isSegmentPanelExpanded ?? false;
            if (_isDismissGesture) {
              _isDismissGesture = false;
              _segmentPanelDragDelta = 0;
              onVerticalDragEnd?.call(details);
              return;
            }
            final shouldExpand =
                !panelExpanded &&
                widget.dismissAnimation.value <= 0.01 &&
                (_segmentPanelDragDelta < -120 || velocity < -800);
            final shouldCollapse =
                panelExpanded &&
                (_segmentPanelDragDelta > 120 || velocity > 800);
            _segmentPanelDragDelta = 0;
            if (shouldExpand) {
              detailState?.expandSegmentPanel();
              return;
            }
            if (shouldCollapse) {
              detailState?.collapseSegmentPanel();
              return;
            }
            onVerticalDragEnd?.call(details);
          },
          onVerticalDragCancel: () {
            _isDismissGesture = false;
            _segmentPanelDragDelta = 0;
            onVerticalDragCancel?.call();
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Dynamic Blurred Background
              if (blurEnabled)
                Positioned.fill(
                  child: ClipRect(
                    child: RepaintBoundary(
                      child: ImageFiltered(
                        key: const ValueKey('session_detail_background_blur'),
                        imageFilter: ImageFilter.blur(
                          sigmaX: _kSessionDetailBackgroundBlurSigma,
                          sigmaY: _kSessionDetailBackgroundBlurSigma,
                          tileMode: TileMode.decal,
                        ),
                        child: AsyncCoverImage(
                          future: coverPathFuture,
                          requestKey: session.id,
                          initialPath: provider
                              .resolvedPlaybackCoverPathForTrack(track),
                          retryFutureBuilder: () =>
                              _coverFutureForTrack(provider, track),
                          fallbackBuilder: (_) => CoverFallbackArtwork(
                            seed:
                                track?.displayName ?? session.currentTrackPath,
                            showIcon: false,
                          ),
                          imageBuilder: (context, coverPath) {
                            return RetryingFileImage(
                              path: coverPath,
                              cacheWidth: coverCacheWidth,
                              useDefaultCacheWidth: coverCacheWidth != null,
                              fit: BoxFit.cover,
                              color: cs.surface.withValues(alpha: 0.45),
                              colorBlendMode: BlendMode.darken,
                              fallbackBuilder: (_) => CoverFallbackArtwork(
                                seed:
                                    track?.displayName ??
                                    session.currentTrackPath,
                                showIcon: false,
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              // Content
              SafeArea(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    return Column(
                      children: [
                        // Top Bar 鈥?outside drag GestureDetector so taps work
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Builder(
                            builder: (context) {
                              final cachedTrack = provider.getSubtitleTrackSync(
                                session.currentTrackPath,
                              );
                              if (cachedTrack == null) {
                                unawaited(
                                  provider.subtitleTrackForPath(
                                    session.currentTrackPath,
                                  ),
                                );
                              }
                              final hasSubtitle = cachedTrack != null;
                              final settings = ref.watch(
                                subtitleSettingsProvider,
                              );

                              return Row(
                                children: [
                                  IconButton(
                                    onPressed: onClose,
                                    icon: Icon(
                                      Icons.keyboard_arrow_down_rounded,
                                      color: cs.onSurface,
                                      size: 32,
                                    ),
                                  ),
                                  Expanded(
                                    child: GestureDetector(
                                      key: const ValueKey(
                                        'session_detail_window_drag_region',
                                      ),
                                      behavior: HitTestBehavior.translucent,
                                      onPanStart: Platform.isWindows
                                          ? (_) => windowManager.startDragging()
                                          : null,
                                      child: const SizedBox(height: 48),
                                    ),
                                  ),
                                  if (hasSubtitle &&
                                      settings.isShowEnabled(session.id) &&
                                      settings.isGlobalEnabled(session.id)) ...[
                                    Icon(
                                      Icons.subtitles_rounded,
                                      color: cs.onSurface,
                                      size: 20,
                                    ),
                                    const SizedBox(width: 8),
                                  ],
                                  Consumer(
                                    builder: (context, ref, child) {
                                      final transport = ref.watch(
                                        sessionDetailTransportProvider(
                                          session.id,
                                        ),
                                      );
                                      final featureIcons =
                                          sessionFeatureBadgeIcons(
                                            showSubtitles: false,
                                            channelSwapEnabled:
                                                transport?.channelSwapEnabled ??
                                                session.channelSwapEnabled,
                                            audioEffects:
                                                transport?.audioEffects ??
                                                session.audioEffects,
                                            speed:
                                                transport?.speed ??
                                                session.speed,
                                          );
                                      if (featureIcons.isEmpty) {
                                        return const SizedBox.shrink();
                                      }
                                      return Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          SessionFeatureIconRow(
                                            featureIcons: featureIcons,
                                            color: cs.onSurface,
                                            iconSize: 20,
                                            spacing: 8,
                                            alignment: WrapAlignment.end,
                                          ),
                                          const SizedBox(width: 8),
                                        ],
                                      );
                                    },
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                        // Content area 鈥?keep session drag gestures on artwork only
                        Expanded(
                          child: Builder(
                            builder: (context) {
                              final isLandscape =
                                  MediaQuery.orientationOf(context) ==
                                  Orientation.landscape;
                              final resolvedCoverPath = provider
                                  .resolvedPlaybackCoverPathForTrack(track);
                              final useArtworkConsole =
                                  track?.isSingle == true &&
                                  track?.isVideo != true &&
                                  !hasDisplayableCoverArtwork(
                                    track,
                                    resolvedCoverPath,
                                  );

                              Widget? artworkWidget = useArtworkConsole
                                  ? null
                                  : _SessionHeroArtwork(
                                      sessionId: session.id,
                                      height: constraints.maxHeight,
                                      track: track,
                                      coverPathFuture: coverPathFuture,
                                    );

                              if (isLandscape && artworkWidget != null) {
                                artworkWidget = Center(
                                  child: AspectRatio(
                                    aspectRatio: 1.0,
                                    child: artworkWidget,
                                  ),
                                );
                              }

                              final artwork = artworkWidget == null
                                  ? null
                                  : Padding(
                                      padding: EdgeInsets.symmetric(
                                        horizontal: isLandscape ? 48.0 : 32.0,
                                        vertical: isLandscape ? 32.0 : 0.0,
                                      ),
                                      child: artworkWidget,
                                    );

                              final detailPadding = EdgeInsets.fromLTRB(
                                isLandscape ? 12 : 28,
                                isLandscape ? 0 : 12,
                                isLandscape ? 64 : 28,
                                isLandscape ? 32 : 8,
                              );
                              final cachedTrack = provider.getSubtitleTrackSync(
                                session.currentTrackPath,
                              );
                              if (cachedTrack == null) {
                                unawaited(
                                  provider.subtitleTrackForPath(
                                    session.currentTrackPath,
                                  ),
                                );
                              }
                              final hasSubtitle = cachedTrack != null;
                              final subtitleSettings = ref.watch(
                                subtitleSettingsProvider,
                              );

                              return _SessionDetailContent(
                                key: _detailContentKey,
                                session: session,
                                provider: provider,
                                segmentPanelExpandedNotifier:
                                    widget.segmentPanelExpandedNotifier,
                                isLandscape: isLandscape,
                                artworkWidget: artwork,
                                useArtworkConsole: useArtworkConsole,
                                detailPadding: detailPadding,
                                hasSubtitle: hasSubtitle,
                                subtitleEnabled: subtitleSettings.isShowEnabled(
                                  session.id,
                                ),
                                subtitleGlobalEnabled: subtitleSettings
                                    .isGlobalEnabled(session.id),
                                onToggleSubtitle: hasSubtitle
                                    ? () {
                                        ref
                                            .read(
                                              subtitleSettingsProvider.notifier,
                                            )
                                            .toggleShowSubtitles(session.id);
                                      }
                                    : null,
                                onToggleGlobalSubtitle: hasSubtitle
                                    ? () {
                                        final notifier = ref.read(
                                          subtitleSettingsProvider.notifier,
                                        );
                                        unawaited(
                                          _toggleGlobalSubtitleDisplay(
                                            notifier,
                                            subtitleSettings,
                                            session.id,
                                          ),
                                        );
                                      }
                                    : null,
                                onOpenTimer: () {
                                  unawaited(_openTimerSettingsPage());
                                },
                                onShowAudioDetail: () =>
                                    _showAudioDetailForSession(
                                      context,
                                      provider,
                                      session,
                                      track,
                                    ),
                              );
                            },
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
