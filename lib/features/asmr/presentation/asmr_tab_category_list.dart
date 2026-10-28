part of 'asmr_tab.dart';

class _CollapsingAsmrWork {
  _CollapsingAsmrWork({
    required this.work,
    required this.originalIndex,
    required TickerProvider vsync,
    required VoidCallback onComplete,
  }) {
    controller = AnimationController(
      vsync: vsync,
      duration: kAppFadeDuration,
      value: 1.0,
    );
    animation = CurvedAnimation(parent: controller, curve: kAppFadeCurve);
    controller.reverse().then((_) {
      onComplete();
    });
  }

  final AsmrWork work;
  final int originalIndex;
  late final AnimationController controller;
  late final Animation<double> animation;

  void dispose() {
    controller.dispose();
  }
}

class _AsmrWorkRowsDelegate extends SliverChildBuilderDelegate {
  _AsmrWorkRowsDelegate(
    super.builder, {
    required this.works,
    required this.columnCount,
    required this.searchQuery,
    required this.searchSession,
    required this.isSelectionMode,
    required Set<String> selectedWorkIds,
    required Map<String, Animation<double>> loadingAnimations,
    required this.collapsingWorks,
    super.childCount,
    super.findChildIndexCallback,
  }) : selectedWorkIds = Set.of(selectedWorkIds),
       loadingAnimations = Map.of(loadingAnimations),
       // Each card already isolates its paint, including cards sharing a row.
       super(addRepaintBoundaries: false);

  final List<AsmrWork> works;
  final int columnCount;
  final String searchQuery;
  final bool searchSession;
  final bool isSelectionMode;
  final Set<String> selectedWorkIds;
  final Map<String, Animation<double>> loadingAnimations;
  final Map<String, _CollapsingAsmrWork> collapsingWorks;

  @override
  bool shouldRebuild(covariant _AsmrWorkRowsDelegate oldDelegate) {
    // Paging progress and retry/footer updates do not change the row content.
    // Let mounted cards keep their layout and decoded covers for those commits.
    return !identical(works, oldDelegate.works) ||
        columnCount != oldDelegate.columnCount ||
        searchQuery != oldDelegate.searchQuery ||
        searchSession != oldDelegate.searchSession ||
        isSelectionMode != oldDelegate.isSelectionMode ||
        !setEquals(selectedWorkIds, oldDelegate.selectedWorkIds) ||
        !mapEquals(loadingAnimations, oldDelegate.loadingAnimations) ||
        !identical(collapsingWorks, oldDelegate.collapsingWorks);
  }
}

class _AsmrCategoryList extends ConsumerStatefulWidget {
  const _AsmrCategoryList({
    super.key,
    required this.isActive,
    this.isPageActive,
    required this.category,
    required this.isLoadPending,
    required this.scrollController,
    required this.searchQuery,
    this.searchSession = false,
    required this.topInset,
    required this.bottomInset,
    required this.onRefresh,
    required this.isSelectionMode,
    required this.selectedWorkIds,
    required this.onEnterSelectionMode,
    required this.onToggleSelection,
  });

  final bool Function() isActive;
  final bool Function()? isPageActive;
  final AsmrCategoryType category;
  final bool isLoadPending;
  final ScrollController scrollController;
  final String searchQuery;
  final bool searchSession;
  final double topInset;
  final double bottomInset;
  final Future<void> Function() onRefresh;
  final bool isSelectionMode;
  final Set<String> selectedWorkIds;
  final ValueChanged<AsmrWork> onEnterSelectionMode;
  final ValueChanged<AsmrWork> onToggleSelection;

  @override
  ConsumerState<_AsmrCategoryList> createState() => _AsmrCategoryListState();
}

class _AsmrCategoryListState extends ConsumerState<_AsmrCategoryList>
    with TickerProviderStateMixin {
  final GlobalKey<GlassRefreshIndicatorState> _refreshIndicatorKey =
      GlobalKey();
  bool _loadMoreTriggeredInCurrentScroll = false;
  bool _automaticLoadMoreScheduled = false;
  ValueListenable<TickerModeData>? _tickerModeNotifier;
  AsmrCategoryStateRequest? _lastPresentedRequest;
  AsmrLibraryController? _lastPresentedController;
  AsmrCategoryViewState? _lastPresentedState;
  late final String _automaticLoadMoreCommitKey =
      'asmr_load_more_${identityHashCode(this)}';
  final Map<String, _CollapsingAsmrWork> _collapsingWorks =
      <String, _CollapsingAsmrWork>{};
  List<AsmrWork>? _lastFavoritesWorks;
  String? _lastFavoritesQuery;
  int? _lastFavoritesRevision;
  AsmrCategoryViewState? _lastLoadState;
  final Map<String, Animation<double>> _loadingWorkAnimations = {};
  final Set<AnimationController> _loadingBatchControllers = {};
  final Map<String, GlobalKey> _itemKeys = {};
  List<AsmrWork>? _visibleWorksSource;
  List<AsmrWork> _visibleWorksCache = const [];
  Map<String, _CollapsingAsmrWork> _visibleCollapsing = const {};
  List<String> _anchorIds = const [];
  Map<String, int> _workIndexById = {};
  Map<Key, int> _workKeyIndices = {};

  List<AsmrWork> _prepareVisibleWorks(List<AsmrWork> works) {
    if (identical(_visibleWorksSource, works) &&
        _visibleCollapsing.length == _collapsingWorks.length &&
        _collapsingWorks.entries.every(
          (entry) => identical(_visibleCollapsing[entry.key], entry.value),
        )) {
      return _visibleWorksCache;
    }
    final visible = _collapsingWorks.isEmpty ? works : <AsmrWork>[...works];
    if (_collapsingWorks.isNotEmpty) {
      final collapsing = _collapsingWorks.values.toList()
        ..sort((a, b) => a.originalIndex.compareTo(b.originalIndex));
      for (final entry in collapsing) {
        visible.insert(
          entry.originalIndex.clamp(0, visible.length),
          entry.work,
        );
      }
    }
    _visibleWorksSource = works;
    _visibleCollapsing = Map.of(_collapsingWorks);
    _visibleWorksCache = visible;
    _workIndexById = {};
    _workKeyIndices = {};
    final anchors = <String>[];
    for (var index = 0; index < visible.length; index++) {
      final id = visible[index].workKey;
      _workIndexById[id] = index;
      anchors.add(id);
      final key = _itemKeys[id];
      if (key != null) _workKeyIndices[key] = index;
    }
    _itemKeys.removeWhere((id, _) => !_workIndexById.containsKey(id));
    _anchorIds = immutableList(anchors);
    return visible;
  }

  bool get _isActive =>
      widget.isActive() &&
      (widget.isPageActive?.call() ?? true) &&
      (_tickerModeNotifier?.value.enabled ?? true) &&
      _route?.isCurrent != false;

  ModalRoute<dynamic>? _route;

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
    if (!_isActive) {
      UiInteractionCoordinator.instance.cancelCommit(
        _automaticLoadMoreCommitKey,
      );
      _automaticLoadMoreScheduled = false;
      _loadMoreTriggeredInCurrentScroll = false;
      // Retained cards still reference these animations. TickerMode pauses them
      // while the next data commit establishes a fresh pagination baseline.
      _lastLoadState = null;
      return;
    }
    final state = _lastPresentedState;
    if (state != null) _scheduleAutomaticLoadMore(state);
  }

  @override
  void didUpdateWidget(covariant _AsmrCategoryList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.category != widget.category ||
        oldWidget.searchSession != widget.searchSession ||
        canonicalSearchQuery(oldWidget.searchQuery) !=
            canonicalSearchQuery(widget.searchQuery)) {
      for (final entry in _collapsingWorks.values) {
        entry.dispose();
      }
      _collapsingWorks.clear();
      _lastFavoritesWorks = null;
      _lastFavoritesQuery = null;
      _lastFavoritesRevision = null;
      _clearLoadAnimations();
      _lastLoadState = null;
    }
    _handleActivityChanged();
  }

  @override
  void dispose() {
    _tickerModeNotifier?.removeListener(_handleActivityChanged);
    UiInteractionCoordinator.instance.cancelCommit(_automaticLoadMoreCommitKey);
    for (final entry in _collapsingWorks.values) {
      entry.dispose();
    }
    _collapsingWorks.clear();
    _clearLoadAnimations();
    super.dispose();
  }

  void _clearLoadAnimations() {
    for (final controller in _loadingBatchControllers) {
      controller.dispose();
    }
    _loadingBatchControllers.clear();
    _loadingWorkAnimations.clear();
  }

  void _updateLoadAnimations(
    AsmrCategoryViewState state,
    List<AsmrWork> works, {
    required bool reduceMotion,
  }) {
    if (!_isActive) {
      _lastLoadState = null;
      return;
    }
    final previous = _lastLoadState;
    _lastLoadState = state;
    if (reduceMotion || state.isLoading || state.isRefreshing) {
      _clearLoadAnimations();
      return;
    }
    if (previous == null ||
        previous.works.isEmpty ||
        !previous.hasMore ||
        previous.isLoading ||
        previous.isRefreshing ||
        works.length <= previous.works.length) {
      return;
    }
    for (var i = 0; i < previous.works.length; i++) {
      if (previous.works[i].workKey != works[i].workKey) return;
    }
    // Start once when a page enters the rendered data, including offscreen
    // records. Lazy card creation then observes the batch's current opacity.
    final controller = AnimationController(
      vsync: this,
      duration: kAppFadeDuration,
    );
    final animation = controller.drive(CurveTween(curve: kAppFadeCurve));
    _loadingBatchControllers.add(controller);
    for (final work in works.skip(previous.works.length)) {
      _loadingWorkAnimations[work.workKey] = animation;
    }
    controller.forward().then((_) {
      if (!mounted) return;
      setState(() {
        _loadingWorkAnimations.removeWhere((_, value) => value == animation);
        _loadingBatchControllers.remove(controller);
      });
      controller.dispose();
    });
  }

  @override
  Widget build(BuildContext context) {
    final normalizedSearchQuery = canonicalSearchQuery(widget.searchQuery);
    final request = (
      category: widget.category,
      searchQuery: normalizedSearchQuery,
      searchSession: widget.searchSession && normalizedSearchQuery.isNotEmpty,
    );
    final categoryProvider = asmrCategoryStateProvider(request);
    final snapshot = ref.watch(categoryProvider);
    final controller = ref.read(asmrLibraryControllerProvider);
    if (_lastPresentedRequest != request ||
        !identical(_lastPresentedController, controller)) {
      _lastPresentedRequest = request;
      _lastPresentedController = controller;
      _lastPresentedState = null;
    }
    // A deferred projection must not replace the last published cards with a
    // placeholder while the page's subscriptions resume.
    if (!snapshot.isLoading && snapshot.value != null) {
      _lastPresentedState = snapshot.value;
    }
    if (_lastPresentedState == null &&
        normalizedSearchQuery.isEmpty &&
        !widget.searchSession &&
        controller?.hasLoadedCategory(widget.category) == true) {
      _lastPresentedState = controller!.categoryViewState(widget.category);
    }
    final state =
        _lastPresentedState ??
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
    final queryMismatch =
        widget.category != AsmrCategoryType.favorites &&
        widget.category != AsmrCategoryType.history &&
        canonicalSearchQuery(state.activeQuery) != normalizedSearchQuery;
    final works = queryMismatch ? const <AsmrWork>[] : state.works;
    final isFavorites = widget.category == AsmrCategoryType.favorites;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (snapshot.isLoading) {
      // Retained cards are not a new data commit. After reactivation, establish
      // the new provider baseline before animating subsequent appended pages.
      _clearLoadAnimations();
      _lastLoadState = null;
    } else {
      _updateLoadAnimations(state, works, reduceMotion: reduceMotion);
    }

    if (isFavorites) {
      if (_lastFavoritesRevision != state.revision &&
          _lastFavoritesQuery == normalizedSearchQuery &&
          _lastFavoritesWorks != null &&
          !state.isLoading &&
          !state.isRefreshing &&
          !reduceMotion) {
        final currentWorkIds = <String>{for (final w in works) w.workKey};
        _collapsingWorks.removeWhere((id, entry) {
          if (currentWorkIds.contains(id)) {
            entry.dispose();
            return true;
          }
          return false;
        });
        var skippedRemovals = 0;
        for (var i = 0; i < _lastFavoritesWorks!.length; i++) {
          final previousWork = _lastFavoritesWorks![i];
          if (currentWorkIds.contains(previousWork.workKey) ||
              _collapsingWorks.containsKey(previousWork.workKey)) {
            continue;
          }
          // Zero-height retiring rows make a lazy list build further rows to
          // fill its viewport. Retaining offscreen removals would build the
          // entire old collection on the final animation frame.
          if (_itemKeys[previousWork.workKey]?.currentContext == null) {
            skippedRemovals++;
            continue;
          }
          final workId = previousWork.workKey;
          _collapsingWorks[workId] = _CollapsingAsmrWork(
            work: previousWork,
            originalIndex: i - skippedRemovals,
            vsync: this,
            onComplete: () {
              if (!mounted) return;
              setState(() {
                final entry = _collapsingWorks.remove(workId);
                entry?.dispose();
              });
            },
          );
        }
      }
      _lastFavoritesWorks = works;
      _lastFavoritesQuery = normalizedSearchQuery;
      _lastFavoritesRevision = state.revision;
    }

    final visibleWorks = _prepareVisibleWorks(works);
    // Outgoing placeholder transitions can still build the previous list.
    // Keep each delegate's indices with the projection it renders.
    final workIndexById = _workIndexById;
    final workKeyIndices = _workKeyIndices;

    Widget buildWorkCard(AsmrWork work) {
      final card = _AsmrWorkTreeCard(
        work: work,
        searchQuery: widget.searchQuery,
        isSelectionMode: widget.isSelectionMode,
        isSelected: widget.selectedWorkIds.contains(work.workKey),
        onLongPress: () => widget.onEnterSelectionMode(work),
        onToggleSelect: () => widget.onToggleSelection(work),
      );
      Widget workCard = FadeTransition(
        key: ValueKey<String>('asmr-work-${work.workKey}'),
        opacity:
            _loadingWorkAnimations[work.workKey] ??
            const AlwaysStoppedAnimation<double>(1),
        child: RepaintBoundary(
          child: widget.searchSession
              ? card
              : BrowseAnchor(id: work.workKey, child: card),
        ),
      );
      final collapsing = _collapsingWorks[work.workKey];
      if (collapsing != null) {
        workCard = AnimatedBuilder(
          animation: collapsing.controller,
          builder: (context, child) {
            return SizeTransition(
              sizeFactor: collapsing.animation,
              axisAlignment: -1.0,
              child: FadeTransition(
                opacity: collapsing.animation,
                child: IgnorePointer(child: ExcludeSemantics(child: child)),
              ),
            );
          },
          child: workCard,
        );
      }
      // Rows regroup on resize; retain the complete card, including its
      // removal host and decoded cover, when it moves to another row.
      final key = _itemKeys.putIfAbsent(work.workKey, GlobalKey.new);
      workKeyIndices[key] = workIndexById[work.workKey]!;
      return KeyedSubtree(key: key, child: workCard);
    }

    final showPlaceholder =
        (queryMismatch && state.operationError == null) ||
        (widget.isLoadPending && normalizedSearchQuery.isNotEmpty) ||
        (visibleWorks.isEmpty &&
            (widget.isLoadPending ||
                state.isLoading ||
                !state.hasAttemptedLoad));
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final theme = Theme.of(context);
    final primaryColor = Theme.of(context).colorScheme.primary;
    double? listWidth;
    Widget? workList;
    final content = ScrollActivityGate(
      onMetricsChanged: ref
          .read(libraryCoverUiControllerProvider)
          .viewportChanged,
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
              _loadMoreTriggeredInCurrentScroll = false;
            }
            return false;
          },
          child: GlassRefreshIndicator(
            key: _refreshIndicatorKey,
            lockChildWhileRefreshing: true,
            color: primaryColor,
            backgroundColor: Theme.of(
              context,
            ).colorScheme.surfaceContainerHighest,
            edgeOffset: widget.topInset,
            displacement: 32,
            triggerMode: GlassRefreshIndicatorTriggerMode.anywhere,
            onRefresh: widget.onRefresh,
            child: PlaceholderContentTransition(
              showPlaceholder: showPlaceholder,
              placeholder: LibrarySkeletonListView(
                key: const ValueKey('loading'),
                topInset: widget.topInset,
                bottomInset: widget.bottomInset + 24,
              ),
              content: LayoutBuilder(
                builder: (context, constraints) {
                  // Keyboard height changes only resize the viewport. New
                  // data or a width change still rebuilds the row delegates.
                  if (listWidth == constraints.maxWidth && workList != null) {
                    return workList!;
                  }
                  listWidth = constraints.maxWidth;
                  final columnCount = responsiveLibraryCardColumnCount(
                    constraints.maxWidth,
                  );
                  if (!widget.searchSession) {
                    BrowsePageScroll.setAnchorIds(
                      context,
                      _anchorIds,
                      columnCount: _collapsingWorks.isEmpty
                          ? columnCount
                          : null,
                      rowExtent: LibraryLikeCardMetrics.rootTileHeight,
                      topPadding: widget.topInset,
                    );
                  }
                  final rowCount = (visibleWorks.length / columnCount).ceil();
                  final hasLoadMore = state.isLoadingMore || state.hasMore;
                  Widget buildFooter(BuildContext context) {
                    final partialError =
                        state.operationError ?? state.lastError;
                    if (visibleWorks.isNotEmpty &&
                        partialError is AsmrPartialCatalogException) {
                      return Padding(
                        key: const ValueKey<String>('asmr_load_more_footer'),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: OperationStatusBanner(
                          key: const ValueKey<String>(
                            'online_library_partial_failure',
                          ),
                          label: localizedAsmrCatalogErrorText(
                            i18n,
                            partialError,
                          ),
                          error: partialError,
                          icon: Icons.cloud_off_rounded,
                          tone: OperationStatusTone.warning,
                          retryTooltip: i18n.tr('retry'),
                          onRetry: () => unawaited(widget.onRefresh()),
                        ),
                      );
                    }
                    return AnimatedSwitcher(
                      key: const ValueKey<String>('asmr_load_more_footer'),
                      duration: reduceMotion ? Duration.zero : kAppFadeDuration,
                      switchInCurve: kAppFadeCurve,
                      switchOutCurve: kAppFadeCurve,
                      child: visibleWorks.isEmpty
                          ? Padding(
                              key: ValueKey(('asmr_empty', state.lastError)),
                              padding: const EdgeInsets.only(top: 80),
                              child: Column(
                                children: [
                                  AppEmptyState(
                                    icon: state.lastError != null
                                        ? Icons.error_outline_rounded
                                        : Icons.search_off_rounded,
                                    title: state.lastError != null
                                        ? i18n.tr('error')
                                        : i18n.tr('asmr_empty_category'),
                                    message: state.lastError == null
                                        ? ''
                                        : localizedAsmrCatalogErrorText(
                                            i18n,
                                            state.lastError,
                                          ),
                                    actionLabel: state.lastError != null
                                        ? i18n.tr('retry')
                                        : null,
                                    actionIcon: Icons.refresh_rounded,
                                    onAction:
                                        state.lastError != null &&
                                            !state.isLoading &&
                                            !state.isRefreshing
                                        ? () => unawaited(widget.onRefresh())
                                        : null,
                                  ),
                                  if (hasLoadMore)
                                    TextButton(
                                      key: const ValueKey(
                                        'asmr_empty_load_more',
                                      ),
                                      onPressed: state.isLoadingMore
                                          ? null
                                          : _loadMore,
                                      child: Text(i18n.tr('my_load_more')),
                                    ),
                                ],
                              ),
                            )
                          : !hasLoadMore
                          ? const SizedBox.shrink(
                              key: ValueKey<String>('asmr_load_more_complete'),
                            )
                          : Padding(
                              key: ValueKey((
                                'asmr_load_more_visible',
                                state.needsLoadMoreRetry,
                              )),
                              padding: const EdgeInsets.only(top: 4, bottom: 4),
                              child: Center(
                                child: state.needsLoadMoreRetry
                                    ? Text(
                                        i18n.tr('asmr_load_more_hint'),
                                        key: const ValueKey<String>(
                                          'asmr_load_more_retry_hint',
                                        ),
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              color: theme
                                                  .colorScheme
                                                  .onSurfaceVariant,
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
                                          color: primaryColor,
                                        ),
                                      ),
                              ),
                            ),
                    );
                  }

                  final rows = _AsmrWorkRowsDelegate(
                    (context, rowIndex) {
                      if (columnCount == 1) {
                        return buildWorkCard(visibleWorks[rowIndex]);
                      }
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (
                            var column = 0;
                            column < columnCount;
                            column++
                          ) ...[
                            if (column > 0)
                              const SizedBox(
                                width: kResponsiveLibraryCardSpacing,
                              ),
                            Expanded(
                              child:
                                  rowIndex * columnCount + column <
                                      visibleWorks.length
                                  ? buildWorkCard(
                                      visibleWorks[rowIndex * columnCount +
                                          column],
                                    )
                                  : const SizedBox.shrink(),
                            ),
                          ],
                        ],
                      );
                    },
                    works: visibleWorks,
                    columnCount: columnCount,
                    searchQuery: widget.searchQuery,
                    searchSession: widget.searchSession,
                    isSelectionMode: widget.isSelectionMode,
                    selectedWorkIds: widget.selectedWorkIds,
                    loadingAnimations: _loadingWorkAnimations,
                    collapsingWorks: _visibleCollapsing,
                    childCount: rowCount,
                    findChildIndexCallback: columnCount == 1
                        ? (key) => workKeyIndices[key]
                        : null,
                  );
                  final footer = RepaintBoundary(
                    child: Builder(builder: buildFooter),
                  );
                  return workList = CustomScrollView(
                    key: PageStorageKey(widget.category),
                    controller: widget.scrollController,
                    cacheExtent: widget.searchSession ? 120 : 320,
                    physics: AlwaysScrollableScrollPhysics(
                      parent: GlassRefreshIndicatorScrollPhysics(
                        isIndicatorVisible: () =>
                            _refreshIndicatorKey
                                .currentState
                                ?.isIndicatorVisible ??
                            false,
                      ),
                    ),
                    semanticChildCount: rowCount + 1,
                    slivers: [
                      SliverPadding(
                        padding: EdgeInsets.fromLTRB(
                          LibraryLikeCardMetrics.listHorizontalPadding,
                          widget.topInset,
                          LibraryLikeCardMetrics.listHorizontalPadding,
                          0,
                        ),
                        // Retiring favorites shrink below the normal row height.
                        sliver: _collapsingWorks.isEmpty
                            ? SliverFixedExtentList(
                                itemExtent:
                                    LibraryLikeCardMetrics.rootTileHeight,
                                delegate: rows,
                              )
                            : ScrollToTopSliverList(delegate: rows),
                      ),
                      SliverPadding(
                        padding: EdgeInsets.fromLTRB(
                          LibraryLikeCardMetrics.listHorizontalPadding,
                          0,
                          LibraryLikeCardMetrics.listHorizontalPadding,
                          widget.bottomInset + 24,
                        ),
                        sliver: SliverLayoutBuilder(
                          builder: (context, constraints) {
                            if (constraints.remainingCacheExtent > 0 &&
                                visibleWorks.isNotEmpty &&
                                !state.needsLoadMoreRetry) {
                              _scheduleAutomaticLoadMore(state);
                            }
                            return SliverToBoxAdapter(
                              // The footer is measured offscreen too; keep its
                              // progress indicator idle until it can be painted.
                              child: TickerMode(
                                enabled: constraints.remainingPaintExtent > 0,
                                child: IndexedSemantics(
                                  index: rowCount,
                                  child: footer,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    final page = Theme(
      data: theme.copyWith(
        scrollbarTheme: theme.scrollbarTheme.copyWith(
          // Value equality avoids invalidating every card's Theme on paging.
          thumbColor: WidgetStateProperty.fromMap({
            WidgetState.dragged: primaryColor,
            WidgetState.hovered: primaryColor.withValues(alpha: 0.7),
            WidgetState.any: theme.colorScheme.outlineVariant.withValues(
              alpha: 0.5,
            ),
          }),
        ),
      ),
      child: widget.searchSession
          ? content
          : BrowsePageScroll(
              pageKey:
                  'asmr_list:${ref.read(asmrLibraryControllerProvider)?.browseCacheScope ?? ''}:${widget.category.name}',
              controller: widget.scrollController,
              anchorIds: _anchorIds,
              child: content,
            ),
    );
    return Builder(
      builder: (context) {
        _route = ModalRoute.of(context);
        _handleActivityChanged();
        return page;
      },
    );
  }

  void _loadMoreOncePerScroll(AsmrCategoryViewState state) {
    if (!_isActive ||
        _loadMoreTriggeredInCurrentScroll ||
        state.isLoadingMore ||
        !state.hasMore) {
      return;
    }
    _loadMoreTriggeredInCurrentScroll = true;
    unawaited(_loadMore());
  }

  void _scheduleAutomaticLoadMore(AsmrCategoryViewState state) {
    if (_automaticLoadMoreScheduled ||
        !_isActive ||
        state.works.isEmpty ||
        state.isLoadingMore ||
        !state.hasMore ||
        state.needsLoadMoreRetry) {
      return;
    }
    _automaticLoadMoreScheduled = true;
    UiInteractionCoordinator.instance.scheduleCommit(
      key: _automaticLoadMoreCommitKey,
      commit: () {
        _automaticLoadMoreScheduled = false;
        if (!mounted || !_isActive) {
          return;
        }
        final currentState = ref
            .read(asmrLibraryControllerProvider)
            ?.categoryViewState(
              widget.category,
              searchQuery: canonicalSearchQuery(widget.searchQuery),
              searchSession: widget.searchSession,
            );
        if (currentState == null ||
            currentState.works.isEmpty ||
            currentState.isLoadingMore ||
            !currentState.hasMore ||
            currentState.needsLoadMoreRetry) {
          return;
        }
        if (!widget.scrollController.hasClients) return;
        final position = widget.scrollController.position;
        if (position.extentAfter > position.viewportDimension) return;
        unawaited(_loadMore());
      },
    );
  }

  Future<void> _loadMore() async {
    await ref
        .read(asmrLibraryControllerProvider)
        ?.loadMoreCategory(
          widget.category,
          searchQuery: widget.searchQuery,
          searchSession: widget.searchSession,
        );
  }
}
