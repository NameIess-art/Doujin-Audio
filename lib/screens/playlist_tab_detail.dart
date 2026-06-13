part of 'playlist_tab.dart';

class SessionDetailPage extends ConsumerStatefulWidget {
  const SessionDetailPage({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<SessionDetailPage> createState() => _SessionDetailPageState();
}

class _SessionDetailPageState extends ConsumerState<SessionDetailPage>
    with TickerProviderStateMixin {
  late final AnimationController _dismissController;
  late final AnimationController _slideController;
  late Animation<Offset> _slideAnimation;
  late String _currentSessionId;
  String? _lastPrecachingCoverKey;
  double _horizontalDragDelta = 0;
  Future<String?>? _coverPathFuture;
  String? _lastTrackPath;
  int _lastCoverGeneration = -1;

  final Set<String> _primedAdjacentCoverKeys = <String>{};
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
    _slideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
      value: 1,
    );
    _slideAnimation = Tween<Offset>(begin: Offset.zero, end: Offset.zero)
        .animate(
          CurvedAnimation(parent: _slideController, curve: Curves.easeOutCubic),
        );
  }

  @override
  void dispose() {
    _segmentPanelExpandedNotifier.dispose();
    _dismissController.dispose();
    _slideController.dispose();
    super.dispose();
  }

  Future<void> _precacheImageProvider(
    ImageProvider<Object> imageProvider,
    ImageConfiguration configuration,
  ) {
    final completer = Completer<void>();
    final stream = imageProvider.resolve(configuration);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (image, syncCall) {
        if (!completer.isCompleted) {
          completer.complete();
        }
        stream.removeListener(listener);
      },
      onError: (error, stackTrace) {
        if (!completer.isCompleted) {
          completer.complete();
        }
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);
    return completer.future;
  }

  void _primeCoverArtwork(MusicTrack? track, Future<String?> coverPathFuture) {
    final mediaSize = MediaQuery.sizeOf(context);
    final heroHeight = min(250.0, max(180.0, mediaSize.height * 0.28));
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final cacheWidth = (mediaSize.width * dpr).round();
    final cacheHeight = (heroHeight * dpr).round();
    final precacheKey = buildSessionCoverPrecacheKey(
      sessionId: _currentSessionId,
      trackPath: _lastTrackPath ?? '',
      cacheWidth: cacheWidth,
      cacheHeight: cacheHeight,
      coverGeneration: _lastCoverGeneration,
    );
    if (_lastPrecachingCoverKey == precacheKey) {
      return;
    }
    _lastPrecachingCoverKey = precacheKey;
    final imageConfiguration = createLocalImageConfiguration(context);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        Future<void>(() async {
          final remoteCoverUrl = track?.remoteCoverUrl?.trim();
          if (remoteCoverUrl != null && remoteCoverUrl.isNotEmpty) {
            try {
              await _precacheImageProvider(
                NetworkImage(remoteCoverUrl),
                imageConfiguration,
              );
            } catch (_) {
              // Cover precaching is optional; the UI has a visual fallback.
            }
            return;
          }
          final coverPath = await coverPathFuture;
          if (!mounted || coverPath == null || coverPath.isEmpty) {
            return;
          }
          try {
            await _precacheImageProvider(
              ResizeImage.resizeIfNeeded(
                kCoverImageCacheSize,
                null,
                FileImage(File(coverPath)),
              ),
              imageConfiguration,
            );
          } catch (_) {
            // Cover precaching is optional; the UI has a visual fallback.
          }
        }),
      );
    });
  }

  void _primeAdjacentCoverArtworks(
    AudioProvider provider,
    int coverGeneration,
  ) {
    final sessions = provider.activeSessions;
    final currentIndex = sessions.indexWhere((s) => s.id == _currentSessionId);
    if (currentIndex < 0) return;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final cacheWidth = (96 * dpr).round();
    final imageConfiguration = createLocalImageConfiguration(context);

    for (final index in <int>[currentIndex - 1, currentIndex + 1]) {
      if (index < 0 || index >= sessions.length) continue;
      final session = sessions[index];
      final trackPath = session.currentTrackPath;
      final precacheKey = buildSessionCoverPrecacheKey(
        sessionId: session.id,
        trackPath: trackPath,
        cacheWidth: cacheWidth,
        cacheHeight: cacheWidth,
        coverGeneration: coverGeneration,
      );
      if (!_primedAdjacentCoverKeys.add(precacheKey)) continue;
      final track = provider.trackByPath(trackPath);
      final future = _coverFutureForTrack(provider, track);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(
          Future<void>(() async {
            final remoteCoverUrl = track?.remoteCoverUrl?.trim();
            if (remoteCoverUrl != null && remoteCoverUrl.isNotEmpty) {
              try {
                await _precacheImageProvider(
                  NetworkImage(remoteCoverUrl),
                  imageConfiguration,
                );
              } catch (_) {
                // Cover precaching is optional; the UI has a visual fallback.
              }
              return;
            }
            final coverPath = await future;
            if (!mounted || coverPath == null || coverPath.isEmpty) return;
            try {
              await _precacheImageProvider(
                ResizeImage.resizeIfNeeded(
                  kCoverImageCacheSize,
                  null,
                  FileImage(File(coverPath)),
                ),
                imageConfiguration,
              );
            } catch (_) {
              // Cover precaching is optional; the UI has a visual fallback.
            }
          }),
        );
      });
    }
  }

  Future<void> _handleVerticalDragEnd(
    DragEndDetails details,
    BuildContext context,
  ) async {
    final navigator = Navigator.of(context);
    final velocity = details.primaryVelocity ?? 0;
    final shouldDismiss = _dismissController.value > 0.25 || velocity > 800;
    if (shouldDismiss) {
      ref
          .read(audioProviderFacadeProvider)
          .requestCarouselSnapTo(_currentSessionId);
      await _animateDismissToEnd(velocity: velocity);
      if (mounted) {
        await navigator.maybePop();
      }
      return;
    }
    await _animateDismissBack();
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

  void _changeSessionByOffset(AudioProvider provider, int offset) {
    final sessions = provider.activeSessions;
    if (sessions.length < 2) return;
    final currentIndex = sessions.indexWhere(
      (session) => session.id == _currentSessionId,
    );
    if (currentIndex < 0) return;
    final nextIndex = (currentIndex + offset)
        .clamp(0, sessions.length - 1)
        .toInt();
    if (nextIndex == currentIndex) return;
    unawaited(
      AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection),
    );
    final direction = offset.sign == 0 ? 1 : offset.sign;
    _slideController.stop();
    _slideAnimation =
        Tween<Offset>(
          begin: Offset(0.12 * direction, 0),
          end: Offset.zero,
        ).animate(
          CurvedAnimation(parent: _slideController, curve: Curves.easeOutQuart),
        );
    setState(() {
      _horizontalDragDelta = 0;
      _currentSessionId = sessions[nextIndex].id;
    });
    unawaited(_slideController.forward(from: 0));
  }

  void _handleHorizontalDragEnd(
    DragEndDetails details,
    AudioProvider provider,
  ) {
    final velocity = details.primaryVelocity ?? 0;
    final shouldGoPrevious = _horizontalDragDelta > 48 || velocity > 400;
    final shouldGoNext = _horizontalDragDelta < -48 || velocity < -400;
    _horizontalDragDelta = 0;
    if (shouldGoPrevious) {
      _changeSessionByOffset(provider, -1);
      return;
    }
    if (shouldGoNext) {
      _changeSessionByOffset(provider, 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.read<AudioProvider>();
    final uiState = ref.watch(sessionDetailUiProvider(_currentSessionId));
    final sessionOrderState = uiState.sessionOrder;
    final detailState = uiState.detail;
    final session = provider.sessionById(_currentSessionId);

    if (session == null || detailState == null) {
      final fallbackSessionId = sessionOrderState.sessionIds.isEmpty
          ? null
          : sessionOrderState.sessionIds.first;
      if (fallbackSessionId == null) {
        return const Scaffold(body: SizedBox.shrink());
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _currentSessionId = fallbackSessionId;
        });
      });
      return const Scaffold(body: SizedBox.shrink());
    }

    final currentCoverGen = uiState.coverGeneration;
    if (_lastTrackPath != detailState.trackPath ||
        _lastCoverGeneration != currentCoverGen) {
      _lastTrackPath = detailState.trackPath;
      _lastCoverGeneration = currentCoverGen;
      final detailTrack = provider.trackByPath(detailState.trackPath);
      _coverPathFuture = _coverFutureForTrack(provider, detailTrack);
    }
    final coverPathFuture = _coverPathFuture!;
    final detailTrack = provider.trackByPath(detailState.trackPath);
    _primeCoverArtwork(detailTrack, coverPathFuture);
    _primeAdjacentCoverArtworks(provider, currentCoverGen);
    final routeAnimation = ModalRoute.of(context)?.animation;
    final animatedListenable = routeAnimation == null
        ? _dismissController
        : Listenable.merge([routeAnimation, _dismissController]);
    final enableVerticalDismiss = !Platform.isWindows;

    return Material(
      color: Colors.transparent,
      child: AnimatedBuilder(
        animation: animatedListenable,
        builder: (context, child) {
          final enterProgress = Curves.easeOutCubic.transform(
            (routeAnimation?.value ?? 1).clamp(0.0, 1.0),
          );
          final dismissProgress = Curves.easeOutCubic.transform(
            _dismissController.value.clamp(0.0, 1.0),
          );
          final dragDistance =
              MediaQuery.sizeOf(context).height * dismissProgress;
          final enterOffset =
              (1 - enterProgress) * MediaQuery.sizeOf(context).height;
          final backdropCurve =
              dismissProgress; // Use linear for backdrop to avoid sudden changes
          final backdropProgress = (enterProgress * (1 - backdropCurve)).clamp(
            0.0,
            1.0,
          );
          final detailOpacity = ((1 - dismissProgress) / 0.75).clamp(0.0, 1.0);

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
              Opacity(
                opacity: detailOpacity,
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: FractionallySizedBox(
                    heightFactor: 1.0,
                    child: Transform.translate(
                      offset: Offset(0, enterOffset + dragDistance),
                      child: child,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
        child: RepaintBoundary(
          child: AnimatedBuilder(
            animation: _slideController,
            builder: (context, child) {
              return child!;
            },
            child: Listener(
              onPointerSignal: Platform.isWindows
                  ? (event) {
                      if (_segmentPanelExpandedNotifier.value) return;
                      if (event is PointerScrollEvent) {
                        if (event.scrollDelta.dy > 0) {
                          _changeSessionByOffset(provider, 1);
                        } else if (event.scrollDelta.dy < 0) {
                          _changeSessionByOffset(provider, -1);
                        }
                      }
                    }
                  : null,
              child: _SessionDetailScaffold(
                session: session,
                provider: provider,
                coverPathFuture: coverPathFuture,
                slideAnimation: _slideAnimation,
                dismissAnimation: _dismissController,
                segmentPanelExpandedNotifier: _segmentPanelExpandedNotifier,
                onClose: () async {
                  ref
                      .read(audioProviderFacadeProvider)
                      .requestCarouselSnapTo(_currentSessionId);
                  await _animateDismissToEnd();
                  if (context.mounted) {
                    await Navigator.of(context).maybePop();
                  }
                },
                switchAnimation: _slideController,
                onHorizontalDragUpdate: Platform.isWindows
                    ? null
                    : (details) {
                        if (_segmentPanelExpandedNotifier.value) return;
                        _horizontalDragDelta += details.primaryDelta ?? 0;
                      },
                onHorizontalDragEnd: Platform.isWindows
                    ? null
                    : (details) {
                        if (_segmentPanelExpandedNotifier.value) return;
                        _handleHorizontalDragEnd(details, provider);
                      },
                onHorizontalDragCancel: Platform.isWindows
                    ? null
                    : () {
                        if (_segmentPanelExpandedNotifier.value) return;
                        _horizontalDragDelta = 0;
                      },
                onVerticalDragUpdate: enableVerticalDismiss
                    ? (details) {
                        final screenHeight = MediaQuery.sizeOf(context).height;
                        if (screenHeight <= 0) return;
                        final nextValue =
                            _dismissController.value +
                            (((details.primaryDelta ?? 0) / screenHeight) *
                                0.92);
                        _dismissController.value = nextValue.clamp(0.0, 1.0);
                      }
                    : null,
                onVerticalDragEnd: enableVerticalDismiss
                    ? (details) => _handleVerticalDragEnd(details, context)
                    : null,
                onVerticalDragCancel: enableVerticalDismiss
                    ? () {
                        _animateDismissBack();
                      }
                    : null,
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
  final Animation<Offset> slideAnimation;
  final Animation<double> dismissAnimation;
  final VoidCallback onClose;
  final void Function(DragUpdateDetails)? onHorizontalDragUpdate;
  final void Function(DragEndDetails)? onHorizontalDragEnd;
  final VoidCallback? onHorizontalDragCancel;
  final void Function(DragUpdateDetails)? onVerticalDragUpdate;
  final void Function(DragEndDetails)? onVerticalDragEnd;
  final VoidCallback? onVerticalDragCancel;
  final Animation<double> switchAnimation;
  final ValueNotifier<bool>? segmentPanelExpandedNotifier;

  const _SessionDetailScaffold({
    required this.session,
    required this.provider,
    required this.coverPathFuture,
    required this.slideAnimation,
    required this.onClose,
    required this.switchAnimation,
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
    final slideAnimation = widget.slideAnimation;
    final onClose = widget.onClose;
    final onHorizontalDragUpdate = widget.onHorizontalDragUpdate;
    final onHorizontalDragEnd = widget.onHorizontalDragEnd;
    final onHorizontalDragCancel = widget.onHorizontalDragCancel;
    final onVerticalDragUpdate = widget.onVerticalDragUpdate;
    final onVerticalDragEnd = widget.onVerticalDragEnd;
    final onVerticalDragCancel = widget.onVerticalDragCancel;

    final cs = Theme.of(context).colorScheme;
    final track = provider.trackByPath(session.currentTrackPath);
    final blurEnabled = ref.watch(
      settingsStateProvider.select(
        (s) => s.valueOrNull?.blurPlayerBackgroundEnabled ?? true,
      ),
    );

    return Material(
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
            _isDismissGesture = true;
          }

          if (_isDismissGesture) {
            onVerticalDragUpdate?.call(details);
            return;
          }

          if ((panelExpanded && delta > 0) ||
              (!panelExpanded && delta < 0 && detailFullyOpen)) {
            _segmentPanelDragDelta += delta;
            return;
          }

          onVerticalDragUpdate?.call(details);
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
              panelExpanded && (_segmentPanelDragDelta > 120 || velocity > 800);
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
                child: RepaintBoundary(
                  child: AnimatedBuilder(
                    animation: widget.dismissAnimation,
                    builder: (context, child) {
                      final dismissProgress = Curves.easeOutCubic.transform(
                        widget.dismissAnimation.value.clamp(0.0, 1.0),
                      );
                      if (dismissProgress >= 1.0) {
                        return const SizedBox.shrink();
                      }
                      return Opacity(
                        opacity: 1 - dismissProgress,
                        child: child,
                      );
                    },
                    child: ImageFiltered(
                      imageFilter: ImageFilter.blur(sigmaX: 64, sigmaY: 64),
                      child: track?.remoteCoverUrl?.trim().isNotEmpty == true
                          ? RetryingNetworkImage(
                              url: track!.remoteCoverUrl!.trim(),
                              fit: BoxFit.cover,
                              cacheWidth:
                                  (MediaQuery.sizeOf(context).width *
                                          MediaQuery.devicePixelRatioOf(
                                            context,
                                          ))
                                      .round(),
                              color: cs.surface.withValues(alpha: 0.45),
                              colorBlendMode: BlendMode.darken,
                              loadingBuilder:
                                  (context, child, loadingProgress) =>
                                      loadingProgress == null
                                      ? child
                                      : CoverLoadingArtwork(
                                          placeholder: CoverFallbackArtwork(
                                            seed: track.displayName,
                                            showIcon: false,
                                          ),
                                          size: 36,
                                          strokeWidth: 3,
                                          color: cs.primary,
                                        ),
                              fallbackBuilder: (_) => CoverFallbackArtwork(
                                seed: track.displayName,
                                showIcon: false,
                              ),
                            )
                          : AsyncCoverImage(
                              duration: Duration.zero,
                              future: coverPathFuture,
                              initialPath: provider.resolvedCoverPathForTrack(
                                track,
                              ),
                              retryFutureBuilder: () =>
                                  _coverFutureForTrack(provider, track),
                              fallbackBuilder: (_) => CoverFallbackArtwork(
                                seed:
                                    track?.displayName ??
                                    session.currentTrackPath,
                                showIcon: false,
                              ),
                              imageBuilder: (context, coverPath) {
                                final mediaSize = MediaQuery.sizeOf(context);
                                final dpr = MediaQuery.devicePixelRatioOf(
                                  context,
                                );
                                return RetryingFileImage(
                                  path: coverPath,
                                  cacheWidth: (mediaSize.width * dpr).round(),
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
                  return AnimatedBuilder(
                    animation: Listenable.merge([
                      slideAnimation,
                      widget.switchAnimation,
                    ]),
                    builder: (context, child) {
                      final switchProgress = Curves.easeOutCubic.transform(
                        widget.switchAnimation.value.clamp(0.0, 1.0),
                      );
                      final opacity =
                          lerpDouble(0.88, 1.0, switchProgress) ?? 1;
                      return opacity == 1.0
                          ? SlideTransition(
                              position: slideAnimation,
                              child: child,
                            )
                          : Opacity(
                              opacity: opacity,
                              child: SlideTransition(
                                position: slideAnimation,
                                child: child,
                              ),
                            );
                    },
                    child: Column(
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
                                  const Spacer(),
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
                                  if (session.channelSwapEnabled) ...[
                                    Icon(
                                      Icons.swap_horiz_rounded,
                                      color: cs.onSurface,
                                      size: 20,
                                    ),
                                    const SizedBox(width: 8),
                                  ],
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

                              Widget artworkWidget = _SessionHeroArtwork(
                                sessionId: session.id,
                                height: constraints.maxHeight,
                                track: track,
                                coverPathFuture: coverPathFuture,
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
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
