import '../../../library/presentation/library_providers.dart';
import '../playback_providers.dart';
import '../../../settings/presentation/settings_providers.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/presentation/app_presentation_providers.dart';
import '../../../../app/state/app_runtime_providers.dart';
import '../../../../app/theme/app_styles.dart';
import '../../../../core/app_language.dart';
import '../../../../core/logging/app_log_service.dart';
import '../../../../core/media/music_track.dart';
import '../../../../core/media/path_display.dart';
import '../../../../core/ui/ui_interaction_coordinator.dart';
import '../../../../core/ui/undoable_removal_service.dart';
import '../../../../core/widgets/app_buttons.dart';
import '../../../../core/widgets/app_edge_fade_mask.dart';
import '../../../../core/widgets/app_feedback.dart';
import '../../../../core/widgets/app_transitions.dart';
import '../../../../core/widgets/async_cover_image.dart';
import '../../../../core/widgets/marquee_text.dart';
import '../../../../core/widgets/mobile_overlay_inset.dart';
import '../../../../core/widgets/operation_feedback.dart';
import '../../../../core/widgets/page_header_inset.dart';
import '../../../../core/widgets/scroll_activity_gate.dart';
import '../../../../core/widgets/top_page_header.dart';
import '../../../../core/widgets/windows_smooth_scroll_controller.dart';
import '../../application/audio_state_services.dart';
import '../../domain/playback_queue.dart';
import '../../../settings/application/settings_state.dart';
import 'playlist_list_view.dart';
import 'playlist_media_widgets.dart';
import 'playlist_shared_helpers.dart';

import 'playback_queue_cover.dart';

const _queueEntryRemovalDuration = Duration(milliseconds: 250);
const _queueEntryPageSize = 128;

class PlaybackQueueAudioEditPage extends ConsumerStatefulWidget {
  const PlaybackQueueAudioEditPage({
    super.key,
    required this.sessionId,
    this.returnContext,
  });
  final String sessionId;
  final BuildContext? returnContext;

  @override
  ConsumerState<PlaybackQueueAudioEditPage> createState() =>
      _PlaybackQueueAudioEditPageState();
}

class _PlaybackQueueAudioEditPageState
    extends ConsumerState<PlaybackQueueAudioEditPage> {
  final _addedQueueScrollController = WindowsSmoothScrollController();
  final _addedQueueSectionKey = GlobalKey();
  int? _draggedIndex;
  VoidCallback? _pendingDrop;
  bool _didPop = false;
  int? _dragPointerId;
  double? _latestDragPointerY;
  double _dragHandleTopOffset = 0;
  double _addedQueueTopInset = 0;
  bool _isTopAutoScrolling = false;
  PlaybackQueueDefinition? _pagedQueue;
  final List<PlaybackQueueEntryPreview> _entryPreviews = [];
  bool _pageLoading = false;
  bool _pageFailed = false;
  bool _pageExhausted = false;

  @override
  void initState() {
    super.initState();
    _addedQueueScrollController.addListener(_loadNearQueueEnd);
  }

  void _loadNearQueueEnd() {
    if (_addedQueueScrollController.hasClients &&
        _addedQueueScrollController.position.extentAfter < 450) {
      _scheduleQueuePage();
    }
  }

  void _scheduleQueuePage() {
    final queue = _pagedQueue;
    if (queue == null ||
        _didPop ||
        _pageLoading ||
        _pageFailed ||
        _pageExhausted ||
        _entryPreviews.length >= queue.entryCount) {
      return;
    }
    _pageLoading = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_didPop && identical(_pagedQueue, queue)) {
        unawaited(_loadQueuePage(queue));
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _loadQueuePage(PlaybackQueueDefinition queue) async {
    final sessionId = widget.sessionId;
    final playback = ref.read(playbackFacadeProvider);
    bool isCurrent() =>
        mounted &&
        !_didPop &&
        identical(_pagedQueue, queue) &&
        identical(playback.sessionById(sessionId)?.playbackQueue, queue);
    try {
      if (_entryPreviews.isNotEmpty) setState(() {});
      final page = await playback.loadQueueEntryPreviews(
        sessionId,
        start: _entryPreviews.length,
        limit: _queueEntryPageSize,
      );
      if (!isCurrent()) return;
      setState(() {
        _pageLoading = false;
        _pageExhausted = page.length < _queueEntryPageSize;
        _entryPreviews.addAll(page);
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (isCurrent()) _loadNearQueueEnd();
      });
    } catch (error, stackTrace) {
      AppLogService.warning(
        'playback_queue_entry_page_failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (!isCurrent()) return;
      setState(() {
        _pageLoading = false;
        _pageFailed = true;
      });
    }
  }

  void _startQueueDrag(PointerDownEvent event, BuildContext itemContext) {
    if (_dragPointerId != null || event.buttons != kPrimaryButton) return;
    _dragPointerId = event.pointer;
    _latestDragPointerY = event.position.dy;
    final box = itemContext.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize) {
      _dragHandleTopOffset =
          event.position.dy - box.localToGlobal(Offset.zero).dy;
    } else {
      _dragHandleTopOffset = 0;
    }
    UiInteractionCoordinator.instance.beginInteraction(this);
  }

  void _updateQueueDrag(PointerMoveEvent event) {
    if (event.pointer != _dragPointerId) return;
    _latestDragPointerY = event.position.dy;
    if (!_isTopAutoScrolling && _computeTopOverDrag() > 0) {
      unawaited(_runTopAutoScroll());
    }
  }

  double _computeTopOverDrag() {
    final pointerY = _latestDragPointerY;
    if (pointerY == null ||
        !_addedQueueScrollController.hasClients ||
        _addedQueueScrollController.offset <=
            _addedQueueScrollController.position.minScrollExtent) {
      return 0;
    }
    final sectionBox =
        _addedQueueSectionKey.currentContext?.findRenderObject() as RenderBox?;
    if (sectionBox == null || !sectionBox.hasSize) return 0;
    // Keep scrolled rows extending behind the floating capsules while driving
    // upward auto-scroll from the boundary below the section heading capsule.
    final triggerY = sectionBox
        .localToGlobal(Offset(0, _addedQueueTopInset))
        .dy;
    final proxyTop = pointerY - _dragHandleTopOffset;
    return math.max(0.0, triggerY - proxyTop);
  }

  Future<void> _runTopAutoScroll() async {
    if (_isTopAutoScrolling) return;
    _isTopAutoScrolling = true;
    try {
      while (mounted && !_didPop && _dragPointerId != null) {
        final overDrag = _computeTopOverDrag();
        if (overDrag <= 0 || !_addedQueueScrollController.hasClients) break;
        final position = _addedQueueScrollController.position;
        final step = math.min(overDrag, 20.0);
        final target = math.max(
          position.minScrollExtent,
          _addedQueueScrollController.offset - step,
        );
        if ((_addedQueueScrollController.offset - target).abs() < 0.5) break;
        await _addedQueueScrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 20),
          curve: Curves.linear,
        );
      }
    } finally {
      _isTopAutoScrolling = false;
    }
  }

  void _finishQueueDrag(PointerEvent event) {
    if (mounted && _dragPointerId == event.pointer) {
      _dragPointerId = null;
      _latestDragPointerY = null;
      UiInteractionCoordinator.instance.endInteraction(this);
    }
  }

  void _handlePop(bool didPop, Object? _) {
    if (!didPop) return;
    _didPop = true;
    if (_dragPointerId != null) {
      _dragPointerId = null;
      _latestDragPointerY = null;
      UiInteractionCoordinator.instance.cancelInteraction(this);
    }
    final pendingDrop = _pendingDrop;
    _pendingDrop = null;
    if (pendingDrop == null) return;
    // The outgoing route still owns the drag proxy during its exit animation.
    final route = ModalRoute.of(context)!;
    unawaited(route.completed.then((_) => pendingDrop()));
  }

  Future<void> _removeEntry(String entryId) async {
    final route = ModalRoute.of(context);
    final returnContext = widget.returnContext;
    final playback = ref.read(playbackFacadeProvider);
    final service = ref.read(undoableRemovalServiceProvider);
    final sessionId = widget.sessionId;

    await Future<void>.delayed(_queueEntryRemovalDuration);
    // Updating the sliver and mounting undo feedback would change the frame
    // being animated out. The removal still needs to be staged after disposal.
    if (_didPop) await route?.completed;
    if (!await service.stage(
      UndoableRemovalAction(
        key: playbackQueueEntryRemovalKey(sessionId, entryId),
        commit: () => playback.removePlaybackQueueEntry(sessionId, entryId),
        undo: () {},
      ),
    )) {
      return;
    }
    final feedbackContext = mounted && !_didPop ? context : returnContext;
    if (feedbackContext != null && feedbackContext.mounted) {
      showPlaybackRemovalFeedback(feedbackContext, service);
    } else {
      await service.commitPending();
    }
  }

  @override
  void dispose() {
    _dragPointerId = null;
    _latestDragPointerY = null;
    UiInteractionCoordinator.instance.cancelInteraction(this);
    _addedQueueScrollController
      ..removeListener(_loadNearQueueEnd)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appLanguageStateProvider);
    final sessionId = widget.sessionId;
    final ordinarySessions = ref
        .watch(
          playlistStructureUiProvider.select(
            (structure) => _OrdinarySourceSessions(
              structure.entries
                  .where((entry) => entry.queueName == null)
                  .toList(growable: false),
            ),
          ),
        )
        .sessions;
    final playback = ref.read(playbackFacadeProvider);

    final sessionProvider = playbackSessionProvider(sessionId);
    ref.listen(
      sessionProvider.select(
        (session) => session?.playbackQueue?.entryCount ?? 0,
      ),
      (previous, next) {
        if (previous != null && next > previous) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!_didPop && _addedQueueScrollController.hasClients) {
              _addedQueueScrollController.jumpTo(
                _addedQueueScrollController.position.maxScrollExtent,
              );
            }
          });
        }
      },
    );

    final (:queue, :requiresLoad) = ref.watch(
      sessionProvider.select(
        (session) => (
          queue: session?.playbackQueue,
          requiresLoad: session?.queueLoadingRequired ?? false,
        ),
      ),
    );
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    if (queue == null) return const SizedBox.shrink();
    final pagedQueue = requiresLoad ? queue : null;
    if (!identical(_pagedQueue, pagedQueue)) {
      _pagedQueue = pagedQueue;
      _entryPreviews.clear();
      _pageLoading = _pageFailed = _pageExhausted = false;
      _scheduleQueuePage();
    }

    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final playlistAreaBackground = isDark
        ? cs.surfaceContainerLowest
        : cs.surfaceContainer;

    final headerHeight = AppPageHeaderMetrics.contentTopInset(context);
    final addedQueueTop = headerHeight + 44;
    final horizontalPadding = AppPageHeaderMetrics.padding.copyWith(top: 0);

    Widget sectionHeading(String label) {
      return Listener(
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: horizontalPadding.copyWith(bottom: AppSpacing.xs),
          child: Align(
            alignment: Alignment.centerLeft,
            child: HeaderFloatingSurface(
              height: 32,
              radius: 16,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.playlist_play_rounded,
                    size: 18,
                    color: cs.primary,
                  ),
                  const SizedBox(width: 8),
                  Text(label, style: appPageHeaderTitleStyle(context)),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final page = Scaffold(
      backgroundColor: Colors.transparent,
      body: PageHeaderInset(
        topInset: headerHeight,
        child: Stack(
          children: [
            Positioned.fill(
              child: AppPageContentTransition(
                backgroundColor: cs.surface,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final isLandscape =
                        defaultTargetPlatform == TargetPlatform.windows ||
                        constraints.maxWidth > constraints.maxHeight;
                    final removalState = ref.watch(
                      undoableRemovalStateProvider,
                    );
                    bool isVisible(String id) => !removalState.isHidden(
                      playbackQueueEntryRemovalKey(sessionId, id),
                    );
                    final filterHidden = removalState.hiddenKeys.isNotEmpty;
                    final queueEntries = requiresLoad || !filterHidden
                        ? queue.entries
                        : queue.entries
                              .where((entry) => isVisible(entry.id))
                              .toList();
                    final previews = !requiresLoad || !filterHidden
                        ? _entryPreviews
                        : _entryPreviews
                              .where((entry) => isVisible(entry.id))
                              .toList();
                    final rowCount = requiresLoad
                        ? previews.length
                        : queueEntries.length;
                    final hasMore =
                        requiresLoad &&
                        !_pageExhausted &&
                        _entryPreviews.length < queue.entryCount;
                    String idAt(int index) => requiresLoad
                        ? previews[index].id
                        : queueEntries[index].id;

                    VoidCallback? captureDrop(int oldIndex, int newIndex) {
                      if (oldIndex == newIndex ||
                          oldIndex + 1 == newIndex ||
                          oldIndex < 0 ||
                          oldIndex >= rowCount ||
                          newIndex < 0 ||
                          newIndex > rowCount) {
                        return null;
                      }
                      final sourceId = idAt(oldIndex);
                      final afterLast = newIndex == rowCount;
                      final targetId = idAt(
                        afterLast ? newIndex - 1 : newIndex,
                      );
                      final returnContext = widget.returnContext;
                      Future<void> commit() async {
                        try {
                          if (requiresLoad &&
                              !await playback.ensureSessionQueueLoaded(
                                sessionId,
                              )) {
                            return;
                          }
                          final entries = playback
                              .sessionById(sessionId)
                              ?.playbackQueue
                              ?.entries;
                          if (entries == null) return;
                          final source = entries.indexWhere(
                            (entry) => entry.id == sourceId,
                          );
                          final target = afterLast && !hasMore
                              ? entries.length
                              : entries.indexWhere(
                                  (entry) => entry.id == targetId,
                                );
                          if (source < 0 || target < 0) return;
                          await playback.reorderPlaybackQueueEntry(
                            sessionId,
                            source,
                            target + (afterLast && hasMore ? 1 : 0),
                          );
                        } catch (error, stackTrace) {
                          AppLogService.warning(
                            'playback_queue_reorder_failed',
                            error: error,
                            stackTrace: stackTrace,
                          );
                          final feedbackContext = mounted && !_didPop
                              ? context
                              : returnContext;
                          if (feedbackContext != null &&
                              feedbackContext.mounted) {
                            showAppSnackBar(
                              feedbackContext,
                              i18n.tr('operation_failed_retry'),
                              tone: AppFeedbackTone.warning,
                            );
                          }
                        }
                      }

                      return () => unawaited(commit());
                    }

                    final footer = hasMore && (_pageLoading || _pageFailed)
                        ? Padding(
                            padding: const EdgeInsets.all(12),
                            child: Center(
                              child: _pageFailed
                                  ? TextButton(
                                      onPressed: () => setState(() {
                                        _pageFailed = false;
                                        _scheduleQueuePage();
                                      }),
                                      child: Text(i18n.tr('retry')),
                                    )
                                  : const CircularProgressIndicator(),
                            ),
                          )
                        : null;

                    _addedQueueTopInset = addedQueueTop;
                    final addedToQueueSection = Stack(
                      key: _addedQueueSectionKey,
                      children: [
                        Positioned.fill(
                          child: rowCount == 0 && footer == null
                              ? Padding(
                                  padding: EdgeInsets.only(
                                    top: addedQueueTop + 4,
                                    bottom:
                                        MediaQuery.paddingOf(context).bottom +
                                            MobileOverlayInset.of(context),
                                  ),
                                  child: Center(
                                    child: AppEmptyState(
                                      icon: Icons.queue_music_rounded,
                                      title: i18n.tr('empty_playback_queue'),
                                    ),
                                  ),
                                )
                              : ReorderableListView.builder(
                                  scrollController: _addedQueueScrollController,
                                  padding: horizontalPadding.copyWith(
                                    top: addedQueueTop,
                                    bottom:
                                        MediaQuery.paddingOf(context).bottom +
                                            MobileOverlayInset.of(context) +
                                            AppSpacing.xs,
                                  ),
                                  buildDefaultDragHandles: false,
                                  proxyDecorator: (child, index, animation) =>
                                      RepaintBoundary(child: child),
                                  itemCount: rowCount,
                                  footer: footer,
                                  onReorderStart: (index) {
                                    _draggedIndex = index;
                                    _pendingDrop = null;
                                  },
                                  onReorderEnd: (index) {
                                    final from = _draggedIndex;
                                    _draggedIndex = null;
                                    // Flutter commits after the drop animation.
                                    // Popping the route can mute its ticker first.
                                    _pendingDrop = from == null
                                        ? null
                                        : captureDrop(from, index);
                                  },
                                  onReorder: (oldIndex, newIndex) {
                                    if (_didPop) return;
                                    final pendingDrop = _pendingDrop;
                                    _pendingDrop = null;
                                    (pendingDrop ??
                                            captureDrop(oldIndex, newIndex))
                                        ?.call();
                                  },
                                  itemBuilder: (itemContext, index) {
                                    final loadedEntry = requiresLoad
                                        ? null
                                        : queueEntries[index];
                                    final entry = loadedEntry == null
                                        ? previews[index]
                                        : (
                                            id: loadedEntry.id,
                                            kind: loadedEntry.kind,
                                            title: loadedEntry.title,
                                            trackCount:
                                                loadedEntry.tracks.length,
                                            firstTrack:
                                                loadedEntry.tracks.firstOrNull,
                                          );
                                    return _AnimatedQueueEntryCard(
                                      key: ValueKey(entry.id),
                                      content: (entry, index, i18n.language),
                                      onRemove: () =>
                                          unawaited(_removeEntry(entry.id)),
                                      builder: (cardContext, triggerRemove) {
                                        final firstTrack = entry.firstTrack;
                                        final itemTitle =
                                            entry.kind ==
                                                PlaybackQueueEntryKind.work
                                            ? i18n.tr('audio_count', {
                                                'count': entry.trackCount,
                                              })
                                            : entry.title;
                                        return _QueueAudioEditCard(
                                          track: firstTrack,
                                          title: itemTitle,
                                          fallbackWorkTitle: entry.title,
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
                                                child: Listener(
                                                  behavior:
                                                      HitTestBehavior.opaque,
                                                  onPointerDown: (event) =>
                                                      _startQueueDrag(
                                                        event,
                                                        cardContext,
                                                      ),
                                                  child: const SizedBox(
                                                    width: 40,
                                                    height: 40,
                                                    child: Center(
                                                      child: Icon(
                                                        Icons
                                                            .drag_handle_rounded,
                                                        size: 22,
                                                      ),
                                                    ),
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
                          child: sectionHeading(i18n.tr('queue_added_audio')),
                        ),
                      ],
                    );
                    final addedToQueuePane = PageHeaderInset(
                      topInset: 0,
                      child: Listener(
                        onPointerMove: _updateQueueDrag,
                        onPointerUp: _finishQueueDrag,
                        onPointerCancel: _finishQueueDrag,
                        child: ScrollActivityGate(child: addedToQueueSection),
                      ),
                    );

                    final sectionTopOffset = isLandscape
                        ? headerHeight
                        : AppSpacing.xs;

                    final playlistAudioSection = DecoratedBox(
                      decoration: BoxDecoration(color: playlistAreaBackground),
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: ListView.builder(
                              padding: horizontalPadding.copyWith(
                                top: sectionTopOffset + 44,
                                bottom: AppSpacing.xs,
                              ),
                              itemCount: ordinarySessions.length,
                              itemBuilder: (context, index) {
                                final source = ordinarySessions[index];
                                return _QueueSourceAudioTile(
                                  queueSessionId: sessionId,
                                  source: source,
                                );
                              },
                            ).withWindowsSmoothScroll(),
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
                            child: sectionHeading(
                              i18n.tr('playback_list_audio'),
                            ),
                          ),
                        ],
                      ),
                    );

                    if (isLandscape) {
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: addedToQueuePane),
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
                          Expanded(child: addedToQueuePane),
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
    return PopScope<void>(onPopInvokedWithResult: _handlePop, child: page);
  }
}

class _QueueSourceAudioTile extends ConsumerWidget {
  const _QueueSourceAudioTile({
    required this.queueSessionId,
    required this.source,
  });
  final String queueSessionId;
  final PlaybackDirectoryEntry source;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final paths = ref.read(audioPathCoordinatorProvider);
    final queueCoordinator = ref.read(playbackQueueCoordinatorProvider);
    final track = paths.sessionTrackForPath(source.id, source.currentTrackPath);
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
      fallbackWorkTitle: track.displayName,
      color: playlistAreaBackground,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: i18n.tr('add_audio_to_queue'),
            style: appIconButtonStyle(
              IconButton.styleFrom(
                minimumSize: const Size.square(44),
                maximumSize: const Size.square(44),
                padding: EdgeInsets.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
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
              style: appIconButtonStyle(
                IconButton.styleFrom(
                  minimumSize: const Size.square(44),
                  maximumSize: const Size.square(44),
                  padding: EdgeInsets.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
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
    required this.fallbackWorkTitle,
    required this.trailing,
    this.color,
  });

  final MusicTrack? track;
  final String title;
  final String fallbackWorkTitle;
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
    final workTitle = switch (resolvedTrack) {
      null => fallbackWorkTitle,
      final track => _workTitle(ref, track),
    };
    final coverSize = coverProgressInnerDimension(playlistCoverSize);
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: color ?? cs.surface,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shape: playlistRowShape,
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: playlistRowHeight),
        child: PlaylistAudioRow(
          cover: SessionCoverProgressRing(
            size: playlistCoverSize,
            child: CoverArtworkFrame(
              borderRadius: BorderRadius.circular(coverSize / 2),
              child: resolvedTrack == null
                  ? const CoverFallbackArtwork()
                  : QueueTrackCover(
                      track: resolvedTrack,
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
          labels: MarqueePauseScope(
            isPaused: false,
            hoverToRun: defaultTargetPlatform == TargetPlatform.windows,
            child: PlaylistAudioLabels(
              workTitle: workTitle,
              title: TextSpan(text: title),
              semanticsLabel: title,
            ),
          ),
          actions: trailing,
        ),
      ),
    );
  }

  String _workTitle(WidgetRef ref, MusicTrack track) {
    final paths = ref.read(audioPathCoordinatorProvider);
    if (track.isRemoteAsmr) return paths.workTitleForTrack(track);

    final settings = ref.read(settingsRepositoryProvider);
    final mode = ref.watch(
      settingsStateProvider.select(
        (state) =>
            state.value?.workNameDisplay ??
            settings.slice.state.workNameDisplay,
      ),
    );
    final target = ref
        .read(libraryFacadeProvider)
        .audioDetailTargetForTrack(track);
    if (mode == WorkNameDisplay.workTitle) {
      final title = ref.watch(
        libraryDetailForTargetProvider(
          target,
        ).select((detail) => detail.value?.workTitle.trim() ?? ''),
      );
      if (title.isNotEmpty) return title;
    }

    if (track.isSingle) {
      return PathDisplay.fileName(track.path, withoutExtension: true);
    }
    final folder = PathDisplay.folderName(target.targetPath);
    final groupTitle = track.groupTitle.trim();
    if (folder.isNotEmpty) {
      return groupTitle.toLowerCase() == folder.toLowerCase()
          ? groupTitle
          : folder;
    }
    return groupTitle.isNotEmpty ? groupTitle : track.displayName;
  }
}

class _AnimatedQueueEntryCard extends StatefulWidget {
  final (PlaybackQueueEntryPreview, int, AppLanguage) content;
  final Widget Function(BuildContext context, VoidCallback triggerRemove)
  builder;
  final VoidCallback onRemove;

  const _AnimatedQueueEntryCard({
    super.key,
    required this.content,
    required this.builder,
    required this.onRemove,
  });

  @override
  State<_AnimatedQueueEntryCard> createState() =>
      _AnimatedQueueEntryCardState();
}

class _AnimatedQueueEntryCardState extends State<_AnimatedQueueEntryCard> {
  bool _isRemoving = false;
  late Widget _card = widget.builder(context, _triggerRemove);

  @override
  void didUpdateWidget(covariant _AnimatedQueueEntryCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The reorderable sliver calls its builder on pointer moves. Reuse the
    // artwork and labels while the entry data, index and language are stable.
    if (oldWidget.content != widget.content) {
      _card = widget.builder(context, _triggerRemove);
    }
  }

  void _triggerRemove() {
    if (_isRemoving) return;
    unawaited(
      AppInteractionFeedback.trigger(AppInteractionFeedbackType.destructive),
    );
    setState(() {
      _isRemoving = true;
    });
    widget.onRemove();
  }

  @override
  Widget build(BuildContext context) {
    return UndoableRemovalTransition(
      hidden: _isRemoving,
      duration: _queueEntryRemovalDuration,
      retainFrameWhenMuted: true,
      child: _card,
    );
  }
}

class _OrdinarySourceSessions {
  const _OrdinarySourceSessions(this.sessions);

  final List<PlaybackDirectoryEntry> sessions;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! _OrdinarySourceSessions ||
        other.sessions.length != sessions.length) {
      return false;
    }
    for (var i = 0; i < sessions.length; i++) {
      if (sessions[i].id != other.sessions[i].id ||
          sessions[i].currentTrackPath != other.sessions[i].currentTrackPath) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(
    sessions.map(
      (session) => Object.hash(session.id, session.currentTrackPath),
    ),
  );
}
