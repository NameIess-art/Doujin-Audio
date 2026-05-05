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
  late String _currentSessionId;
  String? _lastPrecachingCoverKey;
  double _horizontalDragDelta = 0;

  @override
  void initState() {
    super.initState();
    _currentSessionId = widget.sessionId;
    _dismissController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
      value: 0,
    );
  }

  @override
  void dispose() {
    _dismissController.dispose();
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

    unawaited(
      Future<void>.microtask(() async {
        final coverPath = await coverPathFuture;
        if (!mounted || coverPath == null || coverPath.isEmpty) {
          return;
        }
        try {
          await precacheImage(
            ResizeImage.resizeIfNeeded(
              cacheWidth,
              cacheHeight,
              FileImage(File(coverPath)),
            ),
            context,
          );
        } catch (_) {}
      }),
    );
  }

  Future<void> _handleVerticalDragEnd(
    DragEndDetails details,
    BuildContext context,
  ) async {
    final navigator = Navigator.of(context);
    final velocity = details.primaryVelocity ?? 0;
    final shouldDismiss = _dismissController.value > 0.15 || velocity > 800;
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
    final durationMs = lerpDouble(320, 200, velocityFactor)! * remaining;
    return _dismissController.animateTo(
      1,
      duration: Duration(milliseconds: durationMs.round().clamp(180, 340)),
    );
  }

  Future<void> _animateDismissBack() {
    final progress = _dismissController.value.clamp(0.0, 1.0);
    final durationMs = lerpDouble(140, 260, progress)!;
    return _dismissController.animateBack(
      0,
      duration: Duration(milliseconds: durationMs.round().clamp(140, 280)),
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
    HapticFeedback.selectionClick();
    setState(() {
      _currentSessionId = sessions[nextIndex].id;
      _horizontalDragDelta = 0;
    });
  }

  void _handleHorizontalDragEnd(
    DragEndDetails details,
    AudioProvider provider,
  ) {
    final velocity = details.primaryVelocity ?? 0;
    final shouldGoPrevious = _horizontalDragDelta > 56 || velocity > 520;
    final shouldGoNext = _horizontalDragDelta < -56 || velocity < -520;
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
            String sessionIds,
            String? trackPath,
            bool? loading,
            bool? playing,
            ProcessingState? processingState,
            SessionLoopMode? loopMode,
            double? volume,
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
            sessionIds: sessions.map((session) => session.id).join('\u0001'),
            trackPath: session?.currentTrackPath,
            loading: session?.isLoading,
            playing: session?.state.playing,
            processingState: session?.state.processingState,
            loopMode: session?.loopMode,
            volume: session?.volume,
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

    final track = provider.trackByPath(session.currentTrackPath);
    final coverPathFuture = _coverFutureForTrack(provider, track);
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
          final backdropProgress = (enterProgress * pow(1 - dismissProgress, 3))
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
              Opacity(
                opacity: (1 - dismissProgress).clamp(0.0, 1.0),
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
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
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
            child: _SessionDetailScaffold(
              session: session,
              provider: provider,
              coverPathFuture: coverPathFuture,
              onClose: () async {
                await _animateDismissToEnd();
                if (context.mounted) {
                  await Navigator.of(context).maybePop();
                }
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
    final blurSigma = lerpDouble(0, 16, progress) ?? 0;
    final gradientAlpha = lerpDouble(0, 1, progress) ?? 0;

    if (blurSigma < 0.1 && gradientAlpha < 0.01) return const SizedBox.shrink();

    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                cs.surface.withValues(alpha: 0.08 * gradientAlpha),
                cs.scrim.withValues(alpha: 0.08 * gradientAlpha),
                cs.scrim.withValues(alpha: 0.14 * gradientAlpha),
              ],
            ),
          ),
        ),
        if (blurSigma > 0)
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
  const _SessionDetailScaffold({
    required this.session,
    required this.provider,
    required this.coverPathFuture,
    required this.onClose,
  });

  final PlaybackSession session;
  final AudioProvider provider;
  final Future<String?> coverPathFuture;
  final VoidCallback onClose;

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
            child: FutureBuilder<String?>(
              future: coverPathFuture,
              builder: (context, snapshot) {
                final path = snapshot.data;
                if (path == null || path.isEmpty) {
                  return ColoredBox(color: cs.surfaceDim);
                }
                return Image.file(
                  File(path),
                  fit: BoxFit.cover,
                  color: cs.surface.withValues(alpha: 0.45),
                  colorBlendMode: BlendMode.darken,
                );
              },
            ),
          ),
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 45, sigmaY: 45),
              child: const SizedBox.expand(),
            ),
          ),
          // Content
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return Column(
                  children: [
                    // Top Bar
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
                        ],
                      ),
                    ),
                    // Large Artwork
                    Expanded(
                      flex: 6,
                      child: Center(
                        child: RepaintBoundary(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 32),
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
                        padding: const EdgeInsets.fromLTRB(28, 0, 28, 16),
                        child: _SessionDetailContent(
                          session: session,
                          provider: provider,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
