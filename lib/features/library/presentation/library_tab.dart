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
import '../../../core/widgets/confirm_action_dialog.dart';
import '../../../core/widgets/content_bound_reorder_area.dart';
import '../../../core/widgets/library_like_cards.dart';
import '../../../core/widgets/duration_overlay.dart';
import '../../../core/widgets/mobile_overlay_inset.dart';
import '../../../core/widgets/operation_feedback.dart';
import '../../../core/widgets/reorder_auto_scroller.dart';
import '../../../core/widgets/scroll_activity_gate.dart';
import '../../../core/widgets/swipe_reveal_card.dart';
import '../../../core/widgets/top_page_header.dart';
import '../../../core/widgets/unified_popup_menu.dart';
import '../../../core/widgets/glass_refresh_indicator.dart';
import 'audio_detail_sheet.dart';
import 'dlsite_metadata_batch_page.dart';
import 'library_scan_feedback.dart';
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

final class _LibraryCoverWarmupScheduler {
  String? _lastSignature;

  void schedule({
    required LibraryCoverUiController controller,
    required bool Function() canCommit,
    required Iterable<MusicTrack?> tracks,
    required int structureRevision,
    required int detailRevision,
    required int coverGeneration,
    required String scope,
  }) {
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
    if (_lastSignature == signature) return;
    _lastSignature = signature;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!canCommit() || _lastSignature != signature) return;
      controller.warmupTracks(warmupTracks);
    });
  }
}

enum _LibraryMoreAction {
  manageLibraries,
  batchMetadata,
  toggleCardPositionsLocked,
}

class LibraryTab extends ConsumerStatefulWidget {
  const LibraryTab({super.key, this.activeTabIndexListenable});

  final ValueListenable<int>? activeTabIndexListenable;

  @override
  ConsumerState<LibraryTab> createState() => _LibraryTabState();
}

class _LibraryTabState extends ConsumerState<LibraryTab>
    with AutomaticKeepAliveClientMixin, MainTabStateMixin<LibraryTab> {
  final _scanCoordinator = LibraryScanCoordinator();

  @override
  bool get wantKeepAlive => true;

  bool get _isActive =>
      widget.activeTabIndexListenable == null ||
      widget.activeTabIndexListenable!.value == tabIndex;

  T _readOrWatch<T>(ProviderListenable<T> provider) {
    return _isActive ? ref.watch(provider) : ref.read(provider);
  }

  void _handleActiveTabChanged() {
    if (mounted) setState(() {});
  }

  Timer? _startupRefreshIdleTimer;
  bool _startupRefreshWaiting = false;
  bool _startupLibraryRefreshCompleted = false;
  bool _initialLibraryContentReady = false;
  bool _refreshTriggeredInCurrentScroll = false;
  bool _isReordering = false;

  final GlobalKey<GlassRefreshIndicatorState> _refreshIndicatorKey =
      GlobalKey<GlassRefreshIndicatorState>();

  final ScrollController _scrollController = ScrollController();
  int? _categorySnapshotRequestStructureRevision;
  int? _categorySnapshotRequestDetailRevision;
  final _coverWarmupScheduler = _LibraryCoverWarmupScheduler();
  int? _durationBackfillStructureRevision;
  late final String _durationBackfillCommitKey;

  @override
  int get tabIndex => 1;

  @override
  double get headerControlsFullHeight => 0;

  @override
  ScrollController get mainScrollController => _scrollController;

  void _openSearchPage() {
    Navigator.of(context).push(
      buildAppPageRoute<void>(
        context: context,
        child: const _LibrarySearchPage(),
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_refreshAfterStartupIdle());
      }
    });
    initTabState(ref.read(mainScreenControllerProvider).scrollToTopTab);
  }

  Future<void> _refreshAfterStartupIdle() async {
    while (mounted && !ref.read(libraryFacadeProvider).state.isInitialized) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (!mounted) return;
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
    if (!UiInteractionCoordinator.instance.isInteracting) {
      _scheduleStartupRefreshAfter(const Duration(milliseconds: 500));
    }
  }

  void _scheduleStartupRefreshAfter(Duration quietWindow) {
    _startupRefreshIdleTimer?.cancel();
    _startupRefreshIdleTimer = Timer(quietWindow, () {
      _startupRefreshIdleTimer = null;
      if (!mounted || UiInteractionCoordinator.instance.isInteracting) return;
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

  void _ensureCategorySnapshot({
    required LibraryFacade libraryFacade,
    required int structureRevision,
    required int detailRevision,
  }) {
    final snapshot = libraryFacade.categorySnapshot;
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
            .read(libraryFacadeProvider)
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

  void _scheduleLibraryCoverWarmup({
    required Iterable<MusicTrack?> tracks,
    required int structureRevision,
    required int detailRevision,
    required int coverGeneration,
    String scope = '',
  }) {
    if (_isReordering) return;
    if (_isReordering) return;
    _coverWarmupScheduler.schedule(
      controller: ref.read(libraryCoverUiControllerProvider),
      canCommit: () => mounted && !_isReordering,
      tracks: tracks,
      structureRevision: structureRevision,
      detailRevision: detailRevision,
      coverGeneration: coverGeneration,
      scope: scope,
    );
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
    widget.activeTabIndexListenable?.removeListener(_handleActiveTabChanged);
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
    final libraryHeaderWorkCount = listStateRawTree.length;
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
    final detailRevision = _readOrWatch(libraryDetailRevisionProvider);
    _readOrWatch(libraryCategoryRevisionProvider);
    final coverGeneration = _readOrWatch(coverGenerationProvider);
    final settingsState =
        _readOrWatch(settingsStateProvider).value ?? SettingsState();
    final cardPositionsLocked = settingsState.cardPositionsLocked;
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
    _ensureMissingDurationBackfill(
      libraryFacade: libraryFacade,
      structureRevision: listStateStructureRevision,
      canRun:
          listStateIsInitialized &&
          _startupLibraryRefreshCompleted &&
          !listStateIsScanning &&
          !listStateIsBackgroundScanning,
    );
    if (listStateIsInitialized) {
      _ensureCategorySnapshot(
        libraryFacade: libraryFacade,
        structureRevision: listStateStructureRevision,
        detailRevision: detailRevision,
      );
    }
    final tree = listStateRawTree;
    final bottomInset = MobileOverlayInset.of(context);

    final headerControlsFullHeight = this.headerControlsFullHeight;
    final topTotalHeight = headerHeight + 4;
    final headerContentHeight = topTotalHeight + headerControlsFullHeight;
    // Remove the extra 96px to make content flush with the bottom dock.
    final listBottomInset = bottomInset;
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    const double expansion = 320.0;
    final listTopPadding = headerControlsFullHeight + 4.0 + expansion;
    const listBottomPadding = 16.0 + expansion;
    final listViewportBottomInset =
        listBottomInset + (isLandscape ? 16.0 : 0.0);
    // Reduced cacheExtent to significantly lower memory footprint and improve
    // scroll/swipe performance.
    const listCacheExtent = 320.0;
    final hasLibrary = listStateHasLibrary || libraryHeaderAudioCount > 0;
    final categorySnapshot = libraryFacade.categorySnapshot;
    final libraryCardDetailsReady =
        categorySnapshot != null &&
        categorySnapshot.structureRevision == listStateStructureRevision &&
        categorySnapshot.detailRevision == detailRevision;
    if (!_initialLibraryContentReady &&
        listStateIsInitialized &&
        libraryCardDetailsReady) {
      _initialLibraryContentReady = true;
    }
    final showLibrarySkeleton =
        (libraryHeaderHasWatchedSources || hasLibrary) &&
        !_initialLibraryContentReady;
    if (!showLibrarySkeleton &&
        _startupLibraryRefreshCompleted &&
        listStateIsInitialized) {
      _scheduleLibraryCoverWarmup(
        tracks: _libraryCoverWarmupTracksForTree(tree),
        structureRevision: listStateStructureRevision,
        detailRevision: detailRevision,
        coverGeneration: coverGeneration,
        scope: 'all',
      );
    }
    final canPullRefresh = listStateCanPullRefresh;

    Widget buildTopLevelLibraryItem(BuildContext context, int index) {
      if (index == tree.length) {
        return const SizedBox.shrink(key: ValueKey('bottom_spacing'));
      }
      final node = tree[index];
      return KeyedSubtree(
        key: ValueKey(node.path),
        child: RepaintBoundary(
          child: _LibraryTreeItem(
            node: node,
            index: index,
            cardPositionsLocked: cardPositionsLocked,
          ),
        ),
      );
    }

    Widget emptyListBody() {
      final relativeTop = listTopPadding;
      const relativeBottom = listBottomPadding;

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
                headerHeight: headerHeight,
                bottomInset: listViewportBottomInset,
                topExpansion: expansion,
                bottomExpansion: expansion,
                scrollController: _scrollController,
                showScrollbar: isLandscape,
                scrollbarMainAxisMargin: isLandscape ? 8 : 0,
                child: PlaceholderContentTransition(
                  showPlaceholder:
                      !listStateIsInitialized || showLibrarySkeleton,
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
                          triggerMode:
                              GlassRefreshIndicatorTriggerMode.anywhere,
                          child: cardPositionsLocked
                              ? ListView.builder(
                                  key: const PageStorageKey<String>(
                                    'locked_library_list',
                                  ),
                                  controller: _scrollController,
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
                                  keyboardDismissBehavior:
                                      ScrollViewKeyboardDismissBehavior.onDrag,
                                  itemCount: tree.length + 1,
                                  itemBuilder: buildTopLevelLibraryItem,
                                )
                              : ReorderAutoScroller(
                                  scrollController: _scrollController,
                                  isDragging: _isReordering,
                                  contentMarginTop: listTopPadding,
                                  contentMarginBottom: listBottomPadding,
                                  child: ReorderableListView.builder(
                                    key: const PageStorageKey<String>(
                                      'locked_library_list',
                                    ),
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
                                        ScrollViewKeyboardDismissBehavior
                                            .onDrag,
                                    onReorder: (oldIndex, newIndex) {
                                      libraryFacade.reorderLibraryNodes(
                                        oldIndex,
                                        newIndex,
                                      );
                                      setState(() => _isReordering = false);
                                    },
                                    onReorderStart: (index) {
                                      setState(() => _isReordering = true);
                                      unawaited(
                                        AppInteractionFeedback.trigger(
                                          AppInteractionFeedbackType
                                              .destructive,
                                        ),
                                      );
                                    },
                                    onReorderEnd: (_) {
                                      if (_isReordering) {
                                        setState(() => _isReordering = false);
                                      }
                                    },
                                    proxyDecorator: (child, index, animation) =>
                                        _buildReorderProxy(
                                          context,
                                          child,
                                          animation,
                                        ),
                                    itemCount: tree.length + 1,
                                    itemBuilder: buildTopLevelLibraryItem,
                                  ),
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
                subtitle:
                    '${i18n.tr('work_count', {'count': libraryHeaderWorkCount})} · '
                    '${i18n.tr('audio_count', {'count': libraryHeaderAudioCount})}',
                subtitleFontSize: 11,
                fitSubtitleToWidth: true,
                collapseController: _scrollController,
                floatingReveal: true,
                floatingRevealDistance: 56,
                trailing: SizedBox(
                  width: 152 + (isLandscape ? 52 : 0),
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
                                ref
                                    .read(settingsRepositoryProvider)
                                    .setCardPositionsLocked(
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
      padding: EdgeInsets.fromLTRB(16.0, topInset, 16.0, bottomInset),
      children: [
        for (int i = 0; i < 5; i++)
          const Padding(
            padding: EdgeInsets.only(bottom: 6),
            child: LibraryLikeSkeletonCard(),
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
