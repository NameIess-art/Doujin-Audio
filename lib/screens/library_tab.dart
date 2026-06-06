import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart' hide Provider;
import 'package:lottie/lottie.dart';

import '../i18n/app_language_provider.dart';
import '../providers/audio_provider.dart';
import '../providers/audio_provider_riverpod.dart';
import '../services/audio_state_services.dart';
import '../services/media_file_support.dart';
import '../services/natural_sort.dart';
import '../services/path_display.dart';
import '../services/path_matcher.dart';
import '../services/platform_channels.dart';
import '../services/ui_interaction_coordinator.dart';
import '../services/library_scanner_service.dart';
import '../widgets/app_feedback.dart';
import '../widgets/async_cover_image.dart';
import '../widgets/confirm_action_dialog.dart';
import '../widgets/content_bound_reorder_area.dart';
import '../widgets/library_like_cards.dart';
import '../widgets/mobile_overlay_inset.dart';
import '../widgets/reorder_auto_scroller.dart';
import '../widgets/reorderable_hold_drag_listener.dart';
import '../widgets/scroll_activity_gate.dart';
import '../widgets/swipe_reveal_card.dart';
import '../widgets/top_page_header.dart';
import '../widgets/unified_popup_menu.dart';
import '../widgets/glass_refresh_indicator.dart';
import 'audio_detail_sheet.dart';
import 'dlsite_metadata_batch_page.dart';
import 'screen_view_models.dart';
import 'video_converter_tab.dart';

part 'library_tab_ui_helpers.dart';
part 'library_tab_empty_scan.dart';
part 'library_tab_tree_widgets.dart';
part 'library_tab_category_widgets.dart';
part 'library_tab_edit.dart';

String _displaySourceName(String sourcePath) {
  return PathDisplay.folderName(sourcePath);
}

String _displayTrackName(String trackPath) {
  return PathDisplay.fileName(trackPath, withoutExtension: true);
}

enum _LibraryMoreAction {
  manageLibraries,
  batchMetadata,
  toggleCardPositionsLocked,
}

class LibraryTab extends ConsumerStatefulWidget {
  const LibraryTab({super.key});

  @override
  ConsumerState<LibraryTab> createState() => _LibraryTabState();
}

class _LibraryTabState extends ConsumerState<LibraryTab>
    with AutomaticKeepAliveClientMixin {
  final _scanner = LibraryScannerService();

  @override
  bool get wantKeepAlive => true;

  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  Timer? _searchDebounceTimer;
  FilteredLibraryTreeResult? _visibleSearchResult;
  String _visibleSearchQuery = '';
  int? _visibleSearchRevision;
  String? _pendingSearchKey;
  AudioLibraryCategoryType _categoryType = AudioLibraryCategoryType.all;
  final Set<String> _selectedTagTerms = <String>{};
  final Set<String> _selectedVoiceActorTerms = <String>{};
  final Set<String> _selectedCircleTerms = <String>{};
  bool _refreshTriggeredInCurrentScroll = false;
  bool _isReordering = false;

  final GlobalKey<GlassRefreshIndicatorState> _refreshIndicatorKey =
      GlobalKey<GlassRefreshIndicatorState>();
  final GlobalKey _headerKey = GlobalKey();
  double _headerHeight = 90;

  final ScrollController _scrollController = ScrollController();
  ValueListenable<int?>? _scrollToTopTabListenable;
  int? _categorySnapshotRequestStructureRevision;
  int? _categorySnapshotRequestDetailRevision;

  double get _headerControlsFullHeight =>
      _categoryType == AudioLibraryCategoryType.all ? 86.0 : 46.0;

  String get _effectiveSearchQuery =>
      _categoryType == AudioLibraryCategoryType.all ? _searchQuery : '';

  void _setLocalState(VoidCallback fn) => setState(fn);

  void _ensureFilteredSearchSnapshot({
    required List<LibraryNode> tree,
    required String query,
    required int structureRevision,
  }) {
    if (query.isEmpty ||
        (_visibleSearchQuery == query &&
            _visibleSearchRevision == structureRevision) ||
        _pendingSearchKey == '$structureRevision|$query') {
      return;
    }
    final requestKey = '$structureRevision|$query';
    _pendingSearchKey = requestKey;
    final request = LibrarySearchSnapshotRequest(
      tree: tree,
      query: query,
      structureRevision: structureRevision,
    );
    final searchFuture = libraryTreeTrackCount(tree) > 200
        ? compute(buildFilteredLibraryTreeSnapshot, request)
        : Future<FilteredLibraryTreeResult>.microtask(
            () => buildFilteredLibraryTreeSnapshot(request),
          );
    unawaited(
      searchFuture.then((result) {
        if (!mounted || _pendingSearchKey != requestKey) return;
        UiInteractionCoordinator.instance.scheduleCommit(
          key: 'library_search',
          priority: 5,
          commit: () {
            if (!mounted || _pendingSearchKey != requestKey) return;
            setState(() {
              _visibleSearchResult = result;
              _visibleSearchQuery = query;
              _visibleSearchRevision = structureRevision;
              _pendingSearchKey = null;
            });
          },
        );
      }),
    );
  }

  Future<void> _openVideoConverterPage() async {
    if (!mounted) return;
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const VideoConverterTab()));
  }

  Future<void> _openLibraryManagementPage() async {
    if (!mounted) return;
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const LibraryManagementPage()));
  }

  Future<void> _openBatchMetadataPage() async {
    if (!mounted) return;
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const DlsiteMetadataBatchPage()));
  }

  Future<void> _scheduleWatchedFoldersRefresh({
    bool silent = false,
    bool forceShowResult = false,
  }) async {
    final i18n = context.read<AppLanguageProvider>();
    final provider = context.read<AudioProvider>();
    if (provider.isScanning && !silent) {
      showAppSnackBar(context, i18n.tr('scanning_title'));
      return;
    }
    await _scanner.refreshWatchedFolders(
      provider: provider,
      i18n: i18n,
      showSnack: (msg) {
        if (mounted) showAppSnackBar(context, msg);
      },
      silent: silent,
      forceShowResult: forceShowResult,
    );
  }

  Future<void> _runLibraryPullRefresh() async {
    await _scheduleWatchedFoldersRefresh(silent: true, forceShowResult: true);
  }

  Future<void> _addFolder() async {
    final i18n = context.read<AppLanguageProvider>();
    final provider = context.read<AudioProvider>();
    await _scanner.addFolder(
      provider: provider,
      i18n: i18n,
      showSnack: (msg) {
        if (mounted) showAppSnackBar(context, msg);
      },
    );
  }

  Future<void> _addLibrary() async {
    final i18n = context.read<AppLanguageProvider>();
    final provider = context.read<AudioProvider>();
    await _scanner.addLibrary(
      provider: provider,
      i18n: i18n,
      showSnack: (msg) {
        if (mounted) showAppSnackBar(context, msg);
      },
    );
  }

  Future<void> _addFiles() async {
    final i18n = context.read<AppLanguageProvider>();
    final provider = context.read<AudioProvider>();
    await _scanner.addFiles(
      provider: provider,
      i18n: i18n,
      showSnack: (msg) {
        if (mounted) showAppSnackBar(context, msg);
      },
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_scheduleWatchedFoldersRefresh(silent: true));
        _measureHeader();
        _scrollToTopTabListenable = ref
            .read(audioProviderFacadeProvider)
            .scrollToTopTabListenable;
        _scrollToTopTabListenable?.addListener(_handleScrollToTopSignal);
      }
    });
  }

  void _handleScrollToTopSignal() {
    if (!mounted) return;
    final index = _scrollToTopTabListenable?.value;
    if (index == 1) {
      // 1 is LibraryTab after inserting ASMR.ONE on the left.
      _jumpLibraryListToTop();
    }
  }

  void _jumpLibraryListToTop() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
    );
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

  void _ensureCategorySnapshot({
    required AudioProvider provider,
    required int structureRevision,
    required int detailRevision,
  }) {
    final snapshot = provider.audioLibraryCategorySnapshotSync;
    if (snapshot != null &&
        snapshot.structureRevision == structureRevision &&
        snapshot.detailRevision == detailRevision) {
      return;
    }
    if (_categorySnapshotRequestStructureRevision == structureRevision &&
        _categorySnapshotRequestDetailRevision == detailRevision) {
      return;
    }

    _categorySnapshotRequestStructureRevision = structureRevision;
    _categorySnapshotRequestDetailRevision = detailRevision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        ref
            .read(audioProviderFacadeProvider)
            .audioLibraryCategorySnapshot()
            .whenComplete(() {
              if (!mounted ||
                  _categorySnapshotRequestStructureRevision !=
                      structureRevision ||
                  _categorySnapshotRequestDetailRevision != detailRevision) {
                return;
              }
              _categorySnapshotRequestStructureRevision = null;
              _categorySnapshotRequestDetailRevision = null;
            }),
      );
    });
  }

  @override
  void dispose() {
    _scrollToTopTabListenable?.removeListener(_handleScrollToTopSignal);
    _searchDebounceTimer?.cancel();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final i18n = context.watch<AppLanguageProvider>();
    final provider = ref.read(audioProviderFacadeProvider);
    final libraryUiState = ref.watch(libraryUiProvider);
    final settingsState =
        ref.watch(settingsStateProvider).valueOrNull ?? const SettingsState();
    final cardPositionsLocked = settingsState.cardPositionsLocked;
    final detailRevision = libraryUiState.detailRevision;
    final libraryHeaderState = libraryUiState.header;
    final listState = libraryUiState.list;
    _ensureCategorySnapshot(
      provider: provider,
      structureRevision: listState.structureRevision,
      detailRevision: detailRevision,
    );
    final searchQuery = _effectiveSearchQuery;
    _ensureFilteredSearchSnapshot(
      tree: listState.rawTree,
      query: searchQuery,
      structureRevision: listState.structureRevision,
    );
    final visibleSearchResult =
        _visibleSearchQuery == searchQuery &&
            _visibleSearchRevision == listState.structureRevision
        ? _visibleSearchResult
        : null;
    final tree = searchQuery.isEmpty
        ? listState.rawTree
        : visibleSearchResult?.tree ?? const <LibraryNode>[];
    final matchCount = searchQuery.isEmpty
        ? libraryHeaderState.audioCount
        : visibleSearchResult?.matchCount ?? 0;
    final showSearchSkeleton =
        searchQuery.isNotEmpty && visibleSearchResult == null;
    final bottomInset = MobileOverlayInset.of(context);

    final headerControlsFullHeight = _headerControlsFullHeight;
    final topTotalHeight = _headerHeight + 4;
    final headerContentHeight = topTotalHeight + headerControlsFullHeight;
    // Remove the extra 96px to make content flush with the bottom dock.
    final listBottomInset = bottomInset;
    final isWindows =
        Platform.isWindows ||
        MediaQuery.orientationOf(context) == Orientation.landscape;
    const double expansion = 320.0;
    final listTopPadding = 4 + headerControlsFullHeight + expansion;
    const listBottomPadding = 16.0 + expansion;
    final listViewportBottomInset = listBottomInset + (isWindows ? 16.0 : 0.0);
    // Reduced cacheExtent to significantly lower memory footprint and improve
    // scroll/swipe performance.
    final listCacheExtent = (headerContentHeight + 800)
        .clamp(headerContentHeight, 1600.0)
        .toDouble();
    final hasLibrary = listState.hasLibrary;
    final showLibrarySkeleton =
        !hasLibrary &&
        _effectiveSearchQuery.isEmpty &&
        listState.isScanning &&
        libraryHeaderState.hasWatchedSources;
    final canPullRefresh = listState.canPullRefresh;
    Widget dynamicSearchBar() {
      return _CollapsingSearchBar(
        controller: _scrollController,
        height: headerControlsFullHeight,
        pinned: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildLibraryCategoryTabs(i18n),
            if (_categoryType == AudioLibraryCategoryType.all)
              _buildSearchBar(i18n, matchCount, libraryHeaderState.audioCount),
          ],
        ),
      );
    }

    Widget buildLibraryItem(BuildContext context, int index) {
      if (index == tree.length) {
        return const SizedBox.shrink(key: ValueKey('bottom_spacing_search'));
      }
      final node = tree[index];
      final item = RepaintBoundary(
        child: _effectiveSearchQuery.isNotEmpty
            ? _LibraryTreeItem(
                key: ValueKey(node.path),
                node: node,
                initiallyExpanded: true,
                searchQuery: _effectiveSearchQuery,
              )
            : _LibraryTreeItem(key: ValueKey(node.path), node: node),
      );

      return KeyedSubtree(key: ValueKey(node.path), child: item);
    }

    Widget emptyListBody() {
      final relativeTop = listTopPadding;
      const relativeBottom = listBottomPadding;

      if (showSearchSkeleton) {
        return _LibraryLoadingSkeleton(
          bottomInset: relativeBottom,
          topInset: relativeTop,
        );
      }
      if (_effectiveSearchQuery.isNotEmpty) {
        return ListView(
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          padding: EdgeInsets.fromLTRB(
            16,
            relativeTop,
            16,
            relativeBottom + 12,
          ),
          children: [
            SizedBox(
              height: 260,
              child: Center(
                child: Text(
                  hasLibrary
                      ? i18n.tr('no_search_results')
                      : i18n.tr('no_audio_files'),
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ],
        );
      }
      if (showLibrarySkeleton) {
        return _LibraryLoadingSkeleton(
          bottomInset: relativeBottom,
          topInset: relativeTop,
        );
      }
      return _LibraryEmptyState(
        onImportLibrary: _addLibrary,
        onImportFolder: _addFolder,
        onImportFile: _addFiles,
        bottomInset: relativeBottom,
        topInset: relativeTop,
        physics: canPullRefresh
            ? const AlwaysScrollableScrollPhysics(
                parent: BouncingScrollPhysics(),
              )
            : const BouncingScrollPhysics(),
      );
    }

    Widget refreshableEmptyBody() {
      final body = emptyListBody();
      if (!canPullRefresh) return body;
      return GlassRefreshIndicator(
        key: _refreshIndicatorKey,
        color: Theme.of(context).colorScheme.primary,
        backgroundColor: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
        onRefresh: _runLibraryPullRefresh,
        // Adjust edgeOffset because RefreshIndicator is now inside the restricted Positioned.
        edgeOffset: listTopPadding,
        displacement: 32,
        triggerMode: GlassRefreshIndicatorTriggerMode.anywhere,
        child: body,
      );
    }

    return ScrollActivityGate(
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification is ScrollUpdateNotification &&
              notification.dragDetails != null &&
              notification.metrics.pixels < -68 &&
              !_refreshTriggeredInCurrentScroll &&
              canPullRefresh &&
              !listState.isScanning &&
              _effectiveSearchQuery.isEmpty) {
            _refreshTriggeredInCurrentScroll = true;
            unawaited(HapticFeedback.mediumImpact());
            _refreshIndicatorKey.currentState?.show();
          } else if (notification is ScrollEndNotification) {
            _refreshTriggeredInCurrentScroll = false;
          }
          return false;
        },
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // Viewport restricted to content area so drag-to-reorder auto-scroll
            // triggers at content edges rather than screen edges.
            MediaQuery(
              data: MediaQuery.of(context).copyWith(
                padding: EdgeInsets.only(
                  top: headerControlsFullHeight + 4,
                  bottom: listViewportBottomInset,
                  right: 4,
                ),
              ),
              child: ContentBoundReorderArea(
                headerHeight: _headerHeight,
                bottomInset: listViewportBottomInset,
                topExpansion: expansion,
                bottomExpansion: expansion,
                scrollController: _scrollController,
                showScrollbar: isWindows,
                scrollbarMainAxisMargin: isWindows ? 8 : 0,
                child: !listState.isInitialized
                    ? const SizedBox.shrink()
                    : _categoryType == AudioLibraryCategoryType.all &&
                          tree.isEmpty
                    ? refreshableEmptyBody()
                    : _categoryType != AudioLibraryCategoryType.all
                    ? _buildCategoryBody(
                        provider: provider,
                        i18n: i18n,
                        topPadding: listTopPadding,
                        bottomPadding: listBottomPadding,
                        cacheExtent: listCacheExtent,
                        canPullRefresh: canPullRefresh,
                        detailRevision: detailRevision,
                      )
                    : _effectiveSearchQuery.isNotEmpty
                    ? ListView.builder(
                        key: const ValueKey('search_results_list'),
                        controller: _scrollController,
                        padding: EdgeInsets.fromLTRB(
                          16,
                          listTopPadding,
                          16,
                          listBottomPadding,
                        ),
                        cacheExtent: listCacheExtent,
                        clipBehavior: Clip.none,
                        physics: const AlwaysScrollableScrollPhysics(
                          parent: BouncingScrollPhysics(),
                        ),
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        itemCount: tree.length + 1,
                        itemBuilder: buildLibraryItem,
                      )
                    : GlassRefreshIndicator(
                        key: _refreshIndicatorKey,
                        color: Theme.of(context).colorScheme.primary,
                        backgroundColor: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest
                            .withValues(alpha: 0.6),
                        onRefresh: _runLibraryPullRefresh,
                        edgeOffset: listTopPadding,
                        displacement: 32,
                        triggerMode: GlassRefreshIndicatorTriggerMode.anywhere,
                        child: ReorderAutoScroller(
                          scrollController: _scrollController,
                          isDragging: !cardPositionsLocked && _isReordering,
                          contentMarginTop: listTopPadding,
                          contentMarginBottom: listBottomPadding,
                          child: ReorderableListView.builder(
                            scrollController: _scrollController,
                            // Clip.none allows items to be visible when scrolled into the
                            // "empty" space above/below the restricted Positioned area.
                            clipBehavior: Clip.none,
                            padding: EdgeInsets.fromLTRB(
                              16,
                              listTopPadding,
                              16,
                              listBottomPadding,
                            ),
                            cacheExtent: listCacheExtent,
                            physics: canPullRefresh
                                ? const AlwaysScrollableScrollPhysics(
                                    parent: BouncingScrollPhysics(),
                                  )
                                : null,
                            buildDefaultDragHandles: false,
                            keyboardDismissBehavior:
                                ScrollViewKeyboardDismissBehavior.onDrag,
                            onReorder: (oldIndex, newIndex) {
                              if (cardPositionsLocked) return;
                              setState(() => _isReordering = false);
                              provider.reorderLibraryNodes(oldIndex, newIndex);
                            },
                            onReorderStart: (index) {
                              if (cardPositionsLocked) return;
                              setState(() => _isReordering = true);
                              unawaited(HapticFeedback.heavyImpact());
                            },
                            onReorderEnd: (_) {
                              if (_isReordering) {
                                setState(() => _isReordering = false);
                              }
                            },
                            proxyDecorator: (child, index, animation) =>
                                _buildReorderProxy(context, child, animation),
                            itemCount: tree.length + 1,
                            itemBuilder: (context, index) {
                              if (index == tree.length) {
                                return const SizedBox.shrink(
                                  key: ValueKey('bottom_spacing'),
                                );
                              }
                              final node = tree[index];
                              final child = RepaintBoundary(
                                child: _LibraryTreeItem(node: node),
                              );
                              if (cardPositionsLocked) {
                                return KeyedSubtree(
                                  key: ValueKey(node.path),
                                  child: child,
                                );
                              }
                              return ReorderableHoldDragStartListener(
                                key: ValueKey(node.path),
                                index: index,
                                child: child,
                              );
                            },
                          ),
                        ),
                      ),
              ),
            ),

            // Scan progress card
            if (listState.isScanning && !listState.isBackgroundScanning)
              Positioned(
                top: headerContentHeight + 10,
                left: 12,
                right: 12,
                child: _buildScanProgressCard(
                  i18n,
                  provider,
                  listState.scanCurrentFolder,
                  listState.scanFoundCount,
                  listState.scanDuplicateCount,
                  listState.scanFailureCount,
                ),
              ),

            // Header — frosted glass overlay on top of the scrolling list
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: TopPageHeader(
                key: _headerKey,
                icon: Icons.library_music_rounded,
                title: i18n.tr('music_library'),
                isLoading: !libraryHeaderState.isInitialized,
                subtitle: i18n.tr('audio_count', {
                  'count': libraryHeaderState.audioCount,
                }),
                subtitleFontSize: 11,
                fitSubtitleToWidth: true,
                trailing: SizedBox(
                  width: 104 + (isWindows ? 52 : 0),
                  height: 44,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      if (isWindows)
                        IconButton(
                          onPressed: canPullRefresh
                              ? () => unawaited(_runLibraryPullRefresh())
                              : null,
                          icon: const Icon(Icons.refresh_rounded),
                          tooltip: i18n.tr('refresh_watched_folder'),
                        ),
                      UnifiedPopupMenuButton<int>(
                        icon: Icons.add_circle_outline_rounded,
                        tooltip: i18n.tr('import_audio'),
                        entries: [
                          UnifiedMenuEntry<int>.action(
                            value: 0,
                            icon: Icons.create_new_folder_rounded,
                            label: i18n.tr('import_folder'),
                          ),
                          UnifiedMenuEntry<int>.action(
                            value: 2,
                            icon: Icons.upload_file_rounded,
                            label: i18n.tr('import_file'),
                          ),
                          UnifiedMenuEntry<int>.action(
                            value: 1,
                            icon: Icons.library_add_rounded,
                            label: i18n.tr('choose_library'),
                          ),
                          const UnifiedMenuEntry<int>.divider(),
                          UnifiedMenuEntry<int>.action(
                            value: 3,
                            icon: Icons.video_library_rounded,
                            label: i18n.tr('video_to_audio'),
                          ),
                        ],
                        onSelected: (value) {
                          if (value == 0) _addFolder();
                          if (value == 1) _addLibrary();
                          if (value == 2) _addFiles();
                          if (value == 3) _openVideoConverterPage();
                        },
                      ),
                      UnifiedPopupMenuButton<_LibraryMoreAction>(
                        icon: Icons.more_horiz_rounded,
                        tooltip: i18n.tr('more_actions'),
                        entries: [
                          UnifiedMenuEntry<_LibraryMoreAction>.action(
                            value: _LibraryMoreAction.manageLibraries,
                            icon: Icons.edit_note_rounded,
                            label: i18n.tr('edit_library'),
                          ),
                          UnifiedMenuEntry<_LibraryMoreAction>.action(
                            value: _LibraryMoreAction.batchMetadata,
                            icon: Icons.library_add_check_rounded,
                            label: i18n.tr('batch_metadata'),
                          ),
                          const UnifiedMenuEntry<_LibraryMoreAction>.divider(),
                          UnifiedMenuEntry<_LibraryMoreAction>.action(
                            value: _LibraryMoreAction.toggleCardPositionsLocked,
                            icon: Icons.push_pin_rounded,
                            label: i18n.tr('fixed_card_positions'),
                            trailing: cardPositionsLocked
                                ? const Icon(Icons.check_rounded, size: 18)
                                : null,
                          ),
                        ],
                        onSelected: (value) {
                          switch (value) {
                            case _LibraryMoreAction.manageLibraries:
                              _openLibraryManagementPage();
                              break;
                            case _LibraryMoreAction.batchMetadata:
                              _openBatchMetadataPage();
                              break;
                            case _LibraryMoreAction.toggleCardPositionsLocked:
                              unawaited(
                                provider.setCardPositionsLocked(
                                  !cardPositionsLocked,
                                ),
                              );
                              break;
                          }
                        },
                      ),
                    ],
                  ),
                ),
                bottomSpacing: 4,
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                additionalChild: dynamicSearchBar(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CollapsingSearchBar extends StatelessWidget {
  const _CollapsingSearchBar({
    required this.controller,
    required this.height,
    required this.pinned,
    required this.child,
  });

  final ScrollController controller;
  final double height;
  final bool pinned;
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
        final hidden = pinned ? 0.0 : offset.clamp(0.0, height);
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

class _LibraryLoadingSkeleton extends StatelessWidget {
  const _LibraryLoadingSkeleton({
    required this.bottomInset,
    required this.topInset,
  });

  final double bottomInset;
  final double topInset;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    Widget block({
      required double height,
      double radius = 14,
      EdgeInsets margin = EdgeInsets.zero,
    }) {
      return Padding(
        padding: margin,
        child: PulsingPlaceholder(
          borderRadius: BorderRadius.circular(radius),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: cs.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(radius),
            ),
            child: SizedBox(height: height),
          ),
        ),
      );
    }

    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(16, topInset, 16, bottomInset),
      children: [
        block(height: 82, margin: const EdgeInsets.only(bottom: 8)),
        block(height: 70, margin: const EdgeInsets.only(bottom: 8)),
        block(height: 54, margin: const EdgeInsets.only(bottom: 6)),
        block(height: 54, margin: const EdgeInsets.only(bottom: 6)),
        block(height: 62, margin: const EdgeInsets.only(bottom: 8)),
      ],
    );
  }
}

void _showSessionCreatedSnack(BuildContext context, String message) {
  showAppSnackBar(
    context,
    message,
    tone: AppFeedbackTone.success,
    icon: Icons.queue_music_rounded,
  );
}
