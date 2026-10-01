import 'library_tree_list.dart';
import 'library_providers.dart';
import 'library_tab_edit.dart';
import '../../settings/presentation/settings_providers.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

import '../../../app/localization/app_language_provider.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../app/presentation/app_presentation_providers.dart';
import '../../settings/application/settings_state.dart';
import '../application/library_facade.dart';
import '../domain/library_node.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/ui/ui_interaction_coordinator.dart';
import '../../../core/ui/ui_operation_service.dart';
import '../application/library_scanner_service.dart';
import '../application/library_catalog.dart';
import '../application/library_scan_coordinator.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/app_transitions.dart';
import '../../../core/widgets/mobile_overlay_inset.dart';
import '../../../core/widgets/page_header_inset.dart';
import '../../../core/widgets/scroll_activity_gate.dart';
import '../../../core/widgets/sort_options_bottom_sheet.dart';
import '../../../core/widgets/top_page_header.dart';
import '../../../core/widgets/unified_popup_menu.dart';
import '../../../core/widgets/glass_refresh_indicator.dart';
import 'dlsite_metadata_batch_page.dart';
import 'library_scan_feedback.dart';
import '../../video_converter/presentation/video_converter_tab.dart';
import '../../../app/theme/app_styles.dart';

import '../../../app/presentation/main_tab_state_mixin.dart';

import 'library_tab_ui_helpers.dart';
import 'library_tab_empty_scan.dart';
import 'library_search_page.dart';
export 'library_tab_tree_widgets.dart' show LibraryTreeItem;
export 'library_tab_category_widgets.dart' show LibraryCategoryTermBox;

enum _LibraryAddAction { importFolder, importFiles, addLibrary }

class LibraryTab extends ConsumerStatefulWidget {
  const LibraryTab({
    super.key,
    this.tabIndex = 1,
    this.activeTabIndexListenable,
    this.activeSectionListenable,
    this.sectionIndex = 0,
    this.onTitleSwipeLeft,
    this.onTitleSwipeRight,
  });

  final int tabIndex;
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

  @override
  double get defaultHeaderHeight => AppPageHeaderMetrics.expandedToolbarHeight;

  bool get _isActive {
    final route = ModalRoute.of(context);
    final isRouteCurrent = route == null || route.isCurrent;
    return isRouteCurrent &&
        (widget.activeTabIndexListenable == null ||
            widget.activeTabIndexListenable!.value == tabIndex) &&
        (widget.activeSectionListenable == null ||
            widget.activeSectionListenable!.value == widget.sectionIndex);
  }

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
  bool _initialLibraryContentReady = false;
  bool _isSelectionMode = false;
  final Set<String> _selectedLibraryPaths = <String>{};

  final ScrollController _scrollController = ScrollController();
  final GlobalKey<GlassRefreshIndicatorState> _refreshIndicatorKey =
      GlobalKey();
  int? _cardSnapshotRequestRevision;

  @override
  int get tabIndex => widget.tabIndex;

  @override
  double get headerControlsFullHeight => 0;

  @override
  ScrollController get mainScrollController => _scrollController;

  void _openSearchPage() {
    Navigator.of(context).push(
      buildAppPageRoute<void>(
        context: context,
        child: const LibrarySearchPage(),
        duration: Duration.zero,
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
        SortOption(
          value: LibrarySortCriterion.playbackTime,
          label: i18n.tr('sort_playback_time'),
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
    await saveSettingsWithFeedback(
      context,
      () => settings.setLibrarySortOptions(
        criterion: result.criterion,
        ascending: result.ascending,
        groupByLibrary: result.groupByLibrary,
      ),
    );
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
        fadeHeader: false,
        child: const DlsiteMetadataBatchPage(),
      ),
    );
  }

  void _enterSelectionMode(LibraryNode node) {
    if (!isSelectableLibraryNode(node)) return;
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
    setState(() {
      _isSelectionMode = true;
      _selectedLibraryPaths
        ..clear()
        ..add(selectionKeyForLibraryNode(node));
    });
  }

  void _exitSelectionMode() {
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.tap);
    setState(() {
      _isSelectionMode = false;
      _selectedLibraryPaths.clear();
    });
  }

  void _toggleLibrarySelection(LibraryNode node) {
    if (!isSelectableLibraryNode(node)) return;
    final key = selectionKeyForLibraryNode(node);
    AppInteractionFeedback.trigger(AppInteractionFeedbackType.selection);
    setState(() {
      if (!_selectedLibraryPaths.add(key)) {
        _selectedLibraryPaths.remove(key);
        if (_selectedLibraryPaths.isEmpty) _isSelectionMode = false;
      }
    });
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
    widget.activeTabIndexListenable?.addListener(_handleActiveTabChanged);
    widget.activeSectionListenable?.addListener(_handleActiveTabChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _ensureStartupRefreshStarted();
    });
    final controller = ref.read(mainScreenControllerProvider);
    initTabState(controller.scrollToTopTab, controller.stopScrollTab);
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
    await _scheduleWatchedFoldersRefresh(
      silent: true,
      importAudioDetails: false,
    );
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

  @override
  void dispose() {
    widget.activeTabIndexListenable?.removeListener(_handleActiveTabChanged);
    widget.activeSectionListenable?.removeListener(_handleActiveTabChanged);
    UiInteractionCoordinator.instance.removeListener(
      _handleStartupRefreshInteractionChanged,
    );
    _startupRefreshIdleTimer?.cancel();
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
    final pinnedLibraryPaths = _readOrWatch(
      settingsStateProvider.select(
        (state) => state.value?.pinnedLibraryPaths ?? const <String>[],
      ),
    ).toSet();
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
    final tree = _isActive
        ? ref.watch(librarySortedTreeUiProvider)
        : ref.read(librarySortedTreeUiProvider);
    final selectedSelections = _isSelectionMode
        ? selectedLibraryNodeSelections(tree, _selectedLibraryPaths)
        : const <LibraryBatchSelection>[];
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

    Widget emptyListBody() {
      final relativeTop = listTopPadding;
      final relativeBottom = listBottomPadding;

      if (showLibrarySkeleton) {
        return LibraryLoadingSkeleton(
          bottomInset: relativeBottom,
          topInset: relativeTop,
        );
      }
      return LibraryEmptyState(
        onImportLibrary: _addLibrary,
        onImportFolder: _addFolder,
        onImportFile: _addFiles,
        isBusy: libraryRefreshBusy,
        bottomInset: relativeBottom,
        topInset: relativeTop,
        physics: canPullRefresh
            ? AlwaysScrollableScrollPhysics(
                parent: GlassRefreshIndicatorScrollPhysics(
                  isIndicatorVisible: () =>
                      _refreshIndicatorKey.currentState?.isIndicatorVisible ??
                      false,
                ),
              )
            : const ClampingScrollPhysics(),
      );
    }

    Widget refreshableEmptyBody() {
      final body = emptyListBody();
      if (!canPullRefresh) return body;
      return GlassRefreshIndicator(
        key: _refreshIndicatorKey,
        lockChildWhileRefreshing: true,
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
      child: PageHeaderInset(
        topInset: listTopPadding,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            AppPageContentTransition(
              child: PlaceholderContentTransition(
                showPlaceholder: !listStateIsInitialized || showLibrarySkeleton,
                placeholder: LibraryLoadingSkeleton(
                  bottomInset: listBottomPadding,
                  topInset: listTopPadding,
                ),
                content: tree.isEmpty
                    ? refreshableEmptyBody()
                    : GlassRefreshIndicator(
                        key: _refreshIndicatorKey,
                        lockChildWhileRefreshing: true,
                        color: Theme.of(context).colorScheme.primary,
                        backgroundColor: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest
                            .withValues(alpha: 0.6),
                        onRefresh: _runLibraryPullRefresh,
                        edgeOffset: listTopPadding,
                        displacement: 32,
                        triggerMode: GlassRefreshIndicatorTriggerMode.anywhere,
                        child: LibraryTreeList(
                          tree: tree,
                          structureRevision: listStateStructureRevision,
                          selectedPaths: _selectedLibraryPaths,
                          isSelectionMode: _isSelectionMode,
                          scrollController: _scrollController,
                          i18n: i18n,
                          topPadding: listTopPadding,
                          bottomPadding: listBottomPadding,
                          cacheExtent: listCacheExtent,
                          physics: canPullRefresh
                              ? AlwaysScrollableScrollPhysics(
                                  parent: GlassRefreshIndicatorScrollPhysics(
                                    isIndicatorVisible: () =>
                                        _refreshIndicatorKey
                                            .currentState
                                            ?.isIndicatorVisible ??
                                        false,
                                  ),
                                )
                              : null,
                          loadFolder: libraryFacade.loadLibraryFolderTree,
                          currentStructureRevision: () =>
                              libraryFacade.structureRevision,
                          onLongPress: _enterSelectionMode,
                          onToggleSelect: _toggleLibrarySelection,
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
                child: AppPageContentTransition(
                  child: Consumer(
                    builder: (context, ref, _) {
                      final scanState = _isActive
                          ? ref.watch(libraryScanUiProvider)
                          : ref.read(libraryScanUiProvider);
                      return LibraryScanProgressCard(
                        i18n: i18n,
                        scanState: scanState,
                        onCancel: () => _scanCoordinator.cancel(
                          ref.read(libraryFacadeProvider),
                        ),
                      );
                    },
                  ),
                ),
              ),

            // Header — frosted glass overlay on top of the scrolling list
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: _isSelectionMode
                  ? LibraryBatchSelectionHeader(
                      keyPrefix: 'library',
                      i18n: i18n,
                      selectedCount: selectedSelections.length,
                      onAddToPlaylist: selectedSelections.isEmpty
                          ? null
                          : () => addLibraryBatchSelectionsToPlaylist(
                              context: context,
                              ref: ref,
                              selections: selectedSelections,
                              exitSelectionMode: _exitSelectionMode,
                            ),
                      onCompleteMetadata: selectedSelections.isEmpty
                          ? null
                          : () => completeLibraryBatchSelectionsMetadata(
                              context: context,
                              ref: ref,
                              selections: selectedSelections,
                              exitSelectionMode: _exitSelectionMode,
                            ),
                      onTogglePin: selectedSelections.isEmpty
                          ? null
                          : () => toggleLibraryBatchSelectionsPinned(
                              context: context,
                              ref: ref,
                              selections: selectedSelections,
                              exitSelectionMode: _exitSelectionMode,
                            ),
                      isPinned:
                          selectedSelections.isNotEmpty &&
                          selectedSelections.every(
                            (s) => pinnedLibraryPaths.contains(
                              PathMatcher.normalize(s.path),
                            ),
                          ),
                      onRemove: selectedSelections.isEmpty
                          ? null
                          : () => removeLibraryBatchSelections(
                              context: context,
                              ref: ref,
                              selections: selectedSelections,
                              exitSelectionMode: _exitSelectionMode,
                            ),
                      onExit: _exitSelectionMode,
                    )
                  : TopPageHeader(
                      key: headerKey,
                      icon: Icons.library_music_rounded,
                      collapseController: _scrollController,
                      topCapsuleTitle: i18n.tr('music_library'),
                      topCapsuleData: i18n.tr('library_header_stats', {
                        'works': tree.length.toString(),
                        'sessions': libraryHeaderAudioCount.toString(),
                      }),
                      title: i18n.tr('music_library'),
                      titleWidget: _buildHeaderLeftActions(
                        i18n,
                        libraryRefreshBusy,
                      ),
                      onTitleSwipeLeft: widget.onTitleSwipeLeft,
                      onTitleSwipeRight: widget.onTitleSwipeRight,
                      trailing: SizedBox(
                        height: 38,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            HeaderFloatingButton(
                              child: IconButton(
                                key: const ValueKey<String>(
                                  'library_search_button',
                                ),
                                onPressed: _openSearchPage,
                                icon: const Icon(Icons.search_rounded),
                                tooltip: i18n.tr('search'),
                                iconSize: 20,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints.tightFor(
                                  width: 38,
                                  height: 38,
                                ),
                              ),
                            ),
                            if (isLandscape) ...[
                              const SizedBox(width: 8),
                              HeaderFloatingButton(
                                child: IconButton(
                                  onPressed:
                                      canPullRefresh && !libraryRefreshBusy
                                      ? () => unawaited(
                                          _runLibraryPullRefresh(
                                            showSnackbar: true,
                                          ),
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
                                  iconSize: 20,
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints.tightFor(
                                    width: 38,
                                    height: 38,
                                  ),
                                ),
                              ),
                            ],
                            const SizedBox(width: 8),
                            HeaderFloatingButton(
                              child: IconButton(
                                key: const ValueKey<String>(
                                  'library_sort_button',
                                ),
                                onPressed: libraryRefreshBusy
                                    ? null
                                    : _openSortOptions,
                                icon: const Icon(Icons.sort_rounded),
                                tooltip: i18n.tr('sort_by'),
                                iconSize: 20,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints.tightFor(
                                  width: 38,
                                  height: 38,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ).withAppHeaderTransition(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeaderLeftActions(
    AppLanguageProvider i18n,
    bool libraryRefreshBusy,
  ) {
    return HeaderActionPill(
      children: [
        UnifiedPopupMenuButton<_LibraryAddAction>(
          enabled: !libraryRefreshBusy,
          icon: Icons.add_rounded,
          tooltip: i18n.tr('add'),
          iconSize: 20,
          padding: EdgeInsets.zero,
          constraints: HeaderActionPill.buttonConstraints,
          entries: [
            UnifiedMenuEntry<_LibraryAddAction>.action(
              value: _LibraryAddAction.importFolder,
              icon: Icons.create_new_folder_rounded,
              label: i18n.tr('import_folder'),
            ),
            UnifiedMenuEntry<_LibraryAddAction>.action(
              value: _LibraryAddAction.importFiles,
              icon: Icons.upload_file_rounded,
              label: i18n.tr('import_file'),
            ),
            UnifiedMenuEntry<_LibraryAddAction>.action(
              value: _LibraryAddAction.addLibrary,
              icon: Icons.library_add_rounded,
              label: i18n.tr('choose_library'),
            ),
          ],
          onSelected: (value) {
            switch (value) {
              case _LibraryAddAction.importFolder:
                _addFolder();
                break;
              case _LibraryAddAction.importFiles:
                _addFiles();
                break;
              case _LibraryAddAction.addLibrary:
                _addLibrary();
                break;
            }
          },
        ),
        IconButton(
          key: const ValueKey<String>('library_edit_button'),
          onPressed: libraryRefreshBusy ? null : _openLibraryManagementPage,
          icon: const Icon(Icons.edit_note_rounded),
          tooltip: i18n.tr('edit_library'),
          iconSize: 20,
          padding: EdgeInsets.zero,
          constraints: HeaderActionPill.buttonConstraints,
        ),
        IconButton(
          key: const ValueKey<String>('library_batch_metadata_button'),
          onPressed: libraryRefreshBusy ? null : _openBatchMetadataPage,
          icon: const Icon(Icons.library_add_check_rounded),
          tooltip: i18n.tr('batch_metadata'),
          iconSize: 20,
          padding: EdgeInsets.zero,
          constraints: HeaderActionPill.buttonConstraints,
        ),
        IconButton(
          key: const ValueKey<String>('library_video_to_audio_button'),
          onPressed: libraryRefreshBusy ? null : _openVideoConverterPage,
          icon: const Icon(Icons.video_library_rounded),
          tooltip: i18n.tr('video_to_audio'),
          iconSize: 20,
          padding: EdgeInsets.zero,
          constraints: HeaderActionPill.buttonConstraints,
        ),
      ],
    );
  }
}
