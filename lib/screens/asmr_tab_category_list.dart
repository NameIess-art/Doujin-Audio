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
    final i18n = context.watch<AppLanguageProvider>();
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final asmrBlue = isDark ? const Color(0xFF60A5FA) : const Color(0xFF1D4ED8);
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
          child: GlassRefreshIndicator(
            key: _refreshIndicatorKey,
            color: asmrBlue,
            backgroundColor: Theme.of(
              context,
            ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
            edgeOffset: widget.topInset,
            displacement: 32,
            triggerMode: GlassRefreshIndicatorTriggerMode.anywhere,
            onRefresh: () async {
              unawaited(
                AppInteractionFeedback.trigger(
                  AppInteractionFeedbackType.confirmation,
                ),
              );
              await widget.onRefresh();
              await Future<void>.delayed(const Duration(milliseconds: 300));
            },
            child: ListView.builder(
              controller: widget.scrollController,
              cacheExtent: 520,
              physics: kTopPullRefreshScrollPhysics,
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
                  if (state.isLoading) {
                    return ShimmerLoader(
                      child: Column(
                        children: [
                          for (int i = 0; i < 5; i++)
                            const Padding(
                              padding: EdgeInsets.only(bottom: 6),
                              child: _AsmrWorkSkeletonCard(),
                            ),
                        ],
                      ),
                    );
                  }
                  return Padding(
                    padding: const EdgeInsets.only(top: 80),
                    child: Center(
                      child: Text(
                        state.lastError == null
                            ? i18n.tr('asmr_empty_category')
                            : i18n.tr('asmr_refresh_failed'),
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
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
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
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
    );
  }
}
