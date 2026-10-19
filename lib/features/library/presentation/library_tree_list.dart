import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../app/presentation/browse_page_scroll.dart';

import '../../../app/localization/app_language_provider.dart';
import '../domain/library_node.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/immutable_collections.dart';
import '../../../core/logging/app_log_service.dart';
import '../../../core/ui/undoable_removal_service.dart';
import '../../../core/ui/ui_interaction_coordinator.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/animated_reorder.dart';
import '../../../core/widgets/library_like_cards.dart';
import '../../../core/widgets/operation_feedback.dart';

import 'library_tab_ui_helpers.dart';
import 'library_tab_tree_widgets.dart';
import '../../settings/presentation/settings_providers.dart';

class _LoadedLibraryFolder {
  const _LoadedLibraryFolder({required this.folder, required this.revision});

  final FolderNode folder;
  final int revision;
}

typedef _ProjectionInput = ({
  List<LibraryNode> tree,
  Map<String, _LoadedLibraryFolder> loaded,
  Set<String> expanded,
  Map<String, bool> motions,
  Set<String> errors,
});

typedef _LibraryProjection = ({
  List<
    ({List<int> indices, int depth, bool revealed, bool animate, bool error})
  >
  rows,
  List<String> ids,
  List<String> reorderIds,
  Map<String, int> indices,
  Set<String> nodeIds,
  bool uniformRoots,
});

_LibraryProjection _buildLibraryProjection(_ProjectionInput input) {
  final rows =
      <
        ({
          List<int> indices,
          int depth,
          bool revealed,
          bool animate,
          bool error,
        })
      >[];
  final ids = <String>[];
  final reorderIds = <String>[];
  final indicesById = <String, int>{};
  var uniformRoots = true;
  void addNode(
    LibraryNode node,
    int depth, {
    required List<int> indices,
    FolderNode? loaded,
    bool revealed = true,
    bool animate = false,
  }) {
    rows.add((
      indices: indices,
      depth: depth,
      revealed: revealed,
      animate: animate,
      error: false,
    ));
    final id = PathMatcher.equivalenceKey(node.path);
    indicesById[id] = rows.length - 1;
    ids.add(id);
    reorderIds.add(id);
    uniformRoots = uniformRoots && depth == 0 && isSelectableLibraryNode(node);
    if (node is! FolderNode) return;
    final path = PathMatcher.normalize(node.path);
    final expanded = input.expanded.contains(path);
    final motion = input.motions[path];
    if (!expanded && motion != false) return;
    final showChildren = revealed && expanded;
    final animateChildren = animate || (showChildren && motion == true);
    final children = (loaded ?? node).children;
    if (expanded && children.isEmpty && input.errors.contains(path)) {
      rows.add((
        indices: indices,
        depth: depth + 1,
        revealed: showChildren,
        animate: animateChildren,
        error: true,
      ));
      ids.add(id);
      uniformRoots = false;
    } else {
      for (var index = 0; index < children.length; index++) {
        addNode(
          children[index],
          depth + 1,
          indices: [...indices, index],
          revealed: showChildren,
          animate: animateChildren,
        );
      }
    }
  }

  for (var index = 0; index < input.tree.length; index++) {
    final node = input.tree[index];
    addNode(
      node,
      0,
      indices: [index],
      loaded: node is FolderNode
          ? input.loaded[PathMatcher.normalize(node.path)]?.folder
          : null,
    );
  }
  return (
    rows: List.unmodifiable(rows),
    ids: immutableList(ids),
    reorderIds: immutableList(reorderIds),
    indices: Map.unmodifiable(indicesById),
    nodeIds: reorderIds.toSet(),
    uniformRoots: uniformRoots,
  );
}

class LibraryTreeList extends ConsumerStatefulWidget {
  const LibraryTreeList({
    super.key,
    required this.tree,
    required this.structureRevision,
    required this.selectedPaths,
    required this.isSelectionMode,
    required this.scrollController,
    required this.i18n,
    required this.topPadding,
    required this.bottomPadding,
    required this.cacheExtent,
    required this.physics,
    required this.loadFolder,
    required this.currentStructureRevision,
    required this.onLongPress,
    required this.onToggleSelect,
  });
  final List<LibraryNode> tree;
  final int structureRevision;
  final Set<String> selectedPaths;
  final bool isSelectionMode;
  final ScrollController scrollController;
  final AppLanguageProvider i18n;
  final double topPadding;
  final double bottomPadding;
  final double cacheExtent;
  final ScrollPhysics? physics;
  final Future<FolderNode?> Function(String path) loadFolder;
  final int Function() currentStructureRevision;
  final ValueChanged<LibraryNode> onLongPress;
  final ValueChanged<LibraryNode> onToggleSelect;
  @override
  ConsumerState<LibraryTreeList> createState() => _LibraryTreeListState();
}

class _LibraryTreeListState extends ConsumerState<LibraryTreeList>
    with TickerProviderStateMixin {
  final Set<String> _expandedCardPaths = <String>{};
  final Set<String> _folderTreeErrorPaths = <String>{};
  final Map<String, bool> _cardExpansionMotions = <String, bool>{};
  final Map<String, Timer> _cardExpansionMotionTimers = <String, Timer>{};
  final Map<String, _LoadedLibraryFolder> _loadedFolderTrees =
      <String, _LoadedLibraryFolder>{};
  final Map<String, int> _loadingFolderTreeRevisions = <String, int>{};
  final Map<
    String,
    ({AnimationController controller, Animation<double> opacity})
  >
  _folderLoadAnimations = {};
  final Set<String> _pendingFolderReveals = {};
  List<VisibleLibraryItem> _visibleItemsCache = const <VisibleLibraryItem>[];
  Set<String> _presentedPinnedPaths = const {};
  List<String> _visibleItemIds = const [];
  List<String> _reorderItemIds = const [];
  Set<String> _visibleNodeIds = const {};
  Map<String, int> _itemIndexById = const {};
  final Map<Key, int> _itemKeyIndices = {};
  int _visibleItemsVersion = 0;
  (List<LibraryNode>, int, int)? _projectionRequest;
  bool _projectionRunning = false;
  int _presentedProjectionVersion = -1;
  bool _uniformRoots = true;
  bool _tickerModeEnabled = true;
  ValueListenable<TickerModeData>? _tickerModeNotifier;
  ModalRoute<dynamic>? _route;
  Object? _projectionError;
  VoidCallback? _pendingProjectionCommit;
  late final String _projectionCommitKey =
      'library_projection_${identityHashCode(this)}';
  late final String _folderCommitKey =
      'library_folders_${identityHashCode(this)}';
  final Map<String, ({FolderNode? folder, int revision, bool animate})>
  _pendingFolderResults = {};
  int _prunedFolderTreeRevision = -1;
  final Map<String, GlobalKey> _itemKeys = {};
  final Set<String> _removingItemIds = {};
  final Set<UndoableRemovalKey> _removalKeys = {};
  bool _removalMotionActive = false;
  Timer? _removalMotionTimer;

  @override
  void initState() {
    super.initState();
    final expanded = ref
        .read(browsePageStateStoreProvider)
        .stateFor('library')['expanded'];
    if (expanded is List) {
      _expandedCardPaths.addAll(expanded.whereType<String>());
    }
  }

  @override
  void didUpdateWidget(covariant LibraryTreeList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isSelectionMode && !oldWidget.isSelectionMode) {
      _expandedCardPaths.clear();
      _cardExpansionMotions.clear();
      _visibleItemsVersion++;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final notifier = TickerMode.getValuesNotifier(context);
    if (!identical(notifier, _tickerModeNotifier)) {
      _tickerModeNotifier?.removeListener(_handleActivityChanged);
      _tickerModeNotifier = notifier;
      notifier.addListener(_handleActivityChanged);
    }
    _handleActivityChanged();
  }

  void _handleActivityChanged() {
    _tickerModeEnabled = _tickerModeNotifier?.value.enabled ?? true;
    _scheduleFolderCommit();
    _scheduleProjectionCommit();
    _prepareVisibleItems();
    if (_tickerModeEnabled &&
        _presentedProjectionVersion == _visibleItemsVersion) {
      for (final entry in _cardExpansionMotions.entries) {
        _scheduleExpansionEnd(entry.key, entry.value);
      }
    }
    if (_tickerModeEnabled && _removalMotionActive) {
      _scheduleRemovalMotionEnd();
    }
  }

  @override
  void dispose() {
    _tickerModeNotifier?.removeListener(_handleActivityChanged);
    UiInteractionCoordinator.instance.cancelCommit(_projectionCommitKey);
    UiInteractionCoordinator.instance.cancelCommit(_folderCommitKey);
    _pendingProjectionCommit = null;
    _pendingFolderResults.clear();
    _removalMotionTimer?.cancel();
    for (final timer in _cardExpansionMotionTimers.values) {
      timer.cancel();
    }
    for (final animation in _folderLoadAnimations.values) {
      animation.controller.dispose();
    }
    super.dispose();
  }

  void _handleRemovalChanged(
    UndoableRemovalState? previous,
    UndoableRemovalState next,
  ) {
    var changed = false;
    for (final key in next.hiddenKeys) {
      if (key.namespace == 'library') {
        _removalKeys.add(key);
        changed =
            _removingItemIds.add(PathMatcher.equivalenceKey(key.id)) || changed;
      }
    }
    for (final key in next.restoredKeys) {
      if (key.namespace == 'library') {
        _removalKeys.add(key);
        changed =
            _removingItemIds.remove(PathMatcher.equivalenceKey(key.id)) ||
            changed;
      }
    }
    if (!changed) return;
    setState(() => _removalMotionActive = true);
    _scheduleRemovalMotionEnd();
  }

  void _scheduleRemovalMotionEnd() {
    _removalMotionTimer?.cancel();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !TickerMode.getValuesNotifier(context).value.enabled) {
        return;
      }
      // Undo runs the existing row's size animation in reverse. Start the quiet
      // window after its first ticker frame, retaining variable extents until
      // the row has completed rather than constraining its unfinished motion.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !TickerMode.getValuesNotifier(context).value.enabled) {
          return;
        }
        _removalMotionTimer?.cancel();
        _removalMotionTimer = Timer(kAppMotionStandard, () {
          _removalMotionTimer = null;
          // A hidden page can receive undo before its ticker has ever started.
          // Resume the quiet window when the page enables tickers again.
          if (mounted && TickerMode.getValuesNotifier(context).value.enabled) {
            setState(() {
              _removalMotionActive = false;
              _removalKeys.removeWhere(
                (key) => !_removingItemIds.contains(
                  PathMatcher.equivalenceKey(key.id),
                ),
              );
            });
          }
        });
      });
      WidgetsBinding.instance.scheduleFrame();
    });
  }

  void _handleCardExpansionChanged(FolderNode folder, bool expanded) {
    final folderPath = folder.path;
    final normalizedPath = PathMatcher.normalize(folderPath);
    _cardExpansionMotionTimers.remove(normalizedPath)?.cancel();
    final changed = expanded
        ? _expandedCardPaths.add(normalizedPath)
        : _expandedCardPaths.remove(normalizedPath);
    if (!changed || !mounted) return;
    ref.read(browsePageStateStoreProvider).update('library', {
      'expanded': _expandedCardPaths.toList(),
    });
    final animate = !MediaQuery.disableAnimationsOf(context);
    setState(() {
      if (animate) {
        _cardExpansionMotions[normalizedPath] = expanded;
      } else {
        _cardExpansionMotions.remove(normalizedPath);
      }
      _visibleItemsVersion++;
    });
    if (expanded && folder.depth == 0) {
      unawaited(_loadExpandedFolderTree(folderPath));
    }
  }

  void _scheduleExpansionEnd(String path, bool expanded) {
    if (_cardExpansionMotionTimers.containsKey(path)) return;
    // Preparation can wait behind scrolling or navigation. Preserve the full
    // reveal duration from the frame that actually installs the new rows.
    _cardExpansionMotionTimers[path] = Timer(kAppMotionStandard, () {
      _cardExpansionMotionTimers.remove(path);
      if (!mounted || _cardExpansionMotions[path] != expanded) return;
      if (!_tickerModeEnabled) return;
      setState(() {
        _cardExpansionMotions.remove(path);
        _visibleItemsVersion++;
      });
    });
  }

  Future<void> _loadExpandedFolderTree(String folderPath) async {
    final normalizedPath = PathMatcher.normalize(folderPath);
    final revision = widget.currentStructureRevision();
    if (_loadedFolderTrees[normalizedPath]?.revision == revision ||
        _loadingFolderTreeRevisions[normalizedPath] == revision ||
        _pendingFolderResults[normalizedPath]?.revision == revision) {
      return;
    }
    _loadingFolderTreeRevisions[normalizedPath] = revision;
    try {
      final folder = await widget.loadFolder(folderPath);
      if (!mounted) return;
      if (widget.currentStructureRevision() != revision) return;
      _pendingFolderResults[normalizedPath] = (
        folder: folder,
        revision: revision,
        animate:
            _tickerModeEnabled &&
            _route?.isCurrent != false &&
            !MediaQuery.disableAnimationsOf(context),
      );
      _scheduleFolderCommit();
    } catch (e, st) {
      AppLogService.warning(
        'Failed to load expanded folder tree: $folderPath',
        error: e,
        stackTrace: st,
      );
      if (mounted && widget.currentStructureRevision() == revision) {
        _pendingFolderResults[normalizedPath] = (
          folder: null,
          revision: revision,
          animate: false,
        );
        _scheduleFolderCommit();
      }
    } finally {
      if (_loadingFolderTreeRevisions[normalizedPath] == revision) {
        _loadingFolderTreeRevisions.remove(normalizedPath);
      }
    }
  }

  void _scheduleFolderCommit() {
    if (_pendingFolderResults.isEmpty) return;
    UiInteractionCoordinator.instance.scheduleCommit(
      key: _folderCommitKey,
      structural: true,
      canRun: () => mounted && _tickerModeEnabled,
      commit: () {
        if (!mounted) return;
        final revision = widget.currentStructureRevision();
        final results = Map.of(_pendingFolderResults);
        _pendingFolderResults.clear();
        for (final entry in results.entries) {
          if (entry.value.revision != revision) continue;
          final folder = entry.value.folder;
          if (folder == null) {
            _folderTreeErrorPaths.add(entry.key);
          } else {
            _applyLoadedFolder(
              entry.key,
              folder,
              revision,
              animate: entry.value.animate,
            );
          }
        }
        setState(() => _visibleItemsVersion++);
      },
    );
  }

  void _applyLoadedFolder(
    String normalizedPath,
    FolderNode folder,
    int revision, {
    required bool animate,
  }) {
    _folderTreeErrorPaths.remove(normalizedPath);
    final previousFolder = _loadedFolderTrees[normalizedPath]?.folder;
    if (animate && previousFolder == null && folder.children.isNotEmpty) {
      _pendingFolderReveals.add(normalizedPath);
    }
    _loadedFolderTrees[normalizedPath] = _LoadedLibraryFolder(
      folder: folder,
      revision: revision,
    );
    if (previousFolder != null) {
      _removeMissingExpandedFolderPaths(previousFolder, folder);
    }
  }

  void _startFolderReveal(String normalizedPath) {
    final folder = _loadedFolderTrees[normalizedPath]?.folder;
    if (folder == null) return;
    if (folder.children.isNotEmpty &&
        _expandedCardPaths.contains(normalizedPath) &&
        _route?.isCurrent != false &&
        !MediaQuery.disableAnimationsOf(context) &&
        widget.tree.whereType<FolderNode>().any(
          (root) =>
              PathMatcher.equalsNormalized(root.path, folder.path) &&
              root.children.isEmpty,
        )) {
      final animation = AnimationController(
        vsync: this,
        duration: kAppFadeDuration,
      );
      _folderLoadAnimations[normalizedPath] = (
        controller: animation,
        opacity: animation.drive(CurveTween(curve: kAppFadeCurve)),
      );
      animation.addStatusListener((status) {
        if (status != AnimationStatus.completed || !mounted) return;
        setState(() => _folderLoadAnimations.remove(normalizedPath));
        // Rows detach their FadeTransition listeners in this frame's build.
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => animation.dispose(),
        );
      });
      unawaited(animation.forward());
    }
  }

  void _prepareVisibleItems() {
    if (!_tickerModeEnabled) return;
    _pruneFolderTreeCaches(widget.tree, widget.structureRevision);
    final request = (
      widget.tree,
      widget.structureRevision,
      _visibleItemsVersion,
    );
    if (_projectionRequest == request || _projectionRunning) return;
    _projectionRequest = request;
    _projectionRunning = true;
    final input = (
      tree: widget.tree,
      loaded: Map<String, _LoadedLibraryFolder>.of(_loadedFolderTrees),
      expanded: Set<String>.of(_expandedCardPaths),
      motions: Map<String, bool>.of(_cardExpansionMotions),
      errors: Set<String>.of(_folderTreeErrorPaths),
    );
    unawaited(_prepareProjection(input, request));
  }

  Future<void> _prepareProjection(
    _ProjectionInput input,
    (List<LibraryNode>, int, int) request,
  ) async {
    final pinnedPaths =
        ref.read(settingsStateProvider).value?.pinnedLibraryPaths.toSet() ??
        const <String>{};
    try {
      final projection = await compute(_buildLibraryProjection, input);
      if (!mounted) return;
      final current = (
        widget.tree,
        widget.structureRevision,
        _visibleItemsVersion,
      );
      if (current != request) {
        _projectionRequest = null;
        return;
      }
      // Workers return row locations, preserving the original node identities
      // used by selection, undo and retained cards on the UI isolate.
      final items = <VisibleLibraryItem>[];
      final slice = Stopwatch()..start();
      for (final row in projection.rows) {
        var node = input.tree[row.indices.first];
        if (row.indices.length > 1) {
          node = input.loaded[PathMatcher.normalize(node.path)]?.folder ?? node;
          for (final index in row.indices.skip(1)) {
            node = (node as FolderNode).children[index];
          }
        }
        items.add(
          VisibleLibraryItem(
            node: node,
            depth: row.depth,
            revealed: row.revealed,
            animateInitialReveal: row.animate,
            isFolderError: row.error,
            errorFolderPath: row.error ? node.path : null,
          ),
        );
        if (slice.elapsedMicroseconds >= 1000) {
          await Future<void>.delayed(Duration.zero);
          if (!mounted) return;
          if ((widget.tree, widget.structureRevision, _visibleItemsVersion) !=
              request) {
            _projectionRequest = null;
            return;
          }
          slice.reset();
        }
      }
      _pendingProjectionCommit = () {
        if ((widget.tree, widget.structureRevision, _visibleItemsVersion) !=
            request) {
          return;
        }
        for (final path in _pendingFolderReveals) {
          _startFolderReveal(path);
        }
        _pendingFolderReveals.clear();
        for (final entry in input.motions.entries) {
          _scheduleExpansionEnd(entry.key, entry.value);
        }
        setState(() {
          _projectionError = null;
          _presentedProjectionVersion = request.$3;
          _visibleItemsCache = List.unmodifiable(items);
          // Badges follow the same snapshot as the row order so they cannot
          // appear while the replacement projection is still being prepared.
          _presentedPinnedPaths = pinnedPaths;
          _visibleItemIds = projection.ids;
          _reorderItemIds = projection.reorderIds;
          _visibleNodeIds = projection.nodeIds;
          _itemIndexById = projection.indices;
          _itemKeys.removeWhere((id, _) => !_itemIndexById.containsKey(id));
          _itemKeyIndices
            ..clear()
            ..addEntries(
              _itemKeys.entries.map(
                (entry) => MapEntry(entry.value, _itemIndexById[entry.key]!),
              ),
            );
          _uniformRoots = projection.uniformRoots;
        });
        for (final node in widget.tree.whereType<FolderNode>()) {
          final path = PathMatcher.normalize(node.path);
          if (_expandedCardPaths.contains(path) &&
              _loadedFolderTrees[path]?.revision != widget.structureRevision &&
              !_folderTreeErrorPaths.contains(path)) {
            unawaited(_loadExpandedFolderTree(node.path));
          }
        }
      };
      _scheduleProjectionCommit();
    } catch (error, stackTrace) {
      AppLogService.warning(
        'Failed to prepare library rows',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        _pendingProjectionCommit = () {
          if ((widget.tree, widget.structureRevision, _visibleItemsVersion) ==
              request) {
            setState(() => _projectionError = error);
          }
        };
        _scheduleProjectionCommit();
      }
    } finally {
      _projectionRunning = false;
      if (mounted &&
          (widget.tree, widget.structureRevision, _visibleItemsVersion) !=
              request) {
        _prepareVisibleItems();
      }
    }
  }

  void _scheduleProjectionCommit() {
    if (_pendingProjectionCommit == null) return;
    UiInteractionCoordinator.instance.scheduleCommit(
      key: _projectionCommitKey,
      structural: true,
      canRun: () => mounted && _tickerModeEnabled,
      commit: () {
        final commit = _pendingProjectionCommit;
        _pendingProjectionCommit = null;
        commit?.call();
      },
    );
  }

  void _pruneFolderTreeCaches(List<LibraryNode> tree, int structureRevision) {
    if (_prunedFolderTreeRevision == structureRevision) return;
    _prunedFolderTreeRevision = structureRevision;
    final rootPaths = tree
        .whereType<FolderNode>()
        .map((folder) => PathMatcher.normalize(folder.path))
        .toSet();
    var changed = false;
    final removedRootPaths = _loadedFolderTrees.keys
        .where((path) => !rootPaths.contains(path))
        .toList(growable: false);
    for (final path in removedRootPaths) {
      _loadedFolderTrees.remove(path);
      _folderLoadAnimations.remove(path)?.controller.dispose();
      changed = true;
    }
    _loadingFolderTreeRevisions.removeWhere((path, _) {
      final remove = !rootPaths.contains(path);
      changed = changed || remove;
      return remove;
    });
    _folderTreeErrorPaths.removeWhere((path) => !rootPaths.contains(path));

    final previousExpandedCount = _expandedCardPaths.length;
    _retainCurrentExpandedFolderPaths(rootPaths: rootPaths);
    changed = changed || _expandedCardPaths.length != previousExpandedCount;
    if (changed) _visibleItemsVersion++;
  }

  void _retainCurrentExpandedFolderPaths({Set<String>? rootPaths}) {
    final validExpandedPaths = <String>{...?rootPaths};
    void collectFolderPaths(FolderNode folder) {
      validExpandedPaths.add(PathMatcher.normalize(folder.path));
      for (final child in folder.children.whereType<FolderNode>()) {
        collectFolderPaths(child);
      }
    }

    for (final loaded in _loadedFolderTrees.values) {
      collectFolderPaths(loaded.folder);
    }
    _expandedCardPaths.retainWhere(
      (path) =>
          validExpandedPaths.contains(path) ||
          (rootPaths?.any(
                (root) =>
                    !_loadedFolderTrees.containsKey(root) &&
                    PathMatcher.isWithinOrEqual(path, root),
              ) ??
              false),
    );
  }

  void _removeMissingExpandedFolderPaths(
    FolderNode previousFolder,
    FolderNode currentFolder,
  ) {
    Set<String> collectPaths(FolderNode root) {
      final paths = <String>{};
      void collect(FolderNode folder) {
        paths.add(PathMatcher.normalize(folder.path));
        for (final child in folder.children.whereType<FolderNode>()) {
          collect(child);
        }
      }

      collect(root);
      return paths;
    }

    final currentPaths = collectPaths(currentFolder);
    final removedPaths = collectPaths(previousFolder)..removeAll(currentPaths);
    _expandedCardPaths.removeAll(removedPaths);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(undoableRemovalStateProvider, _handleRemovalChanged);
    _prepareVisibleItems();
    final visibleItems = _visibleItemsCache;
    final errorBanner = _projectionError == null
        ? null
        : OperationStatusBanner(
            label: widget.i18n.tr('operation_failed_retry'),
            retryTooltip: widget.i18n.tr('retry'),
            onRetry: () {
              setState(() {
                _projectionError = null;
                _projectionRequest = null;
              });
            },
          );
    if (visibleItems.isEmpty && widget.tree.isNotEmpty) {
      if (errorBanner != null) return errorBanner;
      return LibrarySkeletonListView(
        topInset: widget.topPadding,
        bottomInset: widget.bottomPadding,
      );
    }
    final itemIds = _reorderItemIds;
    final currentIds = _visibleNodeIds;
    _removingItemIds.addAll(
      ref
          .read(undoableRemovalStateProvider)
          .hiddenKeys
          .where((key) => key.namespace == 'library')
          .map((key) => PathMatcher.equivalenceKey(key.id)),
    );
    // Committed rows stay collapsed until the source snapshot removes them.
    _removingItemIds.retainAll(currentIds);
    _removalKeys.removeWhere(
      (key) => !currentIds.contains(PathMatcher.equivalenceKey(key.id)),
    );
    // Riverpod pauses a hidden row's watch subscriptions with TickerMode. Keep
    // removal streams live through undo so a stale reverse cannot finish first
    // on resume, and retain committed state until the tree removes the row.
    for (final key in _removalKeys) {
      ref.listen(isUndoableRemovalHiddenProvider(key), (_, _) {});
    }
    final tilePadding =
        ListTileTheme.of(context).minVerticalPadding ??
        Theme.of(context).listTileTheme.minVerticalPadding ??
        (Theme.of(context).useMaterial3 ? 8.0 : 4.0);
    final uniformRootRows =
        !_removalMotionActive &&
        _removingItemIds.isEmpty &&
        _expandedCardPaths.isEmpty &&
        _cardExpansionMotions.isEmpty &&
        _uniformRoots;
    final useFixedExtent =
        uniformRootRows && tilePadding <= LibraryLikeCardMetrics.coverDistance;
    Widget buildTopLevelLibraryItem(BuildContext context, int index) {
      final item = visibleItems[index];
      final node = item.node;
      if (item.isFolderError) {
        final folderPath = item.errorFolderPath ?? node.path;
        final errorBanner = Padding(
          padding: EdgeInsets.only(left: item.depth * 8.0, top: 4, bottom: 8),
          child: OperationStatusBanner(
            key: ValueKey<String>('library_folder_error:$folderPath'),
            label: widget.i18n.tr('operation_failed_retry'),
            onRetry: () => unawaited(_loadExpandedFolderTree(folderPath)),
            retryTooltip: widget.i18n.tr('retry'),
          ),
        );
        return KeyedSubtree(
          key: ValueKey<String>('library_folder_error_subtree:$folderPath'),
          child: item.depth == 0
              ? errorBanner
              : AnimatedTreeReveal(
                  key: ValueKey<String>(
                    'library-tree-reveal:error:$folderPath',
                  ),
                  visible: item.revealed,
                  animateInitial: item.animateInitialReveal,
                  child: errorBanner,
                ),
        );
      }
      Widget treeItem = Padding(
        padding: EdgeInsets.only(left: item.depth * 8.0),
        child: RepaintBoundary(
          child: LibraryTreeItem(
            node: node,
            isPinned: _presentedPinnedPaths.contains(
              PathMatcher.normalize(node.path),
            ),
            initiallyExpanded:
                node is FolderNode &&
                _expandedCardPaths.contains(PathMatcher.normalize(node.path)),
            onFolderExpansionChanged: _handleCardExpansionChanged,
            renderChildrenInline: false,
            index: index,
            isSelectionMode: item.depth == 0 && widget.isSelectionMode,
            isSelected: widget.selectedPaths.contains(
              selectionKeyForLibraryNode(node),
            ),
            onLongPress: item.depth == 0
                ? () => widget.onLongPress(node)
                : null,
            onToggleSelect: item.depth == 0
                ? () => widget.onToggleSelect(node)
                : null,
          ),
        ),
      );
      if (item.depth > 0) {
        Animation<double> opacity = const AlwaysStoppedAnimation(1);
        if (!MediaQuery.disableAnimationsOf(context)) {
          for (final entry in _folderLoadAnimations.entries) {
            if (PathMatcher.isWithinOrEqual(node.path, entry.key)) {
              opacity = entry.value.opacity;
              break;
            }
          }
        }
        treeItem = FadeTransition(opacity: opacity, child: treeItem);
      }
      final id = _visibleItemIds[index];
      // The sliver changes when expanding/removing rows. Keep the card's State
      // (including its undo size animation) when it moves between those slivers.
      final itemKey = _itemKeys.putIfAbsent(id, GlobalKey.new);
      _itemKeyIndices[itemKey] = index;
      return AnimatedReorderItem(
        key: itemKey,
        id: id,
        child: BrowseAnchor(
          id: id,
          child: item.depth == 0
              ? treeItem
              : AnimatedTreeReveal(
                  key: ValueKey<String>('library-tree-reveal:${node.path}'),
                  visible: item.revealed,
                  animateInitial: item.animateInitialReveal,
                  child: treeItem,
                ),
        ),
      );
    }

    final list = LayoutBuilder(
      builder: (context, constraints) {
        final columnCount = responsiveLibraryCardColumnCount(
          constraints.maxWidth,
        );
        BrowsePageScroll.setAnchorIds(
          context,
          _visibleItemIds,
          columnCount: uniformRootRows ? columnCount : null,
          rowExtent: useFixedExtent
              ? LibraryLikeCardMetrics.rootTileHeight
              : null,
          topPadding: widget.topPadding,
        );
        final rowCount = (visibleItems.length / columnCount).ceil();
        return AnimatedReorder(
          order: itemIds,
          child: ListView.builder(
            key: const PageStorageKey<String>('library_list'),
            controller: widget.scrollController,
            clipBehavior: Clip.none,
            padding: EdgeInsets.fromLTRB(
              LibraryLikeCardMetrics.listHorizontalPadding,
              widget.topPadding,
              LibraryLikeCardMetrics.listHorizontalPadding,
              widget.bottomPadding,
            ),
            cacheExtent: widget.cacheExtent,
            itemExtent: useFixedExtent
                ? LibraryLikeCardMetrics.rootTileHeight
                : null,
            physics: widget.physics,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            itemCount: rowCount,
            findChildIndexCallback: columnCount == 1
                ? (key) => _itemKeyIndices[key]
                : null,
            itemBuilder: (context, rowIndex) {
              if (columnCount == 1) {
                return buildTopLevelLibraryItem(context, rowIndex);
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var column = 0; column < columnCount; column++) ...[
                    if (column > 0)
                      const SizedBox(width: kResponsiveLibraryCardSpacing),
                    Expanded(
                      child:
                          rowIndex * columnCount + column < visibleItems.length
                          ? buildTopLevelLibraryItem(
                              context,
                              rowIndex * columnCount + column,
                            )
                          : const SizedBox.shrink(),
                    ),
                  ],
                ],
              );
            },
          ),
        );
      },
    );
    final content = errorBanner == null
        ? list
        : Column(
            children: [
              errorBanner,
              Expanded(child: list),
            ],
          );
    return Builder(
      builder: (context) {
        _route = ModalRoute.of(context);
        return content;
      },
    );
  }
}
