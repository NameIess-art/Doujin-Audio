part of 'asmr_tab.dart';

class _AsmrCategoryList extends StatefulWidget {
  const _AsmrCategoryList({
    super.key,
    required this.category,
    required this.scrollController,
    required this.searchQuery,
    required this.topInset,
    required this.bottomInset,
    required this.onRefresh,
  });

  final AsmrCategoryType category;
  final ScrollController scrollController;
  final String searchQuery;
  final double topInset;
  final double bottomInset;
  final Future<void> Function() onRefresh;

  @override
  State<_AsmrCategoryList> createState() => _AsmrCategoryListState();
}

class _AsmrCategoryListState extends State<_AsmrCategoryList>
    with AutomaticKeepAliveClientMixin {
  final GlobalKey<GlassRefreshIndicatorState> _refreshIndicatorKey =
      GlobalKey<GlassRefreshIndicatorState>();
  bool _refreshTriggeredInCurrentScroll = false;

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final state = context.select<AsmrLibraryController, AsmrCategoryViewState>(
      (controller) => controller.categoryViewState(
        widget.category,
        searchQuery: widget.searchQuery,
      ),
    );
    final works = state.works;
    final showPlaceholder =
        works.isEmpty &&
        (state.isLoading ||
            (!state.hasAttemptedLoad && state.lastError == null));
    final i18n = context.watch<AppLanguageProvider>();
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
                if (notification.metrics.pixels >
                    notification.metrics.maxScrollExtent - 400) {
                  if (!state.isLoadingMore && state.hasMore) {
                    context.read<AsmrLibraryController>().loadMoreCategory(
                      widget.category,
                      searchQuery: widget.searchQuery,
                    );
                  }
                }
              } else if (notification is ScrollEndNotification) {
                _refreshTriggeredInCurrentScroll = false;
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
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 750),
                reverseDuration: const Duration(milliseconds: 750),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, animation) =>
                    FadeTransition(opacity: animation, child: child),
                child: showPlaceholder
                    ? ListView.builder(
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
                      )
                    : ListView.builder(
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
                                  ((state.isLoadingMore || state.hasMore)
                                      ? 1
                                      : 0),
                        itemBuilder: (context, index) {
                          if (works.isEmpty) {
                            final errorText = state.lastError?.toString();
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
                            return Padding(
                              padding: const EdgeInsets.only(top: 4, bottom: 4),
                              child: Center(
                                child: state.isLoadingMore
                                    ? SizedBox(
                                        width: 22,
                                        height: 22,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2.2,
                                          color: asmrBlue,
                                        ),
                                      )
                                    : Text(
                                        i18n.tr('asmr_load_more_hint'),
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              color: theme
                                                  .colorScheme
                                                  .onSurfaceVariant,
                                              fontWeight: FontWeight.w600,
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
