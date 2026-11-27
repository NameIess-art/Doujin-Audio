part of 'active_session_carousel.dart';

class _ActiveSessionCard extends ConsumerWidget {
  const _ActiveSessionCard({
    required this.session,
    required this.position,
    required this.count,

    required this.onOpen,
    this.compact = false,
    this.embedded = false,
    this.expandedDockWidth,
    this.retainDockPages = false,
    this.dockCollapsed = false,
    this.circularCover = false,
    this.isPlaybackRaised = false,
    required this.isRoutedDock,
  });

  final PlaybackSessionSnapshot session;
  final int position;
  final int count;

  final ValueChanged<BuildContext> onOpen;
  final bool compact;
  final bool embedded;
  final double? expandedDockWidth;
  final bool retainDockPages;
  final bool dockCollapsed;
  final bool circularCover;
  final bool isPlaybackRaised;
  final bool isRoutedDock;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final tokens = AppDesignTokens.of(context);
    final floatingSurface = appFloatingSurfaceColor(cs);

    final cardHeight = embedded ? kActiveSessionCarouselDockHeight : 56.0;
    const coverDistance = 4.0;
    final coverDimension = cardHeight - 2 * coverDistance;
    const coverRadius = LibraryLikeCardMetrics.coverRadius;
    final cardRadius = embedded ? cardHeight / 2 : coverRadius + coverDistance;
    final cardBorderRadius = (embedded && isPlaybackRaised)
        ? const BorderRadius.only(
            topLeft: Radius.circular(LibraryLikeCardMetrics.cardRadius),
            bottomLeft: Radius.circular(LibraryLikeCardMetrics.cardRadius),
            topRight: Radius.circular(kActiveSessionCarouselDockHeight / 2),
            bottomRight: Radius.circular(kActiveSessionCarouselDockHeight / 2),
          )
        : BorderRadius.circular(cardRadius);
    final contentPadding = embedded
        ? const EdgeInsets.fromLTRB(4, 4, 6, 4)
        : const EdgeInsets.fromLTRB(3, 3, 6, 3);

    final view = ref.watch(
      playbackSessionProvider(session.id).select((value) {
        final currentSession = value ?? session;
        return (
          playing: currentSession.playbackRequested,
          loading: currentSession.isPlaybackLoading,
          trackPath: currentSession.currentTrackPath,
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
    final coverCache = library.coverArtworkCacheService;
    final coverScope =
        coverCache.coverSearchKeyForTrack(
          currentTrack,
          trackPath: view.trackPath,
        ) ??
        view.trackPath;
    final folderScope = currentTrack == null
        ? null
        : coverCache.coverScopeFolderForTrack(currentTrack);
    ref.watch(
      coverGenerationProvider.select(
        (_) => (
          coverCache.revisionForScope(coverScope),
          folderScope == null ? null : coverCache.revisionForScope(folderScope),
        ),
      ),
    );
    final displayName =
        currentTrack?.displayName ??
        path.basenameWithoutExtension(view.trackPath);
    var showCover = true;
    if (!embedded && !circularCover) {
      showCover = shouldShowPlaylistCoverArtwork(
        currentTrack,
        library.resolvedPlaybackCoverPathForTrack(currentTrack),
      );
      if (!showCover && currentTrack != null) {
        // Audio-only cards still need to discover artwork before showing it.
        ref
            .read(libraryCoverUiControllerProvider)
            .deferredPlaybackCover(currentTrack, context: context)
            .ignore();
      }
    }
    final screenSize = MediaQuery.sizeOf(context);
    final isTinyWindow = screenSize.width < 300 || screenSize.height < 300;
    final activeColor = session.playbackQueue?.colorValue != null
        ? appReadableAccentColor(
            Color(session.playbackQueue!.colorValue!),
            floatingSurface,
          )
        : cs.primary;

    if (circularCover) {
      return Semantics(
        button: true,
        value: '${position + 1} / $count',
        child: Center(
          child: SizedBox.square(
            key: ValueKey<String>('active_session_card_${session.id}'),
            dimension: kActiveSessionCarouselDockHeight,
            child: Material(
              type: MaterialType.transparency,
              shape: const CircleBorder(),
              child: AppEntryInkWell(
                customBorder: const CircleBorder(),
                onTap: () => onOpen(context),
                child: _ActiveSessionCover(
                  isRoutedDock: isRoutedDock,
                  sessionId: session.id,
                  session: session,
                  track: currentTrack,

                  dimension: kActiveSessionCarouselDockHeight,
                  activeColor: activeColor,
                ),
              ),
            ),
          ),
        ),
      );
    }

    final cardBody = Material(
      key: embedded
          ? null
          : ValueKey<String>('active_session_card_${session.id}'),
      color: Colors.transparent,
      child: AppEntryInkWell(
        key: embedded
            ? ValueKey<String>(
                'active_session_ink_${session.id}_${dockCollapsed ? 'collapsed' : 'expanded'}',
              )
            : null,
        excludeFromSemantics: true,
        customBorder: embedded ? const StadiumBorder() : null,
        borderRadius: embedded ? null : BorderRadius.circular(cardRadius),
        onTap: () => onOpen(context),
        child: Ink(
          height: cardHeight,
          decoration: BoxDecoration(
            color: embedded ? Colors.transparent : floatingSurface,
            borderRadius: BorderRadius.circular(cardRadius),
            border: embedded
                ? null
                : Border.all(
                    color: appOverlayBorderColor(cs, tokens, elevated: true),
                  ),
            boxShadow: embedded || isTinyWindow
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
          child: dockCollapsed
              ? Padding(
                  padding: const EdgeInsets.only(left: coverDistance),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _ActiveSessionCover(
                      isRoutedDock: isRoutedDock,
                      sessionId: session.id,
                      session: session,
                      track: currentTrack,

                      dimension: coverDimension,
                      activeColor: activeColor,
                    ),
                  ),
                )
              : compact
              ? (showCover
                    ? Center(
                        child: _ActiveSessionCover(
                          isRoutedDock: isRoutedDock,
                          sessionId: session.id,
                          session: session,
                          track: currentTrack,

                          dimension: coverDimension,
                          activeColor: activeColor,
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

    return Semantics(
      container: true,
      value: '${position + 1} / $count',
      child: AppPressScale(
        enabled: !embedded,
        pressedScale: 0.985,
        releaseCurve: kAppSpringCurve,
        child: embedded
            ? ClipRRect(
                key: ValueKey<String>('active_session_card_${session.id}'),
                borderRadius: cardBorderRadius,
                child: cardBody,
              )
            : cardBody,
      ),
    );
  }

  Widget _buildCardContent(
    BuildContext context,
    ColorScheme cs,
    bool isPlaying,
    ({String? error, bool loading, bool playing, String trackPath}) view,
    MusicTrack? currentTrack,
    String displayName, {
    required AppLanguageProvider i18n,
    required bool showCover,
    required double coverDimension,
    required EdgeInsets contentPadding,
  }) {
    final activeColor = session.playbackQueue?.colorValue != null
        ? appReadableAccentColor(
            Color(session.playbackQueue!.colorValue!),
            appFloatingSurfaceColor(cs),
          )
        : cs.primary;
    final hasAsmrOnePlaybackError =
        view.error != null && (currentTrack?.isRemoteAsmr ?? false);
    Widget titleSubtitle = _ActiveSessionTitleSubtitle(
      key: ValueKey('${session.id}:${view.trackPath}'),
      session: session,
      displayName: displayName,
      playbackError: view.error,
      isLoading: view.loading,
      useAsmrOneErrorText: hasAsmrOnePlaybackError,
    );
    if (expandedDockWidth case final width?) {
      final textWidth =
          (width -
                  contentPadding.horizontal -
                  (showCover ? coverDimension + 10 : 0) -
                  4 -
                  _ActiveSessionPlayPauseButton.dimension)
              .clamp(0.0, double.infinity);
      // Keep the marquee viewport stable while the dock animates its width.
      titleSubtitle = ClipRect(
        child: OverflowBox(
          key: const ValueKey('active_session_title_overflow_box'),
          alignment: AlignmentDirectional.centerStart,
          fit: OverflowBoxFit.deferToChild,
          minWidth: textWidth,
          maxWidth: textWidth,
          child: titleSubtitle,
        ),
      );
    }

    final content = Padding(
      padding: contentPadding,
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              button: true,
              label: i18n.tr('open_playback_details'),
              onTap: () => onOpen(context),
              child: Row(
                children: [
                  if (showCover) ...[
                    _ActiveSessionCover(
                      isRoutedDock: isRoutedDock,
                      sessionId: session.id,
                      session: session,
                      track: currentTrack,

                      dimension: coverDimension,
                      activeColor: activeColor,
                    ),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        titleSubtitle,
                        if (!compact && count >= 2) const SizedBox(height: 6),
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
                    isLoading: view.loading && view.error == null,
                    hasError: view.error != null,
                    enabled: view.trackPath.isNotEmpty,
                    showTooltip: !embedded,
                    activeColor: activeColor,
                    semanticLabel: i18n.tr(
                      view.error != null
                          ? 'retry_playback'
                          : view.loading
                          ? 'playback_loading'
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
    if (!retainDockPages) return content;
    return LayoutBuilder(
      builder: (context, constraints) {
        // The capsule clips the controls as it narrows. Fix the mounted row to
        // its expanded target width so the dock animation only clips the outer
        // viewport instead of re-laying out the entire row on every frame.
        final targetWidth = expandedDockWidth;
        final width = targetWidth != null
            ? (constraints.maxWidth <= kActiveSessionCarouselDockHeight
                  ? targetWidth
                  : constraints.maxWidth)
            : (constraints.maxWidth < _expandedDockThreshold
                  ? _expandedDockThreshold
                  : constraints.maxWidth);
        return OverflowBox(
          alignment: Alignment.centerLeft,
          minWidth: width,
          maxWidth: width,
          child: MarqueePauseScope(
            isPaused: constraints.maxWidth <= kActiveSessionCarouselDockHeight,
            child: content,
          ),
        );
      },
    );
  }
}

class _ActiveSessionIndicator extends StatelessWidget {
  const _ActiveSessionIndicator({
    required this.sessions,
    required this.indexListenable,
    this.opacity = 1.0,
  });

  final List<PlaybackSessionSnapshot> sessions;
  final ValueListenable<int> indexListenable;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    const dotHeight = 3.5;
    const highlightWidth = 10.0;
    final colors = Theme.of(context).colorScheme;
    final shape = BorderRadius.circular(2);
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 180);
    return ValueListenableBuilder<int>(
      valueListenable: indexListenable,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final _ in sessions)
            SizedBox(
              width: highlightWidth,
              child: Center(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.onSurfaceVariant.withValues(
                      alpha: 0.38 * opacity,
                    ),
                    borderRadius: shape,
                  ),
                  child: const SizedBox(width: 4, height: dotHeight),
                ),
              ),
            ),
        ],
      ),
      builder: (context, index, dots) {
        final count = sessions.length;
        final active = index % count;
        final queueColor = sessions[active].playbackQueue?.colorValue;
        final highlightColor = queueColor == null
            ? colors.primary
            : appReadableAccentColor(
                Color(queueColor),
                appFloatingSurfaceColor(colors),
              );
        return Semantics(
          key: const ValueKey('active_session_indicator'),
          label: '${active + 1} / $count',
          child: Stack(
            children: [
              dots!,
              Positioned.fill(
                child: AnimatedAlign(
                  alignment: AlignmentDirectional(
                    2 * active / (count - 1) - 1,
                    0,
                  ),
                  duration: duration,
                  curve: kAppSpringCurve,
                  child: AnimatedContainer(
                    duration: duration,
                    curve: kAppSpringCurve,
                    width: highlightWidth,
                    height: dotHeight,
                    decoration: BoxDecoration(
                      color: highlightColor.withValues(
                        alpha: highlightColor.a * opacity,
                      ),
                      borderRadius: shape,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ActiveSessionPlayPauseButton extends StatelessWidget {
  static const double dimension = 40;

  const _ActiveSessionPlayPauseButton({
    required this.showPauseIcon,
    required this.isLoading,
    required this.hasError,
    required this.enabled,
    required this.showTooltip,
    required this.activeColor,
    required this.semanticLabel,
    required this.onPressed,
  });

  final bool showPauseIcon;
  final bool isLoading;
  final bool hasError;
  final bool enabled;
  final bool showTooltip;
  final Color activeColor;
  final String semanticLabel;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final button = IconButton(
      onPressed: enabled ? onPressed : null,
      style: appIconButtonStyle(
        IconButton.styleFrom(
          fixedSize: const Size.square(dimension),
          minimumSize: const Size.square(dimension),
          maximumSize: const Size.square(dimension),
          padding: EdgeInsets.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          foregroundColor: showPauseIcon ? activeColor : cs.onSurface,
        ),
      ),
      icon: AppPlaybackIconTransition(
        child: isLoading
            ? SizedBox(
                key: const ValueKey('loading'),
                width: 22,
                height: 22,
                child: RepaintBoundary(
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    color: activeColor,
                  ),
                ),
              )
            : hasError
            ? const Icon(
                Icons.refresh_rounded,
                key: ValueKey('retry'),
                size: 28,
              )
            : Icon(
                showPauseIcon ? Icons.pause_rounded : Icons.play_arrow_rounded,
                key: ValueKey(showPauseIcon),
                size: 30,
              ),
      ),
    );
    return Semantics(
      button: true,
      enabled: enabled,
      label: semanticLabel,
      child: showTooltip
          ? Tooltip(message: semanticLabel, child: button)
          : button,
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
  late final PlaybackSubtitleService _subtitleService;
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
    _subtitleService = ref.read(playbackSubtitleServiceProvider)
      ..addListener(_handleSubtitleServiceChanged);
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
    _subtitleService.removeListener(_handleSubtitleServiceChanged);
    _positionGate
      ..removeListener(_handlePositionTick)
      ..dispose();
    super.dispose();
  }

  void _handlePositionTick() {
    _updateSubtitleText(_positionGate.value.position);
  }

  void _handleSubtitleServiceChanged() {
    if (!mounted) return;
    final trackPath = widget.session.currentTrackPath;
    final subtitles = _subtitleService;
    if (subtitles.hasResult(trackPath)) {
      final updated = subtitles.trackSync(trackPath);
      if (!identical(_subtitleTrack, updated) ||
          _subtitleTrack?.offset != updated?.offset) {
        _subtitleTrack = updated;
        _subtitleTextCache.clear();
        _updateSubtitleText(_positionGate.value.position);
      }
    } else {
      _loadSubtitleTrack();
    }
  }

  void _loadSubtitleTrack() {
    final trackPath = widget.session.currentTrackPath;
    _loadedPath = trackPath;
    _subtitleTextCache.clear();
    final subtitles = _subtitleService;
    if (subtitles.hasResult(trackPath)) {
      _subtitleTrack = subtitles.trackSync(trackPath);
      _subtitleText = null;
      _updateSubtitleText(_positionGate.value.position);
      return;
    }
    if (_subtitleTrack != null || _subtitleText != null) {
      setState(() {
        _subtitleTrack = null;
        _subtitleText = null;
      });
    }
    subtitles.load(trackPath).then((track) {
      if (!mounted || _loadedPath != trackPath) return;
      _subtitleTrack = track;
      _subtitleTextCache.clear();
      _updateSubtitleText(_positionGate.value.position);
    });
  }

  void _updateSubtitleText(Duration position) {
    final track = _subtitleTrack;
    final nextText = track == null
        ? null
        : _subtitleTextCache.resolve(
            trackPath: widget.session.currentTrackPath,
            position: position,
            track: track,
          );
    if (_subtitleText == nextText) return;
    setState(() {
      _subtitleText = nextText;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isAndroid = defaultTargetPlatform == TargetPlatform.android;
    final cs = theme.colorScheme;
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final secondaryText = widget.playbackError == null
        ? (widget.isLoading
              ? i18n.tr('playback_loading')
              : _subtitleText?.replaceAll('\n', ' '))
        : widget.useAsmrOneErrorText
        ? localizedPlaybackErrorText(
            i18n,
            widget.playbackError,
            useAsmrOneText: true,
          )
        : localizedPlaybackErrorText(i18n, widget.playbackError);
    final title = widget.displayName.replaceAll('\n', ' ');
    final titleStyle = theme.textTheme.titleSmall?.copyWith(
      fontWeight: FontWeight.w800,
      fontSize: 13.5,
      height: 1.12,
    );
    final showSecondary = secondaryText != null && secondaryText.isNotEmpty;
    final secondaryStyle = theme.textTheme.bodySmall?.copyWith(
      color: widget.playbackError == null ? cs.onSurfaceVariant : cs.error,
      fontWeight: FontWeight.w600,
      fontSize: 10.5,
      height: 1.15,
    );
    final showCue =
        showSecondary && widget.playbackError == null && !widget.isLoading;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isAndroid)
          Text(
            title,
            style: titleStyle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          )
        else
          SizedBox(
            width: double.infinity,
            height: 16,
            child: MarqueeText(text: title, style: titleStyle, scrollSpeed: 26),
          ),
        const SizedBox(height: 1.5),
        ExcludeSemantics(
          excluding: !showSecondary,
          child: Opacity(
            opacity: showSecondary ? 1 : 0,
            child: showCue && !isAndroid
                ? MarqueeText(
                    text: secondaryText,
                    style: secondaryStyle,
                    pauseDuration: const Duration(milliseconds: 450),
                    scrollSpeed: 26,
                    edgePadding: 0,
                  )
                : Text(
                    showSecondary ? secondaryText : ' ',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: secondaryStyle,
                  ),
          ),
        ),
      ],
    );
  }
}

class _ActiveSessionCover extends ConsumerStatefulWidget {
  const _ActiveSessionCover({
    required this.sessionId,
    this.session,
    required this.track,
    required this.isRoutedDock,
    this.dimension,
    this.activeColor,
  });

  final String sessionId;
  final PlaybackSessionSnapshot? session;
  final MusicTrack? track;
  final bool isRoutedDock;

  final double? dimension;
  final Color? activeColor;

  @override
  ConsumerState<_ActiveSessionCover> createState() =>
      _ActiveSessionCoverState();
}

class _ActiveSessionCoverState extends ConsumerState<_ActiveSessionCover> {
  bool _tickerEnabled = true;
  (String, Object)? _lastPrewarmKey;
  Future<String?>? _observedCoverFuture;
  int _coverFutureGeneration = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
  }

  @override
  void dispose() {
    cancelDetailCoverPrewarm(this);
    super.dispose();
  }

  void _schedulePrewarmIfNeeded({
    required String? initialPath,
    required Future<String?> coverFuture,
    required CoverImageResolution resolution,
  }) {
    if (widget.track?.isVideo == true) {
      cancelDetailCoverPrewarm(this);
      _lastPrewarmKey = null;
      return;
    }
    void scheduleForPath(String? resolvedPath) {
      if (!mounted || resolvedPath == null || resolvedPath.isEmpty) return;
      final key = (resolvedPath, resolution);
      if (_lastPrewarmKey == key) return;
      _lastPrewarmKey = key;
      scheduleDetailCoverPrewarm(
        ownerKey: this,
        coverPath: resolvedPath,
        resolution: resolution,
        isStillValid: () => mounted && _tickerEnabled,
      );
    }

    if (initialPath != null && initialPath.isNotEmpty) {
      scheduleForPath(initialPath);
      return;
    }
    if (identical(_observedCoverFuture, coverFuture)) return;
    _observedCoverFuture = coverFuture;
    final generation = ++_coverFutureGeneration;
    unawaited(
      coverFuture.then((resolvedPath) {
        if (!mounted || generation != _coverFutureGeneration) return;
        scheduleForPath(resolvedPath);
      }, onError: (_, _) {}),
    );
  }

  @override
  Widget build(BuildContext context) {
    final library = ref.read(libraryFacadeProvider);
    final cs = Theme.of(context).colorScheme;
    final effectiveColor = widget.activeColor ?? cs.primary;
    final d = widget.dimension ?? 48.0;
    final innerD = coverProgressInnerDimension(d);
    final resolution = ref.watch(coverImageResolutionProvider);
    final initialPath = library.resolvedPlaybackCoverPathForTrack(widget.track);
    final coverFuture = ref
        .read(libraryCoverUiControllerProvider)
        .deferredPlaybackCover(widget.track, context: context);
    _schedulePrewarmIfNeeded(
      initialPath: initialPath,
      coverFuture: coverFuture,
      resolution: resolution,
    );
    final coverCacheWidth = coverThumbnailCacheWidth(
      logicalWidth: d,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      resolution: resolution,
    );

    return SizedBox.square(
      key: ValueKey<String>('active_session_cover_${widget.sessionId}'),
      dimension: d,
      child: SessionCoverProgressRing(
        session: widget.session,
        sessionId: widget.sessionId,
        activeColor: effectiveColor,
        size: d,
        child: SessionCoverAnchor(
          sessionId: widget.sessionId,
          radius: innerD / 2,
          location: widget.isRoutedDock
              ? SessionCoverLocation.routedDock
              : SessionCoverLocation.dock,
          child: CoverArtworkFrame(
            borderRadius: BorderRadius.circular(innerD / 2),
            child: AsyncLocalCoverImage(
              onImageError:
                  library.coverArtworkCacheService.reportArtworkReadFailure,
              future: coverFuture,
              requestKey: (widget.sessionId, widget.track?.path),
              initialPath: initialPath,
              retryFutureBuilder: () =>
                  library.playbackCoverPathFutureForTrack(widget.track),
              cacheWidth: coverCacheWidth,
              useDefaultCacheWidth: false,
              deferLoadDuringInteraction: true,
              fit: BoxFit.cover,
            ),
          ),
        ),
      ),
    );
  }
}
