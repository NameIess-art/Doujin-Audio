part of 'playlist_tab.dart';

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

class _SessionListCard extends StatefulWidget {
  const _SessionListCard({
    required this.session,
    required this.provider,
    required this.onOpen,
  });

  final PlaybackSession session;
  final AudioProvider provider;
  final VoidCallback onOpen;

  @override
  State<_SessionListCard> createState() => _SessionListCardState();
}

class _SessionListCardState extends State<_SessionListCard>
    with SingleTickerProviderStateMixin {
  Future<String?>? _coverPathFuture;
  String? _lastTrackPath;
  int _lastCoverGeneration = -1;
  late final AnimationController _playPauseController;
  bool _wasPlaying = false;

  @override
  void initState() {
    super.initState();
    _wasPlaying = widget.session.state.playing;
    _playPauseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
      value: _wasPlaying ? 1.0 : 0.0,
    );
    _updateFutureIfNeeded();
  }

  @override
  void dispose() {
    _playPauseController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _SessionListCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateFutureIfNeeded();
  }

  void _updateFutureIfNeeded() {
    final trackPath = widget.session.currentTrackPath;
    final currentGen = widget.provider.coverGeneration;
    if (_lastTrackPath != trackPath || _lastCoverGeneration != currentGen) {
      _lastTrackPath = trackPath;
      _lastCoverGeneration = currentGen;
      final track = widget.provider.trackByPath(trackPath);
      _coverPathFuture = _coverFutureForTrack(widget.provider, track);
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
    final coverGeneration = context.select<AudioProvider, int>(
      (value) => value.coverGeneration,
    );
    final sessionView = context
        .select<
          AudioProvider,
          ({
            MusicTrack? track,
            String trackPath,
            SessionLoopMode loopMode,
            bool isLoading,
            bool isPlaying,
            bool channelSwapEnabled,
          })
        >((value) {
          final currentSession =
              value.sessionById(widget.session.id) ?? session;
          return (
            track: value.trackByPath(currentSession.currentTrackPath),
            trackPath: currentSession.currentTrackPath,
            loopMode: currentSession.loopMode,
            isLoading: currentSession.isLoading,
            isPlaying: currentSession.state.playing,
            channelSwapEnabled: currentSession.channelSwapEnabled,
          );
        });
    if (_lastCoverGeneration != coverGeneration) {
      _lastCoverGeneration = coverGeneration;
      _updateFutureIfNeeded();
    }
    final track = sessionView.track;
    final displayName =
        track?.displayName ??
        path.basenameWithoutExtension(sessionView.trackPath);
    final rootFolderName = provider.getRootFolderName(sessionView.trackPath);
    final folderName = rootFolderName.isNotEmpty
        ? rootFolderName
        : (track != null && !track.isSingle)
        ? track.groupTitle
        : i18n.tr('imported_files');

    final isPlaying = sessionView.isPlaying;
    if (_wasPlaying != isPlaying) {
      _wasPlaying = isPlaying;
      if (isPlaying) {
        _playPauseController.forward();
      } else {
        _playPauseController.reverse();
      }
    }
    
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isAsmrOne = track?.remoteMetadataKind == 'asmr.one';
    final asmrBlue = isDark ? const Color(0xFF60A5FA) : const Color(0xFF1D4ED8);
    final asmrBlueContainer = isDark
        ? const Color(0xFF1E3A8A)
        : const Color(0xFFDBEAFE);
    final localPlayRose = isDark
        ? const Color(0xFFF472B6)
        : const Color(0xFFDB2777);

    final baseBgColor = isAsmrOne
        ? (isDark ? const Color(0xFF121625) : const Color(0xFFF2F6FA))
        : (isDark ? const Color(0xFF2C1A22) : const Color(0xFFFAF2F5));

    final highlightColor = isAsmrOne
        ? (isDark
            ? asmrBlueContainer.withValues(alpha: 0.35)
            : const Color(0xFF93C5FD).withValues(alpha: 0.45))
        : (isDark
            ? const Color(0xFF851A46).withValues(alpha: 0.55)
            : const Color(0xFFE898BA).withValues(alpha: 0.5));

    final cardShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
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
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                gradient: isPlaying
                    ? LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          highlightColor,
                          baseBgColor,
                          baseBgColor,
                          baseBgColor,
                        ],
                      )
                    : null,
              ),
              child: Semantics(
                button: true,
                label: displayName,
                child: InkWell(
                  onTap: () {
                    HapticFeedback.lightImpact();
                    widget.onOpen();
                  },
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 7, 10, 6),
                    child: Row(
                      children: [
                        _SessionCoverThumbnail(
                          track: track,
                          coverPathFuture: _coverPathFuture!,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              MarqueeText(
                                text: folderName,
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
                                      fontWeight: FontWeight.w900,
                                      fontSize: 14,
                                      height: 1.12,
                                    ),
                              ),
                              const SizedBox(height: 4),
                              SizedBox(
                                width: double.infinity,
                                child: _SessionMetaChip(
                                  icon: Icons.repeat_rounded,
                                  text: _loopModeSummary(
                                    context,
                                    sessionView.loopMode,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              onPressed: sessionView.isLoading
                                  ? null
                                  : () {
                                      Feedback.forTap(context);
                                      provider.toggleSessionPlayPause(
                                        session.id,
                                      );
                                    },
                              style: IconButton.styleFrom(
                                foregroundColor: isPlaying
                                    ? (isAsmrOne ? asmrBlue : localPlayRose)
                                    : cs.onSurface,
                                minimumSize: const Size(44, 44),
                                maximumSize: const Size(44, 44),
                                padding: EdgeInsets.zero,
                              ),
                              icon: AnimatedSwitcher(
                                duration: const Duration(milliseconds: 150),
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
                                child: sessionView.isLoading
                                    ? SizedBox(
                                        key: const ValueKey('loading'),
                                        width: 26,
                                        height: 26,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2.5,
                                          color: isPlaying
                                              ? (isAsmrOne
                                                    ? asmrBlue
                                                    : localPlayRose)
                                              : cs.onSurface,
                                        ),
                                      )
                                    : AnimatedIcon(
                                        icon: AnimatedIcons.play_pause,
                                        progress: _playPauseController,
                                        key: const ValueKey('play_pause_anim'),
                                        size: 26,
                                      ),
                              ),
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
