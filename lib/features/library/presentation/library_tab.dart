import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:lottie/lottie.dart';

import '../../../app/localization/app_language_provider.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../core/media/music_track.dart';
import '../../../core/media/audio_detail.dart';
import '../../../core/media/card_info_field.dart';
import '../../../core/media/search_query_utils.dart';
import '../../player/application/playback_facade.dart';
import '../../settings/application/settings_state.dart';
import '../../settings/application/app_preferences.dart';
import '../application/library_entry_editor_service.dart';
import '../application/library_facade.dart';
import '../domain/audio_library_category.dart';
import '../domain/library_node.dart';
import '../domain/library_entry.dart';
import '../../../core/media/natural_sort.dart';
import '../../../core/media/path_display.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/ui/ui_interaction_coordinator.dart';
import '../../../core/ui/ui_operation_service.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../application/library_scanner_service.dart';
import '../application/library_catalog.dart';
import '../application/library_scan_coordinator.dart';
import 'library_cover_ui_controller.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/async_cover_image.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/app_search_page.dart';
import '../../../core/widgets/app_scroll_physics.dart';
import '../../../core/widgets/confirm_action_dialog.dart';
import '../../../core/widgets/library_like_cards.dart';
import '../../../core/widgets/duration_overlay.dart';
import '../../../core/widgets/mobile_overlay_inset.dart';
import '../../../core/widgets/operation_feedback.dart';
import '../../../core/widgets/scroll_activity_gate.dart';
import '../../../core/widgets/search_highlight.dart';
import '../../../core/widgets/sort_options_bottom_sheet.dart';
import '../../../core/widgets/swipe_reveal_card.dart';
import '../../../core/widgets/top_page_header.dart';
import '../../../core/widgets/unified_popup_menu.dart';
import '../../../core/widgets/glass_refresh_indicator.dart';
import 'audio_detail_sheet.dart';
import 'dlsite_metadata_batch_page.dart';
import 'library_scan_feedback.dart';
import 'library_sorting.dart';
import '../../../app/presentation/screen_view_models.dart';
import '../../video_converter/presentation/video_converter_tab.dart';
import '../../../app/theme/app_styles.dart';

import '../../../core/widgets/app_buttons.dart';
import '../../../app/presentation/main_tab_state_mixin.dart';

part 'library_tab_ui_helpers.dart';
part 'library_tab_empty_scan.dart';
part 'library_tab_tree_widgets.dart';
part 'library_tab_category_widgets.dart';
part 'library_tab_edit.dart';
part 'library_search_page.dart';

String _displaySourceName(String sourcePath) {
  return PathDisplay.folderName(sourcePath);
}

String _displayTrackName(String trackPath) {
  return PathDisplay.fileName(trackPath, withoutExtension: true);
}

Future<String?> _deferLibraryCardCoverLookup({
  required bool Function() isMounted,
  required Future<String?> Function() lookup,
}) {
  final completer = Completer<String?>();
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!isMounted()) {
      completer.complete(null);
      return;
    }
    unawaited(
      lookup().then(completer.complete, onError: completer.completeError),
    );
  });
  return completer.future;
}

enum _LibraryMoreAction {
  importFolder,
  importFiles,
  addLibrary,
  videoToAudio,
  manageLibraries,
  batchMetadata,
}

class _LoadedLibraryFolder {
  const _LoadedLibraryFolder({required this.folder, required this.revision});

  final FolderNode folder;
  final int revision;
}

class _VisibleLibraryItem {
  const _VisibleLibraryItem({required this.node, required this.depth});

  final LibraryNode node;
  final int depth;
}

class LibraryTab extends ConsumerStatefulWidget {
  const LibraryTab({
    super.key,
    this.activeTabIndexListenable,
    this.activeSectionListenable,
    this.sectionIndex = 0,
    this.onTitleSwipeLeft,
    this.onTitleSwipeRight,
  });

  final ValueListenable<int>? activeTabIndexListenable;
  final ValueListenable<int>? activeSectionListenable;
  final int sectionIndex;
  final VoidCallback? onTitleSwipeLeft;
  final VoidCallback? onTitleSwipeRight;

  @override
  ConsumerState<LibraryTab> createState() => _LibraryTabState();
}

class _LibraryTabState extends ConsumerState<LibraryTab>
    with AutomaticKeepAliveClientMixin, MainTabStateMixin<LibraryTab> {
  final _scanCoordinator = LibraryScanCoordinator();

  @override
  bool get wantKeepAlive => true;

  bool get _isActive =>
      (widget.activeTabIndexListenable == null ||
          widget.activeTabIndexListenable!.value == tabIndex) &&
      (widget.activeSectionListenable == null ||
          widget.activeSectionListenable!.value == widget.sectionIndex);

  @override
  bool get handlesScrollToTop => _isActive;

  T _readOrWatch<T>(ProviderListenable<T> provider) {
    return _isActive ? ref.watch(provider) : ref.read(provider);
  }

  void _handleActiveTabChanged() {
    if (!mounted) return;
    setState(() {});
    if (_isActive) {
      _ensureStartupRefreshStarted();
      if (_startupRefreshWaiting &&
          !UiInteractionCoordinator.instance.isInteracting) {
        _scheduleStartupRefreshAfter(const Duration(milliseconds: 500));
      }
    } else {
      _startupRefreshIdleTimer?.cancel();
      _startupRefreshIdleTimer = null;
    }
  }

  Timer? _startupRefreshIdleTimer;
  bool _startupRefreshStarted = false;
  bool _startupRefreshWaiting = false;
  bool _startupLibraryRefreshCompleted = false;
  bool _initialLibraryContentReady = false;
  bool _refreshTriggeredInCurrentScroll = false;
  final Set<String> _expandedCardPaths = <String>{};
  final Map<String, _LoadedLibraryFolder> _loadedFolderTrees =
      <String, _LoadedLibraryFolder>{};
  final Map<String, int> _loadingFolderTreeRevisions = <String, int>{};
  List<_VisibleLibraryItem> _visibleItemsCache = const <_VisibleLibraryItem>[];
  List<LibraryNode>? _visibleItemsSource;
  int? _visibleItemsStructureRevision;
  int _visibleItemsVersion = 0;
  int _visibleItemsCacheVersion = -1;
  int _prunedFolderTreeRevision = -1;

  final GlobalKey<GlassRefreshIndicatorState> _refreshIndicatorKey =
      GlobalKey<GlassRefreshIndicatorState>();

  final ScrollController _scrollController = ScrollController();
  int? _cardSnapshotRequestRevision;
  int? _durationBackfillStructureRevision;
  late final String _durationBackfillCommitKey;
  List<LibraryNode>? _sortedTreeCache;
  List<LibraryNode>? _sortedTreeSource;
  LibrarySortCriterion? _sortedTreeCriterion;
  bool? _sortedTreeAscending;
  bool? _sortedTreeGroupByLibrary;
  int? _sortedTreeStructureRevision;
  int? _sortedTreeContentRevision;
  int? _sortedTreeDetailRevision;

  @override
  int get tabIndex => 0;

  @override
  double get headerControlsFullHeight => 0;

  @override
  ScrollController get mainScrollController => _scrollController;

  void _openSearchPage() {
    Navigator.of(context).push(
      buildAppSearchPageRoute<void>(
        context: context,
        child: const _LibrarySearchPage(),
      ),
    );
  }

  Future<void> _openSortOptions() async {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final settingsState = ref.read(settingsStateProvider).value;
    final result = await showSortOptionsBottomSheet<LibrarySortCriterion>(
      context: context,
      options: [
        SortOption(
          value: LibrarySortCriterion.name,
          label: i18n.tr('sort_name'),
        ),
        SortOption(
          value: LibrarySortCriterion.voiceActor,
          label: i18n.tr('sort_voice_actor'),
        ),
        SortOption(
          value: LibrarySortCriterion.duration,
          label: i18n.tr('sort_duration'),
        ),
        SortOption(
          value: LibrarySortCriterion.releaseDate,
          label: i18n.tr('sort_release_date'),
        ),
        SortOption(
          value: LibrarySortCriterion.addedAt,
          label: i18n.tr('sort_added_date'),
        ),
      ],
      selectedCriterion:
          settingsState?.librarySortCriterion ?? LibrarySortCriterion.name,
      ascending: settingsState?.librarySortAscending ?? true,
      groupByLibrary: settingsState?.libraryGroupByLibrary ?? false,
      title: i18n.tr('sort_by_title'),
      descriptionLabel: i18n.tr('sort_description'),
      ascendingLabel: i18n.tr('sort_ascending'),
      descendingLabel: i18n.tr('sort_descending'),
      groupByLibraryLabel: i18n.tr('sort_group_by_library'),
      cancelLabel: i18n.tr('cancel'),
      confirmLabel: i18n.tr('confirm'),
    );
    if (!mounted || result == null) return;
    final settings = ref.read(settingsRepositoryProvider);
    await settings.setLibrarySortOptions(
      criterion: result.criterion,
      ascending: result.ascending,
      groupByLibrary: result.groupByLibrary,
    );
  }

  void _handleCardExpansionChanged(FolderNode folder, bool expanded) {
    final folderPath = folder.path;
    final normalizedPath = PathMatcher.normalize(folderPath);
    final changed = expanded
        ? _expandedCardPaths.add(normalizedPath)
        : _expandedCardPaths.remove(normalizedPath);
    if (changed && mounted) {
      setState(() => _visibleItemsVersion++);
    }
    if (expanded && folder.depth == 0) {
      unawaited(_loadExpandedFolderTree(folderPath));
    }
  }

  Future<void> _loadExpandedFolderTree(String folderPath) async {
    final normalizedPath = PathMatcher.normalize(folderPath);
    final libraryFacade = ref.read(libraryFacadeProvider);
    final revision = libraryFacade.structureRevision;
    if (_loadedFolderTrees[normalizedPath]?.revision == revision ||
        _loadingFolderTreeRevisions[normalizedPath] == revision) {
      return;
    }
    _loadingFolderTreeRevisions[normalizedPath] = revision;
    final folder = await libraryFacade.loadLibraryFolderTree(folderPath);
    if (!mounted) return;
    if (_loadingFolderTreeRevisions[normalizedPath] == revision) {
      _loadingFolderTreeRevisions.remove(normalizedPath);
    }
    if (folder == null || libraryFacade.structureRevision != revision) return;
    setState(() {
      final previousFolder = _loadedFolderTrees[normalizedPath]?.folder;
      _loadedFolderTrees[normalizedPath] = _LoadedLibraryFolder(
        folder: folder,
        revision: revision,
      );
      if (previousFolder != null) {
        _removeMissingExpandedFolderPaths(previousFolder, folder);
      }
      _visibleItemsVersion++;
    });
  }

  List<_VisibleLibraryItem> _visibleLibraryItems({
    required List<LibraryNode> tree,
    required int structureRevision,
  }) {
    _pruneFolderTreeCaches(tree, structureRevision);
    if (identical(_visibleItemsSource, tree) &&
        _visibleItemsStructureRevision == structureRevision &&
        _visibleItemsCacheVersion == _visibleItemsVersion) {
      return _visibleItemsCache;
    }
    final result = <_VisibleLibraryItem>[];

    void addNode(LibraryNode node, int depth, {FolderNode? expandedFolder}) {
      result.add(_VisibleLibraryItem(node: node, depth: depth));
      if (node is! FolderNode ||
          !_expandedCardPaths.contains(PathMatcher.normalize(node.path))) {
        return;
      }
      for (final child in (expandedFolder ?? node).children) {
        addNode(child, depth + 1);
      }
    }

    for (final node in tree) {
      if (node is! FolderNode) {
        addNode(node, 0);
        continue;
      }
      final normalizedPath = PathMatcher.normalize(node.path);
      final loaded = _loadedFolderTrees[normalizedPath];
      addNode(node, 0, expandedFolder: loaded?.folder);
      if (_expandedCardPaths.contains(normalizedPath) &&
          loaded?.revision != structureRevision &&
          _loadingFolderTreeRevisions[normalizedPath] != structureRevision) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_loadExpandedFolderTree(node.path));
        });
      }
    }
    _visibleItemsSource = tree;
    _visibleItemsStructureRevision = structureRevision;
    _visibleItemsCacheVersion = _visibleItemsVersion;
    return _visibleItemsCache = result;
  }

  void _pruneFolderTreeCaches(List<LibraryNode> tree, int structureRevision) {
    if (_prunedFolderTreeRevision == structureRevision) return;
    _prunedFolderTreeRevision = structureRevision;
    final rootPaths = tree
        .whereType<FolderNode>()
        .map((folder) => PathMatcher.normalize(folder.path))
        .toSet();
    var changed = false;
    final removedRootPaths = _loadedFolderTrees.keys
        .where((path) => !rootPaths.contains(path))
        .toList(growable: false);
    for (final path in removedRootPaths) {
      _loadedFolderTrees.remove(path);
      changed = true;
    }
    _loadingFolderTreeRevisions.removeWhere((path, _) {
      final remove = !rootPaths.contains(path);
      changed = changed || remove;
      return remove;
    });

    final previousExpandedCount = _expandedCardPaths.length;
    _retainCurrentExpandedFolderPaths(rootPaths: rootPaths);
    changed = changed || _expandedCardPaths.length != previousExpandedCount;
    if (changed) _visibleItemsVersion++;
  }

  void _retainCurrentExpandedFolderPaths({Set<String>? rootPaths}) {
    final validExpandedPaths = <String>{...?rootPaths};
    void collectFolderPaths(FolderNode folder) {
      validExpandedPaths.add(PathMatcher.normalize(folder.path));
      for (final child in folder.children.whereType<FolderNode>()) {
        collectFolderPaths(child);
      }
    }

    for (final loaded in _loadedFolderTrees.values) {
      collectFolderPaths(loaded.folder);
    }
    _expandedCardPaths.retainWhere(validExpandedPaths.contains);
  }

  void _removeMissingExpandedFolderPaths(
    FolderNode previousFolder,
    FolderNode currentFolder,
  ) {
    Set<String> collectPaths(FolderNode root) {
      final paths = <String>{};
      void collect(FolderNode folder) {
        paths.add(PathMatcher.normalize(folder.path));
        for (final child in folder.children.whereType<FolderNode>()) {
          collect(child);
        }
      }

      collect(root);
      return paths;
    }

    final currentPaths = collectPaths(currentFolder);
    final removedPaths = collectPaths(previousFolder)..removeAll(currentPaths);
    _expandedCardPaths.removeAll(removedPaths);
  }

  Future<void> _openVideoConverterPage() async {
    if (!mounted) return;
    await Navigator.of(context).push(
      buildAppPageRoute<void>(
        context: context,
        child: const VideoConverterTab(),
      ),
    );
  }

  Future<void> _openLibraryManagementPage() async {
    if (!mounted) return;
    await Navigator.of(context).push(
      buildAppPageRoute<void>(
        context: context,
        child: const LibraryManagementPage(),
      ),
    );
  }

  Future<void> _openBatchMetadataPage() async {
    if (!mounted) return;
    await Navigator.of(context).push(
      buildAppPageRoute<void>(
        context: context,
        child: const DlsiteMetadataBatchPage(),
      ),
    );
  }

  Future<void> _scheduleWatchedFoldersRefresh({
    bool silent = false,
    bool forceShowResult = false,
    bool importAudioDetails = true,
  }) async {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final catalog = ref.read(libraryFacadeProvider);
    final operations = ref.read(uiOperationServiceProvider);
    final importBusy = <UiOperationScope>[
      UiOperationScope.libraryRefresh,
      UiOperationScope.libraryImportFolder,
      UiOperationScope.libraryImportLibrary,
      UiOperationScope.libraryImportFiles,
    ].any(operations.isBusy);
    if (catalog.isScanning || importBusy) {
      if (!silent) showAppSnackBar(context, i18n.tr('scanning_title'));
      return;
    }
    final outcome = await ref
        .read(uiOperationServiceProvider)
        .runWithFeedback<LibraryScanOutcome?>(
          context: context,
          scope: UiOperationScope.libraryRefresh,
          labelKey: 'loading_dot',
          failureMessage: i18n.tr('scan_failed_next_step'),
          operationFailedTitle: i18n.tr('operation_failed'),
          retryLabel: i18n.tr('retry'),
          cancelPrevious: false,
          onRetry: () => _scheduleWatchedFoldersRefresh(
            silent: silent,
            forceShowResult: forceShowResult,
            importAudioDetails: importAudioDetails,
          ),
          task: (_) => _scanCoordinator.refresh(
            catalog: catalog,
            labels: LibraryScanPresentationMapper.labels(i18n),
            importAudioDetails: importAudioDetails,
          ),
        );
    if (!mounted || outcome == null) return;
    if (!silent ||
        forceShowResult ||
        outcome.code == LibraryScanOutcomeCode.refreshAdded) {
      _showLibraryScanFeedback(outcome, i18n);
    }
  }

  Future<void> _runLibraryPullRefresh({bool showSnackbar = false}) async {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
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
    required Future<LibraryScanOutcome?> Function({
      required LibraryCatalog catalog,
      required LibraryScanLabels labels,
    })
    action,
    required Future<void> Function() retry,
  }) async {
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final catalog = ref.read(libraryFacadeProvider);
    final outcome = await ref
        .read(uiOperationServiceProvider)
        .runWithFeedback<LibraryScanOutcome?>(
          context: context,
          scope: switch (logEvent) {
            'library_import_files_failed' =>
              UiOperationScope.libraryImportFiles,
            'library_import_library_failed' =>
              UiOperationScope.libraryImportLibrary,
            _ => UiOperationScope.libraryImportFolder,
          },
          labelKey: 'loading_dot',
          failureMessage: i18n.tr('import_failed_next_step'),
          operationFailedTitle: i18n.tr('operation_failed'),
          retryLabel: i18n.tr('retry'),
          cancelPrevious: false,
          onRetry: () {
            unawaited(retry());
          },
          task: (_) => action(
            catalog: catalog,
            labels: LibraryScanPresentationMapper.labels(i18n),
          ),
        );
    if (mounted && outcome != null) {
      _showLibraryScanFeedback(outcome, i18n);
    }
  }

  void _showLibraryScanFeedback(
    LibraryScanOutcome outcome,
    AppLanguageProvider i18n,
  ) {
    final feedback = LibraryScanPresentationMapper.feedback(outcome, i18n);
    if (feedback == null) return;
    showAppSnackBar(
      context,
      feedback.message,
      tone: feedback.tone,
      icon: feedback.icon,
    );
  }

  Future<void> _addFolder() {
    return _runLibraryImportAction(
      logEvent: 'library_import_folder_failed',
      action: _scanCoordinator.importFolder,
      retry: _addFolder,
    );
  }

  Future<void> _addLibrary() async {
    return _runLibraryImportAction(
      logEvent: 'library_import_library_failed',
      action: _scanCoordinator.importLibrary,
      retry: _addLibrary,
    );
  }

  Future<void> _addFiles() async {
    return _runLibraryImportAction(
      logEvent: 'library_import_files_failed',
      action: _scanCoordinator.importFiles,
      retry: _addFiles,
    );
  }

  @override
  void initState() {
    super.initState();
    _durationBackfillCommitKey =
        'library_duration_backfill:${identityHashCode(this)}';
    widget.activeTabIndexListenable?.addListener(_handleActiveTabChanged);
    widget.activeSectionListenable?.addListener(_handleActiveTabChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _ensureStartupRefreshStarted();
    });
    initTabState(ref.read(mainScreenControllerProvider).scrollToTopTab);
  }

  void _ensureStartupRefreshStarted() {
    if (!_isActive || _startupRefreshStarted) return;
    _startupRefreshStarted = true;
    unawaited(_refreshAfterStartupIdle());
  }

  Future<void> _refreshAfterStartupIdle() async {
    while (mounted && !ref.read(libraryFacadeProvider).state.isInitialized) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (!mounted) return;
    if (!_isActive) {
      _startupRefreshStarted = false;
      return;
    }
    _startupRefreshWaiting = true;
    UiInteractionCoordinator.instance.addListener(
      _handleStartupRefreshInteractionChanged,
    );
    if (!UiInteractionCoordinator.instance.isInteracting) {
      _scheduleStartupRefreshAfter(const Duration(seconds: 2));
    }
  }

  void _handleStartupRefreshInteractionChanged() {
    if (!_startupRefreshWaiting || !mounted) return;
    _startupRefreshIdleTimer?.cancel();
    _startupRefreshIdleTimer = null;
    if (_isActive && !UiInteractionCoordinator.instance.isInteracting) {
      _scheduleStartupRefreshAfter(const Duration(milliseconds: 500));
    }
  }

  void _scheduleStartupRefreshAfter(Duration quietWindow) {
    _startupRefreshIdleTimer?.cancel();
    _startupRefreshIdleTimer = Timer(quietWindow, () {
      _startupRefreshIdleTimer = null;
      if (!mounted ||
          !_isActive ||
          UiInteractionCoordinator.instance.isInteracting) {
        return;
      }
      _startupRefreshWaiting = false;
      UiInteractionCoordinator.instance.removeListener(
        _handleStartupRefreshInteractionChanged,
      );
      unawaited(_finishStartupLibraryRefresh());
    });
  }

  Future<void> _finishStartupLibraryRefresh() async {
    try {
      await _scheduleWatchedFoldersRefresh(
        silent: true,
        importAudioDetails: false,
      );
    } finally {
      if (mounted) {
        setState(() => _startupLibraryRefreshCompleted = true);
      }
    }
  }

  void _ensureCardSnapshot({
    required LibraryFacade libraryFacade,
    required int snapshotRevision,
  }) {
    final structureRevision = libraryFacade.structureRevision;
    if (snapshotRevision == structureRevision ||
        _cardSnapshotRequestRevision == structureRevision) {
      return;
    }
    _cardSnapshotRequestRevision = structureRevision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _cardSnapshotRequestRevision != structureRevision) {
        return;
      }
      unawaited(
        libraryFacade.ensureCardSnapshot().whenComplete(() {
          if (mounted && _cardSnapshotRequestRevision == structureRevision) {
            _cardSnapshotRequestRevision = null;
          }
        }),
      );
    });
  }

  void _ensureMissingDurationBackfill({
    required LibraryFacade libraryFacade,
    required int structureRevision,
    required bool canRun,
  }) {
    if (!canRun || _durationBackfillStructureRevision == structureRevision) {
      return;
    }
    _durationBackfillStructureRevision = structureRevision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _durationBackfillStructureRevision != structureRevision) {
        return;
      }
      UiInteractionCoordinator.instance.scheduleCommit(
        key: _durationBackfillCommitKey,
        priority: 90,
        commit: () {
          if (!mounted ||
              _durationBackfillStructureRevision != structureRevision) {
            return;
          }
          unawaited(libraryFacade.backfillMissingLibraryDurations());
        },
      );
    });
  }

  List<LibraryNode> _sortTreeIfNeeded({
    required List<LibraryNode> rawTree,
    required LibraryFacade libraryFacade,
    required LibrarySortCriterion criterion,
    required bool ascending,
    required bool groupByLibrary,
    required int structureRevision,
    required int contentRevision,
    required int detailRevision,
  }) {
    if (identical(_sortedTreeSource, rawTree) &&
        _sortedTreeCriterion == criterion &&
        _sortedTreeAscending == ascending &&
        _sortedTreeGroupByLibrary == groupByLibrary &&
        _sortedTreeStructureRevision == structureRevision &&
        _sortedTreeContentRevision == contentRevision &&
        _sortedTreeDetailRevision == detailRevision) {
      return _sortedTreeCache!;
    }

    final sortedTree = sortLibraryNodes(
      nodes: rawTree,
      criterion: criterion,
      ascending: ascending,
      groupByLibrary: groupByLibrary,
      library: libraryFacade,
    );
    _sortedTreeSource = rawTree;
    _sortedTreeCriterion = criterion;
    _sortedTreeAscending = ascending;
    _sortedTreeGroupByLibrary = groupByLibrary;
    _sortedTreeStructureRevision = structureRevision;
    _sortedTreeContentRevision = contentRevision;
    _sortedTreeDetailRevision = detailRevision;
    return _sortedTreeCache = sortedTree;
  }

  @override
  void dispose() {
    widget.activeTabIndexListenable?.removeListener(_handleActiveTabChanged);
    widget.activeSectionListenable?.removeListener(_handleActiveTabChanged);
    UiInteractionCoordinator.instance.removeListener(
      _handleStartupRefreshInteractionChanged,
    );
    _startupRefreshIdleTimer?.cancel();
    UiInteractionCoordinator.instance.cancelCommit(_durationBackfillCommitKey);
    disposeTabState();
    _scanCoordinator.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final i18n = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appLanguageProviderInstanceProvider);
    final libraryFacade = ref.read(libraryFacadeProvider);
    final libraryHeaderAudioCount = _readOrWatch(
      libraryHeaderUiProvider.select((s) => s.audioCount),
    );
    final libraryHeaderHasWatchedSources = _readOrWatch(
      libraryHeaderUiProvider.select((s) => s.hasWatchedSources),
    );
    final listStateRawTree = _readOrWatch(
      libraryListUiProvider.select((s) => s.rawTree),
    );
    final listStateStructureRevision = _readOrWatch(
      libraryListUiProvider.select((s) => s.structureRevision),
    );
    final listStateIsScanning = _readOrWatch(
      libraryListUiProvider.select((s) => s.isScanning),
    );
    final listStateIsBackgroundScanning = _readOrWatch(
      libraryListUiProvider.select((s) => s.isBackgroundScanning),
    );
    final listStateIsInitialized = _readOrWatch(
      libraryListUiProvider.select((s) => s.isInitialized),
    );
    final listStateHasLibrary = _readOrWatch(
      libraryListUiProvider.select((s) => s.hasLibrary),
    );
    final listStateCanPullRefresh = _readOrWatch(
      libraryListUiProvider.select((s) => s.canPullRefresh),
    );
    final libraryDetailRevision = _readOrWatch(libraryDetailRevisionProvider);
    final librarySortCriterion = _readOrWatch(
      settingsStateProvider.select(
        (state) =>
            state.value?.librarySortCriterion ?? LibrarySortCriterion.name,
      ),
    );
    final librarySortAscending = _readOrWatch(
      settingsStateProvider.select(
        (state) => state.value?.librarySortAscending ?? true,
      ),
    );
    final libraryGroupByLibrary = _readOrWatch(
      settingsStateProvider.select(
        (state) => state.value?.libraryGroupByLibrary ?? false,
      ),
    );
    final libraryRefreshOperationBusy = _readOrWatch(
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
          (scope) => _readOrWatch(
            uiOperationForScopeProvider(scope).select((s) => s.isBusy),
          ),
        );
    final libraryRefreshBusy =
        libraryRefreshOperationBusy || libraryImportBusy || listStateIsScanning;
    if (_isActive && listStateIsInitialized) {
      _ensureCardSnapshot(
        libraryFacade: libraryFacade,
        snapshotRevision: listStateStructureRevision,
      );
    }
    _ensureMissingDurationBackfill(
      libraryFacade: libraryFacade,
      structureRevision: listStateStructureRevision,
      canRun:
          _isActive &&
          listStateIsInitialized &&
          _startupLibraryRefreshCompleted &&
          !listStateIsScanning &&
          !listStateIsBackgroundScanning,
    );
    final tree = _sortTreeIfNeeded(
      rawTree: listStateRawTree,
      libraryFacade: libraryFacade,
      criterion: librarySortCriterion,
      ascending: librarySortAscending,
      groupByLibrary: libraryGroupByLibrary,
      structureRevision: listStateStructureRevision,
      contentRevision: libraryFacade.contentRevision,
      detailRevision: libraryDetailRevision,
    );
    final visibleItems = _visibleLibraryItems(
      tree: tree,
      structureRevision: listStateStructureRevision,
    );
    final bottomInset = MobileOverlayInset.of(context);

    final headerControlsFullHeight = this.headerControlsFullHeight;
    final topTotalHeight = headerHeight + 4;
    final headerContentHeight = topTotalHeight + headerControlsFullHeight;
    // Remove the extra 96px to make content flush with the bottom dock.
    final listBottomInset = bottomInset;
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final listTopPadding = headerContentHeight;
    final listBottomPadding = listBottomInset + 16.0;
    final listViewportBottomInset =
        listBottomInset + (isLandscape ? 16.0 : 0.0);
    // Reduced cacheExtent to significantly lower memory footprint and improve
    // scroll/swipe performance.
    const listCacheExtent = 320.0;
    final hasLibrary = listStateHasLibrary || libraryHeaderAudioCount > 0;
    if (!_initialLibraryContentReady &&
        listStateIsInitialized &&
        listStateStructureRevision == libraryFacade.structureRevision) {
      _initialLibraryContentReady = true;
    }
    final showLibrarySkeleton =
        (libraryHeaderHasWatchedSources || hasLibrary) &&
        !_initialLibraryContentReady;
    final canPullRefresh = listStateCanPullRefresh;

    Widget buildTopLevelLibraryItem(BuildContext context, int index) {
      if (index == visibleItems.length) {
        return const SizedBox.shrink(key: ValueKey('bottom_spacing'));
      }
      final item = visibleItems[index];
      final node = item.node;
      return KeyedSubtree(
        key: ValueKey(node.path),
        child: Padding(
          padding: EdgeInsets.only(left: item.depth * 8.0),
          child: RepaintBoundary(
            child: _LibraryTreeItem(
              node: node,
              initiallyExpanded:
                  node is FolderNode &&
                  _expandedCardPaths.contains(PathMatcher.normalize(node.path)),
              onFolderExpansionChanged: _handleCardExpansionChanged,
              renderChildrenInline: false,
              index: index,
            ),
          ),
        ),
      );
    }

    Widget emptyListBody() {
      final relativeTop = listTopPadding;
      final relativeBottom = listBottomPadding;

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
                parent: RefreshTopScrollPhysics(),
              )
            : const ClampingScrollPhysics(),
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
              !listStateIsScanning) {
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
            MediaQuery(
              data: MediaQuery.of(context).copyWith(
                padding: EdgeInsets.only(
                  top: headerControlsFullHeight + 4,
                  bottom: listViewportBottomInset,
                  right: 4,
                ),
              ),
              child: PlaceholderContentTransition(
                showPlaceholder: !listStateIsInitialized || showLibrarySkeleton,
                placeholder: _LibraryLoadingSkeleton(
                  bottomInset: listBottomPadding,
                  topInset: listTopPadding,
                ),
                content: tree.isEmpty
                    ? refreshableEmptyBody()
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
                        child: ListView.builder(
                          key: const PageStorageKey<String>('library_list'),
                          controller: _scrollController,
                          clipBehavior: Clip.none,
                          padding: EdgeInsets.fromLTRB(
                            LibraryLikeCardMetrics.listHorizontalPadding,
                            listTopPadding,
                            LibraryLikeCardMetrics.listHorizontalPadding,
                            listBottomPadding,
                          ),
                          cacheExtent: listCacheExtent,
                          physics: canPullRefresh
                              ? const AlwaysScrollableScrollPhysics(
                                  parent: RefreshTopScrollPhysics(),
                                )
                              : null,
                          keyboardDismissBehavior:
                              ScrollViewKeyboardDismissBehavior.onDrag,
                          itemCount: visibleItems.length + 1,
                          itemBuilder: buildTopLevelLibraryItem,
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
                    final scanState = _isActive
                        ? ref.watch(libraryScanUiProvider)
                        : ref.read(libraryScanUiProvider);
                    return _buildScanProgressCard(i18n, scanState);
                  },
                ),
              ),

            // Header — frosted glass overlay on top of the scrolling list
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: TopPageHeader(
                key: headerKey,
                icon: Icons.library_music_rounded,
                title: i18n.tr('music_library'),
                padding: AppPageHeaderMetrics.mainTabPadding,
                onTitleSwipeLeft: widget.onTitleSwipeLeft,
                onTitleSwipeRight: widget.onTitleSwipeRight,
                trailing: SizedBox(
                  width: 144 + (isLandscape ? 52 : 0),
                  height: 44,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      IconButton(
                        key: const ValueKey<String>('library_search_button'),
                        onPressed: _openSearchPage,
                        icon: const Icon(Icons.search_rounded),
                        tooltip: i18n.tr('search'),
                      ),
                      if (isLandscape)
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
                      IconButton(
                        key: const ValueKey<String>('library_sort_button'),
                        onPressed: libraryRefreshBusy ? null : _openSortOptions,
                        icon: const Icon(Icons.sort_rounded),
                        tooltip: i18n.tr('sort_by'),
                      ),
                      UnifiedPopupMenuButton<_LibraryMoreAction>(
                        enabled: !libraryRefreshBusy,
                        icon: Icons.more_horiz_rounded,
                        tooltip: i18n.tr('more_actions'),
                        entries: [
                          UnifiedMenuEntry<_LibraryMoreAction>.action(
                            value: _LibraryMoreAction.importFolder,
                            icon: Icons.create_new_folder_rounded,
                            label: i18n.tr('import_folder'),
                          ),
                          UnifiedMenuEntry<_LibraryMoreAction>.action(
                            value: _LibraryMoreAction.importFiles,
                            icon: Icons.upload_file_rounded,
                            label: i18n.tr('import_file'),
                          ),
                          UnifiedMenuEntry<_LibraryMoreAction>.action(
                            value: _LibraryMoreAction.addLibrary,
                            icon: Icons.library_add_rounded,
                            label: i18n.tr('choose_library'),
                          ),
                          const UnifiedMenuEntry<_LibraryMoreAction>.divider(),
                          UnifiedMenuEntry<_LibraryMoreAction>.action(
                            value: _LibraryMoreAction.videoToAudio,
                            icon: Icons.video_library_rounded,
                            label: i18n.tr('video_to_audio'),
                          ),
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
                        ],
                        onSelected: (value) {
                          switch (value) {
                            case _LibraryMoreAction.importFolder:
                              _addFolder();
                              break;
                            case _LibraryMoreAction.importFiles:
                              _addFiles();
                              break;
                            case _LibraryMoreAction.addLibrary:
                              _addLibrary();
                              break;
                            case _LibraryMoreAction.videoToAudio:
                              _openVideoConverterPage();
                              break;
                            case _LibraryMoreAction.manageLibraries:
                              _openLibraryManagementPage();
                              break;
                            case _LibraryMoreAction.batchMetadata:
                              _openBatchMetadataPage();
                              break;
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
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
    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(
        LibraryLikeCardMetrics.listHorizontalPadding,
        topInset,
        LibraryLikeCardMetrics.listHorizontalPadding,
        bottomInset,
      ),
      children: [for (int i = 0; i < 5; i++) const LibraryLikeSkeletonCard()],
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
