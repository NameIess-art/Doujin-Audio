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
    with AutomaticKeepAliveClientMixin, TickerProviderStateMixin {
  final GlobalKey<GlassRefreshIndicatorState> _refreshIndicatorKey =
      GlobalKey<GlassRefreshIndicatorState>();
  bool _refreshTriggeredInCurrentScroll = false;
  bool _loadMoreTriggeredInCurrentScroll = false;
  bool _automaticLoadMoreScheduled = false;
  final Map<int, _CollapsingAsmrWork> _collapsingWorks =
      <int, _CollapsingAsmrWork>{};
  List<AsmrWork>? _lastFavoritesWorks;
  String? _lastFavoritesQuery;
  @override
  void didUpdateWidget(covariant _AsmrCategoryList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.category != widget.category ||
        normalizeSearchQuery(oldWidget.searchQuery) !=
            normalizeSearchQuery(widget.searchQuery)) {
      for (final entry in _collapsingWorks.values) {
        entry.dispose();
      }
      _collapsingWorks.clear();
      _lastFavoritesWorks = null;
      _lastFavoritesQuery = null;
    }
  }

  @override
  void dispose() {
    for (final entry in _collapsingWorks.values) {
      entry.dispose();
    }
    _collapsingWorks.clear();
    super.dispose();
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
    final queryMismatch =
        widget.category != AsmrCategoryType.favorites &&
        widget.category != AsmrCategoryType.history &&
        normalizeSearchQuery(state.activeQuery) != normalizedSearchQuery;
    final works = queryMismatch ? const <AsmrWork>[] : state.works;
    final isFavorites = widget.category == AsmrCategoryType.favorites;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    if (isFavorites) {
      if (_lastFavoritesQuery == normalizedSearchQuery &&
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
      final workCard = RepaintBoundary(
        key: ValueKey<String>('asmr-work-${work.id}'),
        child: _AsmrWorkTreeCard(
          work: work,
          searchQuery: widget.searchQuery,
          isActive: widget.isActive,
          isSelectionMode: widget.isSelectionMode,
          isSelected: widget.selectedWorkIds.contains(work.id),
          onLongPress: () => widget.onEnterSelectionMode(work),
          onToggleSelect: () => widget.onToggleSelection(work),
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
                placeholder: LibrarySkeletonListView(
                  key: const ValueKey('loading'),
                  topInset: widget.topInset,
                  bottomInset: widget.bottomInset + 24,
                ),
                content: LayoutBuilder(
                  builder: (context, constraints) {
                    final columnCount = responsiveLibraryCardColumnCount(
                      constraints.maxWidth,
                    );
                    final rowCount = (visibleWorks.length / columnCount).ceil();
                    final hasLoadMore = state.isLoadingMore || state.hasMore;
                    return ListView.builder(
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
                      itemCount: visibleWorks.isEmpty
                          ? 1
                          : rowCount + (hasLoadMore ? 1 : 0),
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
                          return Padding(
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
                                        color: asmrBlue,
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
      ),
    );
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
