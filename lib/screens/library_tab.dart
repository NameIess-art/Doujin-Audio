import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart' hide Consumer, Provider;
import 'package:lottie/lottie.dart';

import '../i18n/app_language_provider.dart';
import '../providers/audio_provider.dart';
import '../providers/audio_provider_riverpod.dart';
import '../services/audio_state_services.dart';
import '../services/app_log_service.dart';
import '../services/app_preferences.dart';
import '../services/file_cache_platform_gateway.dart';
import '../services/media_file_support.dart';
import '../services/natural_sort.dart';
import '../services/path_display.dart';
import '../services/path_matcher.dart';
import '../services/ui_interaction_coordinator.dart';
import '../services/ui_operation_service.dart';
import '../theme/app_design_tokens.dart';
import '../services/library_scanner_service.dart';
import '../widgets/app_feedback.dart';
import '../widgets/async_cover_image.dart';
import '../widgets/confirm_action_dialog.dart';
import '../widgets/content_bound_reorder_area.dart';
import '../widgets/library_like_cards.dart';
import '../widgets/mobile_overlay_inset.dart';
import '../widgets/operation_feedback.dart';
import '../widgets/reorder_auto_scroller.dart';
import '../widgets/scroll_activity_gate.dart';
import '../widgets/swipe_reveal_card.dart';
import '../widgets/top_page_header.dart';
import '../widgets/unified_popup_menu.dart';
import '../widgets/glass_refresh_indicator.dart';
import '../widgets/shimmer_loading.dart';
import 'audio_detail_sheet.dart';
import 'dlsite_metadata_batch_page.dart';
import 'screen_view_models.dart';
import 'video_converter_tab.dart';
import '../widgets/app_transitions.dart';
import '../theme/app_styles.dart';
import '../platform/app_platform.dart';

import '../widgets/app_buttons.dart';

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
  final Map<AudioLibraryCategoryType, String> _termSearchQueries = {};
  AudioLibraryCategorySnapshot? _lastCategoryFilterSnapshot;
  AudioLibraryCategoryType? _lastCategoryFilterType;
  String? _lastCategoryFilterKey;
  List<AudioLibraryCategoryEntry> _lastCategoryFilterResult = const [];
  String get _termSearchQuery => _termSearchQueries[_categoryType] ?? '';
  set _termSearchQuery(String value) {
    if (value.isEmpty) {
      _termSearchQueries.remove(_categoryType);
    } else {
      _termSearchQueries[_categoryType] = value;
    }
  }

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
  String? _lastLibraryCoverWarmupSignature;

  double get _headerControlsFullHeight =>
      _categoryType == AudioLibraryCategoryType.all ? 86.0 : 42.0;

  String get _effectiveSearchQuery =>
      _categoryType == AudioLibraryCategoryType.all ? _searchQuery : '';

  void _setLocalState(VoidCallback fn) => setState(fn);

  Future<T> _runLibraryOperation<T>({
    required UiOperationScope scope,
    required String labelKey,
    required Future<T> Function() task,
  }) {
    return ref
        .read(uiOperationServiceProvider)
        .run<T>(
          scope: scope,
          labelKey: labelKey,
          task: (_) => task(),
          cancelPrevious: false,
        );
  }

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
    ).push(buildAppPageRoute<void>(child: const VideoConverterTab()));
  }

  Future<void> _openLibraryManagementPage() async {
    if (!mounted) return;
    await Navigator.of(
      context,
    ).push(buildAppPageRoute<void>(child: const LibraryManagementPage()));
  }

  Future<void> _openBatchMetadataPage() async {
    if (!mounted) return;
    await Navigator.of(
      context,
    ).push(buildAppPageRoute<void>(child: const DlsiteMetadataBatchPage()));
  }

  Future<void> _scheduleWatchedFoldersRefresh({
    bool silent = false,
    bool forceShowResult = false,
  }) async {
    final i18n = context.read<AppLanguageProvider>();
    final provider = context.read<AudioProvider>();
    final operations = ref.read(uiOperationServiceProvider);
    final importBusy = <UiOperationScope>[
      UiOperationScope.libraryRefresh,
      UiOperationScope.libraryImportFolder,
      UiOperationScope.libraryImportLibrary,
      UiOperationScope.libraryImportFiles,
    ].any(operations.isBusy);
    if (provider.isScanning || importBusy) {
      if (!silent) showAppSnackBar(context, i18n.tr('scanning_title'));
      return;
    }
    try {
      await _runLibraryOperation<void>(
        scope: UiOperationScope.libraryRefresh,
        labelKey: 'loading_dot',
        task: () => _scanner.refreshWatchedFolders(
          provider: provider,
          i18n: i18n,
          showSnack: (msg) {
            if (!mounted) return;
            final isFailure =
                msg == i18n.tr('scan_failed_next_step') ||
                msg == i18n.tr('import_failed_next_step');
            final isCancelled = msg == i18n.tr('scan_cancelled');
            showAppSnackBar(
              context,
              msg,
              tone: isFailure
                  ? AppFeedbackTone.destructive
                  : (isCancelled
                        ? AppFeedbackTone.warning
                        : AppFeedbackTone.success),
              icon: isFailure
                  ? Icons.error_outline_rounded
                  : (isCancelled
                        ? Icons.cancel_outlined
                        : Icons.check_circle_outline_rounded),
            );
          },
          silent: silent,
          forceShowResult: forceShowResult,
        ),
      );
    } catch (error, stackTrace) {
      AppLogService.error(
        'library_refresh_failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted || (silent && !forceShowResult)) return;
      _showLibraryFailure(
        messageKey: 'scan_failed_next_step',
        retry: () => _scheduleWatchedFoldersRefresh(
          silent: silent,
          forceShowResult: forceShowResult,
        ),
      );
    }
  }

  Future<void> _runLibraryPullRefresh({bool showSnackbar = false}) async {
    final i18n = context.read<AppLanguageProvider>();
    if (showSnackbar) {
      showAppSnackBar(
        context,
        i18n.tr('loading_dot'),
        icon: Icons.sync_rounded,
        iconColor: Theme.of(context).colorScheme.primary,
      );
    }
    await _scheduleWatchedFoldersRefresh(silent: true, forceShowResult: true);
  }

  Future<void> _runLibraryImportAction({
    required String logEvent,
    required Future<void> Function({
      required AudioProvider provider,
      required AppLanguageProvider i18n,
      required void Function(String) showSnack,
    })
    action,
    required Future<void> Function() retry,
  }) async {
    final i18n = context.read<AppLanguageProvider>();
    final provider = context.read<AudioProvider>();
    try {
      await _runLibraryOperation<void>(
        scope: switch (logEvent) {
          'library_import_files_failed' => UiOperationScope.libraryImportFiles,
          'library_import_library_failed' =>
            UiOperationScope.libraryImportLibrary,
          _ => UiOperationScope.libraryImportFolder,
        },
        labelKey: 'loading_dot',
        task: () => action(
          provider: provider,
          i18n: i18n,
          showSnack: (msg) {
            if (mounted) showAppSnackBar(context, msg);
          },
        ),
      );
    } catch (error, stackTrace) {
      AppLogService.error(logEvent, error: error, stackTrace: stackTrace);
      if (!mounted) return;
      _showLibraryFailure(messageKey: 'import_failed_next_step', retry: retry);
    }
  }

  Future<void> _addFolder() {
    return _runLibraryImportAction(
      logEvent: 'library_import_folder_failed',
      action: _scanner.addFolder,
      retry: _addFolder,
    );
  }

  Future<void> _addLibrary() async {
    return _runLibraryImportAction(
      logEvent: 'library_import_library_failed',
      action: _scanner.addLibrary,
      retry: _addLibrary,
    );
  }

  Future<void> _addFiles() async {
    return _runLibraryImportAction(
      logEvent: 'library_import_files_failed',
      action: _scanner.addFiles,
      retry: _addFiles,
    );
  }

  void _showLibraryFailure({
    required String messageKey,
    required Future<void> Function() retry,
  }) {
    final i18n = context.read<AppLanguageProvider>();
    showAppSnackBar(
      context,
      i18n.tr(messageKey),
      tone: AppFeedbackTone.destructive,
      title: i18n.tr('operation_failed'),
      icon: Icons.error_outline_rounded,
      actionLabel: i18n.tr('retry'),
      onAction: () => unawaited(retry()),
      duration: const Duration(seconds: 6),
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
    const fakeAnimationStartOffset = 360.0;
    final animationStartOffset =
        _scrollController.position.maxScrollExtent < fakeAnimationStartOffset
        ? _scrollController.position.maxScrollExtent
        : fakeAnimationStartOffset;
    if (_scrollController.offset > animationStartOffset) {
      _scrollController.jumpTo(animationStartOffset);
    }
    _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 260),
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

  void _scheduleLibraryCoverWarmup({
    required AudioProvider provider,
    required Iterable<MusicTrack?> tracks,
    required int structureRevision,
    required int detailRevision,
    required int coverGeneration,
    String scope = '',
  }) {
    if (_isReordering) return;
    final warmupTracks = tracks
        .whereType<MusicTrack>()
        .where((track) => !track.isVideo)
        .take(12)
        .toList(growable: false);
    if (warmupTracks.isEmpty) return;
    final signature = <String>[
      scope,
      structureRevision.toString(),
      detailRevision.toString(),
      coverGeneration.toString(),
      for (final track in warmupTracks) track.path,
    ].join('|');
    if (_lastLibraryCoverWarmupSignature == signature) return;
    _lastLibraryCoverWarmupSignature = signature;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _isReordering ||
          _lastLibraryCoverWarmupSignature != signature) {
        return;
      }
      provider.warmupLibraryCoversForTracks(warmupTracks);
    });
  }

  Iterable<MusicTrack?> _libraryCoverWarmupTracksForTree(
    Iterable<LibraryNode> nodes,
  ) sync* {
    for (final node in nodes.take(12)) {
      if (node is TrackNode) {
        yield node.track;
      } else if (node is FolderNode) {
        yield node.firstTrack;
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
    final libraryHeaderAudioCount = ref.watch(
      libraryHeaderUiProvider.select((s) => s.audioCount),
    );
    final libraryHeaderHasWatchedSources = ref.watch(
      libraryHeaderUiProvider.select((s) => s.hasWatchedSources),
    );
    final listStateRawTree = ref.watch(
      libraryListUiProvider.select((s) => s.rawTree),
    );
    final listStateStructureRevision = ref.watch(
      libraryListUiProvider.select((s) => s.structureRevision),
    );
    final listStateIsScanning = ref.watch(
      libraryListUiProvider.select((s) => s.isScanning),
    );
    final listStateIsBackgroundScanning = ref.watch(
      libraryListUiProvider.select((s) => s.isBackgroundScanning),
    );
    final listStateIsInitialized = ref.watch(
      libraryListUiProvider.select((s) => s.isInitialized),
    );
    final listStateHasLibrary = ref.watch(
      libraryListUiProvider.select((s) => s.hasLibrary),
    );
    final listStateCanPullRefresh = ref.watch(
      libraryListUiProvider.select((s) => s.canPullRefresh),
    );
    final detailRevision = ref.watch(libraryDetailRevisionProvider);
    ref.watch(libraryCategoryRevisionProvider);
    final coverGeneration = ref.watch(coverGenerationProvider);
    final settingsState =
        ref.watch(settingsStateProvider).valueOrNull ?? const SettingsState();
    final cardPositionsLocked = settingsState.cardPositionsLocked;
    final libraryRefreshOperationBusy = ref.watch(
      uiOperationForScopeProvider(
        UiOperationScope.libraryRefresh,
      ).select((s) => s.isBusy),
    );
    final libraryImportBusy =
        <UiOperationScope>[
          UiOperationScope.libraryImportFolder,
          UiOperationScope.libraryImportLibrary,
          UiOperationScope.libraryImportFiles,
        ].any(
          (scope) => ref.watch(
            uiOperationForScopeProvider(scope).select((s) => s.isBusy),
          ),
        );
    final libraryRefreshBusy =
        libraryRefreshOperationBusy || libraryImportBusy || listStateIsScanning;
    _ensureCategorySnapshot(
      provider: provider,
      structureRevision: listStateStructureRevision,
      detailRevision: detailRevision,
    );
    final searchQuery = _effectiveSearchQuery;
    _ensureFilteredSearchSnapshot(
      tree: listStateRawTree,
      query: searchQuery,
      structureRevision: listStateStructureRevision,
    );
    final visibleSearchResult =
        _visibleSearchQuery == searchQuery &&
            _visibleSearchRevision == listStateStructureRevision
        ? _visibleSearchResult
        : null;
    final tree = searchQuery.isEmpty
        ? listStateRawTree
        : visibleSearchResult?.tree ?? const <LibraryNode>[];
    final matchCount = searchQuery.isEmpty
        ? libraryHeaderAudioCount
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
    final listTopPadding = headerControlsFullHeight + 4.0 + expansion;
    const listBottomPadding = 16.0 + expansion;
    final listViewportBottomInset = listBottomInset + (isWindows ? 16.0 : 0.0);
    // Reduced cacheExtent to significantly lower memory footprint and improve
    // scroll/swipe performance.
    final listCacheExtent = (headerContentHeight + 800)
        .clamp(headerContentHeight, 1600.0)
        .toDouble();
    final hasLibrary = listStateHasLibrary || libraryHeaderAudioCount > 0;
    final showLibrarySkeleton =
        !hasLibrary &&
        _effectiveSearchQuery.isEmpty &&
        libraryRefreshBusy &&
        libraryHeaderHasWatchedSources;
    if (_categoryType == AudioLibraryCategoryType.all &&
        _effectiveSearchQuery.isEmpty &&
        listStateIsInitialized) {
      _scheduleLibraryCoverWarmup(
        provider: provider,
        tracks: _libraryCoverWarmupTracksForTree(tree),
        structureRevision: listStateStructureRevision,
        detailRevision: detailRevision,
        coverGeneration: coverGeneration,
        scope: 'all',
      );
    }
    final canPullRefresh = listStateCanPullRefresh;
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
              _buildSearchBar(i18n, matchCount, libraryHeaderAudioCount),
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

      return KeyedSubtree(key: ValueKey(node.path), child: item)
          .animate(delay: (index.clamp(0, 15) * 40).ms)
          .fade(duration: 300.ms)
          .slideY(begin: 0.15, duration: 300.ms, curve: Curves.easeOutCubic);
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
              height: 300,
              child: AppEmptyState(
                icon: Icons.search_off_rounded,
                title: hasLibrary
                    ? i18n.tr('no_search_results')
                    : i18n.tr('no_audio_files'),
                message: hasLibrary
                    ? i18n.tr('search_try_another_term')
                    : i18n.tr('import_audio_hint'),
                actionLabel: hasLibrary ? i18n.tr('clear') : null,
                actionIcon: Icons.clear_rounded,
                onAction: hasLibrary
                    ? () {
                        _searchController.clear();
                        _searchDebounceTimer?.cancel();
                        _setLocalState(() => _searchQuery = '');
                      }
                    : null,
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
        isBusy: libraryRefreshBusy,
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
              !listStateIsScanning &&
              _effectiveSearchQuery.isEmpty) {
            _refreshTriggeredInCurrentScroll = true;
            unawaited(
              AppInteractionFeedback.trigger(
                AppInteractionFeedbackType.confirmation,
              ),
            );
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
                  top:
                      headerControlsFullHeight +
                      (_categoryType == AudioLibraryCategoryType.all
                          ? 4.0
                          : 0.0),
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
                child: !listStateIsInitialized
                    ? ShimmerLoader(
                        child: ListView.builder(
                          physics: const NeverScrollableScrollPhysics(),
                          padding: EdgeInsets.fromLTRB(
                            16.0,
                            listTopPadding,
                            16.0,
                            listBottomPadding,
                          ),
                          itemCount: 15,
                          itemBuilder: (context, index) {
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: Row(
                                children: [
                                  const ShimmerContainer(width: 48, height: 48),
                                  const SizedBox(width: AppSpacing.lg),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const ShimmerContainer(
                                          width: double.infinity,
                                          height: 16,
                                        ),
                                        const SizedBox(height: 8),
                                        ShimmerContainer(
                                          width:
                                              MediaQuery.sizeOf(context).width *
                                              0.4,
                                          height: 12,
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      )
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
                        structureRevision: listStateStructureRevision,
                        detailRevision: detailRevision,
                        coverGeneration: coverGeneration,
                      )
                    : _effectiveSearchQuery.isNotEmpty
                    ? ListView.builder(
                        key: const ValueKey('search_results_list'),
                        controller: _scrollController,
                        padding: EdgeInsets.fromLTRB(
                          16.0,
                          listTopPadding,
                          16.0,
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
                              16.0,
                              listTopPadding,
                              16.0,
                              listBottomPadding,
                            ),
                            cacheExtent: listCacheExtent,
                            physics: canPullRefresh
                                ? const AlwaysScrollableScrollPhysics(
                                    parent: BouncingScrollPhysics(),
                                  )
                                : null,
                            autoScrollerVelocityScalar: 0,
                            buildDefaultDragHandles: false,
                            keyboardDismissBehavior:
                                ScrollViewKeyboardDismissBehavior.onDrag,
                            onReorder: (oldIndex, newIndex) {
                              if (cardPositionsLocked) return;
                              provider.reorderLibraryNodes(oldIndex, newIndex);
                              setState(() => _isReordering = false);
                            },
                            onReorderStart: (index) {
                              if (cardPositionsLocked) return;
                              setState(() => _isReordering = true);
                              unawaited(
                                AppInteractionFeedback.trigger(
                                  AppInteractionFeedbackType.destructive,
                                ),
                              );
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
                                child: _LibraryTreeItem(
                                  node: node,
                                  index: index,
                                  cardPositionsLocked: cardPositionsLocked,
                                ),
                              );
                              return KeyedSubtree(
                                key: ValueKey(node.path),
                                child: child,
                              );
                            },
                          ),
                        ),
                      ),
              ),
            ),

            // Scan progress card
            if (listStateIsScanning && !listStateIsBackgroundScanning)
              Positioned(
                top: headerContentHeight + 10,
                left: 12,
                right: 12,
                child: Consumer(
                  builder: (context, ref, _) {
                    final scanState = ref.watch(libraryScanUiProvider);
                    return _buildScanProgressCard(i18n, provider, scanState);
                  },
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
                subtitle: i18n.tr('audio_count', {
                  'count': libraryHeaderAudioCount,
                }),
                subtitleFontSize: 11,
                fitSubtitleToWidth: true,
                collapseController: _scrollController,
                collapseDistance: headerControlsFullHeight,
                floatingReveal: true,
                floatingRevealDistance: 56,
                trailing: SizedBox(
                  width: 104 + (isWindows ? 52 : 0),
                  height: 44,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      if (isWindows)
                        IconButton(
                          onPressed: canPullRefresh && !libraryRefreshBusy
                              ? () => unawaited(
                                  _runLibraryPullRefresh(showSnackbar: true),
                                )
                              : null,
                          icon: libraryRefreshBusy
                              ? const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.2,
                                  ),
                                )
                              : const Icon(Icons.refresh_rounded),
                          tooltip: i18n.tr('refresh_watched_folder'),
                        ),
                      UnifiedPopupMenuButton<int>(
                        enabled: !libraryRefreshBusy,
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
            child: OverflowBox(
              maxHeight: height,
              minHeight: height,
              alignment: Alignment.topCenter,
              child: Transform.translate(
                offset: Offset(0, -hidden),
                child: child,
              ),
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
      padding: EdgeInsets.fromLTRB(16.0, topInset, 16.0, bottomInset),
      children: [
        block(height: 82, margin: const EdgeInsets.only(bottom: 6)),
        block(height: 70, margin: const EdgeInsets.only(bottom: 6)),
        block(height: 54, margin: const EdgeInsets.only(bottom: 6)),
        block(height: 54, margin: const EdgeInsets.only(bottom: 6)),
        block(height: 62, margin: const EdgeInsets.only(bottom: 6)),
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
