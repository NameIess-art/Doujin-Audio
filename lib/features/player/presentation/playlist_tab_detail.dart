part of 'playlist_tab.dart';

const double _kSessionDetailBackgroundBlurSigma = 32;
const int _kAsmrSessionDetailBackgroundCacheWidth = 300;

ThemeData _createAsmrSessionDetailTheme(
  ThemeData base,
  AppDesignTokens tokens,
) {
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

ButtonStyle _sessionDetailResetButtonStyle(BuildContext context) {
  final colorScheme = Theme.of(context).colorScheme;
  return FilledButton.styleFrom(
    backgroundColor: colorScheme.primary,
    foregroundColor: colorScheme.onPrimary,
    disabledBackgroundColor: colorScheme.onSurface.withValues(alpha: 0.12),
    disabledForegroundColor: colorScheme.onSurface.withValues(alpha: 0.50),
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
      colorScheme.onPrimary.withValues(alpha: 0.14),
    ),
  );
}

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
      await _dismissAndPop(velocity: velocity, navigator: navigator);
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
    if (MediaQuery.disableAnimationsOf(context)) {
      _dismissController.value = 1;
      return Future<void>.value();
    }
    final normalizedVelocity = (velocity / MediaQuery.sizeOf(context).height)
        .clamp(-4.0, 4.0);
    return _dismissController.animateWith(
      SpringSimulation(
        const SpringDescription(mass: 1, stiffness: 420, damping: 34),
        _dismissController.value,
        1,
        normalizedVelocity,
      ),
    );
  }

  Future<void> _animateDismissBack() {
    if (MediaQuery.disableAnimationsOf(context)) {
      _dismissController.value = 0;
      return Future<void>.value();
    }
    return _dismissController.animateWith(
      SpringSimulation(
        const SpringDescription(mass: 1, stiffness: 420, damping: 34),
        _dismissController.value,
        0,
        0,
      ),
    );
  }

  Future<void> _dismissAndPop({
    double velocity = 0,
    required NavigatorState navigator,
  }) async {
    ref
        .read(playlistUiControllerProvider)
        .requestCarouselSnap(_currentSessionId);
    _beginDismissInteraction();
    try {
      await _animateDismissToEnd(velocity: velocity);
    } finally {
      _endDismissInteraction();
    }
    if (mounted) await navigator.maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final playback = ref.read(playbackFacadeProvider);
    final paths = ref.read(audioPathCoordinatorProvider);
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
    final routeAnimation = MediaQuery.disableAnimationsOf(context)
        ? null
        : ModalRoute.of(context)?.animation;
    final animatedListenable = Listenable.merge([
      ?routeAnimation,
      _contentEnterController,
      _dismissController,
    ]);

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
          final dismissProgress = _dismissController.value.clamp(0.0, 1.0);
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
                    child: Transform.scale(
                      scale: 1 - (0.03 * revealProgress),
                      alignment: Alignment.topCenter,
                      child: ClipRRect(
                        borderRadius: BorderRadius.vertical(
                          top: Radius.circular(24 * revealProgress),
                        ),
                        child: child!,
                      ),
                    ),
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
            child: Builder(
              builder: (context) {
                final pageSession = playback.sessionSnapshotById(
                  _currentSessionId,
                );
                if (pageSession == null) {
                  return const SizedBox.shrink();
                }
                final detailTrack = paths.trackByPath(
                  pageSession.currentTrackPath,
                );
                final coverPathFuture = _coverFutureForTrack(
                  ref.read(libraryFacadeProvider),
                  detailTrack,
                );

                return _SessionDetailScaffold(
                  session: pageSession,
                  coverPathFuture: coverPathFuture,
                  dismissAnimation: _dismissController,
                  segmentPanelExpandedNotifier: _segmentPanelExpandedNotifier,
                  onClose: () =>
                      _dismissAndPop(navigator: Navigator.of(context)),
                  onHorizontalDragUpdate: (details) {
                    if (_segmentPanelExpandedNotifier.value) return;
                    _horizontalDragDelta += details.primaryDelta ?? 0;
                  },
                  onHorizontalDragEnd: (details) {
                    if (_segmentPanelExpandedNotifier.value) return;
                    _handleHorizontalDragEnd(details, sessionIds);
                  },
                  onHorizontalDragCancel: () {
                    if (_segmentPanelExpandedNotifier.value) return;
                    _horizontalDragDelta = 0;
                  },
                  onVerticalDragUpdate: (delta) {
                    final screenHeight = MediaQuery.sizeOf(context).height;
                    if (screenHeight <= 0) return;
                    final nextValue =
                        _dismissController.value + (delta / screenHeight);
                    if (nextValue > 0.001) {
                      _beginDismissInteraction();
                    }
                    _dismissController.value = nextValue.clamp(0.0, 1.0);
                  },
                  onVerticalDragEnd: (details) =>
                      _handleVerticalDragEnd(details, context),
                  onVerticalDragCancel: () {
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
                  },
                );
              },
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
  final PlaybackSessionSnapshot session;
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
  ThemeData? _cachedBaseTheme;
  AppDesignTokens? _cachedDesignTokens;
  ThemeData? _cachedAsmrTheme;
  double _segmentPanelDragDelta = 0;
  bool _isDismissGesture = false;

  ThemeData _detailThemeForTrack(BuildContext context, MusicTrack? track) {
    final base = Theme.of(context);
    if (track?.remoteMetadataKind != 'asmr.one') return base;
    final tokens = AppDesignTokens.of(context);
    if (identical(_cachedBaseTheme, base) &&
        identical(_cachedDesignTokens, tokens) &&
        _cachedAsmrTheme != null) {
      return _cachedAsmrTheme!;
    }
    _cachedBaseTheme = base;
    _cachedDesignTokens = tokens;
    return _cachedAsmrTheme = _createAsmrSessionDetailTheme(base, tokens);
  }

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
    if (!shouldRequestSubtitleOverlayPermission(
      isAndroid: Platform.isAndroid,
    )) {
      notifier.toggleGlobalSubtitles(sessionId);
      return;
    }

    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    await _permissionActionController.ensureGrantedAndRun(
      context: context,
      title: i18n.tr('overlay_permission_title'),
      message: i18n.tr('overlay_permission_message'),
      confirmLabel: i18n.tr('go_settings'),
      cancelLabel: i18n.tr('cancel'),
      isGranted: ref.read(subtitleOverlayControllerProvider).canDrawOverlays,
      openSettings: ref
          .read(subtitleOverlayControllerProvider)
          .openOverlaySettings,
      onGranted: () async {
        notifier.toggleGlobalSubtitles(sessionId);
      },
    );
  }

  void _showAudioDetailForSession(
    BuildContext context,
    PlaybackSessionSnapshot session,
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

    final target = ref
        .read(libraryFacadeProvider)
        .audioDetailTargetForPath(session.currentTrackPath);
    unawaited(showAudioDetailSheet(context, target));
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final paths = ref.read(audioPathCoordinatorProvider);
    final library = ref.read(libraryFacadeProvider);
    final coverPathFuture = widget.coverPathFuture;
    final onClose = widget.onClose;
    final onHorizontalDragUpdate = widget.onHorizontalDragUpdate;
    final onHorizontalDragEnd = widget.onHorizontalDragEnd;
    final onHorizontalDragCancel = widget.onHorizontalDragCancel;
    final onVerticalDragUpdate = widget.onVerticalDragUpdate;
    final onVerticalDragEnd = widget.onVerticalDragEnd;
    final onVerticalDragCancel = widget.onVerticalDragCancel;

    final track = paths.trackByPath(session.currentTrackPath);
    final isAsmrTrack = track?.remoteMetadataKind == 'asmr.one';
    final detailTheme = _detailThemeForTrack(context, track);
    final cs = detailTheme.colorScheme;
    final requestedBackgroundCacheWidth = coverCacheWidthForResolution(
      ref.watch(
        settingsStateProvider.select(
          (state) =>
              state.value?.coverImageResolution ??
              CoverImageResolution.balanced,
        ),
      ),
    );
    final backgroundCacheWidth = isAsmrTrack
        ? min(
            requestedBackgroundCacheWidth ??
                _kAsmrSessionDetailBackgroundCacheWidth,
            _kAsmrSessionDetailBackgroundCacheWidth,
          )
        : requestedBackgroundCacheWidth;
    final blurEnabled = ref.watch(
      settingsStateProvider.select(
        (state) => state.value?.blurPlayerBackgroundEnabled ?? true,
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

            if (!_isDismissGesture &&
                delta > 0 &&
                !panelExpanded &&
                detailFullyOpen) {
              _isDismissGesture = true;
              onVerticalDragUpdate?.call(delta);
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
              if (blurEnabled)
                Positioned.fill(
                  child: FadeTransition(
                    opacity: ReverseAnimation(widget.dismissAnimation),
                    child: ClipRect(
                      child: RepaintBoundary(
                        child: AnimatedSwitcher(
                          duration: kAppMotionSlow,
                          reverseDuration: kAppMotionStandard,
                          transitionBuilder: (child, animation) =>
                              buildAppFadeTransition(
                                context: context,
                                animation: animation,
                                child: child,
                              ),
                          child: KeyedSubtree(
                            key: ValueKey('session_detail_blur_${session.id}'),
                            child: ImageFiltered(
                              key: const ValueKey(
                                'session_detail_background_blur',
                              ),
                              imageFilter: ImageFilter.blur(
                                sigmaX: _kSessionDetailBackgroundBlurSigma,
                                sigmaY: _kSessionDetailBackgroundBlurSigma,
                                tileMode: TileMode.decal,
                              ),
                              child: AsyncCoverImage(
                                future: coverPathFuture,
                                requestKey: session.id,
                                duration: Duration.zero,
                                initialPath: library
                                    .resolvedPlaybackCoverPathForTrack(track),
                                retryFutureBuilder: () => _coverFutureForTrack(
                                  ref.read(libraryFacadeProvider),
                                  track,
                                ),
                                fallbackBuilder: (_) => CoverFallbackArtwork(
                                  seed:
                                      track?.displayName ??
                                      session.currentTrackPath,
                                ),
                                imageBuilder: (context, coverPath) {
                                  return RetryingFileImage(
                                    path: coverPath,
                                    cacheWidth: backgroundCacheWidth,
                                    useDefaultCacheWidth:
                                        backgroundCacheWidth != null,
                                    fit: BoxFit.cover,
                                    filterQuality: isAsmrTrack
                                        ? FilterQuality.low
                                        : FilterQuality.medium,
                                    color: cs.surface.withValues(alpha: 0.45),
                                    colorBlendMode: BlendMode.darken,
                                    fallbackBuilder: (_) =>
                                        CoverFallbackArtwork(
                                          seed:
                                              track?.displayName ??
                                              session.currentTrackPath,
                                        ),
                                  );
                                },
                              ),
                            ),
                          ),
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
                        // Top Bar — outside drag GestureDetector so taps work
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Builder(
                            builder: (context) {
                              final i18n = ProviderScope.containerOf(
                                context,
                                listen: false,
                              ).read(appLanguageProviderInstanceProvider);
                              final subtitles = ref.read(
                                playbackSubtitleServiceProvider,
                              );
                              final hasSubtitle = subtitles.hasKnownSubtitle(
                                session.currentTrackPath,
                              );
                              final settings = ref.watch(
                                subtitleSettingsProvider,
                              );

                              return Row(
                                children: [
                                  IconButton(
                                    onPressed: onClose,
                                    tooltip: i18n.tr('close'),
                                    icon: Icon(
                                      Icons.keyboard_arrow_down_rounded,
                                      color: _sessionDetailForeground(
                                        cs,
                                        _SessionDetailForegroundLevel.muted,
                                      ),
                                      size: 32,
                                    ),
                                  ),
                                  const Expanded(child: SizedBox(height: 48)),
                                  if (hasSubtitle &&
                                      settings.isShowEnabled(session.id) &&
                                      settings.isGlobalEnabled(session.id)) ...[
                                    Icon(
                                      Icons.subtitles_rounded,
                                      color: _sessionDetailForeground(
                                        cs,
                                        _SessionDetailForegroundLevel.muted,
                                      ),
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
                                            color: _sessionDetailForeground(
                                              cs,
                                              _SessionDetailForegroundLevel
                                                  .muted,
                                            ),
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
                        // Content area — keep session drag gestures on artwork only
                        Expanded(
                          child: Builder(
                            builder: (context) {
                              final isLandscape =
                                  MediaQuery.orientationOf(context) ==
                                  Orientation.landscape;
                              Widget artworkWidget = AnimatedSwitcher(
                                duration: kAppMotionSlow,
                                reverseDuration: kAppMotionStandard,
                                transitionBuilder: (child, animation) =>
                                    buildAppFadeTransition(
                                      context: context,
                                      animation: animation,
                                      child: child,
                                    ),
                                child: KeyedSubtree(
                                  key: ValueKey('artwork_${session.id}'),
                                  child: _SessionHeroArtwork(
                                    session: session,
                                    height: constraints.maxHeight,
                                    track: track,
                                    coverPathFuture: coverPathFuture,
                                  ),
                                ),
                              );

                              if (isLandscape) {
                                artworkWidget = Center(
                                  child: AspectRatio(
                                    aspectRatio: 1.0,
                                    child: artworkWidget,
                                  ),
                                );
                              }

                              final artwork = Padding(
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
                              final subtitles = ref.read(
                                playbackSubtitleServiceProvider,
                              );
                              final hasSubtitle = subtitles.hasKnownSubtitle(
                                session.currentTrackPath,
                              );
                              final subtitleSettings = ref.watch(
                                subtitleSettingsProvider,
                              );

                              return _SessionDetailContent(
                                key: _detailContentKey,
                                session: session,
                                segmentPanelExpandedNotifier:
                                    widget.segmentPanelExpandedNotifier,
                                isLandscape: isLandscape,
                                artworkWidget: artwork,
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
                                onShowAudioDetail: () =>
                                    _showAudioDetailForSession(
                                      context,
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
