part of 'playlist_tab.dart';

class _PlaylistLoadingSkeleton extends StatelessWidget {
  const _PlaylistLoadingSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        for (var index = 0; index < 4; index++)
          Container(
            height: 88,
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.fromLTRB(12, 7, 10, 6),
            decoration: BoxDecoration(
              color: cs.surfaceContainerLow,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: cs.outlineVariant.withValues(alpha: 0.32),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 96,
                  height: 72,
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 94,
                        height: 9,
                        decoration: BoxDecoration(
                          color: cs.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(5),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        width: double.infinity,
                        height: 13,
                        decoration: BoxDecoration(
                          color: cs.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(7),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        width: 136,
                        height: 10,
                        decoration: BoxDecoration(
                          color: cs.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(5),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: cs.surfaceContainerHigh,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _SessionsEmptyState extends StatelessWidget {
  const _SessionsEmptyState({
    super.key,
    required this.bottomInset,
    this.topInset = 16,
  });

  final double bottomInset;
  final double topInset;

  @override
  Widget build(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(24, topInset, 24, bottomInset),
      child: Column(
        children: [
          const SizedBox(height: 20),
          Container(
            width: double.infinity,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(28),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  cs.surfaceContainerHigh.withValues(alpha: 0.6),
                  cs.surfaceContainerLow.withValues(alpha: 0.4),
                ],
              ),
              border: Border.all(
                color: cs.outlineVariant.withValues(alpha: 0.1),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 42, 24, 42),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          cs.primaryContainer,
                          cs.primaryContainer.withValues(alpha: 0.8),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(
                          color: cs.primary.withValues(alpha: 0.12),
                          blurRadius: 20,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: Icon(
                      Icons.queue_music_rounded,
                      size: 36,
                      color: cs.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    i18n.tr('no_active_sessions'),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    i18n.tr('go_library_hint'),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: cs.onSurfaceVariant,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SessionListCard extends ConsumerStatefulWidget {
  const _SessionListCard({
    required this.session,
    required this.provider,
    required this.onOpen,
  });

  final PlaybackSession session;
  final AudioProvider provider;
  final VoidCallback onOpen;

  @override
  ConsumerState<_SessionListCard> createState() => _SessionListCardState();
}

class _SessionListCardState extends ConsumerState<_SessionListCard> {
  Future<String?>? _coverPathFuture;
  String? _lastTrackPath;
  int _lastCoverGeneration = -1;
  bool _lastCoverWasCachedOnly = true;

  @override
  void initState() {
    super.initState();
    _updateFutureIfNeeded(cachedOnly: true);
  }

  @override
  void didUpdateWidget(covariant _SessionListCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateFutureIfNeeded(cachedOnly: true);
  }

  void _updateFutureIfNeeded({
    required bool cachedOnly,
    String? trackPath,
    int? coverGeneration,
  }) {
    final effectiveTrackPath = trackPath ?? widget.session.currentTrackPath;
    final currentGen = coverGeneration ?? widget.provider.coverGeneration;
    if (_lastTrackPath != effectiveTrackPath ||
        _lastCoverGeneration != currentGen ||
        _lastCoverWasCachedOnly && !cachedOnly) {
      _lastTrackPath = effectiveTrackPath;
      _lastCoverGeneration = currentGen;
      _lastCoverWasCachedOnly = cachedOnly;
      final track = widget.provider.trackByPath(effectiveTrackPath);
      _coverPathFuture = _coverFutureForTrack(
        widget.provider,
        track,
        cachedOnly: cachedOnly,
      );
    }
  }

  void _confirmRemoveSession(BuildContext context) {
    widget.provider.removeSession(widget.session.id);
    ProviderScope.containerOf(context)
        .read(subtitleSettingsProvider.notifier)
        .resetForSession(widget.session.id);
  }

  String _loopModeSummary(BuildContext context, SessionLoopMode mode) {
    final i18n = context.read<AppLanguageProvider>();
    if (mode == SessionLoopMode.single) return i18n.tr('single_loop');
    final scope =
        mode == SessionLoopMode.crossRandom ||
            mode == SessionLoopMode.crossSequential
        ? i18n.tr('cross_folder')
        : i18n.tr('current_folder');
    final order =
        mode == SessionLoopMode.crossRandom ||
            mode == SessionLoopMode.folderRandom
        ? i18n.tr('random_order')
        : i18n.tr('sequential_order');
    return '$order - $scope';
  }

  @override
  Widget build(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    final cs = Theme.of(context).colorScheme;
    final session = widget.session;
    final provider = widget.provider;
    final uiState = ref.watch(playlistSessionCardUiProvider(widget.session.id));
    final int coverGeneration =
        uiState?.coverGeneration ?? ref.watch(coverGenerationProvider);
    final trackPath = uiState?.trackPath ?? session.currentTrackPath;
    final sessionView = (
      track: provider.trackByPath(trackPath),
      trackPath: trackPath,
      loopMode: uiState?.loopMode ?? session.loopMode,
      isLoading: uiState?.isLoading ?? session.isLoading,
      isPlaying: uiState?.isPlaying ?? session.effectivePlaying,
      channelSwapEnabled:
          uiState?.channelSwapEnabled ?? session.channelSwapEnabled,
      playbackError: uiState?.playbackError ?? session.playbackError,
    );
    if (_lastTrackPath != trackPath ||
        _lastCoverGeneration != coverGeneration) {
      _lastCoverGeneration = coverGeneration;
      _updateFutureIfNeeded(
        cachedOnly: false,
        trackPath: trackPath,
        coverGeneration: coverGeneration,
      );
    }
    final track = sessionView.track;
    final displayName =
        track?.displayName ??
        path.basenameWithoutExtension(sessionView.trackPath);
    final rootFolderName = track?.remoteMetadataKind == 'asmr.one'
        ? ''
        : provider.getRootFolderName(sessionView.trackPath);
    final folderName = rootFolderName.isNotEmpty
        ? rootFolderName
        : (track != null && !track.isSingle)
        ? track.groupTitle
        : i18n.tr('imported_files');
    final isPlaying = sessionView.isPlaying;

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isAsmrOne = track?.remoteMetadataKind == 'asmr.one';
    final asmrBlue = isDark ? const Color(0xFF60A5FA) : const Color(0xFF1D4ED8);
    final localPlayRose = cs.primary;

    final baseBgColor = isAsmrOne
        ? (isDark ? const Color(0xFF181D2B) : const Color(0xFFF4F7FA))
        : cs.surfaceContainerLow;

    final highlightColor = isAsmrOne
        ? asmrBlue.withValues(alpha: isDark ? 0.18 : 0.14)
        : localPlayRose.withValues(alpha: isDark ? 0.16 : 0.12);
    final activeColor = isAsmrOne ? asmrBlue : localPlayRose;

    final cardShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(LibraryLikeCardMetrics.cardRadius),
      side: BorderSide(
        color: isPlaying
            ? activeColor.withValues(alpha: isDark ? 0.34 : 0.28)
            : cs.outlineVariant.withValues(alpha: isDark ? 0.26 : 0.42),
      ),
    );

    return SwipeRevealCard(
      key: ValueKey(session.id),
      margin: const EdgeInsets.only(bottom: 6),
      shape: cardShape,
      actionLabel: i18n.tr('remove'),
      removeTooltip: i18n.tr('remove_audio'),
      onRemove: () => _confirmRemoveSession(context),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 88),
        child: Material(
          color: Colors.transparent,
          child: Card(
            margin: EdgeInsets.zero,
            clipBehavior: Clip.antiAlias,
            shape: cardShape,
            color: isPlaying ? cs.surfaceContainerHigh : baseBgColor,
            elevation: 0,
            shadowColor: Colors.transparent,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(
                  LibraryLikeCardMetrics.cardRadius,
                ),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: isPlaying
                      ? [
                          highlightColor,
                          Colors.transparent,
                          Colors.transparent,
                          Colors.transparent,
                        ]
                      : [
                          Colors.transparent,
                          Colors.transparent,
                          Colors.transparent,
                          Colors.transparent,
                        ],
                ),
              ),
              child: Semantics(
                button: true,
                label: displayName,
                child: InkWell(
                  onTap: () {
                    AppInteractionFeedback.trigger(
                      AppInteractionFeedbackType.tap,
                    );
                    widget.onOpen();
                  },
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 7, 10, 6),
                    child: Row(
                      children: [
                        _SessionCoverThumbnail(
                          sessionId: session.id,
                          track: track,
                          coverPathFuture: _coverPathFuture!,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                folderName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: cs.onSurfaceVariant,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 12,
                                    ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                displayName,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 14,
                                      height: 1.12,
                                    ),
                              ),
                              const SizedBox(height: 4),
                              Wrap(
                                spacing: 10,
                                runSpacing: 2,
                                children: [
                                  _SessionMetaChip(
                                    icon: Icons.repeat_rounded,
                                    text: _loopModeSummary(
                                      context,
                                      sessionView.loopMode,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: isPlaying
                                  ? i18n.tr('pause')
                                  : i18n.tr('play'),
                              onPressed: sessionView.isLoading
                                  ? null
                                  : () {
                                      AppInteractionFeedback.trigger(
                                        AppInteractionFeedbackType.selection,
                                      );
                                      provider.toggleSessionPlayPause(
                                        session.id,
                                      );
                                    },
                              style: IconButton.styleFrom(
                                foregroundColor: isPlaying
                                    ? activeColor
                                    : cs.onSurface,
                                minimumSize: const Size(44, 44),
                                maximumSize: const Size(44, 44),
                                padding: EdgeInsets.zero,
                              ),
                              icon: AnimatedSwitcher(
                                duration: const Duration(milliseconds: 120),
                                transitionBuilder: (child, animation) {
                                  return ScaleTransition(
                                    scale: Tween<double>(begin: 0.4, end: 1.0)
                                        .animate(
                                          CurvedAnimation(
                                            parent: animation,
                                            curve: Curves.easeOutBack,
                                          ),
                                        ),
                                    child: FadeTransition(
                                      opacity: animation,
                                      child: child,
                                    ),
                                  );
                                },
                                child: sessionView.isLoading
                                    ? const SizedBox(
                                        key: ValueKey('loading'),
                                        width: 22,
                                        height: 22,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2.3,
                                        ),
                                      )
                                    : Icon(
                                        isPlaying
                                            ? Icons.pause_rounded
                                            : Icons.play_arrow_rounded,
                                        key: ValueKey(isPlaying),
                                        size: 28,
                                      ),
                              ),
                            ),
                            if (sessionView.playbackError != null)
                              Text(
                                i18n.tr('playback_failed_retry'),
                                style: Theme.of(context).textTheme.labelSmall
                                    ?.copyWith(color: cs.error),
                              ),
                            Consumer(
                              builder: (context, ref, child) {
                                final settings = ref.watch(
                                  subtitleSettingsProvider,
                                );
                                final showSub = settings.isGlobalEnabled(
                                  session.id,
                                );
                                if (!showSub &&
                                    !sessionView.channelSwapEnabled) {
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
                                          color: isAsmrOne
                                              ? asmrBlue
                                              : localPlayRose,
                                        ),
                                      if (showSub &&
                                          sessionView.channelSwapEnabled)
                                        const SizedBox(width: 2),
                                      if (sessionView.channelSwapEnabled)
                                        Icon(
                                          Icons.swap_horiz_rounded,
                                          size: 10,
                                          color: isAsmrOne
                                              ? asmrBlue
                                              : localPlayRose,
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
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
