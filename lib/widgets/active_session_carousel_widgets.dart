part of 'active_session_carousel.dart';

class _ActiveSessionCard extends ConsumerWidget {
  const _ActiveSessionCard({
    required this.session,
    required this.provider,
    required this.coverPathFuture,
    required this.onOpen,
    this.compact = false,
  });

  final PlaybackSession session;
  final AudioProvider provider;
  final Future<String?> coverPathFuture;
  final VoidCallback onOpen;
  final bool compact;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    const cardRadius = 20.0;

    final view = ref.watch(
      playbackStateProvider.select((value) {
        final playbackState = value.valueOrNull;
        final currentSession =
            playbackState?.activeSessions.firstWhere(
              (candidate) => candidate.id == session.id,
              orElse: () => session,
            ) ??
            session;
        return (
          playing: currentSession.state.playing,
          loading:
              currentSession.isLoading || currentSession.isPlaybackStarting,
          trackPath: currentSession.currentTrackPath,
          channelSwapEnabled: currentSession.channelSwapEnabled,
          error: currentSession.playbackError,
        );
      }),
    );
    final isPlaying = view.playing;
    final currentTrack = provider.trackByPath(view.trackPath);
    final displayName =
        currentTrack?.displayName ??
        path.basenameWithoutExtension(view.trackPath);
    final screenSize = MediaQuery.sizeOf(context);
    final isTinyWindow = screenSize.width < 300 || screenSize.height < 300;

    final blurEnabled = ref.watch(
      settingsStateProvider.select(
        (s) => s.valueOrNull?.uiBlurEffectEnabled ?? true,
      ),
    );
    final currentAlpha = blurEnabled ? (isDark ? 0.72 : 0.80) : 0.92;

    Widget buildCardBody() => Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(cardRadius),
        onTap: onOpen,
        child: Ink(
          height: 74,
          decoration: BoxDecoration(
            color: (isDark ? cs.surfaceBright : cs.surfaceContainerHigh)
                .withValues(alpha: currentAlpha),
            borderRadius: BorderRadius.circular(cardRadius),
            border: Border.all(
              color: cs.outlineVariant.withValues(alpha: isDark ? 0.24 : 0.42),
            ),
            boxShadow: isTinyWindow
                ? null
                : [
                    BoxShadow(
                      color: cs.shadow.withValues(
                        alpha: isPlaying ? 0.18 : 0.12,
                      ),
                      blurRadius: isPlaying ? 28 : 22,
                      spreadRadius: -7,
                      offset: const Offset(0, 14),
                    ),
                    BoxShadow(
                      color: cs.primary.withValues(
                        alpha: isPlaying ? 0.06 : 0.03,
                      ),
                      blurRadius: 14,
                      spreadRadius: -10,
                      offset: const Offset(0, 8),
                    ),
                  ],
          ),
          child: compact
              ? Center(
                  child: _ActiveSessionCover(
                    sessionId: session.id,
                    track: currentTrack,
                    coverPathFuture: coverPathFuture,
                  ),
                )
              : _buildCardContent(
                  context,
                  cs,
                  isPlaying,
                  view,
                  currentTrack,
                  displayName,
                ),
        ),
      ),
    );

    return Semantics(
      button: true,
      label: displayName,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(cardRadius),
        child: blurEnabled
            ? BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                child: buildCardBody(),
              )
            : buildCardBody(),
      ),
    );
  }

  Widget _buildCardContent(
    BuildContext context,
    ColorScheme cs,
    bool isPlaying,
    ({
      bool channelSwapEnabled,
      String? error,
      bool loading,
      bool playing,
      String trackPath,
    })
    view,
    MusicTrack? currentTrack,
    String displayName,
  ) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 8, 4),
          child: Row(
            children: [
              _ActiveSessionCover(
                sessionId: session.id,
                track: currentTrack,
                coverPathFuture: coverPathFuture,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _ActiveSessionTitleSubtitle(
                  key: ValueKey('${session.id}:${view.trackPath}'),
                  session: session,
                  provider: provider,
                  displayName: displayName,
                  playbackError: view.error,
                ),
              ),
              const SizedBox(width: 8),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _ActiveSessionPlayPauseButton(
                    isPlaying: isPlaying,
                    isLoading: view.loading,
                    enabled: view.trackPath.isNotEmpty && !view.loading,
                    onPressed: () {
                      AppInteractionFeedback.trigger(
                        AppInteractionFeedbackType.confirmation,
                      );
                      provider.toggleSessionPlayPause(session.id);
                    },
                  ),
                  Consumer(
                    builder: (context, ref, child) {
                      final settings = ref.watch(subtitleSettingsProvider);
                      final showSub = settings.isGlobalEnabled(session.id);
                      if (!showSub && !view.channelSwapEnabled) {
                        return const SizedBox.shrink();
                      }
                      return Padding(
                        padding: const EdgeInsets.only(top: 1),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (showSub)
                              Icon(
                                Icons.subtitles_rounded,
                                size: 10,
                                color: cs.primary,
                              ),
                            if (showSub && view.channelSwapEnabled)
                              const SizedBox(width: 2),
                            if (view.channelSwapEnabled)
                              Icon(
                                Icons.swap_horiz_rounded,
                                size: 10,
                                color: cs.primary,
                              ),
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
    required this.isLoading,
    required this.enabled,
    required this.onPressed,
  });

  final bool isPlaying;
  final bool isLoading;
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
              duration: const Duration(milliseconds: 120),
              transitionBuilder: (child, animation) {
                return ScaleTransition(
                  scale: Tween<double>(begin: 0.4, end: 1.0).animate(
                    CurvedAnimation(
                      parent: animation,
                      curve: Curves.easeOutBack,
                    ),
                  ),
                  child: FadeTransition(opacity: animation, child: child),
                );
              },
              child: isLoading
                  ? SizedBox(
                      key: const ValueKey('loading'),
                      width: 26,
                      height: 26,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: cs.primary,
                      ),
                    )
                  : Icon(
                      isPlaying
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      key: ValueKey(isPlaying),
                      size: 38,
                      color: isPlaying ? cs.primary : cs.onSurface,
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
    required this.playbackError,
  });

  final PlaybackSession session;
  final AudioProvider provider;
  final String displayName;
  final String? playbackError;

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
  }

  @override
  void didUpdateWidget(covariant _ActiveSessionTitleSubtitle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      unawaited(_positionSub?.cancel());
      _positionSub = null;
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
    unawaited(_positionSub?.cancel());
    _positionSub = null;
    if (_subtitleTrack != null || _subtitleText != null) {
      setState(() {
        _subtitleTrack = null;
        _subtitleText = null;
      });
    }
    widget.provider.subtitleTrackForPath(trackPath).then((track) {
      if (!mounted || _loadedPath != trackPath) return;
      _subtitleTrack = track;
      if (track != null) {
        _bindPosition();
      }
      _updateSubtitleText(widget.session.position);
    });
  }

  void _updateSubtitleText(Duration position) {
    if (_subtitleTrack == null) return;
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
    final i18n = context.watch<AppLanguageProvider>();
    final secondaryText = widget.playbackError == null
        ? _subtitleText
        : i18n.tr('playback_failed_retry');
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LibraryLikeTwoLineMarqueeText(
          text: widget.displayName,
          style:
              Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w800,
                fontSize: 14,
                height: 1.08,
              ) ??
              const TextStyle(),
        ),
        if (secondaryText != null) ...[
          const SizedBox(height: 2),
          Text(
            secondaryText,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: widget.playbackError == null
                  ? cs.onSurfaceVariant
                  : cs.error,
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

class _ActiveSessionCover extends ConsumerWidget {
  const _ActiveSessionCover({
    required this.sessionId,
    required this.track,
    required this.coverPathFuture,
  });

  final String sessionId;
  final MusicTrack? track;
  final Future<String?> coverPathFuture;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = ref.read(audioProviderFacadeProvider);
    final cs = Theme.of(context).colorScheme;

    Widget fallback({bool hideIcon = false}) {
      return CoverFallbackArtwork(
        seed: track?.displayName ?? track?.path ?? sessionId,
        showIcon: !hideIcon,
        compact: true,
        iconSize: 24,
      );
    }

    return SizedBox(
      width: 58,
      height: 58,
      child: Material(
        type: MaterialType.transparency,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: track?.remoteCoverUrl?.trim().isNotEmpty == true
            ? RetryingNetworkImage(
                url: track!.remoteCoverUrl!.trim(),
                fit: BoxFit.cover,
                cacheWidth: (58 * MediaQuery.devicePixelRatioOf(context))
                    .round(),
                loadingBuilder: (context, child, loadingProgress) =>
                    loadingProgress == null
                    ? child
                    : CoverLoadingArtwork(
                        placeholder: fallback(hideIcon: true),
                        size: 28,
                        strokeWidth: 2.6,
                        color: cs.primary,
                      ),
                fallbackBuilder: (_) => fallback(),
              )
            : AsyncCoverImage(
                future: coverPathFuture,
                initialPath: provider.resolvedCoverPathForTrack(track),
                retryFutureBuilder: () =>
                    _sessionCoverFutureForTrack(provider, track),
                fallbackBuilder: (_) => fallback(),
                loadingBuilder: (_) => CoverLoadingArtwork(
                  placeholder: fallback(hideIcon: true),
                  size: 28,
                  strokeWidth: 2.6,
                  color: cs.primary,
                ),
                imageBuilder: (context, coverPath) {
                  final dpr = MediaQuery.devicePixelRatioOf(context);
                  return RetryingFileImage(
                    path: coverPath,
                    cacheWidth: (58 * dpr).round(),
                    fit: BoxFit.cover,
                    fallbackBuilder: (_) => fallback(),
                  );
                },
              ),
      ),
    );
  }
}
