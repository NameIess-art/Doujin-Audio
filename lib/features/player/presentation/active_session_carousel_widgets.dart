part of 'active_session_carousel.dart';

class _ActiveSessionCard extends ConsumerWidget {
  const _ActiveSessionCard({
    required this.session,
    required this.position,
    required this.count,
    required this.coverPathFuture,
    required this.onOpen,
    this.compact = false,
  });

  final PlaybackSessionSnapshot session;
  final int position;
  final int count;
  final Future<String?> coverPathFuture;
  final VoidCallback onOpen;
  final bool compact;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    const cardHeight = 56.0;
    const coverDistance = 4.0;
    const coverDimension = cardHeight - 2 * coverDistance;
    const coverRadius = LibraryLikeCardMetrics.coverRadius;
    const cardRadius = coverRadius + coverDistance;
    const contentPadding = EdgeInsets.fromLTRB(3, 3, 6, 3);

    final view = ref.watch(
      playbackStateProvider.select((value) {
        final playbackState = value.value;
        final currentSession =
            playbackState?.activeSessions.firstWhere(
              (candidate) => candidate.id == session.id,
              orElse: () => session,
            ) ??
            session;
        return (
          playing: currentSession.playbackRequested,
          loading:
              currentSession.isPlaybackLoading &&
              currentSession.playbackRequested,
          trackPath: currentSession.currentTrackPath,
          channelSwapEnabled: currentSession.channelSwapEnabled,
          audioEffects: currentSession.audioEffects,
          speed: currentSession.speed,
          error: currentSession.playbackError,
        );
      }),
    );
    final isPlaying = view.playing;
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final library = ref.read(libraryFacadeProvider);
    final currentTrack = ref
        .read(audioPathCoordinatorProvider)
        .sessionTrackForPath(session.id, view.trackPath);
    final displayName =
        currentTrack?.displayName ??
        path.basenameWithoutExtension(view.trackPath);
    final resolvedCoverPath = library.resolvedPlaybackCoverPathForTrack(
      currentTrack,
    );
    final showCover = shouldShowPlaylistCoverArtwork(
      currentTrack,
      resolvedCoverPath,
    );
    final screenSize = MediaQuery.sizeOf(context);
    final isTinyWindow = screenSize.width < 300 || screenSize.height < 300;

    final blurEnabled = ref.watch(
      settingsStateProvider.select((s) => s.value?.uiBlurEffectEnabled ?? true),
    );

    Widget buildCardBody(bool useBlur) => Material(
      color: Colors.transparent,
      child: InkWell(
        excludeFromSemantics: true,
        borderRadius: BorderRadius.circular(cardRadius),
        onTap: onOpen,
        child: Ink(
          height: cardHeight,
          decoration: BoxDecoration(
            color: (isDark ? cs.surfaceContainer : cs.surfaceContainerHigh)
                .withValues(alpha: useBlur ? (isDark ? 0.72 : 0.78) : 1.0),
            borderRadius: BorderRadius.circular(cardRadius),
            border: Border.all(
              color: cs.outlineVariant.withValues(alpha: isDark ? 0.24 : 0.42),
            ),
            boxShadow: isTinyWindow
                ? null
                : [
                    BoxShadow(
                      color: cs.shadow.withValues(
                        alpha: isPlaying ? 0.16 : 0.10,
                      ),
                      blurRadius: isPlaying ? 16 : 12,
                      spreadRadius: -4,
                      offset: const Offset(0, 6),
                    ),
                    BoxShadow(
                      color: cs.primary.withValues(
                        alpha: isPlaying ? 0.05 : 0.02,
                      ),
                      blurRadius: 10,
                      spreadRadius: -6,
                      offset: const Offset(0, 4),
                    ),
                  ],
          ),
          child: compact
              ? (showCover
                    ? Center(
                        child: _ActiveSessionCover(
                          sessionId: session.id,
                          track: currentTrack,
                          coverPathFuture: coverPathFuture,
                          dimension: coverDimension,
                        ),
                      )
                    : _buildCardContent(
                        context,
                        cs,
                        isPlaying,
                        view,
                        currentTrack,
                        displayName,
                        i18n: i18n,
                        showCover: false,
                        coverDimension: coverDimension,
                        contentPadding: const EdgeInsets.fromLTRB(
                          14,
                          coverDistance,
                          6,
                          coverDistance,
                        ),
                      ))
              : _buildCardContent(
                  context,
                  cs,
                  isPlaying,
                  view,
                  currentTrack,
                  displayName,
                  i18n: i18n,
                  showCover: showCover,
                  coverDimension: coverDimension,
                  contentPadding: showCover
                      ? contentPadding
                      : const EdgeInsets.fromLTRB(
                          14,
                          coverDistance,
                          6,
                          coverDistance,
                        ),
                ),
        ),
      ),
    );

    final useBlur = blurEnabled;
    return Semantics(
      container: true,
      value: '${position + 1} / $count',
      child: ClipRRect(
        key: ValueKey<String>('active_session_card_${session.id}'),
        borderRadius: BorderRadius.circular(cardRadius),
        child: useBlur
            ? BackdropFilter(
                key: ValueKey('active_session_blur_${session.id}'),
                filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                child: buildCardBody(useBlur),
              )
            : buildCardBody(useBlur),
      ),
    );
  }

  Widget _buildCardContent(
    BuildContext context,
    ColorScheme cs,
    bool isPlaying,
    ({
      AudioEffectsState audioEffects,
      bool channelSwapEnabled,
      String? error,
      bool loading,
      bool playing,
      double speed,
      String trackPath,
    })
    view,
    MusicTrack? currentTrack,
    String displayName, {
    required AppLanguageProvider i18n,
    required bool showCover,
    required double coverDimension,
    required EdgeInsets contentPadding,
  }) {
    final asmrBlue = AppDesignTokens.of(context).asmrAccent;
    final activeColor = currentTrack?.remoteMetadataKind == 'asmr.one'
        ? asmrBlue
        : cs.primary;
    final hasAsmrOnePlaybackError =
        view.error != null && currentTrack?.remoteMetadataKind == 'asmr.one';

    return Padding(
      padding: contentPadding,
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              button: true,
              label: i18n.tr('open_playback_details'),
              onTap: onOpen,
              child: Row(
                children: [
                  if (showCover) ...[
                    _ActiveSessionCover(
                      sessionId: session.id,
                      track: currentTrack,
                      coverPathFuture: coverPathFuture,
                      dimension: coverDimension,
                    ),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _ActiveSessionTitleSubtitle(
                          key: ValueKey('${session.id}:${view.trackPath}'),
                          session: session,
                          displayName: displayName,
                          playbackError: view.error,
                          isLoading: view.loading,
                          useAsmrOneErrorText: hasAsmrOnePlaybackError,
                        ),
                        _ActiveSessionProgressStrip(
                          session: session,
                          activeColor: activeColor,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 4),
          Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Consumer(
                builder: (context, ref, child) {
                  return _ActiveSessionPlayPauseButton(
                    showPauseIcon: isPlaying,
                    isLoading: view.loading,
                    enabled: view.trackPath.isNotEmpty,
                    activeColor: activeColor,
                    semanticLabel: i18n.tr(
                      view.loading
                          ? 'playback_loading'
                          : view.error != null
                          ? 'retry_playback'
                          : (isPlaying ? 'pause' : 'play'),
                    ),
                    onPressed: () {
                      AppInteractionFeedback.trigger(
                        AppInteractionFeedbackType.confirmation,
                      );
                      ref
                          .read(playbackFacadeProvider)
                          .toggleSessionPlayPause(session.id);
                    },
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ActiveSessionPlayPauseButton extends StatelessWidget {
  const _ActiveSessionPlayPauseButton({
    required this.showPauseIcon,
    required this.isLoading,
    required this.enabled,
    required this.activeColor,
    required this.semanticLabel,
    required this.onPressed,
  });

  final bool showPauseIcon;
  final bool isLoading;
  final bool enabled;
  final Color activeColor;
  final String semanticLabel;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      enabled: enabled,
      label: semanticLabel,
      child: Tooltip(
        message: semanticLabel,
        child: SizedBox.square(
          dimension: 40,
          child: Material(
            color: Colors.transparent,
            child: InkResponse(
              onTap: enabled ? onPressed : null,
              containedInkWell: true,
              radius: 20,
              customBorder: const CircleBorder(),
              child: Center(
                child: AnimatedSwitcher(
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : AppDesignTokens.of(context).motionFast,
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
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.2,
                            color: activeColor,
                          ),
                        )
                      : Icon(
                          showPauseIcon
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          key: ValueKey(showPauseIcon),
                          size: 30,
                          color: showPauseIcon ? activeColor : cs.onSurface,
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ActiveSessionTitleSubtitle extends ConsumerStatefulWidget {
  const _ActiveSessionTitleSubtitle({
    super.key,
    required this.session,
    required this.displayName,
    required this.playbackError,
    required this.isLoading,
    required this.useAsmrOneErrorText,
  });

  final PlaybackSessionSnapshot session;
  final String displayName;
  final String? playbackError;
  final bool isLoading;
  final bool useAsmrOneErrorText;

  @override
  ConsumerState<_ActiveSessionTitleSubtitle> createState() =>
      _ActiveSessionTitleSubtitleState();
}

class _ActiveSessionTitleSubtitleState
    extends ConsumerState<_ActiveSessionTitleSubtitle> {
  late final PlaybackPositionUiGate _positionGate;
  final SubtitleTextCache _subtitleTextCache = SubtitleTextCache();
  SubtitleTrack? _subtitleTrack;
  String? _subtitleText;
  String? _loadedPath;

  @override
  void initState() {
    super.initState();
    _positionGate = PlaybackPositionUiGate(
      session: widget.session,
      includeBufferedPosition: false,
    )..addListener(_handlePositionTick);
    _loadSubtitleTrack();
  }

  @override
  void didUpdateWidget(covariant _ActiveSessionTitleSubtitle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      _positionGate.updateSession(widget.session);
    }
    if (_loadedPath != widget.session.currentTrackPath) {
      _loadSubtitleTrack();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _positionGate.tickerModeEnabled = TickerMode.valuesOf(context).enabled;
  }

  @override
  void dispose() {
    _positionGate
      ..removeListener(_handlePositionTick)
      ..dispose();
    super.dispose();
  }

  void _handlePositionTick() {
    _updateSubtitleText(_positionGate.value.position);
  }

  void _loadSubtitleTrack() {
    final trackPath = widget.session.currentTrackPath;
    _loadedPath = trackPath;
    _subtitleTextCache.clear();
    if (_subtitleTrack != null || _subtitleText != null) {
      setState(() {
        _subtitleTrack = null;
        _subtitleText = null;
      });
    }
    ref.read(playbackSubtitleServiceProvider).load(trackPath).then((track) {
      if (!mounted || _loadedPath != trackPath) return;
      _subtitleTrack = track;
      _subtitleTextCache.clear();
      _updateSubtitleText(_positionGate.value.position);
    });
  }

  void _updateSubtitleText(Duration position) {
    if (_subtitleTrack == null) return;
    final nextText = _subtitleTextCache.resolve(
      trackPath: widget.session.currentTrackPath,
      position: position,
      track: _subtitleTrack,
    );
    if (_subtitleText == nextText) return;
    setState(() {
      _subtitleText = nextText;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final secondaryText = widget.playbackError == null
        ? (widget.isLoading ? i18n.tr('playback_loading') : _subtitleText)
        : widget.useAsmrOneErrorText
        ? localizedPlaybackErrorText(
            i18n,
            widget.playbackError,
            useAsmrOneText: true,
          )
        : localizedPlaybackErrorText(i18n, widget.playbackError);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Theme.of(context).platform == TargetPlatform.android
            ? Text(
                widget.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      fontSize: 13.5,
                      height: 1.12,
                    ) ??
                    const TextStyle(),
              )
            : LibraryLikeMarqueeLine(
                text: widget.displayName,
                style:
                    Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      fontSize: 13.5,
                      height: 1.12,
                    ) ??
                    const TextStyle(),
              ),
        if (secondaryText != null) ...[
          const SizedBox(height: 1.5),
          Text(
            secondaryText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: widget.playbackError == null
                  ? cs.onSurfaceVariant
                  : cs.error,
              fontWeight: FontWeight.w600,
              fontSize: 10.5,
              height: 1.15,
            ),
          ),
        ],
      ],
    );
  }
}

class _ActiveSessionProgressStrip extends StatefulWidget {
  const _ActiveSessionProgressStrip({
    required this.session,
    required this.activeColor,
  });

  final PlaybackSessionSnapshot session;
  final Color activeColor;

  @override
  State<_ActiveSessionProgressStrip> createState() =>
      _ActiveSessionProgressStripState();
}

class _ActiveSessionProgressStripState
    extends State<_ActiveSessionProgressStrip> {
  late final PlaybackPositionUiGate _positionGate;

  @override
  void initState() {
    super.initState();
    _positionGate = PlaybackPositionUiGate(
      session: widget.session,
      includeBufferedPosition: false,
    )..addListener(_handlePositionTick);
  }

  @override
  void didUpdateWidget(covariant _ActiveSessionProgressStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session == widget.session) return;
    _positionGate.updateSession(widget.session);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _positionGate.tickerModeEnabled = TickerMode.valuesOf(context).enabled;
  }

  @override
  void dispose() {
    _positionGate
      ..removeListener(_handlePositionTick)
      ..dispose();
    super.dispose();
  }

  void _handlePositionTick() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return RepaintBoundary(child: _buildProgressStrip(cs));
  }

  Widget _buildProgressStrip(ColorScheme cs) {
    final snapshot = _positionGate.value;
    final duration = snapshot.duration;
    if (duration == null || duration.inMilliseconds <= 0) {
      return const SizedBox(height: 2.5);
    }
    final fraction = snapshot.position.inMilliseconds / duration.inMilliseconds;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2.5),
        child: SizedBox(
          height: 2.5,
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
                            widget.activeColor,
                            widget.activeColor.withValues(alpha: 0.82),
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
    );
  }
}

class _ActiveSessionCover extends ConsumerWidget {
  const _ActiveSessionCover({
    required this.sessionId,
    required this.track,
    required this.coverPathFuture,
    required this.dimension,
  });

  final String sessionId;
  final MusicTrack? track;
  final Future<String?> coverPathFuture;
  final double dimension;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final library = ref.read(libraryFacadeProvider);
    final coverCacheWidth = coverCacheWidthForLogicalSize(
      logicalWidth: dimension,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      resolution: ref.watch(
        settingsStateProvider.select(
          (s) => s.value?.coverImageResolution ?? CoverImageResolution.balanced,
        ),
      ),
    );

    return SizedBox.square(
      key: ValueKey<String>('active_session_cover_$sessionId'),
      dimension: dimension,
      child: Material(
        type: MaterialType.transparency,
        borderRadius: BorderRadius.circular(LibraryLikeCardMetrics.coverRadius),
        clipBehavior: Clip.antiAlias,
        child: AsyncLocalCoverImage(
          future: coverPathFuture,
          initialPath: library.resolvedPlaybackCoverPathForTrack(track),
          retryFutureBuilder: () => _sessionCoverFutureForTrack(library, track),
          seed: track?.displayName ?? track?.path ?? sessionId,
          cacheWidth: coverCacheWidth,
          useDefaultCacheWidth: false,
          fit: BoxFit.cover,
          displayMode: CoverImageDisplayMode.fill,
          compact: true,
          iconSize: 24,
        ),
      ),
    );
  }
}
