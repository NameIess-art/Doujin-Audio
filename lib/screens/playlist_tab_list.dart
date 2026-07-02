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

class _SessionListCard extends StatelessWidget {
  const _SessionListCard({
    required this.sessionId,
    required this.cardState,
    required this.track,
    required this.coverPath,
    required this.coverCacheWidth,
    required this.showSubtitles,
    required this.provider,
    required this.index,
    required this.cardPositionsLocked,
    required this.onOpen,
  });

  final String sessionId;
  final PlaylistSessionCardState cardState;
  final MusicTrack? track;
  final String? coverPath;
  final int? coverCacheWidth;
  final bool showSubtitles;
  final AudioProvider provider;
  final int index;
  final bool cardPositionsLocked;
  final VoidCallback onOpen;

  void _confirmRemoveSession(BuildContext context) {
    provider.removeSession(sessionId);
    ProviderScope.containerOf(
      context,
    ).read(subtitleSettingsProvider.notifier).resetForSession(sessionId);
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
    final displayName =
        track?.displayName ??
        path.basenameWithoutExtension(cardState.trackPath);
    final currentTrack = track;
    final rootFolderName = track?.remoteMetadataKind == 'asmr.one'
        ? ''
        : provider.getRootFolderName(cardState.trackPath);
    final folderName = rootFolderName.isNotEmpty
        ? rootFolderName
        : (currentTrack != null && !currentTrack.isSingle)
        ? currentTrack.groupTitle
        : i18n.tr('imported_files');
    final isPlaying = cardState.isPlaying;

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isAsmrOne = track?.remoteMetadataKind == 'asmr.one';
    final tokens = AppDesignTokens.of(context);
    final asmrBlue = tokens.asmrAccent;
    final localPlayRose = cs.primary;

    final baseBgColor = isAsmrOne ? tokens.asmrSurface : cs.surfaceContainerLow;

    final highlightColor = isAsmrOne
        ? asmrBlue.withValues(alpha: isDark ? 0.18 : 0.14)
        : localPlayRose.withValues(alpha: isDark ? 0.16 : 0.12);
    final activeColor = isAsmrOne ? asmrBlue : localPlayRose;
    final showCover = shouldShowPlaylistCoverArtwork(track, coverPath);

    final cardShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(LibraryLikeCardMetrics.cardRadius),
      side: BorderSide(
        color: isPlaying
            ? activeColor.withValues(alpha: isDark ? 0.34 : 0.28)
            : cs.outlineVariant.withValues(alpha: isDark ? 0.26 : 0.42),
      ),
    );

    return SwipeRevealCard(
      key: ValueKey(sessionId),
      margin: const EdgeInsets.only(bottom: 6),
      shape: cardShape,
      color: activeColor,
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
            child: DecoratedBox(
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
                    onOpen();
                  },
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 7, 10, 6),
                    child: Row(
                      children: [
                        if (showCover) ...[
                          _SessionCoverThumbnail(
                            sessionId: sessionId,
                            track: track,
                            coverPath: coverPath,
                            coverCacheWidth: coverCacheWidth,
                          ),
                          const SizedBox(width: 14),
                        ],
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
                                      cardState.loopMode,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: isPlaying
                                      ? i18n.tr('pause')
                                      : i18n.tr('play'),
                                  onPressed: cardState.isLoading
                                      ? null
                                      : () {
                                          AppInteractionFeedback.trigger(
                                            AppInteractionFeedbackType
                                                .selection,
                                          );
                                          provider.toggleSessionPlayPause(
                                            sessionId,
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
                                        scale:
                                            Tween<double>(
                                              begin: 0.4,
                                              end: 1.0,
                                            ).animate(
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
                                    child: cardState.isLoading
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
                                if (cardState.playbackError != null)
                                  Text(
                                    i18n.tr('playback_failed_retry'),
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(color: cs.error),
                                  ),
                                _SessionFeatureBadges(
                                  channelSwapEnabled:
                                      cardState.channelSwapEnabled,
                                  showSubtitles: showSubtitles,
                                  activeColor: isAsmrOne
                                      ? asmrBlue
                                      : localPlayRose,
                                ),
                              ],
                            ),
                            if (!cardPositionsLocked) ...[
                              const SizedBox(width: 6),
                              ReorderableDragStartListener(
                                index: index,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 8,
                                    horizontal: 4,
                                  ),
                                  color: Colors.transparent,
                                  child: const Icon(
                                    Icons.drag_handle_rounded,
                                    size: 24,
                                  ),
                                ),
                              ),
                            ],
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

class _SessionFeatureBadges extends StatelessWidget {
  const _SessionFeatureBadges({
    required this.channelSwapEnabled,
    required this.showSubtitles,
    required this.activeColor,
  });

  final bool channelSwapEnabled;
  final bool showSubtitles;
  final Color activeColor;

  @override
  Widget build(BuildContext context) {
    if (!showSubtitles && !channelSwapEnabled) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 1),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showSubtitles)
            Icon(Icons.subtitles_rounded, size: 10, color: activeColor),
          if (showSubtitles && channelSwapEnabled) const SizedBox(width: 2),
          if (channelSwapEnabled)
            Icon(Icons.swap_horiz_rounded, size: 10, color: activeColor),
        ],
      ),
    );
  }
}
