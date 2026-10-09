import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../app/presentation/browse_page_scroll.dart';

import '../../../app/localization/app_language_provider.dart';
import '../domain/library_node.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/logging/app_log_service.dart';
import '../../../core/ui/undoable_removal_service.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/animated_reorder.dart';
import '../../../core/widgets/library_like_cards.dart';
import '../../../core/widgets/operation_feedback.dart';

import 'library_tab_ui_helpers.dart';
import 'library_tab_tree_widgets.dart';

class _LoadedLibraryFolder {
  const _LoadedLibraryFolder({required this.folder, required this.revision});

  final FolderNode folder;
  final int revision;
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
  List<VisibleLibraryItem> _visibleItemsCache = const <VisibleLibraryItem>[];
  List<LibraryNode>? _visibleItemsSource;
  int? _visibleItemsStructureRevision;
  int _visibleItemsVersion = 0;
  int _visibleItemsCacheVersion = -1;
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
    if (TickerMode.valuesOf(context).enabled && _removalMotionActive) {
      _scheduleRemovalMotionEnd();
    }
  }

  @override
  void dispose() {
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
    if (animate) {
      _cardExpansionMotionTimers[normalizedPath] = Timer(
        kAppMotionStandard,
        () {
          _cardExpansionMotionTimers.remove(normalizedPath);
          if (!mounted || _cardExpansionMotions[normalizedPath] != expanded) {
            return;
          }
          setState(() {
            _cardExpansionMotions.remove(normalizedPath);
            _visibleItemsVersion++;
          });
        },
      );
    }
    if (expanded && folder.depth == 0) {
      unawaited(_loadExpandedFolderTree(folderPath));
    }
  }

  Future<void> _loadExpandedFolderTree(String folderPath) async {
    final normalizedPath = PathMatcher.normalize(folderPath);
    final revision = widget.currentStructureRevision();
    if (_loadedFolderTrees[normalizedPath]?.revision == revision ||
        _loadingFolderTreeRevisions[normalizedPath] == revision) {
      return;
    }
    _loadingFolderTreeRevisions[normalizedPath] = revision;
    try {
      final folder = await widget.loadFolder(folderPath);
      if (!mounted) return;
      if (folder == null || widget.currentStructureRevision() != revision) {
        if (_folderTreeErrorPaths.add(normalizedPath)) {
          setState(() {
            _visibleItemsVersion++;
          });
        }
        return;
      }
      _folderTreeErrorPaths.remove(normalizedPath);
      if (_loadedFolderTrees[normalizedPath] == null &&
          folder.children.isNotEmpty &&
          _expandedCardPaths.contains(normalizedPath) &&
          ModalRoute.isCurrentOf(context) != false &&
          !MediaQuery.disableAnimationsOf(context) &&
          widget.tree.whereType<FolderNode>().any(
            (root) =>
                PathMatcher.equalsNormalized(root.path, folderPath) &&
                root.children.isEmpty,
          )) {
        final animation = AnimationController(
          vsync: this,
          duration: kPlaceholderContentTransitionDuration,
        );
        _folderLoadAnimations[normalizedPath] = (
          controller: animation,
          opacity: animation.drive(CurveTween(curve: Curves.easeInOutCubic)),
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
      setState(() {
        final previousFolder = _loadedFolderTrees[normalizedPath]?.folder;
        _loadedFolderTrees[normalizedPath] = _LoadedLibraryFolder(
          folder: folder,
          revision: revision,
        );
        if (previousFolder != null) {
          _removeMissingExpandedFolderPaths(previousFolder, folder);
        }
        _visibleItemsVersion++;
      });
    } catch (e, st) {
      AppLogService.warning(
        'Failed to load expanded folder tree: $folderPath',
        error: e,
        stackTrace: st,
      );
      if (mounted) {
        if (_folderTreeErrorPaths.add(normalizedPath)) {
          setState(() {
            _visibleItemsVersion++;
          });
        }
      }
    } finally {
      if (_loadingFolderTreeRevisions[normalizedPath] == revision) {
        _loadingFolderTreeRevisions.remove(normalizedPath);
      }
    }
  }

  List<VisibleLibraryItem> _visibleLibraryItems({
    required List<LibraryNode> tree,
    required int structureRevision,
  }) {
    _pruneFolderTreeCaches(tree, structureRevision);
    if (identical(_visibleItemsSource, tree) &&
        _visibleItemsStructureRevision == structureRevision &&
        _visibleItemsCacheVersion == _visibleItemsVersion) {
      return _visibleItemsCache;
    }
    final result = <VisibleLibraryItem>[];

    void addNode(
      LibraryNode node,
      int depth, {
      FolderNode? expandedFolder,
      bool revealed = true,
      bool animateInitialReveal = false,
    }) {
      result.add(
        VisibleLibraryItem(
          node: node,
          depth: depth,
          revealed: revealed,
          animateInitialReveal: animateInitialReveal,
        ),
      );
      if (node is! FolderNode) {
        return;
      }
      final normalizedPath = PathMatcher.normalize(node.path);
      final expanded = _expandedCardPaths.contains(normalizedPath);
      final motion = _cardExpansionMotions[normalizedPath];
      if (!expanded && motion != false) return;
      final revealChildren = revealed && expanded;
      final animateChildren =
          animateInitialReveal || (revealChildren && motion == true);
      final children = (expandedFolder ?? node).children;
      if (expanded &&
          children.isEmpty &&
          _folderTreeErrorPaths.contains(normalizedPath)) {
        result.add(
          VisibleLibraryItem(
            node: node,
            depth: depth + 1,
            revealed: revealChildren,
            animateInitialReveal: animateChildren,
            isFolderError: true,
            errorFolderPath: node.path,
          ),
        );
      } else {
        for (final child in children) {
          addNode(
            child,
            depth + 1,
            revealed: revealChildren,
            animateInitialReveal: animateChildren,
          );
        }
      }
    }

    final staleExpandedFolders = <String>[];
    for (final node in tree) {
      if (node is! FolderNode) {
        addNode(node, 0);
        continue;
      }
      final normalizedPath = PathMatcher.normalize(node.path);
      final loaded = _loadedFolderTrees[normalizedPath];
      addNode(node, 0, expandedFolder: loaded?.folder);
      if (_expandedCardPaths.contains(normalizedPath) &&
          loaded?.revision != structureRevision &&
          _loadingFolderTreeRevisions[normalizedPath] != structureRevision &&
          !_folderTreeErrorPaths.contains(normalizedPath)) {
        staleExpandedFolders.add(node.path);
      }
    }
    if (staleExpandedFolders.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        for (final path in staleExpandedFolders) {
          unawaited(_loadExpandedFolderTree(path));
        }
      });
    }
    _visibleItemsSource = tree;
    _visibleItemsStructureRevision = structureRevision;
    _visibleItemsCacheVersion = _visibleItemsVersion;
    return _visibleItemsCache = result;
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
    final visibleItems = _visibleLibraryItems(
      tree: widget.tree,
      structureRevision: widget.structureRevision,
    );
    final itemIds = visibleItems
        .where((item) => !item.isFolderError)
        .map((item) => PathMatcher.equivalenceKey(item.node.path))
        .toList(growable: false);
    final currentIds = itemIds.toSet();
    _itemKeys.removeWhere((id, _) => !currentIds.contains(id));
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
    final useFixedExtent =
        !_removalMotionActive &&
        _removingItemIds.isEmpty &&
        _expandedCardPaths.isEmpty &&
        _cardExpansionMotions.isEmpty &&
        tilePadding <= LibraryLikeCardMetrics.coverDistance &&
        visibleItems.every(
          (item) =>
              item.depth == 0 &&
              !item.isFolderError &&
              isSelectableLibraryNode(item.node),
        );
    final itemIndices = <Key, int>{};
    BrowsePageScroll.setAnchorIds(
      context,
      visibleItems.map((item) => PathMatcher.equivalenceKey(item.node.path)),
    );
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
      final id = PathMatcher.equivalenceKey(node.path);
      // The sliver changes when expanding/removing rows. Keep the card's State
      // (including its undo size animation) when it moves between those slivers.
      final itemKey = _itemKeys.putIfAbsent(id, GlobalKey.new);
      itemIndices[itemKey] = index;
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

    return LayoutBuilder(
      builder: (context, constraints) {
        final columnCount = responsiveLibraryCardColumnCount(
          constraints.maxWidth,
        );
        final rowCount = (visibleItems.length / columnCount).ceil();
        itemIndices.clear();
        if (columnCount == 1) {
          for (var i = 0; i < visibleItems.length; i++) {
            final key =
                _itemKeys[PathMatcher.equivalenceKey(
                  visibleItems[i].node.path,
                )];
            if (!visibleItems[i].isFolderError && key != null) {
              itemIndices[key] = i;
            }
          }
        }
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
                ? (key) => itemIndices[key]
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
  }
}
