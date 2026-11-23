import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/state/app_runtime_providers.dart';
import '../../../app/presentation/app_presentation_providers.dart';
import '../../../app/presentation/screen_view_models.dart';
import '../../../core/logging/app_log_service.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/media/search_query_utils.dart';
import '../../player/presentation/playback_providers.dart';
import '../../../core/ui/ui_interaction_coordinator.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_search_page.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/library_like_cards.dart';
import '../../../core/widgets/operation_feedback.dart';
import '../../../core/widgets/scroll_to_top_list.dart';
import '../../../core/widgets/search_highlight.dart';
import '../application/library_facade.dart';
import '../domain/audio_library_category.dart';
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
    this.filters = emptySearchFilters,
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
    this.searchIndex,
    this.onClearFilters,
    this.onEditSearch,
  });

  final String query;
  final SearchFilters filters;
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
  final LibrarySearchIndex? searchIndex;
  final VoidCallback? onClearFilters;
  final VoidCallback? onEditSearch;

  @override
  ConsumerState<LibrarySearchAllResults> createState() =>
      _LibrarySearchAllResultsState();
}

typedef _SearchKey = (int, int, String, SearchFilters);

class _LibrarySearchAllResultsState
    extends ConsumerState<LibrarySearchAllResults> {
  late final _searchCommitKey = 'library_search_page_${identityHashCode(this)}';

  LibrarySearchIndex? _ownedSearchIndex;
  LibrarySearchIndex get _searchIndex =>
      widget.searchIndex ?? (_ownedSearchIndex ??= LibrarySearchIndex());
  Listenable? _observedSubtitleService;
  FilteredLibraryTreeResult? _visibleSearchResult;
  _SearchKey? _visibleSearchKey;
  ({_SearchKey key, Object token})? _pendingSearch;
  Object? _visibleSearchError;
  _SearchKey? _visibleSearchErrorKey;

  void _handleSubtitlesChanged() {
    _searchIndex.invalidateSubtitleCache();
    if (widget.filters.hasSubtitle != null && mounted) {
      _visibleSearchKey = null;
      _pendingSearch = null;
      setState(() {});
    }
  }

  void _observeSubtitleService(Listenable subtitles) {
    if (identical(_observedSubtitleService, subtitles)) return;
    _observedSubtitleService?.removeListener(_handleSubtitlesChanged);
    _observedSubtitleService = subtitles;
    subtitles.addListener(_handleSubtitlesChanged);
  }

  _SearchKey get _searchKey => (
    widget.structureRevision,
    widget.detailRevision,
    widget.query,
    widget.filters,
  );
  final Set<String> _expandedSearchFolderPaths = <String>{};
  List<LibrarySearchRow> _visibleSearchItems = const [];
  List<LibrarySearchRow>? _offsetRows;
  int? _offsetColumnCount;
  List<double>? _rowOffsets;

  List<double> _offsetsFor(List<LibrarySearchRow> rows, int columnCount) {
    if (identical(rows, _offsetRows) && _offsetColumnCount == columnCount) {
      return _rowOffsets!;
    }
    _offsetRows = rows;
    _offsetColumnCount = columnCount;
    var offset = 0.0;
    final offsets = <double>[offset];
    if (columnCount <= 1) {
      for (final row in rows) {
        offset += libraryTileExtent(row.node);
        offsets.add(offset);
      }
      return _rowOffsets = offsets;
    }
    final rowCount = (rows.length / columnCount).ceil();
    for (var rowIndex = 0; rowIndex < rowCount; rowIndex++) {
      var rowExtent = 0.0;
      for (var column = 0; column < columnCount; column++) {
        final itemIndex = rowIndex * columnCount + column;
        if (itemIndex >= rows.length) break;
        final extent = libraryTileExtent(rows[itemIndex].node);
        if (extent > rowExtent) rowExtent = extent;
      }
      offset += rowExtent;
      offsets.add(offset);
    }
    return _rowOffsets = offsets;
  }

  @override
  void didUpdateWidget(covariant LibrarySearchAllResults oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query ||
        oldWidget.filters != widget.filters ||
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
    _observedSubtitleService?.removeListener(_handleSubtitlesChanged);
    _observedSubtitleService = null;
    _ownedSearchIndex?.dispose();
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
    final filters = widget.filters;
    final requestKey = _searchKey;
    if (_visibleSearchKey == requestKey) return;
    final queryRevision = widget.queryRevision;
    if (_pendingSearch?.key == requestKey) return;
    if (_visibleSearchErrorKey == requestKey) return;

    final token = Object();
    _pendingSearch = (key: requestKey, token: token);
    bool isCurrentRequest() =>
        mounted &&
        widget.queryRevision == queryRevision &&
        widget.filters == filters &&
        widget.structureRevision == structureRevision &&
        widget.detailRevision == detailRevision &&
        libraryFacade.structureRevision == structureRevision &&
        libraryFacade.detailCacheService.revision == detailRevision &&
        identical(_pendingSearch?.token, token);
    final searchFuture = () async {
      final cached = _searchIndex.cachedResult(
        query: query,
        structureRevision: structureRevision,
        detailRevision: detailRevision,
        filters: filters,
      );
      final hasSubtitle = filters.hasSubtitle;
      if (cached != null && hasSubtitle == null) return cached;
      final subtitles = hasSubtitle == null
          ? null
          : ref.read(playbackSubtitleServiceProvider);
      if (subtitles != null) {
        _observeSubtitleService(subtitles);
      }
      late final AudioLibraryCategorySnapshot effectiveCategorySnapshot;
      if (categorySnapshot != null) {
        effectiveCategorySnapshot = categorySnapshot;
      }
      late final List<LibraryNode> tree;
      await Future.wait<void>([
        if (categorySnapshot == null)
          libraryFacade
              .audioLibraryCategorySnapshot(isActive: isCurrentRequest)
              .then((snapshot) {
                effectiveCategorySnapshot = snapshot;
              }),
        if (cached == null)
          libraryFacade.loadLibraryTree().then((nodes) {
            tree = nodes;
          }),
      ], eagerError: true);
      if (!isCurrentRequest()) return null;
      var yielded = false;
      final FilteredLibraryTreeResult result;
      if (cached != null) {
        result = cached;
      } else if (libraryTreeTrackCount(tree) > 60) {
        yielded = true;
        result = await _searchIndex.searchInBackground(
          tree: tree,
          query: query,
          filters: filters,
          structureRevision: structureRevision,
          detailRevision: detailRevision,
          categorySnapshot: effectiveCategorySnapshot,
        );
      } else {
        result = _searchIndex.resolve(
          tree: tree,
          query: query,
          filters: filters,
          structureRevision: structureRevision,
          categorySnapshot: effectiveCategorySnapshot,
        );
      }
      if (!isCurrentRequest()) return null;
      if (cached == null) {
        _searchIndex.storeResult(
          query: query,
          structureRevision: structureRevision,
          detailRevision: detailRevision,
          filters: filters,
          result: result,
        );
      }
      if (subtitles != null && hasSubtitle != null) {
        if (!yielded) {
          await Future<void>.delayed(Duration.zero);
          if (!isCurrentRequest()) return null;
        }
        return result.filterSubtitles(
          snapshot: effectiveCategorySnapshot,
          hasSubtitle: hasSubtitle,
          isActive: isCurrentRequest,
          checkTrack: (path) =>
              subtitles.hasLocalSubtitleFile(path, includeImported: true),
          workSubtitleCache: _searchIndex.workSubtitleCacheForRevision(
            structureRevision,
          ),
          trackSubtitleCache: _searchIndex.trackSubtitleCacheForRevision(
            structureRevision,
          ),
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
                _visibleSearchKey = requestKey;
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
    if (widget.query.trim().isEmpty && widget.filters == emptySearchFilters) {
      return const SizedBox.shrink();
    }
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
    final hasCurrentError = _visibleSearchErrorKey == _searchKey;
    // Keep mounted rows while the next query is filtered; the first load still
    // uses a skeleton, and a failed new query keeps the existing error behavior.
    final result =
        hasCurrentError &&
            (_visibleSearchKey?.$3 != widget.query ||
                _visibleSearchKey?.$4 != widget.filters)
        ? null
        : _visibleSearchResult;
    final tree = result?.tree;
    if (tree != null) widget.onTreeChanged(tree);
    final hasActiveFilters = widget.filters != emptySearchFilters;
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
      final hasRecoveryActions =
          (hasActiveFilters && widget.onClearFilters != null) ||
          widget.onEditSearch != null;
      content = Center(
        child: Padding(
          padding: EdgeInsets.only(top: topPadding),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppEmptyState(
                key: const ValueKey<String>('library_search_empty'),
                icon: Icons.search_off_rounded,
                title: i18n.tr('no_search_results'),
                message: i18n.tr('search_try_another_term'),
              ),
              if (hasRecoveryActions) ...[
                const SizedBox(height: 16),
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    if (hasActiveFilters && widget.onClearFilters != null)
                      AppPrimaryButton(
                        key: const ValueKey<String>(
                          'library_search_clear_filters_button',
                        ),
                        onPressed: widget.onClearFilters,
                        label: i18n.tr('clear_filters'),
                      ),
                    if (widget.onEditSearch != null)
                      AppPillButton(
                        key: const ValueKey<String>(
                          'library_search_edit_search_button',
                        ),
                        onPressed: widget.onEditSearch,
                        style: FilledButton.styleFrom(
                          backgroundColor: Theme.of(
                            context,
                          ).colorScheme.secondaryContainer,
                          foregroundColor: Theme.of(
                            context,
                          ).colorScheme.onSecondaryContainer,
                        ),
                        child: Text(i18n.tr('edit_search')),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      );
    } else {
      final visibleItems = _visibleSearchItems;
      final errorItemCount = hasCurrentError ? 1 : 0;
      final canUseGrid =
          !hasCurrentError &&
          _expandedSearchFolderPaths.isEmpty &&
          visibleItems.every((item) => item.depth == 0);
      final fixedExtents =
          !hasCurrentError && libraryTileExtentsAreFixed(context);
      final highlightQuery = searchElementHighlight(
        _visibleSearchKey?.$3 ?? '',
      );
      Widget buildSearchItem(int itemIndex) {
        final item = visibleItems[itemIndex];
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
      }

      content = SearchHighlightScope(
        query: highlightQuery,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final columnCount = canUseGrid
                ? responsiveLibraryCardColumnCount(constraints.maxWidth)
                : 1;
            final offsets = fixedExtents
                ? _offsetsFor(visibleItems, columnCount)
                : null;
            final itemCount = columnCount == 1
                ? visibleItems.length + errorItemCount
                : (visibleItems.length / columnCount).ceil();
            return ScrollToTopListView.builder(
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
              itemCount: itemCount,
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
                if (columnCount == 1) {
                  return buildSearchItem(index - errorItemCount);
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var column = 0; column < columnCount; column++) ...[
                      if (column > 0)
                        const SizedBox(width: kResponsiveLibraryCardSpacing),
                      Expanded(
                        child: index * columnCount + column < visibleItems.length
                            ? buildSearchItem(index * columnCount + column)
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ],
                );
              },
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
