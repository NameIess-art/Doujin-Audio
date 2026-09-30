import '../../../library/presentation/library_providers.dart';
import '../playback_providers.dart';
import '../../../settings/presentation/settings_providers.dart';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/presentation/app_presentation_providers.dart';
import '../../../../app/state/app_runtime_providers.dart';
import '../../../../app/theme/app_styles.dart';
import '../../../../core/media/cover_image_resolution.dart';
import '../../../../core/media/music_track.dart';
import '../../../../core/ui/undoable_removal_service.dart';
import '../../../../core/widgets/app_edge_fade_mask.dart';
import '../../../../core/widgets/app_feedback.dart';
import '../../../../core/widgets/app_transitions.dart';
import '../../../../core/widgets/async_cover_image.dart';
import '../../../../core/widgets/page_header_inset.dart';
import '../../../../core/widgets/top_page_header.dart';
import '../../application/playback_session_snapshot.dart';
import '../../domain/playback_queue.dart';
import 'playlist_shared_helpers.dart';

import 'playback_queue_cover.dart';

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
      key: playbackQueueEntryRemovalKey(sessionId, entryId),
      commit: () => playback.removePlaybackQueueEntry(sessionId, entryId),
      undo: () {},
    ),
  );
  if (staged && context.mounted) {
    showPlaybackRemovalFeedback(context, service);
  } else if (staged) {
    await service.commitPending();
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
    final paths = ref.read(audioPathCoordinatorProvider);

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
      body: PageHeaderInset(
        topInset: headerHeight,
        child: Stack(
          children: [
            Positioned.fill(
              child: AppPageContentTransition(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final isLandscape =
                        defaultTargetPlatform == TargetPlatform.windows ||
                        constraints.maxWidth > constraints.maxHeight;
                    final removalState = ref.watch(
                      undoableRemovalStateProvider,
                    );
                    final queueEntries = queue.entries
                        .where(
                          (entry) => !removalState.isHidden(
                            playbackQueueEntryRemovalKey(sessionId, entry.id),
                          ),
                        )
                        .toList(growable: false);

                    final addedToQueueSection = Stack(
                      children: [
                        Positioned.fill(
                          child: queueEntries.isEmpty
                              ? Padding(
                                  padding: EdgeInsets.only(
                                    top: headerHeight + 48,
                                  ),
                                  child: ListTile(
                                    title: Text(
                                      i18n.tr('empty_playback_queue'),
                                    ),
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
                                        final firstTrack =
                                            entry.tracks.firstOrNull;
                                        final workTitle = firstTrack != null
                                            ? paths.workTitleForTrack(
                                                firstTrack,
                                              )
                                            : entry.title;
                                        final itemTitle =
                                            entry.kind ==
                                                PlaybackQueueEntryKind.work
                                            ? i18n.tr('audio_count', {
                                                'count': entry.tracks.length,
                                              })
                                            : entry.title;
                                        return _QueueAudioEditCard(
                                          track: firstTrack,
                                          title: itemTitle,
                                          workTitle: workTitle,
                                          trailing: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              IconButton(
                                                tooltip: i18n.tr('remove'),
                                                constraints:
                                                    const BoxConstraints.tightFor(
                                                      width: 40,
                                                      height: 40,
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
                                                  height: 40,
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
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.playlist_play_rounded,
                                      size: 16,
                                      color: cs.primary,
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      i18n.tr('queue_added_audio'),
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
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: TopPageHeader(
                icon: Icons.playlist_play_rounded,
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
    final paths = ref.read(audioPathCoordinatorProvider);
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
    final workTitle = paths.workTitleForTrack(track);
    return _QueueAudioEditCard(
      track: track,
      title: track.displayName,
      workTitle: workTitle,
      color: playlistAreaBackground,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
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
              queueCoordinator.addTrack(queueSessionId, track);
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
    required this.workTitle,
    required this.trailing,
    this.color,
  });

  final MusicTrack? track;
  final String title;
  final String workTitle;
  final Widget trailing;
  final Color? color;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final library = ref.read(libraryFacadeProvider);
    final cs = Theme.of(context).colorScheme;
    final resolvedTrack = track;
    final resolvedCoverPath = resolvedTrack == null
        ? null
        : library.resolvedPlaybackCoverPathForTrack(resolvedTrack);
    if (resolvedTrack != null && resolvedCoverPath == null) {
      unawaited(library.playbackCoverPathFutureForTrack(resolvedTrack));
    }
    final showCover =
        shouldShowPlaylistCoverArtwork(resolvedTrack, resolvedCoverPath) ||
        (resolvedTrack != null &&
            (resolvedTrack.isVideo ||
                !resolvedTrack.isSingle ||
                resolvedCoverPath != null));
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: color ?? cs.surface,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shape: playlistRowShape,
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: playlistRowHeight,
        child: Row(
          children: [
            Expanded(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  AppSpacing.xs,
                  playlistRowPadding.top,
                  0,
                  playlistRowPadding.bottom,
                ),
                child: Row(
                  children: [
                    if (showCover) ...[
                      ClipOval(
                        child: SizedBox.square(
                          dimension: playlistCoverSize,
                          child: track == null
                              ? CoverFallbackArtwork(seed: title)
                              : QueueTrackCover(
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
                            workTitle,
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
            Padding(
              padding: const EdgeInsets.only(right: AppSpacing.xs),
              child: trailing,
            ),
          ],
        ),
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
