import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../i18n/app_language_provider.dart';
import '../models/asmr_models.dart';
import '../providers/audio_provider.dart';
import '../services/asmr_download_manager.dart';
import '../services/asmr_library_controller.dart';
import '../widgets/app_feedback.dart';
import '../widgets/library_like_cards.dart';
import '../widgets/mobile_overlay_inset.dart';
import '../widgets/swipe_reveal_card.dart';
import '../widgets/top_page_header.dart';
import 'asmr_download_page.dart';
import 'asmr_work_detail_sheet.dart';

const List<_AsmrCategorySpec> _asmrCategories = <_AsmrCategorySpec>[
  _AsmrCategorySpec(AsmrCategoryType.sales, '销量'),
  _AsmrCategorySpec(AsmrCategoryType.rating, '评价'),
  _AsmrCategorySpec(AsmrCategoryType.release, '发售'),
  _AsmrCategorySpec(AsmrCategoryType.favorites, '收藏'),
  _AsmrCategorySpec(AsmrCategoryType.history, '历史'),
];

class AsmrTab extends StatefulWidget {
  const AsmrTab({super.key});

  @override
  State<AsmrTab> createState() => _AsmrTabState();
}

class _AsmrTabState extends State<AsmrTab>
    with AutomaticKeepAliveClientMixin, TickerProviderStateMixin {
  late final TabController _tabController = TabController(
    length: _asmrCategories.length,
    vsync: this,
  );
  late final Map<AsmrCategoryType, ScrollController> _scrollControllers =
      <AsmrCategoryType, ScrollController>{
        for (final category in _asmrCategories)
          category.type: ScrollController()
            ..addListener(() => _handleCategoryScroll(category.type)),
      };
  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounceTimer;
  ValueListenable<int?>? _scrollToTopTabListenable;
  String _searchQuery = '';
  final GlobalKey _headerKey = GlobalKey();
  double _headerHeight = 72;

  @override
  bool get wantKeepAlive => true;

  AsmrCategoryType get _currentCategory =>
      _asmrCategories[_tabController.index].type;

  double get _headerControlsFullHeight => 86.0;

  @override
  void initState() {
    super.initState();
    _tabController.addListener(_handleTabChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final asmrController = context.read<AsmrLibraryController>();
      _scrollToTopTabListenable = context
          .read<AudioProvider>()
          .scrollToTopTabListenable;
      _scrollToTopTabListenable?.addListener(_handleScrollToTopSignal);
      _measureHeader();
      unawaited(
        asmrController.initialize().then((_) {
          if (!mounted) {
            return;
          }
          unawaited(_ensureCategoryLoaded(_currentCategory));
        }),
      );
    });
  }

  void _handleCategoryScroll(AsmrCategoryType category) {
    final controller = _scrollControllers[category];
    if (controller == null || !controller.hasClients) {
      return;
    }
    if (controller.position.extentAfter > 280) {
      return;
    }
    unawaited(
      context.read<AsmrLibraryController>().loadMoreCategory(
        category,
        searchQuery: _searchQuery,
      ),
    );
  }

  void _handleTabChanged() {
    if (!mounted || _tabController.indexIsChanging) {
      return;
    }
    setState(() {});
    unawaited(_ensureCategoryLoaded(_currentCategory));
  }

  void _measureHeader() {
    final box = _headerKey.currentContext?.findRenderObject() as RenderBox?;
    if (box != null && mounted) {
      final h = box.size.height - _headerControlsFullHeight;
      if (h > 0 && h != _headerHeight) {
        setState(() => _headerHeight = h);
      }
    }
  }

  void _handleScrollToTopSignal() {
    if (!mounted || _scrollToTopTabListenable?.value != 0) {
      return;
    }
    final controller = _scrollControllers[_currentCategory];
    if (controller == null || !controller.hasClients) {
      return;
    }
    controller.animateTo(
      0,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _ensureCategoryLoaded(AsmrCategoryType category) async {
    final controller = context.read<AsmrLibraryController>();
    final needsRefresh =
        controller.worksFor(category).isEmpty ||
        controller.activeQueryFor(category) != _searchQuery;
    if (!needsRefresh) {
      return;
    }
    await controller.refreshCategory(category, searchQuery: _searchQuery);
  }

  Future<void> _refreshCurrentCategory() {
    return context.read<AsmrLibraryController>().refreshCategory(
      _currentCategory,
      searchQuery: _searchQuery,
    );
  }

  Future<void> _refreshCategoryWithFeedback(AsmrCategoryType category) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final asmrBlue = isDark ? const Color(0xFF60A5FA) : const Color(0xFF1D4ED8);
    final controller = context.read<AsmrLibraryController>();
    final i18n = context.read<AppLanguageProvider>();
    final beforeIds = controller
        .filteredWorksFor(category, searchQuery: _searchQuery)
        .map((work) => work.id)
        .toList(growable: false);

    await controller.refreshCategory(category, searchQuery: _searchQuery);
    if (!mounted) {
      return;
    }

    if (controller.lastError != null) {
      showAppSnackBar(
        context,
        i18n.tr('asmr_refresh_failed'),
        tone: AppFeedbackTone.warning,
        icon: Icons.sync_problem_rounded,
        iconColor: asmrBlue,
      );
      return;
    }

    final afterIds = controller
        .filteredWorksFor(category, searchQuery: _searchQuery)
        .map((work) => work.id)
        .toList(growable: false);
    final hasUpdates = !listEquals(beforeIds, afterIds);
    showAppSnackBar(
      context,
      i18n.tr(
        hasUpdates ? 'asmr_refresh_done_updated' : 'asmr_refresh_no_updates',
      ),
      tone: hasUpdates ? AppFeedbackTone.success : AppFeedbackTone.info,
      icon: hasUpdates
          ? Icons.sync_rounded
          : Icons.check_circle_outline_rounded,
      iconColor: asmrBlue,
    );
  }

  void _onSearchChanged(String value) {
    _searchDebounceTimer?.cancel();
    _searchDebounceTimer = Timer(const Duration(milliseconds: 240), () {
      if (!mounted) {
        return;
      }
      final nextQuery = value.trim();
      if (_searchQuery == nextQuery) {
        return;
      }
      setState(() {
        _searchQuery = nextQuery;
      });
      final controller = _scrollControllers[_currentCategory];
      if (controller != null && controller.hasClients) {
        controller.jumpTo(0);
      }
      unawaited(_refreshCurrentCategory());
    });
  }

  @override
  void dispose() {
    _scrollToTopTabListenable?.removeListener(_handleScrollToTopSignal);
    _searchDebounceTimer?.cancel();
    _searchController.dispose();
    _tabController
      ..removeListener(_handleTabChanged)
      ..dispose();
    for (final controller in _scrollControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final controller = context.watch<AsmrLibraryController>();
    final downloadManager = context.watch<AsmrDownloadManager>();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final asmrBlue = isDark ? const Color(0xFF60A5FA) : const Color(0xFF1D4ED8);
    final currentCategory = _currentCategory;
    final currentScrollController = _scrollControllers[currentCategory]!;
    final bottomInset = MobileOverlayInset.of(context);
    final headerControlsFullHeight = _headerControlsFullHeight;
    final topTotalHeight = _headerHeight + 4;
    final headerContentHeight = topTotalHeight + headerControlsFullHeight;

    Widget collapsingHeaderControls() {
      return _AsmrCollapsingHeaderControls(
        controller: currentScrollController,
        height: headerControlsFullHeight,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 42,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 1, 12, 7),
                child: Row(
                  children: [
                    for (var index = 0; index < _asmrCategories.length; index++)
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(left: index == 0 ? 0 : 8),
                          child: _AsmrCategoryButton(
                            label: _asmrCategories[index].label,
                            selected: _tabController.index == index,
                            onTap: () {
                              if (_tabController.index == index) {
                                return;
                              }
                              FocusScope.of(context).unfocus();
                              _tabController.animateTo(index);
                            },
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            _AsmrSearchBar(
              controller: _searchController,
              query: _searchQuery,
              onChanged: _onSearchChanged,
              onClear: () {
                _searchController.clear();
                _searchDebounceTimer?.cancel();
                if (_searchQuery.isEmpty) {
                  return;
                }
                setState(() {
                  _searchQuery = '';
                });
                unawaited(_refreshCurrentCategory());
              },
            ),
          ],
        ),
      );
    }

    return Stack(
      clipBehavior: Clip.none,
      children: [
        controller.initialized
            ? TabBarView(
                controller: _tabController,
                children: [
                  for (final category in _asmrCategories)
                    _AsmrCategoryList(
                      category: category.type,
                      scrollController: _scrollControllers[category.type]!,
                      searchQuery: _searchQuery,
                      topInset: headerContentHeight,
                      bottomInset: bottomInset,
                      onRefresh: () =>
                          _refreshCategoryWithFeedback(category.type),
                    ),
                ],
              )
            : Center(child: CircularProgressIndicator(color: asmrBlue)),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: TopPageHeader(
            key: _headerKey,
            title: 'ASMR.ONE',
            isLoading: !controller.initialized,
            bottomSpacing: 4,
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            additionalChild: collapsingHeaderControls(),
          ),
        ),
        Positioned(
          right: 76,
          bottom: bottomInset + 18,
          child: AnimatedBuilder(
            animation: downloadManager,
            builder: (context, _) {
              final task = downloadManager.currentTask;
              final visible = downloadManager.hasLiveTask && task != null;
              final progress = task?.progress;
              return IgnorePointer(
                ignoring: !visible,
                child: AnimatedOpacity(
                  opacity: visible ? 1 : 0,
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  child: AnimatedScale(
                    scale: visible ? 1 : 0.92,
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    child: FloatingActionButton.small(
                      heroTag: 'asmr-one-download-progress',
                      backgroundColor: Theme.of(
                        context,
                      ).colorScheme.secondaryContainer,
                      foregroundColor: Theme.of(
                        context,
                      ).colorScheme.onSecondaryContainer,
                      elevation: 0,
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const AsmrDownloadTaskPage(),
                          ),
                        );
                      },
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          const Icon(Icons.downloading_rounded),
                          if (progress != null)
                            SizedBox(
                              width: 34,
                              height: 34,
                              child: CircularProgressIndicator(
                                value: progress,
                                strokeWidth: 2.4,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSecondaryContainer.withValues(
                                      alpha: 0.78,
                                    ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        Positioned(
          right: 16,
          bottom: bottomInset + 18,
          child: AnimatedBuilder(
            animation: currentScrollController,
            builder: (context, _) {
              final visible =
                  currentScrollController.hasClients &&
                  currentScrollController.offset > 220;
              return IgnorePointer(
                ignoring: !visible,
                child: AnimatedOpacity(
                  opacity: visible ? 1 : 0,
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  child: AnimatedScale(
                    scale: visible ? 1 : 0.92,
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    child: FloatingActionButton.small(
                      heroTag: 'asmr-one-back-to-top',
                      backgroundColor: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHigh,
                      foregroundColor: Theme.of(
                        context,
                      ).colorScheme.onSurfaceVariant,
                      elevation: 0,
                      onPressed: () {
                        if (!currentScrollController.hasClients) {
                          return;
                        }
                        currentScrollController.animateTo(
                          0,
                          duration: const Duration(milliseconds: 320),
                          curve: Curves.easeOutCubic,
                        );
                      },
                      child: const Icon(Icons.arrow_upward_rounded),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _AsmrCollapsingHeaderControls extends StatelessWidget {
  const _AsmrCollapsingHeaderControls({
    required this.controller,
    required this.height,
    required this.child,
  });

  final ScrollController controller;
  final double height;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      child: child,
      builder: (context, child) {
        final offset = controller.positions.length == 1
            ? controller.positions.single.pixels
            : 0.0;
        final hidden = offset.clamp(0.0, height);
        return SizedBox(
          height: height - hidden,
          child: ClipRect(
            child: Transform.translate(
              offset: Offset(0, -hidden),
              child: child,
            ),
          ),
        );
      },
    );
  }
}

class _AsmrSearchBar extends StatelessWidget {
  const _AsmrSearchBar({
    required this.controller,
    required this.query,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
  final String query;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hasText = query.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: SizedBox(
        height: 34,
        child: TextField(
          controller: controller,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 13),
          decoration: InputDecoration(
            filled: true,
            fillColor: cs.surfaceContainerHigh,
            prefixIcon: Icon(
              Icons.search_rounded,
              color: cs.onSurfaceVariant,
              size: 18,
            ),
            suffixIcon: hasText
                ? IconButton(
                    icon: const Icon(Icons.clear_rounded, size: 18),
                    onPressed: onClear,
                    color: cs.onSurfaceVariant,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                  )
                : null,
            hintText: '搜索作品名称、标签、声优、社团、RJ号',
            hintStyle: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(17),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(17),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(17),
              borderSide: BorderSide.none,
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 7,
            ),
            isDense: true,
          ),
          onChanged: onChanged,
        ),
      ),
    );
  }
}

class _AsmrCategoryList extends StatefulWidget {
  const _AsmrCategoryList({
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

class _AsmrCategoryListState extends State<_AsmrCategoryList> {
  final GlobalKey<RefreshIndicatorState> _refreshIndicatorKey =
      GlobalKey<RefreshIndicatorState>();
  bool _refreshTriggeredInCurrentScroll = false;

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AsmrLibraryController>();
    final works = controller.filteredWorksFor(
      widget.category,
      searchQuery: widget.searchQuery,
    );
    final isLoading = controller.isLoadingCategory(widget.category);
    final isLoadingMore = controller.isLoadingMoreCategory(widget.category);
    final hasMore = controller.hasMoreCategory(widget.category);
    final lastError = controller.lastError;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final asmrBlue = isDark ? const Color(0xFF60A5FA) : const Color(0xFF1D4ED8);
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollUpdateNotification &&
            notification.dragDetails != null &&
            notification.metrics.pixels < -68 &&
            !_refreshTriggeredInCurrentScroll) {
          _refreshTriggeredInCurrentScroll = true;
          unawaited(HapticFeedback.mediumImpact());
          _refreshIndicatorKey.currentState?.show();
        } else if (notification is ScrollEndNotification) {
          _refreshTriggeredInCurrentScroll = false;
        }
        return false;
      },
      child: RefreshIndicator(
        key: _refreshIndicatorKey,
        color: asmrBlue,
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
        edgeOffset: widget.topInset,
        displacement: 32,
        triggerMode: RefreshIndicatorTriggerMode.anywhere,
        onRefresh: () async {
          unawaited(HapticFeedback.mediumImpact());
          await widget.onRefresh();
          await Future<void>.delayed(const Duration(milliseconds: 300));
        },
        child: ListView.builder(
          controller: widget.scrollController,
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          padding: EdgeInsets.fromLTRB(
            16,
            widget.topInset + 6,
            16,
            widget.bottomInset + 24,
          ),
          itemCount: works.isEmpty
              ? 1
              : works.length + ((isLoadingMore || hasMore) ? 1 : 0),
          itemBuilder: (context, index) {
            if (works.isEmpty) {
              if (isLoading) {
                return Padding(
                  padding: const EdgeInsets.only(top: 80),
                  child: Center(child: CircularProgressIndicator(color: asmrBlue)),
                );
              }
              return Padding(
                padding: const EdgeInsets.only(top: 80),
                child: Center(
                  child: Text(
                    lastError == null ? '当前分类暂无内容。' : '同步失败，请下拉重试。',
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
                  child: isLoadingMore
                      ? SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.2,
                            color: asmrBlue,
                          ),
                        )
                      : Text(
                          '继续上拉加载更多',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
              );
            }
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _AsmrWorkTreeCard(
                work: works[index],
                searchQuery: widget.searchQuery,
              ),
            );
          },
        ),
      ),
    );
  }
}

class _AsmrCategoryButton extends StatelessWidget {
  const _AsmrCategoryButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final asmrBlue = isDark ? const Color(0xFF60A5FA) : const Color(0xFF1D4ED8);
    final asmrBlueContainer = isDark ? const Color(0xFF1E3A8A) : const Color(0xFFDBEAFE);
    final onAsmrBlueContainer = isDark ? const Color(0xFFBFDBFE) : const Color(0xFF1E40AF);

    return Material(
      color: selected ? asmrBlueContainer : cs.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: selected
              ? asmrBlue.withValues(alpha: 0.45)
              : cs.outlineVariant,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: SizedBox(
          height: 34,
          child: Center(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                color: selected ? onAsmrBlueContainer : cs.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AsmrWorkTreeCard extends StatefulWidget {
  const _AsmrWorkTreeCard({required this.work, required this.searchQuery});

  final AsmrWork work;
  final String searchQuery;

  @override
  State<_AsmrWorkTreeCard> createState() => _AsmrWorkTreeCardState();
}

class _AsmrWorkTreeCardState extends State<_AsmrWorkTreeCard> {
  static const double _rootTileHeight = 160;
  final ExpansibleController _expansionController = ExpansibleController();
  bool _expanded = false;

  Future<void> _playWork(BuildContext context) async {
    final asmrController = context.read<AsmrLibraryController>();
    await asmrController.playWork(context.read<AudioProvider>(), widget.work);
    if (!context.mounted) {
      return;
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final asmrBlue = isDark ? const Color(0xFF60A5FA) : const Color(0xFF1D4ED8);
    showAppSnackBar(
      context,
      '已添加到播放列表：${widget.work.title}',
      tone: AppFeedbackTone.success,
      icon: Icons.add_circle_rounded,
      iconColor: asmrBlue,
    );
  }

  Future<void> _toggleFavorite(BuildContext context) async {
    final controller = context.read<AsmrLibraryController>();
    final i18n = context.read<AppLanguageProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final asmrBlue = isDark ? const Color(0xFF60A5FA) : const Color(0xFF1D4ED8);
    final shouldFavorite = !widget.work.isFavorite;
    unawaited(controller.toggleFavorite(widget.work));
    showAppSnackBar(
      context,
      i18n.tr(shouldFavorite ? 'asmr_favorite_added' : 'asmr_favorite_removed'),
      tone: shouldFavorite ? AppFeedbackTone.success : AppFeedbackTone.warning,
      icon: shouldFavorite
          ? Icons.favorite_rounded
          : Icons.favorite_border_rounded,
      iconColor: asmrBlue,
    );
  }

  Future<void> _openDownloadPage(BuildContext context) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AsmrDownloadPage(work: widget.work),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final asmrController = context.watch<AsmrLibraryController>();
    final tree = asmrController.trackTreeFor(widget.work.id);
    final visibleTree = tree
        ?.where((node) => node.hasBrowsableContent)
        .toList(growable: false);
    final isTreeLoading = asmrController.isTrackTreeLoading(widget.work.id);
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final asmrBlue = isDark ? const Color(0xFF60A5FA) : const Color(0xFF1D4ED8);
    final cardShape = RoundedRectangleBorder(
      side: BorderSide(color: cs.outlineVariant),
      borderRadius: BorderRadius.circular(14),
    );

    return SwipeRevealCard(
      shape: cardShape,
      actionLabel: '详细信息',
      removeTooltip: '查看作品详细信息',
      primaryActionTooltip: '详细信息',
      primaryActionIcon: Icons.info_outline_rounded,
      destructive: false,
      secondaryActionLabel: widget.work.isFavorite ? '取消收藏' : '收藏',
      secondaryActionTooltip: widget.work.isFavorite ? '取消收藏' : '加入收藏',
      secondaryActionIcon: widget.work.isFavorite
          ? Icons.favorite_rounded
          : Icons.favorite_border_rounded,
      tertiaryActionLabel: '涓嬭浇',
      tertiaryActionTooltip: '涓嬭浇浣滃搧',
      verticalActions: true,
      onTertiaryAction: () => unawaited(_openDownloadPage(context)),
      onSecondaryAction: () => unawaited(_toggleFavorite(context)),
      onRemove: () => unawaited(showAsmrWorkDetailSheet(context, widget.work)),
      onWillReveal: _expansionController.collapse,
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: cardShape,
        color: cs.surface,
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            controller: _expansionController,
            minTileHeight: _rootTileHeight,
            onExpansionChanged: (expanded) {
              if (_expanded == expanded) {
                return;
              }
              setState(() {
                _expanded = expanded;
              });
              if (expanded && tree == null && !isTreeLoading) {
                unawaited(
                  context.read<AsmrLibraryController>().ensureTrackTree(
                    widget.work,
                  ),
                );
              }
            },
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            collapsedShape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            showTrailingIcon: false,
            tilePadding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
            childrenPadding: const EdgeInsets.fromLTRB(12, 0, 0, 0),
            title: _AsmrRootCardContent(
              work: widget.work,
              expanded: _expanded,
              hasChildren: (visibleTree?.isNotEmpty ?? false) || isTreeLoading,
              onPlay: () => unawaited(_playWork(context)),
            ),
            children: [
              if (isTreeLoading && visibleTree == null)
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 12),
                  child: Center(
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      color: asmrBlue,
                    ),
                  ),
                )
              else if (visibleTree == null || visibleTree.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 12),
                  child: Text(
                    '当前作品没有可展开的音频树。',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                )
              else
                for (final node in visibleTree)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: _AsmrTrackTreeNode(
                      work: widget.work,
                      node: node,
                      searchQuery: widget.searchQuery,
                    ),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AsmrRootCardContent extends StatelessWidget {
  const _AsmrRootCardContent({
    required this.work,
    required this.expanded,
    required this.hasChildren,
    required this.onPlay,
  });

  final AsmrWork work;
  final bool expanded;
  final bool hasChildren;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final asmrBlue = isDark ? const Color(0xFF60A5FA) : const Color(0xFF1D4ED8);
    return LibraryLikeFeaturedCardContent(
      title: work.title,
      lines: _workInfoLines(work),
      coverBuilder: (coverWidth) => _AsmrWorkCover(
        url: work.mainCoverUrl.isNotEmpty ? work.mainCoverUrl : work.coverUrl,
        width: coverWidth,
      ),
      onPlay: onPlay,
      expanded: expanded,
      showExpandIndicator: hasChildren,
      playTooltip: '添加到播放列表',
      accentColor: asmrBlue,
    );
  }
}

class _AsmrTrackTreeNode extends StatefulWidget {
  const _AsmrTrackTreeNode({
    required this.work,
    required this.node,
    required this.searchQuery,
  });

  final AsmrWork work;
  final AsmrTrackFile node;
  final String searchQuery;

  @override
  State<_AsmrTrackTreeNode> createState() => _AsmrTrackTreeNodeState();
}

class _AsmrTrackTreeNodeState extends State<_AsmrTrackTreeNode> {
  static const double _childFolderTileHeight = 62;
  static const double _childFolderTitleBlockHeight = 50;
  final ExpansibleController _expansionController = ExpansibleController();
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    if (widget.node.isFolder) {
      final visibleChildren = widget.node.children
          .where((child) => child.hasBrowsableContent)
          .toList(growable: false);
      final cs = Theme.of(context).colorScheme;
      final isDark = Theme.of(context).brightness == Brightness.dark;
      final asmrBlue = isDark ? const Color(0xFF60A5FA) : const Color(0xFF1D4ED8);
      return Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          controller: _expansionController,
          minTileHeight: _childFolderTileHeight,
          onExpansionChanged: (expanded) {
            if (_expanded == expanded) {
              return;
            }
            setState(() {
              _expanded = expanded;
            });
          },
          shape: const RoundedRectangleBorder(),
          collapsedShape: const RoundedRectangleBorder(),
          showTrailingIcon: false,
          tilePadding: const EdgeInsets.fromLTRB(6, 2, 4, 2),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 0, 0),
          title: Row(
            children: [
              Icon(
                _expanded ? Icons.folder_open_rounded : Icons.folder_rounded,
                size: 20,
                color: asmrBlue.withValues(alpha: 0.8),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SizedBox(
                  height: _childFolderTitleBlockHeight,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.node.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                              height: 1.06,
                              color: cs.onSurface.withValues(alpha: 0.9),
                            ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          trailing: SizedBox(
            width: 62,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                IconButton(
                  onPressed: () => unawaited(_playFolder(context)),
                  visualDensity: VisualDensity.compact,
                  tooltip: '添加到播放列表',
                  style: IconButton.styleFrom(
                    foregroundColor: asmrBlue,
                    minimumSize: const Size(40, 44),
                    maximumSize: const Size(40, 44),
                    padding: EdgeInsets.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: const Icon(Icons.add_circle_rounded, size: 25),
                ),
                const SizedBox(width: 2),
                if (visibleChildren.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: IgnorePointer(
                      child: AnimatedRotation(
                        turns: _expanded ? 0.5 : 0,
                        duration: const Duration(milliseconds: 180),
                        curve: Curves.easeOutCubic,
                        child: Icon(
                          Icons.expand_more_rounded,
                          color: cs.onSurfaceVariant,
                          size: 20,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          children: [
            for (final child in visibleChildren)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: _AsmrTrackTreeNode(
                  work: widget.work,
                  node: child,
                  searchQuery: widget.searchQuery,
                ),
              ),
          ],
        ),
      );
    }
    return _AsmrTrackLeafRow(work: widget.work, node: widget.node);
  }

  Future<void> _playFolder(BuildContext context) async {
    final controller = context.read<AsmrLibraryController>();
    final provider = context.read<AudioProvider>();
    final tracks = controller.buildPlayableTracksFromNode(
      widget.work,
      widget.node,
    );
    if (!context.mounted || tracks.isEmpty) {
      return;
    }
    await controller.recordHistory(widget.work);
    await provider.spawnSessionWithQueue(
      tracks,
      autoPlay: true,
      loopMode: tracks.length > 1
          ? SessionLoopMode.folderSequential
          : SessionLoopMode.single,
    );
    if (!context.mounted) {
      return;
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final asmrBlue = isDark ? const Color(0xFF60A5FA) : const Color(0xFF1D4ED8);
    showAppSnackBar(
      context,
      '已添加到播放列表：${widget.node.displayTitle}',
      tone: AppFeedbackTone.success,
      icon: Icons.add_circle_rounded,
      iconColor: asmrBlue,
    );
  }
}

class _AsmrTrackLeafRow extends StatelessWidget {
  const _AsmrTrackLeafRow({required this.work, required this.node});

  final AsmrWork work;
  final AsmrTrackFile node;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final asmrBlue = isDark ? const Color(0xFF60A5FA) : const Color(0xFF1D4ED8);
    return SizedBox(
      height: 48,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
        child: Row(
          children: [
            Icon(
              Icons.audio_file_rounded,
              size: 16,
              color: cs.onSurfaceVariant.withValues(alpha: 0.6),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                node.displayTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                  color: cs.onSurface,
                ),
              ),
            ),
            Text(
              _formatDuration(node.duration),
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: cs.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              onPressed: () => unawaited(_playTrack(context)),
              style: IconButton.styleFrom(
                foregroundColor: asmrBlue,
                minimumSize: const Size(36, 36),
                maximumSize: const Size(36, 36),
                padding: EdgeInsets.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              icon: const Icon(Icons.add_circle_rounded, size: 22),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _playTrack(BuildContext context) async {
    await context.read<AsmrLibraryController>().playTrack(
      context.read<AudioProvider>(),
      work,
      node,
    );
    if (!context.mounted) {
      return;
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final asmrBlue = isDark ? const Color(0xFF60A5FA) : const Color(0xFF1D4ED8);
    showAppSnackBar(
      context,
      '已添加到播放列表：${node.displayTitle}',
      tone: AppFeedbackTone.success,
      icon: Icons.add_circle_rounded,
      iconColor: asmrBlue,
    );
  }
}

class _AsmrWorkCover extends StatelessWidget {
  const _AsmrWorkCover({required this.url, required this.width});

  final String url;
  final double width;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final height = width * 0.8;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: width,
        height: height,
        child: url.trim().isEmpty
            ? _AsmrCoverFallback(colorScheme: cs)
            : Image.network(
                url,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _AsmrCoverFallback(colorScheme: cs),
              ),
      ),
    );
  }
}

class _AsmrCoverFallback extends StatelessWidget {
  const _AsmrCoverFallback({required this.colorScheme});

  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colorScheme.primaryContainer,
            colorScheme.secondaryContainer.withValues(alpha: 0.92),
          ],
        ),
      ),
      child: Icon(
        Icons.photo_album_rounded,
        color: colorScheme.onPrimaryContainer,
        size: 28,
      ),
    );
  }
}

class _AsmrCategorySpec {
  const _AsmrCategorySpec(this.type, this.label);

  final AsmrCategoryType type;
  final String label;
}

List<LibraryLikeInfoLineData> _workInfoLines(AsmrWork work) {
  return <LibraryLikeInfoLineData>[
    if (work.rjCode.trim().isNotEmpty)
      LibraryLikeInfoLineData('RJ', work.rjCode),
    if (work.voiceActors.isNotEmpty)
      LibraryLikeInfoLineData('CV', work.voiceActors.join('、')),
    if (work.circleName.trim().isNotEmpty)
      LibraryLikeInfoLineData('社团', work.circleName.trim()),
    if (work.tags.isNotEmpty)
      LibraryLikeInfoLineData(
        '标签',
        work.tags.join('、'),
        lines: shouldReserveTwoLibraryLikeInfoLines(work.tags.join('、'))
            ? 2
            : 1,
      ),
  ];
}

String _formatDuration(Duration value) {
  if (value == Duration.zero) {
    return '--:--';
  }
  final hours = value.inHours;
  final minutes = value.inMinutes.remainder(60);
  final seconds = value.inSeconds.remainder(60);
  if (hours > 0) {
    return '${hours.toString().padLeft(2, '0')}:'
        '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }
  return '${value.inMinutes.toString().padLeft(2, '0')}:'
      '${seconds.toString().padLeft(2, '0')}';
}
