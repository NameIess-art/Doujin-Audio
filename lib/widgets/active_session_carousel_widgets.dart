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

    final style = ref.watch(
      settingsStateProvider.select(
        (s) =>
            s.valueOrNull?.bottomNavigationStyle ??
            BottomNavigationStyle.capsule,
      ),
    );
    final isBar = style == BottomNavigationStyle.bar;
    final cardRadius = isBar ? 0.0 : 20.0;

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
          playing: currentSession.effectivePlaying,
          loading: currentSession.isLoading,
          trackPath: currentSession.currentTrackPath,
          channelSwapEnabled: currentSession.channelSwapEnabled,
          audioEffects: currentSession.audioEffects,
          speed: currentSession.speed,
          error: currentSession.playbackError,
        );
      }),
    );
    final isPlaying = view.playing;
    final i18n = context.read<AppLanguageProvider>();
    final currentTrack = provider.trackByPath(view.trackPath);
    final displayName =
        currentTrack?.displayName ??
        path.basenameWithoutExtension(view.trackPath);
    final resolvedCoverPath = provider.resolvedPlaybackCoverPathForTrack(
      currentTrack,
    );
    final showCover = shouldShowPlaylistCoverArtwork(
      currentTrack,
      resolvedCoverPath,
    );
    final screenSize = MediaQuery.sizeOf(context);
    final isTinyWindow = screenSize.width < 300 || screenSize.height < 300;

    final blurEnabled = ref.watch(
      settingsStateProvider.select(
        (s) => s.valueOrNull?.uiBlurEffectEnabled ?? true,
      ),
    );

    Widget buildCardBody(bool useBlur) => Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(cardRadius),
        onTap: onOpen,
        child: Ink(
          height: 74,
          decoration: BoxDecoration(
            color: (isDark ? cs.surfaceBright : cs.surfaceContainerHigh)
                .withValues(alpha: useBlur ? (isDark ? 0.80 : 0.86) : 1.0),
            borderRadius: BorderRadius.circular(cardRadius),
            border: isBar
                ? Border(
                    top: BorderSide(
                      color: cs.outlineVariant.withValues(
                        alpha: isDark ? 0.24 : 0.42,
                      ),
                    ),
                  )
                : Border.all(
                    color: cs.outlineVariant.withValues(
                      alpha: isDark ? 0.24 : 0.42,
                    ),
                  ),
            boxShadow: (isTinyWindow || isBar)
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
              ? (showCover
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
                        showCover: false,
                      ))
              : _buildCardContent(
                  context,
                  cs,
                  isPlaying,
                  view,
                  currentTrack,
                  displayName,
                  showCover: showCover,
                ),
        ),
      ),
    );

    final useBlur = blurEnabled;
    return Semantics(
      button: true,
      label: displayName,
      value: isPlaying
          ? i18n.tr('playback_state_playing')
          : i18n.tr('playback_state_paused'),
      selected: isPlaying,
      child: ClipRRect(
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
    required bool showCover,
  }) {
    final asmrBlue = AppDesignTokens.of(context).asmrAccent;
    final activeColor = currentTrack?.remoteMetadataKind == 'asmr.one'
        ? asmrBlue
        : cs.primary;
    final hasAsmrOnePlaybackError =
        view.error != null && currentTrack?.remoteMetadataKind == 'asmr.one';

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 5, 8, 5),
      child: Row(
        children: [
          if (showCover) ...[
            _ActiveSessionCover(
              sessionId: session.id,
              track: currentTrack,
              coverPathFuture: coverPathFuture,
            ),
            const SizedBox(width: 12),
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
                  provider: provider,
                  displayName: displayName,
                  playbackError: view.error,
                  useAsmrOneErrorText: hasAsmrOnePlaybackError,
                ),
                _ActiveSessionProgressStrip(
                  session: session,
                  activeColor: activeColor,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Consumer(
                builder: (context, ref, child) {
                  final settings = ref.watch(subtitleSettingsProvider);
                  final showSub = settings.isGlobalEnabled(session.id);
                  final featureIcons = sessionFeatureBadgeIcons(
                    showSubtitles: showSub,
                    channelSwapEnabled: view.channelSwapEnabled,
                    audioEffects: view.audioEffects,
                    speed: view.speed,
                  );
                  return SessionFeatureBadgeStack(
                    featureIcons: featureIcons,
                    color: activeColor,
                    child: _ActiveSessionPlayPauseButton(
                      showPauseIcon: isPlaying,
                      isLoading: view.loading,
                      enabled: view.trackPath.isNotEmpty && !view.loading,
                      activeColor: activeColor,
                      semanticLabel: context.read<AppLanguageProvider>().tr(
                        view.loading
                            ? 'playback_loading'
                            : (isPlaying ? 'pause' : 'play'),
                      ),
                      onPressed: () {
                        AppInteractionFeedback.trigger(
                          AppInteractionFeedbackType.confirmation,
                        );
                        provider.toggleSessionPlayPause(session.id);
                      },
                    ),
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
                          width: 26,
                          height: 26,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: activeColor,
                          ),
                        )
                      : Icon(
                          showPauseIcon
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          key: ValueKey(showPauseIcon),
                          size: 38,
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

class _ActiveSessionTitleSubtitle extends StatefulWidget {
  const _ActiveSessionTitleSubtitle({
    super.key,
    required this.session,
    required this.provider,
    required this.displayName,
    required this.playbackError,
    required this.useAsmrOneErrorText,
  });

  final PlaybackSession session;
  final AudioProvider provider;
  final String displayName;
  final String? playbackError;
  final bool useAsmrOneErrorText;

  @override
  State<_ActiveSessionTitleSubtitle> createState() =>
      _ActiveSessionTitleSubtitleState();
}

class _ActiveSessionTitleSubtitleState
    extends State<_ActiveSessionTitleSubtitle> {
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
    widget.provider.subtitleTrackForPath(trackPath).then((track) {
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
    final i18n = context.watch<AppLanguageProvider>();
    final secondaryText = widget.playbackError == null
        ? _subtitleText
        : widget.useAsmrOneErrorText
        ? _asmrOnePlaybackErrorText(i18n, widget.playbackError)
        : i18n.tr('playback_failed_retry');
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Theme.of(context).platform == TargetPlatform.android
            ? Text(
                widget.displayName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style:
                    Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                      height: 1.08,
                    ) ??
                    const TextStyle(),
              )
            : LibraryLikeMarqueeLine(
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

String _asmrOnePlaybackErrorText(AppLanguageProvider i18n, String? error) {
  final normalized = error?.toLowerCase() ?? '';
  final isNetworkError =
      normalized.contains('network') ||
      normalized.contains('socket') ||
      normalized.contains('connection') ||
      normalized.contains('timeout') ||
      normalized.contains('timed out') ||
      normalized.contains('host') ||
      normalized.contains('http') ||
      normalized.contains('dns') ||
      normalized.contains('tls') ||
      normalized.contains('ssl') ||
      normalized.contains('internet');
  return i18n.tr(
    isNetworkError
        ? 'asmr_playback_network_failed_retry'
        : 'asmr_playback_load_failed_retry',
  );
}

class _ActiveSessionProgressStrip extends StatefulWidget {
  const _ActiveSessionProgressStrip({
    required this.session,
    required this.activeColor,
  });

  final PlaybackSession session;
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
      return const SizedBox(height: 3);
    }
    final fraction = snapshot.position.inMilliseconds / duration.inMilliseconds;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: SizedBox(
          height: 3,
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
  });

  final String sessionId;
  final MusicTrack? track;
  final Future<String?> coverPathFuture;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = ref.read(audioProviderFacadeProvider);
    final coverCacheWidth = coverCacheWidthForResolution(
      ref.watch(
        settingsStateProvider.select(
          (s) =>
              s.valueOrNull?.coverImageResolution ??
              CoverImageResolution.balanced,
        ),
      ),
    );

    final bottomNavStyle = ref.watch(
      settingsStateProvider.select(
        (s) =>
            s.valueOrNull?.bottomNavigationStyle ??
            BottomNavigationStyle.capsule,
      ),
    );
    final borderRadius = bottomNavStyle == BottomNavigationStyle.capsule
        ? 16.0
        : 10.0;

    return SizedBox(
      width: 64,
      height: 64,
      child: Material(
        type: MaterialType.transparency,
        borderRadius: BorderRadius.circular(borderRadius),
        clipBehavior: Clip.antiAlias,
        child: AsyncLocalCoverImage(
          future: coverPathFuture,
          initialPath: provider.resolvedPlaybackCoverPathForTrack(track),
          retryFutureBuilder: () =>
              _sessionCoverFutureForTrack(provider, track),
          seed: track?.displayName ?? track?.path ?? sessionId,
          cacheWidth: coverCacheWidth,
          useDefaultCacheWidth: coverCacheWidth != null,
          fit: BoxFit.cover,
          compact: true,
          iconSize: 24,
        ),
      ),
    );
  }
}
