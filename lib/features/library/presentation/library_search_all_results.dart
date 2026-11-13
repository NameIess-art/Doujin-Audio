import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/state/app_runtime_providers.dart';
import '../../../app/presentation/app_presentation_providers.dart';
import '../../../app/presentation/screen_view_models.dart';
import '../../../core/logging/app_log_service.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/media/search_query_utils.dart';
import '../../../core/ui/ui_interaction_coordinator.dart';
import '../../../core/widgets/app_search_page.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/library_like_cards.dart';
import '../../../core/widgets/operation_feedback.dart';
import '../../../core/widgets/scroll_to_top_list.dart';
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
  late final _searchCommitKey = 'library_search_page_${identityHashCode(this)}';

  final _searchIndex = LibrarySearchIndex();
  FilteredLibraryTreeResult? _visibleSearchResult;
  String _visibleSearchQuery = '';
  int? _visibleSearchRevision;
  int? _visibleSearchDetailRevision;
  ({String key, Object token})? _pendingSearch;
  Object? _visibleSearchError;
  String? _visibleSearchErrorKey;
  final Set<String> _expandedSearchFolderPaths = <String>{};
  List<LibrarySearchRow> _visibleSearchItems = const [];
  List<LibrarySearchRow>? _offsetRows;
  List<double>? _rowOffsets;

  List<double> _offsetsFor(List<LibrarySearchRow> rows) {
    if (identical(rows, _offsetRows)) return _rowOffsets!;
    _offsetRows = rows;
    var offset = 0.0;
    return _rowOffsets = [
      offset,
      for (final row in rows) offset += libraryTileExtent(row.node),
    ];
  }

  @override
  void didUpdateWidget(covariant LibrarySearchAllResults oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query ||
        oldWidget.queryRevision != widget.queryRevision) {
      _pendingSearch = null;
      _clearSearchError();
    }
    if (widget.isSelectionMode && !oldWidget.isSelectionMode) {
      _expandedSearchFolderPaths.clear();
      final tree = _visibleSearchResult?.tree;
      if (tree != null) {
        _visibleSearchItems = projectLibrarySearchRows(tree, const {});
      }
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
    if (_pendingSearch?.key == requestKey) return;
    if (_visibleSearchErrorKey == requestKey) return;

    final token = Object();
    _pendingSearch = (key: requestKey, token: token);
    bool isCurrentRequest() =>
        mounted &&
        widget.queryRevision == queryRevision &&
        widget.structureRevision == structureRevision &&
        widget.detailRevision == detailRevision &&
        identical(_pendingSearch?.token, token);
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
      final background = libraryTreeTrackCount(tree) > 200;
      final result = background
          ? await _searchIndex.searchInBackground(
              tree: tree,
              query: query,
              structureRevision: structureRevision,
              detailRevision: detailRevision,
              categorySnapshot: effectiveCategorySnapshot,
            )
          : _searchIndex.resolve(
              tree: tree,
              query: query,
              structureRevision: structureRevision,
              categorySnapshot: effectiveCategorySnapshot,
            );
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
                _pendingSearch = null;
                _clearSearchError();
                _expandedSearchFolderPaths
                  ..clear()
                  ..addAll(result.expandedFolderPaths);
                _visibleSearchItems = result.initialRows;
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
            _pendingSearch = null;
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
      _pendingSearch = null;
      _clearSearchError();
    });
  }

  void _handleSearchFolderExpansionChanged(FolderNode folder, bool expanded) {
    final normalizedPath = PathMatcher.normalize(folder.path);
    final changed = expanded
        ? _expandedSearchFolderPaths.add(normalizedPath)
        : _expandedSearchFolderPaths.remove(normalizedPath);
    if (!changed) return;
    final rows = _visibleSearchItems;
    final start = rows.indexWhere((row) => identical(row.node, folder));
    if (start < 0) return;
    final depth = rows[start].depth;
    var end = start + 1;
    while (end < rows.length && rows[end].depth > depth) {
      end++;
    }
    setState(() {
      _visibleSearchItems = [
        ...rows.take(start + 1),
        if (expanded)
          ...projectLibrarySearchRows(
            folder.children,
            _expandedSearchFolderPaths,
            depth: depth + 1,
          ),
        ...rows.skip(end),
      ];
    });
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
      final visibleItems = _visibleSearchItems;
      final errorItemCount = hasCurrentError ? 1 : 0;
      final offsets = !hasCurrentError && libraryTileExtentsAreFixed(context)
          ? _offsetsFor(visibleItems)
          : null;
      final highlightQuery = searchElementHighlight(_visibleSearchQuery);
      content = SearchHighlightScope(
        query: highlightQuery,
        child: ScrollToTopListView.builder(
          key: const ValueKey<String>('library_search_results_all'),
          controller: widget.scrollController,
          padding: EdgeInsets.fromLTRB(
            LibraryLikeCardMetrics.listHorizontalPadding,
            topPadding,
            LibraryLikeCardMetrics.listHorizontalPadding,
            AppSearchPageScaffold.contentBottomInset(context),
          ),
          cacheExtent: 120,
          physics: const ClampingScrollPhysics(),
          itemCount: visibleItems.length + errorItemCount,
          rowOffsets: offsets,
          itemExtentBuilder: offsets == null
              ? null
              : (index, _) => offsets[index + 1] - offsets[index],
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
              key: ValueKey<String>('search_${node.path}'),
              padding: EdgeInsets.only(left: item.depth * 8.0),
              child: LibraryTreeItem(
                node: node,
                initiallyExpanded:
                    node is FolderNode &&
                    _expandedSearchFolderPaths.contains(
                      PathMatcher.normalize(node.path),
                    ),
                onFolderExpansionChanged: _handleSearchFolderExpansionChanged,
                renderChildrenInline: false,
                searchQuery: highlightQuery,
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
