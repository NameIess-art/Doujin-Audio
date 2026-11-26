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
  late final CurvedAnimation animation;

  void dispose() {
    animation.dispose();
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
    required this.collapsingWorks,
    required this.loadAnimationRevision,
    super.childCount,
    super.findChildIndexCallback,
  }) : // Each card already isolates its paint, including cards sharing a row.
       super(addRepaintBoundaries: false);

  final List<AsmrWork> works;
  final int columnCount;
  final String searchQuery;
  final bool searchSession;
  final Map<String, _CollapsingAsmrWork> collapsingWorks;
  final int loadAnimationRevision;

  @override
  bool shouldRebuild(covariant _AsmrWorkRowsDelegate oldDelegate) {
    // Paging progress and retry/footer updates do not change the row content.
    // Let mounted cards keep their layout and decoded covers for those commits.
    return !identical(works, oldDelegate.works) ||
        columnCount != oldDelegate.columnCount ||
        searchQuery != oldDelegate.searchQuery ||
        searchSession != oldDelegate.searchSession ||
        !identical(collapsingWorks, oldDelegate.collapsingWorks) ||
        loadAnimationRevision != oldDelegate.loadAnimationRevision;
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
    this.filters = emptySearchFilters,
    this.searchSession = false,
    required this.topInset,
    required this.bottomInset,
    required this.onRefresh,
    this.onClearFilters,
    required this.selectionListenable,
    required this.onEnterSelectionMode,
    required this.onToggleSelection,
  });

  final bool Function() isActive;
  final bool Function()? isPageActive;
  final AsmrCategoryType category;
  final bool isLoadPending;
  final ScrollController scrollController;
  final String searchQuery;
  final SearchFilters filters;
  final bool searchSession;
  final double topInset;
  final double bottomInset;
  final Future<void> Function() onRefresh;
  final VoidCallback? onClearFilters;
  final ValueListenable<({bool active, Set<String> ids})> selectionListenable;
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
  ({
    SearchFilters filters,
    AsmrCategoryViewState source,
    AsmrCategoryViewState result,
  })?
  _filteredProjection;
  late final String _automaticLoadMoreCommitKey =
      'asmr_load_more_${identityHashCode(this)}';
  final Map<String, _CollapsingAsmrWork> _collapsingWorks =
      <String, _CollapsingAsmrWork>{};
  List<AsmrWork>? _lastFavoritesWorks;
  String? _lastFavoritesQuery;
  int? _lastFavoritesRevision;
  AsmrFavoritesStatusFilter? _lastFavoritesFilter;
  AsmrCategoryViewState? _lastLoadState;
  final Map<String, Animation<double>> _loadingWorkAnimations = {};
  final Set<AnimationController> _loadingBatchControllers = {};
  final List<AnimationController> _pendingDisposedLoadControllers = [];
  bool _loadControllerDisposeScheduled = false;
  int _loadAnimationRevision = 0;
  final Map<String, GlobalKey> _itemKeys = {};
  final Map<String, _SelectableAsmrWorkCard> _workCardCache = {};
  List<AsmrWork>? _visibleWorksSource;
  List<AsmrWork> _visibleWorksCache = const [];
  Object? _visiblePaginationToken;
  Map<String, _CollapsingAsmrWork> _visibleCollapsing = const {};
  Map<String, int> _workIndexById = {};
  Map<Key, int> _workKeyIndices = {};
  LibraryCoverUiController? _coverUi;
  BuildContext? _coverContext;
  (AsmrCategoryType, String, int, Object?)? _lastNotifiedErrorKey;
  bool _unavailableFeedbackScheduled = false;

  Future<void> _handleRefresh() {
    clearAsmrUnavailableNotice(
      ref.read(asmrLibraryControllerProvider) ?? this,
    );
    _lastNotifiedErrorKey = null;
    return widget.onRefresh();
  }

  List<AsmrWork> _prepareVisibleWorks(
    List<AsmrWork> works,
    AsmrCategoryViewState state,
  ) {
    if (identical(_visibleWorksSource, works) &&
        _visibleCollapsing.length == _collapsingWorks.length &&
        _collapsingWorks.entries.every(
          (entry) => identical(_visibleCollapsing[entry.key], entry.value),
        )) {
      _visiblePaginationToken = state.paginationToken;
      return _visibleWorksCache;
    }
    final append = state.appendedTo;
    final extendsVisibleOrder =
        _visibleCollapsing.isEmpty &&
        _collapsingWorks.isEmpty &&
        append != null &&
        identical(append.token, _visiblePaginationToken) &&
        append.length == _visibleWorksCache.length &&
        works.length >= append.length;
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
    final start = extendsVisibleOrder ? _visibleWorksCache.length : 0;
    _visibleWorksSource = works;
    _visiblePaginationToken = state.paginationToken;
    _visibleCollapsing = Map.of(_collapsingWorks);
    _visibleWorksCache = visible;
    if (!extendsVisibleOrder) {
      _workIndexById = {};
      _workKeyIndices = {};
    }
    for (var index = start; index < visible.length; index++) {
      final id = visible[index].workKey;
      _workIndexById[id] = index;
      final key = _itemKeys[id];
      if (key != null) _workKeyIndices[key] = index;
    }
    if (!extendsVisibleOrder) {
      _itemKeys.removeWhere((id, _) => !_workIndexById.containsKey(id));
      _workCardCache.removeWhere((id, _) => !_workIndexById.containsKey(id));
    }
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
    _coverUi?.refreshBrowsePrefetch(this);
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
        oldWidget.filters != widget.filters ||
        canonicalElementQuery(oldWidget.searchQuery) !=
            canonicalElementQuery(widget.searchQuery)) {
      _filteredProjection = null;
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

  AsmrCategoryViewState _applyFilters(AsmrCategoryViewState state) {
    final filters = widget.filters;
    if (filters == emptySearchFilters) return state;
    final cached = _filteredProjection;
    final previous = cached?.filters == filters ? cached : null;
    if (previous != null && identical(previous.source, state)) {
      return previous.result;
    }

    final append = state.appendedTo;
    final List<AsmrWork> matches;
    ({Object token, int length})? filteredAppend;
    if (previous != null && identical(previous.source.works, state.works)) {
      matches = previous.result.works;
      if (identical(previous.source.paginationToken, state.paginationToken)) {
        filteredAppend = previous.result.appendedTo;
      }
    } else if (previous != null &&
        append != null &&
        identical(append.token, previous.source.paginationToken) &&
        append.length == previous.source.works.length &&
        state.works.length >= append.length &&
        // The prefix may have changed in a deferred update, such as a favorite
        // change that increments the revision without advancing pagination.
        state.revision == previous.source.revision + 1) {
      final additions = state.works
          .skip(append.length)
          .where((work) => work.matchesFilters(filters))
          .toList(growable: false);
      final previousMatches = previous.result.works;
      matches = additions.isEmpty
          ? previousMatches
          : immutableList(previousMatches.followedBy(additions));
      filteredAppend = (token: append.token, length: previousMatches.length);
    } else {
      matches = immutableList(
        state.works.where((work) => work.matchesFilters(filters)),
      );
    }
    final result = state.withFilteredWorks(matches, appendedTo: filteredAppend);
    _filteredProjection = (filters: filters, source: state, result: result);
    return result;
  }

  @override
  void dispose() {
    _coverUi?.cancelBrowsePrefetch(this);
    _tickerModeNotifier?.removeListener(_handleActivityChanged);
    UiInteractionCoordinator.instance.cancelCommit(_automaticLoadMoreCommitKey);
    for (final entry in _collapsingWorks.values) {
      entry.dispose();
    }
    _collapsingWorks.clear();
    _clearLoadAnimations(immediate: true);
    super.dispose();
  }

  void _retireLoadControllers(Iterable<AnimationController> controllers) {
    var added = false;
    for (final controller in controllers) {
      controller.stop(canceled: false);
      _pendingDisposedLoadControllers.add(controller);
      added = true;
    }
    if (!added || _loadControllerDisposeScheduled) return;
    _loadControllerDisposeScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadControllerDisposeScheduled = false;
      _disposePendingLoadControllers();
    });
  }

  void _disposePendingLoadControllers() {
    if (_pendingDisposedLoadControllers.isEmpty) return;
    final controllers = List<AnimationController>.of(
      _pendingDisposedLoadControllers,
    );
    _pendingDisposedLoadControllers.clear();
    for (final controller in controllers) {
      controller.dispose();
    }
  }

  void _clearLoadAnimations({bool immediate = false}) {
    if (_loadingWorkAnimations.isNotEmpty) {
      _loadingWorkAnimations.clear();
      _loadAnimationRevision++;
    }
    if (_loadingBatchControllers.isEmpty) {
      if (immediate) _disposePendingLoadControllers();
      return;
    }
    final controllers = List<AnimationController>.of(_loadingBatchControllers);
    _loadingBatchControllers.clear();
    if (immediate) {
      for (final controller in controllers) {
        controller.dispose();
      }
      _disposePendingLoadControllers();
      return;
    }
    _retireLoadControllers(controllers);
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
    // Skip fading newly appended batches during fast scroll without cutting
    // off already-visible older batches mid-fade.
    if (_coverContext?.mounted == true &&
        ScrollActivityGate.isFastScrollingWithoutDependencyOf(_coverContext!)) {
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
    final append = state.appendedTo;
    if (append == null ||
        !identical(append.token, previous.paginationToken) ||
        append.length != previous.works.length) {
      for (var i = 0; i < previous.works.length; i++) {
        if (previous.works[i].workKey != works[i].workKey) return;
      }
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
    _loadAnimationRevision++;
    controller.forward().then((_) {
      if (!_loadingBatchControllers.remove(controller)) return;
      _loadingWorkAnimations.removeWhere((_, value) => value == animation);
      if (!mounted) {
        controller.dispose();
        return;
      }
      // Rebuild first so mounted FadeTransitions detach before dispose.
      _retireLoadControllers([controller]);
      setState(() {
        _loadAnimationRevision++;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    _coverUi = ref.read(libraryCoverUiControllerProvider);
    final coverResolution = ref.watch(coverImageResolutionProvider);
    final normalizedSearchQuery = canonicalElementQuery(widget.searchQuery);
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
      _filteredProjection = null;
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
    final state = _applyFilters(
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
          ),
    );
    final queryMismatch =
        widget.category != AsmrCategoryType.favorites &&
        widget.category != AsmrCategoryType.history &&
        canonicalElementQuery(state.activeQuery) != normalizedSearchQuery;
    final works = queryMismatch ? const <AsmrWork>[] : state.works;
    final isFavorites = widget.category == AsmrCategoryType.favorites;
    final activeFavoritesFilter = isFavorites
        ? ref.watch(
            asmrLibraryGlobalStateProvider.select(
              (s) =>
                  s.value?.favoritesStatusFilter ??
                  controller?.favoritesStatusFilter ??
                  AsmrFavoritesStatusFilter.marked,
            ),
          )
        : AsmrFavoritesStatusFilter.marked;
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
      final filterChanged =
          _lastFavoritesFilter != null &&
          _lastFavoritesFilter != activeFavoritesFilter;
      if (filterChanged) {
        for (final entry in _collapsingWorks.values) {
          entry.dispose();
        }
        _collapsingWorks.clear();
      } else if (_lastFavoritesRevision != state.revision &&
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
      _lastFavoritesFilter = activeFavoritesFilter;
    }

    final visibleWorks = _prepareVisibleWorks(works, state);
    // Outgoing placeholder transitions can still build the previous list.
    // Keep each delegate's indices with the projection it renders.
    final workIndexById = _workIndexById;
    final workKeyIndices = _workKeyIndices;

    Widget buildWorkCard(AsmrWork work) {
      var card = _workCardCache[work.workKey];
      if (card == null ||
          !identical(card.work, work) ||
          card.searchQuery != widget.searchQuery ||
          !identical(card.selectionListenable, widget.selectionListenable)) {
        if (_workCardCache.length >= 128) {
          _workCardCache.removeWhere(
            (id, _) => _itemKeys[id]?.currentContext == null,
          );
        }
        // Paging changes the row delegate, but unchanged mounted cards can
        // reuse their complete widget instead of rebuilding text and artwork.
        card = _SelectableAsmrWorkCard(
          work: work,
          searchQuery: widget.searchQuery,
          selectionListenable: widget.selectionListenable,
          onLongPress: () => widget.onEnterSelectionMode(work),
          onToggleSelect: () => widget.onToggleSelection(work),
        );
        _workCardCache[work.workKey] = card;
      }
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
        workCard = SizeTransition(
          sizeFactor: collapsing.animation,
          axisAlignment: -1.0,
          child: FadeTransition(
            opacity: collapsing.animation,
            child: IgnorePointer(child: ExcludeSemantics(child: workCard)),
          ),
        );
      }
      // Rows regroup on resize; retain the complete card, including its
      // removal host and decoded cover, when it moves to another row.
      var key = _itemKeys[work.workKey];
      if (key == null) {
        if (_itemKeys.length >= 128) {
          final staleIds = <String>[];
          _itemKeys.forEach((id, itemKey) {
            if (itemKey.currentContext == null) {
              staleIds.add(id);
            }
          });
          for (final id in staleIds) {
            final removedKey = _itemKeys.remove(id);
            if (removedKey != null) {
              _workKeyIndices.remove(removedKey);
              workKeyIndices.remove(removedKey);
            }
            _workCardCache.remove(id);
          }
        }
        key = GlobalKey();
        _itemKeys[work.workKey] = key;
      }
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
    if (showPlaceholder || visibleWorks.isEmpty) {
      _coverUi!.cancelBrowsePrefetch(this);
    }
    final activeError = state.operationError ?? state.lastError;
    if (!showPlaceholder &&
        !state.isLoading &&
        !state.isRefreshing &&
        state.hasAttemptedLoad &&
        _isActive) {
      if (activeError == null && controller != null) {
        clearAsmrUnavailableNotice(controller);
        _lastNotifiedErrorKey = null;
      } else if (activeError != null &&
          shouldShowAsmrUnavailableFeedback(activeError)) {
        final errorKey = (
          widget.category,
          normalizedSearchQuery,
          state.revision,
          activeError,
        );
        if (_lastNotifiedErrorKey != errorKey &&
            !_unavailableFeedbackScheduled) {
          _lastNotifiedErrorKey = errorKey;
          final scopeOwner = controller ?? this;
          if (consumeAsmrUnavailableNotice(scopeOwner, activeError)) {
            _unavailableFeedbackScheduled = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _unavailableFeedbackScheduled = false;
              if (!mounted || !_isActive) return;
              showAsmrUnavailableFeedback(
                context: context,
                i18n: ref.read(appLanguageProviderInstanceProvider),
                error: activeError,
                onRetry: () {
                  if (!mounted) return;
                  if ((parseSearchElements(widget.searchQuery)?.any.length ??
                              0) >
                          1 &&
                      state.hasMore) {
                    clearAsmrUnavailableNotice(scopeOwner);
                    _lastNotifiedErrorKey = null;
                    unawaited(_loadMore());
                  } else {
                    unawaited(_handleRefresh());
                  }
                },
              );
            });
          }
        }
      }
    }
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
              final towardBottom = (notification.scrollDelta ?? 0) > 0;
              if (nearBottom &&
                  towardBottom &&
                  (!state.needsLoadMoreRetry ||
                      notification.dragDetails != null)) {
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
            onRefresh: _handleRefresh,
            child: PlaceholderContentTransition(
              showPlaceholder: showPlaceholder,
              placeholder: LibrarySkeletonListView(
                key: const ValueKey('loading'),
                topInset: widget.topInset,
                bottomInset:
                    widget.bottomInset + (widget.searchSession ? 0 : 16),
              ),
              content: LayoutBuilder(
                builder: (context, constraints) {
                  _coverContext = context;
                  // Keyboard height changes only resize the viewport. New
                  // data or a width change still rebuilds the row delegates.
                  if (listWidth == constraints.maxWidth && workList != null) {
                    return workList!;
                  }
                  listWidth = constraints.maxWidth;
                  final columnCount = responsiveLibraryCardColumnCount(
                    constraints.maxWidth,
                  );
                  if (!showPlaceholder &&
                      visibleWorks.isNotEmpty &&
                      _collapsingWorks.isEmpty) {
                    final library = ref.read(libraryFacadeProvider);
                    _coverUi!.updateBrowsePrefetch(
                      owner: this,
                      context: context,
                      scrollController: widget.scrollController,
                      source: visibleWorks,
                      itemCount: visibleWorks.length,
                      columnCount: columnCount,
                      topPadding: widget.topInset,
                      rowExtent: LibraryLikeCardMetrics.rootTileHeight,
                      cacheWidth: coverThumbnailCacheWidth(
                        logicalWidth:
                            LibraryLikeCardMetrics.coverHeight *
                            LibraryLikeCardMetrics.coverAspectRatio,
                        devicePixelRatio: MediaQuery.devicePixelRatioOf(
                          context,
                        ),
                        resolution: coverResolution,
                      ),
                      coverAt: (index) {
                        final url = _asmrWorkListCoverUrl(visibleWorks[index]);
                        return url.isEmpty
                            ? null
                            : library.coverPathFutureForRemoteCover(url);
                      },
                      isActive: () => mounted && _isActive,
                    );
                  } else {
                    _coverUi!.cancelBrowsePrefetch(this);
                  }
                  if (!widget.searchSession) {
                    BrowsePageScroll.setAnchorIds(
                      context,
                      null,
                      columnCount: _collapsingWorks.isEmpty
                          ? columnCount
                          : null,
                      rowExtent: LibraryLikeCardMetrics.rootTileHeight,
                      topPadding: widget.topInset,
                    );
                  }
                  final rowCount = (visibleWorks.length / columnCount).ceil();
                  final hasLoadMore = state.isLoadingMore || state.hasMore;
                  Widget buildRetry() {
                    if (defaultTargetPlatform == TargetPlatform.windows) {
                      return TextButton(
                        key: const ValueKey<String>('asmr_load_more_retry'),
                        onPressed: state.isLoadingMore
                            ? null
                            : () => _loadMore(
                                expectedPaginationToken: state.paginationToken,
                              ),
                        child: Text(i18n.tr('retry')),
                      );
                    }
                    return TextButton(
                      key: const ValueKey<String>('asmr_load_more_retry_hint'),
                      onPressed: state.isLoadingMore
                          ? null
                          : () => _loadMore(
                              expectedPaginationToken: state.paginationToken,
                            ),
                      style: TextButton.styleFrom(
                        foregroundColor: theme.colorScheme.onSurfaceVariant,
                      ),
                      child: Text(
                        i18n.tr('asmr_load_more_hint'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    );
                  }

                  Widget buildFooter(BuildContext context) {
                    return AnimatedSwitcher(
                      key: const ValueKey<String>('asmr_load_more_footer'),
                      duration: reduceMotion ? Duration.zero : kAppFadeDuration,
                      switchInCurve: kAppFadeCurve,
                      switchOutCurve: kAppFadeCurve,
                      child:
                          visibleWorks.isEmpty &&
                              hasLoadMore &&
                              widget.filters != emptySearchFilters &&
                              state.lastError == null
                          ? Padding(
                              key: const ValueKey('asmr_filtered_load_more'),
                              padding: const EdgeInsets.only(top: 24),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (state.needsLoadMoreRetry &&
                                      !state.isLoadingMore)
                                    TextButton(
                                      onPressed: () => _loadMore(
                                        expectedPaginationToken:
                                            state.paginationToken,
                                      ),
                                      child: Text(i18n.tr('my_load_more')),
                                    )
                                  else
                                    const Center(
                                      child: CircularProgressIndicator(),
                                    ),
                                  if (widget.onClearFilters != null) ...[
                                    const SizedBox(height: 8),
                                    TextButton.icon(
                                      key: const ValueKey(
                                        'asmr_filtered_clear_filters',
                                      ),
                                      style: appTextButtonStyle(
                                        scaleOnPress: true,
                                      ),
                                      onPressed: widget.onClearFilters,
                                      icon: const Icon(
                                        Icons.filter_alt_off_rounded,
                                        size: 18,
                                      ),
                                      label: Text(i18n.tr('clear_filters')),
                                    ),
                                  ],
                                ],
                              ),
                            )
                          : visibleWorks.isEmpty
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
                                        : widget.filters !=
                                                  emptySearchFilters &&
                                              widget.onClearFilters != null
                                        ? i18n.tr('clear_filters')
                                        : null,
                                    actionIcon: state.lastError != null
                                        ? Icons.refresh_rounded
                                        : Icons.filter_alt_off_rounded,
                                    onAction:
                                        state.lastError != null &&
                                            !state.isLoading &&
                                            !state.isRefreshing
                                        ? () => unawaited(_handleRefresh())
                                        : state.lastError == null &&
                                              widget.filters !=
                                                  emptySearchFilters
                                        ? widget.onClearFilters
                                        : null,
                                  ),
                                  if (hasLoadMore && state.lastError == null)
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
                                    ? buildRetry()
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
                    collapsingWorks: _visibleCollapsing,
                    loadAnimationRevision: _loadAnimationRevision,
                    childCount: rowCount,
                    findChildIndexCallback: columnCount == 1
                        ? (key) {
                            final index = workKeyIndices[key];
                            return index != null && index < visibleWorks.length
                                ? index
                                : null;
                          }
                        : null,
                  );
                  final footer = RepaintBoundary(
                    child: Builder(builder: buildFooter),
                  );
                  final showFavoritesFilterBar =
                      isFavorites && controller != null && !widget.searchSession;
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
                      if (showFavoritesFilterBar)
                        SliverPadding(
                          padding: EdgeInsets.fromLTRB(
                            LibraryLikeCardMetrics.listHorizontalPadding,
                            widget.topInset,
                            LibraryLikeCardMetrics.listHorizontalPadding,
                            6,
                          ),
                          sliver: SliverToBoxAdapter(
                            child: _AsmrFavoritesStatusFilterBar(
                              selected: activeFavoritesFilter,
                              i18n: i18n,
                              onSelected: controller.setFavoritesStatusFilter,
                            ),
                          ),
                        ),
                      SliverPadding(
                        padding: EdgeInsets.fromLTRB(
                          LibraryLikeCardMetrics.listHorizontalPadding,
                          showFavoritesFilterBar ? 0 : widget.topInset,
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
                          widget.bottomInset + (widget.searchSession ? 0 : 16),
                        ),
                        sliver: SliverLayoutBuilder(
                          builder: (context, constraints) {
                            if (constraints.remainingCacheExtent > 0 &&
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
    final page = widget.searchSession
        ? content
        : BrowsePageScroll(
            pageKey:
                'asmr_list:${ref.read(asmrLibraryControllerProvider)?.browseCacheScope ?? ''}:${widget.category.name}',
            controller: widget.scrollController,
            anchorIndices: workIndexById,
            child: content,
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
    unawaited(_loadMore(expectedPaginationToken: state.paginationToken));
  }

  bool _canAutomaticallyLoadMore(AsmrCategoryViewState state) =>
      (state.works.isNotEmpty || widget.filters != emptySearchFilters) &&
      !state.isLoading &&
      !state.isLoadingMore &&
      state.hasMore &&
      !state.needsLoadMoreRetry;

  void _scheduleAutomaticLoadMore(AsmrCategoryViewState state) {
    if (_automaticLoadMoreScheduled ||
        !_isActive ||
        !_canAutomaticallyLoadMore(state)) {
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
        final currentState = _lastPresentedState;
        if (currentState == null || !_canAutomaticallyLoadMore(currentState)) {
          return;
        }
        if (!widget.scrollController.hasClients) return;
        final position = widget.scrollController.position;
        if (position.extentAfter > position.viewportDimension) return;
        unawaited(
          _loadMore(expectedPaginationToken: currentState.paginationToken),
        );
      },
    );
  }

  Future<void> _loadMore({Object? expectedPaginationToken}) async {
    await ref
        .read(asmrLibraryControllerProvider)
        ?.loadMoreCategory(
          widget.category,
          searchQuery: widget.searchQuery,
          searchSession: widget.searchSession && widget.searchQuery.isNotEmpty,
          expectedPaginationToken: expectedPaginationToken,
        );
  }
}

class _SelectableAsmrWorkCard extends StatefulWidget {
  const _SelectableAsmrWorkCard({
    required this.work,
    required this.searchQuery,
    required this.selectionListenable,
    required this.onLongPress,
    required this.onToggleSelect,
  });

  final AsmrWork work;
  final String searchQuery;
  final ValueListenable<({bool active, Set<String> ids})> selectionListenable;
  final VoidCallback onLongPress;
  final VoidCallback onToggleSelect;

  @override
  State<_SelectableAsmrWorkCard> createState() =>
      _SelectableAsmrWorkCardState();
}

class _SelectableAsmrWorkCardState extends State<_SelectableAsmrWorkCard> {
  late bool _selectionMode;
  late bool _selected;

  @override
  void initState() {
    super.initState();
    _syncState();
    widget.selectionListenable.addListener(_handleSelectionChanged);
  }

  @override
  void didUpdateWidget(covariant _SelectableAsmrWorkCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(
      oldWidget.selectionListenable,
      widget.selectionListenable,
    )) {
      oldWidget.selectionListenable.removeListener(_handleSelectionChanged);
      widget.selectionListenable.addListener(_handleSelectionChanged);
    }
    _syncState();
  }

  void _syncState() {
    final snapshot = widget.selectionListenable.value;
    _selectionMode = snapshot.active;
    _selected = snapshot.ids.contains(widget.work.workKey);
  }

  void _handleSelectionChanged() {
    final snapshot = widget.selectionListenable.value;
    final nextMode = snapshot.active;
    final nextSelected = snapshot.ids.contains(widget.work.workKey);
    if (nextMode != _selectionMode || nextSelected != _selected) {
      setState(() {
        _selectionMode = nextMode;
        _selected = nextSelected;
      });
    }
  }

  @override
  void dispose() {
    widget.selectionListenable.removeListener(_handleSelectionChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _AsmrWorkTreeCard(
    work: widget.work,
    searchQuery: widget.searchQuery,
    isSelectionMode: _selectionMode,
    isSelected: _selected,
    onLongPress: widget.onLongPress,
    onToggleSelect: widget.onToggleSelect,
  );
}

class _AsmrFavoritesStatusFilterBar extends StatelessWidget {
  const _AsmrFavoritesStatusFilterBar({
    required this.selected,
    required this.i18n,
    required this.onSelected,
  });

  final AsmrFavoritesStatusFilter selected;
  final AppLanguageProvider i18n;
  final ValueChanged<AsmrFavoritesStatusFilter> onSelected;

  String _labelFor(AsmrFavoritesStatusFilter filter) {
    final status = filter.listenStatus;
    if (status == null) return i18n.tr('work_status_all');
    return i18n.tr(workListenStatusTranslationKey(status));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final height =
        MediaQuery.textScalerOf(context).scale(12) *
            (theme.textTheme.bodyMedium?.height ?? 1.4) +
        14;

    return HorizontalEdgeFadeScroll(
      key: const ValueKey<String>('asmr_favorites_status_filter_bar'),
      builder: (scrollController) => SizedBox(
        height: height,
        child: SingleChildScrollView(
          controller: scrollController,
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (
                var index = 0;
                index < AsmrFavoritesStatusFilter.values.length;
                index++
              ) ...[
                if (index > 0) const SizedBox(width: 6),
                Builder(
                  builder: (context) {
                    final filter = AsmrFavoritesStatusFilter.values[index];
                    final isActive = selected == filter;
                    final bg = isActive
                        ? cs.primary.withValues(alpha: isDark ? 0.24 : 0.14)
                        : (isDark
                              ? cs.surfaceContainerHighest.withValues(
                                  alpha: 0.45,
                                )
                              : cs.surfaceContainerHigh.withValues(
                                  alpha: 0.60,
                                ));
                    final fg = isActive ? cs.primary : cs.onSurfaceVariant;
                    final border = isActive
                        ? cs.primary.withValues(alpha: 0.55)
                        : cs.outlineVariant.withValues(
                            alpha: isDark ? 0.28 : 0.38,
                          );

                    return Material(
                      color: Colors.transparent,
                      child: AppEntryInkWell(
                        key: ValueKey<String>(
                          'asmr_favorites_filter_${filter.name}',
                        ),
                        onTap: () {
                          unawaited(
                            AppInteractionFeedback.trigger(
                              AppInteractionFeedbackType.selection,
                            ),
                          );
                          onSelected(filter);
                        },
                        borderRadius: BorderRadius.circular(999),
                        child: Ink(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 11,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: bg,
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: border,
                              width: isActive ? 1.0 : 0.8,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (filter.listenStatus case final status?) ...[
                                Icon(
                                  workListenStatusIcon(status),
                                  size: 13,
                                  color: fg,
                                ),
                                const SizedBox(width: 4),
                              ],
                              Text(
                                _labelFor(filter),
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontSize: 12,
                                  fontWeight: isActive
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                  color: fg,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
