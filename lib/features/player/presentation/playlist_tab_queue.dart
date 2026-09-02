part of 'playlist_tab.dart';

Future<void> _stagePlaybackQueueEntryRemoval(
  BuildContext context,
  WidgetRef ref, {
  required String sessionId,
  required String entryId,
}) async {
  final playback = ref.read(playbackFacadeProvider);
  final service = ref.read(undoableRemovalServiceProvider);
  final staged = await service.stage(
    UndoableRemovalAction(
      key: _playbackQueueEntryRemovalKey(sessionId, entryId),
      commit: () => playback.removePlaybackQueueEntry(sessionId, entryId),
      undo: () {},
    ),
  );
  if (staged && context.mounted) {
    _showPlaybackRemovalFeedback(context, service);
  } else if (staged) {
    await service.commitPending();
  }
}

class _PlaybackQueueCard extends ConsumerWidget {
  const _PlaybackQueueCard({
    required this.session,
    required this.library,
    required this.playback,
    required this.coverCacheWidth,
    required this.onOpen,
    required this.onEdit,
    this.isSelectionMode = false,
    this.isSelected = false,
    this.onLongPress,
    this.onToggleSelect,
  });

  final PlaybackSessionSnapshot session;
  final LibraryFacade library;
  final PlaybackFacade playback;
  final int? coverCacheWidth;
  final VoidCallback onOpen;
  final VoidCallback onEdit;
  final bool isSelectionMode;
  final bool isSelected;
  final VoidCallback? onLongPress;
  final VoidCallback? onToggleSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isHidden = ref.watch(
      isUndoableRemovalHiddenProvider(_playbackSessionRemovalKey(session.id)),
    );
    final cardState = ref.watch(playlistSessionCardStateProvider(session.id));
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
    final resolvedCurrentPath = playback.resolveRetargetedPath(
      cardState.trackPath,
    );
    final matchedCurrentIndex = tracks.indexWhere(
      (track) =>
          PathMatcher.equalsNormalized(track.path, cardState.trackPath) ||
          PathMatcher.equalsNormalized(
            playback.resolveRetargetedPath(track.path),
            resolvedCurrentPath,
          ),
    );
    final currentIndex = matchedCurrentIndex >= 0
        ? matchedCurrentIndex
        : session.currentQueueIndex >= 0 &&
              session.currentQueueIndex < tracks.length
        ? session.currentQueueIndex
        : -1;
    final currentTrack = currentIndex >= 0
        ? tracks[currentIndex]
        : ref
              .read(audioPathCoordinatorProvider)
              .sessionTrackForPath(session.id, cardState.trackPath);
    final currentTrackName = tracks.isEmpty
        ? i18n.tr('empty_playback_queue')
        : currentTrack?.displayName ??
              path.basenameWithoutExtension(cardState.trackPath);
    final nextTrack = currentIndex >= 0 && currentIndex + 1 < tracks.length
        ? tracks[currentIndex + 1]
        : null;
    final secondTrackName = nextTrack?.displayName ?? '';
    return UndoableRemovalTransition(
      hidden: isHidden,
      child: SwipeRevealCard(
        key: ValueKey(session.id),
      shape: _playlistRowShape,
      color: revealActionColor,
      closedColor: cs.surface,
      enabled: !isSelectionMode,
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
              color: isSelected
                  ? cs.primaryContainer.withValues(alpha: 0.15)
                  : null,
              borderRadius: const BorderRadius.all(
                Radius.circular(LibraryLikeCardMetrics.cardRadius),
              ),
            ),
            child: InkWell(
              excludeFromSemantics: true,
              onTap: () {
                if (isSelectionMode) {
                  onToggleSelect?.call();
                } else {
                  AppInteractionFeedback.trigger(
                    AppInteractionFeedbackType.tap,
                  );
                  onOpen();
                }
              },
              onLongPress: () {
                if (isSelectionMode) {
                  onToggleSelect?.call();
                } else {
                  onLongPress?.call();
                }
              },
              child: Padding(
                key: ValueKey<String>(
                  'playback_queue_card_content_${session.id}',
                ),
                padding: _playlistRowPadding,
                child: Row(
                  children: [
                    if (coverItems.isNotEmpty) ...[
                      Stack(
                        clipBehavior: Clip.none,
                        children: [
                          _QueueCoverGrid(
                            items: coverItems,
                            coverCacheWidth: coverCacheWidth,
                          ),
                          Positioned(
                            left: 4,
                            bottom: 4,
                            child: _PlaylistSelectionIndicator(
                              sessionId: session.id,
                              isSelected: isSelected,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(width: AppSpacing.xs),
                    ] else ...[
                      _PlaylistSelectionIndicatorAnchor(
                        sessionId: session.id,
                        isSelected: isSelected,
                      ),
                    ],
                    Expanded(
                      child: Semantics(
                        button: true,
                        selected: isSelectionMode ? isSelected : null,
                        label: i18n.tr('open_playback_details'),
                        onTap: isSelectionMode ? onToggleSelect : onOpen,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              queue.name,
                              key: ValueKey<String>(
                                'playback_queue_name_${session.id}',
                              ),
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
                              currentTrackName,
                              key: ValueKey<String>(
                                'playback_queue_track_0_${session.id}',
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 14,
                                    height: 1.12,
                                  ),
                            ),
                            const SizedBox(height: 1),
                            Text(
                              secondTrackName,
                              key: ValueKey<String>(
                                'playback_queue_track_1_${session.id}',
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 14,
                                    height: 1.12,
                                  ),
                            ),
                            const SizedBox(height: 4),
                            _SessionMetaChip(
                              key: ValueKey<String>(
                                'playback_queue_loop_mode_${session.id}',
                              ),
                              icon: Icons.repeat_rounded,
                              text: _playlistLoopModeSummary(
                                context,
                                cardState.loopMode,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.xxs),
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
      borderRadius: BorderRadius.circular(LibraryLikeCardMetrics.coverRadius),
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
  return AppBottomSheet.show<void>(
    context: context,
    builder: (_) => PlaybackQueueEditPage(sessionId: sessionId),
  );
}

const double _playbackQueueEditPanelHeight = 360;

class PlaybackQueueEditPage extends ConsumerStatefulWidget {
  const PlaybackQueueEditPage({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<PlaybackQueueEditPage> createState() =>
      _PlaybackQueueEditPageState();
}

class _PlaybackQueueEditPageState extends ConsumerState<PlaybackQueueEditPage> {
  bool _editingColor = false;

  String get sessionId => widget.sessionId;

  @override
  Widget build(BuildContext context) {
    final structure = ref.watch(playlistStructureUiProvider);
    final playback = ref.read(playbackFacadeProvider);
    final session = structure.entries
        .where((entry) => entry.sessionId == sessionId)
        .firstOrNull
        ?.session;
    final queue = session?.playbackQueue;
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    if (queue == null) return const SizedBox.shrink();
    if (_editingColor) {
      return _PlaybackQueueColorPanel(
        sessionId: sessionId,
        onBack: () => setState(() => _editingColor = false),
      );
    }
    final cs = Theme.of(context).colorScheme;
    final tokens = AppDesignTokens.of(context);
    return SizedBox(
      height: _playbackQueueEditPanelHeight,
      child: Material(
        color: cs.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
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
                      color: cs.primary.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(tokens.radiusSmall),
                    ),
                    child: Icon(
                      Icons.queue_music_rounded,
                      color: cs.primary,
                      size: 22,
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
                          child: PlaybackQueueAudioEditPage(
                            sessionId: sessionId,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    _queueEditTile(
                      context,
                      Icons.drive_file_rename_outline_rounded,
                      i18n.tr('edit_queue_name'),
                      () => _editQueueName(context, playback, queue.name),
                    ),
                    const SizedBox(height: 6),
                    _queueEditTile(
                      context,
                      Icons.palette_outlined,
                      i18n.tr('edit_queue_color'),
                      () => setState(() => _editingColor = true),
                    ),
                    const SizedBox(height: 12),
                    _queueEditTile(
                      context,
                      Icons.delete_outline_rounded,
                      i18n.tr('remove_queue'),
                      () => _removeQueue(context, ref),
                      destructive: true,
                    ),
                  ],
                ),
              ),
            ],
          ),
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
    final iconColor = destructive ? cs.error : cs.primary;
    final iconBgColor = destructive
        ? cs.error.withValues(alpha: 0.14)
        : cs.primary.withValues(alpha: 0.12);

    return Material(
      color: cs.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Container(
                key: ValueKey(
                  'playback_queue_edit_tile_icon_${icon.codePoint}',
                ),
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: iconBgColor,
                  borderRadius: BorderRadius.circular(tokens.radiusSmall),
                ),
                child: Icon(icon, size: 20, color: iconColor),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    color: foreground,
                  ),
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: foreground.withValues(alpha: 0.5),
              ),
            ],
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

  Future<void> _removeQueue(BuildContext context, WidgetRef ref) async {
    if (await _stagePlaybackSessionRemovals(context, ref, [sessionId]) &&
        context.mounted) {
      Navigator.of(context).pop();
    }
  }
}

class PlaybackQueueAudioEditPage extends ConsumerStatefulWidget {
  const PlaybackQueueAudioEditPage({super.key, required this.sessionId});
  final String sessionId;

  @override
  ConsumerState<PlaybackQueueAudioEditPage> createState() =>
      _PlaybackQueueAudioEditPageState();
}

class _PlaybackQueueAudioEditPageState
    extends ConsumerState<PlaybackQueueAudioEditPage> {
  final ScrollController _addedQueueScrollController = ScrollController();

  @override
  void dispose() {
    _addedQueueScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sessionId = widget.sessionId;
    final structure = ref.watch(playlistStructureUiProvider);
    final playback = ref.read(playbackFacadeProvider);

    ref.listen(
      playlistStructureUiProvider.select((s) {
        final q = s.entries
            .where((entry) => entry.sessionId == sessionId)
            .firstOrNull
            ?.session
            .playbackQueue;
        return q?.entries.length ?? 0;
      }),
      (previous, next) {
        if (previous != null && next > previous) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_addedQueueScrollController.hasClients) {
              _addedQueueScrollController.jumpTo(
                _addedQueueScrollController.position.maxScrollExtent,
              );
            }
          });
        }
      },
    );

    final queue = structure.entries
        .where((entry) => entry.sessionId == sessionId)
        .firstOrNull
        ?.session
        .playbackQueue;
    final ordinarySessions = structure.entries
        .where((entry) => !entry.isPlaybackQueue)
        .map((entry) => entry.session)
        .toList(growable: false);
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    if (queue == null) return const SizedBox.shrink();

    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final playlistAreaBackground = isDark
        ? cs.surfaceContainerLowest
        : cs.surfaceContainer;

    final headerHeight =
        MediaQuery.paddingOf(context).top +
        AppPageHeaderMetrics.padding.top +
        38 +
        AppPageHeaderMetrics.bottomSpacing;

    return Scaffold(
      backgroundColor: cs.surface,
      body: Stack(
        children: [
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final isLandscape =
                    constraints.maxWidth > constraints.maxHeight;
                final removalState = ref.watch(undoableRemovalStateProvider);
                final queueEntries = queue.entries
                    .where(
                      (entry) => !removalState.isHidden(
                        _playbackQueueEntryRemovalKey(sessionId, entry.id),
                      ),
                    )
                    .toList(growable: false);

                final addedToQueueSection = Stack(
                  children: [
                    Positioned.fill(
                      child: queueEntries.isEmpty
                          ? Padding(
                              padding: EdgeInsets.only(top: headerHeight + 48),
                              child: ListTile(
                                title: Text(i18n.tr('empty_playback_queue')),
                              ),
                            )
                          : ReorderableListView.builder(
                              scrollController: _addedQueueScrollController,
                              padding: EdgeInsets.fromLTRB(
                                AppSpacing.xs,
                                headerHeight + 44,
                                AppSpacing.xs,
                                AppSpacing.xs,
                              ),
                              buildDefaultDragHandles: false,
                              proxyDecorator: (child, index, animation) =>
                                  child,
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
                                  onRemove: () =>
                                      _stagePlaybackQueueEntryRemoval(
                                        context,
                                        ref,
                                        sessionId: sessionId,
                                        entryId: entry.id,
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
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          IconButton(
                                            tooltip: i18n.tr('remove'),
                                            constraints:
                                                const BoxConstraints.tightFor(
                                                  width: 40,
                                                  height: 32,
                                                ),
                                            padding: EdgeInsets.zero,
                                            visualDensity:
                                                VisualDensity.compact,
                                            icon: const Icon(
                                              Icons
                                                  .remove_circle_outline_rounded,
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
                    Positioned(
                      top: headerHeight,
                      left: 0,
                      right: 0,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(
                          AppSpacing.xs,
                          AppSpacing.sm,
                          AppSpacing.xs,
                          AppSpacing.xs,
                        ),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: HeaderFloatingSurface(
                            height: 32,
                            radius: 16,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.queue_music_rounded,
                                  size: 16,
                                  color: cs.primary,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  i18n.tr('queue_added_audio'),
                                  style: Theme.of(context).textTheme.titleSmall
                                      ?.copyWith(
                                        fontWeight: FontWeight.w700,
                                        color: cs.onSurface,
                                        fontSize: 13,
                                      ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                );

                final sectionTopOffset = isLandscape ? headerHeight : 0.0;

                final playlistAudioSection = DecoratedBox(
                  decoration: BoxDecoration(color: playlistAreaBackground),
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: ListView.builder(
                          padding: EdgeInsets.fromLTRB(
                            AppSpacing.xs,
                            sectionTopOffset + 44,
                            AppSpacing.xs,
                            AppSpacing.xs,
                          ),
                          itemCount: ordinarySessions.length,
                          itemBuilder: (context, index) {
                            final source = ordinarySessions[index];
                            return _QueueSourceAudioTile(
                              queueSessionId: sessionId,
                              source: source,
                            );
                          },
                        ),
                      ),
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        height: sectionTopOffset + 48,
                        child: AppEdgeFadeMask(
                          direction: AppEdgeFadeDirection.towardTop,
                          color: playlistAreaBackground,
                        ),
                      ),
                      Positioned(
                        top: sectionTopOffset,
                        left: 0,
                        right: 0,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(
                            AppSpacing.xs,
                            AppSpacing.sm,
                            AppSpacing.xs,
                            AppSpacing.xs,
                          ),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: HeaderFloatingSurface(
                              height: 32,
                              radius: 16,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.playlist_play_rounded,
                                    size: 17,
                                    color: cs.primary,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    i18n.tr('playback_list_audio'),
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleSmall
                                        ?.copyWith(
                                          fontWeight: FontWeight.w700,
                                          color: cs.onSurface,
                                          fontSize: 13,
                                        ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );

                if (isLandscape) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: addedToQueueSection),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: VerticalDivider(
                          width: 1,
                          thickness: 1,
                          color: cs.outlineVariant.withValues(alpha: 0.35),
                        ),
                      ),
                      Expanded(child: playlistAudioSection),
                    ],
                  );
                } else {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: addedToQueueSection),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Divider(
                          height: 1,
                          thickness: 1,
                          color: cs.outlineVariant.withValues(alpha: 0.35),
                        ),
                      ),
                      Expanded(child: playlistAudioSection),
                    ],
                  );
                }
              },
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: TopPageHeader(
              icon: Icons.queue_music_rounded,
              leading: IconButton(
                tooltip: i18n.tr('close'),
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.arrow_back_rounded),
              ),
              title: i18n.tr('edit_queue_audio'),
            ),
          ),
        ],
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
  final PlaybackSessionSnapshot source;

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
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final playlistAreaBackground = isDark
        ? cs.surfaceContainerLowest
        : cs.surfaceContainer;
    return _QueueAudioEditCard(
      track: track,
      title: track.displayName,
      subtitle: track.groupTitle,
      rowHeight: track.isSingle ? _playlistRowHeight : 88.0,
      color: playlistAreaBackground,
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
    this.rowHeight = _playlistRowHeight,
    this.color,
  });

  final MusicTrack? track;
  final String title;
  final String subtitle;
  final Widget trailing;
  final double rowHeight;
  final Color? color;

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
      color: color ?? cs.surface,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shape: _playlistRowShape,
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: rowHeight,
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
                          LibraryLikeCardMetrics.coverRadius,
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
                            maxLines: 2,
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
            SizedBox(width: 44, height: rowHeight, child: trailing),
          ],
        ),
      ),
    );
  }
}

class _PlaybackQueueColorPanel extends ConsumerWidget {
  const _PlaybackQueueColorPanel({
    required this.sessionId,
    required this.onBack,
  });

  final String sessionId;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final structure = ref.watch(playlistStructureUiProvider);
    final playback = ref.read(playbackFacadeProvider);
    final value = structure.entries
        .where((entry) => entry.sessionId == sessionId)
        .firstOrNull
        ?.queueColorValue;
    final color = value == null
        ? Theme.of(context).colorScheme.primary
        : Color(value);
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final cs = Theme.of(context).colorScheme;
    final tokens = AppDesignTokens.of(context);
    return SizedBox(
      height: _playbackQueueEditPanelHeight,
      child: Material(
        key: const ValueKey('playback_queue_color_panel'),
        color: cs.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
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
                      color: color.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(tokens.radiusSmall),
                    ),
                    child: Icon(Icons.palette_outlined, color: color, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      i18n.tr('edit_queue_color'),
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('playback_queue_color_back'),
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).backButtonTooltip,
                    icon: const Icon(Icons.arrow_back_rounded),
                    onPressed: onBack,
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Container(
                height: 54,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(14),
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
                    final r = channel.$1 == 'R'
                        ? next
                        : (color.r * 255).round();
                    final g = channel.$1 == 'G'
                        ? next
                        : (color.g * 255).round();
                    final b = channel.$1 == 'B'
                        ? next
                        : (color.b * 255).round();
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
    return UndoableRemovalTransition(
      hidden: _isRemoving,
      duration: const Duration(milliseconds: 250),
      child: widget.builder(context, _triggerRemove),
    );
  }
}
