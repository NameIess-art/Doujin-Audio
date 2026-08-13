part of 'asmr_tab.dart';

enum _AsmrVisibleItemKind { work, loading, error, empty, node }

class _AsmrVisibleItem {
  const _AsmrVisibleItem._({
    required this.kind,
    required this.work,
    this.node,
    this.depth = 0,
    this.error,
  });

  const _AsmrVisibleItem.work(AsmrWork work)
    : this._(kind: _AsmrVisibleItemKind.work, work: work);

  const _AsmrVisibleItem.loading(AsmrWork work)
    : this._(kind: _AsmrVisibleItemKind.loading, work: work);

  const _AsmrVisibleItem.error(AsmrWork work, Object error)
    : this._(kind: _AsmrVisibleItemKind.error, work: work, error: error);

  const _AsmrVisibleItem.empty(AsmrWork work)
    : this._(kind: _AsmrVisibleItemKind.empty, work: work);

  const _AsmrVisibleItem.node(AsmrWork work, AsmrTrackFile node, int depth)
    : this._(
        kind: _AsmrVisibleItemKind.node,
        work: work,
        node: node,
        depth: depth,
      );

  final _AsmrVisibleItemKind kind;
  final AsmrWork work;
  final AsmrTrackFile? node;
  final int depth;
  final Object? error;
}

class _AsmrCategoryList extends ConsumerStatefulWidget {
  const _AsmrCategoryList({
    super.key,
    required this.isActive,
    required this.category,
    required this.isLoadPending,
    required this.scrollController,
    required this.searchQuery,
    required this.topInset,
    required this.bottomInset,
    required this.onRefresh,
  });

  final bool isActive;
  final AsmrCategoryType category;
  final bool isLoadPending;
  final ScrollController scrollController;
  final String searchQuery;
  final double topInset;
  final double bottomInset;
  final Future<void> Function() onRefresh;

  @override
  ConsumerState<_AsmrCategoryList> createState() => _AsmrCategoryListState();
}

class _AsmrCategoryListState extends ConsumerState<_AsmrCategoryList>
    with AutomaticKeepAliveClientMixin {
  final GlobalKey<GlassRefreshIndicatorState> _refreshIndicatorKey =
      GlobalKey<GlassRefreshIndicatorState>();
  bool _refreshTriggeredInCurrentScroll = false;
  bool _loadMoreTriggeredInCurrentScroll = false;
  bool _automaticLoadMoreScheduled = false;
  final Set<int> _expandedWorkIds = <int>{};
  final Map<int, Set<String>> _expandedFolderPaths = <int, Set<String>>{};
  List<_AsmrVisibleItem> _visibleItems = const <_AsmrVisibleItem>[];
  List<AsmrWork>? _visibleItemsWorks;
  int? _visibleItemsCategoryRevision;
  int _visibleItemsExpansionVersion = 0;
  int _visibleItemsCacheExpansionVersion = -1;
  int _visibleItemsTreeFingerprint = 0;

  @override
  void didUpdateWidget(covariant _AsmrCategoryList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.category != widget.category ||
        normalizeSearchQuery(oldWidget.searchQuery) !=
            normalizeSearchQuery(widget.searchQuery)) {
      _expandedWorkIds.clear();
      _expandedFolderPaths.clear();
      _visibleItemsWorks = null;
      _visibleItemsExpansionVersion++;
    }
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final normalizedSearchQuery = normalizeSearchQuery(widget.searchQuery);
    final categoryProvider = asmrCategoryStateProvider((
      category: widget.category,
      searchQuery: normalizedSearchQuery,
    ));
    final providerState =
        (widget.isActive
                ? ref.watch(categoryProvider)
                : ref.read(categoryProvider))
            .value;
    final state =
        ref
            .read(asmrLibraryControllerProvider)
            ?.categoryViewState(
              widget.category,
              searchQuery: normalizedSearchQuery,
            ) ??
        providerState ??
        AsmrCategoryViewState(
          category: widget.category,
          works: const <AsmrWork>[],
          isLoading: false,
          isLoadingMore: false,
          isRefreshing: false,
          isStale: false,
          hasAttemptedLoad: false,
          hasMore: false,
          needsLoadMoreRetry: false,
          totalCount: 0,
          activeQuery: widget.searchQuery,
          lastError: null,
          operationError: null,
          revision: 0,
        );
    final works = state.works;
    final trackStates = <int, AsmrTrackTreeViewState>{};
    for (final workId in _expandedWorkIds) {
      final provider = asmrTrackTreeStateProvider(workId);
      final controllerState = ref
          .read(asmrLibraryControllerProvider)
          ?.trackTreeViewState(workId);
      final trackState =
          (widget.isActive ? ref.watch(provider) : ref.read(provider)).value ??
          controllerState;
      if (trackState != null) trackStates[workId] = trackState;
    }
    final visibleItems = _buildVisibleItems(
      works: works,
      categoryRevision: state.revision,
      trackStates: trackStates,
    );
    final showPlaceholder =
        (widget.isLoadPending && normalizedSearchQuery.isNotEmpty) ||
        (works.isEmpty &&
            (widget.isLoadPending ||
                state.isLoading ||
                !state.hasAttemptedLoad));
    if (widget.isActive) {
      ref.watch(appLanguageStateProvider);
    } else {
      ref.read(appLanguageStateProvider);
    }
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final theme = Theme.of(context);
    final asmrBlue = AppDesignTokens.of(context).asmrAccent;
    return Theme(
      data: theme.copyWith(
        scrollbarTheme: theme.scrollbarTheme.copyWith(
          thumbColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.dragged)) {
              return asmrBlue;
            }
            if (states.contains(WidgetState.hovered)) {
              return asmrBlue.withValues(alpha: 0.7);
            }
            return theme.colorScheme.outlineVariant.withValues(alpha: 0.5);
          }),
        ),
      ),
      child: ScrollActivityGate(
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(
            padding: EdgeInsets.only(
              top: widget.topInset,
              bottom: widget.bottomInset,
              right: 4,
            ),
          ),
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification is ScrollUpdateNotification) {
                if (notification.dragDetails != null &&
                    notification.metrics.pixels < -68 &&
                    !_refreshTriggeredInCurrentScroll) {
                  _refreshTriggeredInCurrentScroll = true;
                  unawaited(
                    AppInteractionFeedback.trigger(
                      AppInteractionFeedbackType.confirmation,
                    ),
                  );
                  _refreshIndicatorKey.currentState?.show();
                }
                final nearBottom =
                    notification.metrics.extentAfter <=
                    notification.metrics.viewportDimension;
                final isManualUpwardDrag =
                    notification.dragDetails != null &&
                    (notification.scrollDelta ?? 0) > 0;
                if (nearBottom &&
                    (!state.needsLoadMoreRetry || isManualUpwardDrag)) {
                  _loadMoreOncePerScroll(state);
                }
              } else if (notification is OverscrollNotification) {
                final isManualBottomOverscroll =
                    notification.dragDetails != null &&
                    notification.overscroll > 0;
                if (state.needsLoadMoreRetry && isManualBottomOverscroll) {
                  _loadMoreOncePerScroll(state);
                }
              } else if (notification is ScrollEndNotification) {
                _refreshTriggeredInCurrentScroll = false;
                _loadMoreTriggeredInCurrentScroll = false;
              }
              return false;
            },
            child: GlassRefreshIndicator(
              key: _refreshIndicatorKey,
              color: asmrBlue,
              backgroundColor: Theme.of(
                context,
              ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
              edgeOffset: widget.topInset,
              displacement: 32,
              triggerMode: GlassRefreshIndicatorTriggerMode.anywhere,
              onRefresh: widget.onRefresh,
              child: PlaceholderContentTransition(
                showPlaceholder: showPlaceholder,
                placeholder: ListView.builder(
                  key: const ValueKey('loading'),
                  physics: const AlwaysScrollableScrollPhysics(
                    parent: RefreshTopScrollPhysics(),
                  ),
                  padding: EdgeInsets.fromLTRB(
                    LibraryLikeCardMetrics.listHorizontalPadding,
                    widget.topInset,
                    LibraryLikeCardMetrics.listHorizontalPadding,
                    widget.bottomInset + 24,
                  ),
                  itemCount: 1,
                  itemBuilder: (context, index) {
                    return Column(
                      children: [
                        for (int i = 0; i < 5; i++)
                          const LibraryLikeSkeletonCard(),
                      ],
                    );
                  },
                ),
                content: ListView.builder(
                  key: const ValueKey('content'),
                  controller: widget.scrollController,
                  cacheExtent: 520,
                  physics: const AlwaysScrollableScrollPhysics(
                    parent: RefreshTopScrollPhysics(),
                  ),
                  padding: EdgeInsets.fromLTRB(
                    LibraryLikeCardMetrics.listHorizontalPadding,
                    widget.topInset,
                    LibraryLikeCardMetrics.listHorizontalPadding,
                    widget.bottomInset + 24,
                  ),
                  itemCount: works.isEmpty
                      ? 1
                      : visibleItems.length +
                            ((state.isLoadingMore || state.hasMore) ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (works.isEmpty) {
                      final errorText = state.lastError == null
                          ? null
                          : localizedAsmrCatalogErrorText(
                              i18n,
                              state.lastError,
                            );
                      return Padding(
                        padding: const EdgeInsets.only(top: 80),
                        child: AppEmptyView(
                          icon: state.lastError != null
                              ? Icons.error_outline_rounded
                              : Icons.search_off_rounded,
                          title: state.lastError != null
                              ? i18n.tr('error')
                              : i18n.tr('asmr_empty_category'),
                          subtitle: errorText,
                        ),
                      );
                    }
                    if (index >= visibleItems.length) {
                      if (!state.needsLoadMoreRetry) {
                        _scheduleAutomaticLoadMore(state);
                      }
                      return Padding(
                        padding: const EdgeInsets.only(top: 4, bottom: 4),
                        child: Center(
                          child: state.needsLoadMoreRetry
                              ? Text(
                                  i18n.tr('asmr_load_more_hint'),
                                  key: const ValueKey<String>(
                                    'asmr_load_more_retry_hint',
                                  ),
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                    fontWeight: FontWeight.w600,
                                  ),
                                )
                              : SizedBox(
                                  key: const ValueKey<String>(
                                    'asmr_load_more_progress',
                                  ),
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.2,
                                    color: asmrBlue,
                                  ),
                                ),
                        ),
                      );
                    }
                    return _buildVisibleItem(
                      context,
                      visibleItems[index],
                      i18n: i18n,
                      asmrBlue: asmrBlue,
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<_AsmrVisibleItem> _buildVisibleItems({
    required List<AsmrWork> works,
    required int categoryRevision,
    required Map<int, AsmrTrackTreeViewState> trackStates,
  }) {
    final currentWorkIds = works.map((work) => work.id).toSet();
    final previousExpandedWorkCount = _expandedWorkIds.length;
    _expandedWorkIds.removeWhere((workId) => !currentWorkIds.contains(workId));
    _expandedFolderPaths.removeWhere(
      (workId, _) => !currentWorkIds.contains(workId),
    );
    if (_expandedWorkIds.length != previousExpandedWorkCount) {
      _visibleItemsExpansionVersion++;
    }

    var treeFingerprint = 0;
    for (final entry in trackStates.entries) {
      treeFingerprint = Object.hash(
        treeFingerprint,
        entry.key,
        entry.value.revision,
        identityHashCode(entry.value.tree),
        entry.value.isLoading,
        entry.value.operationError,
      );
    }
    if (identical(_visibleItemsWorks, works) &&
        _visibleItemsCategoryRevision == categoryRevision &&
        _visibleItemsCacheExpansionVersion == _visibleItemsExpansionVersion &&
        _visibleItemsTreeFingerprint == treeFingerprint) {
      return _visibleItems;
    }

    final result = <_AsmrVisibleItem>[];
    for (final work in works) {
      result.add(_AsmrVisibleItem.work(work));
      if (!_expandedWorkIds.contains(work.id)) continue;
      final treeState = trackStates[work.id];
      final tree = treeState?.tree;
      final visibleTree = treeState?.visibleTree;
      if (treeState == null || (tree == null && treeState.isLoading)) {
        result.add(_AsmrVisibleItem.loading(work));
        continue;
      }
      final error = treeState.operationError;
      if (tree == null && error != null) {
        result.add(_AsmrVisibleItem.error(work, error));
        continue;
      }
      if (visibleTree == null || visibleTree.isEmpty) {
        result.add(_AsmrVisibleItem.empty(work));
        continue;
      }

      final expandedPaths = _expandedFolderPaths.putIfAbsent(
        work.id,
        () => <String>{},
      );
      final validFolderPaths = <String>{};
      void collectFolderPaths(Iterable<AsmrTrackFile> nodes) {
        for (final node in nodes) {
          if (!node.isFolder || !node.hasBrowsableContent) continue;
          validFolderPaths.add(node.relativePath);
          collectFolderPaths(node.children);
        }
      }

      collectFolderPaths(visibleTree);
      expandedPaths.retainAll(validFolderPaths);

      void addNode(AsmrTrackFile node, int depth) {
        if (!node.hasBrowsableContent) return;
        result.add(_AsmrVisibleItem.node(work, node, depth));
        if (!node.isFolder || !expandedPaths.contains(node.relativePath)) {
          return;
        }
        for (final child in node.children) {
          addNode(child, depth + 1);
        }
      }

      for (final node in visibleTree) {
        addNode(node, 1);
      }
    }
    _visibleItemsWorks = works;
    _visibleItemsCategoryRevision = categoryRevision;
    _visibleItemsCacheExpansionVersion = _visibleItemsExpansionVersion;
    _visibleItemsTreeFingerprint = treeFingerprint;
    return _visibleItems = result;
  }

  Widget _buildVisibleItem(
    BuildContext context,
    _AsmrVisibleItem item, {
    required AppLanguageProvider i18n,
    required Color asmrBlue,
  }) {
    switch (item.kind) {
      case _AsmrVisibleItemKind.work:
        return RepaintBoundary(
          key: ValueKey<String>('asmr-work-${item.work.id}'),
          child: _AsmrWorkTreeCard(
            work: item.work,
            searchQuery: widget.searchQuery,
            isActive: widget.isActive,
            expanded: _expandedWorkIds.contains(item.work.id),
            onExpansionChanged: (expanded) {
              final changed = expanded
                  ? _expandedWorkIds.add(item.work.id)
                  : _expandedWorkIds.remove(item.work.id);
              if (!changed) return;
              setState(() => _visibleItemsExpansionVersion++);
            },
          ),
        );
      case _AsmrVisibleItemKind.node:
        final node = item.node!;
        final expanded =
            _expandedFolderPaths[item.work.id]?.contains(node.relativePath) ??
            false;
        return Padding(
          key: ValueKey<String>(
            'asmr-tree-${item.work.id}-${node.relativePath}',
          ),
          padding: EdgeInsets.only(left: item.depth * 8.0),
          child: RepaintBoundary(
            child: _AsmrTrackTreeNode(
              work: item.work,
              node: node,
              isActive: widget.isActive,
              expanded: expanded,
              onExpansionChanged: node.isFolder
                  ? (nextExpanded) {
                      final paths = _expandedFolderPaths.putIfAbsent(
                        item.work.id,
                        () => <String>{},
                      );
                      final changed = nextExpanded
                          ? paths.add(node.relativePath)
                          : paths.remove(node.relativePath);
                      if (!changed) return;
                      setState(() => _visibleItemsExpansionVersion++);
                    }
                  : null,
            ),
          ),
        );
      case _AsmrVisibleItemKind.loading:
        return Padding(
          key: ValueKey<String>('asmr-track-tree-loading-${item.work.id}'),
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Center(child: CircularProgressIndicator(color: asmrBlue)),
        );
      case _AsmrVisibleItemKind.error:
        return Padding(
          key: ValueKey<String>('asmr-track-tree-error-${item.work.id}'),
          padding: const EdgeInsets.only(top: 4, bottom: 12),
          child: OperationStatusBanner(
            label: i18n.tr('operation_failed_retry'),
            error: item.error,
            retryTooltip: i18n.tr('retry'),
            onRetry: () => unawaited(_retryTrackTree(item.work)),
          ),
        );
      case _AsmrVisibleItemKind.empty:
        return Padding(
          key: ValueKey<String>('asmr-track-tree-empty-${item.work.id}'),
          padding: const EdgeInsets.only(top: 4, bottom: 12),
          child: Text(
            i18n.tr('asmr_empty_track_tree'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        );
    }
  }

  Future<void> _retryTrackTree(AsmrWork work) async {
    final controller = ref.read(asmrLibraryControllerProvider);
    if (controller == null) return;
    try {
      await ref
          .read(uiOperationServiceProvider)
          .run<List<AsmrTrackFile>>(
            scope: UiOperationScope.asmrWork(
              AsmrOperationKind.trackTree,
              work.id,
            ),
            labelKey: 'loading_dot',
            task: (_) => controller.ensureTrackTree(work),
          );
    } catch (_) {
      // The controller owns the stable error state used by the retry row.
    }
  }

  void _loadMoreOncePerScroll(AsmrCategoryViewState state) {
    if (_loadMoreTriggeredInCurrentScroll ||
        state.isLoadingMore ||
        !state.hasMore) {
      return;
    }
    _loadMoreTriggeredInCurrentScroll = true;
    unawaited(_loadMore());
  }

  void _scheduleAutomaticLoadMore(AsmrCategoryViewState state) {
    if (_automaticLoadMoreScheduled ||
        !widget.isActive ||
        state.isLoadingMore ||
        !state.hasMore ||
        state.needsLoadMoreRetry) {
      return;
    }
    _automaticLoadMoreScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _automaticLoadMoreScheduled = false;
      if (!mounted || !widget.isActive) return;
      final currentState = ref
          .read(asmrLibraryControllerProvider)
          ?.categoryViewState(
            widget.category,
            searchQuery: normalizeSearchQuery(widget.searchQuery),
          );
      if (currentState == null ||
          currentState.isLoadingMore ||
          !currentState.hasMore ||
          currentState.needsLoadMoreRetry) {
        return;
      }
      if (!widget.scrollController.hasClients) return;
      final position = widget.scrollController.position;
      if (position.extentAfter > position.viewportDimension) return;
      unawaited(_loadMore());
    });
  }

  Future<void> _loadMore() async {
    await ref
        .read(asmrLibraryControllerProvider)
        ?.loadMoreCategory(widget.category, searchQuery: widget.searchQuery);
  }
}
