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

    final view = context
        .select<
          AudioProvider,
          ({bool playing, bool loading, String trackPath})
        >((value) {
          final currentSession = value.sessionById(session.id) ?? session;
          return (
            playing: currentSession.state.playing,
            loading: currentSession.isLoading,
            trackPath: currentSession.currentTrackPath,
          );
        });
    final isPlaying = view.playing;
    final currentTrack = provider.trackByPath(view.trackPath);
    final displayName =
        currentTrack?.displayName ??
        path.basenameWithoutExtension(view.trackPath);
    final screenSize = MediaQuery.sizeOf(context);
    final isSmallWindow = screenSize.width < 450 || screenSize.height < 400;
    final isTinyWindow = screenSize.width < 300 || screenSize.height < 300;

    final blurSigma = isSmallWindow ? 4.0 : 8.0;

    return Semantics(
      button: true,
      label: displayName,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(cardRadius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(cardRadius),
              onTap: onOpen,
              child: Ink(
                height: 74,
                decoration: BoxDecoration(
                  color: (isDark ? cs.surfaceBright : cs.surfaceContainerHighest)
                      .withValues(alpha: isSmallWindow 
                          ? (isDark ? 0.88 : 0.92) 
                          : (isDark ? 0.55 : 0.75)),
                  borderRadius: BorderRadius.circular(cardRadius),
                  boxShadow: isTinyWindow ? null : [
                    BoxShadow(
                      color: cs.shadow.withValues(
                        alpha: isPlaying ? 0.26 : 0.18,
                      ),
                      blurRadius: isPlaying ? 34 : 26,
                      spreadRadius: -7,
                      offset: const Offset(0, 18),
                    ),
                    BoxShadow(
                      color: cs.primary.withValues(
                        alpha: isPlaying ? 0.08 : 0.04,
                      ),
                      blurRadius: 18,
                      spreadRadius: -10,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: _buildCardContent(context, cs, isPlaying, view, displayName),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCardContent(BuildContext context, ColorScheme cs, bool isPlaying, 
      ({bool playing, bool loading, String trackPath}) view, String displayName) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 8, 4),
          child: Row(
            children: [
              _ActiveSessionCover(coverPathFuture: coverPathFuture),
              const SizedBox(width: 12),
              Expanded(
                child: _ActiveSessionTitleSubtitle(
                  key: ValueKey('${session.id}:${view.trackPath}'),
                  session: session,
                  provider: provider,
                  displayName: displayName,
                ),
              ),
              const SizedBox(width: 8),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _ActiveSessionPlayPauseButton(
                    isPlaying: isPlaying,
                    enabled: !view.loading,
                    onPressed: () {
                      HapticFeedback.mediumImpact();
                      provider.toggleSessionPlayPause(session.id);
                    },
                  ),
                  Consumer(
                    builder: (context, ref, child) {
                      final settings = ref.watch(subtitleSettingsProvider);
                      final showSub = settings.isGlobalEnabled(session.id);
                      if (!showSub && !session.channelSwapEnabled) {
                        return const SizedBox.shrink();
                      }
                      return Padding(
                        padding: const EdgeInsets.only(top: 1),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (showSub)
                              Icon(Icons.subtitles_rounded, size: 10, color: cs.primary),
                            if (showSub && session.channelSwapEnabled) const SizedBox(width: 2),
                            if (session.channelSwapEnabled)
                              Icon(Icons.swap_horiz_rounded, size: 10, color: cs.primary),
                          ],
                        ),
                      );
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
        _ActiveSessionProgressStrip(session: session),
      ],
    );
  }
}

class _ActiveSessionPlayPauseButton extends StatelessWidget {
  const _ActiveSessionPlayPauseButton({
    required this.isPlaying,
    required this.enabled,
    required this.onPressed,
  });

  final bool isPlaying;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox.square(
      dimension: 48,
      child: Material(
        color: Colors.transparent,
        child: InkResponse(
          onTap: enabled ? onPressed : null,
          containedInkWell: true,
          radius: 24,
          customBorder: const CircleBorder(),
          child: Center(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) {
                return FadeTransition(
                  opacity: animation,
                  child: ScaleTransition(
                    scale: Tween<double>(
                      begin: 0.92,
                      end: 1,
                    ).animate(animation),
                    child: child,
                  ),
                );
              },
              child: Transform.translate(
                key: ValueKey(isPlaying),
                offset: isPlaying ? Offset.zero : const Offset(1, 0),
                child: Icon(
                  isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  size: 36,
                  color: isPlaying ? cs.primary : cs.onSurface,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ActiveSessionTitleSubtitle extends StatefulWidget {
  const _ActiveSessionTitleSubtitle({
    super.key,
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
    if (_loadedPath != widget.session.currentTrackPath) {
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
    setState(() {
      _subtitleTrack = null;
      _subtitleText = null;
    });
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

class _ActiveSessionProgressStrip extends StatefulWidget {
  const _ActiveSessionProgressStrip({required this.session});

  final PlaybackSession session;

  @override
  State<_ActiveSessionProgressStrip> createState() =>
      _ActiveSessionProgressStripState();
}

class _ActiveSessionProgressStripState
    extends State<_ActiveSessionProgressStrip> {
  StreamSubscription<Duration?>? _durationSub;
  Duration? _duration;

  @override
  void initState() {
    super.initState();
    _duration = widget.session.duration;
    _bindDuration();
  }

  @override
  void didUpdateWidget(covariant _ActiveSessionProgressStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session == widget.session) return;
    unawaited(_durationSub?.cancel());
    _duration = widget.session.duration;
    _bindDuration();
  }

  @override
  void dispose() {
    unawaited(_durationSub?.cancel());
    super.dispose();
  }

  void _bindDuration() {
    _durationSub = widget.session.durationStream.listen((duration) {
      if (duration == null && _duration != null) return;
      if (_duration == duration) return;
      setState(() {
        _duration = duration;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return StreamBuilder<Duration>(
      stream: widget.session.positionStream,
      initialData: widget.session.position,
      builder: (context, posSnapshot) {
        final pos = posSnapshot.data ?? widget.session.position;
        final dur = _duration;
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
        child: AsyncCoverImage(
          future: coverPathFuture,
          fallbackBuilder: (_) => fallback(),
          loadingBuilder: (_) => PulsingPlaceholder(
            borderRadius: BorderRadius.circular(14),
            child: fallback(),
          ),
          imageBuilder: (context, coverPath) {
            final dpr = MediaQuery.devicePixelRatioOf(context);
            return Image(
              image: resizeFileImageIfNeeded(
                path: coverPath,
                cacheWidth: (58 * dpr).round(),
              ),
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => fallback(),
            );
          },
        ),
      ),
    );
  }
}
