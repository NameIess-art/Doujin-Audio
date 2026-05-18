import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/asmr_models.dart';
import '../providers/audio_provider.dart';
import '../services/asmr_library_controller.dart';
import '../widgets/app_feedback.dart';
import '../widgets/library_like_cards.dart';
import '../widgets/swipe_reveal_card.dart';
import '../widgets/top_page_header.dart';
import 'asmr_login_sheet.dart';
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

  @override
  bool get wantKeepAlive => true;

  AsmrCategoryType get _currentCategory =>
      _asmrCategories[_tabController.index].type;

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
    unawaited(_ensureCategoryLoaded(_currentCategory));
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
    final authSession = controller.authSession;
    final currentCategory = _currentCategory;
    final currentWorks = controller.filteredWorksFor(
      currentCategory,
      searchQuery: _searchQuery,
    );
    final totalCount = controller.totalCountFor(currentCategory);
    final subtitleParts = <String>[
      authSession.isLoggedIn
          ? '已登录：${authSession.userName ?? '未命名用户'}'
          : '登录后可同步收藏',
      if (_searchQuery.isNotEmpty)
        '搜索“$_searchQuery” ${currentWorks.length}/$totalCount'
      else
        '已显示 ${currentWorks.length}/$totalCount',
    ];

    return Column(
      children: [
        TopPageHeader(
          icon: Icons.podcasts_rounded,
          title: 'ASMR.ONE',
          subtitle: subtitleParts.join(' · '),
          trailing: FilledButton.tonalIcon(
            onPressed: () => showAsmrLoginSheet(context),
            icon: Icon(
              authSession.isLoggedIn
                  ? Icons.verified_user_rounded
                  : Icons.login_rounded,
            ),
            label: const Text('登录'),
          ),
          additionalChild: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
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
              Align(
                alignment: Alignment.centerLeft,
                child: TabBar(
                  controller: _tabController,
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  dividerColor: Colors.transparent,
                  tabs: [
                    for (final category in _asmrCategories)
                      Tab(text: category.label),
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: controller.initialized
              ? TabBarView(
                  controller: _tabController,
                  children: [
                    for (final category in _asmrCategories)
                      _AsmrCategoryList(
                        category: category.type,
                        scrollController: _scrollControllers[category.type]!,
                        searchQuery: _searchQuery,
                      ),
                  ],
                )
              : const Center(child: CircularProgressIndicator()),
        ),
      ],
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
            suffixIcon: query.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear_rounded, size: 18),
                    onPressed: onClear,
                    color: cs.onSurfaceVariant,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                  ),
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

class _AsmrCategoryList extends StatelessWidget {
  const _AsmrCategoryList({
    required this.category,
    required this.scrollController,
    required this.searchQuery,
  });

  final AsmrCategoryType category;
  final ScrollController scrollController;
  final String searchQuery;

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AsmrLibraryController>();
    final works = controller.filteredWorksFor(
      category,
      searchQuery: searchQuery,
    );
    final isLoading = controller.isLoadingCategory(category);
    final isLoadingMore = controller.isLoadingMoreCategory(category);
    final hasMore = controller.hasMoreCategory(category);
    final lastError = controller.lastError;
    final theme = Theme.of(context);

    return RefreshIndicator(
      onRefresh: () => context.read<AsmrLibraryController>().refreshCategory(
        category,
        searchQuery: searchQuery,
      ),
      child: ListView.builder(
        controller: scrollController,
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        itemCount: works.isEmpty
            ? 1
            : works.length + ((isLoadingMore || hasMore) ? 1 : 0),
        itemBuilder: (context, index) {
          if (works.isEmpty) {
            if (isLoading) {
              return const Padding(
                padding: EdgeInsets.only(top: 80),
                child: Center(child: CircularProgressIndicator()),
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
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.2),
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
              searchQuery: searchQuery,
            ),
          );
        },
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
    showAppSnackBar(
      context,
      '已添加到播放列表：${widget.work.title}',
      tone: AppFeedbackTone.success,
      icon: Icons.add_circle_rounded,
    );
  }

  Future<void> _toggleFavorite(BuildContext context) async {
    final controller = context.read<AsmrLibraryController>();
    final shouldFavorite = !widget.work.isFavorite;
    await controller.toggleFavorite(widget.work);
    if (!context.mounted) {
      return;
    }
    showAppSnackBar(
      context,
      shouldFavorite ? '已加入收藏。' : '已取消收藏。',
      tone: shouldFavorite ? AppFeedbackTone.success : AppFeedbackTone.warning,
      icon: shouldFavorite
          ? Icons.favorite_rounded
          : Icons.favorite_border_rounded,
    );
  }

  @override
  Widget build(BuildContext context) {
    final asmrController = context.watch<AsmrLibraryController>();
    final tree = asmrController.trackTreeFor(widget.work.id);
    final isTreeLoading = asmrController.isTrackTreeLoading(widget.work.id);
    final cs = Theme.of(context).colorScheme;
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
      verticalActions: true,
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
              hasChildren: true,
              onPlay: () => unawaited(_playWork(context)),
            ),
            children: [
              if (isTreeLoading && tree == null)
                const Padding(
                  padding: EdgeInsets.only(top: 8, bottom: 12),
                  child: Center(
                    child: CircularProgressIndicator(strokeWidth: 2.2),
                  ),
                )
              else if (tree == null || tree.isEmpty)
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
                for (final node in tree)
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
      final cs = Theme.of(context).colorScheme;
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
                color: cs.primary.withValues(alpha: 0.8),
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
                    foregroundColor: cs.primary,
                    minimumSize: const Size(40, 44),
                    maximumSize: const Size(40, 44),
                    padding: EdgeInsets.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: const Icon(Icons.add_circle_rounded, size: 25),
                ),
                const SizedBox(width: 2),
                if (widget.node.children.isNotEmpty)
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
            for (final child in widget.node.children)
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
    showAppSnackBar(
      context,
      '已添加到播放列表：${widget.node.title}',
      tone: AppFeedbackTone.success,
      icon: Icons.add_circle_rounded,
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
                node.title,
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
                foregroundColor: cs.primary,
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
    showAppSnackBar(
      context,
      '已添加到播放列表：${node.title}',
      tone: AppFeedbackTone.success,
      icon: Icons.add_circle_rounded,
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
      LibraryLikeInfoLineData('CV', work.voiceActors.join('，')),
    if (work.circleName.trim().isNotEmpty)
      LibraryLikeInfoLineData('社团', work.circleName.trim()),
    if (work.tags.isNotEmpty)
      LibraryLikeInfoLineData(
        '标签',
        work.tags.join('，'),
        lines: shouldReserveTwoLibraryLikeInfoLines(work.tags.join('，'))
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
