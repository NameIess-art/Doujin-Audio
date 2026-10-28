import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/state/app_runtime_providers.dart';
import '../../../app/presentation/app_presentation_providers.dart';
import '../../../app/presentation/screen_view_models.dart';
import '../../../core/logging/app_log_service.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/ui/ui_interaction_coordinator.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/library_like_cards.dart';
import '../../../core/widgets/operation_feedback.dart';
import '../../../core/widgets/search_highlight.dart';
import '../application/library_facade.dart';
import '../domain/library_node.dart';
import 'library_providers.dart';
import 'library_tab_empty_scan.dart';
import 'library_tab_tree_widgets.dart';
import 'library_tab_ui_helpers.dart';

/// Owns the asynchronous tree result for a submitted library search.
class LibrarySearchAllResults extends ConsumerStatefulWidget {
  const LibrarySearchAllResults({
    super.key,
    required this.query,
    this.queryRevision = 0,
    required this.structureRevision,
    required this.detailRevision,
    required this.scrollController,
    required this.topPadding,
    required this.isSelectionMode,
    required this.selectedPaths,
    required this.onEnterSelectionMode,
    required this.onToggleSelection,
    required this.onTreeChanged,
  });

  final String query;
  // Resubmitting the same query also resets its previous error.
  final int queryRevision;
  final int structureRevision;
  final int detailRevision;
  final ScrollController scrollController;
  final double topPadding;
  final bool isSelectionMode;
  final Set<String> selectedPaths;
  final ValueChanged<LibraryNode> onEnterSelectionMode;
  final ValueChanged<LibraryNode> onToggleSelection;
  final ValueChanged<List<LibraryNode>> onTreeChanged;

  @override
  ConsumerState<LibrarySearchAllResults> createState() =>
      _LibrarySearchAllResultsState();
}

class _LibrarySearchAllResultsState
    extends ConsumerState<LibrarySearchAllResults> {
  static const _searchCommitKey = 'library_search_page';

  final _searchIndex = LibrarySearchIndex();
  FilteredLibraryTreeResult? _visibleSearchResult;
  String _visibleSearchQuery = '';
  int? _visibleSearchRevision;
  int? _visibleSearchDetailRevision;
  String? _pendingSearchKey;
  Object? _visibleSearchError;
  String? _visibleSearchErrorKey;
  final Set<String> _expandedSearchFolderPaths = <String>{};
  List<VisibleLibraryItem> _visibleSearchItems = const <VisibleLibraryItem>[];
  List<LibraryNode>? _visibleSearchItemsSource;
  int _visibleSearchItemsVersion = 0;
  int _visibleSearchItemsCacheVersion = -1;

  @override
  void didUpdateWidget(covariant LibrarySearchAllResults oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query ||
        oldWidget.queryRevision != widget.queryRevision) {
      _pendingSearchKey = null;
      _clearSearchError();
    }
    if (widget.isSelectionMode && !oldWidget.isSelectionMode) {
      _expandedSearchFolderPaths.clear();
      _visibleSearchItemsVersion++;
    }
  }

  @override
  void dispose() {
    UiInteractionCoordinator.instance.cancelCommit(_searchCommitKey);
    super.dispose();
  }

  void _ensureFilteredSearchSnapshot({
    required LibraryFacade libraryFacade,
    required String query,
    required int structureRevision,
    required int detailRevision,
  }) {
    final resolvedCategorySnapshot = currentLibraryCategorySnapshot(
      snapshot: libraryFacade.categorySnapshot,
      detailRevision: detailRevision,
    );
    final categorySnapshot =
        resolvedCategorySnapshot?.structureRevision == structureRevision
        ? resolvedCategorySnapshot
        : null;
    final categoryRevision = detailRevision;
    if (_visibleSearchQuery == query &&
        _visibleSearchRevision == structureRevision &&
        _visibleSearchDetailRevision == categoryRevision) {
      return;
    }

    final requestKey = '$structureRevision|$categoryRevision|$query';
    final queryRevision = widget.queryRevision;
    bool isCurrentRequest() =>
        mounted &&
        widget.queryRevision == queryRevision &&
        _pendingSearchKey == requestKey;
    if (_pendingSearchKey == requestKey) {
      return;
    }
    if (_visibleSearchErrorKey == requestKey) {
      return;
    }

    _pendingSearchKey = requestKey;
    final searchFuture = () async {
      final cached = _searchIndex.cachedResult(
        query: query,
        structureRevision: structureRevision,
        detailRevision: categoryRevision,
      );
      if (cached != null) return cached;
      final effectiveCategorySnapshot =
          categorySnapshot ??
          await libraryFacade.audioLibraryCategorySnapshot();
      if (!isCurrentRequest()) return null;
      final tree = await libraryFacade.loadLibraryTree();
      if (!isCurrentRequest()) return null;
      final request = LibrarySearchSnapshotRequest(
        tree: tree,
        query: query,
        structureRevision: structureRevision,
        categorySnapshot: effectiveCategorySnapshot,
      );
      final result = libraryTreeTrackCount(tree) > 200
          ? await compute(buildFilteredLibraryTreeSnapshot, request)
          : buildFilteredLibraryTreeSnapshot(request);
      if (isCurrentRequest()) {
        _searchIndex.storeResult(
          query: query,
          structureRevision: structureRevision,
          detailRevision: categoryRevision,
          result: result,
        );
      }
      return result;
    }();
    unawaited(
      searchFuture.then<void>(
        (result) {
          if (result == null || !isCurrentRequest()) {
            return;
          }
          UiInteractionCoordinator.instance.scheduleCommit(
            key: _searchCommitKey,
            priority: 5,
            commit: () {
              if (!isCurrentRequest()) return;
              setState(() {
                _visibleSearchResult = result;
                _visibleSearchQuery = query;
                _visibleSearchRevision = structureRevision;
                _visibleSearchDetailRevision = categoryRevision;
                _pendingSearchKey = null;
                _clearSearchError();
                _expandedSearchFolderPaths
                  ..clear()
                  ..addAll(
                    result.expandedFolderPaths.map(PathMatcher.normalize),
                  );
                _visibleSearchItemsVersion++;
              });
            },
          );
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!isCurrentRequest()) return;
          AppLogService.error(
            'library_search_snapshot_failed',
            error: error,
            stackTrace: stackTrace,
          );
          setState(() {
            _pendingSearchKey = null;
            _visibleSearchError = error;
            _visibleSearchErrorKey = requestKey;
          });
        },
      ),
    );
  }

  void _clearSearchError() {
    _visibleSearchError = null;
    _visibleSearchErrorKey = null;
  }

  void _retrySearch() {
    setState(() {
      _pendingSearchKey = null;
      _clearSearchError();
    });
  }

  void _handleSearchFolderExpansionChanged(FolderNode folder, bool expanded) {
    final normalizedPath = PathMatcher.normalize(folder.path);
    final changed = expanded
        ? _expandedSearchFolderPaths.add(normalizedPath)
        : _expandedSearchFolderPaths.remove(normalizedPath);
    if (changed) {
      setState(() => _visibleSearchItemsVersion++);
    }
  }

  List<VisibleLibraryItem> _flattenVisibleSearchTree(List<LibraryNode> tree) {
    if (identical(_visibleSearchItemsSource, tree) &&
        _visibleSearchItemsCacheVersion == _visibleSearchItemsVersion) {
      return _visibleSearchItems;
    }
    final result = <VisibleLibraryItem>[];
    void addNode(LibraryNode node, int depth) {
      result.add(VisibleLibraryItem(node: node, depth: depth));
      if (node is! FolderNode ||
          !_expandedSearchFolderPaths.contains(
            PathMatcher.normalize(node.path),
          )) {
        return;
      }
      for (final child in node.children) {
        addNode(child, depth + 1);
      }
    }

    for (final node in tree) {
      addNode(node, 0);
    }
    _visibleSearchItemsSource = tree;
    _visibleSearchItemsCacheVersion = _visibleSearchItemsVersion;
    return _visibleSearchItems = result;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.query.trim().isEmpty) return const SizedBox.shrink();
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final libraryFacade = ref.read(libraryFacadeProvider);
    final structureRevision = widget.structureRevision;
    final detailRevision = widget.detailRevision;
    final topPadding = widget.topPadding;
    _ensureFilteredSearchSnapshot(
      libraryFacade: libraryFacade,
      query: widget.query,
      structureRevision: structureRevision,
      detailRevision: detailRevision,
    );
    final hasCurrentError =
        _visibleSearchErrorKey ==
        '$structureRevision|$detailRevision|${widget.query}';
    // Keep mounted rows while the next query is filtered; the first load still
    // uses a skeleton, and a failed new query keeps the existing error behavior.
    final result = hasCurrentError && _visibleSearchQuery != widget.query
        ? null
        : _visibleSearchResult;
    final tree = result?.tree;
    if (tree != null) widget.onTreeChanged(tree);
    final Widget content;
    if (tree == null && hasCurrentError) {
      content = AppErrorState(
        key: const ValueKey<String>('library_search_error'),
        title: i18n.tr('error'),
        message: i18n.tr('operation_failed_retry'),
        retryLabel: i18n.tr('retry'),
        onRetry: _retrySearch,
      );
    } else if (tree == null) {
      content = const SizedBox.shrink();
    } else if (tree.isEmpty) {
      content = AppEmptyState(
        key: const ValueKey<String>('library_search_empty'),
        icon: Icons.search_off_rounded,
        title: i18n.tr('no_search_results'),
        message: i18n.tr('search_try_another_term'),
      );
    } else {
      final visibleItems = _flattenVisibleSearchTree(tree);
      final errorItemCount = hasCurrentError ? 1 : 0;
      content = SearchHighlightScope(
        query: _visibleSearchQuery,
        child: ListView.builder(
          key: const ValueKey<String>('library_search_results_all'),
          controller: widget.scrollController,
          padding: EdgeInsets.fromLTRB(
            LibraryLikeCardMetrics.listHorizontalPadding,
            topPadding,
            LibraryLikeCardMetrics.listHorizontalPadding,
            MediaQuery.paddingOf(context).bottom + 96,
          ),
          cacheExtent: 120,
          physics: const ClampingScrollPhysics(),
          itemCount: visibleItems.length + errorItemCount,
          itemBuilder: (context, index) {
            if (hasCurrentError && index == 0) {
              return Padding(
                key: const ValueKey<String>('library_search_stale_error'),
                padding: const EdgeInsets.only(bottom: 8),
                child: OperationStatusBanner(
                  label: i18n.tr('operation_failed_retry'),
                  error: _visibleSearchError,
                  onRetry: _retrySearch,
                  retryTooltip: i18n.tr('retry'),
                ),
              );
            }
            final item = visibleItems[index - errorItemCount];
            final node = item.node;
            return Padding(
              padding: EdgeInsets.only(left: item.depth * 8.0),
              child: RepaintBoundary(
                key: ValueKey<String>('search_${node.path}'),
                child: LibraryTreeItem(
                  node: node,
                  initiallyExpanded:
                      node is FolderNode &&
                      _expandedSearchFolderPaths.contains(
                        PathMatcher.normalize(node.path),
                      ),
                  onFolderExpansionChanged: _handleSearchFolderExpansionChanged,
                  renderChildrenInline: false,
                  searchQuery: _visibleSearchQuery,
                  isSelectionMode: item.depth == 0 && widget.isSelectionMode,
                  isSelected: widget.selectedPaths.contains(
                    selectionKeyForLibraryNode(node),
                  ),
                  onLongPress: item.depth == 0
                      ? () => widget.onEnterSelectionMode(node)
                      : null,
                  onToggleSelect: item.depth == 0
                      ? () => widget.onToggleSelection(node)
                      : null,
                ),
              ),
            );
          },
        ),
      );
    }
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (_) {
        ref.read(libraryCoverUiControllerProvider).viewportChanged();
        return false;
      },
      child: PlaceholderContentTransition(
        showPlaceholder: result == null && !hasCurrentError,
        placeholder: LibraryLoadingSkeleton(
          bottomInset: 16,
          topInset: topPadding,
        ),
        content: content,
      ),
    );
  }
}
