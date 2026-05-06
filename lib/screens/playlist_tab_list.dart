part of 'playlist_tab.dart';

class _SessionsEmptyState extends StatelessWidget {
  const _SessionsEmptyState({required this.bottomInset});

  final double bottomInset;

  @override
  Widget build(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    final cs = Theme.of(context).colorScheme;
    return ListView(
      padding: EdgeInsets.fromLTRB(24, 16, 24, bottomInset),
      physics: const BouncingScrollPhysics(),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 58,
                  height: 58,
                  decoration: BoxDecoration(
                    color: cs.primaryContainer,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Icon(
                    Icons.queue_music_rounded,
                    size: 30,
                    color: cs.onPrimaryContainer,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  i18n.tr('no_active_sessions'),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  i18n.tr('go_library_hint'),
                  textAlign: TextAlign.center,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
      ],
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

class _SessionListCardState extends State<_SessionListCard> {
  Future<String?>? _coverPathFuture;
  String? _lastTrackPath;

  @override
  void initState() {
    super.initState();
    _updateFutureIfNeeded();
  }

  @override
  void didUpdateWidget(covariant _SessionListCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateFutureIfNeeded();
  }

  void _updateFutureIfNeeded() {
    final trackPath = widget.session.currentTrackPath;
    if (_lastTrackPath != trackPath) {
      _lastTrackPath = trackPath;
      final track = widget.provider.trackByPath(trackPath);
      _coverPathFuture = _coverFutureForTrack(widget.provider, track);
    }
  }

  void _confirmRemoveSession(BuildContext context) {
    widget.provider.removeSession(widget.session.id);
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
    final sessionView = context
        .select<
          AudioProvider,
          ({
            MusicTrack? track,
            String trackPath,
            SessionLoopMode loopMode,
            bool isLoading,
            bool isPlaying,
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
          );
        });
    final track = sessionView.track;
    final displayName =
        track?.displayName ??
        path.basenameWithoutExtension(sessionView.trackPath);
    final folderName = (track != null && !track.isSingle)
        ? track.groupTitle
        : i18n.tr('imported_files');

    final isPlaying = sessionView.isPlaying;
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
            color: isPlaying ? cs.surfaceContainerHigh : cs.surfaceContainerHigh,
            elevation: 0,
            shadowColor: Colors.transparent,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: isPlaying
                    ? Border.all(
                      color: cs.primary.withValues(alpha: 0.25),
                      width: 1.2,
                    )
                    : Border.all(
                      color: cs.outlineVariant.withValues(alpha: 0.15),
                      width: 0.5,
                    ),
                gradient: isPlaying
                    ? LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        cs.primaryContainer.withValues(alpha: 0.3),
                        cs.surfaceContainerHigh,
                        cs.surfaceContainerHigh,
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
                        coverPathFuture: _coverPathFuture!,
                        title: displayName,
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
                      IconButton(
                        onPressed: sessionView.isLoading
                            ? null
                            : () {
                                Feedback.forTap(context);
                                provider.toggleSessionPlayPause(session.id);
                              },
                        style: IconButton.styleFrom(
                          foregroundColor: isPlaying
                              ? cs.primary
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
                                scale: Tween<double>(begin: 0.92, end: 1)
                                    .animate(animation),
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
                                    color: isPlaying ? cs.primary : cs.onSurface,
                                  ),
                                )
                              : Icon(
                                  isPlaying
                                      ? Icons.pause_rounded
                                      : Icons.play_arrow_rounded,
                                  key: ValueKey(isPlaying),
                                  size: 26,
                                ),
                        ),
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
