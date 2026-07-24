part of 'asmr_tab.dart';

class _AsmrCategoryList extends ConsumerStatefulWidget {
  const _AsmrCategoryList({
    super.key,
    required this.category,
    required this.isLoadPending,
    required this.scrollController,
    required this.searchQuery,
    required this.topInset,
    required this.bottomInset,
    required this.onRefresh,
  });

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

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final normalizedSearchQuery = normalizeSearchQuery(widget.searchQuery);
    final providerState = ref
        .watch(
          asmrCategoryStateProvider((
            category: widget.category,
            searchQuery: normalizedSearchQuery,
          )),
        )
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
    final showPlaceholder =
        works.isEmpty &&
        (widget.isLoadPending || state.isLoading || !state.hasAttemptedLoad);
    ref.watch(appLanguageStateProvider);
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
                    notification.metrics.pixels >
                    notification.metrics.maxScrollExtent - 400;
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
                    parent: _TopOnlyBouncingScrollPhysics(),
                  ),
                  padding: EdgeInsets.fromLTRB(
                    16,
                    widget.topInset,
                    16,
                    widget.bottomInset + 24,
                  ),
                  itemCount: 1,
                  itemBuilder: (context, index) {
                    return Column(
                      children: [
                        for (int i = 0; i < 5; i++)
                          const Padding(
                            padding: EdgeInsets.only(bottom: 6),
                            child: LibraryLikeSkeletonCard(),
                          ),
                      ],
                    );
                  },
                ),
                content: ListView.builder(
                  key: const ValueKey('content'),
                  controller: widget.scrollController,
                  cacheExtent: 520,
                  physics: const AlwaysScrollableScrollPhysics(
                    parent: BouncingScrollPhysics(),
                  ),
                  padding: EdgeInsets.fromLTRB(
                    16,
                    widget.topInset,
                    16,
                    widget.bottomInset + 24,
                  ),
                  itemCount: works.isEmpty
                      ? 1
                      : works.length +
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
                    if (index >= works.length) {
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
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: RepaintBoundary(
                        child: _AsmrWorkTreeCard(
                          work: works[index],
                          searchQuery: widget.searchQuery,
                        ),
                      ),
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
        state.isLoadingMore ||
        !state.hasMore ||
        state.needsLoadMoreRetry) {
      return;
    }
    _automaticLoadMoreScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _automaticLoadMoreScheduled = false;
      if (!mounted) return;
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
      unawaited(_loadMore());
    });
  }

  Future<void> _loadMore() async {
    await ref
        .read(asmrLibraryControllerProvider)
        ?.loadMoreCategory(widget.category, searchQuery: widget.searchQuery);
  }
}

class _TopOnlyBouncingScrollPhysics extends BouncingScrollPhysics {
  const _TopOnlyBouncingScrollPhysics({super.parent});

  @override
  _TopOnlyBouncingScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return _TopOnlyBouncingScrollPhysics(parent: buildParent(ancestor));
  }

  @override
  double applyBoundaryConditions(ScrollMetrics position, double value) {
    if (value > 0.0) {
      return value - (position.pixels > 0.0 ? position.pixels : 0.0);
    }
    return super.applyBoundaryConditions(position, value);
  }
}
