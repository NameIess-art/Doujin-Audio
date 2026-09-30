import 'dart:async';
import 'package:flutter/material.dart';

import '../../../app/localization/app_language_provider.dart';
import '../domain/library_node.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/logging/app_log_service.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/library_like_cards.dart';
import '../../../core/widgets/operation_feedback.dart';

import 'library_tab_ui_helpers.dart';
import 'library_tab_tree_widgets.dart';

class _LoadedLibraryFolder {
  const _LoadedLibraryFolder({required this.folder, required this.revision});

  final FolderNode folder;
  final int revision;
}

class LibraryTreeList extends StatefulWidget {
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
  State<LibraryTreeList> createState() => _LibraryTreeListState();
}

class _LibraryTreeListState extends State<LibraryTreeList> {
  final Set<String> _expandedCardPaths = <String>{};
  final Set<String> _folderTreeErrorPaths = <String>{};
  final Map<String, bool> _cardExpansionMotions = <String, bool>{};
  final Map<String, Timer> _cardExpansionMotionTimers = <String, Timer>{};
  final Map<String, _LoadedLibraryFolder> _loadedFolderTrees =
      <String, _LoadedLibraryFolder>{};
  final Map<String, int> _loadingFolderTreeRevisions = <String, int>{};
  List<VisibleLibraryItem> _visibleItemsCache = const <VisibleLibraryItem>[];
  List<LibraryNode>? _visibleItemsSource;
  int? _visibleItemsStructureRevision;
  int _visibleItemsVersion = 0;
  int _visibleItemsCacheVersion = -1;
  int _prunedFolderTreeRevision = -1;

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
  void dispose() {
    for (final timer in _cardExpansionMotionTimers.values) {
      timer.cancel();
    }
    super.dispose();
  }

  void _handleCardExpansionChanged(FolderNode folder, bool expanded) {
    final folderPath = folder.path;
    final normalizedPath = PathMatcher.normalize(folderPath);
    _cardExpansionMotionTimers.remove(normalizedPath)?.cancel();
    final changed = expanded
        ? _expandedCardPaths.add(normalizedPath)
        : _expandedCardPaths.remove(normalizedPath);
    if (!changed || !mounted) return;
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
    _expandedCardPaths.retainWhere(validExpandedPaths.contains);
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
    final visibleItems = _visibleLibraryItems(
      tree: widget.tree,
      structureRevision: widget.structureRevision,
    );
    Widget buildTopLevelLibraryItem(BuildContext context, int index) {
      if (index == visibleItems.length) {
        return const SizedBox.shrink(key: ValueKey('bottom_spacing'));
      }
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
      final treeItem = Padding(
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
      return KeyedSubtree(
        key: ValueKey(node.path),
        child: item.depth == 0
            ? treeItem
            : AnimatedTreeReveal(
                key: ValueKey<String>('library-tree-reveal:${node.path}'),
                visible: item.revealed,
                animateInitial: item.animateInitialReveal,
                child: treeItem,
              ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final columnCount = responsiveLibraryCardColumnCount(
          constraints.maxWidth,
        );
        final rowCount = (visibleItems.length / columnCount).ceil();
        return ListView.builder(
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
          physics: widget.physics,
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          itemCount: rowCount + 1,
          itemBuilder: (context, rowIndex) {
            if (rowIndex == rowCount) {
              return const SizedBox.shrink(key: ValueKey('bottom_spacing'));
            }
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
                    child: rowIndex * columnCount + column < visibleItems.length
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
        );
      },
    );
  }
}
