part of 'playlist_tab.dart';

class SessionDetailPage extends StatefulWidget {
  const SessionDetailPage({super.key, required this.sessionId});

  final String sessionId;

  @override
  State<SessionDetailPage> createState() => _SessionDetailPageState();
}

class _SessionDetailPageState extends State<SessionDetailPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _dismissController;
  late final AnimationController _slideController;
  late Animation<Offset> _slideAnimation;
  late String _currentSessionId;
  String? _lastPrecachingCoverKey;
  double _horizontalDragDelta = 0;
  Future<String?>? _coverPathFuture;
  String? _lastTrackPath;

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
    _dismissController.dispose();
    _slideController.dispose();
    super.dispose();
  }

  void _primeCoverArtwork(Future<String?> coverPathFuture) {
    final mediaSize = MediaQuery.sizeOf(context);
    final heroHeight = min(250.0, max(180.0, mediaSize.height * 0.28));
    final dpr = min(MediaQuery.devicePixelRatioOf(context), 2.0);
    final cacheWidth = (mediaSize.width * dpr).round();
    final cacheHeight = (heroHeight * dpr).round();
    final precacheKey = '$_currentSessionId:$cacheWidth:$cacheHeight';
    if (_lastPrecachingCoverKey == precacheKey) {
      return;
    }
    _lastPrecachingCoverKey = precacheKey;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        Future<void>(() async {
          final coverPath = await coverPathFuture;
          if (!mounted || coverPath == null || coverPath.isEmpty) {
            return;
          }
          try {
            await precacheImage(
              ResizeImage.resizeIfNeeded(
                cacheWidth,
                null,
                FileImage(File(coverPath)),
              ),
              context,
            );
          } catch (_) {}
        }),
      );
    });
  }

  Future<void> _handleVerticalDragEnd(
    DragEndDetails details,
    BuildContext context,
  ) async {
    final navigator = Navigator.of(context);
    final velocity = details.primaryVelocity ?? 0;
    final shouldDismiss = _dismissController.value > 0.25 || velocity > 800;
    if (shouldDismiss) {
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
    final durationMs = lerpDouble(260, 170, velocityFactor)! * remaining;
    return _dismissController.animateTo(
      1,
      duration: Duration(milliseconds: durationMs.round().clamp(150, 280)),
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
    unawaited(HapticFeedback.selectionClick());
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
    final selection = context
        .select<
          AudioProvider,
          ({
            PlaybackSession? session,
            String? fallbackSessionId,
            String? trackPath,
            bool? loading,
            bool? playing,
            ProcessingState? processingState,
            SessionLoopMode? loopMode,
            double? volume,
            bool? channelSwapEnabled,
          })
        >((provider) {
          final sessions = provider.activeSessions;
          final session = sessions.cast<PlaybackSession?>().firstWhere(
            (candidate) => candidate?.id == _currentSessionId,
            orElse: () => null,
          );
          return (
            session: session,
            fallbackSessionId: sessions.isEmpty ? null : sessions.first.id,
            trackPath: session?.currentTrackPath,
            loading: session?.isLoading,
            playing: session?.state.playing,
            processingState: session?.state.processingState,
            loopMode: session?.loopMode,
            volume: session?.volume,
            channelSwapEnabled: session?.channelSwapEnabled,
          );
        });
    final provider = context.read<AudioProvider>();
    final session = selection.session;

    if (session == null) {
      final fallbackSessionId = selection.fallbackSessionId;
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

    final trackPath = session.currentTrackPath;
    if (_lastTrackPath != trackPath) {
      _lastTrackPath = trackPath;
      final track = provider.trackByPath(trackPath);
      _coverPathFuture = _coverFutureForTrack(provider, track);
    }
    final coverPathFuture = _coverPathFuture!;
    _primeCoverArtwork(coverPathFuture);
    final routeAnimation = ModalRoute.of(context)?.animation;
    final animatedListenable = routeAnimation == null
        ? _dismissController
        : Listenable.merge([routeAnimation, _dismissController]);

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
          final enterOffset = (1 - enterProgress) * 60;
          final backdropCurve = Curves.easeInQuint.transform(dismissProgress);
          final backdropProgress = (enterProgress * (1 - backdropCurve)).clamp(
            0.0,
            1.0,
          );
          final detailOpacity = ((1 - dismissProgress) / 0.82).clamp(0.0, 1.0);

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
                  child: RepaintBoundary(
                    child: _SessionDetailBackdrop(progress: backdropProgress),
                  ),
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
              final switchProgress = Curves.easeOutCubic.transform(
                _slideController.value.clamp(0.0, 1.0),
              );
              final opacity = lerpDouble(0.84, 1, switchProgress) ?? 1;
              return Opacity(
                opacity: opacity,
                child: child,
              );
            },
            child: _SessionDetailScaffold(
              session: session,
              provider: provider,
              coverPathFuture: coverPathFuture,
              slideAnimation: _slideAnimation,
              onClose: () async {
                await _animateDismissToEnd();
                if (context.mounted) {
                  await Navigator.of(context).maybePop();
                }
              },
              onHorizontalDragUpdate: (details) {
                _horizontalDragDelta += details.primaryDelta ?? 0;
              },
              onHorizontalDragEnd: (details) =>
                  _handleHorizontalDragEnd(details, provider),
              onHorizontalDragCancel: () {
                _horizontalDragDelta = 0;
              },
              onVerticalDragUpdate: (details) {
                final screenHeight = MediaQuery.sizeOf(context).height;
                if (screenHeight <= 0) return;
                final nextValue =
                    _dismissController.value +
                    (((details.primaryDelta ?? 0) / screenHeight) * 0.92);
                _dismissController.value = nextValue.clamp(0.0, 1.0);
              },
              onVerticalDragEnd: (details) =>
                  _handleVerticalDragEnd(details, context),
              onVerticalDragCancel: () {
                _animateDismissBack();
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
    final blurSigma = lerpDouble(0, 10, progress) ?? 0;
    final gradientAlpha = lerpDouble(0, 1, progress) ?? 0;

    if (blurSigma < 0.1 && gradientAlpha < 0.01) return const SizedBox.shrink();

    return Stack(
      fit: StackFit.expand,
      children: [
        Opacity(
          opacity: gradientAlpha,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  cs.surface.withValues(alpha: 0.08),
                  cs.scrim.withValues(alpha: 0.08),
                  cs.scrim.withValues(alpha: 0.14),
                ],
              ),
            ),
          ),
        ),
        if (blurSigma > 0.1)
          ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
              child: const SizedBox.expand(),
            ),
          ),
      ],
    );
  }
}

class _SessionDetailScaffold extends StatelessWidget {
  final PlaybackSession session;
  final AudioProvider provider;
  final Future<String?> coverPathFuture;
  final Animation<Offset> slideAnimation;
  final VoidCallback onClose;
  final void Function(DragUpdateDetails)? onHorizontalDragUpdate;
  final void Function(DragEndDetails)? onHorizontalDragEnd;
  final VoidCallback? onHorizontalDragCancel;
  final void Function(DragUpdateDetails)? onVerticalDragUpdate;
  final void Function(DragEndDetails)? onVerticalDragEnd;
  final VoidCallback? onVerticalDragCancel;

  const _SessionDetailScaffold({
    required this.session,
    required this.provider,
    required this.coverPathFuture,
    required this.slideAnimation,
    required this.onClose,
    this.onHorizontalDragUpdate,
    this.onHorizontalDragEnd,
    this.onHorizontalDragCancel,
    this.onVerticalDragUpdate,
    this.onVerticalDragEnd,
    this.onVerticalDragCancel,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Material(
      color: cs.surface,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Dynamic Blurred Background
          Positioned.fill(
            child: AsyncCoverImage(
              future: coverPathFuture,
              fallbackBuilder: (_) => ColoredBox(color: cs.surfaceDim),
              imageBuilder: (context, coverPath) {
                final mediaSize = MediaQuery.sizeOf(context);
                final dpr = MediaQuery.devicePixelRatioOf(context);
                return Image(
                  image: resizeFileImageIfNeeded(
                    path: coverPath,
                    cacheWidth: (mediaSize.width * dpr).round(),
                  ),
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  color: cs.surface.withValues(alpha: 0.45),
                  colorBlendMode: BlendMode.darken,
                  errorBuilder: (_, _, _) => ColoredBox(color: cs.surfaceDim),
                );
              },
            ),
          ),
          Positioned.fill(
            child: RepaintBoundary(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                child: const SizedBox.expand(),
              ),
            ),
          ),
          // Content
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return SlideTransition(
                  position: slideAnimation,
                  child: Column(
                    children: [
                    // Top Bar — outside drag GestureDetector so taps work
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(
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
                          if (session.channelSwapEnabled) ...[
                            Icon(
                              Icons.swap_horiz_rounded,
                              color: cs.onSurface,
                              size: 20,
                            ),
                            const SizedBox(width: 8),
                          ],
                          UnifiedPopupMenuButton<String>(
                            icon: Icons.more_horiz_rounded,
                            tooltip: MaterialLocalizations.of(
                              context,
                            ).moreButtonTooltip,
                            entries: [
                              UnifiedMenuEntry<String>.action(
                                value: 'channel_swap',
                                icon: session.channelSwapEnabled
                                    ? Icons.check_rounded
                                    : Icons.swap_horiz_rounded,
                                label: context.read<AppLanguageProvider>().tr(
                                  'channel_swap',
                                ),
                              ),
                            ],
                            onSelected: (value) {
                              if (value != 'channel_swap') return;
                              Feedback.forTap(context);
                              unawaited(
                                provider.setSessionChannelSwap(
                                  session.id,
                                  !session.channelSwapEnabled,
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                    // Content area — wrapped in GestureDetector for drag-to-dismiss / session switching
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onHorizontalDragUpdate: onHorizontalDragUpdate,
                        onHorizontalDragEnd: onHorizontalDragEnd,
                        onHorizontalDragCancel: onHorizontalDragCancel,
                        onVerticalDragUpdate: onVerticalDragUpdate,
                        onVerticalDragEnd: onVerticalDragEnd,
                        onVerticalDragCancel: onVerticalDragCancel,
                        child: Column(
                          children: [
                            // Large Artwork
                            Expanded(
                              flex: 6,
                              child: Center(
                                child: RepaintBoundary(
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 32,
                                    ),
                                    child: _SessionHeroArtwork(
                                      height: constraints.maxHeight * 0.48,
                                      coverPathFuture: coverPathFuture,
                                      title: '',
                                      folderName: '',
                                      isPlaying: session.state.playing,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            // Detail Content
                            Expanded(
                              flex: 5,
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  28,
                                  0,
                                  28,
                                  16,
                                ),
                                child: _SessionDetailContent(
                                  session: session,
                                  provider: provider,
                                ),
                              ),
                            ),
                          ],
                        ),
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
    );
  }
}
