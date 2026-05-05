part of 'active_session_carousel.dart';

class _ActiveSessionCard extends StatelessWidget {
  const _ActiveSessionCard({
    required this.session,
    required this.track,
    required this.provider,
    required this.coverPathFuture,
    required this.onOpen,
  });

  final PlaybackSession session;
  final MusicTrack? track;
  final AudioProvider provider;
  final Future<String?> coverPathFuture;
  final VoidCallback onOpen;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    const cardRadius = 20.0;

    return StreamBuilder<PlayerState>(
      stream: session.stateStream,
      initialData: session.state,
      builder: (context, stateSnapshot) {
        final playerState = stateSnapshot.data ?? session.state;
        final isPlaying = playerState.playing;
        final currentTrack = provider.trackByPath(session.currentTrackPath);
        final displayName =
            currentTrack?.displayName ??
            path.basenameWithoutExtension(session.currentTrackPath);

        return Semantics(
          button: true,
          label: displayName,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(cardRadius),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(cardRadius),
                  onTap: onOpen,
                  child: Ink(
                    height: 74,
                    decoration: BoxDecoration(
                      color:
                          (isDark
                                  ? cs.surfaceBright
                                  : cs.surfaceContainerHighest)
                              .withValues(alpha: isDark ? 0.55 : 0.75),
                      borderRadius: BorderRadius.circular(cardRadius),
                      boxShadow: [
                        BoxShadow(
                          color: cs.shadow.withValues(
                            alpha: isPlaying ? 0.16 : 0.10,
                          ),
                          blurRadius: isPlaying ? 22 : 16,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(10, 6, 8, 4),
                          child: Row(
                            children: [
                              _ActiveSessionCover(
                                coverPathFuture: coverPathFuture,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: _ActiveSessionTitleSubtitle(
                                  session: session,
                                  provider: provider,
                                  displayName: displayName,
                                ),
                              ),
                              const SizedBox(width: 8),
                              IconButton.filledTonal(
                                onPressed: session.isLoading
                                    ? null
                                    : () {
                                        HapticFeedback.mediumImpact();
                                        provider.toggleSessionPlayPause(
                                          session.id,
                                        );
                                      },
                                style: IconButton.styleFrom(
                                  minimumSize: const Size(48, 48),
                                  maximumSize: const Size(48, 48),
                                  backgroundColor: isPlaying
                                      ? cs.primaryContainer
                                      : cs.surfaceContainerLow,
                                  foregroundColor: isPlaying
                                      ? cs.onPrimaryContainer
                                      : cs.onSurface,
                                  shape: const CircleBorder(),
                                  side: BorderSide(
                                    color: isPlaying
                                        ? cs.primary.withValues(alpha: 0.24)
                                        : cs.outlineVariant.withValues(
                                            alpha: 0.72,
                                          ),
                                  ),
                                ),
                                icon: _CarouselSwitcherSlot(
                                  width: 22,
                                  height: 22,
                                  child: Icon(
                                    isPlaying
                                        ? Icons.pause_rounded
                                        : Icons.play_arrow_rounded,
                                    key: ValueKey<IconData>(
                                      isPlaying
                                          ? Icons.pause_rounded
                                          : Icons.play_arrow_rounded,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        _ActiveSessionProgressStrip(session: session),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ActiveSessionTitleSubtitle extends StatefulWidget {
  const _ActiveSessionTitleSubtitle({
    required this.session,
    required this.provider,
    required this.displayName,
  });

  final PlaybackSession session;
  final AudioProvider provider;
  final String displayName;

  @override
  State<_ActiveSessionTitleSubtitle> createState() =>
      _ActiveSessionTitleSubtitleState();
}

class _ActiveSessionTitleSubtitleState
    extends State<_ActiveSessionTitleSubtitle> {
  StreamSubscription<Duration>? _positionSub;
  SubtitleTrack? _subtitleTrack;
  String? _subtitleText;
  String? _loadedPath;

  @override
  void initState() {
    super.initState();
    _loadSubtitleTrack();
    _bindPosition();
  }

  @override
  void didUpdateWidget(covariant _ActiveSessionTitleSubtitle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      unawaited(_positionSub?.cancel());
      _bindPosition();
    }
    if (oldWidget.session.currentTrackPath != widget.session.currentTrackPath) {
      _loadSubtitleTrack();
    }
  }

  @override
  void dispose() {
    unawaited(_positionSub?.cancel());
    super.dispose();
  }

  void _bindPosition() {
    _positionSub = widget.session.positionStream.listen(_updateSubtitleText);
  }

  void _loadSubtitleTrack() {
    final trackPath = widget.session.currentTrackPath;
    _loadedPath = trackPath;
    widget.provider.subtitleTrackForPath(trackPath).then((track) {
      if (!mounted || _loadedPath != trackPath) return;
      _subtitleTrack = track;
      _updateSubtitleText(widget.session.position);
    });
  }

  void _updateSubtitleText(Duration position) {
    final nextText = widget.provider.subtitleTextForTrackAt(
      widget.session.currentTrackPath,
      position,
      subtitleTrack: _subtitleTrack,
    );
    if (_subtitleText == nextText) return;
    setState(() {
      _subtitleText = nextText;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.displayName,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w900,
            fontSize: 14,
            height: 1.08,
          ),
        ),
        if (_subtitleText != null) ...[
          const SizedBox(height: 2),
          Text(
            _subtitleText!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant,
              fontWeight: FontWeight.w600,
              fontSize: 10.2,
              height: 1.15,
            ),
          ),
        ],
      ],
    );
  }
}

class _ActiveSessionProgressStrip extends StatelessWidget {
  const _ActiveSessionProgressStrip({required this.session});

  final PlaybackSession session;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return StreamBuilder<Duration>(
      stream: session.positionStream,
      initialData: session.position,
      builder: (context, posSnapshot) {
        final pos = posSnapshot.data ?? session.position;
        final dur = session.duration;
        if (dur == null || dur.inMilliseconds <= 0) {
          return const SizedBox(height: 3);
        }
        final fraction = pos.inMilliseconds / dur.inMilliseconds;
        return Center(
          child: FractionallySizedBox(
            widthFactor: 0.8,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: SizedBox(
                  height: 4,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final barWidth = constraints.maxWidth;
                      final fillWidth = (barWidth * fraction.clamp(0.0, 1.0))
                          .roundToDouble();
                      return Stack(
                        children: [
                          Positioned.fill(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: cs.surfaceContainerHighest.withValues(
                                  alpha: 0.6,
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            left: 0,
                            top: 0,
                            bottom: 0,
                            width: fillWidth,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    cs.primary,
                                    cs.primary.withValues(alpha: 0.82),
                                  ],
                                ),
                                borderRadius: const BorderRadius.only(
                                  topRight: Radius.circular(3),
                                  bottomRight: Radius.circular(3),
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ActiveSessionCover extends StatelessWidget {
  const _ActiveSessionCover({required this.coverPathFuture});

  final Future<String?> coverPathFuture;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    Widget fallback() {
      return DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              cs.primaryContainer,
              cs.secondaryContainer.withValues(alpha: 0.92),
            ],
          ),
        ),
        child: Center(
          child: Icon(
            Icons.photo_album_rounded,
            size: 24,
            color: cs.onPrimaryContainer,
          ),
        ),
      );
    }

    return SizedBox(
      width: 58,
      height: 58,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: FutureBuilder<String?>(
          future: coverPathFuture,
          builder: (context, snapshot) {
            final coverPath = snapshot.data;
            if (coverPath == null || coverPath.isEmpty) {
              return fallback();
            }
            return Image.file(
              File(coverPath),
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => fallback(),
            );
          },
        ),
      ),
    );
  }
}

class _CarouselSwitcherSlot extends StatelessWidget {
  const _CarouselSwitcherSlot({
    required this.child,
    required this.width,
    required this.height,
  });

  final Widget child;
  final double width;
  final double height;
  final Duration duration = const Duration(milliseconds: 180);

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: duration,
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (currentChild, previousChildren) {
        return SizedBox(
          width: width,
          height: height,
          child: Center(
            child:
                currentChild ??
                (previousChildren.isNotEmpty
                    ? previousChildren.last
                    : const SizedBox.shrink()),
          ),
        );
      },
      transitionBuilder: (child, animation) {
        final opacity = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        );
        return FadeTransition(
          opacity: opacity,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.92, end: 1).animate(opacity),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}
