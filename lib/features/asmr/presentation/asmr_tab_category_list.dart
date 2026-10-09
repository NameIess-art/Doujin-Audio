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
      duration: const Duration(milliseconds: 260),
      value: 1.0,
    );
    animation = CurvedAnimation(parent: controller, curve: Curves.easeOutCubic);
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
  final Set<int> selectedWorkIds;
  final ValueChanged<AsmrWork> onEnterSelectionMode;
  final ValueChanged<AsmrWork> onToggleSelection;

  @override
  ConsumerState<_AsmrCategoryList> createState() => _AsmrCategoryListState();
}

class _AsmrCategoryListState extends ConsumerState<_AsmrCategoryList>
    with AutomaticKeepAliveClientMixin, TickerProviderStateMixin {
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
  final Map<int, _CollapsingAsmrWork> _collapsingWorks =
      <int, _CollapsingAsmrWork>{};
  List<AsmrWork>? _lastFavoritesWorks;
  String? _lastFavoritesQuery;
  int? _lastFavoritesRevision;
  AsmrCategoryViewState? _lastLoadState;
  final Map<int, Animation<double>> _loadingWorkAnimations = {};
  final Set<AnimationController> _loadingBatchControllers = {};

  bool get _isActive =>
      widget.isActive() &&
      (widget.isPageActive?.call() ?? true) &&
      (_tickerModeNotifier?.value.enabled ?? true) &&
      ModalRoute.of(context)?.isCurrent != false;

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
        normalizeSearchQuery(oldWidget.searchQuery) !=
            normalizeSearchQuery(widget.searchQuery)) {
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
      if (previous.works[i].id != works[i].id) return;
    }
    // Start once when a page enters the rendered data, including offscreen
    // records. Lazy card creation then observes the batch's current opacity.
    final controller = AnimationController(
      vsync: this,
      duration: kPlaceholderContentTransitionDuration,
    );
    final animation = controller.drive(
      CurveTween(curve: Curves.easeInOutCubic),
    );
    _loadingBatchControllers.add(controller);
    for (final work in works.skip(previous.works.length)) {
      _loadingWorkAnimations[work.id] = animation;
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
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final normalizedSearchQuery = normalizeSearchQuery(widget.searchQuery);
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
        normalizeSearchQuery(state.activeQuery) != normalizedSearchQuery;
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
        final currentWorkIds = <int>{for (final w in works) w.id};
        _collapsingWorks.removeWhere((id, entry) {
          if (currentWorkIds.contains(id)) {
            entry.dispose();
            return true;
          }
          return false;
        });
        for (var i = 0; i < _lastFavoritesWorks!.length; i++) {
          final previousWork = _lastFavoritesWorks![i];
          if (!currentWorkIds.contains(previousWork.id) &&
              !_collapsingWorks.containsKey(previousWork.id)) {
            final workId = previousWork.id;
            _collapsingWorks[workId] = _CollapsingAsmrWork(
              work: previousWork,
              originalIndex: i,
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
      }
      _lastFavoritesWorks = works;
      _lastFavoritesQuery = normalizedSearchQuery;
      _lastFavoritesRevision = state.revision;
    }

    final visibleWorks = _collapsingWorks.isEmpty
        ? works
        : <AsmrWork>[...works];
    if (_collapsingWorks.isNotEmpty) {
      final sortedCollapsing = _collapsingWorks.values.toList()
        ..sort((a, b) => a.originalIndex.compareTo(b.originalIndex));
      for (final entry in sortedCollapsing) {
        final insertIndex = entry.originalIndex.clamp(0, visibleWorks.length);
        visibleWorks.insert(insertIndex, entry.work);
      }
    }

    Widget buildWorkCard(AsmrWork work) {
      final card = _AsmrWorkTreeCard(
        work: work,
        searchQuery: widget.searchQuery,
        isSelectionMode: widget.isSelectionMode,
        isSelected: widget.selectedWorkIds.contains(work.id),
        onLongPress: () => widget.onEnterSelectionMode(work),
        onToggleSelect: () => widget.onToggleSelection(work),
      );
      final workCard = FadeTransition(
        key: ValueKey<String>('asmr-work-${work.id}'),
        opacity:
            _loadingWorkAnimations[work.id] ??
            const AlwaysStoppedAnimation<double>(1),
        child: RepaintBoundary(
          child: widget.searchSession
              ? card
              : BrowseAnchor(id: '${work.id}', child: card),
        ),
      );
      final collapsing = _collapsingWorks[work.id];
      if (collapsing == null) return workCard;
      return AnimatedBuilder(
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
    final asmrBlue = AppDesignTokens.of(context).asmrAccent;
    double? listWidth;
    Widget? workList;
    final content = ScrollActivityGate(
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
            color: asmrBlue,
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
                  final rowCount = (visibleWorks.length / columnCount).ceil();
                  final hasLoadMore = state.isLoadingMore || state.hasMore;
                  return workList = ListView.builder(
                    key: PageStorageKey(widget.category),
                    controller: widget.scrollController,
                    cacheExtent: widget.searchSession ? 120 : 520,
                    physics: AlwaysScrollableScrollPhysics(
                      parent: GlassRefreshIndicatorScrollPhysics(
                        isIndicatorVisible: () =>
                            _refreshIndicatorKey
                                .currentState
                                ?.isIndicatorVisible ??
                            false,
                      ),
                    ),
                    padding: EdgeInsets.fromLTRB(
                      LibraryLikeCardMetrics.listHorizontalPadding,
                      widget.topInset,
                      LibraryLikeCardMetrics.listHorizontalPadding,
                      widget.bottomInset + 24,
                    ),
                    itemCount: visibleWorks.isEmpty ? 1 : rowCount + 1,
                    findChildIndexCallback: (key) {
                      if (key ==
                          const ValueKey<String>('asmr_load_more_footer')) {
                        return rowCount;
                      }
                      if (columnCount != 1) return null;
                      final index = visibleWorks.indexWhere(
                        (work) =>
                            key == ValueKey<String>('asmr-work-${work.id}'),
                      );
                      return index < 0 ? null : index;
                    },
                    itemBuilder: (context, rowIndex) {
                      if (visibleWorks.isEmpty) {
                        final errorText = state.lastError == null
                            ? null
                            : localizedAsmrCatalogErrorText(
                                i18n,
                                state.lastError,
                              );
                        return Padding(
                          padding: const EdgeInsets.only(top: 80),
                          child: AppEmptyState(
                            icon: state.lastError != null
                                ? Icons.error_outline_rounded
                                : Icons.search_off_rounded,
                            title: state.lastError != null
                                ? i18n.tr('error')
                                : i18n.tr('asmr_empty_category'),
                            message: errorText ?? '',
                          ),
                        );
                      }
                      if (rowIndex >= rowCount) {
                        if (!state.needsLoadMoreRetry) {
                          _scheduleAutomaticLoadMore(state);
                        }
                        return AnimatedSwitcher(
                          key: const ValueKey<String>('asmr_load_more_footer'),
                          duration: reduceMotion
                              ? Duration.zero
                              : kPlaceholderContentTransitionDuration,
                          switchInCurve: Curves.easeInOutCubic,
                          switchOutCurve: Curves.easeInOutCubic,
                          child: !hasLoadMore
                              ? const SizedBox.shrink(
                                  key: ValueKey<String>(
                                    'asmr_load_more_complete',
                                  ),
                                )
                              : Padding(
                                  key: const ValueKey<String>(
                                    'asmr_load_more_visible',
                                  ),
                                  padding: const EdgeInsets.only(
                                    top: 4,
                                    bottom: 4,
                                  ),
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
                                              color: asmrBlue,
                                            ),
                                          ),
                                  ),
                                ),
                        );
                      }
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
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    return Theme(
      data: theme.copyWith(
        scrollbarTheme: theme.scrollbarTheme.copyWith(
          thumbColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.dragged)) return asmrBlue;
            if (states.contains(WidgetState.hovered)) {
              return asmrBlue.withValues(alpha: 0.7);
            }
            return theme.colorScheme.outlineVariant.withValues(alpha: 0.5);
          }),
        ),
      ),
      child: widget.searchSession
          ? content
          : BrowsePageScroll(
              pageKey:
                  'asmr_list:${ref.read(asmrLibraryControllerProvider)?.browseCacheScope ?? ''}:${widget.category.name}',
              controller: widget.scrollController,
              anchorIds: visibleWorks.map((work) => '${work.id}').toList(),
              child: content,
            ),
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
              searchQuery: normalizeSearchQuery(widget.searchQuery),
              searchSession: widget.searchSession,
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
