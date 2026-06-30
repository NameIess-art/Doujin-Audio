part of 'playlist_tab.dart';

class _PlaybackQueueCard extends StatefulWidget {
  const _PlaybackQueueCard({
    required this.session,
    required this.provider,
    required this.index,
    required this.cardPositionsLocked,
    required this.onOpen,
    required this.onEdit,
  });

  final PlaybackSession session;
  final AudioProvider provider;
  final int index;
  final bool cardPositionsLocked;
  final VoidCallback onOpen;
  final VoidCallback onEdit;

  @override
  State<_PlaybackQueueCard> createState() => _PlaybackQueueCardState();
}

class _PlaybackQueueCardState extends State<_PlaybackQueueCard> {
  @override
  Widget build(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    final cs = Theme.of(context).colorScheme;
    final session = widget.session;
    final provider = widget.provider;
    final queue = session.playbackQueue!;
    final tracks = queue.expandedTracks;
    final activeColor = queue.colorValue == null
        ? cs.primary
        : Color(queue.colorValue!);
    final hasCustomColor = queue.colorValue != null;
    final isPlaying = session.effectivePlaying;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final coverTracks = queue.entries
        .where((entry) => entry.tracks.isNotEmpty)
        .map((entry) => entry.tracks.first)
        .take(4)
        .toList(growable: false);
    final currentTrack = tracks.isEmpty
        ? null
        : tracks[session.currentQueueIndex.clamp(0, tracks.length - 1)];
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(LibraryLikeCardMetrics.cardRadius),
      side: BorderSide(
        color: isPlaying
            ? activeColor.withValues(alpha: isDark ? 0.34 : 0.28)
            : hasCustomColor
            ? activeColor.withValues(alpha: isDark ? 0.28 : 0.22)
            : cs.outlineVariant.withValues(alpha: isDark ? 0.26 : 0.42),
      ),
    );
    return SwipeRevealCard(
      key: ValueKey(session.id),
      margin: const EdgeInsets.only(bottom: 6),
      shape: shape,
      color: activeColor,
      destructive: false,
      primaryActionIcon: Icons.edit_rounded,
      actionLabel: i18n.tr('edit'),
      removeTooltip: i18n.tr('edit_playback_queue'),
      onRemove: widget.onEdit,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 88),
        child: Card(
          margin: EdgeInsets.zero,
          elevation: 0,
          color: isPlaying
              ? cs.surfaceContainerHigh
              : hasCustomColor
              ? activeColor.withValues(alpha: isDark ? 0.12 : 0.08)
              : cs.surfaceContainerLow,
          shape: shape,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: widget.onOpen,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 7, 10, 6),
              child: Row(
                children: [
                  _QueueCoverGrid(provider: provider, tracks: coverTracks),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          queue.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                fontWeight: FontWeight.w800,
                                color: isPlaying ? activeColor : cs.onSurface,
                                fontSize: 14,
                              ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          currentTrack?.displayName ??
                              i18n.tr('empty_playback_queue'),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                fontWeight: FontWeight.w800,
                                fontSize: 14,
                                height: 1.12,
                              ),
                        ),
                      ],
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: session.effectivePlaying
                            ? i18n.tr('pause')
                            : i18n.tr('play'),
                        onPressed: tracks.isEmpty
                            ? null
                            : () {
                                AppInteractionFeedback.trigger(
                                  AppInteractionFeedbackType.selection,
                                );
                                provider.toggleSessionPlayPause(session.id);
                              },
                        style: IconButton.styleFrom(
                          foregroundColor: isPlaying ? activeColor : cs.onSurface,
                          minimumSize: const Size(44, 44),
                          maximumSize: const Size(44, 44),
                          padding: EdgeInsets.zero,
                        ),
                        icon: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 120),
                          transitionBuilder: (child, animation) {
                            return ScaleTransition(
                              scale: Tween<double>(begin: 0.4, end: 1.0).animate(
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
                          child: Icon(
                            isPlaying
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            key: ValueKey(isPlaying),
                            size: 28,
                          ),
                        ),
                      ),
                      if (!widget.cardPositionsLocked) ...[
                        const SizedBox(width: 4),
                        ReorderableDragStartListener(
                          index: widget.index,
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                            color: Colors.transparent,
                            child: const Icon(Icons.drag_handle_rounded, size: 24),
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
    );
  }
}

class _QueueCoverGrid extends StatelessWidget {
  const _QueueCoverGrid({required this.provider, required this.tracks});

  final AudioProvider provider;
  final List<MusicTrack> tracks;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: 96,
        height: 72,
        child: Column(
          children: [
            Expanded(
              child: Row(
                children: [
                  Expanded(child: _buildCell(context, 0)),
                  Expanded(child: _buildCell(context, 1)),
                ],
              ),
            ),
            Expanded(
              child: Row(
                children: [
                  Expanded(child: _buildCell(context, 2)),
                  Expanded(child: _buildCell(context, 3)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCell(BuildContext context, int index) {
    if (index >= tracks.length) {
      final cs = Theme.of(context).colorScheme;
      final isDark = Theme.of(context).brightness == Brightness.dark;
      return ColoredBox(
        color: cs.surfaceContainerHighest.withValues(alpha: isDark ? 0.4 : 0.6),
        child: Center(
          child: Icon(
            Icons.audiotrack_rounded,
            size: 18,
            color: cs.onSurfaceVariant.withValues(alpha: 0.35),
          ),
        ),
      );
    }
    final track = tracks[index];
    return _QueueTrackCover(
      key: ValueKey('$index:${track.path}'),
      provider: provider,
      track: track,
    );
  }
}

class _QueueTrackCover extends StatefulWidget {
  const _QueueTrackCover({
    super.key,
    required this.provider,
    required this.track,
  });

  final AudioProvider provider;
  final MusicTrack track;

  @override
  State<_QueueTrackCover> createState() => _QueueTrackCoverState();
}

class _QueueTrackCoverState extends State<_QueueTrackCover> {
  late Future<String?> _coverFuture;
  late int _coverGeneration;

  @override
  void initState() {
    super.initState();
    _bindCoverFuture();
  }

  @override
  void didUpdateWidget(covariant _QueueTrackCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.track.path != widget.track.path ||
        oldWidget.provider != widget.provider ||
        _coverGeneration != widget.provider.coverGeneration) {
      _bindCoverFuture();
    }
  }

  void _bindCoverFuture() {
    _coverGeneration = widget.provider.coverGeneration;
    _coverFuture = _coverFutureForTrack(widget.provider, widget.track);
  }

  @override
  Widget build(BuildContext context) {
    final track = widget.track;
    final coverCacheWidth = coverCacheWidthForResolution(
      context.select<AudioProvider, CoverImageResolution>(
        (provider) => provider.coverImageResolution,
      ),
    );
    return AsyncCoverImage(
      duration: Duration.zero,
      future: _coverFuture,
      initialPath: widget.provider.resolvedCoverPathForTrack(track),
      imageBuilder: (context, path) => RetryingFileImage(
        path: path,
        fit: BoxFit.cover,
        cacheWidth: coverCacheWidth,
        useDefaultCacheWidth: coverCacheWidth != null,
        fallbackBuilder: (_) => CoverFallbackArtwork(seed: track.displayName),
      ),
      fallbackBuilder: (_) => CoverFallbackArtwork(seed: track.displayName),
    );
  }
}

Future<void> showPlaybackQueueEditPanel(
  BuildContext context,
  String sessionId,
) {
  return _showPlaybackQueuePanel(
    context,
    panel: PlaybackQueueEditPage(sessionId: sessionId),
  );
}

Future<void> showPlaybackQueueColorPanel(
  BuildContext context,
  String sessionId,
) {
  return _showPlaybackQueuePanel(
    context,
    panel: _PlaybackQueueColorPanel(sessionId: sessionId),
  );
}

Future<void> _showPlaybackQueuePanel(
  BuildContext context, {
  required Widget panel,
}) {
  final i18n = context.read<AppLanguageProvider>();
  return showGeneralDialog<void>(
    context: context,
    barrierLabel: i18n.tr('close'),
    barrierDismissible: true,
    barrierColor: Colors.transparent,
    transitionDuration: kSecondaryOverlayConfig.transitionDuration,
    pageBuilder: (dialogContext, animation, secondaryAnimation) {
      final mediaSize = MediaQuery.sizeOf(dialogContext);
      final isDesktop = mediaSize.width >= 760;
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return Material(
        color: Colors.transparent,
        child: AnimatedBuilder(
          animation: curved,
          builder: (context, _) {
            final progress = curved.value.clamp(0.0, 1.0);
            return Stack(
              fit: StackFit.expand,
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => Navigator.of(context).maybePop(),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: kSecondaryOverlayConfig.scrimColor(
                          context,
                          progress,
                        ),
                      ),
                    ),
                  ),
                ),
                SafeArea(
                  child: FadeTransition(
                    opacity: curved,
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        isDesktop ? 28 : 16,
                        isDesktop ? 28 : 176,
                        isDesktop ? 28 : 16,
                        isDesktop ? 28 : 132,
                      ),
                      child: Align(
                        alignment: isDesktop
                            ? Alignment.center
                            : Alignment.topCenter,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: isDesktop ? 472 : 404,
                            maxHeight: 560,
                          ),
                          child: panel,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      );
    },
  );
}

class PlaybackQueueEditPage extends ConsumerWidget {
  const PlaybackQueueEditPage({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(playbackStateProvider);
    final provider = ref.read(audioProviderFacadeProvider);
    final session = provider.sessionById(sessionId);
    final queue = session?.playbackQueue;
    final i18n = context.watch<AppLanguageProvider>();
    if (queue == null) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainerLow.withValues(alpha: 0.96),
      elevation: 12,
      shadowColor: cs.shadow.withValues(alpha: 0.22),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(28),
        side: BorderSide(color: cs.primary.withValues(alpha: 0.45)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: cs.primaryContainer,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    Icons.edit_rounded,
                    color: cs.onPrimaryContainer,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    queue.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: i18n.tr('close'),
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                children: [
                  _queueEditTile(
                    context,
                    Icons.queue_music_rounded,
                    i18n.tr('edit_queue_audio'),
                    () => Navigator.of(context).push(
                      buildAppPageRoute<void>(
                        child: PlaybackQueueAudioEditPage(sessionId: sessionId),
                      ),
                    ),
                  ),
                  _queueEditTile(
                    context,
                    Icons.drive_file_rename_outline_rounded,
                    i18n.tr('edit_queue_name'),
                    () => _editQueueName(context, provider, queue.name),
                  ),
                  _queueEditTile(
                    context,
                    Icons.palette_outlined,
                    i18n.tr('edit_card_color'),
                    () => showPlaybackQueueColorPanel(context, sessionId),
                  ),
                  const SizedBox(height: 10),
                  _queueEditTile(
                    context,
                    Icons.delete_outline_rounded,
                    i18n.tr('remove_queue'),
                    () => _removeQueue(context, provider),
                    destructive: true,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _queueEditTile(
    BuildContext context,
    IconData icon,
    String title,
    VoidCallback onTap, {
    bool destructive = false,
  }) {
    final cs = Theme.of(context).colorScheme;
    final foreground = destructive ? cs.error : cs.onSurface;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: destructive
            ? cs.errorContainer.withValues(alpha: 0.18)
            : cs.surfaceContainerHigh.withValues(alpha: 0.44),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: destructive
                ? cs.error.withValues(alpha: 0.22)
                : cs.outlineVariant.withValues(alpha: 0.28),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: destructive
                        ? cs.errorContainer.withValues(alpha: 0.46)
                        : cs.primaryContainer.withValues(alpha: 0.62),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    icon,
                    size: 19,
                    color: destructive ? cs.error : cs.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: foreground,
                    ),
                  ),
                ),
                Icon(
                  destructive
                      ? Icons.delete_forever_outlined
                      : Icons.chevron_right_rounded,
                  size: 20,
                  color: foreground.withValues(alpha: 0.72),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _editQueueName(
    BuildContext context,
    AudioProvider provider,
    String currentName,
  ) async {
    final controller = TextEditingController(text: currentName);
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.read<AppLanguageProvider>().tr('edit_queue_name')),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(context.read<AppLanguageProvider>().tr('cancel')),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: Text(context.read<AppLanguageProvider>().tr('save')),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name?.isNotEmpty == true) {
      provider.renamePlaybackQueue(sessionId, name!);
    }
  }

  Future<void> _removeQueue(
    BuildContext context,
    AudioProvider provider,
  ) async {
    final i18n = context.read<AppLanguageProvider>();
    final confirmed = await showConfirmActionDialog(
      context: context,
      title: i18n.tr('remove_queue'),
      message: i18n.tr('remove_queue_confirm'),
      cancelLabel: i18n.tr('cancel'),
      confirmLabel: i18n.tr('remove'),
      icon: Icons.delete_outline_rounded,
    );
    if (!confirmed || !context.mounted) return;
    await provider.removeSession(sessionId);
    if (context.mounted) Navigator.of(context).pop();
  }
}

class PlaybackQueueAudioEditPage extends ConsumerWidget {
  const PlaybackQueueAudioEditPage({super.key, required this.sessionId});
  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(playbackStateProvider);
    final provider = ref.read(audioProviderFacadeProvider);
    final queue = provider.sessionById(sessionId)?.playbackQueue;
    final i18n = context.watch<AppLanguageProvider>();
    if (queue == null) return const SizedBox.shrink();
    
    return Scaffold(
      appBar: AppBar(title: Text(i18n.tr('edit_queue_audio'))),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isLandscape = constraints.maxWidth > constraints.maxHeight;
          final queueEntries = queue.entries.toList();

          final addedToQueueSection = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
                child: Text(
                  i18n.tr('queue_added_audio'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (queueEntries.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: ListTile(title: Text(i18n.tr('empty_playback_queue'))),
                )
              else
                Expanded(
                  child: ReorderableListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    buildDefaultDragHandles: false,
                    proxyDecorator: (child, index, animation) => child,
                    itemCount: queueEntries.length,
                    onReorder: (oldIndex, newIndex) {
                      provider.reorderPlaybackQueueEntry(
                        sessionId,
                        oldIndex,
                        newIndex,
                      );
                    },
                    itemBuilder: (context, index) {
                      final entry = queueEntries[index];
                      return _QueueAudioEditCard(
                        key: ValueKey(entry.id),
                        provider: provider,
                        track: entry.tracks.firstOrNull,
                        title: entry.title,
                        subtitle: i18n.tr('audio_count', {'count': entry.tracks.length}),
                        trailing: Column(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            IconButton(
                              tooltip: i18n.tr('remove'),
                              constraints: const BoxConstraints.tightFor(width: 40, height: 32),
                              padding: EdgeInsets.zero,
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(Icons.remove_circle_outline_rounded, size: 22),
                              onPressed: () =>
                                  provider.removePlaybackQueueEntry(sessionId, entry.id),
                            ),
                            ReorderableDragStartListener(
                              index: index,
                              child: Container(
                                width: 40,
                                height: 32,
                                alignment: Alignment.center,
                                child: const Icon(Icons.drag_handle_rounded, size: 22),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
            ],
          );

          final playlistAudioSection = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
                child: Text(
                  i18n.tr('playback_list_audio'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    for (final source in provider.ordinaryPlaybackSessions)
                      _QueueSourceAudioTile(queueSessionId: sessionId, source: source),
                  ],
                ),
              ),
            ],
          );

          if (isLandscape) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: addedToQueueSection),
                const VerticalDivider(width: 1),
                Expanded(child: playlistAudioSection),
              ],
            );
          } else {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: addedToQueueSection),
                const Divider(height: 1),
                Expanded(child: playlistAudioSection),
              ],
            );
          }
        },
      ),
    );
  }
}

class _QueueSourceAudioTile extends ConsumerWidget {
  const _QueueSourceAudioTile({
    required this.queueSessionId,
    required this.source,
  });
  final String queueSessionId;
  final PlaybackSession source;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = ref.read(audioProviderFacadeProvider);
    final track = provider.trackByPath(source.currentTrackPath);
    if (track == null) return const SizedBox.shrink();
    final i18n = context.watch<AppLanguageProvider>();
    return _QueueAudioEditCard(
      provider: provider,
      track: track,
      title: track.displayName,
      subtitle: track.groupTitle,
      trailing: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            tooltip: i18n.tr('add_audio_to_queue'),
            constraints: const BoxConstraints.tightFor(width: 40, height: 28),
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.add_circle_outline_rounded, size: 22),
            onPressed: () =>
                provider.addTrackToPlaybackQueue(queueSessionId, track),
          ),
          IconButton(
            tooltip: i18n.tr('add_work_to_queue'),
            constraints: const BoxConstraints.tightFor(width: 40, height: 28),
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.library_add_rounded, size: 22),
            onPressed: () =>
                provider.addWorkToPlaybackQueue(queueSessionId, track),
          ),
        ],
      ),
    );
  }
}

class _QueueAudioEditCard extends StatelessWidget {
  const _QueueAudioEditCard({
    super.key,
    required this.provider,
    required this.track,
    required this.title,
    required this.subtitle,
    required this.trailing,
  });

  final AudioProvider provider;
  final MusicTrack? track;
  final String title;
  final String subtitle;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      elevation: 0,
      color: cs.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.42)),
      ),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: 88,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 7, 10, 6),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: SizedBox(
                  width: 96,
                  height: 72,
                  child: track == null
                      ? CoverFallbackArtwork(seed: title)
                      : _QueueTrackCover(provider: provider, track: track!),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                        fontSize: 14,
                        height: 1.12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              SizedBox(width: 44, child: trailing),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlaybackQueueColorPanel extends ConsumerWidget {
  const _PlaybackQueueColorPanel({required this.sessionId});
  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(playbackStateProvider);
    final provider = ref.read(audioProviderFacadeProvider);
    final value = provider.sessionById(sessionId)?.playbackQueue?.colorValue;
    final color = value == null
        ? Theme.of(context).colorScheme.primary
        : Color(value);
    final i18n = context.watch<AppLanguageProvider>();
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainerLow.withValues(alpha: 0.96),
      elevation: 12,
      shadowColor: cs.shadow.withValues(alpha: 0.22),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(28),
        side: BorderSide(color: cs.primary.withValues(alpha: 0.45)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.22),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(Icons.palette_outlined, color: color, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    i18n.tr('edit_card_color'),
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: i18n.tr('close'),
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Container(
              height: 54,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: color.withValues(alpha: 0.42)),
              ),
              alignment: Alignment.center,
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: color.withValues(alpha: 0.32),
                      blurRadius: 12,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            for (final channel in <(String, int)>[
              ('R', (color.r * 255).round()),
              ('G', (color.g * 255).round()),
              ('B', (color.b * 255).round()),
            ])
              _QueueColorSlider(
                label: channel.$1,
                value: channel.$2,
                color: color,
                onChanged: (next) {
                  final r = channel.$1 == 'R' ? next : (color.r * 255).round();
                  final g = channel.$1 == 'G' ? next : (color.g * 255).round();
                  final b = channel.$1 == 'B' ? next : (color.b * 255).round();
                  provider.setPlaybackQueueColor(
                    sessionId,
                    Color.fromARGB(255, r, g, b),
                  );
                },
              ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () =>
                    provider.setPlaybackQueueColor(sessionId, null),
                icon: const Icon(Icons.restart_alt_rounded, size: 18),
                label: Text(i18n.tr('reset_to_default')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QueueColorSlider extends StatelessWidget {
  const _QueueColorSlider({
    required this.label,
    required this.value,
    required this.color,
    required this.onChanged,
  });

  final String label;
  final int value;
  final Color color;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 42,
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: cs.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(9),
            ),
            alignment: Alignment.center,
            child: Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w900),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Slider(
              max: 255,
              value: value.toDouble(),
              activeColor: color,
              onChanged: (next) => onChanged(next.round()),
            ),
          ),
          SizedBox(
            width: 30,
            child: Text(
              value.toString(),
              textAlign: TextAlign.end,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: cs.onSurfaceVariant,
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
