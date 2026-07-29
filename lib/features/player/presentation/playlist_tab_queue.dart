part of 'playlist_tab.dart';

class _PlaybackQueueCard extends ConsumerWidget {
  const _PlaybackQueueCard({
    required this.session,
    this.cardStateOverride,
    required this.library,
    required this.playback,
    required this.index,
    required this.cardPositionsLocked,
    required this.coverCacheWidth,
    required this.onOpen,
    required this.onEdit,
  });

  final PlaybackSession session;
  final PlaylistSessionCardState? cardStateOverride;
  final LibraryFacade library;
  final PlaybackFacade playback;
  final int index;
  final bool cardPositionsLocked;
  final int? coverCacheWidth;
  final VoidCallback onOpen;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cardState =
        cardStateOverride ??
        ref.watch(playlistSessionCardStateProvider(session.id));
    if (cardState == null) return const SizedBox.shrink();
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final cs = Theme.of(context).colorScheme;
    final queue = session.playbackQueue!;
    final tracks = queue.expandedTracks;
    final activeColor = cardState.queueColorValue == null
        ? cs.primary
        : Color(cardState.queueColorValue!);
    final revealActionColor = cardState.queueColorValue == null
        ? cs.primary
        : activeColor;
    final isPlaying = cardState.isPlaying;
    final highlightColor = activeColor.withValues(
      alpha: Theme.of(context).brightness == Brightness.dark ? 0.16 : 0.12,
    );
    final coverTracks = queue.entries
        .where((entry) => entry.tracks.isNotEmpty)
        .map((entry) => entry.tracks.first)
        .toList(growable: false);
    final coverItems = coverTracks
        .map(
          (track) => (
            track: track,
            coverPath: library.resolvedPlaybackCoverPathForTrack(track),
          ),
        )
        .where(
          (item) => shouldShowPlaylistCoverArtwork(item.track, item.coverPath),
        )
        .take(4)
        .toList(growable: false);
    final currentTrack = tracks.isEmpty
        ? null
        : tracks[session.currentQueueIndex.clamp(0, tracks.length - 1)];
    return SwipeRevealCard(
      key: ValueKey(session.id),
      shape: _playlistRowShape,
      color: revealActionColor,
      closedColor: cs.surface,
      destructive: false,
      primaryActionIcon: Icons.edit_rounded,
      actionLabel: i18n.tr('edit'),
      removeTooltip: i18n.tr('edit_playback_queue'),
      onRemove: onEdit,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: _playlistRowHeight),
        child: Material(
          key: ValueKey('playback_queue_row_surface_${session.id}'),
          color: Colors.transparent,
          child: DecoratedBox(
            key: ValueKey('playback_queue_active_highlight_${session.id}'),
            decoration: BoxDecoration(
              gradient: _playlistActiveHighlightGradient(
                isPlaying,
                highlightColor,
              ),
            ),
            child: InkWell(
              onTap: onOpen,
              child: Padding(
                padding: _playlistRowPadding,
                child: Row(
                  children: [
                    if (coverItems.isNotEmpty) ...[
                      _QueueCoverGrid(
                        items: coverItems,
                        coverCacheWidth: coverCacheWidth,
                      ),
                      const SizedBox(width: AppSpacing.xs),
                    ],
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
                          tooltip: cardState.isPlaying
                              ? i18n.tr('pause')
                              : i18n.tr('play'),
                          onPressed: tracks.isEmpty
                              ? null
                              : () {
                                  AppInteractionFeedback.trigger(
                                    AppInteractionFeedbackType.selection,
                                  );
                                  playback.toggleSessionPlayPause(session.id);
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
                        if (!cardPositionsLocked) ...[
                          const SizedBox(width: 4),
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
    );
  }
}

class _QueueCoverGrid extends StatelessWidget {
  const _QueueCoverGrid({required this.items, required this.coverCacheWidth});

  final List<({MusicTrack track, String? coverPath})> items;
  final int? coverCacheWidth;

  @override
  Widget build(BuildContext context) {
    final Widget content;
    if (items.length == 1) {
      content = _buildCell(context, 0);
    } else if (items.length == 2) {
      content = Row(
        children: [
          Expanded(child: _buildCell(context, 0)),
          Expanded(child: _buildCell(context, 1)),
        ],
      );
    } else {
      content = Column(
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
      );
    }
    return ClipRRect(
      key: const ValueKey('playback_queue_cover_grid'),
      borderRadius: BorderRadius.circular(16),
      child: SizedBox.square(dimension: _playlistCoverSize, child: content),
    );
  }

  Widget _buildCell(BuildContext context, int index) {
    final Widget cell;
    if (index >= items.length) {
      final cs = Theme.of(context).colorScheme;
      final isDark = Theme.of(context).brightness == Brightness.dark;
      cell = ColoredBox(
        color: cs.surfaceContainerHighest.withValues(alpha: isDark ? 0.4 : 0.6),
        child: Center(
          child: Icon(
            Icons.audiotrack_rounded,
            size: 18,
            color: cs.onSurfaceVariant.withValues(alpha: 0.35),
          ),
        ),
      );
    } else {
      final item = items[index];
      cell = _QueueTrackCover(
        key: ValueKey('$index:${item.track.path}'),
        track: item.track,
        coverPath: item.coverPath,
        coverCacheWidth: coverCacheWidth,
      );
    }
    return SizedBox.expand(
      key: ValueKey('playback_queue_cover_cell_$index'),
      child: cell,
    );
  }
}

class _QueueTrackCover extends StatelessWidget {
  const _QueueTrackCover({
    super.key,
    required this.track,
    required this.coverPath,
    required this.coverCacheWidth,
  });

  final MusicTrack track;
  final String? coverPath;
  final int? coverCacheWidth;

  @override
  Widget build(BuildContext context) {
    if (coverPath == null || coverPath!.isEmpty) {
      return CoverFallbackArtwork(seed: track.displayName);
    }
    return RetryingFileImage(
      path: coverPath!,
      fit: BoxFit.cover,
      displayMode: CoverImageDisplayMode.fill,
      cacheWidth: coverCacheWidth,
      useDefaultCacheWidth: coverCacheWidth != null,
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
  final i18n = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(appLanguageProviderInstanceProvider);
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
    final playback = ref.read(playbackFacadeProvider);
    final session = playback.sessionById(sessionId);
    final queue = session?.playbackQueue;
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    if (queue == null) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final tokens = AppDesignTokens.of(context);
    return Material(
      color: cs.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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
                  key: const ValueKey('playback_queue_edit_header_icon'),
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: cs.primaryContainer,
                    borderRadius: BorderRadius.circular(tokens.radiusSmall),
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
                        context: context,
                        child: PlaybackQueueAudioEditPage(sessionId: sessionId),
                      ),
                    ),
                  ),
                  _queueEditTile(
                    context,
                    Icons.drive_file_rename_outline_rounded,
                    i18n.tr('edit_queue_name'),
                    () => _editQueueName(context, playback, queue.name),
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
                    () => _removeQueue(context, playback),
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
    final tokens = AppDesignTokens.of(context);
    final foreground = destructive ? cs.error : cs.onSurface;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: cs.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
            child: Row(
              children: [
                Container(
                  key: ValueKey(
                    'playback_queue_edit_tile_icon_${icon.codePoint}',
                  ),
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: destructive
                        ? cs.errorContainer
                        : cs.primaryContainer,
                    borderRadius: BorderRadius.circular(tokens.radiusSmall),
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
    PlaybackFacade playback,
    String currentName,
  ) async {
    final controller = TextEditingController(text: currentName);
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final name = await showAppDialog<String>(
      context: context,
      builder: (dialogContext) => AppDialog(
        title: i18n.tr('edit_queue_name'),
        icon: Icons.drive_file_rename_outline_rounded,
        content: TextField(
          controller: controller,
          autofocus: true,
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value.trim()),
        ),
        actions: AppDialogActions(
          children: [
            AppSecondaryButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              label: i18n.tr('cancel'),
            ),
            AppPrimaryButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(controller.text.trim()),
              label: i18n.tr('save'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (name?.isNotEmpty == true) {
      playback.renamePlaybackQueue(sessionId, name!);
    }
  }

  Future<void> _removeQueue(
    BuildContext context,
    PlaybackFacade playback,
  ) async {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final confirmed = await showConfirmActionDialog(
      context: context,
      title: i18n.tr('remove_queue'),
      message: i18n.tr('remove_queue_confirm'),
      cancelLabel: i18n.tr('cancel'),
      confirmLabel: i18n.tr('remove_queue'),
      icon: Icons.delete_outline_rounded,
    );
    if (!confirmed || !context.mounted) return;
    await playback.removeSession(sessionId);
    if (context.mounted) Navigator.of(context).pop();
  }
}

class PlaybackQueueAudioEditPage extends ConsumerWidget {
  const PlaybackQueueAudioEditPage({super.key, required this.sessionId});
  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(playbackStateProvider);
    final playback = ref.read(playbackFacadeProvider);
    final queue = playback.sessionById(sessionId)?.playbackQueue;
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    if (queue == null) return const SizedBox.shrink();

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: AppBar(
        toolbarHeight: AppPageHeaderMetrics.toolbarHeight,
        title: Text(i18n.tr('edit_queue_audio')),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isLandscape = constraints.maxWidth > constraints.maxHeight;
          final queueEntries = queue.entries.toList();

          final addedToQueueSection = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.xs,
                  AppSpacing.sm,
                  AppSpacing.xs,
                  AppSpacing.xs,
                ),
                child: Text(
                  i18n.tr('queue_added_audio'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (queueEntries.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.xs,
                  ),
                  child: ListTile(title: Text(i18n.tr('empty_playback_queue'))),
                )
              else
                Expanded(
                  child: ReorderableListView.builder(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.xs,
                    ),
                    buildDefaultDragHandles: false,
                    proxyDecorator: (child, index, animation) => child,
                    itemCount: queueEntries.length,
                    onReorder: (oldIndex, newIndex) {
                      playback.reorderPlaybackQueueEntry(
                        sessionId,
                        oldIndex,
                        newIndex,
                      );
                    },
                    itemBuilder: (context, index) {
                      final entry = queueEntries[index];
                      return _AnimatedQueueEntryCard(
                        key: ValueKey(entry.id),
                        onRemove: () => playback.removePlaybackQueueEntry(
                          sessionId,
                          entry.id,
                        ),
                        builder: (context, triggerRemove) {
                          return _QueueAudioEditCard(
                            track: entry.tracks.firstOrNull,
                            title: entry.title,
                            subtitle: i18n.tr('audio_count', {
                              'count': entry.tracks.length,
                            }),
                            trailing: Column(
                              mainAxisSize: MainAxisSize.min,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                IconButton(
                                  tooltip: i18n.tr('remove'),
                                  constraints: const BoxConstraints.tightFor(
                                    width: 40,
                                    height: 32,
                                  ),
                                  padding: EdgeInsets.zero,
                                  visualDensity: VisualDensity.compact,
                                  icon: const Icon(
                                    Icons.remove_circle_outline_rounded,
                                    size: 22,
                                  ),
                                  onPressed: triggerRemove,
                                ),
                                ReorderableDragStartListener(
                                  index: index,
                                  child: Container(
                                    width: 40,
                                    height: 32,
                                    alignment: Alignment.center,
                                    child: const Icon(
                                      Icons.drag_handle_rounded,
                                      size: 22,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
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
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.xs,
                  AppSpacing.sm,
                  AppSpacing.xs,
                  AppSpacing.xs,
                ),
                child: Text(
                  i18n.tr('playback_list_audio'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.xs,
                  ),
                  itemCount: playback.ordinarySessions.length,
                  itemBuilder: (context, index) {
                    final source = playback.ordinarySessions[index];
                    return _QueueSourceAudioTile(
                      queueSessionId: sessionId,
                      source: source,
                    );
                  },
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
    final library = ref.read(libraryFacadeProvider);
    final playback = ref.read(playbackFacadeProvider);
    final queueCoordinator = ref.read(playbackQueueCoordinatorProvider);
    final track = library.trackByPath(source.currentTrackPath);
    if (track == null) return const SizedBox.shrink();
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    return _QueueAudioEditCard(
      track: track,
      title: track.displayName,
      subtitle: track.groupTitle,
      trailing: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            tooltip: i18n.tr('add_audio_to_queue'),
            style: IconButton.styleFrom(
              minimumSize: const Size.square(44),
              maximumSize: const Size.square(44),
              padding: EdgeInsets.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            icon: const Icon(Icons.add_circle_outline_rounded, size: 22),
            onPressed: () {
              unawaited(
                AppInteractionFeedback.trigger(
                  AppInteractionFeedbackType.selection,
                ),
              );
              playback.addTrackToPlaybackQueue(queueSessionId, track);
            },
          ),
          if (!track.isSingle)
            IconButton(
              tooltip: i18n.tr('add_work_to_queue'),
              style: IconButton.styleFrom(
                minimumSize: const Size.square(44),
                maximumSize: const Size.square(44),
                padding: EdgeInsets.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              icon: const Icon(Icons.library_add_rounded, size: 22),
              onPressed: () {
                unawaited(
                  AppInteractionFeedback.trigger(
                    AppInteractionFeedbackType.selection,
                  ),
                );
                queueCoordinator.addWork(queueSessionId, track);
              },
            ),
        ],
      ),
    );
  }
}

class _QueueAudioEditCard extends ConsumerWidget {
  const _QueueAudioEditCard({
    required this.track,
    required this.title,
    required this.subtitle,
    required this.trailing,
  });

  final MusicTrack? track;
  final String title;
  final String subtitle;
  final Widget trailing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final library = ref.read(libraryFacadeProvider);
    final cs = Theme.of(context).colorScheme;
    final resolvedCoverPath = track == null
        ? null
        : library.resolvedPlaybackCoverPathForTrack(track);
    if (track != null && resolvedCoverPath == null) {
      unawaited(library.playbackCoverPathFutureForTrack(track!));
    }
    final showCover = shouldShowPlaylistCoverArtwork(track, resolvedCoverPath);
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: cs.surface,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shape: _playlistRowShape,
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: _playlistRowHeight,
        child: Row(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.xs,
                  AppSpacing.xs,
                  0,
                  AppSpacing.xs,
                ),
                child: Row(
                  children: [
                    if (showCover) ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(
                          LibraryLikeCardMetrics.cardRadius,
                        ),
                        child: SizedBox.square(
                          dimension: _playlistCoverSize,
                          child: track == null
                              ? CoverFallbackArtwork(seed: title)
                              : _QueueTrackCover(
                                  track: track!,
                                  coverPath: resolvedCoverPath,
                                  coverCacheWidth: coverCacheWidthForResolution(
                                    ref.watch(
                                      settingsStateProvider.select(
                                        (state) =>
                                            state.value?.coverImageResolution ??
                                            CoverImageResolution.balanced,
                                      ),
                                    ),
                                  ),
                                ),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.xs),
                    ],
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            subtitle,
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
                            title,
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
                  ],
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.xxs),
            SizedBox(width: 44, height: _playlistRowHeight, child: trailing),
          ],
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
    final playback = ref.read(playbackFacadeProvider);
    final value = playback.sessionById(sessionId)?.playbackQueue?.colorValue;
    final color = value == null
        ? Theme.of(context).colorScheme.primary
        : Color(value);
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainerLow.withValues(alpha: 0.96),
      elevation: 12,
      shadowColor: cs.shadow.withValues(alpha: 0.22),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
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
                    borderRadius: BorderRadius.circular(16),
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
                  playback.setPlaybackQueueColorValue(
                    sessionId,
                    Color.fromARGB(255, r, g, b).toARGB32(),
                  );
                },
              ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () =>
                    playback.setPlaybackQueueColorValue(sessionId, null),
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
              borderRadius: BorderRadius.circular(16),
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

class _AnimatedQueueEntryCard extends StatefulWidget {
  final Widget Function(BuildContext context, VoidCallback triggerRemove)
  builder;
  final VoidCallback onRemove;

  const _AnimatedQueueEntryCard({
    super.key,
    required this.builder,
    required this.onRemove,
  });

  @override
  State<_AnimatedQueueEntryCard> createState() =>
      _AnimatedQueueEntryCardState();
}

class _AnimatedQueueEntryCardState extends State<_AnimatedQueueEntryCard> {
  bool _isRemoving = false;

  void _triggerRemove() {
    if (_isRemoving) return;
    unawaited(
      AppInteractionFeedback.trigger(AppInteractionFeedbackType.destructive),
    );
    setState(() {
      _isRemoving = true;
    });
    Future.delayed(const Duration(milliseconds: 250), () {
      if (mounted) widget.onRemove();
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: _isRemoving ? 0.0 : 1.0,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
      child: AnimatedSize(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
        child: _isRemoving
            ? const SizedBox(width: double.infinity, height: 0)
            : widget.builder(context, _triggerRemove),
      ),
    );
  }
}
