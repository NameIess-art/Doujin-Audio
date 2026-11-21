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
import '../../../../core/app_language.dart';
import '../../../../core/logging/app_log_service.dart';
import '../../../../core/media/audio_detail.dart';
import '../../../../core/media/music_track.dart';
import '../../../../core/media/path_display.dart';
import '../../../../core/ui/ui_interaction_coordinator.dart';
import '../../../../core/ui/undoable_removal_service.dart';
import '../../../../core/ui/visual_settings_providers.dart';
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
import '../../../../core/widgets/playlist_icon.dart';
import '../../../../core/widgets/scroll_activity_gate.dart';
import '../../../../core/widgets/top_page_header.dart';
import '../../../../core/widgets/windows_smooth_scroll_controller.dart';
import '../../application/audio_state_services.dart';
import '../../application/session_switcher_tree.dart';
import '../../domain/playback_queue.dart';
import '../../../library/application/library_facade.dart';
import '../../../library/domain/library_node.dart';
import 'playlist_shared_helpers.dart';

import 'playback_queue_cover.dart';

const _queueEntryRemovalDuration = Duration(milliseconds: 250);
const _queueEntryPageSize = 128;
const _queueChildRowMinHeight = 48.0;
const _inlineQueueTreeTrackLimit = 64;

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
  double? _dragTriggerY;
  double _dragRowTopOffset = 0;
  double _addedQueueTopInset = 0;
  bool _isTopAutoScrolling = false;
  PlaybackQueueDefinition? _pagedQueue;
  final List<PlaybackQueueEntryPreview> _entryPreviews = [];
  int _previewVersion = 0;
  Object? _queueIndexKey;
  final _queueRootIndices = <String, int>{};
  (List<PlaybackQueueEntry>, _SessionRemovalKeys)? _filteredEntriesKey;
  List<PlaybackQueueEntry>? _filteredEntries;
  (int, _SessionRemovalKeys)? _filteredPreviewsKey;
  List<PlaybackQueueEntryPreview>? _filteredPreviews;
  (String, double, EdgeInsets, double)? _sourceSectionKey;
  Widget? _cachedSourceSection;
  bool _pageLoading = false;
  bool _pageFailed = false;
  bool _pageExhausted = false;
  bool _awaitingPageLayout = false;
  bool _savingRestoredDrop = false;

  @override
  void initState() {
    super.initState();
    _treeMotion = _QueueExpansionMotion(this, () {
      if (mounted && !_didPop) setState(_treeMotion.finish);
    });
    _addedQueueScrollController.addListener(_loadNearQueueEnd);
  }

  void _loadNearQueueEnd() {
    if (_awaitingPageLayout) return;
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
      if (_entryPreviews.isNotEmpty && _dragFinished == null) setState(() {});
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
        _previewVersion++;
        // Wait for the new entries to update maxScrollExtent before checking
        // extentAfter from scroll notifications on the same frame.
        _awaitingPageLayout = page.isNotEmpty;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _awaitingPageLayout = false;
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
    final sectionBox =
        _addedQueueSectionKey.currentContext?.findRenderObject() as RenderBox?;
    _dragTriggerY = sectionBox != null && sectionBox.hasSize
        ? sectionBox.localToGlobal(Offset(0, _addedQueueTopInset)).dy
        : null;
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
    var triggerY = _dragTriggerY;
    if (triggerY == null) {
      final sectionBox =
          _addedQueueSectionKey.currentContext?.findRenderObject()
              as RenderBox?;
      if (sectionBox == null || !sectionBox.hasSize) return 0;
      // Keep scrolled rows extending behind the floating capsules while driving
      // upward auto-scroll from the boundary below the section heading capsule.
      triggerY = sectionBox.localToGlobal(Offset(0, _addedQueueTopInset)).dy;
      _dragTriggerY = triggerY;
    }
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
      _dragTriggerY = null;
      if (event is PointerCancelEvent) _finishQueueReorder(_dragFinished);
      UiInteractionCoordinator.instance.endInteraction(this);
    }
  }

  void _handlePop(bool didPop, Object? _) {
    if (!didPop) return;
    _didPop = true;
    _treeMotion.pause();
    _dragTriggerY = null;
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
    final hadMotion = _treeMotion.hasActiveMotion;
    _treeMotion.finish();
    final removedTree = _addedTrees.remove(_draggedEntryId) != null;
    _dragFinished = null;
    _draggedEntryId = null;
    _draggedIndex = null;
    if ((hadMotion || removedTree) && mounted && !_didPop) setState(() {});
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
    if (loaded != null) {
      _loadingAddedTrees.remove(id);
      final tree = _treeForAddedEntry(loaded);
      setState(() {
        _addedTrees[id] = tree;
        if (!MediaQuery.disableAnimationsOf(context)) _treeMotion.openRoot(id);
      });
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
      final tree = await _buildAddedTreeAsync(entry);
      if (!mounted || _didPop || !isCurrent()) return;
      setState(() {
        _addedTrees[id] = tree;
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

  String? _workRootForEntry(PlaybackQueueEntry entry) {
    final track = entry.tracks.firstOrNull;
    return entry.workRootPath ??
        (track == null
            ? null
            : ref
                  .read(audioPathCoordinatorProvider)
                  .workRootForTrack(track.path, knownTrack: track));
  }

  _QueueEditorTree? _tryTreeFromCachedLibraryFolder(
    PlaybackQueueEntry entry,
    String? root, {
    Set<String>? expanded,
  }) {
    final firstTrack = entry.tracks.firstOrNull;
    if (root == null || firstTrack == null || firstTrack.isRemoteAsmr) {
      return null;
    }
    final cachedFolder = ref
        .read(libraryFacadeProvider)
        .resolvedLibraryFolderTree(root);
    if (cachedFolder == null || !_folderMatchesEntry(cachedFolder, entry)) {
      return null;
    }
    return _QueueEditorTree.fromFolderNode(
      cachedFolder,
      entry: entry,
      expanded: expanded,
    );
  }

  Future<_QueueEditorTree> _buildAddedTreeAsync(PlaybackQueueEntry entry) async {
    final root = _workRootForEntry(entry);
    final cached = _tryTreeFromCachedLibraryFolder(entry, root);
    if (cached != null) return cached;
    if (entry.tracks.length <= _inlineQueueTreeTrackLimit) {
      return _QueueEditorTree(entry.tracks, root, entry: entry);
    }
    final firstTrack = entry.tracks.firstOrNull;
    if (root != null && firstTrack != null && !firstTrack.isRemoteAsmr) {
      final loadedFolder = await ref
          .read(libraryFacadeProvider)
          .loadLibraryFolderTree(root);
      if (loadedFolder != null && _folderMatchesEntry(loadedFolder, entry)) {
        return _QueueEditorTree.fromFolderNode(loadedFolder, entry: entry);
      }
    }
    final preparedRoot = await compute(_buildQueueEditorRootOffIsolate, (
      tracks: entry.tracks,
      workRoot: root,
    ));
    return _QueueEditorTree.fromPrepared(
      entry.tracks,
      root,
      preparedRoot,
      entry: entry,
    );
  }

  _QueueEditorTree _treeForAddedEntry(
    PlaybackQueueEntry entry, {
    Set<String>? expanded,
  }) {
    final root = _workRootForEntry(entry);
    return _tryTreeFromCachedLibraryFolder(entry, root, expanded: expanded) ??
        _QueueEditorTree(entry.tracks, root, entry: entry, expanded: expanded);
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
    _dragTriggerY = null;
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
    final language = i18n.language;
    if (queue == null) return const SizedBox.shrink();
    final coverCacheWidth = coverThumbnailCacheWidth(
      logicalWidth: 40,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      resolution: ref.watch(coverImageResolutionProvider),
    );
    final workNameDisplay = ref.watch(
      settingsStateProvider.select(
        (state) =>
            state.value?.workNameDisplay ??
            ref.read(settingsRepositoryProvider).slice.state.workNameDisplay,
      ),
    );
    final pagedQueue = requiresLoad ? queue : null;
    if (!identical(_pagedQueue, pagedQueue)) {
      _pagedQueue = pagedQueue;
      _entryPreviews.clear();
      _previewVersion++;
      _pageLoading = _pageFailed = _pageExhausted = _awaitingPageLayout = false;
      _scheduleQueuePage();
    }

    final cs = Theme.of(context).colorScheme;
    final headerHeight = AppPageHeaderMetrics.contentTopInset(context);
    final addedQueueTop = headerHeight + 44;
    final horizontalPadding = AppPageHeaderMetrics.padding.copyWith(top: 0);

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
                    final paneWidth = isLandscape
                        ? math.max(0.0, (constraints.maxWidth - 1) / 2)
                        : constraints.maxWidth;
                    final rowAvailableWidth = math.max(
                      0.0,
                      paneWidth - horizontalPadding.horizontal,
                    );
                    final removalKeys = ref.watch(
                      undoableRemovalStateProvider.select(
                        (state) =>
                            _SessionRemovalKeys.fromState(state, sessionId),
                      ),
                    );
                    final filterHidden = removalKeys.entryIds.isNotEmpty;
                    final List<PlaybackQueueEntry> queueEntries;
                    if (requiresLoad || !filterHidden) {
                      queueEntries = queue.entries;
                    } else {
                      final previousKey = _filteredEntriesKey;
                      if (previousKey == null ||
                          !identical(previousKey.$1, queue.entries) ||
                          previousKey.$2 != removalKeys ||
                          _filteredEntries == null) {
                        _filteredEntriesKey = (queue.entries, removalKeys);
                        _filteredEntries = queue.entries
                            .where(
                              (entry) => !removalKeys.isEntryHidden(entry.id),
                            )
                            .toList(growable: false);
                      }
                      queueEntries = _filteredEntries!;
                    }
                    final List<PlaybackQueueEntryPreview> previews;
                    if (!requiresLoad || !filterHidden) {
                      previews = _entryPreviews;
                    } else {
                      final key = (_previewVersion, removalKeys);
                      if (_filteredPreviewsKey != key ||
                          _filteredPreviews == null) {
                        _filteredPreviewsKey = key;
                        _filteredPreviews = _entryPreviews
                            .where(
                              (entry) => !removalKeys.isEntryHidden(entry.id),
                            )
                            .toList(growable: false);
                      }
                      previews = _filteredPreviews!;
                    }
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

                    List<int>? expandedQueueRoots;
                    if (_addedTrees.isNotEmpty) {
                      final indexKey = (
                        requiresLoad,
                        requiresLoad ? _previewVersion : queue.entries,
                        filterHidden ? removalKeys : null,
                      );
                      if (_queueIndexKey != indexKey) {
                        _queueRootIndices.clear();
                        for (var i = 0; i < rowCount; i++) {
                          _queueRootIndices[idAt(i)] = i;
                        }
                        _queueIndexKey = indexKey;
                      }
                      expandedQueueRoots = <int>[];
                      for (final id in _addedTrees.keys) {
                        final root = _queueRootIndices[id];
                        if (root != null) expandedQueueRoots.add(root);
                      }
                      if (expandedQueueRoots.length > 1) {
                        expandedQueueRoots.sort();
                      }
                    }

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
                              final childPrefix = '$sessionId:$id:';
                              final hasHidden =
                                  removalKeys.childKeys.isNotEmpty &&
                                  removalKeys.childKeys.any(
                                    (key) => key.startsWith(childPrefix),
                                  );
                              final children = tree.rows(
                                hiddenRevision: hasHidden ? removalKeys : null,
                                hidden: hasHidden
                                    ? (node) => removalKeys.childKeys.contains(
                                        _queueChildRemovalKey(
                                          sessionId,
                                          id,
                                          node,
                                        ).id,
                                      )
                                    : null,
                              );
                              return _treeMotion.project(context, id, children);
                            },
                      expandedRoots: expandedQueueRoots,
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
                              _previewVersion++;
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
                                  _previewVersion++;
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
                                    final id = idAt(rows.at(index).root);
                                    final hadTree = _addedTrees.containsKey(id);
                                    final wasLoading =
                                        _loadingAddedTrees.remove(id) != null;
                                    final hadMotion =
                                        _treeMotion.hasActiveMotion;
                                    void begin() {
                                      _treeMotion.pause();
                                      _dragFinished = Completer<void>();
                                      _draggedIndex = index;
                                      _draggedEntryId = id;
                                    }

                                    if (hadTree || wasLoading || hadMotion) {
                                      setState(begin);
                                    } else {
                                      begin();
                                    }
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
                                          title: node.title,
                                          depth: child.depth,
                                          folder: node.isFolder,
                                          removing: true,
                                          language: language,
                                          coverCacheWidth: coverCacheWidth,
                                          workNameDisplay: workNameDisplay,
                                          availableWidth: rowAvailableWidth,
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
                                        key: key,
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
                                        expanded,
                                        loading,
                                        expanded
                                            ? tree.count(tree.root)
                                            : entry.trackCount,
                                      ),
                                      display: (
                                        language,
                                        coverCacheWidth,
                                        workNameDisplay,
                                        rowAvailableWidth,
                                      ),
                                      dragIndex: dragIndex,
                                      onStartDrag: dragIndex == null
                                          ? null
                                          : _startQueueDrag,
                                      onRemove: () {
                                        if (_addedTrees.remove(entry.id) !=
                                            null) {
                                          setState(() {});
                                        }
                                        unawaited(_removeEntry(entry.id));
                                      },
                                      builder: (triggerRemove) => _QueueAudioRow(
                                        track: entry.firstTrack,
                                        title: entry.title,
                                        folder: isFolder,
                                        removing: true,
                                        language: language,
                                        coverCacheWidth: coverCacheWidth,
                                        workNameDisplay: workNameDisplay,
                                        availableWidth: rowAvailableWidth,
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
                                      ),
                                    );
                                  },
                                ),
                        ),
                        Positioned(
                          top: headerHeight,
                          left: 0,
                          right: 0,
                          child: _QueueSectionHeading(
                            horizontalPadding: horizontalPadding,
                            child: _QueueSectionCapsule(
                              label: i18n.tr('queue_added_audio'),
                              icon: Icons.playlist_play_rounded,
                            ),
                          ),
                        ),
                      ],
                    );
                    final addedToQueuePane = Listener(
                      onPointerMove: _updateQueueDrag,
                      onPointerUp: _finishQueueDrag,
                      onPointerCancel: _finishQueueDrag,
                      child: ScrollActivityGate(
                        onMetricsChanged: ref
                            .read(libraryCoverUiControllerProvider)
                            .viewportChanged,
                        child: addedToQueueSection,
                      ),
                    );

                    final sectionTopOffset = isLandscape
                        ? headerHeight
                        : AppSpacing.xs;
                    final sourceKey = (
                      sessionId,
                      sectionTopOffset,
                      horizontalPadding,
                      rowAvailableWidth,
                    );
                    if (_sourceSectionKey != sourceKey ||
                        _cachedSourceSection == null) {
                      _sourceSectionKey = sourceKey;
                      _cachedSourceSection = _QueueAudioSourceSection(
                        sessionId: sessionId,
                        topOffset: sectionTopOffset,
                        horizontalPadding: horizontalPadding,
                        rowAvailableWidth: rowAvailableWidth,
                      );
                    }
                    final sourceSection = _cachedSourceSection!;

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
                          Expanded(
                            child: PageHeaderInset(
                              topInset: 0,
                              child: sourceSection,
                            ),
                          ),
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
                icon: Icons.edit_note_rounded,
                leading: const AppHeaderBackButton(),
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

@immutable
class _SessionRemovalKeys {
  const _SessionRemovalKeys({
    required this.entryIds,
    required this.childKeys,
  });

  static const empty = _SessionRemovalKeys(
    entryIds: <String>{},
    childKeys: <String>{},
  );

  final Set<String> entryIds;
  final Set<String> childKeys;

  bool isEntryHidden(String id) => entryIds.contains(id);

  factory _SessionRemovalKeys.fromState(
    UndoableRemovalState state,
    String sessionId,
  ) {
    final prefix = '$sessionId:';
    Set<String>? entryIds;
    Set<String>? childKeys;
    for (final key in state.hiddenKeys) {
      if (key.namespace == 'playback-queue-entry' &&
          key.id.startsWith(prefix)) {
        (entryIds ??= <String>{}).add(key.id.substring(prefix.length));
      } else if (key.namespace == 'playback-queue-child' &&
          key.id.startsWith(prefix)) {
        (childKeys ??= <String>{}).add(key.id);
      }
    }
    if (entryIds == null && childKeys == null) return empty;
    return _SessionRemovalKeys(
      entryIds: entryIds ?? const <String>{},
      childKeys: childKeys ?? const <String>{},
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _SessionRemovalKeys &&
          setEquals(other.entryIds, entryIds) &&
          setEquals(other.childKeys, childKeys);

  @override
  int get hashCode =>
      Object.hash(Object.hashAllUnordered(entryIds), Object.hashAllUnordered(childKeys));
}

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

  bool get hasActiveMotion => _motion.branch != null;

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

  Widget wrap(String id, int childIndex, Widget child, {Key? key}) =>
      _motion.wrap(
        childIndex,
        child,
        key: key,
        active: _motion.branch?.entryId == id,
      );

  void pause() => _motion.pause();
  void finish() => _motion.finish();
  void dispose() => _motion.dispose();
}

typedef _QueueTreeBuildRequest = ({List<MusicTrack> tracks, String? workRoot});

SessionSwitcherNode _buildQueueEditorRootOffIsolate(
  _QueueTreeBuildRequest request,
) {
  final root = SessionSwitcherNode.folder('');
  for (var i = 0; i < request.tracks.length; i++) {
    final track = request.tracks[i];
    root
        .folderForTrack(track, workRoot: request.workRoot)
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
  return root;
}

bool _folderMatchesEntry(FolderNode folder, PlaybackQueueEntry entry) {
  if (folder.children.isEmpty ||
      folder.totalTrackCount != entry.tracks.length) {
    return false;
  }
  final folderTracks = folder.allTracks;
  if (folderTracks.length != entry.tracks.length) return false;
  for (var i = 0; i < folderTracks.length; i++) {
    if (folderTracks[i].path != entry.tracks[i].path) return false;
  }
  return true;
}

class _QueueEditorTree {
  _QueueEditorTree(
    this.tracks,
    this.workRoot, {
    this.entry,
    Set<String>? expanded,
  }) : sourceFolder = null,
       expanded = expanded ?? <String>{},
       root = SessionSwitcherNode.folder('') {
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

  _QueueEditorTree.fromPrepared(
    this.tracks,
    this.workRoot,
    this.root, {
    this.entry,
    Set<String>? expanded,
  }) : sourceFolder = null,
       expanded = expanded ?? <String>{} {
    final pending = <SessionSwitcherNode>[root];
    while (pending.isNotEmpty) {
      final node = pending.removeLast();
      if (node.isFolder) {
        for (final child in node.children) {
          pending.add(child);
        }
      } else if (node.sourceIndex >= 0 && node.sourceIndex < tracks.length) {
        node.track = tracks[node.sourceIndex];
      }
    }
    _count(root, null);
  }

  _QueueEditorTree.fromFolderNode(
    FolderNode folder, {
    this.entry,
    Set<String>? expanded,
  }) : tracks = entry?.tracks ?? folder.allTracks,
       workRoot = folder.path,
       sourceFolder = folder,
       expanded = expanded ?? <String>{},
       root = SessionSwitcherNode.folder('') {
    _folderStartIndices[root.key] = 0;
    _counts[root] = folder.totalTrackCount;
    _populateFolder(root, folder);
  }

  final List<MusicTrack> tracks;
  final String? workRoot;
  final PlaybackQueueEntry? entry;
  final FolderNode? sourceFolder;
  final Set<String> expanded;
  final SessionSwitcherNode root;
  final _counts = <SessionSwitcherNode, int>{};
  final Map<String, FolderNode> _folderNodes = {};
  final Map<String, int> _folderStartIndices = {};
  final Set<String> _populatedFolders = {};
  List<_QueueChildRow>? _rows;
  List<_QueueChildRow> get projectedRows => _rows ?? const [];
  Object? _hiddenRevision;

  void _populateFolder(SessionSwitcherNode target, FolderNode folder) {
    if (!_populatedFolders.add(target.key)) return;
    var cursor = _folderStartIndices[target.key] ?? 0;
    for (final child in folder.children) {
      if (child is FolderNode) {
        final key = '${target.key}/${Uri.encodeComponent(child.name)}';
        final node = SessionSwitcherNode.folder(child.name, key: key);
        _counts[node] = child.totalTrackCount;
        _folderNodes[key] = child;
        _folderStartIndices[key] = cursor;
        cursor += child.totalTrackCount;
        target.children.add(node);
        if (expanded.contains(key)) {
          _populateFolder(node, child);
        }
      } else if (child is TrackNode) {
        final index = cursor++;
        final resolvedTrack = entry != null && index < tracks.length
            ? tracks[index]
            : child.track;
        target.children.add(
          SessionSwitcherNode.track(
            resolvedTrack,
            selected: false,
            queueIndex: index,
            sourceIndex: index,
          ),
        );
      }
    }
  }

  int _count(
    SessionSwitcherNode node,
    bool Function(SessionSwitcherNode)? hidden,
  ) {
    if (hidden?.call(node) == true) return 0;
    if (!node.isFolder) return 1;
    final folder = _folderNodes[node.key];
    if (folder != null && !_populatedFolders.contains(node.key)) {
      if (hidden == null) return _counts[node] = folder.totalTrackCount;
      _populateFolder(node, folder);
    }
    return _counts[node] = node.children.fold<int>(
      0,
      (count, child) => count + _count(child, hidden),
    );
  }

  int count(SessionSwitcherNode node) => _counts[node] ?? 0;

  MusicTrack trackForNode(SessionSwitcherNode node) =>
      node.track ?? tracks[node.sourceIndex];

  List<MusicTrack> tracksForFolder(SessionSwitcherNode node) {
    final folder = _folderNodes[node.key];
    if (folder != null) return folder.allTracks;
    return [for (final index in trackIndices(node)) tracks[index]];
  }

  void toggle(SessionSwitcherNode node) {
    if (!expanded.remove(node.key)) {
      expanded.add(node.key);
      final folder = _folderNodes[node.key];
      if (folder != null) _populateFolder(node, folder);
    }
    _rows = null;
  }

  List<_QueueChildRow> rows({
    Object? hiddenRevision,
    bool Function(SessionSwitcherNode)? hidden,
  }) {
    final changed = hiddenRevision != _hiddenRevision;
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
      final folder = _folderNodes[node.key];
      if (folder != null && !_populatedFolders.contains(node.key)) {
        _populateFolder(node, folder);
      }
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
class _QueueRowGroup {
  _QueueRowGroup({
    required this.root,
    required this.first,
    required this.rows,
  });

  final int root;
  final int first;
  final List<_QueueChildRow> rows;
  Map<String, int>? _indices;

  int indexOf(String nodeKey) {
    if (rows.length <= 16) {
      for (var i = 0; i < rows.length; i++) {
        if (rows[i].node.key == nodeKey) return i;
      }
      return -1;
    }
    final indices = _indices ??= {
      for (var i = 0; i < rows.length; i++) rows[i].node.key: i,
    };
    return indices[nodeKey] ?? -1;
  }
}

class _QueueEditorRows {
  _QueueEditorRows(
    this.rootCount,
    List<_QueueChildRow> Function(int)? children, {
    List<int>? expandedRoots,
  }) {
    if (children == null) return;
    if (expandedRoots != null) {
      for (final root in expandedRoots) {
        final rows = children(root);
        if (rows.isEmpty) continue;
        _groups.add(
          _QueueRowGroup(root: root, first: root + 1 + _childCount, rows: rows),
        );
        _childCount += rows.length;
      }
      return;
    }
    for (var root = 0; root < rootCount; root++) {
      final rows = children(root);
      if (rows.isEmpty) continue;
      _groups.add(
        _QueueRowGroup(root: root, first: root + 1 + _childCount, rows: rows),
      );
      _childCount += rows.length;
    }
  }

  final int rootCount;
  final _groups = <_QueueRowGroup>[];
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

  int? indexOfKey(Key key, int? Function(String) rootIndexOf) {
    if (key is ValueKey<String>) {
      final root = rootIndexOf(key.value);
      if (root == null || root < 0 || root >= rootCount) return null;
      return _flatRootIndex(root);
    }
    if (key is ValueKey<(String, String)>) {
      final (id, nodeKey) = key.value;
      final root = rootIndexOf(id);
      if (root == null || root < 0 || root >= rootCount) return null;
      final group = _groupForRoot(root);
      if (group == null) return null;
      final offset = group.indexOf(nodeKey);
      return offset < 0 ? null : group.first + offset;
    }
    return null;
  }

  int _flatRootIndex(int root) {
    if (_groups.isEmpty) return root;
    var low = 0;
    var high = _groups.length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (_groups[middle].root < root) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    if (low == 0) return root;
    final group = _groups[low - 1];
    return root + (group.first - group.root - 1) + group.rows.length;
  }

  _QueueRowGroup? _groupForRoot(int root) {
    if (_groups.isEmpty) return null;
    var low = 0;
    var high = _groups.length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (_groups[middle].root < root) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    if (low < _groups.length && _groups[low].root == root) {
      return _groups[low];
    }
    return null;
  }
}

class _QueueSectionHeading extends StatelessWidget {
  const _QueueSectionHeading({
    required this.horizontalPadding,
    required this.child,
  });

  final EdgeInsets horizontalPadding;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: horizontalPadding.copyWith(bottom: AppSpacing.xs),
        child: Align(alignment: Alignment.centerLeft, child: child),
      ),
    );
  }
}

TextStyle? _queueSectionTitleStyle(BuildContext context) {
  final isWindows = Theme.of(context).platform == TargetPlatform.windows;
  return appPageHeaderTitleStyle(context)?.copyWith(
    fontSize: 13.5,
    fontWeight: isWindows ? null : FontWeight.w700,
  );
}

class _QueueSectionCapsule extends StatelessWidget {
  const _QueueSectionCapsule({
    required this.label,
    this.icon,
    this.iconWidget,
    this.backgroundOpacity = 1,
  }) : assert(icon != null || iconWidget != null);

  final String label;
  final IconData? icon;
  final Widget? iconWidget;
  final double backgroundOpacity;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    const iconSize = 17.0;
    return HeaderFloatingSurface(
      followBarGlass: true,
      backgroundOpacity: backgroundOpacity,
      height: 32,
      radius: 16,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (iconWidget != null)
            IconTheme.merge(
              data: IconThemeData(size: iconSize, color: cs.primary),
              child: iconWidget!,
            )
          else
            Icon(
              icon,
              size: AppDesignTokens.opticalIconSize(icon, iconSize),
              color: cs.primary,
            ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              style: _queueSectionTitleStyle(context),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _QueueAudioSourceSection extends ConsumerStatefulWidget {
  const _QueueAudioSourceSection({
    required this.sessionId,
    required this.topOffset,
    required this.horizontalPadding,
    required this.rowAvailableWidth,
  });

  final String sessionId;
  final double topOffset;
  final EdgeInsets horizontalPadding;
  final double rowAvailableWidth;

  @override
  ConsumerState<_QueueAudioSourceSection> createState() =>
      _QueueAudioSourceSectionState();
}

class _QueueAudioSourceSectionState
    extends ConsumerState<_QueueAudioSourceSection> {
  bool _showLocalLibrary = false;
  int? _cardSnapshotRequestRevision;
  late final String _cardSnapshotCommitKey =
      'queue_source_library_snapshot_${identityHashCode(this)}';

  void _ensureLibraryCardSnapshot({
    required LibraryFacade libraryFacade,
    required int snapshotRevision,
  }) {
    final structureRevision = libraryFacade.structureRevision;
    if (snapshotRevision == structureRevision ||
        _cardSnapshotRequestRevision == structureRevision) {
      return;
    }
    _cardSnapshotRequestRevision = structureRevision;
    UiInteractionCoordinator.instance.scheduleCommit(
      key: _cardSnapshotCommitKey,
      priority: 20,
      structural: true,
      commit: () {
        if (!mounted ||
            !_showLocalLibrary ||
            _cardSnapshotRequestRevision != structureRevision ||
            libraryFacade.structureRevision != structureRevision) {
          if (_cardSnapshotRequestRevision == structureRevision) {
            _cardSnapshotRequestRevision = null;
          }
          return;
        }
        unawaited(
          libraryFacade
              .ensureCardSnapshot()
              .catchError((Object error, StackTrace stackTrace) {
                AppLogService.error(
                  'queue_library_card_snapshot_failed',
                  error: error,
                  stackTrace: stackTrace,
                );
                return LibraryTreeSnapshot(
                  tree: const <LibraryNode>[],
                  leafFolderCount: 0,
                );
              })
              .whenComplete(() {
                if (mounted &&
                    _cardSnapshotRequestRevision == structureRevision) {
                  _cardSnapshotRequestRevision = null;
                }
              }),
        );
      },
    );
  }

  @override
  void dispose() {
    UiInteractionCoordinator.instance.cancelCommit(_cardSnapshotCommitKey);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final playlistAreaBackground = isDark
        ? cs.surfaceContainerLowest
        : cs.surfaceContainer;
    final glassEnabled = AppDesignTokens.of(context).barGlassEnabled;
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
    final List<LibraryNode> localWorks;
    if (showLocalLibrary) {
      final libraryFacade = ref.read(libraryFacadeProvider);
      final libraryReady = ref.watch(
        libraryListUiProvider.select(
          (state) => (
            isInitialized: state.isInitialized,
            revision: state.structureRevision,
          ),
        ),
      );
      if (libraryReady.isInitialized) {
        _ensureLibraryCardSnapshot(
          libraryFacade: libraryFacade,
          snapshotRevision: libraryReady.revision,
        );
      }
      final sorted = ref.watch(librarySortedTreeUiProvider);
      final rawTree = ref.watch(
        libraryListUiProvider.select((state) => state.rawTree),
      );
      localWorks = sorted.isNotEmpty || rawTree.isEmpty ? sorted : rawTree;
    } else {
      UiInteractionCoordinator.instance.cancelCommit(_cardSnapshotCommitKey);
      _cardSnapshotRequestRevision = null;
      localWorks = const <LibraryNode>[];
    }

    Widget sourceTab(
      String label, {
      IconData? icon,
      Widget? iconWidget,
      required bool local,
    }) {
      final selected = showLocalLibrary == local;
      return Semantics(
        selected: selected,
        child: selected
            ? _QueueSectionCapsule(
                label: label,
                icon: icon,
                iconWidget: iconWidget,
                backgroundOpacity: glassEnabled ? 0.75 : 1,
              )
            : TextButton(
                onPressed: () => setState(() => _showLocalLibrary = local),
                style: appTextButtonStyle(
                  style: TextButton.styleFrom(
                    foregroundColor: cs.onSurfaceVariant,
                    minimumSize: const Size(0, 32),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    textStyle: _queueSectionTitleStyle(context),
                  ),
                ),
                child: Text(label, overflow: TextOverflow.ellipsis),
              ),
      );
    }

    return ScrollActivityGate(
      onMetricsChanged: ref.read(libraryCoverUiControllerProvider).viewportChanged,
      child: DecoratedBox(
        decoration: BoxDecoration(color: playlistAreaBackground),
        child: Stack(
          children: [
            Positioned.fill(
              child: _QueueAudioSourceList(
                key: ValueKey(showLocalLibrary),
                showLibrary: showLocalLibrary,
                works: localWorks,
                sessions: ordinarySessions,
                sessionId: widget.sessionId,
                rowAvailableWidth: widget.rowAvailableWidth,
                padding: widget.horizontalPadding.copyWith(
                  top: widget.topOffset + 44,
                  bottom: AppSpacing.xs,
                ),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: widget.topOffset + 48,
              child: AppEdgeFadeMask(
                direction: AppEdgeFadeDirection.towardTop,
                color: playlistAreaBackground,
                // Leave enough of the scrolling artwork for the glass to sample.
                opacity: glassEnabled ? 0.2 : 1,
              ),
            ),
            Positioned(
              top: widget.topOffset,
              left: 0,
              right: 0,
              child: _QueueSectionHeading(
                horizontalPadding: widget.horizontalPadding,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: sourceTab(
                        i18n.tr('playback_sessions'),
                        iconWidget: const PlaylistIcon(),
                        local: false,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: sourceTab(
                        i18n.tr('show_local_library'),
                        icon: Icons.library_music_rounded,
                        local: true,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
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
    required this.rowAvailableWidth,
    required this.padding,
  });

  final bool showLibrary;
  final List<LibraryNode> works;
  final List<PlaybackDirectoryEntry> sessions;
  final String sessionId;
  final double rowAvailableWidth;
  final EdgeInsetsGeometry padding;

  @override
  ConsumerState<_QueueAudioSourceList> createState() =>
      _QueueAudioSourceListState();
}

class _QueueAudioSourceListState extends ConsumerState<_QueueAudioSourceList>
    with SingleTickerProviderStateMixin {
  final ScrollController _scrollController =
      defaultTargetPlatform == TargetPlatform.windows
      ? WindowsSmoothScrollController()
      : ScrollController();
  final _trees = <String, _QueueEditorTree>{};
  late final _QueueExpansionMotion _treeMotion;
  final _loading = <String, Object>{};
  final _sourcePaths = <String, String>{};
  List<LibraryNode>? _indexedWorks;
  List<PlaybackDirectoryEntry>? _indexedSessions;
  bool? _indexedShowLibrary;
  final _rootIndices = <String, int>{};
  int? _treesLibraryRevision;
  List<PlaybackDirectoryEntry>? _cachedTrackSessions;
  int? _cachedTrackContentRevision;
  final _sessionTracksById = <String, MusicTrack?>{};

  @override
  void initState() {
    super.initState();
    _treeMotion = _QueueExpansionMotion(this, () {
      if (mounted) setState(_treeMotion.finish);
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _treeMotion.dispose();
    super.dispose();
  }

  void _ensureRootIndices() {
    final showLibrary = widget.showLibrary;
    if (_indexedShowLibrary == showLibrary &&
        (showLibrary
            ? identical(_indexedWorks, widget.works)
            : identical(_indexedSessions, widget.sessions))) {
      return;
    }
    _rootIndices.clear();
    if (showLibrary) {
      for (var i = 0; i < widget.works.length; i++) {
        _rootIndices[widget.works[i].path] = i;
      }
      _indexedWorks = widget.works;
      _indexedSessions = null;
    } else {
      for (var i = 0; i < widget.sessions.length; i++) {
        _rootIndices[widget.sessions[i].id] = i;
      }
      _indexedSessions = widget.sessions;
      _indexedWorks = null;
    }
    _indexedShowLibrary = showLibrary;
  }

  String _idAt(int index) =>
      widget.showLibrary ? widget.works[index].path : widget.sessions[index].id;

  Future<List<MusicTrack>> _loadTracks(MusicTrack track) async {
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
    if (work != null) {
      final ready = work.children.isNotEmpty
          ? work
          : ref.read(libraryFacadeProvider).resolvedLibraryFolderTree(work.path);
      final _QueueEditorTree? tree;
      if (ready != null) {
        tree = _QueueEditorTree.fromFolderNode(ready);
      } else if (work.totalTrackCount <= _inlineQueueTreeTrackLimit &&
          work.allTracks.isNotEmpty) {
        tree = _QueueEditorTree(work.allTracks, work.path);
      } else {
        tree = null;
      }
      if (tree != null) {
        setState(() {
          _trees[id] = tree!;
          if (!MediaQuery.disableAnimationsOf(context)) {
            _treeMotion.openRoot(id);
          }
        });
        return;
      }
    }
    await _loadTree(id, track, work);
  }

  Future<void> _loadTree(String id, MusicTrack track, FolderNode? work) async {
    if (_loading.containsKey(id)) return;
    final request = Object();
    setState(() => _loading[id] = request);
    bool isCurrent() => identical(_loading[id], request);
    try {
      if (work != null) {
        final library = ref.read(libraryFacadeProvider);
        final loadedFolder = await library.loadLibraryFolderTree(work.path);
        if (!mounted || !isCurrent()) return;
        final rootIndex = _rootIndices[id];
        if (rootIndex == null ||
            rootIndex >= widget.works.length ||
            widget.works[rootIndex] is! FolderNode) {
          return;
        }
        final latestWork = widget.works[rootIndex] as FolderNode;
        final expanded = _trees[id]?.expanded;
        final tree = loadedFolder != null
            ? _QueueEditorTree.fromFolderNode(loadedFolder, expanded: expanded)
            : _QueueEditorTree(
                latestWork.allTracks,
                latestWork.path,
                expanded: expanded,
              );
        setState(() {
          final opening = !_trees.containsKey(id);
          _trees[id] = tree;
          if (opening && !MediaQuery.disableAnimationsOf(context)) {
            _treeMotion.openRoot(id);
          }
        });
        return;
      }
      final paths = ref.read(audioPathCoordinatorProvider);
      final root = paths.workRootForTrack(track.path, knownTrack: track);
      final tracks = await _loadTracks(track);
      if (!mounted || !isCurrent()) return;
      final existingExpanded = _trees[id]?.expanded;
      final _QueueEditorTree tree;
      if (tracks.length <= _inlineQueueTreeTrackLimit) {
        tree = _QueueEditorTree(tracks, root, expanded: existingExpanded);
      } else {
        final preparedRoot = await compute(_buildQueueEditorRootOffIsolate, (
          tracks: tracks,
          workRoot: root,
        ));
        if (!mounted || !isCurrent()) return;
        tree = _QueueEditorTree.fromPrepared(
          tracks,
          root,
          preparedRoot,
          expanded: existingExpanded,
        );
      }
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
        _trees[id] = tree;
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
        await queue.addTrack(sessionId, tree!.trackForNode(child));
      } else if (track.isSingle) {
        await queue.addTrack(sessionId, track);
      } else if (tree != null || work != null) {
        final tracks = child == null
            ? work?.allTracks ?? tree!.tracks
            : tree!.tracksForFolder(child);
        await queue.addWork(
          sessionId,
          track,
          selectedTracks: tracks,
          workRootPath: work?.path ?? tree?.workRoot,
        );
      } else {
        await queue.addWork(
          sessionId,
          track,
          selectedTracks: await _loadTracks(track),
        );
      }
    } catch (error, stackTrace) {
      if (mounted) _showQueueEditorReadFailure(context, ref, error, stackTrace);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appLanguageStateProvider);
    final language = ref.read(appLanguageProviderInstanceProvider).language;
    final coverCacheWidth = coverThumbnailCacheWidth(
      logicalWidth: 40,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      resolution: ref.watch(coverImageResolutionProvider),
    );
    final workNameDisplay = ref.watch(
      settingsStateProvider.select(
        (state) =>
            state.value?.workNameDisplay ??
            ref.read(settingsRepositoryProvider).slice.state.workNameDisplay,
      ),
    );
    final paths = ref.read(audioPathCoordinatorProvider);
    final showLibrary = widget.showLibrary;
    final roots = showLibrary ? widget.works.length : widget.sessions.length;
    final libraryContentRevision = showLibrary
        ? 0
        : ref.watch(
            libraryStateProvider.select(
              (state) => state.value?.contentRevision ?? 0,
            ),
          );
    if (!showLibrary &&
        (!identical(_cachedTrackSessions, widget.sessions) ||
            _cachedTrackContentRevision != libraryContentRevision)) {
      _cachedTrackSessions = widget.sessions;
      _cachedTrackContentRevision = libraryContentRevision;
      _sessionTracksById.clear();
    }
    MusicTrack? sessionTrack(PlaybackDirectoryEntry source) =>
        _sessionTracksById.putIfAbsent(
          source.id,
          () => paths.sessionTrackForPath(source.id, source.currentTrackPath),
        );

    _ensureRootIndices();
    if (!showLibrary) {
      ref.listen(
        libraryStateProvider.select((state) => state.value?.contentRevision),
        (_, _) {
          if (_trees.isEmpty) return;
          for (final source in widget.sessions) {
            if (!_trees.containsKey(source.id)) continue;
            final track = paths.sessionTrackForPath(
              source.id,
              source.currentTrackPath,
            );
            if (track != null && !track.isSingle) {
              unawaited(_loadTree(source.id, track, null));
            }
          }
        },
      );
    }

    if (showLibrary) {
      final libraryRevision = ref.watch(
        libraryListUiProvider.select((state) => state.structureRevision),
      );
      if (_trees.isEmpty) {
        _treesLibraryRevision = libraryRevision;
      } else if (_treesLibraryRevision != libraryRevision) {
        _treesLibraryRevision = libraryRevision;
        final library = ref.read(libraryFacadeProvider);
        for (final id in _trees.keys.toList(growable: false)) {
          final root = _rootIndices[id];
          if (root == null) {
            _trees.remove(id);
            _loading.remove(id);
            continue;
          }
          final node = widget.works[root];
          if (node is! FolderNode) {
            _trees.remove(id);
            _loading.remove(id);
            continue;
          }
          final opened = _trees[id]!;
          final cachedFolder = node.children.isNotEmpty
              ? node
              : library.resolvedLibraryFolderTree(node.path);
          if (cachedFolder != null) {
            _trees[id] = _QueueEditorTree.fromFolderNode(
              cachedFolder,
              expanded: opened.expanded,
            );
          } else {
            final track = node.firstTrack;
            if (track != null) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted && _trees.containsKey(id)) {
                  unawaited(_loadTree(id, track, node));
                }
              });
            }
          }
        }
      }
    } else if (_trees.isNotEmpty) {
      for (final id in _trees.keys.toList(growable: false)) {
        final root = _rootIndices[id];
        if (root == null) {
          _trees.remove(id);
          _sourcePaths.remove(id);
          _loading.remove(id);
          continue;
        }
        final source = widget.sessions[root];
        if (_sourcePaths[id] != source.currentTrackPath) {
          final track = sessionTrack(source);
          final opened = _trees[id]!;
          if (track == null ||
              track.groupKey != opened.tracks.firstOrNull?.groupKey) {
            _trees.remove(id);
            _sourcePaths.remove(id);
            _loading.remove(id);
          } else {
            _sourcePaths[id] = source.currentTrackPath;
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
    List<int>? expandedRoots;
    if (_trees.isNotEmpty) {
      expandedRoots = <int>[];
      for (final id in _trees.keys) {
        final root = _rootIndices[id];
        if (root != null) expandedRoots.add(root);
      }
      if (expandedRoots.length > 1) expandedRoots.sort();
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
      expandedRoots: expandedRoots,
    );
    return ListView.builder(
      key: PageStorageKey<bool>(showLibrary),
      controller: _scrollController,
      padding: widget.padding,
      addAutomaticKeepAlives: false,
      itemCount: rows.length,
      findChildIndexCallback: (key) =>
          rows.indexOfKey(key, (id) => _rootIndices[id]),
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
        if (track == null) return SizedBox.shrink(key: ValueKey(id));
        final tree = _trees[id];
        if (child == null) {
          return _QueueAudioRow(
            key: ValueKey(id),
            track: track,
            title: track.displayName,
            folder: !track.isSingle,
            language: language,
            coverCacheWidth: coverCacheWidth,
            workNameDisplay: workNameDisplay,
            availableWidth: widget.rowAvailableWidth,
            workRootPath: work?.path,
            folderCoverPath: work?.path,
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
            title: node.title,
            depth: child.depth,
            folder: node.isFolder,
            language: language,
            coverCacheWidth: coverCacheWidth,
            workNameDisplay: workNameDisplay,
            availableWidth: widget.rowAvailableWidth,
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
          key: ValueKey((id, node.key)),
        );
      },
    );
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

class _QueueAudioRow extends ConsumerStatefulWidget {
  const _QueueAudioRow({
    super.key,
    this.track,
    required this.title,
    required this.folder,
    required this.action,
    required this.language,
    required this.coverCacheWidth,
    required this.workNameDisplay,
    this.availableWidth,
    this.workRootPath,
    this.folderCoverPath,
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
  final AppLanguage language;
  final int? coverCacheWidth;
  final WorkNameDisplay workNameDisplay;
  final double? availableWidth;
  final String? workRootPath;
  final String? folderCoverPath;
  final int depth;
  final bool removing;
  final bool expanded;
  final bool loading;
  final String? subtitle;
  final int? count;
  final VoidCallback? toggle;

  @override
  ConsumerState<_QueueAudioRow> createState() => _QueueAudioRowState();
}

class _QueueAudioRowState extends ConsumerState<_QueueAudioRow> {
  Widget? _cachedChild;
  String? _cachedTitle;

  void _handleToggle() => widget.toggle?.call();
  void _handleAction() => widget.action();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _cachedChild = null;
  }

  @override
  void didUpdateWidget(covariant _QueueAudioRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.track, widget.track) ||
        oldWidget.title != widget.title ||
        oldWidget.folder != widget.folder ||
        oldWidget.language != widget.language ||
        oldWidget.coverCacheWidth != widget.coverCacheWidth ||
        oldWidget.workNameDisplay != widget.workNameDisplay ||
        oldWidget.availableWidth != widget.availableWidth ||
        oldWidget.workRootPath != widget.workRootPath ||
        oldWidget.folderCoverPath != widget.folderCoverPath ||
        oldWidget.depth != widget.depth ||
        oldWidget.removing != widget.removing ||
        oldWidget.expanded != widget.expanded ||
        oldWidget.loading != widget.loading ||
        oldWidget.subtitle != widget.subtitle ||
        oldWidget.count != widget.count ||
        (oldWidget.toggle != null) != (widget.toggle != null)) {
      _cachedChild = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final representative = widget.track;
    final root = widget.depth == 0;
    final resolvedTitle = root && widget.folder && representative != null
        ? _workTitle(ref, representative)
        : widget.title;
    if (_cachedChild != null && _cachedTitle == resolvedTitle) {
      return _cachedChild!;
    }
    _cachedTitle = resolvedTitle;

    final cs = Theme.of(context).colorScheme;
    Widget? cover;
    if (root) {
      final library = ref.read(libraryFacadeProvider);
      final folderPath = widget.folderCoverPath;
      cover = CoverArtworkFrame(
        showShadow: false,
        borderRadius: const BorderRadius.all(Radius.circular(20)),
        child: representative == null
            ? const CoverFallbackArtwork()
            : QueueTrackCover(
                track: representative,
                folderPath: folderPath,
                coverPath: folderPath != null
                    ? library.resolvedCoverPathForFolder(folderPath)
                    : library.resolvedPlaybackCoverPathForTrack(
                        representative,
                      ),
                coverCacheWidth: widget.coverCacheWidth,
                browseThumbnail: true,
              ),
      );
    }
    final addHint = widget.folder
        ? (root ? 'add_work_to_queue' : 'add')
        : 'add_audio_to_queue';
    final tile = FileTreeRow(
      availableWidth: widget.availableWidth,
      title: resolvedTitle,
      subtitle: widget.folder && widget.count != null
          ? i18n.tr('audio_count', {'count': widget.count})
          : widget.subtitle,
      depth: widget.depth,
      minHeight: root && widget.folder ? 64 : _queueChildRowMinHeight,
      titleMaxLines: !root && widget.folder ? 1 : 2,
      verticalPadding: root && widget.folder ? 4 : 2,
      reserveSubtitleSpace: widget.folder,
      isFolder: widget.folder,
      onTap: widget.toggle == null ? null : _handleToggle,
      titleColor: widget.expanded ? cs.primary : null,
      leading: root
          ? SizedBox.square(dimension: 40, child: cover)
          : Icon(
              widget.folder
                  ? (widget.expanded
                        ? AppDesignTokens.openFolderIcon
                        : AppDesignTokens.folderIcon)
                  : AppDesignTokens.audioFileIcon,
              size: AppDesignTokens.fileEntryIconSize,
              color: widget.folder
                  ? AppDesignTokens.of(context).folderColor
                  : cs.primary,
            ),
      trailingSpacing: AppSpacing.xxs,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: IconButton(
              tooltip: i18n.tr(widget.removing ? 'remove' : addHint),
              onPressed: _handleAction,
              style: appIconButtonStyle(
                IconButton.styleFrom(
                  foregroundColor: widget.removing ? cs.error : cs.primary,
                  minimumSize: const Size.square(44),
                  maximumSize: const Size.square(44),
                  padding: EdgeInsets.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
              icon: Icon(
                widget.removing
                    ? Icons.remove_circle_outline_rounded
                    : Icons.add_circle_outline_rounded,
                size: 22,
              ),
            ),
          ),
          if (widget.folder) ...[
            const SizedBox(width: 2),
            if (widget.loading)
              const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              FileTreeExpansionArrow(
                expanded: widget.expanded,
                color: widget.expanded ? cs.primary : null,
              ),
          ],
        ],
      ),
    );
    return _cachedChild = widget.folder
        ? Semantics(expanded: widget.expanded, child: tile)
        : tile;
  }

  String _workTitle(WidgetRef ref, MusicTrack track) {
    if (track.isRemoteAsmr) {
      return ref.read(audioPathCoordinatorProvider).workTitleForTrack(track);
    }

    final workRootPath = widget.workRootPath;
    final AudioDetailTarget resolvedTarget;
    if (workRootPath != null) {
      if (widget.workNameDisplay != WorkNameDisplay.workTitle) {
        if (track.isSingle) {
          return PathDisplay.fileName(track.path, withoutExtension: true);
        }
        return _folderDisplayTitle(workRootPath, track);
      }
      resolvedTarget = AudioDetailTarget.libraryRootFolder(workRootPath);
    } else {
      resolvedTarget = ref
          .read(libraryFacadeProvider)
          .audioDetailTargetForTrack(track);
    }

    if (widget.workNameDisplay == WorkNameDisplay.workTitle) {
      final title = ref.watch(
        libraryDetailForTargetProvider(
          resolvedTarget,
        ).select((detail) => detail.value?.workTitle.trim() ?? ''),
      );
      if (title.isNotEmpty) return title;
    }

    if (track.isSingle) {
      return PathDisplay.fileName(track.path, withoutExtension: true);
    }
    return _folderDisplayTitle(resolvedTarget.targetPath, track);
  }

  String _folderDisplayTitle(String folderPath, MusicTrack track) {
    final folder = PathDisplay.folderName(folderPath);
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
  final (PlaybackQueueEntryPreview, PlaybackQueueEntry?, bool, bool, int)
  content;
  final (AppLanguage, int?, WorkNameDisplay, double?) display;
  final int? dragIndex;
  final void Function(PointerDownEvent, BuildContext)? onStartDrag;
  final Widget Function(VoidCallback triggerRemove) builder;
  final VoidCallback onRemove;

  const _AnimatedQueueEntry({
    super.key,
    required this.content,
    required this.display,
    required this.dragIndex,
    required this.onStartDrag,
    required this.builder,
    required this.onRemove,
  });

  @override
  State<_AnimatedQueueEntry> createState() => _AnimatedQueueEntryState();
}

class _AnimatedQueueEntryState extends State<_AnimatedQueueEntry> {
  bool _isRemoving = false;
  late Widget _row = widget.builder(_triggerRemove);
  late Widget _entry = _wrapDrag(_row);

  Widget _wrapDrag(Widget row) {
    final dragIndex = widget.dragIndex;
    if (dragIndex == null) return row;
    return ReorderableDelayedDragStartListener(
      index: dragIndex,
      child: Listener(
        onPointerDown: (event) => widget.onStartDrag?.call(event, context),
        child: row,
      ),
    );
  }

  @override
  void didUpdateWidget(covariant _AnimatedQueueEntry oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The reorderable sliver calls its builder on pointer moves. Reuse the
    // row widget when entry data is stable and only rewrap if dragIndex moved.
    final contentChanged =
        !identical(oldWidget.content.$2, widget.content.$2) ||
        oldWidget.content != widget.content ||
        oldWidget.display != widget.display;
    if (contentChanged) {
      _row = widget.builder(_triggerRemove);
    }
    if (contentChanged ||
        oldWidget.dragIndex != widget.dragIndex ||
        (oldWidget.onStartDrag == null) != (widget.onStartDrag == null)) {
      _entry = _wrapDrag(_row);
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
