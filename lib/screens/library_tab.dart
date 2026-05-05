import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';

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
import '../widgets/confirm_action_dialog.dart';
import '../widgets/mobile_overlay_inset.dart';
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
  static const double _searchBarHeight = 46;

  final ScrollController _scrollController = ScrollController();
  double _searchBarOffset =
      0; // 0 is fully visible, -_searchBarHeight is hidden

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
      final h = box.size.height;
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

  bool _onLibraryScrollNotification(ScrollNotification n) {
    if (n is ScrollUpdateNotification) {
      final d = n.scrollDelta ?? 0;
      final pixels = n.metrics.pixels;

      if (pixels <= 0) {
        if (_searchBarOffset != 0) {
          setState(() => _searchBarOffset = 0);
        }
      } else if (d > 0.5) {
        // Scrolling up (content moves up)
        if (_searchBarOffset > -_searchBarHeight) {
          setState(() {
            _searchBarOffset = max(-_searchBarHeight, _searchBarOffset - d);
          });
        }
      } else if (d < -0.5 && pixels < 100) {
        // Scrolling down (content moves down) - only near top
        if (_searchBarOffset < 0) {
          setState(() {
            _searchBarOffset = min(0.0, _searchBarOffset - d);
          });
        }
      }
    }
    return false;
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
    final topTotalHeight = _headerHeight + _searchBarOffset + 4;
    final hasLibrary = rawTree.isNotEmpty;

    return Stack(
      children: [
        // 1. Content Layer (Scrolls behind header)
        Positioned.fill(
          child: tree.isEmpty
              ? (_searchQuery.isNotEmpty
                    ? Center(
                        child: Padding(
                          padding: EdgeInsets.only(top: topTotalHeight),
                          child: Text(
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
                        ),
                      )
                    : Column(
                        children: [
                          SizedBox(height: topTotalHeight),
                          Expanded(
                            child: _LibraryEmptyState(
                              onImportLibrary: _addLibrary,
                              onImportFolder: _addFolder,
                              onImportFile: _addFiles,
                              bottomInset: bottomInset,
                            ),
                          ),
                        ],
                      ))
              : NotificationListener<ScrollNotification>(
                  onNotification: _onLibraryScrollNotification,
                  child: RefreshIndicator(
                    onRefresh: () => _refreshWatchedFolders(),
                    displacement: topTotalHeight + 10,
                    child: ReorderableListView.builder(
                      scrollController: _scrollController,
                      padding: EdgeInsets.fromLTRB(
                        16,
                        topTotalHeight,
                        16,
                        bottomInset,
                      ),
                      cacheExtent: 720,
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      onReorder: (oldIndex, newIndex) {
                        if (_searchQuery.isNotEmpty) return;
                        provider.reorderLibraryNodes(oldIndex, newIndex);
                      },
                      itemCount: tree.length,
                      itemBuilder: (context, index) {
                        final node = tree[index];
                        return ReorderableDelayedDragStartListener(
                          key: ValueKey(node.path),
                          index: index,
                          child: _LibraryTreeItem(node: node),
                        );
                      },
                    ),
                  ),
                ),
        ),

        // Scan progress card
        if (isScanning)
          Positioned(
            top: _headerHeight + 6 + _searchBarHeight + _searchBarOffset + 10,
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

        // 2. Header Layer (Frosted Glass via TopPageHeader)
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
            additionalChild: Container(
              height: _searchBarHeight + _searchBarOffset,
              clipBehavior: Clip.hardEdge,
              decoration: const BoxDecoration(),
              child: OverflowBox(
                alignment: Alignment.topCenter,
                maxHeight: _searchBarHeight,
                minHeight: _searchBarHeight,
                child: Opacity(
                  opacity: (1.0 + (_searchBarOffset / _searchBarHeight)).clamp(
                    0.0,
                    1.0,
                  ),
                  child: _buildSearchBar(i18n, matchCount, audioCount),
                ),
              ),
            ),
          ),
        ),
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
