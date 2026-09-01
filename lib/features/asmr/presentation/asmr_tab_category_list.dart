part of 'asmr_tab.dart';

enum _AsmrVisibleItemKind { work, loading, error, empty, node }

class _AsmrVisibleItem {
  const _AsmrVisibleItem._({
    required this.kind,
    required this.work,
    this.node,
    this.depth = 0,
    this.error,
    this.revealed = true,
    this.animateInitialReveal = false,
  });

  const _AsmrVisibleItem.work(AsmrWork work)
    : this._(kind: _AsmrVisibleItemKind.work, work: work);

  final _AsmrVisibleItemKind kind;
  final AsmrWork work;
  final AsmrTrackFile? node;
  final int depth;
  final Object? error;
  final bool revealed;
  final bool animateInitialReveal;
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
    required this.isSelectionMode,
    required this.selectedWorkIds,
    required this.onEnterSelectionMode,
    required this.onToggleSelection,
  });

  final bool isActive;
  final AsmrCategoryType category;
  final bool isLoadPending;
  final ScrollController scrollController;
  final String searchQuery;
  final double topInset;
  final double bottomInset;
  final Future<void> Function() onRefresh;
  final bool isSelectionMode;
  final Set<int> selectedWorkIds;
  final ValueChanged<AsmrWork> onEnterSelectionMode;
  final ValueChanged<AsmrWork> onToggleSelection;

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
  final Map<String, bool> _treeExpansionMotions = <String, bool>{};
  final Map<String, Timer> _treeExpansionMotionTimers = <String, Timer>{};
  List<_AsmrVisibleItem> _visibleItems = const <_AsmrVisibleItem>[];
  List<AsmrWork>? _visibleItemsWorks;
  int? _visibleItemsCategoryRevision;
  int _visibleItemsExpansionVersion = 0;
  int _visibleItemsCacheExpansionVersion = -1;
  int _visibleItemsTreeFingerprint = 0;

  @override
  void didUpdateWidget(covariant _AsmrCategoryList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.isSelectionMode && widget.isSelectionMode) {
      _expandedWorkIds.clear();
      _expandedFolderPaths.clear();
      _treeExpansionMotions.clear();
      for (final timer in _treeExpansionMotionTimers.values) {
        timer.cancel();
      }
      _treeExpansionMotionTimers.clear();
      _visibleItemsExpansionVersion++;
    }
    if (oldWidget.category != widget.category ||
        normalizeSearchQuery(oldWidget.searchQuery) !=
            normalizeSearchQuery(widget.searchQuery)) {
      _expandedWorkIds.clear();
      _expandedFolderPaths.clear();
      _treeExpansionMotions.clear();
      for (final timer in _treeExpansionMotionTimers.values) {
        timer.cancel();
      }
      _treeExpansionMotionTimers.clear();
      _visibleItemsWorks = null;
      _visibleItemsExpansionVersion++;
    }
  }

  @override
  void dispose() {
    for (final timer in _treeExpansionMotionTimers.values) {
      timer.cancel();
    }
    super.dispose();
  }

  void _handleWorkExpansion(int workId, bool expanded) {
    final motionKey = 'work:$workId';
    final changed = expanded
        ? _expandedWorkIds.add(workId)
        : _expandedWorkIds.remove(workId);
    if (!changed) return;
    _startTreeExpansionMotion(motionKey, expanded);
  }

  void _handleFolderExpansion(int workId, String folderPath, bool expanded) {
    final motionKey = 'folder:$workId:$folderPath';
    final expandedPaths = _expandedFolderPaths.putIfAbsent(
      workId,
      () => <String>{},
    );
    final changed = expanded
        ? expandedPaths.add(folderPath)
        : expandedPaths.remove(folderPath);
    if (!changed) return;
    _startTreeExpansionMotion(motionKey, expanded);
  }

  void _startTreeExpansionMotion(String motionKey, bool expanded) {
    _treeExpansionMotionTimers.remove(motionKey)?.cancel();
    final animate = !MediaQuery.disableAnimationsOf(context);
    setState(() {
      if (animate) {
        _treeExpansionMotions[motionKey] = expanded;
      } else {
        _treeExpansionMotions.remove(motionKey);
      }
      _visibleItemsExpansionVersion++;
    });
    if (!animate) return;
    _treeExpansionMotionTimers[motionKey] = Timer(kAppMotionStandard, () {
      _treeExpansionMotionTimers.remove(motionKey);
      if (!mounted || _treeExpansionMotions[motionKey] != expanded) return;
      setState(() {
        _treeExpansionMotions.remove(motionKey);
        _visibleItemsExpansionVersion++;
      });
    });
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
    final closingWorkIds = works
        .where((work) => _treeExpansionMotions['work:${work.id}'] == false)
        .map((work) => work.id);
    for (final workId in <int>{..._expandedWorkIds, ...closingWorkIds}) {
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
                  physics: const NeverScrollableScrollPhysics(),
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
      final workExpanded = _expandedWorkIds.contains(work.id);
      final workMotion = _treeExpansionMotions['work:${work.id}'];
      if (!workExpanded && workMotion != false) continue;
      final animateWorkReveal = workExpanded && workMotion == true;
      final treeState = trackStates[work.id];
      final tree = treeState?.tree;
      final visibleTree = treeState?.visibleTree;
      if (treeState == null || (tree == null && treeState.isLoading)) {
        result.add(
          _AsmrVisibleItem._(
            kind: _AsmrVisibleItemKind.loading,
            work: work,
            revealed: workExpanded,
            animateInitialReveal: animateWorkReveal,
          ),
        );
        continue;
      }
      final error = treeState.operationError;
      if (tree == null && error != null) {
        result.add(
          _AsmrVisibleItem._(
            kind: _AsmrVisibleItemKind.error,
            work: work,
            error: error,
            revealed: workExpanded,
            animateInitialReveal: animateWorkReveal,
          ),
        );
        continue;
      }
      if (visibleTree == null || visibleTree.isEmpty) {
        result.add(
          _AsmrVisibleItem._(
            kind: _AsmrVisibleItemKind.empty,
            work: work,
            revealed: workExpanded,
            animateInitialReveal: animateWorkReveal,
          ),
        );
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

      void addNode(
        AsmrTrackFile node,
        int depth, {
        required bool revealed,
        required bool animateInitialReveal,
      }) {
        if (!node.hasBrowsableContent) return;
        result.add(
          _AsmrVisibleItem._(
            kind: _AsmrVisibleItemKind.node,
            work: work,
            node: node,
            depth: depth,
            revealed: revealed,
            animateInitialReveal: animateInitialReveal,
          ),
        );
        if (!node.isFolder) return;
        final expanded = expandedPaths.contains(node.relativePath);
        final motion =
            _treeExpansionMotions['folder:${work.id}:${node.relativePath}'];
        if (!expanded && motion != false) return;
        final revealChildren = revealed && expanded;
        final animateChildren =
            animateInitialReveal || (revealChildren && motion == true);
        for (final child in node.children) {
          addNode(
            child,
            depth + 1,
            revealed: revealChildren,
            animateInitialReveal: animateChildren,
          );
        }
      }

      for (final node in visibleTree) {
        addNode(
          node,
          1,
          revealed: workExpanded,
          animateInitialReveal: animateWorkReveal,
        );
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
    Widget animatedTreeItem(String key, Widget child) {
      return AnimatedTreeReveal(
        key: ValueKey<String>(key),
        visible: item.revealed,
        animateInitial: item.animateInitialReveal,
        child: child,
      );
    }

    switch (item.kind) {
      case _AsmrVisibleItemKind.work:
        return RepaintBoundary(
          key: ValueKey<String>('asmr-work-${item.work.id}'),
          child: _AsmrWorkTreeCard(
            work: item.work,
            searchQuery: widget.searchQuery,
            isActive: widget.isActive,
            expanded: _expandedWorkIds.contains(item.work.id),
            isSelectionMode: widget.isSelectionMode,
            isSelected: widget.selectedWorkIds.contains(item.work.id),
            onLongPress: () => widget.onEnterSelectionMode(item.work),
            onToggleSelect: () => widget.onToggleSelection(item.work),
            onExpansionChanged: (expanded) =>
                _handleWorkExpansion(item.work.id, expanded),
          ),
        );
      case _AsmrVisibleItemKind.node:
        final node = item.node!;
        final expanded =
            _expandedFolderPaths[item.work.id]?.contains(node.relativePath) ??
            false;
        return animatedTreeItem(
          'asmr-tree-${item.work.id}-${node.relativePath}',
          Padding(
            padding: EdgeInsets.only(left: item.depth * 8.0),
            child: RepaintBoundary(
              child: _AsmrTrackTreeNode(
                work: item.work,
                node: node,
                isActive: widget.isActive,
                expanded: expanded,
                onExpansionChanged: node.isFolder
                    ? (nextExpanded) => _handleFolderExpansion(
                        item.work.id,
                        node.relativePath,
                        nextExpanded,
                      )
                    : null,
              ),
            ),
          ),
        );
      case _AsmrVisibleItemKind.loading:
        return animatedTreeItem(
          'asmr-track-tree-loading-${item.work.id}',
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Center(child: CircularProgressIndicator(color: asmrBlue)),
          ),
        );
      case _AsmrVisibleItemKind.error:
        return animatedTreeItem(
          'asmr-track-tree-error-${item.work.id}',
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 12),
            child: OperationStatusBanner(
              label: i18n.tr('operation_failed_retry'),
              error: item.error,
              retryTooltip: i18n.tr('retry'),
              onRetry: () => unawaited(_retryTrackTree(item.work)),
            ),
          ),
        );
      case _AsmrVisibleItemKind.empty:
        return animatedTreeItem(
          'asmr-track-tree-empty-${item.work.id}',
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 12),
            child: Text(
              i18n.tr('asmr_empty_track_tree'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
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
