import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../i18n/app_language_provider.dart';
import '../providers/audio_provider.dart';
import '../providers/audio_provider_riverpod.dart';
import '../services/audio_state_services.dart';
import '../services/media_file_support.dart';
import '../services/natural_sort.dart';
import '../services/path_display.dart';
import '../services/path_matcher.dart';
import '../services/platform_channels.dart';
import '../widgets/app_feedback.dart';
import '../widgets/async_cover_image.dart';
import '../widgets/confirm_action_dialog.dart';
import '../widgets/content_bound_reorder_area.dart';
import '../widgets/marquee_text.dart';
import '../widgets/mobile_overlay_inset.dart';
import '../widgets/reorder_auto_scroller.dart';
import '../widgets/reorderable_hold_drag_listener.dart';
import '../widgets/swipe_reveal_card.dart';
import '../widgets/top_page_header.dart';
import '../widgets/unified_popup_menu.dart';
import '../widgets/waterfall_flow_stagger.dart';
import 'audio_detail_sheet.dart';
import 'screen_view_models.dart';
import 'video_converter_tab.dart';

part 'library_tab_import_actions.dart';
part 'library_tab_folder_imports.dart';
part 'library_tab_ui_helpers.dart';
part 'library_tab_empty_scan.dart';
part 'library_tab_tree_widgets.dart';
part 'library_tab_category_widgets.dart';
part 'library_tab_models.dart';
part 'library_tab_edit.dart';

String _displaySourceName(String sourcePath) {
  return PathDisplay.folderName(sourcePath);
}

String _displayTrackName(String trackPath) {
  return PathDisplay.fileName(trackPath, withoutExtension: true);
}

class LibraryTab extends ConsumerStatefulWidget {
  const LibraryTab({super.key});

  @override
  ConsumerState<LibraryTab> createState() => _LibraryTabState();
}

class _LibraryTabState extends ConsumerState<LibraryTab>
    with AutomaticKeepAliveClientMixin {
  static const MethodChannel _fileCacheChannel = MethodChannel(
    'nameless_audio/file_cache',
  );

  @override
  bool get wantKeepAlive => true;

  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  Timer? _searchDebounceTimer;
  final LibrarySearchIndex _searchIndex = LibrarySearchIndex();
  AudioLibraryCategoryType _categoryType = AudioLibraryCategoryType.all;
  final Set<String> _selectedTagTerms = <String>{};
  final Set<String> _selectedVoiceActorTerms = <String>{};
  final Set<String> _selectedCircleTerms = <String>{};
  bool _refreshTriggeredInCurrentScroll = false;
  bool _isReordering = false;

  final GlobalKey<RefreshIndicatorState> _refreshIndicatorKey =
      GlobalKey<RefreshIndicatorState>();
  final GlobalKey _headerKey = GlobalKey();
  double _headerHeight = 72;

  final ScrollController _scrollController = ScrollController();
  ValueListenable<int?>? _scrollToTopTabListenable;

  double get _headerControlsFullHeight =>
      _categoryType == AudioLibraryCategoryType.all ? 86.0 : 46.0;

  String get _effectiveSearchQuery =>
      _categoryType == AudioLibraryCategoryType.all ? _searchQuery : '';

  void _setLocalState(VoidCallback fn) => setState(fn);

  Future<void> _openVideoConverterPage() async {
    if (!mounted) return;
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const VideoConverterTab()));
  }

  Future<void> _openLibraryEditPage(String libraryPath) async {
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LibraryEditPage(libraryPath: libraryPath),
      ),
    );
  }

  Future<void> _confirmRemoveLibrary(String libraryPath) async {
    final i18n = context.read<AppLanguageProvider>();
    final confirmed = await showConfirmActionDialog(
      context: context,
      title: i18n.tr('remove_library'),
      message: i18n.tr('remove_library_confirm', {
        'name': _displaySourceName(libraryPath),
      }),
      cancelLabel: i18n.tr('cancel'),
      confirmLabel: i18n.tr('remove'),
      icon: Icons.library_music_rounded,
    );
    if (!confirmed || !mounted) return;
    await ref.read(audioProviderFacadeProvider).removeLibrary(libraryPath);
    if (mounted) {
      showAppSnackBar(
        context,
        i18n.tr('library_removed'),
        tone: AppFeedbackTone.destructive,
        icon: Icons.delete_outline_rounded,
      );
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _refreshWatchedFolders(silent: true);
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
    if (index == 0) {
      // 0 is LibraryTab
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
    final detailRevision = context.select<AudioProvider, int>(
      (value) => value.audioDetailRevision,
    );
    unawaited(provider.audioLibraryCategorySnapshot());
    final sliceState =
        ref.watch(libraryStateProvider).valueOrNull ?? const LibraryState();
    final libraryHeaderState = context
        .select<AudioProvider, LibraryHeaderState>(
          (value) => libraryHeaderStateFromSlice(
            LibraryState(
              libraryTrackCount: value.libraryTrackCount,
              watchedFolderCount: value.watchedFolderCount,
              watchedLibraryCount: value.watchedLibraryCount,
              isInitialized: sliceState.isInitialized,
            ),
          ),
        );
    final listState = context.select<AudioProvider, LibraryListState>(
      (value) => LibraryListState(
        rawTree: value.libraryTree,
        watchedLibraries: value.watchedLibraries,
        watchedFolderCount: value.watchedFolderCount,
        watchedLibraryCount: value.watchedLibraryCount,
        isScanning: value.isScanning,
        isBackgroundScanning: value.isBackgroundScanning,
        scanCurrentFolder: value.scanCurrentFolder,
        scanFoundCount: value.scanFoundCount,
        scanDuplicateCount: value.scanDuplicateCount,
        scanFailureCount: value.scanFailureCount,
        structureRevision: sliceState.structureRevision,
        isInitialized: sliceState.isInitialized,
      ),
    );
    final filteredResult = _searchIndex.resolve(
      tree: listState.rawTree,
      query: _effectiveSearchQuery,
      structureRevision: listState.structureRevision,
    );
    final tree = filteredResult.tree;
    final matchCount = filteredResult.matchCount;
    final bottomInset = MobileOverlayInset.of(context);

    final headerControlsFullHeight = _headerControlsFullHeight;
    final topTotalHeight = _headerHeight + 4;
    final headerContentHeight = topTotalHeight + headerControlsFullHeight;
    // Remove the extra 96px to make content flush with the bottom dock.
    final listBottomInset = bottomInset;
    // Reduced cacheExtent to significantly lower memory footprint and improve
    // scroll/swipe performance.
    final listCacheExtent = (headerContentHeight + 400)
        .clamp(headerContentHeight, 720.0)
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

      return WaterfallFlowStagger(
        key: ValueKey('stagger_${node.path}'),
        index: index,
        child: item,
      );
    }

    Widget emptyListBody() {
      // Padding adjustment for restricted Positioned viewport.
      // We expand the Positioned by 80px to pre-render items under the glass,
      // so we add 80px to the internal padding to keep the content visually in place.
      final relativeTop = 150.0 + 4 + headerControlsFullHeight;
      const relativeBottom = 350.0;

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
      return RefreshIndicator(
        key: _refreshIndicatorKey,
        color: Theme.of(context).colorScheme.primary,
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
        onRefresh: () async {
          unawaited(HapticFeedback.mediumImpact());
          await _refreshWatchedFolders();
        },
        // Adjust edgeOffset because RefreshIndicator is now inside the restricted Positioned.
        edgeOffset: 150 + 4 + headerControlsFullHeight,
        displacement: 32,
        triggerMode: RefreshIndicatorTriggerMode.anywhere,
        child: body,
      );
    }

    return NotificationListener<ScrollNotification>(
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
          ContentBoundReorderArea(
            headerHeight: _headerHeight,
            bottomInset: listBottomInset,
            topExpansion: 150,
            bottomExpansion: 350,
            child: !listState.isInitialized
                ? const SizedBox.shrink()
                : _categoryType == AudioLibraryCategoryType.all && tree.isEmpty
                ? refreshableEmptyBody()
                : _categoryType != AudioLibraryCategoryType.all
                ? _buildCategoryBody(
                    provider: provider,
                    i18n: i18n,
                    headerControlsFullHeight: headerControlsFullHeight,
                    bottomInset: listBottomInset,
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
                      4 + headerControlsFullHeight + 150,
                      16,
                      350,
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
                : RefreshIndicator(
                    key: _refreshIndicatorKey,
                    color: Theme.of(context).colorScheme.primary,
                    backgroundColor: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    onRefresh: () async {
                      unawaited(HapticFeedback.mediumImpact());
                      await _refreshWatchedFolders();
                    },
                    edgeOffset: 150 + 4 + headerControlsFullHeight,
                    displacement: 32,
                    triggerMode: RefreshIndicatorTriggerMode.anywhere,
                    child: ReorderAutoScroller(
                      scrollController: _scrollController,
                      isDragging: _isReordering,
                      contentMarginTop: 150 + 4 + headerControlsFullHeight,
                      contentMarginBottom: 350,
                      child: ReorderableListView.builder(
                        scrollController: _scrollController,
                        // Clip.none allows items to be visible when scrolled into the
                        // "empty" space above/below the restricted Positioned area.
                        clipBehavior: Clip.none,
                        padding: EdgeInsets.fromLTRB(
                          16,
                          4 + headerControlsFullHeight + 150,
                          16,
                          350,
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
                          setState(() => _isReordering = false);
                          provider.reorderLibraryNodes(oldIndex, newIndex);
                        },
                        onReorderStart: (index) {
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
                          return WaterfallFlowStagger(
                            key: ValueKey('stagger_${node.path}'),
                            index: index,
                            child: ReorderableHoldDragStartListener(
                              key: ValueKey(node.path),
                              index: index,
                              child: RepaintBoundary(
                                child: _LibraryTreeItem(node: node),
                              ),
                            ),
                          );
                        },
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
              titleSuffix: Text(
                i18n.tr('audio_count', {
                  'count': libraryHeaderState.audioCount,
                }),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
              trailing: SizedBox(
                width: listState.watchedLibraries.isEmpty ? 52 : 104,
                height: 44,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (listState.watchedLibraries.isNotEmpty)
                      UnifiedPopupMenuButton<String>(
                        icon: Icons.edit_note_rounded,
                        tooltip: i18n.tr('edit_library'),
                        menuWidth: 280,
                        entries: listState.watchedLibraries
                            .map(
                              (libraryPath) => UnifiedMenuEntry<String>.action(
                                value: libraryPath,
                                icon: Icons.folder_copy_rounded,
                                label: _displaySourceName(libraryPath),
                                trailingValue: libraryPath,
                                trailing: Icon(
                                  Icons.delete_outline_rounded,
                                  size: 20,
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            )
                            .toList(growable: false),
                        onSelected: _openLibraryEditPage,
                        onTrailingSelected: _confirmRemoveLibrary,
                      ),
                    UnifiedPopupMenuButton<int>(
                      icon: Icons.add_circle_outline_rounded,
                      tooltip: i18n.tr('more_actions'),
                      entries: [
                        UnifiedMenuEntry<int>.action(
                          value: 0,
                          icon: Icons.create_new_folder_rounded,
                          label: i18n.tr('import_folder'),
                        ),
                        UnifiedMenuEntry<int>.action(
                          value: 1,
                          icon: Icons.library_add_rounded,
                          label: i18n.tr('choose_library'),
                        ),
                        UnifiedMenuEntry<int>.action(
                          value: 2,
                          icon: Icons.upload_file_rounded,
                          label: i18n.tr('import_file'),
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
