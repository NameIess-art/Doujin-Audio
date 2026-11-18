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
import '../../../../app/theme/app_design_tokens.dart';
import '../../../../app/theme/app_styles.dart';
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
import '../../../../core/widgets/file_tree_expansion_motion.dart';
import '../../../../core/widgets/file_tree_row.dart';
import '../../../../core/widgets/mobile_overlay_inset.dart';
import '../../../../core/widgets/operation_feedback.dart';
import '../../../../core/widgets/page_header_inset.dart';
import '../../../../core/widgets/scroll_activity_gate.dart';
import '../../../../core/widgets/top_page_header.dart';
import '../../../../core/widgets/windows_smooth_scroll_controller.dart';
import '../../application/audio_state_services.dart';
import '../../application/session_switcher_tree.dart';
import '../../domain/playback_queue.dart';
import '../../../library/domain/library_node.dart';
import '../../../settings/application/settings_state.dart';
import 'playlist_shared_helpers.dart';

import 'playback_queue_cover.dart';

const _queueEntryRemovalDuration = Duration(milliseconds: 250);
const _queueEntryPageSize = 128;
const _queueChildRowMinHeight = 48.0;

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
    extends ConsumerState<PlaybackQueueAudioEditPage>
    with SingleTickerProviderStateMixin {
  final _addedQueueScrollController = WindowsSmoothScrollController();
  final _addedQueueSectionKey = GlobalKey();
  final _addedTrees = <String, _QueueEditorTree>{};
  late final _QueueExpansionMotion _treeMotion;
  final _loadingAddedTrees = <String, Object>{};
  Completer<void>? _dragFinished;
  String? _draggedEntryId;
  int? _draggedIndex;
  VoidCallback? _pendingDrop;
  bool _didPop = false;
  int? _dragPointerId;
  double? _latestDragPointerY;
  double _dragRowTopOffset = 0;
  double _addedQueueTopInset = 0;
  bool _isTopAutoScrolling = false;
  PlaybackQueueDefinition? _pagedQueue;
  final List<PlaybackQueueEntryPreview> _entryPreviews = [];
  bool _pageLoading = false;
  bool _pageFailed = false;
  bool _pageExhausted = false;
  bool _savingRestoredDrop = false;
  bool _showLocalLibrary = false;

  @override
  void initState() {
    super.initState();
    _treeMotion = _QueueExpansionMotion(this, () {
      if (mounted && !_didPop) setState(_treeMotion.finish);
    });
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
      // Changing itemCount cancels an active Flutter reorder. Keep reads
      // running, but publish the page once the drag proxy has been removed.
      while (_dragFinished != null) {
        await _dragFinished!.future;
      }
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
      _dragRowTopOffset = event.position.dy - box.localToGlobal(Offset.zero).dy;
    } else {
      _dragRowTopOffset = 0;
    }
  }

  void _updateQueueDrag(PointerMoveEvent event) {
    if (event.pointer != _dragPointerId) return;
    _latestDragPointerY = event.position.dy;
    if (_draggedIndex != null &&
        !_isTopAutoScrolling &&
        _computeTopOverDrag() > 0) {
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
    final proxyTop = pointerY - _dragRowTopOffset;
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
      if (event is PointerCancelEvent) _finishQueueReorder(_dragFinished);
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

  void _finishQueueReorder(Completer<void>? drag) {
    if (drag == null || !identical(drag, _dragFinished)) return;
    _treeMotion.finish();
    _addedTrees.remove(_draggedEntryId);
    _dragFinished = null;
    _draggedEntryId = null;
    _draggedIndex = null;
    if (mounted && !_didPop) setState(() {});
    drag.complete();
  }

  Future<void> _toggleAddedTree(String id, PlaybackQueueEntry? loaded) async {
    if (_dragFinished != null) return;
    if (_addedTrees.containsKey(id)) {
      setState(
        () => _treeMotion.toggleRoot(
          id,
          _addedTrees,
          !MediaQuery.disableAnimationsOf(context),
        ),
      );
      return;
    }
    if (_loadingAddedTrees.containsKey(id)) return;
    final request = Object();
    setState(() => _loadingAddedTrees[id] = request);
    bool isCurrent() => identical(_loadingAddedTrees[id], request);
    try {
      final entry =
          loaded ??
          await ref
              .read(playbackFacadeProvider)
              .loadQueueEntry(widget.sessionId, id);
      while (mounted && !_didPop && isCurrent() && _dragFinished != null) {
        await _dragFinished!.future;
      }
      if (!mounted || _didPop || !isCurrent()) return;
      if (entry == null) throw StateError('Queue entry no longer exists');
      setState(() {
        _addedTrees[id] = _treeForAddedEntry(entry);
        if (!MediaQuery.disableAnimationsOf(context)) _treeMotion.openRoot(id);
      });
    } catch (error, stackTrace) {
      if (mounted && !_didPop && isCurrent()) {
        _showQueueEditorReadFailure(context, ref, error, stackTrace);
      }
    } finally {
      if (mounted && !_didPop && isCurrent()) {
        setState(() => _loadingAddedTrees.remove(id));
      }
    }
  }

  _QueueEditorTree _treeForAddedEntry(
    PlaybackQueueEntry entry, {
    Set<String>? expanded,
  }) {
    final track = entry.tracks.firstOrNull;
    final root =
        entry.workRootPath ??
        (track == null
            ? null
            : ref
                  .read(audioPathCoordinatorProvider)
                  .workRootForTrack(track.path, knownTrack: track));
    return _QueueEditorTree(
      entry.tracks,
      root,
      entry: entry,
      expanded: expanded,
    );
  }

  Future<void> _removeEntry(
    String entryId, {
    UndoableRemovalKey? key,
    PlaybackQueueEntry? snapshot,
    List<int>? trackIndices,
  }) async {
    unawaited(
      AppInteractionFeedback.trigger(AppInteractionFeedbackType.destructive),
    );
    final route = ModalRoute.of(context);
    final returnContext = widget.returnContext;
    final playback = ref.read(playbackFacadeProvider);
    final service = ref.read(undoableRemovalServiceProvider);
    final sessionId = widget.sessionId;

    if (snapshot == null) {
      await Future<void>.delayed(_queueEntryRemovalDuration);
    }
    List<MusicTrack>? tracks;
    // Updating the sliver and mounting undo feedback would change the frame
    // being animated out. The removal still needs to be staged after disposal.
    if (_didPop) await route?.completed;
    if (!await service.stage(
      UndoableRemovalAction(
        key: key ?? playbackQueueEntryRemovalKey(sessionId, entryId),
        prepare: snapshot == null
            ? null
            : () async {
                tracks = await playback.resolveQueueEntryTracksForEdit(
                  sessionId,
                  snapshot,
                  trackIndices!,
                );
                return tracks?.isNotEmpty == true;
              },
        commit: () => playback.removePlaybackQueueEntry(
          sessionId,
          entryId,
          tracks: tracks,
        ),
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
    _treeMotion.dispose();
    _dragFinished?.complete();
    _dragFinished = null;
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
    final showLocalLibrary = _showLocalLibrary;
    final ordinarySessions = showLocalLibrary
        ? const <PlaybackDirectoryEntry>[]
        : ref
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
    final localWorks = showLocalLibrary
        ? ref.watch(libraryListUiProvider.select((state) => state.rawTree))
        : const <LibraryNode>[];
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

    Widget sectionHeading(Widget child) {
      return Listener(
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: horizontalPadding.copyWith(bottom: AppSpacing.xs),
          child: Align(alignment: Alignment.centerLeft, child: child),
        ),
      );
    }

    Widget sectionCapsule(String label, IconData icon) {
      return HeaderFloatingSurface(
        height: 32,
        radius: 16,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: cs.primary),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label,
                style: appPageHeaderTitleStyle(context),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }

    Widget sourceTab(String label, IconData icon, {required bool local}) {
      final selected = showLocalLibrary == local;
      return Semantics(
        selected: selected,
        child: selected
            ? sectionCapsule(label, icon)
            : TextButton(
                onPressed: () => setState(() => _showLocalLibrary = local),
                style: TextButton.styleFrom(
                  foregroundColor: cs.onSurfaceVariant,
                  minimumSize: const Size(0, 32),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  textStyle: appPageHeaderTitleStyle(context),
                ),
                child: Text(label, overflow: TextOverflow.ellipsis),
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
                    final filterHidden = removalState.hiddenKeys.any(
                      (key) =>
                          key.namespace == 'playback-queue-entry' &&
                          key.id.startsWith('$sessionId:'),
                    );
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

                    final rows = _QueueEditorRows(
                      rowCount,
                      _addedTrees.isEmpty
                          ? null
                          : (index) {
                              final id = idAt(index);
                              var tree = _addedTrees[id];
                              if (tree == null) return const [];
                              final loaded = requiresLoad
                                  ? null
                                  : queueEntries[index];
                              if (loaded != null &&
                                  !identical(tree.entry, loaded)) {
                                tree = _addedTrees[id] = _treeForAddedEntry(
                                  loaded,
                                  expanded: tree.expanded,
                                );
                              }
                              final hasHidden = _hiddenKeysContainChildren(
                                removalState,
                                sessionId,
                                id,
                              );
                              final children = tree.rows(
                                hiddenRevision: hasHidden
                                    ? removalState.hiddenKeys
                                    : null,
                                hidden: hasHidden
                                    ? (node) => removalState.isHidden(
                                        _queueChildRemovalKey(
                                          sessionId,
                                          id,
                                          node,
                                        ),
                                      )
                                    : null,
                              );
                              return _treeMotion.project(context, id, children);
                            },
                    );

                    VoidCallback? captureDrop(int oldRow, int newRow) {
                      if (oldRow < 0 ||
                          oldRow >= rows.length ||
                          newRow < 0 ||
                          newRow > rows.length) {
                        return null;
                      }
                      final origin = rows.at(oldRow);
                      if (origin.child != null) return null;
                      final oldIndex = origin.root;
                      final destination = newRow == rows.length
                          ? null
                          : rows.at(newRow);
                      final int newIndex;
                      if (destination == null) {
                        newIndex = rowCount;
                      } else if (destination.child == null) {
                        newIndex = destination.root;
                      } else if (destination.root == oldIndex) {
                        return null;
                      } else {
                        newIndex = destination.root + (oldRow < newRow ? 1 : 0);
                      }
                      if (oldIndex == newIndex ||
                          oldIndex + 1 == newIndex ||
                          oldIndex < 0 ||
                          oldIndex >= rowCount ||
                          newIndex < 0 ||
                          newIndex > rowCount) {
                        return null;
                      }
                      final sourceId = idAt(oldIndex);
                      final sourceKind = requiresLoad
                          ? previews[oldIndex].kind
                          : queueEntries[oldIndex].kind;
                      if (sourceKind != PlaybackQueueEntryKind.work) {
                        return null;
                      }
                      final afterLast = newIndex == rowCount;
                      final targetId = idAt(
                        afterLast ? newIndex - 1 : newIndex,
                      );
                      final returnContext = widget.returnContext;
                      int insertionIndex<T>(
                        List<T> entries,
                        String Function(T) idOf,
                      ) {
                        if (afterLast && !hasMore) return entries.length;
                        final target = entries.indexWhere(
                          (entry) => idOf(entry) == targetId,
                        );
                        if (target < 0) return -1;
                        return target + (afterLast ? 1 : 0);
                      }

                      Future<void> commit() async {
                        int? oldPreviewIndex;
                        try {
                          if (requiresLoad &&
                              mounted &&
                              !_didPop &&
                              identical(_pagedQueue, queue)) {
                            if (_savingRestoredDrop) return;
                            final source = _entryPreviews.indexWhere(
                              (entry) => entry.id == sourceId,
                            );
                            final target = insertionIndex(
                              _entryPreviews,
                              (entry) => entry.id,
                            );
                            if (source < 0 || target < 0) return;
                            oldPreviewIndex = source;
                            // The sliver removes the drag proxy now, while the
                            // full queue can still be loading from storage.
                            setState(() {
                              _savingRestoredDrop = true;
                              final item = _entryPreviews.removeAt(source);
                              _entryPreviews.insert(
                                source < target ? target - 1 : target,
                                item,
                              );
                            });
                          }
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
                          final target = insertionIndex(
                            entries,
                            (entry) => entry.id,
                          );
                          if (source < 0 || target < 0) return;
                          await playback.reorderPlaybackQueueEntry(
                            sessionId,
                            source,
                            target,
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
                        } finally {
                          if (oldPreviewIndex case final previousIndex?
                              when mounted && !_didPop) {
                            setState(() {
                              _savingRestoredDrop = false;
                              if (identical(_pagedQueue, queue) &&
                                  playback
                                          .sessionById(sessionId)
                                          ?.queueLoadingRequired ==
                                      true) {
                                final index = _entryPreviews.indexWhere(
                                  (entry) => entry.id == sourceId,
                                );
                                if (index >= 0) {
                                  final item = _entryPreviews.removeAt(index);
                                  _entryPreviews.insert(previousIndex, item);
                                }
                              }
                            });
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
                                  proxyDecorator: (child, index, animation) {
                                    final drag = _dragFinished;
                                    return _QueueDragProxy(
                                      onDisposed: () =>
                                          _finishQueueReorder(drag),
                                      child: RepaintBoundary(
                                        child: Material(
                                          color: Color.alphaBlend(
                                            cs.primary.withValues(alpha: 0.18),
                                            cs.surface,
                                          ),
                                          borderRadius:
                                              FileTreeRow.borderRadius,
                                          child: child,
                                        ),
                                      ),
                                    );
                                  },
                                  itemCount: rows.length,
                                  footer: footer,
                                  onReorderStart: (index) {
                                    _finishQueueReorder(_dragFinished);
                                    setState(() {
                                      _treeMotion.pause();
                                      _dragFinished = Completer<void>();
                                      _draggedIndex = index;
                                      final id = idAt(rows.at(index).root);
                                      _draggedEntryId = id;
                                      _loadingAddedTrees.remove(id);
                                    });
                                    _pendingDrop = null;
                                    unawaited(
                                      AppInteractionFeedback.trigger(
                                        AppInteractionFeedbackType.confirmation,
                                      ),
                                    );
                                    UiInteractionCoordinator.instance
                                        .beginInteraction(this);
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
                                    final commit =
                                        pendingDrop ??
                                        captureDrop(oldIndex, newIndex);
                                    _finishQueueReorder(_dragFinished);
                                    commit?.call();
                                  },
                                  itemBuilder: (itemContext, index) {
                                    final (:root, :child, :childIndex) = rows
                                        .at(index);
                                    final loadedEntry = requiresLoad
                                        ? null
                                        : queueEntries[root];
                                    final entry = loadedEntry == null
                                        ? previews[root]
                                        : (
                                            id: loadedEntry.id,
                                            kind: loadedEntry.kind,
                                            title: loadedEntry.title,
                                            trackCount:
                                                loadedEntry.tracks.length,
                                            firstTrack:
                                                loadedEntry.tracks.firstOrNull,
                                          );
                                    final tree = _addedTrees[entry.id];
                                    final draggingThis =
                                        _draggedEntryId == entry.id;
                                    if (child != null) {
                                      final node = child.node;
                                      final key = ValueKey((
                                        entry.id,
                                        node.key,
                                      ));
                                      // Keep itemCount fixed while Flutter owns the
                                      // drag. The dragged folder's children fold away.
                                      if (draggingThis || tree == null) {
                                        return SizedBox.shrink(key: key);
                                      }
                                      return _treeMotion.wrap(
                                        entry.id,
                                        childIndex,
                                        _QueueAudioRow(
                                          key: key,
                                          title: node.title,
                                          depth: child.depth,
                                          folder: node.isFolder,
                                          removing: true,
                                          count: node.isFolder
                                              ? tree.count(node)
                                              : null,
                                          expanded: tree.expanded.contains(
                                            node.key,
                                          ),
                                          toggle: node.isFolder
                                              ? () {
                                                  if (_dragFinished == null) {
                                                    setState(
                                                      () => _treeMotion
                                                          .toggleFolder(
                                                            entry.id,
                                                            tree,
                                                            node,
                                                            !MediaQuery.disableAnimationsOf(
                                                              context,
                                                            ),
                                                          ),
                                                    );
                                                  }
                                                }
                                              : null,
                                          action: () => unawaited(
                                            _removeEntry(
                                              entry.id,
                                              key: _queueChildRemovalKey(
                                                sessionId,
                                                entry.id,
                                                node,
                                              ),
                                              snapshot: tree.entry,
                                              trackIndices: tree
                                                  .trackIndices(node)
                                                  .toList(),
                                            ),
                                          ),
                                        ),
                                      );
                                    }
                                    final isFolder =
                                        entry.kind ==
                                        PlaybackQueueEntryKind.work;
                                    final dragIndex =
                                        isFolder &&
                                            !(requiresLoad &&
                                                _savingRestoredDrop)
                                        ? index
                                        : null;
                                    final expanded =
                                        tree != null &&
                                        !draggingThis &&
                                        !_treeMotion.isClosingRoot(entry.id);
                                    final loading = _loadingAddedTrees
                                        .containsKey(entry.id);
                                    return _AnimatedQueueEntry(
                                      key: ValueKey(entry.id),
                                      content: (
                                        entry,
                                        loadedEntry,
                                        dragIndex,
                                        expanded,
                                        loading,
                                        expanded
                                            ? tree.count(tree.root)
                                            : entry.trackCount,
                                      ),
                                      onRemove: () {
                                        if (_addedTrees.remove(entry.id) !=
                                            null) {
                                          setState(() {});
                                        }
                                        unawaited(_removeEntry(entry.id));
                                      },
                                      builder: (triggerRemove) {
                                        final row = _QueueAudioRow(
                                          track: entry.firstTrack,
                                          title: entry.title,
                                          folder: isFolder,
                                          removing: true,
                                          count: expanded
                                              ? tree.count(tree.root)
                                              : entry.trackCount,
                                          expanded: expanded,
                                          loading: loading,
                                          toggle: isFolder
                                              ? () => unawaited(
                                                  _toggleAddedTree(
                                                    entry.id,
                                                    loadedEntry,
                                                  ),
                                                )
                                              : null,
                                          action: triggerRemove,
                                        );
                                        return dragIndex == null
                                            ? row
                                            : Builder(
                                                builder: (rowContext) =>
                                                    ReorderableDelayedDragStartListener(
                                                      index: dragIndex,
                                                      child: Listener(
                                                        onPointerDown:
                                                            (event) =>
                                                                _startQueueDrag(
                                                                  event,
                                                                  rowContext,
                                                                ),
                                                        child: row,
                                                      ),
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
                          child: sectionHeading(
                            sectionCapsule(
                              i18n.tr('queue_added_audio'),
                              Icons.playlist_play_rounded,
                            ),
                          ),
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

                    final sourceSection = DecoratedBox(
                      decoration: BoxDecoration(color: playlistAreaBackground),
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: _QueueAudioSourceList(
                              key: ValueKey(showLocalLibrary),
                              showLibrary: showLocalLibrary,
                              works: localWorks,
                              sessions: ordinarySessions,
                              sessionId: sessionId,
                              padding: horizontalPadding.copyWith(
                                top: sectionTopOffset + 44,
                                bottom: AppSpacing.xs,
                              ),
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
                            child: sectionHeading(
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Flexible(
                                    child: sourceTab(
                                      i18n.tr('playback_sessions'),
                                      Icons.playlist_play_rounded,
                                      local: false,
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  Flexible(
                                    child: sourceTab(
                                      i18n.tr('show_local_library'),
                                      Icons.library_music_rounded,
                                      local: true,
                                    ),
                                  ),
                                ],
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
                          Expanded(child: addedToQueuePane),
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            child: VerticalDivider(
                              width: 1,
                              thickness: 1,
                              color: cs.outlineVariant.withValues(alpha: 0.35),
                            ),
                          ),
                          Expanded(child: sourceSection),
                        ],
                      );
                    } else {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: addedToQueuePane),
                          Expanded(child: sourceSection),
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

UndoableRemovalKey _queueChildRemovalKey(
  String sessionId,
  String entryId,
  SessionSwitcherNode node,
) {
  final track = node.track;
  final key = track == null
      ? node.key
      : 'track:${Uri.encodeComponent(track.path)}:'
            '${Uri.encodeComponent('${track.remoteMetadata?['trackRelativePath'] ?? ''}')}';
  return UndoableRemovalKey('playback-queue-child', '$sessionId:$entryId:$key');
}

bool _hiddenKeysContainChildren(
  UndoableRemovalState state,
  String sessionId,
  String entryId,
) => state.hiddenKeys.any(
  (key) =>
      key.namespace == 'playback-queue-child' &&
      key.id.startsWith('$sessionId:$entryId:'),
);

class _QueueDragProxy extends StatefulWidget {
  const _QueueDragProxy({required this.child, required this.onDisposed});

  final Widget child;
  final VoidCallback onDisposed;

  @override
  State<_QueueDragProxy> createState() => _QueueDragProxyState();
}

class _QueueDragProxyState extends State<_QueueDragProxy> {
  @override
  void dispose() {
    final onDisposed = widget.onDisposed;
    WidgetsBinding.instance.addPostFrameCallback((_) => onDisposed());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

typedef _QueueChildRow = ({SessionSwitcherNode node, int depth});

typedef _QueueBranch = ({String entryId, String? folderKey});

class _QueueExpansionMotion {
  _QueueExpansionMotion(TickerProvider vsync, VoidCallback onSettled)
    : _motion = FileTreeExpansionMotion(vsync, onSettled);

  final FileTreeExpansionMotion<_QueueBranch, _QueueChildRow> _motion;

  bool isClosingRoot(String id) =>
      _motion.isClosing((entryId: id, folderKey: null));

  void openRoot(String id) {
    finish();
    _motion.start((entryId: id, folderKey: null));
  }

  void toggleRoot(
    String id,
    Map<String, _QueueEditorTree> trees,
    bool animate, {
    VoidCallback? onClosed,
  }) {
    final tree = trees[id]!;
    final branch = (entryId: id, folderKey: null);
    final opening = _motion.isClosing(branch);
    final progress = _motion.progressFor(branch);
    _motion.finish(complete: !opening);

    void close() {
      trees.remove(id);
      onClosed?.call();
    }

    if (opening) {
      if (animate) _motion.start(branch, from: progress);
    } else if (animate && tree.projectedRows.isNotEmpty) {
      _motion.start(
        branch,
        outgoing: tree.projectedRows,
        from: progress,
        onFinish: close,
      );
    } else {
      close();
    }
  }

  void toggleFolder(
    String id,
    _QueueEditorTree tree,
    SessionSwitcherNode folder,
    bool animate,
  ) {
    final branch = (entryId: id, folderKey: folder.key);
    final progress = _motion.progressFor(branch);
    finish();
    final outgoing = tree.expanded.contains(folder.key)
        ? tree.projectedRows
        : null;
    tree.toggle(folder);
    if (animate) _motion.start(branch, outgoing: outgoing, from: progress);
  }

  List<_QueueChildRow> project(
    BuildContext context,
    String id,
    List<_QueueChildRow> rows,
  ) {
    if (_motion.branch?.entryId != id) return rows;
    return _motion.project(
      context,
      rows,
      parentIndex: (rows, branch) {
        if (branch.folderKey == null) return -1;
        final index = rows.indexWhere(
          (row) => row.node.key == branch.folderKey,
        );
        return index < 0 ? null : index;
      },
      depth: (row) => row.depth,
      minRowHeight: _queueChildRowMinHeight,
    );
  }

  Widget wrap(String id, int childIndex, Widget child) =>
      _motion.branch?.entryId == id ? _motion.wrap(childIndex, child) : child;

  void pause() => _motion.pause();
  void finish() => _motion.finish();
  void dispose() => _motion.dispose();
}

class _QueueEditorTree {
  _QueueEditorTree(
    this.tracks,
    this.workRoot, {
    this.entry,
    Set<String>? expanded,
  }) : expanded = expanded ?? <String>{} {
    for (var i = 0; i < tracks.length; i++) {
      final track = tracks[i];
      root
          .folderForTrack(track, workRoot: workRoot)
          .children
          .add(
            SessionSwitcherNode.track(
              track,
              selected: false,
              queueIndex: i,
              sourceIndex: i,
            ),
          );
    }
    root.sortChildrenNaturally();
    _count(root, null);
  }

  final List<MusicTrack> tracks;
  final String? workRoot;
  final PlaybackQueueEntry? entry;
  final Set<String> expanded;
  final root = SessionSwitcherNode.folder('');
  final _counts = <SessionSwitcherNode, int>{};
  List<_QueueChildRow>? _rows;
  List<_QueueChildRow> get projectedRows => _rows ?? const [];
  Set<UndoableRemovalKey>? _hiddenRevision;

  int _count(
    SessionSwitcherNode node,
    bool Function(SessionSwitcherNode)? hidden,
  ) {
    if (hidden?.call(node) == true) return 0;
    if (!node.isFolder) return 1;
    return _counts[node] = node.children.fold<int>(
      0,
      (count, child) => count + _count(child, hidden),
    );
  }

  int count(SessionSwitcherNode node) => _counts[node] ?? 0;

  void toggle(SessionSwitcherNode node) {
    if (!expanded.remove(node.key)) expanded.add(node.key);
    _rows = null;
  }

  List<_QueueChildRow> rows({
    Set<UndoableRemovalKey>? hiddenRevision,
    bool Function(SessionSwitcherNode)? hidden,
  }) {
    final changed = !identical(hiddenRevision, _hiddenRevision);
    if (_rows != null && !changed) return _rows!;
    if (changed) _count(root, hidden);
    _hiddenRevision = hiddenRevision;
    final rows = <_QueueChildRow>[];
    void append(SessionSwitcherNode folder, int depth) {
      for (final node in folder.children) {
        if (hidden?.call(node) == true) continue;
        rows.add((node: node, depth: depth));
        if (expanded.contains(node.key)) append(node, depth + 1);
      }
    }

    append(root, 1);
    return _rows = rows;
  }

  Iterable<int> trackIndices(SessionSwitcherNode node) sync* {
    if (node.isFolder) {
      for (final child in node.children) {
        yield* trackIndices(child);
      }
    } else {
      yield node.sourceIndex;
    }
  }
}

// Collapsed roots remain implicit so large lists don't allocate a row model
// for each root. Only open folders contribute groups of extra row indices.
class _QueueEditorRows {
  _QueueEditorRows(
    this.rootCount,
    List<_QueueChildRow> Function(int)? children,
  ) {
    if (children == null) return;
    for (var root = 0; root < rootCount; root++) {
      final rows = children(root);
      if (rows.isEmpty) continue;
      _groups.add((root: root, first: root + 1 + _childCount, rows: rows));
      _childCount += rows.length;
    }
  }

  final int rootCount;
  final _groups = <({int root, int first, List<_QueueChildRow> rows})>[];
  int _childCount = 0;
  int get length => rootCount + _childCount;

  ({int root, _QueueChildRow? child, int childIndex}) at(int index) {
    var low = 0;
    var high = _groups.length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (_groups[middle].first <= index) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    if (low == 0) return (root: index, child: null, childIndex: -1);
    final group = _groups[low - 1];
    final offset = index - group.first;
    return offset < group.rows.length
        ? (root: group.root, child: group.rows[offset], childIndex: offset)
        : (
            root: group.root + 1 + offset - group.rows.length,
            child: null,
            childIndex: -1,
          );
  }
}

class _QueueAudioSourceList extends ConsumerStatefulWidget {
  const _QueueAudioSourceList({
    super.key,
    required this.showLibrary,
    required this.works,
    required this.sessions,
    required this.sessionId,
    required this.padding,
  });

  final bool showLibrary;
  final List<LibraryNode> works;
  final List<PlaybackDirectoryEntry> sessions;
  final String sessionId;
  final EdgeInsetsGeometry padding;

  @override
  ConsumerState<_QueueAudioSourceList> createState() =>
      _QueueAudioSourceListState();
}

class _QueueAudioSourceListState extends ConsumerState<_QueueAudioSourceList>
    with SingleTickerProviderStateMixin {
  final _trees = <String, _QueueEditorTree>{};
  late final _QueueExpansionMotion _treeMotion;
  final _loading = <String, Object>{};
  final _sourcePaths = <String, String>{};

  @override
  void initState() {
    super.initState();
    _treeMotion = _QueueExpansionMotion(this, () {
      if (mounted) setState(_treeMotion.finish);
    });
  }

  @override
  void dispose() {
    _treeMotion.dispose();
    super.dispose();
  }

  String _idAt(int index) =>
      widget.showLibrary ? widget.works[index].path : widget.sessions[index].id;

  Future<List<MusicTrack>> _loadTracks(
    MusicTrack track,
    FolderNode? work,
  ) async {
    if (work != null) return work.allTracks;
    final tracks = await ref
        .read(audioPathCoordinatorProvider)
        .tracksInSameWorkAsync(track);
    return tracks.isEmpty ? [track] : tracks;
  }

  Future<void> _toggle(String id, MusicTrack track, FolderNode? work) async {
    if (_trees.containsKey(id)) {
      setState(() {
        _treeMotion.toggleRoot(
          id,
          _trees,
          !MediaQuery.disableAnimationsOf(context),
          onClosed: () => _sourcePaths.remove(id),
        );
        _loading.remove(id);
      });
      return;
    }
    await _loadTree(id, track, work);
  }

  Future<void> _loadTree(String id, MusicTrack track, FolderNode? work) async {
    if (_loading.containsKey(id)) return;
    final request = Object();
    setState(() => _loading[id] = request);
    bool isCurrent() => identical(_loading[id], request);
    try {
      final paths = ref.read(audioPathCoordinatorProvider);
      final root =
          work?.path ?? paths.workRootForTrack(track.path, knownTrack: track);
      final tracks = await _loadTracks(track, work);
      if (!mounted || !isCurrent()) return;
      if (!widget.showLibrary) {
        final source = widget.sessions
            .where((source) => source.id == id)
            .firstOrNull;
        if (source == null) return;
        final current = paths.sessionTrackForPath(id, source.currentTrackPath);
        if (current?.groupKey != track.groupKey) return;
        _sourcePaths[id] = source.currentTrackPath;
      }
      setState(() {
        final opening = !_trees.containsKey(id);
        _trees[id] = _QueueEditorTree(
          tracks,
          root,
          expanded: _trees[id]?.expanded,
        );
        if (opening && !MediaQuery.disableAnimationsOf(context)) {
          _treeMotion.openRoot(id);
        }
      });
    } catch (error, stackTrace) {
      if (mounted && isCurrent()) {
        _showQueueEditorReadFailure(context, ref, error, stackTrace);
      }
    } finally {
      if (mounted && isCurrent()) setState(() => _loading.remove(id));
    }
  }

  Future<void> _add(
    MusicTrack track, {
    FolderNode? work,
    _QueueEditorTree? tree,
    SessionSwitcherNode? child,
  }) async {
    final queue = ref.read(playbackQueueCoordinatorProvider);
    final sessionId = widget.sessionId;
    unawaited(
      AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection),
    );
    try {
      if (child != null && !child.isFolder) {
        await queue.addTrack(sessionId, tree!.tracks[child.sourceIndex]);
      } else if (track.isSingle) {
        await queue.addTrack(sessionId, track);
      } else if (tree != null || work != null) {
        final tracks = child == null
            ? tree?.tracks ?? work!.allTracks
            : tree!
                  .trackIndices(child)
                  .map((index) => tree.tracks[index])
                  .toList();
        await queue.addWork(
          sessionId,
          track,
          selectedTracks: tracks,
          workRootPath: tree?.workRoot ?? work?.path,
        );
      } else {
        await queue.addWork(
          sessionId,
          track,
          selectedTracks: await _loadTracks(track, null),
        );
      }
    } catch (error, stackTrace) {
      if (mounted) _showQueueEditorReadFailure(context, ref, error, stackTrace);
    }
  }

  @override
  Widget build(BuildContext context) {
    final paths = ref.read(audioPathCoordinatorProvider);
    final showLibrary = widget.showLibrary;
    final roots = showLibrary ? widget.works.length : widget.sessions.length;
    MusicTrack? sessionTrack(PlaybackDirectoryEntry source) =>
        paths.sessionTrackForPath(source.id, source.currentTrackPath);

    if (_trees.isNotEmpty) {
      if (showLibrary) {
        for (final node in widget.works.whereType<FolderNode>()) {
          final opened = _trees[node.path];
          if (opened != null && !identical(opened.tracks, node.allTracks)) {
            _trees[node.path] = _QueueEditorTree(
              node.allTracks,
              node.path,
              expanded: opened.expanded,
            );
          }
        }
      } else {
        ref.listen(
          libraryStateProvider.select((state) => state.value?.contentRevision),
          (_, _) {
            for (final source in widget.sessions) {
              if (!_trees.containsKey(source.id)) continue;
              final track = sessionTrack(source);
              if (track != null && !track.isSingle) {
                unawaited(_loadTree(source.id, track, null));
              }
            }
          },
        );
        for (final source in widget.sessions) {
          if (_trees.containsKey(source.id) &&
              _sourcePaths[source.id] != source.currentTrackPath) {
            final track = sessionTrack(source);
            final opened = _trees[source.id]!;
            if (track == null ||
                track.groupKey != opened.tracks.firstOrNull?.groupKey) {
              _trees.remove(source.id);
              _sourcePaths.remove(source.id);
              _loading.remove(source.id);
            } else {
              _sourcePaths[source.id] = source.currentTrackPath;
            }
          }
        }
      }
    }

    if (showLibrary && roots == 0) {
      final i18n = ref.read(appLanguageProviderInstanceProvider);
      return Padding(
        padding: widget.padding.add(const EdgeInsets.only(top: AppSpacing.md)),
        child: Align(
          alignment: Alignment.topCenter,
          child: Text(i18n.tr('no_audio_files')),
        ),
      );
    }
    final rows = _QueueEditorRows(
      roots,
      _trees.isEmpty
          ? null
          : (i) {
              final id = _idAt(i);
              final tree = _trees[id];
              return tree == null
                  ? const []
                  : _treeMotion.project(context, id, tree.rows());
            },
    );
    return ListView.builder(
      key: PageStorageKey<bool>(showLibrary),
      padding: widget.padding,
      itemCount: rows.length,
      itemBuilder: (context, index) {
        final (:root, :child, :childIndex) = rows.at(index);
        final id = _idAt(root);
        final work = showLibrary && widget.works[root] is FolderNode
            ? widget.works[root] as FolderNode
            : null;
        final track = showLibrary
            ? (switch (widget.works[root]) {
                FolderNode() => work?.firstTrack,
                TrackNode(track: final track) => track,
                _ => null,
              })
            : sessionTrack(widget.sessions[root]);
        if (track == null) return const SizedBox.shrink();
        final tree = _trees[id];
        if (child == null) {
          return _QueueAudioRow(
            key: ValueKey(id),
            track: track,
            title: track.displayName,
            folder: !track.isSingle,
            subtitle: track.isSingle ? null : track.displayName,
            count: tree?.tracks.length ?? work?.totalTrackCount,
            expanded: tree != null && !_treeMotion.isClosingRoot(id),
            loading: _loading.containsKey(id) && tree == null,
            toggle: track.isSingle
                ? null
                : () => unawaited(_toggle(id, track, work)),
            action: () => unawaited(_add(track, work: work, tree: tree)),
          );
        }
        final node = child.node;
        return _treeMotion.wrap(
          id,
          childIndex,
          _QueueAudioRow(
            key: ValueKey((id, node.key)),
            title: node.title,
            depth: child.depth,
            folder: node.isFolder,
            count: node.isFolder ? tree!.count(node) : null,
            expanded: tree!.expanded.contains(node.key),
            toggle: node.isFolder
                ? () => setState(
                    () => _treeMotion.toggleFolder(
                      id,
                      tree,
                      node,
                      !MediaQuery.disableAnimationsOf(context),
                    ),
                  )
                : null,
            action: () =>
                unawaited(_add(track, work: work, tree: tree, child: node)),
          ),
        );
      },
    ).withWindowsSmoothScroll();
  }
}

void _showQueueEditorReadFailure(
  BuildContext context,
  WidgetRef ref,
  Object error,
  StackTrace stackTrace,
) {
  AppLogService.warning(
    'playback_queue_entry_expand_failed',
    error: error,
    stackTrace: stackTrace,
  );
  showAppSnackBar(
    context,
    ref.read(appLanguageProviderInstanceProvider).tr('operation_failed_retry'),
    tone: AppFeedbackTone.warning,
  );
}

class _QueueAudioRow extends ConsumerWidget {
  const _QueueAudioRow({
    super.key,
    this.track,
    required this.title,
    required this.folder,
    required this.action,
    this.depth = 0,
    this.removing = false,
    this.expanded = false,
    this.loading = false,
    this.subtitle,
    this.count,
    this.toggle,
  });

  final MusicTrack? track;
  final String title;
  final bool folder;
  final VoidCallback action;
  final int depth;
  final bool removing;
  final bool expanded;
  final bool loading;
  final String? subtitle;
  final int? count;
  final VoidCallback? toggle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final cs = Theme.of(context).colorScheme;
    final representative = track;
    final root = depth == 0;
    Widget? cover;
    if (root) {
      final library = ref.read(libraryFacadeProvider);
      cover = CoverArtworkFrame(
        showShadow: false,
        borderRadius: BorderRadius.circular(20),
        child: representative == null
            ? const CoverFallbackArtwork()
            : QueueTrackCover(
                track: representative,
                coverPath: library.resolvedPlaybackCoverPathForTrack(
                  representative,
                ),
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
      );
    }
    final addHint = folder
        ? (root ? 'add_work_to_queue' : 'add')
        : 'add_audio_to_queue';
    final tile = FileTreeRow(
      title: root && folder && representative != null
          ? _workTitle(ref, representative)
          : title,
      subtitle: folder && count != null
          ? i18n.tr('audio_count', {'count': count})
          : subtitle,
      depth: depth,
      minHeight: root && folder ? 64 : _queueChildRowMinHeight,
      titleMaxLines: !root && folder ? 1 : 2,
      verticalPadding: root && folder ? 4 : 2,
      reserveSubtitleSpace: folder,
      isFolder: folder,
      onTap: toggle,
      titleColor: expanded ? cs.primary : null,
      leading: root
          ? SizedBox.square(dimension: 40, child: cover)
          : Icon(
              folder
                  ? (expanded
                        ? AppDesignTokens.openFolderIcon
                        : AppDesignTokens.folderIcon)
                  : AppDesignTokens.audioFileIcon,
              size: AppDesignTokens.fileEntryIconSize,
              color: folder ? AppDesignTokens.folderIconColor : cs.primary,
            ),
      trailingSpacing: AppSpacing.xxs,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: IconButton(
              tooltip: i18n.tr(removing ? 'remove' : addHint),
              onPressed: action,
              style: appIconButtonStyle(
                IconButton.styleFrom(
                  foregroundColor: removing ? cs.error : cs.primary,
                  minimumSize: const Size.square(44),
                  maximumSize: const Size.square(44),
                  padding: EdgeInsets.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
              icon: Icon(
                removing
                    ? Icons.remove_circle_outline_rounded
                    : Icons.add_circle_outline_rounded,
                size: 22,
              ),
            ),
          ),
          if (folder) ...[
            const SizedBox(width: 2),
            if (loading)
              const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              FileTreeExpansionArrow(
                expanded: expanded,
                color: expanded ? cs.primary : null,
              ),
          ],
        ],
      ),
    );
    return folder ? Semantics(expanded: expanded, child: tile) : tile;
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

class _AnimatedQueueEntry extends StatefulWidget {
  final (PlaybackQueueEntryPreview, PlaybackQueueEntry?, int?, bool, bool, int)
  content;
  final Widget Function(VoidCallback triggerRemove) builder;
  final VoidCallback onRemove;

  const _AnimatedQueueEntry({
    super.key,
    required this.content,
    required this.builder,
    required this.onRemove,
  });

  @override
  State<_AnimatedQueueEntry> createState() => _AnimatedQueueEntryState();
}

class _AnimatedQueueEntryState extends State<_AnimatedQueueEntry> {
  bool _isRemoving = false;
  late Widget _entry = widget.builder(_triggerRemove);

  @override
  void didUpdateWidget(covariant _AnimatedQueueEntry oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The reorderable sliver calls its builder on pointer moves. Reuse the
    // artwork and labels while the entry data and index are stable.
    if (!identical(oldWidget.content.$2, widget.content.$2) ||
        oldWidget.content != widget.content) {
      _entry = widget.builder(_triggerRemove);
    }
  }

  void _triggerRemove() {
    if (_isRemoving) return;
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
      child: _entry,
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
