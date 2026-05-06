import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../i18n/app_language_provider.dart';
import '../providers/audio_provider.dart';
import '../widgets/app_feedback.dart';
import '../widgets/async_cover_image.dart';
import '../widgets/mobile_overlay_inset.dart';
import '../widgets/reorderable_hold_drag_listener.dart';
import '../widgets/swipe_reveal_card.dart';
import '../widgets/top_page_header.dart';
import 'video_converter_tab.dart';

part 'library_tab_import_actions.dart';
part 'library_tab_folder_imports.dart';
part 'library_tab_ui_helpers.dart';
part 'library_tab_empty_scan.dart';
part 'library_tab_tree_widgets.dart';
part 'library_tab_models.dart';

class LibraryTab extends StatefulWidget {
  const LibraryTab({super.key});

  @override
  State<LibraryTab> createState() => _LibraryTabState();
}

class _LibraryTabState extends State<LibraryTab>
    with AutomaticKeepAliveClientMixin {
  static const MethodChannel _fileCacheChannel = MethodChannel(
    'music_player/file_cache',
  );

  @override
  bool get wantKeepAlive => true;

  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  Timer? _searchDebounceTimer;
  List<LibraryNode>? _cachedFilteredTree;
  List<LibraryNode>? _cachedFilterRawTree;
  String _cachedFilterQuery = '';

  final GlobalKey _headerKey = GlobalKey();
  double _headerHeight = 72;

  final ScrollController _scrollController = ScrollController();

  void _setLocalState(VoidCallback fn) => setState(fn);

  Future<void> _openVideoConverterPage() async {
    if (!mounted) return;
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const VideoConverterTab()));
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _refreshWatchedFolders(silent: true);
        _measureHeader();
      }
    });
  }

  void _measureHeader() {
    final box = _headerKey.currentContext?.findRenderObject() as RenderBox?;
    if (box != null && mounted) {
      const double searchBarFullHeight = 44.0;
      final h = box.size.height - searchBarFullHeight;
      if (h > 0 && h != _headerHeight) {
        setState(() => _headerHeight = h);
      }
    }
  }

  @override
  void dispose() {
    _searchDebounceTimer?.cancel();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final i18n = context.watch<AppLanguageProvider>();
    final provider = context.read<AudioProvider>();
    final rawTree = context.select<AudioProvider, List<LibraryNode>>(
      (p) => p.libraryTree,
    );
    final audioCount = context.select<AudioProvider, int>(
      (p) => p.libraryTrackCount,
    );
    final watchedFolderCount = context.select<AudioProvider, int>(
      (p) => p.watchedFolderCount,
    );
    final watchedLibraryCount = context.select<AudioProvider, int>(
      (p) => p.watchedLibraryCount,
    );
    final isScanning = context.select<AudioProvider, bool>((p) => p.isScanning);
    final scanFolder = context.select<AudioProvider, String>(
      (p) => p.scanCurrentFolder,
    );
    final scanFound = context.select<AudioProvider, int>(
      (p) => p.scanFoundCount,
    );
    final scanDup = context.select<AudioProvider, int>(
      (p) => p.scanDuplicateCount,
    );
    final scanFail = context.select<AudioProvider, int>(
      (p) => p.scanFailureCount,
    );
    final tree = _filterTreeCached(rawTree, _searchQuery);
    final matchCount = _countTrackNodes(tree);
    final bottomInset = MobileOverlayInset.of(context);

    const double searchBarFullHeight = 44.0;
    final topTotalHeight = _headerHeight + 4;
    final hasLibrary = rawTree.isNotEmpty;
    final showLibrarySkeleton =
        !hasLibrary &&
        _searchQuery.isEmpty &&
        isScanning &&
        (watchedFolderCount > 0 || watchedLibraryCount > 0);
    final canReorder = _searchQuery.isEmpty;

    Widget dynamicSearchBar() {
      return _CollapsingSearchBar(
        controller: _scrollController,
        height: searchBarFullHeight,
        child: _buildSearchBar(i18n, matchCount, audioCount),
      );
    }

    Widget buildLibraryItem(BuildContext context, int index) {
      final node = tree[index];
      return RepaintBoundary(
        child: _LibraryTreeItem(key: ValueKey(node.path), node: node),
      );
    }

    final headerContentHeight = topTotalHeight + searchBarFullHeight;

    return Stack(
      children: [
        // List content starts at top:0, padded so it scrolls behind the header
        // for the BackdropFilter frosted-glass effect.
        Positioned.fill(
          child: tree.isEmpty
              ? Padding(
                  padding: EdgeInsets.only(top: headerContentHeight),
                  child: _searchQuery.isNotEmpty
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const SizedBox(height: 24),
                              Text(
                                hasLibrary
                                    ? i18n.tr('no_search_results')
                                    : i18n.tr('no_audio_files'),
                                style: Theme.of(context).textTheme.bodyLarge
                                    ?.copyWith(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                    ),
                              ),
                            ],
                          ),
                        )
                      : showLibrarySkeleton
                      ? _LibraryLoadingSkeleton(
                          bottomInset: bottomInset,
                          topInset: headerContentHeight,
                        )
                      : _LibraryEmptyState(
                          onImportLibrary: _addLibrary,
                          onImportFolder: _addFolder,
                          onImportFile: _addFiles,
                          bottomInset: bottomInset,
                        ),
                )
              : RefreshIndicator(
                  onRefresh: () => _refreshWatchedFolders(),
                  edgeOffset: headerContentHeight,
                  displacement: 16,
                  triggerMode: RefreshIndicatorTriggerMode.anywhere,
                  child: canReorder
                      ? ReorderableListView.builder(
                          scrollController: _scrollController,
                          padding: EdgeInsets.fromLTRB(
                            16,
                            headerContentHeight,
                            16,
                            bottomInset,
                          ),
                          cacheExtent: 720,
                          buildDefaultDragHandles: false,
                          autoScrollerVelocityScalar: 24,
                          keyboardDismissBehavior:
                              ScrollViewKeyboardDismissBehavior.onDrag,
                          onReorder: provider.reorderLibraryNodes,
                          onReorderStart: (index) =>
                              HapticFeedback.heavyImpact(),
                          proxyDecorator: (child, index, animation) =>
                              _buildReorderProxy(context, child, animation),
                          itemCount: tree.length,
                          itemBuilder: (context, index) {
                            final node = tree[index];
                            return ReorderableHoldDragStartListener(
                              key: ValueKey(node.path),
                              index: index,
                              child: RepaintBoundary(
                                child: _LibraryTreeItem(node: node),
                              ),
                            );
                          },
                        )
                      : ListView.builder(
                          controller: _scrollController,
                          padding: EdgeInsets.fromLTRB(
                            16,
                            headerContentHeight,
                            16,
                            bottomInset,
                          ),
                          cacheExtent: 960,
                          keyboardDismissBehavior:
                              ScrollViewKeyboardDismissBehavior.onDrag,
                          itemCount: tree.length,
                          itemBuilder: buildLibraryItem,
                        ),
                ),
        ),

        // Scan progress card
        if (isScanning)
          Positioned(
            top: headerContentHeight + 10,
            left: 12,
            right: 12,
            child: _buildScanProgressCard(
              i18n,
              provider,
              scanFolder,
              scanFound,
              scanDup,
              scanFail,
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
            titleSuffix: Text(
              i18n.tr('audio_count', {'count': audioCount}),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
            trailing: SizedBox(
              width: 52,
              height: 44,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  PopupMenuButton<int>(
                    icon: const Icon(Icons.add_circle_outline_rounded),
                    tooltip: i18n.tr('more_actions'),
                    onSelected: (value) {
                      if (value == 0) _addFolder();
                      if (value == 1) _addLibrary();
                      if (value == 2) _addFiles();
                      if (value == 3) _openVideoConverterPage();
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: 0,
                        child: Row(
                          children: [
                            const Icon(
                              Icons.create_new_folder_rounded,
                              size: 20,
                            ),
                            const SizedBox(width: 12),
                            Text(i18n.tr('import_folder')),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 1,
                        child: Row(
                          children: [
                            const Icon(Icons.library_add_rounded, size: 20),
                            const SizedBox(width: 12),
                            Text(i18n.tr('choose_library')),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 2,
                        child: Row(
                          children: [
                            const Icon(Icons.upload_file_rounded, size: 20),
                            const SizedBox(width: 12),
                            Text(i18n.tr('import_file')),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 3,
                        child: Row(
                          children: [
                            const Icon(Icons.video_library_rounded, size: 20),
                            const SizedBox(width: 12),
                            Text(i18n.tr('video_to_audio')),
                          ],
                        ),
                      ),
                    ],
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
    );
  }
}

class _CollapsingSearchBar extends StatelessWidget {
  const _CollapsingSearchBar({
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
        final offset = controller.hasClients ? controller.offset : 0.0;
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
